#!/usr/bin/env bash
#
# Mutation proof for the emitter native-execution gate (run_emitter_native.sh).
#
# Proves the gate BITES on the C-FREE path: a reachable LOWERING rule, mutated, still
# COMPILES under the native subset but makes the gen-1-compiled ELF emit a bytecode
# listing that DIVERGES from the independent oracle (stack/emitter_probe.expected) -- so
# the gate's ENDURING leg (native listing == oracle, no C consulted) goes RED. Each
# mutation is one that compiles-but-diverges, the strong bite. The CONTROL (adapter only,
# unmutated) grades GREEN first, so the grader is not vacuous.
#
# The five mutations span THREE DISTINCT lowering behaviors (answering the cross-model
# Codex flag that "narrow mutations make a gate ceremony"):
#   * opcode mapping     -- opcode_for_binop: the AST-tag -> bytecode-opcode table (the
#                           probe lowers + / < / == densely, so each is reached);
#   * frame/slot layout  -- env_from_params_loop: the per-parameter local-slot assignment
#                           (every function with parameters is reached);
#   * control flow       -- emit_if_arms: the conditional-branch opcode for `if` arms
#                           (the probe branches with if/elif/else throughout).
# Unlike a fragment that RUNS the probe, the emitter only LOWERS + SERIALIZES it
# deterministically, so a lowering mutation can never run away -- it yields a structurally
# valid but content-divergent listing. The well-formed envelope (first == STRING_POOL,
# FUNCTIONS + CODE present, last == "0") proves each shipped mutation is a clean
# wrong-LISTING bite, not "broken output that merely differs".
#
# Everything here runs through the native gen-1 ELF and the committed oracle with NO C
# interpreter in the graded path -- the proof is about the C-free execution.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
fragment="$repo_root/stack/emitter_fragment.herb"
oracle="$repo_root/stack/emitter_probe.expected"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass=0
FAILED=0
fail_test() { echo "FAIL: emitter native mutation ($1)"; FAILED=1; }

[[ -f "$fragment" ]] || { echo "FAIL: missing fragment"; exit 1; }
[[ -f "$oracle" ]] || { echo "FAIL: missing oracle"; exit 1; }

source "$script_dir/native_codegen_oracle.sh"
native_codegen_ensure_compiler "$tmp/native-compiler" || { echo "FAIL: could not acquire gen-1 compiler"; exit 1; }
GEN1="$NATIVE_CODEGEN_COMPILER"
[[ -x "$GEN1" ]] || { echo "FAIL: gen-1 not executable"; exit 1; }

# Produce an adapted (main->flogger+return0) emitter, optionally with ONE extra anchor
# substitution applied first. Asserts both anchors are unique (an unscoped multi-hit
# substitution is rejected with exit 3). Writes to $out.
make_variant() { # $1=out  [$2=mut_old $3=mut_new]
    local out="$1" mo="${2:-}" mn="${3:-}"
    MUT_OLD="$mo" MUT_NEW="$mn" python3 - "$fragment" "$out" <<'PY'
import os, sys
src = open(sys.argv[1]).read()
mo, mn = os.environ.get("MUT_OLD",""), os.environ.get("MUT_NEW","")
if mo:
    if src.count(mo) != 1:
        sys.stderr.write("mutation anchor count %d\n" % src.count(mo)); sys.exit(3)
    src = src.replace(mo, mn, 1)
adapt_old = "    return serialize_bytecode(prog)\n"
adapt_new = ("    do flogger(serialize_bytecode(prog))\n"
             "    return 0\n")
if src.count(adapt_old) != 1:
    sys.stderr.write("adapter anchor count %d\n" % src.count(adapt_old)); sys.exit(4)
open(sys.argv[2], "w").write(src.replace(adapt_old, adapt_new, 1))
PY
    return $?
}

# A STRUCTURALLY VALID listing transcript: the three section headers each exactly once and
# in order (STRING_POOL < FUNCTIONS < CODE), ending in the return-0 marker. Rejects
# marker-shaped garbage / duplicated-or-reordered sections / broad serializer corruption as
# a false bite (folds a cross-model Codex impl-review point).
listing_well_formed() {
    local f="$1"
    [[ "$(tail -n1 "$f")" == "0" ]] || return 1
    [[ "$(grep -cx STRING_POOL "$f")" -eq 1 ]] || return 1
    [[ "$(grep -cx FUNCTIONS "$f")" -eq 1 ]] || return 1
    [[ "$(grep -cx CODE "$f")" -eq 1 ]] || return 1
    local sp fn cd
    sp="$(grep -nx STRING_POOL "$f" | cut -d: -f1)"
    fn="$(grep -nx FUNCTIONS "$f" | cut -d: -f1)"
    cd="$(grep -nx CODE "$f" | cut -d: -f1)"
    [[ "$sp" -lt "$fn" && "$fn" -lt "$cd" ]] || return 1
    return 0
}

# Compile a variant with gen-1 and emit its bytecode listing (or a status code).
# rc: 0 ok / 2 did-not-compile / 3 malformed-envelope / other = run crash.
# Compiled with a SCRUBBED PATH (cc/gcc/as/ld unreachable) so a mutated bite is still proven
# C-free AND external-toolchain-free, exactly like the main gate.
native_listing() { # $1=variant.herb  $2=outfile
    local src="$1" out="$2" wd; wd="$(mktemp -d "$tmp/run.XXXX")"
    : >"$out"
    ( cd "$wd" && env PATH=/nonexistent "$GEN1" <"$src" >compile.log 2>compile.err )
    [[ -f "$wd/a.out" ]] || return 2
    [[ "$(head -c4 "$wd/a.out" | xxd -p)" == "7f454c46" ]] || return 2
    chmod +x "$wd/a.out" || return 1
    ( timeout 60s "$wd/a.out" >"$wd/run.out" 2>"$wd/run.err" ); local r=$?
    [[ $r -eq 0 ]] || return $r
    [[ -s "$wd/run.err" ]] && return 3
    # Well-formed envelope: a STRUCTURALLY VALID bytecode listing that ran to completion.
    # (The line count is NOT pinned -- a lowering mutation may legitimately add/remove an
    # instruction -- but the listing must still be a complete listing, so a clean
    # wrong-LISTING bite is distinguished from broken garbage.)
    listing_well_formed "$wd/run.out" || return 3
    head -n -1 "$wd/run.out" >"$out"
    return 0
}

# Right-reason signature: prove the bite is the INTENDED divergence, not an incidental one.
#   drop:TOKEN  -- the mutant listing must contain ZERO lines matching " TOKEN" (the
#                  operator/branch was substituted away), e.g. drop:ADD / drop:BR_IF_FALSE.
#   operands    -- the opcode-mnemonic skeleton (the 2nd field of every listing line) is
#                  UNCHANGED vs the oracle while the full listing DIFFERS, i.e. a pure
#                  frame/operand bite (no opcode corrupted) -- the M-frame shape.
sig_ok() { # $1=listing  $2=spec
    local listing="$1" spec="$2"
    case "$spec" in
        drop:*)
            # field 2 of every listing line is the opcode mnemonic; after the substitution
            # the mutated-away mnemonic must appear ZERO times.
            local tok="${spec#drop:}"
            [[ "$(awk '{print $2}' "$listing" | grep -cx "$tok")" -eq 0 ]]
            ;;
        operands)
            # the opcode-mnemonic skeleton (field 2 of every line) is UNCHANGED vs the oracle
            # while the full listing DIFFERS -> a pure frame/operand bite (no opcode corrupted).
            ! cmp -s "$listing" "$oracle" \
              && [[ "$(awk '{print $2}' "$listing")" == "$(awk '{print $2}' "$oracle")" ]]
            ;;
        *) return 1 ;;
    esac
}

# ===== CONTROL: adapter-only (unmutated) emitter must grade GREEN ================
ctl_src="$tmp/ctl.herb"; ctl="$tmp/ctl.out"
if make_variant "$ctl_src" && native_listing "$ctl_src" "$ctl" && cmp -s "$ctl" "$oracle"; then
    pass=$((pass + 1))
else
    fail_test "CONTROL: unmutated adapted emitter did not grade GREEN (native listing != oracle) -- grader vacuous"
fi

# ===== mutation helper: require the STRONG bite (compiles, runs, diverges) =======
mutate_expect_red() {
    local label="$1" old="$2" new="$3" sig="$4"
    local m="$tmp/mut.$label.herb" out="$tmp/mut.$label.out"
    make_variant "$m" "$old" "$new"; local mk=$?
    if [[ $mk -eq 3 ]]; then
        fail_test "$label: mutation anchor is not unique in emitter (unscoped mutation)"
        return
    fi
    if [[ $mk -ne 0 ]]; then
        fail_test "$label: could not build mutated variant (rc=$mk)"
        return
    fi
    native_listing "$m" "$out"; local rc=$?
    if [[ $rc -eq 2 ]]; then
        fail_test "$label: mutated emitter did NOT compile to a native ELF (want compiles-runs-wrong-listing)"
        return
    fi
    if [[ $rc -eq 3 ]]; then
        fail_test "$label: mutated native ELF produced a MALFORMED listing (want a clean wrong-LISTING bite)"
        return
    fi
    if [[ $rc -ne 0 ]]; then
        fail_test "$label: mutated native ELF did not run cleanly (rc=$rc)"
        return
    fi
    if cmp -s "$out" "$oracle"; then
        fail_test "$label: mutated emitter STILL matched the oracle -- the gate is blind to this rule"
        return
    fi
    # RIGHT-REASON: the divergence must be the INTENDED one (not incidental garbage that
    # merely differs) -- folds a cross-model Codex impl-review point.
    if ! sig_ok "$out" "$sig"; then
        fail_test "$label: mutant diverges but NOT in the expected way (signature '$sig' not met) -- bite is for the wrong reason"
        return
    fi
    pass=$((pass + 1))
}

# A VALID mutation must hit a SELECTION site (which opcode/slot/branch the lowering CHOOSES),
# never an opcode CONSTRUCTOR's value: the disassembler (opcode_name) reads `if op == op_X()`,
# so changing op_add()'s returned constant shifts BOTH the emitted byte AND the printed
# mnemonic together and the listing is UNCHANGED -- a vacuous (non-biting) mutation. All five
# below mutate selection sites (opcode_for_binop / env_from_params_loop / emit_if_arms).

# --- opcode mapping (opcode_for_binop): three distinct operator->opcode entries ---
# M-add: `+` lowers to op_sub -> every ADD in the CODE section becomes SUB (signature:
# the ADD mnemonic disappears entirely).
mutate_expect_red "M-add" 'if equal(tag, "add"):
        return op_add()' 'if equal(tag, "add"):
        return op_sub()' 'drop:ADD'

# M-lt: `<` lowers to op_gt -> the comparison opcode diverges (a distinct table entry;
# the LT mnemonic disappears).
mutate_expect_red "M-lt" 'if equal(tag, "lt"):
        return op_lt()' 'if equal(tag, "lt"):
        return op_gt()' 'drop:LT'

# M-eq: `==` lowers to op_ne -> the equality opcode diverges (a third table entry; the EQ
# mnemonic disappears).
mutate_expect_red "M-eq" 'if equal(tag, "eq"):
        return op_eq()' 'if equal(tag, "eq"):
        return op_ne()' 'drop:EQ'

# --- frame/slot layout (env_from_params_loop): the per-parameter local-slot assignment
# M-frame: each parameter is bound to slot i+1 instead of i -> every LOAD/STORE_LOCAL
# operand shifts while the opcode mnemonics are unchanged; a structurally different lowering
# concern (signature: the opcode skeleton is identical, only operands diverge).
mutate_expect_red "M-frame" 'do add(slots, i)
    return env_from_params_loop(params, i + 1, n, names, slots)' 'do add(slots, i + 1)
    return env_from_params_loop(params, i + 1, n, names, slots)' 'operands'

# --- control flow (emit_if_arms): the conditional-branch opcode for `if` arms
# M-cf: the `if`-arm conditional branch BR_IF_FALSE is emitted as an unconditional BR ->
# the CODE section's branch opcode diverges (signature: the BR_IF_FALSE mnemonic disappears);
# a third distinct lowering behavior.
mutate_expect_red "M-cf" 'ir = emit_target_instr(ir, op_br_if_false(), next_label)' 'ir = emit_target_instr(ir, op_br(), next_label)' 'drop:BR_IF_FALSE'

echo "emitter native mutation proof: pass=$pass"
if [[ $FAILED -eq 0 && $pass -eq 6 ]]; then
    echo "PASS: emitter native mutation (CONTROL green; M-add/M-lt/M-eq/M-frame/M-cf each compile natively then DIVERGE from the oracle across opcode/frame/control-flow lowering -- the C-free gate bites)"
else
    exit 1
fi
