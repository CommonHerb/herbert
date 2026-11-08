# Herbert Scope's helper

A small program with no window that runs on one of the owner's other computers and tells [Scope](scope.md) how busy
that computer's processor is and how much of its memory is in use. Scope then shows those two figures in that
computer's row, where it would otherwise say `answers`.

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
`CPU 12%  MEM 41%` in green. The processor needs two answers, so it shows a dash (`CPU -`) for the first 5 seconds.

## What it does with a connection

- If the connection comes from one of the addresses it was given, it reads `/proc/stat` and `/proc/meminfo` afresh,
  writes one line and closes the connection.
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

One line, the same steps as Scope's own figures (both programs use `lib/figures.herb`):

```text
herbert-scope 1 TOTAL BUSY MEMTOTAL MEMAVAILABLE
```

- `herbert-scope`, a space, `1` (the version of this line), a space, the processor half, a space, the memory half,
  and a newline. One space between parts, no other spaces, and nothing after the newline.
- The processor half is two numbers: **TOTAL**, the sum of the first eight counters on the `cpu` line of
  `/proc/stat` (user, nice, system, idle, iowait, irq, softirq, steal), and **BUSY**, that total less idle and iowait.
  They are counts since the computer started, so Scope needs two of them to work out a percent.
- The memory half is two numbers: **MEMTOTAL** and **MEMAVAILABLE** from `/proc/meminfo`, in KiB.
- A half whose file cannot be read or used (Scope's own rules for its own files) is the word `unavailable` instead,
  and that figure shows as `n/a` in Scope.
- Numbers are plain decimal, from 0 up to 18446744073709551615, with no zero in front of another digit.

For example:

```text
herbert-scope 1 10000 1500 16384000 4096000
herbert-scope 1 unavailable 16384000 4096000
herbert-scope 1 10000 1500 unavailable
herbert-scope 1 unavailable unavailable
```

Scope reads the line strictly. It uses a reply only when the helper closed the connection after it and the reply is
exactly such a line, with BUSY not above TOTAL and MEMTOTAL not zero (the helper never writes those). Anything else,
whether nothing, a different line, a line without its newline, bytes after it, more than 256 bytes, or bytes that
come too slowly to finish within the knock's 2 seconds, leaves the row showing `answers`, as for any computer that
answers. A reply never makes a row look worse than that.

## Running it when the computer starts

On a computer with systemd, a user service starts it at boot. Copy `build/scope-helper` to the computer, for example
to `~/scope-helper`, and write this file as `~/.config/systemd/user/scope-helper.service`, with that computer's
address, the port and the owner's computer's address in place of the examples:

```ini
[Unit]
Description=Scope's helper: answers Scope with this computer's processor and memory figures
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
STAT and MEMINFO instead of `/proc/stat` and `/proc/meminfo`, so the tests know the exact figures each reply must
carry.

## Limits

- IPv4 only; one to four allowed addresses. The address check is the only one: the line is not secret (it is two
  pairs of counts), so it is not encrypted, and anyone on the network who can make a connection appear to come from
  an allowed address can read it.
- One connection at a time: each takes the time to read two small files, well under a millisecond. A client that
  connects and never reads holds nothing up, since the line is written without waiting and the connection closed.
- If accepting a connection fails (for one, too many files open), it waits a tenth of a second before trying again,
  so it never spins.
- Everything it uses is made when it starts; it allocates nothing afterwards, so it does not grow while it runs.

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
must give exactly the figures Scope's hand-written answers give for them, `unavailable` halves included; with the real
`/proc`, the figures must agree with the files read just before and after. Connections from four allowed 127.x
addresses get the line; from others, the listening address itself included, a close with not one byte. Under strace,
each connection gets one send that waits for nothing and close, or close alone, and never a read, even when the
client sends bytes first. The same port at other 127.x addresses is refused. Stopped while a connection lingers on its
port, it starts again at once. 64 clients that connect and never read hold nothing up. 20,000 connections leave its
size, its memory (within 64 KiB) and its open files as they were. With every accept failed by strace (too many files,
a connection given up, a signal) it accepts at most 15 times a second, and with a real limit of four open files and a
client waiting it uses next to no processor time, then answers the client once the limit is raised. Last, Scope's
window shows its figures: exact ones from files the check changes, `answers` once it is stopped, and with the real
`/proc` a memory figure that agrees with `/proc/meminfo`.
