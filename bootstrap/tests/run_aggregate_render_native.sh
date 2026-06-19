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
# SCOPE (honest): link11 rendered FLAT int/bool tuples; link12 (D14) extends this
# to STRINGS (the escaping byte-identical to value.c print_string_lit: 10->\n,
# 92->\\, 34->\", else raw) and NESTED tuples (recursively), so a renderable result
# is int/bool/string or a tuple of renderables, total width 2..15 result words. This
# unblocks test_06 (nested tuple + strings), the LAST rendering-blocked foundational
# test. STILL out of scope (verified below: must ERR432): ARRAY/BUFFER results and
# any aggregate CONTAINING one, and aggregates wider than 15 words. "main canonically
# prints its result" is the language's defined top-level behavior the .expected files
# codify; this completes its aggregate rendering (scalar -> flat -> string/nested).
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

# --- 2b. ENDURING leg: link12 STRING escaping (held-back, DERIVED bytes). The
# string is built at runtime from a buffer so its content is not a baked literal,
# and it carries ALL THREE escape bytes (34->\", 92->\\, 10->\n) plus a raw byte,
# proving the escaping loop is byte-identical to value.c print_string_lit. The key
# is hand-authored with explicit byte escapes (independent of the native output).
probe_str="$tmp/aggregate_probe_str.herb"
cat >"$probe_str" <<'HERB'
func main():
    let b = new_buffer()
    do append(b, 34)          -- "  -> \"
    do append(b, 92)          -- \  -> \\
    do append(b, 10)          -- nl -> \n
    do append(b, 65)          -- A  -> A (raw)
    let s = freeze(b)
    return (s, 6 * 7)
end
HERB
want_str="$tmp/aggregate_probe_str.expected"
# ("\"\\\nA", 42)\n  -- bytes spelled out so the key owes nothing to the renderer.
printf '\x28\x22\x5c\x22\x5c\x5c\x5c\x6e\x41\x22\x2c\x20\x34\x32\x29\x0a' >"$want_str"
nat_str="$tmp/probe_str.out"
native_render "$probe_str" "$nat_str" || fail "string-escaping probe did not run cleanly under gen-1"
cmp -s "$nat_str" "$want_str" || fail "string-escaping native render != independent oracle (native=$(cat "$nat_str" | tr -d '\n'))"

# --- 2c. ENDURING leg: link12 NESTED tuples (held-back, DERIVED + a string elem).
# Exercises a string element, a nested 2-tuple, and a doubly-nested tuple, with the
# word offset accumulating across mixed-width elements.
probe_nest="$tmp/aggregate_probe_nest.herb"
cat >"$probe_nest" <<'HERB'
func main():
    let a = 3 * 4             -- 12
    let s = "hi"
    return (a, (s, a > 5), (1, (2, 3)))
end
HERB
want_nest="$tmp/aggregate_probe_nest.expected"
printf '(12, ("hi", true), (1, (2, 3)))\n' >"$want_nest"
nat_nest="$tmp/probe_nest.out"
native_render "$probe_nest" "$nat_nest" || fail "nested-tuple probe did not run cleanly under gen-1"
cmp -s "$nat_nest" "$want_nest" || fail "nested-tuple native render != independent oracle (native=$(cat "$nat_nest" | tr -d '\n'))"

# --- 3. ENDURING leg over the FOUNDATIONAL tuple tests vs committed .expected.
# These are the actual language-conformance programs the C interpreter runs; the
# native toolchain now reproduces their output C-free. link12 adds test_06 (nested
# tuple + strings), the LAST rendering-blocked foundational test. (test_02 ERR431
# short-circuit and the resource-bound tests test_10..14 remain C-only -- D13/D16,
# not rendering -- so a COMPLETE foundational fence is still future work.)
foundational="test_01_arith test_03_if_elif test_06_tuples test_07_array test_08_strings_buffer test_09_ref_vs_value"
for t in $foundational; do
    src="$tests_dir/$t.herb"; exp="$tests_dir/$t.expected"
    [[ -f "$src" && -f "$exp" ]] || fail "missing foundational probe $t"
    out="$tmp/$t.out"
    native_render "$src" "$out" || fail "foundational $t did not render natively"
    cmp -s "$out" "$exp" || fail "foundational $t native render != committed .expected (native=$(cat "$out" | tr -d '\n'))"
done

# --- 4. Out-of-scope cases are STILL rejected (the scope boundary is real, not
# silently widened). Strings + nested tuples now render; what remains out of scope
# must ERR432: (a) an ARRAY result, (b) a tuple with an array element, (c) an
# aggregate WIDER than 15 result words. Each must produce NO ELF + report ERR432.
reject_oos() {
    local name="$1" src="$2" wd; wd="$(mktemp -d "$tmp/roos.XXXX")"
    printf '%s\n' "$src" >"$wd/p.herb"
    ( cd "$wd" && "$GEN1" <"$wd/p.herb" >oos.log 2>oos.err )
    [[ ! -f "$wd/a.out" ]] || fail "out-of-scope $name UNEXPECTEDLY compiled -- scope silently widened"
    grep -q "432" "$wd/oos.log" "$wd/oos.err" 2>/dev/null || fail "out-of-scope $name rejected for the wrong reason (expected ERR432): $(head -1 "$wd/oos.log")"
}
reject_oos "array-result"  'func main():
    let xs = new_array(int)
    return xs
end'
reject_oos "array-element" 'func main():
    return (1, new_array(int))
end'
reject_oos "width-16"      'func main():
    return (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16)
end'

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
# The link12 string-escaping path is also C-free (emits an ELF + renders under empty PATH).
cfwd2="$tmp/cfree_str"; mkdir -p "$cfwd2"
( cd "$cfwd2" && PATH="" "$GEN1" <"$probe_str" >c.log 2>c.err )
[[ -f "$cfwd2/a.out" ]] || fail "gen-1 emitted no ELF for the string probe under an empty PATH -- C-free claim unproven"
chmod +x "$cfwd2/a.out"
"$cfwd2/a.out" >"$cfwd2/run.out" 2>/dev/null || fail "C-free string ELF exited nonzero"
cmp -s "$cfwd2/run.out" "$want_str" || fail "C-free (empty-PATH) string render != oracle"

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
    cprobe_str="$tmp/probe_str.cinterp"
    "$HERBERT" "$probe_str" >"$cprobe_str" 2>/dev/null || fail "C interpreter could not run the string probe"
    cmp -s "$nat_str" "$cprobe_str" || fail "native string render diverges from the C interpreter (faithfulness)"
    cmp -s "$cprobe_str" "$want_str" || fail "C-interpreted string probe != oracle (reference regressed)"
    cprobe_nest="$tmp/probe_nest.cinterp"
    "$HERBERT" "$probe_nest" >"$cprobe_nest" 2>/dev/null || fail "C interpreter could not run the nested probe"
    cmp -s "$nat_nest" "$cprobe_nest" || fail "native nested render diverges from the C interpreter (faithfulness)"
    cmp -s "$cprobe_nest" "$want_nest" || fail "C-interpreted nested probe != oracle (reference regressed)"
    for t in $foundational; do
        cf="$tmp/$t.cinterp"
        "$HERBERT" "$tests_dir/$t.herb" >"$cf" 2>/dev/null || fail "C interpreter could not run $t"
        cmp -s "$tmp/$t.out" "$cf" || fail "native $t diverges from the C interpreter (faithfulness)"
    done
    c_checked="(faithfulness vs C interpreter: native == C-interp == oracle, held-back flat/string/nested + 6 foundational)"
fi

echo "PASS: aggregate-render native execution (gen-1 renders flat/string/NESTED tuples C-FREE: held-back flat+string+nested probes + test_01/03/06/07/08/09 == committed keys; array/array-elem/width-16 still ERR432; $c_checked)"
