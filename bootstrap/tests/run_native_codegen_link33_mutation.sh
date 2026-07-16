#!/usr/bin/env bash
# Held-back MUTATION proof for Link 33 (lodger). The GATE (run_native_codegen_link33.sh) proves the
# COMPILER's emitted head is BYTE-IDENTICAL to the silicon-proven reference (lodger_ref.py). This
# harness proves each load-bearing DESIGN CHOICE in that reference is non-vacuous: it builds the
# reference echo image with ONE design defect injected (lodger_ref mutate <mut>) -- byte-derived from
# the same proven assembler the compiler is pinned to -- and asserts the dual-substrate host grader
# goes RED. The CLEAN reference build is asserted GREEN first (control), so a vacuous grader is caught.
#
# HONEST RED taxonomy (calibrated against the live empirical run -- the balanced push/pop spray does
# NOT corrupt the return path at 512 words on QEMU, so the aliasing mutations are caught by the host
# WITNESS/recompute, NOT by a silicon divergence; only M-skipcall/M-modaddr change the raw 0xE9 stream):
#  SILICON-RED  (the OBSERVED 0xE9 stream itself changes on QEMU -- no host grader needed to see it):
#    M-skipcall   (bake the answer, never call the module)  -> the CA/FE witness frame is simply ABSENT
#    M-modaddr    (call [mbinfo] -- a non-code pointer -- not [mod_start]) -> faults, no witness frame.
#                  (Runtime DISCOVERY -- that mod_start must be READ at runtime, not hardcoded -- is the
#                   GATE's cross-substrate property: the module is at a DIFFERENT physical addr on QEMU
#                   vs Bochs, so no fixed literal works on both. This mutation proves the call must
#                   dereference the mod_start CELL specifically.)
#  HOST-RED  (the run completes and emits a frame, but the host grader catches it -- via the module
#             WITNESS [esp==alloc_hi, eip==mod_start+10] or by RE-DERIVING the allocator policy from the
#             dumped map+ELF and demanding EQUALITY; this deterministic host catch IS the v2 upgrade):
#    M-aliasframe  (esp into a kernel code page, not alloc_hi) -> witness esp != alloc_hi (deterministic)
#    M-provlit     (dump a clean table, run on a forged stack) -> witness esp != dumped alloc_hi
#    M-noexclude   (skip ALL exclusions)        -> alloc == kernel start; host recompute mismatch
#    M-noexclbuf   (exclude only kernel+module)  -> alloc overlaps the module string/cmdline; recompute mismatch
#    M-hardcodeaddr(alloc base = fixed literal)  -> recompute mismatch; overlaps the FAT module
# The honest residue (a roundup(mod_end)-style allocator coinciding with the full policy when the module
# is topmost) is named in run_native_codegen_link33.sh; M-noexclude+M-noexclbuf prove the machinery is
# load-bearing as far as the layouts allow.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
REF="$script_dir/lodger_ref.py"
REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"
[[ -f "$REF" ]] || { echo "FAIL: stack/native_compile_fragment.herb (missing lodger_ref.py)"; exit 1; }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
HVMARK="/tmp/.hv_harness_fail.$$"; rm -f "$HVMARK"   # fail-closed marker: a dead/timed-out QEMU run trips this -> hard fail at end
pass=0; fail=0
fail_test() { echo "FAIL: stack/native_compile_fragment.herb ($1)"; fail=$((fail + 1)); }
have_qemu() { command -v qemu-system-x86_64 >/dev/null 2>&1; }

python3 "$REF" module X "$work/mod_x.bin"
python3 "$REF" module FAT "$work/mod_fat.bin"
python3 "$REF" module STACK "$work/mod_stk.bin"

qemu_grade() { # elf mod kend goldenhex -> 0 if grader GREEN, 1 if RED
    local elf="$1" mod="$2" kend="$3" gb="$4" out="$work/e9.bin"
    timeout 60 qemu-system-x86_64 -kernel "$elf" -initrd "$mod" -debugcon file:"$out" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none \
        -monitor none -cpu qemu64 -m 64M >/dev/null 2>"$out.qerr"
    # fail-closed: a QEMU LAUNCH failure (bad drive/args/OOM/binary/socket) writes to stderr, while a clean
    # run -- even a guest fault or a hang-is-the-bite mutant -- leaves stderr EMPTY. So non-empty stderr is an
    # unambiguous HARNESS failure, NOT a mutation bite. (rc is NOT usable here: isa-debug-exit yields arbitrary
    # odd exit codes >124 on legit completions, and hang-bites legitimately time out at rc=124.)
    grep -qvE 'terminating on signal' "$out.qerr" 2>/dev/null && { echo "FAIL: link33 harness failure -- QEMU launch error: $(grep -vE 'terminating on signal' "$out.qerr" | head -1)" >&2; : > "$HVMARK"; }   # only a NON-timeout stderr line is a launch failure; a timeout-kill (hang bite) is left to the grader
    python3 "$REF" grade "$out" "$kend" "$gb" - >/dev/null 2>&1
}

if ! have_qemu; then
    if [[ "$REQUIRE_EMU" == "1" ]]; then echo "FAIL: stack/native_compile_fragment.herb (REQUIRE_EMU=1 but qemu missing)"; exit 1; fi
    echo "SKIP: native-codegen link33 mutation (no qemu; authoritative run is the kernel-codegen CI workflow)"; exit 0
fi

# CONTROL: the clean reference build must grade GREEN (else the grader is vacuous).
python3 "$REF" cleanelf "$work/clean.elf"
KCLEAN=$(python3 "$REF" kend -)
if qemu_grade "$work/clean.elf" "$work/mod_x.bin" "$KCLEAN" 5A; then pass=$((pass + 1)); else
    fail_test "CONTROL: clean reference build did NOT grade GREEN -- grader is vacuous"; fi

# each mutation -> the bite-exposing module -> expect RED.
mutate_red() { # mut module label
    local mut="$1" mod="$2" label="$3"
    python3 "$REF" mutate "$mut" "$work/$mut.elf"
    local k; k=$(python3 "$REF" kend "$mut")
    if qemu_grade "$work/$mut.elf" "$mod" "$k" 5A; then
        fail_test "M-$mut ($label): mutation graded GREEN -- the byte is NOT load-bearing"
    else
        pass=$((pass + 1))
    fi
}
mutate_red skipcall     "$work/mod_x.bin"   "bake answer, no module call -> witness absent (SILICON)"
mutate_red modaddr      "$work/mod_x.bin"   "call [mbinfo] non-code pointer -> fault, no witness (SILICON)"
mutate_red aliasframe   "$work/mod_stk.bin" "esp into kernel page -> witness esp!=alloc_hi (HOST)"
mutate_red noexclude    "$work/mod_stk.bin" "skip all exclusions -> alloc==kernel; host recompute mismatch (HOST)"
mutate_red noexclbuf    "$work/mod_x.bin"   "exclude only kernel+module -> overlaps string/cmdline (HOST)"
mutate_red hardcodeaddr "$work/mod_fat.bin" "fixed alloc literal -> recompute mismatch; overlaps FAT (HOST)"
mutate_red provlit      "$work/mod_x.bin"   "forged stack, clean dump -> witness esp!=dumped alloc_hi (HOST)"

echo ""
if [[ "$fail" -ne 0 ]]; then echo "$fail native-codegen-link33 mutation sub-test(s) failed."; exit 1; fi
if [[ -e "$HVMARK" ]]; then echo "FAIL: link33 HARNESS FAILURE -- a QEMU run was dead/timed-out (empty output); fail-closed, NOT a genuine pass"; rm -f "$HVMARK"; exit 1; fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link33 mutation / lodger: control clean build GREEN + 7 mutations each RED on the dual-substrate host grader -- M-skipcall/M-modaddr SILICON-RED (the 0xE9 stream itself changes -- witness frame absent), M-aliasframe/M-provlit/M-noexclude/M-noexclbuf/M-hardcodeaddr HOST-RED (the run completes; the host witness [esp==alloc_hi] + allocator-policy recompute catch it); honest split, $pass checks)"
exit 0
