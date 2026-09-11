# Verifying Herbert

This repo has several verification levels. They are intentionally separate because each one proves a different amount.

## Local Smoke

```bash
make verify-local
```

Runs:

- `make check`: confirms tracked non-`.herb` files exactly match `BOOTSTRAP-ALLOWLIST` (the from-scratch boundary scanner `tools/scan.c` — kept governance meta-tooling, not the retired interpreter).
- `make verification-helpers`: checks exact native transcripts, emulator selection, raw capture retention, and complete CI matrix coverage.
- `make test-timeout`: checks the repo-local portable `timeout` shim.
- `make test`: the full non-emulator harness (see below).
- `make evaluator-native` / `vm-native` / `parser-native` / `lexer-native` / `klondike-native` / `emitter-native`: the six metacircular fragments compiled to ELF by the committed gen-1 seed and run with **no C**, each diffed against its independently-authored oracle, plus a RED-first mutation proof.
- `make error-vocab-native`: the C-free re-gating of klondike.herb's located **front-end error vocabulary** (ERR 101–316) — the gen-1 seed compiles klondike (a 1-line `main` adapter; `klondike.herb` byte-identical) and feeds it the 54 malformed `error_probes` fixtures; each must emit the hand-authored manifest's ERR code (independent anchor) **and** the committed golden diagnostic (regression pin), with gate-time metamorphic checks (line-shift + payload-rename at five extraction sites) proving the diagnostic tracks the input, plus a RED-first mutation proof. Restores the assurance `castoff` spent when it deleted the C-driven `error_probes` differential (`klaxon`, sovereignty link 19). Distinct from the native-codegen seed's own subset vocabulary (ERR 4xx/5xx), which the native-codegen reject battery gates.
- `make lexer-copy-sync`: checks that accepted-token lexer copies in the stdin/parser/evaluator/emitter and Suke fragments stay synchronized with `stack/lexer_fragment.herb` (the line-aware token contract).
- `make native-codegen-diagnostics`: checks the local helper used to enrich kernel QEMU mismatch logs.
- `make switchover-cfree`: proves the C-free production surface stands with the C interpreter PHYSICALLY ABSENT, then proves it bites RED-first.

This is the fast local confidence command. It does not run the full emulator-heavy kernel suite.

## Full Non-Emulator Suite

```bash
make test
```

Runs the main shell harness in `bootstrap/tests/run_tests.sh`.

It also runs `bootstrap/tests/compiler_conformance.py`: independently declared
ordinary hosted inputs with exact compiler status/streams/artifact checks, then
exact generated-program output/status checks for accepted cases. The explicit
`run-stdio` profile additionally checks runtime stderr; the legacy `run` profile
still requires it empty. Source rejection retains the old compiler envelope.
These cases do not replace syscall fault-injection or full target verification.

This target requires a Linux/x86_64 host because the native-codegen links mint and execute Linux ELF artifacts. The Makefile prepends `tools/` to `PATH`, so Linux hosts without GNU `timeout` can still run bounded test legs.

On macOS or non-x86_64 hosts the aggregate `make verify-local` is NOT runnable: it depends on `make test` (which refuses such hosts) and on the native rungs, which mint and execute Linux/x86_64 ELF artifacts. The individually portable checks are `make check`, `make test-timeout`, and `make lexer-copy-sync`; run everything else in Linux CI or an equivalent Linux/x86_64 environment (a VM is fine).

QEMU-emulated x86_64 Linux on Apple Silicon is useful for targeted reproduction,
but it may be too slow for the default full-suite timeouts in deeper
Klondike/metacircular/native-compile legs. Treat CI or real Linux/x86_64
hardware as the authoritative `make test` lane.

This suite exercises the native gen-1 toolchain, the stack fragments run natively, the metacircular native-execution gates, and the native-codegen links — all **C-free** (the C bootstrap interpreter was retired at the switchover). It is still not the same as the emulator-heavy kernel workflow.

## Kernel/Module Gate

The heavy kernel/module proof chain lives in `.github/workflows/kernel-codegen-l1.yml`.

That workflow installs QEMU, Bochs, GRUB, Xvfb, and disk tooling on Linux, then runs the later native-codegen kernel/module links and mutation gates with `KERNEL_CODEGEN_REQUIRE_EMU=1`.

Local runs can silently shrink if emulator prerequisites are absent. Treat the workflow as the authoritative gate for those links.

For the pinned local QEMU, set `QEMU_PREFIX=/opt/qemu-10.2.1` before a
standalone gate or `make kernel-verify`. The prefix must be absolute and contain
an executable regular file at `bin/qemu-system-x86_64`. The shared test helper
`bootstrap/tests/qemu_prefix.sh` removes function shadows and checks that command
lookup resolves to that exact path. Every caller fails closed if its helper or
oracle cannot be sourced, before testing emulator availability. The helper is
an explicit test-tooling allowlist addition; emitted Herbert programs gain no
runtime dependency. A wrapper must use `exec` to preserve signal status.

CI divides links 17..66 into independently scheduled groups. Each group runs
all its gates and mutation proofs even after a failure, records every exit
status, and remains red if any gate fails. Each gate has a 25-minute limit
with a 60-second termination grace period. Existing emulator package pins and
explicit Bochs probe sets remain in force. A diagnostics failure does not
suppress these groups once emulator installation and pin checks succeed.

`bootstrap/tests/kernel_ci_group.sh LO HI` runs the same grouped driver locally.
It writes `_kernel_evidence/` by default; `KERNEL_EVIDENCE_DIR` selects another
absolute output directory. Gate cleanup captures the actual attempts before
deleting temporary files: raw output, feeder logs, configuration, hash/size
inventories with UTC attempt times, gate logs/status, emulator versions,
source/seed hashes, and checkout revision/diff.
Large disk images and executable artifacts are inventoried by hash rather than
uploaded. A failed capture preserves its source directory and makes the group
fail immediately, including standalone evidence-enabled gates and EXIT traps.
An existing nonzero gate status is preserved. Evidence from a failed attempt is not substituted with a subsequent boot.
Without `KERNEL_EVIDENCE_DIR`, ordinary standalone cleanup keeps its prior behavior.

The local Bochs is 2.7 while CI pins 2.8. Local emulator results remain distinct
from the CI substrate. F2-hardened gates classify harness failures (such as disk
setup or feeder failures) separately from completed kernel results.

## What These Commands Do Not Prove

- They do not prove arbitrary-program compiler correctness.
- They do not prove a finished OS.
- They do not, on their own, re-establish the trusting-trust provenance of the committed seed (the C bootstrap interpreter has been removed at the switchover; the seed remains C-minted once, and the textual-seed hardening is the remaining deferred sovereignty residue).
- They do not make old archived docs current.

They prove the specific executable surfaces each command invokes.
