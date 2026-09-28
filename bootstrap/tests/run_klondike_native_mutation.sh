#!/usr/bin/env bash
#
# Mutation proof for the klondike native-execution gate (run_klondike_native.sh).
#
# Proves the gate BITES on the C-FREE path: a reachable klondike VM rule (int_binop
# -- the bytecode VM's integer arithmetic/comparison that RUNS the embedded probe),
# mutated, still COMPILES under the native subset but makes the gen-1-compiled ELF
# emit a serialized result that DIVERGES from the independent oracle -- so the gate's
# ENDURING leg (native transcript == klondike_native_probe.expected, no C consulted)
# goes RED. Each mutation is one that compiles-but-diverges (a wrong RUNTIME VALUE in
# the emitted tuple), the strong bite. The CONTROL (adapter only, unmutated) grades
# GREEN first, so the grader is not vacuous.
#
# int_binop is the VM's interpretation of the PROBE's bytecode -- klondike's own
# compiler (lex/parse/lower) uses native operators directly, so each mutation
# corrupts only the probe's computed result, not klondike's compilation. The probe
# (metacircular_compute_probe) exercises +, <, == densely (tri/sum_tail recursion,
# band multi-way branch, first_digit guards), so each anchor is reached.
#
# Everything here runs through the native gen-1 ELF and the committed oracle with NO
# C interpreter in the graded path -- the proof is about the C-free execution.
set -u

unset CDPATH
script_dir="$(cd -- "$(dirname -- "$0")" && pwd)" || exit 1
repo_root="$(cd "$script_dir/../.." && pwd)"
fragment="$repo_root/stack/klondike.herb"
probe="$repo_root/stack/metacircular_compute_probe.herb"
oracle="$repo_root/stack/klondike_native_probe.expected"
gate="$script_dir/run_klondike_native.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass=0
FAILED=0
fail_test() { echo "FAIL: klondike native mutation ($1)"; FAILED=1; }

[[ -f "$fragment" ]] || { echo "FAIL: missing fragment"; exit 1; }
[[ -f "$probe" ]] || { echo "FAIL: missing probe"; exit 1; }
[[ -f "$oracle" ]] || { echo "FAIL: missing oracle"; exit 1; }
[[ -f "$gate" && -r "$gate" ]] || { echo "FAIL: missing klondike native gate"; exit 1; }

source "$script_dir/native_codegen_oracle.sh" || { echo "FAIL: cannot source native-codegen oracle" >&2; exit 1; }
native_codegen_ensure_compiler "$tmp/native-compiler" || { echo "FAIL: could not acquire gen-1 compiler"; exit 1; }
GEN1="$NATIVE_CODEGEN_COMPILER"
[[ -x "$GEN1" ]] || { echo "FAIL: gen-1 not executable"; exit 1; }

mkbundle() { # $1=payload  $2=outfile
    python3 - "$probe" "$1" "$2" <<'PY'
import sys
src = open(sys.argv[1], "rb").read()
inp = sys.argv[2].encode()
open(sys.argv[3], "wb").write(b"\x00HERB1" + str(len(src)).encode() + b"\n" + src + inp)
PY
}

# Produce an adapted (main->flogger+return0) klondike, optionally with ONE extra
# anchor substitution applied first. Asserts both anchors are unique (an unscoped
# multi-hit substitution is rejected with exit 3). Writes to $out. When $raw is
# given, the mutated but UNADAPTED source is also written there, before the
# adapter step: the actual gate applies its own adapter, so it must receive that.
make_variant() { # $1=out  [$2=mut_old $3=mut_new $4=raw]
    local out="$1" mo="${2:-}" mn="${3:-}" raw="${4:-}"
    MUT_OLD="$mo" MUT_NEW="$mn" python3 - "$fragment" "$out" "$raw" <<'PY'
import os, sys
src = open(sys.argv[1]).read()
mo, mn = os.environ.get("MUT_OLD",""), os.environ.get("MUT_NEW","")
if mo:
    if src.count(mo) != 1:
        sys.stderr.write("mutation anchor count %d\n" % src.count(mo)); sys.exit(3)
    src = src.replace(mo, mn, 1)
if sys.argv[3]:
    open(sys.argv[3], "w").write(src)
adapt_old = "    return serialize_value(result, pools)\n"
adapt_new = ("    do flogger(serialize_value(result, pools))\n"
             "    do flogger(\"\\n\")\n"
             "    return 0\n")
if src.count(adapt_old) != 1:
    sys.stderr.write("adapter anchor count %d\n" % src.count(adapt_old)); sys.exit(4)
open(sys.argv[2], "w").write(src.replace(adapt_old, adapt_new, 1))
PY
    return $?
}

# Compile a variant with gen-1 and emit its payload-5 transcript (or a status code).
# rc: 0 ok / 2 did-not-compile / 3 malformed-envelope / other = run crash.
native_transcript() { # $1=variant.herb  $2=outfile
    local src="$1" out="$2" wd; wd="$(mktemp -d "$tmp/run.XXXX")"
    : >"$out"
    native_codegen_compile_success "$GEN1" "$src" "$wd" || return 2
    [[ -f "$wd/a.out" ]] || return 2
    [[ "$(head -c4 "$wd/a.out" | xxd -p)" == "7f454c46" ]] || return 2
    chmod +x "$wd/a.out" || return 1
    mkbundle "5" "$wd/bundle"
    # timeout guard: a mutation can make the embedded program run away (e.g. the VM's
    # `+` rule mutated to `-` loops); such a mutation is NOT a clean wrong-value bite,
    # so treat a timeout like any non-clean run (caller fails it) without hanging.
    ( timeout 60s "$wd/a.out" <"$wd/bundle" >"$wd/run.out" 2>"$wd/run.err" ); local r=$?
    [[ $r -eq 0 ]] || return $r
    # Well-formed envelope (pahlavi's tightening): the compute probe's transcript is
    # EXACTLY 3 lines -- the probe's own marker "P2-OK", the serialized result tuple,
    # and the return-0 marker. Pinning the STABLE lines (1 == "P2-OK", count == 3,
    # last == "0") proves each shipped mutation is a CLEAN WRONG-VALUE bite -- only the
    # result line (2) diverges while the probe path/envelope stays intact -- not merely
    # "broken output that happens to differ from the oracle" (e.g. an unrelated
    # diagnostic + 0). A mutation that breaks the FORMAT is rejected (rc 3).
    [[ "$(wc -l <"$wd/run.out")" -eq 3 ]] || return 3
    [[ "$(sed -n 1p "$wd/run.out")" == "P2-OK" ]] || return 3
    [[ "$(sed -n 3p "$wd/run.out")" == "0" ]] || return 3
    cp "$wd/run.out" "$out"
    return 0
}

# Exercise the production gate, including its own oracle comparison. The separate
# native run above qualifies the mutation; it must not stand in for this check.
# The gate receives UNADAPTED source and applies its own main adapter.
actual_gate() {
    KLONDIKE_NATIVE_NO_C=1 NATIVE_CODEGEN_COMPILER="$GEN1" \
        bash "$gate" --fragment "$1" >"$2" 2>&1
}

# ===== CONTROL: adapter-only (unmutated) klondike must grade GREEN ==============
ctl_src="$tmp/ctl.herb"; ctl="$tmp/ctl.out"
if make_variant "$ctl_src" && native_transcript "$ctl_src" "$ctl" && cmp -s "$ctl" "$oracle" && \
        actual_gate "$fragment" "$tmp/control.gate.log"; then
    pass=$((pass + 1))
else
    fail_test "CONTROL: unmutated klondike did not match the oracle and pass the actual gate"
fi

# ===== mutation helper: require the STRONG bite (compiles, runs, diverges) ======
mutate_expect_red() {
    local label="$1" old="$2" new="$3"
    local m="$tmp/mut.$label.herb" raw="$tmp/mut.$label.raw.herb" out="$tmp/mut.$label.out"
    make_variant "$m" "$old" "$new" "$raw"; local mk=$?
    if [[ $mk -eq 3 ]]; then
        fail_test "$label: mutation anchor '$old' is not unique in klondike (unscoped mutation)"
        return
    fi
    if [[ $mk -ne 0 ]]; then
        fail_test "$label: could not build mutated variant (rc=$mk)"
        return
    fi
    native_transcript "$m" "$out"; local rc=$?
    if [[ $rc -eq 2 ]]; then
        fail_test "$label: mutated klondike did NOT compile to a native ELF (want compiles-runs-wrong-value)"
        return
    fi
    if [[ $rc -eq 3 ]]; then
        fail_test "$label: mutated native ELF produced a MALFORMED envelope (want a clean wrong-VALUE bite)"
        return
    fi
    if [[ $rc -ne 0 ]]; then
        fail_test "$label: mutated native ELF did not run cleanly (rc=$rc)"
        return
    fi
    if cmp -s "$out" "$oracle"; then
        fail_test "$label: mutated klondike STILL matched the oracle -- the gate is blind to this rule"
    elif actual_gate "$raw" "$tmp/$label.gate.log"; then
        fail_test "$label: actual klondike gate accepted a qualified wrong-value mutation"
    # Keep this prefix in sync with the enduring-leg failure in run_klondike_native.sh.
    elif ! grep -Fq 'FAIL: klondike native execution (native klondike transcript (compute/5) differs from independent oracle' "$tmp/$label.gate.log"; then
        fail_test "$label: actual klondike gate failed outside its enduring oracle comparison"
    else
        pass=$((pass + 1))
    fi
}

# The three anchors are int_binop's integer ADD / less-than / equals rules -- the VM
# arithmetic that computes the probe's result tuple. Each is unique in klondike.herb
# (the sub/le/gt/ge/ne siblings are deliberately untouched, so each appears once).

# M-add: the VM's `+` rule, perturbed off-by-one (`+ rhs` -> `+ rhs + 1`). The probe
# adds densely (tri: n+tri(n-1); sum_tail: acc+n; asum: get+get+get; n+1, n+2), so
# every sum shifts and the result tuple diverges. Off-by-one (not `+`->`-`) keeps the
# probe's recursion bounded and FAST -- a `+`->`-` mutation makes the embedded program
# run away (the timeout guard would catch it, but it is not a clean wrong-VALUE bite).
mutate_expect_red "M-add" 'return make_int_value(lhs + rhs)' 'return make_int_value(lhs + rhs + 1)'

# M-lt: the VM's `<` rule. The probe branches on `<` (band: n<3/n<7; first_digit:
# c<'0'/c>'9'), so flipping it to `>` reshapes band's multi-way result. A distinct rule.
mutate_expect_red "M-lt" 'return make_bool_value(lhs < rhs)' 'return make_bool_value(lhs > rhs)'

# M-eq: the VM's `==` rule. The probe's recursion base cases are `if n == 0`, so
# flipping to `!=` inverts every base case -> the whole tuple changes. A third rule.
mutate_expect_red "M-eq" 'return make_bool_value(lhs == rhs)' 'return make_bool_value(lhs != rhs)'

echo "klondike native mutation proof: pass=$pass"
if [[ $FAILED -eq 0 && $pass -eq 4 ]]; then
    echo "PASS: klondike native mutation (CONTROL green; M-add/M-lt/M-eq each compile natively then DIVERGE from the oracle and are rejected by the actual C-free gate)"
else
    exit 1
fi
