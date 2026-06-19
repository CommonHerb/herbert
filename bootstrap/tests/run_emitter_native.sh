#!/usr/bin/env bash
#
# Emitter native-execution gate (sovereignty axis, Role-C reduction -- the SIXTH and
# FINAL metacircular fragment; closes Role-C for the standalone CODE-GENERATION
# observable).
#
# stack/emitter_fragment.herb is the stack's bytecode CODE GENERATOR: it embeds the
# evaluator probe, lexes + parses it, LOWERS the AST to stack-VM bytecode
# (lower_program / emit_expr / emit_stmt / opcode_for_binop -- the standalone
# AST->bytecode stage), and serializes the canonical bytecode LISTING. Like the other
# five metacircular fragments (lexer/parser/evaluator/vm/klondike) it ran ONLY under
# the C interpreter (the stack/emitter_probe test in run_tests.sh), so deleting C would
# kill its self-description test. This gate gives it a COMMITTED NATIVE EXECUTION PATH:
# the C-free gen-1 seed (the production compiler) compiles it to an x86-64 ELF that
# runs with NO C in its execution path and emits the serialized bytecode listing.
#
# WHY THE EMITTER IS A DISTINCT SURFACE (not redundant with the five freed fragments).
# The five expose tokens / AST / final evaluated value only: a lowering bug -- a wrong
# opcode, a wrong frame slot, a wrong jump target -- that still computes the SAME final
# value is INVISIBLE to evaluator/vm/klondike (whose gates observe only the result),
# but is VISIBLE in the bytecode listing. The emitter gate is the only one that pins
# the lowering PRODUCT -- code-generation structure at the instruction level. (vm_fragment
# RUNS hand-built bytecode build_fn_00..18; it does not LOWER. klondike internally lowers
# but its gate binds only the final Value.) Cross-model Codex concurred this makes the
# emitter genuinely distinct.
#
# WHY A GATE-TIME MAIN ADAPTER (like klondike, not an in-place edit). emitter's main
# returns serialize_bytecode(prog) (a STRING), so the native subset (main:int/bool)
# rejects it ERR 432 at line 1688 -- the SAME trivial main-return issue the other five
# fragments hit, NOT a deeper gap (verified on silicon: with an int-returning main the
# whole ~1690-line body compiles clean under the PRISTINE committed seed -> a 77 KB ELF).
# A one-line adapter -- replace `return serialize_bytecode(prog)` with
# `do flogger(serialize_bytecode(prog)); return 0` -- is applied at GATE TIME so
# emitter_fragment.herb stays BYTE-IDENTICAL and the existing C emitter_probe test keeps
# running the unmodified fragment. This gate is therefore PURELY ADDITIVE: NO fragment
# edit, NO backend change, NO reseed. The transform asserts its anchor is present and
# unique, so a future main rename fails LOUD (no a.out -> the gate fails closed).
#
# TWO assertion legs with deliberately different lifetimes (this is what keeps the gate
# a real C-removal, not a re-introduced C dependency):
#
#   (1) ENDURING / REQUIRED -- the native ELF's listing == the INDEPENDENT committed
#       oracle stack/emitter_probe.expected (the blessed canonical bytecode listing for
#       the probe: human-inspectable, committed in ed8e237 "verified against the probe
#       bytecode oracle"). This consults NO C and must pass AFTER the C interpreter is
#       deleted. Set EMITTER_NATIVE_NO_C=1 (or remove HERBERT) and the gate still passes
#       on leg (1) alone. This is the sovereignty advance.
#
#   (2) RETIREABLE / OPTIONAL -- the native listing == the C interpreter running the
#       SAME adapted emitter (a faithfulness cross-check; a genuine gen-1-vs-C
#       differential the gen2==gen1 fixpoint cannot give). MIGRATION GUARD only -- runs
#       while a C interpreter still exists.
#
# RED-first: this gate, the native path, and the mutation proof do not exist before this
# link; mutating a reachable LOWERING rule (an opcode mapping, a frame-slot allocation,
# or a control-flow branch) makes the native listing diverge from the oracle (proven by
# run_emitter_native_mutation.sh).
#
# SCOPE (honest -- folding the cross-model Codex self-deception flags + the completeness
# critic's silicon survey): this is the FINAL FINITE Role-C closure for the standalone
# lowering OBSERVABLE, over ONE fixed probe (the embedded 12-test evaluator probe).
# "This listing matches and a mutated lowering diverges" is NOT broad production-codegen
# assurance over all programs; the oracle is the blessed canonical listing (a regression +
# faithfulness + codegen-structure anchor), not an independent re-derivation of semantic
# correctness. main is a thin I/O adapter; the lower + serialize logic that runs natively
# is byte-identical to the committed fragment.
#
# WHAT THE FIXED PROBE PINS (completeness-critic silicon survey, ~40 mutations through the
# seed): the byte-exact lowering of 31 of 33 emitted opcodes -- all 8 binops (a mutation to
# ANY of add/sub/eq/ne/lt/le/gt/ge diverges, not just the 3 the mutation gate ships), plus
# push/load/store, call + its operand-count, make_tuple/tuple_get + arity/index, array and
# buffer ops, length/index/equal/get/count/freeze, not, br_and/br_or, the conditional
# br_if_false, ret -- together with frame-slot allocation, the if-arm conditional-branch and
# join-guard logic, and string interning. WHAT IT DOES NOT EXERCISE (genuine dead-for-this-
# probe blind spots, named so this gate is never over-read): the SLICE emit arm (the probe
# uses index, never slice), the UNCONDITIONAL br / if-arm JOIN-JUMP emit (every probe arm
# ends in return or is single-arm, so the join-jump never fires -- the M-cf mutation pins the
# conditional br_if_false selection, NOT this unconditional path), and the three string-escape
# arms (\n/\\/\" -- the pool strings carry no escapable byte). A wider probe would close these;
# this link does not widen the probe (it would re-bless the oracle), it documents the gap.
#
# With this, all SIX metacircular fragments survive C's deletion and Role-C is closed; the
# next strategic axis is the deeper Role-B altimeters, not more fragment-freeing.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"

HERBERT="${HERBERT:-$repo_root/build/herbert}"
fragment="$repo_root/stack/emitter_fragment.herb"
oracle="$repo_root/stack/emitter_probe.expected"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: emitter native execution ($1)"; exit 1; }

[[ -f "$fragment" ]] || fail "missing fragment $fragment"
[[ -f "$oracle" ]] || fail "missing oracle $oracle"
oracle_lines="$(wc -l <"$oracle")"

# --- 1. Acquire the C-free gen-1 production compiler (the committed seed) -------
source "$script_dir/native_codegen_oracle.sh"
native_codegen_ensure_compiler "$tmp/native-compiler" || fail "could not acquire gen-1 compiler"
GEN1="$NATIVE_CODEGEN_COMPILER"
[[ -x "$GEN1" ]] || fail "gen-1 compiler not executable: $GEN1"

# --- 2. Gate-time main adapter (emitter_fragment.herb stays byte-identical) ------
adapter="$tmp/emitter_native.herb"
python3 - "$fragment" "$adapter" <<'PY'
import sys
src = open(sys.argv[1]).read()
old = "    return serialize_bytecode(prog)\n"
new = ("    do flogger(serialize_bytecode(prog))\n"
       "    return 0\n")
n = src.count(old)
if n != 1:
    sys.stderr.write("main-adapter anchor count %d (want 1)\n" % n)
    sys.exit(9)
open(sys.argv[2], "w").write(src.replace(old, new, 1))
PY
[[ $? -eq 0 ]] || fail "main-adapter transform failed (anchor missing or not unique -- emitter main changed?)"

# --- helper: a STRUCTURALLY VALID bytecode listing transcript ------------------
# The three section headers must each appear EXACTLY ONCE and IN ORDER
# (STRING_POOL < FUNCTIONS < CODE), and the transcript must end in the return-0
# marker. This rejects marker-shaped garbage / duplicated-or-reordered sections /
# broad serializer corruption as a false "different listing" (folds a cross-model
# Codex impl-review point) -- a divergent listing must still be a real listing.
listing_well_formed() {
    local f="$1"
    [[ "$(tail -n1 "$f")" == "0" ]] || { echo "    (transcript last line is not the return-0 marker)"; return 1; }
    [[ "$(grep -cx STRING_POOL "$f")" -eq 1 ]] || { echo "    (STRING_POOL header not present exactly once)"; return 1; }
    [[ "$(grep -cx FUNCTIONS "$f")" -eq 1 ]] || { echo "    (FUNCTIONS header not present exactly once)"; return 1; }
    [[ "$(grep -cx CODE "$f")" -eq 1 ]] || { echo "    (CODE header not present exactly once)"; return 1; }
    local sp fn cd
    sp="$(grep -nx STRING_POOL "$f" | cut -d: -f1)"
    fn="$(grep -nx FUNCTIONS "$f" | cut -d: -f1)"
    cd="$(grep -nx CODE "$f" | cut -d: -f1)"
    [[ "$sp" -lt "$fn" && "$fn" -lt "$cd" ]] || { echo "    (section headers out of order: STRING_POOL@$sp FUNCTIONS@$fn CODE@$cd)"; return 1; }
    return 0
}

# --- helper: compile a source with gen-1, run the ELF, return the well-formed listing
# The gen-1 emitter writes ./a.out without the execute bit, so chmod +x before running
# (a missing chmod looks exactly like a C-vs-native divergence -- it is not). The emitter
# emits the bytecode listing, then "0" from `return 0`. The CORRECT listing is exactly
# oracle_lines lines, so the full transcript is oracle_lines+1 lines. We bind the FULL
# transcript envelope (first line == STRING_POOL, FUNCTIONS + CODE section headers
# present, exact line count, last line == "0") so trailing garbage or a truncated/crashed
# run cannot hide behind a correct prefix; then strip the "0" marker and return the listing.
native_listing() {
    local src="$1" out="$2" wd; wd="$(mktemp -d "$tmp/run.XXXX")"
    # Compile C-FREE *and* TOOLCHAIN-FREE: the gen-1 seed emits the ELF directly (no
    # assembler/linker), so we scrub PATH for the compile -- with cc/gcc/as/ld unreachable
    # the seed STILL produces the ELF, proving "C-free" means no external C toolchain in the
    # emission path, not merely "the C interpreter was not used" (folds a cross-model Codex
    # impl-review point). The gen-1 emitter writes ./a.out WITHOUT the execute bit, so
    # chmod +x before running. The seed exits 0 even on a subset-reject (prints the error on
    # stdout, omits a.out) -- so "a.out exists + ELF magic" is the success signal, not the
    # exit code (the established native-gate convention).
    ( cd "$wd" && env PATH=/nonexistent "$GEN1" <"$src" >compile.log 2>compile.err )
    [[ -f "$wd/a.out" ]] || { echo "    (gen-1 compile produced no ELF: $(head -1 "$wd/compile.log" 2>/dev/null))"; return 1; }
    [[ "$(head -c4 "$wd/a.out" | xxd -p)" == "7f454c46" ]] || { echo "    (a.out is not an ELF)"; return 1; }
    chmod +x "$wd/a.out" || return 1
    ( timeout 60s "$wd/a.out" >"$wd/run.out" 2>"$wd/run.err" ) || { echo "    (native ELF exited nonzero/timed out)"; return 1; }
    [[ -s "$wd/run.err" ]] && { echo "    (native ELF wrote unexpected stderr)"; return 1; }
    listing_well_formed "$wd/run.out" || return 1
    [[ "$(wc -l <"$wd/run.out")" -eq $((oracle_lines + 1)) ]] || { echo "    (native transcript is not $((oracle_lines + 1)) lines: $(wc -l <"$wd/run.out"))"; return 1; }
    head -n -1 "$wd/run.out" >"$out"
    [[ -s "$out" ]] || { echo "    (native ELF produced empty listing)"; return 1; }
    return 0
}

# --- 3. ENDURING leg: native gen-1 emitter listing == independent oracle ----------
nat="$tmp/native.listing"
native_listing "$adapter" "$nat" || fail "native gen-1 emitter did not run cleanly"
cmp -s "$nat" "$oracle" || fail "native gen-1 emitter listing differs from independent oracle (native head: $(head -c80 "$nat" | tr '\n' '|'))"

# --- 4. RETIREABLE leg: faithfulness vs the C interpreter (migration guard) --------
# Runs ONLY while a C interpreter exists. EMITTER_NATIVE_NO_C=1 simulates the
# post-retirement world: the gate then passes on the enduring leg alone.
c_checked="(skipped: no C interpreter -- gate passes on the enduring oracle leg alone)"
if [[ "${EMITTER_NATIVE_NO_C:-0}" != "1" && -x "$HERBERT" ]]; then
    ci="$tmp/cinterp.out"; ciln="$tmp/cinterp.listing"
    "$HERBERT" "$adapter" >"$ci" 2>/dev/null || fail "C interpreter could not run the adapted emitter"
    head -n -1 "$ci" >"$ciln"
    cmp -s "$ciln" "$oracle" || fail "C-interpreted adapted emitter listing differs from the oracle (the fragment regressed under C)"
    cmp -s "$nat" "$ciln" || fail "native gen-1 emitter diverges from the C interpreter (faithfulness)"
    c_checked="(faithfulness vs C interpreter: native == C-interp == oracle)"
fi

echo "PASS: emitter native execution (gen-1-compiled emitter_fragment runs C-FREE, bytecode listing == independent oracle; $c_checked)"
