#!/usr/bin/env bash
# Native codegen Link 16 (throne): bounded large-literal encoding -- D15.
#
# Before throne, PUSH_INT serialized a 64-bit literal's 8 little-endian bytes
# with the O(value) repeated-subtraction helpers nc_div256/nc_mod256 (a
# workaround from before the language had * / %). A literal large enough to be a
# real 64-bit address (~20 decimal digits) took billions-to-quintillions of
# iterations to encode -- compilation HUNG. throne rewrote those helpers to use
# tonka's real / and % (O(1) per byte); the emitted bytes are unchanged.
#
# Each probe is a bare large literal. The harness compiles it with the gen-1
# (native) compiler under a WALL-CLOCK BOUND: the old O(value) encoder blows the
# bound (the forcing bite -- revert the helpers and these go RED via timeout),
# the new O(1) encoder finishes in well under a second. The compiled program
# renders the literal as canonical decimal (D14); its stdout is graded
# byte-for-byte against the C bootstrap oracle, so a wrong byte value/order in
# the fast encoder is caught too. Distinct byte patterns (zero+0xFF mix, all
# 0xFF, all-distinct-ascending) guard against a value-fitted or endianness bug.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
HERBERT="${HERBERT:-$repo_root/build/herbert}"
backend="$repo_root/stack/native_compile_fragment.herb"
fixtures="$script_dir/fixtures/link16"
# Wall-clock bound on a single large-literal PROBE compile (the gen-1 native
# compiler encoding the probe's literal -- the exact path throne fixes). NOT the
# one-time gen-1 mint: that is a separate, helper-invariant step (the C bootstrap
# compiling the backend, bounded by NATIVE_SELF_TIMEOUT in native_codegen_oracle.sh)
# and is unaffected by reverting nc_div256/nc_mod256. The real (post-throne) probe
# compile is well under a second; the pre-throne O(value) encoder never finishes.
# Generous (machine-independent) so a loaded CI runner cannot false-positive, but
# finite so the regression bites. timeout returns early on success, so this costs
# the bound only when a probe compile actually hangs.
compile_bound="${THRONE_COMPILE_TIMEOUT:-20s}"

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
native_codegen_oracle_begin link16 || exit 1

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
native_codegen_ensure_compiler "$tmp/native-compiler" || exit 1
pass=0
fail=0

fail_test() {
    echo "FAIL: stack/native_compile_fragment.herb ($1)"
    fail=$((fail + 1))
}

# Compile a probe with the gen-1 compiler under a wall-clock BOUND. timeout
# returns 124 if the bound is exceeded -- THAT is the throne forcing bite: the
# old O(value) PUSH_INT encoder hangs on a large literal. On success the
# compiler writes a byte-pure "a.out" (do fwriter); harvest it (ELF magic
# checked) from a per-label scratch dir.
compile_probe_bounded() {
    local label="$1" probe="$2" elf="$3"
    local cdir="$tmp/$label.compile.d"
    rm -rf "$cdir"; mkdir -p "$cdir"
    ( cd "$cdir" && timeout "$compile_bound" "$NATIVE_CODEGEN_COMPILER" <"$probe" >"$tmp/$label.compile.out" 2>"$tmp/$label.compile.err" )
    local crc=$?
    if [[ $crc -eq 124 ]]; then
        fail_test "compile $label EXCEEDED ${compile_bound} bound -- large-literal O(value) encoder regression (D15/throne)"
        return 1
    fi
    if [[ ! -f "$cdir/a.out" ]]; then
        fail_test "compile $label rejected/no a.out (rc=$crc): stdout=$(head -1 "$tmp/$label.compile.out") stderr=$(head -1 "$tmp/$label.compile.err")"
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

# Bounded large-literal accept probe: compile within the bound, then require the
# compiled program's canonical-decimal stdout to equal the C oracle's, byte for
# byte (one sub-test: bounded compile + byte-exact correctness together).
check_bounded() {
    local label="$1" probe="$2" input="$3"
    local elf="$tmp/$label.elf"
    compile_probe_bounded "$label" "$probe" "$elf" || return
    if ! oracle_expect_le64 "link16_${label}" "$probe" "$input" "$tmp/$label.expected"; then
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

# The probes ignore stdin; a single empty input feeds them all.
: >"$tmp/in_empty"
check_bounded big_addr  "$fixtures/big_addr.herb"  "$tmp/in_empty"
check_bounded max_u64   "$fixtures/max_u64.herb"   "$tmp/in_empty"
check_bounded seq_bytes "$fixtures/seq_bytes.herb" "$tmp/in_empty"

echo ""
if [[ $fail -ne 0 ]]; then
    echo "$fail of $((pass + fail)) native-codegen-link16 sub-test(s) failed."
    exit 1
fi
if ! native_codegen_oracle_finish; then
    exit 1
fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link16: $pass sub-tests: bounded large-literal PUSH_INT encoding -- 0xFFFFFFFF80000000 (higher-half kernel base), 2^64-1, 0x0102030405060708 -- each compiles within ${compile_bound} (an O(value) hang pre-throne) and renders byte-exact canonical decimal vs C (D15))"
exit 0
