#!/usr/bin/env bash
# link67 (folio, mutation) -- reduced ELF reservation must cause an explicit boot-input refusal.
set -euo pipefail
unset CDPATH
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || exit 1
exec bash "$script_dir/run_native_codegen_link67.sh" --mutation
