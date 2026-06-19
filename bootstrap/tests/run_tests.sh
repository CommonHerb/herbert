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
source "./native_codegen_oracle.sh"

fail=0
pass=0
total=0
SLOPE_TOL_NUM=3
SLOPE_TOL_DEN=2
test_14a_heap=
test_14b_heap=
native_codegen_dispatch_tmp=

turnstile_tmp=
cleanup_run_tests() {
    if [[ -n "$native_codegen_dispatch_tmp" && -d "$native_codegen_dispatch_tmp" ]]; then
        rm -rf "$native_codegen_dispatch_tmp"
    fi
    if [[ -n "$turnstile_tmp" && -d "$turnstile_tmp" ]]; then
        rm -rf "$turnstile_tmp"
    fi
}
trap cleanup_run_tests EXIT

# --- turnstile (sovereignty link 9): the first SUBTRACTIVE link --------------
# Links 3-8 ADDED a C-free native execution path BESIDE C for each of the six
# metacircular fragments (lexer/parser/evaluator/vm/klondike/emitter). turnstile
# RETIRES C from GRADING them on the default `make test` path: each fragment
# native gate passes on its ENDURING C-free oracle leg (gen-1 ELF vs an
# INDEPENDENT hand-authored oracle -- strictly stronger than the C cross-check,
# since it catches a bug C and native SHARE), and the RETIREABLE native-vs-C
# faithfulness leg becomes OPT-IN (HERBERT_C_GRADE_CROSSCHECK=1 -- exactly the
# way `make reseed` preserves the one sanctioned C mint). Zero coverage loss.
# A counting-DELEGATING HERBERT shim instruments EXACTLY the six gate dispatches
# so check_fragment_grade_count (below) can fence the default path at ZERO C
# grading invocations -- the grading-path analogue of michoi's "C did not MINT"
# mint-count fence ("C did not GRADE"). This is the first link whose default
# run-path C footprint SHRINKS rather than grows.
turnstile_real_herbert="$HERBERT"
turnstile_crosscheck="${HERBERT_C_GRADE_CROSSCHECK:-0}"
turnstile_tmp="$(mktemp -d)"
turnstile_grade_count="$turnstile_tmp/frag_grade_count"
: >"$turnstile_grade_count"
turnstile_write_shim() {
    # Emit a counting-DELEGATING herbert shim: it records that a fragment gate
    # invoked the C interpreter as a grader, then DELEGATEs to the captured REAL
    # interpreter (so the gate still runs normally -- letting the bite-proof
    # exercise the real pre-turnstile behavior). Paths are shell-escaped via %q
    # (robust to spaces / odd chars); it execs the real interpreter, never itself.
    local shim="$1" count="$2"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'printf %s >> %q\n' "'C-GRADE\\n'" "$count"
        printf 'exec %q "$@"\n' "$turnstile_real_herbert"
    } >"$shim"
    chmod +x "$shim"
}
turnstile_grade_shim="$turnstile_tmp/herbert_grade_shim.sh"
turnstile_write_shim "$turnstile_grade_shim" "$turnstile_grade_count"
if [[ "$turnstile_crosscheck" == "1" ]]; then
    # Opt-in: run the native-vs-C faithfulness cross-check (requires C to exist).
    turnstile_frag_no_c=0
    turnstile_frag_herbert="$turnstile_real_herbert"
else
    # Default: C-free grading. <FRAG>_NATIVE_NO_C=1 skips each faithfulness leg;
    # the shim is a trip-wire the C-free gates never reach (caught by the fence
    # if a regression re-enters the C grading path).
    turnstile_frag_no_c=1
    turnstile_frag_herbert="$turnstile_grade_shim"
fi

# --- tollgate (sovereignty link 10): the second SUBTRACTIVE link ---------------
# turnstile retired C from grading the six metacircular fragments. tollgate
# retires C from grading the NATIVE-CODEGEN differential oracle (the 17 scripts
# run_native_codegen_link1..16 + rejects). Two moves: (1) the differential
# oracle's default flips c->golden (native artifacts graded against committed
# C-free goldens; the live-C re-validation is opt-in NATIVE_CODEGEN_ORACLE=c),
# retiring ~179 oracle C-grade calls; (2) every BESPOKE per-link C call -- link1
# (ELF-emitter fragment), link4 (mutated backends), link6/rejects (verifier-
# diagnostic drivers), link10 (self-host altimeter), link11 (layout introspection),
# link15 (trap parity) -- is retired by seed-compiling+running the .herb natively
# or grading an intrinsic property, with the live-C path preserved opt-in under
# NATIVE_CODEGEN_ORACLE=c. A counting-DELEGATING HERBERT shim (the turnstile
# writer, reused) wraps the ENTIRE native-codegen dispatch so
# check_native_codegen_grade_count fences the default at ZERO C grading
# invocations -- the native-codegen analogue of the turnstile "C did not GRADE"
# fence. The shim wraps the $HERBERT VARIABLE, so it counts EVERY C-grade idiom
# ($HERBERT $backend/$driver/$probe/$fragment/$be), not a single grepped pattern.
tollgate_oracle="${NATIVE_CODEGEN_ORACLE:-golden}"
tollgate_grade_count="$turnstile_tmp/nc_grade_count"
: >"$tollgate_grade_count"
tollgate_grade_shim="$turnstile_tmp/herbert_nc_grade_shim.sh"
turnstile_write_shim "$tollgate_grade_shim" "$tollgate_grade_count"
if [[ "$tollgate_oracle" == "golden" ]]; then
    # Default: C-free grading. The shim is a trip-wire the C-free scripts never
    # reach; the fence goes RED if a regression re-enters the C grading path.
    tollgate_nc_herbert="$tollgate_grade_shim"
else
    # Opt-in (NATIVE_CODEGEN_ORACLE=c): the live-C differential + per-link
    # cross-checks run against the real interpreter; the fence is disarmed.
    tollgate_nc_herbert="$turnstile_real_herbert"
fi

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

run_native_codegen_non_vacuity_check() {
    total=$((total + 1))
    local out="$native_codegen_dispatch_tmp/non_vacuity.out"
    local err="$native_codegen_dispatch_tmp/non_vacuity.err"
    if NATIVE_CODEGEN_COMPILER=/bin/false NATIVE_CODEGEN_ORACLE=golden HERBERT="$HERBERT" "$PWD/run_native_codegen_link2.sh" >"$out" 2>"$err"; then
        echo "FAIL: native-codegen switchover non-vacuity (/bin/false compiler unexpectedly passed)"
        fail=$((fail + 1))
    elif grep -q "compile p1 failed" "$out"; then
        echo "PASS: native-codegen switchover non-vacuity (/bin/false compiler fails at first Role-2 compile)"
        pass=$((pass + 1))
    else
        echo "FAIL: native-codegen switchover non-vacuity (unexpected failure mode)"
        echo "--- stdout"
        cat "$out"
        echo "--- stderr"
        cat "$err"
        fail=$((fail + 1))
    fi
}

run_native_codegen_corrupt_compiler_check() {
    total=$((total + 1))
    local wrapper="$native_codegen_dispatch_tmp/corrupt-native-codegen.sh"
    local out="$native_codegen_dispatch_tmp/corrupt.out"
    local err="$native_codegen_dispatch_tmp/corrupt.err"
    cat >"$wrapper" <<'SH'
#!/usr/bin/env bash
set -u
"$NATIVE_CODEGEN_REAL_COMPILER" "$@"
rc=$?
if [[ $rc -eq 0 && -f a.out ]]; then
    printf 'BAD!' | dd of=a.out bs=1 count=4 conv=notrunc >/dev/null 2>&1
fi
exit "$rc"
SH
    chmod +x "$wrapper"
    if NATIVE_CODEGEN_REAL_COMPILER="$NATIVE_CODEGEN_COMPILER" NATIVE_CODEGEN_COMPILER="$wrapper" NATIVE_CODEGEN_ORACLE=golden HERBERT="$HERBERT" "$PWD/run_native_codegen_link2.sh" >"$out" 2>"$err"; then
        echo "FAIL: native-codegen switchover corrupt-compiler proof (corrupting wrapper unexpectedly passed)"
        fail=$((fail + 1))
    elif grep -Eq "native exit non-zero|readelf -h failed|not an ELF" "$out"; then
        echo "PASS: native-codegen switchover corrupt-compiler proof (corrupted a.out is caught)"
        pass=$((pass + 1))
    else
        echo "FAIL: native-codegen switchover corrupt-compiler proof (unexpected failure mode)"
        echo "--- stdout"
        cat "$out"
        echo "--- stderr"
        cat "$err"
        fail=$((fail + 1))
    fi
}

check_native_codegen_grade_count() {
    # tollgate: the FENCE. On the default `make test` path the C interpreter must
    # GRADE the native-codegen suite (link1..16 + rejects) ZERO times -- the
    # differential oracle loads committed C-free goldens, and every per-link
    # bespoke C call is retired (seed-compiled+run natively, or an intrinsic
    # property graded directly). The count only increments inside the delegating
    # shim the ENTIRE native-codegen dispatch was wrapped with, so 0 here proves C
    # was not in their grading path -- the native-codegen analogue of the turnstile
    # "C did not GRADE" fence. The shim wraps the $HERBERT VARIABLE, so it counts
    # EVERY C-grade idiom ($HERBERT $backend/$driver/$probe/$fragment/$be), not one
    # grepped pattern -- strictly more complete than the prior presence grep.
    total=$((total + 1))
    if [[ "$tollgate_oracle" != "golden" ]]; then
        echo "PASS: native-codegen C-grade fence: opt-in live-C cross-check ran (NATIVE_CODEGEN_ORACLE=$tollgate_oracle -- the native-vs-C differential was exercised by request; the C-free fence is not asserted in this mode)"
        pass=$((pass + 1))
        return
    fi
    local got
    got=$(grep -c 'C-GRADE' "$tollgate_grade_count" 2>/dev/null || true)
    [[ -n "$got" ]] || got=0
    if [[ "$got" -eq 0 ]]; then
        echo "PASS: native-codegen C-grade count: 0 (the C interpreter did NOT grade link1..16+rejects -- each passed C-free on the committed golden / seed-compiled native path)"
        pass=$((pass + 1))
    else
        echo "FAIL: native-codegen C-grade count: $got (expected 0 -- the C interpreter re-entered the native-codegen grading path on the default run)"
        cat "$tollgate_grade_count"
        fail=$((fail + 1))
    fi
}

check_native_codegen_grade_gating_present() {
    # Static backstop to the behavioral fence -- it DE-HOLES the prior
    # named-exception presence grep (which matched only `"$HERBERT" "$backend"`
    # and carved out two named sites). Every native-codegen script must EXIST + be
    # executable (so a deleted gate cannot pass vacuously by recording zero C
    # calls) and route C ONLY via the $HERBERT variable -- no command-position
    # hardcoded `herbert` binary (build/herbert) and no unconditional HERBERT=
    # override -- so the injected counting shim cannot be bypassed.
    # (check_native_codegen_grade_count is the primary guard: any $HERBERT C call
    # that fires under the default golden run is counted, in ANY idiom.)
    total=$((total + 1))
    local bad="" s n
    for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 rejects; do
        if [[ "$n" == "rejects" ]]; then
            s="$PWD/run_native_codegen_rejects.sh"
        else
            s="$PWD/run_native_codegen_link${n}.sh"
        fi
        if [[ ! -x "$s" ]]; then
            bad="$bad ${n}(missing-or-not-exec)"
            continue
        fi
        # Forbid a COMMAND-POSITION invocation of a hardcoded lowercase `herbert`
        # binary that bypasses $HERBERT. Strip full-line comments first (the
        # scripts narrate "herbert's runtime fault" etc.), then two patterns
        # (cross-model + same-model review both flagged the turnstile space-only
        # pattern alone misses a quote-immediate path "build/herbert"$x):
        # (a) the validated turnstile pattern -- `herbert` + space + quote/var/
        # redirect/pipe (catches `build/herbert "$x"`); (b) any `build/herbert`
        # path token NOT inside a ${HERBERT:-...} default-fallback (catches the
        # quoted `"build/herbert" "$x"`). $HERBERT is uppercase so never matches.
        local decommented
        decommented="$(grep -vE '^[[:space:]]*#' "$s")"
        if printf '%s\n' "$decommented" | grep -qE '(^|[^[:alnum:]_])herbert[[:space:]]+["'\''$<>|]'; then
            bad="$bad ${n}(hardcoded-C-call)"
        fi
        if printf '%s\n' "$decommented" | grep -E 'build/herbert' | grep -vE ':[-=]' | grep -q .; then
            bad="$bad ${n}(hardcoded-build-herbert)"
        fi
        if grep -nE '^[[:space:]]*HERBERT=' "$s" | grep -vE '\$\{?HERBERT' | grep -q .; then
            bad="$bad ${n}(unconditional-HERBERT-override)"
        fi
    done
    if [[ -z "$bad" ]]; then
        echo "PASS: native-codegen C-grade gating present (all 17 scripts exist+executable and route C only via \$HERBERT -- the counting shim cannot be bypassed by a hardcoded C call)"
        pass=$((pass + 1))
    else
        echo "FAIL: native-codegen C-grade gating present (issues:$bad)"
        fail=$((fail + 1))
    fi
}

run_native_codegen_grade_fence_mutation() {
    # Prove the C-grade fence BITES on the REAL pre-tollgate behavior (the live-C
    # differential oracle + per-link C calls -- exactly the grading path this link
    # removes), not a poison-only setup: re-run representative scripts -- link2 (a
    # pure differential-oracle link) and link1 (a bespoke ELF-emitter link) -- under
    # NATIVE_CODEGEN_ORACLE=c with a delegating counting shim. Each must still
    # SUCCEED (rc 0 -- a real completed C-grade, not a crash) and the total count
    # must be nonzero. That nonzero count is exactly what
    # check_native_codegen_grade_count would catch under the (now-default) golden run.
    total=$((total + 1))
    local mcount="$turnstile_tmp/nc_grade_count.mutation"
    local mshim="$turnstile_tmp/herbert_nc_grade_shim.mutation.sh"
    : >"$mcount"
    turnstile_write_shim "$mshim" "$mcount"
    local ran=0 ok=0 rc s
    for s in "$PWD/run_native_codegen_link2.sh" "$PWD/run_native_codegen_link1.sh"; do
        if [[ ! -x "$s" ]]; then
            echo "FAIL: native-codegen C-grade fence mutation (representative script $s missing -- cannot prove the fence bites)"
            fail=$((fail + 1)); return
        fi
        NATIVE_CODEGEN_ORACLE=c HERBERT="$mshim" "$s" >/dev/null 2>&1
        rc=$?
        ran=$((ran + 1))
        [[ $rc -eq 0 ]] && ok=$((ok + 1))
    done
    local got
    got=$(grep -c 'C-GRADE' "$mcount" 2>/dev/null || true)
    [[ -n "$got" ]] || got=0
    if [[ "$ran" -eq 2 && "$ok" -eq 2 && "$got" -gt 0 ]]; then
        echo "PASS: native-codegen C-grade fence mutation (the pre-tollgate default -- NATIVE_CODEGEN_ORACLE=c -- invoked C $got times across $ran scripts, both succeeding; check_native_codegen_grade_count would go RED on it; the fence bites on real prior behavior, not a poison-only setup)"
        pass=$((pass + 1))
    else
        echo "FAIL: native-codegen C-grade fence mutation (expected ran=2 ok=2 got>0 under NATIVE_CODEGEN_ORACLE=c; got ran=$ran ok=$ok got=$got -- the fence may be vacuous or C delegation failed)"
        fail=$((fail + 1))
    fi
}

check_native_codegen_mint_count() {
    # michoi: the FENCE. In the default (seeded) run the C interpreter must mint
    # gen-1 ZERO times -- the production compiler comes from the committed C-free
    # seed. The C mint runs exactly once only when explicitly re-seeding
    # (NATIVE_CODEGEN_ALLOW_C_MINT=1). The count only ever increments inside
    # native_codegen_compiler_mint, so 0 here proves C was not in the mint path.
    total=$((total + 1))
    local got want
    got="${NATIVE_CODEGEN_COMPILER_MINT_COUNT:-0}"
    if [[ "${NATIVE_CODEGEN_ALLOW_C_MINT:-0}" == "1" ]]; then want=1; else want=0; fi
    if [[ "$got" == "$want" ]]; then
        if [[ "$want" == "0" ]]; then
            echo "PASS: native-codegen gen-1 C-mint count: 0 (C-free seed -- the C interpreter did NOT mint the production compiler)"
        else
            echo "PASS: native-codegen gen-1 C-mint count: 1 (re-seed mode; seconds=${NATIVE_CODEGEN_COMPILER_MINT_SECONDS:-unknown})"
        fi
        pass=$((pass + 1))
    else
        echo "FAIL: native-codegen gen-1 C-mint count: $got (expected $want)"
        fail=$((fail + 1))
    fi
}

check_fragment_grade_count() {
    # turnstile: the FENCE. On the default `make test` path the C interpreter must
    # GRADE the six metacircular-fragment native gates ZERO times -- each gate
    # passes on its ENDURING C-free oracle leg, and the RETIREABLE native-vs-C
    # faithfulness leg is opt-in (HERBERT_C_GRADE_CROSSCHECK=1). The count only
    # ever increments inside the delegating shim the six gates were dispatched
    # with, so 0 here proves C was not in their grading path -- the grading-path
    # analogue of the michoi "C did not MINT" mint-count fence ("C did not GRADE").
    total=$((total + 1))
    if [[ "$turnstile_crosscheck" == "1" ]]; then
        echo "PASS: fragment-gate C-grade fence: opt-in cross-check ran (HERBERT_C_GRADE_CROSSCHECK=1 -- native-vs-C faithfulness exercised by request; the C-free fence is not asserted in this mode)"
        pass=$((pass + 1))
        return
    fi
    local got
    got=$(grep -c 'C-GRADE' "$turnstile_grade_count" 2>/dev/null || true)
    [[ -n "$got" ]] || got=0
    if [[ "$got" -eq 0 ]]; then
        echo "PASS: fragment-gate C-grade count: 0 (the C interpreter did NOT grade the 6 metacircular fragments -- each passed C-free on its enduring oracle leg)"
        pass=$((pass + 1))
    else
        echo "FAIL: fragment-gate C-grade count: $got (expected 0 -- the C interpreter re-entered the fragment grading path on the default run)"
        cat "$turnstile_grade_count"
        fail=$((fail + 1))
    fi
}

check_fragment_grade_gating_present() {
    # Secondary STATIC backstop to the behavioral fence (closes two gaps the
    # cross-model review flagged): (1) all six fragment native gates must EXIST and
    # be executable, so a deleted/disabled gate cannot pass vacuously by recording
    # zero C calls; (2) every gate must retain its <FRAG>_NATIVE_NO_C opt-out AND
    # route its C-grader call through the $HERBERT variable -- no hardcoded
    # build/herbert at a command position (a ':-'/':=' default-fallback, comment,
    # or "cannot find" error string is fine; those never override an injected
    # HERBERT) -- so the injected counting shim cannot be bypassed.
    # (check_fragment_grade_count is the primary behavioral guard: any UNGUARDED
    # $HERBERT grade call would still hit the shim and be counted.)
    total=$((total + 1))
    local bad="" g flag s
    for g in lexer parser evaluator vm klondike emitter; do
        flag="$(printf '%s' "$g" | tr '[:lower:]' '[:upper:]')_NATIVE_NO_C"
        s="$PWD/run_${g}_native.sh"
        if [[ ! -x "$s" ]]; then
            bad="$bad ${g}(missing-or-not-exec)"
            continue
        fi
        grep -q "$flag" "$s" || bad="$bad ${g}(no-NO_C-guard)"
        # Forbid a COMMAND-POSITION invocation of the C interpreter binary that
        # bypasses $HERBERT -- a hardcoded lowercase `herbert` path (e.g.
        # build/herbert) called with an arg/redirect/pipe. $HERBERT is UPPERCASE so
        # this never matches the variable; a ':-' default-fallback (build/herbert}),
        # the "cannot find herbert at $HERBERT" error string (herbert at ...), and
        # comments are command-position-safe (validated: zero match on all 6 gates).
        if grep -nE '(^|[^[:alnum:]_])herbert[[:space:]]+["'\''$<>|]' "$s" | grep -q .; then
            bad="$bad ${g}(hardcoded-C-call)"
        fi
        # Forbid an UNCONDITIONAL HERBERT= override (one whose RHS ignores the
        # injected ${HERBERT}); the gates' "${HERBERT:-default}" fallback is fine.
        if grep -nE '^[[:space:]]*HERBERT=' "$s" | grep -vE '\$\{?HERBERT' | grep -q .; then
            bad="$bad ${g}(unconditional-HERBERT-override)"
        fi
    done
    if [[ -z "$bad" ]]; then
        echo "PASS: fragment-gate C-grade gating present (all 6 native gates exist+executable, retain their *_NATIVE_NO_C opt-out, and route C only via \$HERBERT -- the C-free default cannot be silently removed or bypassed)"
        pass=$((pass + 1))
    else
        echo "FAIL: fragment-gate C-grade gating present (issues:$bad)"
        fail=$((fail + 1))
    fi
}

run_fragment_grade_fence_mutation() {
    # Prove the C-grade fence BITES on the REAL pre-turnstile behavior (NO_C=0, the
    # flag's unset default -- exactly the grading path this link removes), not a poison-only
    # setup: re-run BOTH representative fragment gates (lexer+emitter, smallest for
    # runtime; the NO_C mechanism is identical across all six) with the faithfulness
    # leg ENABLED, counting C invocations via a delegating shim. Each gate must
    # still SUCCEED (rc 0 -- so the count reflects a real, completed C-grader call,
    # not a crash), and the count must equal the gate count (each invokes C exactly
    # once). That nonzero count is what check_fragment_grade_count would catch.
    total=$((total + 1))
    local mcount="$turnstile_tmp/frag_grade_count.mutation"
    local mshim="$turnstile_tmp/herbert_grade_shim.mutation.sh"
    : >"$mcount"
    turnstile_write_shim "$mshim" "$mcount"
    local ran=0 ok=0 rc g flag
    for g in lexer emitter; do
        if [[ ! -x "$PWD/run_${g}_native.sh" ]]; then
            echo "FAIL: fragment-gate C-grade fence mutation (representative gate $g missing -- cannot prove the fence bites)"
            fail=$((fail + 1)); return
        fi
        flag="$(printf '%s' "$g" | tr '[:lower:]' '[:upper:]')_NATIVE_NO_C"
        # NO_C=0 == the pre-turnstile default: the faithfulness leg runs and calls C.
        env "$flag=0" HERBERT="$mshim" "$PWD/run_${g}_native.sh" >/dev/null 2>&1
        rc=$?
        ran=$((ran + 1))
        [[ $rc -eq 0 ]] && ok=$((ok + 1))
    done
    local got
    got=$(grep -c 'C-GRADE' "$mcount" 2>/dev/null || true)
    [[ -n "$got" ]] || got=0
    if [[ "$ran" -eq 2 && "$ok" -eq 2 && "$got" -eq 2 ]]; then
        echo "PASS: fragment-gate C-grade fence mutation (the pre-turnstile default -- NO_C=0, the flag's unset default, the grading path this link removes -- invoked C exactly $got times across $ran gates, both succeeding; check_fragment_grade_count would go RED on it; the fence bites on real prior behavior, not a poison-only setup)"
        pass=$((pass + 1))
    else
        echo "FAIL: fragment-gate C-grade fence mutation (expected ran=2 ok=2 got=2 under the pre-turnstile default; got ran=$ran ok=$ok got=$got -- the fence may be vacuous or C delegation failed)"
        fail=$((fail + 1))
    fi
}

run_native_codegen_michoi_seed_check() {
    # michoi: prove the production compiler this run used IS the committed,
    # integrity-checked, C-free gen-1 seed. (The seed's C-free SELF-REPRODUCTION
    # -- seed compiles the backend back into the seed -- is proven by the link10
    # fixpoint, which runs under make test.)
    total=$((total + 1))
    local seed magic want got used
    seed="$native_codegen_seed_file"
    if [[ ! -f "$seed" || ! -f "$seed.sha256" ]]; then
        echo "FAIL: michoi C-free seed (missing $seed)"; fail=$((fail + 1)); return
    fi
    magic=$(head -c4 "$seed" | xxd -p | tr -d '\n')
    want=$(awk '{print $1}' "$seed.sha256")
    got=$(sha256sum "$seed" | awk '{print $1}')
    if [[ "$magic" != "7f454c46" || "$got" != "$want" ]]; then
        echo "FAIL: michoi C-free seed integrity (magic=$magic sha got=$got want=$want)"; fail=$((fail + 1)); return
    fi
    if [[ -z "${NATIVE_CODEGEN_COMPILER:-}" || ! -x "$NATIVE_CODEGEN_COMPILER" ]]; then
        echo "FAIL: michoi C-free seed (no production compiler acquired)"; fail=$((fail + 1)); return
    fi
    # In seeded mode the production compiler must be byte-identical to the seed.
    if [[ "${NATIVE_CODEGEN_ALLOW_C_MINT:-0}" != "1" ]]; then
        used=$(sha256sum "$NATIVE_CODEGEN_COMPILER" | awk '{print $1}')
        if [[ "$used" != "$want" ]]; then
            echo "FAIL: michoi C-free seed (production compiler sha=$used != committed seed sha=$want -- the run did not use the seed)"; fail=$((fail + 1)); return
        fi
    fi
    echo "PASS: michoi C-free gen-1 seed (committed seed integrity OK; production compiler IS the seed; C did not mint it)"
    pass=$((pass + 1))
}

run_recursion_depth_guard_check() {
    # The C bootstrap must fail pathologically deep nesting with a CLEAN
    # diagnostic, never a C-stack overflow (SIGSEGV/139). The parser's four
    # recursive sites share ONE depth budget (P.depth, one limit, one
    # "nesting too deep" diagnostic): parens, call-args and nested tuples
    # re-enter parse_expr; nested-if arms re-enter parse_block (its increment is
    # what bounds statement nesting — verified: removing it overflows ~100k-deep
    # ifs); not/tilde prefix chains re-enter parse_not; nested array types
    # re-enter parse_type. A seventh shape, deepvalue, builds an n-deep nested
    # value with TAIL recursion (so the evaluator runs flat and the only deep C
    # recursion is the canonical printer v_print_canonical_rec, PRINT_MAX_DEPTH)
    # and prints it. Every shape is driven past its empirical overflow threshold,
    # so a regressed/removed guard SIGSEGVs (rc=139) and the shape goes RED;
    # post-guard each must exit nonzero (NOT 139) with its expected diagnostic.
    # parens<->calls is a renamed-twin; nots<->tildes twin the parse_not branches.
    local shape prog err rc label depth want
    for shape in parens calls ifs nots tildes types deepvalue; do
        total=$((total + 1))
        want="nesting too deep"
        case "$shape" in
            parens|calls)  depth=50000 ;;
            ifs)           depth=250000 ;;
            nots|tildes)   depth=300000 ;;
            types)         depth=400000 ;;
            deepvalue)     depth=300000; want="value nested too deep to print" ;;
        esac
        label="recursion depth guard ($shape, $depth deep)"
        prog=$(mktemp)
        err=$(mktemp)
        case "$shape" in
            parens)
                python3 -c "import sys; n=int(sys.argv[1]); sys.stdout.write('func main():\n    return '+'('*n+'0'+')'*n+'\nend\n')" "$depth" >"$prog" ;;
            calls)
                python3 -c "import sys; n=int(sys.argv[1]); sys.stdout.write('func id(x): return x end\nfunc main():\n    return '+'id('*n+'0'+')'*n+'\nend\n')" "$depth" >"$prog" ;;
            ifs)
                python3 -c "import sys; n=int(sys.argv[1]); sys.stdout.write('func main():\n'+'    if true:\n'*n+'        return 0\n'+'    end\n'*n+'end\n')" "$depth" >"$prog" ;;
            nots)
                python3 -c "import sys; n=int(sys.argv[1]); sys.stdout.write('func main():\n    return '+'not '*n+'true\nend\n')" "$depth" >"$prog" ;;
            tildes)
                python3 -c "import sys; n=int(sys.argv[1]); sys.stdout.write('func main():\n    return '+'~'*n+'0\nend\n')" "$depth" >"$prog" ;;
            types)
                python3 -c "import sys; n=int(sys.argv[1]); sys.stdout.write('func main():\n    let a = new_array('+'array('*n+'int'+')'*n+')\n    return 0\nend\n')" "$depth" >"$prog" ;;
            deepvalue)
                # Tail-recursive accumulator: `return wrap(...)` is tail-called,
                # so the evaluator runs flat (the n-deep value lives on the heap,
                # not the C stack). Returning it forces the canonical printer to
                # descend n deep, so pre-guard this SIGSEGVs ONLY in the printer.
                python3 -c "import sys; n=int(sys.argv[1]); sys.stdout.write('func wrap(k, acc):\n    if k == 0:\n        return acc\n    end\n    return wrap(k - 1, (acc, 0))\nend\nfunc main():\n    return wrap(%d, 0)\nend\n' % n)" "$depth" >"$prog" ;;
        esac
        HERBERT_REPORT_PEAK=1 "$HERBERT" "$prog" >/dev/null 2>"$err"
        rc=$?
        if [[ $rc -eq 139 ]]; then
            echo "FAIL: $label (SIGSEGV — recursion depth guard missing/ineffective)"
            fail=$((fail + 1))
        elif [[ $rc -eq 0 ]]; then
            echo "FAIL: $label (deep input accepted — guard did not fire)"
            fail=$((fail + 1))
        elif grep -q "$want" "$err"; then
            echo "PASS: $label (clean diagnostic: $want, exit $rc)"
            pass=$((pass + 1))
        else
            echo "FAIL: $label (nonzero exit $rc but missing diagnostic '$want')"
            echo "--- stderr"
            cat "$err"
            fail=$((fail + 1))
        fi
        rm -f "$prog" "$err"
    done
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

run_recursion_depth_guard_check

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

    # Lexer forcing-function test: the lexer fragment (embedding lexer_probe.herb
    # byte-for-byte in its main()) now EMITS its serialized token stream via flogger
    # (stdout line 1) + returns 0, so it runs identically under the C interpreter AND
    # the native gen-1 compiler (the native execution path is gated by
    # run_lexer_native.sh below). Diff stdout line 1 against the hand-authored answer
    # key (the canonical token stream in lexer_probe.expected, never produced by any
    # lexer).
    LEX_DRIVER="$STACK_DIR/lexer_fragment.herb"
    LEX_PROBE_EXPECTED="$STACK_DIR/lexer_probe.expected"
    if [[ -f "$LEX_DRIVER" && -f "$LEX_PROBE_EXPECTED" ]]; then
        total=$((total + 1))
        actual=$(mktemp)
        raw_actual=$(mktemp)
        err=$(mktemp)
        HERBERT_REPORT_PEAK=1 "$HERBERT" "$LEX_DRIVER" >"$actual" 2>"$err"
        rc=$?
        if [[ $rc -ne 0 ]]; then
            echo "FAIL: stack/lexer_probe (driver: lexer_fragment.herb) (interpreter exit $rc)"
            echo "--- stderr"
            cat "$err"
            echo "--- stdout"
            cat "$actual"
            fail=$((fail + 1))
            rm -f "$actual" "$raw_actual" "$err"
        elif ! head -1 "$actual" >"$raw_actual" || [[ ! -s "$raw_actual" ]]; then
            echo "FAIL: stack/lexer_probe (driver: lexer_fragment.herb) (expected serialized line-1 output)"
            echo "--- stdout"
            cat "$actual"
            fail=$((fail + 1))
            rm -f "$actual" "$raw_actual" "$err"
        elif ! diff -u "$LEX_PROBE_EXPECTED" "$raw_actual" >/tmp/herbert_diff.$$ 2>&1; then
            echo "FAIL: stack/lexer_probe (driver: lexer_fragment.herb) (output mismatch)"
            cat /tmp/herbert_diff.$$
            fail=$((fail + 1))
            rm -f /tmp/herbert_diff.$$ "$actual" "$raw_actual" "$err"
        else
            echo "PASS: stack/lexer_probe (driver: lexer_fragment.herb)"
            pass=$((pass + 1))
            rm -f "$actual" "$raw_actual" "$err"
        fi
    fi

    # Lexer NATIVE-EXECUTION gate (sovereignty axis, Role-C reduction): the C-free
    # gen-1 seed compiles lexer_fragment.herb to an ELF that scans+classifies+serializes
    # with NO C in its execution path; its stdout line 1 must equal the independent
    # oracle (ENDURING) and -- while a C interpreter still exists -- the interpreter's
    # output (RETIREABLE faithfulness guard). The FOURTH metacircular fragment to gain a
    # committed native execution path (after the evaluator, the VM, and the parser); the
    # lexer self-description test now survives C's deletion (only klondike remains).
    if [[ -x "$PWD/run_lexer_native.sh" ]]; then
        total=$((total + 1))
        if LEXER_NATIVE_NO_C="$turnstile_frag_no_c" HERBERT="$turnstile_frag_herbert" "$PWD/run_lexer_native.sh"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    # Prove the lexer native-execution gate BITES (RED-first): a mutated lex rule
    # (a character-class -> token-kind classification) still compiles natively but
    # makes the C-free ELF emit a divergent token stream.
    if [[ -x "$PWD/run_lexer_native_mutation.sh" ]]; then
        total=$((total + 1))
        if "$PWD/run_lexer_native_mutation.sh"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    # C-vs-Herbert lexer equivalence: normalize the bootstrap C token stream
    # to the Herbert lexer fragment's coarse `(kind, text)` shape and diff it
    # against the same hand-authored oracle as the Herbert-side lexer test.
    if [[ -x "$PWD/run_lexer_equivalence.sh" ]]; then
        total=$((total + 1))
        if "$PWD/run_lexer_equivalence.sh"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    # C-vs-Herbert PARSER equivalence (sovereignty parser altimeter): diff the
    # independent C parse.c AST (parser_equiv_dump.c) against the PRODUCTION
    # Herbert parser's AST (emitted by the backend's `-- emit: ast-dump` mode,
    # run NATIVELY by the gen-1 seed and by the C interpreter) over a corpus.
    if [[ -x "$PWD/run_parser_equivalence.sh" ]]; then
        total=$((total + 1))
        if "$PWD/run_parser_equivalence.sh"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    # Prove the parser-equivalence altimeter BITES (RED-first): mutating the C
    # parser OR the production Herbert parser flips the AST diff to divergent.
    if [[ -x "$PWD/run_parser_equivalence_mutation.sh" ]]; then
        total=$((total + 1))
        if "$PWD/run_parser_equivalence_mutation.sh"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    # Parser forcing-function test: the parser fragment (embedding parser_probe.herb
    # byte-for-byte in its main()) now EMITS its serialized S-expression via flogger
    # (stdout line 1) + returns 0, so it runs identically under the C interpreter AND
    # the native gen-1 compiler (the native execution path is gated by
    # run_parser_native.sh below). Diff stdout line 1 against the hand-authored answer
    # key (the raw S-expression in parser_probe.expected, never produced by any parser).
    PARSE_DRIVER="$STACK_DIR/parser_fragment.herb"
    PARSE_PROBE_EXPECTED="$STACK_DIR/parser_probe.expected"
    if [[ -f "$PARSE_DRIVER" && -f "$PARSE_PROBE_EXPECTED" ]]; then
        total=$((total + 1))
        actual=$(mktemp)
        raw_actual=$(mktemp)
        err=$(mktemp)
        HERBERT_REPORT_PEAK=1 "$HERBERT" "$PARSE_DRIVER" >"$actual" 2>"$err"
        rc=$?
        if [[ $rc -ne 0 ]]; then
            echo "FAIL: stack/parser_probe (driver: parser_fragment.herb) (interpreter exit $rc)"
            echo "--- stderr"
            cat "$err"
            echo "--- stdout"
            cat "$actual"
            fail=$((fail + 1))
            rm -f "$actual" "$raw_actual" "$err"
        elif ! head -1 "$actual" >"$raw_actual" || [[ ! -s "$raw_actual" ]]; then
            echo "FAIL: stack/parser_probe (driver: parser_fragment.herb) (expected serialized line-1 output)"
            echo "--- stdout"
            cat "$actual"
            fail=$((fail + 1))
            rm -f "$actual" "$raw_actual" "$err"
        elif ! diff -u "$PARSE_PROBE_EXPECTED" "$raw_actual" >/tmp/herbert_diff.$$ 2>&1; then
            echo "FAIL: stack/parser_probe (driver: parser_fragment.herb) (output mismatch)"
            cat /tmp/herbert_diff.$$
            fail=$((fail + 1))
            rm -f /tmp/herbert_diff.$$ "$actual" "$raw_actual" "$err"
        else
            echo "PASS: stack/parser_probe (driver: parser_fragment.herb)"
            pass=$((pass + 1))
            rm -f "$actual" "$raw_actual" "$err"
        fi
    fi

    # Parser NATIVE-EXECUTION gate (sovereignty axis, Role-C reduction): the C-free
    # gen-1 seed compiles parser_fragment.herb to an ELF that lexes+parses+serializes
    # with NO C in its execution path; its stdout line 1 must equal the independent
    # oracle (ENDURING) and -- while a C interpreter still exists -- the interpreter's
    # output (RETIREABLE faithfulness guard). The THIRD metacircular fragment to gain a
    # committed native execution path (after the evaluator and the VM); the parser
    # self-description test now survives C's deletion.
    if [[ -x "$PWD/run_parser_native.sh" ]]; then
        total=$((total + 1))
        if PARSER_NATIVE_NO_C="$turnstile_frag_no_c" HERBERT="$turnstile_frag_herbert" "$PWD/run_parser_native.sh"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    # Prove the parser native-execution gate BITES (RED-first): a mutated parse rule
    # (an operator -> AST-tag mapping) still compiles natively but makes the C-free
    # ELF emit a divergent S-expression.
    if [[ -x "$PWD/run_parser_native_mutation.sh" ]]; then
        total=$((total + 1))
        if "$PWD/run_parser_native_mutation.sh"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    # Evaluator forcing-function test: the evaluator fragment EMITS the
    # serialized probe result via flogger (stdout line 1) and returns 0, so it
    # runs identically under the C interpreter AND the native gen-1 compiler
    # (the native execution path is gated by run_evaluator_native.sh below).
    # Diff stdout line 1 against the hand-authored answer key.
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
        elif ! head -1 "$actual" >"$raw_actual" || [[ ! -s "$raw_actual" ]]; then
            echo "FAIL: stack/evaluator_probe (driver: evaluator_fragment.herb) (expected serialized line-1 output)"
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

    # Evaluator NATIVE-EXECUTION gate (sovereignty axis, Role-C reduction): the
    # C-free gen-1 seed compiles evaluator_fragment.herb to an ELF that runs with
    # NO C in its execution path; its stdout line 1 must equal the independent
    # oracle (ENDURING) and -- while a C interpreter still exists -- the
    # interpreter's output (RETIREABLE faithfulness guard). This is the first
    # metacircular fragment to gain a committed native execution path, so the
    # evaluator self-description test now survives C's deletion.
    if [[ -x "$PWD/run_evaluator_native.sh" ]]; then
        total=$((total + 1))
        if EVALUATOR_NATIVE_NO_C="$turnstile_frag_no_c" HERBERT="$turnstile_frag_herbert" "$PWD/run_evaluator_native.sh"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    # Prove the evaluator native-execution gate BITES (RED-first): a mutated
    # evaluator rule still compiles natively but makes the C-free ELF diverge
    # from the oracle.
    if [[ -x "$PWD/run_evaluator_native_mutation.sh" ]]; then
        total=$((total + 1))
        if "$PWD/run_evaluator_native_mutation.sh"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    # link11 (sovereignty axis, D14 aggregate half): the native back end now
    # canonically renders a `main` returning a FLAT int/bool TUPLE, so the
    # foundational language tests that return a tuple (test_01/03/07/08/09) run
    # C-FREE via the gen-1 seed. ENDURING leg = native render == committed key;
    # RETIREABLE leg = faithfulness vs C (real HERBERT, NOT the fragment shim --
    # this gate is its own capability gate, under neither the turnstile fragment
    # fence nor the tollgate native-codegen fence).
    if [[ -x "$PWD/run_aggregate_render_native.sh" ]]; then
        total=$((total + 1))
        if HERBERT="$HERBERT" "$PWD/run_aggregate_render_native.sh"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    # Prove the aggregate-render gate BITES (RED-first): a mutated renderer still
    # compiles but makes the rendered tuple diverge from the canonical key.
    if [[ -x "$PWD/run_aggregate_render_native_mutation.sh" ]]; then
        total=$((total + 1))
        if "$PWD/run_aggregate_render_native_mutation.sh"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    # VM forcing-function test: the VM fragment runs the blessed bytecode for the
    # same evaluator probe and now EMITS the serialized result via flogger (stdout
    # line 1) + returns 0, so it runs identically under the C interpreter AND the
    # native gen-1 compiler (the native execution path is gated by run_vm_native.sh
    # below). Reuse the evaluator oracle; diff stdout line 1.
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
        elif ! head -1 "$actual" >"$raw_actual" || [[ ! -s "$raw_actual" ]]; then
            echo "FAIL: stack/vm (driver: vm_fragment.herb) (expected serialized line-1 output)"
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

    # VM NATIVE-EXECUTION gate (sovereignty axis, Role-C reduction): the C-free
    # gen-1 seed compiles vm_fragment.herb to an ELF that runs the bytecode VM with
    # NO C in its execution path; its stdout line 1 must equal the independent
    # oracle (ENDURING) and -- while a C interpreter still exists -- the
    # interpreter's output (RETIREABLE faithfulness guard). The SECOND metacircular
    # fragment to gain a committed native execution path (after the evaluator); the
    # bytecode-VM self-description test now survives C's deletion.
    if [[ -x "$PWD/run_vm_native.sh" ]]; then
        total=$((total + 1))
        if VM_NATIVE_NO_C="$turnstile_frag_no_c" HERBERT="$turnstile_frag_herbert" "$PWD/run_vm_native.sh"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    # Prove the VM native-execution gate BITES (RED-first): a mutated bytecode-VM
    # opcode handler still compiles natively but makes the C-free ELF diverge from
    # the oracle.
    if [[ -x "$PWD/run_vm_native_mutation.sh" ]]; then
        total=$((total + 1))
        if "$PWD/run_vm_native_mutation.sh"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    # Klondike NATIVE-EXECUTION gate (sovereignty axis, Role-C reduction -- the LAST
    # and FIFTH metacircular fragment). The C-free gen-1 seed compiles a one-line
    # main-adapted klondike (the full toolchain: lex+parse+check+lower+VM+serialize)
    # to an ELF that compiles+runs an embedded probe with NO C in its execution path;
    # its transcript must equal the independent oracle (ENDURING) and -- while a C
    # interpreter still exists -- the interpreter's output (RETIREABLE faithfulness
    # guard). klondike.herb is byte-identical (the adapter is applied at gate time so
    # its meta-circular-suite role is preserved). With this, ALL FIVE metacircular
    # fragments survive C's deletion.
    if [[ -x "$PWD/run_klondike_native.sh" ]]; then
        total=$((total + 1))
        if KLONDIKE_NATIVE_NO_C="$turnstile_frag_no_c" HERBERT="$turnstile_frag_herbert" "$PWD/run_klondike_native.sh"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    # Prove the klondike native-execution gate BITES (RED-first): a mutated VM rule
    # (int_binop's + / < / == ) still compiles natively but makes the C-free ELF emit
    # a divergent result tuple.
    if [[ -x "$PWD/run_klondike_native_mutation.sh" ]]; then
        total=$((total + 1))
        if "$PWD/run_klondike_native_mutation.sh"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    # Emitter NATIVE-EXECUTION gate (sovereignty axis, Role-C reduction -- the SIXTH and
    # FINAL metacircular fragment). The C-free gen-1 seed compiles a one-line main-adapted
    # emitter_fragment (the standalone AST->bytecode CODE GENERATOR: lower_program /
    # emit_expr / opcode_for_binop / serialize_bytecode) to an ELF that lowers the embedded
    # probe to bytecode with NO C in its execution path; its serialized listing must equal
    # the independent oracle stack/emitter_probe.expected (ENDURING) and -- while a C
    # interpreter still exists -- the interpreter's listing (RETIREABLE faithfulness guard).
    # emitter_fragment.herb is byte-identical (the adapter is applied at gate time, so the
    # existing C emitter_probe test still runs the unmodified fragment -- purely additive).
    # The emitter is the only fragment that pins the lowering PRODUCT (codegen structure at
    # the instruction level), invisible to the five value-observing fragments. With this,
    # ALL SIX metacircular fragments survive C's deletion.
    if [[ -x "$PWD/run_emitter_native.sh" ]]; then
        total=$((total + 1))
        if EMITTER_NATIVE_NO_C="$turnstile_frag_no_c" HERBERT="$turnstile_frag_herbert" "$PWD/run_emitter_native.sh"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    # Prove the emitter native-execution gate BITES (RED-first): a mutated reachable
    # LOWERING rule (an opcode mapping / a frame-slot allocation / a control-flow branch)
    # still compiles natively but makes the C-free ELF emit a divergent bytecode listing.
    if [[ -x "$PWD/run_emitter_native_mutation.sh" ]]; then
        total=$((total + 1))
        if "$PWD/run_emitter_native_mutation.sh"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    # turnstile (sovereignty link 9): the six fragment native gates above ran on
    # the default C-free path; fence the default at ZERO C grading invocations,
    # prove the gating is intact, and prove the fence BITES on the real
    # pre-turnstile default.
    check_fragment_grade_count
    check_fragment_grade_gating_present
    run_fragment_grade_fence_mutation

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
    backend="$STACK_DIR/native_compile_fragment.herb"
    native_codegen_dispatch_tmp="$(mktemp -d)"
    # michoi: source the production gen-1 from the committed C-free seed (the C
    # interpreter is no longer in the mint path). ensure_compiler reuses a preset
    # NATIVE_CODEGEN_COMPILER, else acquires the seed, else (only with
    # NATIVE_CODEGEN_ALLOW_C_MINT=1) re-mints via C; fails closed otherwise.
    native_codegen_ensure_compiler "$native_codegen_dispatch_tmp/compiler" || exit 1

    if [[ -f "$NATIVE_CODEGEN_LINK1" ]]; then
        total=$((total + 1))
        if HERBERT="$tollgate_nc_herbert" "$NATIVE_CODEGEN_LINK1"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    NATIVE_CODEGEN_LINK2="$PWD/run_native_codegen_link2.sh"
    if [[ -f "$NATIVE_CODEGEN_LINK2" ]]; then
        total=$((total + 1))
        if HERBERT="$tollgate_nc_herbert" "$NATIVE_CODEGEN_LINK2"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    NATIVE_CODEGEN_LINK3="$PWD/run_native_codegen_link3.sh"
    if [[ -f "$NATIVE_CODEGEN_LINK3" ]]; then
        total=$((total + 1))
        if HERBERT="$tollgate_nc_herbert" "$NATIVE_CODEGEN_LINK3"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    NATIVE_CODEGEN_LINK4="$PWD/run_native_codegen_link4.sh"
    if [[ -f "$NATIVE_CODEGEN_LINK4" ]]; then
        total=$((total + 1))
        if HERBERT="$tollgate_nc_herbert" "$NATIVE_CODEGEN_LINK4"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    NATIVE_CODEGEN_LINK5="$PWD/run_native_codegen_link5.sh"
    if [[ -f "$NATIVE_CODEGEN_LINK5" ]]; then
        total=$((total + 1))
        if HERBERT="$tollgate_nc_herbert" "$NATIVE_CODEGEN_LINK5"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    NATIVE_CODEGEN_LINK6="$PWD/run_native_codegen_link6.sh"
    if [[ -f "$NATIVE_CODEGEN_LINK6" ]]; then
        total=$((total + 1))
        if HERBERT="$tollgate_nc_herbert" "$NATIVE_CODEGEN_LINK6"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    NATIVE_CODEGEN_LINK7="$PWD/run_native_codegen_link7.sh"
    if [[ -f "$NATIVE_CODEGEN_LINK7" ]]; then
        total=$((total + 1))
        if HERBERT="$tollgate_nc_herbert" "$NATIVE_CODEGEN_LINK7"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    NATIVE_CODEGEN_LINK8="$PWD/run_native_codegen_link8.sh"
    if [[ -f "$NATIVE_CODEGEN_LINK8" ]]; then
        total=$((total + 1))
        if HERBERT="$tollgate_nc_herbert" "$NATIVE_CODEGEN_LINK8"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    NATIVE_CODEGEN_LINK9="$PWD/run_native_codegen_link9.sh"
    if [[ -f "$NATIVE_CODEGEN_LINK9" ]]; then
        total=$((total + 1))
        if HERBERT="$tollgate_nc_herbert" "$NATIVE_CODEGEN_LINK9"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    NATIVE_CODEGEN_LINK10="$PWD/run_native_codegen_link10.sh"
    if [[ -f "$NATIVE_CODEGEN_LINK10" ]]; then
        total=$((total + 1))
        if HERBERT="$tollgate_nc_herbert" "$NATIVE_CODEGEN_LINK10"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    NATIVE_CODEGEN_LINK11="$PWD/run_native_codegen_link11.sh"
    if [[ -f "$NATIVE_CODEGEN_LINK11" ]]; then
        total=$((total + 1))
        if HERBERT="$tollgate_nc_herbert" "$NATIVE_CODEGEN_LINK11"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    NATIVE_CODEGEN_LINK12="$PWD/run_native_codegen_link12.sh"
    if [[ -f "$NATIVE_CODEGEN_LINK12" ]]; then
        total=$((total + 1))
        if HERBERT="$tollgate_nc_herbert" "$NATIVE_CODEGEN_LINK12"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    NATIVE_CODEGEN_LINK13="$PWD/run_native_codegen_link13.sh"
    if [[ -f "$NATIVE_CODEGEN_LINK13" ]]; then
        total=$((total + 1))
        if HERBERT="$tollgate_nc_herbert" "$NATIVE_CODEGEN_LINK13"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    NATIVE_CODEGEN_LINK14="$PWD/run_native_codegen_link14.sh"
    if [[ -f "$NATIVE_CODEGEN_LINK14" ]]; then
        total=$((total + 1))
        if HERBERT="$tollgate_nc_herbert" "$NATIVE_CODEGEN_LINK14"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    NATIVE_CODEGEN_LINK15="$PWD/run_native_codegen_link15.sh"
    if [[ -f "$NATIVE_CODEGEN_LINK15" ]]; then
        total=$((total + 1))
        if HERBERT="$tollgate_nc_herbert" "$NATIVE_CODEGEN_LINK15"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    NATIVE_CODEGEN_LINK16="$PWD/run_native_codegen_link16.sh"
    if [[ -f "$NATIVE_CODEGEN_LINK16" ]]; then
        total=$((total + 1))
        if HERBERT="$tollgate_nc_herbert" "$NATIVE_CODEGEN_LINK16"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    NATIVE_CODEGEN_REJECTS="$PWD/run_native_codegen_rejects.sh"
    if [[ -f "$NATIVE_CODEGEN_REJECTS" ]]; then
        total=$((total + 1))
        if HERBERT="$tollgate_nc_herbert" "$NATIVE_CODEGEN_REJECTS"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    # tollgate: the DEFAULT is golden (C-free); this redundant C-free re-validation
    # pass runs ONLY under the opt-in `c` cross-check, where pass-1 ran live C.
    if [[ "${NATIVE_CODEGEN_ORACLE:-golden}" != "golden" ]]; then
        for native_codegen_script in \
            "$PWD/run_native_codegen_link1.sh" \
            "$PWD/run_native_codegen_link2.sh" \
            "$PWD/run_native_codegen_link3.sh" \
            "$PWD/run_native_codegen_link4.sh" \
            "$PWD/run_native_codegen_link5.sh" \
            "$PWD/run_native_codegen_link6.sh" \
            "$PWD/run_native_codegen_link7.sh" \
            "$PWD/run_native_codegen_link8.sh" \
            "$PWD/run_native_codegen_link9.sh" \
            "$PWD/run_native_codegen_link10.sh" \
            "$PWD/run_native_codegen_link11.sh" \
            "$PWD/run_native_codegen_link12.sh" \
            "$PWD/run_native_codegen_link13.sh" \
            "$PWD/run_native_codegen_link14.sh" \
            "$PWD/run_native_codegen_link15.sh" \
            "$PWD/run_native_codegen_link16.sh" \
            "$PWD/run_native_codegen_rejects.sh"; do
            [[ -f "$native_codegen_script" ]] || continue
            total=$((total + 1))
            if NATIVE_CODEGEN_ORACLE=golden HERBERT="$HERBERT" "$native_codegen_script"; then
                pass=$((pass + 1))
            else
                fail=$((fail + 1))
            fi
        done
    fi

    run_native_codegen_non_vacuity_check
    run_native_codegen_corrupt_compiler_check
    check_native_codegen_grade_count
    check_native_codegen_grade_gating_present
    run_native_codegen_grade_fence_mutation
    check_native_codegen_mint_count
    run_native_codegen_michoi_seed_check

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
