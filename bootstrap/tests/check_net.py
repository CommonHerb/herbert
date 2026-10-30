#!/usr/bin/env python3
"""knock's checks: lib/net.herb, through examples/knock.herb, on this machine only.

Every knock here goes to 127.x (all of 127/8 is this computer's loopback), or to an address inside a private network
namespace this check makes and that has nothing in it but its own loopback. Nothing knocks, pings or scans another
computer.

On loopback, needing no privileges:
- Malformed addresses, ports, limits and command lines are refused with exit status 2 and a plain message before any
  socket is made. These run under strace with socket() made to fail (--inject), so the trace shows that no socket was
  even asked for, and no build, however broken its parser, can send a packet from them. Every malformed address is
  built around 127.x, so a mis-read would still name this computer. `--parse` shows what good command lines mean,
  edges included, under the same strace; each test mode with the wrong number of arguments prints its own usage.
- The library itself, through a small Herbert probe this check compiles from lib/linux.herb, lib/net.herb and a main
  of its own: net_knock's range guard (an address past 32 bits, port 0 and 65536, limit 0 and 60001) is error 22
  with no socket asked for, while the edges just inside it do ask for one; net_classify's mapping of every error
  the library names (100, 101, 112 and 113 unreachable, 110 no answer, 111 refused, the rest error) and
  net_error_name's words for each.
- The system calls of one knock, from strace, to 127.200.1.254 (four different bytes, two past 127): one socket,
  SOCK_STREAM|SOCK_CLOEXEC|SOCK_NONBLOCK; then, in this order and nothing else on it, connect to that address and
  port, poll, getsockopt(SO_ERROR), close; nothing written or sent on it.
- answered: listeners this check opens on random free ports at 127.0.0.1, 127.45.67.89 and 127.200.1.254; each must
  see one connection and not one byte. refused: a port held bound but not listening, at 127.0.0.1 and 127.200.1.254.
- Edges made certain with strace's fault injection: an EINTR on the first poll still answers; a connect that returns
  only after the time limit has passed (answered or refused) and an EINTR that comes back after it are each followed
  by one more poll, with no wait, that sees the answer, never "no answer" without one; connect returning 0 at once
  is answered; a socket that never connects (poll says POLLOUT|POLLHUP, SO_ERROR 0) is an error, not an answer; and a
  listener that accepts and then resets (ECONNRESET), or closes and then resets (EPIPE), was answered, with the
  error named ("then connection reset", "then broken pipe").
- no answer: a listener whose accept queue this check fills, so Linux drops every further SYN (tcp_conn_request,
  "listen overflow"): no reset, no ICMP, nothing comes back. This needs no privilege and no namespace, so it works on
  any Linux; the check proves the black hole is one (a connection of its own stays pending for 300 ms) before using
  it, and fails if it cannot make one. The time limit is honoured: for 100, 700 and 1500 ms (the last past the first
  SYN retry) the knock's own count is at least the limit and at most the limit + 100 ms, and the program, start to
  exit as this check sees it, at least the limit and at most the limit + 500 ms. Under strace, the knock's own clock
  readings show its last poll waits for nothing, comes at or after the limit, and finds nothing. Answered and refused
  with a 10-second limit must come back within one second.
- No leaks: `knock --rounds` knocks the three targets in turn 8,000 times in one process (24,000 knocks, the no-answer
  ones with a 1 ms limit, the others with 5 s, well past the 1 s SYN retry, so a listener running behind cannot turn
  an answer into a miscount), stopping every 1,000 rounds for this check to look at it. Every count must be exact,
  the process must hold no socket and the same descriptors at every stop, its virtual size (VmSize) must not change
  and its resident memory (Rss) must stay within 64 KiB from the first stop to the last: 21,000 knocks, so even four
  bytes kept per knock would show. The listener must have seen 8,000 connections and not one byte.

In a private network namespace (`unshare -rn`), when this machine allows an unprivileged user to make one:
- unreachable: an address with no route (ENETUNREACH), one whose route says unreachable (EHOSTUNREACH), and, with
  nft, a port whose firewall rule answers with ICMP host-unreachable, which arrives after connect has begun, through
  SO_ERROR (the namespace's own icmp_ratemask is set to 0 so Linux's ICMP rate limit cannot drop those answers);
- error: an address whose route is "prohibit" (EACCES);
- no answer again, from a firewall rule that drops the SYN (with nft);
- No leaks with all five outcomes: 4,000 rounds of every target there, the same measures as above.
Where this machine does not allow such a namespace (Ubuntu's kernel.apparmor_restrict_unprivileged_userns=1 is one
cause), or lacks ip or nft, those checks are not run, and the check says so plainly in its output and in result.json
("not_tested"); nothing else can make those outcomes on this machine without privileges. With
HERBERT_NET_REQUIRE_ALL=1 (GitHub's check sets it) a check that is not run fails instead, recorded as the failure.

Python and strace are test tools only; knock links neither. Evidence is kept in /tmp/herbert-hosted-apps-net-*.
"""

if not __debug__:
    raise SystemExit('verification requires Python assertions; remove -O/-OO and PYTHONOPTIMIZE')

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import select
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

from check_desktop import memory as process_memory
from check_hosted_apps import stable_memory, static_elf, wait_for

ROOT = Path(__file__).resolve().parents[2]
LOOPBACK = '127.0.0.1'
SPREAD, HIGH = '127.45.67.89', '127.200.1.254'     # loopback addresses whose four bytes all differ
STATUS = {'answered': 0, 'refused': 3, 'no answer': 4, 'unreachable': 5, 'error': 6}
LINE = re.compile(r'(answered|refused|no answer|unreachable|error): (\S+) port (\d+) in (\d+) ms'
                  r'(?: \((then )?(?:([a-z ]+), )?errno (\d+)\))?\n')
REPORT = re.compile(r'round (\d+) answered (\d+) refused (\d+) no-answer (\d+) unreachable (\d+) error (\d+)\n')
OUTCOMES = ('answered', 'refused', 'no-answer', 'unreachable', 'error')
ENV = {k: v for k, v in os.environ.items() if k != 'DISPLAY'}

BAD_ADDRESS = b'knock: not an IPv4 address; write four numbers 0 to 255 joined by dots, like 127.0.0.1\n'
BAD_PORT = b'knock: not a port; write a number 1 to 65535\n'
BAD_LIMIT = b'knock: not a time limit; write whole milliseconds, 1 to 60000\n'
USAGE = b'knock: usage: knock ADDRESS PORT [MILLISECONDS]\n'
PARSE_USAGE = b'knock: usage: knock --parse ADDRESS PORT [MILLISECONDS]\n'
ROUNDS_USAGE = b'knock: usage: knock --rounds ROUNDS EVERY ADDRESS PORT MS [ADDRESS PORT MS ...]\n'

# Each built around 127.x: whatever a broken parser made of them would still be this computer.
MALFORMED_ADDRESSES = [
    '', '127', '127.0.0', '127.0.0.1.1', '127.0.0.1.', '.127.0.0.1', '127..0.1', '127.0..1', '127.0.0.',
    '127.0.0.256', '127.0.0.999', '127.0.0.1000', '127.0.0.01', '127.0.0.00', '127.000.0.1', '0127.0.0.1',
    ' 127.0.0.1', '127.0.0.1 ', '127.0.0.1\t', '127.0. 0.1', '+127.0.0.1', '127.0.0.-1', '127.0.0.+1',
    '127.0.0.1x', 'x127.0.0.1', '127.0.0.1:22', '127.0.0.1/8', '0x7f.0.0.1', '127.0.0.0x1', '127,0,0,1',
    '2130706433', '127.1', '127.0.1', 'localhost', '::1', '127.0.0.18446744073709551617',
    '127.0.0.' + '9' * 30, '127.0.0.1' + '.1' * 40,
]
MALFORMED_PORTS = ['', '0', '00', '022', '65536', '65535x', '99999', '100000', '18446744073709551638', '-22', '+22',
                   ' 22', '22 ', '2 2', '0x16', '22.0', 'ssh']
MALFORMED_LIMITS = ['', '0', '000', '0100', '60001', '99999', '100000', '-1', '1.5', '1e3', ' 100', '100 ', 'ms']
# (arguments, the line --parse prints): edges of every field, and the default limit.
PARSED = [
    (['127.0.0.1', '22'], 'address 127.0.0.1 port 22 limit 1000'),
    (['0.0.0.0', '1', '1'], 'address 0.0.0.0 port 1 limit 1'),
    (['255.255.255.255', '65535', '60000'], 'address 255.255.255.255 port 65535 limit 60000'),
    (['100.85.56.67', '22', '2500'], 'address 100.85.56.67 port 22 limit 2500'),
    (['10.0.0.1', '80'], 'address 10.0.0.1 port 80 limit 1000'),
    (['192.168.1.5', '443', '999'], 'address 192.168.1.5 port 443 limit 999'),
    (['1.20.199.250', '65534', '59999'], 'address 1.20.199.250 port 65534 limit 59999'),
    (['127.0.0.1', '9', '10'], 'address 127.0.0.1 port 9 limit 10'),
]

# The library through a main of its own: net_knock's guard and the error words and classes. Its knocks on 127.0.0.1
# run with socket() made to fail, so none can leave this computer whatever the library does.
PROBE = r'''
func probe_put(out, text):
    let i = 0
    while i < length(text):
        do append(out, index(text, i))
        i = i + 1
    end
    return 0
end

func probe_number(out, n):
    let digits = linux_buffer(20)
    let stop = linux_decimal(digits, 0, n)
    let i = 0
    while i < stop:
        do append(out, buffer_get(digits, i))
        i = i + 1
    end
    return 0
end

func probe_guard(out, n, address, port, limit):
    let outcome = net_knock(n, address, port, limit)
    do probe_put(out, "guard ")
    do probe_number(out, address)
    do probe_put(out, " ")
    do probe_number(out, port)
    do probe_put(out, " ")
    do probe_number(out, limit)
    do probe_put(out, " outcome ")
    do probe_number(out, outcome)
    do probe_put(out, " error ")
    do probe_number(out, n.state.error)
    return probe_put(out, "\n")
end

func probe_classify(out, e):
    do probe_put(out, "classify ")
    do probe_number(out, e)
    do probe_put(out, " ")
    do probe_number(out, net_classify(e))
    do probe_put(out, " ")
    do probe_put(out, net_error_name(e))
    return probe_put(out, "\n")
end

func main():
    let n = net_new()
    let out = new_buffer()
    do probe_guard(out, n, 4294967296, 9, 100)
    do probe_guard(out, n, 18446744073709551615, 9, 100)
    do probe_guard(out, n, 2130706433, 0, 100)
    do probe_guard(out, n, 2130706433, 65536, 100)
    do probe_guard(out, n, 2130706433, 9, 0)
    do probe_guard(out, n, 2130706433, 9, 60001)
    do probe_guard(out, n, 2130706433, 65535, 60000)
    do probe_guard(out, n, 2130706433, 1, 1)
    let errors = new_array(int)
    do add(errors, 111)
    do add(errors, 101)
    do add(errors, 113)
    do add(errors, 100)
    do add(errors, 112)
    do add(errors, 110)
    do add(errors, 13)
    do add(errors, 1)
    do add(errors, 22)
    do add(errors, 99)
    do add(errors, 104)
    do add(errors, 32)
    do add(errors, 107)
    do add(errors, 24)
    do add(errors, 23)
    do add(errors, 105)
    do add(errors, 12)
    do add(errors, 9999)
    let i = 0
    while i < count(errors):
        do probe_classify(out, get(errors, i))
        i = i + 1
    end
    do flogger(freeze(out))
    do process_exit(0)
    return 0
end
'''
# What the probe must print. The last two guard lines are inside the range: they ask for a socket (and get EPERM).
PROBE_ANSWER = ''.join(f'guard {a} {p} {l} outcome 4 error {e}\n' for a, p, l, e in (
    (4294967296, 9, 100, 22), (18446744073709551615, 9, 100, 22), (2130706433, 0, 100, 22),
    (2130706433, 65536, 100, 22), (2130706433, 9, 0, 22), (2130706433, 9, 60001, 22),
    (2130706433, 65535, 60000, 1), (2130706433, 1, 1, 1))) + ''.join(f'classify {e} {o} {w}\n' for e, o, w in (
    (111, 1, 'connection refused'), (101, 3, 'network is unreachable'), (113, 3, 'no route to host'),
    (100, 3, 'network is down'), (112, 3, 'host is down'), (110, 2, 'timed out'), (13, 4, 'permission denied'),
    (1, 4, 'operation not permitted'), (22, 4, 'invalid argument'), (99, 4, 'address not available'),
    (104, 4, 'connection reset'), (32, 4, 'broken pipe'), (107, 4, 'not connected'), (24, 4, 'too many open files'),
    (23, 4, 'too many open files in the system'), (105, 4, 'no buffer space'), (12, 4, 'out of memory'),
    (9999, 4, '')))


class Listener:
    """A free port at address, accepting at once. plain: reads each connection to its end, counting every byte sent;
    reset: closes each at once with a reset; fin-reset: sends its own end first, then resets."""

    def __init__(self, address=LOOPBACK, mode='plain'):
        self.mode = mode
        self.sock = socket.socket()
        self.sock.bind((address, 0))
        self.sock.listen(4096)
        self.port = self.sock.getsockname()[1]
        self.connections, self.received, self.errors = 0, 0, []
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def serve(self):
        while True:
            try:
                connection, _ = self.sock.accept()
            except OSError:
                return
            with connection:
                try:
                    if self.mode == 'plain':
                        connection.settimeout(5)
                        while True:
                            data = connection.recv(4096)
                            if not data:
                                break
                            self.received += len(data)
                    else:
                        if self.mode == 'fin-reset':
                            connection.shutdown(socket.SHUT_WR)
                        connection.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack('ii', 1, 0))
                except OSError as error:
                    self.errors.append(repr(error))
            self.connections += 1

    def close(self):
        try:
            self.sock.shutdown(socket.SHUT_RDWR)       # wakes the accept
        except OSError:
            pass
        self.sock.close()
        self.thread.join(10)


class ClosedPort:
    """A port held bound at address but not listening: Linux answers a SYN to it with a reset."""

    def __init__(self, address=LOOPBACK):
        self.sock = socket.socket()
        self.sock.bind((address, 0))
        self.port = self.sock.getsockname()[1]

    def close(self):
        self.sock.close()


def pending(port, milliseconds, address=LOOPBACK):
    """Whether a connection of this check's own to port stays unanswered for that long (no accept, reset or error)."""
    probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM | socket.SOCK_NONBLOCK)
    try:
        started = probe.connect_ex((address, port))
        if started != 115:                          # EINPROGRESS
            return False, f'connect gave errno {started} at once'
        ready = select.poll()
        ready.register(probe, select.POLLOUT)
        events = ready.poll(milliseconds)
        return not events, f'events {events}, SO_ERROR {probe.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR)}'
    finally:
        probe.close()


class BlackHole:
    """A listener nobody accepts from, its accept queue full: Linux drops every further SYN to it, silently."""

    def __init__(self):
        self.sock = socket.socket()
        self.sock.bind((LOOPBACK, 0))
        self.sock.listen(0)
        self.port = self.sock.getsockname()[1]
        self.fillers = []
        while len(self.fillers) < 8:
            filler = socket.socket(socket.AF_INET, socket.SOCK_STREAM | socket.SOCK_NONBLOCK)
            filler.connect_ex((LOOPBACK, self.port))
            ready = select.poll()
            ready.register(filler, select.POLLOUT)
            events = ready.poll(300)
            if not events:
                filler.close()
                break
            assert filler.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR) == 0, 'black-hole filler failed'
            self.fillers.append(filler)
        else:
            self.close()
            raise AssertionError('cannot make a black hole here: eight connections were all accepted into a '
                                 'listen(0) queue; this Linux does not drop SYNs at a full accept queue')
        held, how = pending(self.port, 300)
        assert held, ('the black hole answered a connection of its own', how)

    def close(self):
        for filler in self.fillers:
            filler.close()
        self.sock.close()


def knock(args, *argv, timeout=75):
    started = time.monotonic()
    result = subprocess.run([str(args.knock), *argv], stdin=subprocess.DEVNULL, capture_output=True,
                            timeout=timeout, env=ENV)
    return result, (time.monotonic() - started) * 1000


def check_line(result, argv, outcome, address, port, reason=None, errno=None):
    """knock's exit status and its one line, which must say outcome; reason and errno when given (after "then" for
    an answer). Returns the knock's own milliseconds."""
    assert result.stderr == b'' and result.returncode == STATUS[outcome], (argv, result.returncode, result.stdout,
                                                                           result.stderr)
    line = LINE.fullmatch(result.stdout.decode())
    assert line, (argv, result.stdout)
    assert (line.group(1), line.group(2), int(line.group(3))) == (outcome, address, port), (argv, result.stdout)
    if errno is None:
        assert line.group(7) is None, (argv, result.stdout)
    else:
        assert (line.group(5), line.group(6), int(line.group(7))) == ('then ' if outcome == 'answered' else None,
                                                                       reason, errno), (argv, result.stdout)
    return int(line.group(4))


def expect(args, argv, outcome, address, port, reason=None, errno=None, timeout=75):
    """One knock that must print outcome; returns (the knock's own milliseconds, wall milliseconds)."""
    result, wall = knock(args, *argv, timeout=timeout)
    return check_line(result, argv, outcome, address, port, reason, errno), wall


def traced(args, evidence, label, argv, calls, inject=()):
    """knock (or another program, argv[0] when args is None) under strace, the given calls traced and the inject
    specs applied; (result, trace lines without their process ids)."""
    trace = evidence / (label + '.strace')
    command = ['strace', '-f', '-qq', '-o', str(trace), '-e', 'trace=' + calls]
    for spec in inject:
        command += ['-e', 'inject=' + spec]
    program = [str(args.knock)] if args is not None else []
    result = subprocess.run(command + program + list(argv), stdin=subprocess.DEVNULL, capture_output=True,
                            timeout=75, env=ENV)
    lines = [re.sub(r'^\d+ +', '', line) for line in trace.read_text().splitlines()]
    return result, lines


def refusal_checks(args, evidence, passed):
    assert shutil.which('strace'), 'strace is required (a test tool; CI installs it)'
    root = evidence / 'refusals'
    root.mkdir()
    cases = []
    for address in MALFORMED_ADDRESSES:
        cases.append(('address', [address, '9', '100'], BAD_ADDRESS))
    for port in MALFORMED_PORTS:
        cases.append(('port', [LOOPBACK, port, '100'], BAD_PORT))
    for limit in MALFORMED_LIMITS:
        cases.append(('limit', [LOOPBACK, '9', limit], BAD_LIMIT))
    cases += [('usage', [], USAGE), ('usage', [LOOPBACK], USAGE), ('usage', [LOOPBACK, '9', '100', 'x'], USAGE),
              ('parse-usage', ['--parse'], PARSE_USAGE), ('parse-usage', ['--parse', LOOPBACK], PARSE_USAGE),
              ('parse-usage', ['--parse', LOOPBACK, '9', '100', 'x'], PARSE_USAGE),
              ('rounds-usage', ['--rounds'], ROUNDS_USAGE), ('rounds-usage', ['--rounds', '1'], ROUNDS_USAGE),
              ('rounds-usage', ['--rounds', '1', '1'], ROUNDS_USAGE),
              ('rounds-usage', ['--rounds', '1', '1', LOOPBACK, '9'], ROUNDS_USAGE),
              ('rounds-usage', ['--rounds', '1', '1', LOOPBACK, '9', '1', LOOPBACK], ROUNDS_USAGE),
              ('address-first', ['127.0.0.256', '0', '0'], BAD_ADDRESS), ('port-before-limit', [LOOPBACK, '0', '0'],
                                                                         BAD_PORT),
              ('parse-address', ['--parse', '127.0.0.01', '9'], BAD_ADDRESS),
              ('parse-limit', ['--parse', LOOPBACK, '9', '60001'], BAD_LIMIT),
              ('rounds-count', ['--rounds', '0', '1', LOOPBACK, '9', '1'], ROUNDS_USAGE),
              ('rounds-every', ['--rounds', '5', '01', LOOPBACK, '9', '1'], ROUNDS_USAGE),
              ('rounds-target', ['--rounds', '5', '1', LOOPBACK, '9', '1', '127.0.0.1x', '9', '1'], BAD_ADDRESS)]
    for number, (kind, argv, message) in enumerate(cases):
        result, trace = traced(args, root, f'{number:03d}-{kind}', argv, 'socket,connect', ['socket:error=EPERM'])
        assert (result.returncode, result.stdout, result.stderr) == (2, b'', message), (kind, argv, result)
        assert trace == [], ('a socket was asked for before the refusal', kind, argv, trace)
    passed('net-refuses-malformed-before-any-socket', addresses=len(MALFORMED_ADDRESSES), ports=len(MALFORMED_PORTS),
           limits=len(MALFORMED_LIMITS), command_lines=len(cases) - len(MALFORMED_ADDRESSES) - len(MALFORMED_PORTS)
           - len(MALFORMED_LIMITS), socket_calls_seen=0)
    for number, (argv, line) in enumerate(PARSED):
        result, trace = traced(args, root, f'parse-{number}', ['--parse', *argv], 'socket,connect',
                               ['socket:error=EPERM'])
        assert (result.returncode, result.stdout, result.stderr) == (0, (line + '\n').encode(), b''), (argv, result)
        assert trace == [], ('--parse asked for a socket', argv, trace)
    passed('net-parses-good-command-lines', cases=len(PARSED), socket_calls_seen=0)


def library_checks(args, evidence, passed):
    """net_knock's guard, net_classify and net_error_name through a probe compiled here with the committed seed."""
    root = evidence / 'probe'
    root.mkdir()
    seed = ROOT / 'bootstrap/seed/gen1.seed'
    expected = (ROOT / 'bootstrap/seed/gen1.seed.sha256').read_text().split()[0]
    assert hashlib.sha256(seed.read_bytes()).hexdigest() == expected, 'committed seed hash mismatch'
    units = [ROOT / 'lib/linux.herb', ROOT / 'lib/net.herb']
    if args.library is not None:
        units = [ROOT / 'lib/linux.herb', args.library]
    source = b''.join(unit.read_bytes() + b'\n' for unit in units) + PROBE.encode()
    (root / 'source.herb').write_bytes(source)
    compiler = root / 'compiler'
    shutil.copyfile(seed, compiler)
    compiler.chmod(0o755)
    compiled = subprocess.run([str(compiler)], input=source, cwd=root, capture_output=True, timeout=60,
                              preexec_fn=lambda: resource.setrlimit(resource.RLIMIT_CORE, (0, 0)))
    assert compiled.returncode == 0 and compiled.stdout == b'0\n' and not compiled.stderr, (
        'the probe did not compile', compiled.returncode, compiled.stdout, compiled.stderr[:2000])
    compiler.unlink()
    image = root / 'a.out'
    image.chmod(0o755)
    result, trace = traced(None, root, 'probe', [str(image)], 'socket,connect', ['socket:error=EPERM'])
    (root / 'probe.stdout').write_bytes(result.stdout)
    assert (result.returncode, result.stderr) == (0, b''), ('the probe failed', result.returncode, result.stderr)
    got = result.stdout.decode()
    assert got == PROBE_ANSWER, ('the library gave other answers', [(g, w) for g, w in
                                 zip(got.splitlines(), PROBE_ANSWER.splitlines()) if g != w] or got)
    sockets = [line for line in trace if line.startswith('socket(')]
    assert len(sockets) == 2 and all('EPERM' in line for line in sockets), ('the guard let a socket be made, or the '
                                                                            'edges inside it did not ask', trace)
    assert not [line for line in trace if line.startswith('connect(')], trace
    passed('net-library-guard-and-error-classes', guard_cases=6, edges_inside_the_guard=2, error_numbers=18,
           sockets_asked_for=len(sockets), library=str(units[-1]) if args.library else 'lib/net.herb')


def syscall_checks(args, evidence, passed):
    listener = Listener(HIGH)
    try:
        result, trace = traced(args, evidence, 'answered-syscalls', [HIGH, str(listener.port), '5000'],
                               'socket,connect,poll,getsockopt,close,write,writev,sendto,sendmsg,sendmmsg')
        check_line(result, 'answered-syscalls', 'answered', HIGH, listener.port)
        sockets = [line for line in trace if line.startswith('socket(')]
        assert len(sockets) == 1, trace
        made = re.fullmatch(r'socket\(AF_INET, (\S+), IPPROTO_TCP\) = (\d+)', sockets[0])
        assert made and set(made.group(1).split('|')) == {'SOCK_STREAM', 'SOCK_CLOEXEC', 'SOCK_NONBLOCK'}, sockets
        fd = made.group(2)
        after = trace[trace.index(sockets[0]):]
        on_socket = [line for line in after if line.startswith(('socket(', f'connect({fd},', f'poll([{{fd={fd},',
                                                                f'getsockopt({fd},', f'close({fd})'))]
        assert [line.split('(')[0] for line in on_socket] == ['socket', 'connect', 'poll', 'getsockopt', 'close'], \
            ('the knock did not go socket, connect, poll, getsockopt, close', on_socket)
        assert on_socket[1] == (f'connect({fd}, {{sa_family=AF_INET, sin_port=htons({listener.port}), '
                                f'sin_addr=inet_addr("{HIGH}")}}, 16) = -1 EINPROGRESS (Operation now in progress)'), \
            ('connect went elsewhere', on_socket[1])
        assert re.fullmatch(rf'poll\(\[\{{fd={fd}, events=POLLOUT\}}\], 1, \d+\) += 1 \(\[\{{fd={fd}, '
                            rf'revents=POLLOUT\}}\]\)', on_socket[2]), on_socket[2]
        assert on_socket[3] == f'getsockopt({fd}, SOL_SOCKET, SO_ERROR, [0], [4]) = 0', on_socket[3]
        assert re.fullmatch(rf'close\({fd}\) += 0', on_socket[4]), on_socket[4]
        sent = [line for line in after if re.match(rf'(write|writev|sendto|sendmsg|sendmmsg)\({fd},', line)]
        assert sent == [], ('data sent on the socket', sent)
        wait_for(lambda: listener.connections == 1, 'the traced connection accepted')
        assert listener.received == 0, ('the listener received bytes from the knock', listener.received)
    finally:
        listener.close()
    passed('net-knock-system-calls', order=[line.split('(')[0] for line in on_socket], socket=sockets[0],
           connect=on_socket[1], bytes_sent=0)


def outcome_checks(args, evidence, passed):
    listeners = [Listener(address) for address in (LOOPBACK, SPREAD, HIGH)]
    closed = [ClosedPort(address) for address in (LOOPBACK, HIGH)]
    try:
        for listener, address in zip(listeners, (LOOPBACK, SPREAD, HIGH)):
            own, wall = expect(args, [address, str(listener.port)], 'answered', address, listener.port)
            wait_for(lambda: listener.connections == 1, f'one connection accepted at {address}')
            assert listener.received == 0 and not listener.errors, ('the listener received bytes from the knock',
                                                                    listener.received, listener.errors)
        passed('net-answered', addresses=[LOOPBACK, SPREAD, HIGH], listener_connections=1, bytes_received=0)
        for port, address in zip(closed, (LOOPBACK, HIGH)):
            expect(args, [address, str(port.port)], 'refused', address, port.port)
        passed('net-refused', addresses=[LOOPBACK, HIGH])
        listener = listeners[0]
        own, wall = expect(args, [LOOPBACK, str(listener.port), '10000'], 'answered', LOOPBACK, listener.port)
        assert own < 1000 and wall < 1000, ('answered waited for the limit', own, wall)
        own_r, wall_r = expect(args, [LOOPBACK, str(closed[0].port), '10000'], 'refused', LOOPBACK, closed[0].port)
        assert own_r < 1000 and wall_r < 1000, ('refused waited for the limit', own_r, wall_r)
        passed('net-answered-and-refused-do-not-wait-for-the-limit', limit=10000, answered_ms=own,
               answered_wall_ms=round(wall), refused_ms=own_r, refused_wall_ms=round(wall_r))
        wait_for(lambda: listener.connections == 2, 'two connections accepted')
        assert listener.received == 0, ('the listener received bytes from the knock', listener.received)
    finally:
        for fixture in (*listeners, *closed):
            fixture.close()
    hole = BlackHole()
    try:
        timings = []
        for limit in (100, 700, 1500):
            own, wall = expect(args, [LOOPBACK, str(hole.port), str(limit)], 'no answer', LOOPBACK, hole.port)
            timings.append({'limit': limit, 'knock_ms': own, 'wall_ms': round(wall, 1)})
            assert limit <= own <= limit + 100, ('the knock did not keep to its time limit', timings)
            assert limit <= wall <= limit + 500, ('the program did not keep to its time limit', timings)
        last = last_poll_checks(args, evidence, hole.port, 300)
        held, how = pending(hole.port, 100)
        assert held, ('the black hole stopped being one', how)
        passed('net-no-answer-keeps-the-time-limit', black_hole='full accept queue on 127.0.0.1', timings=timings,
               slack_knock_ms=100, slack_wall_ms=500, traced_limit_300=last)
    finally:
        hole.close()


CLOCK = re.compile(r'clock_gettime\(CLOCK_MONOTONIC, \{tv_sec=(\d+), tv_nsec=(\d+)\}\) = 0')
POLL = re.compile(r'poll\(\[\{fd=\d+, events=POLLOUT\}\], 1, (\d+)\) += (-?\d+)')


def last_poll_checks(args, evidence, port, limit):
    """A no-answer knock under strace, read from its own clock: its last look is a poll with no wait, at or after
    the limit from its first clock reading, that finds nothing; no poll waits past the limit."""
    result, trace = traced(args, evidence, f'no-answer-{limit}-polls', [LOOPBACK, str(port), str(limit)],
                           'clock_gettime,poll')
    own = check_line(result, 'traced no answer', 'no answer', LOOPBACK, port)
    events = []
    for line in trace:
        if (clock := CLOCK.fullmatch(line)):
            events.append(('clock', int(clock.group(1)) * 10**9 + int(clock.group(2))))
        elif (poll := POLL.match(line)):
            events.append(('poll', int(poll.group(1)), int(poll.group(2))))
    assert events and events[0][0] == 'clock', ('no clock reading before the knock', trace)
    started = events[0][1]
    polls = [i for i, event in enumerate(events) if event[0] == 'poll']
    assert len(polls) >= 2, ('no final poll after the wait', events)
    final = events[polls[-1]]
    assert final[1:] == (0, 0), ('the last poll waited, or found something', final)
    before = [event for event in events[:polls[-1]] if event[0] == 'clock']
    assert before[-1][1] - started >= limit * 10**6, ('the last poll came before the limit', before[-1][1] - started)
    assert all(events[i][2] == 0 and events[i][1] <= limit for i in polls), ('a poll found something or waited past '
                                                                             'the limit', events)
    assert own >= limit, own
    return {'knock_ms': own, 'polls': [events[i][1] for i in polls],
            'final_poll_after_ms': round((before[-1][1] - started) / 10**6, 3)}


def injected_checks(args, evidence, passed):
    """Edges made certain by strace's fault injection, all on loopback listeners and ports."""
    root = evidence / 'injected'
    root.mkdir()
    calls = 'connect,poll,getsockopt,close'
    plain, closed = Listener(SPREAD), ClosedPort(SPREAD)
    try:
        target = [SPREAD, str(plain.port)]
        result, trace = traced(args, root, 'eintr-first-poll', target + ['5000'], calls, ['poll:error=EINTR:when=1'])
        check_line(result, 'eintr-first-poll', 'answered', SPREAD, plain.port)
        polls = [line for line in trace if line.startswith('poll(')]
        assert len(polls) == 2 and 'INJECTED' in polls[0] and 'revents=POLLOUT' in polls[1], polls
        passed('net-eintr-polls-again', polls=polls)

        result, trace = traced(args, root, 'connect-after-the-limit', target + ['10'], calls,
                               ['connect:delay_exit=60ms'])
        check_line(result, 'connect-after-the-limit', 'answered', SPREAD, plain.port)
        polls = [line for line in trace if line.startswith('poll(')]
        assert len(polls) == 1 and re.match(r'poll\(\[\{fd=\d+, events=POLLOUT\}\], 1, 0\) += 1 ', polls[0]), polls
        result, trace = traced(args, root, 'connect-after-the-limit-refused', [SPREAD, str(closed.port), '10'], calls,
                               ['connect:delay_exit=60ms'])
        check_line(result, 'connect-after-the-limit-refused', 'refused', SPREAD, closed.port)
        polls_refused = [line for line in trace if line.startswith('poll(')]
        assert len(polls_refused) == 1 and ', 1, 0) ' in polls_refused[0], polls_refused
        result, trace = traced(args, root, 'eintr-after-the-limit', target + ['20'], calls,
                               ['poll:error=EINTR:delay_exit=60ms:when=1'])
        check_line(result, 'eintr-after-the-limit', 'answered', SPREAD, plain.port)
        polls_late = [line for line in trace if line.startswith('poll(')]
        assert len(polls_late) == 2 and ', 1, 0) ' in polls_late[1] and 'revents=POLLOUT' in polls_late[1], polls_late
        passed('net-no-answer-only-after-a-last-poll', connect_returning_after_the_limit=polls[0],
               refused_after_the_limit=polls_refused[0], eintr_after_the_limit=polls_late)

        result, trace = traced(args, root, 'connect-returns-0', target + ['1000'], calls, ['connect:retval=0'])
        check_line(result, 'connect-returns-0', 'answered', SPREAD, plain.port)
        assert not [line for line in trace if line.startswith('poll(')], ('a connect of 0 still polled', trace)
        result, trace = traced(args, root, 'never-connected', target + ['1000'], calls, ['connect:error=EINPROGRESS'])
        check_line(result, 'never-connected', 'error', SPREAD, plain.port, 'not connected', 107)
        polls = [line for line in trace if line.startswith('poll(')]
        assert len(polls) == 1 and 'revents=POLLOUT|POLLHUP' in polls[0], polls
        assert any('SO_ERROR, [0]' in line for line in trace), trace
        passed('net-connect-results', connect_returning_0='answered', never_connected=polls[0])
    finally:
        plain.close()
        closed.close()
    for mode, spec, reason, errno in (('reset', 'getsockopt:delay_enter=1000ms', 'connection reset', 104),
                                      ('fin-reset', 'poll:delay_enter=1000ms', 'broken pipe', 32)):
        listener = Listener(SPREAD, mode)
        try:
            result, trace = traced(args, root, f'answered-then-{mode}', [SPREAD, str(listener.port), '5000'], calls,
                                   [spec])
            check_line(result, f'answered-then-{mode}', 'answered', SPREAD, listener.port, reason, errno)
            wait_for(lambda: listener.connections == 1, f'{mode} listener accepted')
            assert not listener.errors, listener.errors
        finally:
            listener.close()
    passed('net-answered-then-reset-is-an-answer', econnreset='answered (then connection reset, errno 104)',
           epipe='answered (then broken pipe, errno 32)')


def descriptors(pid):
    return sorted(os.readlink(f'/proc/{pid}/fd/{fd}') for fd in os.listdir(f'/proc/{pid}/fd'))


def read_line(p, timeout):
    data = b''
    deadline = time.monotonic() + timeout
    while not data.endswith(b'\n'):
        left = deadline - time.monotonic()
        assert left > 0 and select.select([p.stdout], [], [], left)[0], ('knock --rounds stopped reporting', data)
        chunk = os.read(p.stdout.fileno(), 4096)
        assert chunk, ('knock --rounds ended early', data, p.wait(10))
        data += chunk
    return data.decode()


def rounds_check(args, evidence, label, targets, rounds, every, expected):
    """knock --rounds over targets [(address, port, ms)]; expected[outcome] = that outcome's knocks per round.
    Returns the samples."""
    argv = [str(args.knock), '--rounds', str(rounds), str(every)]
    for address, port, limit in targets:
        argv += [address, str(port), str(limit)]
    stderr = (evidence / (label + '.stderr')).open('wb')
    p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr, env=ENV)
    samples, reports = [], []
    try:
        while True:
            line = read_line(p, 120)
            report = REPORT.fullmatch(line)
            assert report, line
            reports.append(line.strip())
            round_ = int(report.group(1))
            counts = dict(zip(OUTCOMES, map(int, report.groups()[1:])))
            assert counts == {k: round_ * expected.get(k, 0) for k in OUTCOMES}, (label, line, expected)
            sample = process_memory(p.pid)
            sample['round'], sample['knocks'] = round_, round_ * len(targets)
            sample['descriptors'] = descriptors(p.pid)
            samples.append(sample)
            (evidence / (label + '.json')).write_text(json.dumps(samples, indent=2) + '\n')
            # At every stop, so a knock that leaves its socket open fails here, not hours later.
            held = sample['descriptors']
            assert not any(d.startswith('socket:') for d in held), (label, 'sockets left open at round', round_,
                                                                    sum(d.startswith('socket:') for d in held))
            assert held == samples[0]['descriptors'], (label, 'descriptors changed at round', round_, held)
            p.stdin.write(b'\n')
            p.stdin.flush()
            if round_ == rounds:
                break
        assert p.wait(30) == 0, p.returncode
    finally:
        if p.poll() is None:
            p.kill()
            p.wait()
        stderr.close()
    assert (evidence / (label + '.stderr')).read_bytes() == b''
    assert [s['round'] for s in samples] == list(range(every, rounds + 1, every)), [s['round'] for s in samples]
    stable_memory(samples, label)
    return samples


def leak_checks(args, evidence, passed):
    listener, closed, hole = Listener(), ClosedPort(), BlackHole()
    try:
        targets = [(LOOPBACK, listener.port, 5000), (LOOPBACK, closed.port, 5000), (LOOPBACK, hole.port, 1)]
        rounds, every = args.rounds, args.rounds // 8
        samples = rounds_check(args, evidence, 'leak-loopback', targets, rounds, every,
                               {'answered': 1, 'refused': 1, 'no-answer': 1})
        wait_for(lambda: listener.connections == rounds, 'every answered knock accepted', 30)
        assert listener.received == 0 and not listener.errors, ('the listener received bytes from the knocks',
                                                                listener.received, listener.errors[:5])
    finally:
        listener.close()
        closed.close()
        hole.close()
    rss = [s['Rss'] for s in samples]
    passed('net-no-leak-on-loopback', knocks=rounds * len(targets), measured_knocks=(rounds - every) * len(targets),
           descriptors=samples[0]['descriptors'], vm_size_kib=samples[0]['VmSize'], vm_size_must_not_change=True,
           rss_kib_first=rss[0], rss_kib_last=rss[-1], rss_kib_min=min(rss), rss_kib_max=max(rss),
           rss_tolerance_kib=64, listener_connections=rounds, bytes_received=0)


# Inside the namespace: TEST-NET addresses (RFC 5737), routed only by the rules this check adds there.
NO_ROUTE, UNREACHABLE_NET, PROHIBITED_NET = '198.51.100.1', '192.0.2.0/24', '203.0.113.0/24'
UNREACHABLE, PROHIBITED = '192.0.2.1', '203.0.113.1'


def inside_namespace(args, evidence, passed, not_tested):
    """Runs as root of a fresh user and network namespace made by unshare -rn; nothing in it reaches outside."""
    assert os.getuid() == 0, 'not inside unshare -rn'
    links = subprocess.run(['ip', '-o', 'link'], capture_output=True, text=True, check=True).stdout.splitlines()
    assert len(links) == 1 and ': lo:' in links[0], ('not a private network namespace', links)
    for command in (['ip', 'link', 'set', 'lo', 'up'], ['ip', 'route', 'add', 'unreachable', UNREACHABLE_NET],
                    ['ip', 'route', 'add', 'prohibit', PROHIBITED_NET]):
        subprocess.run(command, check=True, capture_output=True)
    # Linux limits how many ICMP errors a namespace sends a second (icmp_msgs_per_sec, burst 50), and drops the rest;
    # an ICMP the firewall rule below sends could then be missing and its knock say no answer. With icmp_ratemask 0
    # no ICMP type is limited, in this namespace only. Should a kernel refuse that, the leak run's two 1 ms waits a
    # round still keep it under about 500 such answers a second, half the limit.
    ratemask = Path('/proc/sys/net/ipv4/icmp_ratemask')
    try:
        ratemask.write_text('0\n')
        icmp_ratemask = ratemask.read_text().strip()
    except OSError as error:
        icmp_ratemask = f'unchanged: {error}'
    expect(args, [NO_ROUTE, '80', '1000'], 'unreachable', NO_ROUTE, 80, 'network is unreachable', 101)
    expect(args, [UNREACHABLE, '22', '1000'], 'unreachable', UNREACHABLE, 22, 'no route to host', 113)
    passed('net-unreachable-from-the-routes', no_route='ENETUNREACH', unreachable_route='EHOSTUNREACH')
    expect(args, [PROHIBITED, '22', '1000'], 'error', PROHIBITED, 22, 'permission denied', 13)
    passed('net-error-names-the-linux-error', prohibited_route='EACCES')
    listener, closed, hole = Listener(), ClosedPort(), BlackHole()
    reject = drop = None
    try:
        expect(args, [LOOPBACK, str(listener.port)], 'answered', LOOPBACK, listener.port)
        firewall = None
        if shutil.which('nft'):
            reject, drop = ClosedPort(), ClosedPort()
            rules = (f'table inet knock {{\n chain out {{\n  type filter hook output priority 0;\n'
                     f'  ip daddr {LOOPBACK} tcp dport {reject.port} reject with icmp type host-unreachable\n'
                     f'  ip daddr {LOOPBACK} tcp dport {drop.port} drop\n }}\n}}\n')
            firewall = subprocess.run(['nft', '-f', '-'], input=rules.encode(), capture_output=True)
        if firewall is not None and firewall.returncode == 0:
            expect(args, [LOOPBACK, str(reject.port), '1000'], 'unreachable', LOOPBACK, reject.port,
                   'no route to host', 113)
            passed('net-unreachable-reported-later-through-so-error', icmp='host-unreachable', errno=113,
                   icmp_ratemask=icmp_ratemask)
            own, wall = expect(args, [LOOPBACK, str(drop.port), '300'], 'no answer', LOOPBACK, drop.port)
            assert 300 <= own <= 400 and 300 <= wall <= 800, (own, wall)
            passed('net-no-answer-from-a-firewall-drop', limit=300, knock_ms=own, wall_ms=round(wall))
        else:
            reason = 'nft is not installed' if firewall is None else firewall.stderr.decode(errors='replace').strip()
            not_tested.append(f'unreachable reported later by ICMP, and no answer from a firewall drop: nft '
                              f'cannot set rules in the namespace here ({reason})')
        targets = [(LOOPBACK, listener.port, 5000), (LOOPBACK, closed.port, 5000), (LOOPBACK, hole.port, 1),
                   (NO_ROUTE, 80, 5000), (UNREACHABLE, 22, 5000), (PROHIBITED, 22, 5000)]
        expected = {'answered': 1, 'refused': 1, 'no-answer': 1, 'unreachable': 2, 'error': 1}
        if firewall is not None and firewall.returncode == 0:
            targets += [(LOOPBACK, reject.port, 5000), (LOOPBACK, drop.port, 1)]
            expected['unreachable'] += 1
            expected['no-answer'] += 1
        rounds, every = args.rounds // 2, args.rounds // 16
        samples = rounds_check(args, evidence, 'leak-namespace', targets, rounds, every, expected)
        wait_for(lambda: listener.connections == rounds + 1, 'every answered knock accepted', 30)
        assert listener.received == 0 and not listener.errors, ('the listener received bytes from the knocks',
                                                                listener.received, listener.errors[:5])
    finally:
        for fixture in (listener, closed, hole, reject, drop):
            if fixture is not None:
                fixture.close()
    rss = [s['Rss'] for s in samples]
    passed('net-no-leak-with-every-outcome', knocks=rounds * len(targets),
           measured_knocks=(rounds - every) * len(targets), per_round=expected,
           descriptors=samples[0]['descriptors'], vm_size_kib=samples[0]['VmSize'], vm_size_must_not_change=True,
           rss_kib_first=rss[0], rss_kib_last=rss[-1], rss_kib_min=min(rss), rss_kib_max=max(rss),
           rss_tolerance_kib=64, icmp_ratemask=icmp_ratemask)


NAMESPACE_CHECKS = ('unreachable (no route, unreachable route, ICMP later)', 'error (prohibited route)',
                    'no answer from a firewall drop', 'no leaks with all five outcomes in one process')


def namespace_checks(args, evidence, passed, not_tested, result):
    """Run inside_namespace in a fresh unshare -rn, or say plainly why it cannot run here."""
    unshare, ip = shutil.which('unshare'), shutil.which('ip')
    reason = None
    if unshare is None or ip is None:
        reason = 'the unshare or ip command is missing'
    else:
        probe = subprocess.run([unshare, '-rn', 'true'], stdin=subprocess.DEVNULL, capture_output=True, timeout=30)
        if probe.returncode != 0:
            reason = (f'this machine does not let an unprivileged user make a private network namespace (unshare -rn '
                      f'exited {probe.returncode}: {probe.stderr.decode(errors="replace").strip()}); on Ubuntu, '
                      f'kernel.apparmor_restrict_unprivileged_userns=1 does that')
    if reason is not None:
        for name in NAMESPACE_CHECKS:
            not_tested.append(f'{name}: {reason}')
        return
    inner = evidence / 'namespace'
    inner.mkdir()
    command = [unshare, '-rn', sys.executable, str(Path(__file__).resolve()), '--inside-namespace',
               '--knock', str(args.knock.resolve()), '--evidence', str(inner), '--rounds', str(args.rounds)]
    run = subprocess.run(command, stdin=subprocess.DEVNULL, timeout=600, env=ENV)
    inside = json.loads((inner / 'result.json').read_text())
    result['namespace'] = inside
    assert run.returncode == 0 and 'failure' not in inside, ('namespace checks failed', run.returncode,
                                                             inside.get('failure'))
    not_tested.extend(inside['not_tested'])
    for check in inside['checks']:
        result['checks'].append(dict(check, namespace=True))


SECTIONS = ('refusals', 'library', 'syscalls', 'outcomes', 'injected', 'leaks', 'namespace')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--knock', type=Path, default=ROOT / 'build/knock')
    parser.add_argument('--library', type=Path, help='the net.herb the probe uses (default lib/net.herb)')
    parser.add_argument('--rounds', type=int, default=8000, help='rounds of the loopback leak check (namespace: half)')
    parser.add_argument('--only', choices=['all', *SECTIONS], default='all')
    parser.add_argument('--evidence', type=Path)
    parser.add_argument('--inside-namespace', action='store_true', help=argparse.SUPPRESS)
    args = parser.parse_args()
    assert args.rounds >= 1600 and args.rounds % 16 == 0, 'rounds: a multiple of 16, at least 1600 (default 8000)'
    evidence = (args.evidence or Path(tempfile.mkdtemp(prefix='herbert-hosted-apps-net-'))).resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    result = {'checks': [], 'not_tested': []}
    def passed(name, **details):
        result['checks'].append(dict(name=name, **details))
        print('PASS:', name, json.dumps(details, sort_keys=True) if details else '', flush=True)
        (evidence / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    if args.inside_namespace:
        try:
            inside_namespace(args, evidence, passed, result['not_tested'])
        except BaseException as error:
            result['failure'] = repr(error)
            raise
        finally:
            (evidence / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        return
    shutil.copyfile(__file__, evidence / 'check_net.py')
    shutil.copyfile(args.knock, evidence / 'knock.elf')
    combined = args.knock.parent / (args.knock.name + '-work') / 'source.herb'
    if combined.exists():
        shutil.copyfile(combined, evidence / 'knock-source.herb')
    result.update(image=static_elf(args.knock), rounds=args.rounds, only=args.only)
    print('Evidence:', evidence, flush=True)
    checks = {'refusals': refusal_checks, 'library': library_checks, 'syscalls': syscall_checks,
              'outcomes': outcome_checks, 'injected': injected_checks, 'leaks': leak_checks}
    try:
        for section in SECTIONS:
            if args.only not in ('all', section):
                continue
            if section == 'namespace':
                namespace_checks(args, evidence, passed, result['not_tested'], result)
            else:
                checks[section](args, evidence, passed)
        for line in result['not_tested']:
            print('NOT TESTED here:', line, flush=True)
        if os.environ.get('HERBERT_NET_REQUIRE_ALL') == '1':
            assert not result['not_tested'], ('HERBERT_NET_REQUIRE_ALL=1, but checks were not run',
                                              result['not_tested'])
    except BaseException as error:
        result['failure'] = repr(error)
        raise
    finally:
        (evidence / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(f'net: {len(result["checks"])}/{len(result["checks"])} PASS, {len(result["not_tested"])} not tested here; '
          f'evidence {evidence}')


if __name__ == '__main__':
    main()
