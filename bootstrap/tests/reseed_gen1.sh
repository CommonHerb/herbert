#!/usr/bin/env bash
# Re-mint the gen-1 seed (bootstrap/seed/gen1.seed) C-FREE, via the committed seed.
#
# Post-switchover (castoff, sovereignty link 18) the C bootstrap interpreter is gone;
# the seed re-mints ITSELF. Run this ONLY when stack/native_compile_fragment.herb
# legitimately changes (which shifts gen-1's bytes -> the committed seed goes stale ->
# the michoi seed gate goes RED). A RED michoi gate means "re-seed", not "regression".
#
#   usage:  make reseed        (or: bash bootstrap/tests/reseed_gen1.sh)
#
# It compiles the (possibly changed) backend with the CURRENT committed seed to mint
# the new gen-1, PROVES the fresh mint reproduces itself (the self-hosting fixpoint /
# determinism guard -- the ONLY validation now that there is no C to diff against),
# then rewrites gen1.seed + gen1.seed.sha256. NO C is involved.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
backend="$root/stack/native_compile_fragment.herb"
seed="$root/bootstrap/seed/gen1.seed"

[[ -f "$seed" ]] || { echo "reseed: missing committed seed $seed (cannot re-mint C-free without it)"; exit 1; }
[[ -f "$backend" ]] || { echo "reseed: missing backend $backend"; exit 1; }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
echo "reseed: minting gen-1 by compiling the backend with the committed C-free seed..."
cp "$seed" "$work/seedbin"; chmod +x "$work/seedbin"
( cd "$work" && ./seedbin <"$backend" >/dev/null )
magic="$(head -c4 "$work/a.out" | xxd -p | tr -d '\n')"
[[ "$magic" == "7f454c46" ]] || { echo "reseed: mint did not produce an ELF (magic=$magic)"; exit 1; }

# Fixpoint / determinism guard: the fresh mint must reproduce ITSELF byte-for-byte
# when IT compiles the backend (gen-1' == gen-2'). This self-hosting fixpoint is what
# makes a committed seed legitimate -- and, post-switchover, the ONLY validation (there
# is no C interpreter to diff against).
g2="$(mktemp -d)"; cp "$work/a.out" "$g2/seedbin"; chmod +x "$g2/seedbin"
( cd "$g2" && ./seedbin <"$backend" >/dev/null )
cmp -s "$work/a.out" "$g2/a.out" || { echo "reseed: FRESH mint does not self-reproduce (not at the fixpoint -- re-run to iterate the bootstrap, or investigate a non-deterministic / non-converging backend change) -- ABORT"; exit 1; }

if [[ -f "$seed" ]] && cmp -s "$work/a.out" "$seed"; then
    echo "reseed: committed seed already current (no change needed)."
    exit 0
fi

cp "$work/a.out" "$seed"
chmod -x "$seed" 2>/dev/null || true
( cd "$root/bootstrap/seed" && sha256sum gen1.seed >gen1.seed.sha256 )
echo "reseed: updated $seed (C-free, via the committed seed)"
echo "reseed: $(cat "$root/bootstrap/seed/gen1.seed.sha256")"
echo "reseed: now 'git add bootstrap/seed/gen1.seed bootstrap/seed/gen1.seed.sha256' and run 'make check && make test'."
