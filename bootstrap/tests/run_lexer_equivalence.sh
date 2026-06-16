#!/usr/bin/env bash
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"

cc="${CC:-cc}"
cflags="${CFLAGS:--std=c11 -Wall -Wextra -Wpedantic -O2}"
src="$repo_root/stack/lexer_probe.herb"
expected="$repo_root/stack/lexer_probe.expected"
driver="$repo_root/stack/lexer_stdin_driver.herb"
dumper_src="$script_dir/lexer_equiv_dump.c"
HERBERT="${HERBERT:-$repo_root/build/herbert}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

dump="$tmp/lexer_equiv_dump"
actual="$tmp/c-lexer-normalized.out"
herbert_actual="$tmp/herbert-lexer-normalized.out"

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

echo "PASS: lexer equivalence (${#fixtures[@]} accepted fixture(s) match C lex() and Herbert lexer)"
