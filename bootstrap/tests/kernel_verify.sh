#!/usr/bin/env bash
# kernel_verify.sh -- the LOCAL kernel-arc BOOT GATE (invoked by `make kernel-verify`).
#
# Runs every kernel-codegen link gate (link17..link67) plus its
# mutation proof with KERNEL_CODEGEN_REQUIRE_EMU=1. Individual gates enforce
# that emulator requirement; this driver verifies their presence and exit status.
#
# WHY THIS TARGET EXISTS (the local/CI split, Constitution A11):
#   * CI (`.github/workflows/kernel-codegen-l1.yml`) runs these same gates on GitHub runners
#     that have NO /dev/kvm, so a CI green certifies QEMU-TCG + Bochs ONLY.
#   * KVM (real silicon -- the A11 tier-1 anchor) is a LOCAL pre-push leg by necessity.
#     Commit a2b255e correctly made the per-gate KVM leg skip-if-absent so CI stays green;
#     the cost is that a KVM host can silently NOT exercise real silicon.
#   * This target checks KVM availability for the declared member links and fails if
#     /dev/kvm exists but cannot be accessed. Individual gates own their KVM branches.
#     Availability is not execution evidence: the aggregate records gate exit statuses,
#     and makes no per-substrate execution claim without per-gate boot receipts.
#
# Range override (for smoke tests): KERNEL_VERIFY_LO / KERNEL_VERIFY_HI (default 17..67).

set -uo pipefail
# CDPATH is unset FIRST and the cd is checked: `cd` with a RELATIVE operand searches $CDPATH before
# the current directory, so an inherited CDPATH sent this script into a decoy tree and every one of
# its anti-vacuous-GREEN guards was then evaluated against the decoy -- a single `exit 0` stub gate
# printed "kernel-verify: GREEN (kernel-arc links 17..17 ...)" rc 0. `make kernel-verify` invokes
# this file by a RELATIVE $0, so the vector is reachable from the top-level target. Same class the
# suite driver closed the same day; found here by the blind Opus 5 refuter, 2026-09-02.
unset CDPATH
cd -- "$(dirname "$0")/../.." || exit 1   # herbert repo root

LO="${KERNEL_VERIFY_LO:-17}"
# The DEFAULT sweep must track the canonical set below (GATE_LO/GATE_HI), or `make kernel-verify`
# silently stops short of the newest link while that link is still REQUIRED to exist -- which is
# exactly what happened when the canonical range moved to 66 and this default was left at 65:
# link66 would have been canonical, mandatory, and never run by the local sweep.
HI="${KERNEL_VERIFY_HI:-67}"

# Validate the range up front: a non-integer or inverted range must FAIL, never fall
# through to a vacuous "GREEN" with zero gates run (a false-green is the one outcome this
# gate exists to prevent).
if ! [[ "$LO" =~ ^[0-9]+$ && "$HI" =~ ^[0-9]+$ ]] || (( LO > HI )); then
    echo "FAIL: KERNEL_VERIFY_LO/HI must be integers with LO<=HI (got LO='$LO' HI='$HI')." >&2
    exit 1
fi


# Fail closed before any emulator availability probe, including standalone runs.
unset CDPATH
qemu_helper_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || exit 1
source "$qemu_helper_dir/qemu_prefix.sh" || { echo "FAIL: cannot establish QEMU prefix" >&2; exit 1; }


have_qemu() { command -v qemu-system-x86_64 >/dev/null 2>&1; }
have_kvm()  { [[ -r /dev/kvm && -w /dev/kvm ]] && have_qemu; }   # mirrors the gate scripts

# --- the canonical kernel-arc gate set (what MUST exist -- a missing member inside the requested range is a
#     HARD failure, never the silent skip that yields a vacuous GREEN) --------------------------------------
#   * gate script     for every link 17..67
#   * mutation proof  for every link 18..67  (link17 predates the mutation-proof convention -- the ONE
#                     documented gate-only exception)
#   The declaration below is also the SCORECARD's range authority for section 4.
#   folio extends it through link67, alongside the local default and CI matrix.
#   NOTE TO ANYONE EDITING THIS COMMENT: the scorecard requires EXACTLY ONE occurrence each of the
#   two assignment strings in this whole file, so do not spell them out in prose -- writing them
#   here once broke section 4 outright (`declaration not unique: 2 assignment(s)`), which is a
#   uniqueness invariant doing its job on a comment that meant well.
GATE_LO=17; GATE_HI=67
mutation_expected() { local n="$1"; (( n >= 18 && n <= GATE_HI )); }

# --- declared KVM member links (an explicit set, not a contiguous range) --------
# link39 and links44..67 have KVM branches; links40..43 do not. Membership controls
# the access preflight only. It is not proof that a successful gate ran its KVM
# branch. A required-KVM protocol with per-gate receipts remains future work.
# Specific trap retained from the 2026-09-01 independent Opus review: link39's
# tripwire requires two engines, not KVM. TCG + Bochs satisfies it; it would not
# catch removal of link39's KVM branch. Gate success is not a KVM receipt.
KVM_LINKS="39 $(seq -s' ' 44 67)"
kvm_links_desc() {   # compact the member set for the banner -- DERIVED from KVM_LINKS, so the text a
                     # reader sees can never drift from the set the requirement is computed on.
    local n out="" s="" p=""
    for n in $KVM_LINKS; do
        if [[ -z "$s" ]]; then s="$n"; p="$n"; continue; fi
        if (( n == p + 1 )); then p="$n"; continue; fi
        out+="${out:+, }$s"; (( p > s )) && out+="..$p"
        s="$n"; p="$n"
    done
    [[ -n "$s" ]] && { out+="${out:+, }$s"; (( p > s )) && out+="..$p"; }
    echo "$out"
}
KVM_DESC="$(kvm_links_desc)"
range_has_kvm_leg=0
for _k in $KVM_LINKS; do (( _k >= LO && _k <= HI )) && { range_has_kvm_leg=1; break; }; done

# expected counts for the requested range (its intersection with the canonical set)
elo=$(( LO > GATE_LO ? LO : GATE_LO )); ehi=$(( HI < GATE_HI ? HI : GATE_HI ))
exp_gates=0; exp_muts=0
if (( ehi >= elo )); then
    exp_gates=$(( ehi - elo + 1 ))
    for ((n=elo; n<=ehi; n++)); do mutation_expected "$n" && exp_muts=$((exp_muts+1)); done
fi

# --- KVM access preflight for requested member links when /dev/kvm exists -----
if [[ "$range_has_kvm_leg" -eq 1 && -e /dev/kvm ]]; then
    if have_kvm; then
        echo "kernel-verify: /dev/kvm present + r/w and qemu-system-x86_64 available (availability preflight only)."
        echo "               KVM execution is owned by member gates (links ${KVM_DESC}); this aggregate does not collect per-gate KVM receipts."
    else
        {
          echo "FAIL: /dev/kvm exists but is not usable (not r/w, or qemu-system-x86_64 missing)."
          echo "      kernel-verify requires usable KVM access when the device exists and the requested range includes a KVM member."
          echo "      Either fix access (e.g. add yourself to the 'kvm' group), or run where /dev/kvm is absent for the CI-equivalent"
          echo "      QEMU-TCG + Bochs gate. Refusing to silently drop the real-silicon substrate."
        } >&2
        exit 1
    fi
elif [[ "$range_has_kvm_leg" -eq 1 ]]; then
    echo "kernel-verify: /dev/kvm ABSENT -- requesting the CI-equivalent emulator policy from each gate (no KVM available)."
    echo "               Run on a KVM host before a kernel-arc push to exercise the A11 tier-1 real-silicon anchor."
else
    echo "kernel-verify: requested range ${LO}..${HI} contains no declared KVM member (members: ${KVM_DESC}); individual gates enforce the requested emulator policy."
fi

fail=0; ran=0; ran_mut=0
for n in $(seq "$LO" "$HI"); do
    (( n >= GATE_LO && n <= GATE_HI )) || continue   # kernel-verify runs ONLY the canonical kernel-arc set (17..67)
    g="bootstrap/tests/run_native_codegen_link${n}.sh"
    [[ -f "$g" ]] || { echo "FAIL: canonical kernel-arc gate $g is MISSING (deleted/renamed?) -- refusing a vacuous GREEN." >&2; fail=1; break; }
    echo "== link${n} gate (kernel-arc L$((n-16))) =="
    if ! KERNEL_CODEGEN_REQUIRE_EMU=1 bash "$g"; then echo "FAIL: $g" >&2; fail=1; break; fi
    ran=$((ran+1))
    m="bootstrap/tests/run_native_codegen_link${n}_mutation.sh"
    if mutation_expected "$n" && [[ ! -f "$m" ]]; then
        echo "FAIL: canonical mutation proof $m is MISSING (deleted/renamed?) -- refusing a vacuous GREEN." >&2; fail=1; break
    fi
    if [[ -f "$m" ]]; then
        echo "== link${n} mutation proof =="
        if ! KERNEL_CODEGEN_REQUIRE_EMU=1 KERNEL_CODEGEN_MUTATION=1 bash "$m"; then echo "FAIL: $m" >&2; fail=1; break; fi
        ran_mut=$((ran_mut+1))
    fi
done

if [[ "$fail" -ne 0 ]]; then echo "kernel-verify: RED" >&2; exit 1; fi
if [[ "$ran" -eq 0 ]]; then
    echo "FAIL: no kernel-arc gate scripts found in range ${LO}..${HI} -- refusing to report GREEN with zero gates run." >&2
    exit 1
fi
# Belt-and-suspenders: the count that RAN must equal the canonical expectation for this range (a gate or
# mutation skipped for any reason other than a loud FAIL above would surface here, never as a vacuous GREEN).
if (( ran != exp_gates || ran_mut != exp_muts )); then
    echo "FAIL: ran ${ran} gate(s) / ${ran_mut} mutation(s) but the canonical set expects ${exp_gates} / ${exp_muts} in range ${LO}..${HI} -- refusing a vacuous GREEN." >&2
    exit 1
fi
echo "kernel-verify: GREEN (${ran} gates + ${ran_mut} mutation proofs passed; kernel-arc links ${LO}..${HI}, KERNEL_CODEGEN_REQUIRE_EMU=1)"
echo "kernel-verify: substrate scope: individual gate assertions; no aggregate per-substrate execution receipts, including KVM."
