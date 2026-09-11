# Test-only cleanup with optional exact output retention. The ordinary rm still
# runs without retention unless the caller explicitly selects an evidence path.
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
    rm -rf -- "$@"
}
