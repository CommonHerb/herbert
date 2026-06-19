#!/usr/bin/env bash
#
# Klondike native-execution gate (sovereignty axis, Role-C reduction -- the LAST
# metacircular fragment).
#
# klondike.herb is the consolidated toolchain (lex + parse + semantic check + lower
# + a bytecode VM + a Value serializer, ~3800 lines). It is the FIFTH and final
# metacircular fragment; the evaluator [dolly], VM [anon], parser [dolamite] and
# lexer [pahlavi] already run natively. Like those, klondike ran ONLY under the C
# interpreter, so deleting C would kill its self-description test. This gate gives
# klondike a COMMITTED NATIVE EXECUTION PATH: the C-free gen-1 seed (the production
# compiler) compiles it to an x86-64 ELF that runs with NO C in its execution path,
# reads a bundle (a Herbert SOURCE program + that program's runtime input),
# compiles+runs the embedded program, and emits the serialized result Value.
#
# WHY A GATE-TIME MAIN ADAPTER (and not an in-place edit like the other four).
# klondike's native-subset blocker was NOT a recursive-Value / backend gap (the
# canon's unverified claim, refuted by the silicon leg AND a cross-model Codex
# review); it is the SAME "main must return int/bool" issue the other fragments hit.
# klondike's main does `return serialize_value(result, pools)` -- serialize_value
# returns a STRING (freeze: buffer->string) -- so the native subset (main:int/bool)
# makes the verifier unify serialize_value's return signature to int (main returns
# its result), which collides with its string body -> a structural-type conflict
# surfaced as ERR 430 at line 3382. Replacing that ONE line with
# `do flogger(<result>); return 0` makes the entire ~3800-line toolchain compile
# clean under the PRISTINE committed seed -- NO backend change, NO reseed.
#
# Unlike the other four fragments, klondike's real main (returning the serialized
# string) is LOAD-BEARING for the beta-full META-CIRCULAR nesting suite (klondike
# runs klondike runs a probe; the inner result must propagate as a return value).
# So klondike.herb stays BYTE-IDENTICAL and the adapter is applied at gate time: the
# ~3760 lines of compiler/VM logic that run natively are byte-identical to the
# committed fragment; only the 1-line main I/O adapter (how the result leaves the
# program) differs -- the same "main is a thin I/O adapter" honesty the other native
# gates carry, here kept out of the committed file so the meta-circular role is
# preserved. The honest claim is exactly that: a mechanically-checked one-line main
# adapter makes the otherwise-unchanged toolchain compile and run under the seed --
# NOT that byte-identical klondike.herb is itself native-compilable. The transform
# asserts its anchor is present and unique, so a future rename fails LOUD (no a.out
# -> the gate fails closed), never silently passes.
#
# TWO assertion legs with deliberately different lifetimes (this is what keeps the
# gate a real C-removal, not a re-introduced C dependency):
#
#   (1) ENDURING / REQUIRED -- the native ELF's full transcript == the INDEPENDENT
#       hand-authored oracle, for TWO structurally-different probes, with NO C:
#         * metacircular_compute_probe on payload "5" == klondike_native_probe.expected
#           (arith, multi-way branch, non-tail + tail recursion, growable array,
#           tuple build, tuple serialization) -> "(5 15 15 200 18 0)";
#         * klondike_io_probe on payload "hello" == an inline answer key
#           (clogger length, string buffer build, int serialization) -> "5".
#       Plus an INPUT-SENSITIVITY check: the SAME ELF on payload "8" must produce a
#       DIFFERENT, specifically-correct transcript -> "(8 36 36 300 27 0)" -- so a
#       baked echo of one oracle cannot pass; klondike genuinely compiles+runs input.
#       These consult NO C and must pass AFTER the C interpreter is deleted (set
#       KLONDIKE_NATIVE_NO_C=1 or remove HERBERT). This is the sovereignty advance.
#
#   (2) RETIREABLE / OPTIONAL -- the native transcript == the C interpreter running
#       the SAME adapted klondike (a faithfulness cross-check; a genuine gen-1-vs-C
#       differential the gen2==gen1 fixpoint cannot give). MIGRATION GUARD only.
#
# RED-first: this gate, the native path, and the mutation proof do not exist before
# this link; mutating a reachable klondike VM rule makes the native output diverge
# from the oracle (proven by run_klondike_native_mutation.sh).
#
# SCOPE (honest): two fixed forcing probes. "These probes compile+run natively and
# match their oracles" is broad coverage of klondike's stages, but is NOT "klondike
# fully replaces the C toolchain over all programs".
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"

HERBERT="${HERBERT:-$repo_root/build/herbert}"
fragment="$repo_root/stack/klondike.herb"
compute_probe="$repo_root/stack/metacircular_compute_probe.herb"
io_probe="$repo_root/stack/klondike_io_probe.herb"
oracle="$repo_root/stack/klondike_native_probe.expected"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: klondike native execution ($1)"; exit 1; }

[[ -f "$fragment" ]] || fail "missing fragment $fragment"
[[ -f "$compute_probe" ]] || fail "missing probe $compute_probe"
[[ -f "$io_probe" ]] || fail "missing probe $io_probe"
[[ -f "$oracle" ]] || fail "missing oracle $oracle"

# --- 1. Acquire the C-free gen-1 production compiler (the committed seed) -------
source "$script_dir/native_codegen_oracle.sh"
native_codegen_ensure_compiler "$tmp/native-compiler" || fail "could not acquire gen-1 compiler"
GEN1="$NATIVE_CODEGEN_COMPILER"
[[ -x "$GEN1" ]] || fail "gen-1 compiler not executable: $GEN1"

# --- 2. Gate-time main adapter (klondike.herb stays byte-identical) -------------
adapter="$tmp/klondike_native.herb"
python3 - "$fragment" "$adapter" <<'PY'
import sys
src = open(sys.argv[1]).read()
old = "    return serialize_value(result, pools)\n"
new = ("    do flogger(serialize_value(result, pools))\n"
       "    do flogger(\"\\n\")\n"
       "    return 0\n")
n = src.count(old)
if n != 1:
    sys.stderr.write("main-adapter anchor count %d (want 1)\n" % n)
    sys.exit(9)
open(sys.argv[2], "w").write(src.replace(old, new, 1))
PY
[[ $? -eq 0 ]] || fail "main-adapter transform failed (anchor missing or not unique -- klondike main changed?)"

# --- helper: build a klondike bundle  \x00HERB1<len>\n<src><input> --------------
mkbundle() { # $1=probe-file  $2=payload-string  $3=outfile
    python3 - "$1" "$2" "$3" <<'PY'
import sys
src = open(sys.argv[1], "rb").read()
inp = sys.argv[2].encode()
open(sys.argv[3], "wb").write(b"\x00HERB1" + str(len(src)).encode() + b"\n" + src + inp)
PY
}

# --- 3. Compile the adapted klondike with gen-1 (once) --------------------------
# The gen-1 emitter writes ./a.out without the execute bit, so chmod +x before
# running (a missing chmod looks exactly like a C-vs-native divergence -- it is not).
bwd="$(mktemp -d "$tmp/build.XXXX")"
( cd "$bwd" && "$GEN1" <"$adapter" >compile.log 2>compile.err )
[[ -f "$bwd/a.out" ]] || fail "gen-1 did not compile adapted klondike: $(head -1 "$bwd/compile.log" 2>/dev/null)"
# Require a genuine ELF, not just any a.out: the native path must really be a
# gen-1-emitted ELF, not a wrapper/shim that echoes the oracle.
[[ "$(head -c4 "$bwd/a.out" | xxd -p)" == "7f454c46" ]] || fail "gen-1 output a.out is not an ELF (klondike did not compile to native code)"
chmod +x "$bwd/a.out" || fail "could not chmod the native ELF"
elf="$bwd/a.out"

# --- helper: run the ELF on (probe, payload), bind the well-formed transcript ----
# klondike emits the probe's own output, then the serialized result Value, then the
# return-0 marker. We bind the FULL transcript against the oracle; the last line ==
# "0" envelope check ensures the program ran to completion (returned 0) rather than
# crashing mid-way and happening to print a matching prefix. A timeout guards against
# a runaway (klondike runs an arbitrary embedded program).
native_run() { # $1=probe-file  $2=payload  $3=outfile  -> 0 ok / nonzero on failure
    local pf="$1" pay="$2" out="$3" rwd; rwd="$(mktemp -d "$tmp/run.XXXX")"
    mkbundle "$pf" "$pay" "$rwd/bundle"
    ( timeout 60s "$elf" <"$rwd/bundle" >"$out" 2>"$rwd/run.err" ) || { echo "    (native ELF exited nonzero/timed out on $(basename "$pf"), payload '$pay')"; return 1; }
    [[ -s "$out" ]] || { echo "    (native ELF produced empty output on payload '$pay')"; return 1; }
    [[ "$(tail -n1 "$out")" == "0" ]] || { echo "    (native transcript last line is not the return-0 marker on payload '$pay')"; return 1; }
    return 0
}

# --- 4. ENDURING leg: native transcript == independent oracle (NO C) ------------
nat5="$tmp/native.compute.5"
native_run "$compute_probe" "5" "$nat5" || fail "native gen-1 klondike did not run cleanly on compute/5"
cmp -s "$nat5" "$oracle" || fail "native klondike transcript (compute/5) differs from independent oracle (native=$(head -c80 "$nat5" | tr '\n' '|') oracle=$(head -c80 "$oracle" | tr '\n' '|'))"

# --- 4b. INPUT-SENSITIVITY (anti-forgery): payload 8 -> a DIFFERENT correct answer
nat8="$tmp/native.compute.8"
native_run "$compute_probe" "8" "$nat8" || fail "native gen-1 klondike did not run cleanly on compute/8"
cmp -s "$nat5" "$nat8" && fail "native klondike emitted IDENTICAL output for payload 5 and 8 (not input-driven -- a baked echo, not a real compile+run)"
printf 'P2-OK\n(8 36 36 300 27 0)\n0\n' >"$tmp/oracle8"
cmp -s "$nat8" "$tmp/oracle8" || fail "native klondike transcript (compute/8) differs from the independent answer key"

# --- 4c. SECOND PROBE (a structurally different program): klondike_io_probe ------
# Exercises clogger-length + string buffer build + INT-result serialization (the
# compute probe exercises tuple serialization). Answer key: the probe floggers
# "KLONDIKE-IO" then returns length("hello") == 5.
natio="$tmp/native.io.hello"
native_run "$io_probe" "hello" "$natio" || fail "native gen-1 klondike did not run cleanly on io/hello"
printf 'KLONDIKE-IO\n5\n0\n' >"$tmp/oracle_io"
cmp -s "$natio" "$tmp/oracle_io" || fail "native klondike transcript (io/hello) differs from the independent answer key (native=$(head -c80 "$natio" | tr '\n' '|'))"

# --- 5. RETIREABLE leg: faithfulness vs the C interpreter (migration guard) ------
# Runs ONLY while a C interpreter exists. KLONDIKE_NATIVE_NO_C=1 simulates the
# post-retirement world: the gate then passes on the enduring leg alone.
c_checked="(skipped: no C interpreter -- gate passes on the enduring oracle legs alone)"
if [[ "${KLONDIKE_NATIVE_NO_C:-0}" != "1" && -x "$HERBERT" ]]; then
    mkbundle "$compute_probe" "5" "$tmp/bundle5"
    ci="$tmp/cinterp.5"
    timeout 120s "$HERBERT" "$adapter" <"$tmp/bundle5" >"$ci" 2>/dev/null || fail "C interpreter could not run the adapted klondike"
    cmp -s "$ci" "$oracle" || fail "C-interpreted adapted klondike differs from the oracle (the fragment regressed under C)"
    cmp -s "$nat5" "$ci" || fail "native gen-1 klondike diverges from the C interpreter (faithfulness)"
    c_checked="(faithfulness vs C interpreter: native == C-interp == oracle)"
fi

echo "PASS: klondike native execution (gen-1-compiled adapted klondike runs C-FREE: compute_probe/'5' -> '(5 15 15 200 18 0)' == oracle; input-sensitive ('8' -> '(8 36 36 300 27 0)'); io_probe/'hello' -> '5'; $c_checked)"
