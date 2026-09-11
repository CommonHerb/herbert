#!/usr/bin/env bash
# Native codegen Link 12 (native file output / `fwriter` capability): the back end
# lowers `do fwriter(bytes)` to openat/write-loop/close syscalls, so a compiled
# native program writes its bytes to a BYTE-PURE file "a.out" — every byte
# Herbert-authored, no host trailer (the native return-word trailer goes to
# stdout, a separate stream). The C bootstrap's bi_fwriter (captured once into the committed golden; golden mode, C not run) is the differential
# oracle. The compiler's own main is UNCHANGED (still emits the ELF to stdout);
# this link proves the capability the D12-payment link will use.
set -u

unset CDPATH
script_dir="$(cd -- "$(dirname -- "$0")" && pwd)" || exit 1
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

source "$script_dir/native_codegen_oracle.sh" || { echo "FAIL: cannot source native-codegen oracle" >&2; exit 1; }
native_codegen_oracle_begin link12 || exit 1

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
native_codegen_ensure_compiler "$tmp/native-compiler" || exit 1
pass=0
fail=0

fail_test() {
    echo "FAIL: stack/native_compile_fragment.herb ($1)"
    fail=$((fail + 1))
}

compile_probe() {
    local label="$1" probe="$2" elf="$3"
    # D12: the compiler now emits its ELF to a byte-pure file "a.out" (do fwriter),
    # not stdout. IMPORTANT collision: these probes are themselves fwriter-probes,
    # so when RUN they also write "a.out". Compile in a DEDICATED dir and harvest
    # that dir's a.out into $elf (a distinct path), keeping the compiler's output
    # ELF separate from the probe's runtime a.out (which check_bytepure captures
    # in its own $nd/$cd dirs below).
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

# Byte-pure differential: native-run a.out must equal C-run a.out exactly, with
# size == expected (no trailer; the native return word goes to stdout, not the file).
check_bytepure() {
    local label="$1" probe="$2" expect_size="$3"
    local elf="$tmp/$label.elf"
    compile_probe "$label" "$probe" "$elf" || return
    local nd="$tmp/$label.nat" cd="$tmp/$label.c"
    local expected="$tmp/$label.expected.a.out" empty_input="$tmp/$label.empty"
    rm -rf "$nd" "$cd"; mkdir -p "$nd" "$cd"
    ( cd "$nd" && "$elf" >/dev/null 2>&1 )
    : >"$empty_input"
    if [[ ! -f "$nd/a.out" ]]; then fail_test "$label: native run produced no a.out"; return; fi
    if ! oracle_expect_file "link12_${label}" "$probe" "$cd" "a.out" "$expected" "$empty_input"; then
        fail_test "$label: file oracle failed"
        return
    fi
    local nsz golden_sz
    nsz=$(wc -c <"$nd/a.out"); golden_sz=$(wc -c <"$expected")
    if [[ "$nsz" -ne "$expect_size" ]]; then
        fail_test "$label: native a.out size $nsz != expected $expect_size (trailer present?)"
        return
    fi
    if cmp -s "$nd/a.out" "$expected"; then
        pass=$((pass + 1))
    else
        fail_test "$label: native a.out differs from the committed C-derived golden a.out (native $nsz, golden $golden_sz; golden mode, C not run)"
    fi
}

# White-box pin of the complete atomic writer, assembled from
# fixtures/fwriter_linux_x86_64.s. The fault target verifies that reference with
# GNU as; this C-free gate deliberately needs no assembler at runtime.
check_disasm_gate() {
    local label="$1" probe="$2"
    local elf="$tmp/$label.elf"
    compile_probe "$label" "$probe" "$elf" || return
    if python3 - "$elf" <<'PYWRITER'
from pathlib import Path
import hashlib, sys
image = Path(sys.argv[1]).read_bytes()
prefix = bytes.fromhex("415841595341544155415641574883ec60")
start = image.find(prefix)
expected = "63981c56c5677d52567015e724a39d3bb760be697c4abb9b0d03ebf7082e4c22"
ok = (start >= 0 and image.count(prefix) == 1 and
      hashlib.sha256(image[start:start + 593]).hexdigest() == expected)
raise SystemExit(0 if ok else 1)
PYWRITER
    then
        pass=$((pass + 1))
    else
        fail_test "$label disasm gate: atomic fwriter instruction image differs"
    fi
}

# Rejection: a probe that should NOT compile to an ELF (renamed twin / type error).
check_reject() {
    local label="$1" probe="$2"
    if native_codegen_expect_rejection "$NATIVE_CODEGEN_COMPILER" "$probe" "$tmp/$label.out" "$tmp/$label.err" 'ERR 4[0-9][0-9]'; then
        pass=$((pass + 1))
    else
        fail_test "$label: expected clean rejection"
    fi
}

cat >"$tmp/hi.herb" <<'HERB'
func main():
    let b = new_buffer()
    do append(b, 72)
    do append(b, 105)
    do fwriter(freeze(b))
    return 0
end
HERB

cat >"$tmp/empty.herb" <<'HERB'
func main():
    let b = new_buffer()
    do fwriter(freeze(b))
    return 0
end
HERB

# Renamed twin: fwriter -> fwriterX (unknown builtin) must reject — proves the
# builtin plumbing is real, not probe-fitted.
cat >"$tmp/twin.herb" <<'HERB'
func main():
    let b = new_buffer()
    do append(b, 72)
    do fwriterX(freeze(b))
    return 0
end
HERB

# Non-string argument must reject at compile time.
cat >"$tmp/badarg.herb" <<'HERB'
func main():
    do fwriter(42)
    return 0
end
HERB

check_bytepure hi "$tmp/hi.herb" 2
check_bytepure empty "$tmp/empty.herb" 0
check_disasm_gate disasm "$tmp/hi.herb"
check_reject twin "$tmp/twin.herb"
check_reject badarg "$tmp/badarg.herb"

echo ""
if [[ $fail -ne 0 ]]; then
    echo "$fail of $((pass + fail)) native-codegen-link12 sub-test(s) failed."
    exit 1
fi
if ! native_codegen_oracle_finish; then
    exit 1
fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link12: $pass sub-tests: fwriter byte-pure file differential vs the committed C-derived goldens (golden mode, C not run) (hi/empty), complete atomic-writer instruction pin, renamed-twin + non-string rejects)"
exit 0
