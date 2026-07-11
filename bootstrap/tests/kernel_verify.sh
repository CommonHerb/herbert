#!/usr/bin/env bash
# kernel_verify.sh -- the LOCAL kernel-arc BOOT GATE (invoked by `make kernel-verify`).
#
# Runs every kernel-codegen link gate (link17..link65 = kernel-arc L1..L49) plus its
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
# Range override (for smoke tests): KERNEL_VERIFY_LO / KERNEL_VERIFY_HI (default 17..65).

set -uo pipefail
cd "$(dirname "$0")/../.."   # herbert repo root

LO="${KERNEL_VERIFY_LO:-17}"
HI="${KERNEL_VERIFY_HI:-65}"

# Validate the range up front: a non-integer or inverted range must FAIL, never fall
# through to a vacuous "GREEN" with zero gates run (a false-green is the one outcome this
# gate exists to prevent).
if ! [[ "$LO" =~ ^[0-9]+$ && "$HI" =~ ^[0-9]+$ ]] || (( LO > HI )); then
    echo "FAIL: KERNEL_VERIFY_LO/HI must be integers with LO<=HI (got LO='$LO' HI='$HI')." >&2
    exit 1
fi

have_qemu() { command -v qemu-system-x86_64 >/dev/null 2>&1; }
have_kvm()  { [[ -r /dev/kvm && -w /dev/kvm ]] && have_qemu; }   # mirrors the gate scripts

# --- the canonical kernel-arc gate set (what MUST exist -- a missing member inside the requested range is a
#     HARD failure, never the silent skip that yields a vacuous GREEN) --------------------------------------
#   * gate script     for every link 17..65
#   * mutation proof  for every link 18..65  (link17 predates the mutation-proof convention -- the ONE
#                     documented gate-only exception)
GATE_LO=17; GATE_HI=65
mutation_expected() { local n="$1"; (( n >= 18 && n <= GATE_HI )); }

# --- which requested links carry a KVM real-silicon leg (links 44..65; link62/taproot gained it 2026-07-03).
#     The KVM REQUIREMENT and the GREEN banner's KVM claim apply ONLY when the requested range includes one:
#     a 17..18 smoke has no KVM leg, so requiring or claiming KVM there would be a false guarantee. If a
#     future link past 62 lands without a KVM leg, RAISE nothing here; if it lands WITH one, bump KVM_HI.
#     RESIDUAL (cross-model Codex, 2026-07-03): this is a RANGE assumption, not per-gate proof -- kernel-verify
#     verifies each 44..65 gate EXISTS + exits 0 (3a), but not that it actually ran its -enable-kvm leg. So a
#     FUTURE gate silently dropping its KVM branch while still exiting 0 would let the banner over-claim
#     "+ KVM". Accepted for now: each gate's KVM leg is byte-pinned in that gate, and this full run empirically
#     REQUIRES KVM. A stronger closure (a machine-readable KVM-ran sentinel per gate, or a
#     KERNEL_CODEGEN_REQUIRE_KVM=1 the [44,65] gates honor) is a future hardening, out of this pass's scope. ---
KVM_LO=44; KVM_HI=65
range_has_kvm_leg=0; (( LO <= KVM_HI && HI >= KVM_LO )) && range_has_kvm_leg=1

# expected counts for the requested range (its intersection with the canonical set)
elo=$(( LO > GATE_LO ? LO : GATE_LO )); ehi=$(( HI < GATE_HI ? HI : GATE_HI ))
exp_gates=0; exp_muts=0
if (( ehi >= elo )); then
    exp_gates=$(( ehi - elo + 1 ))
    for ((n=elo; n<=ehi; n++)); do mutation_expected "$n" && exp_muts=$((exp_muts+1)); done
fi

# --- KVM preflight: the real-silicon leg is REQUIRED when /dev/kvm exists AND the range has a KVM leg -----
if [[ "$range_has_kvm_leg" -eq 1 && -e /dev/kvm ]]; then
    if have_kvm; then
        echo "kernel-verify: /dev/kvm present + r/w and qemu-system-x86_64 available -- the KVM real-silicon leg is REQUIRED this run"
        echo "               (A11 tier-1; actual KVM acceleration runs when a tri-substrate gate boots -enable-kvm -- links ${KVM_LO}..${KVM_HI})."
    else
        {
          echo "FAIL: /dev/kvm exists but is not usable (not r/w, or qemu-system-x86_64 missing)."
          echo "      kernel-verify REQUIRES the KVM real-silicon leg when /dev/kvm is present and the range includes a KVM-leg link."
          echo "      Either fix access (e.g. add yourself to the 'kvm' group), or run where /dev/kvm is absent for the CI-equivalent"
          echo "      QEMU-TCG + Bochs gate. Refusing to silently drop the real-silicon substrate."
        } >&2
        exit 1
    fi
elif [[ "$range_has_kvm_leg" -eq 1 ]]; then
    echo "kernel-verify: /dev/kvm ABSENT -- running the CI-equivalent QEMU-TCG + Bochs gate ONLY (no real silicon)."
    echo "               Run on a KVM host before a kernel-arc push to exercise the A11 tier-1 real-silicon anchor."
else
    echo "kernel-verify: requested range ${LO}..${HI} contains no KVM-leg link (KVM legs are links ${KVM_LO}..${KVM_HI}) -- QEMU-TCG + Bochs only, no KVM required or claimed."
fi

fail=0; ran=0; ran_mut=0
for n in $(seq "$LO" "$HI"); do
    (( n >= GATE_LO && n <= GATE_HI )) || continue   # kernel-verify runs ONLY the canonical kernel-arc set (17..65)
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
kvm_note="QEMU-TCG + Bochs"
[[ "$range_has_kvm_leg" -eq 1 ]] && have_kvm && kvm_note="QEMU-TCG + Bochs + KVM (real silicon)"
echo "kernel-verify: GREEN (kernel-arc links ${LO}..${HI}, KERNEL_CODEGEN_REQUIRE_EMU=1, ${kvm_note})"
