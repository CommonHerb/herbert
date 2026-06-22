#!/usr/bin/env bash
# Native-codegen Link 46 / rollcall MUTATION proof: every design choice in the runtime-K process table + run-queue is
# load-bearing -- a held-back mutant kernel makes the silicon grade RED (vs the GREEN control). Mutations:
#   ROLLCALL-SPECIFIC (the heart of THIS link -- the scheduler-as-data-structure):
#     M-cap2      clamp K<=2 (tickover-style) -> proc>=2 never created -> worker starves                  -> RED
#     M-norobin   pick = cur^1 (toggle 0/1) instead of round-robin -> proc>=2 never scheduled -> starves   -> RED
#     M-nowake    never wake the spinner on the last worker exit -> spinner spins forever -> hang           -> RED
#   INHERITED (tickover preemption / nokta isolation, now exercised across K-way switches):
#     M-coop      IF=0 module frames -> the non-yielding spinner is never preempted -> workers starve       -> RED
#     M-noswitch  timer EOIs without switching -> spinner runs forever -> workers never reached             -> RED
#     M-noflip    no per-proc U/S flip on switch -> the resumed proc faults / isolation defeated            -> RED
#     M-noflip0   proc0 pages left Supervisor at boot -> CPL3 spinner #PFs immediately                      -> RED
#     M-minimal   TCB = {ebp,eip,esp} (tandem cooperative) -> the spinner's edx/markers lost across preempt -> RED
#     M-noeflags  drop eflags from the TCB -> the spinner's DF lost -> sentinel                             -> RED
# (The byte-pin to build_elf() is in the main gate; this proves the construct is NON-VACUOUS.)
set -u
script_dir="$(cd "$(dirname "$0")" && pwd)"
REF="$script_dir/rollcall_ref.py"
K="${ROLLCALL_MUT_K:-3}"
if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    if [[ "${KERNEL_CODEGEN_REQUIRE_EMU:-0}" == "1" ]]; then echo "FAIL: stack/native_compile_fragment.herb (mutation proof requires QEMU)"; exit 1; fi
    echo "  SKIP: qemu-system-x86_64 not found -- mutation proof needs the silicon gate"; exit 0
fi
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
pass=0; fail=0
ok() { echo "  PASS: $1"; pass=$((pass + 1)); }
fail_test() { echo "FAIL: stack/native_compile_fragment.herb ($1)"; fail=$((fail + 1)); }

KEND="$(python3 "$REF" kend)"
SP="$work/sp.bin"; python3 "$REF" modspinner "$SP"
LIST="$SP"; for i in $(seq 1 $((K-1))); do w="$work/w$i.bin"; python3 "$REF" modworker "$w" "$K" "$i"; LIST="$LIST,$w"; done
boot() { # kelf out
    timeout 60 qemu-system-x86_64 -cpu qemu64 -kernel "$1" -initrd "$LIST" -debugcon file:"$2" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none -monitor none -m 64M >/dev/null 2>&1
}
# control: the canonical kernel must be GREEN
python3 "$REF" kernelelf "$work/k_none.elf" none full >/dev/null
boot "$work/k_none.elf" "$work/o_none"
if python3 "$REF" grade "$work/o_none" "$KEND" "$K" >/dev/null 2>&1; then ok "control (no mutation) GREEN -- the K=$K run-queue works"
else fail_test "control RED -- $(python3 "$REF" grade "$work/o_none" "$KEND" "$K" 2>&1 | tr '\n' ';')"; fi

for mut in cap2 norobin nowake nolive coop noswitch noflip noflip0 minimal noeflags; do
    python3 "$REF" kernelelf "$work/k_$mut.elf" "$mut" full >/dev/null 2>"$work/e_$mut"
    if [[ ! -s "$work/k_$mut.elf" ]]; then fail_test "M-$mut: kernel failed to build ($(head -1 "$work/e_$mut"))"; continue; fi
    boot "$work/k_$mut.elf" "$work/o_$mut"
    if python3 "$REF" grade "$work/o_$mut" "$KEND" "$K" >/dev/null 2>&1; then fail_test "M-$mut graded GREEN -- the mutation is VACUOUS (the design choice is not load-bearing)"
    else ok "M-$mut RED -- the mutation is caught (the design choice is load-bearing)"; fi
done

echo "native-codegen link46 mutation (rollcall): pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "PASS: stack/native_compile_fragment.herb (native-codegen link46 rollcall MUTATION proof)"
