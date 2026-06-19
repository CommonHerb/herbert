#!/usr/bin/env bash
#
# Aggregate-render native-execution gate (sovereignty axis, D14 aggregate half).
#
# link11 teaches the native back end to canonically render a `main` that returns
# a FLAT int/bool TUPLE -- "(" + elements joined by ", " + ")" + newline, byte-
# identical to the C reference (bootstrap/value.c v_print_canonical_rec). Before
# this link, the native subset only let `main` return int/bool (kringle, D14's
# decimal/bool half) and rejected a tuple return with ERR432, so the foundational
# language tests that return a tuple (test_01/03/07/08/09) could be run ONLY by
# the C interpreter. This gate proves the C-free gen-1 seed (the production
# compiler) now compiles such a program to an x86-64 ELF that renders the tuple
# WITH NO C in its execution path -- a switchover prerequisite: the native
# toolchain cannot replace C as the reference until it reproduces the reference's
# output on these basic programs.
#
# TWO assertion legs, with deliberately different lifetimes (this is what keeps
# the gate a real native-capability advance rather than a C dependency):
#
#   (1) ENDURING / REQUIRED -- the native ELF's stdout == a COMMITTED answer key
#       (an INDEPENDENT hand-authored canonical string for the held-back probe,
#       and the committed .expected for the foundational probes). Consults NO C.
#       Must pass AFTER the C interpreter is deleted. This is the sovereignty
#       advance.
#
#   (2) RETIREABLE / OPTIONAL -- the native ELF's stdout == the C interpreter's
#       stdout (a faithfulness cross-check). A MIGRATION GUARD, not a permanent
#       dependency: it runs only while a C interpreter exists. Set
#       AGGREGATE_RENDER_NATIVE_NO_C=1 (or remove HERBERT) and the gate still
#       passes on leg (1) alone -- proving the C dependency is genuinely gone.
#
# RED-first: the native path, this gate, and the mutation proof do not exist
# before this link (the probes fail to compile -- ERR432 -- under the pre-link
# seed); mutating the renderer makes the native output diverge from the answer
# key (proven by run_aggregate_render_native_mutation.sh).
#
# SCOPE (honest): the rendered tuples are FLAT and every element is int or bool
# (2..15 elements). Nested-tuple / string / array element rendering is deferred
# to a later D14 installment and still ERR432 (verified below: test_06 -- nested
# tuples + strings -- does NOT compile). "main canonically prints its result" is
# the language's defined top-level behavior the .expected files codify; this
# completes it from scalar to flat aggregate.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"

HERBERT="${HERBERT:-$repo_root/build/herbert}"
tests_dir="$repo_root/bootstrap/tests"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: aggregate-render native execution ($1)"; exit 1; }

# --- 1. Acquire the C-free gen-1 production compiler (the committed seed) -------
source "$script_dir/native_codegen_oracle.sh"
native_codegen_ensure_compiler "$tmp/native-compiler" || fail "could not acquire gen-1 compiler"
GEN1="$NATIVE_CODEGEN_COMPILER"
[[ -x "$GEN1" ]] || fail "gen-1 compiler not executable: $GEN1"

# --- helper: compile a source with gen-1 (in $1's dir) and run, capturing stdout.
# The gen-1 emitter writes ./a.out without +x; chmod before running (a missing
# chmod looks exactly like a C-vs-native divergence -- it is not). Binds the FULL
# transcript: a genuine ELF whose stdout is EXACTLY the one rendered line.
native_render() {
    local src="$1" out="$2" wd; wd="$(mktemp -d "$tmp/run.XXXX")"
    ( cd "$wd" && "$GEN1" <"$src" >compile.log 2>compile.err )
    [[ -f "$wd/a.out" ]] || { echo "    (gen-1 compile produced no ELF: $(head -1 "$wd/compile.log" 2>/dev/null))"; return 1; }
    [[ "$(head -c4 "$wd/a.out" | xxd -p)" == "7f454c46" ]] || { echo "    (a.out is not an ELF)"; return 1; }
    chmod +x "$wd/a.out" || return 1
    "$wd/a.out" >"$wd/run.out" 2>"$wd/run.err" || { echo "    (native ELF exited nonzero)"; return 1; }
    [[ "$(wc -l <"$wd/run.out")" -eq 1 ]] || { echo "    (native output is not exactly 1 line: $(wc -l <"$wd/run.out"))"; return 1; }
    cp "$wd/run.out" "$out"
    return 0
}

# --- 2. ENDURING leg over a held-back probe (independent hand-authored key) -----
# A flat int/bool tuple computed from arithmetic so the rendered values are
# DERIVED, not baked literals: covers small ints, unsigned wrap to 2^64-1, both
# bools, zero, and ordered distinct elements (N=6).
probe="$tmp/aggregate_probe.herb"
cat >"$probe" <<'HERB'
func main():
    let a = 6 * 7              -- 42
    let big = 0 - 1           -- 2^64 - 1 (unsigned wrap)
    let lt = a < 10           -- false
    let gt = a > 10           -- true
    return (a, big, lt, gt, 0, 255)
end
HERB
want="$tmp/aggregate_probe.expected"
printf '(42, 18446744073709551615, false, true, 0, 255)\n' >"$want"

nat="$tmp/probe.out"
native_render "$probe" "$nat" || fail "held-back probe did not run cleanly under gen-1"
cmp -s "$nat" "$want" || fail "held-back probe native render != independent oracle (native=$(cat "$nat" | tr -d '\n') want=$(cat "$want" | tr -d '\n'))"

# A second held-back probe at MAX ARITY (N=15): exercises the imm32 sub/add rsp
# encoding (the sret scratch S=144 > 127, distinct from the imm8 path the smaller
# probes take) and the 15-element cap edge. Last element is a bool.
probe15="$tmp/aggregate_probe15.herb"
cat >"$probe15" <<'HERB'
func main():
    return (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 8 > 9)
end
HERB
want15="$tmp/aggregate_probe15.expected"
printf '(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, false)\n' >"$want15"
nat15="$tmp/probe15.out"
native_render "$probe15" "$nat15" || fail "max-arity (N=15) probe did not run cleanly under gen-1"
cmp -s "$nat15" "$want15" || fail "N=15 probe native render != oracle (imm32 sret path; native=$(cat "$nat15" | tr -d '\n'))"

# --- 3. ENDURING leg over the FOUNDATIONAL flat-tuple tests vs committed .expected.
# These are the actual language-conformance programs the C interpreter runs; the
# native toolchain now reproduces their output C-free. (test_02 ERR431 short-
# circuit, test_06 nested+strings, and the resource-bound tests are out of scope.)
foundational="test_01_arith test_03_if_elif test_07_array test_08_strings_buffer test_09_ref_vs_value"
for t in $foundational; do
    src="$tests_dir/$t.herb"; exp="$tests_dir/$t.expected"
    [[ -f "$src" && -f "$exp" ]] || fail "missing foundational probe $t"
    out="$tmp/$t.out"
    native_render "$src" "$out" || fail "foundational $t did not render natively"
    cmp -s "$out" "$exp" || fail "foundational $t native render != committed .expected (native=$(cat "$out" | tr -d '\n'))"
done

# --- 4. Out-of-scope cases are STILL rejected (the scope boundary is real, not
# silently widened): test_06 (nested tuple + string elements) must NOT compile.
wd6="$(mktemp -d "$tmp/r6.XXXX")"
( cd "$wd6" && "$GEN1" <"$tests_dir/test_06_tuples.herb" >c6.log 2>c6.err )
[[ ! -f "$wd6/a.out" ]] || fail "test_06 (nested tuple + strings) UNEXPECTEDLY compiled -- scope silently widened"
grep -q "432" "$wd6/c6.log" "$wd6/c6.err" 2>/dev/null || fail "test_06 rejected for the wrong reason (expected ERR432): $(head -1 "$wd6/c6.log")"

# --- 5. C-FREE proven, not asserted: run gen-1 with an EMPTY PATH (so no external
# toolchain -- cc/gcc/as/ld -- is reachable by name) and it must STILL emit the ELF
# + render. Only the gen-1 invocation is scrubbed; the harness tools keep the normal
# PATH. The native back end casts ELF directly; there is no hidden toolchain shellout.
cfwd="$tmp/cfree"; mkdir -p "$cfwd"
( cd "$cfwd" && PATH="" "$GEN1" <"$probe" >c.log 2>c.err )
[[ -f "$cfwd/a.out" ]] || fail "gen-1 emitted no ELF under an empty PATH (no external toolchain) -- C-free claim unproven"
[[ "$(head -c4 "$cfwd/a.out" | xxd -p)" == "7f454c46" ]] || fail "C-free a.out is not an ELF"
chmod +x "$cfwd/a.out"
"$cfwd/a.out" >"$cfwd/run.out" 2>/dev/null || fail "C-free ELF exited nonzero"
cmp -s "$cfwd/run.out" "$want" || fail "C-free (empty-PATH) render != oracle"

# --- 6. RETIREABLE leg: faithfulness vs the C interpreter (migration guard) -----
# Runs ONLY while a C interpreter exists. AGGREGATE_RENDER_NATIVE_NO_C=1 simulates
# the post-retirement world: the gate then passes on the enduring legs alone.
c_checked="(skipped: no C interpreter -- gate passes on the enduring oracle legs alone)"
if [[ "${AGGREGATE_RENDER_NATIVE_NO_C:-0}" != "1" && -x "$HERBERT" ]]; then
    cprobe="$tmp/probe.cinterp"
    "$HERBERT" "$probe" >"$cprobe" 2>/dev/null || fail "C interpreter could not run the held-back probe"
    cmp -s "$cprobe" "$want" || fail "C-interpreted held-back probe != oracle (reference regressed)"
    cmp -s "$nat" "$cprobe" || fail "native render diverges from the C interpreter (faithfulness)"
    cprobe15="$tmp/probe15.cinterp"
    "$HERBERT" "$probe15" >"$cprobe15" 2>/dev/null || fail "C interpreter could not run the N=15 probe"
    cmp -s "$nat15" "$cprobe15" || fail "native N=15 render diverges from the C interpreter (faithfulness)"
    for t in $foundational; do
        cf="$tmp/$t.cinterp"
        "$HERBERT" "$tests_dir/$t.herb" >"$cf" 2>/dev/null || fail "C interpreter could not run $t"
        cmp -s "$tmp/$t.out" "$cf" || fail "native $t diverges from the C interpreter (faithfulness)"
    done
    c_checked="(faithfulness vs C interpreter: native == C-interp == oracle, held-back + 5 foundational)"
fi

echo "PASS: aggregate-render native execution (gen-1 renders flat int/bool tuples C-FREE: held-back probe + test_01/03/07/08/09 == committed keys; test_06 still ERR432; $c_checked)"
