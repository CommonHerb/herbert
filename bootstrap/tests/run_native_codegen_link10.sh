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

strip_c_trailer() {
    local src="$1" dst="$2"
    python3 - "$src" "$dst" <<'PY'
from pathlib import Path
import sys
data = Path(sys.argv[1]).read_bytes()
if not data.endswith(b"0\n"):
    raise SystemExit("missing C trailer")
Path(sys.argv[2]).write_bytes(data[:-2])
PY
}

strip_native_trailer() {
    local src="$1" dst="$2"
    python3 - "$src" "$dst" <<'PY'
from pathlib import Path
import sys
data = Path(sys.argv[1]).read_bytes()
if not data.endswith(b"\0" * 8):
    raise SystemExit("missing native trailer")
Path(sys.argv[2]).write_bytes(data[:-8])
PY
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

cat >"$tmp/self_host_probe.herb" <<'HERB'
func main():
    let i = clogger()
    return index(i, 0) + index(i, 1)
end
HERB

total_self_timeout="${NATIVE_SELF_TIMEOUT:-480s}"
if command -v timeout >/dev/null 2>&1; then
    timeout "$total_self_timeout" "$HERBERT" "$backend" <"$backend" >"$tmp/self_compiler.out" 2>"$tmp/self_compiler.err"
    self_rc=$?
else
    "$HERBERT" "$backend" <"$backend" >"$tmp/self_compiler.out" 2>"$tmp/self_compiler.err"
    self_rc=$?
fi
self_magic=$(head -c4 "$tmp/self_compiler.out" | xxd -p | tr -d '\n')
if [[ $self_rc -eq 0 && "$self_magic" == "7f454c46" ]]; then
    cp "$tmp/self_compiler.out" "$tmp/self_compiler.elf"
    chmod +x "$tmp/self_compiler.elf"
    "$tmp/self_compiler.elf" <"$tmp/self_host_probe.herb" >"$tmp/self_probe.native.out" 2>"$tmp/self_probe.native.err"
    native_rc=$?
    "$HERBERT" "$backend" <"$tmp/self_host_probe.herb" >"$tmp/self_probe.c.out" 2>"$tmp/self_probe.c.err"
    c_rc=$?
    native_magic=$(head -c4 "$tmp/self_probe.native.out" | xxd -p | tr -d '\n')
    c_magic=$(head -c4 "$tmp/self_probe.c.out" | xxd -p | tr -d '\n')
    if [[ $native_rc -eq 0 && $c_rc -eq 0 && "$native_magic" == "7f454c46" && "$c_magic" == "7f454c46" ]] \
        && strip_native_trailer "$tmp/self_probe.native.out" "$tmp/self_probe.native.elf" \
        && strip_c_trailer "$tmp/self_probe.c.out" "$tmp/self_probe.c.elf" \
        && cmp -s "$tmp/self_probe.native.elf" "$tmp/self_probe.c.elf"; then
        pass=$((pass + 1))
    else
        fail_test "self-compile altimeter: self compiler did not byte-match reference probe (self_rc=$self_rc native_rc=$native_rc c_rc=$c_rc native_magic=$native_magic c_magic=$c_magic native_size=$(wc -c <"$tmp/self_probe.native.out") c_size=$(wc -c <"$tmp/self_probe.c.out"))"
    fi
    # tito: full native self-hosting FIXPOINT. gen-1 (the self-compiler just built)
    # compiles the WHOLE backend into gen-2; gen-2 must byte-match gen-1 (each modulo
    # its own host trailer: gen-1 from C ends "0\n", gen-2 from native ends 8x\0).
    # This is the capstone forcing function and is only reachable because tito enlarged
    # the native heap (16 MiB -> ~2 GiB) so the self-compiler can hold its own compile.
    # Cheap to add here: gen-1 is already built above; this only adds the ~1-2s gen-2.
    fix_timeout="${NATIVE_FIXPOINT_TIMEOUT:-180s}"
    if command -v timeout >/dev/null 2>&1; then
        timeout "$fix_timeout" "$tmp/self_compiler.elf" <"$backend" >"$tmp/gen2.out" 2>"$tmp/gen2.err"
        gen2_rc=$?
    else
        "$tmp/self_compiler.elf" <"$backend" >"$tmp/gen2.out" 2>"$tmp/gen2.err"
        gen2_rc=$?
    fi
    gen2_magic=$(head -c4 "$tmp/gen2.out" | xxd -p | tr -d '\n')
    if [[ $gen2_rc -eq 0 && "$gen2_magic" == "7f454c46" ]] \
        && strip_c_trailer "$tmp/self_compiler.out" "$tmp/gen1.elf" \
        && strip_native_trailer "$tmp/gen2.out" "$tmp/gen2.elf" \
        && cmp -s "$tmp/gen1.elf" "$tmp/gen2.elf"; then
        pass=$((pass + 1))
    else
        fail_test "self-host FIXPOINT: gen-2 (self-compiler compiling the whole backend) did not byte-match gen-1 (gen2_rc=$gen2_rc gen2_magic=$gen2_magic gen1_size=$(wc -c <"$tmp/self_compiler.out") gen2_size=$(wc -c <"$tmp/gen2.out"))"
    fi
else
    fail_test "self-compile altimeter: expected self-host ELF, rc=$self_rc magic=$self_magic stdout=$(head -1 "$tmp/self_compiler.out") stderr=$(head -1 "$tmp/self_compiler.err")"
fi

echo ""
if [[ $fail -ne 0 ]]; then
    echo "$fail of $((pass + fail)) native-codegen-link10 sub-test(s) failed."
    exit 1
fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link10: $pass sub-tests: benign complementary partial aggregate compiles+runs byte-exact vs C, self-compile self-host probe byte-exact modulo host trailer, tito self-hosting FIXPOINT gen2==gen1)"
exit 0
