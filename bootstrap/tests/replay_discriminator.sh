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
# RESIDUAL (tranche 1b, 2026-08-31; SCOPE CORRECTED 2026-09-02 -- was flatly "RESIDUAL PAID"):
# bash cannot see WIFSIGNALED through timeout(1) -- coreutils folds a signal death into a plain exit
# code -- so an EXTERNAL signal killing QEMU between the terminal debugcon write and the
# isa-debug-exit port write, with a folded rc colliding with a debug-exit encoding, was
# indistinguishable from a completed boot. The boot_qemu runner below preserves the wait status of
# THE PROCESS IT SPAWNS: a signal death is reported as SIGNAL:<n> in a status file (and rc 120, an
# even value no debug-exit encoding can produce) and qemu_classify refuses it as NO_COMPLETION
# whatever the folded rc would have been. (Original acceptance: Codex LAND-WITH-CHANGES item 1,
# 2026-07-17 -- no regression vs the pre-discriminator gates, which shared the collision.)
# WHAT THAT DOES AND DOES NOT COVER (parent delta refutation panel, 2026-09-02 -- the earlier
# unqualified "RESIDUAL PAID" line overclaimed, and is retired):
#   COVERED  the guest is boot_qemu's own child and dies on a signal, whether the runner survives
#            (SIGNAL:<n>, rc 120) or is reaped with it (status file absent -> NO_COMPLETION, added
#            2026-09-02). There are EIGHT boot_qemu call sites, not seven (an earlier draft of this
#            comment miscounted -- blind Opus 5 refuter finding 3, 2026-09-02): link37 x5 (247, 273,
#            295, 323, 346) and link39 x2 (145, 252) reach the verdict through qemu_classify below;
#            the eighth, run_native_codegen_link39_mutation.sh:93 (boot_once), reads the status file
#            ITSELF and carries the same missing-file test inline, added the same day.
#   NOT COVERED  a NON-exec wrapper interposed between the runner and qemu: the wrapper's OWN exit is
#            normal (128+n), so python3 sees a positive returncode and honestly records EXIT:137 --
#            no layer below the runner can be seen. An `exec`-style wrapper preserves the status
#            correctly; a plain one does not. Do NOT read this as "unreachable in practice": the
#            project's own documented QEMU_PREFIX knob IS a PATH-shim mechanism, and the guard above
#            requires only a REGULAR executable file, which a non-exec wrapper script satisfies --
#            demonstrated end to end (guard ACCEPTED the wrapper prefix, then a SIGKILLed guest
#            graded COMPLETED). Nothing in the tree ships such a wrapper (all eight sites invoke
#            qemu-system-x86_64 by bare name), but the honest statement is "$QEMU_PREFIX/bin/
#            qemu-system-x86_64 must be the real binary or an exec-style wrapper", which VERIFYING.md
#            now says. Named, not silently absorbed, and NOT closed by this packet.
ATT=""; ATT_SIG=""; ATT_HERR=""; ATT_CTX=""

# QEMU_PREFIX knob (2026-08-31): fail LOUD, never fall silently back to a system qemu.
# Inline (not a `source`) because this file defines no script_dir -- and because there is no shared
# helper to source: the 29 files that invoke qemu without sourcing an oracle each carry this same
# block inline, by decision (2026-09-01), so the bootstrap allowlist does not grow. (Gates that DO
# source native_codegen_oracle.sh inherit it from there.) Same contract as the oracle's copy.
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
fi
boot_qemu() { # timeout-secs statusfile cmd args... -> rc: EXIT:n -> n verbatim; TIMEOUT -> 124;
    # SIGNAL:s -> 120 (even -- never an isa-debug-exit encoding, so it can never classify COMPLETED).
    # The status-preserving boot runner (tranche 1b): subprocess sees the real wait status (negative
    # returncode = WIFSIGNALED), which timeout(1)+bash structurally cannot.
    local tmo="$1" sf="$2"; shift 2
    python3 - "$tmo" "$sf" "$@" <<'PY'
import subprocess, sys
tmo = int(sys.argv[1]); sf = sys.argv[2]; cmd = sys.argv[3:]
try:
    p = subprocess.run(cmd, timeout=tmo)
    rc = p.returncode
    if rc < 0:
        open(sf, 'w').write('SIGNAL:%d\n' % -rc); sys.exit(120)
    open(sf, 'w').write('EXIT:%d\n' % rc); sys.exit(rc & 0xFF)
except subprocess.TimeoutExpired:
    open(sf, 'w').write('TIMEOUT\n'); sys.exit(124)
PY
}

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

qemu_classify() { # rc debugcon qerr feedlog(""=no-feeder leg) [bootstatusfile] -> 0 iff COMPLETED (caller grades); else sets ATT and returns 1
    local rc="$1" out="$2" qerr="$3" flog="$4" bsf="${5:-}"
    if [[ -n "$bsf" ]]; then   # status-preserving runner verdict outranks the folded rc (tranche 1b)
        # A REQUESTED-but-ABSENT status file is NEVER a completion (parent delta refutation panel,
        # 2026-09-02): the previous guard was `[[ -n "$bsf" && -r "$bsf" ]]`, so a missing file
        # skipped the SIGNAL test entirely and a signal-killed boot fell through to the rc-parity
        # backstop -- which an odd folded rc (137 = 128+SIGKILL) passes -- and then graded COMPLETED
        # off a stale terminal DE..AD frame. Reachable whenever the RUNNER ITSELF is reaped: an
        # external sweeping `pkill -f ...qemu-system-x86_64...` matches the python3 runner's own
        # command line, which is exactly when its wait status is lost.
        # WHEN THE FILE IS ABSENT, precisely (blind Opus 5 refuter finding 2, 2026-09-02 -- an
        # earlier draft of this comment claimed boot_qemu "writes this file on every path it
        # survives", which is FALSE): boot_qemu writes it on every path where subprocess.run returns
        # or times out AND THE WRITE ITSELF SUCCEEDS. It does NOT write it when the runner is reaped
        # with the guest, nor when python3 raises -- either before the child runs (a nonexistent
        # command) or after it returns (a status path in a nonexistent directory: the guest ran, the
        # open() then failed). Both were demonstrated (rc=1, no file, a Python traceback /
        # FileNotFoundError on stderr; the second with the child's own stdout already printed, which
        # is why "subprocess.run returns" alone was the wrong line to draw -- corrected here by the
        # blind confirm leg, 2026-09-02). Every one of those is a broken harness, not a
        # boot, which is why absence is graded rather than trusted. A PROVEN launch failure keeps
        # its own diagnostic instead of being mislabelled a reaping.
        # UNCONDITIONAL, not gated on KERNEL_CODEGEN_REQUIRE_EMU, because run_qemu_leg already fails
        # closed on NO_COMPLETION exhaustion "regardless of KERNEL_CODEGEN_REQUIRE_EMU" -- gating it
        # would have been strictly weaker with nothing gained.
        if [[ ! -r "$bsf" ]]; then
            if [[ "$rc" -eq 1 && ! -s "$out" && -s "$qerr" ]]; then
                ATT=SETUP_FAILURE; ATT_HERR="QEMU launch error, no guest output AND no boot status file: $(head -1 "$qerr" | head -c 200)"
            else
                ATT=NO_COMPLETION; ATT_HERR="boot status file '$bsf' is missing or unreadable -- the status-preserving runner recorded no wait status, so nothing witnesses that this boot ENDED normally (the runner was reaped with the guest, or could not write the file); rc=$rc is then the folded status of a dead runner, not of the guest"
            fi
            return 1
        fi
        local bst; bst="$(head -1 "$bsf" 2>/dev/null)"
        if [[ "$bst" == SIGNAL:* ]]; then
            ATT=NO_COMPLETION; ATT_HERR="QEMU died on ${bst} (WIFSIGNALED, status-preserving boot runner) -- a signal death is never a completion witness, whatever exit code it would fold to"; return 1
        fi
    fi
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
