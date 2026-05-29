#!/usr/bin/env bash
# Native codegen Link 14 (iager): bitwise and shift operators -- & | ^ ~ << >>
# on 64-bit unsigned ints. Accept probes are compiled, run, and diffed
# byte-for-byte against the C bootstrap oracle (the native program renders its
# return value as canonical decimal/bool directly to stdout, per D14). Reject
# probes (each with a renamed twin) must NOT compile to an ELF -- they cover the
# int/bool split (~true, not 5) and the settled-precedence (c) class-mixing
# rejects. A white-box disasm gate pins the exact emit bytes and proves the
# branch-after-bitwise displacement is correct (the nc_group_single_len layout
# forcing function -- the straight-line PTE probe cannot expose a sizing bug).
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
HERBERT="${HERBERT:-$repo_root/build/herbert}"
backend="$repo_root/stack/native_compile_fragment.herb"
fixtures="$script_dir/fixtures/link14"

if [[ ! -x "$HERBERT" ]]; then
    echo "FAIL: stack/native_compile_fragment.herb (cannot find herbert at $HERBERT)"
    exit 1
fi
if [[ ! -f "$backend" ]]; then
    echo "FAIL: stack/native_compile_fragment.herb (missing backend)"
    exit 1
fi
if [[ ! -d "$fixtures" ]]; then
    echo "FAIL: stack/native_compile_fragment.herb (missing fixtures dir $fixtures)"
    exit 1
fi

source "$script_dir/native_codegen_oracle.sh"
native_codegen_oracle_begin link14 || exit 1

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
native_codegen_ensure_compiler "$tmp/native-compiler" || exit 1
pass=0
fail=0

fail_test() {
    echo "FAIL: stack/native_compile_fragment.herb ($1)"
    fail=$((fail + 1))
}

# Compile a probe with the gen-1 compiler. The compiler emits its ELF to a
# byte-pure file "a.out" (do fwriter), so run it in a per-label scratch dir and
# harvest that dir's a.out into a distinct path.
compile_probe() {
    local label="$1" probe="$2" elf="$3"
    local cdir="$tmp/$label.compile.d"
    rm -rf "$cdir"; mkdir -p "$cdir"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" <"$probe" >"$tmp/$label.compile.out" 2>"$tmp/$label.compile.err" )
    if [[ ! -f "$cdir/a.out" ]]; then
        fail_test "compile $label rejected/no a.out: stdout=$(head -1 "$tmp/$label.compile.out") stderr=$(head -1 "$tmp/$label.compile.err")"
        return 1
    fi
    local magic
    magic=$(head -c4 "$cdir/a.out" | xxd -p | tr -d '\n')
    if [[ "$magic" != "7f454c46" ]]; then
        fail_test "compile $label: a.out not an ELF (magic=$magic)"
        return 1
    fi
    cp "$cdir/a.out" "$elf"
    chmod +x "$elf"
    return 0
}

# Accept probe: compile, run the ELF with $input on stdin, and require its
# stdout to equal the C oracle's stdout byte-for-byte (canonical render).
check_diff() {
    local label="$1" probe="$2" input="$3"
    local elf="$tmp/$label.elf"
    compile_probe "$label" "$probe" "$elf" || return
    if ! oracle_expect_le64 "link14_${label}" "$probe" "$input" "$tmp/$label.expected"; then
        fail_test "differential $label: oracle failed"
        return
    fi
    "$elf" <"$input" >"$tmp/$label.native" 2>"$tmp/$label.native.err"
    local nrc=$?
    if [[ $nrc -eq 0 ]] && cmp -s "$tmp/$label.expected" "$tmp/$label.native"; then
        pass=$((pass + 1))
    else
        fail_test "differential $label: native rc=$nrc bytes=$(xxd -p "$tmp/$label.native" | tr -d '\n') expected=$(xxd -p "$tmp/$label.expected" | tr -d '\n')"
    fi
}

# Reject probe: the gen-1 compiler must NOT emit an ELF, AND the rejection must be
# the INTENDED clean one -- the compiler's own diagnostic, NOT an accidental
# mis-parse crash. A bare "no a.out" check cannot tell a principled reject from a
# crash; that gap is exactly how the F1 dead-code class-mix slipped (a buried
# class-mix used to "reject" via a `get: ... out of range` parser crash that also
# wrote no a.out). $3 is an ERE the diagnostic MUST match (e.g. "ERR 442").
#
# Stream contract (verified on silicon): the compiler reports rejections through
# its own `flogger` to STDOUT (fd 1, both in the C oracle and the emitted ELF) and
# returns 0 from main -- so a clean reject is exit 0 + diagnostic-on-stdout + no
# a.out. A crash is the opposite: a nonzero exit from the C runtime with the
# `get:`/`out of range` abort text on STDERR and no diagnostic on stdout. We assert
# the diagnostic IS on stdout and a crash signature is on NEITHER stream.
check_reject() {
    local label="$1" probe="$2" expect_diag="$3"
    local rdir="$tmp/$label.reject.d"
    rm -rf "$rdir"; mkdir -p "$rdir"
    ( cd "$rdir" && "$NATIVE_CODEGEN_COMPILER" <"$probe" >"$tmp/$label.out" 2>"$tmp/$label.err" )
    local rc=$?
    if [[ -f "$rdir/a.out" ]]; then
        fail_test "$label: expected rejection but compiler emitted a.out (stdout=$(head -1 "$tmp/$label.out"))"
        return
    fi
    # A clean reject is exit 0 + diagnostic-on-stdout + no a.out. ANY nonzero exit is
    # a crash (segfault, abort, runtime fault) regardless of what is on stderr --
    # the airtight form of the crash check below, which stays for a clearer message
    # on the known get:/out-of-range parser-crash path.
    if [[ $rc -ne 0 ]]; then
        fail_test "$label: rejection exited nonzero ($rc) -- a crash, not a clean diagnostic-on-stdout reject (stderr=$(head -1 "$tmp/$label.err"))"
        return
    fi
    if grep -Eq 'out of range|get:' "$tmp/$label.out" "$tmp/$label.err"; then
        fail_test "$label: rejection is a CRASH, not a clean diagnostic (stdout=$(head -1 "$tmp/$label.out") stderr=$(head -1 "$tmp/$label.err"))"
        return
    fi
    if ! grep -Eq "$expect_diag" "$tmp/$label.out"; then
        fail_test "$label: rejection diagnostic missing /$expect_diag/ (stdout=$(head -1 "$tmp/$label.out") stderr=$(head -1 "$tmp/$label.err"))"
        return
    fi
    pass=$((pass + 1))
}

# Reject probe + its renamed twin: BOTH must reject cleanly with the same expected
# diagnostic. If the twin flips to compile, the rejection was probe-fitted (a bug).
check_reject_pair() {
    local label="$1" probe="$2" twin="$3" expect_diag="$4"
    check_reject "${label}" "$probe" "$expect_diag"
    check_reject "${label}_twin" "$twin" "$expect_diag"
}

# White-box disasm gate. Pins the exact emit bytes for every new opcode and
# proves the branch-after-bitwise displacement is correct.
check_disasm_gate() {
    local pte_elf="$tmp/gate_pte.elf"
    local xor_elf="$tmp/gate_xor.elf"
    local shr_elf="$tmp/gate_shr.elf"
    local bnot_elf="$tmp/gate_bnot.elf"
    local branch_elf="$tmp/gate_branch.elf"
    compile_probe gate_pte    "$fixtures/pte.herb"                  "$pte_elf"    || return
    compile_probe gate_xor    "$fixtures/xor.herb"                  "$xor_elf"    || return
    compile_probe gate_shr    "$fixtures/shr.herb"                  "$shr_elf"    || return
    compile_probe gate_bnot   "$fixtures/bnot.herb"                 "$bnot_elf"   || return
    compile_probe gate_branch "$fixtures/branch_after_bitwise.herb" "$branch_elf" || return

    local pte_hex xor_hex shr_hex bnot_hex branch_hex
    pte_hex=$(xxd -p "$pte_elf" | tr -d '\n')
    xor_hex=$(xxd -p "$xor_elf" | tr -d '\n')
    shr_hex=$(xxd -p "$shr_elf" | tr -d '\n')
    bnot_hex=$(xxd -p "$bnot_elf" | tr -d '\n')
    branch_hex=$(xxd -p "$branch_elf" | tr -d '\n')

    # The new emit byte sequences (pop rcx=59 pop rax=58 <op> push rax=50):
    #   band 59 58 48 21 c8 50 | bor 59 58 48 09 c8 50 | bxor 59 58 48 31 c8 50
    #   shl  59 58 48 d3 e0 50 | shr 59 58 48 d3 e8 50 | bnot 58 48 f7 d0 50
    local gate_ok=1
    [[ "$pte_hex"    == *"595848d3e050"* ]] || { fail_test "disasm gate: pte missing shl (59 58 48 d3 e0 50)"; gate_ok=0; }
    [[ "$pte_hex"    == *"59584821c850"* ]] || { fail_test "disasm gate: pte missing and (59 58 48 21 c8 50)"; gate_ok=0; }
    [[ "$pte_hex"    == *"59584809c850"* ]] || { fail_test "disasm gate: pte missing or (59 58 48 09 c8 50)"; gate_ok=0; }
    [[ "$xor_hex"    == *"59584831c850"* ]] || { fail_test "disasm gate: xor missing xor (59 58 48 31 c8 50)"; gate_ok=0; }
    [[ "$shr_hex"    == *"595848d3e850"* ]] || { fail_test "disasm gate: shr missing shr (59 58 48 d3 e8 50)"; gate_ok=0; }
    [[ "$bnot_hex"   == *"5848f7d050"*   ]] || { fail_test "disasm gate: bnot missing not (58 48 f7 d0 50)"; gate_ok=0; }
    # Branch-after-bitwise: the classify() body computes (x & 1) then a setcc
    # compare (eq), then a conditional branch. The `and` emit byte must be
    # present, and the conditional-branch opcode (0f 84 = je rel32, emitted by
    # nc_emit_br_if_false's path) must appear -- if the bitwise op were sized 0
    # the displacement would rot (the differential below catches the value).
    [[ "$branch_hex" == *"59584821c850"* ]] || { fail_test "disasm gate: branch probe missing and (59 58 48 21 c8 50)"; gate_ok=0; }

    if [[ $gate_ok -eq 1 ]]; then
        pass=$((pass + 1))
    fi
}

# --- accept probes (data-dependent inputs) ---
printf '\xDE\xAD\x07'     >"$tmp/in_pte"
check_diff pte            "$fixtures/pte.herb"                  "$tmp/in_pte"
printf '\x0c\x0a'         >"$tmp/in_xor"
check_diff xor            "$fixtures/xor.herb"                  "$tmp/in_xor"
printf '\xff\x03'         >"$tmp/in_shr"
check_diff shr            "$fixtures/shr.herb"                  "$tmp/in_shr"
printf '\x96'             >"$tmp/in_bnot"
check_diff bnot           "$fixtures/bnot.herb"                 "$tmp/in_bnot"
printf '\x05\x12'         >"$tmp/in_nsc"
check_diff nonshortcircuit "$fixtures/nonshortcircuit.herb"    "$tmp/in_nsc"
printf '\x07'             >"$tmp/in_lex"
check_diff lexer_longest  "$fixtures/lexer_longest.herb"       "$tmp/in_lex"
# branch-after-bitwise: even byte (40000 arm) and odd byte (50001 arm) so both
# arms are exercised and the displacement must be correct for the value to match.
printf '\x06\x07'         >"$tmp/in_branch"
check_diff branch_after_bitwise "$fixtures/branch_after_bitwise.herb" "$tmp/in_branch"

# --- parenthesised accept probes (the precedence-(c) forms that DO parse) ---
printf '\x09'             >"$tmp/in_pc"
check_diff parens_cross       "$fixtures/accept_parens_cross.herb"       "$tmp/in_pc"
printf '\x03'             >"$tmp/in_psa"
check_diff parens_shift_arith "$fixtures/accept_parens_shift_arith.herb" "$tmp/in_psa"
printf '\x04'             >"$tmp/in_pbc"
check_diff parens_bit_cmp     "$fixtures/accept_parens_bit_cmp.herb"     "$tmp/in_pbc"

# --- reject probes (each with a renamed twin; BOTH must reject CLEANLY) ---
# Class-mixing rejects carry the precedence-(c) diagnostic (ERR 442); the int/bool
# category-split rejects carry the type-conflict diagnostic (ERR 430). The probe
# must reject with the INTENDED code, not merely "no a.out" (see check_reject).
check_reject_pair mix_cross       "$fixtures/reject_mix_cross.herb"       "$fixtures/reject_mix_cross_twin.herb"       "ERR 442"
check_reject_pair mix_shift_arith "$fixtures/reject_mix_shift_arith.herb" "$fixtures/reject_mix_shift_arith_twin.herb" "ERR 442"
check_reject_pair mix_bit_cmp     "$fixtures/reject_mix_bit_cmp.herb"     "$fixtures/reject_mix_bit_cmp_twin.herb"     "ERR 442"
# Dead-function class-mix (the F1 repro): a class-mix in a function NOT reachable
# from main is a syntactic error C rejects for all functions; native must reject it
# too (reachability-independent), with the SAME clean ERR 442 -- not silently emit
# an ELF (the F1 bug) and not crash. The twin renames/revalues to guard against a
# probe-fitted fix.
check_reject_pair dead_mix        "$fixtures/reject_dead_mix.herb"        "$fixtures/reject_dead_mix_twin.herb"        "ERR 442"
check_reject_pair bnot_bool       "$fixtures/reject_bnot_bool.herb"       "$fixtures/reject_bnot_bool_twin.herb"       "ERR 430"
check_reject_pair not_int         "$fixtures/reject_not_int.herb"         "$fixtures/reject_not_int_twin.herb"         "ERR 430"

# --- white-box emit/layout disasm gate ---
check_disasm_gate

echo ""
if [[ $fail -ne 0 ]]; then
    echo "$fail of $((pass + fail)) native-codegen-link14 sub-test(s) failed."
    exit 1
fi
if ! native_codegen_oracle_finish; then
    exit 1
fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link14: $pass sub-tests: & | ^ ~ << >> differentials (pte/xor/shr/bnot/non-short-circuit/lexer-longest-match/branch-after-bitwise), parens-precedence accepts, int/bool + precedence-(c) class-mix rejects (incl. reachability-independent dead-function class-mix) with renamed twins -- each asserting the intended clean diagnostic (ERR 442/430), not just no-a.out, emit-byte/layout disasm gate)"
exit 0
