#!/usr/bin/env bash
# Native codegen Link 13: accepted-program native runtime faults must match the
# C bootstrap's stdout, stderr, and exit status for located index/get/append OOB.
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

source "$script_dir/native_codegen_oracle.sh"
native_codegen_oracle_begin link13 || exit 1

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
pass=0
fail=0

fail_test() {
    echo "FAIL: stack/native_compile_fragment.herb ($1)"
    fail=$((fail + 1))
}

compile_probe() {
    local label="$1" probe="$2" elf="$3"
    local cdir="$tmp/$label.compile.d"
    rm -rf "$cdir"; mkdir -p "$cdir"
    ( cd "$cdir" && "$HERBERT" "$backend" <"$probe" >"$tmp/$label.compile.out" 2>"$tmp/$label.compile.err" )
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

check_stdio_exit() {
    local label="$1" probe="$2"
    local elf="$tmp/$label.elf" expected="$tmp/$label.expected" actual="$tmp/$label.actual"
    local n_out="$tmp/$label.native.stdout" n_err="$tmp/$label.native.stderr" empty="$tmp/empty.stdin"
    : >"$empty"
    compile_probe "$label" "$probe" "$elf" || return
    "$elf" <"$empty" >"$n_out" 2>"$n_err"
    local n_rc=$?
    native_codegen_oracle_pack_stdio_exit "$n_rc" "$n_out" "$n_err" "$actual" || {
        fail_test "$label: native envelope pack failed"
        return
    }
    if ! oracle_expect_stdio_exit "link13_${label}" "$probe" "$empty" "$expected"; then
        fail_test "$label: stdio+exit oracle failed"
        return
    fi
    if cmp -s "$expected" "$actual"; then
        pass=$((pass + 1))
    else
        fail_test "$label: native stdio+exit envelope differs (expected $(xxd -p "$expected" | tr -d '\n') got $(xxd -p "$actual" | tr -d '\n'))"
    fi
}

hex_lit() {
    printf '%s' "$1" | xxd -p | tr -d '\n'
}

check_disasm_gate() {
    local index_elf="$tmp/index_oob.disasm.elf"
    local get_elf="$tmp/get_oob.disasm.elf"
    local append_elf="$tmp/append_256.disasm.elf"
    compile_probe disasm_index "$tmp/index_oob.herb" "$index_elf" || return
    compile_probe disasm_get "$tmp/get_oob.herb" "$get_elf" || return
    compile_probe disasm_append "$tmp/append_256.herb" "$append_elf" || return

    local index_hex get_hex append_hex all_hex silent
    index_hex=$(xxd -p "$index_elf" | tr -d '\n')
    get_hex=$(xxd -p "$get_elf" | tr -d '\n')
    append_hex=$(xxd -p "$append_elf" | tr -d '\n')
    all_hex="${index_hex}${get_hex}${append_hex}"
    silent="b8e7000000bf010000000f05"

    local gate_ok=1
    [[ "$index_hex" == *"595a5e4839d1720c49c7c202000000e9"* ]] || { fail_test "disasm gate: index OOB branch does not route through line+jmp stub"; gate_ok=0; }
    [[ "$index_hex" != *"595a5e4839d1720c${silent}"* ]] || { fail_test "disasm gate: index OOB branch still reaches silent trap"; gate_ok=0; }
    [[ "$get_hex" == *"5941584d8b084c39c9720c49c7c204000000e9"* ]] || { fail_test "disasm gate: get OOB branch does not route through line+jmp stub"; gate_ok=0; }
    [[ "$get_hex" != *"5941584d8b084c39c9720c${silent}"* ]] || { fail_test "disasm gate: get OOB branch still reaches silent trap"; gate_ok=0; }
    [[ "$append_hex" == *"594881f9ff000000760c49c7c203000000e9"* ]] || { fail_test "disasm gate: append OOB branch does not route through line+jmp stub"; gate_ok=0; }
    [[ "$append_hex" != *"594881f9ff000000760c${silent}"* ]] || { fail_test "disasm gate: append OOB branch still reaches silent trap"; gate_ok=0; }
    [[ "$append_hex" == *"$silent"* ]] || { fail_test "disasm gate: resource silent trap signature disappeared"; gate_ok=0; }
    [[ "$all_hex" == *"bf02000000"* ]] || { fail_test "disasm gate: fd=2 write syscall signature missing"; gate_ok=0; }
    [[ "$all_hex" == *"48f7f1"* ]] || { fail_test "disasm gate: div-based decimal renderer missing"; gate_ok=0; }

    local frag
    for frag in \
        "herbert: line " \
        ": index: position " \
        ": get: position " \
        ": append: byte value " \
        " out of range (length " \
        " out of range (count " \
        " out of range 0..255"; do
        [[ "$all_hex" == *"$(hex_lit "$frag")"* ]] || { fail_test "disasm gate: rodata fragment missing: $frag"; gate_ok=0; }
    done
    [[ "$all_hex" == *"$(printf ')\n' | xxd -p | tr -d '\n')"* ]] || { fail_test "disasm gate: close-paren newline fragment missing"; gate_ok=0; }

    if [[ $gate_ok -eq 1 ]]; then
        pass=$((pass + 1))
    fi
}

cat >"$tmp/index_oob.herb" <<'HERB'
func main():
    return index("abc", 3)
end
HERB

cat >"$tmp/get_oob.herb" <<'HERB'
func main():
    let a = new_array(int)
    do add(a, 7)
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

cat >"$tmp/partial_stdout_then_fault.herb" <<'HERB'
func main():
    do flogger("pre")
    let b = new_buffer()
    do append(b, 256)
    return 0
end
HERB

cat >"$tmp/large_index_oob.herb" <<'HERB'
func main():
    return index("ab", 1000000)
end
HERB

check_stdio_exit index_oob "$tmp/index_oob.herb"
check_stdio_exit get_oob "$tmp/get_oob.herb"
check_stdio_exit append_256 "$tmp/append_256.herb"
check_stdio_exit partial_stdout_then_fault "$tmp/partial_stdout_then_fault.herb"
check_stdio_exit large_index_oob "$tmp/large_index_oob.herb"
check_disasm_gate

echo ""
if [[ $fail -ne 0 ]]; then
    echo "$fail of $((pass + fail)) native-codegen-link13 sub-test(s) failed."
    exit 1
fi
if ! native_codegen_oracle_finish; then
    exit 1
fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link13: $pass sub-tests: stdio+exit parity for index/get/append faults, partial stdout, large decimal renderer, fd=2/div/routing disasm gate)"
exit 0
