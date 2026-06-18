#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERBERT="${HERBERT:-$SCRIPT_DIR/../../build/herbert}"

if [[ ! -x "$HERBERT" ]]; then
    echo "FAIL: smoke (cannot execute HERBERT=$HERBERT)" >&2
    exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0
total=0

check_limit() {
    local label="$1" metric="$2" max_file="$3" err="$4"
    [[ -f "$max_file" ]] || return 0

    local max actual
    max="$(tr -d '[:space:]' <"$max_file")"
    actual="$(awk -v metric="$metric" '$1 == metric":" && $2 ~ /^[0-9]+$/ {v=$2} END {print v}' "$err")"

    if [[ -z "$actual" ]]; then
        echo "FAIL: $label (missing $metric report)"
        return 1
    fi
    if (( actual > max )); then
        echo "FAIL: $label ($metric $actual exceeds max $max)"
        return 1
    fi
    return 0
}

for herb in "$SCRIPT_DIR"/test_*.herb; do
    total=$((total + 1))
    label="$(basename "$herb")"
    base="${herb%.herb}"
    expected="$base.expected"
    out="$tmp/$label.out"
    err="$tmp/$label.err"

    if [[ ! -f "$expected" ]]; then
        echo "FAIL: $label (missing expected file)"
        fail=$((fail + 1))
        continue
    fi

    env_args=()
    if [[ -f "$base.maxscopes" ]]; then
        env_args+=("HERBERT_REPORT_PEAK=1")
    fi
    if [[ -f "$base.maxheap" ]]; then
        env_args+=("HERBERT_REPORT_HEAP=1")
    fi

    if [[ ${#env_args[@]} -gt 0 ]]; then
        env "${env_args[@]}" "$HERBERT" "$herb" >"$out" 2>"$err" || rc=$?
    else
        "$HERBERT" "$herb" >"$out" 2>"$err" || rc=$?
    fi
    rc="${rc:-0}"

    if [[ "$rc" -ne 0 ]]; then
        echo "FAIL: $label (exit $rc)"
        sed -n '1,20p' "$err"
        fail=$((fail + 1))
        unset rc
        continue
    fi

    if ! diff -u "$expected" "$out"; then
        echo "FAIL: $label (output mismatch)"
        fail=$((fail + 1))
        unset rc
        continue
    fi

    if ! check_limit "$label" "peak-live-scopes" "$base.maxscopes" "$err"; then
        fail=$((fail + 1))
        unset rc
        continue
    fi
    if ! check_limit "$label" "peak-heap-bytes" "$base.maxheap" "$err"; then
        fail=$((fail + 1))
        unset rc
        continue
    fi

    echo "PASS: $label"
    pass=$((pass + 1))
    unset rc
done

if [[ "$fail" -ne 0 ]]; then
    echo "FAIL: smoke ($pass of $total passed, $fail failed)"
    exit 1
fi

echo "PASS: smoke ($pass of $total passed)"
