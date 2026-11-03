# Herbert Scope

A window to leave open on this computer. It shows the computer's name, how busy its processor is and how much of
its memory is in use, read again once a second, and the owner's other computers, each with whether it answers,
checked every 5 seconds.

```sh
make scope
./build/scope
```

Run it from a terminal inside your graphical desktop. A window 640 pixels wide opens and stays until you close it
with **Escape**, **Q** or the window's close button. It is 428 pixels tall plus 34 for each row of other computers
(462 with one row, 700 with the most, eight), and keeps that size.

## What it shows

- **This computer**: the computer's name, from the first line of `/proc/sys/kernel/hostname`, cut at the 64
  characters Linux allows. A name longer than 48 characters is drawn smaller so that it fits.
- **Processor**: how much of the time since the last reading, about a second, the processors spent working, all of
  them together, as a percent and a bar. Linux counts time in the first line of `/proc/stat`, the one labelled
  `cpu`, in counters that only go up. Scope takes the first eight (user, nice, system, idle, iowait, irq, softirq,
  steal; guest time is already inside user and nice). Each counter's rise since the last reading is the time it
  counted; the figure is the rise of all of them but idle and iowait (the time spent waiting for a disk) over the
  rise of all eight. It needs two readings, so it shows a dash for the first second.
- **Memory**: memory in use, as a percent and a bar, and under the bar as, for example, `7.4 GiB of 30.5 GiB in
  use`, to the nearest tenth (in MiB on a computer with less than 1 GiB). In use means `MemTotal` less
  `MemAvailable` from `/proc/meminfo`: what programs could still be given without swapping does not count, so caches
  Linux can drop are not in use.
- **Other computers**: one row for each computer in the owner's list (below), in the list's order, with its name,
  under it its address and port, and to the right what the last check found:
  - **answers**, in green: the computer took the connection, or refused it;
  - **no answer**, in amber: nothing came back within 2 seconds (it is off, asleep, too far, or a firewall keeps
    quiet);
  - **unreachable**, in amber: the network says there is no way there;
  - **error**, in amber, with what Linux said under it (or `Linux error` and its number when there are no words for
    it);
  - **checking**, in grey, until the first check ends.

  A row keeps showing its last result while the next check is under way.
- A small light at the top right changes at every reading of the processor, so you can see that the window is
  still working.

Percents are rounded to the nearest whole number, a half upward, exactly, however large the counts: 0.4 % shows as
0 % and 99.5 % as 100 %. A bar is 400 pixels long, four for each percent shown.

When a file cannot be read, or what it says does not make sense, that line says **unavailable** in amber and the
window goes on. Each figure comes back by itself when its file can be read again; the processor shows its dash for
a second first.

## The list of other computers

Scope reads the list from `~/.config/herbert/computers.txt` (that is, `$HOME/.config/herbert/computers.txt`) once,
when it starts: after changing the list, close Scope and start it again. The list lives on the owner's own computer,
not in this repository. One computer a line, its name, address and port, separated by spaces or tabs:

```text
# My other computers (these addresses are examples).
noggin    192.0.2.5     9
attic     198.51.100.20 22
```

- The **name** is what the row shows: 1 to 24 characters, ASCII only, with no spaces.
- The **address** is an IPv4 address, four numbers 0 to 255 joined by dots, as [knock](knock.md) reads it. Names
  such as `noggin.local` are not looked up.
- The **port** is a number 1 to 65535. A port nothing listens on is fine, and often best: see below.
- A line whose first word starts with `#` is a comment, and blank lines do not count. A comment cannot follow a
  computer on its line. Lines may end in a carriage return and a newline (as Windows writes them), and the last line
  needs no newline.
- At most 6 computers.

Nothing in the list is skipped without a word. A line Scope cannot use becomes a row in amber, for example
`line 4 not understood`, with the reason under it (the line needs three words; the name, the address or the port is
not as above), and each computer past the sixth one too (`line 9: more than 6 listed`). The rows are at most eight:
the computers first, then the problems in the list's order, and when the problems do not fit, the last row says how
many more there are and the line of the first of them (`and 3 more problems from line 8`). With no list, or a list
with no computers in it, the section shows one grey row, `none listed`, saying where to list them. A list that
cannot be read (it is not an ordinary file, Scope may not read it, or it is larger than 64 KiB) shows one amber row,
`could not read the list`.

## How a check works, and why a refusal counts as an answer

Every 5 seconds, start to start, Scope knocks on each computer as [knock](knock.md) does: it starts a TCP connection
to the address and port, and closes it again when the computer has said something or 2 seconds have passed, whichever
comes first. It never sends a byte. A computer that is up answers a knock at once, either by taking the connection,
when a program listens on that port, or by refusing it: the refusal comes from the computer's own network system,
so it proves the computer is there and running just as well. That is why a refusal shows **answers**, and why a port
nothing listens on is a good port to list: no program on that computer sees the knock or writes it down. Only
silence (**no answer**) or the network saying there is no way there (**unreachable**) means it could not be found.

The window never waits for a knock. A knock is started and then looked at without waiting; while it is under way,
the window waits on its display and on every knock under way at once, so it wakes for a key, for a knock that ends,
for a knock's 2 seconds running out, for the next knock due, or for the next reading, whichever comes first. A
computer that never answers holds nothing up: the readings, the light and Escape go on as before.

## Limits

- For the other computers, only whether each answers: how busy each of them is comes next (below).
- At most 6 other computers, IPv4 addresses only, read once at startup. A knock can tell that a computer is there,
  not whether the program you care about on it works.
- The whole processor only: no figure per processor, and nothing on swap, disks or the network.
- Linux only, with an X11 or XWayland desktop, like the other Herbert windows. The window is a fixed size; the
  display profile it needs is described in [the First steps guide](first_steps.md). There are no settings and no
  sound, and it writes no files. The list of other computers is the one file it reads besides those in `/proc`.
- Readings are about a second apart, plus the few milliseconds a frame takes to draw. It is not a clock.
- A counter in `/proc/stat` that goes backwards between two readings, as iowait can, counts no time for that
  interval. If two readings count no time at all, the figure stays as it was rather than dividing by zero. The
  counters start again only when the computer does, which ends Scope too; if their total ever went backwards
  anyway (only test files can do that), the processor shows a dash for one interval and goes on from there.
- Each file is read a byte at a time through one 4096-byte buffer, keeping only the numbers wanted and none of the
  lines, so the number of processors and the length of other lines do not matter. Only the first 1 MiB of a file is
  looked at: a figure's line must end within it, with a newline or with the end of the file, or the figure is
  unavailable. In Linux's own files the figures are at the top. The name is read only as far as its 64th byte.
- The list is read only if it is an ordinary file, and opened so that a file that is really a pipe cannot hold
  startup; only its first 64 KiB and one byte more are ever read.
- Everything Scope uses is made once when it starts and reused for every frame and every knock, so it does not grow
  while it runs; the check below holds it to that at a hundred times its normal rate of readings and 250 times its
  rate of knocks. Herbert still never gives memory back, so this rests on Scope allocating nothing after it starts.

## What comes next

The next piece shows how busy each of the other computers is, as this one's processor and memory are shown now.

## Test modes

These are for the tests; the window itself takes no arguments.

`scope --sample STAT1 STAT2 [STAT3 ...] MEMINFO HOSTNAME` reads two or more processor samples in order, one
memory file and one name file, puts them through the same steps as the window and prints what the window would then
show, then exits:

```text
stat1=10000 1500
stat2=11000 1900
meminfo=16384000 4096000
host=test-host
processor=40%
processor-bar=160
memory=75%
memory-bar=300
detail=11.7 GiB of 15.6 GiB in use
```

`stat1`, `stat2` and so on are each sample's total (its first eight counters) and busy (the total less idle and
iowait), `meminfo` is `MemTotal` and `MemAvailable` in KiB, the two bars are their lengths in pixels, and a file that
cannot be used says `unavailable`; for memory that includes a `MemTotal` of zero.

`scope --test STAT MEMINFO HOSTNAME MILLISECONDS` opens the window but reads those files every MILLISECONDS (1 to
60000) instead of the files in `/proc` every second. `scope --test STAT MEMINFO HOSTNAME MILLISECONDS COMPUTERS EVERY
LIMIT` also reads the list of other computers from COMPUTERS instead of `~/.config/herbert/computers.txt`, and knocks
on each every EVERY ms with a time limit of LIMIT ms (each 1 to 60000) instead of every 5 seconds with 2. A knock still
under way when the next is due delays it until it ends.

`scope --computers [FILE]` reads the list (FILE, or `~/.config/herbert/computers.txt`) as the window would, prints
each row the window would show before any check ends, one line each, then the window's height, and exits. It knocks
on nothing. A line is the row's kind (`computer`, `problem` in amber, or `note` in grey), its main text and the text
under it, separated by tabs (written `<TAB>` here):

```text
computer<TAB>noggin<TAB>192.0.2.5 port 9
problem<TAB>line 3 not understood<TAB>the port must be a number 1 to 65535
height<TAB>496
```

Any other arguments print `scope: usage: scope` and exit with status 1, before a window opens.

## How it is built

The build joins `lib/linux.herb`, `lib/x11.herb`, `lib/pixel_text.herb`, `lib/net.herb` and `examples/scope.herb` and
compiles them with the committed Herbert compiler, as for First steps. Scope reads `/proc` with Linux system calls,
knocks with `lib/net.herb` and draws through its own X11 client; no foreign runtime or graphics library is linked in.

## Verification

```sh
make check-scope
```

`make check-hosted-apps` runs the same checks (`bootstrap/tests/check_scope.py`), and so do `make verify-local`
and CI. Every run of Scope in them has a home directory of the check's own, so none can read the owner's list, and
every knock goes to an address in 127.x on this computer, to listeners and ports the check opens. First `--sample`
runs on fixed files and every printed line must match an answer written by hand: one and
64 processors, an 18 KB line, a cpu line across two reads or after a 20 KB line, tabs, old kernels' four counters,
guest, irq, softirq, steal and iowait each in its place, `meminfo` fields missing, reordered, repeated, look-alike
or malformed, files at the 1 MiB bound, and the edges: 0 %, 100 %, half a percent and 99.5 % exactly, also with
counts past 2^56, a zero-length interval after a figure, counters that did not move, a counter that went back,
totals that went back, numbers at and past 2^64, tenths that carry, and missing or empty files. Then `--computers`,
with the network closed to it (strace makes every request for a socket fail), on 86 lists, each line it prints
against an answer written by hand: comments, blank lines, tabs, CRLF, no final newline, names of 1, 24 and 25 bytes
and of every printable mark, bytes that are not printable ASCII, lines of one, two and four words, every malformed
address and port knock refuses, the edges of each, 6, 7 and 8 computers, more problems than rows, line 40,000, empty
lists, a list of exactly 64 KiB and one byte more; then a missing list, a dangling link, a directory, a FIFO and a
link to `/dev/zero` (each within 2 seconds), a list it may not read, and the list in HOME, missing, and with HOME
unset or empty. Then, on a private Xvfb display with XTest input: with the real `/proc` the window must draw this
computer's name, a processor figure, and memory figures that match `/proc/meminfo` read just before and after the
frame that shows a new reading, and the two computers listed in its HOME answering (a listener and a closed port);
it must quit on Escape, q, Shift+Q and the close button, with no list, a directory for a list and no HOME. With
`--test`, the light must change at every reading while nothing else changes, and the exact text, inks and bars are
read back from its pixels for known figures, a zero-length interval, MiB and GiB, names of 48 and 60 bytes, files
that vanish (unavailable, in amber) and files that come back. The other computers, read back the same way: a
computer that never answers (a listener whose queue the check fills, so Linux drops every knock in silence) shows
checking while its 10-second knock is under way, while the light still changes at every reading (200 ms) and Escape
closes the window within 300 ms; eight rows of every kind, a row keeping no answer while its next knock is under way,
and the seventh computer never knocked; unreachable, error with Linux's words, and error with a number, made by
strace failing the knocks' connects. Under strace, with knocks every 700 ms and a limit of 300 ms: each computer's
knocks start 700 ms apart, no answer comes only after a look at or past the limit and within 100 ms of it, answers and
refusals are seen within 50 ms, every wait of the window includes the knocks under way, nothing is sent, and a knock
under way at Escape is closed before Scope exits. Last, for 120 seconds it reads every 10 ms through links the check
turns between the real `/proc`, files without a final newline (memory under 1 GiB, a 60-byte name), missing files and
malformed files, while it knocks every 20 ms on a listener, a closed port and the silent listener: its memory may not
grow (the same virtual size throughout, resident memory within 64 KiB), its descriptors stay the same but for knocks
under way (no socket outlives its knock), and at the end the closed port is made silent and the silent listener
starts answering, and both rows must follow.
