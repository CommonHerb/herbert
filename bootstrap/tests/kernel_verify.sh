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
# Range override (for smoke tests): KERNEL_VERIFY_LO / KERNEL_VERIFY_HI (default 17..66).

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
HI="${KERNEL_VERIFY_HI:-66}"

# Validate the range up front: a non-integer or inverted range must FAIL, never fall
# through to a vacuous "GREEN" with zero gates run (a false-green is the one outcome this
# gate exists to prevent).
if ! [[ "$LO" =~ ^[0-9]+$ && "$HI" =~ ^[0-9]+$ ]] || (( LO > HI )); then
    echo "FAIL: KERNEL_VERIFY_LO/HI must be integers with LO<=HI (got LO='$LO' HI='$HI')." >&2
    exit 1
fi

# QEMU_PREFIX knob (2026-08-31, Ben-greenlit; same contract as native_codegen_oracle.sh): when set,
# $QEMU_PREFIX/bin must hold qemu-system-x86_64 and is prepended to PATH -- fail loud, never fall
# silently back to a system qemu. The gates re-apply it themselves via the sourced oracle; this block
# makes THIS script's own have_qemu/have_kvm probes and the banner see the same emulator.
if [[ -n "${QEMU_PREFIX:-}" ]]; then
    qp_bin="$QEMU_PREFIX/bin/qemu-system-x86_64"
    # -x alone is TRUE for a DIRECTORY and says nothing about the prefix being absolute, so a
    # prefix that passed it could still leave PATH lookup resolving to the system qemu 8.2.2 --
    # the exact silent downgrade this knob exists to retire (parent delta refutation panel,
    # 2026-09-02). Require a REGULAR executable file at an ABSOLUTE path: a relative prefix
    # installs a relative PATH entry that silently stops resolving after any `cd`.
    if [[ "$QEMU_PREFIX" != /* || ! -f "$qp_bin" || ! -x "$qp_bin" ]]; then
        echo "FAIL: QEMU_PREFIX='$QEMU_PREFIX' is set but $qp_bin is not an executable REGULAR FILE at an ABSOLUTE path -- refusing to fall back to a system qemu" >&2
        exit 1
    fi
    # A shell FUNCTION shadows PATH lookup entirely, so an inherited `export -f qemu-system-x86_64`
    # silently restored the system 8.2.2 while this guard reported success (Codex refutation leg,
    # 2026-09-02). Drop any such shadow, then PROVE the resolution instead of assuming it: the knob's
    # promise is that the PINNED binary runs, and only `command -v` after the prepend establishes it.
    unset -f qemu-system-x86_64 2>/dev/null || true
    export PATH="$QEMU_PREFIX/bin:$PATH"
    qp_res="$(command -v qemu-system-x86_64 || true)"
    if [[ "$qp_res" != "$qp_bin" ]]; then
        echo "FAIL: QEMU_PREFIX='$QEMU_PREFIX' is set but qemu-system-x86_64 resolves to '${qp_res:-<nothing>}', not '$qp_bin' -- refusing to fall back to a system qemu" >&2
        exit 1
    fi
    echo "kernel-verify: QEMU_PREFIX=$QEMU_PREFIX -> $(qemu-system-x86_64 --version | head -1)"
fi

have_qemu() { command -v qemu-system-x86_64 >/dev/null 2>&1; }
have_kvm()  { [[ -r /dev/kvm && -w /dev/kvm ]] && have_qemu; }   # mirrors the gate scripts

# --- the canonical kernel-arc gate set (what MUST exist -- a missing member inside the requested range is a
#     HARD failure, never the silent skip that yields a vacuous GREEN) --------------------------------------
#   * gate script     for every link 17..66
#   * mutation proof  for every link 18..66  (link17 predates the mutation-proof convention -- the ONE
#                     documented gate-only exception)
#   RANGE MOVED 65 -> 66 in link66's landing slice (longbuf, the 50th kernel-arc link). This line is
#   also the SCORECARD's range authority for its section 4 (tools/scorecard.sh reads the declaration
#   below out of this file's git HEAD blob), so until it moves the scorecard cannot see link66 and
#   NOTE TO ANYONE EDITING THIS COMMENT: the scorecard requires EXACTLY ONE occurrence each of the
#   two assignment strings in this whole file, so do not spell them out in prose -- writing them
#   here once broke section 4 outright (`declaration not unique: 2 assignment(s)`), which is a
#   uniqueness invariant doing its job on a comment that meant well.
#   reports 49 links with link65 as the newest -- which is why a landing that stops at the workflow
#   leaves the project's own progress authority telling the truth about the wrong tree.
GATE_LO=17; GATE_HI=66
mutation_expected() { local n="$1"; (( n >= 18 && n <= GATE_HI )); }

# --- which requested links carry a KVM real-silicon leg. An explicit MEMBER SET, NOT a contiguous range
#     (changed 2026-09-01): link39 (ouroboros) gained a KVM arm when its SINGLE-ENGINE overflow leg was
#     closed -- the A11 residual -- while links 40..43 still have none, so writing this as "39..65" would
#     OVER-CLAIM four links in the banner below. links 44..65 are the original tri-substrate members
#     (link62/taproot joined 2026-07-03). The KVM REQUIREMENT and the GREEN banner's KVM claim apply ONLY
#     when the requested range contains a MEMBER: a 17..18 smoke has none, so requiring or claiming KVM
#     there would be a false guarantee. A gate that GAINS a KVM leg is added here by number; never widen
#     this back into a range to make the arithmetic simpler.
#     RESIDUAL (cross-model Codex, 2026-07-03; unchanged in substance by the 2026-09-01 edit): this is a
#     MEMBERSHIP assumption, not per-gate proof -- kernel-verify verifies each member gate EXISTS + exits 0
#     (3a), but not that it actually ran its -enable-kvm leg. So a FUTURE gate silently dropping its KVM
#     branch while still exiting 0 would let the banner over-claim "+ KVM". Accepted for now: each gate's
#     KVM leg is byte-pinned in that gate, and this full run empirically REQUIRES KVM. Do NOT read
#     link39's own in-gate tripwire as closing this: that tripwire requires TWO ENGINES, not KVM, and
#     under REQUIRE_EMU=1 Bochs is already mandatory -- so tcg+bochs satisfies it and link39 could lose
#     its -enable-kvm arm entirely while this script still stamps "+ KVM (real silicon)". The residual
#     is unchanged in substance (blind Opus 5 finding 3, 2026-09-01). A stronger closure
#     (a machine-readable KVM-ran sentinel per gate, or a KERNEL_CODEGEN_REQUIRE_KVM=1 the member gates
#     honor) remains a future hardening, out of scope here. ---
KVM_LINKS="39 $(seq -s' ' 44 66)"
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

# --- KVM preflight: the real-silicon leg is REQUIRED when /dev/kvm exists AND the range has a KVM leg -----
if [[ "$range_has_kvm_leg" -eq 1 && -e /dev/kvm ]]; then
    if have_kvm; then
        echo "kernel-verify: /dev/kvm present + r/w and qemu-system-x86_64 available -- the KVM real-silicon leg is REQUIRED this run"
        echo "               (A11 tier-1; actual KVM acceleration runs when a member gate boots -enable-kvm -- links ${KVM_DESC})."
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
    echo "kernel-verify: requested range ${LO}..${HI} contains no KVM-leg link (KVM legs are links ${KVM_DESC}) -- QEMU-TCG + Bochs only, no KVM required or claimed."
fi

fail=0; ran=0; ran_mut=0
for n in $(seq "$LO" "$HI"); do
    (( n >= GATE_LO && n <= GATE_HI )) || continue   # kernel-verify runs ONLY the canonical kernel-arc set (17..66)
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
