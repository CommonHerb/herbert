# Test-only cleanup with optional exact output retention. The ordinary rm still
# runs without retention unless the caller explicitly selects an evidence path.
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
