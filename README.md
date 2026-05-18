# Herbert

A new programming language, from scratch.

## Layout

    stack/            the Herbert stack: the from-scratch artifact (`.herb`
                      files). Empty for now; will be populated as the language
                      is built.
    tools/            the guard apparatus. Not part of the artifact.
    bootstrap/        the host-language (C) interpreter that runs Herbert
                      until Herbert can host itself. Shrinks toward zero
                      over the project's life.
    bootstrap/tests/  small `.herb` programs that exercise the interpreter,
                      with their expected canonical outputs.
    repo root         Makefile, CI config, BOOTSTRAP-ALLOWLIST, this README.

## The rule

Every git-tracked file whose name does not end in `.herb` must be listed,
by exact repository-relative path, in `BOOTSTRAP-ALLOWLIST` at the
repository root. The set of tracked non-`.herb` files and the set of
listed paths must match exactly, in both directions.

`.herb` files are never listed and never violations. The allowlist makes
the bootstrap boundary — the host-language code that exists only until
Herbert can host itself — visible, so it cannot grow silently.

## Building and running

    make            # builds the interpreter into build/herbert
    make test       # builds and runs the .herb test suite
    make check      # runs the guard
    make clean      # removes build/

`build/herbert <file.herb>` runs a Herbert program. The interpreter
registers all `func` definitions, calls `main()` (which must take zero
parameters), and prints `main`'s return value to standard output in the
canonical form described in `bootstrap/herbert.h`. Errors go to standard
error and exit non-zero.

## Running the guard

    make check

The Makefile writes `git ls-files` to `build/tracked.txt`, builds the
scanner (`tools/scan.c`) into `build/scan`, and runs the scanner with the
list path as its argument. The scanner is plain standard C: it reads the
tracked-files list and `BOOTSTRAP-ALLOWLIST` and compares the two sets.
Exits non-zero on any violation, printing each offending path labelled
`unlisted` (tracked file missing from the allowlist) or `stale`
(allowlist line with no tracked file).

CI runs `make check` and `make test` on every push and pull request.
