#!/usr/bin/env bash
# Native-codegen Link 48 / homestead MUTATION proof: every design choice in the DEMAND-PAGING machinery is
# load-bearing -- a held-back mutant kernel makes the silicon grade RED (vs the GREEN control), AND fails the
# white-box (assert_homestead False). Mutations (the heart of THIS link -- genuine demand paging):
#   M-nogrow   remove the #PF demand-commit branch entirely (terminal kill on every fault) -> the grower's stack
#              push past page 1 #PFs and the program is KILLED -> 0/partial output, 0 commit witnesses           -> RED
#   M-noclear  skip the boot P-clear of the grow window -> the window stays PRESENT (+Supervisor) -> a CPL3 push
#              hits a present-Supervisor page -> PROTECTION #PF (err.P=1) -> the demand branch (err.P==0 only) does
#              NOT fire -> terminal kill -> 0/partial output                                                      -> RED
#   M-eager    map the WHOLE grow window PRESENT+RW+User up front (eager, mumbani-style) -> the grower completes
#              and emits the FULL correct output, but takes ZERO not-present #PFs -> ZERO demand commits           -> RED
#              (THE KEY MUTATION: same OUTPUT as the genuine kernel, missing the temporal demand-commit witness --
#              this is the "fixed-large / eager reserve" forge, and it is caught only by the demand-commit gate.)
# The mutant kernel is built DIRECTLY from homestead_ref.py kernelelf OUT <mut> (the mutation is applied in the
# PYTHON ref's build). The byte-pin to build_elf() is in the main gate; this proves the construct is NON-VACUOUS.
set -u
script_dir="$(cd "$(dirname "$0")" && pwd)"
REF="$script_dir/homestead_ref.py"
N="${HOMESTEAD_MUT_N:-400}"
SEED="${HOMESTEAD_MUT_SEED:-90}"
if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    if [[ "${KERNEL_CODEGEN_REQUIRE_EMU:-0}" == "1" ]]; then echo "FAIL: stack/native_compile_fragment.herb (mutation proof requires QEMU)"; exit 1; fi
    echo "  SKIP: qemu-system-x86_64 not found -- mutation proof needs the silicon gate"; exit 0
fi
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
HVMARK="/tmp/.hv_harness_fail.$$"; rm -f "$HVMARK"   # fail-closed marker: a dead feeder/QEMU run trips this -> hard fail at end
pass=0; fail=0
ok() { echo "  PASS: $1"; pass=$((pass + 1)); }
fail_test() { echo "FAIL: stack/native_compile_fragment.herb ($1)"; fail=$((fail + 1)); }
free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }

KEND="$(python3 "$REF" kend 2>/dev/null || python3 "$REF" kernelelf "$work/probe.elf" none full)"
GROWER="$work/grower.bin"; python3 "$REF" modgrower "$GROWER" "$N"
boot() { # kelf out
    local P; P="$(free_port)"
    python3 "$script_dir/kernel_input_feed.py" "$P" "$SEED" --hold 12 > "$work/feed.log" 2>&1 &
    local fp=$!; local i; for i in $(seq 1 50); do grep -q LISTENING "$work/feed.log" 2>/dev/null && break; sleep 0.1; done
    grep -q LISTENING "$work/feed.log" 2>/dev/null || { echo "FAIL: link48 harness failure -- feeder never reached LISTENING (socket/QEMU launch dead; NOT a mutation bite)" >&2; : > "$HVMARK"; kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null; return; }
    timeout 90 qemu-system-x86_64 -cpu qemu64 -kernel "$1" -initrd "$GROWER" -debugcon file:"$2" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none \
        -chardev socket,id=s0,host=127.0.0.1,port="$P",server=off -serial chardev:s0 -monitor none -m 64M >/dev/null 2>"$2.qerr"
        grep -qvE 'terminating on signal' "$2.qerr" 2>/dev/null && { echo "FAIL: link48 harness failure -- QEMU launch error: $(grep -vE 'terminating on signal' "$2.qerr" | head -1)" >&2; : > "$HVMARK"; }   # F2a: only a NON-timeout stderr line is a launch failure; a timeout-kill (hang bite) is left to the grader
    wait "$fp" 2>/dev/null
}
# control: the canonical kernel must be GREEN (else the grader is vacuous and the RED mutants prove nothing)
python3 "$REF" kernelelf "$work/k_none.elf" none full >/dev/null
boot "$work/k_none.elf" "$work/o_none"
if python3 "$REF" gradehome "$work/o_none" "$KEND" "$N" "$SEED" >/dev/null 2>&1; then ok "control (no mutation) GREEN -- the grower's stack demand-grows past its 1-page region and the full stream comes out"
else fail_test "control RED -- $(python3 "$REF" gradehome "$work/o_none" "$KEND" "$N" "$SEED" 2>&1 | tr '\n' ';')"; fi

for mut in nogrow noclear eager; do
    python3 "$REF" kernelelf "$work/k_$mut.elf" "$mut" full >/dev/null 2>"$work/e_$mut"
    if [[ ! -s "$work/k_$mut.elf" ]]; then fail_test "M-$mut: kernel failed to build ($(head -1 "$work/e_$mut"))"; continue; fi
    # (a) structural: the white-box catches the mutation too
    if python3 "$REF" homestead "$work/k_$mut.elf"; then fail_test "M-$mut: assert_homestead returned True on the mutant -- the white-box does NOT catch it structurally"
    else ok "M-$mut: assert_homestead False -- the white-box catches the mutation structurally"; fi
    # (b) silicon: boot + grade must be RED
    boot "$work/k_$mut.elf" "$work/o_$mut"
    if python3 "$REF" gradehome "$work/o_$mut" "$KEND" "$N" "$SEED" >/dev/null 2>&1; then fail_test "M-$mut graded GREEN -- the mutation is VACUOUS (the demand-paging choice is not load-bearing)"
    else ok "M-$mut RED -- the mutation is caught on silicon (the demand-paging choice is load-bearing)"; fi
done

echo "native-codegen link48 mutation (homestead): pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]] || exit 1
if [[ -e "$HVMARK" ]]; then echo "FAIL: link48 HARNESS FAILURE -- a feeder never reached LISTENING (dead socket/QEMU); fail-closed, NOT a genuine pass"; rm -f "$HVMARK"; exit 1; fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link48 homestead MUTATION proof -- nogrow/noclear/eager each RED on silicon + assert_homestead False; M-eager = full output, zero demand commits)"
