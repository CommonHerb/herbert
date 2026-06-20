#!/usr/bin/env bash
# Native codegen Link 7 test: native value output via flogger, byte-for-byte
# payload parity against the C bootstrap, exact reject codes, and a decisive
# white-box gate for the 44-byte looping write lowering.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
HERBERT="${HERBERT:-$repo_root/build/herbert}"
backend="$repo_root/stack/native_compile_fragment.herb"

if [[ "${NATIVE_CODEGEN_ORACLE:-golden}" == "c" && ! -x "$HERBERT" ]]; then
    echo "FAIL: stack/native_compile_fragment.herb (cannot find herbert at $HERBERT)"
    exit 1
fi
if [[ ! -f "$backend" ]]; then
    echo "FAIL: stack/native_compile_fragment.herb (missing backend)"
    exit 1
fi

source "$script_dir/native_codegen_oracle.sh"
native_codegen_oracle_begin link7 || exit 1

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
native_codegen_ensure_compiler "$tmp/native-compiler" || exit 1

pass=0
fail=0
total=0

loop_hex='5a5e4885d27425b801000000bf010000000f054885c07e084801c64829c2ebe2b8e7000000bf010000000f05'
ret0_tail_hex="${loop_hex}48b800000000000000005058c9c3"

fail_test() {
    echo "FAIL: stack/native_compile_fragment.herb ($1)"
    fail=$((fail + 1))
}

write_rt_hex() {
    local hex="$1"
    local out="$2"
    python3 - "$hex" "$out" <<'PY'
import sys
data = bytes.fromhex(sys.argv[1])
open(sys.argv[2], "wb").write(data)
PY
}

compile_probe() {
    local label="$1"
    local probe="$2"
    local elf="$3"
    local out="$tmp/${label}.compile.out"
    local err="$tmp/${label}.compile.err"
    # D12: the compiler emits its ELF to a byte-pure file "a.out" (do fwriter),
    # not stdout. Run it in a per-label scratch dir and harvest that dir's a.out.
    # (NB: the smug PROBES below still write their flogger payload to STDOUT when
    # run -- that is the probe's output, unrelated to the compiler's a.out.)
    local cdir="$tmp/${label}.cdir"
    rm -rf "$cdir"; mkdir -p "$cdir"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" <"$probe" >"$out" 2>"$err" )
    if [[ ! -f "$cdir/a.out" ]]; then
        fail_test "compile $label rejected or did not emit a.out: stdout=$(head -1 "$out"), stderr=$(head -1 "$err")"
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

strip_c_payload() {
    local in="$1"
    local out="$2"
    local size
    size=$(wc -c <"$in")
    if (( size < 2 )); then
        return 1
    fi
    head -c $((size - 2)) "$in" >"$out"
}

strip_native_payload() {
    local in="$1"
    local out="$2"
    local size
    size=$(wc -c <"$in")
    if (( size < 2 )); then
        return 1
    fi
    head -c $((size - 2)) "$in" >"$out"
}

run_payload_diff() {
    local label="$1"
    local probe="$2"
    local elf="$3"
    local rt="$4"
    total=$((total + 1))
    local n_out="$tmp/${label}.n.out"
    local expected_payload="$tmp/${label}.expected.payload"
    local n_payload="$tmp/${label}.n.payload"

    oracle_expect_payload "link7_${label}" "$probe" "$rt" "$expected_payload" || { fail_test "$label payload oracle failed"; return; }
    "$elf" <"$rt" >"$n_out" 2>/dev/null || { fail_test "$label native failed"; return; }
    [[ "$(tail -c2 "$n_out" | xxd -p | tr -d '\n')" == "300a" ]] || { fail_test "$label native trailer"; return; }
    strip_native_payload "$n_out" "$n_payload" || { fail_test "$label native payload strip"; return; }
    if ! cmp -s "$expected_payload" "$n_payload"; then
        fail_test "$label payload mismatch: expected=$(xxd -p "$expected_payload" | tr -d '\n') native=$(xxd -p "$n_payload" | tr -d '\n')"
        return
    fi
    pass=$((pass + 1))
}

oracle_le64() {
    local probe_file="$1"
    local rt_file="$2"
    local out_file="$3"
    oracle_expect_le64 "$(native_codegen_oracle_case_id "$out_file")" "$probe_file" "$rt_file" "$out_file"
}

run_return_diff() {
    local label="$1"
    local probe="$2"
    local rt="$3"
    total=$((total + 1))
    local elf="$tmp/${label}.elf"
    local expected="$tmp/${label}.expected"
    local actual="$tmp/${label}.actual"
    compile_probe "$label" "$probe" "$elf" || return
    oracle_le64 "$probe" "$rt" "$expected" || { fail_test "$label C oracle failed"; return; }
    "$elf" <"$rt" >"$actual" 2>/dev/null || { fail_test "$label native failed"; return; }
    if ! cmp -s "$expected" "$actual"; then
        fail_test "$label return mismatch: expected=$(xxd -p "$expected" | tr -d '\n') actual=$(xxd -p "$actual" | tr -d '\n')"
        return
    fi
    pass=$((pass + 1))
}

check_reject_code() {
    local label="$1"
    local code="$2"
    local probe="$3"
    total=$((total + 1))
    local out="$tmp/reject_${label}.out"
    local err="$tmp/reject_${label}.err"
    "$NATIVE_CODEGEN_COMPILER" <"$probe" >"$out" 2>"$err"
    local magic
    magic=$(head -c4 "$out" | xxd -p | tr -d '\n')
    if [[ "$magic" == "7f454c46" ]]; then
        fail_test "reject $label: unexpectedly emitted ELF"
        return
    fi
    if grep -q "ERR 438" "$out"; then
        fail_test "reject $label: obsolete ERR 438 surfaced"
        return
    fi
    if grep -q "ERR $code" "$out"; then
        pass=$((pass + 1))
    else
        fail_test "reject $label: expected ERR $code, stdout=$(head -1 "$out"), stderr=$(head -1 "$err")"
    fi
}

count_loop_hex() {
    local elf="$1"
    local hex
    hex=$(xxd -p -c999999 "$elf" | tr -d '\n')
    grep -o "$loop_hex" <<<"$hex" | wc -l | tr -d ' '
}

check_disasm_gate() {
    local one_probe="$1"
    local multi_probe="$2"
    total=$((total + 1))
    local one_elf="$tmp/disasm_one.elf"
    local multi_elf="$tmp/disasm_multi.elf"
    local hex count multi_count
    compile_probe "disasm_one" "$one_probe" "$one_elf" || return
    compile_probe "disasm_multi" "$multi_probe" "$multi_elf" || return
    hex=$(xxd -p -c999999 "$one_elf" | tr -d '\n')
    count=$(grep -o "$loop_hex" <<<"$hex" | wc -l | tr -d ' ')
    if [[ "$count" != "1" ]]; then
        fail_test "flogger loop absent/duplicated in one-flogger ELF: count=$count"
        return
    fi
    if ! grep -q "$ret0_tail_hex" <<<"$hex"; then
        fail_test "one-flogger loop not immediately followed by push_int 0; ret"
        return
    fi
    if grep -Eq '41|49|4c|4d' <<<"$loop_hex"; then
        fail_test "flogger loop touches r12/r13/r14/r15"
        return
    fi
    multi_count=$(count_loop_hex "$multi_elf")
    if [[ "$multi_count" != "3" ]]; then
        fail_test "multi-flogger ELF loop count: expected 3 got $multi_count"
        return
    fi
    pass=$((pass + 1))
    echo "PASS: stack/native_compile_fragment.herb (link7 disasm gate: one-flogger loop_count=$count, multi-flogger loop_count=$multi_count, tail=push_int0+ret, r12-r15=absent, exact loop required so single-write lowering fails)"
}

cat >"$tmp/literal.herb" <<'HERB'
func main():
    do flogger("HELLO\n")
    return 0
end
HERB

cat >"$tmp/data_dependent.herb" <<'HERB'
func main():
    let input = clogger()
    let b = new_buffer()
    if length(input) > 0:
        do append(b, index(input, 0))
    end
    if length(input) > 1:
        do append(b, index(input, 1))
    end
    do append(b, length(input))
    do flogger(freeze(b))
    return 0
end
HERB

cat >"$tmp/multi.herb" <<'HERB'
func main():
    do flogger("pre:")
    do flogger("")
    do flogger("post\n")
    return 0
end
HERB

cat >"$tmp/matrix.herb" <<'HERB'
func id_string(s):
    return s
end

func main():
    let local = "L"
    do flogger(local)
    do flogger(id_string("P"))
    let b = new_buffer()
    do append(b, 'F')
    do flogger(freeze(b))
    let t = ("T", 7)
    do flogger(t.0)
    let a = new_array(string)
    do add(a, "A")
    do flogger(get(a, 0))
    do flogger(clogger())
    return 0
end
HERB

cat >"$tmp/renamed_accept.herb" <<'HERB'
func renamed_echo(renamed_arg):
    return renamed_arg
end

func main():
    let renamed_local = renamed_echo("R")
    do flogger(renamed_local)
    return 0
end
HERB

cat >"$tmp/large.herb" <<'HERB'
func fill(b, i, n, v):
    if i >= n:
        return 0
    end
    do append(b, v)
    return fill(b, i + 1, n, v)
end

func main():
    let input = clogger()
    let v = 0
    if length(input) > 0:
        v = index(input, 0)
    end
    let b = new_buffer()
    let ignored = fill(b, 0, 1048576, v)
    do flogger(freeze(b))
    return 0
end
HERB

: >"$tmp/empty.rt"
printf 'A' >"$tmp/A.rt"
printf 'xy' >"$tmp/xy.rt"
printf 'C' >"$tmp/C.rt"
write_rt_hex "ab" "$tmp/ab.rt"

compile_probe literal "$tmp/literal.herb" "$tmp/literal.elf" && run_payload_diff literal "$tmp/literal.herb" "$tmp/literal.elf" "$tmp/empty.rt"
compile_probe data_dependent "$tmp/data_dependent.herb" "$tmp/data_dependent.elf" && {
    run_payload_diff data_dependent_A "$tmp/data_dependent.herb" "$tmp/data_dependent.elf" "$tmp/A.rt"
    run_payload_diff data_dependent_xy "$tmp/data_dependent.herb" "$tmp/data_dependent.elf" "$tmp/xy.rt"
}
compile_probe multi "$tmp/multi.herb" "$tmp/multi.elf" && run_payload_diff multi "$tmp/multi.herb" "$tmp/multi.elf" "$tmp/empty.rt"
compile_probe matrix "$tmp/matrix.herb" "$tmp/matrix.elf" && run_payload_diff matrix "$tmp/matrix.herb" "$tmp/matrix.elf" "$tmp/C.rt"
compile_probe renamed_accept "$tmp/renamed_accept.herb" "$tmp/renamed_accept.elf" && run_payload_diff renamed_accept "$tmp/renamed_accept.herb" "$tmp/renamed_accept.elf" "$tmp/empty.rt"

total=$((total + 1))
if compile_probe large "$tmp/large.herb" "$tmp/large.elf"; then
    "$tmp/large.elf" <"$tmp/ab.rt" >"$tmp/large.out" 2>/dev/null || { fail_test "large native failed"; }
    if [[ "$(tail -c2 "$tmp/large.out" | xxd -p | tr -d '\n')" != "300a" ]]; then
        fail_test "large native trailer"
    elif ! python3 - "$tmp/large.out" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
payload, trailer = data[:-2], data[-2:]
if len(payload) != 1048576 or trailer != b"0\n" or payload != b"\xab" * 1048576:
    raise SystemExit(1)
PY
    then
        fail_test "large output integrity"
    else
        pass=$((pass + 1))
    fi
fi

cat >"$tmp/r_flogger_int.herb" <<'HERB'
func main():
    do flogger(1)
    return 0
end
HERB
cat >"$tmp/r_flogger_bool.herb" <<'HERB'
func main():
    do flogger(true)
    return 0
end
HERB
cat >"$tmp/r_flogger_tuple.herb" <<'HERB'
func main():
    do flogger((1, 2))
    return 0
end
HERB
cat >"$tmp/r_flogger_array.herb" <<'HERB'
func main():
    let a = new_array(int)
    do flogger(a)
    return 0
end
HERB
cat >"$tmp/r_flogger_buffer.herb" <<'HERB'
func main():
    let b = new_buffer()
    do flogger(b)
    return 0
end
HERB
cat >"$tmp/r_flogger_zero.herb" <<'HERB'
func main():
    do flogger()
    return 0
end
HERB
cat >"$tmp/r_flogger_two.herb" <<'HERB'
func main():
    do flogger("a", "b")
    return 0
end
HERB
cat >"$tmp/r_return_flogger.herb" <<'HERB'
func main():
    return flogger("x")
end
HERB
cat >"$tmp/r_let_flogger.herb" <<'HERB'
func main():
    let x = flogger("x")
    return 0
end
HERB
cat >"$tmp/r_renamed_flogger_int.herb" <<'HERB'
func main():
    let renamed_value = 1
    do flogger(renamed_value)
    return 0
end
HERB

check_reject_code flogger_int 430 "$tmp/r_flogger_int.herb"
check_reject_code flogger_bool 430 "$tmp/r_flogger_bool.herb"
check_reject_code flogger_tuple 430 "$tmp/r_flogger_tuple.herb"
check_reject_code flogger_array 430 "$tmp/r_flogger_array.herb"
check_reject_code flogger_buffer 430 "$tmp/r_flogger_buffer.herb"
check_reject_code flogger_zero_arity 420 "$tmp/r_flogger_zero.herb"
check_reject_code flogger_two_arity 420 "$tmp/r_flogger_two.herb"
check_reject_code return_flogger 440 "$tmp/r_return_flogger.herb"
check_reject_code let_flogger 440 "$tmp/r_let_flogger.herb"
check_reject_code renamed_flogger_int 430 "$tmp/r_renamed_flogger_int.herb"

cat >"$tmp/cudois_positive.herb" <<'HERB'
func loop(n, acc):
    if n == 0:
        return acc
    end
    return loop(n - 1, acc + 1)
end

func main():
    return loop(1000, 7)
end
HERB
cat >"$tmp/mercer_positive.herb" <<'HERB'
func make(s):
    return (s, length(s))
end

func main():
    let t = make("AZ")
    return length(t.0) + index(t.0, 1) + t.1
end
HERB
cat >"$tmp/goddard_positive.herb" <<'HERB'
func main():
    let a = new_array(int)
    do add(a, 7)
    let b = new_buffer()
    do append(b, 8)
    let s = freeze(b)
    return get(a, 0) + index(s, 0) + count(a) + length(s)
end
HERB

run_return_diff cudois_positive "$tmp/cudois_positive.herb" "$tmp/empty.rt"
run_return_diff mercer_positive "$tmp/mercer_positive.herb" "$tmp/empty.rt"
run_return_diff goddard_positive "$tmp/goddard_positive.herb" "$tmp/empty.rt"

cat >"$tmp/disasm_one.herb" <<'HERB'
func main():
    do flogger("G")
    return 0
end
HERB

check_disasm_gate "$tmp/disasm_one.herb" "$tmp/multi.herb"

echo ""
if [[ $fail -ne 0 ]]; then
    echo "$fail of $((pass + fail)) native-codegen-link7 sub-test(s) failed."
    exit 1
fi
if ! native_codegen_oracle_finish; then
    exit 1
fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link7: $pass sub-tests: flogger payload accept matrix, large output smoke, exact reject codes, renamed twins, anti-over-rejection, decisive disasm gate)"
exit 0
