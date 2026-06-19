#!/usr/bin/env bash
# Native codegen Link 5 test: value types (strings + tuples), rodata,
# multi-word locals/args/returns, sret, aggregate TCO, and input arena.
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
native_codegen_oracle_begin link5 || exit 1

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
native_codegen_ensure_compiler "$tmp/native-compiler" || exit 1

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
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" <"$probe" >"$out" 2>"$err" )
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

check_reject_code() {
    local label="$1" code="$2" probe="$3"
    total=$((total + 1))
    local out="$tmp/reject_${label}.out" err="$tmp/reject_${label}.err"
    "$NATIVE_CODEGEN_COMPILER" <"$probe" >"$out" 2>"$err"
    if grep -q "ERR $code" "$out"; then
        pass=$((pass + 1))
    else
        fail_test "reject $label: expected ERR $code, stdout=$(head -1 "$out"), stderr=$(head -1 "$err")"
    fi
}

check_accept() {
    local label="$1" probe="$2" rt="$3"
    total=$((total + 1))
    local elf="$tmp/${label}.elf" expected="$tmp/${label}.expected" actual="$tmp/${label}.actual"
    if ! compile_probe "$label" "$probe" "$elf"; then
        return
    fi
    if ! oracle_le64 "$probe" "$rt" "$expected"; then
        fail_test "accept $label (C oracle failed)"
        return
    fi
    if ! "$elf" <"$rt" >"$actual" 2>/dev/null; then
        fail_test "accept $label (native failed)"
        return
    fi
    if ! cmp -s "$expected" "$actual"; then
        fail_test "accept $label (expected $(xxd -p "$expected" | tr -d '\n') got $(xxd -p "$actual" | tr -d '\n'))"
        return
    fi
    pass=$((pass + 1))
}

cat >"$tmp/diff.herb" <<'HERB'
func make(s):
    return (1, (s, length(s)), (7, (8, 9)))
end

func score(t):
    return length(t.1.0) + t.1.1 + t.2.1.0 + t.2.1.1
end

func main():
    let s = clogger()
    let t = make(s)
    let first = 5
    if length(s) == 0:
        first = 5
    else:
        first = index(s, 0)
    end
    let eqv = 400
    if equal(s, "A"):
        eqv = 100
    elif equal(s, "B"):
        eqv = 200
    elif equal(s, ""):
        eqv = 300
    end
    let lit = length("AZ") + index("AZ", 1)
    let v = score(t)
    return lit + v + first + eqv
end
HERB

: >"$tmp/empty.rt"
printf 'A' >"$tmp/A.rt"
printf 'B' >"$tmp/B.rt"
python3 - <<'PY' >"$tmp/long.rt"
import sys
sys.stdout.buffer.write(b"Z" * 300)
PY

compile_probe diff "$tmp/diff.herb" "$tmp/diff.elf"
run_diff "diff_empty" "$tmp/diff.herb" "$tmp/diff.elf" "$tmp/empty.rt"
run_diff "diff_A" "$tmp/diff.herb" "$tmp/diff.elf" "$tmp/A.rt"
run_diff "diff_B" "$tmp/diff.herb" "$tmp/diff.elf" "$tmp/B.rt"
run_diff "diff_300" "$tmp/diff.herb" "$tmp/diff.elf" "$tmp/long.rt"

run_runtime_fault() {
    local label="$1" probe="$2" rt="$3" compare_c="$4"
    total=$((total + 1))
    local elf="$tmp/${label}.elf" expected="$tmp/${label}.expected" n_out="$tmp/${label}.n.out"
    compile_probe "$label" "$probe" "$elf" || return
    "$elf" <"$rt" >"$n_out" 2>/dev/null
    local n_rc=$?
    if [[ "$compare_c" == "yes" ]]; then
        if ! oracle_expect_trap_stdout "link5_${label}" "$probe" "$rt" "$expected"; then
            fail_test "runtime $label (trap oracle failed)"
            return
        fi
        if [[ $n_rc -eq 0 ]] || ! cmp -s "$expected" "$n_out"; then
            fail_test "runtime $label (native rc=$n_rc stdout=$(xxd -p "$n_out" | tr -d '\n'))"
            return
        fi
    elif [[ $n_rc -eq 0 || -s "$n_out" ]]; then
        fail_test "runtime $label (native rc=$n_rc stdout=$(xxd -p "$n_out" | tr -d '\n'))"
        return
    fi
    pass=$((pass + 1))
}

cat >"$tmp/oob_input.herb" <<'HERB'
func main():
    let s = clogger()
    return index(s, 0)
end
HERB
cat >"$tmp/oob_lit.herb" <<'HERB'
func main():
    return index("a", 1)
end
HERB
run_runtime_fault empty_input_oob "$tmp/oob_input.herb" "$tmp/empty.rt" yes
run_runtime_fault literal_oob "$tmp/oob_lit.herb" "$tmp/empty.rt" yes
# (overcap 64 KiB native-fault retired at beaver: clogger now reads into the
#  heap, enlarged to ~2 GiB at tito. The capacity frontier lives in run_native_codegen_rejects.sh.)

cat >"$tmp/r_slice.herb" <<'HERB'
func main():
    return slice("abc", 0, 1)
end
HERB
cat >"$tmp/r_multi_clogger.herb" <<'HERB'
func main():
    let a = clogger()
    let b = clogger()
    return length(a) + length(b)
end
HERB
cat >"$tmp/r_helper_clogger.herb" <<'HERB'
func f():
    return clogger()
end
func main():
    return length(f())
end
HERB
cat >"$tmp/r_length_int.herb" <<'HERB'
func main():
    return length(1)
end
HERB
cat >"$tmp/r_index_key.herb" <<'HERB'
func main():
    return index("abc", "x")
end
HERB
cat >"$tmp/r_index_int.herb" <<'HERB'
func main():
    return index(1, 0)
end
HERB
cat >"$tmp/r_equal_mixed.herb" <<'HERB'
func main():
    return equal("a", 1)
end
HERB
cat >"$tmp/r_equal_tuple.herb" <<'HERB'
func main():
    return equal((1, 2), (1, 2))
end
HERB
cat >"$tmp/r_dot_range.herb" <<'HERB'
func main():
    return (1, "x").2
end
HERB
cat >"$tmp/r_dot_non.herb" <<'HERB'
func main():
    return 1.0
end
HERB
cat >"$tmp/r_rebind_width.herb" <<'HERB'
func main():
    let x = 1
    x = "hi"
    return x
end
HERB
# link11 renders flat int/bool tuples; link12 (D14) renders strings + NESTED
# tuples, so `return "x"` and `return (1, (2, 3))` now COMPILE. The remaining
# out-of-scope main return types are arrays/buffers and any aggregate CONTAINING
# one: a bare array (here) and a tuple with an array element (below) must ERR432.
cat >"$tmp/r_main_array.herb" <<'HERB'
func main():
    let xs = new_array(int)
    return xs
end
HERB
cat >"$tmp/r_main_arr_elem.herb" <<'HERB'
func main():
    return (1, new_array(int))
end
HERB

for item in \
    "slice 438 r_slice" \
    "multi_clogger 411 r_multi_clogger" "helper_clogger 404 r_helper_clogger" \
    "length_int 430 r_length_int" "index_key 430 r_index_key" "index_int 430 r_index_int" \
    "equal_mixed 430 r_equal_mixed" "equal_tuple 430 r_equal_tuple" \
    "dot_range 431 r_dot_range" "dot_non 431 r_dot_non" \
    "rebind_width 433 r_rebind_width" \
    "main_array 432 r_main_array" "main_arr_elem 432 r_main_arr_elem"; do
    set -- $item
    check_reject_code "$1" "$2" "$tmp/$3.herb"
done

cat >"$tmp/a_literal.herb" <<'HERB'
func main():
    return length("abc") + index("abc", 2)
end
HERB
cat >"$tmp/a_input_return.herb" <<'HERB'
func id(s):
    return s
end
func main():
    let s = id(clogger())
    return length(s)
end
HERB
cat >"$tmp/a_nested.herb" <<'HERB'
func main():
    let t = (1, (2, 30), 4)
    return t.1.0 + t.1.1
end
HERB
cat >"$tmp/a_wide.herb" <<'HERB'
func main():
    let t = (1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20)
    let u = (t,t,t,t,t,t,t)
    return u.6.19 + u.0.0
end
HERB
cat >"$tmp/a_sret_tail.herb" <<'HERB'
func done(a):
    return (a, 2)
end
func loop(n, a):
    if n == 0:
        return done(a)
    else:
        return loop(n - 1, a + 1)
    end
end
func main():
    let t = loop(10000, 5)
    return t.0 + t.1
end
HERB
check_accept literal "$tmp/a_literal.herb" "$tmp/empty.rt"
check_accept input_return "$tmp/a_input_return.herb" "$tmp/long.rt"
check_accept nested "$tmp/a_nested.herb" "$tmp/empty.rt"
check_accept wide_disp32 "$tmp/a_wide.herb" "$tmp/empty.rt"
check_accept sret_tail "$tmp/a_sret_tail.herb" "$tmp/empty.rt"

total=$((total + 1))
gate_ok=1
dump="$tmp/disasm.txt"
rl="$tmp/readelf-l.txt"
objdump -D -b binary -m i386:x86-64 --adjust-vma=0x400000 "$tmp/diff.elf" >"$dump" 2>/dev/null || { fail_test "disasm objdump failed"; gate_ok=0; }
readelf -l "$tmp/diff.elf" >"$rl" 2>/dev/null || { fail_test "readelf failed"; gate_ok=0; }
if [[ $gate_ok -eq 1 ]]; then grep -qE 'R E' "$rl" || { fail_test "disasm gate no R E LOAD"; gate_ok=0; }; fi
if [[ $gate_ok -eq 1 ]]; then grep -q '48 8d 35' <(xxd -p -c999 "$tmp/diff.elf" | sed 's/../& /g') || { fail_test "disasm gate no PUSH_STR lea"; gate_ok=0; }; fi
if [[ $gate_ok -eq 1 ]]; then grep -q '4e 0f b6' <(xxd -p -c999 "$tmp/diff.elf" | sed 's/../& /g') || { fail_test "disasm gate no EQUAL byte loop"; gate_ok=0; }; fi
if [[ $gate_ok -eq 1 ]]; then grep -q '4c 0f b6 04 0e' <(xxd -p -c999 "$tmp/diff.elf" | sed 's/../& /g') || { fail_test "disasm gate no INDEX movzx"; gate_ok=0; }; fi
if [[ $gate_ok -eq 1 ]]; then ! grep -q '0f be' <(xxd -p -c999 "$tmp/diff.elf" | sed 's/../& /g') || { fail_test "disasm gate found movsx"; gate_ok=0; }; fi
if [[ $gate_ok -eq 1 ]]; then
    # D12 byte-purity: emitted file is EXACTLY the page-padded image, no trailer.
    filesz=$(awk '/LOAD/ { getline; print $1; exit }' "$rl")
    filesz_dec=$(python3 -c "print(int('$filesz', 16))")
    actual_size=$(wc -c < "$tmp/diff.elf")
    [[ "$actual_size" -eq "$filesz_dec" ]] || { fail_test "byte-purity gate (file size $actual_size != image size $filesz_dec; trailer present?)"; gate_ok=0; }
fi
if [[ $gate_ok -eq 1 ]]; then
    pass=$((pass + 1))
    echo "PASS: stack/native_compile_fragment.herb (link5 disasm gate: rodata, byte loops, checked unsigned index, single RX LOAD, byte-pure size==image)"
fi

echo ""
if [[ $fail -ne 0 ]]; then
    echo "$fail of $((pass + fail)) native-codegen-link5 sub-test(s) failed."
    exit 1
fi
if ! native_codegen_oracle_finish; then
    exit 1
fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link5: $pass sub-tests: string/tuple differential, D13 traps, rejection battery, anti-over-rejection, disasm gate)"
exit 0
