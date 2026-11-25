# Verifying Herbert

Each command proves only what it runs. Run the checks that cover what you changed; `make verify-local` runs them all:
`make check`, `answers`, `cli`, `hands`, `seeds` and `helper`, each a Herbert program the committed seed builds. The
Python and shell checks that came before them left on 2026-11-25; they are in git at the tag `python-checks-2026-11-25`.

Everything here builds and runs Linux programs, so it needs Linux/x86-64. QEMU-emulated x86-64 Linux (on Apple
Silicon, say) can reproduce a failure but may be too slow for the time limits; CI or real Linux/x86-64 hardware is the
authority. Beyond make, git and coreutils, only `make hands` needs a host tool: Xvfb, the display server.

## make check (seconds)

- Builds the allowlist scanner `tools/scan.herb` with the committed seed (no C compiler is involved) and checks that
  the tracked files whose names do not end in `.herb` match `BOOTSTRAP-ALLOWLIST` exactly, in both directions.
  Adding, removing or renaming such a file needs its allowlist row in the same commit. Before trusting the scanner,
  `checks/scans.herb` (built by the seed too) runs it on 36 checks with hand-written answers, each in a folder of its
  own under `$TMPDIR` (or `/tmp`) that is removed when every check passes: matches, unlisted and stale paths,
  byte-order sorting (bytes above 127 last), CRLF and several CRs, comments, whitespace, duplicates, `.herb`
  look-alikes, a NUL, a path over 4095 bytes, lists larger than its first read (one through a pipe it can read only
  once), and the refusals (status 2, nothing on standard output, a message on standard error) for no argument, two
  arguments, an empty one, and a list or allowlist that is missing or a folder. Each run has 30 seconds (60 for the
  large lists); one that runs past them fails. Ten planted failures, one for each thing its judge can find, keep the
  judge honest.
- Checks that `stack/native_compile_fragment.herb` is exactly the ordered stage files under `stack/compiler/`
  ([docs/COMPILER.md](docs/COMPILER.md)). `make compiler-source` refreshes it; no check regenerates it for you.

## make answers (about 45 seconds): the checks written in Herbert

`checks/run.herb` is the runner. The committed seed builds it, and it holds a compiler (the seed, or
`make answers COMPILER=/absolute/path` for a candidate) to every case in six files:

- `checks/rebuild.cases`: the compiler compiles its own source and what it writes must be the committed seed, byte for
  byte, using at most 128 MiB.
- `checks/first.cases`: fifteen small programs covering the basics, each with the output it must print (three of them
  the native-today examples in `examples/`).
- `checks/language.cases`: 904 cases of what the compiler accepts and refuses: a program with the output, error output
  and exit status it must give, or the exact words the compiler must refuse it in. 588 came from the Python checks'
  conformance corpus. The other 316 were written by hand from [the language guide](docs/LANGUAGE.md)
  for what the Python and shell checks held and these did not:
  - **Memory, output and Linux** (78): the out-of-memory message where a fill's count wraps and where input is larger
    than the heap left (with input that still fits beside it), the heap that cannot be reserved under an
    address-space limit, a result that cannot be written (a full device, a closed output, and a reader gone with the
    pipe signal left to end the program and with it ignored; a number and a string), Linux's sixth argument (a file
    mapped at an offset), its raw errors, and Linux reading into a buffer and writing from inside it; a copy whose
    destination is checked first and whose start or count wraps, and a position or a byte written `0 - 1` in each
    builtin that takes one; a fill and appends that leave a neighbouring buffer whole, bytes shared through an alias
    beside a frozen string that keeps its own, and two million updates of a buffer that take no heap; each of the
    seven byte and Linux builtins refused with an argument short, an argument over, `true` in each argument's place,
    and as a function's name; 300 sums nested to the right and 300 nested calls; input from a closed descriptor and
    3 MiB of input through a pipe; and the word counter's counts on seven inputs.
  - **What the old native-code gates held** (221). The ELF-writing fragment (`stack/native_elf_fragment.herb`) writes
    its exact 4,098 bytes for five input bytes. A compiled program is a static, 64-bit, low-byte-first x86-64 ELF file
    with no loader and no library, one program header and no table of sections; its file ends where its last loaded
    segment ends, and no segment is both writable and executable. Input bytes are added, compared and subtracted as
    unsigned, all six comparisons unsigned past 2^63; `equal` compares bytes past 127 as the bytes they are.
    `if`/`elif`/`else`, `not`/`and`/`or`, a bare `false` printed. Helpers after `main` with non-tail, mutual and tail
    recursion; a two-parameter tail call a million deep and bool tail calls two million deep under a 1 MiB stack the
    program sets itself; non-tail recursion a million deep under 8 MiB ending by the stack signal with nothing written
    (asking Linux for no core image). Twenty parameters, a call on the right of `and` in a return, nested tuples from a
    helper, a 140-word tuple local read at its far end. Arrays of one-, two- and three-word elements and buffers grown
    to 200; arrays of arrays and of buffers through helpers. What `main` renders (15 words at the cap; a quote, a
    backslash and a newline as `\"`, `\\` and `\n`) and what it may not return (ERR 432). Polymorphic functions at int,
    bool and string, at twenty types, in a chain of growing tuples, in a projection cycle and on an unconstrained
    parameter; six instantiations whose types grow refused at once (ERR 441). A never-returning helper at tuple and bool
    results, as an operand of `+` and under other names, stopping the program at the first call that reaches it, and the
    rule's exclusions (ERR 424). `flogger` writing input bytes, an empty string between two writes and strings from six
    sources; a mebibyte arriving whole when Linux takes it in parts (the writer stopped while its pipe is full); a
    `flogger` that cannot write ending with status 1 and no message. `clogger` reading 573,104 bytes through a pipe,
    65,537 and 16,777,216 from a file and 16,777,217 through a pipe, each whole. Bounds checked on all 64 bits: each
    builtin at a position or byte of 2^32 stops with the located message, and division by 2^32 is not division by zero.
    Operators on input (a page-table entry, Adler-32, a product past 2^64, `&` and `^` above 2^32), class mixes of
    operators, `~` on a bool and `not` on an int, builtins refused with three arguments, as values or with the wrong
    types, array element types on rebinding, a refusal's line past 1,000, and 49 more refusals in their exact words. The
    back end's own guards on hand-built code (ERR 416, 418, and ERR 439 for missing NEW_ARRAY metadata), by compiling
    the compiler's stage files (`libs ../stack/compiler/NAME`) in front of a `main` of the case's own: these hold the
    stage files of the checkout the cases are run against, as `make answers` and `make reseed` do.
  - **Publishing and reading** (17). A name bound nowhere is refused. `fwriter` of nothing, called mid-function, three
    times in a row (closing the folder and the temporary each time and leaving no descriptor open), over a link, over
    a second hard link, into a folder named `a.out`, with its error output closed, under umask 077 and 022, in a folder
    it cannot read or write in, past a file-size limit and from eight processes at once; a new file has mode 0644 and
    no execute bits. `stdin_read` of a folder (21), of an empty nonblocking pipe still open (11) or closed (end of
    input), and 65,537 bytes through a pipe.

  Several of these programs run themselves a second time, to give that run a closed input, a pipe or a limit. They
  need `/dev/full`, a pipe with a name made in the runner's folder, stop and continue signals and a hard stack limit
  of at least 1 MiB, and expect not to be run by the administrator.
- `checks/libraries.cases`: 203 cases for the support libraries, each written from the library's documented contract
  before it was run:
  - the text buffer behind Notes (53: edits, the cursor, selection, undo and redo, find, word-wrap rows), saving,
    rescuing and recovering files (31), text and numbers (15), UTF-8, graphemes and what can be drawn (26), Scope's
    figures (8), network addresses, maps, lettering and the Linux helpers (14);
  - what the seed maker stands on (10): SHA-256 checksums against the standard's own examples and against `sha256sum`
    at each side of a block's edge; a folder of the program's own, also under a folder reached through a link, and
    removing a folder with everything under it while what its links point at stays; and running another program to
    its end, with its status, a signal, the time limit and its peak memory, also for a caller whose own input and
    output are closed;
  - making chosen system calls fail on purpose (`lib/fault.herb`, 19): a Linux seccomp filter a program puts on
    itself, or on a new process just before execve. Its own cases: a call named in a rule gives the error chosen and
    is not done, each time, while other calls are done as usual; error 0 makes a call give 0; a rule can test one
    argument, equal to a value or above it, over all 64 bits and unsigned; rules are tried in order, rules added after
    `fault_ready` count once it is called again, and a second filter adds to the first; a filter put on before execve
    holds in the program started; 64 rules fit and one more is refused. Through it: `file_save` failing before its
    rename at a write (28), fchmod (1), fsync (5), the rename (13) or the temporary's close (5) gives that error, the
    same file with its bytes and no temporary left, and after the rename (the folder's fsync, a new document's stat)
    gives 1 with the new bytes in place; a rescue copy and a recovery checkpoint the same way; and the `fwriter`
    routine the compiler emits failing before its rename at getrandom (EIO, ENOSYS or no bytes), the write (no bytes,
    ENOSPC), fsync, close (EIO, or EINTR every time) or renameat gives status 1, `compiler: output publication
    failed`, the old `a.out` and no temporary, and each of its calls interrupted (EINTR) every time is tried again;
  - Notes' files (17): a file's own bytes (CR LF, a byte order mark, U+FFFE, accents, a joined emoji, no final
    newline, exactly the capacity) go through the text buffer and back to disk exactly, and an edit reaches a save, a
    rescue copy and a checkpoint in the file's own newline style; in a CRLF text each newline takes two bytes of the
    capacity and undo and redo stay exact at it; a refused load keeps the style, the text, the cursor and undo, and a
    load taken empties undo and redo; a save, a rescue copy and a checkpoint whose write fails (a file-size limit)
    change nothing; outside changes seen only in the file's times, or after a save left unconfirmed in its bytes, are
    refused; rescue copies never write over a file and give 17 when all 32 names are taken; a file far over the
    capacity is read only to one byte past it; a folder of 1,500 names is scanned over several reads; a FIFO at the
    document's name is refused at once; 160 seeded runs of 300 random edits on wrapped accents, CJK and emoji leave the
    cursor on a character's first byte; a 400-round session at the full capacity, a letter typed and backspaced each
    round, takes no heap and no descriptor, nor do `text.herb`'s readers and writers over 100,000 rounds; UTF-8 is
    stored as RFC 3629's own bytes at each edge; earlier sessions' unusual folders are left as they were; and a
    60,002-byte paste over everything is one undo step;
  - Scope's knocks and replies (10): an empty reply is refused; no drive sensor gives `none`, and a drive reading
    emptied or removed while running reads n/a; an address with a part past 2^64 or an empty last part is refused; an
    Xauthority file whose field claims more bytes than it holds is refused in words that never show its bytes; a map
    ending in a lone carriage return is refused at its place, and Maze's own map is read with all 198 dots reached; a
    reading knock stops at a full 256-byte reply and at its limit (300 to 400 ms for 300), a knock on a computer that
    never answers stops at its limit, each look takes under 50 ms, a computer that sends a line and ends or sends two
    bytes and resets ends the knock answered with its socket closed, and no knock sends a byte; 8,000 rounds of the
    reading knock on a listener, a refusing port and a black hole, then 8,000 with every connect failed at once, leave
    the lowest free descriptor, the size and the resident memory (within 64 KiB) as they were; and a connect failed
    at once with EHOSTUNREACH, EACCES or EBADMSG ends unreachable, error and error, its socket closed.

  No case can mount a disk, so `folder_remove` stopping at one is not held by a case. A case's program runs in the
  runner's scratch folder and may make files there. Nothing in these cases opens a window; the knock cases connect
  only on this computer, to addresses in 127.77.0.0/16 at ports 47700 to 47799 where they listen themselves (the
  knocks leave from 127.0.0.1). They expect an ordinary umask (022, 002 or 077), a user who is not the administrator
  (a mode-000 copy must be unreadable), Linux's seccomp filters (stock Ubuntu and GitHub's runners have them), a
  file clock that moves within 20 ms, and a file system that allows a position past 8 GiB.
- `checks/fragments.cases`: 99 cases in two parts. The first holds the compiler to the large programs written in Herbert
  in `stack/`: the lexer, parser, evaluator and bytecode-machine fragments, each printing its probe's answer as its key
  says; the emitter returning its 482-line bytecode listing as `main`'s string (shown in double quotes, each newline,
  double quote and backslash as an escape: the guide does not say so, the case holds it as the compiler does it); and
  Klondike, the older front end with its own lowerer and bytecode machine, given the compute probe on 5 and on 8 and the
  io probe on `hello`, and reporting each of the 54 malformed programs in `stack/error_probes` with its line and its
  `ERR` code in its own words (five of them a second time with the offending name renamed, so the name in the report is
  seen to come from the input; the codes come from a hand-written list, the words from Klondike's message table as first
  captured); and the surface ledger, `stack/native_surface_ledger.herb`. Klondike is compiled as it is; its `main`
  writes its result and a newline. The second part, the cases named `lexer:`, holds the compiler's own lexer: a tab is
  blank space and a vertical tab and a form feed are not; a name may hold a capital Z and start with an underscore, and
  a `$` straight after a name is no part of it; `[`, a backtick and `{` start no token; an operator followed by `=` or
  by itself (other than `==`, `!=`, `<=`, `>=`, `<<`, `>>`) is two operators; a character literal left open is refused
  with ERR 110 at a newline and ERR 109 at the end of the source; and a source that ends right after a number, a minus,
  an `=` or a `<` gets the parser's refusal, not a fault in the compiler. One case builds the compiler from the
  checkout's source and has it dump (`-- emit: ast-dump`) a source holding every kind of token; it holds the scan only
  that route uses, and fails when that scan changes in the checkout, as under `make reseed`.
- `checks/planted.cases`: two cases that must pass and fifteen failures planted on purpose (a wrong answer, an answer
  one byte short, an output that stops short of its answer, an empty output, a wrong status, a fault, a signal, a
  program that never ends, a refusal in other words, a compiler that writes something else, a compiler held to
  10 MiB). Each planted case names the exact finding the runner must report and passes only on that finding. A runner
  that passed everything would fail all fifteen, and one that failed a case for another reason would fail it too.

A case is plain text: its name, the program (or the file it is in), and its answer; the top of `checks/run.herb` gives
the format, with a form for cases written by hand and a counted form for text of any bytes. A refused case passes when
the compiler ends with status 1, writes nothing to standard output, says exactly the words given and leaves nothing
named `a.out`, not even a link that leads nowhere. Any other case passes when the compiler ends with status 0, prints
its `0` marker, says nothing on standard error and leaves a program: a plain file named `a.out` (not a link) that
starts as a Linux x86-64 program does, and that gives exactly the answer. The runner prints one `FAIL` line for each
case that did not give its answer, with what it gave (its first 400 bytes), then the count. Its exit status is 0 when
every case passed and 1 when one did not. It is 2, with one line on standard error, when the runner could not do its
own work: a cases file it cannot follow, a file a case names that is not there, a compiler that cannot be started, or
a file's closing count of cases that does not match the cases it held. `make verify-local` and CI run it.

What it does not check: the planted cases here run with the real compiler; the findings about a compiler that breaks
its own side (no program, a wrong marker, a program that cannot be started) are planted by `make cli`, which runs the
runner over them with a stand-in compiler. The `memory` field holds a compile's peak, and that counts what the runner
itself holds when it starts the compiler, 16 MiB more for each file of cases read so far, so a ceiling is honest only
in a file listed first; the compiler's tighter ceilings are held by `make cli`. The runner gives a compiler and a
program the stack limit it was started with, 8 MiB as a rule, and no case sets one for a compile (two cases lower a
program's own soft limit to 1 MiB and start it again, to hold that tail calls use no stack): the cases at the nesting
limit (2,000 terms, 1,999 nested ifs) hold the compiler's use of the stack only where that limit is 8 MiB. A program
is also started with signals ignored or not as the runner was; the cases that depend on the pipe signal set it
themselves. Every case gives the compiler its source in a file; `make cli` holds sources through pipes. Of the
compiler's internal ERR 439 guards, only the one for missing NEW_ARRAY metadata is held. What the stack probes never
reach is not held: the lexer probe has no `<<` or `>>`, the emitter probe reaches no slice, no unconditional jump and
no string escape, and the dump shows no line numbers. The word counter's own message for input it cannot read is not
held. The language guide's promise that a call under `do` compiles to the same bytes as that call bound to a name
nothing reads is not held either: the cases hold what such calls do. Through `lib/fault.herb`, these are watched, not
held: that `fwriter` closes its temporary file once only, that an interrupted call or a short read or write then
finishes with the right bytes, and that the filter stops a program that calls Linux the 32-bit way. A fault fails every
call it names alike, never only the second, and cannot make an answer slow or short.

## make hands (about 75 seconds): the window checks written in Herbert

`checks/hands.herb` plays the user's hands. The committed seed builds it, Notes, Scope, Maze, First steps and a stand-in
(`checks/stand_in.herb`). It starts a display nobody sees (Xvfb, on a display number Xvfb picks), opens each program
there, gives its window the keyboard and presses keys through the display's XTEST extension, which the display treats
as presses of its own keyboard. It reads nothing back from the screen: what a person sees with their own eyes is not
checked here. What they would lose is: the bytes on disk, and a program that stops, faults, hangs, leaks or will not
close.

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
- **Notes on a file it must not save over**: one its owner may not write (0464, which its group may), and one another
  program rewrites after Notes opened it. For each, typed into and saved with Ctrl+S, the file must stay as it was
  (its bytes, its inode and its time); Ctrl+Shift+S must then write a private (0600) rescue copy holding the edit; the
  close button, sent by itself, must then ask, with Notes still running at its question; Ctrl+S there must be refused
  too and Ctrl+Shift+S make a second copy; and Y must close Notes with status 0, the file as it was. A writable file
  made read-only (0444) while open must be refused the same way, and saved once it is writable again.
- **Notes opening files with Ctrl+O.** A file it refuses (invalid UTF-8) and a name in a missing folder must leave the
  open file in place: what is typed next is saved there, and the refused file is not written. A CRLF file opened next
  must be saved in its own style; the file before stays untouched, the new file's recovery copy goes in a new folder
  beside it, and the first file's copy stays as it was. A name not yet on disk must be made by Ctrl+S, private. Escape
  must close with status 0, leaving nothing but the files and one recovery folder for each file edited.
- **Notes killed and cut off in the middle of an edit.** Killed (SIGKILL) once the edit reached its recovery copy, the
  file and the copy must both be whole. Cut off from the display (KillClient), Notes must end by itself with a status
  that is not 0, both files whole. After another program changes the file, the copy opened as a document must save
  into itself and leave the file with that program's bytes.
- **Notes where no recovery copy can be made** (its folder set to 0500). Once the folder is writable again, the next
  edit must make the copy with both edits, and Ctrl+S must save them. In such a folder, Ctrl+Q and Y must close with
  status 0 and leave the file as it was. The check knows Notes has handled the first edit by asking Notes for its
  clipboard twice: Notes answers between reading its keys and handling them, and a request is asked again until
  answered.
- **Notes on a line of 4 MiB** (64 bytes short of the limit). Three edits, each saved within 20 seconds as the line
  before with that one change: a mark typed near the end, a mark typed at the start, and 20 characters taken off the
  start, so that megabytes move both ways.
- **Notes' fields filled to their edge.** Find's 64 bytes are filled and a 4-byte character after them must be
  refused; F3 is used again. A seventh digit of Unicode entry must not be taken. Ctrl+S must save only the one
  character the entry adds.
- **Notes' memory through a session.** Twelve rounds, each saved and its file checked: typing, undo and redo, Find and
  F3, Notes' own copy pasted and undone, another program's text pasted and undone, the wheel, a click and a drag,
  Ctrl+S, and Ctrl+O between two files. From the fourth round, every second round: the same virtual size, resident
  memory (Rss in `/proc/PID/smaps_rollup`) within 64 KiB, and as many descriptors.
- **Notes' keys and the clipboard.**
  - With nothing on the clipboard, Ctrl+V pastes nothing.
  - While Notes is stopped, the check sends a request for the clipboard from a window that is gone, Ctrl+C, Ctrl+V,
    300 wheel notches, and 820 keys with the keyboard given to the screen and back. Between the keys come a second
    request from the gone window, a second Ctrl+V, a request from the check's own window, and two changes of the
    keyboard's map that cancel. The display's refusals of Notes' answer to the first request come after all of that,
    so Notes answers the other two first and must still pass the refusals over. Once Notes goes on, every key must
    reach the file in order and nothing be pasted.
  - Stopped again, a map change and Ctrl+V together must paste Notes' own copy once.
  - Requests left by a program that went away must not stop Notes: a window gone, a property that is no name, and
    KeymapNotify events that look numbered. This holds before and after Notes idles four seconds, past 65,536 requests
    of its own.
  - With the check owning the clipboard and never answering, Ctrl+V must give up, and what is typed after it must be
    saved within 6 seconds.
  - A paste of "ok" must go in. A paste with a control character, or one of 70,000 bytes, must be refused whole.
- **Scope**, as its owner starts it: no arguments, this machine's real figures, and one other computer in its list
  (127.0.0.1, port 9, so the knock stays on this machine). It must stay up for six seconds, through its first readings
  and its second knock, and close with status 0 on Escape.
- **Scope's list of other computers.** Scope must open, stay up and close with status 0 with no list (closed with q),
  a folder where the list should be (Shift+Q), no HOME (the close button), a pipe nothing writes into, a list of
  65,537 bytes, and a list of every kind of line, watched for six seconds: a blank first line, a comment, a line not
  understood, a 24-byte name, and seven computers on this machine, the seventh one too many.
- **Scope's knocks.** Scope knocks every half second with a 2-second limit, on six computers the check makes on
  127.88.x.y, ports 47800 to 47899: a version-2 helper whose second line makes the widest row (43 characters) and which
  then stops listening; one that sends 257 bytes; one that sends an SSH greeting and holds the connection open; one
  that drips a line a byte every 300 ms; one that says nothing; and one that never answers (a full listen queue).
  Scope must stay up through two knocks on each and never send a byte, give the silent one up at its limit (1.7 to
  3.5 seconds), and close within a second of Escape pressed while knocks are under way.
- **Scope for half a minute.** Scope reads every 10 ms through links the check turns every tenth of a second among
  the real `/proc`, short, missing and malformed files, stand-in temperature files, and the disk (`/`, its own folder,
  nothing, `/proc`). It knocks every 20 ms (limit 10 ms) on a helper of each version, a silent computer, a refusing
  port, and one that never answers. Every two seconds: the same virtual size and Rss within 64 KiB; at most one file
  open, and at least once none; at most five knocks under way, none of them still open two seconds later. Each
  listener must be knocked 100 times or more. The close button then closes Scope with status 0.
- **Maze** on a small map: into the walls, over every dot, R, then the close button; a second run, Escape. Each must
  leave Maze running until asked, then close it with status 0.
- **First steps.** An arrow held, then Escape: closed within 3 seconds, status 0. A second run, closed by the close
  button. A third run on a second display of its own, which is stopped under it: First steps must end by itself
  within 3 seconds with status 1.
- **The stand-in doing everything right** must pass the stand-in's steps: open, type, save with Ctrl+S, close with
  Ctrl+Q.
- **Seven planted failures**, the stand-in failing on purpose: no window, keys unheard, a file that is not what was
  typed, a signal at its first key (the stand-in marks itself not to be dumped first, so no core file and no crash
  report are made), a Herbert fault at its first key, a window that will not close, and closing right after it saves,
  before it is asked. Each names the exact finding the check must give and passes only on that finding, as the
  runner's planted cases do.
- **Nothing left behind**: the check's folder must hold only what the run made, and the programs' home only Scope's
  list, by its name and with its bytes. And one more planted failure: a file the check puts in that home must be
  found. The checks from "Notes on a file it must not save over" on each work in a folder of their own and remove
  what they made when they pass; a folder that then cannot be removed, because the program left a file there, is a
  failure.

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
ends, however it ends, and with no descriptor past standard error but their own (none the check holds, and none that
whatever started the check left open, so the descriptors counted are the program's). Every program it starts gets a
core limit of one byte: that makes no core file, and Linux then
hands a crash to no crash reporter either (with a limit of 0 it still does). Run it under a soft core limit of 0, not
a hard one: a plain `ulimit -c 0` sets both, the one byte can then not be set, and a program that crashes by a signal
would reach the crash reporter (the stand-in's planted crash never does).

It prints one `FAIL` line for each check that did not give its answer, then the count. Its exit status is 0 when every
check passed, 1 when one did not, and 2, with its reason on standard error (and where its folder is, once it has
one), when it could not do its own work: a program that is not there, a display server that cannot be started, stops
answering or stops during the run, or a program's memory that cannot be read in `/proc` (a display that refuses the
check's connection at the start ends it with `lib/x11.herb`'s message and status 1). Usage is
`hands NOTES SCOPE MAZE FIRST-STEPS STAND-IN UNDER [XVFB]`; it needs Xvfb at `/usr/bin/Xvfb` or that path. It expects
not to be run by the administrator (a 0500 folder must refuse Notes). `make verify-local` and CI run it.

What it does not check: anything drawn (where a click or the wheel puts the cursor, which row Scope shows); a save
refused because the disk is full; whether a save reaches the disk before a power cut; a first fsync of the recovery
copy that fails or is slow; the clipboard's request counting at its exact 16-bit edges, refusals read only after
65,536 requests of Notes' own, and a paste whose question the display itself holds back (another program holding the
display); Scope's figures, its real helper and its malformed one-line replies (the library cases hold their verdicts);
and any program for longer than these seconds. The library cases of `make answers` hold the text buffer, saving and
recovery and Scope's arithmetic.

## make seeds (about 6 seconds): the seed maker's checks, written in Herbert

`make reseed` runs the seed maker, `tools/reseed.herb`: the one program that replaces the compiler's seed
([the seed guide](bootstrap/seed/README.md)). `checks/seeds.herb` holds it to this: it writes a new seed only when
the old seed builds a new compiler that rebuilds itself and gives every answer, and refuses everything else with the
seed and its checksum left as they were. The committed seed builds the seed maker, the check runner, the check and a
stand-in compiler (`checks/seed_stand_in.herb`), a program that copies itself where a compiler would compile and
fails on purpose as its one-line source asks. Each check runs the seed maker on a small checkout of its own (a seed,
its checksum, a compiler's source) and judges how it ended, its words, what the three files hold afterwards and what
it left behind: after a refusal that came once it had made its folder, that folder, a line saying where it is, and
in it the seed, checksum and source as they were; otherwise nothing. Nothing is written in the real checkout. 123 checks
(115 where Linux will not let an ordinary user make namespaces of their own; see "A rename that fails"):

- **A seed that is current** (4): a seed that builds its source into itself is left alone, the stand-in and the real
  seed with the compiler's real source alike, and is never held to the cases: a case that leaves a mark if any
  compiler is run on it is never run. Watched as it runs (inotify: Linux's queue of what is done in a folder, which
  needs no rights), the seed maker opens each of the three files twice, once to use it and once to check it again,
  and writes to none of them.
- **Refused before any compiler runs** (25): a checksum that is another seed's, one with a second line, one without
  its newline and one naming another file; a seed that is a script, and four that are not Linux x86-64 programs by
  one byte (another processor, the processor's number right in its low byte only, 32-bit, high byte first), each
  under its right checksum; a seed, a checksum or a source that is a link, a pipe, not there or a folder (each found
  so afterwards), and the folder `bootstrap/seed`, `bootstrap` or `stack` a link to another; a file of cases whose
  path does not start at the root. Where the seed could run at all, a mark it would leave if it were ever started
  shows that it was not (the stand-in is asked for the mark by its source; the script leaves it itself).
- **A compile that is not clean** (17): a seed that ends with an error status, says something on standard error,
  prints more than its marker, prints no marker, prints its marker without the newline, prints the marker 1 and a
  newline (the right length, the wrong marker), writes no program, leaves `a.out` a link to the program it wrote,
  writes a script, or is stopped by a signal after writing its program; a new compiler that fails, says something on
  standard error, prints more than its marker, writes no program, writes a script or leaves `a.out` a link where the
  seed did not, and one that needs more than 128 MiB.
- **A new compiler that does not rebuild itself** (2: what it writes grows each time, or is of its own length and
  differs from it), one that does not give every answer, cases that cannot be run, and the real compiler failing a
  case in the fourth file of cases.
- **The cases are given the new compiler, not the seed**: a case only the new compiler answers must pass, and the
  new seed is written. Watched as it runs, the seed maker opens each of the three files three times (at the start and
  at each of its two checks) and does nothing to them but put the seed and then its checksum in place, each by one
  rename. With the seed's folder closed to writing the same run must refuse and leave the old pair (not checked when
  the check is run by the administrator, whom Linux lets write anywhere; it says so).
- **A rename that fails** (2): the same run, with the seed maker in namespaces of its own (Linux's private view of
  users and of what is mounted: the same user inside, and nothing it mounts seen outside), where the seed, or its
  checksum, is mounted over itself so that Linux refuses the rename onto it. The seed: the seed and checksum stay as
  they were, the new pair waits in `bootstrap/seed/.reseed.new-NUMBER`, and the run says so. The checksum: the new
  seed is in place under the old checksum, the new checksum waits in that folder, the run's own folder holds the old
  pair, and the run says what to do. Where Linux will not let an ordinary user make such namespaces (Ubuntu's AppArmor
  with `kernel.apparmor_restrict_unprivileged_userns` at 1; CI sets it to 0 first), these two and their six planted
  failures are not run, and the check says so in one line.
- **The checkout changed during the run** (18): the seed, its checksum and the source, each while the compilers ran
  and each while the cases ran, once by a line added and once by its first byte changed, its size as it was; the
  seed's folder made a link to where it was moved, the same files to be found through it, while the compilers ran and
  while the cases ran; and each of the three files made a link to where it was moved, the same bytes to be read
  through it, while the compilers ran, and the source while the cases ran too.
- **A new seed**: the compiler's real source with a line added on top (which moves every line down, and so changes the
  line numbers the compiler keeps for its own fault messages) must give a new seed that is, byte for byte, what the
  check has the real seed build from that source by itself, with its right checksum, both files readable by all
  (0644), nothing else beside them and nothing left behind.
- **Stopped from outside**: the stand-in, as the seed, stops the seed maker with the signal TERM in the middle of its
  compile. The seed maker must end by that signal and say nothing, leave the checkout as it was and its folder
  holding the seed, checksum and source as they were, and the compiler it had started must be killed with it (for
  that one run the check is Linux's subreaper, so it can wait for that compiler and see how it ended).
- **Forty-seven planted failures**: a finished run is judged again with one thing wrong on purpose, in the answer
  expected or in what the run left, once for each thing each judge can find and once more for each other way it can
  come to find it: the run's judge 23 (three for the folder left, four for what must be found where a file was
  twisted), the stopped run's 12, the watched runs' 6 and the failed renames' 6. Each passes only on exactly that
  finding. Each return line and each `or` of the four judges, taken out one at a time, makes the check fail.

The check works in a folder it makes, `herbert-seeds-NUMBER` under `$TMPDIR` (or `/tmp`); a run in which every check
passed removes it, and a run with a failure leaves it, each check's small checkout and output in a numbered folder,
and says where. `$TMPDIR` may be a link and may hold spaces; a line break in its name ends the check at once with
status 2. It prints one `FAIL` line for each check that did not give its answer, then the count; status 0, 1, or 2
when it could not do its own work. `make verify-local` and CI run it.

What it does not check, because no check here can make it happen: a write or a sync that fails while the new seed is
put in place (those need system calls made to fail, and the compilers make the same calls), and a run cut off between
the two renames (it leaves what the failed second rename leaves, which is checked, and a seed under another seed's
checksum is the first refusal above); that the bytes it checked are the bytes it runs, beyond each file being opened
once at the start (two reads through one opening would pass); that the seed maker's own writes refuse a link or a
file already there (they go into folders it has just made); a compile that runs past its two minutes; a file that
grows while it is read, and one over 64 MiB; one of the three files made a pipe or a folder, rather than a link,
during the run; the seed maker started with its own standard input, output or error closed; the check runner stopped
with the seed maker (it gets the same death signal as the compiler, which is checked); and anything changed between
its last look at the checkout and the two renames, which is why it wants to be the only writer. A program the check
runner had started may run on until its own time limit. Two limits of the check itself: another program that opens
the three files while the two watched runs go (an indexer watching `$TMPDIR`, say) makes them fail, and a machine out
of inotify instances ends the check with status 2.

## make cli (about a minute): the compiler's command-line checks, written in Herbert

`checks/cli.herb` starts the compiler itself (a copy of the seed, or `make cli COMPILER=/absolute/path`), in states
the runner never sets up, and holds it to `docs/LANGUAGE.md` sections 4(e), G9, G11 and 8. 44 checks:

- **Publishing `a.out`**: a good compile writes a plain-file x86-64 program, mode 0644 under umask 022 and 0600 under
  077; it replaces a plain `a.out` (its old 0755 mode reset), a link (what it pointed at untouched) and a second hard
  link (which keeps the old bytes); 32 compiles of two programs, 8 at a time, in one folder: every look finds `a.out`
  there, the old file or one whole program.
- **Keeping the old `a.out`**: a lexical, a structural and a native refusal; and a publication that fails, with status
  1: a folder named `a.out` (another writer's temporary left alone), a folder the compiler cannot read or cannot
  write in (not checked as the administrator), and a file-size limit below the program's size (its temporary
  removed).
- **Standard input it cannot read** (closed 9, a folder 21, an empty nonblocking pipe still open 11): exact words and
  status 1, with `a.out` absent, plain with a second hard link, or a link to a file with a second hard link, and left
  unchanged down to its times.
- **A marker it cannot write** (standard output closed, full, or a pipe whose reader has gone, with the pipe signal at
  Linux's own way): the whole program published, its words, status 1 and not a signal.
- **Pipes**: the source through a nonblocking pipe, and through a pipe in 4,096-byte pieces (the compiler's own source,
  and a 270 KB source refused at line 5,002), gives what a file gives.
- **The ast-dump route**: alone, a known tree, and over the compiler's own source.
- **Five memory shapes**: 2,000 calls, 2,000 tuple projections, 2,000 array operations with a buffer, and 200 and 500
  locals across as many branches. Each compiles within 128 MiB (64 MiB for 500) and runs within 128 MiB with its
  answer, under a 4 GiB address-space limit, 20 seconds of processor and 30 in all.
- **The runner's 19 planted cases**, run with a stand-in compiler (the check itself, run with no arguments): a compile
  past 60 seconds; an error status; words on standard error; a marker without its newline, with a carriage return, or
  missing; no program; a script; a link; a program whose ELF header is wrong at any byte the runner reads; a program
  Linux will not start; a signal; and a refusal that leaves a link named `a.out` that leads nowhere.
- **Seven planted judge checks.**

The `fwriter` failures (getrandom, a write, fsync, the temporary's close, the rename, and every interrupted call tried
again) are held by the `lib/fault.herb` cases of `make answers`, not here. The check works in a folder it makes,
`herbert-cli-NUMBER` under `$TMPDIR` (or `/tmp`), removed when every check passes and left, with where it is, when one
fails. It prints one `FAIL` line for each check that did not give its answer, then the count; status 0, 1, or 2 when it
could not do its own work. `make verify-local` and CI run it.

What it does not check, because it needs the system calls watched: that a call interrupted once, or a temporary name
taken once, is tried again and the publication still ends with the whole program; writes or getrandom reads cut short
that still end in a whole `a.out`; that the temporary's descriptor is closed exactly once; the temporary's exact open
flags and mode; and that `fwriter` gives back rbx, r12 and r13 as it found them (no compiled code uses them today).
Nor is `fwriter`'s code compared with the readable reference the Python check kept (at the tag): a slip that changes
what no case can see, such as a test made against the wrong register, shows only if it changes what a case does. The
compiler carries the same routine, so such a slip also changes the compiler's own bytes, and `make reseed` refuses a
compiler that does not rebuild itself.

## make helper (about 9 seconds): Scope's helper's checks, written in Herbert

`checks/helper.herb` starts Scope's helper (`build/scope-helper`, built by the committed seed) on this computer only.
The helper listens at 127.77.0.9, every client the check makes is bound to an address of its own in 127.77.0.0/16, and
the port is the first free one from 47700 to 47799. The helper runs for weeks on another of the owner's computers, and
it is held to what would cost him something:

- From each of the four addresses it was given, a client gets one whole line that Scope takes, then the end. A client
  gets the end without a byte when it comes from two addresses differing in the last part, from the helper's own
  address, or from one differing in the third part. Its port at two other addresses is refused, and between
  connections it holds one socket.
- Started as on his other computer (`scope-helper ADDRESS PORT ALLOWED...`, reading this computer's own `/proc`), with
  its open files limited to four so every accept fails: it keeps running, uses at most 5 ticks of processor time and
  pauses at least 5 times in 1.5 seconds. Once the limit is raised, the waiting client gets a line with this
  computer's processor and memory figures within a second. A client from 127.77.0.2 then gets the end without a byte:
  the helper was given 127.1.0.2, which differs from it only in its second part (that address is only a number on its
  command line; nothing connects there).
- With Linux failing its every accept as when a client gives up first (ECONNABORTED, through `lib/fault.herb`), it
  keeps running, uses at most 5 ticks and pauses at least 5 times in 1.5 seconds.
- A client from an allowed address shuts its end and resets while the helper is stopped. Once the helper goes on, it
  is still running and the next client gets its line.
- 64 clients that connect and never read hold nothing up: ten more are each answered within half a second, its
  descriptors are back as they were within 2 seconds, and each of the 64 then finds its whole line.
- 20,000 connections, one in five from an address it was not given, each allowed one reading `/proc`, the disk holding
  `/` and a stand-in drive. Every one gets what it should, and its size, resident memory (within 64 KiB) and open
  descriptors stay as they were.
- Asked to stop (signal 15), in each of its three runs, it ends by that signal within a second, having written
  nothing.
- At a port another program listens at, it ends within a second with status 1 and nothing on its output.

The check works in a folder it makes, `herbert-helper-NUMBER` under `$TMPDIR` (or `/tmp`). A pass removes it; a
failure leaves it, with what each start of the helper wrote, and says where it is. It prints one `FAIL` line for each
check that did not give its answer, then the count; status 0, 1, or 2 when it could not do its own work.
`make verify-local` and CI run it.

What it does not check: the flags of each accept and send (non-blocking, close-on-exec, no wait, no pipe signal), and
that a connection is never read, which need the system calls watched; an accept failed by a signal (EINTR), which
takes the same branch as the two failures it makes; and the command lines it refuses with status 2.

## make verify-local

It runs `check`, `answers`, `cli`, `hands`, `seeds` and `helper`: every check above, in about four minutes. `make
reseed` asks for it after a new seed. Two things are not run by any check: `make program` (its own guards are in its
recipe, [docs/BUILDING.md](docs/BUILDING.md)) and `make reseed` itself, which `make seeds` runs on small checkouts of
its own.

## Bite proofs

A check that cannot fail proves nothing, so each check carries failures planted on purpose, and each planted failure
passes only on exactly the finding it plants: the runner's fifteen (`checks/planted.cases`) and nineteen more that
`make cli` plants with a stand-in compiler, beside its seven for its own judge; the scanner's ten; the seed maker's
forty-seven; the window check's eight. Every case and check written to replace the Python and shell checks was also
shown to fail on a one-line fault planted in the code it holds, and the faults the old checks refused were tried on
it. `make answers COMPILER=/absolute/path` and `make cli COMPILER=/absolute/path` hold another compiler, such as an
old seed or a mutant, to the same cases.

## CI

`.github/workflows/check.yml` runs on every push and pull request, on `ubuntu-26.04`. It installs make and Xvfb, logs
the OS and their versions, lets unprivileged users make private namespaces (Ubuntu's AppArmor stops them by default,
and the seed maker's checks need them), then runs `make check`, `answers`, `hands`, `seeds`, `cli` and `helper`: all of
`verify-local`. The runner image is not a lock on every package; the logged versions identify each run's
environment. What a failed check leaves under `/tmp` is packed and uploaded as `hosted-application-evidence`, also when
the run fails.

## What these commands do not prove

- That the compiler is correct for arbitrary programs.
- The seed's original provenance. The seed's lineage began with a compiler made by the retired C interpreter;
  reproducing the seed shows consistency and determinism, not an independent origin
  ([bootstrap/seed/README.md](bootstrap/seed/README.md)).

They prove the specific behavior each command runs.
