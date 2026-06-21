#!/usr/bin/env bash
# Run every test_*.herb in this directory through the interpreter and
# compare its stdout (byte for byte) against the matching .expected file.
# Also run every stack/*.herb that ships with a matching .expected file,
# so the Herbert-side artifacts under stack/ are exercised by the same
# suite. Stops after running all tests and exits non-zero if any failed.
#
# Bounded-memory regression check: each run sets HERBERT_REPORT_PEAK=1 so
# the interpreter emits "peak-live-scopes: N" on stderr. If the .herb's
# sibling .maxscopes file exists, its single integer is taken as an upper
# bound on N — the test fails if the bound is exceeded. This guards the
# tail-call frame-reclamation invariant: tail-recursive iteration must
# run in scope memory bounded by a small constant independent of depth.
set -u

cd "$(dirname "$0")"

# The C interpreter is retired (the switchover). $HERBERT names a now-nonexistent
# path purely so set -u and the golden-mode native gates (which pass HERBERT= but
# never invoke it) have a defined value; nothing in this suite runs the C interpreter.
HERBERT="${HERBERT:-$(pwd)/../../build/herbert}"
source "./native_codegen_oracle.sh"

fail=0
pass=0
total=0
SLOPE_TOL_NUM=3
SLOPE_TOL_DEN=2
test_14a_heap=
test_14b_heap=
native_codegen_dispatch_tmp=

turnstile_tmp=
cleanup_run_tests() {
    if [[ -n "$native_codegen_dispatch_tmp" && -d "$native_codegen_dispatch_tmp" ]]; then
        rm -rf "$native_codegen_dispatch_tmp"
    fi
    if [[ -n "$turnstile_tmp" && -d "$turnstile_tmp" ]]; then
        rm -rf "$turnstile_tmp"
    fi
}
trap cleanup_run_tests EXIT

# --- turnstile (sovereignty link 9): the first SUBTRACTIVE link --------------
# Links 3-8 ADDED a C-free native execution path BESIDE C for each of the six
# metacircular fragments (lexer/parser/evaluator/vm/klondike/emitter). turnstile
# RETIRES C from GRADING them on the default `make test` path: each fragment
# native gate passes on its ENDURING C-free oracle leg (gen-1 ELF vs an
# INDEPENDENT hand-authored oracle -- strictly stronger than the C cross-check,
# since it catches a bug C and native SHARE), and the RETIREABLE native-vs-C
# faithfulness leg becomes OPT-IN (HERBERT_C_GRADE_CROSSCHECK=1 -- exactly the
# way `make reseed` preserves the one sanctioned C mint). Zero coverage loss.
# A counting-DELEGATING HERBERT shim instruments EXACTLY the six gate dispatches
# so check_fragment_grade_count (below) can fence the default path at ZERO C
# grading invocations -- the grading-path analogue of michoi's "C did not MINT"
# mint-count fence ("C did not GRADE"). This is the first link whose default
# run-path C footprint SHRINKS rather than grows.
turnstile_real_herbert="$HERBERT"
turnstile_crosscheck="${HERBERT_C_GRADE_CROSSCHECK:-0}"
turnstile_tmp="$(mktemp -d)"
turnstile_grade_count="$turnstile_tmp/frag_grade_count"
: >"$turnstile_grade_count"
turnstile_write_shim() {
    # Emit a counting-DELEGATING herbert shim: it records that a fragment gate
    # invoked the C interpreter as a grader, then DELEGATEs to the captured REAL
    # interpreter (so the gate still runs normally -- letting the bite-proof
    # exercise the real pre-turnstile behavior). Paths are shell-escaped via %q
    # (robust to spaces / odd chars); it execs the real interpreter, never itself.
    local shim="$1" count="$2"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'printf %s >> %q\n' "'C-GRADE\\n'" "$count"
        printf 'exec %q "$@"\n' "$turnstile_real_herbert"
    } >"$shim"
    chmod +x "$shim"
}
turnstile_grade_shim="$turnstile_tmp/herbert_grade_shim.sh"
turnstile_write_shim "$turnstile_grade_shim" "$turnstile_grade_count"
if [[ "$turnstile_crosscheck" == "1" ]]; then
    # Opt-in: run the native-vs-C faithfulness cross-check (requires C to exist).
    turnstile_frag_no_c=0
    turnstile_frag_herbert="$turnstile_real_herbert"
else
    # Default: C-free grading. <FRAG>_NATIVE_NO_C=1 skips each faithfulness leg;
    # the shim is a trip-wire the C-free gates never reach (caught by the fence
    # if a regression re-enters the C grading path).
    turnstile_frag_no_c=1
    turnstile_frag_herbert="$turnstile_grade_shim"
fi

# --- tollgate (sovereignty link 10): the second SUBTRACTIVE link ---------------
# turnstile retired C from grading the six metacircular fragments. tollgate
# retires C from grading the NATIVE-CODEGEN differential oracle (the 17 scripts
# run_native_codegen_link1..16 + rejects). Two moves: (1) the differential
# oracle's default flips c->golden (native artifacts graded against committed
# C-free goldens; the live-C re-validation is opt-in NATIVE_CODEGEN_ORACLE=c),
# retiring ~179 oracle C-grade calls; (2) every BESPOKE per-link C call -- link1
# (ELF-emitter fragment), link4 (mutated backends), link6/rejects (verifier-
# diagnostic drivers), link10 (self-host altimeter), link11 (layout introspection),
# link15 (trap parity) -- is retired by seed-compiling+running the .herb natively
# or grading an intrinsic property, with the live-C path preserved opt-in under
# NATIVE_CODEGEN_ORACLE=c. A counting-DELEGATING HERBERT shim (the turnstile
# writer, reused) wraps the ENTIRE native-codegen dispatch so
# check_native_codegen_grade_count fences the default at ZERO C grading
# invocations -- the native-codegen analogue of the turnstile "C did not GRADE"
# fence. The shim wraps the $HERBERT VARIABLE, so it counts EVERY C-grade idiom
# ($HERBERT $backend/$driver/$probe/$fragment/$be), not a single grepped pattern.
tollgate_oracle="${NATIVE_CODEGEN_ORACLE:-golden}"
tollgate_grade_count="$turnstile_tmp/nc_grade_count"
: >"$tollgate_grade_count"
tollgate_grade_shim="$turnstile_tmp/herbert_nc_grade_shim.sh"
turnstile_write_shim "$tollgate_grade_shim" "$tollgate_grade_count"
if [[ "$tollgate_oracle" == "golden" ]]; then
    # Default: C-free grading. The shim is a trip-wire the C-free scripts never
    # reach; the fence goes RED if a regression re-enters the C grading path.
    tollgate_nc_herbert="$tollgate_grade_shim"
else
    # Opt-in (NATIVE_CODEGEN_ORACLE=c): the live-C differential + per-link
    # cross-checks run against the real interpreter; the fence is disarmed.
    tollgate_nc_herbert="$turnstile_real_herbert"
fi

# --- muster (sovereignty link 13): the foundational-suite switchover fence ------
# turnstile retired C from grading the 6 metacircular fragments; tollgate from the
# native-codegen oracle. muster retires C from grading the FOUNDATIONAL suite's
# OUTPUT -- the 15 test_*.herb language-conformance programs that until now were
# graded ONLY by running each under the C interpreter and diffing stdout vs its
# committed .expected. Every foundational test gets a SETTLED switchover DISPOSITION
# (a complete roll-call; no test left undischarged, no C grade native can replace):
#   * 12 are NATIVE-OUTPUT-GRADED, C-FREE: the C-free seed compiles+runs each and its
#     stdout == .expected (run_aggregate_render_native.sh, the muster enduring leg).
#     C grades their OUTPUT zero times on the default path.
#   * 3 RETIRE WITH C (whole): native diverges on OUTPUT, each for a defended reason
#     -- test_02 (native's verifier correctly REJECTS dead OOB code C runs lazily,
#     ERR431 -- native is MORE correct; parity would be a regression) and test_11/12
#     (1,000,000-deep non-tail recursion SIGSEGVs the native hardware stack; C runs
#     it on a heap activation stack -- a FAR-axis capacity debt, D13).
#   * 4 RETIRE the C-GC INSTRUMENTATION ASSERTION only: test_10/13 (.maxscopes) and
#     test_14a/14b (.maxheap + heap-slope). Their OUTPUT is native-graded above; only
#     the peak-live-scopes / peak-heap-bytes bounds -- a property of C's mark-sweep GC
#     the native runtime cannot emit (native never frees, D16) -- stay on C, retiring
#     at the switchover. The honest line is assertion-granular: grade everything
#     native reproduces, retire WITH C only what native genuinely cannot.
# A counting-DELEGATING HERBERT shim (the turnstile writer, reused) instruments the
# enduring-leg dispatch so check_foundational_grade_count fences the default at ZERO
# C grading invocations of the 12 OUTPUTS; check_foundational_grade_gating_present is
# a static backstop (exhaustive partition + the gate grades exactly the fenced set +
# each retire-with-C test still carries its stated C-only PROPERTY, not just a blessed
# name). Post-switchover the C interpreter is gone, so the count is trivially 0 and
# the fence stands as a permanent invariant guarding against C creeping back; the
# transition-era fence-mutation pretest retired with C.
muster_crosscheck="${FOUNDATIONAL_C_GRADE_CROSSCHECK:-0}"
muster_grade_count="$turnstile_tmp/foundational_grade_count"
: >"$muster_grade_count"
muster_grade_shim="$turnstile_tmp/herbert_foundational_grade_shim.sh"
turnstile_write_shim "$muster_grade_shim" "$muster_grade_count"
muster_manifest="$turnstile_tmp/foundational_manifest"
: >"$muster_manifest"
# The 12 native-OUTPUT-gradeable foundational tests (stdout == .expected under the
# C-free seed) and their complementary retire-with-C dispositions. These lists are
# the fence's source of truth; check_foundational_grade_gating_present proves they
# partition the on-disk test_*.herb set EXHAUSTIVELY (MUSTER_NATIVE_OUTPUT and
# MUSTER_RETIRE_WHOLE are disjoint and cover all 15; MUSTER_RETIRE_GC is the subset
# of the 12 that ALSO carries a C-GC-instrumentation assertion).
MUSTER_NATIVE_OUTPUT="test_01_arith test_03_if_elif test_04_recursion test_05_block_scope test_06_tuples test_07_array test_08_strings_buffer test_09_ref_vs_value test_10_tco test_13_cross_function_tail_call test_14a_bounded_heap test_14b_bounded_heap"
MUSTER_RETIRE_WHOLE="test_02_short_circuit test_11_non_tail_self_recursion test_12_non_tail_mutual_recursion"
MUSTER_RETIRE_GC="test_10_tco test_13_cross_function_tail_call test_14a_bounded_heap test_14b_bounded_heap"
if [[ "$muster_crosscheck" == "1" ]]; then
    # Opt-in: run the native-vs-C faithfulness cross-check (requires C to exist).
    muster_no_c=0
    muster_grade_herbert="$turnstile_real_herbert"
else
    # Default: C-free grading of the 12 outputs; the shim is a trip-wire the C-free
    # enduring leg never reaches (caught by the fence if C re-enters the path).
    muster_no_c=1
    muster_grade_herbert="$muster_grade_shim"
fi

run_native_codegen_non_vacuity_check() {
    total=$((total + 1))
    local out="$native_codegen_dispatch_tmp/non_vacuity.out"
    local err="$native_codegen_dispatch_tmp/non_vacuity.err"
    if NATIVE_CODEGEN_COMPILER=/bin/false NATIVE_CODEGEN_ORACLE=golden HERBERT="$HERBERT" "$PWD/run_native_codegen_link2.sh" >"$out" 2>"$err"; then
        echo "FAIL: native-codegen switchover non-vacuity (/bin/false compiler unexpectedly passed)"
        fail=$((fail + 1))
    elif grep -q "compile p1 failed" "$out"; then
        echo "PASS: native-codegen switchover non-vacuity (/bin/false compiler fails at first Role-2 compile)"
        pass=$((pass + 1))
    else
        echo "FAIL: native-codegen switchover non-vacuity (unexpected failure mode)"
        echo "--- stdout"
        cat "$out"
        echo "--- stderr"
        cat "$err"
        fail=$((fail + 1))
    fi
}

run_native_codegen_corrupt_compiler_check() {
    total=$((total + 1))
    local wrapper="$native_codegen_dispatch_tmp/corrupt-native-codegen.sh"
    local out="$native_codegen_dispatch_tmp/corrupt.out"
    local err="$native_codegen_dispatch_tmp/corrupt.err"
    cat >"$wrapper" <<'SH'
#!/usr/bin/env bash
set -u
"$NATIVE_CODEGEN_REAL_COMPILER" "$@"
rc=$?
if [[ $rc -eq 0 && -f a.out ]]; then
    printf 'BAD!' | dd of=a.out bs=1 count=4 conv=notrunc >/dev/null 2>&1
fi
exit "$rc"
SH
    chmod +x "$wrapper"
    if NATIVE_CODEGEN_REAL_COMPILER="$NATIVE_CODEGEN_COMPILER" NATIVE_CODEGEN_COMPILER="$wrapper" NATIVE_CODEGEN_ORACLE=golden HERBERT="$HERBERT" "$PWD/run_native_codegen_link2.sh" >"$out" 2>"$err"; then
        echo "FAIL: native-codegen switchover corrupt-compiler proof (corrupting wrapper unexpectedly passed)"
        fail=$((fail + 1))
    elif grep -Eq "native exit non-zero|readelf -h failed|not an ELF" "$out"; then
        echo "PASS: native-codegen switchover corrupt-compiler proof (corrupted a.out is caught)"
        pass=$((pass + 1))
    else
        echo "FAIL: native-codegen switchover corrupt-compiler proof (unexpected failure mode)"
        echo "--- stdout"
        cat "$out"
        echo "--- stderr"
        cat "$err"
        fail=$((fail + 1))
    fi
}

check_native_codegen_grade_count() {
    # tollgate: the FENCE. On the default `make test` path the C interpreter must
    # GRADE the native-codegen suite (link1..16 + rejects) ZERO times -- the
    # differential oracle loads committed C-free goldens, and every per-link
    # bespoke C call is retired (seed-compiled+run natively, or an intrinsic
    # property graded directly). The count only increments inside the delegating
    # shim the ENTIRE native-codegen dispatch was wrapped with, so 0 here proves C
    # was not in their grading path -- the native-codegen analogue of the turnstile
    # "C did not GRADE" fence. The shim wraps the $HERBERT VARIABLE, so it counts
    # EVERY C-grade idiom ($HERBERT $backend/$driver/$probe/$fragment/$be), not one
    # grepped pattern -- strictly more complete than the prior presence grep.
    total=$((total + 1))
    if [[ "$tollgate_oracle" != "golden" ]]; then
        echo "PASS: native-codegen C-grade fence: opt-in live-C cross-check ran (NATIVE_CODEGEN_ORACLE=$tollgate_oracle -- the native-vs-C differential was exercised by request; the C-free fence is not asserted in this mode)"
        pass=$((pass + 1))
        return
    fi
    local got
    got=$(grep -c 'C-GRADE' "$tollgate_grade_count" 2>/dev/null || true)
    [[ -n "$got" ]] || got=0
    if [[ "$got" -eq 0 ]]; then
        echo "PASS: native-codegen C-grade count: 0 (the C interpreter did NOT grade link1..16+rejects -- each passed C-free on the committed golden / seed-compiled native path)"
        pass=$((pass + 1))
    else
        echo "FAIL: native-codegen C-grade count: $got (expected 0 -- the C interpreter re-entered the native-codegen grading path on the default run)"
        cat "$tollgate_grade_count"
        fail=$((fail + 1))
    fi
}

check_native_codegen_grade_gating_present() {
    # Static backstop to the behavioral fence -- it DE-HOLES the prior
    # named-exception presence grep (which matched only `"$HERBERT" "$backend"`
    # and carved out two named sites). Every native-codegen script must EXIST + be
    # executable (so a deleted gate cannot pass vacuously by recording zero C
    # calls) and route C ONLY via the $HERBERT variable -- no command-position
    # hardcoded `herbert` binary (build/herbert) and no unconditional HERBERT=
    # override -- so the injected counting shim cannot be bypassed.
    # (check_native_codegen_grade_count is the primary guard: any $HERBERT C call
    # that fires under the default golden run is counted, in ANY idiom.)
    total=$((total + 1))
    local bad="" s n
    for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 rejects; do
        if [[ "$n" == "rejects" ]]; then
            s="$PWD/run_native_codegen_rejects.sh"
        else
            s="$PWD/run_native_codegen_link${n}.sh"
        fi
        if [[ ! -x "$s" ]]; then
            bad="$bad ${n}(missing-or-not-exec)"
            continue
        fi
        # Forbid a COMMAND-POSITION invocation of a hardcoded lowercase `herbert`
        # binary that bypasses $HERBERT. Strip full-line comments first (the
        # scripts narrate "herbert's runtime fault" etc.), then two patterns
        # (cross-model + same-model review both flagged the turnstile space-only
        # pattern alone misses a quote-immediate path "build/herbert"$x):
        # (a) the validated turnstile pattern -- `herbert` + space + quote/var/
        # redirect/pipe (catches `build/herbert "$x"`); (b) any `build/herbert`
        # path token NOT inside a ${HERBERT:-...} default-fallback (catches the
        # quoted `"build/herbert" "$x"`). $HERBERT is uppercase so never matches.
        local decommented
        decommented="$(grep -vE '^[[:space:]]*#' "$s")"
        if printf '%s\n' "$decommented" | grep -qE '(^|[^[:alnum:]_])herbert[[:space:]]+["'\''$<>|]'; then
            bad="$bad ${n}(hardcoded-C-call)"
        fi
        if printf '%s\n' "$decommented" | grep -E 'build/herbert' | grep -vE ':[-=]' | grep -q .; then
            bad="$bad ${n}(hardcoded-build-herbert)"
        fi
        if grep -nE '^[[:space:]]*HERBERT=' "$s" | grep -vE '\$\{?HERBERT' | grep -q .; then
            bad="$bad ${n}(unconditional-HERBERT-override)"
        fi
    done
    if [[ -z "$bad" ]]; then
        echo "PASS: native-codegen C-grade gating present (all 17 scripts exist+executable and route C only via \$HERBERT -- the counting shim cannot be bypassed by a hardcoded C call)"
        pass=$((pass + 1))
    else
        echo "FAIL: native-codegen C-grade gating present (issues:$bad)"
        fail=$((fail + 1))
    fi
}

check_native_codegen_mint_count() {
    # michoi: the FENCE. In the default (seeded) run the C interpreter must mint
    # gen-1 ZERO times -- the production compiler comes from the committed C-free
    # seed. The C mint runs exactly once only when explicitly re-seeding
    # (NATIVE_CODEGEN_ALLOW_C_MINT=1). The count only ever increments inside
    # native_codegen_compiler_mint, so 0 here proves C was not in the mint path.
    total=$((total + 1))
    local got want
    got="${NATIVE_CODEGEN_COMPILER_MINT_COUNT:-0}"
    if [[ "${NATIVE_CODEGEN_ALLOW_C_MINT:-0}" == "1" ]]; then want=1; else want=0; fi
    if [[ "$got" == "$want" ]]; then
        if [[ "$want" == "0" ]]; then
            echo "PASS: native-codegen gen-1 C-mint count: 0 (C-free seed -- the C interpreter did NOT mint the production compiler)"
        else
            echo "PASS: native-codegen gen-1 C-mint count: 1 (re-seed mode; seconds=${NATIVE_CODEGEN_COMPILER_MINT_SECONDS:-unknown})"
        fi
        pass=$((pass + 1))
    else
        echo "FAIL: native-codegen gen-1 C-mint count: $got (expected $want)"
        fail=$((fail + 1))
    fi
}

check_fragment_grade_count() {
    # turnstile: the FENCE. On the default `make test` path the C interpreter must
    # GRADE the six metacircular-fragment native gates ZERO times -- each gate
    # passes on its ENDURING C-free oracle leg, and the RETIREABLE native-vs-C
    # faithfulness leg is opt-in (HERBERT_C_GRADE_CROSSCHECK=1). The count only
    # ever increments inside the delegating shim the six gates were dispatched
    # with, so 0 here proves C was not in their grading path -- the grading-path
    # analogue of the michoi "C did not MINT" mint-count fence ("C did not GRADE").
    total=$((total + 1))
    if [[ "$turnstile_crosscheck" == "1" ]]; then
        echo "PASS: fragment-gate C-grade fence: opt-in cross-check ran (HERBERT_C_GRADE_CROSSCHECK=1 -- native-vs-C faithfulness exercised by request; the C-free fence is not asserted in this mode)"
        pass=$((pass + 1))
        return
    fi
    local got
    got=$(grep -c 'C-GRADE' "$turnstile_grade_count" 2>/dev/null || true)
    [[ -n "$got" ]] || got=0
    if [[ "$got" -eq 0 ]]; then
        echo "PASS: fragment-gate C-grade count: 0 (the C interpreter did NOT grade the 6 metacircular fragments -- each passed C-free on its enduring oracle leg)"
        pass=$((pass + 1))
    else
        echo "FAIL: fragment-gate C-grade count: $got (expected 0 -- the C interpreter re-entered the fragment grading path on the default run)"
        cat "$turnstile_grade_count"
        fail=$((fail + 1))
    fi
}

check_fragment_grade_gating_present() {
    # Secondary STATIC backstop to the behavioral fence (closes two gaps the
    # cross-model review flagged): (1) all six fragment native gates must EXIST and
    # be executable, so a deleted/disabled gate cannot pass vacuously by recording
    # zero C calls; (2) every gate must retain its <FRAG>_NATIVE_NO_C opt-out AND
    # route its C-grader call through the $HERBERT variable -- no hardcoded
    # build/herbert at a command position (a ':-'/':=' default-fallback, comment,
    # or "cannot find" error string is fine; those never override an injected
    # HERBERT) -- so the injected counting shim cannot be bypassed.
    # (check_fragment_grade_count is the primary behavioral guard: any UNGUARDED
    # $HERBERT grade call would still hit the shim and be counted.)
    total=$((total + 1))
    local bad="" g flag s
    for g in lexer parser evaluator vm klondike emitter; do
        flag="$(printf '%s' "$g" | tr '[:lower:]' '[:upper:]')_NATIVE_NO_C"
        s="$PWD/run_${g}_native.sh"
        if [[ ! -x "$s" ]]; then
            bad="$bad ${g}(missing-or-not-exec)"
            continue
        fi
        grep -q "$flag" "$s" || bad="$bad ${g}(no-NO_C-guard)"
        # Forbid a COMMAND-POSITION invocation of the C interpreter binary that
        # bypasses $HERBERT -- a hardcoded lowercase `herbert` path (e.g.
        # build/herbert) called with an arg/redirect/pipe. $HERBERT is UPPERCASE so
        # this never matches the variable; a ':-' default-fallback (build/herbert}),
        # the "cannot find herbert at $HERBERT" error string (herbert at ...), and
        # comments are command-position-safe (validated: zero match on all 6 gates).
        if grep -nE '(^|[^[:alnum:]_])herbert[[:space:]]+["'\''$<>|]' "$s" | grep -q .; then
            bad="$bad ${g}(hardcoded-C-call)"
        fi
        # Forbid an UNCONDITIONAL HERBERT= override (one whose RHS ignores the
        # injected ${HERBERT}); the gates' "${HERBERT:-default}" fallback is fine.
        if grep -nE '^[[:space:]]*HERBERT=' "$s" | grep -vE '\$\{?HERBERT' | grep -q .; then
            bad="$bad ${g}(unconditional-HERBERT-override)"
        fi
    done
    if [[ -z "$bad" ]]; then
        echo "PASS: fragment-gate C-grade gating present (all 6 native gates exist+executable, retain their *_NATIVE_NO_C opt-out, and route C only via \$HERBERT -- the C-free default cannot be silently removed or bypassed)"
        pass=$((pass + 1))
    else
        echo "FAIL: fragment-gate C-grade gating present (issues:$bad)"
        fail=$((fail + 1))
    fi
}

check_foundational_grade_count() {
    # muster: the FENCE. On the default `make test` path the C interpreter must GRADE
    # the 12 native-OUTPUT foundational tests ZERO times -- their stdout is graded by
    # the C-free seed in run_aggregate_render_native.sh (the enduring leg), and the
    # native-vs-C faithfulness leg is opt-in (FOUNDATIONAL_C_GRADE_CROSSCHECK=1). The
    # count only increments inside the delegating shim the enduring leg was dispatched
    # with, so 0 here proves C was not in their OUTPUT grading path -- the foundational
    # analogue of the michoi "C did not MINT" / turnstile "C did not GRADE" fence. (The
    # retire-with-C residue -- test_02/11/12 whole and the GC instrumentation of
    # 10/13/14a/14b -- retired WITH the C interpreter at the switchover; the 12 native
    # OUTPUTS are the C-free survivors graded by the enduring leg.)
    total=$((total + 1))
    if [[ "$muster_crosscheck" == "1" ]]; then
        echo "PASS: foundational C-grade fence: opt-in cross-check ran (FOUNDATIONAL_C_GRADE_CROSSCHECK=1 -- native-vs-C faithfulness exercised by request; the C-free fence is not asserted in this mode)"
        pass=$((pass + 1))
        return
    fi
    local got
    got=$(grep -c 'C-GRADE' "$muster_grade_count" 2>/dev/null || true)
    [[ -n "$got" ]] || got=0
    if [[ "$got" -eq 0 ]]; then
        echo "PASS: foundational C-grade count: 0 (the C interpreter did NOT grade the 12 native-output foundational tests -- each passed C-free on the seed-compiled enduring leg)"
        pass=$((pass + 1))
    else
        echo "FAIL: foundational C-grade count: $got (expected 0 -- the C interpreter re-entered the foundational output grading path on the default run)"
        cat "$muster_grade_count"
        fail=$((fail + 1))
    fi
}

check_foundational_grade_gating_present() {
    # Static backstop to the behavioral fence (folds the cross-model design review):
    #  (1) the enduring leg exists+executable, retains its AGGREGATE_RENDER_NATIVE_NO_C
    #      opt-out, and routes C only via $HERBERT -- no hardcoded command-position
    #      `herbert` and no unconditional HERBERT= override (so the counting shim
    #      cannot be bypassed by a direct C-interpreter call);
    #  (2) MANIFEST == fenced set: the enduring leg graded EXACTLY MUSTER_NATIVE_OUTPUT
    #      (a RUNTIME manifest, so the fence cannot pass vacuously on a silently-shrunk
    #      graded list);
    #  (3) EXHAUSTIVE partition: MUSTER_NATIVE_OUTPUT and MUSTER_RETIRE_WHOLE are
    #      disjoint and together cover every on-disk test_*.herb (no orphan slips past
    #      native grading); MUSTER_RETIRE_GC is a subset of the native-output set;
    #  (4) REASON not just NAME: each retire-with-C test still EXERCISES its stated
    #      C-only property -- 10/13 keep a .maxscopes, 14a/14b a .maxheap, 11/12 keep
    #      their deep (1,000,000) non-tail recursion (test_02's native-ERR431 rejection
    #      is pinned C-free inside the enduring leg) -- so a retired test cannot be
    #      silently weakened while keeping its blessed name.
    total=$((total + 1))
    local bad="" s
    s="$PWD/run_aggregate_render_native.sh"
    if [[ ! -x "$s" ]]; then
        echo "FAIL: foundational C-grade gating present (enduring leg run_aggregate_render_native.sh missing or not executable)"
        fail=$((fail + 1)); return
    fi
    grep -q "AGGREGATE_RENDER_NATIVE_NO_C" "$s" || bad="$bad enduring-leg(no-NO_C-guard)"
    if grep -nE '(^|[^[:alnum:]_])herbert[[:space:]]+["'\''$<>|]' "$s" | grep -q .; then
        bad="$bad enduring-leg(hardcoded-C-call)"
    fi
    if grep -nE '^[[:space:]]*HERBERT=' "$s" | grep -vE '\$\{?HERBERT' | grep -q .; then
        bad="$bad enduring-leg(unconditional-HERBERT-override)"
    fi
    # Forbid any hardcoded build/herbert C-interpreter invocation (the direct-C
    # bypass the behavioral fence cannot see). The ONLY allowed occurrence is the
    # documented ${HERBERT:-...build/herbert} default fallback (then called via the
    # routed $HERBERT). Catches "$repo_root/build/herbert" "$x" and the like, which
    # the whitespace-form herbert grep above misses (herbert followed by a quote).
    if grep -n 'build/herbert' "$s" | grep -vE 'HERBERT:-' | grep -q .; then
        bad="$bad enduring-leg(hardcoded-build/herbert)"
    fi
    # (2) manifest == fenced set (sorted compare).
    local want_native got_native
    want_native=$(printf '%s\n' $MUSTER_NATIVE_OUTPUT | sort)
    got_native=$(sort "$muster_manifest" 2>/dev/null)
    [[ "$want_native" == "$got_native" ]] || bad="$bad manifest!=fenced-set"
    # (3) exhaustive + disjoint partition over the on-disk test_*.herb set.
    local on_disk want_all f
    on_disk=$(for f in "$PWD"/test_*.herb; do printf '%s\n' "$(basename "${f%.herb}")"; done | sort)
    want_all=$(printf '%s\n' $MUSTER_NATIVE_OUTPUT $MUSTER_RETIRE_WHOLE | sort)
    [[ "$on_disk" == "$want_all" ]] || bad="$bad partition-not-exhaustive"
    if printf '%s\n' $MUSTER_NATIVE_OUTPUT $MUSTER_RETIRE_WHOLE | sort | uniq -d | grep -q .; then
        bad="$bad native/whole-overlap"
    fi
    local g
    for g in $MUSTER_RETIRE_GC; do
        [[ " $MUSTER_NATIVE_OUTPUT " == *" $g "* ]] || bad="$bad gc-not-in-native($g)"
    done
    # (4) FREEZE the retire-with-C sets by EXACT membership, so a new test cannot be
    # silently dropped into retire-with-C (dodging native grading with no reason
    # check). Adding a test forces it into MUSTER_NATIVE_OUTPUT (native-graded) or a
    # CONSCIOUS update here plus a new reason pin.
    local t v
    [[ "$(printf '%s\n' $MUSTER_RETIRE_WHOLE | sort | tr '\n' ' ')" == "test_02_short_circuit test_11_non_tail_self_recursion test_12_non_tail_mutual_recursion " ]] || bad="$bad retire-whole-set-changed"
    [[ "$(printf '%s\n' $MUSTER_RETIRE_GC | sort | tr '\n' ' ')" == "test_10_tco test_13_cross_function_tail_call test_14a_bounded_heap test_14b_bounded_heap " ]] || bad="$bad retire-gc-set-changed"
    # (5) reason-not-name (structural): pin the GC bounds by EXACT committed VALUE (not
    # mere existence). These C-GC instrumentation bounds (the C interpreter's mark-sweep
    # peak) retired WITH C at the switchover; the pin is kept as a frozen record of the
    # retired property so the membership/partition above stays honest. 10/13/14 carry
    # .maxscopes==16, 14a/14b .maxheap==1100000; a deliberate bound change must update this pin too. (test_02's native-ERR431 rejection and
    # test_11/12's native-SIGSEGV divergence are reason-pinned by BEHAVIOR -- C-free,
    # run under the seed -- inside the enduring leg run_aggregate_render_native.sh.)
    for t in test_10_tco test_13_cross_function_tail_call test_14a_bounded_heap test_14b_bounded_heap; do
        v=$(tr -d '[:space:]' < "$PWD/$t.maxscopes" 2>/dev/null)
        [[ "$v" == "16" ]] || bad="$bad $t(.maxscopes!=16:${v:-missing})"
    done
    for t in test_14a_bounded_heap test_14b_bounded_heap; do
        v=$(tr -d '[:space:]' < "$PWD/$t.maxheap" 2>/dev/null)
        [[ "$v" == "1100000" ]] || bad="$bad $t(.maxheap!=1100000:${v:-missing})"
    done
    if [[ -z "$bad" ]]; then
        echo "PASS: foundational C-grade gating present (enduring leg exists+exec, retains its NO_C opt-out, routes C only via \$HERBERT with no hardcoded build/herbert; manifest == the 12 fenced tests; the {12 native-output}+{3 retire-whole} partition is exhaustive+disjoint over all test_*.herb, GC-subset OK; the retire-with-C sets are FROZEN by exact membership; GC bounds pinned exact -- 10/13/14 .maxscopes==16, 14a/14b .maxheap==1100000; 02 ERR431-reject + 11/12 SIGSEGV behavior-pinned C-free in the enduring leg)"
        pass=$((pass + 1))
    else
        echo "FAIL: foundational C-grade gating present (issues:$bad)"
        fail=$((fail + 1))
    fi
}

run_native_codegen_michoi_seed_check() {
    # michoi: prove the production compiler this run used IS the committed,
    # integrity-checked, C-free gen-1 seed. (The seed's C-free SELF-REPRODUCTION
    # -- seed compiles the backend back into the seed -- is proven by the link10
    # fixpoint, which runs under make test.)
    total=$((total + 1))
    local seed magic want got used
    seed="$native_codegen_seed_file"
    if [[ ! -f "$seed" || ! -f "$seed.sha256" ]]; then
        echo "FAIL: michoi C-free seed (missing $seed)"; fail=$((fail + 1)); return
    fi
    magic=$(head -c4 "$seed" | xxd -p | tr -d '\n')
    want=$(awk '{print $1}' "$seed.sha256")
    got=$(sha256sum "$seed" | awk '{print $1}')
    if [[ "$magic" != "7f454c46" || "$got" != "$want" ]]; then
        echo "FAIL: michoi C-free seed integrity (magic=$magic sha got=$got want=$want)"; fail=$((fail + 1)); return
    fi
    if [[ -z "${NATIVE_CODEGEN_COMPILER:-}" || ! -x "$NATIVE_CODEGEN_COMPILER" ]]; then
        echo "FAIL: michoi C-free seed (no production compiler acquired)"; fail=$((fail + 1)); return
    fi
    # In seeded mode the production compiler must be byte-identical to the seed.
    if [[ "${NATIVE_CODEGEN_ALLOW_C_MINT:-0}" != "1" ]]; then
        used=$(sha256sum "$NATIVE_CODEGEN_COMPILER" | awk '{print $1}')
        if [[ "$used" != "$want" ]]; then
            echo "FAIL: michoi C-free seed (production compiler sha=$used != committed seed sha=$want -- the run did not use the seed)"; fail=$((fail + 1)); return
        fi
    fi
    echo "PASS: michoi C-free gen-1 seed (committed seed integrity OK; production compiler IS the seed; C did not mint it)"
    pass=$((pass + 1))
}

shopt -s nullglob

if [[ -d ../../stack ]]; then
    STACK_DIR="$(cd ../../stack && pwd)"

    # Lexer NATIVE-EXECUTION gate (sovereignty axis, Role-C reduction): the C-free
    # gen-1 seed compiles lexer_fragment.herb to an ELF that scans+classifies+serializes
    # with NO C in its execution path; its stdout line 1 must equal the independent
    # oracle (ENDURING) and -- while a C interpreter still exists -- the interpreter's
    # output (RETIREABLE faithfulness guard). The FOURTH metacircular fragment to gain a
    # committed native execution path (after the evaluator, the VM, and the parser); the
    # lexer self-description test now survives C's deletion (only klondike remains).
    if [[ -x "$PWD/run_lexer_native.sh" ]]; then
        total=$((total + 1))
        if LEXER_NATIVE_NO_C="$turnstile_frag_no_c" HERBERT="$turnstile_frag_herbert" "$PWD/run_lexer_native.sh"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    # Prove the lexer native-execution gate BITES (RED-first): a mutated lex rule
    # (a character-class -> token-kind classification) still compiles natively but
    # makes the C-free ELF emit a divergent token stream.
    if [[ -x "$PWD/run_lexer_native_mutation.sh" ]]; then
        total=$((total + 1))
        if "$PWD/run_lexer_native_mutation.sh"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi



    # Parser NATIVE-EXECUTION gate (sovereignty axis, Role-C reduction): the C-free
    # gen-1 seed compiles parser_fragment.herb to an ELF that lexes+parses+serializes
    # with NO C in its execution path; its stdout line 1 must equal the independent
    # oracle (ENDURING) and -- while a C interpreter still exists -- the interpreter's
    # output (RETIREABLE faithfulness guard). The THIRD metacircular fragment to gain a
    # committed native execution path (after the evaluator and the VM); the parser
    # self-description test now survives C's deletion.
    if [[ -x "$PWD/run_parser_native.sh" ]]; then
        total=$((total + 1))
        if PARSER_NATIVE_NO_C="$turnstile_frag_no_c" HERBERT="$turnstile_frag_herbert" "$PWD/run_parser_native.sh"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    # Prove the parser native-execution gate BITES (RED-first): a mutated parse rule
    # (an operator -> AST-tag mapping) still compiles natively but makes the C-free
    # ELF emit a divergent S-expression.
    if [[ -x "$PWD/run_parser_native_mutation.sh" ]]; then
        total=$((total + 1))
        if "$PWD/run_parser_native_mutation.sh"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi


    # Evaluator NATIVE-EXECUTION gate (sovereignty axis, Role-C reduction): the
    # C-free gen-1 seed compiles evaluator_fragment.herb to an ELF that runs with
    # NO C in its execution path; its stdout line 1 must equal the independent
    # oracle (ENDURING) and -- while a C interpreter still exists -- the
    # interpreter's output (RETIREABLE faithfulness guard). This is the first
    # metacircular fragment to gain a committed native execution path, so the
    # evaluator self-description test now survives C's deletion.
    if [[ -x "$PWD/run_evaluator_native.sh" ]]; then
        total=$((total + 1))
        if EVALUATOR_NATIVE_NO_C="$turnstile_frag_no_c" HERBERT="$turnstile_frag_herbert" "$PWD/run_evaluator_native.sh"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    # Prove the evaluator native-execution gate BITES (RED-first): a mutated
    # evaluator rule still compiles natively but makes the C-free ELF diverge
    # from the oracle.
    if [[ -x "$PWD/run_evaluator_native_mutation.sh" ]]; then
        total=$((total + 1))
        if "$PWD/run_evaluator_native_mutation.sh"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    # link11 (sovereignty axis, D14 aggregate half): the native back end now
    # canonically renders a `main` returning a FLAT int/bool TUPLE, so the
    # foundational language tests that return a tuple (test_01/03/07/08/09) run
    # C-FREE via the gen-1 seed. ENDURING leg = native render == committed key;
    # RETIREABLE leg = faithfulness vs C (real HERBERT, NOT the fragment shim --
    # this gate is its own capability gate, under neither the turnstile fragment
    # fence nor the tollgate native-codegen fence).
    if [[ -x "$PWD/run_aggregate_render_native.sh" ]]; then
        total=$((total + 1))
        # muster (link 13): the enduring leg grades the 12 native-output foundational
        # tests C-FREE (AGGREGATE_RENDER_NATIVE_NO_C=1 default) under the counting shim,
        # so check_foundational_grade_count can fence the default at ZERO C output-grades.
        # MUSTER_MANIFEST records exactly which tests it graded (backstop cross-check).
        # FOUNDATIONAL_C_GRADE_CROSSCHECK=1 re-enables the native-vs-C faithfulness leg.
        if AGGREGATE_RENDER_NATIVE_NO_C="$muster_no_c" MUSTER_MANIFEST="$muster_manifest" HERBERT="$muster_grade_herbert" "$PWD/run_aggregate_render_native.sh"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    # Prove the aggregate-render gate BITES (RED-first): a mutated renderer still
    # compiles but makes the rendered tuple diverge from the canonical key.
    if [[ -x "$PWD/run_aggregate_render_native_mutation.sh" ]]; then
        total=$((total + 1))
        if "$PWD/run_aggregate_render_native_mutation.sh"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    # muster (link 13): the enduring leg above graded the 12 native-output
    # foundational tests on the default C-free path; fence the default at ZERO C
    # output-grading invocations, prove the partition/gating is intact (exhaustive +
    # the gate grades exactly the fenced set + each retired test still carries its
    # stated C-only property + C reachable only via $HERBERT), and prove the fence
    # BITES on the real pre-muster default.
    check_foundational_grade_count
    check_foundational_grade_gating_present


    # VM NATIVE-EXECUTION gate (sovereignty axis, Role-C reduction): the C-free
    # gen-1 seed compiles vm_fragment.herb to an ELF that runs the bytecode VM with
    # NO C in its execution path; its stdout line 1 must equal the independent
    # oracle (ENDURING) and -- while a C interpreter still exists -- the
    # interpreter's output (RETIREABLE faithfulness guard). The SECOND metacircular
    # fragment to gain a committed native execution path (after the evaluator); the
    # bytecode-VM self-description test now survives C's deletion.
    if [[ -x "$PWD/run_vm_native.sh" ]]; then
        total=$((total + 1))
        if VM_NATIVE_NO_C="$turnstile_frag_no_c" HERBERT="$turnstile_frag_herbert" "$PWD/run_vm_native.sh"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    # Prove the VM native-execution gate BITES (RED-first): a mutated bytecode-VM
    # opcode handler still compiles natively but makes the C-free ELF diverge from
    # the oracle.
    if [[ -x "$PWD/run_vm_native_mutation.sh" ]]; then
        total=$((total + 1))
        if "$PWD/run_vm_native_mutation.sh"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    # Klondike NATIVE-EXECUTION gate (sovereignty axis, Role-C reduction -- the LAST
    # and FIFTH metacircular fragment). The C-free gen-1 seed compiles a one-line
    # main-adapted klondike (the full toolchain: lex+parse+check+lower+VM+serialize)
    # to an ELF that compiles+runs an embedded probe with NO C in its execution path;
    # its transcript must equal the independent oracle (ENDURING) and -- while a C
    # interpreter still exists -- the interpreter's output (RETIREABLE faithfulness
    # guard). klondike.herb is byte-identical (the adapter is applied at gate time so
    # its meta-circular-suite role is preserved). With this, ALL FIVE metacircular
    # fragments survive C's deletion.
    if [[ -x "$PWD/run_klondike_native.sh" ]]; then
        total=$((total + 1))
        if KLONDIKE_NATIVE_NO_C="$turnstile_frag_no_c" HERBERT="$turnstile_frag_herbert" "$PWD/run_klondike_native.sh"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    # Prove the klondike native-execution gate BITES (RED-first): a mutated VM rule
    # (int_binop's + / < / == ) still compiles natively but makes the C-free ELF emit
    # a divergent result tuple.
    if [[ -x "$PWD/run_klondike_native_mutation.sh" ]]; then
        total=$((total + 1))
        if "$PWD/run_klondike_native_mutation.sh"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    # Emitter NATIVE-EXECUTION gate (sovereignty axis, Role-C reduction -- the SIXTH and
    # FINAL metacircular fragment). The C-free gen-1 seed compiles a one-line main-adapted
    # emitter_fragment (the standalone AST->bytecode CODE GENERATOR: lower_program /
    # emit_expr / opcode_for_binop / serialize_bytecode) to an ELF that lowers the embedded
    # probe to bytecode with NO C in its execution path; its serialized listing must equal
    # the independent oracle stack/emitter_probe.expected (ENDURING) and -- while a C
    # interpreter still exists -- the interpreter's listing (RETIREABLE faithfulness guard).
    # emitter_fragment.herb is byte-identical (the adapter is applied at gate time, so the
    # existing C emitter_probe test still runs the unmodified fragment -- purely additive).
    # The emitter is the only fragment that pins the lowering PRODUCT (codegen structure at
    # the instruction level), invisible to the five value-observing fragments. With this,
    # ALL SIX metacircular fragments survive C's deletion.
    if [[ -x "$PWD/run_emitter_native.sh" ]]; then
        total=$((total + 1))
        if EMITTER_NATIVE_NO_C="$turnstile_frag_no_c" HERBERT="$turnstile_frag_herbert" "$PWD/run_emitter_native.sh"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    # Prove the emitter native-execution gate BITES (RED-first): a mutated reachable
    # LOWERING rule (an opcode mapping / a frame-slot allocation / a control-flow branch)
    # still compiles natively but makes the C-free ELF emit a divergent bytecode listing.
    if [[ -x "$PWD/run_emitter_native_mutation.sh" ]]; then
        total=$((total + 1))
        if "$PWD/run_emitter_native_mutation.sh"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    # turnstile (sovereignty link 9): the six fragment native gates above ran on
    # the default C-free path; fence the default at ZERO C grading invocations,
    # prove the gating is intact, and prove the fence BITES on the real
    # pre-turnstile default.
    check_fragment_grade_count
    check_fragment_grade_gating_present


    NATIVE_CODEGEN_LINK1="$PWD/run_native_codegen_link1.sh"
    backend="$STACK_DIR/native_compile_fragment.herb"
    native_codegen_dispatch_tmp="$(mktemp -d)"
    # michoi: source the production gen-1 from the committed C-free seed (the C
    # interpreter is no longer in the mint path). ensure_compiler reuses a preset
    # NATIVE_CODEGEN_COMPILER, else acquires the seed, else (only with
    # NATIVE_CODEGEN_ALLOW_C_MINT=1) re-mints via C; fails closed otherwise.
    native_codegen_ensure_compiler "$native_codegen_dispatch_tmp/compiler" || exit 1

    if [[ -f "$NATIVE_CODEGEN_LINK1" ]]; then
        total=$((total + 1))
        if HERBERT="$tollgate_nc_herbert" "$NATIVE_CODEGEN_LINK1"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    NATIVE_CODEGEN_LINK2="$PWD/run_native_codegen_link2.sh"
    if [[ -f "$NATIVE_CODEGEN_LINK2" ]]; then
        total=$((total + 1))
        if HERBERT="$tollgate_nc_herbert" "$NATIVE_CODEGEN_LINK2"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    NATIVE_CODEGEN_LINK3="$PWD/run_native_codegen_link3.sh"
    if [[ -f "$NATIVE_CODEGEN_LINK3" ]]; then
        total=$((total + 1))
        if HERBERT="$tollgate_nc_herbert" "$NATIVE_CODEGEN_LINK3"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    NATIVE_CODEGEN_LINK4="$PWD/run_native_codegen_link4.sh"
    if [[ -f "$NATIVE_CODEGEN_LINK4" ]]; then
        total=$((total + 1))
        if HERBERT="$tollgate_nc_herbert" "$NATIVE_CODEGEN_LINK4"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    NATIVE_CODEGEN_LINK5="$PWD/run_native_codegen_link5.sh"
    if [[ -f "$NATIVE_CODEGEN_LINK5" ]]; then
        total=$((total + 1))
        if HERBERT="$tollgate_nc_herbert" "$NATIVE_CODEGEN_LINK5"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    NATIVE_CODEGEN_LINK6="$PWD/run_native_codegen_link6.sh"
    if [[ -f "$NATIVE_CODEGEN_LINK6" ]]; then
        total=$((total + 1))
        if HERBERT="$tollgate_nc_herbert" "$NATIVE_CODEGEN_LINK6"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    NATIVE_CODEGEN_LINK7="$PWD/run_native_codegen_link7.sh"
    if [[ -f "$NATIVE_CODEGEN_LINK7" ]]; then
        total=$((total + 1))
        if HERBERT="$tollgate_nc_herbert" "$NATIVE_CODEGEN_LINK7"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    NATIVE_CODEGEN_LINK8="$PWD/run_native_codegen_link8.sh"
    if [[ -f "$NATIVE_CODEGEN_LINK8" ]]; then
        total=$((total + 1))
        if HERBERT="$tollgate_nc_herbert" "$NATIVE_CODEGEN_LINK8"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    NATIVE_CODEGEN_LINK9="$PWD/run_native_codegen_link9.sh"
    if [[ -f "$NATIVE_CODEGEN_LINK9" ]]; then
        total=$((total + 1))
        if HERBERT="$tollgate_nc_herbert" "$NATIVE_CODEGEN_LINK9"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    NATIVE_CODEGEN_LINK10="$PWD/run_native_codegen_link10.sh"
    if [[ -f "$NATIVE_CODEGEN_LINK10" ]]; then
        total=$((total + 1))
        if HERBERT="$tollgate_nc_herbert" "$NATIVE_CODEGEN_LINK10"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    NATIVE_CODEGEN_LINK11="$PWD/run_native_codegen_link11.sh"
    if [[ -f "$NATIVE_CODEGEN_LINK11" ]]; then
        total=$((total + 1))
        if HERBERT="$tollgate_nc_herbert" "$NATIVE_CODEGEN_LINK11"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    NATIVE_CODEGEN_LINK12="$PWD/run_native_codegen_link12.sh"
    if [[ -f "$NATIVE_CODEGEN_LINK12" ]]; then
        total=$((total + 1))
        if HERBERT="$tollgate_nc_herbert" "$NATIVE_CODEGEN_LINK12"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    NATIVE_CODEGEN_LINK13="$PWD/run_native_codegen_link13.sh"
    if [[ -f "$NATIVE_CODEGEN_LINK13" ]]; then
        total=$((total + 1))
        if HERBERT="$tollgate_nc_herbert" "$NATIVE_CODEGEN_LINK13"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    NATIVE_CODEGEN_LINK14="$PWD/run_native_codegen_link14.sh"
    if [[ -f "$NATIVE_CODEGEN_LINK14" ]]; then
        total=$((total + 1))
        if HERBERT="$tollgate_nc_herbert" "$NATIVE_CODEGEN_LINK14"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    NATIVE_CODEGEN_LINK15="$PWD/run_native_codegen_link15.sh"
    if [[ -f "$NATIVE_CODEGEN_LINK15" ]]; then
        total=$((total + 1))
        if HERBERT="$tollgate_nc_herbert" "$NATIVE_CODEGEN_LINK15"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    NATIVE_CODEGEN_LINK16="$PWD/run_native_codegen_link16.sh"
    if [[ -f "$NATIVE_CODEGEN_LINK16" ]]; then
        total=$((total + 1))
        if HERBERT="$tollgate_nc_herbert" "$NATIVE_CODEGEN_LINK16"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    NATIVE_CODEGEN_REJECTS="$PWD/run_native_codegen_rejects.sh"
    if [[ -f "$NATIVE_CODEGEN_REJECTS" ]]; then
        total=$((total + 1))
        if HERBERT="$tollgate_nc_herbert" "$NATIVE_CODEGEN_REJECTS"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    # tollgate: the DEFAULT is golden (C-free); this redundant C-free re-validation
    # pass runs ONLY under the opt-in `c` cross-check, where pass-1 ran live C.
    if [[ "${NATIVE_CODEGEN_ORACLE:-golden}" != "golden" ]]; then
        for native_codegen_script in \
            "$PWD/run_native_codegen_link1.sh" \
            "$PWD/run_native_codegen_link2.sh" \
            "$PWD/run_native_codegen_link3.sh" \
            "$PWD/run_native_codegen_link4.sh" \
            "$PWD/run_native_codegen_link5.sh" \
            "$PWD/run_native_codegen_link6.sh" \
            "$PWD/run_native_codegen_link7.sh" \
            "$PWD/run_native_codegen_link8.sh" \
            "$PWD/run_native_codegen_link9.sh" \
            "$PWD/run_native_codegen_link10.sh" \
            "$PWD/run_native_codegen_link11.sh" \
            "$PWD/run_native_codegen_link12.sh" \
            "$PWD/run_native_codegen_link13.sh" \
            "$PWD/run_native_codegen_link14.sh" \
            "$PWD/run_native_codegen_link15.sh" \
            "$PWD/run_native_codegen_link16.sh" \
            "$PWD/run_native_codegen_rejects.sh"; do
            [[ -f "$native_codegen_script" ]] || continue
            total=$((total + 1))
            if NATIVE_CODEGEN_ORACLE=golden HERBERT="$HERBERT" "$native_codegen_script"; then
                pass=$((pass + 1))
            else
                fail=$((fail + 1))
            fi
        done
    fi

    run_native_codegen_non_vacuity_check
    run_native_codegen_corrupt_compiler_check
    check_native_codegen_grade_count
    check_native_codegen_grade_gating_present
    check_native_codegen_mint_count
    run_native_codegen_michoi_seed_check

fi

# --- switchover-cfree (sovereignty link 14): the FIRST switchover-machinery slice
#     -- prove the C-free production surface STANDS WITH THE C INTERPRETER
#     PHYSICALLY ABSENT (no build/herbert; cc/gcc/as/ld unreachable) over a
#     COMPLETE, frozen, whole-suite partition, and prove it BITES RED-first. The
#     driver/bite-proof self-scrub C; nothing here touches the make-test $HERBERT.
if [[ -x "$PWD/run_switchover_cfree.sh" ]]; then
    total=$((total + 1))
    if bash "$PWD/run_switchover_cfree.sh" >/tmp/herbert_switchover.$$ 2>&1; then
        echo "PASS: $(grep -E '^PASS: switchover-cfree' /tmp/herbert_switchover.$$ | tail -1 | sed 's/^PASS: //')"
        pass=$((pass + 1))
    else
        echo "FAIL: switchover-cfree (the C-free production surface did NOT stand with C physically absent)"
        sed 's/^/    | /' /tmp/herbert_switchover.$$ | tail -20
        fail=$((fail + 1))
    fi
    rm -f /tmp/herbert_switchover.$$
fi
if [[ -x "$PWD/run_switchover_cfree_mutation.sh" ]]; then
    total=$((total + 1))
    if bash "$PWD/run_switchover_cfree_mutation.sh" >/tmp/herbert_switchover_bite.$$ 2>&1; then
        echo "PASS: switchover-cfree mutation proof (M-guard + M-gerrymander + M-modeenv + M-incomplete bite; control green; M-leak retired with C)"
        pass=$((pass + 1))
    else
        echo "FAIL: switchover-cfree mutation proof (a load-bearing piece did not bite)"
        sed 's/^/    | /' /tmp/herbert_switchover_bite.$$ | tail -20
        fail=$((fail + 1))
    fi
    rm -f /tmp/herbert_switchover_bite.$$
fi

echo
if [[ $fail -ne 0 ]]; then
    echo "$fail of $total test(s) failed."
    exit 1
fi
echo "$pass of $total test(s) passed."
exit 0
