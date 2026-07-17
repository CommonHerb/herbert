#!/usr/bin/env bash
# Native codegen Link 39 (ouroboros) MUTATION proof: the held-back proof that the gate's make-or-break checks
# BITE. Control must grade GREEN first (else the grader is vacuous); then each mutation must go RED:
#   M-byteshift : the emitted module differs from the STEP-0 target by one byte -> the white-box BYTE-PIN bites.
#   M-noxform   : main echoes the byte, never calls the recursive helper -> answer == fed != tri(fed) (the
#                 recursion is load-bearing: skipping it is caught by answer-correctness).
#   M-baseflip  : the recursion base case returns 1 instead of 0 -> answer == tri(n)+1, wrong -> bites.
#   M-wrongrel  : the BACKWARD recursive call rel32 is corrupted (target shifted) -> wrong target -> wrong
#                 answer or a CPL3 fault the watchdog/fault->continue names -> bites (the signed backward
#                 call is load-bearing).
#   M-constbake : a module that READS the byte then bakes 0x5A -> answer != host_T AND the X!=Y differential
#                 collapses (answer(fx)==answer(fy)) -> the differential bites.
# Negative controls fed as raw module blobs (ouroboros_ref mutant); the FROZEN geeking kernel runs them and
# the ouroboros grader must reject. Run under KERNEL_CODEGEN_MUTATION=1 (CI) like every prior link.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
HERBERT="${HERBERT:-$repo_root/build/herbert}"
backend="$repo_root/stack/native_compile_fragment.herb"
REF="$script_dir/ouroboros_ref.py"
GREF="$script_dir/geeking_ref.py"
feeder="$script_dir/kernel_input_feed.py"
REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"

if [[ "${NATIVE_CODEGEN_ORACLE:-golden}" == "c" && ! -x "$HERBERT" ]]; then echo "FAIL: stack/native_compile_fragment.herb (cannot find herbert at $HERBERT)"; exit 1; fi
if [[ ! -f "$backend" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing backend)"; exit 1; fi
if [[ ! -f "$REF" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing ouroboros_ref.py $REF)"; exit 1; fi
if [[ ! -f "$GREF" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing geeking_ref.py $GREF)"; exit 1; fi
if [[ ! -f "$feeder" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing input feeder $feeder)"; exit 1; fi

source "$script_dir/native_codegen_oracle.sh"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
HVMARK="/tmp/.hv_harness_fail.$$"; rm -f "$HVMARK"   # fail-closed marker: a dead feeder/QEMU run trips this -> hard fail at end
native_codegen_ensure_compiler "$work/gen1" || exit 1
pass=0; fail=0
fail_test() { echo "FAIL: stack/native_compile_fragment.herb ($1)"; fail=$((fail + 1)); }
have_qemu() { command -v qemu-system-x86_64 >/dev/null 2>&1; }
le32_val() { local h="${1:$2:8}"; echo $(( 16#${h:6:2}${h:4:2}${h:2:2}${h:0:2} )); }
free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }
elf_meta() { local elf="$1" eh; eh=$(dd if="$elf" bs=1 count=84 status=none 2>/dev/null | xxd -p | tr -d '\n'); echo $(( 1048576 + $(le32_val "$eh" 144) )); }
# tri probe bytes (safe recursion depth, well under the one-page bound): fx=20, fy=42
FX=20; FY=42

# ---- the frozen geeking host kernel (re-emitted from source) ----
KCDIR="$work/kernel.d"; mkdir -p "$KCDIR"
printf -- '-- emit: multiboot32-geeking\nfunc main(): return module_byte() end\n' > "$KCDIR/k.herb"
( cd "$KCDIR" && "$NATIVE_CODEGEN_COMPILER" < k.herb >/dev/null 2>"$KCDIR/err" )
[[ -f "$KCDIR/a.out" ]] || { echo "FAIL: stack/native_compile_fragment.herb (kernel emit failed)"; exit 1; }
KELF="$work/geeking.elf"; cp "$KCDIR/a.out" "$KELF"
# byte-pin the battery's host kernel (2026-07-17, discriminator-sweep tranche 1a / Codex change 1:
# GREF was previously only existence-checked and KELF trusted unpinned -- a silent geeking-emit drift
# would have run the whole mutation battery on an unverified kernel). Mirrors the main gate's L73-74.
python3 "$GREF" cleanelf "$work/geeking_ref.elf"
cmp -s "$KELF" "$work/geeking_ref.elf" || { echo "FAIL: stack/native_compile_fragment.herb (mutation harness: compiled geeking != geeking_ref.build_elf -- refusing to run mutants on an unpinned host kernel)"; exit 1; }
KELF_SHA="$(sha256sum "$KELF" | cut -d' ' -f1)"
KEND="$(printf '%x' "$(elf_meta "$KELF")")"

boot_answer() { # modfile byte -> sets OUT (e9 file) and ANSWER (hex of the emitted DE<x>AD byte, or empty)
    local mod="$1" byte="$2" W; W="$(mktemp -d "$work/run.XXXX")"
    OUT="$W/e9"; ANSWER=""
    local port; port=$(free_port)
    python3 "$feeder" "$port" "$byte" --hold 6 > "$W/feed.log" 2>&1 & local fp=$!
    local i; for i in $(seq 1 40); do grep -q LISTENING "$W/feed.log" && break; sleep 0.1; done
    grep -q LISTENING "$W/feed.log" 2>/dev/null || { echo "FAIL: link39 harness failure -- feeder never reached LISTENING (socket/QEMU launch dead; NOT a mutation bite)" >&2; : > "$HVMARK"; kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null; return; }
    timeout 60 qemu-system-x86_64 -kernel "$KELF" -initrd "$mod" -debugcon file:"$OUT" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none -cpu qemu64 \
        -chardev socket,id=s0,host=127.0.0.1,port="$port",server=off -serial chardev:s0 -monitor none -m 64M >/dev/null 2>"$OUT.qerr"
    local rc=$?
    grep -qvE 'terminating on signal' "$OUT.qerr" 2>/dev/null && { echo "FAIL: link39 harness failure -- QEMU launch error: $(grep -vE 'terminating on signal' "$OUT.qerr" | head -1)" >&2; : > "$HVMARK"; }   # F2a: only a NON-timeout stderr line is a launch failure; a timeout-kill (hang bite) is left to the grader
    wait "$fp" 2>/dev/null
    ANSWER=$(xxd -p "$OUT" 2>/dev/null | tr -d '\n' | grep -oE 'de..ad' | head -1 | sed -E 's/^de(..)ad$/\1/')
    # completion witness (2026-07-17, tranche 1a): mutants here are MODULES run on the byte-pinned
    # GENUINE geeking kernel, whose watchdog/fault-continue guarantees every boot reaches the emit tail
    # (kill 'K' / fault 'G'|'P'|'F' / exit -- empirically re-pinned on qemu 10.2.1). A stream with NO
    # byte-ALIGNED terminal DE..AD frame is therefore a QEMU/capture failure, NEVER a mutant behavior
    # -- fail closed so a dead boot cannot score as a vacuous "bite".
    if ! xxd -p "$OUT" 2>/dev/null | tr -d '\n' | grep -qE '^([0-9a-f]{2})*de[0-9a-f]{2}ad$'; then
        echo "FAIL: link39 harness failure -- no completion witness (no terminal DE..AD frame in the debugcon stream; the geeking host kernel guarantees module termination, so an absent frame is a QEMU/capture failure, NOT a mutant behavior) rc=$rc" >&2; : > "$HVMARK"
    fi
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

# ===== CONTROL: a clean compiled 'tri' module must grade GREEN on both bytes (else the grader is vacuous) =====
CDIR="$work/ctl.d"; mkdir -p "$CDIR"
printf -- '-- emit: multiboot32-ouroboros\n%s\n' "$(python3 "$REF" src tri)" > "$CDIR/m.herb"
( cd "$CDIR" && "$NATIVE_CODEGEN_COMPILER" < m.herb >/dev/null 2>"$CDIR/err" )
[[ -f "$CDIR/a.out" ]] || { echo "FAIL: stack/native_compile_fragment.herb (control tri did not compile)"; exit 1; }
CTL="$work/ctl.bin"; cp "$CDIR/a.out" "$CTL"
[[ "$(xxd -p "$CTL" | tr -d '\n')" == "$(python3 "$REF" hex tri)" ]] || { echo "FAIL: stack/native_compile_fragment.herb (control tri != target)"; exit 1; }
for b in "$FX" "$FY"; do
    boot_answer "$CTL" "$b"
    if python3 "$REF" grade "$OUT" "$KEND" "$(printf '%x' "$b")" tri >/dev/null 2>&1; then pass=$((pass + 1)); else fail_test "CONTROL tri byte=$b: clean module not GREEN -- grader vacuous (answer=0x$ANSWER)"; fi
done

# ===== M-byteshift: a one-byte change to the target must break the white-box BYTE-PIN =====
SHIFT="$work/shift.bin"
python3 - "$CTL" "$SHIFT" <<'PY'
import sys
b=bytearray(open(sys.argv[1],'rb').read()); b[6]^=0x01
open(sys.argv[2],'wb').write(b)
PY
if [[ "$(xxd -p "$SHIFT" | tr -d '\n')" != "$(python3 "$REF" hex tri)" ]]; then pass=$((pass + 1)); else fail_test "M-byteshift: byte-pin would not detect a 1-byte module change"; fi

# ===== behavioral make-or-break: recursion + base case + backward call + differential all bite =====
python3 "$REF" mutant noxform   "$work/noxform.bin"
python3 "$REF" mutant baseflip  "$work/baseflip.bin"
python3 "$REF" mutant wrongrel  "$work/wrongrel.bin"
python3 "$REF" mutant constbake "$work/constbake.bin"
mutate_red noxform   "$work/noxform.bin"   tri "$FX"   # echo: answer==fed != tri(fed) (recursion load-bearing)
mutate_red baseflip  "$work/baseflip.bin"  tri "$FX"   # base returns 1: answer == tri(n)+1, wrong
mutate_red wrongrel  "$work/wrongrel.bin"  tri "$FX"   # corrupted backward call rel32: wrong target/fault
mutate_red constbake "$work/constbake.bin" tri "$FX"   # bakes 0x5A: answer != tri(fed)

# ===== the X!=Y differential bites a const-baker: answer(FX)==answer(FY) for constbake =====
cb_sha="$(sha256sum "$work/constbake.bin" | cut -d' ' -f1)"   # freeze the mutant blob across the two boots (hash-identity, Codex change 1)
boot_answer "$work/constbake.bin" "$FX"; ax="$ANSWER"
boot_answer "$work/constbake.bin" "$FY"; ay="$ANSWER"
[[ "$(sha256sum "$work/constbake.bin" | cut -d' ' -f1)" == "$cb_sha" ]] || fail_test "M-differential: constbake module changed between the FX and FY boots -- hash-identity violated"
if [[ -n "$ax" && "$ax" == "$ay" ]]; then pass=$((pass + 1)); else fail_test "M-differential: constbake answer(FX)=0x$ax answer(FY)=0x$ay -- expected equal (dead-module signature)"; fi

# hash-identity: the pinned host kernel must be unchanged across the whole battery (Codex change 1).
[[ "$(sha256sum "$KELF" | cut -d' ' -f1)" == "$KELF_SHA" ]] || fail_test "host kernel hash changed during the battery -- hash-identity violated"
echo "ouroboros mutation proof: pass=$pass fail=$fail"
if [[ -e "$HVMARK" ]]; then echo "FAIL: link39 HARNESS FAILURE -- a harness failure was flagged (feeder never LISTENING, QEMU launch error, or a boot with no completion witness); fail-closed, NOT a genuine pass"; rm -f "$HVMARK"; exit 1; fi
if [[ "$fail" -eq 0 ]]; then echo "PASS"; exit 0; else exit 1; fi
