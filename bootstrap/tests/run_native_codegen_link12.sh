#!/usr/bin/env bash
# Native codegen Link 12 (native file output / `fwriter` capability): the back end
# lowers `do fwriter(bytes)` to openat/write-loop/close syscalls, so a compiled
# native program writes its bytes to a BYTE-PURE file "a.out" — every byte
# Herbert-authored, no host trailer (the native return-word trailer goes to
# stdout, a separate stream). The C bootstrap's bi_fwriter is the differential
# oracle. The compiler's own main is UNCHANGED (still emits the ELF to stdout);
# this link proves the capability the D12-payment link will use.
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

compile_probe() {
    local label="$1" probe="$2" elf="$3"
    "$HERBERT" "$backend" <"$probe" >"$tmp/$label.compile.out" 2>"$tmp/$label.compile.err"
    local magic
    magic=$(head -c4 "$tmp/$label.compile.out" | xxd -p | tr -d '\n')
    if [[ "$magic" != "7f454c46" ]]; then
        fail_test "compile $label rejected/no ELF: stdout=$(head -1 "$tmp/$label.compile.out") stderr=$(head -1 "$tmp/$label.compile.err")"
        return 1
    fi
    cp "$tmp/$label.compile.out" "$elf"
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
    rm -rf "$nd" "$cd"; mkdir -p "$nd" "$cd"
    ( cd "$nd" && "$elf" >/dev/null 2>&1 )
    ( cd "$cd" && "$HERBERT" "$probe" >/dev/null 2>&1 )
    if [[ ! -f "$nd/a.out" ]]; then fail_test "$label: native run produced no a.out"; return; fi
    if [[ ! -f "$cd/a.out" ]]; then fail_test "$label: C oracle produced no a.out"; return; fi
    local nsz csz
    nsz=$(wc -c <"$nd/a.out"); csz=$(wc -c <"$cd/a.out")
    if [[ "$nsz" -ne "$expect_size" ]]; then
        fail_test "$label: native a.out size $nsz != expected $expect_size (trailer present?)"
        return
    fi
    if cmp -s "$nd/a.out" "$cd/a.out"; then
        pass=$((pass + 1))
    else
        fail_test "$label: native a.out differs from C oracle a.out (native $nsz, C $csz)"
    fi
}

# White-box disasm gate: the emitted ELF must contain the exact fwriter syscall
# sequence (openat with AT_FDCWD/flags=0x241/mode=0644, then close), and the
# success path must jmp over the error-exit block (add rsp,8; jmp +12).
check_disasm_gate() {
    local label="$1" probe="$2"
    local elf="$tmp/$label.elf"
    compile_probe "$label" "$probe" "$elf" || return
    local hex
    hex=$(xxd -p "$elf" | tr -d '\n')
    local openat="b80101000048c7c79cffffffba4102000041baa40100000f05"
    local close="b8030000004c89e70f05"
    local jmpover="4883c408eb0c"
    if [[ "$hex" == *"$openat"* && "$hex" == *"$close"* && "$hex" == *"$jmpover"* ]]; then
        pass=$((pass + 1))
    else
        fail_test "$label disasm gate: fwriter openat/close/jmp-over-error byte signature missing"
    fi
}

# Rejection: a probe that should NOT compile to an ELF (renamed twin / type error).
check_reject() {
    local label="$1" probe="$2"
    "$HERBERT" "$backend" <"$probe" >"$tmp/$label.out" 2>"$tmp/$label.err"
    local magic
    magic=$(head -c4 "$tmp/$label.out" | xxd -p | tr -d '\n')
    if [[ "$magic" == "7f454c46" ]]; then
        fail_test "$label: expected rejection but got an ELF"
    else
        pass=$((pass + 1))
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
echo "PASS: stack/native_compile_fragment.herb (native-codegen link12: $pass sub-tests: fwriter byte-pure file differential vs C (hi/empty), openat/close/jmp-over-error disasm gate, renamed-twin + non-string rejects)"
exit 0
