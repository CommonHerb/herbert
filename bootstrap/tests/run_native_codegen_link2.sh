#!/usr/bin/env bash
# Native codegen Link 2 test: Herbert compiles a straight-line integer subset
# program to a native x86-64 ELF; tests differential correctness, disassembly
# gate, and verifier rejection battery.
#
# Probes use the input-ALIAS form:
#   let input = clogger()
#   ... index(input,0) ...
# The differential oracle is the REAL C bootstrap (build/herbert), restored after
# the first build's Python-oracle regression was caught at conductor reconciliation.
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
native_codegen_oracle_begin link2 || exit 1

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

# ====================================================================
# Probes -- input-ALIAS form (single clogger() call, result aliased)
# ====================================================================
cat > "$tmp/p1.herb" << 'HERB'
func main():
    let input = clogger()
    return index(input,0) + index(input,1)
end
HERB

cat > "$tmp/p2.herb" << 'HERB'
func main():
    let input = clogger()
    let a = index(input,0)
    let b = index(input,1)
    return a < b
end
HERB

cat > "$tmp/p3.herb" << 'HERB'
func main():
    let input = clogger()
    return index(input,0) - index(input,1)
end
HERB

# Compile each probe once.
# D12: the compiler emits its ELF to a byte-pure file "a.out" (do fwriter), not to
# stdout; stdout now carries only the host return-word trailer. Run the compiler in
# a per-probe scratch dir and harvest that dir's a.out. A rejected program writes
# NO a.out (it returns before the emit), so a missing a.out IS the rejection signal.
for probe_name in p1 p2 p3; do
    probe="$tmp/$probe_name.herb"
    elf="$tmp/$probe_name.elf"
    err_file="$tmp/$probe_name.compile.err"
    out_file="$tmp/$probe_name.compile.out"
    cdir="$tmp/$probe_name.cdir"
    rm -rf "$cdir"; mkdir -p "$cdir"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < "$probe" > "$out_file" 2>"$err_file" )
    rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "FAIL: stack/native_compile_fragment.herb (compile $probe_name failed: $(cat "$err_file" | head -1))"
        exit 1
    fi
    if [[ ! -f "$cdir/a.out" ]]; then
        echo "FAIL: stack/native_compile_fragment.herb (compile $probe_name: no a.out emitted (unexpected rejection?): $(head -1 "$out_file"))"
        exit 1
    fi
    cp "$cdir/a.out" "$elf"
    chmod +x "$elf"
done

# ====================================================================
# Oracle: REAL C bootstrap (not Python arithmetic)
# Run build/herbert probe.herb < RT, parse its stdout, pack to LE64.
# C bootstrap prints: int -> unsigned decimal; bool -> true/false.
# Pack: int value -> 8 LE bytes; bool true -> 01 00 00 00 00 00 00 00 ;
#       bool false -> 00 00 00 00 00 00 00 00.
# ====================================================================
oracle_le64() {
    local probe_file="$1"
    local rt_file="$2"
    local out_file="$3"
    oracle_expect_le64 "$(native_codegen_oracle_case_id "$out_file")" "$probe_file" "$rt_file" "$out_file"
}

# ====================================================================
# Differential
# ====================================================================
run_differential() {
    local probe_name="$1"
    local b0="$2"
    local b1="$3"
    local label="differential $probe_name b0=0x$(printf '%02x' "$b0") b1=0x$(printf '%02x' "$b1")"
    total=$((total + 1))

    local elf="$tmp/$probe_name.elf"
    local probe_file="$tmp/$probe_name.herb"
    local rt="$tmp/rt_${probe_name}_${b0}_${b1}.bin"
    local actual="$tmp/actual_${probe_name}_${b0}_${b1}.bin"
    local expected="$tmp/expected_${probe_name}_${b0}_${b1}.bin"

    LC_ALL=C printf "\\$(printf '%03o' "$b0")\\$(printf '%03o' "$b1")" > "$rt"

    if ! oracle_le64 "$probe_file" "$rt" "$expected"; then
        fail_test "$label (C bootstrap oracle failed)"
        return
    fi
    if ! "$elf" < "$rt" > "$actual" 2>/dev/null; then
        fail_test "$label (native exit non-zero)"
        return
    fi
    if ! cmp -s "$expected" "$actual"; then
        fail_test "$label (LE64 mismatch: expected $(xxd -p "$expected") got $(xxd -p "$actual"))"
        return
    fi
    pass=$((pass + 1))
}

# P1: add (including wrapping)
run_differential "p1" 65 66
run_differential "p1" 255 255
run_differential "p1" 128 128
run_differential "p1" 0 1
run_differential "p1" 127 128
run_differential "p1" 0 0
run_differential "p1" 255 1

# P2: unsigned compare (including the boundary that catches signed bugs)
run_differential "p2" 0 1
run_differential "p2" 1 0
run_differential "p2" 255 1
run_differential "p2" 1 255
run_differential "p2" 128 128
run_differential "p2" 0 255
run_differential "p2" 255 0

# P3: sub/wrap
run_differential "p3" 0 1
run_differential "p3" 5 3
run_differential "p3" 128 128
run_differential "p3" 255 0

# ====================================================================
# White-box disassembly gate (P2 has comparison, P1 has add, P3 has sub)
# ====================================================================
total=$((total + 1))
gate_ok=1

rh="$tmp/readelf-h.txt"
rl="$tmp/readelf-l.txt"
gate_elf="$tmp/p2.elf"

readelf -h "$gate_elf" >"$rh" 2>/dev/null || { fail_test "disassembly gate (readelf -h failed)"; gate_ok=0; }
readelf -l "$gate_elf" >"$rl" 2>/dev/null || { fail_test "disassembly gate (readelf -l failed)"; gate_ok=0; }

if [[ $gate_ok -eq 1 ]]; then
    grep -Fq "Type:                              EXEC" "$rh"            || { fail_test "disassembly gate (not EXEC)"; gate_ok=0; }
fi
if [[ $gate_ok -eq 1 ]]; then
    grep -Fq "Machine:                           Advanced Micro Devices X86-64" "$rh" || { fail_test "disassembly gate (not x86-64)"; gate_ok=0; }
fi
if [[ $gate_ok -eq 1 ]]; then
    grep -Fq "Entry point address:               0x400078" "$rh"       || { fail_test "disassembly gate (entry != 0x400078)"; gate_ok=0; }
fi
if [[ $gate_ok -eq 1 ]]; then
    grep -Fq "Number of program headers:         1" "$rh"              || { fail_test "disassembly gate (phnum != 1)"; gate_ok=0; }
fi
if [[ $gate_ok -eq 1 ]]; then
    grep -Fq "Number of section headers:         0" "$rh"              || { fail_test "disassembly gate (shnum != 0)"; gate_ok=0; }
fi
if [[ $gate_ok -eq 1 ]]; then
    grep -qE 'R E' "$rl"                                               || { fail_test "disassembly gate (no R E LOAD segment)"; gate_ok=0; }
fi
if [[ $gate_ok -eq 1 ]]; then
    # FileSiz = MemSiz
    filesz=$(grep -oE 'FileSiz[[:space:]]+0x[0-9a-f]+' "$rl" | grep -oE '0x[0-9a-f]+' | head -1)
    memsz=$(grep -oE 'MemSiz[[:space:]]+0x[0-9a-f]+' "$rl" | grep -oE '0x[0-9a-f]+' | head -1)
    if [[ "$filesz" != "$memsz" ]]; then
        fail_test "disassembly gate (FileSiz=$filesz != MemSiz=$memsz)"
        gate_ok=0
    fi
fi
if [[ $gate_ok -eq 1 ]]; then
    # D12 byte-purity: the emitted file is EXACTLY the page-padded ELF image with
    # NO host trailer appended (do fwriter writes only the image bytes; the host
    # return-word trailer goes to stdout, a separate stream). So the on-disk file
    # size equals the LOAD image size -- there is no byte at offset filesz.
    filesz_dec=$(python3 -c "print(int('$filesz', 16))" 2>/dev/null)
    actual_size=$(wc -c < "$gate_elf")
    if [[ -n "$filesz_dec" && "$actual_size" -ne "$filesz_dec" ]]; then
        fail_test "byte-purity gate (file size $actual_size != image size $filesz_dec; trailer present?)"
        gate_ok=0
    fi
fi

dump2="$tmp/objdump_p2.txt"
dump1="$tmp/objdump_p1.txt"
dump3="$tmp/objdump_p3.txt"
objdump -D -b binary -m i386:x86-64 --adjust-vma=0x400000 "$gate_elf" >"$dump2" 2>/dev/null
objdump -D -b binary -m i386:x86-64 --adjust-vma=0x400000 "$tmp/p1.elf" >"$dump1" 2>/dev/null
objdump -D -b binary -m i386:x86-64 --adjust-vma=0x400000 "$tmp/p3.elf" >"$dump3" 2>/dev/null

if [[ $gate_ok -eq 1 ]]; then
    # read syscall: xor eax,eax then syscall
    grep -qE 'xor\s+%eax,%eax' "$dump2" || { fail_test "disassembly gate (no xor eax,eax for read in P2)"; gate_ok=0; }
fi
if [[ $gate_ok -eq 1 ]]; then
    # unsigned setcc present in P2 (setb/setbe/seta/setae/sete/setne)
    grep -qE 'set(b|be|a|ae|e|ne)\s+%dl' "$dump2" || { fail_test "disassembly gate (no unsigned setcc in P2)"; gate_ok=0; }
fi
if [[ $gate_ok -eq 1 ]]; then
    # NO signed setcc (setl/setg/setle/setge)
    if grep -qE 'set(l|g|le|ge)\s+%dl' "$dump2"; then
        fail_test "disassembly gate (signed setcc found in P2!)"
        gate_ok=0
    fi
fi
if [[ $gate_ok -eq 1 ]]; then
    # write syscall (eax=1)
    grep -qE 'mov\s+\$0x1,%eax' "$dump2" || { fail_test "disassembly gate (no write syscall in P2)"; gate_ok=0; }
fi
if [[ $gate_ok -eq 1 ]]; then
    # exit_group (eax=231=0xe7)
    grep -qE 'mov\s+\$0xe7,%eax' "$dump2" || { fail_test "disassembly gate (no exit_group in P2)"; gate_ok=0; }
fi
if [[ $gate_ok -eq 1 ]]; then
    # add in P1
    grep -qE 'add\s+%rcx,%rax' "$dump1" || { fail_test "disassembly gate (no add %rcx,%rax in P1)"; gate_ok=0; }
fi
if [[ $gate_ok -eq 1 ]]; then
    # sub in P3
    grep -qE 'sub\s+%rcx,%rax' "$dump3" || { fail_test "disassembly gate (no sub %rcx,%rax in P3)"; gate_ok=0; }
fi

if [[ $gate_ok -eq 1 ]]; then
    pass=$((pass + 1))
    echo "PASS: stack/native_compile_fragment.herb (disassembly gate: read+add/sub+unsigned-setcc+write+exit_group; ELF EXEC/x86-64/0x400078/one-LOAD/FileSiz=MemSiz; byte-pure file size==image size)"
fi

# ====================================================================
# Rejection battery
# ====================================================================
check_reject() {
    local label="$1"
    local probe_file="$2"
    total=$((total + 1))
    local out_file="$tmp/reject_${label}.elf"
    local err_file="$tmp/reject_${label}.err"
    "$NATIVE_CODEGEN_COMPILER" < "$probe_file" > "$out_file" 2>"$err_file"
    # Diagnostic goes to stdout (via flogger); check there
    if grep -qE 'ERR 4[0-9][0-9]' "$out_file"; then
        pass=$((pass + 1))
    else
        fail_test "reject $label: expected 4xx diagnostic, stdout: $(head -1 "$out_file"), stderr: $(head -1 "$err_file")"
    fi
}

check_reject_code() {
    local label="$1"
    local code="$2"
    local probe_file="$3"
    total=$((total + 1))
    local out_file="$tmp/reject_${label}.elf"
    local err_file="$tmp/reject_${label}.err"
    "$NATIVE_CODEGEN_COMPILER" < "$probe_file" > "$out_file" 2>"$err_file"
    if grep -q "ERR $code" "$out_file"; then
        pass=$((pass + 1))
    else
        fail_test "reject $label: expected ERR $code, stdout: $(head -1 "$out_file"), stderr: $(head -1 "$err_file")"
    fi
}

# Create rejection probes
# rj02: a bare heap HANDLE returned. (filigree/link12 made a bare STRING render, so
# `return clogger()` is now valid; a BUFFER is still non-renderable, so returning it
# bare remains ERR432 -- the bare-handle-escape boundary still bites.)
cat > "$tmp/rj02.herb" << 'HERB'
func main():
    let b = new_buffer()
    return b
end
HERB
# rj08: flogger-of-int remains illegal after flogger string output support.
cat > "$tmp/rj08.herb" << 'HERB'
func main():
    let input = clogger()
    do flogger(index(input,0))
    return 0
end
HERB
# rj10: two clogger() calls (double-clogger -- new rejection ERR 411)
cat > "$tmp/rj10.herb" << 'HERB'
func main():
    let a = clogger()
    let b = clogger()
    return index(a,0) + index(b,1)
end
HERB
cat > "$tmp/rj12.herb" << 'HERB'
func main(x):
    return x
end
HERB

check_reject "handle_escape"    "$tmp/rj02.herb"
check_reject_code "flogger_int" 430 "$tmp/rj08.herb"
check_reject "double_clogger"   "$tmp/rj10.herb"
check_reject "params"           "$tmp/rj12.herb"

# ====================================================================
# Anti-over-rejection: accepted probes compile and run
# Expected values computed from C bootstrap oracle
# P1: 'A'(65)+'B'(66)=131 -> 83 00 00 00 00 00 00 00
# P2: 0x01 < 0xff -> true -> 1 -> 01 00 00 00 00 00 00 00
# P3: 0x00 - 0x01 = -1 (wrap) -> ff ff ff ff ff ff ff ff
# ====================================================================
check_accept() {
    local label="$1"
    local probe_file="$2"
    local rt_hex="$3"
    local expected_hex="$4"
    total=$((total + 1))
    local elf_file="$tmp/accept_${label}.elf"
    local err_file="$tmp/accept_${label}.err"
    local out_file="$tmp/accept_${label}.compile.out"
    local rt_file="$tmp/accept_${label}.rt"
    local actual_file="$tmp/accept_${label}.actual"
    local expected_file="$tmp/accept_${label}.expected"

    local cdir="$tmp/accept_${label}.cdir"
    rm -rf "$cdir"; mkdir -p "$cdir"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < "$probe_file" > "$out_file" 2>"$err_file" )
    if [[ ! -f "$cdir/a.out" ]]; then
        fail_test "accept $label: no a.out emitted (unexpected rejection?): $(head -1 "$out_file")"
        return
    fi
    cp "$cdir/a.out" "$elf_file"
    chmod +x "$elf_file"
    printf '%b' "$(echo "$rt_hex" | sed 's/\(..\)/\\x\1/g')" > "$rt_file"

    # Get expected from C bootstrap oracle
    if ! oracle_le64 "$probe_file" "$rt_file" "$expected_file"; then
        fail_test "accept $label: C bootstrap oracle failed"
        return
    fi
    local oracle_hex
    oracle_hex=$(xxd -p "$expected_file" | tr -d '\n')
    # Sanity check: oracle must match the hardcoded expected_hex
    if [[ "$oracle_hex" != "$expected_hex" ]]; then
        fail_test "accept $label: oracle $oracle_hex != hardcoded $expected_hex (update test)"
        return
    fi

    if ! "$elf_file" < "$rt_file" > "$actual_file" 2>/dev/null; then
        fail_test "accept $label: native exit non-zero"
        return
    fi
    local actual_hex
    actual_hex=$(xxd -p "$actual_file" | tr -d '\n')
    if [[ "$actual_hex" != "$expected_hex" ]]; then
        fail_test "accept $label: expected $expected_hex got $actual_hex"
        return
    fi
    pass=$((pass + 1))
}

check_accept "p1_add" "$tmp/p1.herb" "4142" "3133310a"
check_accept "p2_lt"  "$tmp/p2.herb" "01ff" "747275650a"
check_accept "p3_sub" "$tmp/p3.herb" "0001" "31383434363734343037333730393535313631350a"

# ====================================================================
# Report
# ====================================================================
echo ""
if [[ $fail -ne 0 ]]; then
    echo "$fail of $((pass + fail)) native-codegen-link2 sub-test(s) failed."
    exit 1
fi
if ! native_codegen_oracle_finish; then
    exit 1
fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link2: $pass sub-tests: differential P1/P2/P3 x boundary inputs vs C bootstrap oracle; disassembly gate; 6-probe rejection battery incl. double-clogger + 3 anti-over-rejection; string/tuple/length/nonlit-index/inline-clogger rejects retired -- now in-subset at mercer Link 5)"
exit 0
