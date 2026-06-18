#!/usr/bin/env bash
# Re-mint the C-free gen-1 seed (bootstrap/seed/gen1.seed) from the C bootstrap.
#
# This is the ONE sanctioned place the C interpreter mints gen-1. Run it ONLY
# when stack/native_compile_fragment.herb legitimately changes (which shifts
# gen-1's bytes -> the committed seed goes stale -> the michoi seed gate goes
# RED). A RED michoi gate means "re-seed", not "regression".
#
#   usage:  make reseed        (or: bash bootstrap/tests/reseed_gen1.sh)
#
# It mints gen-1 via C, PROVES the fresh mint reproduces itself C-free
# (determinism guard), then rewrites gen1.seed + gen1.seed.sha256.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
HERBERT="${HERBERT:-$root/build/herbert}"
backend="$root/stack/native_compile_fragment.herb"
seed="$root/bootstrap/seed/gen1.seed"

[[ -x "$HERBERT" ]] || { echo "reseed: build the C bootstrap first (make all): $HERBERT"; exit 1; }
[[ -f "$backend" ]] || { echo "reseed: missing backend $backend"; exit 1; }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
echo "reseed: minting gen-1 via the C interpreter (provenance: the S2 seed)..."
( cd "$work" && "$HERBERT" "$backend" <"$backend" >/dev/null )
magic="$(head -c4 "$work/a.out" | xxd -p | tr -d '\n')"
[[ "$magic" == "7f454c46" ]] || { echo "reseed: mint did not produce an ELF (magic=$magic)"; exit 1; }

# C-free self-reproduction: the fresh mint must reproduce itself byte-for-byte
# (this is what makes a committed seed legitimate).
g2="$(mktemp -d)"; cp "$work/a.out" "$g2/seedbin"; chmod +x "$g2/seedbin"
( cd "$g2" && ./seedbin <"$backend" >/dev/null )
cmp -s "$work/a.out" "$g2/a.out" || { echo "reseed: FRESH mint does not self-reproduce (non-deterministic emit?) -- ABORT"; exit 1; }

if [[ -f "$seed" ]] && cmp -s "$work/a.out" "$seed"; then
    echo "reseed: committed seed already current (no change needed)."
    exit 0
fi

mkdir -p "$root/bootstrap/seed"
cp "$work/a.out" "$seed"
chmod -x "$seed" 2>/dev/null || true
( cd "$root/bootstrap/seed" && sha256sum gen1.seed >gen1.seed.sha256 )
echo "reseed: updated $seed"
echo "reseed: $(cat "$root/bootstrap/seed/gen1.seed.sha256")"
echo "reseed: now 'git add bootstrap/seed/gen1.seed bootstrap/seed/gen1.seed.sha256' and run 'make check && make test'."
