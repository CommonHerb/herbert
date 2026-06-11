#!/usr/bin/env bash
# Held-back MUTATION proof for Link 35 (nokta). The GATE (run_native_codegen_link35.sh) proves the COMPILER's
# emitted prefix+epilogue is BYTE-IDENTICAL to the silicon+KVM-proven reference (nokta_ref.py). This harness
# proves each load-bearing DESIGN CHOICE in that reference is non-vacuous: it builds the reference image with
# ONE design defect injected (nokta_ref mutate <mut>) and asserts the host grader goes RED. The CLEAN build is
# asserted GREEN first on every graded path (control), so a vacuous grader is caught.
#
# RED taxonomy (each proves a distinct piece of the memory-isolation atom is load-bearing):
#  PAGING + U/S PARTITION (the nokta atom):
#    M-nopaging    (skip CR3+CR0.PG -> flat PM) -> hostile WRITE lands, no #PF                          (RED)
#    M-canaryuser  (flip the kernel target page to User too) -> hostile WRITE lands, reaches int 0x30   (RED)
#    M-nomodflip   (module code page left Supervisor) -> CPL3 instruction fetch #PFs -> benign breaks   (RED)
#    M-nostackflip (module stack page left Supervisor) -> benign own-page write #PFs                    (RED)
#    M-pdesup      (PDEs Supervisor -> module pages effective-Supervisor by the U/S AND-rule)           (RED)
#    M-ptuser      (the PT page itself User -> a CPL3 module can patch its own PTE) -> hostile PT-write
#                   LANDS -> no #PF (proves the page-tables-are-Supervisor property is load-bearing)    (RED)
#  RING ENTRY / SYSCALL GATE / PRIV-OP ISOLATION (inherited from trikon, must still bite UNDER paging):
#    M-dpl0frame / M-callcpl0 / M-gatedpl0 / M-iopl3frame / M-iomap / M-tssesp0 / M-resumeorder /
#    M-wrongcell                                                                                        (RED)
#  HONEST ALLOCATION (inherited from lodger, D20 -- the allocator runs in flat PM before paging):
#    M-noexclude / M-noexclbuf / M-hardcodeaddr                                                         (RED)
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
REF="$script_dir/nokta_ref.py"
REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"
[[ -f "$REF" ]] || { echo "FAIL: stack/native_compile_fragment.herb (missing nokta_ref.py)"; exit 1; }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
pass=0; fail=0
fail_test() { echo "FAIL: stack/native_compile_fragment.herb ($1)"; fail=$((fail + 1)); }
have_qemu() { command -v qemu-system-x86_64 >/dev/null 2>&1; }

python3 "$REF" module X "$work/mod_x.bin"
python3 "$REF" module HOST "$work/mod_h.bin"
python3 "$REF" module HOSW "$work/mod_w.bin"
python3 "$REF" module HOSR "$work/mod_r.bin"
python3 "$REF" module HOSPT "$work/mod_pt.bin"
python3 "$REF" module FAT "$work/mod_fat.bin"
PTADDR="$(python3 "$REF" ptaddr)"

qemu_grade() { # elf mod kend golden kind [expect_cr2] -> 0 if grader GREEN, 1 if RED
    local elf="$1" mod="$2" kend="$3" gb="$4" kind="$5" ec2="${6:-}" out="$work/e9.bin"
    timeout 60 qemu-system-x86_64 -kernel "$elf" -initrd "$mod" -debugcon file:"$out" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none \
        -monitor none -cpu qemu64 -m 64M >/dev/null 2>&1 || true
    python3 "$REF" grade "$out" "$kend" "$gb" "$kind" $ec2 >/dev/null 2>&1
}

if ! have_qemu; then
    if [[ "$REQUIRE_EMU" == "1" ]]; then echo "FAIL: stack/native_compile_fragment.herb (REQUIRE_EMU=1 but qemu missing)"; exit 1; fi
    echo "SKIP: native-codegen link35 mutation (no qemu; authoritative run is the kernel-codegen CI workflow)"; exit 0
fi

# CONTROL: the clean reference must grade GREEN on EVERY graded path (else a vacuous grader).
python3 "$REF" cleanelf "$work/clean.elf"
KCLEAN=$(python3 "$REF" kend -)
qemu_grade "$work/clean.elf" "$work/mod_x.bin"  "$KCLEAN" 5A benign      && pass=$((pass+1)) || fail_test "CONTROL benign: clean reference not GREEN -- grader vacuous"
qemu_grade "$work/clean.elf" "$work/mod_h.bin"  "$KCLEAN" 00 hostile     && pass=$((pass+1)) || fail_test "CONTROL hostile-out: clean reference not GREEN"
qemu_grade "$work/clean.elf" "$work/mod_w.bin"  "$KCLEAN" 00 pfault      && pass=$((pass+1)) || fail_test "CONTROL hostile-write: clean reference not GREEN"
qemu_grade "$work/clean.elf" "$work/mod_r.bin"  "$KCLEAN" 00 pfault_read && pass=$((pass+1)) || fail_test "CONTROL hostile-read: clean reference not GREEN"
qemu_grade "$work/clean.elf" "$work/mod_pt.bin" "$KCLEAN" 00 pfault_pt "0x$PTADDR" && pass=$((pass+1)) || fail_test "CONTROL hostile-PT: clean reference not GREEN"

mutate_red() { # mut module golden kind label [expect_cr2]
    local mut="$1" mod="$2" gb="$3" kind="$4" label="$5" ec2="${6:-}"
    python3 "$REF" mutate "$mut" "$work/$mut.elf"
    local k; k=$(python3 "$REF" kend "$mut")
    if qemu_grade "$work/$mut.elf" "$mod" "$k" "$gb" "$kind" "$ec2"; then
        fail_test "M-$mut ($label): mutation graded GREEN -- NOT load-bearing"
    else
        pass=$((pass + 1))
    fi
}
# --- the nokta memory-isolation atom ---
mutate_red nopaging    "$work/mod_w.bin"  00 pfault      "flat PM -> hostile write lands"
mutate_red canaryuser  "$work/mod_w.bin"  00 pfault      "kernel target page User -> write lands"
mutate_red nomodflip   "$work/mod_x.bin"  5A benign      "module code page Supervisor -> CPL3 fetch #PF"
mutate_red nostackflip "$work/mod_x.bin"  5A benign      "module stack page Supervisor -> own-write #PF"
mutate_red pdesup      "$work/mod_x.bin"  5A benign      "PDEs Supervisor -> module pages effective-Supervisor"
mutate_red ptuser      "$work/mod_pt.bin" 00 pfault_pt   "PT page User -> CPL3 patches its own PTE" "0x$PTADDR"
# --- inherited ring boundary (must still bite under paging) ---
mutate_red dpl0frame   "$work/mod_x.bin"  5A benign      "iret pushes ring-0 cs -> no CPL3 entry"
mutate_red callcpl0    "$work/mod_h.bin"  00 hostile     "CPL0 call instead of iret -> hostile out undetected"
mutate_red gatedpl0    "$work/mod_x.bin"  5A benign      "exit gate DPL0 -> benign int 0x30 #GPs"
mutate_red iopl3frame  "$work/mod_h.bin"  00 hostile     "iret IOPL=3 -> hostile out permitted"
mutate_red iomap       "$work/mod_h.bin"  00 hostile     "TSS IOPB grants port 0xE9 -> hostile out permitted"
mutate_red tssesp0     "$work/mod_x.bin"  5A benign      "unmapped esp0 -> frame push triple-faults"
mutate_red resumeorder "$work/mod_x.bin"  5A benign      "reload segs before saving status -> wrong f"
mutate_red wrongcell   "$work/mod_x.bin"  5A benign      "store status to wrong cell -> stale body read"
# --- inherited honest allocation (D20) ---
mutate_red noexclude   "$work/mod_x.bin"  5A benign      "skip all exclusions -> alloc==kernel; recompute mismatch"
mutate_red noexclbuf   "$work/mod_x.bin"  5A benign      "exclude only kernel+module -> overlaps loader buffers"
mutate_red hardcodeaddr "$work/mod_fat.bin" 5A benign    "fixed alloc literal -> recompute mismatch; overlaps FAT"

echo ""
if [[ "$fail" -ne 0 ]]; then echo "$fail native-codegen-link35 mutation sub-test(s) failed."; exit 1; fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link35 mutation / nokta: control clean build GREEN on benign+hostile-out+write+read+PT-write + 17 mutations each RED on the dual-substrate host grader -- the U/S partition (M-nopaging/M-canaryuser/M-nomodflip/M-nostackflip/M-pdesup/M-ptuser), ring entry/syscall-gate/priv-op isolation under paging (M-dpl0frame/M-callcpl0/M-gatedpl0/M-iopl3frame/M-iomap/M-tssesp0/M-resumeorder/M-wrongcell), honest allocation (M-noexclude/M-noexclbuf/M-hardcodeaddr); $pass checks)"
exit 0
