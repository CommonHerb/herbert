#!/usr/bin/env bash
# Mutation proof for native-codegen link 64 (riposte): each gate leg that guards the DEVICE-OUTPUT
# capability must BITE (go RED) when broken. Image-forge mutations (no reseed) + one compiler mutation:
#   M-noout   : NOP the `out dx,al` inside the 18-byte op-53 window -> (a) the output white-box (op-53
#               window / 'out dx,al' count) must fail, AND (b) at runtime the COM1 stream VANISHES while
#               the checksum frame stays correct (feed b=4 -> cap EMPTY, e9 still de52ad) -- proving the
#               captured stream provably traces to the op-53 out, not to any other channel.
#   M-pushdx  : the window's `push rbx` (53) -> `push rdx` (52; at push time dx holds 0x3FD, the LSR
#               port set by the drain) -> at runtime the STREAM stays right but the CHECKSUM frame goes
#               wrong (b=4: observed def4ad/139 vs the genuine de52ad/199; asserted as stream-intact +
#               frame != genuine) -- proving the gate consumes output_byte's RETURN VALUE (the full
#               argument), so a pops-without-correct-push lowering cannot hide behind a correct stream.
#   M-nodrain : NOP the 9-byte TEMT drain (mov dx,0x3FD; in al,dx; test al,0x40; jz) -> the output
#               white-box (window + 'in al,dx' count) must fail. (Runtime evidence that the drain is
#               load-bearing lives on the Bochs substrate -- STEP-0 measured 1/3 then 2/3 bytes lost
#               without it; the mutation harness stays QEMU-only by precedent, where TX never blocks.)
#   M-nouart  : zero the 56-byte UART init block in the OUTPUT-ONLY (oo) image -> the white-box
#               (uart-block-present) must fail -- the op-53-alone init predicate is load-bearing.
#   M-golden  : perturb one image byte -> the golden-hash pin must fail.
#   M-op53size: COMPILER mutation -- nc_tap_op_size(53) 18->17 -> the emission-length invariant (ERR
#               610/611) fires, the probe does NOT compile (no a.out). Proves the size feeds the layout.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
backend="$repo_root/stack/native_compile_fragment.herb"
goldens_dir="$script_dir/riposte_goldens"
feeder="$script_dir/kernel_io_feed.py"
source "$script_dir/native_codegen_oracle.sh"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
native_codegen_ensure_compiler "$tmp/gen1" || exit 1
pass=0; fail=0
fail_test() { echo "FAIL: link64-mutation ($1)"; fail=$((fail + 1)); }
have_qemu() { command -v qemu-system-x86_64 >/dev/null 2>&1; }
if ! have_qemu; then echo "NOTE: no QEMU; link64-mutation skipped locally (authoritative in CI)."; [[ "${KERNEL_CODEGEN_REQUIRE_EMU:-0}" == "1" ]] && { echo "FAIL: REQUIRE_EMU=1 but no QEMU"; exit 1; }; exit 0; fi

OP53_WINDOW="5b66baf80388d8ee66bafd03eca84074f753"
OP45_WINDOW="66bafd03eca80174f766baf803ec0fb6c050"
UART_BLOCK="66bafb03b003ee66baf903b000ee66bafb03b080ee66baf803b001ee66baf903b000ee66bafb03b003ee66bafa03b000ee66bafc03b003ee"

# base images: ro (input->recursive self-sized output) and oo (output-only).
compile_src() { # out src...
    local out="$1"; shift
    local cdir="$tmp/c.$$.$RANDOM"; mkdir -p "$cdir"
    printf -- '-- emit: multiboot32-long64\n%b' "$*" > "$cdir/p.herb"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < p.herb >/dev/null 2>/dev/null )
    [[ -f "$cdir/a.out" ]] || return 1
    cp "$cdir/a.out" "$out"
}
RO_SRC='func spew(n):\n    if n == 0: return 0 end\n    return output_byte(n * 7 + 259) + spew(n - 1)\nend\nfunc main(): return spew(input_byte()) * 4294967296 end\n'
OO_SRC='func emitpair(v):\n    return output_byte(v) + output_byte(v * 3 + 130)\nend\nfunc main(): return emitpair(65) * 4294967296 end\n'
base="$tmp/ro.elf"; compile_src "$base" "$RO_SRC" || { echo "FAIL: link64-mutation (base ro did not compile -- compiler lacks op 53?)"; exit 1; }
oobase="$tmp/oo.elf"; compile_src "$oobase" "$OO_SRC" || { echo "FAIL: link64-mutation (base oo did not compile)"; exit 1; }

# output white-box (mirrors the gate's output_wb; n53/n45 for the ro shape).
output_wb_ok() { # elf n53 n45
    local elf="$1" n53="$2" n45="$3"
    local chx; chx=$(dd if="$elf" bs=1 skip=4108 status=none 2>/dev/null | xxd -p | tr -d '\n')
    [[ "$(echo "$chx" | grep -o "$OP53_WINDOW" | wc -l | tr -d ' ')" -eq "$n53" ]] || return 1
    [[ "$(echo "$chx" | grep -o "$OP45_WINDOW" | wc -l | tr -d ' ')" -eq "$n45" ]] || return 1
    [[ "$(echo "$chx" | grep -o "$UART_BLOCK" | wc -l | tr -d ' ')" -eq 1 ]] || return 1
    local sig_off; sig_off=$(echo "$chx" | grep -bo 'ffff00000' | head -1 | cut -d: -f1)
    local xb=$(( ${sig_off:-0} / 2 ))
    [[ "$xb" -gt 56 ]] || return 1
    dd if="$elf" bs=1 skip=4108 count="$xb" status=none of="$tmp/x.bin" 2>/dev/null
    local dis; dis=$(objdump -D -b binary -m i386:x86-64 -M intel "$tmp/x.bin" 2>/dev/null)
    [[ "$(echo "$dis" | grep -cE '\bout +dx,al\b')" -eq $((20 + n53)) ]] || return 1
    [[ "$(echo "$dis" | grep -cE '\bin +al,dx\b')" -eq $((2 * n45 + n53)) ]] || return 1
    return 0
}
expect_red() { if [[ "$1" -ne 0 ]]; then pass=$((pass + 1)); else fail_test "$2 did not bite"; fi; }

# control: both base images PASS the white-box (so the forge, not a broken checker, is what fails).
if output_wb_ok "$base" 1 1; then pass=$((pass + 1)); else fail_test "control: base ro image fails output_wb (checker broken)"; fi
if output_wb_ok "$oobase" 2 0; then pass=$((pass + 1)); else fail_test "control: base oo image fails output_wb (checker broken)"; fi

# ---- image forger ----
PY="$tmp/mut.py"; cat > "$PY" <<'PYEOF'
import sys
elf = bytearray(open(sys.argv[1], 'rb').read()); mode = sys.argv[2]
win = bytes.fromhex("5b66baf80388d8ee66bafd03eca84074f753")
uart = bytes.fromhex("66bafb03b003ee66baf903b000ee66bafb03b080ee66baf803b001ee66baf903b000ee66bafb03b003ee66bafa03b000ee66bafc03b003ee")
i = bytes(elf).find(win)
if mode in ("noout", "pushdx", "nodrain"):
    assert i > 0, "op-53 window not found"
if mode == "noout":
    elf[i+7] = 0x90                    # the out dx,al -> NOP (stream vanishes; length preserved)
elif mode == "pushdx":
    elf[i+17] = 0x52                   # push rbx -> push rdx (checksum corrupted; stream intact)
elif mode == "nodrain":
    elf[i+8:i+17] = b"\x90" * 9        # the TEMT drain (mov dx; in; test; jz) -> NOPs
elif mode == "nouart":
    j = bytes(elf).find(uart); assert j > 0, "uart block not found"
    elf[j:j+56] = b"\x00" * 56
elif mode == "golden":
    elf[4200] ^= 0xFF
open(sys.argv[3], 'wb').write(bytes(elf))
PYEOF
# forge <mode> <in.elf> <out.elf> (mut.py takes in, mode, out -- and must SUCCEED: a forge that
# fails to produce its mutant would make every downstream RED vacuous).
forge() { python3 "$PY" "$2" "$1" "$3" && [[ -f "$3" ]] || { fail_test "forge $1 failed to produce a mutant image"; return 1; }; }

# ---- QEMU duplex runner (grades cap + e9 + exit against EXPECTED values) ----
free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }
run_duplex() { # elf byte -> sets GOT_RC GOT_E9 GOT_CAP; returns 1 on harness failure
    local elf="$1" byte="$2"
    local W="$tmp/run.$RANDOM"; mkdir -p "$W"
    local port; port=$(free_port)
    python3 "$feeder" "$port" "$byte" --cap "$W/cap.bin" --hold 45 > "$W/feed.log" 2>&1 &
    local fp=$!
    local i; for i in $(seq 1 80); do grep -q LISTENING "$W/feed.log" 2>/dev/null && break; sleep 0.1; done
    grep -q LISTENING "$W/feed.log" || { kill "$fp" 2>/dev/null; return 1; }
    timeout 60 qemu-system-x86_64 -kernel "$elf" -debugcon file:"$W/e9.bin" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none \
        -chardev socket,id=s0,host=127.0.0.1,port="$port",server=off -serial chardev:s0 \
        -monitor none -cpu qemu64 -m 64M
    GOT_RC=$?
    wait "$fp" 2>/dev/null
    GOT_E9=$(xxd -p "$W/e9.bin" 2>/dev/null | tr -d '\n')
    GOT_CAP=$(xxd -p "$W/cap.bin" 2>/dev/null | tr -d '\n')
    return 0
}

# --- M-noout: white-box RED + runtime: cap EMPTY while the checksum frame stays correct (b=4).
forge noout "$base" "$tmp/m_noout.elf"
output_wb_ok "$tmp/m_noout.elf" 1 1; expect_red $? "M-noout white-box"
if run_duplex "$tmp/m_noout.elf" 4; then
    if [[ -z "$GOT_CAP" && "$GOT_E9" == "de52ad" && "$GOT_RC" -eq 199 ]]; then pass=$((pass + 1));
    else fail_test "M-noout runtime: expected EMPTY cap + intact de52ad/199, got cap=${GOT_CAP:-EMPTY} e9=$GOT_E9 rc=$GOT_RC"; fi
else fail_test "M-noout runtime: harness failure (feeder never LISTENING)"; fi

# --- M-pushdx: runtime: stream INTACT but the checksum frame CORRUPTS (b=4: at push time dx holds
#     0x3FD -- the LSR, set by the drain -- so the sum becomes 4*1021, never 4 distinct 7n+259 args;
#     observed def4ad/139). Assert the RED essence (stream right, frame wrong) rather than pinning
#     mutant-internal register state.
forge pushdx "$base" "$tmp/m_pushdx.elf"
output_wb_ok "$tmp/m_pushdx.elf" 1 1; expect_red $? "M-pushdx white-box"
if run_duplex "$tmp/m_pushdx.elf" 4; then
    # the frame must be WELL-FORMED (de..ad -- the run COMPLETED through the epilogue) yet differ from
    # the genuine de52ad (completeness-critic tightening: a mutant that hung with an empty e9 must not
    # satisfy this leg -- the corruption essence is a completed-but-wrong checksum, not a dead channel).
    if [[ "$GOT_CAP" == "1f18110a" && "$GOT_E9" =~ ^de[0-9a-f]{2}ad$ && "$GOT_E9" != "de52ad" && "$GOT_RC" -ne 199 ]]; then pass=$((pass + 1));
    else fail_test "M-pushdx runtime: expected intact stream 1f18110a + a COMPLETED corrupted frame (de..ad != de52ad), got cap=${GOT_CAP:-EMPTY} e9=$GOT_E9 rc=$GOT_RC"; fi
else fail_test "M-pushdx runtime: harness failure (feeder never LISTENING)"; fi

# --- M-nodrain: white-box RED (QEMU runtime is blind to the drain by design; Bochs evidence in STEP-0).
forge nodrain "$base" "$tmp/m_nodrain.elf"
output_wb_ok "$tmp/m_nodrain.elf" 1 1; expect_red $? "M-nodrain white-box"

# --- M-nouart: zero the uart block in the OUTPUT-ONLY image -> white-box RED.
forge nouart "$oobase" "$tmp/m_nouart.elf"
output_wb_ok "$tmp/m_nouart.elf" 2 0; expect_red $? "M-nouart white-box"

# --- M-golden: one perturbed byte -> the committed-golden pin RED (the equality check FAILS).
forge golden "$base" "$tmp/m_golden.elf"
want=$(cat "$goldens_dir/ro.sha256"); got=$(sha256sum "$tmp/m_golden.elf" | cut -d' ' -f1)
[[ "$got" == "$want" ]]; expect_red $? "M-golden hash pin"

# --- M-op53size: compiler mutation -- op-size 18->17 must trip ERR 610/611 (no a.out).
mutfrag="$tmp/frag_op53size.herb"
python3 - "$backend" "$mutfrag" <<'PYEOF'
import sys
src = open(sys.argv[1]).read()
old = "    if op == 53:\n        return 18\n    end\n    return nc64_op_size(op, is_last)"
new = "    if op == 53:\n        return 17\n    end\n    return nc64_op_size(op, is_last)"
assert old in src, "op-53 size site not found"
open(sys.argv[2], 'w').write(src.replace(old, new, 1))
PYEOF
mutc="$tmp/mutc"; mdir="$tmp/mut.d"; mkdir -p "$mdir"
( cd "$mdir" && "$NATIVE_CODEGEN_COMPILER" < "$mutfrag" >/dev/null 2>/dev/null && mv a.out "$mutc" ) || { fail_test "M-op53size: mutated fragment itself did not compile"; mutc=""; }
if [[ -n "$mutc" && -x "$mutc" || -n "$mutc" && -f "$mutc" ]]; then
    chmod +x "$mutc"
    pdir="$tmp/mut.p"; mkdir -p "$pdir"
    printf -- '-- emit: multiboot32-long64\n%b' "$RO_SRC" > "$pdir/p.herb"
    ( cd "$pdir" && "$mutc" < p.herb > out.txt 2>&1 )
    if [[ ! -f "$pdir/a.out" ]] && grep -qE 'ERR 61[01]' "$pdir/out.txt"; then pass=$((pass + 1));
    else fail_test "M-op53size: expected ERR 610/611 + no a.out, got a.out=$([[ -f "$pdir/a.out" ]] && echo yes || echo no) msg=$(head -1 "$pdir/out.txt")"; fi
fi

if [[ "$fail" -gt 0 ]]; then
    echo "native-codegen link64-mutation (riposte): pass=$pass fail=$fail"
    exit 1
fi
echo "PASS: link64-mutation ($pass legs each bit RED where they must: control GREEN x2 (ro+oo pass the checker) + M-noout (white-box + runtime: the stream VANISHES while the checksum frame stays -- the capture traces to the op-53 out) + M-pushdx (white-box + runtime: the stream stays while the checksum frame CORRUPTS -- the gate consumes the op's return value) + M-nodrain (white-box; Bochs runtime evidence in the link's STEP-0 record) + M-nouart (op-53-alone init predicate) + M-golden (committed-golden pin) + M-op53size (ERR 610/611 emission-length invariant fires at compile time))"
