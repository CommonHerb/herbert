# Test-only kernel evidence: cleanup with optional exact output retention (the
# plain rm runs unless the caller selects an evidence path; it never removes a tree
# that still holds a live mount or loop backing file) and kernel_xvfb_capture.
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

# Never recursively remove a tree that still holds a live mount or an attached loop device's backing
# file (Astra R3, 2026-09-29). A Bochs disk build whose own cleanup failed leaves its boot directory in
# place as LEAKED, and that promise has to hold at the gate's final cleanup too: rm -rf does not stop at
# a mount point, and it unlinks an attached loop device's backing image. So before each recursive
# removal this checks whether a mount sits at or below the target (findmnt) or whether any loop device's
# backing file lies below it (losetup --list). Such a target is kept, one loud line on stderr names it
# and what is still live, and the other targets are removed as before. The gate's exit status does not
# change: a leaked mount from one attempt says nothing about the kernel, later attempts use fresh
# directories, and the kept tree and the line are the evidence. findmnt and losetup can exit nonzero
# when they find nothing, which is the normal case, and this runs in EXIT traps, some under set -e, so
# only their output is tested, never their exit status.
kernel_test_remove() { # TARGET... -- rm -rf each target, except one a live mount or loop backing file is in
    local target abs line entry live mounts loops device file
    mounts="$(findmnt -rn -o TARGET 2>/dev/null)" || mounts=""
    loops="$(losetup --list --noheadings --raw --output NAME,BACK-FILE 2>/dev/null)" || loops=""
    for target in "$@"; do
        live=""
        abs=""
        if [[ -d "$target" && ! -L "$target" ]]; then
            abs="$(unset CDPATH; cd -P -- "$target" 2>/dev/null && pwd -P)" || abs=""
        fi
        if [[ -n "$abs" ]]; then
            while IFS= read -r line; do
                if [[ -z "$line" ]]; then continue; fi
                entry="$(printf '%b' "$line")" || entry="$line"   # findmnt -r hex-escapes unsafe characters (\x20)
                if [[ "$entry" == "$abs" || "$entry" == "$abs"/* ]]; then live="$live mount $entry;"; fi
            done <<< "$mounts"
            while IFS=' ' read -r device file; do
                if [[ -z "$file" ]]; then continue; fi
                file="$(printf '%b' "$file")" || true
                file="${file% (deleted)}"
                if [[ "$file" == "$abs"/* ]]; then live="$live loop $device backing $file;"; fi
            done <<< "$loops"
        fi
        if [[ -n "$live" ]]; then
            echo "LEAKED: kernel_test_cleanup did NOT remove $target -- still live:${live%;} -- a disk build's mount or loop device outlived its attempt; the tree is kept as evidence, release it by hand before removing it (the gate's exit status is unchanged)" >&2
            continue
        fi
        rm -rf -- "$target"
    done
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
        kernel_test_remove "$@"
        exit 1
    fi
    kernel_test_remove "$@"
}

# Bochs boots run under xvfb-run, which sends the wrapped command's stdout to
# its own stdout. Where the command's stderr goes depends on the version: xvfb
# 2:21.1.12-1ubuntu1.8 (Ubuntu 24.04) runs it as `"$@" 2>&1`
# (/usr/bin/xvfb-run:184), merging it into xvfb-run's stdout, but xvfb
# 2:21.1.22-1ubuntu1.2 (Ubuntu 26.04, GitHub's ubuntu-26.04 runner) runs it as
# `"$@" 3>&-` (:200), leaving it on xvfb-run's stderr. Bochs writes its log
# lines and its exit banner ("... shutdown requested") on stderr, so this
# helper merges the command's stderr into its stdout itself and depends on
# neither: a shim between xvfb-run's options and the command,
# `sh -c 'exec "$@" 2>&1'`, which replaces itself with the command, so the
# process left running has the caller's own argv (`bash -c "<inner>"`), as
# scoped `pkill -f` patterns and bash's job reports expect. In both versions
# xvfb-run prints its OWN diagnostics on stderr (error(), :35-37). One is
# "problem while cleaning up temporary directory" from its EXIT trap, which
# then exits 5 before it kills its Xvfb server (:84-92). A graded capture
# holds only the wrapped command's stream; the frame parser rightly refuses
# anything else (FLAKE-LOG F12). The wrapper's own diagnostics are host harness
# evidence: kept beside the capture as CAPTURE.xvfb-run.stderr, with xvfb-run's
# status in CAPTURE.xvfb-run.exit (so KERNEL_EVIDENCE_DIR snapshots retain
# both), and announced on stderr as a HARNESS-NOTE. They are never graded and
# never change a class or a verdict. The return status is xvfb-run's own,
# unchanged. An Xvfb still running from this boot directory is named in the
# note and never signalled. The shim can go only between options known to take
# no argument and the command, so the only options accepted are -a and
# --auto-servernum; any other argument shape is refused with a HARNESS-ERROR on
# stderr and status 2, and nothing is run. A refused call also removes the
# capture. Removal needs a writable directory, not a writable file, so a stale
# capture there, read-only or not, is not left to be graded as this boot. A
# capture that cannot be removed (in a read-only directory) is emptied instead
# if it is writable, and either way a second HARNESS-ERROR names what is left.
# HF-01 residual: a capture that can be neither removed nor emptied, such as a
# read-only capture in a read-only directory, keeps its bytes. Callers act on
# neither status 2 nor that line: they classify and grade whatever capture
# they find, so they would grade those bytes as this boot. No current
# caller is refused: all 25 call sites pass CAPTURE -a bash -c ..., and each
# capture lies in a directory its gate or the harness made during the same
# run, under its own mktemp -d directory. (29 until 2026-09-29, when links 47,
# 62, 63 and 65 moved onto the shared harness's own call.)
# Keep this file self-contained: helper tests copy it alone into fixtures.
kernel_xvfb_capture() { # CAPTURE [-a|--auto-servernum]... COMMAND [ARG]...  -> xvfb-run's own exit status
    local capture="${1-}" side here pid pids="" text rc=0 got options=()
    if (( $# )); then shift; fi
    while (( $# )) && [[ "$1" == -a || "$1" == --auto-servernum ]]; do
        options+=("$1")
        shift
    done
    if [[ -z "$capture" || "$capture" == -* || $# -eq 0 || "$1" == -* ]]; then
        # Removed, not left alone: a stale capture must never be graded as this
        # boot. Callers grade whatever they find. Removal needs a writable
        # directory and emptying a writable file, so try both; neither failure
        # may stop the reports below, even under a caller's set -e.
        if [[ -n "$capture" && "$capture" != -* ]]; then
            rm -f -- "${capture:?}" || true
            if [[ -e "$capture" || -L "$capture" ]]; then
                if [[ -f "$capture" ]]; then : > "$capture" || true; fi
                if [[ -s "$capture" ]]; then
                    echo "HARNESS-ERROR: ${0##*/}: kernel_xvfb_capture could not remove the stale capture $capture or empty it; it is not this boot's output and must not be graded" >&2
                else
                    echo "HARNESS-ERROR: ${0##*/}: kernel_xvfb_capture could not remove the stale capture $capture; emptied it instead" >&2
                fi
            fi
        fi
        printf -v got ' %q' "$capture" "${options[@]}" "$@"
        echo "HARNESS-ERROR: ${0##*/}: kernel_xvfb_capture cannot place its stderr-merging shim in this argument list (want CAPTURE [-a|--auto-servernum]... COMMAND...); nothing was run; got:$got" >&2
        return 2
    fi
    side="$capture.xvfb-run.stderr"
    xvfb-run "${options[@]}" sh -c 'exec "$@" 2>&1' kernel_xvfb_capture "$@" > "$capture" 2> "$side" || rc=$?
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
