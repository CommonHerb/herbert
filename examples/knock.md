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
make answers
```

The knock library's cases are in `checks/libraries.cases` ([VERIFYING.md](../VERIFYING.md)). They knock only on this
computer, to addresses in 127.77.0.0/16 where they listen themselves: a reading knock stops at a full 256-byte reply and
at its limit (300 to 400 ms for 300); a knock on a computer that never answers (a listener whose queue is full, so
Linux drops every new connection) stops at its limit both ways; each look takes under 50 ms; a computer that sends a
line and ends, or sends two bytes and resets, ends the knock answered with its socket closed; no knock sends a byte;
8,000 rounds on a listener, a refused port and the full queue, then 8,000 with every connect failed at once, leave the
open files, the size and the memory as they were; and a connect failed at once with EHOSTUNREACH, EACCES or EBADMSG
(made by `lib/fault.herb`) ends unreachable, error and error, its socket closed. Address, port and limit parsing are
held there too. `make hands` has Scope knock on six stand-in computers for real.

Not checked: the exact system calls of a knock and its waits (that needs the calls watched), `net_knock` and
`net_start` in a long run, limits other than 300 ms, and a real firewall drop, which takes the full queue's path.
