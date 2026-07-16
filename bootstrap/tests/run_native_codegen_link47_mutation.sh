#!/usr/bin/env bash
# Native-codegen Link 47 / tenement MUTATION proof: every design choice in the MEMORY-RECLAMATION machinery is
# load-bearing -- a held-back mutant kernel makes the silicon grade RED (vs the GREEN control), AND fails the
# strengthened white-box (assert_tenement False). Mutations (the heart of THIS link -- physical page REUSE):
#   M-noreclaim  skip the cur->waiter region HANDOFF on SYS_EXIT -> the WAITING procs never get a page -> the
#                scheduler skips them, live never reaches 0 -> hang; their held-back tokens never appear      -> RED
#   M-noremap    hand the waiter alloc_lo but SKIP the alloc_hi store -> the waiter is schedulable (lo!=0) but
#                fresh-starts with useresp=alloc_hi==0 -> its first push #PFs at addr ~0 -> token missing       -> RED
#   M-noskip     INVERT the scheduler's WAITING-skip (jz->jnz, byte-length identical) -> the pick lands on a
#                still-WAITING (regionless) proc -> fresh-start useresp=0 -> #PF -> that proc never emits        -> RED
# The mutant kernel is built DIRECTLY from tenement_ref.py kernelelf OUT <mut> (the mutation is applied in the
# PYTHON ref's build), exactly as link46_mutation builds its rollcall mutants. (The byte-pin to build_elf() is in
# the main gate; this proves the construct is NON-VACUOUS -- structurally AND on silicon.)
set -u
script_dir="$(cd "$(dirname "$0")" && pwd)"
REF="$script_dir/tenement_ref.py"
N="${TENEMENT_MUT_N:-6}"   # canonical N=6 workers
M="${TENEMENT_MUT_M:-2}"   # MSLOTS=2
if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    if [[ "${KERNEL_CODEGEN_REQUIRE_EMU:-0}" == "1" ]]; then echo "FAIL: stack/native_compile_fragment.herb (mutation proof requires QEMU)"; exit 1; fi
    echo "  SKIP: qemu-system-x86_64 not found -- mutation proof needs the silicon gate"; exit 0
fi
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
HVMARK="/tmp/.hv_harness_fail.$$"; rm -f "$HVMARK"   # fail-closed marker: a dead/timed-out QEMU run trips this -> hard fail at end
pass=0; fail=0
ok() { echo "  PASS: $1"; pass=$((pass + 1)); }
fail_test() { echo "FAIL: stack/native_compile_fragment.herb ($1)"; fail=$((fail + 1)); }

KEND="$(python3 "$REF" kend)"
LIST=""; for i in $(seq 0 $((N-1))); do w="$work/tw$i.bin"; python3 "$REF" modworker_ten "$w" "$N" "$i"; [[ -z "$LIST" ]] && LIST="$w" || LIST="$LIST,$w"; done
boot() { # kelf out
    timeout 60 qemu-system-x86_64 -cpu qemu64 -kernel "$1" -initrd "$LIST" -debugcon file:"$2" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none -monitor none -m 64M >/dev/null 2>"$2.qerr"
    # fail-closed: a QEMU LAUNCH failure writes to stderr, while a clean run -- even a hang-is-the-bite mutant --
    # leaves stderr EMPTY. Non-empty stderr is an unambiguous HARNESS failure, NOT a bite. (rc is NOT usable:
    # isa-debug-exit yields odd codes >124 on legit completions, and hang bites legitimately time out at 124.)
    grep -qvE 'terminating on signal' "$2.qerr" 2>/dev/null && { echo "FAIL: link47 harness failure -- QEMU launch error: $(grep -vE 'terminating on signal' "$2.qerr" | head -1)" >&2; : > "$HVMARK"; }   # only a NON-timeout stderr line is a launch failure; a timeout-kill (hang bite) is left to the grader
}
# control: the canonical kernel must be GREEN (else the grader is vacuous and the RED mutants prove nothing)
python3 "$REF" kernelelf "$work/k_none.elf" none full >/dev/null
boot "$work/k_none.elf" "$work/o_none"
if python3 "$REF" gradeten "$work/o_none" "$KEND" "$N" "$M" >/dev/null 2>&1; then ok "control (no mutation) GREEN -- the N=$N programs reuse $M physical pages"
else fail_test "control RED -- $(python3 "$REF" gradeten "$work/o_none" "$KEND" "$N" "$M" 2>&1 | tr '\n' ';')"; fi

for mut in noreclaim noremap noskip; do
    python3 "$REF" kernelelf "$work/k_$mut.elf" "$mut" full >/dev/null 2>"$work/e_$mut"
    if [[ ! -s "$work/k_$mut.elf" ]]; then fail_test "M-$mut: kernel failed to build ($(head -1 "$work/e_$mut"))"; continue; fi
    # (a) structural: the strengthened white-box catches the mutation too
    if python3 "$REF" tenement "$work/k_$mut.elf"; then fail_test "M-$mut: assert_tenement returned True on the mutant -- the white-box does NOT catch it structurally"
    else ok "M-$mut: assert_tenement False -- the white-box catches the mutation structurally"; fi
    # (b) silicon: boot + grade must be RED
    boot "$work/k_$mut.elf" "$work/o_$mut"
    if python3 "$REF" gradeten "$work/o_$mut" "$KEND" "$N" "$M" >/dev/null 2>&1; then fail_test "M-$mut graded GREEN -- the mutation is VACUOUS (the reclamation choice is not load-bearing)"
    else ok "M-$mut RED -- the mutation is caught on silicon (the reclamation choice is load-bearing)"; fi
done

echo "native-codegen link47 mutation (tenement): pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]] || exit 1
if [[ -e "$HVMARK" ]]; then echo "FAIL: link47 HARNESS FAILURE -- a QEMU run was dead/timed-out (empty output); fail-closed, NOT a genuine pass"; rm -f "$HVMARK"; exit 1; fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link47 tenement MUTATION proof -- noreclaim/noremap/noskip each RED on silicon + assert_tenement False)"
