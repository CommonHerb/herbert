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
    # D12: the compiler emits its ELF to a byte-pure file "a.out" (do fwriter),
    # not stdout. Run it in a per-label scratch dir and harvest that dir's a.out.
    local cdir="$tmp/$label.cdir"
    rm -rf "$cdir"; mkdir -p "$cdir"
    ( cd "$cdir" && "$HERBERT" "$backend" <"$probe" >"$tmp/$label.o" 2>"$tmp/$label.e" )
    if [[ ! -f "$cdir/a.out" ]]; then
        fail_test "compile $label rejected/no a.out: $(head -1 "$tmp/$label.o") $(head -1 "$tmp/$label.e")"
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

# D12: gen-1, gen-2, and the altimeter probe compiles all write byte-pure files
# (do fwriter) with NO host trailer, so the fixpoint/altimeter are DIRECT cmps --
# the trailer-strip helpers this test used pre-D12 are gone.

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

# gen-1: the self-compiler emitted by C, compiling the whole backend. With D12 it
# writes a byte-pure ELF to a.out in its own dir (stdout = only the "0\n" host
# trailer). Run in g1d and harvest g1d/a.out.
g1d="$tmp/gen1.d"; rm -rf "$g1d"; mkdir -p "$g1d"
total_self_timeout="${NATIVE_SELF_TIMEOUT:-480s}"
if command -v timeout >/dev/null 2>&1; then
    ( cd "$g1d" && timeout "$total_self_timeout" "$HERBERT" "$backend" <"$backend" >"$tmp/self_compiler.out" 2>"$tmp/self_compiler.err" )
    self_rc=$?
else
    ( cd "$g1d" && "$HERBERT" "$backend" <"$backend" >"$tmp/self_compiler.out" 2>"$tmp/self_compiler.err" )
    self_rc=$?
fi
self_magic=""
[[ -f "$g1d/a.out" ]] && self_magic=$(head -c4 "$g1d/a.out" | xxd -p | tr -d '\n')
if [[ $self_rc -eq 0 && "$self_magic" == "7f454c46" ]]; then
    cp "$g1d/a.out" "$tmp/self_compiler.elf"
    chmod +x "$tmp/self_compiler.elf"
    # Altimeter: gen-1 and C each compile the same probe to a byte-pure a.out (each
    # in its own dir); the two files must be byte-identical -- a DIRECT cmp, no
    # trailer strip (both are byte-pure now).
    nd="$tmp/altimeter.native.d"; acd="$tmp/altimeter.c.d"
    rm -rf "$nd" "$acd"; mkdir -p "$nd" "$acd"
    ( cd "$nd" && "$tmp/self_compiler.elf" <"$tmp/self_host_probe.herb" >"$tmp/self_probe.native.out" 2>"$tmp/self_probe.native.err" )
    native_rc=$?
    ( cd "$acd" && "$HERBERT" "$backend" <"$tmp/self_host_probe.herb" >"$tmp/self_probe.c.out" 2>"$tmp/self_probe.c.err" )
    c_rc=$?
    native_magic=""; c_magic=""
    [[ -f "$nd/a.out" ]] && native_magic=$(head -c4 "$nd/a.out" | xxd -p | tr -d '\n')
    [[ -f "$acd/a.out" ]] && c_magic=$(head -c4 "$acd/a.out" | xxd -p | tr -d '\n')
    if [[ $native_rc -eq 0 && $c_rc -eq 0 && "$native_magic" == "7f454c46" && "$c_magic" == "7f454c46" ]] \
        && cmp -s "$nd/a.out" "$acd/a.out"; then
        pass=$((pass + 1))
    else
        fail_test "self-compile altimeter: self compiler did not byte-match reference probe (self_rc=$self_rc native_rc=$native_rc c_rc=$c_rc native_magic=$native_magic c_magic=$c_magic native_size=$([[ -f "$nd/a.out" ]] && wc -c <"$nd/a.out" || echo none) c_size=$([[ -f "$acd/a.out" ]] && wc -c <"$acd/a.out" || echo none))"
    fi
    # tito: full native self-hosting FIXPOINT. gen-1 (the self-compiler just built)
    # compiles the WHOLE backend into gen-2. With D12 both gen-1 and gen-2 are
    # BYTE-PURE files, so the fixpoint is a DIRECT cmp -- gen-2 == gen-1, no
    # per-side host-trailer strip (the cleanest statement of self-hosting). Only
    # reachable because tito enlarged the native heap (16 MiB -> ~2 GiB) so the
    # self-compiler can hold its own compile. Cheap to add: gen-1 is already built;
    # this only adds the ~1-2s gen-2.
    g2d="$tmp/gen2.d"; rm -rf "$g2d"; mkdir -p "$g2d"
    fix_timeout="${NATIVE_FIXPOINT_TIMEOUT:-180s}"
    if command -v timeout >/dev/null 2>&1; then
        ( cd "$g2d" && timeout "$fix_timeout" "$tmp/self_compiler.elf" <"$backend" >"$tmp/gen2.out" 2>"$tmp/gen2.err" )
        gen2_rc=$?
    else
        ( cd "$g2d" && "$tmp/self_compiler.elf" <"$backend" >"$tmp/gen2.out" 2>"$tmp/gen2.err" )
        gen2_rc=$?
    fi
    gen2_magic=""
    [[ -f "$g2d/a.out" ]] && gen2_magic=$(head -c4 "$g2d/a.out" | xxd -p | tr -d '\n')
    if [[ $gen2_rc -eq 0 && "$gen2_magic" == "7f454c46" ]] \
        && cmp -s "$tmp/self_compiler.elf" "$g2d/a.out"; then
        pass=$((pass + 1))
    else
        fail_test "self-host FIXPOINT: gen-2 (self-compiler compiling the whole backend) did not byte-match gen-1 (gen2_rc=$gen2_rc gen2_magic=$gen2_magic gen1_size=$(wc -c <"$tmp/self_compiler.elf") gen2_size=$([[ -f "$g2d/a.out" ]] && wc -c <"$g2d/a.out" || echo none))"
    fi
else
    fail_test "self-compile altimeter: expected self-host ELF, rc=$self_rc magic=$self_magic stdout=$(head -1 "$tmp/self_compiler.out") stderr=$(head -1 "$tmp/self_compiler.err")"
fi

echo ""
if [[ $fail -ne 0 ]]; then
    echo "$fail of $((pass + fail)) native-codegen-link10 sub-test(s) failed."
    exit 1
fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link10: $pass sub-tests: benign complementary partial aggregate compiles+runs byte-exact vs C, self-compile self-host probe byte-exact (byte-pure files, direct cmp), tito self-hosting FIXPOINT gen2==gen1 (byte-pure direct cmp, no trailer strip))"
exit 0
