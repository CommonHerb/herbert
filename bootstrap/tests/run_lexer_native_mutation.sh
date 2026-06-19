#!/usr/bin/env bash
#
# Mutation proof for the lexer native-execution gate (run_lexer_native.sh).
#
# Proves the gate BITES on the C-FREE path: a reachable LEXER rule (the lexer's
# character-class -> token-kind classification), mutated, still COMPILES under the
# native subset but makes the gen-1-compiled ELF emit a token stream that DIVERGES
# from the independent oracle -- so the gate's ENDURING leg (native ELF line 1 ==
# lexer_probe.expected, no C consulted) goes RED. Each mutation is one that
# compiles-but-diverges (a wrong RUNTIME VALUE -- a wrong token KIND in the emitted
# stream), the strong bite: a mere compile failure would prove far less. The CONTROL
# (unmutated) grades GREEN first, so the grader is not vacuous.
#
# Everything here runs through the native gen-1 ELF and the committed oracle with
# NO C interpreter in the graded path (LEXER_NATIVE_NO_C semantics) -- the proof is
# about the C-free execution, not the faithfulness guard.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
fragment="$repo_root/stack/lexer_fragment.herb"
oracle="$repo_root/stack/lexer_probe.expected"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass=0
fail_test() { echo "FAIL: lexer native mutation ($1)"; FAILED=1; }
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
    [[ $r -eq 0 ]] || return $r                # runtime crash -> propagate the rc
    # Enforce the well-formed envelope (same binding as run_lexer_native.sh):
    # exactly 2 lines, line 2 == "0". A mutation that breaks the output FORMAT (not
    # just a token value) is rejected (rc 3) so each shipped mutation is proven to be
    # a CLEAN WRONG-VALUE bite -- line 1 diverges while the transcript envelope stays
    # intact -- not merely "broken output that happens to differ from the oracle".
    [[ "$(wc -l <"$wd/run.out")" -eq 2 ]] || return 3
    [[ "$(sed -n 2p "$wd/run.out")" == "0" ]] || return 3
    head -1 "$wd/run.out" >"$out" 2>/dev/null
    return 0
}

# ===== CONTROL: the unmutated fragment must grade GREEN (else the grader is vacuous) =====
ctl="$tmp/ctl.line1"
if native_line1 "$fragment" "$ctl" && cmp -s "$ctl" "$oracle"; then
    pass=$((pass + 1))
else
    fail_test "CONTROL: unmutated lexer did not grade GREEN (native line1 != oracle) -- grader vacuous"
fi

# ===== mutation helper: replace a UNIQUE anchor, require the STRONG bite =====
# Strong bite = the mutated fragment (a) has the anchor exactly once (an unscoped
# multi-hit substitution is rejected), (b) compiles to a real native ELF, (c) the
# ELF runs cleanly (rc 0) and emits a non-empty line 1, and (d) that line 1
# DIFFERS from the oracle. A compile failure or a crash is NOT accepted for these
# shipped mutations -- we are proving the C-free path grades a WRONG RUNTIME VALUE
# (a wrong token kind in the emitted stream), not merely that broken input fails to build.
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
    if [[ $rc -eq 3 ]]; then
        fail_test "$label: mutated native ELF produced a MALFORMED envelope (not exactly 2 lines / line2 != 0; want a clean wrong-VALUE bite, not broken output)"
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
        fail_test "$label: mutated lexer STILL matched the oracle -- the gate is blind to this rule"
    else
        pass=$((pass + 1))
    fi
}

# The three anchors are the lexer's character-class -> token-kind classifications
# in scan (each `do add(out, (KIND, slice_text(...)))`). Mutating one changes the
# emitted token's KIND for that whole character class, so the serialized stream
# diverges from the oracle -- a genuine lex-rule bite (distinct from the parser's
# operator-tag anchors and the evaluator/VM execution-rule anchors). Each anchor is
# unique in the fragment (the two kind-5 operator emits and the kind-2/3 string/char
# emits are deliberately untouched, so each anchor below appears exactly once).

# M-ident: the identifier -> kind 0 classification. The probe is dense with
# identifiers/keywords (func, pick, c, if, return, ...), so every one gains kind 9
# where the oracle has kind 0. Compiles natively (a single-digit change).
mutate_expect_red "M-ident" '(0, slice_text(src, i, j))' '(9, slice_text(src, i, j))'

# M-int: the integer-literal -> kind 1 classification. The probe uses int literals
# (0, 1, 2, 4, 8, 9), so each gains kind 8 where the oracle has kind 1. A distinct rule.
mutate_expect_red "M-int" '(1, slice_text(src, i, j))' '(8, slice_text(src, i, j))'

# M-punct: the punctuator -> kind 4 classification (the ( ) , : . tail branch). The
# probe is full of punctuation, so each gains kind 7 where the oracle has kind 4. A
# third distinct rule.
mutate_expect_red "M-punct" '(4, slice_text(src, i, i + 1))' '(7, slice_text(src, i, i + 1))'

echo "lexer native mutation proof: pass=$pass fail=$([[ $FAILED -eq 1 ]] && echo "$((4 - pass))" || echo 0)"
if [[ $FAILED -eq 0 && $pass -eq 4 ]]; then
    echo "PASS: lexer native mutation (CONTROL green; M-ident/M-int/M-punct each compile natively then DIVERGE from the oracle -- the C-free gate bites)"
else
    exit 1
fi
