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
#    M-tssesp0    (TSS esp0 outside 64M RAM) -> invalid exit/#GP frame                            (RED)
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

unset CDPATH
script_dir="$(cd "$(dirname "$0")" && pwd)"


# Fail closed before any emulator availability probe, including standalone runs.
qemu_helper_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || exit 1
source "$qemu_helper_dir/qemu_prefix.sh" || { echo "FAIL: cannot establish QEMU prefix" >&2; exit 1; }

REF="$script_dir/trikon_ref.py"
REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"
[[ -f "$REF" ]] || { echo "FAIL: stack/native_compile_fragment.herb (missing trikon_ref.py)"; exit 1; }

work="$(mktemp -d)" || exit 1
export KERNEL_PARSE_ERROR_FILE="$work/parser-errors.txt"
link34_cleanup() {
    local status=$?
    if [[ -z "${KERNEL_EVIDENCE_DIR:-}" ]] && { (( status != 0 )) || [[ -s "$KERNEL_PARSE_ERROR_FILE" ]]; }; then
        echo "link34: failed work retained at $work" >&2
        # With no deletion targets the shared helper still enforces parser-error
        # failure, while leaving this gate's complete scratch available to inspect.
        KERNEL_TEST_EXIT_STATUS="$status" kernel_test_cleanup
        return "$status"
    fi
    KERNEL_TEST_EXIT_STATUS="$status" kernel_test_cleanup "$work"
}
trap 'link34_cleanup' EXIT
HVMARK="$work/harness-failures.txt"   # captured with the attempts; any recorded emulator/grader failure makes the run RED
pass=0; fail=0
fail_test() { [[ ! -s "$KERNEL_PARSE_ERROR_FILE" ]] || exit 1; echo "FAIL: stack/native_compile_fragment.herb ($1)"; fail=$((fail + 1)); }
have_qemu() { command -v qemu-system-x86_64 >/dev/null 2>&1; }

python3 "$REF" module X "$work/mod_x.bin"
python3 "$REF" module HOST "$work/mod_h.bin"
python3 "$REF" module FAT "$work/mod_fat.bin"

qemu_grade() { # elf mod kend golden kind -> 0 if grader GREEN, 1 if RED
    local elf="$1" mod="$2" kend="$3" gb="$4" kind="$5"
    local label="${elf##*/}-$kind" out qemu_status grade_status grade_verdict expected_verdict
    out="$work/$label.e9.bin"
    # Every control/mutation has its own capture; later runs cannot overwrite an
    # earlier abort. KERNEL_EVIDENCE_DIR retains these files through the EXIT trap.
    [[ ! -e "$out.inputs.sha256" ]] || { echo "FAIL: duplicate link34 capture label $label" >&2; exit 1; }
    sha256sum -- "$elf" "$mod" > "$out.inputs.sha256" || { echo "FAIL: cannot record link34 inputs for $label" >&2; exit 1; }
    timeout 60 qemu-system-x86_64 -kernel "$elf" -initrd "$mod" -debugcon file:"$out" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none \
        -monitor none -cpu qemu64 -m 64M >"$out.qout" 2>"$out.qerr"
    qemu_status=$?
    printf 'qemu_status=%s\nkend=%s\ngolden=%s\nkind=%s\n' "$qemu_status" "$kend" "$gb" "$kind" > "$out.status" || { echo "FAIL: cannot record link34 status for $label" >&2; exit 1; }
    # Preserve the existing fail-closed predicate. Non-timeout stderr includes
    # launch failures AND emulator assertions during guest execution. Exit status
    # alone is not a verdict: legitimate isa-debug-exit codes can be above 124.
    if grep -qvE 'terminating on signal' "$out.qerr" 2>/dev/null; then
        echo "FAIL: link34 harness failure -- QEMU diagnostics for $label (status $qemu_status):" >&2
        cat "$out.qerr" >&2
        printf '%s (QEMU)\n' "$label" >> "$HVMARK" || { echo "FAIL: cannot record link34 harness failure for $label" >&2; exit 1; }
    fi
    python3 "$REF" grade "$out" "$kend" "$gb" "$kind" >"$out.grade" 2>"$out.grade.qerr"
    grade_status=$?
    IFS= read -r grade_verdict < "$out.grade" || grade_verdict=""
    expected_verdict=RED; (( grade_status == 0 )) && expected_verdict=GREEN
    printf 'grader_status=%s\ngrader_verdict=%s\n' "$grade_status" "$grade_verdict" >> "$out.status" || { echo "FAIL: cannot record link34 status for $label" >&2; exit 1; }
    # Ordinary rejects print RED, exit 1 and leave stderr empty. Missing captures,
    # exceptions and status-only failures must not certify a mutation's bite.
    if (( grade_status != 0 && grade_status != 1 )) || [[ -s "$out.grade.qerr" || "$grade_verdict" != "$expected_verdict" ]]; then
        echo "FAIL: link34 harness failure -- grader diagnostics for $label (status $grade_status):" >&2
        cat "$out.grade.qerr" >&2
        printf '%s (grader)\n' "$label" >> "$HVMARK" || { echo "FAIL: cannot record link34 harness failure for $label" >&2; exit 1; }
    fi
    return "$grade_status"
}

if ! have_qemu; then
    if [[ "$REQUIRE_EMU" == "1" ]]; then echo "FAIL: stack/native_compile_fragment.herb (REQUIRE_EMU=1 but qemu missing)"; exit 1; fi
    echo "SKIP: native-codegen link34 mutation (no qemu; authoritative run is the kernel-codegen CI workflow)"; exit 0
fi

# CONTROL: the clean reference must grade GREEN on BOTH the benign and hostile paths (else vacuous).
python3 "$REF" cleanelf "$work/clean.elf"
KCLEAN=$(python3 "$REF" kend -) || { echo "FAIL: cannot determine link34 clean kernel end" >&2; exit 1; }
if qemu_grade "$work/clean.elf" "$work/mod_x.bin" "$KCLEAN" 5A benign; then pass=$((pass + 1)); else
    fail_test "CONTROL benign: clean reference did NOT grade GREEN -- grader is vacuous"; fi
if qemu_grade "$work/clean.elf" "$work/mod_h.bin" "$KCLEAN" 00 hostile; then pass=$((pass + 1)); else
    fail_test "CONTROL hostile: clean reference did NOT grade GREEN -- grader is vacuous"; fi

mutate_red() { # mut module golden kind label
    local mut="$1" mod="$2" gb="$3" kind="$4" label="$5"
    python3 "$REF" mutate "$mut" "$work/$mut.elf"
    local k; k=$(python3 "$REF" kend "$mut") || { echo "FAIL: cannot determine link34 kernel end for $mut" >&2; exit 1; }
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
mutate_red tssesp0     "$work/mod_x.bin"   5A benign  "TSS esp0 outside RAM -> invalid exit/#GP frame"
mutate_red resumeorder "$work/mod_x.bin"   5A benign  "reload segs before saving status -> wrong f"
mutate_red wrongcell   "$work/mod_x.bin"   5A benign  "store status to wrong cell -> stale body read"
mutate_red noexclude   "$work/mod_x.bin"   5A benign  "skip all exclusions -> alloc==kernel; recompute mismatch"
mutate_red noexclbuf   "$work/mod_x.bin"   5A benign  "exclude only kernel+module -> overlaps loader buffers"
mutate_red hardcodeaddr "$work/mod_fat.bin" 5A benign "fixed alloc literal -> recompute mismatch; overlaps FAT"

echo ""
[[ ! -s "$KERNEL_PARSE_ERROR_FILE" ]] || exit 1  # EXIT cleanup prints the parser error; never print PASS first.
if [[ "$fail" -ne 0 ]]; then echo "$fail native-codegen-link34 mutation sub-test(s) failed."; exit 1; fi
if [[ -e "$HVMARK" ]]; then
    echo "FAIL: link34 HARNESS FAILURE -- emulator or grader failure; fail-closed, NOT a genuine pass. Affected attempts:"
    cat "$HVMARK"
    exit 1
fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link34 mutation / trikonderoga: control clean build GREEN on benign+hostile + 11 mutations each RED on the dual-substrate host grader -- ring entry (M-dpl0frame/M-callcpl0), syscall exit gate (M-gatedpl0), privileged-op isolation (M-iopl3frame/M-iomap/M-tssesp0), resume path (M-resumeorder/M-wrongcell), honest allocation (M-noexclude/M-noexclbuf/M-hardcodeaddr); $pass checks)"
exit 0
