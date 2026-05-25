#!/usr/bin/env bash
# Native codegen Link 8 test (beaver): native clogger() reads stdin into the
# heap, lifting the old 64 KiB stack-arena cap. Byte-for-byte parity vs the C
# bootstrap on inputs far larger than 64 KiB (including the compiler's own
# source), boundary coverage across the old cap, a whole-input fold proving the
# bytes are actually read, index past the old cap, clogger-after-alloc, a
# renamed twin, and a white-box disasm gate (heap-tail read present, the old
# 64 KiB arena/cap bytes absent). The >16 MiB heap-cap fault lives in the
# consolidated reject battery (run_native_codegen_rejects.sh).
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
    "$HERBERT" "$backend" <"$probe" >"$tmp/$label.o" 2>"$tmp/$label.e"
    local magic
    magic=$(head -c4 "$tmp/$label.o" | xxd -p | tr -d '\n')
    if [[ "$magic" != "7f454c46" ]]; then
        fail_test "compile $label rejected/no ELF: $(head -1 "$tmp/$label.e")"
        return 1
    fi
    cp "$tmp/$label.o" "$elf"
    chmod +x "$elf"
    return 0
}

le64() { python3 -c "import sys;sys.stdout.buffer.write(int(sys.argv[1]).to_bytes(8,'little'))" "$1"; }

# return-int probe: native 8-byte LE return word must equal LE64(C decimal).
check_return() {
    local label="$1" probe="$2" elf="$3" f="$4"
    "$elf" <"$f" >"$tmp/$label.n" 2>/dev/null
    local nrc=$?
    "$HERBERT" "$probe" <"$f" >"$tmp/$label.c" 2>/dev/null
    local cval
    cval=$(tr -d '\n' <"$tmp/$label.c")
    le64 "$cval" >"$tmp/$label.cle" 2>/dev/null
    if [[ $nrc -eq 0 ]] && cmp -s "$tmp/$label.n" "$tmp/$label.cle"; then
        pass=$((pass + 1))
    else
        fail_test "$label (in=$(wc -c <"$f") B): native rc=$nrc word=$(xxd -p "$tmp/$label.n" | tr -d '\n') vs C=$cval"
    fi
}

# flogger probe: native stdout = payload||le64(0); C stdout = payload||"0\n".
# Strip the fixed trailers (native -8, C -2) and compare the payloads.
check_flogger() {
    local label="$1" probe="$2" elf="$3" f="$4"
    "$elf" <"$f" >"$tmp/$label.n" 2>/dev/null
    local nrc=$?
    "$HERBERT" "$probe" <"$f" >"$tmp/$label.c" 2>/dev/null
    local ns cs
    ns=$(wc -c <"$tmp/$label.n")
    cs=$(wc -c <"$tmp/$label.c")
    if [[ $nrc -ne 0 || $ns -lt 8 || $cs -lt 2 ]]; then
        fail_test "$label (in=$(wc -c <"$f") B): native rc=$nrc ns=$ns cs=$cs"
        return
    fi
    head -c $((ns - 8)) "$tmp/$label.n" >"$tmp/$label.np"
    head -c $((cs - 2)) "$tmp/$label.c" >"$tmp/$label.cp"
    if cmp -s "$tmp/$label.np" "$tmp/$label.cp"; then
        pass=$((pass + 1))
    else
        fail_test "$label payload: native=$(xxd -p "$tmp/$label.np" | tr -d '\n') C=$(xxd -p "$tmp/$label.cp" | tr -d '\n')"
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
: >"$tmp/i_empty"
head -c 65535 "$backend" >"$tmp/i_65535"
head -c 65536 "$backend" >"$tmp/i_65536"
head -c 65537 "$backend" >"$tmp/i_65537"
head -c 100000 "$backend" >"$tmp/i_100k"
head -c 5 "$backend" >"$tmp/i_5"
cp "$backend" "$tmp/i_src"   # the compiler's own ~237 KiB source -- the self-hosting input

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
echo "PASS: stack/native_compile_fragment.herb (native-codegen link8: $pass sub-tests: clogger-into-heap length boundary across 64 KiB, whole-input fold incl. the compiler's own source, index past the old cap, clogger-after-alloc, renamed twin, disasm gate)"
exit 0
