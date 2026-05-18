#!/usr/bin/env bash
# Run every test_*.herb in this directory through the interpreter and
# compare its stdout (byte for byte) against the matching .expected file.
# Stops after running all tests and exits non-zero if any failed.
set -u

cd "$(dirname "$0")"

HERBERT="${HERBERT:-$(pwd)/../../build/herbert}"
if [[ ! -x "$HERBERT" ]]; then
    echo "run_tests: cannot find herbert at $HERBERT" >&2
    exit 2
fi

fail=0
pass=0
total=0

shopt -s nullglob
for prog in test_*.herb; do
    total=$((total + 1))
    base="${prog%.herb}"
    expected="${base}.expected"
    if [[ ! -f "$expected" ]]; then
        echo "FAIL: $prog (missing $expected)"
        fail=$((fail + 1))
        continue
    fi
    actual=$(mktemp)
    err=$(mktemp)
    "$HERBERT" "$prog" >"$actual" 2>"$err"
    rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "FAIL: $prog (interpreter exit $rc)"
        echo "--- stderr"
        cat "$err"
        echo "--- stdout"
        cat "$actual"
        rm -f "$actual" "$err"
        fail=$((fail + 1))
        continue
    fi
    if ! diff -u "$expected" "$actual" >/tmp/herbert_diff.$$ 2>&1; then
        echo "FAIL: $prog (output mismatch)"
        cat /tmp/herbert_diff.$$
        rm -f /tmp/herbert_diff.$$ "$actual" "$err"
        fail=$((fail + 1))
        continue
    fi
    rm -f /tmp/herbert_diff.$$ "$actual" "$err"
    echo "PASS: $prog"
    pass=$((pass + 1))
done

echo
if [[ $fail -ne 0 ]]; then
    echo "$fail of $total test(s) failed."
    exit 1
fi
echo "$pass of $total test(s) passed."
exit 0
