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

The full run mints and executes Linux ELF native-codegen artifacts. On this
host ($os/$arch), use 'make verify-local' for the portable local ladder and run
'make test' in Linux CI or an equivalent Linux/x86_64 environment.
MSG
exit 1
