# Herbert Sovereignty Audit

Date: 2026-06-24
Branch: `codex/sovereignty-audit-20260624`
Base: `d1e8eb218acf91fa4ce5f10b72bd59fec20394a5`
Remote: `https://github.com/CommonHerb/herbert.git`

## Verdict

Herbert is materially more sovereign than the old narrative around the project
would lead a reader to expect. In the current GitHub checkout, the C bootstrap
interpreter is gone. The production compiler/runtime path is the committed
x86_64 Linux `bootstrap/seed/gen1.seed`, Herbert source in `stack/`, committed
goldens, and Linux/emulator CI gates. The remaining tracked C source is
`tools/scan.c`, a governance scanner for the allowlist, not a Herbert runtime.

The project is also less cleanly self-owned than the strongest prose implies.
The seed is still a once-C-minted binary trust root, textual seed hardening is
deferred, the most advanced kernel work is a chain of named proof emit modes
rather than a general-purpose OS/compiler surface, and local verification is
currently misleading on macOS: `VERIFYING.md` says non-Linux hosts should use
`make verify-local`, but `make verify-local` depends on `make test`, and
`make test` correctly rejects Darwin/arm64.

My senior-engineer verdict: Herbert is a serious experimental language and
runtime stack with unusually strong bite-proof discipline, but the current
truth surface has drift. The next sovereignty work should not be more rhetoric.
It should make verification commands truthful, keep docs aligned with the
post-switchover source tree, and close the remaining seed/golden/kernel trust
boundaries with executable gates.

## Audit Method

This audit treated the GitHub checkout as source of truth. The local zip at
`/Users/ben/Desktop/1/herbert-main.zip` was inspected only as a hint. The actual
worktree was hydrated from `https://github.com/CommonHerb/herbert.git` and the
branch `codex/sovereignty-audit-20260624` was created from remote `main` at
`d1e8eb2`.

Evidence was gathered from:

- `README.md`, `ROADMAP.md`, `VERIFYING.md`, `SWITCHOVER.md`,
  `BOOTSTRAP-RESPONSIBILITIES.md`, `BOOTSTRAP-ALLOWLIST`, and `Makefile`
- `.github/workflows/check.yml` and `.github/workflows/kernel-codegen-l1.yml`
- `bootstrap/tests/run_tests.sh`, switchover scripts, native-codegen scripts,
  mutation scripts, references, and committed goldens
- Current local behavior on Darwin/arm64
- Current GitHub Actions state via `gh`
- Four read-only explorer passes over docs, verification/CI, bootstrap/runtime,
  and native/kernel frontier

## What Is Proven

### The C interpreter is retired in this checkout

Evidence:

- `find . -name '*.c' -print` returns only `./tools/scan.c`.
- `find . -name '*.h' -print` returns no tracked headers.
- `Makefile` states that the C bootstrap interpreter was retired and only builds
  `tools/scan.c` into `build/scan`.
- `BOOTSTRAP-RESPONSIBILITIES.md` says the C bootstrap migration is finished and
  identifies `tools/scan.c` as governance meta-tooling, not a Herbert
  interpreter.

This supports the present-tense claim "the C bootstrap interpreter is gone." It
does not support "there are zero C bytes in the repo," because `tools/scan.c`
intentionally remains.

### The allowlist guard is real

Evidence:

- At the initial audit baseline, `make check` compiled `tools/scan.c` and
  reported: `OK: 351 tracked non-.herb file(s) match BOOTSTRAP-ALLOWLIST`.
  After adding this audit document and allowlist entry, it reported `OK: 352`.
- `BOOTSTRAP-ALLOWLIST` says every tracked non-`.herb` file must be listed by
  exact repository-relative path.
- The scanner fails both unlisted tracked files and stale allowlist entries.

This is a strong governance guard. It makes non-Herbert residue visible and
reviewable.

### The committed seed is an x86_64 Linux trust root and its hash matches

Evidence:

- `file bootstrap/seed/gen1.seed` reports:
  `ELF 64-bit LSB executable, x86-64, version 1 (SYSV), statically linked, no section header`.
- `shasum -a 256 bootstrap/seed/gen1.seed` reports:
  `a3378031aa1314d522f68b0580e8c9723348ea8fd429b0c479edbb8777b11167`.
- `bootstrap/seed/gen1.seed.sha256` contains the same hash.
- The native-codegen oracle checks seed presence, ELF magic, and SHA before use.

This proves the checked-in seed is pinned. It does not prove the seed's original
provenance is human-auditable or trusting-trust hardened.

### The normal Linux CI lane is green at the branch base

Evidence:

- Branch push run:
  `https://github.com/CommonHerb/herbert/actions/runs/28085107553`
- SHA: `d1e8eb218acf91fa4ce5f10b72bd59fec20394a5`
- Result: success
- Steps succeeded: `make check`, `timeout shim`, `make test`
- Completed: `2026-06-24T08:20:59Z`

This proves the Linux `check` workflow accepted the branch base. It does not
prove kernel/emulator links.

### The kernel frontier is scripted through Link 52

Evidence:

- Recent history ends at:
  `d1e8eb2 lethe (kernel-arc link 36 / native-codegen Link 52): ALIAS-REMAP + TARGETED TLB INVALIDATION`.
- `.github/workflows/kernel-codegen-l1.yml` includes kernel gates through L36
  and mutation proof for L36 using `KERNEL_CODEGEN_REQUIRE_EMU=1`.
- `bootstrap/tests/run_native_codegen_link52.sh` byte-pins the emitted kernel,
  checks `assertlethe`, attempts QEMU, optionally KVM, and Bochs where tooling is
  present.

This proves the Link 52 frontier is present and wired. At audit time, the latest
kernel workflow for `d1e8eb2` was still in progress, so current Link 52 should be
called "scripted and under CI evaluation" until that run finishes green.

## What Is Aspirational Or Provisional

### Total self-ownership is not complete

The current stack has no C interpreter, but it still relies on:

- A committed once-C-minted binary seed
- Shell and Python harnesses
- Committed golden artifacts
- Linux/x86_64 execution
- QEMU/Bochs/GRUB/Xvfb/disk tooling for kernel proof
- A C governance scanner

`VERIFYING.md` correctly admits that the commands do not re-establish the
trusting-trust provenance of the committed seed. `BOOTSTRAP-RESPONSIBILITIES.md`
also says textual-seed hardening remains deferred.

### Kernel/runtime capability is substantial but not general

The Link 52 frontier is meaningful: alias remap plus targeted TLB invalidation
is a real kernel primitive. The risk is scope inflation. The later kernel links
are emitted proof modes and reference-pinned experiments, not yet a general OS,
general process model, general ELF loader, SMP-safe TLB shootdown, or arbitrary
compiler correctness proof.

The right wording is: Herbert has many executable kernel/runtime proof links.
It does not yet have a finished independent operating system.

### Goldens are both strength and trust boundary

Committed goldens provide repeatable C-free regression evidence. They also
become part of the trust root. A golden-passing suite can still preserve a wrong
contract if the seed, reference, and golden all share the same blind spot. The
mutation gates reduce that risk, but do not eliminate it for arbitrary programs.

## Misleading Or Stale Surfaces

### `make verify-local` is not local-portable on macOS

Current docs say non-Linux hosts should use `make verify-local`. Current source
does not make that true.

Evidence:

- `VERIFYING.md` says macOS or non-x86_64 hosts should use `make verify-local`.
- `ROADMAP.md` says to keep `make verify-local` green on Darwin/arm64 and Linux.
- `Makefile` defines:
  `verify-local: check test-timeout test evaluator-native vm-native parser-native lexer-native klondike-native emitter-native error-vocab-native lexer-copy-sync native-codegen-diagnostics switchover-cfree switchover-dry-run`
- `make test` runs `tools/check_full_test_host.sh`.
- `tools/check_full_test_host.sh` exits successfully only on Linux/x86_64.
- On this host, `make verify-local` failed with:
  `FAIL: make test requires a Linux/x86_64 host.`

Root cause: the command named `verify-local` included non-portable native ELF
execution gates after the switchover. Branch repair: `make verify-local` is now
the portable source/governance ladder, and `make verify-linux` preserves the old
Linux/x86_64 ladder under a truthful name.

### Initial finding: `README.md` described a C interpreter layout

`README.md` says `bootstrap/` contains the C seed interpreter/runtime, parser,
evaluator, value model, garbage collector, and test harness. The current tree no
longer contains that C interpreter. The remaining C source is `tools/scan.c`.

Branch repair: `README.md` now describes the committed native gen-1 seed,
verification harnesses, goldens, and switchover machinery instead of a live C
interpreter.

### Initial finding: `ROADMAP.md` said "The C bootstrap builds"

`ROADMAP.md` listed as proven: "The C bootstrap builds and runs the smoke suite
through `make verify-local`." That contradicts the current Makefile and tree:
the C interpreter is retired, `smoke` is gone, and `make verify-local` fails on
Darwin/arm64 before reaching the advertised ladder.

Branch repair: `ROADMAP.md` now names `make verify-local`, `make verify-linux`,
`make test`, and the kernel workflow by their current proof boundaries. Its
self-hosting section now treats `BOOTSTRAP-RESPONSIBILITIES.md` as a retired
map and says not to revive C as a live oracle.

### Initial finding: `SWITCHOVER.md` was historical but read like pending plan

`SWITCHOVER.md` said the event had not executed and described a greenlight gate.
The source history and current tree show the switchover has been executed. This
file may still be useful as historical record, but it needs an explicit
post-switchover preface or archival status so readers do not treat it as current
operating truth.

Branch repair: `SWITCHOVER.md` now identifies itself as a historical record,
names `castoff` commit `e231a7127a2d576e9caf5704b6e80e47cfe0b475` as the
executed switchover, and points current truth to the Makefile, verifying docs,
responsibility map, gates, and CI.

### Initial finding: `bootstrap/seed/README.md` had stale pre-switchover text

The seed README correctly admitted the trusting-trust limit and described the
post-switchover reseed path later in the file. But its opening said C was
present for the differential oracle and interpreted probes. That was stale.

It also advertises an old hash prefix `4af3dbee...ec7a0`; the tracked seed hash
is currently `a3378031aa1314d522f68b0580e8c9723348ea8fd429b0c479edbb8777b11167`.
The `.sha256` file is correct, so this is documentation drift rather than an
integrity failure.

Branch repair: the seed README now says the C interpreter is retired and the
remaining tracked C source is only the `tools/scan.c` governance scanner. It
also names the current seed hash from `gen1.seed.sha256`.

### Initial finding: `BOOTSTRAP-RESPONSIBILITIES.md` referenced missing `LEDGER.md`

The responsibility map referenced `LEDGER.md`; no such file exists in the
current checkout. That weakens the audit trail for claims such as native
reclamation being far-axis-tethered.

Branch repair: `BOOTSTRAP-RESPONSIBILITIES.md` now points to live sources. The
C-GC instrumentation retirement is tied to the muster classification in
`bootstrap/tests/run_tests.sh`; the later far-axis native reclamation proof is
tied to `bootstrap/tests/run_native_codegen_link47.sh`, its mutation proof, and
the L31 steps in `.github/workflows/kernel-codegen-l1.yml`.

## Verification Evidence

Commands run locally on Darwin/arm64:

```text
git status -sb
## codex/sovereignty-audit-20260624

git rev-parse HEAD
d1e8eb218acf91fa4ce5f10b72bd59fec20394a5

git ls-remote https://github.com/CommonHerb/herbert.git HEAD refs/heads/main
d1e8eb218acf91fa4ce5f10b72bd59fec20394a5 HEAD
d1e8eb218acf91fa4ce5f10b72bd59fec20394a5 refs/heads/main

make verify-local  # initial audit baseline, before this document was tracked
OK: 351 tracked non-.herb file(s) match BOOTSTRAP-ALLOWLIST
PASS: timeout wrapper
FAIL: make test requires a Linux/x86_64 host.
...
host (Darwin/arm64)

make check test-timeout lexer-copy-sync native-codegen-diagnostics  # after adding this document
OK: 352 tracked non-.herb file(s) match BOOTSTRAP-ALLOWLIST
PASS: timeout wrapper
PASS: lexer copy sync (8 copied lexer blocks match stack/lexer_fragment.herb contracts)
PASS: native-codegen qemu diagnostics
```

Initial baseline before this document was tracked:

```text
make check test-timeout lexer-copy-sync native-codegen-diagnostics
OK: 351 tracked non-.herb file(s) match BOOTSTRAP-ALLOWLIST
PASS: timeout wrapper
PASS: lexer copy sync (8 copied lexer blocks match stack/lexer_fragment.herb contracts)
PASS: native-codegen qemu diagnostics

make test
FAIL: make test requires a Linux/x86_64 host.

make lexer-native
native-codegen: acquired C-free gen-1 seed ...
    (gen-1 compile produced no ELF: )
FAIL: lexer native execution (native gen-1 lexer did not run cleanly)

file bootstrap/seed/gen1.seed tools/scan.c tools/timeout
bootstrap/seed/gen1.seed: ELF 64-bit LSB executable, x86-64, statically linked, no section header
tools/scan.c:             c program text
tools/timeout:            Python script text executable, ASCII text

shasum -a 256 bootstrap/seed/gen1.seed
a3378031aa1314d522f68b0580e8c9723348ea8fd429b0c479edbb8777b11167  bootstrap/seed/gen1.seed
```

GitHub Actions evidence:

```text
check, branch codex/sovereignty-audit-20260624, run 28085107553
status: completed
conclusion: success
headSha: d1e8eb218acf91fa4ce5f10b72bd59fec20394a5
completedAt: 2026-06-24T08:20:59Z
steps: make check, timeout shim, make test

kernel-codegen-l1, branch main, run 28070189136
status at audit time: in_progress
headSha: d1e8eb218acf91fa4ce5f10b72bd59fec20394a5
observed completed through L19 and then L20 in progress during audit
```

## Risks To The Vision

1. Misnamed verification commands erode trust. If `verify-local` is the advertised
   portable ladder, it must pass locally or be renamed/split.
2. Stale docs undermine the bootstrapping honesty the project is trying to
   defend. The source may be better than the docs, but auditors read both.
3. The seed is still the deepest trust root. Until textual-seed hardening exists,
   Herbert is C-free after seed creation, not fully provenance-free.
4. Goldens can ossify mistakes. The suite needs continued negative tests,
   independent references, mutation proofs, and eventually more generated-from-
   text reproducibility.
5. Kernel progress is real but frontier-shaped. Proof links must keep saying what
   they do not prove: no general OS, no arbitrary compiler correctness, no SMP TLB
   protocol, no general ELF loader yet.
6. CI topology can mislead. The normal `check` workflow is green quickly, while
   kernel proof is separate and long-running. A green `check` badge alone is not
   the whole truth.

## Highest-Leverage Next Moves

1. Split or repair local verification.
   - Make `make verify-local` a truthful portable source/governance ladder, or
     rename the current full local command to a Linux-only target.
   - Keep `make test` as the authoritative Linux/x86_64 non-emulator suite.
   - Update `VERIFYING.md` and `ROADMAP.md` to match the target topology.

2. Continue truth-surface cleanup beyond the repaired switchover docs.
   - The branch now marks `SWITCHOVER.md` as historical, fixes the seed README
     hash/provenance wording, updates `ROADMAP.md`'s retired-C framing, and
     replaces the missing `LEDGER.md` pointer with live proof surfaces.
   - Remaining cleanup should focus on any overbroad kernel PASS prose found by
     log review.

3. Tighten kernel run truth.
   - Treat Link 52 as not fully current until the `kernel-codegen-l1` run for
     `d1e8eb2` is green.
   - Audit mutation scripts for `KERNEL_CODEGEN_REQUIRE_EMU=1` fail-closed
     behavior.
   - Avoid PASS prose that says KVM was green when KVM was skipped.

4. Advance seed provenance.
   - Document an executable plan for textual seed hardening.
   - Add smaller reproducibility checks around seed structure and deterministic
     materialization.

5. Reduce monolith risk gradually.
   - `stack/native_compile_fragment.herb` is about 20k lines. Avoid large
     refactors, but use focused sync guards and extraction proofs where Herbert
     lacks modules and copies logic across fragments.

## Current Audit Verdict

Proven:

- C interpreter retired from the checkout.
- Only tracked C source is the allowlist governance scanner.
- Seed hash and ELF identity are pinned.
- Linux `check` workflow is green at the branch base.
- Kernel proof chain is wired through Link 52.

Provisional:

- Link 52 runtime truth for the current SHA until the latest kernel workflow
  completes green.
- The strength of "self-owned" claims beyond the seed/golden trust root.
- Any claim of general OS or arbitrary compiler correctness.

Repaired on this branch:

Misleading `make verify-local` guidance, `README.md` C interpreter layout,
`ROADMAP.md` C-bootstrap language, `SWITCHOVER.md` pending-status language, and
`bootstrap/seed/README.md` pre-switchover/hash-prefix drift, and the missing
`LEDGER.md` reference in `BOOTSTRAP-RESPONSIBILITIES.md`.

Still misleading or stale:

- No currently identified stale truth-surface entry in this audit remains open;
  the next risk is claim precision in kernel PASS prose.

Recommended next autonomous step:

Reduce the next remaining trust-boundary ambiguity: audit the kernel PASS/log
wording for any claim that says KVM or emulator proof happened when the
authoritative workflow did not actually run that substrate.
