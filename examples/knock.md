# Herbert knock

Asks one computer whether it answers at an address and a port, once, and says what happened. It is the first piece of
networking in Herbert. Its library, `lib/net.herb`, is also what [Scope](scope.md) uses to show whether each of the
owner's other computers answers.

```sh
make knock
./build/knock 127.0.0.1 22
./build/knock 127.0.0.1 22 250
```

The address is IPv4, four numbers 0 to 255 joined by dots; the port is a number 1 to 65535; the last number, if
given, is how long to wait, in milliseconds, 1 to 60000 (a second if not given). It prints one line and exits:

| Line begins | What it means | Exit status |
| --- | --- | --- |
| `answered` | the computer took the connection (if it then reset it, the line says so: `(then connection reset, errno 104)`) | 0 |
| `refused` | the computer is there and said no: nothing takes connections on that port | 3 |
| `no answer` | nothing came back in the time allowed: the computer is off, asleep, too far, or a firewall keeps quiet | 4 |
| `unreachable` | the network says there is no way there (Linux says why) | 5 |
| `error` | anything else (Linux says what) | 6 |

```text
answered: 127.0.0.1 port 22 in 0 ms
no answer: 127.0.0.1 port 4000 in 250 ms
unreachable: 192.0.2.1 port 22 in 0 ms (no route to host, errno 113)
```

A command line it cannot read (an address like `127.0.0.01` or `127.0.0.1 `, port 0, a wait of 0) is refused with a
line on stderr saying what to write instead, and exit status 2, before anything touches the network. Status 1 is left
for Herbert's own faults.

## How a knock works

It opens a connection without waiting on it, waits at most the time allowed for Linux to say how it went, and closes
it again on every path, whatever happened. It never sends a byte: the computer sees a connection open and close.
Linux's own words decide the outcome: a reset before the computer takes the connection is `refused`, and one after it
(the computer took it, then dropped it) is still `answered`; "network is unreachable", "no route to host", "network is
down" and "host is down" are `unreachable`, whether this computer's routes say so at once or a router's message says
so later; silence until the limit is `no answer`. It says `no answer` only after one last look at the limit, so an
answer that came just in time is never missed, and never before the limit.

## Limits

- Addresses only. A name such as `noggin` is not looked up; there is no DNS and no reading of `/etc/hosts`.
- IPv4 and TCP only. No IPv6, no ping.
- An answer means the port took a connection. It says nothing about whether the program behind it works.
- What comes back for a computer that is off depends on the network between: `no answer`, or `unreachable` when a
  router, or this computer's own network, reports that nobody has that address.
- The library, `lib/net.herb`, makes everything a knock needs once, so knocking every few seconds for weeks does not
  grow. Herbert never gives memory back, so this rests on a knock allocating nothing; the check below holds it to that.

## Knocking without waiting

knock waits for its one knock (`net_knock`). A program that must keep going meanwhile, such as Scope's window, uses
the library's other way, with the same rules: `net_start` begins a knock and returns at once, with the outcome when
the knock ended there (this computer can accept or refuse in the call, and a missing route fails in it), or with
"under way". Then `net_check` looks at the knock without waiting, as often as the program likes, and gives the
outcome once there is one, closing the connection. While a knock is under way the program may wait on its socket,
along with anything else it waits for (Scope waits on its display too, with `linux_poll_many` from `lib/linux.herb`),
and `net_left` says how long it may wait at most before looking again, rounded up so that the look after the wait
comes at or after the time limit. `no answer` still comes only from a look that began at or after the limit and found
nothing. `net_stop` gives up a knock under way and closes its connection; Scope does that when its window closes.
One knock at a time per `Net`: starting another first gives up the one under way.

## Reading what the computer sends

`net_start_reading` begins a knock exactly as `net_start` does, and it too never sends a byte. The difference comes
once the computer takes the connection: instead of closing it, the knock keeps it open and reads what the computer
sends into the `Net`'s fixed 256-byte reply buffer, without ever waiting (each look is a `recvfrom` that asks for no
wait, repeated until nothing more is there), until the computer closes the connection, 256 bytes have come, the
connection fails or the knock's time limit passes, whichever comes first; the time limit covers the whole knock,
connecting and reading. The knock is then over, `answered` whatever was read, with how many bytes came (`got`) and
whether the computer closed the connection after them (`closed`): only then are those bytes all it sent. While it
reads, a program waiting on its socket must wait for bytes (POLLIN), not for room to write (POLLOUT), which a
connected socket always has; the state's `events` says which, and `net_left` how long at most. Scope uses this to read
its helper's one line ([Scope's helper](scope_helper.md)); knock itself does not read.

## Test modes

These are for the tests. Each one given the wrong number of arguments prints its own usage and exits 2.

`knock --parse ADDRESS PORT [MILLISECONDS]` prints what the command line means, `address 127.0.0.1 port 22 limit 1000`,
and knocks on nothing.

`knock --rounds ROUNDS EVERY ADDRESS PORT MS [ADDRESS PORT MS ...]` knocks each target in turn, ROUNDS times, with one
set of buffers. After every EVERY rounds, and after the last, it prints the counts so far
(`round 1000 answered 1000 refused 1000 no-answer 1000 unreachable 0 error 0`) and waits for a byte on standard input
before going on, so the check can look at it while it stands still.

`knock --split ADDRESS PORT [MILLISECONDS]` knocks once as `knock` does, but through `net_start` and `net_check`: between
looks it waits on the connection for at most what `net_left` gives, as Scope's window does. It prints the same line
and exits with the same status. `knock --split-rounds ...` is `--rounds` with these knocks.

## How it is built

The build joins `lib/linux.herb`, `lib/text.herb`, `lib/net.herb` and `examples/knock.herb` and compiles them with
the committed Herbert compiler. It talks to Linux with system calls; no foreign runtime is linked in.

## Verification

```sh
make check-net
```

`make check-hosted-apps` runs the same checks (`bootstrap/tests/check_net.py`), and so do `make verify-local` and CI.
They knock only on this computer: addresses in 127.x, and addresses inside a private network namespace the check makes.
Malformed command lines must be refused before a socket is asked for (strace watches); a small program built from the
library checks its own refusals and its sorting of Linux's errors; one knock's system calls are checked, in order;
listeners the check opens must see a connection and not one byte; a port held closed must be refused; a listener whose
queue the check fills (so Linux drops every new connection silently) must give no answer, at the time limit and no more
than 100 ms after it; strace makes the rare cases happen on purpose (an interrupted wait, a connect that returns only
after the limit, a computer that answers and then resets); and 24,000 knocks in one process must leave its open files,
its size and its memory as they were. All of this runs twice, once through `net_knock` and once through `net_start` and
`net_check` (`--split`, `--split-rounds`), whose system calls must also be socket, connect, then polls only, the answer
found by a look that waits for nothing, then SO_ERROR and close; the small program also checks that `net_start` keeps
`net_knock`'s range guard and leaves no knock under way when it fails, and a second one that starting a knock while
another is under way on the same `Net` first closes that one, and that `net_stop` closes a knock under way. A third
small program checks `net_start_reading` against listeners the check opens, each playing a part: a line and then the end
of the connection (read whole), the end alone, 300 bytes held open (stopped at 256 at once), nothing (given up at the
time limit, within 100 ms of it), two bytes and a reset (answered, with the reset named), a refusal, and a plain
`net_start` knock after them (nothing read); under strace, each knock's socket sees only socket, connect, polls,
SO_ERROR, `recvfrom` with no wait and close, the waits between looks ask for POLLIN once the connection is taken, and
nothing is sent. Where the machine lets an unprivileged user make a private network namespace, the check also makes
`unreachable` and `error` happen there (with routes, and with firewall rules when `nft` is present), both ways, and runs
the memory check with all five outcomes, a quarter as many rounds for the split knock; where it does not, the check says
so plainly.
