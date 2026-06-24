# Verifying Herbert

This repo has several verification levels. They are intentionally separate because each one proves a different amount.

## Local Smoke

```bash
make verify-local
```

Runs:

- `make check`: confirms tracked non-`.herb` files exactly match `BOOTSTRAP-ALLOWLIST` (the from-scratch boundary scanner `tools/scan.c` — kept governance meta-tooling, not the retired interpreter).
- `make test-timeout`: checks the repo-local portable `timeout` shim.
- `make lexer-copy-sync`: checks that accepted-token lexer copies in the stdin/parser/evaluator/emitter and Suke fragments stay synchronized with `stack/lexer_fragment.herb` (the line-aware token contract).
- `make native-codegen-diagnostics`: checks the local helper used to enrich kernel QEMU mismatch logs.

This is the portable local confidence command. It does not run x86_64 Linux ELF
artifacts, the full non-emulator suite, or the emulator-heavy kernel suite.

## Full Linux Local Ladder

```bash
make verify-linux
```

Runs the portable local smoke checks plus:

- `make test`: the full non-emulator harness (see below).
- `make evaluator-native` / `vm-native` / `parser-native` / `lexer-native` / `klondike-native` / `emitter-native`: the six metacircular fragments compiled to ELF by the committed gen-1 seed and run with **no C**, each diffed against its independently-authored oracle, plus a RED-first mutation proof.
- `make error-vocab-native`: the C-free re-gating of klondike.herb's located **front-end error vocabulary** (ERR 101–316) — the gen-1 seed compiles klondike (a 1-line `main` adapter; `klondike.herb` byte-identical) and feeds it the 54 malformed `error_probes` fixtures; each must emit the hand-authored manifest's ERR code (independent anchor) **and** the committed golden diagnostic (regression pin), with gate-time metamorphic checks (line-shift + payload-rename at five extraction sites) proving the diagnostic tracks the input, plus a RED-first mutation proof. Restores the assurance `castoff` spent when it deleted the C-driven `error_probes` differential (`klaxon`, sovereignty link 19). Distinct from the native-codegen seed's own subset vocabulary (ERR 4xx/5xx), which the native-codegen reject battery gates.
- `make switchover-cfree`: proves the C-free production surface stands with the C interpreter PHYSICALLY ABSENT, then proves it bites RED-first.
- `make switchover-dry-run`: proves the C-free bite-proofs still bite with the C interpreter physically absent.

This target requires a Linux/x86_64 host because the committed seed and native
outputs are x86_64 Linux ELF binaries.

## Full Non-Emulator Suite

```bash
make test
```

Runs the main shell harness in `bootstrap/tests/run_tests.sh`.

This target requires a Linux/x86_64 host because the native-codegen links mint and execute Linux ELF artifacts. The Makefile prepends `tools/` to `PATH`, so Linux hosts without GNU `timeout` can still run bounded test legs.

On macOS or non-x86_64 hosts, use `make verify-local` for the portable local ladder and run `make test` or `make verify-linux` in Linux CI or an equivalent Linux/x86_64 environment.

QEMU-emulated x86_64 Linux on Apple Silicon is useful for targeted reproduction,
but it may be too slow for the default full-suite timeouts in deeper
Klondike/metacircular/native-compile legs. Treat CI or real Linux/x86_64
hardware as the authoritative `make test` lane.

This suite exercises the native gen-1 toolchain, the stack fragments run natively, the metacircular native-execution gates, and the native-codegen links — all **C-free** (the C bootstrap interpreter was retired at the switchover). It is still not the same as the emulator-heavy kernel workflow.

## Kernel/Module Gate

The heavy kernel/module proof chain lives in `.github/workflows/kernel-codegen-l1.yml`.

That workflow installs QEMU, Bochs, GRUB, Xvfb, and disk tooling on Linux, then runs the later native-codegen kernel/module links and mutation gates with `KERNEL_CODEGEN_REQUIRE_EMU=1`.

Local runs can silently shrink if emulator prerequisites are absent. Treat the workflow as the authoritative gate for those links.

## What These Commands Do Not Prove

- They do not prove arbitrary-program compiler correctness.
- They do not prove a finished OS.
- They do not, on their own, re-establish the trusting-trust provenance of the committed seed (the C bootstrap interpreter has been removed at the switchover; the seed remains C-minted once, and the textual-seed hardening is the remaining deferred sovereignty residue).
- They do not make old archived docs current.

They prove the specific executable surfaces each command invokes.
