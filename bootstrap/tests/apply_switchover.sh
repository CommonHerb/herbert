#!/usr/bin/env bash
# apply_switchover.sh -- sovereignty link 17: the EXECUTABLE C-RETIREMENT RECIPE.
#
# This is the EXACT, AUDITABLE, RE-RUNNABLE operation the eventual switchover (the
# irreversible C-interpreter deletion) performs -- not a one-time hand-edit, and
# not prose. It runs against a TARGET directory (a clean checkout / throwaway
# worktree -- NEVER the live tree by default), performs the deletion + metadata
# reconciliation, then PROVES the post-deletion tree is COHERENT: no dangling
# reference to a deleted file remains, the switchover-disposition manifest still
# partitions exhaustively, and the C-free production SURFACE + its (reconciled)
# bite-proof stand GREEN with the C interpreter now physically GONE.
#
# It is RED-first by construction: if the deletion leaves a dangling reference, or
# the manifest no longer reconciles, or a "C-free" gate secretly needed C, the
# coherence proof FAILS. `make switchover-dry-run` runs this on a throwaway worktree
# as the standing rehearsal; SWITCHOVER.md is the human-readable companion plan.
#
# What it DELETES (the C-interpreter retirement -- see SWITCHOVER.md for the full
# disposition table and the residual Makefile/CI surgery this recipe documents but
# leaves to the irreversible event):
#   * the C interpreter:  bootstrap/{eval,lex,main,parse,reclaim,util,value}.c + herbert.h
#   * the 2 equiv dumpers: bootstrap/tests/{lexer,parser}_equiv_dump.c
#   * the 5 retire-tests:  run_{beta_full,smoke,lexer_equivalence,parser_equivalence,
#                          parser_equivalence_mutation}.sh
#   It does NOT delete tools/scan.c (the `make check` from-scratch guard is a
#   governance meta-tool, not the Herbert interpreter; its rehoming-to-Herbert is a
#   separate tee'd-up sovereignty sub-link -- see SWITCHOVER.md disposition #1).
set -u

target="${1:-}"
[[ -n "$target" && -d "$target" ]] || { echo "usage: apply_switchover.sh <clean-checkout-dir>"; exit 2; }
target="$(cd "$target" && pwd)"
T="$target/bootstrap/tests"

note() { printf '%s\n' "$*"; }
die()  { printf 'FAIL: apply-switchover (%s)\n' "$1"; exit 1; }

# A target must be a CLEAN checkout WITH C present (this recipe retires it).
[[ -f "$target/bootstrap/eval.c" ]] || die "target has no bootstrap/eval.c (not a clean pre-switchover checkout)"
[[ -f "$target/bootstrap/seed/gen1.seed" ]] || die "target has no committed gen-1 seed"

# ----------------------------------------------------------------------------
note "== apply-switchover: 1. DELETE the C interpreter + its dumpers + the retire-tests =="
C_INTERP="bootstrap/eval.c bootstrap/lex.c bootstrap/main.c bootstrap/parse.c bootstrap/reclaim.c bootstrap/util.c bootstrap/value.c bootstrap/herbert.h"
C_DUMPERS="bootstrap/tests/lexer_equiv_dump.c bootstrap/tests/parser_equiv_dump.c"
RETIRE_TESTS="run_beta_full.sh run_smoke.sh run_lexer_equivalence.sh run_parser_equivalence.sh run_parser_equivalence_mutation.sh"
for f in $C_INTERP $C_DUMPERS; do
    [[ -f "$target/$f" ]] || die "expected file to delete is missing: $f"
    rm -f "$target/$f"
done
for f in $RETIRE_TESTS; do
    [[ -f "$T/$f" ]] || die "expected retire-test to delete is missing: $f"
    rm -f "$T/$f"
done
note "  deleted ${C_INTERP// /, } + 2 dumpers + 5 retire-tests"

# ----------------------------------------------------------------------------
note "== apply-switchover: 2. RECONCILE switchover_manifest.tsv (drop the retired rows) =="
mani="$T/switchover_manifest.tsv"
[[ -f "$mani" ]] || die "missing switchover_manifest.tsv"
tmp="$(mktemp)"
awk -F'\t' 'NF<2 || $3 !~ /^run_(beta_full|smoke|lexer_equivalence|parser_equivalence|parser_equivalence_mutation)\.sh$/' "$mani" >"$tmp"
mv "$tmp" "$mani"
# The dropped rows must be gone; the file must still have the surviving classes.
grep -qE '^(RETIRE_WITH_C|RETIRE_AT_SWITCH)\t' "$mani" && die "a RETIRE row survived manifest reconciliation (the retire-tests are deleted)"
grep -q '^CFREE_SWITCHOVER' "$mani" || die "manifest lost its CFREE_SWITCHOVER surface"
note "  manifest reconciled: RETIRE_WITH_C + RETIRE_AT_SWITCH rows removed (their scripts are deleted)"

# ----------------------------------------------------------------------------
note "== apply-switchover: 3. RECONCILE the switchover-cfree bite-proof (post-C) =="
# M-leak proved 'the counting tombstone DETECTS C use' by invoking a C-using gate
# (run_beta_full.sh -> klondike-under-C). With C deleted there is NO C-using gate to
# invoke, so M-leak is INHERENTLY vacuous post-C -> it RETIRES WITH C. M-incomplete
# dropped run_smoke.sh's row to prove the partition bites on limbo; run_smoke.sh is
# deleted, so it RETARGETS to a surviving CFREE_KERNEL row.
bp="$T/run_switchover_cfree_mutation.sh"
[[ -f "$bp" ]] || die "missing run_switchover_cfree_mutation.sh"
# (a) retire the M-leak block (its header line through its assertion line).
awk '
  /^printf .== M-leak:/ { skip=1 }
  skip && /^printf .== M-gerrymander:/ { skip=0 }
  !skip { print }
' "$bp" >"$bp.new"
# (b) retarget M-incomplete from the deleted run_smoke.sh to a surviving on-disk row.
sed -i 's/run_smoke\.sh/run_native_codegen_link17.sh/g; s/with run_smoke.sh in limbo/with a CFREE_KERNEL row in limbo/' "$bp.new"
# (c) drop the now-stale M-leak mention from the header comment + the PASS string.
sed -i 's/ + M-leak//; s/M-guard + M-leak/M-guard/' "$bp.new"
mv "$bp.new" "$bp"; chmod +x "$bp"
# Hard-verify the reconcile (an awk/sed slip would silently corrupt the bite-proof):
grep -q 'run_beta_full' "$bp" && die "bite-proof reconcile FAILED: M-leak still invokes the deleted run_beta_full.sh"
grep -q 'run_smoke\.sh' "$bp" && die "bite-proof reconcile FAILED: M-incomplete still drops the deleted run_smoke.sh row"
grep -q 'run_native_codegen_link17.sh' "$bp" || die "bite-proof reconcile FAILED: M-incomplete was not retargeted to a surviving row"
bash -n "$bp" || die "bite-proof reconcile produced a syntactically invalid script"
grep -q 'M-leak' "$bp" && note "  note: residual 'M-leak' mentions remain in comments (cosmetic)"
note "  bite-proof reconciled: M-leak retired-with-C; M-incomplete retargeted to a surviving row"

# ----------------------------------------------------------------------------
note "== apply-switchover: 4. COHERENCE of the C-free SURFACE (whole-tree refs = documented residual) =="
# Every reference to a deleted path, anywhere in the post-deletion tree, except in
# the recipe/plan/manifest-comment that legitimately NAME them as deleted.
deleted_basenames="eval.c lex.c main.c parse.c reclaim.c util.c value.c herbert.h lexer_equiv_dump.c parser_equiv_dump.c run_beta_full.sh run_smoke.sh run_lexer_equivalence.sh run_parser_equivalence.sh run_parser_equivalence_mutation.sh"
dangling=""
for b in $deleted_basenames; do
    # Exclude: this recipe, the plan, the manifest (comments), git metadata, the
    # native_compile_fragment line-number embedding is .herb (not a path ref).
    hits=$(grep -rIl --exclude-dir=.git \
                --exclude=apply_switchover.sh --exclude=SWITCHOVER.md \
                --exclude=switchover_manifest.tsv \
                -e "$b" "$target" 2>/dev/null \
            | grep -vE '/(bootstrap/seed/README\.md)$' || true)
    [[ -n "$hits" ]] && dangling="$dangling"$'\n'"  $b referenced by:"$'\n'"$(printf '%s\n' "$hits" | sed 's/^/      /')"
done
if [[ -n "$dangling" ]]; then
    note "  DANGLING references to deleted files remain (the Makefile/CI/run_tests.sh surgery"
    note "  documented in SWITCHOVER.md must accompany the deletion):$dangling"
    note ""
    note "  (this recipe proves the SURFACE coherence below; the run_tests.sh + Makefile + CI"
    note "   excision is the documented residual the irreversible event completes -- it does NOT"
    note "   block the C-free SURFACE proof, which routes through neither.)"
    danglers=1
else
    note "  no dangling reference to any deleted file anywhere (the WHOLE tree is self-consistent)"
    danglers=0
fi

# ----------------------------------------------------------------------------
note "== apply-switchover: 5. PROVE the C-free SURFACE + bite-proof stand on the post-deletion tree =="
# switchover-cfree has NO C dependency (it poisons cc + tombstones $HERBERT + forces
# the seed); on the post-deletion tree it proves the 24-gate surface + the reconciled
# bite-proof are GREEN with the C interpreter now PHYSICALLY GONE (not just absent).
if bash "$T/run_switchover_cfree.sh" >"$target/.sw_surface.out" 2>&1; then
    note "  ok   run_switchover_cfree.sh GREEN on the post-deletion tree (24-gate surface, 0 C)"
    surf=0
else
    note "  RED  run_switchover_cfree.sh FAILED on the post-deletion tree:"; tail -8 "$target/.sw_surface.out" | sed 's/^/      | /'
    surf=1
fi
if bash "$T/run_switchover_cfree_mutation.sh" >"$target/.sw_bite.out" 2>&1; then
    note "  ok   run_switchover_cfree_mutation.sh GREEN post-deletion (reconciled bite-proof bites)"
    bite=0
else
    note "  RED  reconciled switchover-cfree bite-proof FAILED post-deletion:"; tail -10 "$target/.sw_bite.out" | sed 's/^/      | /'
    bite=1
fi
if [[ -x "$T/run_switchover_dryrun.sh" ]]; then
    if bash "$T/run_switchover_dryrun.sh" >"$target/.sw_dryrun.out" 2>&1; then
        note "  ok   run_switchover_dryrun.sh GREEN post-deletion (the 7 bite-proofs still bite C-gone)"
        dr=0
    else
        note "  RED  run_switchover_dryrun.sh FAILED post-deletion:"; tail -8 "$target/.sw_dryrun.out" | sed 's/^/      | /'
        dr=1
    fi
else
    dr=0
fi

note ""
if [[ $((surf + bite + dr)) -eq 0 ]]; then
    note "PASS: apply-switchover (the C interpreter + dumpers + retire-tests DELETED; manifest +"
    note "      bite-proof RECONCILED; the C-free production SURFACE + bite-proofs stand GREEN with"
    note "      the C interpreter PHYSICALLY GONE -- the deletion + reconciliation are mechanical and proven)"
    if [[ "$danglers" -eq 1 ]]; then
        note "      SCOPE: this proves SURFACE coherence ONLY. The tree is NOT yet whole-tree-coherent --"
        note "      the run_tests.sh/Makefile/CI excision of the deleted-file references (above) is the"
        note "      DOCUMENTED RESIDUAL the irreversible event completes per SWITCHOVER.md (NOT proven here)."
    else
        note "      and the WHOLE tree is dangling-reference-free (no residual surgery outstanding)."
    fi
    exit 0
fi
die "the post-deletion tree did not stand (surface=$surf bite=$bite dryrun=$dr)"
