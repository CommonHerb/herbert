#!/usr/bin/env bash
# Native codegen Link 3 test: control flow, bools, not, and short-circuit
# compile to native x86-64 branches and match the real C bootstrap oracle.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
HERBERT="${HERBERT:-$repo_root/build/herbert}"
backend="$repo_root/stack/native_compile_fragment.herb"

if [[ ! -x "$HERBERT" ]]; then
    echo "FAIL: stack/native_compile_fragment.herb (cannot find herbert at $HERBERT)"
    exit 1
fi
if [[ ! -f "$backend" ]]; then
    echo "FAIL: stack/native_compile_fragment.herb (missing backend)"
    exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0
total=0

fail_test() {
    echo "FAIL: stack/native_compile_fragment.herb ($1)"
    fail=$((fail + 1))
}

write_rt() {
    local path="$1"
    shift
    : >"$path"
    local b
    for b in "$@"; do
        LC_ALL=C printf "\\$(printf '%03o' "$b")" >>"$path"
    done
}

oracle_le64() {
    local probe_file="$1"
    local rt_file="$2"
    local out_file="$3"
    local c_out
    if ! c_out=$("$HERBERT" "$probe_file" < "$rt_file" 2>/dev/null); then
        return 1
    fi
    local val
    if [[ "$c_out" == "true" ]]; then
        val=1
    elif [[ "$c_out" == "false" ]]; then
        val=0
    else
        val="$c_out"
    fi
    python3 - "$val" "$out_file" <<'PY'
import struct
import sys
val = int(sys.argv[1])
with open(sys.argv[2], "wb") as f:
    f.write(struct.pack("<Q", val & 0xFFFFFFFFFFFFFFFF))
PY
}

compile_probe() {
    local name="$1"
    local probe="$tmp/$name.herb"
    local out="$tmp/$name.compile.out"
    local err="$tmp/$name.compile.err"
    local elf="$tmp/$name.elf"
    "$HERBERT" "$backend" < "$probe" >"$out" 2>"$err"
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "FAIL: stack/native_compile_fragment.herb (compile $name failed: $(head -1 "$err"))"
        exit 1
    fi
    if grep -qE 'native-subset|ERR 4[0-9][0-9]' "$out"; then
        echo "FAIL: stack/native_compile_fragment.herb (compile $name: unexpected rejection: $(head -1 "$out"))"
        exit 1
    fi
    cp "$out" "$elf"
    chmod +x "$elf"
}

cat >"$tmp/p_if.herb" <<'HERB'
func main():
    let input = clogger()
    let a = index(input,0)
    let b = index(input,1)
    let out = 0
    if a < b:
        out = 10
    elif a == b:
        out = 20
    elif a > 250:
        out = 30
    else:
        out = 40
    end
    return out
end
HERB

cat >"$tmp/p_bool.herb" <<'HERB'
func main():
    let input = clogger()
    let a = index(input,0) == 0
    let b = index(input,1) == 0
    let out = false
    if (not a) or (a and b):
        out = true
    else:
        out = false
    end
    return out
end
HERB

compile_probe p_if
compile_probe p_bool

run_diff() {
    local probe_name="$1"
    local b0="$2"
    local b1="$3"
    local label="differential $probe_name b0=0x$(printf '%02x' "$b0") b1=0x$(printf '%02x' "$b1")"
    total=$((total + 1))
    local rt="$tmp/rt_${probe_name}_${b0}_${b1}.bin"
    local actual="$tmp/actual_${probe_name}_${b0}_${b1}.bin"
    local expected="$tmp/expected_${probe_name}_${b0}_${b1}.bin"
    write_rt "$rt" "$b0" "$b1"
    if ! oracle_le64 "$tmp/$probe_name.herb" "$rt" "$expected"; then
        fail_test "$label (C bootstrap oracle failed)"
        return
    fi
    if ! "$tmp/$probe_name.elf" <"$rt" >"$actual" 2>/dev/null; then
        fail_test "$label (native exit non-zero)"
        return
    fi
    if ! cmp -s "$expected" "$actual"; then
        fail_test "$label (LE64 mismatch: expected $(xxd -p "$expected" | tr -d '\n') got $(xxd -p "$actual" | tr -d '\n'))"
        return
    fi
    pass=$((pass + 1))
}

for pair in "0 1" "1 0" "127 128" "128 127" "255 1" "1 255" "255 255"; do
    # shellcheck disable=SC2086
    run_diff p_if $pair
done

for pair in "0 0" "0 1" "1 0" "1 1" "127 128" "255 1" "1 255"; do
    # shellcheck disable=SC2086
    run_diff p_bool $pair
done

check_reject() {
    local label="$1"
    local probe_file="$2"
    total=$((total + 1))
    local out="$tmp/reject_${label}.out"
    local err="$tmp/reject_${label}.err"
    "$HERBERT" "$backend" <"$probe_file" >"$out" 2>"$err"
    if grep -qE 'ERR 4[0-9][0-9]' "$out"; then
        pass=$((pass + 1))
    else
        fail_test "reject $label: expected 4xx diagnostic, stdout: $(head -1 "$out"), stderr: $(head -1 "$err")"
    fi
}

cat >"$tmp/r_if_int.herb" <<'HERB'
func main():
    if 1:
        return 1
    else:
        return 0
    end
end
HERB
cat >"$tmp/r_elif_int.herb" <<'HERB'
func main():
    if false:
        return 0
    elif 1:
        return 1
    else:
        return 2
    end
end
HERB
cat >"$tmp/r_not_int.herb" <<'HERB'
func main():
    return not 1
end
HERB
cat >"$tmp/r_and_int.herb" <<'HERB'
func main():
    return true and 1
end
HERB
cat >"$tmp/r_or_int.herb" <<'HERB'
func main():
    return false or 1
end
HERB
cat >"$tmp/r_add_bool.herb" <<'HERB'
func main():
    return true + 1
end
HERB
cat >"$tmp/r_sub_bool.herb" <<'HERB'
func main():
    return 1 - false
end
HERB
cat >"$tmp/r_lt_bool.herb" <<'HERB'
func main():
    return true < 1
end
HERB
cat >"$tmp/r_eq_bool.herb" <<'HERB'
func main():
    return 1 == false
end
HERB
cat >"$tmp/r_join.herb" <<'HERB'
func main():
    let x = 1
    if true:
        x = true
    end
    return x
end
HERB
cat >"$tmp/r_array.herb" <<'HERB'
func main():
    let a = new_array(int)
    return 0
end
HERB
cat >"$tmp/r_buffer.herb" <<'HERB'
func main():
    let b = new_buffer()
    return 0
end
HERB
cat >"$tmp/r_flogger.herb" <<'HERB'
func main():
    do flogger("x")
    return 0
end
HERB
cat >"$tmp/r_user_call.herb" <<'HERB'
func main():
    return helper()
end
HERB
cat >"$tmp/r_params.herb" <<'HERB'
func main(x):
    return x
end
HERB
cat >"$tmp/r_handle_escape.herb" <<'HERB'
func main():
    let input = clogger()
    return input
end
HERB
cat >"$tmp/r_handle_reassign.herb" <<'HERB'
func main():
    let input = clogger()
    input = 1
    return 0
end
HERB
cat >"$tmp/r_double_clogger.herb" <<'HERB'
func main():
    let a = clogger()
    let b = clogger()
    return index(a,0)
end
HERB

for item in \
    "if_int r_if_int" "elif_int r_elif_int" "not_int r_not_int" \
    "and_int r_and_int" "or_int r_or_int" "add_bool r_add_bool" \
    "sub_bool r_sub_bool" "lt_bool r_lt_bool" "eq_bool r_eq_bool" \
    "join r_join" "array r_array" \
    "buffer r_buffer" "flogger r_flogger" "user_call r_user_call" \
    "params r_params" "handle_escape r_handle_escape" \
    "handle_reassign r_handle_reassign" "double_clogger r_double_clogger"; do
    set -- $item
    check_reject "$1" "$tmp/$2.herb"
done

check_accept() {
    local label="$1"
    local probe="$2"
    local rt_hex="$3"
    total=$((total + 1))
    local out="$tmp/accept_${label}.out"
    local err="$tmp/accept_${label}.err"
    local elf="$tmp/accept_${label}.elf"
    local rt="$tmp/accept_${label}.rt"
    local actual="$tmp/accept_${label}.actual"
    local expected="$tmp/accept_${label}.expected"
    "$HERBERT" "$backend" <"$probe" >"$out" 2>"$err"
    if grep -qE 'native-subset|ERR 4[0-9][0-9]' "$out"; then
        fail_test "accept $label: unexpected rejection: $(head -1 "$out")"
        return
    fi
    cp "$out" "$elf"
    chmod +x "$elf"
    printf '%b' "$(echo "$rt_hex" | sed 's/\(..\)/\\x\1/g')" >"$rt"
    if ! oracle_le64 "$probe" "$rt" "$expected"; then
        fail_test "accept $label: C bootstrap oracle failed"
        return
    fi
    if ! "$elf" <"$rt" >"$actual" 2>/dev/null; then
        fail_test "accept $label: native exit non-zero"
        return
    fi
    if ! cmp -s "$expected" "$actual"; then
        fail_test "accept $label: expected $(xxd -p "$expected" | tr -d '\n') got $(xxd -p "$actual" | tr -d '\n')"
        return
    fi
    pass=$((pass + 1))
}

cat >"$tmp/a_bool_local.herb" <<'HERB'
func main():
    let b = true
    if b:
        return 7
    else:
        return 9
    end
end
HERB
cat >"$tmp/a_bool_lit.herb" <<'HERB'
func main():
    if false:
        return 7
    else:
        return 9
    end
end
HERB
cat >"$tmp/a_ret_true.herb" <<'HERB'
func main():
    return true
end
HERB
cat >"$tmp/a_ret_false.herb" <<'HERB'
func main():
    return false
end
HERB
cat >"$tmp/a_rebind.herb" <<'HERB'
func main():
    let x = 1
    x = (1 < 2)
    return x
end
HERB

check_accept bool_local "$tmp/a_bool_local.herb" ""
check_accept bool_literal "$tmp/a_bool_lit.herb" ""
check_accept ret_true "$tmp/a_ret_true.herb" ""
check_accept ret_false "$tmp/a_ret_false.herb" ""
check_accept rebind "$tmp/a_rebind.herb" ""

total=$((total + 1))
gate_ok=1
rh="$tmp/readelf-h.txt"
rl="$tmp/readelf-l.txt"
dump_if="$tmp/objdump_if.txt"
dump_bool="$tmp/objdump_bool.txt"

readelf -h "$tmp/p_bool.elf" >"$rh" 2>/dev/null || { fail_test "disassembly gate (readelf -h failed)"; gate_ok=0; }
readelf -l "$tmp/p_bool.elf" >"$rl" 2>/dev/null || { fail_test "disassembly gate (readelf -l failed)"; gate_ok=0; }
objdump -D -b binary -m i386:x86-64 --adjust-vma=0x400000 "$tmp/p_if.elf" >"$dump_if" 2>/dev/null || { fail_test "disassembly gate (objdump if failed)"; gate_ok=0; }
objdump -D -b binary -m i386:x86-64 --adjust-vma=0x400000 "$tmp/p_bool.elf" >"$dump_bool" 2>/dev/null || { fail_test "disassembly gate (objdump bool failed)"; gate_ok=0; }

if [[ $gate_ok -eq 1 ]]; then
    grep -Fq "Type:                              EXEC" "$rh" || { fail_test "disassembly gate (not EXEC)"; gate_ok=0; }
fi
if [[ $gate_ok -eq 1 ]]; then
    grep -Fq "Machine:                           Advanced Micro Devices X86-64" "$rh" || { fail_test "disassembly gate (not x86-64)"; gate_ok=0; }
fi
if [[ $gate_ok -eq 1 ]]; then
    grep -Fq "Entry point address:               0x400078" "$rh" || { fail_test "disassembly gate (entry != 0x400078)"; gate_ok=0; }
fi
if [[ $gate_ok -eq 1 ]]; then
    grep -Fq "Number of section headers:         0" "$rh" || { fail_test "disassembly gate (shnum != 0)"; gate_ok=0; }
fi
if [[ $gate_ok -eq 1 ]]; then
    grep -qE 'R E' "$rl" || { fail_test "disassembly gate (no R E LOAD segment)"; gate_ok=0; }
fi
if [[ $gate_ok -eq 1 ]]; then
    filesz=$(awk '/LOAD/ { getline; print $1; exit }' "$rl")
    memsz=$(awk '/LOAD/ { getline; print $2; exit }' "$rl")
    if [[ "$filesz" != "$memsz" ]]; then
        fail_test "disassembly gate (FileSiz=$filesz != MemSiz=$memsz)"
        gate_ok=0
    fi
fi
if [[ $gate_ok -eq 1 ]]; then
    filesz_dec=$(python3 -c "print(int('$filesz', 16))" 2>/dev/null)
    trailer=$(dd if="$tmp/p_bool.elf" bs=1 skip="$filesz_dec" count=2 2>/dev/null | xxd -p)
    if [[ "$trailer" != "300a" ]]; then
        fail_test "disassembly gate (trailer at $filesz not 0\\n, got '$trailer')"
        gate_ok=0
    fi
fi
if [[ $gate_ok -eq 1 ]]; then
    grep -qE '\bjmp\b' "$dump_if" || { fail_test "disassembly gate (no jmp)"; gate_ok=0; }
fi
if [[ $gate_ok -eq 1 ]]; then
    grep -qE '\b(jz|je)\b' "$dump_if" "$dump_bool" || { fail_test "disassembly gate (no jz/je)"; gate_ok=0; }
fi
if [[ $gate_ok -eq 1 ]]; then
    grep -qE '\b(jnz|jne)\b' "$dump_bool" || { fail_test "disassembly gate (no jnz/jne)"; gate_ok=0; }
fi
if [[ $gate_ok -eq 1 ]]; then
    grep -qE 'test\s+%rax,%rax' "$dump_bool" || { fail_test "disassembly gate (no test %rax,%rax)"; gate_ok=0; }
fi
if [[ $gate_ok -eq 1 ]]; then
    grep -qE 'mov\s+\(%rsp\),%rax' "$dump_bool" || { fail_test "disassembly gate (no BR_AND/OR peek)"; gate_ok=0; }
fi
if [[ $gate_ok -eq 1 ]]; then
    grep -qE 'add\s+\$0x8,%rsp' "$dump_bool" || { fail_test "disassembly gate (no BR_AND/OR pop)"; gate_ok=0; }
fi
if [[ $gate_ok -eq 1 ]]; then
    grep -qE 'sete\s+%al' "$dump_bool" || { fail_test "disassembly gate (no NOT sete)"; gate_ok=0; }
fi
if [[ $gate_ok -eq 1 ]]; then
    grep -qE 'movzbq\s+%al,%rax' "$dump_bool" || { fail_test "disassembly gate (no NOT movzbq)"; gate_ok=0; }
fi
if [[ $gate_ok -eq 1 ]]; then
    grep -qE 'push\s+\$0x0' "$dump_bool" || { fail_test "disassembly gate (no push $0)"; gate_ok=0; }
fi
if [[ $gate_ok -eq 1 ]]; then
    grep -qE 'push\s+\$0x1' "$dump_bool" || { fail_test "disassembly gate (no push $1)"; gate_ok=0; }
fi
if [[ $gate_ok -eq 1 ]]; then
    grep -qE 'set(b|be|a|ae|e|ne)\s+%dl' "$dump_if" || { fail_test "disassembly gate (no unsigned setcc)"; gate_ok=0; }
fi
if [[ $gate_ok -eq 1 ]]; then
    if grep -qE 'set(l|le|g|ge)\s+%dl' "$dump_if"; then
        fail_test "disassembly gate (signed setcc found)"
        gate_ok=0
    fi
fi
if [[ $gate_ok -eq 1 ]]; then
    grep -qE 'mov\s+\$0x1,%eax' "$dump_bool" || { fail_test "disassembly gate (no write syscall)"; gate_ok=0; }
fi
if [[ $gate_ok -eq 1 ]]; then
    grep -qE 'mov\s+\$0xe7,%eax' "$dump_bool" || { fail_test "disassembly gate (no exit_group)"; gate_ok=0; }
fi
if [[ $gate_ok -eq 1 ]]; then
    pass=$((pass + 1))
    echo "PASS: stack/native_compile_fragment.herb (disassembly gate: ELF EXEC/x86-64/0x400078/one-LOAD/FileSiz=MemSiz/trailer; jmp+jz+jnz; BR_AND/OR peek-pop; NOT; bool pushes; unsigned setcc; write+exit_group; clogger entry-stub call permitted since mercer Link 5)"
fi

echo ""
if [[ $fail -ne 0 ]]; then
    echo "$fail of $((pass + fail)) native-codegen-link3 sub-test(s) failed."
    exit 1
fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link3: $pass sub-tests: if/elif/else and bool/short-circuit differentials vs C bootstrap; 18-probe rejection battery; 5 anti-over-rejection probes; disassembly gate; string/tuple/inline-clogger/nonlit-index rejects retired -- in-subset at mercer Link 5)"
exit 0
