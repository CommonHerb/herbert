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
- `checks/language.cases`: 666 cases of what the compiler accepts and refuses: a program with the output, error output
  and exit status it must give, or the exact words the compiler must refuse it in. 588 came from the conformance
  corpus below, which they will replace. 78 were written by hand from [the language guide](docs/LANGUAGE.md) for what
  three other Python checks below held and these did not: the out-of-memory message where a fill's count wraps and
  where input is larger than the heap left (with input that still fits beside it), the heap that cannot be reserved
  under an address-space limit, a result that cannot be written (a full device, a closed output, and a reader gone
  with the pipe signal left to end the program and with it ignored; a number and a string), Linux's sixth argument
  (a file mapped at an offset), its raw errors, and Linux reading into a buffer and writing from inside it; a copy
  whose destination is checked first and whose start or count wraps, and a position or a byte written `0 - 1` in
  each builtin that takes one (`buffer_get`, `buffer_set`, `buffer_fill`, `append`, an array's `get`, a string's
  `index`); a fill and appends that leave a neighbouring buffer whole, bytes shared through an alias beside a frozen
  string that keeps its own, and two million updates of a buffer that take no heap; each of the seven byte and Linux
  builtins refused with an argument short, an argument over, `true` in each argument's place, and as a function's
  name (43 refusals); 300 sums nested to the right and 300 nested calls; input from a closed descriptor and 3 MiB of
  input through a pipe; and the word counter's counts on seven inputs. Several of these programs run themselves a
  second time, to give that run a closed input, a pipe or a limit.
- `checks/libraries.cases`: 157 cases for the support libraries, each written from the library's documented contract
  before it was run: the text buffer behind Notes (53: edits, the cursor, selection, undo and redo, find, word-wrap
  rows), saving, rescuing and recovering files (31), text and numbers (15), UTF-8, graphemes and what can be drawn
  (26), Scope's figures (8), network addresses, maps, lettering and the Linux helpers (14), and what the seed maker
  stands on (10): SHA-256 checksums against the standard's own examples and against `sha256sum` at each side of a
  block's edge; a folder of the program's own, also under a folder reached through a link, and removing a folder
  with everything under it while what its links point at stays; and running another program to its end, with its
  status, a signal, the time limit and its peak memory, also for a caller whose own input and output are closed.
  No case can mount a disk, so `folder_remove` stopping at one is not held by a case. A case's program runs in the
  runner's scratch folder and may make files there; nothing in these cases opens a window or a connection. They
  expect an ordinary umask (022, 002 or 077).
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
writes no program, a wrong marker or a program that cannot be started are exercised by hand, not by a case. The
runner gives a compiler and a program the stack limit it was started with, 8 MiB as a rule, and no case sets one: the
cases at the nesting limit (2,000 terms, 1,999 nested ifs) hold the compiler's use of the stack only where that limit
is 8 MiB. A program is also started with signals ignored or not as the runner was; the cases that depend on the pipe
signal set it themselves. The word counter is held on small inputs (3 MiB of input is read by another case), and its
own message for input it cannot read is not held. The language guide's promise that a call under `do` compiles to
the same bytes as that call bound to a name nothing reads is not held either: the cases hold what such calls do.

## make hands (about 12 seconds): the window checks written in Herbert

`checks/hands.herb` plays the user's hands. The committed seed builds it, Notes, Scope and a stand-in
(`checks/stand_in.herb`). It starts a display nobody sees (Xvfb, on a display number Xvfb picks), opens each program
there, gives its window the keyboard and presses keys through the display's XTEST extension, which the display treats
as presses of its own keyboard. It reads nothing back from the screen: what a person sees with their own eyes is not
checked here. What they would lose is: the bytes on disk, and a program that stops, faults or will not close.

- **Notes**, on a file that is not there yet.
  - First run. Two lines typed (capitals, digits and colons, so Shift too) must be in the recovery copy Notes keeps
    beside the file before anything is saved, and on disk after Ctrl+S, byte for byte. A line typed at the top
    (Ctrl+Home) and Ctrl+S must leave it there with the rest unchanged. Two characters typed must reach the recovery
    copy, and one then deleted with Backspace, sent by itself, must reach it too. Ctrl+Q with that edit not saved must
    ask, and Ctrl+S at its question must save. Ctrl+Shift+S must then write a rescue copy of the text, a `.txt` beside
    the file (so Notes is still running after its last save). Ctrl+Q must close Notes with status 0.
  - Second run, the file opened again. A line typed at the end (Ctrl+End) and not saved must be in this run's recovery
    copy. Each of the three ways to close must ask first while that edit is not saved: Ctrl+Q, Escape, and the window's
    close button (the message a desktop sends for it). At the question a character typed must not be taken into the
    text, and Escape must go back to the text: each time the recovery copy must gain the character typed after Escape
    and not the one typed before it. After the close button's question one more character, typed by itself, must
    reach the copy: the question must not come back. Ctrl+Q and Y must close Notes with status 0, leave the file as it
    was saved and the recovery copy in place.
  - Twice more the file is opened and closed with nothing typed, with Escape and with the close button: each must
    close it with status 0, the file unchanged. Last, the folder must hold the file, the two rescue copies and the two
    runs' recovery folders, each with its one copy, and nothing else.
- **Scope**, as its owner starts it: no arguments, this machine's real figures, and one other computer in its list
  (127.0.0.1, port 9, so the knock stays on this machine). It must stay up for six seconds, through its first readings
  and its second knock, and close with status 0 on Escape.
- **The stand-in doing everything right** must pass the stand-in's steps: open, type, save with Ctrl+S, close with
  Ctrl+Q.
- **Seven planted failures**, the stand-in failing on purpose: no window, keys unheard, a file that is not what was
  typed, a signal at its first key, a Herbert fault at its first key, a window that will not close, and closing right
  after it saves, before it is asked. Each names the exact finding the check must give and passes only on that
  finding, as the runner's planted cases do.
- **Nothing left behind**: the check's folder must hold only what the run made, and the programs' home only Scope's
  list, by its name and with its bytes. And one more planted failure: a file the check puts in that home must be
  found.

A step's keys go to the display together, and the check then waits for the thing itself (the window, the file's bytes,
a name, the program's end) for at most 20 seconds. A program that ends while a file is waited for is the finding at
once, whatever the file holds. The four planted failures that end at a time limit (no window, keys unheard, a wrong
file, will not close) get one second there. Scope's six seconds are the one pause. Two things are not left to timing:

- A click on the close button is not a key, and Notes, handed a click and keys together, takes the keys first, so
  that a key already typed is never read as the answer to a question the click only then asks. So after the click the
  check asks for a rescue copy (Ctrl+Shift+S works at the question too) and goes on when that copy is on disk, which
  says Notes has dealt with the click.
- Before a program is asked to close it is watched for a tenth of a second, so one already on its way out is not taken
  for one that closed when asked. That watch is a guard, not a proof; what catches a Notes that stops after a save is
  the step that needs it again, and after its last save that step is the rescue copy.

The programs get the hidden display and a home of the check's own, never the owner's display, display permission file
or home. The check works in a folder it makes, `herbert-hands-NUMBER` under `$TMPDIR` (or `/tmp`). A run in which
every check passed removes what it made there, each file and folder by its name, and that folder last; a run with a
failure removes nothing, leaves the folder with what the programs and the display wrote (`programs.log`,
`display.log`), and says where it is. The display and the programs are started so that Linux stops them when the check
ends, however it ends, and leave no core files.

It prints one `FAIL` line for each check that did not give its answer, then the count. Its exit status is 0 when every
check passed, 1 when one did not, and 2, with its reason on standard error (and where its folder is, once it has
one), when it could not do its own work: a program that is not there, a display server that cannot be started, stops
answering or stops during the run (a display that refuses the check's connection at the start ends it with
`lib/x11.herb`'s message and status 1). It needs Xvfb at `/usr/bin/Xvfb`, or its path as a fifth argument.
`make verify-local` and CI run it.

What it does not check: anything drawn, the mouse, the clipboard, Find, undo, Delete, opening another file, files that
are not new plain-text ones, a save that must be refused (another program's change, a read-only file, a full disk),
whether a save reaches the disk before a power cut (that needs the system calls watched), Scope's figures, its helper
and its other keys, and either program for longer than these seconds. The library cases of `make answers` hold the text
buffer, saving and recovery and Scope's arithmetic; the Python checks below still cover the rest.

## make seeds (about 6 seconds): the seed maker's checks, written in Herbert

`make reseed` runs the seed maker, `tools/reseed.herb`: the one program that replaces the compiler's seed
([the seed guide](bootstrap/seed/README.md)). `checks/seeds.herb` holds it to this: it writes a new seed only when
the old seed builds a new compiler that rebuilds itself and gives every answer, and refuses everything else with the
seed and its checksum left as they were. The committed seed builds the seed maker, the check runner, the check and a
stand-in compiler (`checks/seed_stand_in.herb`), a program that copies itself where a compiler would compile and
fails on purpose as its one-line source asks. Each check runs the seed maker on a small checkout of its own (a seed,
its checksum, a compiler's source) and judges how it ended, its words, what the three files hold afterwards and what
it left behind: after a refusal that came once it had made its folder, that folder, a line saying where it is, and
in it the seed and checksum as they were; otherwise nothing. Nothing is written in the real checkout. 60 checks:

- **A seed that is current**: a seed that builds its source into itself is left alone, the stand-in and the real
  seed with the compiler's real source alike.
- **Refused before any compiler runs** (17): a checksum that is another seed's, one with a second line, one without
  its newline and one naming another file; a seed that is a script, and four that are not Linux x86-64 programs by
  one byte (another processor, the processor's number right in its low byte only, 32-bit, high byte first), each
  under its right checksum; a seed, a checksum or a source that is a link, a seed that is a pipe, and the folder
  `bootstrap/seed`, `bootstrap` or `stack` a link to another; a file of cases whose path does not start at the root.
  Where the seed could run at all, a mark it would leave if it were ever started shows that it was not (the
  stand-in is asked for the mark by its source; the script leaves it itself).
- **A compile that is not clean** (8): a seed that ends with an error status, says something on standard error,
  prints more than its marker, writes no program, writes a script, or is stopped by a signal after writing its
  program; a new compiler that fails where the seed did not, and one that needs more than 128 MiB.
- **A new compiler that does not rebuild itself**, one that does not give every answer, cases that cannot be run,
  and the real compiler failing a case in the fourth file of cases.
- **The cases are given the new compiler, not the seed**: a case only the new compiler answers must pass, and the
  new seed is written. With the seed's folder closed to writing the same run must refuse and leave the old pair
  (not checked when the check is run by the administrator, whom Linux lets write anywhere; it says so).
- **The checkout changed during the run** (8): the seed, its checksum and the source, each while the compilers ran
  and each while the cases ran; and the seed's folder made a link to where it was moved, the same files to be found
  through it, while the compilers ran and while the cases ran.
- **A new seed**: the compiler's real source with a line added on top (which moves every line down, and so changes the
  line numbers the compiler keeps for its own fault messages) must give a new seed that is, byte for byte, what the
  check has the real seed build from that source by itself, with its right checksum, both files readable by all
  (0644), nothing else beside them and nothing left behind.
- **Eighteen planted failures**: a finished run is judged again with one thing wrong on purpose, in the answer
  expected or in what the run left, once for each thing the judge can find (twice for the folder left: its seed and
  its checksum), and passes only on exactly that finding.

The check works in a folder it makes, `herbert-seeds-NUMBER` under `$TMPDIR` (or `/tmp`); a run in which every check
passed removes it, and a run with a failure leaves it, each check's small checkout and output in a numbered folder,
and says where. `$TMPDIR` may be a link and may hold spaces; a line break in its name ends the check at once with
status 2. It prints one `FAIL` line for each check that did not give its answer, then the count; status 0, 1, or 2
when it could not do its own work. `make verify-local` and CI run it.

What it does not check, because no check here can make it happen: a write, a sync or a rename that fails while the
new seed is put in place, and a run cut off between the two renames (those need the system calls watched; the state
such a cut leaves, a seed under another seed's checksum, is the first refusal above); the order of the two renames;
that the seed maker's own writes refuse a link or a file already there (they go into folders it has just made); a
compile that runs past its two minutes; a file that grows while it is read, and one over 64 MiB; the seed maker
started with its own standard input, output or error closed; and anything changed between its last look at the
checkout and the two renames, which is why it wants to be the only writer. A seed maker stopped from outside leaves its folder
without a word, and a program the check runner had started may run on until its own time limit.

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

It runs `compiler-metadata`, `check`, `answers`, `hands`, `seeds`, `verification-helpers`, `program-contract`,
`test-timeout`, `test`, `error-vocab-native`, `lexer-copy-sync`, `compiler-cli-contract`, `check-desktop`,
`check-app-support` and `check-hosted-apps`. Beyond `make check`, `make answers`, `make hands`, `make seeds` and
`make test`:

- `make compiler-metadata`: compiles and runs 2,000-operation call, tuple and heap programs and 200- and 500-local
  programs with as many conditionals, checking their values and the compiler's peak memory (128 MiB; 64 MiB for the
  500 case) with GNU time. It catches the known quadratic copying regressions; it is not a general linearity claim.
- `make verification-helpers`: tests of the test tooling. `check_verification_helpers.py` checks
  complete compiler and program transcripts, that gates reject failing or noisy compilers even when they emit a valid
  image, that `run_tests.sh` refuses ambient overrides before grading, the refusals and recovery of the shell script
  that made the seed before the seed maker did (`make reseed-shell`, which leaves with the Python checks), and that
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
  logs the actual OS and tool versions, then runs `make check`, `answers`, `hands`, `seeds`, `verification-helpers`,
  `program-contract`, `test-timeout`, `test`, `compiler-metadata`, `check-desktop`, `check-app-support`,
  `check-hosted-apps`, `compiler-cli-contract`, `error-vocab-native` and `lexer-copy-sync`: all of `verify-local`.
  The runner image is not a lock on every package; the logged versions identify each run's environment. Test
  evidence from `/tmp` is packed and uploaded as `hosted-application-evidence`, also when the run fails.

## What these commands do not prove

- That the compiler is correct for arbitrary programs.
- The seed's original provenance. The seed's lineage began with a compiler made by the retired C interpreter;
  reproducing the seed shows consistency and determinism, not an independent origin
  ([bootstrap/seed/README.md](bootstrap/seed/README.md)).

They prove the specific behavior each command runs.
