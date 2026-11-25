# Herbert Scope

A window to leave open on this computer. It shows the computer's name, how busy its processor is, how much of its
memory is in use, how full its disk is and how warm its drive and processor are, read again once a second, and the
owner's other computers, each with whether it answers, checked every 5 seconds, and, for a computer that runs
[Scope's helper](scope_helper.md), how busy its processor is, how much of its memory is in use, how full its disk is
and how warm its drive is.

```sh
make scope
./build/scope
```

Run it from a terminal inside your graphical desktop. A window 640 pixels wide opens and stays until you close it
with **Escape**, **Q** or the window's close button. It is 552 pixels tall plus 34 for each row of other computers
(586 with one row, 824 with the most, eight), and keeps that size.

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
- **Disk**: how full the disk is that the computer runs from (the one holding `/`), as a percent and a bar, and under
  the bar as, for example, `413.2 GiB free of 936.8 GiB`, to the nearest tenth (in MiB on a disk under 1 GiB). The
  figures are Linux's own (the `statfs` system call), worked out as `df` works them out: the size is all the disk's
  blocks, free is what an ordinary user may still write, and in use is the blocks that are not free at all. Linux keeps
  a few percent of a disk back for the system, which count as neither in use nor free, so the percent is in use over in
  use and free, and `df /` shows the same percent. A disk with no room left for the owner, every free block kept back,
  shows 100 %.
- **Temperatures**: one line at the bottom of the panel, for example `DRIVE 35 C  PROCESSOR 39 C`, in whole degrees
  Celsius, to the nearest, a half rounding up. There is no degree sign: the letters Scope draws have none (see the
  limits). The drive is the computer's NVMe drive, and its figure is the one the drive judges its own limits by (its
  "Composite" temperature). It is drawn
  - in **green** while it is more than 10 °C under the drive's own warning limit,
  - in **amber** from 10 °C under that limit up to it,
  - in **red** (a clear red, `#EF4444`) at the limit or above it.

  The limit is the drive's own (83.85 °C on the owner's drive), compared to a thousandth of a degree, as the drive
  compares it, so 83.849 °C is amber and 83.850 °C red, though both show as 84. A drive that gives no usable limit
  stays green. The processor's figure is drawn in white, with no limits. A figure that cannot be read shows `n/a`, in
  grey, and comes back by itself; a drive or processor that Scope did not find when it started is left out of the
  line.

  Linux keeps these in its hwmon files (`/sys/class/hwmon/hwmon0`, `hwmon1`, and so on), each device's `name` saying
  what it is. Linux may number them differently at each start, so Scope looks through `hwmon0` to `hwmon63` once, when
  it starts, skipping any number that is not there: the drive is the first named `nvme`, the processor the first named
  `k10temp` (AMD), or, without one, the first named `coretemp` (Intel). Each is its `temp1_input`, read again with the
  other figures. The drive's warning limit (`temp1_max`) and critical limit (`temp1_crit`) are read once, at start; a
  limit that is missing, not a plain number, zero or above 200 °C means no limit (the owner's drive gives 65261.85 °C
  for one of its other sensors' limits). The critical limit is read but not drawn: the colours follow the warning
  limit alone.
- **Other computers**: one row for each computer in the owner's list (below), in the list's order: its name alone,
  and to the right what the last check found:
  - **its figures**, for example `CPU 12%  MEM 41%  DISK 7%  DRIVE 31 C`: the computer took the connection and its
    [helper](scope_helper.md) sent its figures. The processor is worked out from two answers 5 seconds apart, as
    this computer's is from two readings, so it shows a dash (`CPU -`) after the first; memory, the disk and the
    drive come from one answer each, the disk's percent and the drive's whole degrees worked out as this computer's
    are. All of it is green but the drive's part, which takes this computer's drive's colours against that drive's
    own warning limit (green, amber within 10 °C under it, red at it or above, grey for `n/a`). A figure the helper
    could not read shows `n/a`, and a computer with no NVMe drive has no `DRIVE` part. These figures are drawn
    smaller than the rest of the row (at most 43 characters, `CPU 100%  MEM 100%  DISK 100%  DRIVE 1000 C`, fit
    before the panel's edge). A helper of the older kind (version 1 of [its line](scope_helper.md#the-line-it-writes))
    sends the processor and memory alone, and its row shows `CPU 12%  MEM 41%`, at the row's full size, as before;
  - **answers**, in green: the computer took the connection, or refused it, and sent no figures;
  - **no answer**, in amber: nothing came back within 2 seconds (it is off, asleep, too far, or a firewall keeps
    quiet);
  - **unreachable**, in amber: the network says there is no way there;
  - **error**, in amber, with what Linux said under it (or `Linux error` and its number when there are no words for
    it);
  - **checking**, in grey, until the first check ends.

  A row keeps showing its last result while the next check is under way. A row whose next check finds anything other
  than the helper's figures (a refusal, silence, a helper that has stopped) shows that instead, and its processor
  starts again from a dash when the figures come back.
- A small light at the top right changes at every reading of the processor, so you can see that the window is
  still working.

Percents are rounded to the nearest whole number, a half upward, exactly, however large the counts: 0.4 % shows as
0 % and 99.5 % as 100 %. A bar is 400 pixels long, four for each percent shown.

When a file cannot be read, or what it says does not make sense, that line says **unavailable** in amber and the
window goes on; the disk does too when Linux will not say how full it is. Each figure comes back by itself when its
file can be read again; the processor shows its dash for a second first.

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
- The **port** is a number 1 to 65535: the port its [helper](scope_helper.md) listens at, for its figures, or any
  other. A port nothing listens on is fine, and often best for a computer without a helper: see below.
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

Every 5 seconds, start to start, Scope knocks on each computer as [knock](knock.md) does: it starts a TCP connection to
the address and port, and closes it again when the computer has said something or 2 seconds have passed, whichever comes
first. It never sends a byte. When the computer takes the connection, Scope keeps it open and reads what the computer
sends, without waiting, until the computer closes it, 256 bytes have come or the 2 seconds are up; only a helper's one
line, followed by the close, gives figures ([the line](scope_helper.md#the-line-it-writes)), and Scope reads it
strictly: anything else shows `answers`. So a computer that takes connections on its port without a helper (an SSH
server, say) shows `answers` once its 2 seconds are up, and is held open that long. A computer that is up answers a
knock at once, either by taking the connection, when a program listens on that port, or by refusing it: the refusal
comes from the computer's own network system, so it proves the computer is there and running just as well. That is why a
refusal shows **answers**, and why a port nothing listens on is a good port to list: no program on that computer sees
the knock or writes it down. Only silence (**no answer**) or the network saying there is no way there (**unreachable**)
means it could not be found. One exception: a firewall on the way, on this computer or between the two, can refuse on
the other's behalf (a "reject" rule), and that refusal shows **answers** too, even while the other computer is off.
Scope cannot tell the two refusals apart, so list a computer this way only when no such rule stands in the path.

The window never waits for a knock. A knock is started and then looked at without waiting; while it is under way,
the window waits on its display and on every knock under way at once, so it wakes for a key, for a knock whose
connection is taken or refused, for bytes or the end of the connection from a computer that took it, for a knock's 2
seconds running out, for the next knock due, or for the next reading, whichever comes first. A computer that never
answers, or a helper that sends its line a byte at a time, holds nothing up: the readings, the light and Escape go on
as before.

## Limits

- For the other computers, whether each answers, and the processor, memory, disk and drive figures of those that
  run the helper; not their processors' temperatures (there is no room in a row). The helper sends two totals for the
  processor (all its time, and the busy part), not each counter, so a counter that goes backwards there cannot be left
  out as it is here: Scope works the percent out from those two, with the same steps as its own.
- At most 6 other computers, IPv4 addresses only, read once at startup. A knock can tell that a computer is there,
  not whether the program you care about on it works.
- The whole processor only: no figure per processor, and nothing on swap or the network. One disk, the one holding
  `/`; another disk, or a part of this one mounted elsewhere, is not shown. One temperature each for the drive and the
  processor, and none for other parts (the graphics, the board).
- No degree sign: Scope's letters (`lib/pixel_text.herb`) have none, and adding one would change what Notes draws for
  that byte in its status line, which its checks hold fixed, so the line says `35 C`.
- Only the first 64 hwmon devices are looked at, and only when Scope starts: a drive added later is not shown until
  Scope is started again. A reading is up to 31 bytes of plain decimal; anything else is `n/a`.
- Reading the drive's temperature makes Linux ask the drive itself, which takes about 3 ms on the owner's computer,
  once a second.
- Linux only, with an X11 or XWayland desktop, like the other Herbert windows. The window is a fixed size; the
  display profile it needs is described in [the First steps guide](first_steps.md). There are no settings and no
  sound, and it writes no files. Besides those in `/proc`, it reads the list of other computers and the hwmon files
  in `/sys/class/hwmon`.
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
under way when the next is due delays it until it ends. These two forms show no disk and no temperatures: the disk
row says `unavailable` and the temperature line is empty, so that the window's picture changes only with the files
the test gives it. `scope --test STAT MEMINFO HOSTNAME MILLISECONDS COMPUTERS EVERY LIMIT HWMON STATFS` also finds the
temperatures under the directory HWMON instead of `/sys/class/hwmon`, and shows the disk holding the path STATFS
instead of `/`; the tests write a stand-in hwmon directory and change its files while the window runs, and turn
STATFS, a link, between disks.

`scope --readings HWMON STATFS` finds and reads the temperatures under HWMON and asks about the disk holding STATFS,
as the window does at its start and at a reading, prints what it found and what the window would then show, one line
each, and exits:

```text
drive-sensor=hwmon1 83850 87850
processor-sensor=hwmon2 k10temp
statfs=245573239 120819101 108326237 4096
disk=54%
disk-bar=216
disk-detail=413.2 GiB free of 936.8 GiB
temperatures=DRIVE 34 C  PROCESSOR 37 C
drive-colour=green
```

`drive-sensor` is the drive's hwmon device and its warning and critical limits in thousandths of a degree (`none` for
no limit), `processor-sensor` the processor's device and its kind (`k10temp` or `coretemp`), each `none` when not
found; `statfs` is the disk's blocks, free blocks, blocks free for an ordinary user and block size, or `unavailable`
when Linux refused; the bar is in pixels; `drive-colour` is `green`, `amber`, `red`, `grey` (for `n/a`) or `none`.

`scope --disk-figures BLOCKS BFREE BAVAIL FRSIZE` puts those four numbers, as `statfs` would give them, through the
steps the disk row takes and prints its three lines (`disk`, `disk-bar` and `disk-detail`, as above), then exits. Each
must be 1 to 20 digits and below 2^64.

`scope --replies FILE [FILE ...]` puts each file's bytes, in order, through the steps one computer's knock puts a
helper's reply through (as much as a knock reads, 256 bytes, counted as the whole reply only when the file ends
before its 256th byte), and prints what that computer's row then shows, one line each, then exits; a row with a
drive's part is followed by a tab and that part's colour (`green`, `amber`, `red`, or `grey` for `n/a`). It knocks on
nothing:

```text
row=CPU -  MEM 75%
row=CPU 40%  MEM 75%
row=CPU 40%  MEM 75%  DISK 54%  DRIVE 74 C<TAB>drive=amber
row=answers
```

`scope --computers [FILE]` reads the list (FILE, or `~/.config/herbert/computers.txt`) as the window would, prints
each row the window would show before any check ends, one line each, then the window's height, and exits. It knocks
on nothing. A line is the row's kind (`computer`, `problem` in amber, or `note` in grey), its main text and its
detail, separated by tabs (written `<TAB>` here). The window draws a problem's or a note's detail under its main
text; a computer's detail is the address and port it is knocked at, which only this line shows (the window shows the
name alone):

```text
computer<TAB>noggin<TAB>192.0.2.5 port 9
problem<TAB>line 3 not understood<TAB>the port must be a number 1 to 65535
height<TAB>620
```

Any other arguments print `scope: usage: scope` and exit with status 1, before a window opens.

## How it is built

The build joins `lib/linux.herb`, `lib/x11.herb`, `lib/pixel_text.herb`, `lib/text.herb`, `lib/net.herb`,
`lib/figures.herb` and `examples/scope.herb` and compiles them with the committed Herbert compiler, as for First
steps. Scope reads `/proc`, the disk and the temperatures with `lib/figures.herb` (the helper reads them with the same
code), knocks with
`lib/net.herb`, builds its text with `lib/text.herb` and draws through its own X11 client; no foreign runtime or
graphics library is linked in.

## Verification

```sh
make hands
make answers
```

`make hands` runs Scope on a display nobody sees, with a home of the check's own so it never reads its owner's list,
and every knock on this computer ([VERIFYING.md](../VERIFYING.md)). Scope must open, stay up and close with status 0
as its owner starts it; with no list, a folder where the list should be, no HOME, a pipe nothing writes into, a list
of 65,537 bytes and a list of every kind of line; knocking on six stand-in computers (a version-2 helper making the
widest row, one sending 257 bytes, one sending an SSH greeting, one dripping a byte every 300 ms, one silent and one
that never answers), where it must never send a byte, give the silent one up at its limit and close within a second of
Escape; and for half a minute reading every 10 ms through files the check turns among the real `/proc`, short,
missing and malformed ones, stand-in temperatures and the disk, while knocking every 20 ms, with the same size, its
memory within 64 KiB, at most one file open and no knock left open. The cases of `make answers`
(`checks/libraries.cases`) hold its arithmetic: the processor and memory figures, percents rounded at their edges, the
disk, the drive's temperature and shade, the sensors found by name, the helper's line written and read back, the reply
reader's verdicts, an empty reply, and the knock library.

Not checked: anything drawn (its figures, colours, rows and light), its many readings of unusual `/proc`, sensor and
list files against hand-written answers, and its knocks' exact timing and system calls. Those were the Python checks',
which are in git at the tag `python-checks-2026-11-25`.
