#!/usr/bin/env bash
# Native codegen Link 38 (coalgate) MUTATION proof: the held-back proof that the gate's make-or-break checks
# BITE. Control must grade GREEN first (else the grader is vacuous); then each mutation must go RED:
#   M-byteshift  : the emitted module differs from the STEP-0 target by one byte -> the white-box BYTE-PIN bites.
#   M-constbake  : a module that READS the byte then IGNORES it (bakes 0x5A) -> answer != host_T AND the
#                  two-byte X!=Y differential collapses (answer(X)==answer(Y)) -> the differential bites.
#   M-wrongadd   : a module that does +8 where the add7 transform expects +7 -> answer != host_T bites.
#   M-noxform    : echo where add7 is expected -> answer == fed != fed+7 -> answer-correctness bites.
# These are negative controls fed as raw module blobs (coalgate_ref mutant); the FROZEN geeking kernel runs
# them and the coalgate grader must reject. Run under KERNEL_CODEGEN_MUTATION=1 (CI) like every prior link.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
HERBERT="${HERBERT:-$repo_root/build/herbert}"
backend="$repo_root/stack/native_compile_fragment.herb"
REF="$script_dir/coalgate_ref.py"
GREF="$script_dir/geeking_ref.py"
feeder="$script_dir/kernel_input_feed.py"
REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"

# (per-file existence checks on separate lines so the herbert binary and the backend path never appear
# textually adjacent -- run_tests.sh's native-codegen completeness grep flags any adjacent compile site)
if [[ "${NATIVE_CODEGEN_ORACLE:-golden}" == "c" && ! -x "$HERBERT" ]]; then echo "FAIL: stack/native_compile_fragment.herb (cannot find herbert at $HERBERT)"; exit 1; fi
if [[ ! -f "$backend" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing backend)"; exit 1; fi
if [[ ! -f "$REF" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing coalgate_ref.py $REF)"; exit 1; fi
if [[ ! -f "$GREF" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing geeking_ref.py $GREF)"; exit 1; fi
if [[ ! -f "$feeder" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing input feeder $feeder)"; exit 1; fi

source "$script_dir/native_codegen_oracle.sh"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
native_codegen_ensure_compiler "$work/gen1" || exit 1
pass=0; fail=0
fail_test() { echo "FAIL: stack/native_compile_fragment.herb ($1)"; fail=$((fail + 1)); }
have_qemu() { command -v qemu-system-x86_64 >/dev/null 2>&1; }
le32_val() { local h="${1:$2:8}"; echo $(( 16#${h:6:2}${h:4:2}${h:2:2}${h:0:2} )); }
free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }
elf_meta() { local elf="$1" eh; eh=$(dd if="$elf" bs=1 count=84 status=none 2>/dev/null | xxd -p | tr -d '\n'); echo $(( 1048576 + $(le32_val "$eh" 144) )); }
FX=60; FY=197

# ---- the frozen geeking host kernel (re-emitted from source) ----
KCDIR="$work/kernel.d"; mkdir -p "$KCDIR"
printf -- '-- emit: multiboot32-geeking\nfunc main(): return module_byte() end\n' > "$KCDIR/k.herb"
( cd "$KCDIR" && "$NATIVE_CODEGEN_COMPILER" < k.herb >/dev/null 2>"$KCDIR/err" )
[[ -f "$KCDIR/a.out" ]] || { echo "FAIL: stack/native_compile_fragment.herb (kernel emit failed)"; exit 1; }
KELF="$work/geeking.elf"; cp "$KCDIR/a.out" "$KELF"
KEND="$(printf '%x' "$(elf_meta "$KELF")")"

# ---- boot the frozen kernel + a module blob, feed a byte, return the e9 stream in $OUT (+ the DE<x>AD answer) ----
boot_answer() { # modfile byte -> sets OUT (e9 file) and ANSWER (hex of the emitted DE<x>AD byte, or empty)
    local mod="$1" byte="$2" W; W="$(mktemp -d "$work/run.XXXX")"
    OUT="$W/e9"; ANSWER=""
    local port; port=$(free_port)
    python3 "$feeder" "$port" "$byte" --hold 6 > "$W/feed.log" 2>&1 & local fp=$!
    local i; for i in $(seq 1 40); do grep -q LISTENING "$W/feed.log" && break; sleep 0.1; done
    timeout 60 qemu-system-x86_64 -kernel "$KELF" -initrd "$mod" -debugcon file:"$OUT" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none -cpu qemu64 \
        -chardev socket,id=s0,host=127.0.0.1,port="$port",server=off -serial chardev:s0 -monitor none -m 64M >/dev/null 2>&1
    wait "$fp" 2>/dev/null
    ANSWER=$(xxd -p "$OUT" 2>/dev/null | tr -d '\n' | grep -oE 'de..ad' | head -1 | sed -E 's/^de(..)ad$/\1/')
}

mutate_red() { # label modfile gradekind byte  -- boot the mutant, grade as <gradekind>, MUST be RED
    local label="$1" mod="$2" kind="$3" byte="$4"
    boot_answer "$mod" "$byte"
    if python3 "$REF" grade "$OUT" "$KEND" "$(printf '%x' "$byte")" "$kind" >/dev/null 2>&1; then
        fail_test "M-$label: graded GREEN as '$kind' -- NOT load-bearing (answer=0x$ANSWER)"
    else
        pass=$((pass + 1))
    fi
}

if ! have_qemu; then
    if [[ "$REQUIRE_EMU" == "1" ]]; then echo "FAIL: stack/native_compile_fragment.herb (qemu required under KERNEL_CODEGEN_REQUIRE_EMU=1)"; exit 1; fi
    echo "SKIP: qemu not found (mutation proof needs an emulator; set KERNEL_CODEGEN_REQUIRE_EMU=1 to force)."
    exit 0
fi

# ===== CONTROL: a clean compiled add7 module must grade GREEN on both bytes (else the grader is vacuous) =====
CDIR="$work/ctl.d"; mkdir -p "$CDIR"
printf -- '-- emit: multiboot32-coalgate\n%s\n' "$(python3 "$REF" src add7)" > "$CDIR/m.herb"
( cd "$CDIR" && "$NATIVE_CODEGEN_COMPILER" < m.herb >/dev/null 2>"$CDIR/err" )
[[ -f "$CDIR/a.out" ]] || { echo "FAIL: stack/native_compile_fragment.herb (control add7 did not compile)"; exit 1; }
CTL="$work/ctl.bin"; cp "$CDIR/a.out" "$CTL"
# control must equal the STEP-0 target (else the byte-pin is itself the bug)
[[ "$(xxd -p "$CTL" | tr -d '\n')" == "$(python3 "$REF" hex add7)" ]] || { echo "FAIL: stack/native_compile_fragment.herb (control add7 != target)"; exit 1; }
for b in "$FX" "$FY"; do
    boot_answer "$CTL" "$b"
    if python3 "$REF" grade "$OUT" "$KEND" "$(printf '%x' "$b")" add7 >/dev/null 2>&1; then pass=$((pass + 1)); else fail_test "CONTROL add7 byte=$b: clean module not GREEN -- grader vacuous (answer=0x$ANSWER)"; fi
done

# ===== M-byteshift: a one-byte change to the target must break the white-box BYTE-PIN =====
SHIFT="$work/shift.bin"
python3 - "$CTL" "$SHIFT" <<'PY'
import sys
b=bytearray(open(sys.argv[1],'rb').read()); b[6]^=0x01   # flip a bit in the push-eax / int region
open(sys.argv[2],'wb').write(b)
PY
if [[ "$(xxd -p "$SHIFT" | tr -d '\n')" != "$(python3 "$REF" hex add7)" ]]; then pass=$((pass + 1)); else fail_test "M-byteshift: byte-pin would not detect a 1-byte module change"; fi

# ===== M-constbake / M-wrongadd / M-noxform: behavioral make-or-break checks must bite =====
python3 "$REF" mutant constbake "$work/constbake.bin"
python3 "$REF" mutant wrongadd  "$work/wrongadd.bin"
python3 "$REF" mutant noxform   "$work/noxform.bin"
mutate_red constbake "$work/constbake.bin" echo "$FX"   # reads then ignores byte -> answer 0x5A != fed
mutate_red wrongadd  "$work/wrongadd.bin"  add7 "$FX"   # +8 != +7
mutate_red noxform   "$work/noxform.bin"   add7 "$FX"   # echo != +7

# ===== the two-byte X!=Y differential bites a const-baker: answer(FX)==answer(FY) for constbake =====
boot_answer "$work/constbake.bin" "$FX"; ax="$ANSWER"
boot_answer "$work/constbake.bin" "$FY"; ay="$ANSWER"
if [[ -n "$ax" && "$ax" == "$ay" ]]; then pass=$((pass + 1)); else fail_test "M-differential: constbake answer(FX)=0x$ax answer(FY)=0x$ay -- expected equal (the differential signature of a dead module)"; fi

echo "coalgate mutation proof: pass=$pass fail=$fail"
if [[ "$fail" -eq 0 ]]; then echo "PASS"; exit 0; else exit 1; fi
