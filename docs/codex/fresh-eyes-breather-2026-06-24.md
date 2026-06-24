# Fresh-Eyes Breather - 2026-06-24

Branch: `codex/fresh-eyes-breather-20260624`
Base branch inspected: `codex/sovereignty-audit-20260624`
Base SHA inspected: `e192db7b34e1f3a8f0023176a16b89c67a77409e`
Existing audit PR inspected: `https://github.com/CommonHerb/herbert/pull/3`

This note is intentionally a breather, not another mainline feature push. It is
for future Herbert workers who need the shape of the repo held in their head
before they add more proof links or more prose.

## What Herbert Actually Is

Herbert is a serious experimental language/runtime stack. In this checkout, the
C interpreter is retired. The active production path is the committed x86_64
Linux `bootstrap/seed/gen1.seed`, Herbert source in `stack/`, committed goldens,
shell/Python harnesses, Linux ELF execution, and the QEMU/Bochs kernel workflow.

Do not flatten it into "just scripts" or "just a C project." Also do not round
it up into a finished self-hosted OS. It is a proof-driven bootstrapping stack
with a native compiler seed and a long kernel/module frontier.

## What Is Actually Proven

- `make verify-local` is now the portable local source/governance ladder. On
  this Darwin/arm64 host it passed at `e192db7`.
- `make verify-linux` is the full Linux/x86_64 non-emulator ladder. It is not
  proven by this Mac run.
- PR #3 was green at `e192db7`: push `check`, PR `check`, and PR
  `kernel-codegen-l1` all completed successfully.
- The C interpreter is gone from the source tree; the remaining tracked C file
  is `tools/scan.c`, the allowlist governance scanner.
- The kernel/module frontier is wired through Link 52, with the authoritative
  public gate in `.github/workflows/kernel-codegen-l1.yml`.

## What Is Still Trust Root Or Aspirational

- `bootstrap/seed/gen1.seed` remains once-C-minted. The textual seed /
  trusting-trust hardening is still deferred.
- Committed goldens, Python references, shell harnesses, QEMU, Bochs, GRUB, disk
  tooling, and Linux/x86_64 execution are still named trust surfaces.
- A green normal `check` workflow is not the whole kernel truth. The long
  `kernel-codegen-l1` workflow is the stronger public kernel/module evidence.
- The kernel links are proof-mode frontier work, not a finished general OS, a
  general ELF loader, arbitrary-program compiler correctness, or SMP-safe TLB
  machinery.
- KVM must be described as conditional on `/dev/kvm` actually being available in
  that run. QEMU plus Bochs are the public dual-substrate lane in CI.

## What Not To Accidentally Revive

- Do not revive C as a live oracle for the interpreter, parser, lexer, or
  evaluator. Post-switchover replacement proof should be executable and C-free.
- Do not claim Linux/x86_64 native truth from a Darwin/arm64 local run.
- Do not treat QEMU-emulated Apple Silicon experiments as the same thing as the
  GitHub Linux/x86_64 lane.
- Do not convert historical switchover prose back into pending-plan language.
- Do not let "silicon" or KVM wording imply proof that a run skipped.

## Small Repair In This Branch

The existing audit branch had already repaired the major truth surfaces. This
fresh-eyes pass found one narrow consistency gap in the next-step area named by
`docs/codex/status-2026-06-24.md`: latest mutation scripts `link49` through
`link52` skipped missing QEMU even when `KERNEL_CODEGEN_REQUIRE_EMU=1`.

This branch changes those four mutation scripts so a missing QEMU is a hard
failure under `KERNEL_CODEGEN_REQUIRE_EMU=1`, matching the nearby `link47` and
`link48` behavior. With the flag unset, local non-emulator machines can still
skip those QEMU-only mutation proofs honestly.

## Highest-Leverage Safe Moves

1. Add a small scanner or check target that enforces the fail-closed emulator
   convention across all kernel mutation scripts, then clean up older links in
   small batches.
2. Continue reducing "silicon" wording where the actual public proof is QEMU
   plus Bochs and KVM is optional.
3. Draft a textual-seed hardening plan with executable intermediate checks
   before attempting any seed rewrite.
4. Keep `VERIFYING.md` as the first stop for new workers; every ambitious claim
   should lead back to a command, workflow, golden, runner, or explicit limit.

## Evidence Captured Before This Edit

Local:

```text
git status --short --branch
## codex/fresh-eyes-breather-20260624

git rev-parse HEAD
e192db7b34e1f3a8f0023176a16b89c67a77409e

make verify-local
PASS: verify target guard (verify-local is portable; verify-linux keeps the full Linux/x86_64 ladder)
OK: 354 tracked non-.herb file(s) match BOOTSTRAP-ALLOWLIST
PASS: timeout wrapper
PASS: lexer copy sync (8 copied lexer blocks match stack/lexer_fragment.herb contracts)
PASS: native-codegen qemu diagnostics
```

Remote:

```text
origin/codex/sovereignty-audit-20260624
e192db7b34e1f3a8f0023176a16b89c67a77409e

PR #3
https://github.com/CommonHerb/herbert/pull/3
draft, open, base main, head codex/sovereignty-audit-20260624

Checks at e192db7:
push check: success
PR check: success
PR kernel-codegen-l1 / l1-dual-substrate: success
```

## Evidence Captured After This Edit

Focused fail-closed proof with QEMU hidden from `PATH`:

```text
PATH=/usr/bin:/bin KERNEL_CODEGEN_REQUIRE_EMU=1 bash bootstrap/tests/run_native_codegen_link49_mutation.sh
FAIL: stack/native_compile_fragment.herb (mutation proof requires QEMU)

PATH=/usr/bin:/bin bash bootstrap/tests/run_native_codegen_link49_mutation.sh
SKIP: qemu not found (mutation proof needs the silicon gate)
```

The same require-fails / nonrequire-skips behavior was checked for
`run_native_codegen_link50_mutation.sh`, `run_native_codegen_link51_mutation.sh`,
and `run_native_codegen_link52_mutation.sh`.

Local gates:

```text
git diff --check

python3 tools/check_verify_targets.py
PASS: verify target guard (verify-local is portable; verify-linux keeps the full Linux/x86_64 ladder)

python3 tools/check_timeout.py
PASS: timeout wrapper

python3 bootstrap/tests/check_lexer_copy_sync.py
PASS: lexer copy sync (8 copied lexer blocks match stack/lexer_fragment.herb contracts)

bash bootstrap/tests/run_native_codegen_qemu_diag_tests.sh
PASS: native-codegen qemu diagnostics

bash -n bootstrap/tests/run_native_codegen_link49_mutation.sh bootstrap/tests/run_native_codegen_link50_mutation.sh bootstrap/tests/run_native_codegen_link51_mutation.sh bootstrap/tests/run_native_codegen_link52_mutation.sh

make verify-local
PASS: verify target guard (verify-local is portable; verify-linux keeps the full Linux/x86_64 ladder)
OK: 355 tracked non-.herb file(s) match BOOTSTRAP-ALLOWLIST
PASS: timeout wrapper
PASS: lexer copy sync (8 copied lexer blocks match stack/lexer_fragment.herb contracts)
PASS: native-codegen qemu diagnostics
```
