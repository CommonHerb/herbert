#!/usr/bin/env bash
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"

cc="${CC:-cc}"
cflags="${CFLAGS:--std=c11 -Wall -Wextra -Wpedantic -O2}"
src="$repo_root/stack/lexer_probe.herb"
expected="$repo_root/stack/lexer_probe.expected"
driver="$repo_root/stack/lexer_stdin_driver.herb"
error_driver="$repo_root/stack/lexer_error_driver.herb"
error_manifest="$repo_root/stack/error_probes.expected"
error_probe_dir="$repo_root/stack/error_probes"
dumper_src="$script_dir/lexer_equiv_dump.c"
HERBERT="${HERBERT:-$repo_root/build/herbert}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

dump="$tmp/lexer_equiv_dump"
actual="$tmp/c-lexer-normalized.out"
herbert_actual="$tmp/herbert-lexer-normalized.out"
c_actual="$tmp/c-bootstrap.out"
c_err="$tmp/c-bootstrap.err"
expected_error="$tmp/lexer-error.expected"

if ! $cc $cflags -I"$repo_root/bootstrap" \
        -o "$dump" \
        "$dumper_src" "$repo_root/bootstrap/lex.c" "$repo_root/bootstrap/util.c"; then
    echo "FAIL: lexer equivalence (could not build C lexer normalizer)"
    exit 1
fi

if ! "$dump" "$src" >"$actual"; then
    echo "FAIL: lexer equivalence (C lexer normalizer exited nonzero)"
    exit 1
fi

if ! diff -u "$expected" "$actual"; then
    echo "FAIL: lexer equivalence (normalized C lexer tokens differ from Herbert lexer oracle)"
    exit 1
fi

if [[ ! -x "$HERBERT" ]]; then
    echo "FAIL: lexer equivalence (cannot execute HERBERT=$HERBERT)"
    exit 1
fi
if [[ ! -f "$driver" ]]; then
    echo "FAIL: lexer equivalence (missing stdin driver: $driver)"
    exit 1
fi

fixtures=(
    "$repo_root/stack/lexer_probe.herb"
    "$repo_root/stack/lexer_fixtures/ops_and_types.herb"
    "$repo_root/stack/lexer_fixtures/native_operator_surface.herb"
    "$repo_root/stack/lexer_fixtures/comments_and_literals.herb"
)

for fixture in "${fixtures[@]}"; do
    label="${fixture#$repo_root/}"
    if [[ ! -f "$fixture" ]]; then
        echo "FAIL: lexer equivalence (missing fixture: $label)"
        exit 1
    fi
    if ! "$dump" "$fixture" >"$actual"; then
        echo "FAIL: lexer equivalence ($label C normalizer exited nonzero)"
        exit 1
    fi
    if ! "$HERBERT" "$driver" <"$fixture" >"$herbert_actual"; then
        echo "FAIL: lexer equivalence ($label Herbert stdin driver exited nonzero)"
        exit 1
    fi
    if ! diff -u "$actual" "$herbert_actual"; then
        echo "FAIL: lexer equivalence ($label C tokens differ from Herbert stdin driver)"
        exit 1
    fi
done

if [[ ! -f "$error_driver" ]]; then
    echo "FAIL: lexer equivalence (missing error driver: $error_driver)"
    exit 1
fi
if [[ ! -f "$error_manifest" || ! -d "$error_probe_dir" ]]; then
    echo "FAIL: lexer equivalence (missing error probe manifest or directory)"
    exit 1
fi

error_count=0
while read -r probe_name err_word err_code; do
    [[ -n "$probe_name" ]] || continue
    case "$probe_name" in
        lex_*) ;;
        *) continue ;;
    esac
    probe="$error_probe_dir/$probe_name.herb"
    label="${probe#$repo_root/}"
    if [[ ! -f "$probe" ]]; then
        echo "FAIL: lexer equivalence (missing error probe: $label)"
        exit 1
    fi
    if "$HERBERT" "$probe" >"$c_actual" 2>"$c_err"; then
        echo "FAIL: lexer equivalence ($label C bootstrap accepted malformed lexer probe)"
        exit 1
    fi
    python3 - "$err_code" "$c_err" >"$expected_error" <<'PY'
import json
import re
import sys

code = sys.argv[1]
err_path = sys.argv[2]
text = open(err_path, encoding="utf-8").read().strip()
match = re.fullmatch(r"herbert: line ([0-9]+): (.*)", text)
if not match:
    raise SystemExit(f"cannot normalize C lexer diagnostic: {text!r}")
line, msg = match.groups()
print(f"({code}, {line}, {json.dumps(msg)})")
PY
    if ! "$HERBERT" "$error_driver" <"$probe" >"$herbert_actual"; then
        echo "FAIL: lexer equivalence ($label Herbert error driver exited nonzero)"
        exit 1
    fi
    if ! diff -u "$expected_error" "$herbert_actual"; then
        echo "FAIL: lexer equivalence ($label lexer diagnostic differs from C bootstrap)"
        exit 1
    fi
    error_count=$((error_count + 1))
done < "$error_manifest"

if [[ "$error_count" -eq 0 ]]; then
    echo "FAIL: lexer equivalence (no lexer error probes found in $error_manifest)"
    exit 1
fi

echo "PASS: lexer equivalence (${#fixtures[@]} accepted fixture(s), $error_count lexer error fixture(s) match C lex() and Herbert lexer)"
