# Verifying Herbert

Each command proves only what it runs. Run the checks that cover what you changed; `make verify-local` is the full
local set. Two of its tests use copies of `docs/LANGUAGE.md` and `docs/BUILDING.md` as sample text, so even a
documents change runs them.

Almost everything here builds and runs Linux programs, so it needs Linux/x86-64, `make check` included: its scanner is
a Herbert program. Only `make test-timeout` and `make lexer-copy-sync` also run elsewhere; `make test` refuses any other
host. QEMU-emulated x86-64 Linux (on Apple Silicon, say) can reproduce a failure but may be too slow for the default
time limits; CI or real Linux/x86-64 hardware is the authority for `make test`.

## make check (seconds)

- Builds the allowlist scanner `tools/scan.herb` with the committed seed (no C compiler is involved) and checks that
  the tracked files whose names do not end in `.herb` match `BOOTSTRAP-ALLOWLIST` exactly, in both directions.
  Adding, removing or renaming such a file needs its allowlist row in the same commit. Before trusting the scanner,
  `check_scan.py` runs it on 36 cases with hand-written answers: matches, unlisted and stale paths, byte-order
  sorting, CRLF, comments, whitespace, duplicates, `.herb` look-alikes, lists larger than its first read (one
  through a pipe), and the refusals (status 2) for a wrong argument count or an input that cannot be read.
- Checks that `stack/native_compile_fragment.herb` is exactly the ordered stage files under `stack/compiler/`, and
  `stack/i386_oracle_fragment.herb` exactly its units ([docs/COMPILER.md](docs/COMPILER.md)). `make compiler-source`
  and `make oracle-source` refresh them; no check regenerates them for you.
- `bootstrap/tests/run_tests.sh --check-pinned`: the pinned gate and mutation-proof scripts exist and are executable,
  and every `run_*.sh` is run by something (`make test`, the kernel suite, or its own make target).
- The self-checks of the conformance corpus and the stdin contract (their declarations and oracles), without running
  the compiler.

## make test (about 45 seconds)

`bootstrap/tests/run_tests.sh` runs a pinned number of tests (37) with the committed seed; a test silently dropped or
added turns it red. Nothing in it runs C or an emulator.

- **Fragment gates.** The seed compiles six Herbert fragments from `stack/` (lexer, parser, evaluator, VM, the Klondike
  semantic driver, emitter), runs each, and compares its output with an independently written answer. The
  aggregate-render gate does the same for the foundational `test_*.herb` programs, with a fence that every such program
  is either graded or has a reason pinned by behavior. Each of these seven has a mutation proof (below).
- **Hosted native-codegen links 1–16 and the reject battery**, graded against committed goldens: a frozen snapshot
  from the retired C bootstrap, not regenerable in this tree.
- **Harness bites.** A `/bin/false` compiler must fail, a compiler whose output is corrupted must be caught, and the
  seed must match its checksum pin (red there means re-seed, see [the seed guide](bootstrap/seed/README.md)).
- **Closed-loop memory diet.** The seed compiles its own source and must reproduce itself byte for byte under a pinned
  memory ceiling.
- **Error-vocabulary gate.** The seed compiles `stack/klondike.herb`, which must report the committed located ERR
  101–316 diagnostics on the 54 malformed probes in `stack/error_probes`: each must match a hand-written manifest of
  codes and the committed golden text, and line-shift and rename checks show the diagnostic follows the input. This is
  the older Klondike driver's front-end vocabulary; the production compiler's own 4xx/5xx diagnostics are graded by
  the reject battery and the conformance corpus.

Then, each through the seed:

- `compiler_conformance.py`: hand-written hosted programs with the exact compiler status, stdout, stderr and artifact
  expected, then the exact output and status of each accepted program. A rejection needs status 1, empty stdout and
  the exact diagnostic on stderr.
- `stdin_contract.py`: `stdin_read` programs and the compiler itself against real closed, directory and
  nonblocking-pipe descriptors. Empty EOF must differ from an empty pipe whose writer is still open; compiler read
  errors must give the exact failure and leave an earlier `a.out` (absent, regular, symlink or hardlink) as it was.
  Python's standard library only. Injected mid-read errors, short reads and the heap-capacity probe are not
  exercised here.
- `compiler_cli_contract.py`: atomic publication of `a.out` across regular files, symlinks, hardlinks, umask, a
  directory in the way, empty files and concurrent compiles. Fault injection is `make compiler-cli-contract`.
  Abrupt termination, hostile changes to the containing directory and power loss after the rename are outside
  this contract.
- `check_hosted_memory_io.py`: the byte-storage builtins and `linux_syscall6` in real programs, with independently
  written expected results, rejections, and memory use under sustained mutation.
- `check_wordcount.py`: the word counter's exact results, binary input, a closed input descriptor and multi-megabyte
  pipe input under a fixed 8 MiB stack.
- `check_stack_headroom.py`: generated 1,950-term and 300-deep programs at an explicit 8 MiB stack; red if the compiler
  loses about a third of its stack headroom.

Failed runs keep their scratch directories and print where; `stdin_contract.py` and `compiler_cli_contract.py` also
keep successful ones with `--keep-work`.

## make verify-local (the full local set)

It runs `compiler-metadata`, `check`, `verification-helpers`, `program-contract`, `test-timeout`, `test`,
`error-vocab-native`, `lexer-copy-sync`, `native-codegen-diagnostics`, `compiler-cli-contract`, `check-desktop`,
`check-app-support` and `check-hosted-apps`. Beyond `make check` and `make test`:

- `make compiler-metadata`: compiles and runs 2,000-operation call, tuple and heap programs and 200- and 500-local
  programs with as many conditionals, checking their values and the compiler's peak memory (128 MiB; 64 MiB for the
  500 case) with GNU time. It catches the known quadratic copying regressions; it is not a general linearity claim.
- `make verification-helpers`: tests of the test tooling. `check_verification_helpers.py` checks
  complete compiler and program transcripts, that gates reject failing or noisy compilers even when they emit a valid
  image, emulator selection that cannot silently skip, honest kernel summaries, raw evidence surviving cleanup, the
  reseed's refusals and recovery, and that verifiers relying on Python `assert` refuse to run under `-O`, `-OO` or
  `PYTHONOPTIMIZE`. `check_debugcon_frames.py` checks the binary-safe kernel trace parser
  ([DEBUGCON-FRAMES.md](bootstrap/tests/DEBUGCON-FRAMES.md)). Three bite proofs run the real Bochs harness against
  stub commands, with no emulator: link 44's retry block (`check_link44_attempts.py`), xvfb-run's own messages kept out of graded
  captures (`check_bochs_xvfb_capture.py`) and an emulator crash after the shutdown banner never graded
  (`check_bochs_emulator_crash.py`); [FLAKE-LOG.md](bootstrap/tests/FLAKE-LOG.md) F12 and F13 say why.
- `make program-contract`: the [`make program` build](docs/BUILDING.md) with the real seed: source locations, retained
  evidence, path and overwrite protection, bad compiler envelopes and a failed publication.
- `make test-timeout`: the repository's portable `timeout` shim (`make test` puts `tools/` first on `PATH`, so hosts
  without GNU `timeout` can still run bounded steps).
- `make error-vocab-native`: the error-vocabulary gate again, plus its mutation proof, which `make test` does not run.
  This is the one `make test` gate that `verify-local` runs a second time.
- `make lexer-copy-sync`: the lexer copies inside other fragments stay in step with `stack/lexer_fragment.herb`.
- `make native-codegen-diagnostics`: a small QEMU diagnostics suite for the emitter, used to enrich kernel mismatch
  logs. It needs QEMU. It is not the kernel boot proof.
- `make compiler-cli-contract`: with strace, GDB and GNU binutils, injects open, random, write, fsync, close and rename
  failures and EINTR, forces real short writes, and compares the emitted writer with its readable assembly
  specification. Missing tools fail it. No assembler is involved in the compiler or in re-seeding.
- `make check-desktop`: builds First steps and, on a private Xvfb display, checks pixels, real keyboard events, focus,
  shutdown and memory over sustained updates.
- `make check-app-support`: the map parser, text-buffer models, UTF-8 decoding against the pinned Unicode 18
  grapheme oracle, font geometry, key mapping, LF/CRLF-preserving edits, bounded history, atomic saving, external
  conflicts, rescue and recovery, with syscall fault injection (needs strace). Its Notes endurance case has wall-time
  limits (60 s to ready, 300 s for 2,000 sampled iterations) that are hang guards, not performance bounds.
- `make check-hosted-apps`: Maze and Notes on private XTest windows: movement, collection, completion and restart;
  typing, navigation, Unicode entry, search, save, reopen, rescue, recovery and editing copies of the project's own
  documents; with strace, the visible warning after a failed sync and its retry; plus 120-second memory checks of
  Maze play and of Notes editing LF and CRLF files. Evidence includes
  screenshots, input history, saved bytes and memory samples. Then `check_scope.py` checks Scope:
  its `--sample` output on 72 sets of fixed `/proc/stat`, `/proc/meminfo` and name files against hand-written answers
  (one and 64 processors, long lines, lines across reads and at the 1 MiB bound, tabs, fields missing, reordered or
  malformed, exact rounding at half a percent and 99.5 % also past 2^56, zero-length intervals, counters that went
  back, numbers past 2^64) and six refused command lines; its window's name, figures, inks and bars read back from
  its pixels, from the real `/proc` (memory against `/proc/meminfo` read around the frame of a new reading) and from
  files the check writes, removes (amber `unavailable`) and restores; the redraw light changing at every reading;
  quitting on Escape, q, Shift+Q and the close button; and 120 seconds redrawing every 10 ms through the real
  `/proc`, missing, malformed and unusual files with the same virtual size throughout and resident memory within
  64 KiB. `make check-scope` runs those checks alone. Last, `check_net.py` checks knock (`lib/net.herb`), knocking
  only on 127.x and inside a private network namespace it makes: malformed command lines refused before any socket
  (under strace), the library's own range guard and error classes through a probe it compiles, one knock's system
  calls in order, answered at three loopback addresses (a listener that must receive no byte), refused, no answer at
  a full accept queue within its time limit plus 100 ms and only after a last poll at the limit, strace-injected
  EINTR, late connects, connect results and resets after accept, and 24,000 knocks in one process with the same descriptors,
  virtual size and resident memory within 64 KiB; where an unprivileged network namespace can be made, also
  unreachable and error from its routes and firewall and the memory check with all five outcomes, and otherwise a
  plain "NOT TESTED here" line. `make check-net` runs those checks alone.

Python, GNU time, strace, GDB, binutils, Xvfb, libX11 and libXtst are test tools, never dependencies of the programs.
So is a C compiler, now used only for one stand-in compiler in the reseed tests of `check_verification_helpers.py`.
Verifiers that rely on Python `assert` must run with assertions enabled.

Standalone targets re-run one `make test` gate for diagnosis: `evaluator-native`, `vm-native`, `parser-native`,
`lexer-native`, `klondike-native`, `emitter-native` (each a fragment gate and its mutation proof),
`closed-loop-memory-diet`, `compiler-conformance`, `stdin-contract`, `wordcount`, `hosted-memory-io` and
`stack-headroom`. `verify-local` does not call them. `check-scope` and `check-net` re-run Scope's and knock's parts of `check-hosted-apps`.

## Bite proofs

A check that cannot fail proves nothing, so the important gates carry a proof that they do fail when they should.

- **Mutation proofs.** Each fragment gate, the aggregate-render gate, the error-vocabulary gate and every kernel link
  from 18 to 67 has a `_mutation.sh` sibling. A proof first grades the unmutated control green, then breaks one thing
  on purpose in a disposable copy and requires the gate to go red. For the fragment gates the break is one reachable
  rule changed so the program still compiles and runs but produces a wrong value. In `make test` a proof counts only
  when it exits 0 and prints its own `PASS:` line.
- **Harness bites** in `make test` (above) and **helper bite proofs** in `make verification-helpers` (above).
- `compiler_cli_contract.py --compiler PATH` qualifies another compiler, such as an old seed or a mutant.

## CI

- `.github/workflows/check.yml` runs on every push and pull request, on `ubuntu-26.04`. It installs the test tools,
  logs the actual OS and tool versions, then runs `make check`, `verification-helpers`, `program-contract`,
  `test-timeout`, `test`, `compiler-metadata`, `check-desktop`, `check-app-support`, `check-hosted-apps`,
  `compiler-cli-contract`, `error-vocab-native` and `lexer-copy-sync`: all of `verify-local` except
  `native-codegen-diagnostics`, which needs QEMU and runs in the kernel workflow. The runner image is not a lock on
  every package; the logged versions identify each run's environment. Test evidence from `/tmp` is packed and
  uploaded as `hosted-application-evidence`, also when the run fails.
- `.github/workflows/kernel-codegen-l1.yml` runs the kernel suite of the paused OS work. A push to `main` or a pull
  request starts it only when the change touches a file that can change the kernel route or its gates: `stack/`,
  `bootstrap/seed/`, the link 17–67 gate and mutation scripts, the `*_ref.py` reference builders, the kernel goldens and
  harness files, `examples/*_long64*`, `tools/*_long64.py`, the `Makefile` and the workflow itself (the full list is in
  the workflow). Otherwise it runs by hand (`workflow_dispatch`), for example
  `gh workflow run kernel-codegen-l1.yml --ref <branch>`. A new run on the same branch cancels the earlier one.
  Eight jobs split links 17–67 (17–32, 33–43, 44–51, 52–55, 56–57, 58–59, 60–61, 62–67). Each installs QEMU and Bochs
  at exact pinned versions from Ubuntu's snapshot service and asserts them (FLAKE-LOG F8 and F14), runs the QEMU
  diagnostics suite, then every gate and mutation proof in its range with `KERNEL_CODEGEN_REQUIRE_EMU=1`, so a missing
  emulator fails instead of skipping. A job runs all its gates even after a failure, records every exit status and
  stays red if any gate fails; each gate has a 25-minute limit with a 60-second grace period. The 60–61 job also
  checks the long64 word counter and ELF inspector ([docs/os-tools.md](docs/os-tools.md)). Results and raw emulator
  streams are uploaded as `kernel-evidence-<lo>-<hi>-<run id>`.

## The kernel suite locally

`make kernel-verify` runs the 51 link gates (17–67) and 50 mutation proofs with `KERNEL_CODEGEN_REQUIRE_EMU=1`, so it
needs QEMU and Bochs; bare per-link scripts may skip an absent emulator. It fails if a required script is missing.
For the links with KVM legs, a present but inaccessible `/dev/kvm` fails its preflight; device availability alone does
not prove a KVM boot. Its summary counts passed gates and proofs and makes no per-emulator claim; read each gate's
captures for that. One link: `KERNEL_VERIFY_LO=67 KERNEL_VERIFY_HI=67 make kernel-verify`. Run it on a quiet machine:
load makes correct but slow boots time out ([FLAKE-LOG.md](bootstrap/tests/FLAKE-LOG.md) F4, F7).

`bootstrap/tests/kernel_ci_group.sh LO HI` runs CI's grouped driver locally. It writes evidence to `_kernel_evidence/`,
or to the absolute directory in `KERNEL_EVIDENCE_DIR`: raw output, feeder logs, configuration, hash and size
inventories with UTC attempt times, gate logs and statuses, emulator versions, source and seed hashes, and the
checkout's revision and diff. Large disk images and executables are inventoried by hash, not copied. A failed capture
keeps its source directory and fails the group at once; evidence from a failed attempt is never replaced by a later
boot's. Without `KERNEL_EVIDENCE_DIR`, a standalone gate only does its ordinary cleanup.

To use a particular QEMU, set `QEMU_PREFIX` (for example `/opt/qemu-10.2.1`) before a gate or `make kernel-verify`.
It must be absolute and contain an executable regular file at `bin/qemu-system-x86_64`; `bootstrap/tests/qemu_prefix.sh`
removes function shadows and checks that command lookup resolves to exactly that path, and every caller fails closed
if the helper or its oracle cannot be loaded. That file must be the real binary or a wrapper that uses `exec`, so
signal status survives.

CI pins Bochs 2.8; a local Bochs may differ (the development machine has 2.7), so local results are kept apart from CI's. The hardened Bochs gates class
harness failures (disk setup, feeder failures, an emulator crash) separately from completed kernel results. Before
calling a red kernel run a flake, read [FLAKE-LOG.md](bootstrap/tests/FLAKE-LOG.md).

## What these commands do not prove

- That the compiler is correct for arbitrary programs.
- A finished operating system.
- The seed's original provenance. The seed's lineage began with a compiler made by the retired C interpreter;
  reproducing the seed shows consistency and determinism, not an independent origin
  ([bootstrap/seed/README.md](bootstrap/seed/README.md)).

They prove the specific behavior each command runs.
