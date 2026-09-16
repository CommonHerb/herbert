# Verifying Herbert

This repo has several verification levels. They are intentionally separate because each one proves a different amount.

Choose checks that cover the behavior changed. Run affected checks first and
use the aggregate below to qualify integrated hosted changes. Once the relevant
checks pass, repeat or broaden them only for new changes, failures, or unresolved
concerns. Prose changes need source and link review, not runtime reruns.

## Integrated Hosted Qualification

```bash
make verify-local
```

Runs:

- `make check`: confirms tracked non-`.herb` files exactly match `BOOTSTRAP-ALLOWLIST` (the from-scratch boundary scanner `tools/scan.c` — kept governance meta-tooling, not the retired interpreter).
- `make verification-helpers`: checks exact compiler success and native runtime transcripts, rejects failing/noisy compilers even when they emit valid images, and checks emulator selection, honest kernel summaries, raw capture retention and complete CI matrix coverage.
- `make test-timeout`: checks the repo-local portable `timeout` shim.
- `make test`: the full non-emulator harness (see below). This already includes
  all six fragment/mutation pairs (`evaluator-native`, `vm-native`, `parser-native`,
  `lexer-native`, `klondike-native`, `emitter-native`) and `switchover-cfree`.
  Each fragment is compiled to ELF by the committed gen-1 seed, runs with **no C**,
  and is compared to its independently authored oracle; the mutations must compile
  and run before producing a wrong runtime value. These fragment checks, plus the aggregate-render and error-vocabulary gates, require compiler success status
  0, exactly `0\n` stdout and empty stderr before any image is inspected.
  The standalone targets remain available for diagnosis; `verify-local` does not
  dispatch those same targets a second time. The C-free proof retains both its
  absent-interpreter and counting-tombstone phases, with the toolchain excluded.
- `make error-vocab-native`: the C-free re-gating of klondike.herb's located **front-end error vocabulary** (ERR 101–316) — the gen-1 seed compiles klondike (a 1-line `main` adapter; `klondike.herb` byte-identical) and feeds it the 54 malformed `error_probes` fixtures; each must emit the hand-authored manifest's ERR code (independent anchor) **and** the committed golden diagnostic (regression pin), with gate-time metamorphic checks (line-shift + payload-rename at five extraction sites) proving the diagnostic tracks the input, plus a RED-first mutation proof. Restores the assurance `castoff` spent when it deleted the C-driven `error_probes` differential (`klaxon`, sovereignty link 19). Distinct from the native-codegen seed's own subset vocabulary (ERR 4xx/5xx), which the native-codegen reject battery gates.
- `make lexer-copy-sync`: checks that accepted-token lexer copies in the stdin/parser/evaluator/emitter and Suke fragments stay synchronized with `stack/lexer_fragment.herb` (the line-aware token contract).
- `make native-codegen-diagnostics`: checks the local helper used to enrich kernel QEMU mismatch logs.
- `make switchover-dry-run`: checks that the existing C-free mutation proofs still detect faults with the retired C toolchain absent.
- `make compiler-cli-contract`: checks atomic output publication, including syscall fault injection and the emitted writer's instruction layout (tools described below).
- `make wordcount`: compiles the maintained word counter with the committed seed and checks its output, input failures, and sustained input processing.
- `make hosted-memory-io`: checks the general hosted byte-buffer/syscall interfaces,
  including Linux ABI arguments, rejection and sustained mutation memory use.
- `make check-desktop`: builds First steps, then observes pixels, real keyboard
  events, focus/shutdown and sustained memory on a private Xvfb display. Python,
  libX11, libXtst and Xvfb are independent test tooling, not program dependencies.

- `make check-app-support`: independent map/parser and text-buffer models,
  file validation, atomic saving, external conflicts and syscall fault injection.
  Requires strace for file-failure checks; it is development tooling only.
- `make check-hosted-apps`: maze wall/collection/completion/restart behavior and
  editor typing/navigation/save/reopen/dirty-close on private XTest windows,
  plus 120 seconds each of repeated play/restart and edit/save/scroll memory checks.
  Strace also tests the visible post-publication sync warning and retry.
  Evidence includes screenshots, input history, saved bytes and memory samples;
  the hosted CI workflow uploads retained application evidence even on failure.

This is the full hosted aggregate. It does not run the emulator-heavy kernel suite.
Hosted CI selects `ubuntu-26.04`, matching the kernel job's explicit image, and
logs the actual OS, architecture and installed test-tool versions before grading.
The image label is not a lock on every package; the recorded versions identify
that run's environment. No unvalidated package-version pins are implied.

## Full Non-Emulator Suite

```bash
make test
```

Runs the main shell harness in `bootstrap/tests/run_tests.sh`.

It also runs `bootstrap/tests/compiler_conformance.py`: independently declared
ordinary hosted inputs with exact compiler status/streams/artifact checks, then
exact generated-program output/status checks for accepted cases. The explicit
`run-stdio` profile additionally checks runtime stderr; the legacy `run` profile
still requires it empty. Version 3 source rejection requires status 1, empty
stdout and the unchanged exact diagnostic on stderr.
These cases do not replace syscall fault-injection or full target verification.

`bootstrap/tests/stdin_contract.py` also runs under `make test`, or separately
with `make stdin-contract`. It checks generated `stdin_read` programs and the
compiler itself using real closed/directory/nonblocking-pipe descriptors. Empty
EOF differs from an empty pipe with a held-open writer. Compiler read errors
must produce the exact failure status/streams and preserve absent, regular,
symlink and hardlink artifact state. A closed-writer pipe carrying valid source
is the successful compiler control. This needs only Python's standard library
and Linux/x86_64, not ptrace, GDB, strace or an emulator. Failed runs retain
their scratch evidence automatically; `--keep-work` also retains successful
runs. `make check` runs only its portable declaration/oracle self-tests.

This regular gate checks final artifact state, not transient file operations.
Injected errors after a valid prefix, interrupted/short transfers, arena-capacity
probes and broken-stderr cases have separate manual fault evidence; they are
not continuously exercised by this descriptor gate. No output-publication or kernel verification claim follows from that
descriptor gate alone.

`compiler_cli_contract.py` runs filesystem and concurrent-publication checks in
`make test`. `make compiler-cli-contract` additionally uses strace to inject
open/random/write/fsync/close/rename failures and EINTR, GDB to force real short
writes, and GNU binutils to compare the emitted writer against its readable
assembly specification. Missing tools/tracing fail this target. The fault target
runs in `verify-local` and the check workflow; no assembler is involved in the
production compiler or normal seed mint. `--compiler PATH` can qualify an old
seed or mutant; `--keep-work` retains successful evidence, and failures retain
it automatically. This includes regular-file, symlink, hardlink, umask, directory
rejection, empty-file and concurrent whole-image publication checks. Abrupt
termination, hostile containing-directory mutations and post-rename power loss
are outside this contract.

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

Bare per-link scripts may skip absent emulators. `make kernel-verify` requires
QEMU-TCG and Bochs through the policy `KERNEL_CODEGEN_REQUIRE_EMU=1` that each
individual gate enforces. The driver checks every requested
canonical gate and mutation proof, and fails if a required script is missing.
For declared KVM member links, a present but inaccessible `/dev/kvm` fails the
preflight. Device availability alone does not prove a KVM boot. Its GREEN summary
reports passed gate/proof counts and explicitly makes no aggregate per-substrate
execution claim; inspect actual per-gate captures for that evidence. CI remains
the separately pinned dual-emulator lane, without a KVM claim.

For the pinned local QEMU, set `QEMU_PREFIX=/opt/qemu-10.2.1` before a
standalone gate or `make kernel-verify`. The prefix must be absolute and contain
an executable regular file at `bin/qemu-system-x86_64`. The shared test helper
`bootstrap/tests/qemu_prefix.sh` removes function shadows and checks that command
lookup resolves to that exact path. Every caller fails closed if its helper or
oracle cannot be sourced, before testing emulator availability. The helper is
an explicit test-tooling allowlist addition; emitted Herbert programs gain no
runtime dependency. A wrapper must use `exec` to preserve signal status.

CI divides links 17..67 into independently scheduled groups. Each group runs
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

`make check-long64-wordcount` separately builds and checks the maintained
[streaming application](examples/wordcount_long64.md) under QEMU. It runs once
in the 60..61 CI job, retaining application evidence alongside the kernel gate
directories. Its application result remains separate from the kernel gate
STATUS files. The application checker has an optional `--kvm` case for local hardware;
its normal CI checks use QEMU TCG and do not claim a Bochs application run.

Folio (link67) supplies boot-file input and exercises the
[binary file viewer](examples/hexview_long64.md). Its normal and mutation gates
join the existing 99 kernel gates. They check exact raw bytes and EOF, call
continuity, ELF stack reservation and explicit refusal of invalid boot input.
GDB changes selected boot registers/metadata at the real kernel entry to exercise
invalid spans without adding production hooks. GRUB uses `module --nounzip`;
Bochs exercises GRUB's empty-file sentinel; QEMU checks missing input. The local command
for this link is `KERNEL_VERIFY_LO=67 KERNEL_VERIFY_HI=67 make kernel-verify`.

`make check-long64-elfinfo` builds the [ELF inspector](examples/elfinfo_long64.md)
and checks the actual compiler and inspector images, both supported header
formats and focused malformed inputs. It uses KVM and Bochs when available;
the 60..61 CI job requires Bochs and retains the application evidence in its own
subdirectory of the same kernel-job artifact. This application adds no kernel gate.

## What These Commands Do Not Prove

- They do not prove arbitrary-program compiler correctness.
- They do not prove a finished OS.
- They do not, on their own, re-establish the trusting-trust provenance of the committed seed (the C bootstrap interpreter has been removed at the switchover; the seed remains C-minted once, and the textual-seed hardening is the remaining deferred sovereignty residue).
- They do not make old archived docs current.

They prove the specific executable surfaces each command invokes.
