# Herbert Scope's helper

A small program with no window that runs on one of the owner's other computers and tells [Scope](scope.md) how busy
that computer's processor is, how much of its memory is in use, how full its disk is and how warm its drive is. Scope
then shows those figures in that computer's row, where it would otherwise say `answers`.

```sh
make scope-helper
./build/scope-helper 192.0.2.5 47400 192.0.2.10
```

The first address is the one it listens at: one of this computer's own addresses on the network (these addresses
are examples). The number is the port. The rest, one to four of them, are the addresses it answers: the owner's
computer that runs Scope. It runs until it is stopped (Ctrl+C, or `kill`). It is one file with nothing else needed,
so it can be built on the owner's computer and copied to the other one (`build/scope-helper`).

Scope always makes the connection; the helper only waits for one. So a firewall on the owner's computer that stops
every connection the other computer starts toward it does not get in the way. A firewall on the other computer must
let the owner's computer reach the helper's port.

## Listing it in Scope

In the owner's list of other computers (`~/.config/herbert/computers.txt`, see [Scope](scope.md)), list the computer
at the helper's address and port:

```text
noggin    192.0.2.5     47400
```

Scope knocks on it every 5 seconds as on any computer; when the helper answers, the row shows, for example,
`CPU 12%  MEM 41%  DISK 7%  DRIVE 31 C`, in green but for the drive, which takes the colour of this computer's own
drive in Scope: green, amber within 10 °C under the drive's warning limit, red at it or above, grey for `n/a`. The
processor needs two answers, so it shows a dash (`CPU -`) for the first 5 seconds. A computer with no NVMe drive shows
no `DRIVE` part.

## What it does with a connection

- If the connection comes from one of the addresses it was given, it reads `/proc/stat` and `/proc/meminfo` afresh,
  asks Linux how full the disk holding `/` is (`statfs`), reads the drive's temperature, writes one line and closes
  the connection.
- From any other address, it closes the connection at once and writes nothing.
- It never reads from a connection. Nothing that comes over the network is ever looked at, so nothing anyone sends
  can change what it does.

It listens at exactly the address given, never at every address of the computer (unless `0.0.0.0` is what was
given). It writes nothing to disk and logs nothing. A command line it cannot read (an address like `192.0.2.05`, a
port of 0, no allowed address or more than four) prints a line on stderr saying what to write and exits with status 2,
before it touches the network. If it cannot listen (another program has that port, or the address is not this
computer's, for example because the network is not up yet), it prints why, with Linux's error number, and exits with
status 1.

## The line it writes

One line, version 2, the same steps as Scope's own figures (both programs use `lib/figures.herb`):

```text
herbert-scope 2 CPU MEMORY DISK DRIVE
```

- `herbert-scope`, a space, `2` (the version of this line), a space, then four parts, one space between each, and a
  newline. No other spaces, and nothing after the newline.
- **CPU** is two numbers, `TOTAL BUSY`: TOTAL is the sum of the first eight counters on the `cpu` line of
  `/proc/stat` (user, nice, system, idle, iowait, irq, softirq, steal), and BUSY that total less idle and iowait.
  They are counts since the computer started, so Scope needs two of them to work out a percent.
- **MEMORY** is two numbers, `MEMTOTAL MEMAVAILABLE`, from `/proc/meminfo`, in KiB.
- **DISK** is two numbers, `USED FREE`: the blocks of the disk holding `/` that are in use (all its blocks less the
  free ones) and the blocks an ordinary user may still write, as `statfs` gives them. Scope's percent is USED over
  USED and FREE, as for its own disk; the block size cancels out of it, so it is not sent.
- **DRIVE** is two numbers, `READING LIMIT`: the NVMe drive's temperature and its warning limit, in thousandths of a
  degree Celsius, found as Scope finds its own (the first hwmon device named `nvme`, looked for once, when the helper
  starts), LIMIT `0` when the drive gives no usable one. It is the word `none` when the helper found no drive.
- A part that cannot be read or used (Scope's own rules for its own files and disk) is the word `unavailable`
  instead, and shows as `n/a` in Scope; so is a drive reading of 1000 °C (1000000) or more, which no drive means and
  the row has no room for.
- Numbers are plain decimal, from 0 up to 18446744073709551615, with no zero in front of another digit.

For example:

```text
herbert-scope 2 10000 1500 16384000 4096000 124754138 108326237 35850 83850
herbert-scope 2 unavailable 16384000 4096000 124754138 108326237 35850 0
herbert-scope 2 10000 1500 unavailable unavailable unavailable
herbert-scope 2 10000 1500 16384000 4096000 124754138 108326237 none
```

The longest line is 155 bytes with its newline: four numbers of 20 digits, then the disk, whose two numbers together
are below 2^64, so only one can have 20 digits, then `999999 200000`. Scope reads up to 256 bytes; the helper's own
buffer is made that size (155 bytes) when it starts.

Scope reads the line strictly. It uses a reply only when the helper closed the connection after it and the reply is
exactly such a line, with BUSY not above TOTAL, MEMTOTAL not zero, USED and FREE together below 2^64, READING below
1000000 and LIMIT not above 200000 (the helper never writes anything else). Anything else, whether nothing, a
different line, a line without its newline, bytes after it, more than 256 bytes, or bytes that come too slowly to
finish within the knock's 2 seconds, leaves the row showing `answers`, as for any computer that answers. A reply never
makes a row look worse than that.

Scope also still reads version 1, which helpers sent before this one: `herbert-scope 1 TOTAL BUSY MEMTOTAL
MEMAVAILABLE`, the first two parts alone (each a pair or `unavailable`), at most 100 bytes. Its row shows the
processor and memory alone, `CPU 12%  MEM 41%`, as before. A line of any other version (`herbert-scope 3 ...`)
shows `answers`.

## Running it when the computer starts

On a computer with systemd, a user service starts it at boot. Copy `build/scope-helper` to the computer, for example
to `~/scope-helper`, and write this file as `~/.config/systemd/user/scope-helper.service`, with that computer's
address, the port and the owner's computer's address in place of the examples:

```ini
[Unit]
Description=Scope's helper: answers Scope with this computer's processor, memory, disk and drive figures
# Try again for as long as it takes (the network may come up after the service starts).
StartLimitIntervalSec=0

[Service]
ExecStart=%h/scope-helper 192.0.2.5 47400 192.0.2.10
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
```

Then `systemctl --user daemon-reload`, `systemctl --user enable --now scope-helper`, and, so that it starts at boot
before anyone logs in, `loginctl enable-linger` once for that user. `systemctl --user status scope-helper` shows
whether it is running and the line it printed if it stopped. If the address is not up yet when it starts, it exits
with status 1 and systemd starts it again 5 seconds later. Nothing here is installed by the build or by the tests.

## Test mode

`scope-helper --test STAT MEMINFO LISTEN_ADDRESS PORT ALLOWED_ADDRESS [...]` does the same, but reads the files
STAT and MEMINFO instead of `/proc/stat` and `/proc/meminfo`, and reads no disk and looks for no drive (its line
says `unavailable` and `none` for them), so the tests know the exact figures each reply must carry.

`scope-helper --test-all STAT MEMINFO HWMON STATFS LISTEN_ADDRESS PORT ALLOWED_ADDRESS [...]` also looks for the
drive under the directory HWMON instead of `/sys/class/hwmon`, and reads the disk holding the path STATFS instead of
`/`; the tests write a stand-in hwmon directory and change its files while the helper runs.

## Limits

- IPv4 only; one to four allowed addresses. The address check is the only one: the line is not secret (it is four
  pairs of counts), so it is not encrypted, and anyone on the network who can make a connection appear to come from
  an allowed address can read it.
- One connection at a time: each takes the time to read two small files and ask about the disk, well under a
  millisecond, and to read the drive's temperature, which makes Linux ask the drive itself (about 2 ms on the owner's
  computer). A client that connects and never reads holds nothing up, since the line is written without waiting and
  the connection closed.
- The drive is looked for once, when the helper starts, among the first 64 hwmon devices: a drive added later is not
  seen until it is started again. Only the drive's temperature is sent; Scope has no room in a row for the
  processor's.
- If accepting a connection fails (for one, too many files open), it waits a tenth of a second before trying again,
  so it never spins.
- Everything it uses is made when it starts; it allocates nothing afterwards, so it does not grow while it runs.
- Besides `/proc/stat` and `/proc/meminfo` it reads the `name`, `temp1_input` and `temp1_max` files under
  `/sys/class/hwmon`, and asks `statfs` about `/`; a sandboxed service must leave those readable.

## How it is built

The build joins `lib/linux.herb`, `lib/text.herb`, `lib/net.herb`, `lib/figures.herb` and
`examples/scope_helper.herb` and compiles them with the committed Herbert compiler. It talks to Linux with system calls; no foreign runtime is linked in.

## Verification

```sh
make check-scope-helper
```

`make check-hosted-apps` runs the same checks (`bootstrap/tests/check_scope_helper.py`), and so do `make
verify-local` and CI. Every connection in them goes to an address in 127.x on this computer. Malformed command lines
must be refused before a socket is asked for (strace watches), and a socket or port it cannot have must end it with
status 1 and a line saying why. Through `--test`, every `/proc/stat` and `/proc/meminfo` file of Scope's own checks
must give exactly the figures Scope's hand-written answers give for them, `unavailable` parts included, and
`unavailable none` for the disk and the drive; with the real `/proc`, `/sys/class/hwmon` and `/`, the figures must
agree with the files read just before and after, the disk with `os.statvfs('/')` read just before and after (tried
again, up to eight times, since other programs may be writing to the disk), and the drive's part must be there
exactly when the check's own search finds an NVMe drive, with its limit. A probe compiled from `lib/figures.herb`
writes the longest line, 155 bytes, into a buffer of exactly that size, byte for byte what Scope's checks read, and
stops with the range message given one byte less; and it writes every form of the disk and the drive. Through
`--test-all`, with a stand-in hwmon directory: the drive read again at every connection (73.849, 73.850, 83.849 and
83.850 °C, 999.999 and 1000 °C, negative, malformed and missing readings), its limit and the search made at startup
only, limits missing, zero, absurd and at 200 °C, the first of two drives, the drive at `hwmon63` and past `hwmon64`,
and no drive; and the disk holding a link the check turns between `/`, `/proc` and nothing. Connections from four
allowed 127.x addresses get the line; from others, the listening address itself included, a close with not one byte.
Under strace, each connection gets one send that waits for nothing and close, or close alone, and never a read, even
when the client sends bytes first. The same port at other 127.x addresses is refused. Stopped while a connection
lingers on its port, it starts again at once. 64 clients that connect and never read hold nothing up. 20,000
connections, each reading the real `/proc` and `/` and a stand-in drive, leave its size, its memory (within 64 KiB)
and its open files as they were. With every accept failed by strace (too many files, a connection given up, a signal)
it accepts at most 15 times a second, and with a real limit of four open files and a client waiting it uses next to
no processor time, then answers the client once the limit is raised. Last, Scope's window shows its figures: exact
ones from files the check changes (the disk `n/a` and no drive), `answers` once it is stopped; with `--test-all`, the
drive green, amber, red and grey `n/a` as its stand-in reading changes and the disk's percent that of
`os.statvfs('/')`; and with the real `/proc` and `/`, a memory figure that agrees with `/proc/meminfo`, a disk figure
that agrees with `os.statvfs('/')`, and a drive's part when this computer has an NVMe drive.
