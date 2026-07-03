#!/usr/bin/env bash
# kernel_verify.sh -- the LOCAL kernel-arc BOOT GATE (invoked by `make kernel-verify`).
#
# Runs every kernel-codegen link gate (link17..link62 = kernel-arc L1..L46) plus its
# mutation proof with KERNEL_CODEGEN_REQUIRE_EMU=1 -- so a missing QEMU-TCG or Bochs is a
# HARD failure, never the silent skip you get from a bare `bash run_native_codegen_linkNN.sh`.
#
# WHY THIS TARGET EXISTS (the local/CI split, Constitution A11):
#   * CI (`.github/workflows/kernel-codegen-l1.yml`) runs these same gates on GitHub runners
#     that have NO /dev/kvm, so a CI green certifies QEMU-TCG + Bochs ONLY.
#   * KVM (real silicon -- the A11 tier-1 anchor) is a LOCAL pre-push leg by necessity.
#     Commit a2b255e correctly made the per-gate KVM leg skip-if-absent so CI stays green;
#     the cost is that a KVM host can silently NOT exercise real silicon.
#   * This target closes that: when /dev/kvm is present-and-usable it REQUIRES the real-silicon
#     leg (each tri-substrate gate's own `have_kvm` then runs it); if /dev/kvm exists but is not
#     usable it FAILS LOUD rather than dropping the substrate. When /dev/kvm is genuinely absent
#     it runs the CI-equivalent QEMU+Bochs gate and says so.
#
# Range override (for smoke tests): KERNEL_VERIFY_LO / KERNEL_VERIFY_HI (default 17..62).

set -uo pipefail
cd "$(dirname "$0")/../.."   # herbert repo root

LO="${KERNEL_VERIFY_LO:-17}"
HI="${KERNEL_VERIFY_HI:-62}"

# Validate the range up front: a non-integer or inverted range must FAIL, never fall
# through to a vacuous "GREEN" with zero gates run (a false-green is the one outcome this
# gate exists to prevent).
if ! [[ "$LO" =~ ^[0-9]+$ && "$HI" =~ ^[0-9]+$ ]] || (( LO > HI )); then
    echo "FAIL: KERNEL_VERIFY_LO/HI must be integers with LO<=HI (got LO='$LO' HI='$HI')." >&2
    exit 1
fi

have_qemu() { command -v qemu-system-x86_64 >/dev/null 2>&1; }
have_kvm()  { [[ -r /dev/kvm && -w /dev/kvm ]] && have_qemu; }   # mirrors the gate scripts

# --- KVM preflight: the real-silicon leg is REQUIRED when /dev/kvm exists ------------
if [[ -e /dev/kvm ]]; then
    if have_kvm; then
        echo "kernel-verify: /dev/kvm present + r/w and qemu-system-x86_64 available -- the KVM real-silicon leg is REQUIRED this run"
        echo "               (A11 tier-1; actual KVM acceleration is proven when the first tri-substrate gate boots -enable-kvm -- link44+)."
    else
        {
          echo "FAIL: /dev/kvm exists but is not usable (not r/w, or qemu-system-x86_64 missing)."
          echo "      kernel-verify REQUIRES the KVM real-silicon leg when /dev/kvm is present. Either fix access"
          echo "      (e.g. add yourself to the 'kvm' group), or run where /dev/kvm is absent for the CI-equivalent"
          echo "      QEMU-TCG + Bochs gate. Refusing to silently drop the real-silicon substrate."
        } >&2
        exit 1
    fi
else
    echo "kernel-verify: /dev/kvm ABSENT -- running the CI-equivalent QEMU-TCG + Bochs gate ONLY (no real silicon)."
    echo "               Run on a KVM host before a kernel-arc push to exercise the A11 tier-1 real-silicon anchor."
fi

fail=0
ran=0
for n in $(seq "$LO" "$HI"); do
    g="bootstrap/tests/run_native_codegen_link${n}.sh"
    [[ -f "$g" ]] || continue
    echo "== link${n} gate (kernel-arc L$((n-16))) =="
    if ! KERNEL_CODEGEN_REQUIRE_EMU=1 bash "$g"; then echo "FAIL: $g" >&2; fail=1; break; fi
    ran=$((ran+1))
    m="bootstrap/tests/run_native_codegen_link${n}_mutation.sh"
    if [[ -f "$m" ]]; then
        echo "== link${n} mutation proof =="
        if ! KERNEL_CODEGEN_REQUIRE_EMU=1 KERNEL_CODEGEN_MUTATION=1 bash "$m"; then echo "FAIL: $m" >&2; fail=1; break; fi
    fi
done

if [[ "$fail" -ne 0 ]]; then echo "kernel-verify: RED" >&2; exit 1; fi
if [[ "$ran" -eq 0 ]]; then
    echo "FAIL: no kernel-arc gate scripts found in range ${LO}..${HI} -- refusing to report GREEN with zero gates run." >&2
    exit 1
fi
kvm_note="QEMU-TCG + Bochs"; [[ -e /dev/kvm ]] && have_kvm && kvm_note="QEMU-TCG + Bochs + KVM (real silicon)"
echo "kernel-verify: GREEN (kernel-arc links ${LO}..${HI}, KERNEL_CODEGEN_REQUIRE_EMU=1, ${kvm_note})"
