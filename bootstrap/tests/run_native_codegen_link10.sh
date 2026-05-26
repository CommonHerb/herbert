#!/usr/bin/env bash
# Native codegen Link 10 test (kanawha): complementary partially-resolved
# aggregate types merge during verifier fixpoint, while the compiler
# self-compile advances past the old ERR 436/433 cascade to the next frontier.
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

fail_test() {
    echo "FAIL: stack/native_compile_fragment.herb ($1)"
    fail=$((fail + 1))
}

le64() { python3 -c "import sys;sys.stdout.buffer.write(int(sys.argv[1]).to_bytes(8,'little'))" "$1"; }

compile_probe() {
    local label="$1" probe="$2" elf="$3"
    "$HERBERT" "$backend" <"$probe" >"$tmp/$label.o" 2>"$tmp/$label.e"
    local magic
    magic=$(head -c4 "$tmp/$label.o" | xxd -p | tr -d '\n')
    if [[ "$magic" != "7f454c46" ]]; then
        fail_test "compile $label rejected/no ELF: $(head -1 "$tmp/$label.o") $(head -1 "$tmp/$label.e")"
        return 1
    fi
    cp "$tmp/$label.o" "$elf"
    chmod +x "$elf"
    return 0
}

check_native_vs_c_int() {
    local label="$1" probe="$2" elf="$3" expected_int="$4"
    "$elf" >"$tmp/$label.native" 2>/dev/null
    local nrc=$?
    "$HERBERT" "$probe" >"$tmp/$label.c" 2>/dev/null
    local crc=$?
    local cval
    cval=$(tr -d '\n' <"$tmp/$label.c")
    le64 "$cval" >"$tmp/$label.cle"
    if [[ $nrc -eq 0 && $crc -eq 0 && "$cval" == "$expected_int" ]] && cmp -s "$tmp/$label.native" "$tmp/$label.cle"; then
        pass=$((pass + 1))
    else
        fail_test "$label: native rc=$nrc word=$(xxd -p "$tmp/$label.native" | tr -d '\n') vs C rc=$crc value=$cval expected=$expected_int"
    fi
}

cat >"$tmp/benign_complementary_if.herb" <<'HERB'
func left(a, x):
    do add(a, (x, 1))
    return a
end

func right(a, y):
    do add(a, (2, y))
    return a
end

func main():
    let a = new_array((int, int))
    a = left(a, 1)
    a = right(a, 2)
    return get(a, 0).0 + get(a, 1).1 + 1
end
HERB

compile_probe benign_complementary_if "$tmp/benign_complementary_if.herb" "$tmp/benign_complementary_if.elf" || true
if [[ -x "$tmp/benign_complementary_if.elf" ]]; then
    check_native_vs_c_int benign_complementary_if "$tmp/benign_complementary_if.herb" "$tmp/benign_complementary_if.elf" 4
fi

expected_self="$tmp/self.expected"
printf 'program: native-subset: deferred native operation (ERR 438)\n0\n' >"$expected_self"
if command -v timeout >/dev/null 2>&1; then
    timeout 180 "$HERBERT" "$backend" <"$backend" >"$tmp/self.out" 2>"$tmp/self.err"
    self_rc=$?
else
    "$HERBERT" "$backend" <"$backend" >"$tmp/self.out" 2>"$tmp/self.err"
    self_rc=$?
fi
self_magic=$(head -c4 "$tmp/self.out" | xxd -p | tr -d '\n')
if [[ $self_rc -eq 0 && "$self_magic" != "7f454c46" ]] && cmp -s "$expected_self" "$tmp/self.out"; then
    pass=$((pass + 1))
else
    fail_test "self-compile: expected ERR 438 non-ELF, rc=$self_rc magic=$self_magic stdout=$(head -2 "$tmp/self.out" | tr '\n' '|') stderr=$(head -1 "$tmp/self.err")"
fi

echo ""
if [[ $fail -ne 0 ]]; then
    echo "$fail of $((pass + fail)) native-codegen-link10 sub-test(s) failed."
    exit 1
fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link10: $pass sub-tests: benign complementary partial aggregate compiles+runs byte-exact vs C, self-compile reaches ERR 438 frontier)"
exit 0
