#!/usr/bin/env bash
set -euo pipefail

os="$(uname -s)"
arch="$(uname -m)"

case "$os/$arch" in
    Linux/x86_64|Linux/amd64)
        exit 0
        ;;
esac

cat >&2 <<MSG
FAIL: make test requires a Linux/x86_64 host.

The full run mints and executes Linux ELF native-codegen artifacts, and the
aggregate 'make verify-local' depends on this target, so neither runs on this
host ($os/$arch). Portable here: 'make check', 'make test-timeout',
'make lexer-copy-sync'. Run 'make test' / 'make verify-local' in Linux CI or an
equivalent Linux/x86_64 environment (a VM is fine).
MSG
exit 1
