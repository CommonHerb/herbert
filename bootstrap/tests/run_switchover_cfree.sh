#!/usr/bin/env bash
# run_switchover_cfree.sh -- sovereignty link 14: the first SWITCHOVER-MACHINERY slice.
#
# Proves the C-FREE production surface STANDS WITH THE C INTERPRETER PHYSICALLY
# ABSENT. Every prior sovereignty link proved "C present but not invoked on path
# P" with a counting fence (michoi mint / turnstile fragment-grades / tollgate
# codegen-grades / muster foundational-grades). NONE proved the surface survives
# C's physical removal -- and `make test` itself unconditionally `cc`-builds
# build/herbert and runs C on the retire-with-C set, so no C-absent configuration
# existed. This driver is that configuration. It is forge-resistant by design:
#
#   * FROZEN SURFACE   the CFREE_SWITCHOVER run-list is pinned by exact membership
#                      here, so a gerrymandered/emptied/swapped manifest is RED
#                      (you cannot shrink the surface to make the proof pass).
#   * SEED FORCED      the committed C-free gen-1 seed is the production compiler
#                      (NATIVE_CODEGEN_COMPILER), not merely "C not preset".
#   * MODE ALLOWLIST   each gate's C-free mode env must be a known flag (no
#                      arbitrary `env KEY=VAL` injection from the manifest text).
#   * STATIC ANTI-BYPASS  no surface gate may reach C via a command-position
#                      hardcoded `build/herbert` (the $HERBERT count is blind to it).
#   * TWO PHASES       (A) $HERBERT a NONEXISTENT path -> catches any "C must be
#                      present" guard; (B) $HERBERT a counting TOMBSTONE whose exec
#                      target does not exist -> asserts ZERO C invocations (and any
#                      actual call both counts AND fails). cc/gcc/clang/c++/g++/as/ld
#                      are poisoned in both -- the gen-1 seed casts ELF directly.
#
# Exit 0 iff the whole frozen CFREE_SWITCHOVER surface ran green with C absent in
# BOTH phases, with zero C invocations, over a COMPLETE whole-suite partition.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
manifest="${SWITCHOVER_MANIFEST:-$script_dir/switchover_manifest.tsv}"
seed="$script_dir/../seed/gen1.seed"

note() { printf '%s\n' "$*"; }
die()  { printf 'FAIL: switchover-cfree (%s)\n' "$1"; exit 1; }

# The frozen C-free production surface (sovereignty link 14). Changing this set is
# a deliberate act recorded in git -- the manifest's CFREE_SWITCHOVER rows must
# equal it exactly, or the proof is RED.
FROZEN_SURFACE="$(printf '%s\n' \
  run_native_codegen_link1.sh run_native_codegen_link2.sh run_native_codegen_link3.sh \
  run_native_codegen_link4.sh run_native_codegen_link5.sh run_native_codegen_link6.sh \
  run_native_codegen_link7.sh run_native_codegen_link8.sh run_native_codegen_link9.sh \
  run_native_codegen_link10.sh run_native_codegen_link11.sh run_native_codegen_link12.sh \
  run_native_codegen_link13.sh run_native_codegen_link14.sh run_native_codegen_link15.sh \
  run_native_codegen_link16.sh run_native_codegen_rejects.sh \
  run_evaluator_native.sh run_vm_native.sh run_parser_native.sh run_lexer_native.sh \
  run_klondike_native.sh run_emitter_native.sh run_aggregate_render_native.sh \
  run_error_vocab_native.sh | sort)"
# Allowlisted C-free mode envs (no arbitrary injection from manifest text).
ALLOWED_MODES=$'-\nNATIVE_CODEGEN_ORACLE=golden\nEVALUATOR_NATIVE_NO_C=1\nVM_NATIVE_NO_C=1\nPARSER_NATIVE_NO_C=1\nLEXER_NATIVE_NO_C=1\nKLONDIKE_NATIVE_NO_C=1\nEMITTER_NATIVE_NO_C=1\nAGGREGATE_RENDER_NATIVE_NO_C=1'

[[ -f "$manifest" ]] || die "missing switchover_manifest.tsv"
[[ -f "$seed" && -f "$seed.sha256" ]] || die "missing committed gen-1 seed"

# --- seed integrity precondition (michoi's gate, inlined) --------------------
seed_magic=$(head -c4 "$seed" | xxd -p | tr -d '\n')
seed_want=$(awk '{print $1}' "$seed.sha256")
seed_got=$(sha256sum "$seed" | awk '{print $1}')
[[ "$seed_magic" == "7f454c46" ]] || die "committed seed is not an ELF (magic=$seed_magic)"
[[ "$seed_got" == "$seed_want" ]] || die "committed seed sha mismatch (got=$seed_got want=$seed_want)"

# --- 0. completeness: the manifest must partition EVERY run_*.sh exactly once --
inv_missing=""
for s in "$script_dir"/run_*.sh; do
    b="$(basename "$s")"
    n=$(awk -F'\t' -v want="$b" '$0 !~ /^#/ && $3==want {c++} END{print c+0}' "$manifest")
    [[ "$n" -eq 1 ]] || inv_missing="$inv_missing $b(x$n)"
done
[[ -z "$inv_missing" ]] || die "incomplete/duplicated partition -- run_*.sh not classified exactly once:$inv_missing"
phantom=""
while IFS=$'\t' read -r disp ctx scriptname modeenv reason; do
    [[ -f "$script_dir/$scriptname" ]] || phantom="$phantom $scriptname"
done < <(grep -vE '^#|^[[:space:]]*$' "$manifest")
[[ -z "$phantom" ]] || die "manifest names nonexistent scripts:$phantom"
note "switchover-cfree: partition COMPLETE -- every run_*.sh classified exactly once ($(grep -vcE '^#|^[[:space:]]*$' "$manifest") rows)"

# --- 1. the run-surface == the FROZEN list; modes allowlisted; no C bypass ----
declare -a SURFACE_SCRIPTS SURFACE_MODES
manifest_surface=""
while IFS=$'\t' read -r disp ctx scriptname modeenv reason; do
    [[ "$disp" == "CFREE_SWITCHOVER" ]] || continue
    manifest_surface="$manifest_surface$scriptname"$'\n'
    grep -qxF "$modeenv" <<<"$ALLOWED_MODES" || die "gate $scriptname has a non-allowlisted mode env '$modeenv' (possible injection)"
    SURFACE_SCRIPTS+=("$scriptname"); SURFACE_MODES+=("$modeenv")
done < <(grep -vE '^#|^[[:space:]]*$' "$manifest")
manifest_surface="$(printf '%s' "$manifest_surface" | grep -v '^$' | sort)"
if [[ "$manifest_surface" != "$FROZEN_SURFACE" ]]; then
    die "manifest CFREE_SWITCHOVER set != the FROZEN 25-gate surface (gerrymander/swap):"$'\n'"$(diff <(printf '%s\n' "$FROZEN_SURFACE") <(printf '%s\n' "$manifest_surface") | sed 's/^/    /')"
fi
# Static anti-bypass: a surface gate must not reach C by a path the $HERBERT
# tombstone count cannot see -- a hardcoded `build/herbert`, or an absolute C
# toolchain (`/usr/bin/cc` etc.) the PATH-poison misses. A `${HERBERT:-...
# build/herbert}` DEFAULT is fine (the driver overrides $HERBERT). The exclusion
# requires build/herbert to sit INSIDE a `${...:-/:=...}` expansion (Codex
# re-review: a whole-line `:[-=]` filter false-negatives `: "${X:=x}"; build/herbert`).
for s in "${SURFACE_SCRIPTS[@]}"; do
    body="$(grep -vE '^[[:space:]]*#' "$script_dir/$s")"
    if grep -E 'build/herbert' <<<"$body" | grep -vE '\$\{[^}]*:[-=][^}]*build/herbert' | grep -q .; then
        die "surface gate $s has a command-position hardcoded build/herbert (C bypass the count cannot see)"
    fi
    if grep -E '(^|[^[:alnum:]_/])/[^[:space:]\"'\'']*/(cc|gcc|g\+\+|clang|as|ld)([[:space:]\"'\'']|$)' <<<"$body" | grep -q .; then
        die "surface gate $s invokes an ABSOLUTE C toolchain path (PATH-poison cannot see it)"
    fi
done
note "switchover-cfree: surface is the FROZEN ${#SURFACE_SCRIPTS[@]}-gate set; modes allowlisted; no hardcoded-C bypass"

# --- 2. build the C-absent environment ---------------------------------------
scrub_dir="$(mktemp -d)" || die "mktemp -d failed"
count_file="$(mktemp)" || die "mktemp failed"
trap 'rm -rf "$scrub_dir" "$count_file"' EXIT

# Poison the C toolchain (the gen-1 seed emits ELF with no cc/as/ld execve).
TOOLS="cc gcc clang c++ g++ as ld"
for t in $TOOLS; do
    printf '#!/bin/sh\necho "switchover-cfree: C toolchain (%s) is physically absent" >&2\nexit 127\n' "$t" >"$scrub_dir/$t"
    chmod +x "$scrub_dir/$t"
done
# FORCE the committed seed as the production compiler (an executable copy).
seed_exec="$scrub_dir/gen1-seed"
cp "$seed" "$seed_exec"; chmod +x "$seed_exec"
export PATH="$scrub_dir:$PATH"
export NATIVE_CODEGEN_COMPILER="$seed_exec"
# Pin the oracle to the COMMITTED goldens: clear every override that could
# redirect a "golden" gate at a forged goldens dir / manifest / capture mode
# (Codex re-review: the inherited-env forgery vector). The defaults in
# native_codegen_oracle.sh then resolve to the committed bootstrap/tests goldens.
unset NATIVE_CODEGEN_ALLOW_C_MINT NATIVE_CODEGEN_GOLDENS_DIR NATIVE_CODEGEN_MANIFEST \
      NATIVE_CODEGEN_ORACLE_CAPTURE NATIVE_CODEGEN_CAPTURE NATIVE_CODEGEN_CAPTURE_MANIFEST \
      NATIVE_CODEGEN_REAL_COMPILER NATIVE_CODEGEN_ORACLE

# Assert the scrub held (an honest physical-absence proof verifies its premise).
for t in $TOOLS; do
    resolved="$(command -v "$t" 2>/dev/null || true)"
    [[ "$resolved" == "$scrub_dir/$t" ]] || die "C toolchain $t is NOT scrubbed (resolved to '${resolved:-<none>}')"
done

# Run the frozen surface; $1 = label, $2 = the $HERBERT to use this phase.
run_surface() {
    local label="$1" herbert="$2" i p=0 f=0
    for i in "${!SURFACE_SCRIPTS[@]}"; do
        local s="${SURFACE_SCRIPTS[$i]}" m="${SURFACE_MODES[$i]}" env_kv=""
        [[ "$m" != "-" ]] && env_kv="$m"
        [[ -x "$script_dir/$s" ]] || { note "  [$label] FAIL  $s (missing/not executable)"; f=$((f+1)); continue; }
        if env HERBERT="$herbert" $env_kv bash "$script_dir/$s" >"$scrub_dir/out" 2>&1; then
            p=$((p+1))
        else
            f=$((f+1)); note "  [$label] FAIL  $s"; sed 's/^/        | /' "$scrub_dir/out" | tail -5
        fi
    done
    note "  [$label] $p/${#SURFACE_SCRIPTS[@]} gates green"
    [[ "$f" -eq 0 ]]
}

note ""
note "== CFREE_SWITCHOVER -- the C-free production surface, with C PHYSICALLY ABSENT =="
phaseA_ok=0; phaseB_ok=0
# Phase A: $HERBERT a NONEXISTENT path -> any "-x $HERBERT" presence guard FIRES.
note "  -- phase A: \$HERBERT is a nonexistent path (catches C-presence guards)"
run_surface "A/absent" "$scrub_dir/NO-C-INTERPRETER-EXISTS" && phaseA_ok=1 || true
# Phase B: $HERBERT a counting tombstone -> assert ZERO invocations.
note "  -- phase B: \$HERBERT is a counting tombstone (asserts 0 C invocations)"
herbert_tomb="$scrub_dir/herbert"
absent_target="$scrub_dir/THIS-C-INTERPRETER-DOES-NOT-EXIST"
printf '#!/bin/sh\nprintf "%%s %%s\\n" "$0" "$*" >> %q\nexec %q "$@"\n' "$count_file" "$absent_target" >"$herbert_tomb"
chmod +x "$herbert_tomb"
run_surface "B/tombstone" "$herbert_tomb" && phaseB_ok=1 || true
c_calls=$(wc -l <"$count_file" | tr -d ' ')

note ""
fail=0
[[ "$phaseA_ok" -eq 1 ]] || { note "  phase A RED: a gate could not run with \$HERBERT absent"; fail=1; }
[[ "$phaseB_ok" -eq 1 ]] || { note "  phase B RED: a gate failed under the C tombstone"; fail=1; }
if [[ "$c_calls" != "0" ]]; then
    note "  C-INVOCATION LEAK: the C tombstone was called $c_calls time(s):"; sed 's/^/        | /' "$count_file"; fail=1
else
    note "  C-invocation count: 0 (the C interpreter was never touched in either phase)"
fi

# --- 3. register every other surface (the complete switchover ledger) --------
register() {
    note ""; note "== $2 =="
    while IFS=$'\t' read -r disp ctx scriptname modeenv reason; do
        [[ "$disp" == "$1" ]] || continue
        note "  [$ctx] $scriptname -- $reason"
    done < <(grep -vE '^#|^[[:space:]]*$' "$manifest")
}
register CFREE_KERNEL      "CFREE_KERNEL -- C-free, far-axis (QEMU+Bochs substrate oracle; C interpreter not invoked; kernel-codegen-l1 CI)"
register KERNEL_C_EMIT     "KERNEL_C_EMIT -- far-axis kernel gates that EMIT via the C interpreter today (rehome onto the seed at the switchover)"
register CFREE_BITEPROOF   "CFREE_BITEPROOF -- C-free RED-first bite-proofs (verify-local)"
register RETIRE_WITH_C     "RETIRE-WITH-C -- needs the C interpreter; retires WHEN C is deleted"
register RETIRE_AT_SWITCH  "RETIRE-AT-SWITCH -- inherently-C reference; retires AT the switchover"

note ""
if [[ "$fail" -eq 0 ]]; then
    note "PASS: switchover-cfree (the frozen ${#SURFACE_SCRIPTS[@]}-gate C-free production surface stands with the C interpreter PHYSICALLY ABSENT in both phases; 0 C invocations; complete switchover partition registered)"
    exit 0
fi
note "FAIL: switchover-cfree (the C-free production surface did NOT stand C-absent)"
exit 1
