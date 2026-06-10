#!/usr/bin/env bash
# Held-back MUTATION proof for Link 34 (trikonderoga). The GATE (run_native_codegen_link34.sh) proves the
# COMPILER's emitted prefix+epilogue is BYTE-IDENTICAL to the silicon-proven reference (trikon_ref.py).
# This harness proves each load-bearing DESIGN CHOICE in that reference is non-vacuous: it builds the
# reference image with ONE design defect injected (trikon_ref mutate <mut>) and asserts the host grader
# goes RED. The CLEAN build is asserted GREEN first (control), so a vacuous grader is caught.
#
# RED taxonomy (each proves a distinct piece of the ring boundary is load-bearing):
#  RING ENTRY:
#    M-dpl0frame  (push ring-0 cs in the iret frame -> no privilege change) -> benign cs != ucode|3  (RED)
#    M-callcpl0   (lodger-style CPL0 call instead of iret) -> hostile out runs at CPL0 undetected   (RED)
#  THE SYSCALL EXIT GATE:
#    M-gatedpl0   (exit gate DPL0) -> a benign CPL3 int 0x30 itself #GPs -> no exit frame            (RED)
#  PRIVILEGED-OP ISOLATION:
#    M-iopl3frame (iret EFLAGS IOPL=3) -> hostile out is permitted at CPL3 -> no #GP frame            (RED)
#    M-iomap      (TSS I/O bitmap base inside the limit -> grants port 0xE9) -> hostile out permitted (RED)
#    M-tssesp0    (unmapped TSS esp0) -> the exit/#GP frame push triple-faults -> no clean frame       (RED)
#  THE RESUME PATH (Codex Q1 + completeness-critic B1 both flagged the ordering):
#    M-resumeorder(reload data segs BEFORE saving the status off al) -> al clobbered -> wrong f(status)(RED)
#    M-wrongcell  (store status to the wrong cell) -> the compiled body reads a stale 0 -> wrong f     (RED)
#  HONEST ALLOCATION (inherited from lodger, D20):
#    M-noexclude  (skip ALL exclusions) -> alloc == kernel start; host recompute mismatch              (RED)
#    M-noexclbuf  (exclude only kernel+module) -> alloc overlaps the loader buffers; recompute mismatch (RED)
#    M-hardcodeaddr(fixed alloc literal) -> recompute mismatch; overlaps the FAT module                (RED)
# (M-nodsreload is intentionally NOT in the battery: the head sets ds=udata3 before the iret, which also
#  protects the resumed body, so omitting the handler's ds reload is non-biting here -- a defensive
#  redundancy, confirmed GREEN on both substrates. Recorded honestly, not shipped as a vacuous mutation.)
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
REF="$script_dir/trikon_ref.py"
REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"
[[ -f "$REF" ]] || { echo "FAIL: stack/native_compile_fragment.herb (missing trikon_ref.py)"; exit 1; }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
pass=0; fail=0
fail_test() { echo "FAIL: stack/native_compile_fragment.herb ($1)"; fail=$((fail + 1)); }
have_qemu() { command -v qemu-system-x86_64 >/dev/null 2>&1; }

python3 "$REF" module X "$work/mod_x.bin"
python3 "$REF" module HOST "$work/mod_h.bin"
python3 "$REF" module FAT "$work/mod_fat.bin"

qemu_grade() { # elf mod kend golden kind -> 0 if grader GREEN, 1 if RED
    local elf="$1" mod="$2" kend="$3" gb="$4" kind="$5" out="$work/e9.bin"
    timeout 60 qemu-system-x86_64 -kernel "$elf" -initrd "$mod" -debugcon file:"$out" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none \
        -monitor none -cpu qemu64 -m 64M >/dev/null 2>&1 || true
    python3 "$REF" grade "$out" "$kend" "$gb" "$kind" >/dev/null 2>&1
}

if ! have_qemu; then
    if [[ "$REQUIRE_EMU" == "1" ]]; then echo "FAIL: stack/native_compile_fragment.herb (REQUIRE_EMU=1 but qemu missing)"; exit 1; fi
    echo "SKIP: native-codegen link34 mutation (no qemu; authoritative run is the kernel-codegen CI workflow)"; exit 0
fi

# CONTROL: the clean reference must grade GREEN on BOTH the benign and hostile paths (else vacuous).
python3 "$REF" cleanelf "$work/clean.elf"
KCLEAN=$(python3 "$REF" kend -)
if qemu_grade "$work/clean.elf" "$work/mod_x.bin" "$KCLEAN" 5A benign; then pass=$((pass + 1)); else
    fail_test "CONTROL benign: clean reference did NOT grade GREEN -- grader is vacuous"; fi
if qemu_grade "$work/clean.elf" "$work/mod_h.bin" "$KCLEAN" 00 hostile; then pass=$((pass + 1)); else
    fail_test "CONTROL hostile: clean reference did NOT grade GREEN -- grader is vacuous"; fi

mutate_red() { # mut module golden kind label
    local mut="$1" mod="$2" gb="$3" kind="$4" label="$5"
    python3 "$REF" mutate "$mut" "$work/$mut.elf"
    local k; k=$(python3 "$REF" kend "$mut")
    if qemu_grade "$work/$mut.elf" "$mod" "$k" "$gb" "$kind"; then
        fail_test "M-$mut ($label): mutation graded GREEN -- NOT load-bearing"
    else
        pass=$((pass + 1))
    fi
}
mutate_red dpl0frame   "$work/mod_x.bin"   5A benign  "iret pushes ring-0 cs -> no CPL3 entry"
mutate_red callcpl0    "$work/mod_h.bin"   00 hostile "CPL0 call instead of iret -> hostile out undetected"
mutate_red gatedpl0    "$work/mod_x.bin"   5A benign  "exit gate DPL0 -> benign int 0x30 #GPs"
mutate_red iopl3frame  "$work/mod_h.bin"   00 hostile "iret IOPL=3 -> hostile out permitted"
mutate_red iomap       "$work/mod_h.bin"   00 hostile "TSS IOPB grants port 0xE9 -> hostile out permitted"
mutate_red tssesp0     "$work/mod_x.bin"   5A benign  "unmapped esp0 -> frame push triple-faults"
mutate_red resumeorder "$work/mod_x.bin"   5A benign  "reload segs before saving status -> wrong f"
mutate_red wrongcell   "$work/mod_x.bin"   5A benign  "store status to wrong cell -> stale body read"
mutate_red noexclude   "$work/mod_x.bin"   5A benign  "skip all exclusions -> alloc==kernel; recompute mismatch"
mutate_red noexclbuf   "$work/mod_x.bin"   5A benign  "exclude only kernel+module -> overlaps loader buffers"
mutate_red hardcodeaddr "$work/mod_fat.bin" 5A benign "fixed alloc literal -> recompute mismatch; overlaps FAT"

echo ""
if [[ "$fail" -ne 0 ]]; then echo "$fail native-codegen-link34 mutation sub-test(s) failed."; exit 1; fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link34 mutation / trikonderoga: control clean build GREEN on benign+hostile + 11 mutations each RED on the dual-substrate host grader -- ring entry (M-dpl0frame/M-callcpl0), syscall exit gate (M-gatedpl0), privileged-op isolation (M-iopl3frame/M-iomap/M-tssesp0), resume path (M-resumeorder/M-wrongcell), honest allocation (M-noexclude/M-noexclbuf/M-hardcodeaddr); $pass checks)"
exit 0
