#!/usr/bin/env bash
# Deliberately recapture native-codegen Role-1 goldens from the live C bootstrap.
# This script is not called by make test.
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
HERBERT="${HERBERT:-$repo_root/build/herbert}"
backend="$repo_root/stack/native_compile_fragment.herb"
goldens_dir="$script_dir/native_codegen_goldens"

if [[ ! -x "$HERBERT" ]]; then
    echo "capture_native_goldens: cannot find herbert at $HERBERT" >&2
    exit 2
fi
if [[ ! -f "$backend" ]]; then
    echo "capture_native_goldens: missing backend $backend" >&2
    exit 2
fi

new_dir="$(mktemp -d)"
cleanup() {
    if [[ -n "${new_dir:-}" && -d "$new_dir" ]]; then
        rm -rf "$new_dir"
    fi
}
trap cleanup EXIT

mkdir -p "$new_dir/artifacts" "$new_dir/fixtures/link8"
manifest="$new_dir/manifest.tsv"
printf 'case_id\tscript\tprobe_label\tinput_label\tkind\texpected\tprobe_sha256\tinput_sha256\tc_transform\n' >"$manifest"

: >"$new_dir/fixtures/link8/i_empty"
head -c 65535 "$backend" >"$new_dir/fixtures/link8/i_65535"
head -c 65536 "$backend" >"$new_dir/fixtures/link8/i_65536"
head -c 65537 "$backend" >"$new_dir/fixtures/link8/i_65537"
head -c 100000 "$backend" >"$new_dir/fixtures/link8/i_100k"
head -c 5 "$backend" >"$new_dir/fixtures/link8/i_5"
cp "$backend" "$new_dir/fixtures/link8/i_src"

scripts=(
    run_native_codegen_link2.sh
    run_native_codegen_link3.sh
    run_native_codegen_link4.sh
    run_native_codegen_link5.sh
    run_native_codegen_link6.sh
    run_native_codegen_link7.sh
    run_native_codegen_link8.sh
    run_native_codegen_link9.sh
    run_native_codegen_link10.sh
    run_native_codegen_link11.sh
    run_native_codegen_link12.sh
    run_native_codegen_link13.sh
    run_native_codegen_link14.sh
    run_native_codegen_link15.sh
    run_native_codegen_link16.sh
    run_native_codegen_rejects.sh
)

for script in "${scripts[@]}"; do
    echo "capture_native_goldens: $script"
    HERBERT="$HERBERT" \
        NATIVE_CODEGEN_ORACLE=c \
        NATIVE_CODEGEN_ORACLE_CAPTURE=1 \
        NATIVE_CODEGEN_GOLDENS_DIR="$new_dir" \
        NATIVE_CODEGEN_CAPTURE_MANIFEST="$manifest" \
        bash "$script_dir/$script"
done

awk -F '\t' '
    NR == 1 { next }
    {
        key = $2 "/" $1
        if (seen[key]++) {
            printf("duplicate case id: %s\n", key) > "/dev/stderr"
            bad = 1
        }
    }
    END { exit bad ? 1 : 0 }
' "$manifest"

awk -F '\t' -v root="$new_dir" '
    NR == 1 { next }
    {
        path = root "/" $6
        if (system("[ -f \"" path "\" ]") != 0) {
            printf("missing artifact for %s/%s: %s\n", $2, $1, $6) > "/dev/stderr"
            bad = 1
        }
        count[$2]++
    }
    END {
        expected["link2"] = 21
        expected["link3"] = 19
        expected["link4"] = 11
        expected["link5"] = 11
        expected["link6"] = 13
        expected["link7"] = 9
        expected["link8"] = 13
        expected["link9"] = 24
        expected["link10"] = 1
        expected["link11"] = 6
        expected["link12"] = 2
        expected["link13"] = 5
        expected["link14"] = 10
        expected["link15"] = 8
        expected["link16"] = 3
        expected["rejects"] = 3
        for (script in expected) {
            if (count[script] != expected[script]) {
                printf("case count mismatch for %s: got %d expected %d\n", script, count[script], expected[script]) > "/dev/stderr"
                bad = 1
            }
        }
        exit bad ? 1 : 0
    }
' "$manifest"

old_dir=
if [[ -d "$goldens_dir" ]]; then
    old_dir="$(mktemp -d)"
    mv "$goldens_dir" "$old_dir/native_codegen_goldens.old"
fi
mv "$new_dir" "$goldens_dir"
new_dir=
if [[ -n "$old_dir" ]]; then
    rm -rf "$old_dir"
fi

echo "capture_native_goldens: wrote $goldens_dir"
