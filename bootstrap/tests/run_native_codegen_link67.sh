#!/usr/bin/env bash
# link67 (folio, raw boot-file input) -- exact bytes, bounded metadata and loader reservation.
set -euo pipefail
unset CDPATH PYTHONPATH PYTHONHOME PYTHONSTARTUP
export PYTHONNOUSERSITE=1
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || exit 1
repo_root="$(cd -- "$script_dir/../.." && pwd)" || exit 1
source "$script_dir/native_codegen_oracle.sh" || exit 1
backend="$repo_root/stack/native_compile_fragment.herb"
mode=normal
if [[ "${1:-}" == "--mutation" && $# == 1 ]]; then mode=mutation
elif [[ $# != 0 ]]; then echo "FAIL: link67: unexpected arguments" >&2; exit 1; fi
tmp="$(mktemp -d)"
cleanup() {
    local status=$?
    # A failed/interrupted disk build may still own a mount or loop device.
    # Preserve its tree; the shared capture helper never follows mounts.
    if [[ -f "$tmp/PRESERVE" ]]; then
        echo "FAIL: incomplete Bochs disk build; preserving $tmp" >&2
        if [[ -n "${KERNEL_EVIDENCE_DIR:-}" ]]; then
            python3 "$script_dir/kernel_evidence.py" "$tmp" "$KERNEL_EVIDENCE_DIR" || exit 1
        fi
        (( status != 0 )) || status=1
        exit "$status"
    fi
    KERNEL_TEST_EXIT_STATUS=$status kernel_test_cleanup "$tmp"
}
trap cleanup EXIT
native_codegen_ensure_compiler "$tmp/mint"
# The declaration is passed to the checker and used in every generated probe.
emit_header='-- emit: multiboot32-long64'
python3 -I "$script_dir/check_boot_input.py" --mode "$mode" \
    --compiler "$NATIVE_CODEGEN_COMPILER" --work "$tmp" --emit-header="$emit_header"
