#!/usr/bin/env bash
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"

cc="${CC:-cc}"
cflags="${CFLAGS:--std=c11 -Wall -Wextra -Wpedantic -O2}"
src="$repo_root/stack/lexer_probe.herb"
expected="$repo_root/stack/lexer_probe.expected"
dumper_src="$script_dir/lexer_equiv_dump.c"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

dump="$tmp/lexer_equiv_dump"
actual="$tmp/c-lexer-normalized.out"

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

echo "PASS: lexer equivalence (C lex() normalized to stack/lexer_probe.expected)"
