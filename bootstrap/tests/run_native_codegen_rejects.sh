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

source "$script_dir/native_codegen_oracle.sh"
native_codegen_oracle_begin rejects || exit 1

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

check_source_reject_code() {
    local label="$1"
    local code="$2"
    local probe="$3"
    total=$((total + 1))
    local out="$tmp/reject_${label}.out"
    local err="$tmp/reject_${label}.err"
    "$NATIVE_CODEGEN_COMPILER" <"$probe" >"$out" 2>"$err"
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

check_source_reject_code_once() {
    local label="$1"
    local code="$2"
    local probe="$3"
    total=$((total + 1))
    local out="$tmp/reject_${label}.out"
    local err="$tmp/reject_${label}.err"
    "$NATIVE_CODEGEN_COMPILER" <"$probe" >"$out" 2>"$err"
    local magic
    magic=$(head -c4 "$out" | xxd -p | tr -d '\n')
    if [[ "$magic" == "7f454c46" ]]; then
        fail_test "reject $label: unexpectedly emitted ELF"
        return
    fi
    local err_count diag_count
    err_count=$(grep -c "ERR " "$out" || true)
    diag_count=$(grep -c "native-subset:" "$out" || true)
    if grep -q "ERR $code" "$out" && [[ "$err_count" -eq 1 && "$diag_count" -eq 1 ]]; then
        pass=$((pass + 1))
    else
        fail_test "reject $label: expected exactly one ERR $code diagnostic, err_count=$err_count diag_count=$diag_count stdout=$(head -2 "$out" | tr '\n' '|'), stderr=$(head -1 "$err")"
    fi
}

check_driver_reject_code() {
    local label="$1"
    local code="$2"
    local driver="$3"
    total=$((total + 1))
    local out="$tmp/driver_${label}.out"
    local err="$tmp/driver_${label}.err"
    # tollgate: retire C from grading these verifier-diagnostic drivers (backend
    # body + a main that hand-builds a malformed IR and calls the verifier). The
    # driver is COMPILED by the C-free gen-1 seed and RUN -- the same verifier
    # path C exercised by interpretation, now native. C is preserved as an OPT-IN
    # byte-faithfulness cross-check under NATIVE_CODEGEN_ORACLE=c.
    local cdir="$tmp/driver_${label}.cdir"
    rm -rf "$cdir"; mkdir -p "$cdir"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" <"$driver" >"$tmp/driver_${label}.cc.out" 2>"$tmp/driver_${label}.cc.err" )
    [[ -f "$cdir/a.out" ]] && chmod +x "$cdir/a.out"
    if [[ ! -f "$cdir/a.out" ]]; then
        fail_test "driver reject $label: seed did not compile driver: $(head -1 "$tmp/driver_${label}.cc.out") $(head -1 "$tmp/driver_${label}.cc.err")"
    elif ! { "$cdir/a.out" >"$out" 2>"$err"; grep -q "ERR $code" "$out"; }; then
        fail_test "driver reject $label: expected ERR $code, stdout=$(head -1 "$out"), stderr=$(head -1 "$err")"
    elif [[ "$NATIVE_CODEGEN_ORACLE" == "c" ]] && ! { "$HERBERT" "$driver" >"$tmp/driver_${label}.cref" 2>/dev/null; cmp -s "$out" "$tmp/driver_${label}.cref"; }; then
        fail_test "driver reject $label: C cross-check diverged from native (C=$(head -1 "$tmp/driver_${label}.cref"))"
    else
        pass=$((pass + 1))
    fi
}

compile_probe() {
    local label="$1"
    local probe="$2"
    local elf="$3"
    local out="$tmp/${label}.compile.out"
    local err="$tmp/${label}.compile.err"
    # D12: the compiler emits its ELF to a byte-pure file "a.out" (do fwriter), not
    # stdout. Run it in a per-label scratch dir and harvest that dir's a.out. (Only
    # the frontier-cap ACCEPT probe uses this; every reject check below reads the
    # diagnostic from stdout, unchanged -- a rejected program writes no a.out.)
    local cdir="$tmp/${label}.compile.d"
    rm -rf "$cdir"; mkdir -p "$cdir"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" <"$probe" >"$out" 2>"$err" )
    if [[ ! -f "$cdir/a.out" ]]; then
        fail_test "compile $label rejected or did not emit a.out: stdout=$(head -1 "$out"), stderr=$(head -1 "$err")"
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

check_runtime_frontier_cap() {
    local label="$1"
    local probe="$2"
    local elf="$tmp/${label}.elf"
    compile_probe "$label" "$probe" "$elf" || return
    # beaver lifted the 64 KiB stack-arena cap; tito lifted the 16 MiB heap cap to
    # ~2 GiB, and ouroboros raised it to ~3.5 GiB (0xe0000000) when the self-compile
    # outgrew 2 GiB. All three historical frontier sizes now SUCCEED == C: 64 KiB,
    # the old exact-16 MiB cap, and old-16 MiB+1 all fit the heap. Pre-tito, old-16
    # MiB+1 faulted native (nonzero, empty stdout); that boundary MOVED, it did not
    # vanish — the current ~3.5 GiB cap is proven structurally by the link6 disasm
    # gate (asserts the zero-extended mmap-size + cap bytes), since a runtime
    # over-cap probe is impractical per-push.
    local sizes=(65537 16777216 16777217)
    local kinds=(obsolete_64k old_exact_16M old_over_16M)
    local i=0
    while [[ $i -lt 3 ]]; do
        total=$((total + 1))
        local sz="${sizes[$i]}" kind="${kinds[$i]}"
        python3 -c "import sys;sys.stdout.buffer.write(b'x'*${sz})" >"$tmp/${label}.${kind}.in"
        "$elf" <"$tmp/${label}.${kind}.in" >"$tmp/${label}.${kind}.n" 2>/dev/null
        local nrc=$?
        if ! oracle_expect_le64 "rejects_${label}_${kind}" "$probe" "$tmp/${label}.${kind}.in" "$tmp/${label}.${kind}.expected"; then
            fail_test "frontier $label $kind: ${sz} B oracle failed"
            i=$((i + 1))
            continue
        fi
        if [[ $nrc -eq 0 ]] && cmp -s "$tmp/${label}.${kind}.n" "$tmp/${label}.${kind}.expected"; then
            pass=$((pass + 1))
        else
            fail_test "frontier $label $kind: ${sz} B must match golden (native rc=$nrc)"
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
cat >"$tmp/r_poly_direct_pair_growth.herb" <<'HERB'
func f(x):
    return f((x, x))
end

func main():
    return f(1)
end
HERB
cat >"$tmp/r_poly_one_sided_growth.herb" <<'HERB'
func f(x):
    return f((x, 0))
end

func main():
    return f(1)
end
HERB
cat >"$tmp/r_poly_mutual_growth.herb" <<'HERB'
func f(x):
    return g((x, x))
end

func g(y):
    return f((y, y))
end

func main():
    return f(1)
end
HERB
cat >"$tmp/r_poly_recursive_fanout.herb" <<'HERB'
func f(x):
    return g((x, 0)) + h((x, true))
end

func g(y):
    return f((y, y))
end

func h(z):
    return f((z, z))
end

func main():
    return f(1)
end
HERB
cat >"$tmp/r_poly_array_tuple_growth.herb" <<'HERB'
func f(x):
    return f((x, new_array(int)))
end

func main():
    return f(1)
end
HERB
cat >"$tmp/r_poly_dead_growth.herb" <<'HERB'
func f(x):
    if false:
        return f((x, x))
    end
    return 0
end

func main():
    return f(1)
end
HERB
cat >"$tmp/r_poly_same_instance_return_conflict.herb" <<'HERB'
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

# zelph soundness rails: the never-returning helper `fault` is type-bottom only
# when it provably traps. These four look bottom-ish but must NOT be classified
# as never-returning, or the relaxation would unsoundly accept a function that
# actually returns a value (masking a real type conflict).
#
# (1) rebind: `let a = new_array(...); a = filled(); return get(a, 0)` -- the
# assign rebinds `a` to a non-empty array, so the get does not trap and the
# function returns (int,int). The assign guard must catch it; otherwise `lb`
# would be bottom and the int/string conflict at its callers is masked. -> 430.
cat >"$tmp/r_zelph_rebind.herb" <<'HERB'
func filled():
    let t = new_array((int, int))
    do add(t, (3, 4))
    return t
end
func lb(reason):
    let a = new_array((int, int))
    a = filled()
    return get(a, 0)
end
func want_int(v):
    if v < 10:
        return lb("low")
    end
    return v
end
func want_str(v):
    if v < 10:
        return lb("low")
    end
    return "y"
end
func main():
    let inp = clogger()
    let v = index(inp, 0)
    return want_int(v) + length(want_str(v))
end
HERB

# (2) let-shadow: a nested `let other = filled()` shadows the top-level fresh
# `let other = new_array(...)`; the returned `other` is the non-empty inner one,
# so the function returns. The exactly-one-let-target guard (the cross-model
# Codex find) must catch it -- the value-use count and assign guard alone do
# not. -> 430.
cat >"$tmp/r_zelph_let_shadow.herb" <<'HERB'
func filled():
    let t = new_array((int, int))
    do add(t, (3, 4))
    return t
end
func lb():
    let slot = new_array((int, int))
    let other = new_array((int, int))
    if true:
        let other = filled()
        return get(other, 0)
    end
    return get(slot, 0)
end
func main():
    return length(lb())
end
HERB

# (3) pure-bottom: a function whose every return is `fault(...)` (a CALL, not a
# direct trap-get) is deliberately NOT classified never-returning -- only direct
# `get(X, k)` returns match. Its sig-return stays unknown and the concreteness
# rail rejects it. This preserves the "direct-get-only, not via-call" property
# that keeps the design free of a call-graph fixpoint. -> 424.
cat >"$tmp/r_zelph_pure_bottom.herb" <<'HERB'
func fault(why):
    let slot = new_array((int, int))
    return get(slot, 0)
end
func only_bad(n):
    if n > 0:
        return fault("a")
    end
    return fault("b")
end
func main():
    let x = only_bad(3)
    do flogger("unreached\n")
    return 0
end
HERB

# (4) fake-trap: `let a = new_array(...); do add(a, ...); return get(a, 0)` does
# a get on a now-non-empty array, so it returns. The exactly-once value-use
# guard catches it (`a` is used twice: the add and the get). -> 430.
cat >"$tmp/r_zelph_fake_trap.herb" <<'HERB'
func notrap(why):
    let slot = new_array((int, int))
    do add(slot, (1, 1))
    return get(slot, 0)
end
func pick(n):
    if n > 0:
        return 5
    end
    return notrap("x")
end
func main():
    return pick(1)
end
HERB

# kanawha rails: partial aggregate merges may resolve benign unknown leaves, but
# genuine aggregate conflicts must still reject with one clean diagnostic.
cat >"$tmp/r_kanawha_array_bool_rebind.herb" <<'HERB'
func make_bool_array():
    let b = new_array(bool)
    do add(b, true)
    return b
end

func main():
    let a = new_array(int)
    if true:
        a = make_bool_array()
    end
    return 0
end
HERB
cat >"$tmp/r_kanawha_tuple_int_bool_assign.herb" <<'HERB'
func main():
    let t = (1, 2)
    if true:
        t = (true, 2)
    end
    return 0
end
HERB
cat >"$tmp/r_kanawha_array_int_bool_add.herb" <<'HERB'
func main():
    let a = new_array((int, int))
    do add(a, (1, 2))
    do add(a, (true, 2))
    return 0
end
HERB
cat >"$tmp/r_kanawha_partial_rebind_conflict.herb" <<'HERB'
func left(src, x):
    do add(src, (x, 1))
    return src
end

func right(src, y):
    do add(src, (true, y))
    return src
end

func bad(src1, x, src2, y):
    let a = left(src1, x)
    a = right(src2, y)
    return 0
end

func main():
    let src1 = new_array((int, int))
    let src2 = new_array((bool, int))
    if false:
        return bad(src1, 0, src2, 2)
    end
    return 0
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
check_source_reject_code_once poly_direct_pair_growth 441 "$tmp/r_poly_direct_pair_growth.herb"
check_source_reject_code_once poly_one_sided_growth 441 "$tmp/r_poly_one_sided_growth.herb"
check_source_reject_code_once poly_mutual_growth 441 "$tmp/r_poly_mutual_growth.herb"
check_source_reject_code_once poly_recursive_fanout 441 "$tmp/r_poly_recursive_fanout.herb"
check_source_reject_code_once poly_array_tuple_growth 441 "$tmp/r_poly_array_tuple_growth.herb"
check_source_reject_code_once poly_dead_growth 441 "$tmp/r_poly_dead_growth.herb"
check_source_reject_code_once poly_same_instance_return_conflict 430 "$tmp/r_poly_same_instance_return_conflict.herb"
check_source_reject_code monomorph 436 "$tmp/r_monomorph.herb"
check_source_reject_code main_string 432 "$tmp/r_main_string.herb"
check_source_reject_code main_tuple 432 "$tmp/r_main_tuple.herb"
check_source_reject_code zelph_rebind 430 "$tmp/r_zelph_rebind.herb"
check_source_reject_code zelph_let_shadow 430 "$tmp/r_zelph_let_shadow.herb"
check_source_reject_code zelph_pure_bottom 424 "$tmp/r_zelph_pure_bottom.herb"
check_source_reject_code zelph_fake_trap 430 "$tmp/r_zelph_fake_trap.herb"
check_source_reject_code_once kanawha_array_bool_rebind 436 "$tmp/r_kanawha_array_bool_rebind.herb"
check_source_reject_code_once kanawha_tuple_int_bool_assign 430 "$tmp/r_kanawha_tuple_int_bool_assign.herb"
check_source_reject_code_once kanawha_array_int_bool_add 436 "$tmp/r_kanawha_array_int_bool_add.herb"
check_source_reject_code_once kanawha_partial_rebind_conflict 436 "$tmp/r_kanawha_partial_rebind_conflict.herb"

# Malformed bytecode / metadata drivers.
awk '/^func main\(\):$/ { exit } { print }' "$backend" >"$tmp/stack_underflow_driver.herb"
cat >>"$tmp/stack_underflow_driver.herb" <<'HERB'
func main():
    let type_pool = nc_type_pool_new()
    let funcs = new_array((string, int, int, int, array((int, int, int)), array(int), array(int)))
    let code = new_array((int, int, int))
    do add(code, (21, 0, 0))
    let meta = new_array(int)
    do add(meta, 0)
    let lines = new_array(int)
    do add(lines, 0)
    do add(funcs, ("main", 0, 0, 0, code, meta, lines))
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
    let has_faultable = nc_prog_has_faultable(prog)
    let pass1 = nc_pass1_program(prog, analyzed.1, analyzed.2, analyzed.3, has_faultable)
    let layouts = pass1.1
    let main_layout = get(layouts, prog.2)
    let bad_layout = (main_layout.0, main_layout.1, main_layout.2, main_layout.3, main_layout.4, main_layout.5 + 1)
    let bad_layouts = new_array((int, array(int), array(int), int, int, int))
    do add(bad_layouts, bad_layout)
    let emitted = nc_emit_function(new_buffer(), get(prog.0, prog.2), prog.0, get(analyzed.1, prog.2), analyzed.1, bad_layout, bad_layouts, prog.1, pass1.2, 0)
    return 0
end
HERB

awk '/^func main\(\):$/ { exit } { print }' "$backend" >"$tmp/missing_meta_driver.herb"
cat >>"$tmp/missing_meta_driver.herb" <<'HERB'
func main():
    let type_pool = nc_type_pool_new()
    let funcs = new_array((string, int, int, int, array((int, int, int)), array(int), array(int)))
    let code = new_array((int, int, int))
    do add(code, (28, 0, 0))
    do add(code, (21, 0, 0))
    let missing = new_array(int)
    let lines = new_array(int)
    do add(lines, 0)
    do add(lines, 0)
    do add(funcs, ("main", 0, 0, 0, code, missing, lines))
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
if ! native_codegen_oracle_finish; then
    exit 1
fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen rejects: $pass sub-tests: stable 420/424/430/432/435/436/437/438/439/440 boundaries, zelph never-returning-bottom soundness rails (rebind/let-shadow/pure-bottom/fake-trap), kanawha partial-aggregate single-diagnostic rails, plus frontier clogger limits)"
exit 0
