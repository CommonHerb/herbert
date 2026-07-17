# SAME-INPUT REPLAY DISCRIMINATOR -- shared QEMU-leg machinery (sourced, not executed).
# (parley, herbert 57262f7, landed on link40/link55; extended to the geeking/ouroboros QEMU legs
# 2026-07-17 -- tranche 1a of the fleet-wide sweep, audits/discriminator-sweep-2026-07-17/CHARTER.md,
# scoped + cross-model-reviewed by Codex, AGREE-WITH-CHANGES all adopted.)
#
# Every wrapped QEMU leg's input is CONSTANT (fixed fed bytes, fixed ref-built modules) and the kernel
# is byte-pinned by its gate's master pin, so re-running a COMPLETED-but-RED boot re-poses the EXACT
# same question: a deterministic same-input defect MUST recur (hard RED, both signatures printed); a
# one-shot serial-transport/debugcon capture miss does not (GREEN + a hedged FLAKE-DISCRIMINATED
# marker). Budget: ONE completed replay. This narrows the false-RED direction ONLY: it is NOT a receipt
# proof and does NOT rule out an intermittent same-input race -- the marker hedges accordingly.
#
# Tri-state attempt API (an attempt function NEVER calls fail_test and never touches pass/fail; only
# the driver adjudicates). An attempt sets ATT plus ATT_SIG/ATT_HERR/ATT_CTX and returns 0:
#   SETUP_FAILURE  -- proven pre-boot harness failure (feeder never LISTENING, so QEMU was never
#                     launched; or a QEMU launch error: rc 1 + zero guest output). Re-rolled;
#                     exhaustion FAILS CLOSED like every other class (the gate already SKIPs earlier
#                     when no emulator is present, so exhausting 4 setup attempts WITH QEMU present is
#                     a broken harness -- the pre-discriminator gates hard-failed this stimulus and a
#                     silent leg-skip that still prints PASS would be a fail-open regression).
#   NO_COMPLETION  -- the boot ran but produced no completion witness: rc 124 timeout; feeder never
#                     SENT (the leg's question was never posed); a non-debug-exit rc (even / signal
#                     death); or no terminal DE<answer>AD frame. AMBIGUOUS -- re-rolled boundedly, but
#                     exhaustion FAILS CLOSED regardless of REQUIRE_EMU (an emulator that launches but
#                     never completes is not provably a setup failure).
#   COMPLETED_GREEN / COMPLETED_RED -- rc is an isa-debug-exit encoding AND the debugcon carries the
#                     byte-aligned terminal DE<answer>AD frame (the geeking-family kernels guarantee
#                     module termination: kill/fault/exit all reach the emit tail -- empirically
#                     re-pinned 2026-07-17 on qemu 10.2.1). GREEN requires the leg's EXPECTED terminal
#                     rc (the T/G/P/K/F encodings) AND a GREEN grade; any other completed boot is RED.
# A COMPLETED RED whose same-input replay never completes is UNADJUDICATED -> FAILS CLOSED
# unconditionally, checked BEFORE the REQUIRE_EMU test (the parley teeth rule, link55): a completed RED
# that cannot be reproduced-or-refuted stays a failure. A replay may clear a RED ONLY against the SAME
# artifact bytes: every completed attempt records kernel+module hashes and the clearing GREEN must
# match attempt-1's (hash-freeze, fail closed on mismatch).
# KNOWN RESIDUAL (named; deferred to tranche 1b with a status-preserving python boot runner): bash
# cannot see WIFSIGNALED through timeout(1) -- coreutils folds a signal death into a plain exit code --
# so an EXTERNAL signal killing QEMU in the handful of instructions between the terminal debugcon
# write and the isa-debug-exit port write, with a signal number whose folded rc collides with a
# debug-exit encoding, is indistinguishable from a completed boot. Nothing in this harness signals
# QEMU, and the pre-discriminator gates accepted the same collision (rc+grade), so this is NO
# regression -- cross-model reviewed (Codex LAND-WITH-CHANGES item 1) and accepted 2026-07-17.
ATT=""; ATT_SIG=""; ATT_HERR=""; ATT_CTX=""

replay_capture_ctx() { # kernel-elf module-file -> 0 + ATT_CTX set, or ATT=SETUP_FAILURE + 1 if unhashable.
    # Called PRE-LAUNCH by every attempt fn (Codex delta review): hashing after the boot leaves a
    # TOCTOU window, and an unhashable artifact must refuse to boot rather than yield an empty --
    # and therefore trivially MATCHING -- identity string. Full sha256, no truncation.
    local ksha msha
    ksha=$(sha256sum "$1" 2>/dev/null | cut -d' ' -f1); msha=$(sha256sum "$2" 2>/dev/null | cut -d' ' -f1)
    if [[ -z "$ksha" || -z "$msha" ]]; then
        ATT=SETUP_FAILURE; ATT_HERR="artifact hash unobtainable (kernel or module file unreadable: $1 / $2) -- refusing to boot"; return 1
    fi
    ATT_CTX="kernel-sha256=$ksha module-sha256=$msha"
    return 0
}

replay_final_frame() { # debugcon-file -> 0 iff the stream ENDS with a byte-ALIGNED terminal DE<answer>AD frame
    # $-anchored: the DE<answer>AD emit tail is the FINAL debugcon write on every guaranteed-termination
    # path (kill/fault/exit all end emit-then-port-0xf4, nothing after -- empirically re-pinned on all
    # 12 leg streams, qemu 10.2.1), so a mid-stream stale frame in a truncated boot must NOT witness.
    xxd -p "$1" 2>/dev/null | tr -d '\n' | grep -qE '^([0-9a-f]{2})*de[0-9a-f]{2}ad$'
}

qemu_classify() { # rc debugcon qerr feedlog(""=no-feeder leg) -> 0 iff COMPLETED (caller grades); else sets ATT and returns 1
    local rc="$1" out="$2" qerr="$3" flog="$4"
    if [[ -n "$flog" ]] && ! grep -q SENT "$flog" 2>/dev/null; then
        ATT=NO_COMPLETION; ATT_HERR="feeder never logged SENT (COM1 never connected/delivered -- the leg's question was never posed) rc=$rc"; return 1
    fi
    if [[ "$rc" -eq 124 ]]; then
        ATT=NO_COMPLETION; ATT_HERR="60s timeout (rc 124) -- the boot never reached the isa-debug-exit tail"; return 1
    fi
    if (( rc % 2 == 0 )); then
        ATT=NO_COMPLETION; ATT_HERR="QEMU exited rc=$rc (not an isa-debug-exit encoding) -- no completion witness"; return 1
    fi
    if ! replay_final_frame "$out"; then
        if [[ "$rc" -eq 1 && ! -s "$out" && -s "$qerr" ]]; then   # rc 1 = QEMU's launch-error exit; rc alone is non-authoritative (Q7), so guest-output absence is required too
            ATT=SETUP_FAILURE; ATT_HERR="QEMU launch error with no guest output: $(head -1 "$qerr" | head -c 200)"
        else
            ATT=NO_COMPLETION; ATT_HERR="rc=$rc but no terminal DE..AD frame in the debugcon stream -- no completion witness (a signal-death rc collision or a capture miss)"
        fi
        return 1
    fi
    return 0
}

run_qemu_leg() { # legdesc outbase attempt_fn attempt_args...   (attempt_fn is called as: fn args... outfile)
    local legdesc="$1" outbase="$2" attempt_fn="$3"; shift 3
    local att state=idle a1sig="" a1ctx="" herr="none" nocomp=0
    for att in 1 2 3 4; do
        ATT=""; ATT_SIG=""; ATT_HERR=""; ATT_CTX=""
        "$attempt_fn" "$@" "$outbase.a$att"
        case "$ATT" in
        COMPLETED_GREEN)
            if [[ "$state" == replay ]]; then
                if [[ -z "$ATT_CTX" || "$ATT_CTX" != "$a1ctx" ]]; then
                    fail_test "$legdesc replay completed GREEN but the artifact identity does not match attempt-1 (attempt-1 [$a1ctx] vs replay [${ATT_CTX:-MISSING}]) -- hash-freeze violated, REFUSING to clear the completed RED (a RED may only be cleared against the SAME bytes; fail closed)"
                    return 1
                fi
                echo "  NOTE: $legdesc [FLAKE-DISCRIMINATED: a completed RED ($a1sig) did NOT recur under one same-input replay -- no deterministic same-input RED reproduced; classed a one-shot transport/capture miss, NOT proof against an intermittent same-input race]"
            fi
            return 0 ;;
        COMPLETED_RED)
            if [[ "$state" == replay ]]; then
                fail_test "$legdesc REPRODUCED under same-input replay -> hard RED: deterministic same-input kernel/substrate failure, not a one-shot transport miss (attempt-1: $a1sig [$a1ctx]; replay: $ATT_SIG [$ATT_CTX]; $(qemu-system-x86_64 --version 2>/dev/null | head -1))"
                return 1
            fi
            state=replay; a1sig="$ATT_SIG"; a1ctx="$ATT_CTX"
            echo "  REPLAY $legdesc: completed boot graded RED ($ATT_SIG) -- running ONE same-input replay (same-input discriminator: byte-pinned kernel + constant input; recurrence -> deterministic RED, non-recurrence -> transport/capture-class miss)" >&2 ;;
        NO_COMPLETION)
            nocomp=$((nocomp+1)); herr="$ATT_HERR"
            echo "  HARNESS ($legdesc attempt $att/4): $ATT_HERR -- re-rolling (no completion witness, NOT an adjudicated kernel grade; does not consume the replay budget)" >&2 ;;
        SETUP_FAILURE)
            herr="$ATT_HERR"
            echo "  HARNESS ($legdesc attempt $att/4): $ATT_HERR -- re-rolling (proven setup failure; QEMU never adjudicated)" >&2 ;;
        *)
            fail_test "$legdesc attempt function returned unknown state '${ATT:-UNSET}' -- harness contract violation, FAILED CLOSED immediately (a broken attempt API is a harness bug, not a retryable emulator ambiguity)"
            return 1 ;;
        esac
    done
    # exhausted the attempt budget. Order is load-bearing: UNADJUDICATED is checked BEFORE REQUIRE_EMU.
    if [[ "$state" == replay ]]; then
        fail_test "$legdesc completed RED ($a1sig; $a1ctx) but its same-input replay never completed within the attempt budget -- UNADJUDICATED completed RED, FAILED CLOSED (never cleared; a completed RED that cannot be reproduced-or-refuted stays a failure regardless of KERNEL_CODEGEN_REQUIRE_EMU)"
        return 1
    fi
    if [[ "$nocomp" -gt 0 ]]; then
        fail_test "$legdesc never produced a completed boot in 4 attempts (last: $herr) -- ambiguous no-completion exhaustion, FAILED CLOSED regardless of KERNEL_CODEGEN_REQUIRE_EMU (an emulator that launches but never completes is not provably a setup failure)"
        return 1
    fi
    fail_test "$legdesc exhausted 4 attempts on proven setup failures (last: $herr) -- FAILED CLOSED: with QEMU present a persistently failing feeder/launch is a broken harness, and skipping the leg while the gate prints PASS would be a fail-open regression vs the pre-discriminator gate (which hard-failed this stimulus on its first occurrence)"
    return 1
}
