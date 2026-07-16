#!/usr/bin/env bash
# Native-codegen Link 41 (mmj / THE UNION) MUTATION proof: the held-back proof that the gate's checks BITE.
# Control must grade GREEN first (else the grader is vacuous); then each mutation must be CAUGHT:
#   M-byteshift : a 1-byte change to the emitted module -> the white-box BYTE-PIN bites (hex != target).
#   M-fixedcount: a STRAIGHT-LINE module that writes a CONSTANT 2 words (no recursion) -> runtime grade RED
#                 (count != fed) -- the variable-LENGTH make-or-break is load-bearing.
#   M-content   : the real recursion (count==fed) but writes le32(0) each level -> runtime grade RED (content pin).
#   M-forge (HEADLINE): a NON-RECURSIVE backward-`jmp` loop that manufactures the descending-esp/count/eip
#                 signature. It grades GREEN AT RUNTIME on real silicon -- recursion is NOT observable in a
#                 syscall trace -- so the runtime grade ALONE is forgeable. The UNION is bound at the EMITTER
#                 layer: the forge is byte-DIFFERENT from target_module('down') (BYTE-PIN catches it) AND has
#                 ZERO backward E8 calls (assert_backward_call catches it). A backward `jmp` is UNEMITTABLE from
#                 Herbert (no while; ouro branches forward-only), so byte-pin + backward-call forbid the forge.
# Run under KERNEL_CODEGEN_MUTATION=1 (CI), like every prior link.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
HERBERT="${HERBERT:-$repo_root/build/herbert}"
backend="$repo_root/stack/native_compile_fragment.herb"
REF="$script_dir/mmj_ref.py"
feeder="$script_dir/kernel_input_feed.py"
REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"

if [[ "${NATIVE_CODEGEN_ORACLE:-golden}" == "c" && ! -x "$HERBERT" ]]; then echo "FAIL: stack/native_compile_fragment.herb (cannot find herbert at $HERBERT)"; exit 1; fi
if [[ ! -f "$backend" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing backend)"; exit 1; fi
if [[ ! -f "$REF" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing mmj_ref.py $REF)"; exit 1; fi
if [[ ! -f "$feeder" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing input feeder $feeder)"; exit 1; fi

source "$script_dir/native_codegen_oracle.sh"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
HVMARK="/tmp/.hv_harness_fail.$$"; rm -f "$HVMARK"   # fail-closed marker: a dead feeder/QEMU run trips this -> hard fail at end
native_codegen_ensure_compiler "$work/gen1" || exit 1
pass=0; fail=0
fail_test() { echo "FAIL: stack/native_compile_fragment.herb ($1)"; fail=$((fail + 1)); }
have_qemu() { command -v qemu-system-x86_64 >/dev/null 2>&1; }
free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }

FX=5; FXH=5
FY=8; FYH=8

REFK="$work/k.elf"; KEND="$(python3 "$REF" kernelelf "$REFK")"
REFM="$work/target.bin"; python3 "$REF" module down "$REFM"

if ! have_qemu; then
    if [[ "$REQUIRE_EMU" == "1" ]]; then echo "FAIL: stack/native_compile_fragment.herb (qemu required under KERNEL_CODEGEN_REQUIRE_EMU=1)"; exit 1; fi
    echo "SKIP: qemu not found (mutation proof needs an emulator; set KERNEL_CODEGEN_REQUIRE_EMU=1 to force)."
    exit 0
fi

boot() { # modfile byte -> sets OUT (debugcon stream)
    local mod="$1" byte="$2" W; W="$(mktemp -d "$work/run.XXXX")"; OUT="$W/e9"
    local port; port=$(free_port)
    python3 "$feeder" "$port" "$byte" --hold 6 > "$W/feed.log" 2>&1 & local fp=$!
    local i; for i in $(seq 1 40); do grep -q LISTENING "$W/feed.log" && break; sleep 0.1; done
    grep -q LISTENING "$W/feed.log" 2>/dev/null || { echo "FAIL: link41 harness failure -- feeder never reached LISTENING (socket/QEMU launch dead; NOT a mutation bite)" >&2; : > "$HVMARK"; kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null; return; }
    timeout 60 qemu-system-x86_64 -kernel "$REFK" -initrd "$mod" -debugcon file:"$OUT" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none -cpu qemu64 \
        -chardev socket,id=s0,host=127.0.0.1,port="$port",server=off -serial chardev:s0 -monitor none -m 64M >/dev/null 2>"$OUT.qerr"
        grep -qvE 'terminating on signal' "$OUT.qerr" 2>/dev/null && { echo "FAIL: link41 harness failure -- QEMU launch error: $(grep -vE 'terminating on signal' "$OUT.qerr" | head -1)" >&2; : > "$HVMARK"; }   # F2a: only a NON-timeout stderr line is a launch failure; a timeout-kill (hang bite) is left to the grader
    wait "$fp" 2>/dev/null
}
grade_green() { python3 "$REF" grade "$OUT" "$KEND" "$1" down >/dev/null 2>&1; }   # 0 == GREEN

# ===== CONTROL: the gen-1-EMITTED down module must grade GREEN on both bytes (else the grader is vacuous) =====
CDIR="$work/ctl.d"; mkdir -p "$CDIR"
printf -- '-- emit: module-mmj\n%s\n' "$(python3 "$REF" src down)" > "$CDIR/m.herb"
( cd "$CDIR" && "$NATIVE_CODEGEN_COMPILER" < m.herb >/dev/null 2>"$CDIR/err" )
[[ -f "$CDIR/a.out" ]] || { echo "FAIL: stack/native_compile_fragment.herb (control down did not compile)"; exit 1; }
CTL="$work/ctl.bin"; cp "$CDIR/a.out" "$CTL"
cmp -s "$CTL" "$REFM" || { echo "FAIL: stack/native_compile_fragment.herb (control: emitter != target_module)"; exit 1; }
for b in "$FX" "$FY"; do
    boot "$CTL" "$b"
    if grade_green "$(printf '%x' "$b")"; then pass=$((pass + 1)); else fail_test "CONTROL down byte=$b not GREEN -- grader vacuous"; fi
done

# ===== M-byteshift: a 1-byte change to the module must break the BYTE-PIN (hex != target) =====
python3 - "$CTL" "$work/shift.bin" <<'PY'
import sys
b=bytearray(open(sys.argv[1],'rb').read()); b[6]^=0x01
open(sys.argv[2],'wb').write(b)
PY
if ! cmp -s "$work/shift.bin" "$REFM"; then pass=$((pass + 1)); else fail_test "M-byteshift: byte-pin would not detect a 1-byte module change"; fi

# ===== M-fixedcount: straight-line const-2-write (no recursion) -> runtime grade RED (count != fed) =====
python3 "$REF" mutant fixedcount "$work/fixed.bin"
boot "$work/fixed.bin" "$FX"
if grade_green "$FXH"; then fail_test "M-fixedcount graded GREEN -- variable-LENGTH not load-bearing"; else pass=$((pass + 1)); fi

# ===== M-content: right count, writes le32(0) -> runtime grade RED (content pin) =====
python3 "$REF" mutant content "$work/content.bin"
boot "$work/content.bin" "$FX"
if grade_green "$FXH"; then fail_test "M-content graded GREEN -- content pin not load-bearing"; else pass=$((pass + 1)); fi

# ===== M-forge (HEADLINE): non-recursive jmp-loop. Runtime-GREEN (forgeable!) but byte-pin + backcall catch it =====
python3 "$REF" mutant forge "$work/forge.bin"
boot "$work/forge.bin" "$FX"
if grade_green "$FXH"; then
    pass=$((pass + 1))   # EXPECTED: the runtime grade IS forgeable (recursion invisible in a trace)
    echo "  note: M-forge grades GREEN at runtime (as designed -- a syscall trace cannot witness recursion)"
else
    fail_test "M-forge did NOT grade GREEN at runtime -- the forge demonstration is broken (it should pass the runtime grade)"
fi
# the EMITTER-LAYER gate catches it: byte-pin (forge != target) AND backward-call (forge has 0 E8)
if ! cmp -s "$work/forge.bin" "$REFM"; then pass=$((pass + 1)); else fail_test "M-forge: BYTE-PIN failed to distinguish the forge from the genuine module"; fi
if python3 - "$work/forge.bin" <<'PY'
import sys, struct
d=open(sys.argv[1],'rb').read()
bw=[i for i in range(len(d)-4) if d[i]==0xE8 and struct.unpack('<i',d[i+1:i+5])[0]<0]
sys.exit(1 if bw else 0)   # exit 0 (PASS) iff there is NO backward E8 (the forge is not genuinely recursive)
PY
then pass=$((pass + 1)); else fail_test "M-forge: assert_backward_call found a backward E8 in the non-recursive forge"; fi

echo "mmj mutation proof: pass=$pass fail=$fail"
if [[ -e "$HVMARK" ]]; then echo "FAIL: link41 HARNESS FAILURE -- a feeder never reached LISTENING (dead socket/QEMU); fail-closed, NOT a genuine pass"; rm -f "$HVMARK"; exit 1; fi
if [[ "$fail" -eq 0 ]]; then echo "PASS"; exit 0; else exit 1; fi
