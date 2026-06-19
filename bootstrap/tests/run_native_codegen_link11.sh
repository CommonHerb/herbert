#!/usr/bin/env bash
# Native codegen Link 11 test (mojo): polymorphic user functions are
# monomorphized per concrete caller instance, with a guarded finite instance set
# and the frozen x86-64 emitter still seeing ordinary concrete functions.
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
native_codegen_oracle_begin link11 || exit 1

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

compile_probe() {
    local label="$1" probe="$2" elf="$3"
    # D12: the compiler emits its ELF to a byte-pure file "a.out" (do fwriter),
    # not stdout. Run it in a per-label scratch dir and harvest that dir's a.out.
    # (The make_layout_driver introspection driver below replaces the backend's
    # main with its OWN flogger-emitting main, so it never reaches fwriter and is
    # unaffected -- it still writes its LAY/TARGET layout lines to stdout.)
    local cdir="$tmp/$label.cdir"
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

c_to_le64() {
    local val="$1" out="$2"
    if [[ "$val" == "true" ]]; then
        val=1
    elif [[ "$val" == "false" ]]; then
        val=0
    fi
    python3 - "$val" "$out" <<'PY'
import struct
import sys
value = int(sys.argv[1]) & 0xFFFFFFFFFFFFFFFF
with open(sys.argv[2], "wb") as f:
    f.write(struct.pack("<Q", value))
PY
}

check_diff() {
    local label="$1" probe="$2"
    total=$((total + 1))
    local elf="$tmp/$label.elf"
    compile_probe "$label" "$probe" "$elf" || return
    : >"$tmp/$label.empty"
    if ! oracle_expect_le64 "link11_${label}" "$probe" "$tmp/$label.empty" "$tmp/$label.expected"; then
        fail_test "differential $label: oracle failed"
        return
    fi
    "$elf" >"$tmp/$label.native" 2>"$tmp/$label.native.err"
    local nrc=$?
    if [[ $nrc -eq 0 ]] && cmp -s "$tmp/$label.expected" "$tmp/$label.native"; then
        pass=$((pass + 1))
    else
        fail_test "differential $label: native rc=$nrc bytes=$(xxd -p "$tmp/$label.native" | tr -d '\n') expected=$(xxd -p "$tmp/$label.expected" | tr -d '\n')"
    fi
}

check_compile_only() {
    local label="$1" probe="$2"
    total=$((total + 1))
    local elf="$tmp/$label.elf"
    if compile_probe "$label" "$probe" "$elf"; then
        pass=$((pass + 1))
    fi
}

make_layout_driver() {
    local out="$1"
    awk '/^func main\(\):$/ { exit } { print }' "$backend" >"$out"
    cat >>"$out" <<'HERB'
func link11_print_layouts(layouts, i, n):
    if i >= n:
        return 0
    end
    let lay = get(layouts, i)
    do flogger("LAY ")
    do flogger(int_to_str(i))
    do flogger(" ")
    do flogger(int_to_str(lay.0))
    do flogger(" ")
    do flogger(int_to_str(lay.5))
    do flogger("\n")
    return link11_print_layouts(layouts, i + 1, n)
end

func link11_print_targets(targets, i, n):
    if i >= n:
        return 0
    end
    let target = get(targets, i)
    do flogger("TARGET ")
    do flogger(int_to_str(target.0))
    do flogger(" ")
    do flogger(int_to_str(target.1))
    do flogger(" ")
    do flogger(int_to_str(target.2))
    do flogger("\n")
    return link11_print_targets(targets, i + 1, n)
end

func main():
    let source = clogger()
    let tokens = lex_source(source)
    let nodes = pool_new()
    let parsed = parse_program(tokens, 0, nodes)
    let type_pool = nc_type_pool_new()
    let ast_result = nc_verify_ast(nodes, parsed.0, type_pool)
    if ast_result.0 != 0:
        return 1
    end
    let prog = lower_program_poly(nodes, parsed.0, type_pool, ast_result.2)
    let has_faultable = nc_prog_has_faultable(prog)
    if has_faultable != 0:
        let diag_strings = nc_append_fault_rodata(prog.1)
    end
    let analyzed = nc_analyze_program(type_pool, prog, ast_result.1)
    if analyzed.0 != 0:
        return 2
    end
    let main_ret = get(analyzed.1, prog.2).1
    let main_kids = new_array(int)
    if nc_type_is_flat_int_bool_tuple(type_pool, main_ret):
        main_kids = nc_type_tuple_children(type_pool, main_ret)
    end
    let pass1 = nc_pass1_program(prog, analyzed.1, analyzed.2, analyzed.3, has_faultable, main_kids)
    if pass1.0 != 0:
        return 3
    end
    let ignored1 = link11_print_layouts(pass1.1, 0, count(pass1.1))
    let ignored2 = link11_print_targets(ast_result.2.1, 0, count(ast_result.2.1))
    return 0
end
HERB
}

# tollgate: retire C from the layout-introspection driver. The driver (backend
# body + a main that lexes/parses/lowers the probe and prints its function
# LAY/TARGET layout) used to be C-INTERPRETED. It is now COMPILED by the C-free
# gen-1 seed and RUN -- the native-derived layout TRACKS the actual native ELF
# (so a backend codegen change shifts both together, preserving the RED-first
# byte-slice gate; a golden layout could drift stale and mask it). Compiled once
# per driver (cached). C is preserved as an OPT-IN byte cross-check under
# NATIVE_CODEGEN_ORACLE=c. Echoes the layout records to $out; nonzero on failure.
layout_driver_elf=
layout_driver_for=
layout_via() {
    local driver="$1" input="$2" out="$3"
    if [[ "$layout_driver_for" != "$driver" ]]; then
        local cdir="$tmp/layout_driver.cdir"; rm -rf "$cdir"; mkdir -p "$cdir"
        ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" <"$driver" >/dev/null 2>&1 )
        if [[ ! -f "$cdir/a.out" ]]; then
            fail_test "layout driver: seed did not compile the introspection driver"
            return 1
        fi
        layout_driver_elf="$tmp/layout_driver.elf"; cp "$cdir/a.out" "$layout_driver_elf"; chmod +x "$layout_driver_elf"
        layout_driver_for="$driver"
    fi
    "$layout_driver_elf" <"$input" >"$out" 2>/dev/null
    if [[ "$NATIVE_CODEGEN_ORACLE" == "c" ]]; then
        local cref; cref="$(mktemp)"
        "$HERBERT" "$driver" <"$input" >"$cref" 2>/dev/null
        if ! cmp -s "$out" "$cref"; then
            fail_test "layout driver: C cross-check diverged from native layout"
            rm -f "$cref"; return 1
        fi
        rm -f "$cref"
    fi
    return 0
}

layout_field() {
    local info="$1" idx="$2" field="$3"
    awk -v idx="$idx" -v field="$field" '$1 == "LAY" && $2 == idx { print $field; exit }' "$info"
}

slice_func_bytes() {
    local elf="$1" start="$2" len="$3" out="$4"
    dd if="$elf" of="$out" bs=1 skip=$((120 + start)) count="$len" 2>/dev/null
}

check_frozen_emitter_gate() {
    total=$((total + 1))
    local generic="$tmp/frozen_generic.herb"
    local concrete="$tmp/frozen_concrete.herb"
    local gen_elf="$tmp/frozen_generic.elf"
    local con_elf="$tmp/frozen_concrete.elf"
    local driver="$tmp/layout_driver.herb"
    local gen_info="$tmp/frozen_generic.layout"
    local con_info="$tmp/frozen_concrete.layout"

    cat >"$generic" <<'HERB'
func id(x):
    return x
end

func main():
    let a = id(1)
    let b = id("xy")
    return a + length(b)
end
HERB
    cat >"$concrete" <<'HERB'
func id_int(x):
    return x
end

func id_string(x):
    return x
end

func main():
    let a = id_int(1)
    let b = id_string("xy")
    return a + length(b)
end
HERB

    compile_probe frozen_generic "$generic" "$gen_elf" || return
    compile_probe frozen_concrete "$concrete" "$con_elf" || return
    make_layout_driver "$driver"
    layout_via "$driver" "$generic" "$gen_info" || return
    layout_via "$driver" "$concrete" "$con_info" || return

    local gi_start gi_len gs_start gs_len ci_start ci_len cs_start cs_len
    gi_start=$(layout_field "$gen_info" 1 3)
    gi_len=$(layout_field "$gen_info" 1 4)
    gs_start=$(layout_field "$gen_info" 2 3)
    gs_len=$(layout_field "$gen_info" 2 4)
    ci_start=$(layout_field "$con_info" 1 3)
    ci_len=$(layout_field "$con_info" 1 4)
    cs_start=$(layout_field "$con_info" 2 3)
    cs_len=$(layout_field "$con_info" 2 4)

    slice_func_bytes "$gen_elf" "$gi_start" "$gi_len" "$tmp/gen_id_int.bytes"
    slice_func_bytes "$con_elf" "$ci_start" "$ci_len" "$tmp/con_id_int.bytes"
    slice_func_bytes "$gen_elf" "$gs_start" "$gs_len" "$tmp/gen_id_string.bytes"
    slice_func_bytes "$con_elf" "$cs_start" "$cs_len" "$tmp/con_id_string.bytes"

    # tollgate: require non-empty leaf slices so a degenerate (len==0) native-
    # derived layout cannot pass this cmp vacuously (the completeness critic's note).
    if [[ ! -s "$tmp/gen_id_int.bytes" || ! -s "$tmp/con_id_int.bytes" || ! -s "$tmp/gen_id_string.bytes" || ! -s "$tmp/con_id_string.bytes" ]]; then
        fail_test "frozen-emitter gate: empty leaf slice (gi=$gi_len ci=$ci_len gs=$gs_len cs=$cs_len) -- layout introspection produced no bytes"
    elif cmp -s "$tmp/gen_id_int.bytes" "$tmp/con_id_int.bytes" && cmp -s "$tmp/gen_id_string.bytes" "$tmp/con_id_string.bytes"; then
        pass=$((pass + 1))
    else
        fail_test "frozen-emitter gate: stamped id leaf bytes differ from hand-written concrete leaves"
    fi
}

check_call_target_gate() {
    total=$((total + 1))
    local probe="$tmp/call_targets.herb"
    local elf="$tmp/call_targets.elf"
    local driver="$tmp/layout_driver_call.herb"
    local info="$tmp/call_targets.layout"

    cat >"$probe" <<'HERB'
func id(x):
    return x
end

func wrap(y):
    let z = id(y)
    return z
end

func main():
    let a = wrap(5)
    let b = wrap("abc")
    return a + length(b)
end
HERB

    compile_probe call_targets "$probe" "$elf" || return
    make_layout_driver "$driver"
    layout_via "$driver" "$probe" "$info" || return

    if python3 - "$elf" "$info" <<'PY'
import struct
import sys

elf_path, info_path = sys.argv[1], sys.argv[2]
layouts = {}
with open(info_path, "r", encoding="utf-8", errors="ignore") as f:
    for line in f:
        parts = line.split()
        if len(parts) == 4 and parts[0] == "LAY":
            layouts[int(parts[1])] = (int(parts[2]), int(parts[3]))

with open(elf_path, "rb") as f:
    data = f.read()

starts = {120 + start: idx for idx, (start, _length) in layouts.items()}

def rel_calls(idx):
    start, length = layouts[idx]
    lo = 120 + start
    hi = lo + length
    out = []
    pos = lo
    while pos + 5 <= hi:
        if data[pos] == 0xE8:
            rel = struct.unpack_from("<i", data, pos + 1)[0]
            dest = pos + 5 + rel
            if dest in starts:
                out.append(starts[dest])
        pos += 1
    return out

expected = {
    0: [1, 2],
    1: [3],
    2: [4],
}
for idx, want in expected.items():
    got = rel_calls(idx)
    if got != want:
        raise SystemExit(f"instance {idx}: expected call targets {want}, got {got}")
PY
    then
        pass=$((pass + 1))
    else
        fail_test "call-target-resolution gate: disassembled calls did not land on expected instances"
    fi
}

cat >"$tmp/id_int_string.herb" <<'HERB'
func id(x):
    return x
end

func main():
    let a = id(1)
    let b = id("x")
    return a
end
HERB

cat >"$tmp/finite_poly.herb" <<'HERB'
func id(x):
    return x
end

func main():
    return id(1) + length(id("xy"))
end
HERB

cat >"$tmp/propagation.herb" <<'HERB'
func id(x):
    return x
end

func wrap(y):
    return id(y)
end

func main():
    let a = wrap(5)
    let b = wrap("abc")
    return a + length(b)
end
HERB

cat >"$tmp/three_types.herb" <<'HERB'
func id(x):
    return x
end

func main():
    let a = id(4)
    let b = id(true)
    let c = id("abc")
    if b:
        return a + length(c)
    end
    return 0
end
HERB

cat >"$tmp/ignore20.herb" <<'HERB'
func ignore(x):
    return 1
end

func main():
    let s = 0
    s = s + ignore(0)
    s = s + ignore(true)
    s = s + ignore("x")
    s = s + ignore((1, 2))
    s = s + ignore((1, true))
    s = s + ignore((true, 1))
    s = s + ignore(("x", 1))
    s = s + ignore((1, "x"))
    s = s + ignore(((1, 2), 3))
    s = s + ignore((1, (2, 3)))
    s = s + ignore((true, (1, 2)))
    s = s + ignore(((1, true), (2, 3)))
    s = s + ignore(new_array(int))
    s = s + ignore(new_array(bool))
    s = s + ignore(new_array(string))
    s = s + ignore(new_array((int, int)))
    s = s + ignore(new_array((int, bool)))
    s = s + ignore(new_array(array(int)))
    s = s + ignore(new_buffer())
    s = s + ignore((new_array(int), 1))
    return s
end
HERB

cat >"$tmp/fanout_chain.herb" <<'HERB'
func leaf(x):
    return 1
end

func stage4(x):
    return leaf(x) + leaf((x, 0)) + leaf((x, true)) + leaf((x, "s")) + leaf((x, (0, 1)))
end

func stage3(x):
    return stage4(x) + stage4((x, 0))
end

func stage2(x):
    return stage3(x) + stage3((x, true))
end

func main():
    return stage2(1)
end
HERB

cat >"$tmp/projection_cycle.herb" <<'HERB'
func f(x):
    return g((x, 0)) + 0
end

func g(y):
    return f(y.0) + 0
end

func main():
    return f(1) + 0
end
HERB

cat >"$tmp/plain_recursion.herb" <<'HERB'
func loop(x):
    return loop(x) + 0
end

func main():
    return loop(1) + 0
end
HERB

check_diff id_int_string "$tmp/id_int_string.herb"
check_diff finite_poly "$tmp/finite_poly.herb"
check_diff propagation "$tmp/propagation.herb"
check_diff three_types "$tmp/three_types.herb"
check_diff ignore20 "$tmp/ignore20.herb"
check_diff fanout_chain "$tmp/fanout_chain.herb"
check_compile_only projection_cycle "$tmp/projection_cycle.herb"
check_compile_only plain_recursion "$tmp/plain_recursion.herb"
check_frozen_emitter_gate
check_call_target_gate

echo ""
if [[ $fail -ne 0 ]]; then
    echo "$fail of $((pass + fail)) native-codegen-link11 sub-test(s) failed."
    exit 1
fi
if ! native_codegen_oracle_finish; then
    exit 1
fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link11: $pass sub-tests: polymorphic monomorphization differentials, guarded finite recursion accepts, frozen-emitter bytes, call-target resolution)"
exit 0
