#!/usr/bin/env bash
# Native codegen Link 6 test: native heap arrays/buffers/freeze, reference
# handles, grow/relocate, runtime traps, and disassembly invariants.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
HERBERT="${HERBERT:-$repo_root/build/herbert}"
backend="$repo_root/stack/native_compile_fragment.herb"

if [[ ! -x "$HERBERT" ]]; then
    echo "FAIL: stack/native_compile_fragment.herb (cannot find herbert at $HERBERT)"
    exit 1
fi

source "$script_dir/native_codegen_oracle.sh"
native_codegen_oracle_begin link6 || exit 1

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0
total=0

fail_test() {
    echo "FAIL: stack/native_compile_fragment.herb ($1)"
    fail=$((fail + 1))
}

oracle_le64() {
    local probe_file="$1" rt_file="$2" out_file="$3"
    oracle_expect_le64 "$(native_codegen_oracle_case_id "$out_file")" "$probe_file" "$rt_file" "$out_file"
}

compile_probe() {
    local label="$1" probe="$2" elf="$3"
    local out="$tmp/${label}.out" err="$tmp/${label}.err"
    # D12: compiler emits its ELF to a byte-pure file "a.out" (do fwriter), not
    # stdout. Run in a per-label scratch dir; harvest that dir's a.out (no a.out
    # means rejected before the emit).
    local cdir="$tmp/${label}.cdir"
    rm -rf "$cdir"; mkdir -p "$cdir"
    ( cd "$cdir" && "$HERBERT" "$backend" <"$probe" >"$out" 2>"$err" )
    if [[ ! -f "$cdir/a.out" ]]; then
        fail_test "compile $label rejected/no a.out: $(head -1 "$out")"
        return 1
    fi
    cp "$cdir/a.out" "$elf"
    chmod +x "$elf"
}

run_diff() {
    local label="$1" probe="$2" elf="$3" rt="$4"
    total=$((total + 1))
    local expected="$tmp/${label}.expected" actual="$tmp/${label}.actual"
    if ! oracle_le64 "$probe" "$rt" "$expected"; then
        fail_test "$label (C oracle failed)"
        return
    fi
    if ! "$elf" <"$rt" >"$actual" 2>/dev/null; then
        fail_test "$label (native exit nonzero)"
        return
    fi
    if ! cmp -s "$expected" "$actual"; then
        fail_test "$label (expected $(xxd -p "$expected" | tr -d '\n') got $(xxd -p "$actual" | tr -d '\n'))"
        return
    fi
    pass=$((pass + 1))
}

check_accept() {
    local label="$1" probe="$2" rt="$3"
    total=$((total + 1))
    local elf="$tmp/${label}.elf"
    if ! compile_probe "$label" "$probe" "$elf"; then
        return
    fi
    run_diff "$label" "$probe" "$elf" "$rt"
    total=$((total - 1))
}

check_reject_code() {
    local label="$1" code="$2" probe="$3"
    total=$((total + 1))
    local out="$tmp/reject_${label}.out" err="$tmp/reject_${label}.err"
    "$HERBERT" "$backend" <"$probe" >"$out" 2>"$err"
    if grep -q "ERR $code" "$out"; then
        pass=$((pass + 1))
    else
        fail_test "reject $label: expected ERR $code, stdout=$(head -1 "$out"), stderr=$(head -1 "$err")"
    fi
}

check_runtime_parity() {
    local label="$1" probe="$2" rt="$3"
    total=$((total + 1))
    local elf="$tmp/${label}.elf" expected="$tmp/${label}.expected" n_out="$tmp/${label}.n.out"
    if ! compile_probe "$label" "$probe" "$elf"; then
        return
    fi
    "$elf" <"$rt" >"$n_out" 2>/dev/null
    local n_rc=$?
    if ! oracle_expect_trap_stdout "link6_${label}" "$probe" "$rt" "$expected"; then
        fail_test "runtime $label trap oracle failed"
        return
    fi
    if [[ $n_rc -eq 0 ]] || ! cmp -s "$expected" "$n_out"; then
        fail_test "runtime $label expected native trap stdout $(xxd -p "$expected" | tr -d '\n') (native rc=$n_rc stdout=$(xxd -p "$n_out" | tr -d '\n'))"
        return
    fi
    pass=$((pass + 1))
}

cat >"$tmp/diff.herb" <<'HERB'
func fill_int(a, i, n):
    if i >= n:
        return 0
    end
    do add(a, i)
    return fill_int(a, i + 1, n)
end
func sum_int(a, i, acc):
    if i >= count(a):
        return acc
    end
    return sum_int(a, i + 1, acc + get(a, i))
end
func fill_pair(a, i, n):
    if i >= n:
        return 0
    end
    do add(a, (i, i + 1))
    return fill_pair(a, i + 1, n)
end
func sum_pair(a, i, acc):
    if i >= count(a):
        return acc
    end
    let p = get(a, i)
    return sum_pair(a, i + 1, acc + p.0 + p.1)
end
func fill_tri(a, i, n):
    if i >= n:
        return 0
    end
    do add(a, (i, i + 1, i + 2))
    return fill_tri(a, i + 1, n)
end
func sum_tri(a, i, acc):
    if i >= count(a):
        return acc
    end
    let t = get(a, i)
    return sum_tri(a, i + 1, acc + t.0 + t.1 + t.2)
end
func fill_buf(b, i, n):
    if i >= n:
        return 0
    end
    do append(b, i + 1)
    return fill_buf(b, i + 1, n)
end
func sum_str(s, i, acc):
    if i >= length(s):
        return acc
    end
    return sum_str(s, i + 1, acc + index(s, i))
end
func main():
    let h = clogger()
    let n = 0
    if length(h) > 0:
        n = index(h, 0)
    end
    let a = new_array(int)
    let p = new_array((int, int))
    let t = new_array((int, int, int))
    let b = new_buffer()
    let w = fill_int(a, 0, n)
    let x = fill_pair(p, 0, n)
    let y = fill_tri(t, 0, n)
    let z = fill_buf(b, 0, n)
    let frozen = freeze(b)
    do append(b, 99)
    return sum_int(a, 0, 0) + sum_pair(p, 0, 0) + sum_tri(t, 0, 0) + sum_str(frozen, 0, 0) + count(a) + count(p) + count(t) + length(frozen)
end
HERB

: >"$tmp/empty.rt"
printf '\000' >"$tmp/00.rt"
printf '\001' >"$tmp/01.rt"
printf '\012' >"$tmp/0a.rt"
printf '\310' >"$tmp/c8.rt"

compile_probe diff "$tmp/diff.herb" "$tmp/diff.elf"
run_diff diff_empty "$tmp/diff.herb" "$tmp/diff.elf" "$tmp/empty.rt"
run_diff diff_00 "$tmp/diff.herb" "$tmp/diff.elf" "$tmp/00.rt"
run_diff diff_01 "$tmp/diff.herb" "$tmp/diff.elf" "$tmp/01.rt"
run_diff diff_0a "$tmp/diff.herb" "$tmp/diff.elf" "$tmp/0a.rt"
run_diff diff_c8 "$tmp/diff.herb" "$tmp/diff.elf" "$tmp/c8.rt"

cat >"$tmp/array_int_string.herb" <<'HERB'
func main():
    let a = new_array((int, string))
    do add(a, (7, "az"))
    let p = get(a, 0)
    return p.0 + length(p.1) + index(p.1, 1)
end
HERB
check_accept array_int_string "$tmp/array_int_string.herb" "$tmp/empty.rt"

cat >"$tmp/composite.herb" <<'HERB'
func fill_a(a, i, n):
    if i >= n:
        return 0
    end
    do add(a, i)
    return fill_a(a, i + 1, n)
end
func fill_b(b, i, n):
    if i >= n:
        return 0
    end
    do append(b, 1)
    return fill_b(b, i + 1, n)
end
func main():
    let h = clogger()
    let k = 0
    if length(h) > 0:
        k = index(h, 0)
    end
    let a = new_array(int)
    let b = new_buffer()
    let x = fill_a(a, 0, k)
    let y = fill_b(b, 0, k)
    let s = freeze(b)
    do append(b, 99)
    return count(a) + length(s) + 355
end
HERB
compile_probe composite "$tmp/composite.herb" "$tmp/composite.elf"
run_diff composite_empty "$tmp/composite.herb" "$tmp/composite.elf" "$tmp/empty.rt"
run_diff composite_01 "$tmp/composite.herb" "$tmp/composite.elf" "$tmp/01.rt"
run_diff composite_0a "$tmp/composite.herb" "$tmp/composite.elf" "$tmp/0a.rt"
run_diff composite_c8 "$tmp/composite.herb" "$tmp/composite.elf" "$tmp/c8.rt"

cat >"$tmp/anti_over.herb" <<'HERB'
func ret_arr(a):
    return a
end
func ret_buf(b):
    return b
end
func hold(n, a, b):
    if n == 0:
        return (a, b)
    end
    return hold(n - 1, a, b)
end
func main():
    let inner = new_array(int)
    do add(inner, 5)
    let aa = new_array(array(int))
    do add(aa, inner)
    let b = new_buffer()
    do append(b, 7)
    let ab = new_array(buffer)
    do add(ab, b)
    let t = hold(100, ret_arr(inner), ret_buf(b))
    return get(get(aa, 0), 0) + index(freeze(get(ab, 0)), 0) + get(t.0, 0) + index(freeze(t.1), 0)
end
HERB
check_accept anti_over "$tmp/anti_over.herb" "$tmp/empty.rt"

cat >"$tmp/r_add_mismatch.herb" <<'HERB'
func main():
    let a = new_array(int)
    do add(a, "x")
    return 0
end
HERB
cat >"$tmp/r_add_mismatch_renamed.herb" <<'HERB'
func main():
    let renamed = new_array(int)
    do add(renamed, "x")
    return 0
end
HERB
cat >"$tmp/r_get_non_array.herb" <<'HERB'
func main():
    return get(1, 0)
end
HERB
cat >"$tmp/r_count_non_array.herb" <<'HERB'
func main():
    return count(1)
end
HERB
cat >"$tmp/r_append_non_buffer.herb" <<'HERB'
func main():
    do append(1, 2)
    return 0
end
HERB
cat >"$tmp/r_append_non_buffer_renamed.herb" <<'HERB'
func main():
    let local = 1
    do append(local, 2)
    return 0
end
HERB
cat >"$tmp/r_freeze_non_buffer.herb" <<'HERB'
func main():
    return freeze(1)
end
HERB
cat >"$tmp/r_append_non_int.herb" <<'HERB'
func main():
    let b = new_buffer()
    do append(b, "x")
    return 0
end
HERB
cat >"$tmp/r_monomorph.herb" <<'HERB'
func main():
    let a = new_array(int)
    if true:
        a = new_array(string)
    end
    return 0
end
HERB
cat >"$tmp/r_bad_type.herb" <<'HERB'
func main():
    let a = new_array(widget)
    return 0
end
HERB
cat >"$tmp/r_len_buffer.herb" <<'HERB'
func main():
    return length(new_buffer())
end
HERB
cat >"$tmp/r_index_buffer.herb" <<'HERB'
func main():
    return index(new_buffer(), 0)
end
HERB
cat >"$tmp/r_equal_buffer.herb" <<'HERB'
func main():
    return equal(new_buffer(), new_buffer())
end
HERB
cat >"$tmp/r_slice.herb" <<'HERB'
func main():
    return slice("abc", 0, 1)
end
HERB
cat >"$tmp/r_main_string.herb" <<'HERB'
func main():
    return "x"
end
HERB
cat >"$tmp/r_main_tuple.herb" <<'HERB'
func main():
    return (1, 2)
end
HERB

check_reject_code add_mismatch 436 "$tmp/r_add_mismatch.herb"
check_reject_code add_mismatch_renamed 436 "$tmp/r_add_mismatch_renamed.herb"
check_reject_code get_non_array 435 "$tmp/r_get_non_array.herb"
check_reject_code count_non_array 435 "$tmp/r_count_non_array.herb"
check_reject_code append_non_buffer 437 "$tmp/r_append_non_buffer.herb"
check_reject_code append_non_buffer_renamed 437 "$tmp/r_append_non_buffer_renamed.herb"
check_reject_code freeze_non_buffer 437 "$tmp/r_freeze_non_buffer.herb"
check_reject_code append_non_int 430 "$tmp/r_append_non_int.herb"
check_reject_code monomorph 436 "$tmp/r_monomorph.herb"
check_reject_code bad_type 434 "$tmp/r_bad_type.herb"
check_reject_code len_buffer 438 "$tmp/r_len_buffer.herb"
check_reject_code index_buffer 438 "$tmp/r_index_buffer.herb"
check_reject_code equal_buffer 438 "$tmp/r_equal_buffer.herb"
check_reject_code slice 438 "$tmp/r_slice.herb"
check_reject_code main_string 432 "$tmp/r_main_string.herb"
check_reject_code main_tuple 432 "$tmp/r_main_tuple.herb"

total=$((total + 1))
awk '/^func main\(\):$/ { exit } { print }' "$backend" >"$tmp/missing_meta_driver.herb"
cat >>"$tmp/missing_meta_driver.herb" <<'HERB'
func main():
    let type_pool = nc_type_pool_new()
    let funcs = new_array((string, int, int, int, array((int, int, int)), array(int)))
    let code = new_array((int, int, int))
    do add(code, (28, 0, 0))
    do add(code, (21, 0, 0))
    let missing = new_array(int)
    do add(funcs, ("main", 0, 0, 0, code, missing))
    let strings = new_array(string)
    let prog = (funcs, strings, 0)
    let params = new_array(array(int))
    let returns = new_array(int)
    do add(params, new_array(int))
    do add(returns, nc_type_int())
    let sig = (params, returns)
    let r = nc_analyze_program(type_pool, prog, sig)
    return 0
end
HERB
"$HERBERT" "$tmp/missing_meta_driver.herb" >"$tmp/missing_meta.out" 2>"$tmp/missing_meta.err"
if grep -q "ERR 439" "$tmp/missing_meta.out"; then
    pass=$((pass + 1))
else
    fail_test "reject missing_new_array_metadata: expected ERR 439, stdout=$(head -1 "$tmp/missing_meta.out"), stderr=$(head -1 "$tmp/missing_meta.err")"
fi

cat >"$tmp/oob.herb" <<'HERB'
func main():
    let a = new_array(int)
    do add(a, 1)
    return get(a, 1)
end
HERB
cat >"$tmp/append_256.herb" <<'HERB'
func main():
    let b = new_buffer()
    do append(b, 256)
    return 0
end
HERB
check_runtime_parity get_oob "$tmp/oob.herb" "$tmp/empty.rt"
check_runtime_parity append_256 "$tmp/append_256.herb" "$tmp/empty.rt"

total=$((total + 1))
gate_ok=1
dump="$tmp/diff.disasm"
hex="$tmp/diff.hex"
objdump -D -b binary -m i386:x86-64 --adjust-vma=0x400000 "$tmp/diff.elf" >"$dump" 2>/dev/null || { fail_test "disasm objdump failed"; gate_ok=0; }
xxd -p -c999 "$tmp/diff.elf" | sed 's/../& /g' >"$hex"
if [[ $gate_ok -eq 1 ]]; then grep -q '48 c7 c0 09 00 00 00' "$hex" || { fail_test "disasm gate no mmap syscall 9"; gate_ok=0; }; fi
if [[ $gate_ok -eq 1 ]]; then grep -q '49 c7 c2 22 00 00 00' "$hex" || { fail_test "disasm gate no r10 MAP_PRIVATE|ANON"; gate_ok=0; }; fi
if [[ $gate_ok -eq 1 ]]; then grep -q '49 c7 c0 ff ff ff ff' "$hex" || { fail_test "disasm gate no r8 -1 fd"; gate_ok=0; }; fi
if [[ $gate_ok -eq 1 ]]; then grep -q '49 89 c6' "$hex" || { fail_test "disasm gate no r14 heap bump"; gate_ok=0; }; fi
if [[ $gate_ok -eq 1 ]]; then grep -q '48 c7 c6 00 f0 ff 7f' "$hex" || { fail_test "disasm gate no rsi 2GiB mmap size (tito)"; gate_ok=0; }; fi
if [[ $gate_ok -eq 1 ]]; then grep -q '4c 8d b8 00 f0 ff 7f' "$hex" || { fail_test "disasm gate no r15 heap limit (tito 2GiB cap)"; gate_ok=0; }; fi
if [[ $gate_ok -eq 1 ]]; then grep -q '49 89 40 10' "$hex" || { fail_test "disasm gate no grow backing rewrite"; gate_ok=0; }; fi
if [[ $gate_ok -eq 1 ]]; then grep -q '48 8b 34 ca' "$hex" || { fail_test "disasm gate no array qword copy load"; gate_ok=0; }; fi
if [[ $gate_ok -eq 1 ]]; then grep -q '48 89 34 c8' "$hex" || { fail_test "disasm gate no array qword copy store"; gate_ok=0; }; fi
if [[ $gate_ok -eq 1 ]]; then grep -Eq '40 8a 3c 32|41 8a 3c 0a' "$hex" || { fail_test "disasm gate no byte copy loop"; gate_ok=0; }; fi
if [[ $gate_ok -eq 1 ]]; then grep -q '69 f1 18 00 00 00' "$hex" || { fail_test "disasm gate no general width-3 imul stride"; gate_ok=0; }; fi
if [[ $gate_ok -eq 1 ]]; then grep -q '72 0c' "$hex" || { fail_test "disasm gate no unsigned GET jb"; gate_ok=0; }; fi
if [[ $gate_ok -eq 1 ]]; then grep -q '76 0c' "$hex" || { fail_test "disasm gate no unsigned BUF_APPEND jbe"; gate_ok=0; }; fi
if [[ $gate_ok -eq 1 ]]; then ! grep -q '0f be' "$hex" || { fail_test "disasm gate found movsx"; gate_ok=0; }; fi
if [[ $gate_ok -eq 1 ]]; then
    pass=$((pass + 1))
    echo "PASS: stack/native_compile_fragment.herb (link6 disasm gate: mmap heap, grow indirection, word/byte copies, imul stride, unsigned traps)"
fi

echo ""
if [[ $fail -ne 0 ]]; then
    echo "$fail of $((pass + fail)) native-codegen-link6 sub-test(s) failed."
    exit 1
fi
if ! native_codegen_oracle_finish; then
    exit 1
fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link6: $pass sub-tests: heap differential, composite, rejects, runtime traps, anti-over-rejection, renamed twins, disasm gate)"
exit 0
