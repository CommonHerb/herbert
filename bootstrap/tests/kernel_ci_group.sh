#!/usr/bin/env bash
# Run independent kernel gates, recording every verdict and preserving raw
# outputs of the actual attempts. Any failure keeps the group red.
set -uo pipefail
unset CDPATH
script_dir="$(cd -- "$(dirname -- "$0")" && pwd)" || exit 1
source "$script_dir/qemu_prefix.sh" || exit 1
cd "$script_dir/../.." || exit 1
[[ $# == 2 && "$1" =~ ^[0-9]+$ && "$2" =~ ^[0-9]+$ ]] || exit 2
lo=$1 hi=$2
(( lo >= 17 && hi <= 67 && lo <= hi )) || exit 2
evidence="${KERNEL_EVIDENCE_DIR:-$PWD/_kernel_evidence}"
mkdir -p "$evidence" || exit 1
if [[ -e "$evidence/GIT-HEAD.txt" || -e "$evidence/RESULTS.tsv" ]]; then
    echo "FAIL: evidence directory already contains a run; select a fresh KERNEL_EVIDENCE_DIR" >&2
    exit 1
fi
evidence="$(cd "$evidence" && pwd)" || exit 1
# Attribute captures to the actual checkout, including reviewable local changes.
git rev-parse HEAD > "$evidence/GIT-HEAD.txt" || exit 1
git status --short > "$evidence/GIT-STATUS.txt" || exit 1
git ls-files --others --exclude-standard -z -- bootstrap stack tools | xargs -0 -r sha256sum > "$evidence/UNTRACKED-SHA256.txt" || exit 1
git diff --binary HEAD > "$evidence/WORKTREE.patch" || exit 1
sha256sum bootstrap/seed/gen1.seed stack/native_compile_fragment.herb > "$evidence/COMPILER-SHA256.txt" || exit 1
{
    date -u +%Y-%m-%dT%H:%M:%SZ
    uname -a
    qemu-system-x86_64 --version
    bochs --help 2>&1 || true
    dpkg-query -W qemu-system-x86 bochs 2>&1 || true
} > "$evidence/ENV.txt"
failed=0
for ((link=lo; link<=hi; link++)); do
    for suffix in '' _mutation; do
        [[ $link == 17 && -n $suffix ]] && continue
        gate="run_native_codegen_link${link}${suffix}"
        out="$evidence/$gate"; mkdir -p "$out" || exit 1
        rc=0
        KERNEL_EVIDENCE_DIR="$out" KERNEL_CODEGEN_REQUIRE_EMU=1 KERNEL_CODEGEN_MUTATION=1 \
            timeout -k 60 1500 bash "$script_dir/$gate.sh" > "$out/gate.log" 2>&1 || rc=$?
        printf '%s\n' "$rc" > "$out/STATUS.txt"
        cat "$out/gate.log"
        if [[ $rc != 0 || -f "$out/CAPTURE-ERRORS.txt" ]]; then failed=1; fi
        printf '%s\t%s\n' "$gate" "$rc" >> "$evidence/RESULTS.tsv"
    done
done
exit "$failed"
