#!/usr/bin/env bash
# Native-codegen Link 42 (chiefturbo / RUNTIME-INDEXED MEMORY) MUTATION proof: the held-back proof the gate bites.
# Control must grade GREEN first (else the grader is vacuous); then each mutation must be CAUGHT:
#   M-byteshift : a 1-byte change to the emitted module -> the BYTE-PIN bites (hex != target_module).
#   M-wrongidx  : a genuine indexed module but gather reads buf[k+1] -> runtime grade RED (the random-access
#                 CONTENT pin -- it emits data[idx+1], not data[idx]).
#   M-constidx  : a genuine indexed module but gather uses a CONSTANT index (ignores the runtime index) -> RED
#                 (read-count pin: it skips the index reads; AND content pin: emits data[0] for every query).
#   M-forge (HEADLINE): a NON-INDEXED module that BAKES the gx output (reads all 1+3N+N inputs to pass the
#                 read-count pin, then emits the expected words as IMMEDIATES). It grades GREEN AT RUNTIME on gx
#                 -- the runtime trace ALONE is forgeable for KNOWN data -- but is caught at the EMITTER layer:
#                 byte-pin (forge != target_module) AND assert_indexed_load (ZERO SS-relative SIB ops). The
#                 genuine make-or-break uses RANDOM HELD-BACK data the gate seed picks, which a baked forge
#                 cannot precompute; this forge only works because it is hand-built against the fixed gx seed.
# Run under KERNEL_CODEGEN_MUTATION=1 (CI), like every prior link.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
HERBERT="${HERBERT:-$repo_root/build/herbert}"
backend="$repo_root/stack/native_compile_fragment.herb"
REF="$script_dir/chiefturbo_ref.py"
feeder="$script_dir/kernel_input_feed.py"
REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"

if [[ ! -x "$HERBERT" ]]; then echo "FAIL: stack/native_compile_fragment.herb (cannot find herbert at $HERBERT)"; exit 1; fi
if [[ ! -f "$backend" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing backend)"; exit 1; fi
if [[ ! -f "$REF" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing chiefturbo_ref.py $REF)"; exit 1; fi
if [[ ! -f "$feeder" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing input feeder $feeder)"; exit 1; fi

source "$script_dir/native_codegen_oracle.sh"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
native_codegen_ensure_compiler "$work/gen1" || exit 1
pass=0; fail=0
fail_test() { echo "FAIL: stack/native_compile_fragment.herb ($1)"; fail=$((fail + 1)); }
have_qemu() { command -v qemu-system-x86_64 >/dev/null 2>&1; }
free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }

REFK="$work/k.elf"; KEND="$(python3 "$REF" kernelelf "$REFK")"
REFM="$work/target.bin"; python3 "$REF" module "$REFM"

if ! have_qemu; then
    if [[ "$REQUIRE_EMU" == "1" ]]; then echo "FAIL: stack/native_compile_fragment.herb (qemu required under KERNEL_CODEGEN_REQUIRE_EMU=1)"; exit 1; fi
    echo "SKIP: qemu not found (mutation proof needs an emulator; set KERNEL_CODEGEN_REQUIRE_EMU=1 to force)."
    exit 0
fi

boot() { # modfile kind -> sets OUT (debugcon stream)
    local mod="$1" kind="$2" W; W="$(mktemp -d "$work/run.XXXX")"; OUT="$W/e9"
    local stream; stream=$(python3 "$REF" stream "$kind")
    local port; port=$(free_port)
    python3 "$feeder" "$port" $stream --hold 8 > "$W/feed.log" 2>&1 & local fp=$!
    local i; for i in $(seq 1 40); do grep -q LISTENING "$W/feed.log" && break; sleep 0.1; done
    timeout 90 qemu-system-x86_64 -kernel "$REFK" -initrd "$mod" -debugcon file:"$OUT" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none -cpu qemu64 \
        -chardev socket,id=s0,host=127.0.0.1,port="$port",server=off -serial chardev:s0 -monitor none -m 64M >/dev/null 2>&1
    wait "$fp" 2>/dev/null
}
grade_green() { python3 "$REF" grade "$OUT" "$KEND" "$1" >/dev/null 2>&1; }   # 0 == GREEN

# ===== CONTROL: the gen-1-EMITTED chiefturbo module must grade GREEN on gx & gy (else the grader is vacuous) =====
CDIR="$work/ctl.d"; mkdir -p "$CDIR"
printf -- '-- emit: module-chiefturbo\n%s\n' "$(python3 "$REF" src)" > "$CDIR/m.herb"
( cd "$CDIR" && "$NATIVE_CODEGEN_COMPILER" < m.herb >/dev/null 2>"$CDIR/err" )
[[ -f "$CDIR/a.out" ]] || { echo "FAIL: stack/native_compile_fragment.herb (control chiefturbo did not compile: $(grep -o 'ERR [0-9]*' "$CDIR/err" | head -1))"; exit 1; }
CTL="$work/ctl.bin"; cp "$CDIR/a.out" "$CTL"
cmp -s "$CTL" "$REFM" || { echo "FAIL: stack/native_compile_fragment.herb (control: emitter != target_module)"; exit 1; }
for k in gx gy; do
    boot "$CTL" "$k"
    if grade_green "$k"; then pass=$((pass + 1)); else fail_test "CONTROL chiefturbo $k not GREEN -- grader vacuous"; fi
done

# ===== M-byteshift: a 1-byte change to the module must break the BYTE-PIN =====
python3 - "$CTL" "$work/shift.bin" <<'PY'
import sys
b=bytearray(open(sys.argv[1],'rb').read()); b[10]^=0x01
open(sys.argv[2],'wb').write(b)
PY
if ! cmp -s "$work/shift.bin" "$REFM"; then pass=$((pass + 1)); else fail_test "M-byteshift: byte-pin would not detect a 1-byte module change"; fi

# ===== M-wrongidx: gather reads buf[k+1] -> runtime grade RED (random-access content pin) =====
python3 "$REF" mutant wrongidx "$work/wrongidx.bin"
boot "$work/wrongidx.bin" gx
if grade_green gx; then fail_test "M-wrongidx graded GREEN -- the random-access content pin is not load-bearing"; else pass=$((pass + 1)); fi

# ===== M-constidx: gather uses a constant index -> RED (read-count + content pins) =====
python3 "$REF" mutant constidx "$work/constidx.bin"
boot "$work/constidx.bin" gx
if grade_green gx; then fail_test "M-constidx graded GREEN -- the index is not load-bearing (read-count/content)"; else pass=$((pass + 1)); fi

# ===== M-forge (HEADLINE): non-indexed baked module. Runtime-GREEN (forgeable!) but byte-pin + assert_indexed catch it =====
python3 "$REF" forge gx "$work/forge.bin"
boot "$work/forge.bin" gx
if grade_green gx; then
    pass=$((pass + 1))   # EXPECTED: the runtime grade IS forgeable for KNOWN data (the forge bakes the gx output)
    echo "  note: M-forge grades GREEN at runtime (as designed -- a runtime trace cannot witness indexed memory for KNOWN data)"
else
    fail_test "M-forge did NOT grade GREEN at runtime -- the forge demonstration is broken (it should pass the runtime grade)"
fi
# the EMITTER-LAYER gate catches it: byte-pin (forge != target) AND assert_indexed_load (forge has ZERO SS-SIB ops)
if ! cmp -s "$work/forge.bin" "$REFM"; then pass=$((pass + 1)); else fail_test "M-forge: BYTE-PIN failed to distinguish the forge from the genuine module"; fi
if python3 "$REF" indexed "$work/forge.bin"; then fail_test "M-forge: assert_indexed_load found an indexed op in the non-indexed forge"; else pass=$((pass + 1)); fi

echo "chiefturbo mutation proof: pass=$pass fail=$fail"
if [[ "$fail" -eq 0 ]]; then echo "PASS"; exit 0; else exit 1; fi
