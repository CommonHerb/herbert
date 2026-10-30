# Herbert Scope

A window to leave open on this computer. It shows the computer's name, how busy its processor is and how much of
its memory is in use, read again once a second. It is the first piece of a window on all of the owner's computers.

```sh
make scope
./build/scope
```

Run it from a terminal inside your graphical desktop. A 640 by 370 window opens and stays until you close it with
**Escape**, **Q** or the window's close button.

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
- A small light at the top right changes at every reading, so you can see that the window is still working.

Percents are rounded to the nearest whole number, a half upward, exactly, however large the counts: 0.4 % shows as
0 % and 99.5 % as 100 %. A bar is 400 pixels long, four for each percent shown.

When a file cannot be read, or what it says does not make sense, that line says **unavailable** in amber and the
window goes on. Each figure comes back by itself when its file can be read again; the processor shows its dash for
a second first.

## Limits

- This computer only. The other computers come next (below).
- The whole processor only: no figure per processor, and nothing on swap, disks or the network.
- Linux only, with an X11 or XWayland desktop, like the other Herbert windows. The window is a fixed size; the
  display profile it needs is described in [the First steps guide](first_steps.md). There are no settings and no
  sound, and it writes no files.
- Readings are about a second apart, plus the few milliseconds a frame takes to draw. It is not a clock.
- A counter in `/proc/stat` that goes backwards between two readings, as iowait can, counts no time for that
  interval. If two readings count no time at all, the figure stays as it was rather than dividing by zero. The
  counters start again only when the computer does, which ends Scope too; if their total ever went backwards
  anyway (only test files can do that), the processor shows a dash for one interval and goes on from there.
- Each file is read a byte at a time through one 4096-byte buffer, keeping only the numbers wanted and none of the
  lines, so the number of processors and the length of other lines do not matter. Only the first 1 MiB of a file is
  looked at: a figure's line must end within it, with a newline or with the end of the file, or the figure is
  unavailable. In Linux's own files the figures are at the top. The name is read only as far as its 64th byte.
- Everything Scope uses is made once when it starts and reused for every frame, so it does not grow while it
  runs; the check below holds it to that at a hundred times its normal rate. Herbert still never gives memory back,
  so this rests on Scope allocating nothing after it starts.

## What comes next

The next piece adds the owner's other computers to the window, each with whether it answers. That needs Herbert to
reach the network, which it cannot do yet ([ROADMAP.md](../ROADMAP.md)).

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
60000) instead of the files in `/proc` every second. Any other arguments print `scope: usage: scope` and exit
with status 1, before a window opens.

## How it is built

The build joins `lib/linux.herb`, `lib/x11.herb`, `lib/pixel_text.herb` and `examples/scope.herb` and compiles them
with the committed Herbert compiler, as for First steps. Scope reads `/proc` with Linux system calls and draws
through its own X11 client; no foreign runtime or graphics library is linked in.

## Verification

```sh
make check-scope
```

`make check-hosted-apps` runs the same checks (`bootstrap/tests/check_scope.py`), and so do `make verify-local`
and CI. First `--sample` runs on fixed files and every printed line must match an answer written by hand: one and
64 processors, an 18 KB line, a cpu line across two reads or after a 20 KB line, tabs, old kernels' four counters,
guest, irq, softirq, steal and iowait each in its place, `meminfo` fields missing, reordered, repeated, look-alike
or malformed, files at the 1 MiB bound, and the edges: 0 %, 100 %, half a percent and 99.5 % exactly, also with
counts past 2^56, a zero-length interval after a figure, counters that did not move, a counter that went back,
totals that went back, numbers at and past 2^64, tenths that carry, and missing or empty files. Then, on a private
Xvfb display with XTest input: with the real `/proc` the window must draw this computer's name, a processor figure,
and memory figures that match `/proc/meminfo` read just before and after the frame that shows a new reading, and it
must quit on Escape, q, Shift+Q and the close button. With `--test`, the light must change at every reading while
nothing else changes, and the exact text, inks and bars are read back from its pixels for known figures, a
zero-length interval, MiB and GiB, names of 48 and 60 bytes, files that vanish (unavailable, in amber) and files that
come back. Last, for 120 seconds it reads every 10 ms through links the check turns between the real `/proc`, files
without a final newline (memory under 1 GiB, a 60-byte name), missing files and malformed files: its memory may not
grow (the same virtual size throughout, resident memory within 64 KiB).
