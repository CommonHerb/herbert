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
- Checks that `stack/native_compile_fragment.herb` is exactly the ordered stage files under `stack/compiler/`
  ([docs/COMPILER.md](docs/COMPILER.md)). `make compiler-source` refreshes it; no check regenerates it for you.
- `bootstrap/tests/run_tests.sh --check-pinned`: the pinned gate and mutation-proof scripts exist and are executable,
  and every `run_*.sh` is run by something (`make test` or its own make target).
- The self-checks of the conformance corpus and the stdin contract (their declarations and oracles), without running
  the compiler.

## make answers (about 10 seconds): the checks written in Herbert

Herbert's checks are being rewritten in Herbert, and no new check is written in Python or shell. `checks/run.herb` is
the runner. The committed seed builds it, and it holds a compiler (the seed, or `make answers COMPILER=/absolute/path`
for a candidate) to every case in five files:

- `checks/rebuild.cases`: the compiler compiles its own source and what it writes must be the committed seed, byte for
  byte, using at most 128 MiB.
- `checks/first.cases`: twelve small programs covering the basics, each with the output it must print.
- `checks/language.cases`: 588 cases of what the compiler accepts and refuses: a program with the output, error output
  and exit status it must give, or the exact words the compiler must refuse it in. They came from the conformance
  corpus below, which they will replace.
- `checks/libraries.cases`: 147 cases for the support libraries, each written from the library's documented contract
  before it was run: the text buffer behind Notes (53: edits, the cursor, selection, undo and redo, find, word-wrap
  rows), saving, rescuing and recovering files (31), text and numbers (15), UTF-8, graphemes and what can be drawn
  (26), Scope's figures (8), network addresses, maps, lettering and the Linux helpers (14). A case's program runs
  in the runner's scratch folder and may make files there; nothing in these cases opens a window or a connection.
  They expect an ordinary umask (022, 002 or 077).
- `checks/planted.cases`: two cases that must pass and thirteen failures planted on purpose (a wrong answer, an answer
  one byte short, a wrong status, a fault, a signal, a program that never ends, a refusal in other words, a compiler
  that writes something else, a compiler held to 10 MiB). Each planted case names the exact finding the runner must
  report and passes only on that finding. A runner that passed everything would fail all thirteen, and one that
  failed a case for another reason would fail it too.

A case is plain text: its name, the program (or the file it is in), and its answer; the top of `checks/run.herb` gives
the format, with a form for cases written by hand and a counted form for text of any bytes. A refused case passes when
the compiler ends with status 1, writes nothing to standard output, says exactly the words given and leaves no
program. Any other case passes when the compiler ends with status 0, prints its `0` marker, says nothing on standard
error and leaves a program that gives exactly the answer. The runner prints one `FAIL` line for each case that did not
give its answer, with what it gave, then the count. Its exit status is 0 when every case passed and 1 when one did
not. It is 2, with one line on standard error, when the runner could not do its own work: a cases file it cannot
follow, a file a case names that is not there, a compiler that cannot be started, or a file's closing count of cases
that does not match the cases it held. `make verify-local` and CI run it.

What it does not check: the planted cases cannot plant a broken compiler, so the findings about a compiler that
writes no program, a wrong marker or a program that cannot be started are exercised by hand, not by a case.

## make test (about 45 seconds)

`bootstrap/tests/run_tests.sh` runs a pinned number of tests (37) with the committed seed; a test silently dropped or
added turns it red. Nothing in it runs C.

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
  the older Klondike driver's front-end vocabulary; the production compiler's own 4xx diagnostics are graded by
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

It runs `compiler-metadata`, `check`, `answers`, `verification-helpers`, `program-contract`, `test-timeout`, `test`,
`error-vocab-native`, `lexer-copy-sync`, `compiler-cli-contract`, `check-desktop`, `check-app-support` and
`check-hosted-apps`. Beyond `make check` and `make test`:

- `make compiler-metadata`: compiles and runs 2,000-operation call, tuple and heap programs and 200- and 500-local
  programs with as many conditionals, checking their values and the compiler's peak memory (128 MiB; 64 MiB for the
  500 case) with GNU time. It catches the known quadratic copying regressions; it is not a general linearity claim.
- `make verification-helpers`: tests of the test tooling. `check_verification_helpers.py` checks
  complete compiler and program transcripts, that gates reject failing or noisy compilers even when they emit a valid
  image, that `run_tests.sh` refuses ambient overrides before grading, the reseed's refusals and recovery, and that
  verifiers relying on Python `assert` refuse to run under `-O`, `-OO` or `PYTHONOPTIMIZE`.
- `make program-contract`: the [`make program` build](docs/BUILDING.md) with the real seed: source locations, retained
  evidence, path and overwrite protection, bad compiler envelopes and a failed publication.
- `make test-timeout`: the repository's portable `timeout` shim (`make test` puts `tools/` first on `PATH`, so hosts
  without GNU `timeout` can still run bounded steps).
- `make error-vocab-native`: the error-vocabulary gate again, plus its mutation proof, which `make test` does not run.
  This is the one `make test` gate that `verify-local` runs a second time.
- `make lexer-copy-sync`: the lexer copies inside other fragments stay in step with `stack/lexer_fragment.herb`.
- `make compiler-cli-contract`: with strace, GDB and GNU binutils, injects open, random, write, fsync, close and rename
  failures and EINTR, forces real short writes, and compares the emitted writer with its readable assembly
  specification. Missing tools fail it. No assembler is involved in the compiler or in re-seeding.
- `make check-desktop`: builds First steps and, on a private Xvfb display, checks pixels, real keyboard events, focus,
  shutdown and memory over sustained updates.
- `make check-app-support`: the map parser, text-buffer models, UTF-8 decoding against the pinned Unicode 18
  grapheme oracle, font geometry, key mapping, LF/CRLF-preserving edits, bounded history, atomic saving, external
  conflicts, rescue and recovery, with syscall fault injection (needs strace). Its Notes endurance case has wall-time
  limits (60 s to ready, 300 s for 2,000 sampled iterations) that are hang guards, not performance bounds. Notes' word
  wrap (the screen rows of `lib/text_buffer.herb`) is checked against `notes_wrap_model.py`, which lays the same text
  out again from the rule: 31 documents of clusters with known boundaries (blanks and tabs at the edge, words of 70 and
  71 columns, CJK, accents, emoji, flags, an Indic conjunct, an accented space, empty lines, CRLF) at widths 1 to 70,
  each with rows remembered every 1, 2 and 32 rows: every row, the row, line and column of every offset, each row's
  last place, positions at each column, rows back and ahead, and Up/Down runs; then 16 runs of 90 random steps of
  edits, undos and redos between lookups, a step often two or three edits at rising or falling places before one
  lookup, with U+0301 typed at and beside places where lines wrap; a line of 15,000 rows, past what the remembered
  rows hold; and the work as a count of rows walked, not a time: a lookup at the end of a 4 MiB line walks its 61,945
  rows once, then an edit there with its lookup, Up, Page Up and Down walks under 300 rows, every answer checked
  against the model too; four short lines after that line do not cost it its remembered rows (stepping back 20 rows,
  Page Up and Notes' own view, copied from `examples/notes.herb`, each under 300); that view after an edit at the
  line's start walks under 300; and on 4 MiB of short lines a lookup walks one row. Then
  `check_text.py` checks `lib/text.herb` through a probe it compiles: its readers and writers against Python's own
  answers (the 2^64 edge, zeros in front, fields, tenths rounded half up), a write past a buffer's end stopping,
  `linux_argument_count`, `and` and `or` stopping early, and no allocation over 300,000 rounds.
- `make check-hosted-apps`: Maze and Notes on private XTest windows: movement, collection, completion and restart;
  typing, navigation, Unicode entry, search, save, reopen, rescue, recovery and editing copies of the project's own
  documents; word wrap, every drawn cell of a wrapped document against the model (ink in each cell holding a
  character, none elsewhere), the selection's cells across a wrap and over a blank hanging at column 70, and clicks,
  Home, End, Up, Down, Page Down, Shift+Down, a drag beside the text, the wheel and the footer, each by the bytes saved
  after a marker, also near the end of a 4 MiB single line; with strace, the visible warning after a failed sync and its retry; plus
  120-second memory checks of
  Maze play and of Notes editing LF and CRLF files. Evidence includes
  screenshots, input history, saved bytes and memory samples. Then `check_scope.py` checks Scope:
  its `--sample` output on 72 sets of fixed `/proc/stat`, `/proc/meminfo` and name files against hand-written answers
  (one and 64 processors, long lines, lines across reads and at the 1 MiB bound, tabs, fields missing, reordered or
  malformed, exact rounding at half a percent and 99.5 % also past 2^56, zero-length intervals, counters that went
  back, numbers past 2^64) and 24 refused command lines; its `--computers` reading of 86 lists of other
  computers (comments, blanks, tabs, CRLF, names at 24 and 25 bytes, every malformed address and port, 6 and 7
  computers, more problems than rows, 64 KiB and one byte more), of files that are not lists (a FIFO and
  `/dev/zero` within 2 s) and of the list in HOME, each line against a hand-written answer, with socket() made to
  fail; its `--replies` reading of 26 runs of well-formed helper replies, 12 of version 1 and 14 of version 2 (the
  disk's percent at its edges, the drive's colour at 73.849, 73.850, 83.849 and 83.850 °C, no drive sensor, n/a, the
  widest row of 43 characters, the longest line of 155 bytes), and 46 malformed version-1 and 43 malformed version-2
  ones (no newline, bytes after it, CRLF, other prefixes and versions, parts missing or extra, stray spaces, leading
  zeros, 2^64, a busy count above the total, a zero memory total, the disk past 2^64, a reading of 1000 °C, a limit
  above 200 °C, an SSH banner, 256 and 257 bytes), each between good ones, every row against a hand-written answer;
  its `--readings` search and reading of temperatures in 62 stand-in hwmon directories (the drive at `hwmon63` and
  past `hwmon64`, gaps, `k10temp` before `coretemp`, look-alike names, limits missing, zero, absurd and malformed, the
  colour at each edge of its bands, rounding at a half degree, 17 readings that are n/a, FIFOs within 2 s), each line
  against a hand-written answer, and this computer's own `/sys/class/hwmon` against a search the check works out; its
  disk arithmetic (`--disk-figures`) on 23 sets of numbers against hand-written answers, up to and past 64 bits in KiB,
  and `--readings` on real paths against `os.statvfs` read just before and after;
  its window's name, figures, inks and bars read back from its pixels, from the real `/proc` (memory against
  `/proc/meminfo` read around the frame of a new reading, the disk against `os.statvfs('/')`) and from files the check
  writes, removes (amber `unavailable`) and restores; the drive's temperature green, amber and red at the edges of its
  bands, n/a in grey, and its sensors and limits read at startup only, from a stand-in hwmon directory changed while
  the window runs; the redraw light changing at every reading; quitting on Escape, q, Shift+Q and the
  close button; the other computers' rows (names alone, nothing drawn under them; answers from a listener and from a
  closed port, checking, no answer from a full accept queue, kept while the next knock is under way, problems, a
  seventh computer never knocked, and unreachable and errors made by strace), with every knock on 127.x and every
  run in a home of the check's own; fake helpers on 127.x, which count every byte Scope sends (none): figures (a
  dash, then 40 %) beside ten malformed replies showing answers knock after knock; version-2 rows read back at scale
  1, the drive green, amber, amber and red at the edges of its bands, grey n/a and left out with no drive, the disk
  n/a and the widest row inside the panel, beside a version-1 row and three malformed replies; and a row dropping its
  figures when its helper is refused or silent and starting its processor again when it comes back; a
  knock that never answers and a helper that drips holding nothing up (the light on time, little processor time,
  Escape within 300 ms); under strace, knocks 700 ms apart, no answer only after a look at its 300 ms limit,
  refusals and a helper's figures seen within 50 ms, a silent listener read only without waiting until its limit,
  waits for POLLOUT while connecting and POLLIN while reading, and the knock under way closed at exit; and 120 seconds
  redrawing every 10 ms through the real `/proc`, missing, malformed and unusual files, with the disk and the
  temperatures read live, knocking every 20 ms on a
  listener, a closed port, a full accept queue and two helpers replying to every knock (versions 1 and 2), with the
  same virtual size
  throughout, resident memory within 64 KiB, no socket outliving its knock and no file left open. `make check-scope`
  runs those checks alone. Then `check_scope_helper.py` checks Scope's helper, on 127.x only: malformed command lines
  refused before any
  socket (under strace) and a socket or port it cannot have ending it with status 1; its version-2 reply for every
  `/proc` file of the `--sample` cases carrying exactly their hand-written figures, in all four shapes, and the real
  `/proc`, `/` (against `os.statvfs`, tried again while other programs write to the disk) and drive agreeing; the
  line's writer through a probe compiled from `lib/figures.herb` (the longest line, 155 bytes, filling its buffer
  exactly and one byte less stopping it; every form of the disk and the drive); with a stand-in hwmon directory, the
  drive read again at each connection at the edges of its bands, at 1000 °C and n/a, its limit and search at startup
  only, no drive `none`, and the disk turned between `/`, `/proc` and nothing; the line only for allowed addresses and
  a close with no byte for others; under strace, one non-waiting send and close per allowed connection, never a read;
  exactly its own address listened at; a restart at once while TIME_WAIT lingers on its port; 64 clients that never
  read holding nothing up; 20,000 connections, each reading `/proc`, `/` and a drive, with the same virtual size,
  resident memory within 64 KiB and the same descriptors; at most 15 accepts a second while strace fails them, and
  next to no processor time at a real EMFILE; and Scope's window showing its exact figures, then `answers` once it
  stops, the drive's colours and the disk against `os.statvfs('/')`, and real figures from the real `/proc` and `/`.
  `make check-scope-helper` runs those checks alone.
  Last, `check_net.py` checks knock (`lib/net.herb`), knocking
  only on 127.x and inside a private network namespace it makes: malformed command lines refused before any socket
  (under strace), the library's own range guard and error classes through a probe it compiles, one knock's system
  calls in order, answered at three loopback addresses (a listener that must receive no byte), refused, no answer at
  a full accept queue within its time limit plus 100 ms and only after a last poll at the limit, strace-injected
  EINTR, late connects, connect results and resets after accept, and 24,000 knocks in one process with the same descriptors,
  virtual size and resident memory within 64 KiB, all of it both through `net_knock` and through the knock that does
  not wait (`net_start`, `net_check`); the reading knock (`net_start_reading`) through a probe against listeners
  that send a line and close, close at once, send 300 bytes, send nothing and reset, with its system calls; where an
  unprivileged network namespace can be made, also
  unreachable and error from its routes and firewall and the memory check with all five outcomes, and otherwise a
  plain "NOT TESTED here" line. `make check-net` runs those checks alone.

Python, GNU time, strace, GDB, binutils, Xvfb, libX11 and libXtst are test tools, never dependencies of the programs.
So is a C compiler, now used only for one stand-in compiler in the reseed tests of `check_verification_helpers.py`.
Verifiers that rely on Python `assert` must run with assertions enabled.

Standalone targets re-run one `make test` gate for diagnosis: `evaluator-native`, `vm-native`, `parser-native`,
`lexer-native`, `klondike-native`, `emitter-native` (each a fragment gate and its mutation proof),
`closed-loop-memory-diet`, `compiler-conformance`, `stdin-contract`, `wordcount`, `hosted-memory-io` and
`stack-headroom`. `verify-local` does not call them. `check-scope`, `check-scope-helper` and `check-net` re-run Scope's,
Scope's helper's and knock's parts of `check-hosted-apps`.

## Bite proofs

A check that cannot fail proves nothing, so the important gates carry a proof that they do fail when they should.

- **Mutation proofs.** Each fragment gate, the aggregate-render gate and the error-vocabulary gate has a
  `_mutation.sh` sibling. A proof first grades the unmutated control green, then breaks one thing
  on purpose in a disposable copy and requires the gate to go red. For the fragment gates the break is one reachable
  rule changed so the program still compiles and runs but produces a wrong value. In `make test` a proof counts only
  when it exits 0 and prints its own `PASS:` line.
- **Harness bites** in `make test` (above), and the noisy and failing compilers that `make verification-helpers`
  (above) feeds the real gates.
- `compiler_cli_contract.py --compiler PATH` qualifies another compiler, such as an old seed or a mutant.

## CI

- `.github/workflows/check.yml` runs on every push and pull request, on `ubuntu-26.04`. It installs the test tools,
  logs the actual OS and tool versions, then runs `make check`, `answers`, `verification-helpers`, `program-contract`,
  `test-timeout`, `test`, `compiler-metadata`, `check-desktop`, `check-app-support`, `check-hosted-apps`,
  `compiler-cli-contract`, `error-vocab-native` and `lexer-copy-sync`: all of `verify-local`. The runner image is
  not a lock on every package; the logged versions identify each run's environment. Test evidence from `/tmp` is
  packed and uploaded as `hosted-application-evidence`, also when the run fails.

## What these commands do not prove

- That the compiler is correct for arbitrary programs.
- The seed's original provenance. The seed's lineage began with a compiler made by the retired C interpreter;
  reproducing the seed shows consistency and determinism, not an independent origin
  ([bootstrap/seed/README.md](bootstrap/seed/README.md)).

They prove the specific behavior each command runs.
