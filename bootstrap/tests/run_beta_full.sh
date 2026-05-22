#!/usr/bin/env bash
# Witnessed beta-full triple-nest runner. This is intentionally not part of
# make test; it runs the 100 KB in-VM compile path and usually takes minutes.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HERBERT="${HERBERT:-$REPO_ROOT/build/herbert}"
KLONDIKE="$REPO_ROOT/stack/klondike.herb"
R_PROBE="${BETA_FULL_R:-$REPO_ROOT/stack/metacircular_compute_probe.herb}"
R_INPUT_TEXT="${BETA_FULL_INPUT:-5}"
TIMEOUT_LIMIT="${BETA_FULL_TIMEOUT:-45m}"
VMEM_KB="${BETA_FULL_VMEM_KB:-8388608}"
# cudder: the compute-probe witness runs doubly-interpreted at L2, so its peak
# heap (478,370,817 B, measured identically by the build worker and the conductor)
# is higher than a trivial witness; cap = real peak + ~25% headroom. A regression
# of gulpin reclamation / hoopty TCO at this scale blows past this into GB/OOM.
HEAP_CAP="${BETA_FULL_HEAP_CAP:-600000000}"
SCOPE_CAP="${BETA_FULL_SCOPE_CAP:-64}"
AUDIT_DIR="${BETA_AUDIT_DIR:-$REPO_ROOT/../audits/beta-full}"
RUN_LOG="$AUDIT_DIR/RUN-LOG.md"

fail() {
    echo "FAIL: beta-full: $*" >&2
    exit 1
}

bytes_of() {
    wc -c <"$1" | tr -d '[:space:]'
}

sha_of() {
    sha256sum "$1" | awk '{print $1}'
}

write_herbert_bundle() {
    local src="$1"
    local input="$2"
    local out="$3"
    python3 - "$src" "$input" "$out" <<'PY'
import sys

src = open(sys.argv[1], "rb").read()
inp = open(sys.argv[2], "rb").read()
with open(sys.argv[3], "wb") as out:
    out.write(b"\x00HERB1" + str(len(src)).encode() + b"\n" + src + inp)
PY
}

decode_canonical_string() {
    local input="$1"
    perl -0777 -ne '
        my $s = $_;
        $s =~ s/\n\z//;
        exit 1 unless $s =~ /\A"(.*)"\z/s;
        $s = $1;
        $s =~ s/\\([n\\"])/$1 eq "n" ? "\n" : $1/ge;
        print $s;
    ' "$input"
}

normalize_klondike_driver_output() {
    local input="$1"
    local output="$2"
    local prefix quoted decoded
    prefix=$(mktemp)
    quoted=$(mktemp)
    decoded=$(mktemp)

    sed '$d' "$input" >"$prefix"
    tail -n 1 "$input" >"$quoted"
    if ! decode_canonical_string "$quoted" >"$decoded"; then
        rm -f "$prefix" "$quoted" "$decoded"
        return 1
    fi
    cat "$prefix" "$decoded" >"$output"
    printf '\n' >>"$output"
    rm -f "$prefix" "$quoted" "$decoded"
    return 0
}

metric_value() {
    local pattern="$1"
    local file="$2"
    awk -v pat="$pattern" '$0 ~ pat {v=$NF} END {print v}' "$file"
}

time_value() {
    local key="$1"
    local file="$2"
    sed -n "s/^[[:space:]]*$key:[[:space:]]*//p" "$file" | tail -n 1
}

elapsed_value() {
    local file="$1"
    sed -n 's/^[[:space:]]*Elapsed (wall clock) time (h:mm:ss or m:ss):[[:space:]]*//p' "$file" | tail -n 1
}

command -v timeout >/dev/null 2>&1 || fail "timeout(1) is required"
[[ -x /usr/bin/time ]] || fail "/usr/bin/time is required"
[[ -x "$HERBERT" ]] || fail "cannot find executable herbert at $HERBERT"
[[ -f "$KLONDIKE" ]] || fail "cannot find $KLONDIKE"
[[ -f "$R_PROBE" ]] || fail "cannot find $R_PROBE"

mkdir -p "$AUDIT_DIR" || fail "cannot create $AUDIT_DIR"

tmpdir=$(mktemp -d)
cleanup() {
    rm -rf "$tmpdir"
}
trap cleanup EXIT

input="$tmpdir/R.input"
innermost="$tmpdir/innermost.bundle"
middle="$tmpdir/middle.bundle"
outer="$tmpdir/outer.bundle"
reference_stdout="$tmpdir/reference.stdout"
reference_stderr="$tmpdir/reference.stderr"
reference_norm="$tmpdir/reference.normalized"
candidate_stdout="$tmpdir/candidate.stdout"
candidate_stderr="$tmpdir/candidate.stderr"
candidate_norm="$tmpdir/candidate.normalized"
diff_file="$tmpdir/normalized.diff"

printf '%s' "$R_INPUT_TEXT" >"$input"

env HERBERT_REPORT_PEAK=1 HERBERT_REPORT_HEAP=1 "$HERBERT" "$R_PROBE" <"$input" >"$reference_stdout" 2>"$reference_stderr"
reference_rc=$?
if [[ $reference_rc -ne 0 ]]; then
    echo "--- reference stderr" >&2
    cat "$reference_stderr" >&2
    echo "--- reference stdout" >&2
    cat "$reference_stdout" >&2
    fail "reference exited $reference_rc"
fi
tr -d ',' <"$reference_stdout" >"$reference_norm"

write_herbert_bundle "$R_PROBE" "$input" "$innermost" || fail "failed to build innermost bundle"
write_herbert_bundle "$KLONDIKE" "$innermost" "$middle" || fail "failed to build middle bundle"
write_herbert_bundle "$KLONDIKE" "$middle" "$outer" || fail "failed to build outer bundle"

start_epoch=$(date +%s)
timeout "$TIMEOUT_LIMIT" bash -c '
    vmem="$1"
    shift
    ulimit -v "$vmem"
    exec env HERBERT_REPORT_PEAK=1 HERBERT_REPORT_HEAP=1 /usr/bin/time -v "$@"
' beta-full "$VMEM_KB" "$HERBERT" "$KLONDIKE" <"$outer" >"$candidate_stdout" 2>"$candidate_stderr"
candidate_rc=$?
end_epoch=$(date +%s)
external_wall_s=$((end_epoch - start_epoch))

if [[ $candidate_rc -eq 124 ]]; then
    fail "candidate exceeded timeout $TIMEOUT_LIMIT"
elif [[ $candidate_rc -ne 0 ]]; then
    echo "--- candidate stderr" >&2
    cat "$candidate_stderr" >&2
    echo "--- candidate stdout" >&2
    cat "$candidate_stdout" >&2
    fail "candidate exited $candidate_rc"
fi

if ! normalize_klondike_driver_output "$candidate_stdout" "$candidate_norm"; then
    echo "--- candidate stdout" >&2
    cat "$candidate_stdout" >&2
    fail "candidate did not end in a canonical string result"
fi

if ! cmp -s "$reference_norm" "$candidate_norm"; then
    diff -u "$reference_norm" "$candidate_norm" >"$diff_file" || true
    cat "$diff_file" >&2
    fail "normalized stdout mismatch"
fi

peak_heap=$(metric_value '^peak-heap-bytes: [0-9]+$' "$candidate_stderr")
peak_scopes=$(metric_value '^peak-live-scopes: [0-9]+$' "$candidate_stderr")
[[ -n "$peak_heap" ]] || fail "candidate did not report peak-heap-bytes"
[[ -n "$peak_scopes" ]] || fail "candidate did not report peak-live-scopes"

gate_result="PASS"
gate_failure=
if (( peak_heap > HEAP_CAP )); then
    gate_result="FAIL"
    gate_failure="peak-heap-bytes $peak_heap > $HEAP_CAP"
elif (( peak_scopes > SCOPE_CAP )); then
    gate_result="FAIL"
    gate_failure="peak-live-scopes $peak_scopes > $SCOPE_CAP"
fi
if grep -Eiq 'out of memory|cannot allocate memory|command terminated by signal 9' "$candidate_stderr"; then
    gate_result="FAIL"
    gate_failure="${gate_failure:-candidate stderr indicates OOM or signal-9 termination}"
fi

commit=$(git -C "$REPO_ROOT" rev-parse HEAD)
status_short=$(git -C "$REPO_ROOT" status --short)
if [[ -z "$status_short" ]]; then
    clean_status="clean"
else
    clean_status="dirty"
fi
host="$(hostname)"
uname_text="$(uname -a)"
timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
wall_time="$(elapsed_value "$candidate_stderr")"
user_time="$(time_value 'User time (seconds)' "$candidate_stderr")"
system_time="$(time_value 'System time (seconds)' "$candidate_stderr")"
cpu_percent="$(time_value 'Percent of CPU this job got' "$candidate_stderr")"
max_rss="$(time_value 'Maximum resident set size (kbytes)' "$candidate_stderr")"

{
    printf '\n## %s - beta-full witness\n\n' "$timestamp"
    printf -- '- commit: `%s`\n' "$commit"
    printf -- '- clean-tree status: `%s`\n' "$clean_status"
    if [[ -n "$status_short" ]]; then
        printf -- '- status entries:\n'
        printf '```text\n%s\n```\n' "$status_short"
    fi
    printf -- '- R: `%s`\n' "${R_PROBE#$REPO_ROOT/}"
    printf -- '- input: `%s`\n' "$R_INPUT_TEXT"
    printf -- '- klondike.herb: %s bytes, sha256 `%s`\n' "$(bytes_of "$KLONDIKE")" "$(sha_of "$KLONDIKE")"
    printf -- '- R bytes/sha256: %s bytes, `%s`\n' "$(bytes_of "$R_PROBE")" "$(sha_of "$R_PROBE")"
    printf -- '- input bytes/sha256: %s bytes, `%s`\n' "$(bytes_of "$input")" "$(sha_of "$input")"
    printf -- '- normalized stdout bytes/sha256: %s bytes, `%s`\n' "$(bytes_of "$reference_norm")" "$(sha_of "$reference_norm")"
    printf -- '- normalized diff result: byte-identical\n'
    printf -- '- gate result: `%s`\n' "$gate_result"
    if [[ -n "$gate_failure" ]]; then
        printf -- '- gate failure: `%s`\n' "$gate_failure"
    fi
    printf -- '- wall: `%s` (/usr/bin/time), %ss external\n' "$wall_time" "$external_wall_s"
    printf -- '- CPU: user `%s`, system `%s`, `%s`\n' "$user_time" "$system_time" "$cpu_percent"
    printf -- '- max RSS: %s kbytes\n' "$max_rss"
    printf -- '- peak-heap-bytes: %s\n' "$peak_heap"
    printf -- '- peak-live-scopes: %s\n' "$peak_scopes"
    printf -- '- host: `%s`; `%s`\n' "$host" "$uname_text"
    printf -- '- witness: beta-full build worker\n'
    printf '\nNormalized stdout:\n\n```text\n'
    cat "$reference_norm"
    printf '```\n'
} >>"$RUN_LOG"

if [[ "$gate_result" != "PASS" ]]; then
    fail "$gate_failure"
fi

echo "PASS: beta-full witness (wall $wall_time, peak-heap-bytes $peak_heap, peak-live-scopes $peak_scopes, max RSS ${max_rss}KB)"
echo "RUN-LOG: $RUN_LOG"
