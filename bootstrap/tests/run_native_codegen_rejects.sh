#!/usr/bin/env bash
# Consolidated native-codegen reject and boundary battery. Stable rejects assert
# exact current ERR codes; frontier cases document the not-yet subset boundary.
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
total=0

fail_test() {
    echo "FAIL: stack/native_compile_fragment.herb ($1)"
    fail=$((fail + 1))
}

check_source_reject_code() {
    local label="$1"
    local code="$2"
    local probe="$3"
    total=$((total + 1))
    local out="$tmp/reject_${label}.out"
    local err="$tmp/reject_${label}.err"
    "$HERBERT" "$backend" <"$probe" >"$out" 2>"$err"
    local magic
    magic=$(head -c4 "$out" | xxd -p | tr -d '\n')
    if [[ "$magic" == "7f454c46" ]]; then
        fail_test "reject $label: unexpectedly emitted ELF"
        return
    fi
    if grep -q "ERR $code" "$out"; then
        pass=$((pass + 1))
    else
        fail_test "reject $label: expected ERR $code, stdout=$(head -1 "$out"), stderr=$(head -1 "$err")"
    fi
}

check_driver_reject_code() {
    local label="$1"
    local code="$2"
    local driver="$3"
    total=$((total + 1))
    local out="$tmp/driver_${label}.out"
    local err="$tmp/driver_${label}.err"
    "$HERBERT" "$driver" >"$out" 2>"$err"
    if grep -q "ERR $code" "$out"; then
        pass=$((pass + 1))
    else
        fail_test "driver reject $label: expected ERR $code, stdout=$(head -1 "$out"), stderr=$(head -1 "$err")"
    fi
}

compile_probe() {
    local label="$1"
    local probe="$2"
    local elf="$3"
    local out="$tmp/${label}.compile.out"
    local err="$tmp/${label}.compile.err"
    "$HERBERT" "$backend" <"$probe" >"$out" 2>"$err"
    local magic
    magic=$(head -c4 "$out" | xxd -p | tr -d '\n')
    if [[ "$magic" != "7f454c46" ]]; then
        fail_test "compile $label rejected or did not emit ELF: stdout=$(head -1 "$out"), stderr=$(head -1 "$err")"
        return 1
    fi
    cp "$out" "$elf"
    chmod +x "$elf"
    return 0
}

check_runtime_frontier_cap() {
    local label="$1"
    local probe="$2"
    local elf="$tmp/${label}.elf"
    compile_probe "$label" "$probe" "$elf" || return
    # beaver lifted the 64 KiB stack-arena cap: native clogger now reads into the
    # 16 MiB heap. (a) the old 64 KiB frontier now SUCCEEDS == C (obsolete-proof);
    # (b) the exact 16 MiB heap cap succeeds == C; (c) the new frontier (> 16 MiB)
    # faults native (nonzero, empty stdout) while C, which has no fixed cap, succeeds.
    local sizes=(65537 16777216 16777217)
    local kinds=(obsolete_64k exact_16M over_16M)
    local i=0
    while [[ $i -lt 3 ]]; do
        total=$((total + 1))
        local sz="${sizes[$i]}" kind="${kinds[$i]}"
        python3 -c "import sys;sys.stdout.buffer.write(b'x'*${sz})" >"$tmp/${label}.${kind}.in"
        "$elf" <"$tmp/${label}.${kind}.in" >"$tmp/${label}.${kind}.n" 2>/dev/null
        local nrc=$?
        "$HERBERT" "$probe" <"$tmp/${label}.${kind}.in" >"$tmp/${label}.${kind}.c" 2>/dev/null
        local crc=$?
        if [[ "$kind" == "over_16M" ]]; then
            if [[ $nrc -ne 0 && ! -s "$tmp/${label}.${kind}.n" && $crc -eq 0 ]]; then
                pass=$((pass + 1))
            else
                fail_test "frontier $label $kind: ${sz} B must fault native (rc=$nrc) while C succeeds (rc=$crc)"
            fi
        else
            python3 -c "import sys;sys.stdout.buffer.write(int((open('$tmp/${label}.${kind}.c').read().strip() or '0')).to_bytes(8,'little'))" >"$tmp/${label}.${kind}.cle" 2>/dev/null
            if [[ $nrc -eq 0 ]] && cmp -s "$tmp/${label}.${kind}.n" "$tmp/${label}.${kind}.cle"; then
                pass=$((pass + 1))
            else
                fail_test "frontier $label $kind: ${sz} B must succeed == C (native rc=$nrc)"
            fi
        fi
        i=$((i + 1))
    done
}

# Stable / permanently-out source rejects.
cat >"$tmp/r_slice.herb" <<'HERB'
func main():
    return slice("abc", 0, 1)
end
HERB
cat >"$tmp/r_return_append.herb" <<'HERB'
func main():
    return append(new_buffer(), 1)
end
HERB
cat >"$tmp/r_return_add.herb" <<'HERB'
func main():
    return add(new_array(int), 1)
end
HERB
cat >"$tmp/r_return_flogger.herb" <<'HERB'
func main():
    return flogger("x")
end
HERB
cat >"$tmp/r_flogger_zero.herb" <<'HERB'
func main():
    do flogger()
    return 0
end
HERB
cat >"$tmp/r_flogger_two.herb" <<'HERB'
func main():
    do flogger("a", "b")
    return 0
end
HERB
cat >"$tmp/r_flogger_int.herb" <<'HERB'
func main():
    do flogger(1)
    return 0
end
HERB
cat >"$tmp/r_flogger_bool.herb" <<'HERB'
func main():
    do flogger(true)
    return 0
end
HERB
cat >"$tmp/r_flogger_tuple.herb" <<'HERB'
func main():
    do flogger((1, 2))
    return 0
end
HERB
cat >"$tmp/r_flogger_array.herb" <<'HERB'
func main():
    let a = new_array(int)
    do flogger(a)
    return 0
end
HERB
cat >"$tmp/r_flogger_buffer.herb" <<'HERB'
func main():
    let b = new_buffer()
    do flogger(b)
    return 0
end
HERB
cat >"$tmp/r_get_non_array.herb" <<'HERB'
func main():
    return get(1, 0)
end
HERB
cat >"$tmp/r_count_non_array.herb" <<'HERB'
func main():
    return count(1)
end
HERB
cat >"$tmp/r_add_non_array.herb" <<'HERB'
func main():
    do add(1, 2)
    return 0
end
HERB
cat >"$tmp/r_array_elem_mismatch.herb" <<'HERB'
func main():
    let a = new_array(int)
    do add(a, "x")
    return 0
end
HERB
cat >"$tmp/r_append_non_buffer.herb" <<'HERB'
func main():
    do append(1, 2)
    return 0
end
HERB
cat >"$tmp/r_freeze_non_buffer.herb" <<'HERB'
func main():
    return freeze(1)
end
HERB
cat >"$tmp/r_unconstrained_signature.herb" <<'HERB'
func id(x):
    return x
end

func main():
    return 1
end
HERB
cat >"$tmp/r_call_conflict.herb" <<'HERB'
func id(x):
    return x
end

func main():
    let a = id(1)
    let b = id("x")
    return a
end
HERB
cat >"$tmp/r_monomorph.herb" <<'HERB'
func main():
    let a = new_array(int)
    if true:
        a = new_array(string)
    end
    return 0
end
HERB
cat >"$tmp/r_main_string.herb" <<'HERB'
func main():
    return "x"
end
HERB
cat >"$tmp/r_main_tuple.herb" <<'HERB'
func main():
    return (1, 2)
end
HERB

check_source_reject_code stable_slice 438 "$tmp/r_slice.herb"
check_source_reject_code value_append 440 "$tmp/r_return_append.herb"
check_source_reject_code value_add 440 "$tmp/r_return_add.herb"
check_source_reject_code value_flogger 440 "$tmp/r_return_flogger.herb"
check_source_reject_code flogger_zero_arity 420 "$tmp/r_flogger_zero.herb"
check_source_reject_code flogger_two_arity 420 "$tmp/r_flogger_two.herb"
check_source_reject_code flogger_int 430 "$tmp/r_flogger_int.herb"
check_source_reject_code flogger_bool 430 "$tmp/r_flogger_bool.herb"
check_source_reject_code flogger_tuple 430 "$tmp/r_flogger_tuple.herb"
check_source_reject_code flogger_array 430 "$tmp/r_flogger_array.herb"
check_source_reject_code flogger_buffer 430 "$tmp/r_flogger_buffer.herb"
check_source_reject_code get_non_array 435 "$tmp/r_get_non_array.herb"
check_source_reject_code count_non_array 435 "$tmp/r_count_non_array.herb"
check_source_reject_code add_non_array 435 "$tmp/r_add_non_array.herb"
check_source_reject_code array_elem_mismatch 436 "$tmp/r_array_elem_mismatch.herb"
check_source_reject_code append_non_buffer 437 "$tmp/r_append_non_buffer.herb"
check_source_reject_code freeze_non_buffer 437 "$tmp/r_freeze_non_buffer.herb"
check_source_reject_code unconstrained_signature 424 "$tmp/r_unconstrained_signature.herb"
check_source_reject_code call_conflict 430 "$tmp/r_call_conflict.herb"
check_source_reject_code monomorph 436 "$tmp/r_monomorph.herb"
check_source_reject_code main_string 432 "$tmp/r_main_string.herb"
check_source_reject_code main_tuple 432 "$tmp/r_main_tuple.herb"

# Malformed bytecode / metadata drivers.
awk '/^func main\(\):$/ { exit } { print }' "$backend" >"$tmp/stack_underflow_driver.herb"
cat >>"$tmp/stack_underflow_driver.herb" <<'HERB'
func main():
    let type_pool = nc_type_pool_new()
    let funcs = new_array((string, int, int, int, array((int, int, int)), array(int)))
    let code = new_array((int, int, int))
    do add(code, (21, 0, 0))
    let meta = new_array(int)
    do add(meta, 0)
    do add(funcs, ("main", 0, 0, 0, code, meta))
    let strings = new_array(string)
    let prog = (funcs, strings, 0)
    let params = new_array(array(int))
    let returns = new_array(int)
    do add(params, new_array(int))
    do add(returns, nc_type_int())
    let sig = (params, returns)
    let r = nc_analyze_program(type_pool, prog, sig)
    return 0
end
HERB

awk '/^func main\(\):$/ { exit } { print }' "$backend" >"$tmp/layout_418_driver.herb"
cat >>"$tmp/layout_418_driver.herb" <<'HERB'
func main():
    let source = "func main():\n    return 0\nend\n"
    let tokens = lex_source(source)
    let nodes = pool_new()
    let parsed = parse_program(tokens, 0, nodes)
    let type_pool = nc_type_pool_new()
    let ast_result = nc_verify_ast(nodes, parsed.0, type_pool)
    let prog = lower_program(nodes, parsed.0, type_pool)
    let analyzed = nc_analyze_program(type_pool, prog, ast_result.1)
    let pass1 = nc_pass1_program(prog, analyzed.1, analyzed.2, analyzed.3)
    let layouts = pass1.1
    let main_layout = get(layouts, prog.2)
    let bad_layout = (main_layout.0, main_layout.1, main_layout.2, main_layout.3, main_layout.4, main_layout.5 + 1)
    let bad_layouts = new_array((int, array(int), array(int), int, int, int))
    do add(bad_layouts, bad_layout)
    let emitted = nc_emit_function(new_buffer(), get(prog.0, prog.2), prog.0, get(analyzed.1, prog.2), analyzed.1, bad_layout, bad_layouts, prog.1, pass1.2)
    return 0
end
HERB

awk '/^func main\(\):$/ { exit } { print }' "$backend" >"$tmp/missing_meta_driver.herb"
cat >>"$tmp/missing_meta_driver.herb" <<'HERB'
func main():
    let type_pool = nc_type_pool_new()
    let funcs = new_array((string, int, int, int, array((int, int, int)), array(int)))
    let code = new_array((int, int, int))
    do add(code, (28, 0, 0))
    do add(code, (21, 0, 0))
    let missing = new_array(int)
    do add(funcs, ("main", 0, 0, 0, code, missing))
    let strings = new_array(string)
    let prog = (funcs, strings, 0)
    let params = new_array(array(int))
    let returns = new_array(int)
    do add(params, new_array(int))
    do add(returns, nc_type_int())
    let sig = (params, returns)
    let r = nc_analyze_program(type_pool, prog, sig)
    return 0
end
HERB

check_driver_reject_code malformed_stack_underflow 416 "$tmp/stack_underflow_driver.herb"
check_driver_reject_code malformed_layout_length 418 "$tmp/layout_418_driver.herb"
check_driver_reject_code malformed_new_array_metadata 439 "$tmp/missing_meta_driver.herb"

# Frontier / not-yet boundary.
cat >"$tmp/r_multi_clogger.herb" <<'HERB'
func main():
    let a = clogger()
    let b = clogger()
    return length(a) + length(b)
end
HERB
cat >"$tmp/r_helper_clogger.herb" <<'HERB'
func f():
    return clogger()
end

func main():
    return length(f())
end
HERB
cat >"$tmp/frontier_cap.herb" <<'HERB'
func main():
    let s = clogger()
    if length(s) == 0:
        return 0
    end
    return index(s, 0)
end
HERB

check_source_reject_code frontier_multi_clogger 411 "$tmp/r_multi_clogger.herb"
check_source_reject_code frontier_helper_clogger 404 "$tmp/r_helper_clogger.herb"
check_runtime_frontier_cap frontier_clogger_arena_cap "$tmp/frontier_cap.herb"

echo ""
if [[ $fail -ne 0 ]]; then
    echo "$fail of $((pass + fail)) native-codegen-reject sub-test(s) failed."
    exit 1
fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen rejects: $pass sub-tests: stable 420/424/430/432/435/436/437/438/439/440 boundaries plus frontier clogger limits)"
exit 0
