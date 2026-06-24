# Kernel Proof Hygiene - 2026-06-24

Branch: `codex/kernel-proof-hygiene-20260624`
Stack base: `codex/fresh-eyes-breather-20260624`

This note covers a narrow proof-contract pass over the kernel/native-codegen
emulator gates. It does not change compiler or kernel semantics.

## Audited

- `.github/workflows/kernel-codegen-l1.yml` commands that run with
  `KERNEL_CODEGEN_REQUIRE_EMU=1`.
- `bootstrap/tests/run_native_codegen_link17.sh` through
  `bootstrap/tests/run_native_codegen_link52.sh`, with emphasis on mutation
  companions invoked by the kernel workflow.
- Missing-QEMU behavior with `PATH=/usr/bin:/bin` and
  `KERNEL_CODEGEN_REQUIRE_EMU=1`.
- Existing KVM / "silicon" wording in workflow names, docs, and kernel scripts.

## Touched

- `bootstrap/tests/run_native_codegen_link18_mutation.sh`
- `bootstrap/tests/run_native_codegen_link19_mutation.sh`
- `bootstrap/tests/run_native_codegen_link20_mutation.sh`
- `bootstrap/tests/run_native_codegen_link21_mutation.sh`
- `bootstrap/tests/run_native_codegen_link22_mutation.sh`
- `bootstrap/tests/run_native_codegen_link23_mutation.sh`
- `bootstrap/tests/run_native_codegen_link24_mutation.sh`
- `bootstrap/tests/run_native_codegen_link25_mutation.sh`
- `bootstrap/tests/run_native_codegen_link26_mutation.sh`
- `bootstrap/tests/run_native_codegen_link27_mutation.sh`
- `bootstrap/tests/run_native_codegen_link28_mutation.sh`
- `bootstrap/tests/run_native_codegen_link29_mutation.sh`
- `tools/check_kernel_emu_contracts.py`
- `Makefile`
- `tools/check_verify_targets.py`
- `BOOTSTRAP-ALLOWLIST`
- `VERIFYING.md`
- `docs/codex/proof-hygiene-2026-06-24.md`

## Repair

Mutation links 18 through 29 were wired so
`KERNEL_CODEGEN_REQUIRE_EMU=1` caused the mutation proof to run, but their
missing-QEMU branch still exited successfully with a `SKIP`. That contradicted
the kernel workflow's explicit contract that missing emulator tooling is a hard
failure when emulators are required.

Each touched mutation script now preserves the default optional local skip, but
fails if `KERNEL_CODEGEN_REQUIRE_EMU=1` and `qemu-system-x86_64` is absent.

The new `kernel-emu-contracts` target runs
`tools/check_kernel_emu_contracts.py`, which reads the workflow mutation-script
list and flags missing-QEMU skip blocks that do not have an explicit
require-mode failure path. `verify-local` and `verify-linux` both include this
portable static guard.

## Deferred

- The broader "silicon" vocabulary remains mixed in old script comments and
  PASS prose. Recent workflow names and late-link scope summaries already make
  QEMU, Bochs, and KVM availability explicit; rewriting all older prose would be
  a separate documentation pass.
- This pass does not claim local Linux/x86_64, Bochs, KVM, or full kernel
  proof. Those require the GitHub kernel workflow or an equivalent verified
  Linux/emulator environment.
- This pass does not touch compiler output, kernel bytes, references, goldens,
  or the seed.

## Checks

Initial RED evidence before repair:

```text
PATH=/usr/bin:/bin KERNEL_CODEGEN_REQUIRE_EMU=1 bash bootstrap/tests/run_native_codegen_link18_mutation.sh
SKIP: native-codegen link18 mutation proof (no qemu)
exit=0

PATH=/usr/bin:/bin KERNEL_CODEGEN_REQUIRE_EMU=1 bash bootstrap/tests/run_native_codegen_link29_mutation.sh
SKIP: native-codegen link29 mutation proof (no qemu)
exit=0

PATH=/usr/bin:/bin KERNEL_CODEGEN_REQUIRE_EMU=1 bash bootstrap/tests/run_native_codegen_link30_mutation.sh
FAIL: link30 mutation (REQUIRE_EMU=1 but qemu missing)
exit=1
```

Final local verification before push:

```text
python3 tools/check_kernel_emu_contracts.py
PASS: kernel emulator contract guard (35 workflow mutation scripts fail closed when emulators are required)

python3 tools/check_verify_targets.py
PASS: verify target guard (verify-local is portable; verify-linux keeps the full Linux/x86_64 ladder)

git diff --check

bash -n bootstrap/tests/run_native_codegen_link18_mutation.sh ... bootstrap/tests/run_native_codegen_link29_mutation.sh

python3 -m py_compile tools/check_kernel_emu_contracts.py tools/check_verify_targets.py

PATH=/usr/bin:/bin KERNEL_CODEGEN_REQUIRE_EMU=1 bash bootstrap/tests/run_native_codegen_link18_mutation.sh
FAIL: stack/native_compile_fragment.herb (mutation proof requires QEMU)

PATH=/usr/bin:/bin KERNEL_CODEGEN_MUTATION=1 bash bootstrap/tests/run_native_codegen_link18_mutation.sh
SKIP: native-codegen link18 mutation proof (no qemu)

make verify-local
PASS: verify target guard (verify-local is portable; verify-linux keeps the full Linux/x86_64 ladder)
OK: 357 tracked non-.herb file(s) match BOOTSTRAP-ALLOWLIST
PASS: timeout wrapper
PASS: lexer copy sync (8 copied lexer blocks match stack/lexer_fragment.herb contracts)
PASS: native-codegen qemu diagnostics
PASS: kernel emulator contract guard (35 workflow mutation scripts fail closed when emulators are required)
```

The hidden-QEMU require/optional behavior was checked for every edited mutation
script from `run_native_codegen_link18_mutation.sh` through
`run_native_codegen_link29_mutation.sh`.

Not locally claimed: Linux/x86_64 native execution, Bochs, KVM, or the full
kernel workflow. Those remain remote/equivalent-environment proof surfaces.
