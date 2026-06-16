# Verifying Herbert

This repo has several verification levels. They are intentionally separate because each one proves a different amount.

## Local Smoke

```bash
make verify-local
```

Runs:

- `make check`: confirms tracked non-`.herb` files exactly match `BOOTSTRAP-ALLOWLIST`.
- `make test-timeout`: checks the repo-local portable `timeout` shim.
- `make smoke`: builds the C bootstrap and runs the `bootstrap/tests/test_*.herb` sample suite, including existing scope/heap sidecar limits.
- `make lexer-equivalence`: normalizes C `lex()` output for the accepted lexer fixture corpus, checks `stack/lexer_probe.expected`, diffs the corpus against `stack/lexer_stdin_driver.herb`, and checks the existing lexer malformed probes against `stack/lexer_error_driver.herb` for ERR code, line, and message parity.
- `make lexer-copy-sync`: checks that accepted-token lexer copies in the stdin driver, parser/evaluator/emitter fragments, and Suke fragments remain synchronized with `stack/lexer_fragment.herb`; it also checks the line-aware Klondike/native lexer variants against the same token contract plus their line field.
- `make native-codegen-diagnostics`: checks the local helper used to enrich Link 38 QEMU mismatch logs.

This is the fast local confidence command. It does not run the full metacircular/native-codegen suite.

## Full Non-Emulator Suite

```bash
make test
```

Runs the main shell harness in `bootstrap/tests/run_tests.sh`.

This target requires a Linux/x86_64 host because the native-codegen links mint and execute Linux ELF artifacts. The Makefile prepends `tools/` to `PATH`, so Linux hosts without GNU `timeout` can still run bounded test legs.

On macOS or non-x86_64 hosts, use `make verify-local` for the portable local ladder and run `make test` in Linux CI or an equivalent Linux/x86_64 environment.

QEMU-emulated x86_64 Linux on Apple Silicon is useful for targeted reproduction,
but it may be too slow for the default full-suite timeouts in deeper
Klondike/metacircular/native-compile legs. Treat CI or real Linux/x86_64
hardware as the authoritative `make test` lane.

This suite exercises the C bootstrap, stack probes, metacircular paths, and native-codegen links covered by the main harness. It is still not the same as the emulator-heavy kernel workflow.

## Beta Full

```bash
make beta-full
```

Runs the dedicated deeper metacircular driver in `bootstrap/tests/run_beta_full.sh`.

## Kernel/Module Gate

The heavy kernel/module proof chain lives in `.github/workflows/kernel-codegen-l1.yml`.

That workflow installs QEMU, Bochs, GRUB, Xvfb, and disk tooling on Linux, then runs the later native-codegen kernel/module links and mutation gates with `KERNEL_CODEGEN_REQUIRE_EMU=1`.

Local runs can silently shrink if emulator prerequisites are absent. Treat the workflow as the authoritative gate for those links.

## What These Commands Do Not Prove

- They do not prove arbitrary-program compiler correctness.
- They do not prove a finished OS.
- They do not remove the C bootstrap.
- They do not make old archived docs current.

They prove the specific executable surfaces each command invokes.
