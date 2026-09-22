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
# It verifies the current seed pin, snapshots the inputs, and checks both compiler
# invocations' complete success envelopes. A changed, self-reproducing candidate
# must pass ordinary hosted conformance BEFORE replacing the seed. Full hosted and
# applicable target qualification still follow; convergence is not provenance.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
backend="$root/stack/native_compile_fragment.herb"
seed="$root/bootstrap/seed/gen1.seed"

pin="$seed.sha256"
die() { echo "reseed: $*" >&2; exit 1; }
for input in "$seed" "$pin" "$backend"; do
    [[ -f "$input" && ! -L "$input" ]] || die "input must be a regular non-symlink file: $input"
done

work="$(mktemp -d "${TMPDIR:-/tmp}/herbert-reseed.XXXXXXXX")"
stage=""
finish() {
    local status=$?
    if [[ "$status" -eq 0 ]]; then
        rm -rf -- "${work:?}"
        if [[ -n "$stage" ]]; then rmdir -- "$stage"; fi
    else
        echo "reseed: failed work retained at $work" >&2
        if [[ -n "$stage" ]]; then echo "reseed: publication staging retained at $stage" >&2; fi
    fi
}
trap finish EXIT
cp -- "$seed" "$work/previous.seed"
cp -- "$pin" "$work/previous.sha256"
cp -- "$backend" "$work/source.herb"
digest="$(sha256sum "$work/previous.seed" | awk '{print $1}')"
printf '%s  gen1.seed\n' "$digest" > "$work/expected.sha256"
cmp -s "$work/expected.sha256" "$work/previous.sha256" || die 'current seed checksum mismatch; no compiler executed'
printf '0\n' > "$work/expected.stdout"

require_elf() {
    [[ -f "$1" && ! -L "$1" ]] || die "missing regular compiler image: $1"
    [[ "$(od -An -tx1 -N6 "$1" | tr -d ' \n')" == 7f454c460201 &&
       "$(od -An -tx1 -j18 -N2 "$1" | tr -d ' \n')" == 3e00 ]] || die "not a Linux/x86-64 little-endian ELF: $1"
}
compile_generation() {
    local input=$1 directory=$2 status
    require_elf "$input"
    mkdir -- "$directory"
    cp -- "$input" "$directory/compiler"
    chmod u+x "$directory/compiler"
    if (cd "$directory" && ./compiler < "$work/source.herb" > compiler.stdout 2> compiler.stderr); then
        status=0
    else
        status=$?
    fi
    printf '%s\n' "$status" > "$directory/compiler.status"
    [[ "$status" -eq 0 ]] || die "compiler exited $status in $directory"
    cmp -s "$work/expected.stdout" "$directory/compiler.stdout" && [[ ! -s "$directory/compiler.stderr" ]] || die "compiler success envelope failed in $directory"
    require_elf "$directory/a.out"
}
require_unchanged_inputs() {
    [[ -f "$seed" && ! -L "$seed" && -f "$pin" && ! -L "$pin" &&
       -f "$backend" && ! -L "$backend" ]] &&
        cmp -s "$seed" "$work/previous.seed" &&
        cmp -s "$pin" "$work/previous.sha256" &&
        cmp -s "$backend" "$work/source.herb" ||
        die 'inputs changed during qualification; refusing publication'
}

echo "reseed: minting gen-1 by compiling the backend with the checksum-verified C-free seed..."
compile_generation "$work/previous.seed" "$work/gen1"
compile_generation "$work/gen1/a.out" "$work/gen2"
cmp -s "$work/gen1/a.out" "$work/gen2/a.out" || die 'fresh mint does not self-reproduce; seed unchanged'
require_unchanged_inputs

if cmp -s "$work/gen1/a.out" "$work/previous.seed"; then
    echo "reseed: committed seed already current (no change needed)."
    exit 0
fi

echo 'reseed: checking changed candidate against ordinary hosted conformance before publication...'
if ! python3 "$here/compiler_conformance.py" --compiler "$work/gen1/a.out" > "$work/conformance.log" 2>&1; then
    cat "$work/conformance.log" >&2
    die 'candidate conformance failed; seed unchanged'
fi
tail -n 1 "$work/conformance.log"
# This recipe has one writer. Refuse to replace inputs edited during qualification.
require_unchanged_inputs
stage="$(mktemp -d "$root/bootstrap/seed/.reseed.XXXXXXXX")"
cp -- "$work/gen1/a.out" "$stage/gen1.seed"
(cd "$stage" && sha256sum gen1.seed > gen1.seed.sha256)
chmod 644 "$stage/gen1.seed" "$stage/gen1.seed.sha256"
# Each file is replaced atomically. An interruption between the two renames leaves
# a detectable checksum mismatch; retained failure inputs provide the prior pair.
mv -T -- "$stage/gen1.seed" "$seed"
mv -T -- "$stage/gen1.seed.sha256" "$pin"
echo "reseed: updated $seed (C-free, via the committed seed)"
echo "reseed: $(cat "$pin")"
echo "reseed: now qualify the changed compiler with 'make verify-local' and applicable target gates."
