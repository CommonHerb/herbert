#!/usr/bin/env bash
#
# Mutation proof for the parser native-execution gate (run_parser_native.sh).
#
# Proves the gate BITES on the C-FREE path: a reachable PARSE rule (the parser's
# operator-text -> AST-tag mapping), mutated, still COMPILES under the native
# subset but makes the gen-1-compiled ELF emit an S-expression that DIVERGES from
# the independent oracle -- so the gate's ENDURING leg (native ELF line 1 ==
# parser_probe.expected, no C consulted) goes RED. Each mutation is one that
# compiles-but-diverges (a wrong RUNTIME VALUE -- a wrong AST tag in the emitted
# tree), the strong bite: a mere compile failure would prove far less. The CONTROL
# (unmutated) grades GREEN first, so the grader is not vacuous.
#
# Everything here runs through the native gen-1 ELF and the committed oracle with
# NO C interpreter in the graded path (PARSER_NATIVE_NO_C semantics) -- the proof
# is about the C-free execution, not the faithfulness guard.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
fragment="$repo_root/stack/parser_fragment.herb"
oracle="$repo_root/stack/parser_probe.expected"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass=0
fail_test() { echo "FAIL: parser native mutation ($1)"; FAILED=1; }
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
    ( "$wd/a.out" >"$wd/run.out" 2>"$wd/run.err" ); local r=$?
    head -1 "$wd/run.out" >"$out" 2>/dev/null
    return $r
}

# ===== CONTROL: the unmutated fragment must grade GREEN (else the grader is vacuous) =====
ctl="$tmp/ctl.line1"
if native_line1 "$fragment" "$ctl" && cmp -s "$ctl" "$oracle"; then
    pass=$((pass + 1))
else
    fail_test "CONTROL: unmutated parser did not grade GREEN (native line1 != oracle) -- grader vacuous"
fi

# ===== mutation helper: replace a UNIQUE anchor, require the STRONG bite =====
# Strong bite = the mutated fragment (a) has the anchor exactly once (an unscoped
# multi-hit substitution is rejected), (b) compiles to a real native ELF, (c) the
# ELF runs cleanly (rc 0) and emits a non-empty line 1, and (d) that line 1
# DIFFERS from the oracle. A compile failure or a crash is NOT accepted for these
# shipped mutations -- we are proving the C-free path grades a WRONG RUNTIME VALUE
# (a wrong AST tag in the emitted tree), not merely that broken input fails to build.
mutate_expect_red() {
    local label="$1" old="$2" new="$3"
    local m="$tmp/mut.$label.herb" ln="$tmp/mut.$label.line1"
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
        fail_test "$label: mutated parser STILL matched the oracle -- the gate is blind to this rule"
    else
        pass=$((pass + 1))
    fi
}

# The three anchors are the parser's operator-text -> AST-tag mappings (each
# returns the canonical S-expression head for an operator token). Mutating one
# changes the EMITTED TREE's tag for that operator, so the serialized S-expression
# diverges from the oracle -- a genuine parse-rule bite (distinct from the
# evaluator/VM execution-rule anchors). Each anchor is unique in the fragment.

# M-add: the `+` -> "add" tag mapping. The probe uses `+` (e.g. n + sum_to(n-1),
# deep_expr's grouping), so the tree gains `(sub ...)` where the oracle has
# `(add ...)`. Compiles natively (a string change).
mutate_expect_red "M-add" 'return "add"' 'return "sub"'

# M-eq: the `==` -> "eq" tag mapping. The probe uses `==` (classify, flags), so
# the tree gains `(ne ...)` where the oracle has `(eq ...)`. A distinct rule.
mutate_expect_red "M-eq" 'return "eq"' 'return "ne"'

# M-lt: the `<` -> "lt" tag mapping. The probe uses `<` (classify, flags), so the
# tree gains `(gt ...)` where the oracle has `(lt ...)`. A third distinct rule.
mutate_expect_red "M-lt" 'return "lt"' 'return "gt"'

echo "parser native mutation proof: pass=$pass fail=$([[ $FAILED -eq 1 ]] && echo "$((4 - pass))" || echo 0)"
if [[ $FAILED -eq 0 && $pass -eq 4 ]]; then
    echo "PASS: parser native mutation (CONTROL green; M-add/M-eq/M-lt each compile natively then DIVERGE from the oracle -- the C-free gate bites)"
else
    exit 1
fi
