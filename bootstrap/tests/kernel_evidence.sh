# Test-only kernel evidence: cleanup with optional exact output retention (the
# plain rm runs unless the caller selects an evidence path) and kernel_xvfb_capture.
kernel_test_record_boot() {
    [[ -n "${KERNEL_EVIDENCE_DIR:-}" ]] || return 0
    local directory="$1" raw="$2" kernel="$3" module="$4" file failed=0
    # Heap gates reuse sibling output names; place the completed attempt inside
    # their existing per-attempt directory before the next cleanup captures it.
    for file in "$raw" "$raw.qerr"; do
        if [[ -e "$file" ]]; then
            cp -T -- "$file" "$directory/${file##*/}" || failed=1
        fi
    done
    sha256sum -- "$kernel" "$module" > "$directory/BOOT-SHA256.txt" || failed=1
    if (( failed )); then
        echo "FAIL: could not retain completed boot $raw" >&2
        mkdir -p "$KERNEL_EVIDENCE_DIR" || true
        printf '%s\n' "$raw" >> "$KERNEL_EVIDENCE_DIR/CAPTURE-ERRORS.txt" || true
        exit 1
    fi
}

kernel_test_cleanup() {
    local original_status=${KERNEL_TEST_EXIT_STATUS:-$?}
    local directory
    for directory in "$@"; do
        if [[ -n "${KERNEL_EVIDENCE_DIR:-}" && -d "$directory" ]]; then
            if ! python3 "$kernel_evidence_helper_dir/kernel_evidence.py" "$directory" "$KERNEL_EVIDENCE_DIR"; then
                echo "FAIL: could not retain kernel evidence from $directory; preserving directory" >&2
                mkdir -p "$KERNEL_EVIDENCE_DIR" || true
                printf '%s\n' "$directory" >> "$KERNEL_EVIDENCE_DIR/CAPTURE-ERRORS.txt" || true
                # Abort even from EXIT traps or a caller about to reuse this path.
                (( original_status != 0 )) && exit "$original_status"
                exit 1
            fi
        fi
    done
    if [[ -n "${KERNEL_EVIDENCE_DIR:-}" && -s "$KERNEL_EVIDENCE_DIR/CAPTURE-ERRORS.txt" ]]; then
        echo "FAIL: a requested boot capture failed" >&2
        (( original_status != 0 )) && exit "$original_status"
        exit 1
    fi
    if [[ -n "${KERNEL_PARSE_ERROR_FILE:-}" && -s "$KERNEL_PARSE_ERROR_FILE" ]]; then
        echo "PARSER-ERROR: a malformed/ambiguous capture cannot certify a mutation" >&2
        cat "$KERNEL_PARSE_ERROR_FILE" >&2
        # This is also called from EXIT traps; force the gate red even when an
        # intentionally inverted mutation predicate consumed the Python failure.
        rm -rf -- "$@"
        exit 1
    fi
    rm -rf -- "$@"
}

# Bochs boots run under xvfb-run, which sends the wrapped command's stdout AND
# stderr to its own stdout ("$@" 2>&1, /usr/bin/xvfb-run:184 in xvfb
# 2:21.1.12-1ubuntu1.8) and prints its OWN diagnostics on stderr (error(),
# :35-37). One is "problem while cleaning up temporary directory" from its EXIT
# trap, which then exits 5 before it kills its Xvfb server (:85-92). A graded
# capture holds only the wrapped command's stream; the frame parser rightly
# refuses anything else (FLAKE-LOG F12). The wrapper's own diagnostics are host
# harness evidence: kept beside the capture as CAPTURE.xvfb-run.stderr, with
# xvfb-run's status in CAPTURE.xvfb-run.exit (so KERNEL_EVIDENCE_DIR snapshots
# retain both), and announced on stderr as a HARNESS-NOTE. They are never
# graded and never change a class or a verdict. The return status is
# xvfb-run's own, unchanged. An Xvfb still running from this boot directory is
# named in the note and never signalled. Keep this file self-contained: helper
# tests copy it alone into fixtures.
kernel_xvfb_capture() { # CAPTURE XVFB_RUN_ARGS...  -> xvfb-run's own exit status
    local capture="$1" side here pid pids="" text rc=0
    shift
    side="$capture.xvfb-run.stderr"
    xvfb-run "$@" > "$capture" 2> "$side" || rc=$?
    if [[ ! -s "$side" ]]; then
        rm -f -- "${side:?}"
        return "$rc"
    fi
    printf '%s\n' "$rc" > "$capture.xvfb-run.exit"
    here="$(pwd -P)"
    # Absolute in the note: a harness boot directory is removed moments later,
    # and the evidence snapshot's INVENTORY.json names it by this source path.
    [[ "$side" == /* ]] || side="$here/$side"
    for pid in $(pgrep -x Xvfb 2>/dev/null); do   # report only; nothing is signalled here
        if [[ "$(readlink "/proc/$pid/cwd" 2>/dev/null)" == "$here" ]]; then
            pids="$pids $pid"
        fi
    done
    text="$(head -c 300 -- "$side" | tr '\n' ' ')"
    echo "HARNESS-NOTE: ${0##*/}: xvfb-run exited $rc and wrote its own diagnostics; kept OUT of the graded capture, retained in $side (host harness evidence, not guest output, not graded): ${text% }${pids:+ -- Xvfb still running from this boot directory (not signalled):$pids}" >&2
    return "$rc"
}
