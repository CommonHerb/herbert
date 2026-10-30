#!/usr/bin/env bash
# The make test harness: the emulator-free gates that grade the committed gen-1
# seed and the programs it compiles. It runs the six metacircular-fragment native
# gates and their mutation proofs, the aggregate-render gate and its mutation
# proof, hosted native-codegen links 1-16 and the reject battery against the
# committed goldens, the non-vacuity, corrupt-compiler and seed-integrity checks,
# the closed-loop memory diet and the error-vocabulary gate. The number of tests
# is pinned (EXPECTED_SUITE_TOTAL). `--check-pinned` (make check) only confirms
# that the pinned gate and proof scripts are present and executable.
set -u

# CDPATH is unset FIRST: `cd` with a RELATIVE operand searches $CDPATH before the current
# directory, so an inherited CDPATH could send this suite into a decoy tree whose 16 pinned
# proofs are `exit 0` stubs -- flipping a correctly RED `make check` (execute-bit drift on a
# real proof) to a green rc 0. `|| exit 1` because a cd that fails must never leave the suite
# grading whatever directory it happens to be in (parent delta refutation panel, 2026-09-02).
unset CDPATH
cd -- "$(dirname "$0")" || exit 1

# The C interpreter is retired (the switchover). $HERBERT names a now-nonexistent
# path purely so set -u and the golden-mode native gates (which pass HERBERT= but
# never invoke it) have a defined value; nothing in this suite runs the C interpreter.
HERBERT="${HERBERT:-$(pwd)/../../build/herbert}"
# The suite grades against the COMMITTED goldens only: an inherited goldens dir / manifest /
# capture override would let an external artifact set forge a green (Codex confirm leg 4,
# blind-audit R3). Refuse them here, BEFORE the oracle is sourced (it reads them as defaults).
for native_codegen_override in NATIVE_CODEGEN_GOLDENS_DIR NATIVE_CODEGEN_MANIFEST NATIVE_CODEGEN_ORACLE_CAPTURE NATIVE_CODEGEN_CAPTURE_MANIFEST; do
    if [[ -n "${!native_codegen_override:-}" ]]; then
        echo "FAIL: $native_codegen_override is set in the environment -- the suite pins the committed goldens (bootstrap/tests/native_codegen_goldens) and honors no override. Refusing."
        exit 1
    fi
done
# The error-vocab gate reads two ambient names: ERROR_VOCAB_CAPTURE=1 re-mints the TRACKED golden
# instead of asserting (the whole gate is off, and a regression passed 43 of 43 while rewriting
# stack/error_probes_native.expected), and ERROR_VOCAB_FRAGMENT grades some other klondike file.
# The suite runs that gate directly (below); refuse both here (R06-verification-bite-03).
for error_vocab_override in ERROR_VOCAB_CAPTURE ERROR_VOCAB_FRAGMENT; do
    if [[ -n "${!error_vocab_override:-}" ]]; then
        echo "FAIL: $error_vocab_override is set in the environment -- the suite grades the committed stack/klondike.herb against the committed error-vocab golden (stack/error_probes_native.expected) and never re-mints it; re-bless only by running bootstrap/tests/run_error_vocab_native.sh directly. Refusing."
        exit 1
    fi
done
# GUARDED: this script sets `set -u` but never `set -e`, so a bare `source` of a missing oracle
# printed its error and CONTINUED -- and `--check-pinned` needs nothing the oracle defines, so
# `make check` still printed its green OK and exited 0 with the file every suite gate sources
# gone. Fail closed instead (parent delta refutation panel, 2026-09-02).
if ! source "./native_codegen_oracle.sh"; then
    echo "FAIL: bootstrap/tests/native_codegen_oracle.sh could not be sourced (missing or unreadable) -- the shared oracle every native-codegen gate depends on is gone; refusing to grade anything, including --check-pinned"
    exit 1
fi

fail=0
pass=0
total=0

# ---- PINNED PROOF SET (blind-audit R1, 2026-08-29) -----------------------------------------------
# Every gate/proof script named here is REQUIRED: missing or non-executable = a FAILED test, never a
# silent skip. Before R1 each was guarded by `[[ -x ... ]]`, so `chmod -x` on ONE mutation proof dropped
# it from the dynamically computed denominator and the suite still printed `42 of 42 test(s) passed.`
# rc 0 (two cross-family blind readers + the parent reproduced it). The suite TOTAL is pinned too
# (kernel_verify.sh's `ran == exp` house style): adding a test is a deliberate bump of
# EXPECTED_SUITE_TOTAL, never an accident, and losing one is RED. `make check` runs
# `run_tests.sh --check-pinned` to catch execute-bit drift on this set without running the suite.
PINNED_PROOFS=(
    run_lexer_native.sh run_lexer_native_mutation.sh
    run_parser_native.sh run_parser_native_mutation.sh
    run_evaluator_native.sh run_evaluator_native_mutation.sh
    run_aggregate_render_native.sh run_aggregate_render_native_mutation.sh
    run_vm_native.sh run_vm_native_mutation.sh
    run_klondike_native.sh run_klondike_native_mutation.sh
    run_emitter_native.sh run_emitter_native_mutation.sh
    run_closed_loop_memory_diet.sh run_error_vocab_native.sh
)
EXPECTED_SUITE_TOTAL=36
pinned_proof() { # name -> 0 iff present + executable; else prints FAIL, scores a FAILED test, returns 1
    if [[ -x "$PWD/$1" ]]; then return 0; fi
    echo "FAIL: pinned proof $1 is missing or not executable (fail-closed: a proof that cannot run is a FAILED test, never a silent skip)"
    total=$((total + 1)); fail=$((fail + 1)); return 1
}
# The C re-seed mint mode is RETIRED too (no C interpreter exists to mint with). Refuse it, so
# the seed-integrity check below always compares the production compiler with the committed seed.
if [[ "${NATIVE_CODEGEN_ALLOW_C_MINT:-0}" == "1" ]]; then
    echo "FAIL: NATIVE_CODEGEN_ALLOW_C_MINT=1 is retired -- the C bootstrap no longer exists; gen-1 is re-minted C-FREE by \`make reseed\` (reseed_gen1.sh), never by C. Refusing."
    exit 1
fi
# The C oracle mode is RETIRED (the C bootstrap is gone; native_codegen_oracle.sh refuses
# NATIVE_CODEGEN_ORACLE=c inside every gate): refuse it here, before any gate runs.
if [[ "${NATIVE_CODEGEN_ORACLE:-golden}" != "golden" ]]; then
    echo "FAIL: NATIVE_CODEGEN_ORACLE='${NATIVE_CODEGEN_ORACLE}' is retired -- the C bootstrap no longer exists; the only oracle mode is 'golden' (committed C-derived goldens, LEDGER D24). Refusing."
    exit 1
fi
if [[ "${1:-}" == "--check-pinned" ]]; then
    pinned_bad=0
    for pinned_s in "${PINNED_PROOFS[@]}"; do
        [[ -x "$PWD/$pinned_s" ]] || { echo "FAIL: pinned proof $pinned_s is missing or not executable (bootstrap/tests/run_tests.sh PINNED_PROOFS)"; pinned_bad=1; }
    done
    [[ "$pinned_bad" -eq 0 ]] && echo "OK: ${#PINNED_PROOFS[@]} pinned proof scripts present + executable"
    exit "$pinned_bad"
fi
native_codegen_dispatch_tmp=
cleanup_run_tests() {
    if [[ -n "$native_codegen_dispatch_tmp" && -d "$native_codegen_dispatch_tmp" ]]; then
        rm -rf "$native_codegen_dispatch_tmp"
    fi
}
trap cleanup_run_tests EXIT

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

# Golden provenance banner -- printed ONCE per suite here (subprocess gates stage their own seed and
# would otherwise each print it; blind-audit R3 + Codex NIT): the default oracle for links 2..16 +
# rejects is a FROZEN SNAPSHOT captured once from the retired C bootstrap, NOT a live differential and
# NOT regenerable in this tree (MEWTWO LEDGER D24). Standalone gate runs still print their own line.
echo "native-codegen: oracle mode=golden -- links 2..16 + rejects are graded against COMMITTED C-derived goldens (a frozen snapshot of the retired C bootstrap, NOT regenerable in this tree -- LEDGER D24); C is NOT run"
export NATIVE_CODEGEN_GOLDEN_BANNER_SHOWN=1

if [[ -d ../../stack ]]; then
    STACK_DIR="$(cd ../../stack && pwd)"

    # Lexer NATIVE-EXECUTION gate (sovereignty axis, Role-C reduction): the C-free
    # gen-1 seed compiles lexer_fragment.herb to an ELF that scans+classifies+serializes
    # with NO C in its execution path; its stdout line 1 must equal the independent
    # oracle (ENDURING) and -- while a C interpreter still exists -- the interpreter's
    # output (RETIREABLE faithfulness guard). The FOURTH metacircular fragment to gain a
    # committed native execution path (after the evaluator, the VM, and the parser); the
    # lexer self-description test now survives C's deletion (only klondike remains).
    if pinned_proof run_lexer_native.sh; then
        total=$((total + 1))
        if LEXER_NATIVE_NO_C=1 HERBERT="$HERBERT" "$PWD/run_lexer_native.sh"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    # Prove the lexer native-execution gate BITES (RED-first): a mutated lex rule
    # (a character-class -> token-kind classification) still compiles natively but
    # makes the C-free ELF emit a divergent token stream.
    if pinned_proof run_lexer_native_mutation.sh; then
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
    if pinned_proof run_parser_native.sh; then
        total=$((total + 1))
        if PARSER_NATIVE_NO_C=1 HERBERT="$HERBERT" "$PWD/run_parser_native.sh"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    # Prove the parser native-execution gate BITES (RED-first): a mutated parse rule
    # (an operator -> AST-tag mapping) still compiles natively but makes the C-free
    # ELF emit a divergent S-expression.
    if pinned_proof run_parser_native_mutation.sh; then
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
    if pinned_proof run_evaluator_native.sh; then
        total=$((total + 1))
        if EVALUATOR_NATIVE_NO_C=1 HERBERT="$HERBERT" "$PWD/run_evaluator_native.sh"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    # Prove the evaluator native-execution gate BITES (RED-first): a mutated
    # evaluator rule still compiles natively but makes the C-free ELF diverge
    # from the oracle.
    if pinned_proof run_evaluator_native_mutation.sh; then
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
    # the retired faithfulness leg vs C stays off (AGGREGATE_RENDER_NATIVE_NO_C=1).
    if pinned_proof run_aggregate_render_native.sh; then
        total=$((total + 1))
        # muster (link 13): the enduring leg grades the 12 native-output foundational
        # tests C-FREE against their committed .expected files.
        if AGGREGATE_RENDER_NATIVE_NO_C=1 HERBERT="$HERBERT" "$PWD/run_aggregate_render_native.sh"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    # Prove the aggregate-render gate BITES (RED-first): a mutated renderer still
    # compiles but makes the rendered tuple diverge from the canonical key.
    if pinned_proof run_aggregate_render_native_mutation.sh; then
        total=$((total + 1))
        if "$PWD/run_aggregate_render_native_mutation.sh"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi


    # VM NATIVE-EXECUTION gate (sovereignty axis, Role-C reduction): the C-free
    # gen-1 seed compiles vm_fragment.herb to an ELF that runs the bytecode VM with
    # NO C in its execution path; its stdout line 1 must equal the independent
    # oracle (ENDURING) and -- while a C interpreter still exists -- the
    # interpreter's output (RETIREABLE faithfulness guard). The SECOND metacircular
    # fragment to gain a committed native execution path (after the evaluator); the
    # bytecode-VM self-description test now survives C's deletion.
    if pinned_proof run_vm_native.sh; then
        total=$((total + 1))
        if VM_NATIVE_NO_C=1 HERBERT="$HERBERT" "$PWD/run_vm_native.sh"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    # Prove the VM native-execution gate BITES (RED-first): a mutated bytecode-VM
    # opcode handler still compiles natively but makes the C-free ELF diverge from
    # the oracle.
    if pinned_proof run_vm_native_mutation.sh; then
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
    if pinned_proof run_klondike_native.sh; then
        total=$((total + 1))
        if KLONDIKE_NATIVE_NO_C=1 HERBERT="$HERBERT" "$PWD/run_klondike_native.sh"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    # Prove the klondike native-execution gate BITES (RED-first): a mutated VM rule
    # (int_binop's + / < / == ) still compiles natively but makes the C-free ELF emit
    # a divergent result tuple.
    if pinned_proof run_klondike_native_mutation.sh; then
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
    if pinned_proof run_emitter_native.sh; then
        total=$((total + 1))
        if EMITTER_NATIVE_NO_C=1 HERBERT="$HERBERT" "$PWD/run_emitter_native.sh"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    # Prove the emitter native-execution gate BITES (RED-first): a mutated reachable
    # LOWERING rule (an opcode mapping / a frame-slot allocation / a control-flow branch)
    # still compiles natively but makes the C-free ELF emit a divergent bytecode listing.
    if pinned_proof run_emitter_native_mutation.sh; then
        total=$((total + 1))
        if "$PWD/run_emitter_native_mutation.sh"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

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
        if HERBERT="$HERBERT" "$NATIVE_CODEGEN_LINK1"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    NATIVE_CODEGEN_LINK2="$PWD/run_native_codegen_link2.sh"
    if [[ -f "$NATIVE_CODEGEN_LINK2" ]]; then
        total=$((total + 1))
        if HERBERT="$HERBERT" "$NATIVE_CODEGEN_LINK2"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    NATIVE_CODEGEN_LINK3="$PWD/run_native_codegen_link3.sh"
    if [[ -f "$NATIVE_CODEGEN_LINK3" ]]; then
        total=$((total + 1))
        if HERBERT="$HERBERT" "$NATIVE_CODEGEN_LINK3"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    NATIVE_CODEGEN_LINK4="$PWD/run_native_codegen_link4.sh"
    if [[ -f "$NATIVE_CODEGEN_LINK4" ]]; then
        total=$((total + 1))
        if HERBERT="$HERBERT" "$NATIVE_CODEGEN_LINK4"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    NATIVE_CODEGEN_LINK5="$PWD/run_native_codegen_link5.sh"
    if [[ -f "$NATIVE_CODEGEN_LINK5" ]]; then
        total=$((total + 1))
        if HERBERT="$HERBERT" "$NATIVE_CODEGEN_LINK5"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    NATIVE_CODEGEN_LINK6="$PWD/run_native_codegen_link6.sh"
    if [[ -f "$NATIVE_CODEGEN_LINK6" ]]; then
        total=$((total + 1))
        if HERBERT="$HERBERT" "$NATIVE_CODEGEN_LINK6"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    NATIVE_CODEGEN_LINK7="$PWD/run_native_codegen_link7.sh"
    if [[ -f "$NATIVE_CODEGEN_LINK7" ]]; then
        total=$((total + 1))
        if HERBERT="$HERBERT" "$NATIVE_CODEGEN_LINK7"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    NATIVE_CODEGEN_LINK8="$PWD/run_native_codegen_link8.sh"
    if [[ -f "$NATIVE_CODEGEN_LINK8" ]]; then
        total=$((total + 1))
        if HERBERT="$HERBERT" "$NATIVE_CODEGEN_LINK8"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    NATIVE_CODEGEN_LINK9="$PWD/run_native_codegen_link9.sh"
    if [[ -f "$NATIVE_CODEGEN_LINK9" ]]; then
        total=$((total + 1))
        if HERBERT="$HERBERT" "$NATIVE_CODEGEN_LINK9"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    NATIVE_CODEGEN_LINK10="$PWD/run_native_codegen_link10.sh"
    if [[ -f "$NATIVE_CODEGEN_LINK10" ]]; then
        total=$((total + 1))
        if HERBERT="$HERBERT" "$NATIVE_CODEGEN_LINK10"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    NATIVE_CODEGEN_LINK11="$PWD/run_native_codegen_link11.sh"
    if [[ -f "$NATIVE_CODEGEN_LINK11" ]]; then
        total=$((total + 1))
        if HERBERT="$HERBERT" "$NATIVE_CODEGEN_LINK11"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    NATIVE_CODEGEN_LINK12="$PWD/run_native_codegen_link12.sh"
    if [[ -f "$NATIVE_CODEGEN_LINK12" ]]; then
        total=$((total + 1))
        if HERBERT="$HERBERT" "$NATIVE_CODEGEN_LINK12"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    NATIVE_CODEGEN_LINK13="$PWD/run_native_codegen_link13.sh"
    if [[ -f "$NATIVE_CODEGEN_LINK13" ]]; then
        total=$((total + 1))
        if HERBERT="$HERBERT" "$NATIVE_CODEGEN_LINK13"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    NATIVE_CODEGEN_LINK14="$PWD/run_native_codegen_link14.sh"
    if [[ -f "$NATIVE_CODEGEN_LINK14" ]]; then
        total=$((total + 1))
        if HERBERT="$HERBERT" "$NATIVE_CODEGEN_LINK14"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    NATIVE_CODEGEN_LINK15="$PWD/run_native_codegen_link15.sh"
    if [[ -f "$NATIVE_CODEGEN_LINK15" ]]; then
        total=$((total + 1))
        if HERBERT="$HERBERT" "$NATIVE_CODEGEN_LINK15"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    NATIVE_CODEGEN_LINK16="$PWD/run_native_codegen_link16.sh"
    if [[ -f "$NATIVE_CODEGEN_LINK16" ]]; then
        total=$((total + 1))
        if HERBERT="$HERBERT" "$NATIVE_CODEGEN_LINK16"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    NATIVE_CODEGEN_REJECTS="$PWD/run_native_codegen_rejects.sh"
    if [[ -f "$NATIVE_CODEGEN_REJECTS" ]]; then
        total=$((total + 1))
        if HERBERT="$HERBERT" "$NATIVE_CODEGEN_REJECTS"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    fi

    run_native_codegen_non_vacuity_check
    run_native_codegen_corrupt_compiler_check
    run_native_codegen_michoi_seed_check

fi

# Closed-loop memory diet: the committed seed compiles stack/native_compile_fragment.herb
# and must reproduce itself byte for byte under the pinned RSS ceiling.
if pinned_proof run_closed_loop_memory_diet.sh; then
    total=$((total + 1))
    if "$PWD/run_closed_loop_memory_diet.sh"; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
    fi
fi

# Error-vocabulary gate: the seed compiles stack/klondike.herb, which must report
# the committed ERR 101-316 diagnostics on the 54 malformed probes in stack/error_probes.
# Its mutation proof runs in verify-local and CI (make error-vocab-native).
if pinned_proof run_error_vocab_native.sh; then
    total=$((total + 1))
    if "$PWD/run_error_vocab_native.sh"; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
    fi
fi

echo
if [[ $total -ne $EXPECTED_SUITE_TOTAL ]]; then
    echo "FAIL: suite ran $total test(s) but the pinned set expects $EXPECTED_SUITE_TOTAL -- refusing a vacuous GREEN (a test silently dropped or added; bump EXPECTED_SUITE_TOTAL deliberately, in the same commit as the test)"
    fail=$((fail + 1))
fi
if [[ $fail -ne 0 ]]; then
    echo "$fail of $total test(s) failed."
    exit 1
fi
echo "$pass of $total test(s) passed."
exit 0
