#!/usr/bin/env bash
# Native codegen Link 8 test (beaver): native clogger() reads stdin into the
# heap, lifting the old 64 KiB stack-arena cap. Byte-for-byte parity vs the C
# bootstrap on inputs far larger than 64 KiB (including the compiler's own
# source), boundary coverage across the old cap, a whole-input fold proving the
# bytes are actually read, index past the old cap, clogger-after-alloc, a
# renamed twin, and a white-box disasm gate (heap-tail read present, the old
# 64 KiB arena/cap bytes absent). The heap-cap behavior (cap enlarged to ~2 GiB
# at tito) lives in the consolidated reject battery (run_native_codegen_rejects.sh).
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
native_codegen_oracle_begin link8 || exit 1

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
native_codegen_ensure_compiler "$tmp/native-compiler" || exit 1
pass=0
fail=0

fail_test() {
    echo "FAIL: stack/native_compile_fragment.herb ($1)"
    fail=$((fail + 1))
}

link8_fixtures="$NATIVE_CODEGEN_GOLDENS_DIR/fixtures/link8"
if [[ ! -d "$link8_fixtures" ]]; then
    echo "FAIL: stack/native_compile_fragment.herb (missing link8 oracle fixtures; run bootstrap/tests/capture_native_goldens.sh)"
    exit 1
fi

compile_probe() {
    local label="$1" probe="$2" elf="$3"
    # D12: the compiler emits its ELF to a byte-pure file "a.out" (do fwriter),
    # not stdout. Run it in a per-label scratch dir and harvest that dir's a.out.
    # (The PROBES below still read stdin via clogger and write to STDOUT via
    # flogger when run -- that is the probe's I/O, unrelated to the a.out file.)
    local cdir="$tmp/$label.cdir"
    rm -rf "$cdir"; mkdir -p "$cdir"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" <"$probe" >"$tmp/$label.o" 2>"$tmp/$label.e" )
    if [[ ! -f "$cdir/a.out" ]]; then
        fail_test "compile $label rejected/no a.out: $(head -1 "$tmp/$label.e")"
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

le64() { python3 -c "import sys;sys.stdout.buffer.write(int(sys.argv[1]).to_bytes(8,'little'))" "$1"; }

# return-int probe: native 8-byte LE return word must equal LE64(C decimal).
check_return() {
    local label="$1" probe="$2" elf="$3" f="$4"
    "$elf" <"$f" >"$tmp/$label.n" 2>/dev/null
    local nrc=$?
    if ! oracle_expect_le64 "link8_${label}" "$probe" "$f" "$tmp/$label.expected"; then
        fail_test "$label (in=$(wc -c <"$f") B): return oracle failed"
        return
    fi
    if [[ $nrc -eq 0 ]] && cmp -s "$tmp/$label.n" "$tmp/$label.expected"; then
        pass=$((pass + 1))
    else
        fail_test "$label (in=$(wc -c <"$f") B): native rc=$nrc word=$(xxd -p "$tmp/$label.n" | tr -d '\n') expected=$(xxd -p "$tmp/$label.expected" | tr -d '\n')"
    fi
}

# flogger probe (D14): native stdout = payload||"0\n"; C stdout = payload||"0\n".
# Strip the fixed 2-byte "0\n" trailer from native and compare to the payload golden.
check_flogger() {
    local label="$1" probe="$2" elf="$3" f="$4"
    "$elf" <"$f" >"$tmp/$label.n" 2>/dev/null
    local nrc=$?
    local ns cs
    ns=$(wc -c <"$tmp/$label.n")
    if [[ $nrc -ne 0 || $ns -lt 2 ]]; then
        fail_test "$label (in=$(wc -c <"$f") B): native rc=$nrc ns=$ns"
        return
    fi
    head -c $((ns - 2)) "$tmp/$label.n" >"$tmp/$label.np"
    if [[ "$(tail -c2 "$tmp/$label.n" | xxd -p | tr -d '\n')" != "300a" ]]; then
        fail_test "$label native trailer"
        return
    fi
    if ! oracle_expect_payload "link8_${label}" "$probe" "$f" "$tmp/$label.expected"; then
        fail_test "$label (in=$(wc -c <"$f") B): payload oracle failed"
        return
    fi
    if cmp -s "$tmp/$label.np" "$tmp/$label.expected"; then
        pass=$((pass + 1))
    else
        fail_test "$label payload: native=$(xxd -p "$tmp/$label.np" | tr -d '\n') expected=$(xxd -p "$tmp/$label.expected" | tr -d '\n')"
    fi
}

# ---- probes -------------------------------------------------------------
cat >"$tmp/len.herb" <<'HERB'
func main():
    return length(clogger())
end
HERB

cat >"$tmp/idx.herb" <<'HERB'
func main():
    let s = clogger()
    return index(s, 70000)
end
HERB

cat >"$tmp/idx2.herb" <<'HERB'
func main():
    let s = clogger()
    return index(s, 200000)
end
HERB

cat >"$tmp/fold.herb" <<'HERB'
func low_byte(x):
    if x < 256:
        return x
    end
    return low_byte(x - 256)
end
func fold64(s, i, n, acc):
    if i >= n:
        return acc
    end
    return fold64(s, i + 1, n, acc + index(s, i))
end
func main():
    let s = clogger()
    let h = fold64(s, 0, length(s), 0)
    let b = new_buffer()
    do append(b, low_byte(h))
    do flogger(freeze(b))
    return 0
end
HERB

# Renamed twin of fold.herb (different func/local names, identical shape) -- the
# verdict must not change (renamed-twin gate; the back end is name-agnostic).
cat >"$tmp/twin.herb" <<'HERB'
func reduce_one(q):
    if q < 256:
        return q
    end
    return reduce_one(q - 256)
end
func roll(buf_in, k, m, total):
    if k >= m:
        return total
    end
    return roll(buf_in, k + 1, m, total + index(buf_in, k))
end
func main():
    let data = clogger()
    let r = roll(data, 0, length(data), 0)
    let out = new_buffer()
    do append(out, reduce_one(r))
    do flogger(freeze(out))
    return 0
end
HERB

# clogger-after-alloc: heap objects allocated BEFORE the read must survive, the
# read must start at the current bump, and later objects must not overwrite the
# input string.
cat >"$tmp/aa.herb" <<'HERB'
func main():
    let pre = new_buffer()
    do append(pre, 80)
    let arr = new_array(int)
    do add(arr, 7)
    let s = clogger()
    let out = new_buffer()
    do append(out, get(arr, 0))
    do append(out, index(s, 70000))
    do append(out, index(freeze(pre), 0))
    do flogger(freeze(out))
    return 0
end
HERB

# ---- inputs (real bytes from the compiler's own source; the self-hosting input)
cp "$link8_fixtures/i_empty" "$tmp/i_empty"
cp "$link8_fixtures/i_65535" "$tmp/i_65535"
cp "$link8_fixtures/i_65536" "$tmp/i_65536"
cp "$link8_fixtures/i_65537" "$tmp/i_65537"
cp "$link8_fixtures/i_100k" "$tmp/i_100k"
cp "$link8_fixtures/i_5" "$tmp/i_5"
cp "$link8_fixtures/i_src" "$tmp/i_src"   # snapshot of the compiler source input

# ---- length boundary across the old 64 KiB cap (all must match C) -------
compile_probe len "$tmp/len.herb" "$tmp/len.elf" || true
if [[ -x "$tmp/len.elf" ]]; then
    check_return len_empty "$tmp/len.herb" "$tmp/len.elf" "$tmp/i_empty"
    check_return len_65535 "$tmp/len.herb" "$tmp/len.elf" "$tmp/i_65535"
    check_return len_65536 "$tmp/len.herb" "$tmp/len.elf" "$tmp/i_65536"
    check_return len_65537 "$tmp/len.herb" "$tmp/len.elf" "$tmp/i_65537"
    check_return len_100k  "$tmp/len.herb" "$tmp/len.elf" "$tmp/i_100k"
    check_return len_src   "$tmp/len.herb" "$tmp/len.elf" "$tmp/i_src"
fi

# ---- whole-input fold (proves the bytes are actually read, not just counted)
compile_probe fold "$tmp/fold.herb" "$tmp/fold.elf" || true
if [[ -x "$tmp/fold.elf" ]]; then
    check_flogger fold_5    "$tmp/fold.herb" "$tmp/fold.elf" "$tmp/i_5"
    check_flogger fold_100k "$tmp/fold.herb" "$tmp/fold.elf" "$tmp/i_100k"
    check_flogger fold_src  "$tmp/fold.herb" "$tmp/fold.elf" "$tmp/i_src"
fi

# ---- index past the old 64 KiB cap (bytes beyond 64 KiB are real) -------
compile_probe idx "$tmp/idx.herb" "$tmp/idx.elf" || true
[[ -x "$tmp/idx.elf" ]] && check_return idx70k "$tmp/idx.herb" "$tmp/idx.elf" "$tmp/i_src"
compile_probe idx2 "$tmp/idx2.herb" "$tmp/idx2.elf" || true
[[ -x "$tmp/idx2.elf" ]] && check_return idx200k "$tmp/idx2.herb" "$tmp/idx2.elf" "$tmp/i_src"

# ---- clogger-after-alloc -------------------------------------------------
compile_probe aa "$tmp/aa.herb" "$tmp/aa.elf" || true
[[ -x "$tmp/aa.elf" ]] && check_flogger aa_src "$tmp/aa.herb" "$tmp/aa.elf" "$tmp/i_src"

# ---- renamed twin (same verdict + same payload as fold) ------------------
compile_probe twin "$tmp/twin.herb" "$tmp/twin.elf" || true
[[ -x "$tmp/twin.elf" ]] && check_flogger twin_src "$tmp/twin.herb" "$tmp/twin.elf" "$tmp/i_src"

# ---- white-box disasm gate ----------------------------------------------
# Required present: r12=r14 (heap-tail base), remaining=r15-r12-r13, loop
# back-edge, commit r14=r12+r13, push (addr,len). Required absent: the old
# 64 KiB stack arena/cap bytes.
if [[ -x "$tmp/len.elf" ]]; then
    pass=$((pass + 1))
    hex=$(xxd -p -c999999 "$tmp/len.elf" | tr -d '\n')
    for p in 4d89f4 4c89fa4c29e24c29ea ebdc 4d89e64d01ee 41544155; do
        if ! printf '%s' "$hex" | grep -q "$p"; then
            fail_test "disasm gate: missing heap-tail pattern $p"
            pass=$((pass - 1))
            break
        fi
    done
    for p in 4981fd00000100 ba00000100 4881ec10000100 4881c410000100 4989e4; do
        if printf '%s' "$hex" | grep -q "$p"; then
            fail_test "disasm gate: old 64 KiB arena/cap pattern $p still present"
            pass=$((pass - 1))
            break
        fi
    done
fi

echo ""
if [[ $fail -ne 0 ]]; then
    echo "$fail of $((pass + fail)) native-codegen-link8 sub-test(s) failed."
    exit 1
fi
if ! native_codegen_oracle_finish; then
    exit 1
fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link8: $pass sub-tests: clogger-into-heap length boundary across 64 KiB, whole-input fold incl. the compiler's own source, index past the old cap, clogger-after-alloc, renamed twin, disasm gate)"
exit 0
