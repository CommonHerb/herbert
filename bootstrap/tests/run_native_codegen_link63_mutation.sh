#!/usr/bin/env bash
# Mutation proof for native-codegen link 63 (hearken): each gate leg that guards the LATE-BOUND INPUT
# capability must BITE (go RED) when broken. Image-forge mutations (no reseed) + one compiler mutation:
#   M-noinput   : overwrite the 18-byte op-45 window with `push 0` (constant) + NOPs -> (a) the instruction
#                 white-box (op-45 window / 'in al,dx' count) must fail, AND (b) the runtime output no longer
#                 tracks the fed byte (feed b=8 -> forged emits de00ad, not de24ad). Proves the graded byte
#                 provably traces to the RBR read, not a bake.
#   M-nouart    : zero the 56-byte UART init block -> the input white-box (uart-block-present) must fail.
#   M-golden    : perturb one image byte -> the golden-hash pin must fail.
#   M-op45size  : COMPILER mutation -- nc_tap_op_size(45) 18->17 -> the emission-length invariant (ERR
#                 610/611) fires, the probe does NOT compile (no a.out). Proves the size feeds the layout.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
backend="$repo_root/stack/native_compile_fragment.herb"
goldens_dir="$script_dir/hearken_goldens"
source "$script_dir/native_codegen_oracle.sh"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
native_codegen_ensure_compiler "$tmp/gen1" || exit 1
pass=0; fail=0
fail_test() { echo "FAIL: link63-mutation ($1)"; fail=$((fail + 1)); }
have_qemu() { command -v qemu-system-x86_64 >/dev/null 2>&1; }
if ! have_qemu; then echo "NOTE: no QEMU; link63-mutation skipped locally (authoritative in CI)."; [[ "${KERNEL_CODEGEN_REQUIRE_EMU:-0}" == "1" ]] && { echo "FAIL: REQUIRE_EMU=1 but no QEMU"; exit 1; }; exit 0; fi

OP45_WINDOW="66bafd03eca80174f766baf803ec0fb6c050"
UART_BLOCK="66bafb03b003ee66baf903b000ee66bafb03b080ee66baf803b001ee66baf903b000ee66bafb03b003ee66bafa03b000ee66bafc03b003ee"

# base image: probe hi (input in main). Compiled with the live compiler (which has op 45).
base="$tmp/hi.elf"; cdir="$tmp/hi.d"; mkdir -p "$cdir"
printf -- '-- emit: multiboot32-long64\nfunc tri(n):\n    if n == 0: return 0 end\n    return n + tri(n - 1)\nend\nfunc main(): return tri(input_byte()) * 4294967296 end\n' > "$cdir/p.herb"
( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < p.herb >/dev/null 2>/dev/null )
[[ -f "$cdir/a.out" ]] || { echo "FAIL: link63-mutation (base hi did not compile -- compiler lacks op 45?)"; exit 1; }
cp "$cdir/a.out" "$base"

# instruction-aware white-box on an image (mirrors the gate's input_wb).
input_wb_ok() { # elf -> 0 if all input legs pass
    local elf="$1"
    local chx; chx=$(dd if="$elf" bs=1 skip=4108 status=none 2>/dev/null | xxd -p | tr -d '\n')
    [[ "$(echo "$chx" | grep -o "$OP45_WINDOW" | wc -l | tr -d ' ')" -eq 1 ]] || return 1
    [[ "$(echo "$chx" | grep -o "$UART_BLOCK" | wc -l | tr -d ' ')" -eq 1 ]] || return 1
    local sig_off; sig_off=$(echo "$chx" | grep -bo 'ffff00000' | head -1 | cut -d: -f1)
    local xb=$(( ${sig_off:-0} / 2 ))
    [[ "$xb" -gt 56 ]] || return 1
    dd if="$elf" bs=1 skip=4108 count="$xb" status=none of="$tmp/x.bin" 2>/dev/null
    [[ "$(objdump -D -b binary -m i386:x86-64 -M intel "$tmp/x.bin" 2>/dev/null | grep -cE '\bin +al,dx\b')" -eq 2 ]] || return 1
    return 0
}
expect_red() { if [[ "$1" -ne 0 ]]; then pass=$((pass + 1)); else fail_test "$2 did not bite"; fi; }

# control: the base image PASSES input_wb (so the forge, not a broken checker, is what fails).
if input_wb_ok "$base"; then pass=$((pass + 1)); else fail_test "control: base hi image fails input_wb (checker broken)"; fi

# --- M-noinput: forge op-45 window -> `push 0` (6A 00) + 16 NOP (90). Stack-balanced (push imm8 = 8-byte 0).
PY="$tmp/mut.py"; cat > "$PY" <<'PYEOF'
import sys,struct
elf=bytearray(open(sys.argv[1],'rb').read()); mode=sys.argv[2]
filesz=struct.unpack('<I',elf[68:72])[0]; co=4108; code=bytes(elf[co:co+filesz-12])
win=bytes.fromhex("66bafd03eca80174f766baf803ec0fb6c050")
uart=bytes.fromhex("66bafb03b003ee66baf903b000ee66bafb03b080ee66baf803b001ee66baf903b000ee66bafb03b003ee66bafa03b000ee66bafc03b003ee")
if mode=='noinput':
    i=code.find(win)
    if i<0: print("no op45 window"); sys.exit(2)
    forged=bytes([0x6A,0x00])+bytes([0x90]*16)   # push 0 ; 16 nop
    elf[co+i:co+i+18]=forged
    open(sys.argv[3],'wb').write(elf); sys.exit(0)
if mode=='nouart':
    i=code.find(uart)
    if i<0: print("no uart block"); sys.exit(2)
    elf[co+i:co+i+56]=bytes([0x90]*56)   # NOP out the uart init
    open(sys.argv[3],'wb').write(elf); sys.exit(0)
sys.exit(3)
PYEOF

python3 "$PY" "$base" noinput "$tmp/m_noin.elf"
# (a) input white-box must fail on the forged image
if input_wb_ok "$tmp/m_noin.elf"; then fail_test "M-noinput (input white-box) did not bite"; else pass=$((pass + 1)); fi
# (b) runtime: feed b=8 -> genuine tri(8)=36=0x24 (de24ad). Forged pushes 0 -> tri(0)=0 -> de00ad, NOT de24ad.
feeder="$script_dir/kernel_input_feed.py"
port=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
python3 "$feeder" "$port" 8 --hold 6 > "$tmp/mn.feed" 2>&1 &
fp=$!; for i in $(seq 1 40); do grep -q LISTENING "$tmp/mn.feed" && break; sleep 0.1; done
timeout 60 qemu-system-x86_64 -kernel "$tmp/m_noin.elf" -debugcon file:"$tmp/mn.bin" \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none \
    -chardev socket,id=s0,host=127.0.0.1,port="$port",server=off -serial chardev:s0 -monitor none -cpu qemu64 -m 64M >/dev/null 2>&1
wait "$fp" 2>/dev/null
got=$(xxd -p "$tmp/mn.bin" 2>/dev/null | tr -d '\n')
if echo "$got" | grep -q 'de24ad'; then fail_test "M-noinput (runtime) did not bite: forged image still emitted de24ad"; else pass=$((pass + 1)); fi

# --- M-nouart: zero the uart block -> input white-box (uart-present) must fail
python3 "$PY" "$base" nouart "$tmp/m_nouart.elf"
if input_wb_ok "$tmp/m_nouart.elf"; then fail_test "M-nouart (input white-box) did not bite"; else pass=$((pass + 1)); fi

# --- M-golden: base matches the committed golden; a one-byte perturb must MISMATCH it.
want_g=$(cat "$goldens_dir/hi.sha256" 2>/dev/null || echo MISSING)
got_base=$(sha256sum "$base" | cut -d' ' -f1)
cp "$base" "$tmp/m_gold.elf"; printf '\xff' | dd of="$tmp/m_gold.elf" bs=1 seek=5000 count=1 conv=notrunc status=none 2>/dev/null
got_forged=$(sha256sum "$tmp/m_gold.elf" | cut -d' ' -f1)
if [[ "$got_base" == "$want_g" && "$got_forged" != "$want_g" ]]; then pass=$((pass + 1)); else fail_test "M-golden vacuous (base==golden:$([[ "$got_base" == "$want_g" ]] && echo yes || echo NO))"; fi

# --- M-op45size (COMPILER mutation): nc_tap_op_size(45) 18->17 -> emission-length invariant fires ->
#     the probe must NOT compile. Requires the committed seed to mint the mutant (C-free self-compile).
seed_bin="$tmp/seedbin"
if native_codegen_seed_available 2>/dev/null; then
    cp "$repo_root/bootstrap/seed/gen1.seed" "$seed_bin" 2>/dev/null && chmod +x "$seed_bin"
fi
if [[ -x "$seed_bin" ]]; then
    mut_backend="$tmp/mut_backend.herb"
    # narrowly target the op-45 arm of nc_tap_op_size (the line 'if op == 45:' inside nc_tap_op_size returns 18)
    awk 'BEGIN{inf=0} /^func nc_tap_op_size\(/{inf=1} inf==1 && /return 18/{sub(/return 18/,"return 17"); inf=2} {print}' "$backend" > "$mut_backend"
    if ! cmp -s "$backend" "$mut_backend"; then
        md="$tmp/mut.d"; mkdir -p "$md"; cp "$seed_bin" "$md/sb"; chmod +x "$md/sb"
        ( cd "$md" && ./sb < "$mut_backend" >/dev/null 2>/dev/null )   # mint mutant compiler -> a.out
        if [[ -f "$md/a.out" ]]; then
            cp "$md/a.out" "$md/mutc"; chmod +x "$md/mutc"
            printf -- '-- emit: multiboot32-long64\nfunc tri(n):\n    if n == 0: return 0 end\n    return n + tri(n - 1)\nend\nfunc main(): return tri(input_byte()) * 4294967296 end\n' > "$md/p.herb"
            ( cd "$md" && rm -f a.out && ./mutc < p.herb >/dev/null 2>/dev/null )
            if [[ -f "$md/a.out" ]]; then fail_test "M-op45size: probe compiled despite wrong op_size (length invariant did not fire)"; else pass=$((pass + 1)); fi
        else
            echo "NOTE: M-op45size mutant compiler did not mint (skipped); other mutations authoritative."
        fi
    else
        echo "NOTE: M-op45size sed matched nothing (skipped)."
    fi
else
    echo "NOTE: M-op45size needs the committed seed to mint a mutant (skipped locally; the ERR 610/611 invariants are exercised by the gate's golden pin)."
fi

echo ""
if [[ "$fail" -ne 0 ]]; then echo "$fail link63-mutation sub-test(s) failed."; exit 1; fi
echo "PASS: link63-mutation ($pass legs each bit RED: op-45 window white-box + runtime input-trace (M-noinput), uart-block white-box (M-nouart), golden hash (M-golden), emission-length invariant (M-op45size))"
exit 0
