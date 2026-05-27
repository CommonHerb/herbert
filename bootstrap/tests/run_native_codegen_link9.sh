#!/usr/bin/env bash
# Native codegen Link 9 test (zelph): the never-returning error helper `fault`
# (`let a = new_array(...); return get(a, 0)` -- always traps, get-on-empty) is
# recognized structurally as type-bottom (bottom). Its sig-return must not be
# forced onto callers, so the fault idiom -- used polymorphically across int /
# string / tuple / bool return positions, and mid-expression -- now compiles and
# runs byte-for-byte vs the C bootstrap (including the trap path, where both
# native and C fault with empty stdout). The recognition is structural, not
# name-keyed: a renamed twin behaves identically. A white-box disasm gate
# confirms `fault` is lowered as an ordinary `call` -- NOT tail-call-optimized
# into a `jmp` (a wrong TCO would still trap identically at runtime, so only the
# disassembly can catch it). The soundness rails (rebind / let-shadow / pure-
# bottom / fake-trap rejects) live in the consolidated reject battery
# (run_native_codegen_rejects.sh).
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

le64() { python3 -c "import sys;sys.stdout.buffer.write(int(sys.argv[1]).to_bytes(8,'little'))" "$1"; }
byte() { python3 -c "import sys;sys.stdout.buffer.write(bytes([int(sys.argv[1])]))" "$1"; }

# int-returning probe with a fault (trap) path. For an input byte the C bootstrap
# runs to a value, native's 8-byte LE return word must equal LE64(C decimal); for
# an input byte that drives the fault path, the C bootstrap traps (nonzero exit,
# empty stdout) and native must trap the same way (nonzero exit, empty stdout).
check_return_or_trap() {
    local label="$1" probe="$2" elf="$3" b="$4"
    byte "$b" >"$tmp/$label.$b.in"
    "$elf" <"$tmp/$label.$b.in" >"$tmp/$label.$b.n" 2>/dev/null
    local nrc=$?
    "$HERBERT" "$probe" <"$tmp/$label.$b.in" >"$tmp/$label.$b.c" 2>/dev/null
    local crc=$?
    if [[ $crc -ne 0 ]]; then
        if [[ $nrc -ne 0 && ! -s "$tmp/$label.$b.n" ]]; then
            pass=$((pass + 1))
        else
            fail_test "$label byte=$b: C trapped (rc=$crc) but native rc=$nrc size=$(wc -c <"$tmp/$label.$b.n")"
        fi
    else
        local cval
        cval=$(tr -d '\n' <"$tmp/$label.$b.c")
        le64 "$cval" >"$tmp/$label.$b.cle" 2>/dev/null
        if [[ $nrc -eq 0 ]] && cmp -s "$tmp/$label.$b.n" "$tmp/$label.$b.cle"; then
            pass=$((pass + 1))
        else
            fail_test "$label byte=$b: native rc=$nrc word=$(xxd -p "$tmp/$label.$b.n" | tr -d '\n') vs C=$cval"
        fi
    fi
}

# ---- probes -------------------------------------------------------------
# fault used polymorphically across int (grade_int) and string (grade_str)
# return contexts -- the core ERR 430 the monomorphic solver hit pre-zelph.
cat >"$tmp/accept_poly.herb" <<'HERB'
func fault(reason):
    let bucket = new_array((int, int))
    return get(bucket, 0)
end
func grade_int(v):
    if v < 10:
        return fault("low")
    end
    return v + 7
end
func grade_str(v):
    if v < 10:
        return fault("low")
    end
    return "ok"
end
func main():
    let inp = clogger()
    let v = index(inp, 0)
    return grade_int(v) + length(grade_str(v))
end
HERB

# fault in tuple-return (as_triple) and bool-return (as_flag) contexts.
cat >"$tmp/accept_tuple_bool.herb" <<'HERB'
func fault(reason):
    let bucket = new_array((int, int))
    return get(bucket, 0)
end
func as_triple(v):
    if v < 10:
        return fault("low")
    end
    return (v, v + 1, v + 2)
end
func as_flag(v):
    if v < 10:
        return fault("low")
    end
    return v < 100
end
func main():
    let inp = clogger()
    let v = index(inp, 0)
    let t = as_triple(v)
    if as_flag(v):
        return t.0 + t.1 + t.2
    end
    return t.0
end
HERB

# fault mid-expression (operand of +, not a bare return) -- exercises the op-20
# synthesize-current-return path; the `+ 1` is dead code after the trap.
cat >"$tmp/accept_fault_in_expr.herb" <<'HERB'
func fault(why):
    let slot = new_array((int, int))
    return get(slot, 0)
end
func f(v):
    if v < 10:
        return fault("low") + 1
    end
    return v
end
func main():
    let inp = clogger()
    return f(index(inp, 0))
end
HERB

# Renamed twin of accept_poly (fault->halt, grade_int->m1, grade_str->m2, all
# locals renamed; identical shape). The verdict and output must not change --
# the recognition is structural, not keyed on the name "fault".
cat >"$tmp/twin_poly.herb" <<'HERB'
func halt(why):
    let slot = new_array((int, int))
    return get(slot, 0)
end
func m1(k):
    if k < 10:
        return halt("low")
    end
    return k + 7
end
func m2(k):
    if k < 10:
        return halt("low")
    end
    return "ok"
end
func main():
    let buf = clogger()
    let k = index(buf, 0)
    return m1(k) + length(m2(k))
end
HERB

# byte 5 drives the fault (trap) path; 10/32/100/128/255 are value paths.
bytes="5 10 32 100 128 255"

# ---- accept + run byte-exact vs C (incl. trap path) ---------------------
compile_probe accept_poly "$tmp/accept_poly.herb" "$tmp/accept_poly.elf" || true
if [[ -x "$tmp/accept_poly.elf" ]]; then
    for b in $bytes; do check_return_or_trap accept_poly "$tmp/accept_poly.herb" "$tmp/accept_poly.elf" "$b"; done
fi

compile_probe accept_tb "$tmp/accept_tuple_bool.herb" "$tmp/accept_tb.elf" || true
if [[ -x "$tmp/accept_tb.elf" ]]; then
    for b in $bytes; do check_return_or_trap accept_tb "$tmp/accept_tuple_bool.herb" "$tmp/accept_tb.elf" "$b"; done
fi

compile_probe accept_fie "$tmp/accept_fault_in_expr.herb" "$tmp/accept_fie.elf" || true
if [[ -x "$tmp/accept_fie.elf" ]]; then
    for b in $bytes; do check_return_or_trap accept_fie "$tmp/accept_fault_in_expr.herb" "$tmp/accept_fie.elf" "$b"; done
fi

# ---- renamed twin: same verdict, byte-identical to the original ---------
compile_probe twin_poly "$tmp/twin_poly.herb" "$tmp/twin_poly.elf" || true
if [[ -x "$tmp/twin_poly.elf" ]]; then
    for b in $bytes; do check_return_or_trap twin_poly "$tmp/twin_poly.herb" "$tmp/twin_poly.elf" "$b"; done
    if [[ -x "$tmp/accept_poly.elf" ]]; then
        for b in 32 100 255; do
            byte "$b" >"$tmp/twin.$b.in"
            "$tmp/accept_poly.elf" <"$tmp/twin.$b.in" >"$tmp/twin.$b.orig" 2>/dev/null
            "$tmp/twin_poly.elf"   <"$tmp/twin.$b.in" >"$tmp/twin.$b.twin" 2>/dev/null
            if cmp -s "$tmp/twin.$b.orig" "$tmp/twin.$b.twin"; then
                pass=$((pass + 1))
            else
                fail_test "twin!=original byte=$b (structural recognition broken)"
            fi
        done
    fi
fi

# ---- white-box disasm gate: fault = ordinary call, NOT TCO'd ------------
# accept_poly has exactly five direct calls: entry-stub->main, main->grade_int,
# main->grade_str, grade_int->fault, grade_str->fault. The last two are in tail
# position; zelph deliberately does NOT TCO a bottom (never-returning) callee, so
# they stay real `call`s. A wrong TCO would turn either into a `jmp`, dropping
# the count below 5. (clogger/index/length are lowered inline, not as calls.)
if [[ -x "$tmp/accept_poly.elf" ]]; then
    if ! command -v objdump >/dev/null 2>&1; then
        fail_test "disasm gate: objdump unavailable"
    else
        calls=$(objdump -D -b binary -m i386:x86-64 -M intel "$tmp/accept_poly.elf" 2>/dev/null | grep -cE 'call[[:space:]]+0x')
        if [[ "$calls" -eq 5 ]]; then
            pass=$((pass + 1))
        else
            fail_test "disasm gate: expected 5 direct calls (fault reached via call, not TCO'd), got $calls"
        fi
    fi
fi

echo ""
if [[ $fail -ne 0 ]]; then
    echo "$fail of $((pass + fail)) native-codegen-link9 sub-test(s) failed."
    exit 1
fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link9: $pass sub-tests: fault-as-bottom idiom compiles+runs byte-exact vs C across int/string/tuple/bool + mid-expression contexts incl. the trap path, renamed twin byte-identical, disasm gate fault=call-not-TCO'd)"
exit 0
