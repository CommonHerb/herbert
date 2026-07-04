#!/usr/bin/env bash
# run_switchover_dryrun_mutation.sh -- sovereignty link 17: prove the switchover
# DRY-RUN gate BITES (RED-first). Five load-bearing mutations, each of which MUST
# flip the dry-run RED -- otherwise a guard in run_switchover_dryrun.sh is decorative:
#
#   M-cleak       The 0-C-invocation assertion must DETECT C. Drop one bite-proof's
#                 retireable-cross-check OPT-OUT (*_NO_C): the bite-proof then runs its
#                 C cross-check, hits the counting tombstone -> the dry-run must go RED
#                 ("C-INVOCATION LEAK"). A C-using bite-proof cannot hide.
#   M-cleanstate  The clean-state precondition must bite. Plant a stale build/herbert:
#                 the dry-run must REFUSE to run ("stale C-built artifact") -- a dry-run
#                 may not silently reuse a pre-built C binary.
#   M-gerrymander The bite-proof set is FROZEN by exact membership against the manifest.
#                 Drop one entry from FROZEN_BITEPROOFS: the dry-run must go RED
#                 ("!= the frozen bite-proof set") -- you cannot shrink the proven set.
#   M-forge       The dry-run requires every bite-proof's PASS SIGNATURE, not just
#                 exit 0. Replace one bite-proof with a stub that EXITS 0 with NO
#                 verdict (the silent-success forge): the dry-run must go RED on the
#                 missing 'PASS' -- a forged-green bite-proof cannot be waved through.
#   M-borncfree   The excluded (born-C-free, column-4 "-") CFREE_BITEPROOFs are pinned by
#                 exact membership to a named allowlist. Append an UNLISTED "-" bite-proof
#                 to the manifest: the $4!="-" frozen-set filter excludes it (so the
#                 membership pin still reads 7==7), so the born-C-free allowlist check must
#                 catch it -> the dry-run must go RED ("born-C-free allowlist"). A retireable
#                 bite-proof mislabeled "-" to dodge the frozen set cannot hide.
#
# Exit 0 iff all five bite and the matching CONTROL is GREEN.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
driver="$script_dir/run_switchover_dryrun.sh"
[[ -x "$driver" ]] || { echo "FAIL: missing run_switchover_dryrun.sh"; exit 1; }

work="$(mktemp -d)"
mut="$script_dir/dryrun_mut_tmp_$$.sh"   # a temp driver copy must live in script_dir
                                         # so its repo_root + gate paths still resolve.
restore_emitter() { [[ -f "$work/emitter.orig" ]] && cp "$work/emitter.orig" "$script_dir/run_emitter_native_mutation.sh"; }
trap 'restore_emitter; rm -rf "$work" "$mut"; rm -f "$repo_root/build/herbert"' EXIT

pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  BAD  %s\n' "$1"; fail=$((fail+1)); }

run_driver() { timeout 300 bash "$1" >"$work/out" 2>&1; }

# --- CONTROL: the unmutated dry-run is GREEN --------------------------------
printf '== CONTROL: the unmutated dry-run is GREEN ==\n'
if run_driver "$driver"; then ok "CONTROL: dry-run PASSES unmutated"; else bad "CONTROL: dry-run should pass unmutated ($(tail -1 "$work/out"))"; fi

# --- M-cleak: dropping a *_NO_C opt-out lets a bite-proof reach C ------------
printf '== M-cleak: the 0-C-invocation assertion detects a C-reaching bite-proof ==\n'
# run_aggregate_render_native_mutation.sh carries the retireable C cross-check
# (M-sep: native two-stage image == C image) that invokes $HERBERT when NOT opted
# out. Remove AGGREGATE_RENDER_MUTATION_NO_C=1 so it runs that cross-check -> hits
# the counting tombstone. (FROZEN_BITEPROOFS is a $'...' literal: its field
# separator is the two source chars backslash-t = \\t in sed.) Dropping the flag
# leaves an EMPTY flag (clean env), not "-".
sed 's/run_aggregate_render_native_mutation.sh\\tAGGREGATE_RENDER_MUTATION_NO_C=1/run_aggregate_render_native_mutation.sh/' "$driver" >"$mut"; chmod +x "$mut"
# Setup validity: the sed MUST have removed the opt-out (else the mutation is vacuous
# and any failure would be for the wrong reason).
if ! cmp -s "$driver" "$mut" && ! grep -q 'run_aggregate_render_native_mutation.sh\\tAGGREGATE_RENDER_MUTATION_NO_C=1' "$mut"; then
    if run_driver "$mut"; then bad "M-cleak did NOT bite: dry-run passed with a C-reaching bite-proof"; else
        grep -qE 'C-INVOCATION LEAK|tombstone was called' "$work/out" && ok "M-cleak BITES: dry-run RED via the C-invocation count" || bad "M-cleak failed but NOT via the C count ($(grep -E 'FAIL|LEAK' "$work/out" | head -1))"
    fi
else
    bad "M-cleak setup INVALID: the opt-out flag was not removed (sed no-op) -- mutation is vacuous"
fi

# --- M-cleanstate: a stale C-built binary is refused ------------------------
printf '== M-cleanstate: the clean-state precondition refuses a stale C binary ==\n'
mkdir -p "$repo_root/build"
# Use a sentinel name the trap cleans; the check looks for build/herbert exactly,
# so plant build/herbert (saved/restored is unnecessary -- a fresh worktree has none).
: >"$repo_root/build/herbert"
if run_driver "$driver"; then rm -f "$repo_root/build/herbert"; bad "M-cleanstate did NOT bite: dry-run ran with a stale build/herbert present"; else
    rm -f "$repo_root/build/herbert"
    grep -q 'stale C interpreter artifact' "$work/out" && ok "M-cleanstate BITES: dry-run RED on a stale C binary" || bad "M-cleanstate failed but not via the clean-state check ($(grep FAIL "$work/out" | head -1))"
fi

# --- M-gerrymander: the bite-proof set is frozen by exact membership --------
printf '== M-gerrymander: the bite-proof set is FROZEN against the manifest ==\n'
# Drop a MIDDLE entry (run_klondike_native_mutation) from FROZEN_BITEPROOFS (it stays
# in the manifest) -> membership mismatch. Must be a middle line, not the last: the
# set is a $'...' literal whose last line carries the closing quote.
grep -v 'run_klondike_native_mutation' "$driver" >"$mut"; chmod +x "$mut"
if run_driver "$mut"; then bad "M-gerrymander did NOT bite: dry-run passed with a shrunk bite-proof set"; else
    grep -qE 'frozen bite-proof set|gerrymander' "$work/out" && ok "M-gerrymander BITES: dry-run RED on set != manifest" || bad "M-gerrymander failed but not via the membership check ($(grep FAIL "$work/out" | head -1))"
fi

# --- M-forge: a silent-success (exit 0, no PASS) bite-proof is caught --------
printf '== M-forge: the dry-run requires the PASS signature, not just exit 0 ==\n'
# Replace a real bite-proof's CONTENTS with a SILENT-SUCCESS forge (exit 0 with no
# verdict) -- the exact attack the PASS-signature check defends. Membership is
# UNCHANGED, so this isolates the bite-semantics requirement from the frozen-set check.
emitter="$script_dir/run_emitter_native_mutation.sh"
cp "$emitter" "$work/emitter.orig"
printf '#!/usr/bin/env bash\necho "silent success, no verdict"\nexit 0\n' >"$emitter"; chmod +x "$emitter"
run_driver "$driver"; rc=$?
restore_emitter
if [[ $rc -eq 0 ]]; then bad "M-forge did NOT bite: dry-run passed a silent-success (exit 0, no PASS) bite-proof"; else
    grep -qiE "NO .PASS. verdict|vacuous/forged" "$work/out" && ok "M-forge BITES: dry-run RED on a forged-green bite-proof (no PASS signature)" || bad "M-forge failed but not via the PASS-signature check ($(grep -i fail "$work/out" | head -1))"
fi

# --- M-borncfree: an unlisted column-4 "-" CFREE_BITEPROOF (mislabeled retireable / new born-C-free) ------
printf '== M-borncfree: an unlisted column-4 "-" CFREE_BITEPROOF is caught by the born-C-free allowlist ==\n'
# Append a fake CFREE_BITEPROOF row whose mode-env is "-" and whose script is NOT on the driver's
# born-C-free allowlist. The $4!="-" frozen-set filter EXCLUDES it, so the membership pin still reads 7==7
# and would NOT catch it -- which is exactly why the born-C-free allowlist check must. Point the UNMUTATED
# driver at the mutated manifest via SWITCHOVER_MANIFEST; it must go RED on the allowlist diff.
fake_manifest="$work/manifest_borncfree.tsv"
cp "$script_dir/switchover_manifest.tsv" "$fake_manifest"
printf 'CFREE_BITEPROOF\tverify-local\trun_fake_borncfree_mutation.sh\t-\tfake born-C-free row (M-borncfree)\n' >> "$fake_manifest"
if timeout 300 env SWITCHOVER_MANIFEST="$fake_manifest" bash "$driver" >"$work/out" 2>&1; then
    bad "M-borncfree did NOT bite: dry-run passed with an unlisted '-' CFREE_BITEPROOF"
else
    grep -q 'born-C-free allowlist' "$work/out" && ok "M-borncfree BITES: dry-run RED on an unlisted born-C-free-labeled bite-proof" || bad "M-borncfree failed but not via the allowlist check ($(grep FAIL "$work/out" | head -1))"
fi

printf '\n'
if [[ "$fail" -eq 0 ]]; then
    echo "PASS: switchover-dry-run mutation proof ($pass/$pass -- M-cleak + M-cleanstate + M-gerrymander + M-forge + M-borncfree all bite, control green)"
    exit 0
fi
echo "FAIL: switchover-dry-run mutation proof ($fail of $((pass+fail)) checks bad)"
exit 1
