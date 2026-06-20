#!/usr/bin/env bash
# Native codegen Link 4 test: user calls, whole-program layout, native TCO,
# monomorphic signatures, wide displacements, and rel32 backedges.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
HERBERT="${HERBERT:-$repo_root/build/herbert}"
backend="$repo_root/stack/native_compile_fragment.herb"

if [[ "${NATIVE_CODEGEN_ORACLE:-golden}" == "c" && ! -x "$HERBERT" ]]; then
    echo "FAIL: stack/native_compile_fragment.herb (cannot find herbert at $HERBERT)"
    exit 1
fi

source "$script_dir/native_codegen_oracle.sh"
native_codegen_oracle_begin link4 || exit 1

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
native_codegen_ensure_compiler "$tmp/native-compiler" || exit 1

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
    oracle_expect_le64 "$(native_codegen_oracle_case_id "$out_file")" "$probe_file" "$rt_file" "$out_file"
}

# tollgate: compile a (possibly MUTATED) backend to a native compiler ELF with
# the C-free gen-1 seed, cached by content hash, so a mutated-backend probe is
# graded WITHOUT the C interpreter (the mutant used to be C-INTERPRETED as a
# compiler). Echoes the ELF path; nonzero rc on compile failure.
seed_compile_backend() {
    local be="$1" key be_elf cdir
    key="$(native_codegen_oracle_sha256 "$be")"
    be_elf="$tmp/be_compiler.$key.elf"
    if [[ ! -f "$be_elf" ]]; then
        cdir="$tmp/be_compiler.$key.cdir"; rm -rf "$cdir"; mkdir -p "$cdir"
        ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" <"$be" >/dev/null 2>&1 )
        [[ -f "$cdir/a.out" ]] || return 1
        cp "$cdir/a.out" "$be_elf"; chmod +x "$be_elf"
    fi
    printf '%s\n' "$be_elf"
}

compile_probe() {
    local label="$1" probe="$2" elf="$3" be="${4:-$backend}"
    local out="$tmp/${label}.out" err="$tmp/${label}.err"
    # D12: the compiler emits its ELF to a byte-pure file "a.out" (do fwriter), not
    # stdout. Run it in a per-label scratch dir and harvest that dir's a.out; a
    # missing a.out means the program was rejected before the emit. (Works for the
    # real backend and the forced-false / old-recognizer backends alike -- each
    # is the post-D12 backend with only nc_is_tail_call swapped, so main still
    # writes a.out.)
    local cdir="$tmp/${label}.cdir"
    rm -rf "$cdir"; mkdir -p "$cdir"
    if [[ "$be" == "$backend" ]]; then
        ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" <"$probe" >"$out" 2>"$err" )
    else
        # tollgate: seed-compile the mutated backend, then run it on the probe
        # (C-free); preserve C-interpretation as an opt-in a.out cross-check.
        local be_elf
        if ! be_elf="$(seed_compile_backend "$be")"; then
            echo "FAIL: stack/native_compile_fragment.herb (compile $label: seed did not compile mutated backend $(basename "$be"))"
            exit 1
        fi
        ( cd "$cdir" && "$be_elf" <"$probe" >"$out" 2>"$err" )
        if [[ "$NATIVE_CODEGEN_ORACLE" == "c" ]]; then
            local ccdir="$tmp/${label}.c.cdir"; rm -rf "$ccdir"; mkdir -p "$ccdir"
            ( cd "$ccdir" && "$HERBERT" "$be" <"$probe" >/dev/null 2>&1 )
            if [[ -f "$cdir/a.out" && -f "$ccdir/a.out" ]] && ! cmp -s "$cdir/a.out" "$ccdir/a.out"; then
                echo "FAIL: stack/native_compile_fragment.herb (compile $label: C cross-check a.out diverged from seed-compiled mutant)"
                exit 1
            fi
        fi
    fi
    if [[ ! -f "$cdir/a.out" ]]; then
        echo "FAIL: stack/native_compile_fragment.herb (compile $label rejected/no a.out: $(head -1 "$out"))"
        exit 1
    fi
    cp "$cdir/a.out" "$elf"
    chmod +x "$elf"
}

run_diff() {
    local label="$1" probe="$2" elf="$3" b0="$4" b1="$5"
    total=$((total + 1))
    local rt="$tmp/${label}_${b0}_${b1}.rt"
    local expected="$tmp/${label}_${b0}_${b1}.expected"
    local actual="$tmp/${label}_${b0}_${b1}.actual"
    write_rt "$rt" "$b0" "$b1"
    if ! oracle_le64 "$probe" "$rt" "$expected"; then
        fail_test "$label b0=$b0 b1=$b1 (C oracle failed)"
        return
    fi
    if ! "$elf" <"$rt" >"$actual" 2>/dev/null; then
        fail_test "$label b0=$b0 b1=$b1 (native exit nonzero)"
        return
    fi
    if ! cmp -s "$expected" "$actual"; then
        fail_test "$label b0=$b0 b1=$b1 (expected $(xxd -p "$expected" | tr -d '\n') got $(xxd -p "$actual" | tr -d '\n'))"
        return
    fi
    pass=$((pass + 1))
}

cat >"$tmp/diff.herb" <<'HERB'
func sub2(a, b):
    return a - b
end

func main():
    let input = clogger()
    let a = index(input, 0)
    let b = index(input, 1)
    let m = sub2(id(a), id(b))
    let r = 0
    if is_zero(a):
        r = bounded_self(5)
    elif less_than(b, 128):
        r = mutual_a(6)
    else:
        r = tail_even(10)
    end
    if less_than(a, b):
        return m + r
    else:
        return sub2(r, m)
    end
end

func id(x):
    return x
end

func is_zero(x):
    return x == 0
end

func less_than(x, y):
    return x < y
end

func bounded_self(n):
    if n == 0:
        return 1
    else:
        return 1 + bounded_self(n - 1)
    end
end

func mutual_a(n):
    if n == 0:
        return 2
    else:
        return 1 + mutual_b(n - 1)
    end
end

func mutual_b(n):
    if n == 0:
        return 3
    else:
        return 1 + mutual_a(n - 1)
    end
end

func tail_even(n):
    if n == 0:
        return 4
    else:
        return tail_odd(n - 1)
    end
end

func tail_odd(n):
    if n == 0:
        return 5
    else:
        return tail_even(n - 1)
    end
end
HERB

compile_probe diff "$tmp/diff.herb" "$tmp/diff.elf"
for pair in "0 0" "0 1" "1 0" "127 128" "128 127" "255 1" "1 255" "255 255"; do
    # shellcheck disable=SC2086
    run_diff recursive_diff "$tmp/diff.herb" "$tmp/diff.elf" $pair
done

cat >"$tmp/sum_tco.herb" <<'HERB'
func sum_to(acc, n):
    if n == 0:
        return acc
    else:
        return sum_to(acc + n, n - 1)
    end
end
func main():
    return sum_to(0, 1000000)
end
HERB

cat >"$tmp/mutual_tco.herb" <<'HERB'
func is_even(n):
    if n == 0:
        return true
    else:
        return is_odd(n - 1)
    end
end
func is_odd(n):
    if n == 0:
        return false
    else:
        return is_even(n - 1)
    end
end
func main():
    return is_even(2000000)
end
HERB

cat >"$tmp/branch_target_ret_tail.herb" <<'HERB'
func f(x):
    return x and f(false)
end
func main():
    if f(false):
        return 1
    else:
        return 2
    end
end
HERB

make_forced_false_backend() {
    local dst="$1"
    python3 - "$backend" "$dst" <<'PY'
from pathlib import Path
import sys
src = Path(sys.argv[1]).read_text()
start = src.index("func nc_is_tail_call(")
end = src.index("\nend\n", start) + len("\nend\n")
replacement = """func nc_is_tail_call(code, i, n):
    return false
end
"""
Path(sys.argv[2]).write_text(src[:start] + replacement + src[end:])
PY
}

make_old_branch_target_backend() {
    local dst="$1"
    python3 - "$backend" "$dst" <<'PY'
from pathlib import Path
import sys
src = Path(sys.argv[1]).read_text()
start = src.index("func nc_is_tail_call(")
end = src.index("\nend\n", start) + len("\nend\n")
replacement = """func nc_is_tail_call(code, i, n):
    if i + 1 >= n:
        return false
    end
    let instr = get(code, i)
    let next = get(code, i + 1)
    return instr.0 == 20 and next.0 == 21
end
"""
Path(sys.argv[2]).write_text(src[:start] + replacement + src[end:])
PY
}

run_tco_positive() {
    local label="$1" probe="$2" expected_hex="$3"
    total=$((total + 1))
    local elf="$tmp/${label}.elf" actual="$tmp/${label}.actual"
    compile_probe "$label" "$probe" "$elf"
    if ! (ulimit -s 1024; timeout 10s "$elf" >"$actual" 2>/dev/null); then
        fail_test "$label TCO positive (native failed under 1MB stack)"
        return
    fi
    if [[ "$(xxd -p "$actual" | tr -d '\n')" != "$expected_hex" ]]; then
        fail_test "$label TCO positive (expected $expected_hex got $(xxd -p "$actual" | tr -d '\n'))"
        return
    fi
    pass=$((pass + 1))
}

run_tco_negative() {
    local label="$1" probe="$2" be="$3"
    total=$((total + 1))
    local elf="$tmp/${label}.false.elf" actual="$tmp/${label}.false.actual"
    compile_probe "$label.false" "$probe" "$elf" "$be"
    bash -c 'ulimit -s 1024; timeout 5s "$1" >"$2" 2>/dev/null' bash "$elf" "$actual" 2>/dev/null
    local rc=$?
    if [[ $rc -eq 0 ]]; then
        fail_test "$label forced-false recognizer unexpectedly passed"
        return
    fi
    pass=$((pass + 1))
}

run_branch_target_ret_probe() {
    local fixed_be="$1" old_be="$2"
    total=$((total + 1))
    local elf="$tmp/branch_target_ret_tail.elf" actual="$tmp/branch_target_ret_tail.actual"
    compile_probe branch_target_ret_tail "$tmp/branch_target_ret_tail.herb" "$elf" "$fixed_be"
    if ! "$elf" >"$actual" 2>/dev/null; then
        fail_test "branch-target RET tail probe failed under fixed recognizer"
        return
    fi
    if [[ "$(xxd -p "$actual" | tr -d '\n')" != "320a" ]]; then
        fail_test "branch-target RET tail probe expected 2 got $(xxd -p "$actual" | tr -d '\n')"
        return
    fi
    local out="$tmp/branch_target_ret_tail.old.out" err="$tmp/branch_target_ret_tail.old.err"
    # tollgate: seed-compile the old-recognizer backend, then run it on the probe
    # (C-free) -- the old recognizer rejects the probe with ERR 415 at the
    # mutant-compiler's runtime, exactly as C-interpretation did. C preserved as
    # an opt-in byte cross-check under NATIVE_CODEGEN_ORACLE=c.
    local old_elf
    if ! old_elf="$(seed_compile_backend "$old_be")"; then
        fail_test "branch-target RET: seed did not compile old-recognizer backend"
        return
    fi
    "$old_elf" <"$tmp/branch_target_ret_tail.herb" >"$out" 2>"$err"
    if ! grep -q "ERR 415" "$out"; then
        fail_test "branch-target RET old recognizer should reject ERR 415, stdout=$(head -1 "$out") stderr=$(head -1 "$err")"
    elif [[ "$NATIVE_CODEGEN_ORACLE" == "c" ]] && ! { "$HERBERT" "$old_be" <"$tmp/branch_target_ret_tail.herb" >"$tmp/btr.cref" 2>/dev/null; cmp -s "$out" "$tmp/btr.cref"; }; then
        fail_test "branch-target RET old recognizer: C cross-check diverged from native (C=$(head -1 "$tmp/btr.cref"))"
    else
        pass=$((pass + 1))
    fi
}

forced_backend="$tmp/native_compile_no_tco.herb"
old_branch_target_backend="$tmp/native_compile_old_branch_target_tail.herb"
make_forced_false_backend "$forced_backend"
make_old_branch_target_backend "$old_branch_target_backend"
run_tco_positive self_sum "$tmp/sum_tco.herb" "3530303030303530303030300a"
run_tco_positive mutual_even "$tmp/mutual_tco.herb" "747275650a"
run_tco_negative self_sum "$tmp/sum_tco.herb" "$forced_backend"
run_tco_negative mutual_even "$tmp/mutual_tco.herb" "$forced_backend"
run_branch_target_ret_probe "$backend" "$old_branch_target_backend"

check_reject() {
    local label="$1" probe="$2"
    total=$((total + 1))
    local out="$tmp/reject_${label}.out" err="$tmp/reject_${label}.err"
    "$NATIVE_CODEGEN_COMPILER" <"$probe" >"$out" 2>"$err"
    if grep -qE 'ERR 4[0-9][0-9]' "$out"; then
        pass=$((pass + 1))
    else
        fail_test "reject $label: expected ERR 4xx, stdout=$(head -1 "$out"), stderr=$(head -1 "$err")"
    fi
}

cat >"$tmp/r_unknown.herb" <<'HERB'
func main():
    return nope()
end
HERB
cat >"$tmp/r_arity.herb" <<'HERB'
func f(x):
    return x
end
func main():
    return f()
end
HERB
cat >"$tmp/r_main.herb" <<'HERB'
func f():
    return main()
end
func main():
    return f()
end
HERB
cat >"$tmp/r_ret.herb" <<'HERB'
func f(x):
    if x:
        return 1
    else:
        return false
    end
end
func main():
    return f(true)
end
HERB
cat >"$tmp/r_dup.herb" <<'HERB'
func f():
    return 1
end
func f():
    return 2
end
func main():
    return f()
end
HERB
cat >"$tmp/r_builtin.herb" <<'HERB'
func length():
    return 1
end
func main():
    return 0
end
HERB
cat >"$tmp/r_clogger_nonmain.herb" <<'HERB'
func f():
    let input = clogger()
    return index(input, 0)
end
func main():
    return f()
end
HERB

for item in \
    "unknown r_unknown" "arity r_arity" "main_call r_main" \
    "return_conflict r_ret" \
    "duplicate r_dup" "builtin_collision r_builtin" \
    "clogger_nonmain r_clogger_nonmain"; do
    set -- $item
    check_reject "$1" "$tmp/$2.herb"
done

check_accept() {
    local label="$1" probe="$2" rt_hex="${3:-}"
    total=$((total + 1))
    local elf="$tmp/${label}.elf" rt="$tmp/${label}.rt" actual="$tmp/${label}.actual" expected="$tmp/${label}.expected"
    compile_probe "$label" "$probe" "$elf"
    printf '%b' "$(echo "$rt_hex" | sed 's/\(..\)/\\x\1/g')" >"$rt"
    if ! oracle_le64 "$probe" "$rt" "$expected"; then
        fail_test "accept $label (C oracle failed)"
        return
    fi
    if ! "$elf" <"$rt" >"$actual" 2>/dev/null; then
        fail_test "accept $label (native failed)"
        return
    fi
    if ! cmp -s "$expected" "$actual"; then
        fail_test "accept $label (expected $(xxd -p "$expected" | tr -d '\n') got $(xxd -p "$actual" | tr -d '\n'))"
        return
    fi
    pass=$((pass + 1))
}

cat >"$tmp/a_zero.herb" <<'HERB'
func forty():
    return 40
end
func main():
    return forty() + 2
end
HERB
cat >"$tmp/a_bool.herb" <<'HERB'
func pred(x):
    return x == 0
end
func main():
    let input = clogger()
    if pred(index(input, 0)):
        return 7
    else:
        return 9
    end
end
HERB
cat >"$tmp/a_wide.herb" <<'HERB'
func done():
    return 123
end
func take20(a0,a1,a2,a3,a4,a5,a6,a7,a8,a9,a10,a11,a12,a13,a14,a15,a16,a17,a18,a19):
    let z = a19
    return done()
end
func sum20(a0,a1,a2,a3,a4,a5,a6,a7,a8,a9,a10,a11,a12,a13,a14,a15,a16,a17,a18,a19):
    return a0 + a19
end
func start():
    return take20(1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20)
end
func main():
    let s = sum20(1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20)
    return start() + s
end
HERB

check_accept zero_arg "$tmp/a_zero.herb"
check_accept bool_helper "$tmp/a_bool.herb" "00"
check_accept wide_disp32 "$tmp/a_wide.herb"

total=$((total + 1))
gate_ok=1
dump="$tmp/disasm.txt"
rh="$tmp/readelf-h.txt"
rl="$tmp/readelf-l.txt"
objdump -D -b binary -m i386:x86-64 --adjust-vma=0x400000 "$tmp/wide_disp32.elf" >"$dump" 2>/dev/null || { fail_test "disasm gate objdump failed"; gate_ok=0; }
readelf -h "$tmp/wide_disp32.elf" >"$rh" 2>/dev/null || { fail_test "disasm gate readelf -h failed"; gate_ok=0; }
readelf -l "$tmp/wide_disp32.elf" >"$rl" 2>/dev/null || { fail_test "disasm gate readelf -l failed"; gate_ok=0; }
if [[ $gate_ok -eq 1 ]]; then grep -Fq "Type:                              EXEC" "$rh" || { fail_test "disasm gate not EXEC"; gate_ok=0; }; fi
if [[ $gate_ok -eq 1 ]]; then grep -Fq "Machine:                           Advanced Micro Devices X86-64" "$rh" || { fail_test "disasm gate not x86-64"; gate_ok=0; }; fi
if [[ $gate_ok -eq 1 ]]; then grep -Fq "Entry point address:               0x400078" "$rh" || { fail_test "disasm gate entry"; gate_ok=0; }; fi
if [[ $gate_ok -eq 1 ]]; then grep -Fq "Number of section headers:         0" "$rh" || { fail_test "disasm gate sections"; gate_ok=0; }; fi
if [[ $gate_ok -eq 1 ]]; then grep -qE 'R E' "$rl" || { fail_test "disasm gate no R E LOAD"; gate_ok=0; }; fi
if [[ $gate_ok -eq 1 ]]; then grep -qE '\bcall\b' "$dump" || { fail_test "disasm gate no non-tail call"; gate_ok=0; }; fi
if [[ $gate_ok -eq 1 ]]; then
    self_dump="$tmp/self_sum.dump"
    objdump -D -b binary -m i386:x86-64 --adjust-vma=0x400000 "$tmp/self_sum.elf" >"$self_dump" 2>/dev/null || { fail_test "disasm gate self_sum objdump failed"; gate_ok=0; }
    grep -qE '\bjmp\b' "$self_dump" || { fail_test "disasm gate no self-tail jmp"; gate_ok=0; }
fi
if [[ $gate_ok -eq 1 ]]; then grep -qE '\bleave\b' "$dump" && grep -qE '\bret\b' "$dump" || { fail_test "disasm gate no leave/ret"; gate_ok=0; }; fi
if [[ $gate_ok -eq 1 ]]; then grep -qE '0x[0-9a-f]+\(%rbp\)' "$dump" || { fail_test "disasm gate no disp32 rbp access"; gate_ok=0; }; fi
if [[ $gate_ok -eq 1 ]]; then grep -qE 'set(b|be|a|ae|e|ne)\\s+%dl' "$tmp/diff.dump" 2>/dev/null || true; fi
if [[ $gate_ok -eq 1 ]]; then
    filesz=$(awk '/LOAD/ { getline; print $1; exit }' "$rl")
    memsz=$(awk '/LOAD/ { getline; print $2; exit }' "$rl")
    [[ "$filesz" == "$memsz" ]] || { fail_test "disasm gate FileSiz/MemSiz"; gate_ok=0; }
fi
if [[ $gate_ok -eq 1 ]]; then
    # D12 byte-purity: emitted file is EXACTLY the page-padded image, no trailer.
    filesz_dec=$(python3 -c "print(int('$filesz', 16))")
    actual_size=$(wc -c < "$tmp/wide_disp32.elf")
    [[ "$actual_size" -eq "$filesz_dec" ]] || { fail_test "byte-purity gate (file size $actual_size != image size $filesz_dec; trailer present?)"; gate_ok=0; }
fi
if [[ $gate_ok -eq 1 ]]; then
    pass=$((pass + 1))
    echo "PASS: stack/native_compile_fragment.herb (link4 disasm gate: ELF, real call/ret, tail jmp, disp32, byte-pure size==image)"
fi

echo ""
if [[ $fail -ne 0 ]]; then
    echo "$fail of $((pass + fail)) native-codegen-link4 sub-test(s) failed."
    exit 1
fi
if ! native_codegen_oracle_finish; then
    exit 1
fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link4: $pass sub-tests: recursive differential, self+mutual TCO tethers with forced-false negative proofs, branch-target RET tail guard, rejection battery, anti-over-rejection incl. wide disp32, disasm gate)"
exit 0
