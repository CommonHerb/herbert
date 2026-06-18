#!/usr/bin/env bash
#
# Mutation proof for the parser-equivalence altimeter (run_parser_equivalence.sh).
#
# Proves the altimeter BITES in BOTH directions -- i.e. that the C-vs-Herbert AST
# diff is load-bearing, not vacuously green:
#
#   M-cparser  mutate the C bootstrap parser (bootstrap/parse.c): swap parse_add's
#              operands so `a - b` parses as (sub b a). The independent C dump must
#              then DIVERGE from the (unmutated) production Herbert parser's dump.
#   M-hparser  mutate the production Herbert parser (a parse_* in
#              stack/native_compile_fragment.herb): swap parse_add_loop's operands.
#              The Herbert dump must then DIVERGE from the (unmutated) C dump.
#   positive   unmutated, the two dumps AGREE (the gate is green for a reason).
#
# All mutations are applied to PRIVATE COPIES in a tempdir; the tracked tree is
# never modified. A mutation that fails to flip the diff to RED is a FAIL (the gate
# would be blind to a real parser divergence).
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
cc="${CC:-cc}"
cflags="${CFLAGS:--std=c11 -O2}"
HERBERT="${HERBERT:-$repo_root/build/herbert}"
backend="$repo_root/stack/native_compile_fragment.herb"
probe_rel="bootstrap/tests/test_01_arith.herb"   # uses +,-,*,< -- operand order matters

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: parser-equivalence mutation ($1)"; exit 1; }

[[ -x "$HERBERT" ]] || fail "cannot execute HERBERT=$HERBERT"

# Corpus probe WITH the ast-dump directive.
wd="$tmp/wd.herb"
{ printf -- '-- emit: ast-dump\n'; cat "$repo_root/$probe_rel"; } >"$wd"

build_c_dumper() {  # $1 = parse.c to use, $2 = output binary
    $cc $cflags -I"$repo_root/bootstrap" -o "$2" \
        "$script_dir/parser_equiv_dump.c" "$1" \
        "$repo_root/bootstrap/lex.c" "$repo_root/bootstrap/util.c" \
        "$repo_root/bootstrap/value.c" "$repo_root/bootstrap/reclaim.c" \
        "$repo_root/bootstrap/eval.c" 2>/dev/null
}

# --- baseline (unmutated) dumps ----------------------------------------------------------
build_c_dumper "$repo_root/bootstrap/parse.c" "$tmp/cd" || fail "could not build baseline C dumper"
"$tmp/cd" "$wd" >"$tmp/c.base" 2>/dev/null || fail "baseline C dumper rejected probe"
"$HERBERT" "$backend" <"$wd" 2>/dev/null | head -1 >"$tmp/h.base"
[[ -s "$tmp/c.base" && -s "$tmp/h.base" ]] || fail "empty baseline dump"
cmp -s "$tmp/c.base" "$tmp/h.base" || fail "positive control: unmutated C and Herbert ASTs already differ"

# --- M-cparser: swap parse_add operands in a private copy of parse.c ----------------------
cp "$repo_root/bootstrap/parse.c" "$tmp/parse_mut.c"
python3 - "$tmp/parse_mut.c" <<'PY' || exit 1
import sys
p=sys.argv[1]; s=open(p).read()
old="""        Expr *e = new_expr(E_BINOP, ln);
        e->op = op;
        e->l  = l;
        e->r  = parse_mul(p);
        l = e;"""
new="""        Expr *e = new_expr(E_BINOP, ln);
        e->op = op;
        e->r  = l;
        e->l  = parse_mul(p);
        l = e;"""
if s.count(old)!=1:
    sys.stderr.write("M-cparser anchor not unique in parse.c\n"); sys.exit(1)
open(p,"w").write(s.replace(old,new,1))
PY
build_c_dumper "$tmp/parse_mut.c" "$tmp/cd_mut" || fail "M-cparser: mutated C dumper did not build"
"$tmp/cd_mut" "$wd" >"$tmp/c.mut" 2>/dev/null || fail "M-cparser: mutated C dumper rejected probe"
if cmp -s "$tmp/c.mut" "$tmp/h.base"; then
    fail "M-cparser: a swapped-operand parse.c STILL matched the Herbert AST -- the altimeter is blind to a C parser divergence"
fi

# --- M-hparser: swap parse_add_loop operands in a private copy of the backend -------------
cp "$backend" "$tmp/backend_mut.herb"
python3 - "$tmp/backend_mut.herb" <<'PY' || exit 1
import sys
p=sys.argv[1]; s=open(p).read()
old="return parse_add_loop(tokens, r.1, pool, make_binop(pool, tag, lidx, r.0, t.2))"
new="return parse_add_loop(tokens, r.1, pool, make_binop(pool, tag, r.0, lidx, t.2))"
if s.count(old)!=1:
    sys.stderr.write("M-hparser anchor not unique in backend\n"); sys.exit(1)
open(p,"w").write(s.replace(old,new,1))
PY
"$HERBERT" "$tmp/backend_mut.herb" <"$wd" 2>/dev/null | head -1 >"$tmp/h.mut"
[[ -s "$tmp/h.mut" ]] || fail "M-hparser: mutated backend produced no dump"
if cmp -s "$tmp/h.mut" "$tmp/c.base"; then
    fail "M-hparser: a swapped-operand production parser STILL matched the C AST -- the altimeter is blind to a Herbert parser divergence"
fi

echo "PASS: parser-equivalence mutation (3/3: positive control green; M-cparser RED; M-hparser RED -- the C-vs-Herbert parser diff is load-bearing)"
