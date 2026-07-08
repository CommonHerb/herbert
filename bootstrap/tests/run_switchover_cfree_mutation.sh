#!/usr/bin/env bash
# run_switchover_cfree_mutation.sh -- sovereignty link 14: prove the C-absent
# switchover machinery BITES (RED-first). Four load-bearing mutations, each of
# which MUST flip RED -- otherwise a guard in run_switchover_cfree.sh is decorative:
#
#   (M-leak retired WITH C at the switchover -- sovereignty link `castoff`: it proved
#    the counting tombstone DETECTS C use by running a C-using gate; with the C
#    interpreter physically gone there is no C-using gate to invoke, so the proof is
#    vacuously satisfied and unprovable. The remaining four still bite.)
#
#   M-guard      The vestigial-guard CONDITIONING is what makes the C-free
#                production gates runnable with C absent. Restore a gate's OLD bare
#                `[[ ! -x "$HERBERT" ]]` guard, run it with $HERBERT truly absent +
#                golden oracle: it must FAIL where the real conditioned gate PASSES.
#   M-gerrymander  The surface is FROZEN by exact membership. Move a CFREE_SWITCHOVER
#                gate to another disposition (manifest still complete) -> the driver
#                must go RED (you cannot shrink/swap the proven surface).
#   M-modeenv    The mode env is allowlisted. Inject an arbitrary `KEY=VAL` into a
#                surface row -> the driver must go RED (no manifest-text injection).
#   M-incomplete The partition must be EXHAUSTIVE. Drop a row -> driver RED (limbo).
#
# Exit 0 iff all four bite and the matching CONTROL is GREEN.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
manifest="$script_dir/switchover_manifest.tsv"
driver="$script_dir/run_switchover_cfree.sh"
gate="$script_dir/run_native_codegen_link2.sh"

work="$(mktemp -d)"
bite_gate="$script_dir/biteproof_tmp_link2_$$.sh"   # temp copy must live beside the
                                                    # oracle it sources (script_dir)
trap 'rm -rf "$work" "$bite_gate"' EXIT

pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  BAD  %s\n' "$1"; fail=$((fail+1)); }

# A truly-absent C interpreter + poisoned C toolchain.
scrub="$work/bin"; mkdir -p "$scrub"
for t in cc gcc clang c++ g++ as ld; do printf '#!/bin/sh\nexit 127\n' >"$scrub/$t"; chmod +x "$scrub/$t"; done
seed_exec="$work/gen1"; cp "$script_dir/../seed/gen1.seed" "$seed_exec"; chmod +x "$seed_exec"
absent_herbert="$work/NO-C-INTERPRETER-HERE"

printf '== M-guard: the vestigial-guard conditioning is load-bearing ==\n'
run_gate() { env PATH="$scrub:$PATH" HERBERT="$absent_herbert" NATIVE_CODEGEN_ORACLE=golden \
                 NATIVE_CODEGEN_COMPILER="$seed_exec" NATIVE_CODEGEN_ALLOW_C_MINT= bash "$1" >"$work/out" 2>&1; }
if run_gate "$gate"; then ok "CONTROL conditioned gate GREEN with C truly absent"; else bad "CONTROL conditioned gate should pass C-absent ($(tail -1 "$work/out"))"; fi
sed 's/\[\[ "\${NATIVE_CODEGEN_ORACLE:-golden}" == "c" && ! -x "\$HERBERT" \]\]/[[ ! -x "$HERBERT" ]]/' "$gate" >"$bite_gate"; chmod +x "$bite_gate"
grep -q '\[\[ ! -x "\$HERBERT" \]\]' "$bite_gate" || bad "M-guard setup: bare guard not restored"
if run_gate "$bite_gate"; then bad "M-guard did NOT bite: bare-guard gate passed C-absent"; else
    grep -q 'cannot find herbert' "$work/out" && ok "M-guard BITES: bare-guard gate FAILS C-absent for the right reason" || bad "M-guard failed but not via the bare guard ($(tail -1 "$work/out"))"
fi

printf '== M-gerrymander: the CFREE surface is FROZEN by exact membership ==\n'
# Move one CFREE_SWITCHOVER gate to CFREE_KERNEL while keeping the partition complete.
sed 's/^CFREE_SWITCHOVER\tswitchover\trun_native_codegen_link1\.sh\tNATIVE_CODEGEN_ORACLE=golden/CFREE_KERNEL\tkernel-ci\trun_native_codegen_link1.sh\t-/' "$manifest" >"$work/m_gerry.tsv"
if SWITCHOVER_MANIFEST="$work/m_gerry.tsv" bash "$driver" >"$work/out" 2>&1; then bad "M-gerrymander did NOT bite: driver passed with a shrunk CFREE surface"; else
    grep -q 'FROZEN' "$work/out" && ok "M-gerrymander BITES: driver RED on surface != frozen set" || bad "M-gerrymander failed but not via the frozen-set check ($(grep FAIL "$work/out" | head -1))"
fi

printf '== M-modeenv: the mode env is allowlisted (no manifest-text injection) ==\n'
sed 's/^CFREE_SWITCHOVER\tswitchover\trun_native_codegen_link2\.sh\tNATIVE_CODEGEN_ORACLE=golden/CFREE_SWITCHOVER\tswitchover\trun_native_codegen_link2.sh\tINJECTED=evil/' "$manifest" >"$work/m_mode.tsv"
if SWITCHOVER_MANIFEST="$work/m_mode.tsv" bash "$driver" >"$work/out" 2>&1; then bad "M-modeenv did NOT bite: driver accepted an injected mode env"; else
    grep -q 'non-allowlisted mode' "$work/out" && ok "M-modeenv BITES: driver RED on injected mode env" || bad "M-modeenv failed but not via the mode allowlist ($(grep FAIL "$work/out" | head -1))"
fi

printf '== M-incomplete: the partition must be exhaustive (no limbo) ==\n'
grep -v $'\trun_native_codegen_link17.sh\t' "$manifest" >"$work/m_incomplete.tsv"
if SWITCHOVER_MANIFEST="$work/m_incomplete.tsv" bash "$driver" >"$work/out" 2>&1; then bad "M-incomplete did NOT bite: driver passed with run_native_codegen_link17.sh in limbo"; else
    grep -q 'incomplete/duplicated partition' "$work/out" && ok "M-incomplete BITES: driver RED on the limbo gate" || bad "M-incomplete failed but not via the completeness check ($(grep FAIL "$work/out" | head -1))"
fi

printf '\n'
if [[ "$fail" -eq 0 ]]; then
    echo "PASS: switchover-cfree mutation proof ($pass/$pass -- M-guard + M-gerrymander + M-modeenv + M-incomplete all bite, control green)"
    exit 0
fi
echo "FAIL: switchover-cfree mutation proof ($fail of $((pass+fail)) checks bad)"
exit 1
