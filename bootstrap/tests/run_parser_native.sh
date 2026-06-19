#!/usr/bin/env bash
#
# Parser native-execution gate (sovereignty axis, Role-C reduction).
#
# The metacircular PARSER fragment (stack/parser_fragment.herb -- it lexes the
# embedded parser_probe, runs a genuine recursive-descent parse of the Herbert
# grammar into a pool-arena AST, and serializes that AST to a canonical
# S-expression) is given a COMMITTED NATIVE EXECUTION PATH: the C-free gen-1 seed
# (the production compiler) compiles it to an x86-64 ELF that runs with NO C in
# its execution path, and emits the serialized S-expression.
#
# This is the THIRD metacircular fragment to gain a native execution path (after
# the evaluator [dolly] and the VM [anon]). Every fragment
# (lexer/parser/evaluator/vm/klondike) ran ONLY under the C interpreter, so
# deleting C would kill its self-description test. The parser fragment is the
# front-end stage (lex + parse + serialize); this gate makes its self-description
# test survive C's deletion -- a genuine Role-C C-removal, not a measurement.
#
# (The parser's C side, bootstrap/parse.c, is the ORACLE role, separately
# cross-checked by the harlan parser-equivalence altimeter; this gate removes C
# from the metacircular parser FRAGMENT's *execution*, a distinct Role-C surface.)
#
# TWO assertion legs, with deliberately different lifetimes (this is what keeps
# the gate a real C-removal rather than a re-introduced C dependency):
#
#   (1) ENDURING / REQUIRED -- native ELF line 1 == the INDEPENDENT hand-authored
#       oracle (stack/parser_probe.expected -- the answer-key S-expression, never
#       produced by any parser). This consults NO C: it runs the gen-1-compiled
#       parser and diffs against the committed answer key. It must pass AFTER the
#       C interpreter is deleted. This is the sovereignty advance.
#
#   (2) RETIREABLE / OPTIONAL -- native ELF line 1 == the C interpreter's line 1
#       (a faithfulness cross-check: the native-compiled parser agrees with the
#       interpreted one -- a genuine gen-1-vs-C differential the gen2==gen1 fixpoint
#       cannot give). This leg is a MIGRATION GUARD, not a permanent dependency: it
#       runs only while a C interpreter exists. Set PARSER_NATIVE_NO_C=1 (or
#       remove HERBERT) and the gate still passes on leg (1) alone -- proving the
#       C dependency is genuinely gone, not merely unused.
#
# RED-first: this gate, the native path, and the mutation proof do not exist
# before this link; mutating a reachable parse rule makes the native output
# diverge from the oracle (proven by run_parser_native_mutation.sh).
#
# SCOPE (honest): the native parser is exercised over ONE fixed forcing probe
# (parser_probe, hand-authored to exercise every grammar production -- if/elif/
# else, recursion, let/rebind, all six comparisons, and/or/not, booleans,
# precedence, nested tuples, type expressions, string/char escapes, builtins,
# deep grouping, nested calls). That is broad, but "this probe parses natively
# and matches the oracle" is NOT "the parser fragment fully replaces parse.c over
# all programs." The main entry point is a thin I/O adapter (the serialized
# S-expression is emitted via flogger and main returns 0, because the native
# subset requires main to return int/bool); the ~910 lines of lex + recursive-
# descent parse + serialize logic are byte-identical to the interpreted fragment.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"

HERBERT="${HERBERT:-$repo_root/build/herbert}"
fragment="$repo_root/stack/parser_fragment.herb"
oracle="$repo_root/stack/parser_probe.expected"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: parser native execution ($1)"; exit 1; }

[[ -f "$fragment" ]] || fail "missing fragment $fragment"
[[ -f "$oracle" ]] || fail "missing oracle $oracle"

# --- 1. Acquire the C-free gen-1 production compiler (the committed seed) -------
source "$script_dir/native_codegen_oracle.sh"
native_codegen_ensure_compiler "$tmp/native-compiler" || fail "could not acquire gen-1 compiler"
GEN1="$NATIVE_CODEGEN_COMPILER"
[[ -x "$GEN1" ]] || fail "gen-1 compiler not executable: $GEN1"

# --- helper: compile a source with gen-1 and run the ELF, capturing line 1 -----
# The gen-1 emitter writes ./a.out without the execute bit, so chmod +x before
# running (a missing chmod looks exactly like a C-vs-native divergence -- it is not).
native_line1() {
    local src="$1" out="$2" wd; wd="$(mktemp -d "$tmp/run.XXXX")"
    ( cd "$wd" && "$GEN1" <"$src" >compile.log 2>compile.err )
    [[ -f "$wd/a.out" ]] || { echo "    (gen-1 compile produced no ELF: $(head -1 "$wd/compile.log" 2>/dev/null))"; return 1; }
    # Require a genuine ELF, not just any executable named a.out: the native path
    # must really be a gen-1-emitted ELF, not a wrapper/shim that echoes the oracle.
    [[ "$(head -c4 "$wd/a.out" | xxd -p)" == "7f454c46" ]] || { echo "    (a.out is not an ELF)"; return 1; }
    chmod +x "$wd/a.out" || return 1
    "$wd/a.out" >"$wd/run.out" 2>"$wd/run.err" || { echo "    (native ELF exited nonzero)"; return 1; }
    # Bind the FULL native transcript, not just line 1: the fragment emits the
    # serialized S-expression (line 1) then "0" from `return 0` (line 2), and
    # nothing else -- so trailing garbage or a corrupted return marker cannot hide
    # behind a correct line 1.
    [[ "$(wc -l <"$wd/run.out")" -eq 2 ]] || { echo "    (native output is not exactly 2 lines: $(wc -l <"$wd/run.out"))"; return 1; }
    [[ "$(sed -n 2p "$wd/run.out")" == "0" ]] || { echo "    (native line 2 is not the expected return-0 marker)"; return 1; }
    head -1 "$wd/run.out" >"$out"
    [[ -s "$out" ]] || { echo "    (native ELF produced empty line 1)"; return 1; }
    return 0
}

# --- 2. ENDURING leg: native gen-1 parser output == independent oracle ---------
nat="$tmp/native.line1"
native_line1 "$fragment" "$nat" || fail "native gen-1 parser did not run cleanly"
cmp -s "$nat" "$oracle" || fail "native gen-1 parser line 1 differs from independent oracle (native=$(head -c80 "$nat") oracle=$(head -c80 "$oracle"))"

# --- 3. RETIREABLE leg: faithfulness vs the C interpreter (migration guard) ------
# Runs ONLY while a C interpreter exists. PARSER_NATIVE_NO_C=1 simulates the
# post-retirement world: the gate then passes on the enduring leg alone.
c_checked="(skipped: no C interpreter -- gate passes on the enduring oracle leg alone)"
if [[ "${PARSER_NATIVE_NO_C:-0}" != "1" && -x "$HERBERT" ]]; then
    ci="$tmp/cinterp.out"; ciln="$tmp/cinterp.line1"
    "$HERBERT" "$fragment" >"$ci" 2>/dev/null || fail "C interpreter could not run the parser fragment"
    head -1 "$ci" >"$ciln"
    cmp -s "$ciln" "$oracle" || fail "C-interpreted parser line 1 differs from the oracle (the fragment regressed under C)"
    cmp -s "$nat" "$ciln" || fail "native gen-1 parser diverges from the C interpreter (faithfulness)"
    c_checked="(faithfulness vs C interpreter: native == C-interp == oracle)"
fi

echo "PASS: parser native execution (gen-1-compiled parser_fragment runs C-FREE, line 1 == independent oracle; $c_checked)"
