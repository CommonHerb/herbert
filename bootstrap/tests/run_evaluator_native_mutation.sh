#!/usr/bin/env bash
#
# Mutation proof for the evaluator native-execution gate (run_evaluator_native.sh).
#
# Proves the gate BITES on the C-FREE path: a reachable evaluator rule, mutated,
# still COMPILES under the native subset but makes the gen-1-compiled ELF emit a
# 12-tuple that DIVERGES from the independent oracle -- so the gate's ENDURING leg
# (native ELF line 1 == evaluator_probe.expected, no C consulted) goes RED. Each
# mutation is one that compiles-but-diverges (a wrong RUNTIME VALUE), the strong
# bite: a mere compile failure would prove far less. The CONTROL (unmutated)
# grades GREEN first, so the grader is not vacuous.
#
# Everything here runs through the native gen-1 ELF and the committed oracle with
# NO C interpreter in the graded path (EVALUATOR_NATIVE_NO_C semantics) -- the
# proof is about the C-free execution, not the faithfulness guard.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
fragment="$repo_root/stack/evaluator_fragment.herb"
oracle="$repo_root/stack/evaluator_probe.expected"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass=0
fail_test() { echo "FAIL: evaluator native mutation ($1)"; FAILED=1; }
FAILED=0

[[ -f "$fragment" ]] || { echo "FAIL: missing fragment"; exit 1; }

source "$script_dir/native_codegen_oracle.sh"
native_codegen_ensure_compiler "$tmp/native-compiler" || { echo "FAIL: could not acquire gen-1 compiler"; exit 1; }
GEN1="$NATIVE_CODEGEN_COMPILER"
[[ -x "$GEN1" ]] || { echo "FAIL: gen-1 not executable"; exit 1; }

# Compile a source with gen-1 and emit native ELF line 1 (or empty + rc!=0 on a
# compile/run failure). chmod +x: the gen-1 emitter writes ./a.out non-executable.
native_line1() {
    local src="$1" out="$2" wd; wd="$(mktemp -d "$tmp/run.XXXX")"
    : >"$out"                                 # always exists, so a fault -> clean empty diff
    ( cd "$wd" && "$GEN1" <"$src" >compile.log 2>compile.err )
    [[ -f "$wd/a.out" ]] || return 2          # rc 2 = did not compile
    [[ "$(head -c4 "$wd/a.out" | xxd -p)" == "7f454c46" ]] || return 2   # not a real ELF
    chmod +x "$wd/a.out" || return 1
    # A mutated evaluator may fault (e.g. a broken termination rule overflows the
    # stack); that is still a divergence, but a CLEAN compiles-runs-wrong-value
    # bite (rc 0) is the strong form we require of the shipped mutations below.
    ( "$wd/a.out" >"$wd/run.out" 2>"$wd/run.err" ); local r=$?
    head -1 "$wd/run.out" >"$out" 2>/dev/null
    return $r
}

# ===== CONTROL: the unmutated fragment must grade GREEN (else the grader is vacuous) =====
ctl="$tmp/ctl.line1"
if native_line1 "$fragment" "$ctl" && cmp -s "$ctl" "$oracle"; then
    pass=$((pass + 1))
else
    fail_test "CONTROL: unmutated evaluator did not grade GREEN (native line1 != oracle) -- grader vacuous"
fi

# ===== mutation helper: replace a UNIQUE anchor, require the STRONG bite =====
# Strong bite = the mutated fragment (a) has the anchor exactly once (an unscoped
# multi-hit substitution is rejected), (b) compiles to a real native ELF, (c) the
# ELF runs cleanly (rc 0) and emits a non-empty line 1, and (d) that line 1
# DIFFERS from the oracle. A compile failure or a crash is NOT accepted for these
# shipped mutations -- we are proving the C-free path grades a WRONG RUNTIME VALUE,
# not merely that broken input fails to build.
mutate_expect_red() {
    local label="$1" old="$2" new="$3"
    local m="$tmp/mut.$label.herb" ln="$tmp/mut.$label.line1"
    # Literal single-occurrence replace; assert the anchor is unique (else the
    # mutation could silently hit the wrong/multiple sites and still grade RED).
    if ! python3 - "$fragment" "$old" "$new" "$m" <<'PY'
import sys
src = open(sys.argv[1]).read()
old, new = sys.argv[2], sys.argv[3]
n = src.count(old)
if n != 1:
    sys.stderr.write("anchor count %d\n" % n); sys.exit(3)
open(sys.argv[4], "w").write(src.replace(old, new, 1))
PY
    then
        fail_test "$label: anchor '$old' is not unique in the fragment (unscoped mutation)"
        return
    fi
    native_line1 "$m" "$ln"; local rc=$?
    if [[ $rc -eq 2 ]]; then
        fail_test "$label: mutated fragment did NOT compile to a native ELF (want compiles-runs-wrong-value, not a build failure)"
        return
    fi
    if [[ $rc -ne 0 ]]; then
        fail_test "$label: mutated native ELF did not run cleanly (rc=$rc; want a clean wrong-value bite)"
        return
    fi
    if [[ ! -s "$ln" ]]; then
        fail_test "$label: mutated native ELF produced an empty line 1"
        return
    fi
    if cmp -s "$ln" "$oracle"; then
        fail_test "$label: mutated evaluator STILL matched the oracle -- the gate is blind to this rule"
    else
        pass=$((pass + 1))
    fi
}

# M-add: off-by-one in the evaluator's integer ADD rule (eval_int_binop). Additions
# pervade the probe (test_arith, sum_to/sum_tail recursion, the branch sums), so the
# 12-tuple diverges. Compiles natively (still a valid expression).
mutate_expect_red "M-add" "make_int_value(left + right)" "make_int_value(left + right + 1)"

# M-eq: invert the evaluator's EQUALITY rule. test_compare/test_branch depend on
# `==`, so multiple tuple elements diverge. A distinct (boolean) rule from M-add.
mutate_expect_red "M-eq" "make_bool_value(left == right)" "make_bool_value(left != right)"

# M-lt: invert the evaluator's less-than comparison rule. classify()/test_branch
# and test_compare depend on `<`, so the tuple diverges. A third distinct rule.
mutate_expect_red "M-lt" "make_bool_value(left < right)" "make_bool_value(left > right)"

echo "evaluator native mutation proof: pass=$pass fail=$([[ $FAILED -eq 1 ]] && echo "$((4 - pass))" || echo 0)"
if [[ $FAILED -eq 0 && $pass -eq 4 ]]; then
    echo "PASS: evaluator native mutation (CONTROL green; M-add/M-eq/M-lt each compile natively then DIVERGE from the oracle -- the C-free gate bites)"
else
    exit 1
fi
