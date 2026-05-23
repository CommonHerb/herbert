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
SLOPE_TOL_NUM=3
SLOPE_TOL_DEN=2
test_14a_heap=
test_14b_heap=

run_one() {
    local prog="$1"
    local expected="$2"
    local label="$3"
    local actual err rc
    actual=$(mktemp)
    err=$(mktemp)
    HERBERT_REPORT_PEAK=1 HERBERT_REPORT_HEAP=1 "$HERBERT" "$prog" >"$actual" 2>"$err"
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
    local maxheapfile="${prog%.herb}.maxheap"
    local peak heap detail base
    peak=$(awk '/^peak-live-scopes: [0-9]+$/ {print $2}' "$err")
    heap=$(awk '/^peak-heap-bytes: [0-9]+$/ {print $2}' "$err")
    base="$(basename "$prog")"
    case "$base" in
        test_14a_bounded_heap.herb) test_14a_heap="$heap" ;;
        test_14b_bounded_heap.herb) test_14b_heap="$heap" ;;
    esac
    detail=
    if [[ -f "$maxfile" ]]; then
        local bound
        bound=$(tr -d '[:space:]' < "$maxfile")
        if [[ -z "$peak" ]]; then
            echo "FAIL: $label (no peak-live-scopes reported)"
            rm -f "$err"
            return 1
        fi
        if (( peak > bound )); then
            echo "FAIL: $label (peak-live-scopes $peak > bound $bound)"
            rm -f "$err"
            return 1
        fi
        detail="peak-live-scopes $peak <= $bound"
    fi
    if [[ -f "$maxheapfile" ]]; then
        local heap_bound
        heap_bound=$(tr -d '[:space:]' < "$maxheapfile")
        if [[ -z "$heap" ]]; then
            echo "FAIL: $label (no peak-heap-bytes reported)"
            rm -f "$err"
            return 1
        fi
        if (( heap > heap_bound )); then
            echo "FAIL: $label (peak-heap-bytes $heap > bound $heap_bound)"
            rm -f "$err"
            return 1
        fi
        detail="${detail}${detail:+; }peak-heap-bytes $heap <= $heap_bound"
    fi
    rm -f "$err"
    if [[ -n "$detail" ]]; then
        echo "PASS: $label ($detail)"
    else
        echo "PASS: $label"
    fi
    return 0
}

decode_canonical_string() {
    local input="$1"
    perl -0777 -ne '
        my $s = $_;
        $s =~ s/\n\z//;
        exit 1 unless $s =~ /\A"(.*)"\z/s;
        $s = $1;
        $s =~ s/\\([n\\"])/$1 eq "n" ? "\n" : $1/ge;
        print $s;
    ' "$input"
}

write_klondike_emitter_driver() {
    local source="$1"
    local out="$2"
    awk '/^func main\(\):$/ { exit } { print }' "$source" >"$out"
    cat >>"$out" <<'HERBERT_KLONDIKE_EMITTER_MAIN'
func main():
    let probe = clogger()
    let tokens = lex_source(probe)
    let nodes = pool_new()
    let parsed = parse_program(tokens, 0, nodes)
    let prog = lower_program(nodes, parsed.0)
    return serialize_bytecode(prog)
end
HERBERT_KLONDIKE_EMITTER_MAIN
}

diagnostic_message() {
    local code="$1"
    local payload="${2:-}"
    case "$code" in
        101) printf 'unexpected character' ;;
        102) printf 'expected digit' ;;
        103) printf 'integer literal does not fit in 64 bits' ;;
        104) printf 'unknown escape sequence' ;;
        105) printf 'unterminated escape' ;;
        106) printf 'newline in string literal' ;;
        107) printf 'unterminated string literal' ;;
        108) printf 'empty character literal' ;;
        109) printf 'character literal not closed' ;;
        110) printf 'newline in character literal' ;;
        201) printf "expected 'func' at top level" ;;
        202) printf 'invalid function header' ;;
        203) printf 'expected end' ;;
        204) printf 'expected expression' ;;
        205) printf "'do' must be followed by a call" ;;
        206) printf "expected integer after '.'" ;;
        207) printf "expected ')'" ;;
        208) printf 'new_array requires a type argument' ;;
        209) printf 'function body must contain at least one statement' ;;
        210) printf 'if/elif/else arm must contain at least one statement' ;;
        211) printf 'invalid type expression' ;;
        212) printf 'invalid assignment or name' ;;
        301) printf "duplicate let '%s' in this scope" "$payload" ;;
        302) printf "undefined name '%s'" "$payload" ;;
        303) printf "assignment to undefined name '%s'" "$payload" ;;
        304) printf "unknown function '%s'" "$payload" ;;
        305) printf "wrong number of arguments to '%s'" "$payload" ;;
        306) printf "wrong number of arguments to '%s'" "$payload" ;;
        307) printf "wrong number of arguments to '%s'" "$payload" ;;
        308) printf "builtin '%s' has no value" "$payload" ;;
        310) printf "'do' requires a value-less call, got '%s'" "$payload" ;;
        311) printf "duplicate parameter '%s'" "$payload" ;;
        312) printf "duplicate function '%s'" "$payload" ;;
        313) printf "function reuses built-in name '%s'" "$payload" ;;
        314) printf 'no main function defined' ;;
        315) printf "function '%s' must take zero parameters" "$payload" ;;
        316) printf "function '%s' may complete without returning" "$payload" ;;
        *) printf 'unknown error' ;;
    esac
}

bootstrap_line() {
    local err_file="$1"
    perl -ne 'if (/^herbert: line ([0-9]+):/) { print $1; exit }' "$err_file"
}

bootstrap_payload() {
    local code="$1"
    local err_file="$2"
    case "$code" in
        301|302|303|304|305|308|311|312|313|315|316)
            perl -ne 'if (/'\''([^'\'']*)'\''/) { print $1; exit }' "$err_file"
            ;;
        310)
            perl -ne 'while (/'\''([^'\'']*)'\''/g) { $last = $1 } END { print $last if defined $last }' "$err_file"
            ;;
        306|307)
            perl -ne 'if (/^herbert: line [0-9]+: ([^:]+):/) { print $1; exit }' "$err_file"
            ;;
        *)
            printf ''
            ;;
    esac
}

write_expected_diagnostic() {
    local code="$1"
    local line="$2"
    local payload="$3"
    local out="$4"
    local message
    message="$(diagnostic_message "$code" "$payload")"
    if [[ -n "$line" ]]; then
        printf 'line %s: %s (ERR %s)\n0\n' "$line" "$message" "$code" >"$out"
    else
        printf 'program: %s (ERR %s)\n0\n' "$message" "$code" >"$out"
    fi
}

write_herbert_bundle() {
    local src="$1"
    local input="$2"
    local out="$3"
    python3 - "$src" "$input" "$out" <<'PY'
import sys

src = open(sys.argv[1], "rb").read()
inp = open(sys.argv[2], "rb").read()
with open(sys.argv[3], "wb") as out:
    out.write(b"\x00HERB1" + str(len(src)).encode() + b"\n" + src + inp)
PY
}

normalize_klondike_driver_output() {
    local input="$1"
    local output="$2"
    local prefix quoted decoded
    prefix=$(mktemp)
    quoted=$(mktemp)
    decoded=$(mktemp)

    sed '$d' "$input" >"$prefix"
    tail -n 1 "$input" >"$quoted"
    if ! decode_canonical_string "$quoted" >"$decoded"; then
        rm -f "$prefix" "$quoted" "$decoded"
        return 1
    fi
    cat "$prefix" "$decoded" >"$output"
    printf '\n' >>"$output"
    rm -f "$prefix" "$quoted" "$decoded"
    return 0
}

run_klondike_bundle_diff() {
    local label="$1"
    local probe="$2"
    local payload="$3"
    local mode="$4"
    local driver="$5"
    local inner middle outer driver_input oracle_display oracle actual raw_actual oracle_err err rc peak heap detail
    total=$((total + 1))
    inner=$(mktemp)
    middle=$(mktemp)
    outer=$(mktemp)
    oracle_display=$(mktemp)
    oracle=$(mktemp)
    actual=$(mktemp)
    raw_actual=$(mktemp)
    oracle_err=$(mktemp)
    err=$(mktemp)

    if ! write_herbert_bundle "$probe" "$payload" "$inner"; then
        echo "FAIL: $label (bundle build failed)"
        fail=$((fail + 1))
        rm -f "$inner" "$middle" "$outer" "$oracle_display" "$oracle" "$actual" "$raw_actual" "$oracle_err" "$err"
        return
    fi

    case "$mode" in
        preflight)
            driver_input="$inner"
            ;;
        nested)
            if ! write_herbert_bundle "$driver" "$inner" "$outer"; then
                echo "FAIL: $label (outer bundle build failed)"
                fail=$((fail + 1))
                rm -f "$inner" "$middle" "$outer" "$oracle_display" "$oracle" "$actual" "$raw_actual" "$oracle_err" "$err"
                return
            fi
            driver_input="$outer"
            ;;
        triple)
            if ! write_herbert_bundle "$driver" "$inner" "$middle"; then
                echo "FAIL: $label (middle bundle build failed)"
                fail=$((fail + 1))
                rm -f "$inner" "$middle" "$outer" "$oracle_display" "$oracle" "$actual" "$raw_actual" "$oracle_err" "$err"
                return
            fi
            if ! write_herbert_bundle "$driver" "$middle" "$outer"; then
                echo "FAIL: $label (outer bundle build failed)"
                fail=$((fail + 1))
                rm -f "$inner" "$middle" "$outer" "$oracle_display" "$oracle" "$actual" "$raw_actual" "$oracle_err" "$err"
                return
            fi
            driver_input="$outer"
            ;;
        *)
            echo "FAIL: $label (unknown bundle mode $mode)"
            fail=$((fail + 1))
            rm -f "$inner" "$middle" "$outer" "$oracle_display" "$oracle" "$actual" "$raw_actual" "$oracle_err" "$err"
            return
            ;;
    esac

    HERBERT_REPORT_PEAK=1 HERBERT_REPORT_HEAP=1 "$HERBERT" "$probe" <"$payload" >"$oracle_display" 2>"$oracle_err"
    rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "FAIL: $label (oracle exit $rc)"
        echo "--- oracle stderr"
        cat "$oracle_err"
        echo "--- oracle stdout"
        cat "$oracle_display"
        fail=$((fail + 1))
        rm -f "$inner" "$middle" "$outer" "$oracle_display" "$oracle" "$actual" "$raw_actual" "$oracle_err" "$err"
        return
    fi
    tr -d ',' <"$oracle_display" >"$oracle"

    HERBERT_REPORT_PEAK=1 HERBERT_REPORT_HEAP=1 "$HERBERT" "$driver" <"$driver_input" >"$actual" 2>"$err"
    rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "FAIL: $label (interpreter exit $rc)"
        echo "--- stderr"
        cat "$err"
        echo "--- stdout"
        cat "$actual"
        fail=$((fail + 1))
        rm -f "$inner" "$middle" "$outer" "$oracle_display" "$oracle" "$actual" "$raw_actual" "$oracle_err" "$err"
        return
    fi

    if ! normalize_klondike_driver_output "$actual" "$raw_actual"; then
        echo "FAIL: $label (expected canonical string result)"
        echo "--- stdout"
        cat "$actual"
        fail=$((fail + 1))
        rm -f "$inner" "$middle" "$outer" "$oracle_display" "$oracle" "$actual" "$raw_actual" "$oracle_err" "$err"
        return
    fi

    if ! cmp -s "$oracle" "$raw_actual"; then
        echo "FAIL: $label (output mismatch)"
        diff -u "$oracle" "$raw_actual" || true
        fail=$((fail + 1))
        rm -f "$inner" "$middle" "$outer" "$oracle_display" "$oracle" "$actual" "$raw_actual" "$oracle_err" "$err"
        return
    fi

    if [[ "$mode" == "nested" || "$mode" == "triple" ]]; then
        peak=$(awk '/^peak-live-scopes: [0-9]+$/ {v=$2} END {print v}' "$err")
        heap=$(awk '/^peak-heap-bytes: [0-9]+$/ {v=$2} END {print v}' "$err")
        detail=
        [[ -n "$peak" ]] && detail="peak-live-scopes $peak"
        [[ -n "$heap" ]] && detail="${detail}${detail:+; }peak-heap-bytes $heap"
        if [[ -n "$detail" ]]; then
            echo "PASS: $label ($detail)"
        else
            echo "PASS: $label"
        fi
    else
        echo "PASS: $label"
    fi
    pass=$((pass + 1))
    rm -f "$inner" "$middle" "$outer" "$oracle_display" "$oracle" "$actual" "$raw_actual" "$oracle_err" "$err"
}

run_klondike_medium_case() {
    local label="$1"
    local probe="$2"
    local payload="$3"
    local driver="$4"
    local timeout_s="$5"
    local inner outer oracle_display oracle actual raw_actual oracle_err err rc start_s end_s
    KLONDIKE_MEDIUM_HEAP=
    KLONDIKE_MEDIUM_SCOPES=
    KLONDIKE_MEDIUM_WALL=
    inner=$(mktemp)
    outer=$(mktemp)
    oracle_display=$(mktemp)
    oracle=$(mktemp)
    actual=$(mktemp)
    raw_actual=$(mktemp)
    oracle_err=$(mktemp)
    err=$(mktemp)

    if ! write_herbert_bundle "$probe" "$payload" "$inner"; then
        echo "FAIL: $label (bundle build failed)"
        rm -f "$inner" "$outer" "$oracle_display" "$oracle" "$actual" "$raw_actual" "$oracle_err" "$err"
        return 1
    fi
    if ! write_herbert_bundle "$driver" "$inner" "$outer"; then
        echo "FAIL: $label (outer bundle build failed)"
        rm -f "$inner" "$outer" "$oracle_display" "$oracle" "$actual" "$raw_actual" "$oracle_err" "$err"
        return 1
    fi

    timeout "$timeout_s" env HERBERT_REPORT_PEAK=1 HERBERT_REPORT_HEAP=1 "$HERBERT" "$probe" <"$payload" >"$oracle_display" 2>"$oracle_err"
    rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "FAIL: $label (oracle exit $rc)"
        echo "--- oracle stderr"
        cat "$oracle_err"
        echo "--- oracle stdout"
        cat "$oracle_display"
        rm -f "$inner" "$outer" "$oracle_display" "$oracle" "$actual" "$raw_actual" "$oracle_err" "$err"
        return 1
    fi
    tr -d ',' <"$oracle_display" >"$oracle"

    start_s=$(date +%s)
    timeout "$timeout_s" env HERBERT_REPORT_PEAK=1 HERBERT_REPORT_HEAP=1 "$HERBERT" "$driver" <"$outer" >"$actual" 2>"$err"
    rc=$?
    end_s=$(date +%s)
    KLONDIKE_MEDIUM_WALL=$((end_s - start_s))
    if [[ $rc -ne 0 ]]; then
        echo "FAIL: $label (interpreter exit $rc)"
        echo "--- stderr"
        cat "$err"
        echo "--- stdout"
        cat "$actual"
        rm -f "$inner" "$outer" "$oracle_display" "$oracle" "$actual" "$raw_actual" "$oracle_err" "$err"
        return 1
    fi
    if ! normalize_klondike_driver_output "$actual" "$raw_actual"; then
        echo "FAIL: $label (expected canonical string result)"
        echo "--- stdout"
        cat "$actual"
        rm -f "$inner" "$outer" "$oracle_display" "$oracle" "$actual" "$raw_actual" "$oracle_err" "$err"
        return 1
    fi
    if ! cmp -s "$oracle" "$raw_actual"; then
        echo "FAIL: $label (output mismatch)"
        diff -u "$oracle" "$raw_actual" || true
        rm -f "$inner" "$outer" "$oracle_display" "$oracle" "$actual" "$raw_actual" "$oracle_err" "$err"
        return 1
    fi

    KLONDIKE_MEDIUM_SCOPES=$(awk '/^peak-live-scopes: [0-9]+$/ {v=$2} END {print v}' "$err")
    KLONDIKE_MEDIUM_HEAP=$(awk '/^peak-heap-bytes: [0-9]+$/ {v=$2} END {print v}' "$err")
    if [[ -z "$KLONDIKE_MEDIUM_SCOPES" ]]; then
        echo "FAIL: $label (no peak-live-scopes reported)"
        rm -f "$inner" "$outer" "$oracle_display" "$oracle" "$actual" "$raw_actual" "$oracle_err" "$err"
        return 1
    fi
    if [[ -z "$KLONDIKE_MEDIUM_HEAP" ]]; then
        echo "FAIL: $label (no peak-heap-bytes reported)"
        rm -f "$inner" "$outer" "$oracle_display" "$oracle" "$actual" "$raw_actual" "$oracle_err" "$err"
        return 1
    fi

    rm -f "$inner" "$outer" "$oracle_display" "$oracle" "$actual" "$raw_actual" "$oracle_err" "$err"
    return 0
}

run_klondike_medium_guard() {
    local driver="$1"
    local large_probe="$2"
    local small_probe="$3"
    local label="stack/beta-full medium guard (driver: klondike.herb, nested)"
    local timeout_s="${BETA_MEDIUM_TIMEOUT:-240s}"
    local scope_cap=64
    local heap_cap=45000000
    local slope_num=2
    local slope_den=1
    local large_payload small_payload large_heap large_scopes large_wall small_heap small_scopes small_wall
    total=$((total + 1))
    large_payload=$(mktemp)
    small_payload=$(mktemp)
    : >"$large_payload"
    printf '5' >"$small_payload"

    if ! run_klondike_medium_case "$label/evaluator_probe" "$large_probe" "$large_payload" "$driver" "$timeout_s"; then
        fail=$((fail + 1))
        rm -f "$large_payload" "$small_payload"
        return
    fi
    large_heap="$KLONDIKE_MEDIUM_HEAP"
    large_scopes="$KLONDIKE_MEDIUM_SCOPES"
    large_wall="$KLONDIKE_MEDIUM_WALL"

    if ! run_klondike_medium_case "$label/metacircular_compute_probe" "$small_probe" "$small_payload" "$driver" "$timeout_s"; then
        fail=$((fail + 1))
        rm -f "$large_payload" "$small_payload"
        return
    fi
    small_heap="$KLONDIKE_MEDIUM_HEAP"
    small_scopes="$KLONDIKE_MEDIUM_SCOPES"
    small_wall="$KLONDIKE_MEDIUM_WALL"
    rm -f "$large_payload" "$small_payload"

    if (( large_scopes > scope_cap )); then
        echo "FAIL: $label (evaluator peak-live-scopes $large_scopes > $scope_cap)"
        fail=$((fail + 1))
    elif (( small_scopes > scope_cap )); then
        echo "FAIL: $label (compute peak-live-scopes $small_scopes > $scope_cap)"
        fail=$((fail + 1))
    elif (( large_heap > heap_cap )); then
        echo "FAIL: $label (evaluator peak-heap-bytes $large_heap > $heap_cap)"
        fail=$((fail + 1))
    elif (( small_heap > heap_cap )); then
        echo "FAIL: $label (compute peak-heap-bytes $small_heap > $heap_cap)"
        fail=$((fail + 1))
    elif (( large_heap * slope_den > small_heap * slope_num )); then
        echo "FAIL: $label (heap slope $large_heap > 2.0 * $small_heap)"
        fail=$((fail + 1))
    else
        echo "PASS: $label (evaluator heap $large_heap, scopes $large_scopes, wall ${large_wall}s; compute heap $small_heap, scopes $small_scopes, wall ${small_wall}s; slope <= 2.0)"
        pass=$((pass + 1))
    fi
}

run_suke_diff() {
    local label="$1"
    local probe="$2"
    local driver="$3"
    local payload="$4"
    local oracle actual oracle_err err rc
    total=$((total + 1))
    oracle=$(mktemp)
    actual=$(mktemp)
    oracle_err=$(mktemp)
    err=$(mktemp)

    HERBERT_REPORT_PEAK=1 "$HERBERT" "$probe" <"$payload" >"$oracle" 2>"$oracle_err"
    rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "FAIL: $label (oracle exit $rc)"
        echo "--- oracle stderr"
        cat "$oracle_err"
        echo "--- oracle stdout"
        cat "$oracle"
        fail=$((fail + 1))
        rm -f "$oracle" "$actual" "$oracle_err" "$err"
        return
    fi

    HERBERT_REPORT_PEAK=1 "$HERBERT" "$driver" <"$payload" >"$actual" 2>"$err"
    rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "FAIL: $label (interpreter exit $rc)"
        echo "--- stderr"
        cat "$err"
        echo "--- stdout"
        cat "$actual"
        fail=$((fail + 1))
        rm -f "$oracle" "$actual" "$oracle_err" "$err"
        return
    fi

    if ! cmp -s "$oracle" "$actual"; then
        echo "FAIL: $label (output mismatch)"
        cmp -l "$oracle" "$actual" || true
        fail=$((fail + 1))
        rm -f "$oracle" "$actual" "$oracle_err" "$err"
        return
    fi

    echo "PASS: $label"
    pass=$((pass + 1))
    rm -f "$oracle" "$actual" "$oracle_err" "$err"
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

if [[ -n "$test_14a_heap" || -n "$test_14b_heap" ]]; then
    total=$((total + 1))
    if [[ -z "$test_14a_heap" || -z "$test_14b_heap" ]]; then
        echo "FAIL: test_14 heap slope (missing heap measurement)"
        fail=$((fail + 1))
    elif (( test_14b_heap * SLOPE_TOL_DEN > test_14a_heap * SLOPE_TOL_NUM )); then
        echo "FAIL: test_14 heap slope ($test_14b_heap > 1.5 * $test_14a_heap)"
        fail=$((fail + 1))
    else
        echo "PASS: test_14 heap slope ($test_14b_heap <= 1.5 * $test_14a_heap)"
        pass=$((pass + 1))
    fi
fi

if [[ -d ../../stack ]]; then
    STACK_DIR="$(cd ../../stack && pwd)"
    for prog in "$STACK_DIR"/*.herb; do
        # lexer_probe.herb and parser_probe.herb are DATA, not programs:
        # their bytes are the input to the corresponding fragment's
        # forcing-function test (run explicitly below).
        case "$(basename "$prog" .herb)" in
            lexer_probe|parser_probe|evaluator_probe) continue ;;
        esac
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

    # Parser forcing-function test: run the parser fragment, which has
    # an embedded byte-for-byte copy of parser_probe.herb in its main(),
    # and diff its canonical S-expression output against the
    # hand-derived answer key in parser_probe.expected. The expected
    # file is the canonical-print form (Herbert's "..."-wrapped string)
    # of the answer key text, so the test pins the fragment byte-for-byte
    # against an oracle that was never produced by any parser.
    PARSE_DRIVER="$STACK_DIR/parser_fragment.herb"
    PARSE_PROBE_EXPECTED="$STACK_DIR/parser_probe.expected"
    if [[ -f "$PARSE_DRIVER" && -f "$PARSE_PROBE_EXPECTED" ]]; then
        total=$((total + 1))
        if run_one "$PARSE_DRIVER" "$PARSE_PROBE_EXPECTED" \
                "stack/parser_probe (driver: parser_fragment.herb)"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    # Evaluator forcing-function test: the evaluator fragment returns the
    # serialized probe result as a Herbert string value, so the bootstrap
    # prints that value in canonical quoted form. The oracle is the raw
    # serialized line; strip the canonical wrapper before diffing.
    EVAL_DRIVER="$STACK_DIR/evaluator_fragment.herb"
    EVAL_PROBE_EXPECTED="$STACK_DIR/evaluator_probe.expected"
    if [[ -f "$EVAL_DRIVER" && -f "$EVAL_PROBE_EXPECTED" ]]; then
        total=$((total + 1))
        actual=$(mktemp)
        raw_actual=$(mktemp)
        err=$(mktemp)
        HERBERT_REPORT_PEAK=1 "$HERBERT" "$EVAL_DRIVER" >"$actual" 2>"$err"
        rc=$?
        if [[ $rc -ne 0 ]]; then
            echo "FAIL: stack/evaluator_probe (driver: evaluator_fragment.herb) (interpreter exit $rc)"
            echo "--- stderr"
            cat "$err"
            echo "--- stdout"
            cat "$actual"
            fail=$((fail + 1))
            rm -f "$actual" "$raw_actual" "$err"
        elif ! sed -n 's/^"\(.*\)"$/\1/p' "$actual" >"$raw_actual" || [[ ! -s "$raw_actual" ]]; then
            echo "FAIL: stack/evaluator_probe (driver: evaluator_fragment.herb) (expected canonical string output)"
            echo "--- stdout"
            cat "$actual"
            fail=$((fail + 1))
            rm -f "$actual" "$raw_actual" "$err"
        elif ! diff -u "$EVAL_PROBE_EXPECTED" "$raw_actual" >/tmp/herbert_diff.$$ 2>&1; then
            echo "FAIL: stack/evaluator_probe (driver: evaluator_fragment.herb) (output mismatch)"
            cat /tmp/herbert_diff.$$
            fail=$((fail + 1))
            rm -f /tmp/herbert_diff.$$ "$actual" "$raw_actual" "$err"
        else
            echo "PASS: stack/evaluator_probe (driver: evaluator_fragment.herb)"
            pass=$((pass + 1))
            rm -f "$actual" "$raw_actual" "$err"
        fi
    fi

    # VM forcing-function test: the VM fragment runs the blessed bytecode
    # for the same evaluator probe and returns the serialized result as a
    # Herbert string value. Reuse the evaluator oracle and strip the
    # canonical string wrapper before diffing.
    VM_DRIVER="$STACK_DIR/vm_fragment.herb"
    VM_PROBE_EXPECTED="$STACK_DIR/evaluator_probe.expected"
    if [[ -f "$VM_DRIVER" && -f "$VM_PROBE_EXPECTED" ]]; then
        total=$((total + 1))
        actual=$(mktemp)
        raw_actual=$(mktemp)
        err=$(mktemp)
        HERBERT_REPORT_PEAK=1 "$HERBERT" "$VM_DRIVER" >"$actual" 2>"$err"
        rc=$?
        if [[ $rc -ne 0 ]]; then
            echo "FAIL: stack/vm (driver: vm_fragment.herb) (interpreter exit $rc)"
            echo "--- stderr"
            cat "$err"
            echo "--- stdout"
            cat "$actual"
            fail=$((fail + 1))
            rm -f "$actual" "$raw_actual" "$err"
        elif ! sed -n 's/^"\(.*\)"$/\1/p' "$actual" >"$raw_actual" || [[ ! -s "$raw_actual" ]]; then
            echo "FAIL: stack/vm (driver: vm_fragment.herb) (expected canonical string output)"
            echo "--- stdout"
            cat "$actual"
            fail=$((fail + 1))
            rm -f "$actual" "$raw_actual" "$err"
        elif ! diff -u "$VM_PROBE_EXPECTED" "$raw_actual" >/tmp/herbert_diff.$$ 2>&1; then
            echo "FAIL: stack/vm (driver: vm_fragment.herb) (output mismatch)"
            cat /tmp/herbert_diff.$$
            fail=$((fail + 1))
            rm -f /tmp/herbert_diff.$$ "$actual" "$raw_actual" "$err"
        else
            echo "PASS: stack/vm (driver: vm_fragment.herb)"
            pass=$((pass + 1))
            rm -f "$actual" "$raw_actual" "$err"
        fi
    fi

    # Klondike canonical integration forcing functions. The canonical driver
    # reads source through clogger(), checks the diagnostics front end, lowers
    # to bytecode, adapts, and executes through the VM.
    KLONDIKE_DRIVER="$STACK_DIR/klondike.herb"
    KLONDIKE_EVAL_PROBE="$STACK_DIR/evaluator_probe.herb"
    KLONDIKE_EVAL_EXPECTED="$STACK_DIR/evaluator_probe.expected"
    KLONDIKE_PIPELINE_PROBE="$STACK_DIR/pipeline_probe.herb"
    KLONDIKE_IO_PROBE="$STACK_DIR/klondike_io_probe.herb"
    KLONDIKE_COMPUTE_PROBE="$STACK_DIR/metacircular_compute_probe.herb"

    if [[ -f "$KLONDIKE_DRIVER" && -f "$KLONDIKE_EVAL_PROBE" && -f "$KLONDIKE_EVAL_EXPECTED" ]]; then
        total=$((total + 1))
        actual=$(mktemp)
        raw_actual=$(mktemp)
        err=$(mktemp)
        HERBERT_REPORT_PEAK=1 "$HERBERT" "$KLONDIKE_DRIVER" <"$KLONDIKE_EVAL_PROBE" >"$actual" 2>"$err"
        rc=$?
        if [[ $rc -ne 0 ]]; then
            echo "FAIL: stack/evaluator_probe (driver: klondike.herb, stdin) (interpreter exit $rc)"
            echo "--- stderr"
            cat "$err"
            echo "--- stdout"
            cat "$actual"
            fail=$((fail + 1))
            rm -f "$actual" "$raw_actual" "$err"
        elif ! { decode_canonical_string "$actual" >"$raw_actual" && printf '\n' >>"$raw_actual"; } || [[ ! -s "$raw_actual" ]]; then
            echo "FAIL: stack/evaluator_probe (driver: klondike.herb, stdin) (expected canonical string output)"
            echo "--- stdout"
            cat "$actual"
            fail=$((fail + 1))
            rm -f "$actual" "$raw_actual" "$err"
        elif ! diff -u "$KLONDIKE_EVAL_EXPECTED" "$raw_actual" >/tmp/herbert_diff.$$ 2>&1; then
            echo "FAIL: stack/evaluator_probe (driver: klondike.herb, stdin) (output mismatch)"
            cat /tmp/herbert_diff.$$
            fail=$((fail + 1))
            rm -f /tmp/herbert_diff.$$ "$actual" "$raw_actual" "$err"
        else
            echo "PASS: stack/evaluator_probe (driver: klondike.herb, stdin)"
            pass=$((pass + 1))
            rm -f "$actual" "$raw_actual" "$err"
        fi
    fi

    # Flat-VM tail-position dispatch forcing function. Two zero-allocation
    # tail-recursive loops (bounds N and 10N) are compiled and run *through*
    # klondike.herb (the loop is the guest source on stdin). Pre-change the VM
    # pushed a caller frame on every CALL, so the guest `frames` array — a
    # Herbert array on the C heap — grew linearly with the iteration count and
    # is captured by peak-heap-bytes. Post-change a tail CALL elides the caller
    # frame, so the heap stays flat as the bound grows 10x. We assert three
    # things, mirroring test_14's heap-slope discipline but with klondike as the
    # driver: (1) value correctness — each loop returns the closed-form sum
    # sum(0..BOUND-1) = BOUND*(BOUND-1)/2; (2) slope — heap_b <= 1.5 * heap_a;
    # (3) an absolute cap — heap_b <= TAIL_MAXHEAP, a flat constant just above
    # the post-change flat heap and far below the pre-change linear value, so it
    # independently catches linear growth. Measured with peak-heap-bytes only:
    # peak-live-scopes is a flat ~24 here (the C bootstrap already TCOs
    # klondike's own vm_loop recursion), so it does not see the guest defect.
    TAIL_PROBE_A="$STACK_DIR/tail_dispatch_probe_a.herb"
    TAIL_PROBE_B="$STACK_DIR/tail_dispatch_probe_b.herb"
    # Closed-form sums for BOUND=2000 (probe a) and BOUND=20000 (probe b):
    # sum(0..1999)=1999000, sum(0..19999)=199990000.
    TAIL_SUM_A=1999000
    TAIL_SUM_B=199990000
    TAIL_SLOPE_NUM=3
    TAIL_SLOPE_DEN=2
    # Post-change flat heap measures ~1.0486 MB at both bounds; cap at 1.5 MB,
    # which is below even the pre-change a-bound (~2.06 MB) and far below the
    # pre-change b-bound (~11 MB).
    TAIL_MAXHEAP=1500000
    if [[ -f "$KLONDIKE_DRIVER" && -f "$TAIL_PROBE_A" && -f "$TAIL_PROBE_B" ]]; then
        total=$((total + 1))
        tail_label="stack/tail_dispatch_probe (driver: klondike.herb, stdin, bounded heap)"
        tail_ok=1
        tail_detail=
        tail_heap_a=
        tail_heap_b=
        for tail_case in "a:$TAIL_PROBE_A:$TAIL_SUM_A" "b:$TAIL_PROBE_B:$TAIL_SUM_B"; do
            tail_which="${tail_case%%:*}"
            tail_rest="${tail_case#*:}"
            tail_probe="${tail_rest%%:*}"
            tail_sum="${tail_rest##*:}"
            actual=$(mktemp)
            raw_actual=$(mktemp)
            err=$(mktemp)
            HERBERT_REPORT_PEAK=1 HERBERT_REPORT_HEAP=1 "$HERBERT" "$KLONDIKE_DRIVER" <"$tail_probe" >"$actual" 2>"$err"
            rc=$?
            if [[ $rc -ne 0 ]]; then
                echo "FAIL: $tail_label (probe $tail_which interpreter exit $rc)"
                echo "--- stderr"
                cat "$err"
                echo "--- stdout"
                cat "$actual"
                tail_ok=0
                rm -f "$actual" "$raw_actual" "$err"
                break
            fi
            # klondike serializes the int result as a canonical quoted string
            # (e.g. "1999000"); strip the wrapper to recover the integer.
            if ! decode_canonical_string "$actual" >"$raw_actual" || [[ ! -s "$raw_actual" ]]; then
                echo "FAIL: $tail_label (probe $tail_which expected canonical string result)"
                echo "--- stdout"
                cat "$actual"
                tail_ok=0
                rm -f "$actual" "$raw_actual" "$err"
                break
            fi
            tail_result=$(tr -d '[:space:]' < "$raw_actual")
            if [[ "$tail_result" != "$tail_sum" ]]; then
                echo "FAIL: $tail_label (probe $tail_which value $tail_result != closed-form sum $tail_sum)"
                tail_ok=0
                rm -f "$actual" "$raw_actual" "$err"
                break
            fi
            tail_heap=$(awk '/^peak-heap-bytes: [0-9]+$/ {print $2}' "$err")
            if [[ -z "$tail_heap" ]]; then
                echo "FAIL: $tail_label (probe $tail_which no peak-heap-bytes reported)"
                tail_ok=0
                rm -f "$actual" "$raw_actual" "$err"
                break
            fi
            if [[ "$tail_which" == "a" ]]; then
                tail_heap_a="$tail_heap"
            else
                tail_heap_b="$tail_heap"
            fi
            rm -f "$actual" "$raw_actual" "$err"
        done
        if (( tail_ok == 1 )); then
            # Absolute cap on the larger bound: catches linear growth on its own.
            if (( tail_heap_b > TAIL_MAXHEAP )); then
                echo "FAIL: $tail_label (peak-heap-bytes $tail_heap_b > cap $TAIL_MAXHEAP)"
                tail_ok=0
            # Slope: heap_b must not exceed 1.5 * heap_a (integer-ratio form).
            elif (( tail_heap_b * TAIL_SLOPE_DEN > tail_heap_a * TAIL_SLOPE_NUM )); then
                echo "FAIL: $tail_label (heap slope $tail_heap_b > 1.5 * $tail_heap_a)"
                tail_ok=0
            else
                tail_detail="values ok; peak-heap-bytes $tail_heap_b <= 1.5 * $tail_heap_a and <= $TAIL_MAXHEAP"
            fi
        fi
        if (( tail_ok == 1 )); then
            echo "PASS: $tail_label ($tail_detail)"
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    if [[ -f "$KLONDIKE_DRIVER" && -f "$KLONDIKE_PIPELINE_PROBE" ]]; then
        total=$((total + 1))
        oracle_display=$(mktemp)
        oracle=$(mktemp)
        actual=$(mktemp)
        raw_actual=$(mktemp)
        oracle_err=$(mktemp)
        err=$(mktemp)
        HERBERT_REPORT_PEAK=1 "$HERBERT" "$KLONDIKE_PIPELINE_PROBE" >"$oracle_display" 2>"$oracle_err"
        rc=$?
        if [[ $rc -ne 0 ]]; then
            echo "FAIL: stack/pipeline_probe (driver: klondike.herb, stdin) (oracle exit $rc)"
            echo "--- oracle stderr"
            cat "$oracle_err"
            echo "--- oracle stdout"
            cat "$oracle_display"
            fail=$((fail + 1))
            rm -f "$oracle_display" "$oracle" "$actual" "$raw_actual" "$oracle_err" "$err"
        else
            tr -d ',' <"$oracle_display" >"$oracle"
            HERBERT_REPORT_PEAK=1 "$HERBERT" "$KLONDIKE_DRIVER" <"$KLONDIKE_PIPELINE_PROBE" >"$actual" 2>"$err"
            rc=$?
            if [[ $rc -ne 0 ]]; then
                echo "FAIL: stack/pipeline_probe (driver: klondike.herb, stdin) (interpreter exit $rc)"
                echo "--- stderr"
                cat "$err"
                echo "--- stdout"
                cat "$actual"
                fail=$((fail + 1))
                rm -f "$oracle_display" "$oracle" "$actual" "$raw_actual" "$oracle_err" "$err"
            elif ! { decode_canonical_string "$actual" >"$raw_actual" && printf '\n' >>"$raw_actual"; } || [[ ! -s "$raw_actual" ]]; then
                echo "FAIL: stack/pipeline_probe (driver: klondike.herb, stdin) (expected canonical string output)"
                echo "--- stdout"
                cat "$actual"
                fail=$((fail + 1))
                rm -f "$oracle_display" "$oracle" "$actual" "$raw_actual" "$oracle_err" "$err"
            elif ! diff -u "$oracle" "$raw_actual" >/tmp/herbert_diff.$$ 2>&1; then
                echo "FAIL: stack/pipeline_probe (driver: klondike.herb, stdin) (output mismatch)"
                cat /tmp/herbert_diff.$$
                fail=$((fail + 1))
                rm -f /tmp/herbert_diff.$$ "$oracle_display" "$oracle" "$actual" "$raw_actual" "$oracle_err" "$err"
            else
                echo "PASS: stack/pipeline_probe (driver: klondike.herb, stdin)"
                pass=$((pass + 1))
                rm -f "$oracle_display" "$oracle" "$actual" "$raw_actual" "$oracle_err" "$err"
            fi
        fi
    fi

    if [[ -f "$KLONDIKE_DRIVER" && -f "$KLONDIKE_IO_PROBE" ]]; then
        total=$((total + 1))
        oracle=$(mktemp)
        expected=$(mktemp)
        actual=$(mktemp)
        oracle_err=$(mktemp)
        err=$(mktemp)
        HERBERT_REPORT_PEAK=1 "$HERBERT" "$KLONDIKE_IO_PROBE" </dev/null >"$oracle" 2>"$oracle_err"
        rc=$?
        if [[ $rc -ne 0 ]]; then
            echo "FAIL: stack/klondike_io_probe (driver: klondike.herb, stdin) (oracle exit $rc)"
            echo "--- oracle stderr"
            cat "$oracle_err"
            echo "--- oracle stdout"
            cat "$oracle"
            fail=$((fail + 1))
            rm -f "$oracle" "$expected" "$actual" "$oracle_err" "$err"
        else
            perl -0777 -pe 's/([^\n]*)\n\z/"$1"\n/s' "$oracle" >"$expected"
            HERBERT_REPORT_PEAK=1 "$HERBERT" "$KLONDIKE_DRIVER" <"$KLONDIKE_IO_PROBE" >"$actual" 2>"$err"
            rc=$?
            if [[ $rc -ne 0 ]]; then
                echo "FAIL: stack/klondike_io_probe (driver: klondike.herb, stdin) (interpreter exit $rc)"
                echo "--- stderr"
                cat "$err"
                echo "--- stdout"
                cat "$actual"
                fail=$((fail + 1))
                rm -f "$oracle" "$expected" "$actual" "$oracle_err" "$err"
            elif ! cmp -s "$expected" "$actual"; then
                echo "FAIL: stack/klondike_io_probe (driver: klondike.herb, stdin) (output mismatch)"
                diff -u "$expected" "$actual" || true
                fail=$((fail + 1))
                rm -f "$oracle" "$expected" "$actual" "$oracle_err" "$err"
            else
                echo "PASS: stack/klondike_io_probe (driver: klondike.herb, stdin)"
                pass=$((pass + 1))
                rm -f "$oracle" "$expected" "$actual" "$oracle_err" "$err"
            fi
        fi
    fi

    if [[ -f "$KLONDIKE_DRIVER" && -f "$KLONDIKE_IO_PROBE" ]]; then
        payload=$(mktemp)
        printf 'hello' >"$payload"
        run_klondike_bundle_diff \
            "stack/klondike_io_probe (driver: klondike.herb, bundled preflight)" \
            "$KLONDIKE_IO_PROBE" "$payload" "preflight" "$KLONDIKE_DRIVER"
        run_klondike_bundle_diff \
            "stack/klondike_io_probe (driver: klondike.herb, nested beta-small)" \
            "$KLONDIKE_IO_PROBE" "$payload" "nested" "$KLONDIKE_DRIVER"
        rm -f "$payload"
    fi

    if [[ -f "$KLONDIKE_DRIVER" && -f "$KLONDIKE_COMPUTE_PROBE" ]]; then
        payload=$(mktemp)
        printf '5' >"$payload"
        run_klondike_bundle_diff \
            "stack/metacircular_compute_probe (driver: klondike.herb, bundled preflight)" \
            "$KLONDIKE_COMPUTE_PROBE" "$payload" "preflight" "$KLONDIKE_DRIVER"
        run_klondike_bundle_diff \
            "stack/metacircular_compute_probe (driver: klondike.herb, nested beta-small)" \
            "$KLONDIKE_COMPUTE_PROBE" "$payload" "nested" "$KLONDIKE_DRIVER"
        rm -f "$payload"
    fi

    if [[ -f "$KLONDIKE_DRIVER" && -f "$KLONDIKE_EVAL_PROBE" && -f "$KLONDIKE_COMPUTE_PROBE" ]]; then
        run_klondike_medium_guard "$KLONDIKE_DRIVER" "$KLONDIKE_EVAL_PROBE" "$KLONDIKE_COMPUTE_PROBE"
    fi

    # Output primitive forcing-function tests: flogger writes raw bytes to
    # stdout, while main() still prints the fixed 0 sentinel after return.
    OUTPUT_ECHO_DRIVER="$STACK_DIR/output_echo_fragment.herb"
    if [[ -f "$OUTPUT_ECHO_DRIVER" ]]; then
        total=$((total + 1))
        payload=$(mktemp)
        expected=$(mktemp)
        actual=$(mktemp)
        err=$(mktemp)
        printf 'ordinary text\nsecond line\n' >"$payload"
        cp "$payload" "$expected"
        printf '0\n' >>"$expected"
        HERBERT_REPORT_PEAK=1 "$HERBERT" "$OUTPUT_ECHO_DRIVER" <"$payload" >"$actual" 2>"$err"
        rc=$?
        if [[ $rc -ne 0 ]]; then
            echo "FAIL: stack/output_echo_fragment.herb (ordinary payload) (interpreter exit $rc)"
            echo "--- stderr"
            cat "$err"
            echo "--- stdout"
            cat "$actual"
            fail=$((fail + 1))
            rm -f "$payload" "$expected" "$actual" "$err"
        elif ! cmp -s "$expected" "$actual"; then
            echo "FAIL: stack/output_echo_fragment.herb (ordinary payload) (output mismatch)"
            cmp -l "$expected" "$actual" || true
            fail=$((fail + 1))
            rm -f "$payload" "$expected" "$actual" "$err"
        else
            echo "PASS: stack/output_echo_fragment.herb (ordinary payload)"
            pass=$((pass + 1))
            rm -f "$payload" "$expected" "$actual" "$err"
        fi

        total=$((total + 1))
        payload=$(mktemp)
        expected=$(mktemp)
        actual=$(mktemp)
        err=$(mktemp)
        printf 'binary\000quote"slash\\\nhi\200end' >"$payload"
        cp "$payload" "$expected"
        printf '0\n' >>"$expected"
        HERBERT_REPORT_PEAK=1 "$HERBERT" "$OUTPUT_ECHO_DRIVER" <"$payload" >"$actual" 2>"$err"
        rc=$?
        if [[ $rc -ne 0 ]]; then
            echo "FAIL: stack/output_echo_fragment.herb (binary payload) (interpreter exit $rc)"
            echo "--- stderr"
            cat "$err"
            echo "--- stdout"
            cat "$actual"
            fail=$((fail + 1))
            rm -f "$payload" "$expected" "$actual" "$err"
        elif ! cmp -s "$expected" "$actual"; then
            echo "FAIL: stack/output_echo_fragment.herb (binary payload) (output mismatch)"
            cmp -l "$expected" "$actual" || true
            fail=$((fail + 1))
            rm -f "$payload" "$expected" "$actual" "$err"
        else
            echo "PASS: stack/output_echo_fragment.herb (binary payload)"
            pass=$((pass + 1))
            rm -f "$payload" "$expected" "$actual" "$err"
        fi
    fi

    NATIVE_CODEGEN_LINK1="$PWD/run_native_codegen_link1.sh"
    if [[ -f "$NATIVE_CODEGEN_LINK1" ]]; then
        total=$((total + 1))
        if HERBERT="$HERBERT" "$NATIVE_CODEGEN_LINK1"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    NATIVE_CODEGEN_LINK2="$PWD/run_native_codegen_link2.sh"
    if [[ -f "$NATIVE_CODEGEN_LINK2" ]]; then
        total=$((total + 1))
        if HERBERT="$HERBERT" "$NATIVE_CODEGEN_LINK2"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    # Suke codegen forcing-function tests: the C bootstrap runs each probe
    # directly as the oracle, then the Herbert pipeline fragment compiles the
    # same embedded source and executes it on the VM with the same stdin.
    SUKE_ECHO_PROBE="$STACK_DIR/suke_echo_probe.herb"
    SUKE_ECHO_DRIVER="$STACK_DIR/suke_echo_fragment.herb"
    SUKE_COMPUTE_PROBE="$STACK_DIR/suke_compute_probe.herb"
    SUKE_COMPUTE_DRIVER="$STACK_DIR/suke_compute_fragment.herb"
    if [[ -f "$SUKE_ECHO_PROBE" && -f "$SUKE_ECHO_DRIVER" && -f "$SUKE_COMPUTE_PROBE" && -f "$SUKE_COMPUTE_DRIVER" ]]; then
        payload=$(mktemp)
        printf 'ordinary text\nsecond line\n' >"$payload"
        run_suke_diff "stack/suke_echo_probe (driver: suke_echo_fragment.herb, ordinary payload)" "$SUKE_ECHO_PROBE" "$SUKE_ECHO_DRIVER" "$payload"
        rm -f "$payload"

        payload=$(mktemp)
        printf 'binary\000quote"slash\\\nhi\200end' >"$payload"
        run_suke_diff "stack/suke_echo_probe (driver: suke_echo_fragment.herb, binary payload)" "$SUKE_ECHO_PROBE" "$SUKE_ECHO_DRIVER" "$payload"
        rm -f "$payload"

        payload=$(mktemp)
        : >"$payload"
        run_suke_diff "stack/suke_echo_probe (driver: suke_echo_fragment.herb, empty payload)" "$SUKE_ECHO_PROBE" "$SUKE_ECHO_DRIVER" "$payload"
        rm -f "$payload"

        payload=$(mktemp)
        printf 'ordinary text\nsecond line\n' >"$payload"
        run_suke_diff "stack/suke_compute_probe (driver: suke_compute_fragment.herb, ordinary payload)" "$SUKE_COMPUTE_PROBE" "$SUKE_COMPUTE_DRIVER" "$payload"
        rm -f "$payload"

        payload=$(mktemp)
        printf 'binary\000quote"slash\\\nhi\200end' >"$payload"
        run_suke_diff "stack/suke_compute_probe (driver: suke_compute_fragment.herb, binary payload)" "$SUKE_COMPUTE_PROBE" "$SUKE_COMPUTE_DRIVER" "$payload"
        rm -f "$payload"

        payload=$(mktemp)
        : >"$payload"
        run_suke_diff "stack/suke_compute_probe (driver: suke_compute_fragment.herb, empty payload)" "$SUKE_COMPUTE_PROBE" "$SUKE_COMPUTE_DRIVER" "$payload"
        rm -f "$payload"
    fi

    # Klondike malformed-probe battery: the C bootstrap must reject every
    # probe, and the canonical Herbert driver must match its source line plus
    # the manifest's exact ERR code.
    ERROR_MANIFEST="$STACK_DIR/error_probes.expected"
    ERROR_PROBE_DIR="$STACK_DIR/error_probes"
    if [[ -f "$KLONDIKE_DRIVER" && -f "$ERROR_MANIFEST" && -d "$ERROR_PROBE_DIR" ]]; then
        while read -r probe_name err_word err_code; do
            [[ -n "$probe_name" ]] || continue
            total=$((total + 1))
            probe="$ERROR_PROBE_DIR/$probe_name.herb"
            expected=$(mktemp)
            c_actual=$(mktemp)
            c_err=$(mktemp)
            actual=$(mktemp)
            err=$(mktemp)
            if [[ ! -f "$probe" ]]; then
                echo "FAIL: stack/error_probes/$probe_name (missing probe file)"
                fail=$((fail + 1))
                rm -f "$expected" "$c_actual" "$c_err" "$actual" "$err"
                continue
            fi
            HERBERT_REPORT_PEAK=1 "$HERBERT" "$probe" >"$c_actual" 2>"$c_err"
            rc=$?
            if [[ $rc -eq 0 ]]; then
                echo "FAIL: stack/error_probes/$probe_name (bootstrap accepted malformed probe)"
                echo "--- bootstrap stdout"
                cat "$c_actual"
                fail=$((fail + 1))
                rm -f "$expected" "$c_actual" "$c_err" "$actual" "$err"
                continue
            fi
            line="$(bootstrap_line "$c_err")"
            payload="$(bootstrap_payload "$err_code" "$c_err")"
            if [[ "$err_code" != "314" && -z "$line" ]]; then
                echo "FAIL: stack/error_probes/$probe_name (bootstrap diagnostic had no line)"
                echo "--- bootstrap stderr"
                cat "$c_err"
                fail=$((fail + 1))
                rm -f "$expected" "$c_actual" "$c_err" "$actual" "$err"
                continue
            fi
            if [[ "$err_code" == "314" && -n "$line" ]]; then
                echo "FAIL: stack/error_probes/$probe_name (bootstrap no-main unexpectedly had a line)"
                echo "--- bootstrap stderr"
                cat "$c_err"
                fail=$((fail + 1))
                rm -f "$expected" "$c_actual" "$c_err" "$actual" "$err"
                continue
            fi
            write_expected_diagnostic "$err_code" "$line" "$payload" "$expected"
            HERBERT_REPORT_PEAK=1 "$HERBERT" "$KLONDIKE_DRIVER" <"$probe" >"$actual" 2>"$err"
            rc=$?
            if [[ $rc -ne 0 ]]; then
                echo "FAIL: stack/error_probes/$probe_name (driver: klondike.herb, stdin) (interpreter exit $rc)"
                echo "--- stderr"
                cat "$err"
                echo "--- stdout"
                cat "$actual"
                fail=$((fail + 1))
                rm -f "$expected" "$c_actual" "$c_err" "$actual" "$err"
            elif ! cmp -s "$expected" "$actual"; then
                echo "FAIL: stack/error_probes/$probe_name (driver: klondike.herb, stdin) (output mismatch)"
                diff -u "$expected" "$actual" || true
                fail=$((fail + 1))
                rm -f "$expected" "$c_actual" "$c_err" "$actual" "$err"
            else
                echo "PASS: stack/error_probes/$probe_name (driver: klondike.herb, stdin)"
                pass=$((pass + 1))
                rm -f "$expected" "$c_actual" "$c_err" "$actual" "$err"
            fi
        done < "$ERROR_MANIFEST"
    fi

    # Emitter forcing-function test: the emitter fragment returns the
    # full bytecode listing as a Herbert string value. Decode the
    # bootstrap's canonical string display before diffing against the
    # raw blessed listing oracle.
    EMIT_DRIVER="$STACK_DIR/emitter_fragment.herb"
    EMIT_PROBE_EXPECTED="$STACK_DIR/emitter_probe.expected"
    if [[ -f "$EMIT_DRIVER" && -f "$EMIT_PROBE_EXPECTED" ]]; then
        total=$((total + 1))
        actual=$(mktemp)
        raw_actual=$(mktemp)
        err=$(mktemp)
        HERBERT_REPORT_PEAK=1 "$HERBERT" "$EMIT_DRIVER" >"$actual" 2>"$err"
        rc=$?
        if [[ $rc -ne 0 ]]; then
            echo "FAIL: stack/emitter_probe (driver: emitter_fragment.herb) (interpreter exit $rc)"
            echo "--- stderr"
            cat "$err"
            echo "--- stdout"
            cat "$actual"
            fail=$((fail + 1))
            rm -f "$actual" "$raw_actual" "$err"
        elif ! decode_canonical_string "$actual" >"$raw_actual" || [[ ! -s "$raw_actual" ]]; then
            echo "FAIL: stack/emitter_probe (driver: emitter_fragment.herb) (expected canonical string output)"
            echo "--- stdout"
            cat "$actual"
            fail=$((fail + 1))
            rm -f "$actual" "$raw_actual" "$err"
        elif ! diff -u "$EMIT_PROBE_EXPECTED" "$raw_actual" >/tmp/herbert_diff.$$ 2>&1; then
            echo "FAIL: stack/emitter_probe (driver: emitter_fragment.herb) (output mismatch)"
            cat /tmp/herbert_diff.$$
            fail=$((fail + 1))
            rm -f /tmp/herbert_diff.$$ "$actual" "$raw_actual" "$err"
        else
            echo "PASS: stack/emitter_probe (driver: emitter_fragment.herb)"
            pass=$((pass + 1))
            rm -f "$actual" "$raw_actual" "$err"
        fi
    fi

    # Klondike bytecode-equivalence check: generate a temporary driver with
    # klondike's emitter and a bytecode-listing main, then diff the evaluator
    # probe bytecode against the blessed emitter oracle.
    if [[ -f "$KLONDIKE_DRIVER" && -f "$KLONDIKE_EVAL_PROBE" && -f "$EMIT_PROBE_EXPECTED" ]]; then
        total=$((total + 1))
        emit_driver=$(mktemp "${TMPDIR:-/tmp}/klondike-emitter.XXXXXX.herb")
        actual=$(mktemp)
        raw_actual=$(mktemp)
        err=$(mktemp)
        write_klondike_emitter_driver "$KLONDIKE_DRIVER" "$emit_driver"
        HERBERT_REPORT_PEAK=1 "$HERBERT" "$emit_driver" <"$KLONDIKE_EVAL_PROBE" >"$actual" 2>"$err"
        rc=$?
        if [[ $rc -ne 0 ]]; then
            echo "FAIL: stack/emitter_probe (driver: klondike.herb emitter) (interpreter exit $rc)"
            echo "--- stderr"
            cat "$err"
            echo "--- stdout"
            cat "$actual"
            fail=$((fail + 1))
            rm -f "$emit_driver" "$actual" "$raw_actual" "$err"
        elif ! decode_canonical_string "$actual" >"$raw_actual" || [[ ! -s "$raw_actual" ]]; then
            echo "FAIL: stack/emitter_probe (driver: klondike.herb emitter) (expected canonical string output)"
            echo "--- stdout"
            cat "$actual"
            fail=$((fail + 1))
            rm -f "$emit_driver" "$actual" "$raw_actual" "$err"
        elif ! diff -u "$EMIT_PROBE_EXPECTED" "$raw_actual" >/tmp/herbert_diff.$$ 2>&1; then
            echo "FAIL: stack/emitter_probe (driver: klondike.herb emitter) (output mismatch)"
            cat /tmp/herbert_diff.$$
            fail=$((fail + 1))
            rm -f /tmp/herbert_diff.$$ "$emit_driver" "$actual" "$raw_actual" "$err"
        else
            echo "PASS: stack/emitter_probe (driver: klondike.herb emitter)"
            pass=$((pass + 1))
            rm -f "$emit_driver" "$actual" "$raw_actual" "$err"
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
