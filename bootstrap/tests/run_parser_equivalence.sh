#!/usr/bin/env bash
#
# Parser-equivalence altimeter (sovereignty axis, pre-switchover parser cross-check).
#
# Diffs the AST built by the INDEPENDENT C bootstrap parser (bootstrap/parse.c,
# walked by bootstrap/tests/parser_equiv_dump.c -- derived from the parse.c/herbert.h
# typed tree, NOT from any Herbert serializer) against the AST built by the PRODUCTION
# Herbert parser (the parse_* routines inline in stack/native_compile_fragment.herb),
# emitted by the backend's `-- emit: ast-dump` mode.
#
# The Herbert side is run TWO ways and BOTH must agree with C:
#   (1) NATIVELY, by the committed C-free gen-1 seed (the production compiler) -- this
#       is the sovereignty ADVANCE: the production parser's tree is observed with NO C
#       in its execution path. It is also a genuine non-backend C-vs-native differential
#       (gen-1's compiled parser vs the independent C parser) that the gen2==gen1 fixpoint
#       (self-consistency) cannot provide.
#   (2) by the C interpreter (build/herbert) running the backend -- a compiler-faithfulness
#       cross-check (the native parser matches the interpreted one).
#
# This is the parser rung of the lexer-equivalence ladder. It is RED-first (the C dumper,
# the ast-dump mode, and this gate do not exist before this link; a mutation of parse.c OR
# of a production parse_* makes the dumps diverge -- proven by the M-* mutation gate).
#
# SCOPE (honest): the altimeter compares parse trees over programs BOTH front ends accept
# AT PARSE TIME (well-formed, non-class-mix). It deliberately does NOT assert parse-ERROR
# parity: the C parser reports located syntax errors and rejects bare bitwise class-mix at
# parse time, whereas the Herbert production parser is permissive -- it defers syntax and
# class-mix rejection to the downstream verifier (nc_verify_ast, ERR 442) and faults on
# malformed input. Both front ends ultimately reject the same programs; they merely catch
# them at different stages, so the raw parse trees are only comparable on accepted input.
# The dump compares AST STRUCTURE (tags/atoms/children); source LINE/span parity is a
# separable future gate (the token-level line parity is already covered by lexer-equivalence).
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"

cc="${CC:-cc}"
cflags="${CFLAGS:--std=c11 -Wall -Wextra -Wpedantic -O2}"
HERBERT="${HERBERT:-$repo_root/build/herbert}"
backend="$repo_root/stack/native_compile_fragment.herb"
dumper_src="$script_dir/parser_equiv_dump.c"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: parser equivalence ($1)"; exit 1; }

[[ -x "$HERBERT" ]] || fail "cannot execute HERBERT=$HERBERT"
[[ -f "$backend" ]] || fail "missing backend $backend"
[[ -f "$dumper_src" ]] || fail "missing C dumper $dumper_src"

# --- 1. Acquire the native gen-1 production compiler (the committed C-free seed) ----------
source "$script_dir/native_codegen_oracle.sh"
native_codegen_ensure_compiler "$tmp/native-compiler" || fail "could not acquire gen-1 compiler"
GEN1="$NATIVE_CODEGEN_COMPILER"
[[ -x "$GEN1" ]] || fail "gen-1 compiler not executable: $GEN1"

# --- 2. Build the independent C-side AST dumper from bootstrap/parse.c --------------------
# The dumper object is compiled with -Werror=switch: every Expr/Stmt/TypeExpr/BinOp enum
# value MUST have an explicit dump case, so a future node kind added to the grammar
# HARD-FAILS this gate's build rather than silently dumping nothing (the omitted-field /
# unmapped-enum collision class). The bootstrap .c files are compiled without it.
dump="$tmp/parser_equiv_dump"
if ! $cc $cflags -Werror=switch -I"$repo_root/bootstrap" -c "$dumper_src" -o "$tmp/parser_equiv_dump.o"; then
    fail "C parser AST dumper has a non-exhaustive node switch (a node kind is unmapped)"
fi
if ! $cc $cflags -I"$repo_root/bootstrap" -o "$dump" \
        "$tmp/parser_equiv_dump.o" \
        "$repo_root/bootstrap/parse.c" "$repo_root/bootstrap/lex.c" \
        "$repo_root/bootstrap/util.c" "$repo_root/bootstrap/value.c" \
        "$repo_root/bootstrap/reclaim.c" "$repo_root/bootstrap/eval.c"; then
    fail "could not build C parser AST dumper"
fi

# --- helpers -----------------------------------------------------------------------------
# Dump a corpus FILE's AST three ways and require all three to agree. The AST is a single
# line (the ser format has no embedded newlines -- string bytes are emitted as decimals),
# so `head -1` isolates it from any trailing matter: the gen-1 ELF and the C interpreter
# both render main's return value (0) on a SECOND line (D14 canonical-decimal stdout); the
# C dumper prints only the AST. `&&` preserves the dumper's own reject exit status.
ast_line() { local raw="$tmp/raw.$$"; "$@" >"$raw" 2>/dev/null && head -1 "$raw" >"$OUT"; local rc=$?; rm -f "$raw"; return $rc; }
c_dump()      { OUT="$2" ast_line "$dump" "$1"; }                                  # C parse.c (file arg)
gen1_dump()   { OUT="$2" ast_line "$GEN1" <"$1"; }                                 # NATIVE gen-1 (stdin)
interp_dump() { OUT="$2" ast_line "$HERBERT" "$backend" <"$1"; }                   # C-interp backend (stdin)

with_directive() { { printf -- '-- emit: ast-dump\n'; cat "$1"; } >"$2"; }

checked=0
check_file() {
    local src="$1" label="$2"
    local wd="$tmp/wd.herb" c="$tmp/c.out" g="$tmp/g.out" i="$tmp/i.out"
    with_directive "$src" "$wd"
    c_dump "$wd" "$c"      || fail "$label: C parser rejected an in-corpus program (not well-formed?)"
    gen1_dump "$wd" "$g"   || fail "$label: native gen-1 ast-dump exited nonzero"
    interp_dump "$wd" "$i"
    [[ -s "$c" ]] || fail "$label: empty C dump"
    cmp -s "$c" "$g" || fail "$label: native gen-1 production-parser AST differs from independent C parse.c AST"
    cmp -s "$c" "$i" || fail "$label: C-interpreted backend AST differs from independent C parse.c AST"
    checked=$((checked + 1))
}

# --- 3. Corpus: well-formed, parse-accepted programs exercising the grammar ----------------
# The single most thorough item is the backend parsing its OWN 18.5k-line source (every
# production, ~944 KB of AST). parser_probe is the hand-authored every-production exerciser.
# The rest add operator/precedence/bitwise(non-class-mix)/large-literal breadth.
corpus=(
    "bootstrap/tests/fixtures/parser_equiv/all_constructs.herb"
    "stack/native_compile_fragment.herb"
    "stack/parser_probe.herb"
    "stack/native_elf_fragment.herb"
    "stack/lexer_probe.herb"
    "bootstrap/tests/test_01_arith.herb"
    "bootstrap/tests/test_02_short_circuit.herb"
    "bootstrap/tests/test_03_if_elif.herb"
    "bootstrap/tests/test_04_recursion.herb"
    "bootstrap/tests/test_05_block_scope.herb"
    "bootstrap/tests/test_06_tuples.herb"
    "bootstrap/tests/test_07_array.herb"
    "bootstrap/tests/test_08_strings_buffer.herb"
    "bootstrap/tests/test_09_ref_vs_value.herb"
    "bootstrap/tests/test_10_tco.herb"
    "bootstrap/tests/test_13_cross_function_tail_call.herb"
    "bootstrap/tests/fixtures/link14/bnot.herb"
    "bootstrap/tests/fixtures/link14/shr.herb"
    "bootstrap/tests/fixtures/link14/xor.herb"
    "bootstrap/tests/fixtures/link14/pte.herb"
    "bootstrap/tests/fixtures/link14/branch_after_bitwise.herb"
    "bootstrap/tests/fixtures/link14/accept_parens_cross.herb"
    "bootstrap/tests/fixtures/link15/mul.herb"
    "bootstrap/tests/fixtures/link15/div.herb"
    "bootstrap/tests/fixtures/link15/mod.herb"
    "bootstrap/tests/fixtures/link15/prec_mul_add.herb"
    "bootstrap/tests/fixtures/link15/prec_paren_add.herb"
    "bootstrap/tests/fixtures/link15/adler32.herb"
    "bootstrap/tests/fixtures/link16/big_addr.herb"
    "bootstrap/tests/fixtures/link16/max_u64.herb"
    "bootstrap/tests/fixtures/link16/seq_bytes.herb"
)
for rel in "${corpus[@]}"; do
    [[ -f "$repo_root/$rel" ]] || fail "missing corpus file $rel"
    check_file "$repo_root/$rel" "$rel"
done

# --- 3b. Node-kind coverage: every tag the dump schema can emit must actually appear -----
# (closes the "an unexercised node class hides a C-vs-Herbert collision" hole). The
# all_constructs fixture is authored to exercise every production; if a tag is missing,
# either the fixture regressed or the schema grew without coverage.
with_directive "$repo_root/bootstrap/tests/fixtures/parser_equiv/all_constructs.herb" "$tmp/cov.herb"
"$dump" "$tmp/cov.herb" 2>/dev/null | head -1 >"$tmp/cov.out" || fail "coverage: C dumper rejected all_constructs fixture"
expected_tags="program func params body let assign return do if clause else int str bool name call tuple dot not bnot type type-array type-tuple add sub mul div mod lt le gt ge eq ne and or band bor bxor shl shr"
for tag in $expected_tags; do
    grep -qE "\($tag( |\))" "$tmp/cov.out" || fail "node-kind coverage: tag '($tag ...)' never appears in the all_constructs dump"
done



# --- 4. Structure-sensitivity twins (false-equivalence guard) -----------------------------
# Two programs with the SAME tokens at a binop level but DIFFERENT trees (associativity and
# precedence). Each must agree C-vs-Herbert, AND the two dumps must DIFFER -- proving the
# normalized dump distinguishes structure, not just tokens (the false-equivalence hole).
twin_a="$tmp/twin_a.herb"; twin_b="$tmp/twin_b.herb"
cat >"$twin_a" <<'HERB'
func main():
    let a = 1
    let b = 2
    let c = 3
    return a - b - c
end
HERB
cat >"$twin_b" <<'HERB'
func main():
    let a = 1
    let b = 2
    let c = 3
    return a - (b - c)
end
HERB
check_file "$twin_a" "twin:assoc-left"
check_file "$twin_b" "twin:assoc-right"
with_directive "$twin_a" "$tmp/wa.herb"; "$dump" "$tmp/wa.herb" >"$tmp/da.out" 2>/dev/null
with_directive "$twin_b" "$tmp/wb.herb"; "$dump" "$tmp/wb.herb" >"$tmp/db.out" 2>/dev/null
if cmp -s "$tmp/da.out" "$tmp/db.out"; then
    fail "structure-sensitivity twin: (a - b - c) and (a - (b - c)) produced identical dumps -- the dump is structure-blind"
fi

prec_a="$tmp/prec_a.herb"; prec_b="$tmp/prec_b.herb"
cat >"$prec_a" <<'HERB'
func main():
    let a = 2
    let b = 3
    let c = 4
    return a + b * c
end
HERB
cat >"$prec_b" <<'HERB'
func main():
    let a = 2
    let b = 3
    let c = 4
    return (a + b) * c
end
HERB
check_file "$prec_a" "twin:prec-mul-binds-tighter"
check_file "$prec_b" "twin:prec-paren-overrides"
with_directive "$prec_a" "$tmp/pa.herb"; "$dump" "$tmp/pa.herb" >"$tmp/dpa.out" 2>/dev/null
with_directive "$prec_b" "$tmp/pb.herb"; "$dump" "$tmp/pb.herb" >"$tmp/dpb.out" 2>/dev/null
if cmp -s "$tmp/dpa.out" "$tmp/dpb.out"; then
    fail "structure-sensitivity twin: (a + b * c) and ((a + b) * c) produced identical dumps -- the dump is precedence-blind"
fi

echo "PASS: parser equivalence ($checked corpus program(s): production Herbert parser AST == independent C parse.c AST, native gen-1 + C-interp; all node kinds covered; 2 structure-sensitivity twin pairs distinguished)"
