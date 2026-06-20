#!/usr/bin/env bash
# run_switchover_dryrun.sh -- sovereignty link 17: the SWITCHOVER DRY-RUN.
#
# drydock (link 14) proved the FROZEN 24-gate near-axis production SURFACE stands
# with the C interpreter physically absent. It did NOT prove two further things the
# eventual switchover depends on:
#
#   (1) the C-free RED-first BITE-PROOFS (the regression guards that prove each
#       C-free gate is non-vacuous) survive C's removal -- they were rehomed onto
#       the gen-1 seed (assay/crucible) but never RUN with C PHYSICALLY ABSENT and
#       asserted to STILL BITE; and
#   (2) that nothing in the WHOLE make-test suite is in switchover LIMBO -- drydock's
#       manifest partitions the run_*.sh GATES, and muster classified the 15
#       foundational test_*.herb, but the LARGE inline residue of run_tests.sh (the
#       error-diagnostic probes, the klondike metacircular-under-C suite, the suke
#       suite, the recursion-depth guard, the fragment C-interp forcing tests) was
#       lumped as one opaque HARNESS row.
#
# This driver closes (1): it runs the 7 committed C-free bite-proofs with the C
# toolchain + interpreter PHYSICALLY ABSENT (extended poison, sealed namespace,
# clean artifact state, the committed gen-1 seed forced, a counting $HERBERT
# tombstone) and asserts each runs GREEN -- i.e. each still CATCHES its mutations
# without C -- at ZERO C invocations. (2) is closed by run_switchover_classification.sh
# (the inline-suite completeness manifest), run alongside by `make switchover-dry-run`.
#
# This is forge-resistant by the drydock discipline, plus three Codex-review
# hardenings beyond it: an EXTENDED tool poison (clang/cpp/gcc-NN/ld.lld/ccache,
# not just cc/gcc), a CLEAN-STATE precondition (no stale C-built binary may be
# reused), and EXACT-membership pinning of the bite-proof set (gerrymander -> RED).
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
seed="$script_dir/../seed/gen1.seed"

note() { printf '%s\n' "$*"; }
die()  { printf 'FAIL: switchover-dry-run (%s)\n' "$1"; exit 1; }

# The frozen C-free bite-proof set (sovereignty link 17). Each is a RED-first
# regression guard for a gate that SURVIVES C's deletion; each carries a
# DEFAULT-ON retireable C cross-check whose opt-out flag is named here. Changing
# this set is a deliberate act recorded in git; the manifest's CFREE_BITEPROOF
# rows must equal it exactly (asserted below), or the proof is RED.
#   script                                  cross-check opt-out env
FROZEN_BITEPROOFS=$'run_aggregate_render_native_mutation.sh\tAGGREGATE_RENDER_MUTATION_NO_C=1
run_emitter_native_mutation.sh\tEMITTER_NATIVE_NO_C=1
run_evaluator_native_mutation.sh\tEVALUATOR_NATIVE_NO_C=1
run_klondike_native_mutation.sh\tKLONDIKE_NATIVE_NO_C=1
run_lexer_native_mutation.sh\tLEXER_NATIVE_NO_C=1
run_parser_native_mutation.sh\tPARSER_NATIVE_NO_C=1
run_vm_native_mutation.sh\tVM_NATIVE_NO_C=1'

[[ -f "$seed" && -f "$seed.sha256" ]] || die "missing committed gen-1 seed"

# --- seed integrity precondition (michoi's gate, inlined) --------------------
seed_magic=$(head -c4 "$seed" | xxd -p | tr -d '\n')
seed_want=$(awk '{print $1}' "$seed.sha256")
seed_got=$(sha256sum "$seed" | awk '{print $1}')
[[ "$seed_magic" == "7f454c46" ]] || die "committed seed is not an ELF (magic=$seed_magic)"
[[ "$seed_got" == "$seed_want" ]] || die "committed seed sha mismatch (got=$seed_got want=$seed_want)"

# --- the bite-proof set == the manifest's CFREE_BITEPROOF set ----------------
manifest="${SWITCHOVER_MANIFEST:-$script_dir/switchover_manifest.tsv}"
[[ -f "$manifest" ]] || die "missing switchover_manifest.tsv"
manifest_bp="$(awk -F'\t' '$1=="CFREE_BITEPROOF"{print $3}' "$manifest" | sort)"
frozen_bp="$(printf '%s\n' "$FROZEN_BITEPROOFS" | cut -f1 | sort)"
if [[ "$manifest_bp" != "$frozen_bp" ]]; then
    die "manifest CFREE_BITEPROOF set != the frozen bite-proof set (gerrymander/swap):"$'\n'"$(diff <(printf '%s\n' "$frozen_bp") <(printf '%s\n' "$manifest_bp") | sed 's/^/    /')"
fi

# --- clean-state precondition (Codex hardening): no stale C INTERPRETER -------
# A dry-run that silently reused a stale build/herbert (the C interpreter, the one
# binary the suite could route grading through) would not be a physical-absence
# proof. Refuse to run if it is present. (build/scan -- the `make check`
# from-scratch guard -- is NOT the interpreter; it is kept past the switchover
# per SWITCHOVER.md disposition #1, and the seed-driven gates never route through
# it, so it is deliberately NOT flagged.)
stale=""
[[ -e "$repo_root/build/herbert" ]] && stale="$stale build/herbert"
while IFS= read -r o; do
    [[ "$o" == *"/scan.o" ]] && continue
    stale="$stale $o"
done < <(find "$repo_root/build" -name '*.o' -o -name '*.a' 2>/dev/null)
[[ -z "$stale" ]] || die "stale C interpreter artifact present (rebuild from clean; a dry-run must not reuse a pre-built C interpreter):$stale"

# --- build the C-physically-absent environment -------------------------------
scrub_dir="$(mktemp -d)" || die "mktemp -d failed"
count_file="$(mktemp)" || die "mktemp failed"
trap 'rm -rf "$scrub_dir" "$count_file"' EXIT

# EXTENDED toolchain poison (Codex hardening): a PATH-poison that misses clang /
# cpp / gcc-NN / ld.lld / ccache lets a real compile survive. Poison the common
# aliases; the seed casts ELF directly with no cc/as/ld execve.
TOOLS="cc gcc clang cpp c++ g++ as ld tcc ccache gcc-11 gcc-12 gcc-13 gcc-14 clang-15 clang-16 clang-17 clang-18 ld.lld ld.gold lld"
for t in $TOOLS; do
    printf '#!/bin/sh\necho "switchover-dry-run: C toolchain (%s) is physically absent" >&2\nexit 127\n' "$t" >"$scrub_dir/$t"
    chmod +x "$scrub_dir/$t"
done
# FORCE the committed seed as the production compiler (an executable copy).
seed_exec="$scrub_dir/gen1-seed"
cp "$seed" "$seed_exec"; chmod +x "$seed_exec"
export PATH="$scrub_dir:$PATH"
export NATIVE_CODEGEN_COMPILER="$seed_exec"
# Pin the oracle to the COMMITTED goldens (clear every redirect override).
unset NATIVE_CODEGEN_ALLOW_C_MINT NATIVE_CODEGEN_GOLDENS_DIR NATIVE_CODEGEN_MANIFEST \
      NATIVE_CODEGEN_ORACLE_CAPTURE NATIVE_CODEGEN_CAPTURE NATIVE_CODEGEN_CAPTURE_MANIFEST \
      NATIVE_CODEGEN_REAL_COMPILER NATIVE_CODEGEN_ORACLE

# Assert the scrub held (an honest physical-absence proof verifies its premise).
for t in cc gcc clang cpp as ld; do
    resolved="$(command -v "$t" 2>/dev/null || true)"
    [[ "$resolved" == "$scrub_dir/$t" ]] || die "C toolchain $t is NOT scrubbed (resolved to '${resolved:-<none>}')"
done

# A counting $HERBERT tombstone: any C-interpreter reach both COUNTS and fails.
herbert_tomb="$scrub_dir/herbert"
absent_target="$scrub_dir/THIS-C-INTERPRETER-DOES-NOT-EXIST"
printf '#!/bin/sh\nprintf "%%s %%s\\n" "$0" "$*" >> %q\nexec %q "$@"\n' "$count_file" "$absent_target" >"$herbert_tomb"
chmod +x "$herbert_tomb"

# --- static anti-bypass (drydock discipline): the $HERBERT count + PATH poison are
# blind to a gate that reaches C by a COMMAND-POSITION hardcoded build/herbert or an
# ABSOLUTE C-toolchain path (/usr/bin/cc etc). Scan each bite-proof for those before
# trusting the run. (A `${HERBERT:-...build/herbert}` DEFAULT is fine -- the driver
# overrides $HERBERT with the tombstone.)
while IFS=$'\t' read -r s flag; do
    [[ -n "$s" && -f "$script_dir/$s" ]] || continue
    body="$(grep -vE '^[[:space:]]*#' "$script_dir/$s")"
    if grep -E 'build/herbert' <<<"$body" | grep -vE '\$\{[^}]*:[-=][^}]*build/herbert' | grep -q .; then
        die "bite-proof $s has a command-position hardcoded build/herbert (C bypass the $HERBERT count cannot see)"
    fi
    if grep -E '(^|[^[:alnum:]_/])/[^[:space:]"'\'']*/(cc|gcc|g\+\+|clang|cpp|as|ld)([[:space:]"'\'']|$)' <<<"$body" | grep -q .; then
        die "bite-proof $s invokes an ABSOLUTE C toolchain path (the PATH poison cannot see it)"
    fi
done < <(printf '%s\n' "$FROZEN_BITEPROOFS")

note "== switchover-dry-run -- the C-free BITE-PROOFS, with the C interpreter PHYSICALLY ABSENT =="
note "  (extended toolchain poison; static anti-bypass; clean artifact state; gen-1 seed forced; counting C tombstone)"

p=0; f=0
while IFS=$'\t' read -r s flag; do
    [[ -n "$s" ]] || continue
    [[ -x "$script_dir/$s" ]] || { note "  FAIL  $s (missing/not executable)"; f=$((f+1)); continue; }
    # $flag is the gate's retireable-C-cross-check OPT-OUT (enduring leg only). It comes
    # from the frozen literal, but enforce the NAME=VALUE shape before `env $flag` (no
    # arbitrary token injection into the command position).
    if [[ -n "$flag" && ! "$flag" =~ ^[A-Z_][A-Z0-9_]*=[A-Za-z0-9_=:/.-]*$ ]]; then
        note "  FAIL  $s (mode env '$flag' is not a NAME=VALUE flag)"; f=$((f+1)); continue
    fi
    if env HERBERT="$herbert_tomb" $flag bash "$script_dir/$s" >"$scrub_dir/out" 2>&1; then
        # exit 0 is necessary but NOT sufficient: a bite-proof forged to `exit 0`
        # would also pass. Require its success SIGNATURE -- a "PASS" verdict line --
        # which a real bite-proof prints ONLY after catching every mutation. (Each
        # *_native_mutation.sh ends `echo "PASS: ... (N/N ... bite ...)"`.)
        if grep -q 'PASS' "$scrub_dir/out"; then
            note "  ok    $s -- BITES C-absent (enduring leg green + PASS signature; mutations caught without C)"
            p=$((p+1))
        else
            note "  FAIL  $s (exit 0 but NO 'PASS' verdict -- a vacuous/forged bite-proof, not a real catch)"
            sed 's/^/        | /' "$scrub_dir/out" | tail -4; f=$((f+1))
        fi
    else
        note "  FAIL  $s (did NOT stand C-absent)"; sed 's/^/        | /' "$scrub_dir/out" | tail -6
        f=$((f+1))
    fi
done < <(printf '%s\n' "$FROZEN_BITEPROOFS")

c_calls=$(wc -l <"$count_file" | tr -d ' ')
note ""
note "  bite-proofs green C-absent: $p/$(printf '%s\n' "$FROZEN_BITEPROOFS" | grep -c .)"
fail=0
[[ "$f" -eq 0 ]] || { note "  RED: $f bite-proof(s) did not stand C-absent"; fail=1; }
if [[ "$c_calls" != "0" ]]; then
    note "  C-INVOCATION LEAK: the C tombstone was called $c_calls time(s):"; sed 's/^/        | /' "$count_file"; fail=1
else
    note "  C-invocation count: 0 (no call through \$HERBERT or the poisoned toolchain; static anti-bypass clean)"
fi

note ""
if [[ "$fail" -eq 0 ]]; then
    note "PASS: switchover-dry-run (all 7 C-free bite-proofs still bite -- each reaches its PASS verdict"
    note "      with the C interpreter PHYSICALLY ABSENT; 0 invocations through \$HERBERT or the PATH-poisoned"
    note "      toolchain, no hardcoded/absolute-path C bypass -- the non-vacuity guards survive C's removal)"
    exit 0
fi
note "FAIL: switchover-dry-run (the C-free bite-proofs did NOT all stand C-absent)"
exit 1
