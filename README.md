# Herbert

A new programming language, from scratch.

## Layout

    stack/   the Herbert stack: the from-scratch artifact (`.herb` files).
             Empty for now; will be populated as the language is built.
    tools/   the guard apparatus and build glue. Not part of the artifact.
    repo root  Makefile, CI config, BOOTSTRAP-ALLOWLIST, this README.

## The rule

Every git-tracked file whose name does not end in `.herb` must be listed,
by exact repository-relative path, in `BOOTSTRAP-ALLOWLIST` at the
repository root. The set of tracked non-`.herb` files and the set of
listed paths must match exactly, in both directions.

`.herb` files are never listed and never violations. The allowlist makes
the bootstrap boundary — the host-language code that exists only until
Herbert can host itself — visible, so it cannot grow silently.

## Running the guard

    make check

Builds the scanner (`tools/scan.c`) into `build/scan` and runs it. Exits
non-zero on any violation, printing each offending path labelled
`unlisted` (tracked file missing from the allowlist) or `stale`
(allowlist line with no tracked file).

CI runs `make check` on every push and pull request.
