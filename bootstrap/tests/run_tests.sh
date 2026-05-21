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

    # Pipeline forcing-function test: run the novel probe directly under
    # the bootstrap to derive the oracle, then run the Herbert-authored
    # lexer->parser->emitter->adapter->VM pipeline and compare its
    # serialized result. The bootstrap's tuple printer includes commas;
    # the VM serializer's tuple format does not, so strip commas from
    # the dynamic tuple-of-ints oracle before diffing.
    PIPELINE_DRIVER="$STACK_DIR/pipeline_fragment.herb"
    PIPELINE_PROBE="$STACK_DIR/pipeline_probe.herb"
    if [[ -f "$PIPELINE_DRIVER" && -f "$PIPELINE_PROBE" ]]; then
        total=$((total + 1))
        oracle_display=$(mktemp)
        oracle=$(mktemp)
        actual=$(mktemp)
        raw_actual=$(mktemp)
        oracle_err=$(mktemp)
        err=$(mktemp)
        HERBERT_REPORT_PEAK=1 "$HERBERT" "$PIPELINE_PROBE" >"$oracle_display" 2>"$oracle_err"
        rc=$?
        if [[ $rc -ne 0 ]]; then
            echo "FAIL: stack/pipeline_probe (driver: pipeline_fragment.herb) (oracle exit $rc)"
            echo "--- oracle stderr"
            cat "$oracle_err"
            echo "--- oracle stdout"
            cat "$oracle_display"
            fail=$((fail + 1))
            rm -f "$oracle_display" "$oracle" "$actual" "$raw_actual" "$oracle_err" "$err"
        else
            tr -d ',' <"$oracle_display" >"$oracle"
            HERBERT_REPORT_PEAK=1 "$HERBERT" "$PIPELINE_DRIVER" >"$actual" 2>"$err"
            rc=$?
            if [[ $rc -ne 0 ]]; then
                echo "FAIL: stack/pipeline_probe (driver: pipeline_fragment.herb) (interpreter exit $rc)"
                echo "--- stderr"
                cat "$err"
                echo "--- stdout"
                cat "$actual"
                fail=$((fail + 1))
                rm -f "$oracle_display" "$oracle" "$actual" "$raw_actual" "$oracle_err" "$err"
            elif ! sed -n 's/^"\(.*\)"$/\1/p' "$actual" >"$raw_actual" || [[ ! -s "$raw_actual" ]]; then
                echo "FAIL: stack/pipeline_probe (driver: pipeline_fragment.herb) (expected canonical string output)"
                echo "--- stdout"
                cat "$actual"
                fail=$((fail + 1))
                rm -f "$oracle_display" "$oracle" "$actual" "$raw_actual" "$oracle_err" "$err"
            elif ! diff -u "$oracle" "$raw_actual" >/tmp/herbert_diff.$$ 2>&1; then
                echo "FAIL: stack/pipeline_probe (driver: pipeline_fragment.herb) (output mismatch)"
                cat /tmp/herbert_diff.$$
                fail=$((fail + 1))
                rm -f /tmp/herbert_diff.$$ "$oracle_display" "$oracle" "$actual" "$raw_actual" "$oracle_err" "$err"
            else
                echo "PASS: stack/pipeline_probe (driver: pipeline_fragment.herb)"
                pass=$((pass + 1))
                rm -f "$oracle_display" "$oracle" "$actual" "$raw_actual" "$oracle_err" "$err"
            fi
        fi
    fi

    # Input forcing-function tests: run the same stdin-reading fragment twice
    # with distinct well-formed source payloads. The fragment obtains source
    # only through clogger(), then follows the same lexer->parser->emitter->
    # adapter->VM path as pipeline_fragment.herb.
    INPUT_DRIVER="$STACK_DIR/input_fragment.herb"
    INPUT_EVAL_PROBE="$STACK_DIR/evaluator_probe.herb"
    INPUT_EVAL_EXPECTED="$STACK_DIR/evaluator_probe.expected"
    INPUT_PIPELINE_PROBE="$STACK_DIR/pipeline_probe.herb"
    if [[ -f "$INPUT_DRIVER" && -f "$INPUT_EVAL_PROBE" && -f "$INPUT_EVAL_EXPECTED" ]]; then
        total=$((total + 1))
        actual=$(mktemp)
        raw_actual=$(mktemp)
        err=$(mktemp)
        HERBERT_REPORT_PEAK=1 "$HERBERT" "$INPUT_DRIVER" <"$INPUT_EVAL_PROBE" >"$actual" 2>"$err"
        rc=$?
        if [[ $rc -ne 0 ]]; then
            echo "FAIL: stack/evaluator_probe (driver: input_fragment.herb, stdin) (interpreter exit $rc)"
            echo "--- stderr"
            cat "$err"
            echo "--- stdout"
            cat "$actual"
            fail=$((fail + 1))
            rm -f "$actual" "$raw_actual" "$err"
        elif ! sed -n 's/^"\(.*\)"$/\1/p' "$actual" >"$raw_actual" || [[ ! -s "$raw_actual" ]]; then
            echo "FAIL: stack/evaluator_probe (driver: input_fragment.herb, stdin) (expected canonical string output)"
            echo "--- stdout"
            cat "$actual"
            fail=$((fail + 1))
            rm -f "$actual" "$raw_actual" "$err"
        elif ! diff -u "$INPUT_EVAL_EXPECTED" "$raw_actual" >/tmp/herbert_diff.$$ 2>&1; then
            echo "FAIL: stack/evaluator_probe (driver: input_fragment.herb, stdin) (output mismatch)"
            cat /tmp/herbert_diff.$$
            fail=$((fail + 1))
            rm -f /tmp/herbert_diff.$$ "$actual" "$raw_actual" "$err"
        else
            echo "PASS: stack/evaluator_probe (driver: input_fragment.herb, stdin)"
            pass=$((pass + 1))
            rm -f "$actual" "$raw_actual" "$err"
        fi
    fi

    if [[ -f "$INPUT_DRIVER" && -f "$INPUT_PIPELINE_PROBE" ]]; then
        total=$((total + 1))
        oracle_display=$(mktemp)
        oracle=$(mktemp)
        actual=$(mktemp)
        raw_actual=$(mktemp)
        oracle_err=$(mktemp)
        err=$(mktemp)
        HERBERT_REPORT_PEAK=1 "$HERBERT" "$INPUT_PIPELINE_PROBE" >"$oracle_display" 2>"$oracle_err"
        rc=$?
        if [[ $rc -ne 0 ]]; then
            echo "FAIL: stack/pipeline_probe (driver: input_fragment.herb, stdin) (oracle exit $rc)"
            echo "--- oracle stderr"
            cat "$oracle_err"
            echo "--- oracle stdout"
            cat "$oracle_display"
            fail=$((fail + 1))
            rm -f "$oracle_display" "$oracle" "$actual" "$raw_actual" "$oracle_err" "$err"
        else
            tr -d ',' <"$oracle_display" >"$oracle"
            HERBERT_REPORT_PEAK=1 "$HERBERT" "$INPUT_DRIVER" <"$INPUT_PIPELINE_PROBE" >"$actual" 2>"$err"
            rc=$?
            if [[ $rc -ne 0 ]]; then
                echo "FAIL: stack/pipeline_probe (driver: input_fragment.herb, stdin) (interpreter exit $rc)"
                echo "--- stderr"
                cat "$err"
                echo "--- stdout"
                cat "$actual"
                fail=$((fail + 1))
                rm -f "$oracle_display" "$oracle" "$actual" "$raw_actual" "$oracle_err" "$err"
            elif ! sed -n 's/^"\(.*\)"$/\1/p' "$actual" >"$raw_actual" || [[ ! -s "$raw_actual" ]]; then
                echo "FAIL: stack/pipeline_probe (driver: input_fragment.herb, stdin) (expected canonical string output)"
                echo "--- stdout"
                cat "$actual"
                fail=$((fail + 1))
                rm -f "$oracle_display" "$oracle" "$actual" "$raw_actual" "$oracle_err" "$err"
            elif ! diff -u "$oracle" "$raw_actual" >/tmp/herbert_diff.$$ 2>&1; then
                echo "FAIL: stack/pipeline_probe (driver: input_fragment.herb, stdin) (output mismatch)"
                cat /tmp/herbert_diff.$$
                fail=$((fail + 1))
                rm -f /tmp/herbert_diff.$$ "$oracle_display" "$oracle" "$actual" "$raw_actual" "$oracle_err" "$err"
            else
                echo "PASS: stack/pipeline_probe (driver: input_fragment.herb, stdin)"
                pass=$((pass + 1))
                rm -f "$oracle_display" "$oracle" "$actual" "$raw_actual" "$oracle_err" "$err"
            fi
        fi
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

    OUTPUT_DRIVER="$STACK_DIR/output_fragment.herb"
    OUTPUT_EVAL_PROBE="$STACK_DIR/evaluator_probe.herb"
    OUTPUT_EVAL_EXPECTED="$STACK_DIR/evaluator_probe.expected"
    if [[ -f "$OUTPUT_DRIVER" && -f "$OUTPUT_EVAL_PROBE" && -f "$OUTPUT_EVAL_EXPECTED" ]]; then
        total=$((total + 1))
        expected=$(mktemp)
        actual=$(mktemp)
        err=$(mktemp)
        cp "$OUTPUT_EVAL_EXPECTED" "$expected"
        printf '0\n' >>"$expected"
        HERBERT_REPORT_PEAK=1 "$HERBERT" "$OUTPUT_DRIVER" <"$OUTPUT_EVAL_PROBE" >"$actual" 2>"$err"
        rc=$?
        if [[ $rc -ne 0 ]]; then
            echo "FAIL: stack/evaluator_probe (driver: output_fragment.herb, stdin) (interpreter exit $rc)"
            echo "--- stderr"
            cat "$err"
            echo "--- stdout"
            cat "$actual"
            fail=$((fail + 1))
            rm -f "$expected" "$actual" "$err"
        elif ! cmp -s "$expected" "$actual"; then
            echo "FAIL: stack/evaluator_probe (driver: output_fragment.herb, stdin) (output mismatch)"
            cmp -l "$expected" "$actual" || true
            fail=$((fail + 1))
            rm -f "$expected" "$actual" "$err"
        else
            echo "PASS: stack/evaluator_probe (driver: output_fragment.herb, stdin)"
            pass=$((pass + 1))
            rm -f "$expected" "$actual" "$err"
        fi
    fi

    # Error-handling malformed-probe battery: the C bootstrap must reject
    # every probe, and the Herbert error fragment must classify it with
    # the manifest's exact ERR code.
    ERROR_DRIVER="$STACK_DIR/error_fragment.herb"
    ERROR_MANIFEST="$STACK_DIR/error_probes.expected"
    ERROR_PROBE_DIR="$STACK_DIR/error_probes"
    if [[ -f "$ERROR_DRIVER" && -f "$ERROR_MANIFEST" && -d "$ERROR_PROBE_DIR" ]]; then
        while read -r probe_name err_word err_code; do
            [[ -n "$probe_name" ]] || continue
            total=$((total + 1))
            probe="$ERROR_PROBE_DIR/$probe_name.herb"
            expected=$(mktemp)
            c_actual=$(mktemp)
            c_err=$(mktemp)
            actual=$(mktemp)
            raw_actual=$(mktemp)
            err=$(mktemp)
            printf '%s %s\n' "$err_word" "$err_code" >"$expected"
            if [[ ! -f "$probe" ]]; then
                echo "FAIL: stack/error_probes/$probe_name (missing probe file)"
                fail=$((fail + 1))
                rm -f "$expected" "$c_actual" "$c_err" "$actual" "$raw_actual" "$err"
                continue
            fi
            HERBERT_REPORT_PEAK=1 "$HERBERT" "$probe" >"$c_actual" 2>"$c_err"
            rc=$?
            if [[ $rc -eq 0 ]]; then
                echo "FAIL: stack/error_probes/$probe_name (bootstrap accepted malformed probe)"
                echo "--- bootstrap stdout"
                cat "$c_actual"
                fail=$((fail + 1))
                rm -f "$expected" "$c_actual" "$c_err" "$actual" "$raw_actual" "$err"
                continue
            fi
            HERBERT_REPORT_PEAK=1 "$HERBERT" "$ERROR_DRIVER" <"$probe" >"$actual" 2>"$err"
            rc=$?
            if [[ $rc -ne 0 ]]; then
                echo "FAIL: stack/error_probes/$probe_name (driver: error_fragment.herb, stdin) (interpreter exit $rc)"
                echo "--- stderr"
                cat "$err"
                echo "--- stdout"
                cat "$actual"
                fail=$((fail + 1))
                rm -f "$expected" "$c_actual" "$c_err" "$actual" "$raw_actual" "$err"
            elif ! sed -n 's/^"\(.*\)"$/\1/p' "$actual" >"$raw_actual" || [[ ! -s "$raw_actual" ]]; then
                echo "FAIL: stack/error_probes/$probe_name (driver: error_fragment.herb, stdin) (expected canonical string output)"
                echo "--- stdout"
                cat "$actual"
                fail=$((fail + 1))
                rm -f "$expected" "$c_actual" "$c_err" "$actual" "$raw_actual" "$err"
            elif ! diff -u "$expected" "$raw_actual" >/tmp/herbert_diff.$$ 2>&1; then
                echo "FAIL: stack/error_probes/$probe_name (driver: error_fragment.herb, stdin) (output mismatch)"
                cat /tmp/herbert_diff.$$
                fail=$((fail + 1))
                rm -f /tmp/herbert_diff.$$ "$expected" "$c_actual" "$c_err" "$actual" "$raw_actual" "$err"
            else
                echo "PASS: stack/error_probes/$probe_name (driver: error_fragment.herb, stdin)"
                pass=$((pass + 1))
                rm -f "$expected" "$c_actual" "$c_err" "$actual" "$raw_actual" "$err"
            fi
        done < "$ERROR_MANIFEST"
    fi

    # Well-formed controls through the error fragment. These mirror the
    # input-fragment stdin checks and guard against over-rejection.
    if [[ -f "$ERROR_DRIVER" && -f "$INPUT_EVAL_PROBE" && -f "$INPUT_EVAL_EXPECTED" ]]; then
        total=$((total + 1))
        actual=$(mktemp)
        raw_actual=$(mktemp)
        err=$(mktemp)
        HERBERT_REPORT_PEAK=1 "$HERBERT" "$ERROR_DRIVER" <"$INPUT_EVAL_PROBE" >"$actual" 2>"$err"
        rc=$?
        if [[ $rc -ne 0 ]]; then
            echo "FAIL: stack/evaluator_probe (driver: error_fragment.herb, stdin) (interpreter exit $rc)"
            echo "--- stderr"
            cat "$err"
            echo "--- stdout"
            cat "$actual"
            fail=$((fail + 1))
            rm -f "$actual" "$raw_actual" "$err"
        elif ! sed -n 's/^"\(.*\)"$/\1/p' "$actual" >"$raw_actual" || [[ ! -s "$raw_actual" ]]; then
            echo "FAIL: stack/evaluator_probe (driver: error_fragment.herb, stdin) (expected canonical string output)"
            echo "--- stdout"
            cat "$actual"
            fail=$((fail + 1))
            rm -f "$actual" "$raw_actual" "$err"
        elif ! diff -u "$INPUT_EVAL_EXPECTED" "$raw_actual" >/tmp/herbert_diff.$$ 2>&1; then
            echo "FAIL: stack/evaluator_probe (driver: error_fragment.herb, stdin) (output mismatch)"
            cat /tmp/herbert_diff.$$
            fail=$((fail + 1))
            rm -f /tmp/herbert_diff.$$ "$actual" "$raw_actual" "$err"
        else
            echo "PASS: stack/evaluator_probe (driver: error_fragment.herb, stdin)"
            pass=$((pass + 1))
            rm -f "$actual" "$raw_actual" "$err"
        fi
    fi

    if [[ -f "$ERROR_DRIVER" && -f "$INPUT_PIPELINE_PROBE" ]]; then
        total=$((total + 1))
        oracle_display=$(mktemp)
        oracle=$(mktemp)
        actual=$(mktemp)
        raw_actual=$(mktemp)
        oracle_err=$(mktemp)
        err=$(mktemp)
        HERBERT_REPORT_PEAK=1 "$HERBERT" "$INPUT_PIPELINE_PROBE" >"$oracle_display" 2>"$oracle_err"
        rc=$?
        if [[ $rc -ne 0 ]]; then
            echo "FAIL: stack/pipeline_probe (driver: error_fragment.herb, stdin) (oracle exit $rc)"
            echo "--- oracle stderr"
            cat "$oracle_err"
            echo "--- oracle stdout"
            cat "$oracle_display"
            fail=$((fail + 1))
            rm -f "$oracle_display" "$oracle" "$actual" "$raw_actual" "$oracle_err" "$err"
        else
            tr -d ',' <"$oracle_display" >"$oracle"
            HERBERT_REPORT_PEAK=1 "$HERBERT" "$ERROR_DRIVER" <"$INPUT_PIPELINE_PROBE" >"$actual" 2>"$err"
            rc=$?
            if [[ $rc -ne 0 ]]; then
                echo "FAIL: stack/pipeline_probe (driver: error_fragment.herb, stdin) (interpreter exit $rc)"
                echo "--- stderr"
                cat "$err"
                echo "--- stdout"
                cat "$actual"
                fail=$((fail + 1))
                rm -f "$oracle_display" "$oracle" "$actual" "$raw_actual" "$oracle_err" "$err"
            elif ! sed -n 's/^"\(.*\)"$/\1/p' "$actual" >"$raw_actual" || [[ ! -s "$raw_actual" ]]; then
                echo "FAIL: stack/pipeline_probe (driver: error_fragment.herb, stdin) (expected canonical string output)"
                echo "--- stdout"
                cat "$actual"
                fail=$((fail + 1))
                rm -f "$oracle_display" "$oracle" "$actual" "$raw_actual" "$oracle_err" "$err"
            elif ! diff -u "$oracle" "$raw_actual" >/tmp/herbert_diff.$$ 2>&1; then
                echo "FAIL: stack/pipeline_probe (driver: error_fragment.herb, stdin) (output mismatch)"
                cat /tmp/herbert_diff.$$
                fail=$((fail + 1))
                rm -f /tmp/herbert_diff.$$ "$oracle_display" "$oracle" "$actual" "$raw_actual" "$oracle_err" "$err"
            else
                echo "PASS: stack/pipeline_probe (driver: error_fragment.herb, stdin)"
                pass=$((pass + 1))
                rm -f "$oracle_display" "$oracle" "$actual" "$raw_actual" "$oracle_err" "$err"
            fi
        fi
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
fi

echo
if [[ $fail -ne 0 ]]; then
    echo "$fail of $total test(s) failed."
    exit 1
fi
echo "$pass of $total test(s) passed."
exit 0
