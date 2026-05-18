#!/usr/bin/env bash
# Run every test_*.herb in this directory through the interpreter and
# compare its stdout (byte for byte) against the matching .expected file.
# Also run every stack/*.herb that ships with a matching .expected file,
# so the Herbert-side artifacts under stack/ are exercised by the same
# suite. Stops after running all tests and exits non-zero if any failed.
#
# Bounded-memory regression check: each run sets HERBERT_REPORT_PEAK=1 so
# the interpreter emits "peak-live-scopes: N" on stderr. If the .herb's
# sibling .maxscopes file exists, its single integer is taken as an upper
# bound on N — the test fails if the bound is exceeded. This guards the
# tail-call frame-reclamation invariant: tail-recursive iteration must
# run in scope memory bounded by a small constant independent of depth.
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

run_one() {
    local prog="$1"
    local expected="$2"
    local label="$3"
    local actual err rc
    actual=$(mktemp)
    err=$(mktemp)
    HERBERT_REPORT_PEAK=1 "$HERBERT" "$prog" >"$actual" 2>"$err"
    rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "FAIL: $label (interpreter exit $rc)"
        echo "--- stderr"
        cat "$err"
        echo "--- stdout"
        cat "$actual"
        rm -f "$actual" "$err"
        return 1
    fi
    if ! diff -u "$expected" "$actual" >/tmp/herbert_diff.$$ 2>&1; then
        echo "FAIL: $label (output mismatch)"
        cat /tmp/herbert_diff.$$
        rm -f /tmp/herbert_diff.$$ "$actual" "$err"
        return 1
    fi
    rm -f /tmp/herbert_diff.$$ "$actual"
    local maxfile="${prog%.herb}.maxscopes"
    if [[ -f "$maxfile" ]]; then
        local bound peak
        bound=$(tr -d '[:space:]' < "$maxfile")
        peak=$(awk '/^peak-live-scopes: [0-9]+$/ {print $2}' "$err")
        rm -f "$err"
        if [[ -z "$peak" ]]; then
            echo "FAIL: $label (no peak-live-scopes reported)"
            return 1
        fi
        if (( peak > bound )); then
            echo "FAIL: $label (peak-live-scopes $peak > bound $bound)"
            return 1
        fi
        echo "PASS: $label (peak-live-scopes $peak <= $bound)"
        return 0
    fi
    rm -f "$err"
    echo "PASS: $label"
    return 0
}

shopt -s nullglob
for prog in test_*.herb; do
    total=$((total + 1))
    expected="${prog%.herb}.expected"
    if [[ ! -f "$expected" ]]; then
        echo "FAIL: $prog (missing $expected)"
        fail=$((fail + 1))
        continue
    fi
    if run_one "$prog" "$expected" "$prog"; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
    fi
done

if [[ -d ../../stack ]]; then
    STACK_DIR="$(cd ../../stack && pwd)"
    for prog in "$STACK_DIR"/*.herb; do
        # lexer_probe.herb is DATA, not a program: its bytes are the input
        # to the lexer fragment's forcing-function test (run below).
        if [[ "$(basename "$prog" .herb)" == "lexer_probe" ]]; then
            continue
        fi
        expected="${prog%.herb}.expected"
        [[ -f "$expected" ]] || continue
        total=$((total + 1))
        label="stack/$(basename "$prog")"
        if run_one "$prog" "$expected" "$label"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    done

    # Lexer forcing-function test: run the lexer fragment, which has an
    # embedded byte-for-byte copy of lexer_probe.herb in its main(), and
    # diff its canonical token output against the hand-authored answer
    # key in lexer_probe.expected. The expected file is independent of
    # any lexer implementation, so this test pins the fragment against a
    # genuine oracle.
    LEX_DRIVER="$STACK_DIR/lexer_fragment.herb"
    LEX_PROBE_EXPECTED="$STACK_DIR/lexer_probe.expected"
    if [[ -f "$LEX_DRIVER" && -f "$LEX_PROBE_EXPECTED" ]]; then
        total=$((total + 1))
        if run_one "$LEX_DRIVER" "$LEX_PROBE_EXPECTED" \
                "stack/lexer_probe (driver: lexer_fragment.herb)"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi
fi

echo
if [[ $fail -ne 0 ]]; then
    echo "$fail of $total test(s) failed."
    exit 1
fi
echo "$pass of $total test(s) passed."
exit 0
