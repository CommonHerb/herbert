# Herbert knock

Asks one computer whether it answers at an address and a port, once, and says what happened. It is the first piece of
networking in Herbert, and the start of the second piece of the window on the owner's computers, which will show
whether each of them answers.

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

## Test modes

These are for the tests. Either one given the wrong number of arguments prints its own usage and exits 2.

`knock --parse ADDRESS PORT [MILLISECONDS]` prints what the command line means, `address 127.0.0.1 port 22 limit 1000`,
and knocks on nothing.

`knock --rounds ROUNDS EVERY ADDRESS PORT MS [ADDRESS PORT MS ...]` knocks each target in turn, ROUNDS times, with one
set of buffers. After every EVERY rounds, and after the last, it prints the counts so far
(`round 1000 answered 1000 refused 1000 no-answer 1000 unreachable 0 error 0`) and waits for a byte on standard input
before going on, so the check can look at it while it stands still.

## How it is built

The build joins `lib/linux.herb`, `lib/net.herb` and `examples/knock.herb` and compiles them with the committed
Herbert compiler. It talks to Linux with system calls; no foreign runtime is linked in.

## Verification

```sh
make check-net
```

`make check-hosted-apps` runs the same checks (`bootstrap/tests/check_net.py`), and so do `make verify-local` and CI.
They knock only on this computer: addresses in 127.x, and addresses inside a private network namespace the check
makes. Malformed command lines must be refused before a socket is asked for (strace watches); a small program built
from the library checks its own refusals and its sorting of Linux's errors; one knock's system calls are checked, in
order; listeners the check opens must see a connection and not one byte; a port held closed must be refused; a
listener whose queue the check fills (so Linux drops every new connection silently) must give no answer, at the time
limit and no more than 100 ms after it; strace makes the rare cases happen on purpose (an interrupted wait, a connect
that returns only after the limit, a computer that answers and then resets); and 24,000 knocks in one process must
leave its open files, its size and its memory as they were. Where the machine lets an unprivileged user make a private network namespace, the check also
makes `unreachable` and `error` happen there (with routes, and with firewall rules when `nft` is present) and runs the
memory check with all five outcomes; where it does not, the check says so plainly.
