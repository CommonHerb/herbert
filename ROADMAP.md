# Herbert Roadmap

This map keeps Herbert's verification and self-ownership path tied to code,
tests, goldens, runners, and workflow logs.

## Current Map

### Proven

- The C bootstrap builds and runs the smoke suite through `make verify-local`.
- `make check` enforces the visible non-`.herb` bootstrap boundary in
  `BOOTSTRAP-ALLOWLIST`.
- `make verify-local` includes a C-vs-Herbert accepted-source lexer
  equivalence check for a small fixture corpus, including a focused
  native/operator-surface fixture, via `stack/lexer_stdin_driver.herb`, plus
  lexer ERR code, line, and message parity for the existing
  `stack/error_probes/lex_*.herb` malformed probes via
  `stack/lexer_error_driver.herb`.
- `make verify-local` also checks that the accepted-token lexer copies in
  `stack/lexer_stdin_driver.herb`, parser/evaluator/emitter fragments, and
  Suke fragments remain synchronized with `stack/lexer_fragment.herb`; it
  additionally checks that the line-aware lexer variants in `stack/klondike.herb`
  and `stack/native_compile_fragment.herb` match the same token contract with
  their documented line field.
- `make test` is the Linux/x86_64 full non-emulator suite and refuses early on
  other hosts.
- `.github/workflows/kernel-codegen-l1.yml` is the authoritative emulator gate
  for the kernel/module native-codegen links when CI runs with QEMU and Bochs.
- Native-codegen links up through the current kernel/module arc are represented
  by shell harnesses, Python reference builders, golden artifacts, and mutation
  gates under `bootstrap/tests/`.

### Aspirational

- Herbert should own more of its own lexer, parser, evaluator, compiler,
  runtime, and verification surfaces over time.
- Host languages are bootstrap tools, not Herbert's identity.
- Native execution should grow by verified compiler/runtime pieces rather than
  claims of dependency erasure.
- Kernel and OS work should remain substrate-graded and fail closed when an
  emulator, golden, or mutation proof is missing.
- Self-hosting should arrive as a chain of reproducible fixpoints, not a rename
  of hosted code.

### Unknown

- Which C bootstrap component is the safest next deletion candidate.
- Which Herbert-written stack fragment has enough coverage to become an
  authoritative replacement for a host component.
- Which optional Linux/x86_64 runner helper is the least misleading local path
  for developer machines that need the Linux-only gates.
- Which kernel/module gates are too expensive for every PR and need scheduled
  or manually dispatched lanes.

## Near-Term Stabilization

- Keep `make verify-local` fast, portable, and green on Darwin/arm64 and Linux.
- Keep `make test` truthful about its Linux/x86_64 requirement.
- Keep CI logs reviewable by separating portable checks, full non-emulator
  checks, and emulator-heavy kernel/module checks.
- Add regression probes before behavior changes; documentation follows code,
  not the other way around.

## Self-Hosting Prerequisites

- Map each C bootstrap responsibility to the Herbert file or test that would
  prove a replacement.
- Add dual-run checks where a Herbert implementation and C bootstrap component
  can be compared on the same fixtures.
- Preserve byte-for-byte or behavior-for-behavior fixpoint checks where the
  compiler/runtime is claiming self-ownership.
- Delete from `BOOTSTRAP-ALLOWLIST` only when a replacement is executable and
  verified.

## Native Runtime And Compiler Work

- Continue expanding native-codegen only through small, named links with
  reference builders, goldens, disassembly or byte pins where useful, and
  mutation proofs.
- Prefer runtime-observable witnesses over static claims when proving a new
  compiler/runtime capability.
- Keep old emit modes byte-identical unless the change intentionally updates
  their contract and tests.

## Kernel And OS Substrate Work

- Keep QEMU plus Bochs as the dual-substrate public gate for kernel/module
  claims.
- Require `KERNEL_CODEGEN_REQUIRE_EMU=1` in authoritative workflows so missing
  emulator tooling is a failure, not a skip.
- Treat module isolation, syscall, memory, scheduling, and multi-page work as
  kernel contract surfaces that need hostile probes as well as benign probes.

## Far-Future Language Purity Goals

- Shrink host-language scaffolding by replacement, not hiding.
- Move syntax, semantics, IR, compiler, runtime, and eventually build tooling
  into Herbert-owned code with executable equivalence checks.
- Keep foreign tools only as explicitly named substrates until Herbert has a
  verified native alternative.

## Next Small Real Step

Continue expanding lexer equivalence with focused fixtures for real parser,
compiler, and native-codegen source shapes, then start the parser replacement
proof with a C-AST-to-Herbert-AST comparison. Keep this as proof-building only;
no C lexer deletion is justified yet.
