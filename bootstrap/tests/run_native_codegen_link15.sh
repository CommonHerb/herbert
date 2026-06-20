#!/usr/bin/env bash
# Native codegen Link 15 (tonka): multiply / divide / modulo operators -- * / %
# on 64-bit unsigned ints. The multiplicative tier binds tighter than additive
# `+ -` and looser than prefix-unary `not`/`~`.
#
# Accept probes are compiled with the gen-1 (native) compiler, run, and diffed
# byte-for-byte against the C bootstrap oracle (the native program renders its
# return value as canonical decimal directly to stdout, per D14). The Adler-32
# probe is the differential centerpiece -- it exercises `+`, `*`, and `% 65521`
# (a non-power-of-two modulus that needs REAL unsigned division, not a mask).
#
# Div/mod by zero must TRAP CLEANLY: the compiled program faults with a nonzero
# exit and empty stdout (NO SIGFPE/#DE), matching the C bootstrap's exit status.
# The native back end guards with `test rcx,rcx; jz <exit1>` before `div`.
# (Exact-stderr text is deferred per the D13 fault-parity convention: C prints
# `herbert: line N: division by zero`; native matches exit status + empty
# stdout.) Each trap probe carries a renamed twin -- if the twin behaves
# differently the trap was probe-fitted.
#
# A white-box disasm gate pins the exact emit bytes for imul and the div
# zero-check+div sequence (the nc_group_single_len layout forcing function: a
# wrong op length silently rots branch displacements; the straight-line probe
# cannot expose a sizing bug).
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
HERBERT="${HERBERT:-$repo_root/build/herbert}"
backend="$repo_root/stack/native_compile_fragment.herb"
fixtures="$script_dir/fixtures/link15"

if [[ "${NATIVE_CODEGEN_ORACLE:-golden}" == "c" && ! -x "$HERBERT" ]]; then
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
native_codegen_oracle_begin link15 || exit 1

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
# stdout to equal the C oracle's stdout byte-for-byte (canonical render). The
# captured native stdout is stashed under $tmp/$label.native for cross-probe
# precedence comparisons.
check_diff() {
    local label="$1" probe="$2" input="$3"
    local elf="$tmp/$label.elf"
    compile_probe "$label" "$probe" "$elf" || return
    if ! oracle_expect_le64 "link15_${label}" "$probe" "$input" "$tmp/$label.expected"; then
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

# Trap probe: the compiled program must fault CLEANLY on a zero divisor -- a
# nonzero exit with EMPTY stdout and NO SIGFPE (#DE, exit 136) / SIGSEGV. The C
# bootstrap does the same (nonzero exit, empty stdout, located stderr). We grade
# exit-status parity (NOT the full stderr envelope -- exact-stderr is deferred).
# The compiler itself must exit 0 and emit a valid ELF (this is an ACCEPTED
# program with a runtime fault, not a rejected one).
check_trap() {
    local label="$1" probe="$2" input="$3"
    local elf="$tmp/$label.elf"
    compile_probe "$label" "$probe" "$elf" || return
    # tollgate: the compiled probe must trap CLEANLY -- nonzero exit, empty
    # stdout, and crucially NOT a raw SIGFPE/#DE (136) or SIGSEGV (139). The
    # fixture is a runtime fault BY CONSTRUCTION (e.g. divide-by-zero) and the
    # exact trap-emitting bytes are pinned white-box by the disasm gate, so the
    # clean-trap property is intrinsic and graded WITHOUT C. The native trap exits
    # 1 (herbert's runtime-fault convention). C is preserved as an OPT-IN
    # exit-status-parity cross-check under NATIVE_CODEGEN_ORACLE=c.
    "$elf" <"$input" >"$tmp/$label.n.out" 2>"$tmp/$label.n.err"
    local nrc=$?
    if [[ $nrc -eq 0 ]]; then
        fail_test "trap $label: native did NOT trap (rc=0)"
        return
    fi
    if [[ $nrc -eq 136 || $nrc -eq 139 ]]; then
        fail_test "trap $label: native crashed with a HARDWARE fault (rc=$nrc -- SIGFPE/#DE or SIGSEGV), not a clean trap"
        return
    fi
    if [[ -s "$tmp/$label.n.out" ]]; then
        fail_test "trap $label: native wrote stdout before faulting (expected empty): $(xxd -p "$tmp/$label.n.out" | tr -d '\n')"
        return
    fi
    if [[ $nrc -ne 1 ]]; then
        fail_test "trap $label: native trap exit was $nrc, expected 1 (herbert runtime-fault convention)"
        return
    fi
    if [[ "$NATIVE_CODEGEN_ORACLE" == "c" ]]; then
        "$HERBERT" "$probe" <"$input" >"$tmp/$label.c.out" 2>"$tmp/$label.c.err"
        local crc=$?
        if [[ $crc -eq 0 || -s "$tmp/$label.c.out" ]]; then
            fail_test "trap $label: C cross-check did not cleanly trap (rc=$crc) -- probe is not a runtime fault"
            return
        fi
        if [[ $nrc -ne $crc ]]; then
            fail_test "trap $label: exit-status parity broken (C rc=$crc native rc=$nrc)"
            return
        fi
    fi
    pass=$((pass + 1))
}

# Trap probe + renamed twin: BOTH must trap cleanly with the same exit status.
check_trap_pair() {
    local label="$1" probe="$2" twin="$3" input="$4"
    check_trap "$label" "$probe" "$input"
    check_trap "${label}_twin" "$twin" "$input"
}

# Precedence proof: `a + b * c` (prec_mul_add) must DIFFER from `(a + b) * c`
# (prec_paren_add) on the same input. Both are already graded byte-exact vs C by
# check_diff; here we assert their native results are not equal, which can only
# hold if `*` binds tighter than `+` (a parser that bound them equally would
# make the two probes agree).
check_precedence_differ() {
    if [[ ! -s "$tmp/prec_mul_add.native" || ! -s "$tmp/prec_paren_add.native" ]]; then
        fail_test "precedence: missing native outputs (prereq probes failed)"
        return
    fi
    if cmp -s "$tmp/prec_mul_add.native" "$tmp/prec_paren_add.native"; then
        fail_test "precedence: a + b * c == (a + b) * c (multiplicative did NOT bind tighter than additive)"
        return
    fi
    # Sanity: with input bytes (2,3,4) the values are exactly 14 and 20.
    if [[ "$(tr -d '\n' <"$tmp/prec_mul_add.native")" != "14" ]]; then
        fail_test "precedence: a + b * c was $(tr -d '\n' <"$tmp/prec_mul_add.native"), expected 14"
        return
    fi
    if [[ "$(tr -d '\n' <"$tmp/prec_paren_add.native")" != "20" ]]; then
        fail_test "precedence: (a + b) * c was $(tr -d '\n' <"$tmp/prec_paren_add.native"), expected 20"
        return
    fi
    pass=$((pass + 1))
}

# White-box disasm gate. Pins the exact emit bytes for imul and the div
# zero-check+div sequence.
check_disasm_gate() {
    local mul_elf="$tmp/gate_mul.elf"
    local div_elf="$tmp/gate_div.elf"
    local mod_elf="$tmp/gate_mod.elf"
    compile_probe gate_mul "$fixtures/mul.herb" "$mul_elf" || return
    compile_probe gate_div "$fixtures/div.herb" "$div_elf" || return
    compile_probe gate_mod "$fixtures/mod.herb" "$mod_elf" || return

    local mul_hex div_hex mod_hex
    mul_hex=$(xxd -p "$mul_elf" | tr -d '\n')
    div_hex=$(xxd -p "$div_elf" | tr -d '\n')
    mod_hex=$(xxd -p "$mod_elf" | tr -d '\n')

    # Emit byte sequences (pop rcx=59 pop rax=58 ... push result):
    #   mul: 59 58 48 0f af c1 50          (imul rax,rcx; push rax)
    #   div: 59 58 48 85 c9 0f 84 <rel32>  (test rcx,rcx; jz exit1)
    #        48 31 d2 48 f7 f1 50          (xor rdx,rdx; div rcx; push rax)
    #   mod: ... 48 31 d2 48 f7 f1 52      (push rdx instead of rax)
    local gate_ok=1
    [[ "$mul_hex" == *"5958480fafc150"* ]] || { fail_test "disasm gate: mul missing imul (59 58 48 0f af c1 50)"; gate_ok=0; }
    [[ "$div_hex" == *"59584885c90f84"* ]] || { fail_test "disasm gate: div missing zero-check (59 58 48 85 c9 0f 84)"; gate_ok=0; }
    [[ "$div_hex" == *"4831d248f7f150"* ]] || { fail_test "disasm gate: div missing div body (48 31 d2 48 f7 f1 50 / push rax)"; gate_ok=0; }
    [[ "$mod_hex" == *"59584885c90f84"* ]] || { fail_test "disasm gate: mod missing zero-check (59 58 48 85 c9 0f 84)"; gate_ok=0; }
    [[ "$mod_hex" == *"4831d248f7f152"* ]] || { fail_test "disasm gate: mod missing mod body (48 31 d2 48 f7 f1 52 / push rdx)"; gate_ok=0; }
    # The mod body must NOT push rax (0x50): a copy-paste regression that pushed
    # the quotient instead of the remainder would still pass a fixed-input
    # differential if the values coincided, but never the byte gate.
    [[ "$mod_hex" != *"4831d248f7f150"* ]] || { fail_test "disasm gate: mod pushed rax (quotient) not rdx (remainder)"; gate_ok=0; }

    if [[ $gate_ok -eq 1 ]]; then
        pass=$((pass + 1))
    fi
}

# --- accept probes (data-dependent inputs) ---
# Adler-32 over a representative payload (exercises + * and % 65521).
printf 'Wikipedia'      >"$tmp/in_adler"
check_diff adler32      "$fixtures/adler32.herb"       "$tmp/in_adler"
printf '\xDE\x07'       >"$tmp/in_mul"
check_diff mul          "$fixtures/mul.herb"           "$tmp/in_mul"
printf '\x64\x07'       >"$tmp/in_div"
check_diff div          "$fixtures/div.herb"           "$tmp/in_div"
printf '\x64\x07'       >"$tmp/in_mod"
check_diff mod          "$fixtures/mod.herb"           "$tmp/in_mod"
printf '\x07'           >"$tmp/in_mulw"
check_diff mul_wrap     "$fixtures/mul_wrap.herb"      "$tmp/in_mulw"
printf '\x06'           >"$tmp/in_divw"
check_diff div_wrap     "$fixtures/div_wrap.herb"      "$tmp/in_divw"

# --- precedence probes (same input feeds both forms) ---
printf '\x02\x03\x04'   >"$tmp/in_prec"
check_diff prec_mul_add   "$fixtures/prec_mul_add.herb"   "$tmp/in_prec"
check_diff prec_paren_add "$fixtures/prec_paren_add.herb" "$tmp/in_prec"
check_precedence_differ

# --- div/mod by zero trap probes (each with a renamed twin) ---
printf '\x05\x00'       >"$tmp/in_zero"
check_trap_pair divzero "$fixtures/divzero.herb" "$fixtures/divzero_twin.herb" "$tmp/in_zero"
check_trap_pair modzero "$fixtures/modzero.herb" "$fixtures/modzero_twin.herb" "$tmp/in_zero"

# --- white-box emit/layout disasm gate ---
check_disasm_gate

echo ""
if [[ $fail -ne 0 ]]; then
    echo "$fail of $((pass + fail)) native-codegen-link15 sub-test(s) failed."
    exit 1
fi
if ! native_codegen_oracle_finish; then
    exit 1
fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link15: $pass sub-tests: * / % differentials (Adler-32 with + * %65521, mul/div/mod, 64-bit wrap mul/div), a+b*c vs (a+b)*c precedence proof, clean div/mod-by-zero traps with renamed twins (exit-status parity, no SIGFPE), imul/div emit-byte disasm gate)"
exit 0
