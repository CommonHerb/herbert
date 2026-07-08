#!/usr/bin/env bash
# Closed-Loop compiler memory diet gate.
#
# Runs the committed gen-1 seed as the production compiler appliance in a tempdir:
#   1. full self-compile: gen1.seed < stack/native_compile_fragment.herb
#   2. front-end attribution cone: same source under the AST-dump emit marker
#
# The full leg is a real gate: exit 0, emitted a.out byte-identical to the
# committed seed, and max RSS below CLOSED_LOOP_MAX_RSS_KB.
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
seed="$repo_root/bootstrap/seed/gen1.seed"
backend="$repo_root/stack/native_compile_fragment.herb"
time_bin="${TIME_BIN:-/usr/bin/time}"
max_rss_kb="${CLOSED_LOOP_MAX_RSS_KB:-1200000}"

[[ -f "$seed" ]] || { echo "FAIL: closed-loop-memory-diet (missing seed $seed)"; exit 1; }
[[ -f "$backend" ]] || { echo "FAIL: closed-loop-memory-diet (missing backend $backend)"; exit 1; }
[[ -x "$time_bin" ]] || { echo "FAIL: closed-loop-memory-diet ($time_bin missing or not executable)"; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

kib_to_mib() {
    awk -v kb="$1" 'BEGIN { printf "%.1f", kb / 1024 }'
}

run_profile() {
    local label="$1" input="$2" outdir="$3"
    mkdir -p "$outdir"
    cp "$seed" "$outdir/seedbin"
    chmod +x "$outdir/seedbin"

    set +e
    ( cd "$outdir" && "$time_bin" -v ./seedbin < "$input" > stdout.txt 2> time.txt )
    local rc=$?
    set -e

    local rss elapsed
    rss="$(awk -F: '/Maximum resident set size/ {gsub(/^[ \t]+/, "", $2); print $2}' "$outdir/time.txt")"
    elapsed="$(awk '/Elapsed \(wall clock\) time/ {sub(/^.*\): /, ""); print; exit}' "$outdir/time.txt")"
    rss="${rss:-0}"
    elapsed="${elapsed:-unknown}"
    printf '%s_rc=%s\n%s_rss_kb=%s\n%s_elapsed=%s\n' "$label" "$rc" "$label" "$rss" "$label" "$elapsed" > "$outdir/profile.env"
}

ast_source="$tmp/ast-dump-source.herb"
{
    printf '%s\n' '-- emit: ast-dump'
    cat "$backend"
} > "$ast_source"

full_dir="$tmp/full"
ast_dir="$tmp/ast"
run_profile full "$backend" "$full_dir"
run_profile ast "$ast_source" "$ast_dir"

# shellcheck disable=SC1091
. "$full_dir/profile.env"
# shellcheck disable=SC1091
. "$ast_dir/profile.env"

stdout="$(tr -d '\r' < "$full_dir/stdout.txt" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
out_bytes=0
if [[ -f "$full_dir/a.out" ]]; then
    out_bytes="$(wc -c < "$full_dir/a.out" | tr -d ' ')"
fi
seed_bytes="$(wc -c < "$seed" | tr -d ' ')"
attrib_rest=$((full_rss_kb - ast_rss_kb))
if [[ "$attrib_rest" -lt 0 ]]; then
    attrib_rest=0
fi

echo "Closed Loop memory diet gate:"
echo "  full self-compile: rc=$full_rc rss=${full_rss_kb} kB ($(kib_to_mib "$full_rss_kb") MiB) elapsed=$full_elapsed stdout=${stdout:-<empty>}"
echo "  output: a.out bytes=$out_bytes seed bytes=$seed_bytes"
echo "  attribution: ast-dump front-end cone=${ast_rss_kb} kB ($(kib_to_mib "$ast_rss_kb") MiB)"
echo "  attribution: post-front-end/lower+emit cone<=${attrib_rest} kB ($(kib_to_mib "$attrib_rest") MiB)"
echo "  ceiling: CLOSED_LOOP_MAX_RSS_KB=$max_rss_kb ($(kib_to_mib "$max_rss_kb") MiB)"

fail=0
if [[ "$full_rc" -ne 0 ]]; then
    echo "FAIL: closed-loop-memory-diet (full self-compile rc=$full_rc)"
    fail=1
fi
if [[ "$ast_rc" -ne 0 ]]; then
    echo "FAIL: closed-loop-memory-diet (ast attribution rc=$ast_rc)"
    fail=1
fi
if [[ ! -f "$full_dir/a.out" ]]; then
    echo "FAIL: closed-loop-memory-diet (full self-compile emitted no a.out)"
    fail=1
elif ! cmp -s "$full_dir/a.out" "$seed"; then
    echo "FAIL: closed-loop-memory-diet (gen-2 differs from committed gen-1 seed)"
    fail=1
fi
if [[ "$full_rss_kb" -gt "$max_rss_kb" ]]; then
    echo "FAIL: closed-loop-memory-diet (rss ${full_rss_kb} kB > ceiling ${max_rss_kb} kB)"
    fail=1
fi

if [[ "$fail" -ne 0 ]]; then
    exit 1
fi

echo "PASS: closed-loop-memory-diet (byte-identical gen-2 under bounded RSS ceiling, attribution printed)"
