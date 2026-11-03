#!/usr/bin/env python3
"""Scope's helper's checks: examples/scope_helper.herb on this machine only, then Scope showing the real helper's figures.

Every connection here goes to an address in 127.x (all of 127/8 is this computer's loopback). The helper is started
by this check, on addresses and ports it picks, and stopped by its own process id; nothing contacts another computer.

- Command lines it cannot read (a wrong count of arguments, more than 4 allowed addresses, every malformed address
  and port check_net knows, in each place) are refused with exit status 2 and a plain message, under strace with
  socket() made to fail, so the trace shows no socket was even asked for. A socket it cannot make, and a port it
  cannot listen at (another program listens there), end it with status 1 and a line saying why.
- The exact reply for fixed files: through `--test`, for every /proc/stat and /proc/meminfo file of check_scope's
  `--sample` cases, the reply must carry exactly the figures check_scope's hand-written answers give for them, or
  `unavailable` for that half: the helper and Scope share one reader (lib/figures.herb). All four shapes of the line
  must come up. Then the real /proc: MEMTOTAL must be /proc/meminfo's, and TOTAL lie between /proc/stat's read just
  before and just after.
- The allow-list: from each of four allowed 127.x addresses a reply; from 127.x addresses not on it, the listening
  address itself included, a connection that is taken and closed with not one byte.
- Under strace: the listening socket's set-up (SO_REUSEADDR, bind to exactly the given address and port), every
  accept4 with SOCK_NONBLOCK|SOCK_CLOEXEC, and on each accepted socket nothing but one sendto with
  MSG_DONTWAIT|MSG_NOSIGNAL (allowed peers) or nothing at all (others), then close: no read or receive of any kind,
  even from a client that sends bytes first; nothing written anywhere else.
- It listens on exactly the given address: the same port at other 127.x addresses is refused.
- SO_REUSEADDR: stopped while its last connection lingers in TIME_WAIT on its port (seen in /proc/net/tcp), it starts
  again at once on the same address and port.
- 64 clients that connect and never read hold nothing up: other clients are answered at once meanwhile, the helper
  keeps no socket of theirs, and each of them finds its whole reply waiting when it does read.
- 20,000 connections in one process (one in five from an address not allowed), stopping every 2,500 to look: its
  virtual size (VmSize) unchanged, resident memory (Rss) within 64 KiB, and the same descriptors throughout.
- An accept that fails does not spin: with strace failing every accept4 (EMFILE, ECONNABORTED, EINTR), at most 15
  accept4 calls in a second; and with a real EMFILE (its open files limited to 4) and a client waiting, at most
  0.05 s of processor time in 1.5 s, and the client answered once the limit is raised.
- End to end, on a private Xvfb display: the real helper on 127.x, reading files this check writes (`--test`), and
  Scope's window listing it: its row shows the processor's dash, then the exact figures as the files change, then
  `answers` once the helper is stopped (its port refused); and the real helper reading the real /proc, its row
  showing a processor figure and a memory figure that agrees with /proc/meminfo.

Python, strace, prlimit, Xvfb, libX11 and libXtst are test tools only; the helper links none of them. Evidence is
kept in /tmp/herbert-hosted-apps-scope-helper-*.
"""

if not __debug__:
    raise SystemExit('verification requires Python assertions; remove -O/-OO and PYTHONOPTIMIZE')

import argparse
import json
import os
from pathlib import Path
import re
import select
import shutil
import signal
import socket
import subprocess
import tempfile
import time

from check_desktop import private_display, XConnection
from check_desktop import memory as process_memory
from check_hosted_apps import stable_memory, static_elf, wait_for
from check_net import HIGH, Listener, LOOPBACK, MALFORMED_ADDRESSES, MALFORMED_PORTS, SPREAD
from check_scope import (ANSWER, CASES, FILES, FIRST, MEM_TYPICAL, STAT_ONE_1, STAT_ONE_2, Scope, computer_row,
                         empty_home, fixed_files, put, real_memory, section, show_until, stat_line)

ROOT = Path(__file__).resolve().parents[2]
ENV = {k: v for k, v in os.environ.items() if k not in ('DISPLAY', 'HOME')}
USAGE = (b'scope-helper: usage: scope-helper LISTEN_ADDRESS PORT ALLOWED_ADDRESS [ALLOWED_ADDRESS ...] '
         b'(1 to 4 allowed addresses)\n')
BAD_ADDRESS = b'scope-helper: not an IPv4 address; write four numbers 0 to 255 joined by dots, like 127.0.0.1\n'
BAD_PORT = b'scope-helper: not a port; write a number 1 to 65535\n'
REPLY = re.compile(rb'herbert-scope 1 (\d+) (\d+) (\d+) (\d+)\n')
LISTEN_AT = '127.0.0.9'                                 # where the helper listens in these checks
ALLOWED = ['127.0.0.1', '127.0.0.3', '127.0.0.4', '127.0.0.5']
NOT_ALLOWED = ['127.0.0.2', '127.0.0.6', LISTEN_AT, '127.1.0.1']


def free_port(address):
    """A port free at address a moment ago."""
    with socket.socket() as probe:
        probe.bind((address, 0))
        return probe.getsockname()[1]


def hexed(address, port):
    """address:port as /proc/net/tcp writes it."""
    return '%08X:%04X' % (int.from_bytes(socket.inet_aton(address), 'little'), port)


def tcp_states(address, port):
    """The states of this machine's TCP sockets at address:port, as /proc/net/tcp numbers them (0A listening, 06
    TIME_WAIT)."""
    local = hexed(address, port)
    return [line.split()[3] for line in Path('/proc/net/tcp').read_text().splitlines()[1:] if line.split()[1] == local]


class Helper:
    """build/scope-helper with arguments, run by this check; prefix runs it under another program (strace, prlimit)
    whose process is the helper's, or its parent. Its output goes to the evidence folder."""

    def __init__(self, args, evidence, label, argv, prefix=(), address=None, port=None):
        self.label = label
        self.out = (evidence / (label + '.stdout')).open('wb')
        self.err = (evidence / (label + '.stderr')).open('wb')
        self.evidence = evidence
        self.p = subprocess.Popen([*prefix, str(args.helper.resolve()), *argv], stdin=subprocess.DEVNULL,
                                  stdout=self.out, stderr=self.err, env=ENV)
        self.prefix = prefix
        if address is not None:
            try:
                wait_for(lambda: self.p.poll() is None and '0A' in tcp_states(address, port), label + ' listening', 10)
            except BaseException:
                self.stop()
                raise

    def pid(self):
        """The helper's own process: the one started, or, under strace, its one child."""
        if not self.prefix or self.prefix[0] != 'strace':
            return self.p.pid
        children = Path(f'/proc/{self.p.pid}/task/{self.p.pid}/children').read_text().split()
        assert len(children) == 1, ('strace has not exactly one child', children)
        return int(children[0])

    def stop(self):
        """SIGTERM to the helper (under strace, to strace's one child, the helper), then the status of the process
        this check started."""
        if self.p.poll() is None:
            os.kill(self.pid(), signal.SIGTERM)
        try:
            status = self.p.wait(10)
        except subprocess.TimeoutExpired:
            self.p.kill()
            status = self.p.wait(10)
        self.out.close()
        self.err.close()
        return status

    def stderr(self):
        return (self.evidence / (self.label + '.stderr')).read_bytes()


def ask(address, port, source=LOOPBACK, send=b'', timeout=5):
    """One connection from source to address:port: send these bytes first (if any), then read to the end. The bytes
    read, or the name of the error that ended the reading."""
    with socket.socket() as client:
        client.settimeout(timeout)
        client.bind((source, 0))
        client.connect((address, port))
        if send:
            client.sendall(send)
        data = b''
        while True:
            try:
                chunk = client.recv(4096)
            except ConnectionResetError:
                return data + b'<reset>'
            if not chunk:
                return data
            data += chunk


def descriptors(pid):
    return sorted(os.readlink(f'/proc/{pid}/fd/{fd}') for fd in os.listdir(f'/proc/{pid}/fd'))


def strace_lines(trace):
    """The trace's lines without their process ids, and with strace's padding before a result taken out."""
    return [re.sub(r'\) +=', ') =', re.sub(r'^\d+ +', '', line)) for line in trace.read_text().splitlines()]


def refusal_checks(args, evidence, passed):
    root = evidence / 'refusals'
    root.mkdir()
    good = [LOOPBACK, '4000', LOOPBACK]
    cases = [('none', [], USAGE), ('address-only', [LOOPBACK], USAGE), ('no-allowed', [LOOPBACK, '4000'], USAGE),
             ('five-allowed', [LOOPBACK, '4000'] + ALLOWED + ['127.0.0.7'], USAGE),
             ('test-alone', ['--test'], USAGE), ('test-no-allowed', ['--test', 'stat', 'meminfo', LOOPBACK, '4000'], USAGE),
             ('test-five-allowed', ['--test', 'stat', 'meminfo', LOOPBACK, '4000'] + ALLOWED + ['127.0.0.7'], USAGE),
             ('address-before-port', ['127.0.0.256', '0', LOOPBACK], BAD_ADDRESS),
             ('port-before-allowed', [LOOPBACK, '0', '127.0.0.256'], BAD_PORT),
             ('test-address', ['--test', 'stat', 'meminfo', '127.0.0.01', '4000', LOOPBACK], BAD_ADDRESS),
             ('test-port', ['--test', 'stat', 'meminfo', LOOPBACK, '65536', LOOPBACK], BAD_PORT),
             ('test-allowed', ['--test', 'stat', 'meminfo', LOOPBACK, '4000', 'localhost'], BAD_ADDRESS)]
    for n, address in enumerate(MALFORMED_ADDRESSES):
        cases.append((f'listen-address-{n}', [address, '4000', LOOPBACK], BAD_ADDRESS))
        cases.append((f'allowed-address-{n}', [LOOPBACK, '4000', LOOPBACK, address], BAD_ADDRESS))
    for n, port in enumerate(MALFORMED_PORTS):
        cases.append((f'port-{n}', [LOOPBACK, port, LOOPBACK], BAD_PORT))
    for label, argv, message in cases:
        trace = root / (label + '.strace')
        result = subprocess.run(['strace', '-f', '-qq', '-o', str(trace), '-e',
                                 'trace=socket,bind,listen,accept4,setsockopt', '-e', 'inject=socket:error=EPERM',
                                 str(args.helper.resolve()), *argv], stdin=subprocess.DEVNULL, capture_output=True,
                                timeout=30, env=ENV)
        assert (result.returncode, result.stdout, result.stderr) == (2, b'', message), (label, argv, result)
        assert trace.read_text() == '', ('a socket was asked for before the refusal', label, trace.read_text())
    passed('scope-helper-refuses-malformed-before-any-socket', command_lines=len(cases),
           addresses=len(MALFORMED_ADDRESSES), ports=len(MALFORMED_PORTS), socket_calls_seen=0)
    # A good command line with socket() failing, and a port another program listens at: status 1 and why.
    result = subprocess.run(['strace', '-f', '-qq', '-o', str(root / 'no-socket.strace'), '-e', 'trace=socket', '-e',
                             'inject=socket:error=EMFILE', str(args.helper.resolve()), *good], stdin=subprocess.DEVNULL,
                            capture_output=True, timeout=30, env=ENV)
    assert (result.returncode, result.stdout, result.stderr) == (
        1, b'', b'scope-helper: cannot make a socket (Linux error 24)\n'), result
    taken = Listener(HIGH)
    try:
        result = subprocess.run([str(args.helper.resolve()), HIGH, str(taken.port), LOOPBACK],
                                stdin=subprocess.DEVNULL, capture_output=True, timeout=30, env=ENV)
    finally:
        taken.close()
    assert (result.returncode, result.stdout, result.stderr) == (
        1, b'', b'scope-helper: cannot listen at that address and port (Linux error 98)\n'), result
    passed('scope-helper-says-why-it-cannot-start', no_socket='Linux error 24', port_taken='Linux error 98', status=1)


def expected_reply(stat, meminfo):
    """The reply for a stat file and a meminfo file whose --sample answers (check_scope) are stat and meminfo."""
    return b'herbert-scope 1 %s %s\n' % (stat.encode(), meminfo.encode())


def point(link, target):
    """link names target, or nothing when target is None; changed in one step."""
    if target is None:
        if link.is_symlink():
            link.unlink()
        return
    spare = link.with_name(link.name + '.new')
    os.symlink(target, spare)
    os.replace(spare, link)


def reply_checks(args, evidence, passed):
    """Every /proc/stat and /proc/meminfo file of check_scope's --sample cases through the helper: the reply must
    carry the figures check_scope's hand-written answers give for them."""
    root = evidence / 'replies'
    links = root / 'links'
    links.mkdir(parents=True)
    port = free_port(HIGH)
    helper = Helper(args, evidence, 'scope-helper-replies',
                    ['--test', str(links / 'stat'), str(links / 'meminfo'), HIGH, str(port), LOOPBACK], address=HIGH,
                    port=port)
    shapes, count = set(), 0
    try:
        for name, files, changes in CASES:
            directory = root / name
            directory.mkdir()
            answer = dict(ANSWER, **changes)
            stats = sorted((key for key in set(FILES) | set(files) if key.startswith('stat')), key=lambda k: int(k[4:]))
            meminfo = files.get('meminfo', FILES['meminfo'])
            if meminfo is not None:
                (directory / 'meminfo').write_bytes(meminfo)
            point(links / 'meminfo', None if meminfo is None else directory / 'meminfo')
            for key in stats:
                data = files.get(key, FILES.get(key))
                if data is not None:
                    (directory / key).write_bytes(data)
                point(links / 'stat', None if data is None else directory / key)
                got = ask(HIGH, port)
                want = expected_reply(answer[key], answer['meminfo'])
                assert got == want, (name, key, got, want)
                shapes.add((answer[key] == 'unavailable', answer['meminfo'] == 'unavailable'))
                count += 1
    finally:
        status = helper.stop()
    assert status in (-signal.SIGTERM, 128 + signal.SIGTERM) and helper.stderr() == b'', (status, helper.stderr())
    assert shapes == {(False, False), (True, False), (False, True), (True, True)}, ('not every shape of reply', shapes)
    passed('scope-helper-replies-with-scopes-own-figures', cases=len(CASES), replies=count,
           shapes=['both', 'processor unavailable', 'memory unavailable', 'both unavailable'])
    # The real /proc.
    port = free_port(HIGH)
    helper = Helper(args, evidence, 'scope-helper-real-proc', [HIGH, str(port), LOOPBACK], address=HIGH, port=port)
    try:
        def totals():
            fields = Path('/proc/stat').read_text().split('\n', 1)[0].split()
            assert fields[0] == 'cpu', fields
            return sum(int(n) for n in fields[1:9])
        before = totals()
        memory_before = real_memory()
        got = ask(HIGH, port)
        memory_after = real_memory()
        after = totals()
    finally:
        helper.stop()
    m = REPLY.fullmatch(got)
    assert m, got
    total, busy, mem_total, available = (int(g) for g in m.groups())
    assert before <= total <= after and busy <= total, (before, total, after, busy)
    assert mem_total == memory_before[0] == memory_after[0], (mem_total, memory_before, memory_after)
    assert min(memory_before[1], memory_after[1]) - 65536 <= available <= max(memory_before[1], memory_after[1]) + 65536
    passed('scope-helper-reads-the-real-proc', reply=got.decode().strip(), total_between=[before, after],
           mem_total_matches=True)


def allow_checks(args, evidence, passed):
    """The allow-list, and under strace what the helper does with each connection."""
    port = free_port(LISTEN_AT)
    trace = evidence / 'scope-helper-connections.strace'
    prefix = ['strace', '-f', '-qq', '-s', '128', '-o', str(trace), '-e',
              'trace=socket,setsockopt,bind,listen,accept4,read,readv,pread64,preadv,preadv2,recvfrom,recvmsg,'
              'recvmmsg,write,writev,pwrite64,sendto,sendmsg,sendmmsg,openat,open,close,exit_group']
    helper = Helper(args, evidence, 'scope-helper-allowed', [LISTEN_AT, str(port), *ALLOWED], prefix=prefix,
                    address=LISTEN_AT, port=port)
    got = {}
    try:
        for source in ALLOWED:
            got[source] = ask(LISTEN_AT, port, source)
            assert REPLY.fullmatch(got[source]), (source, got[source])
        for source in NOT_ALLOWED:
            got[source] = ask(LISTEN_AT, port, source)
            assert got[source] == b'', ('a peer not allowed got bytes', source, got[source])
        # A client that sends first: the helper never reads, so its close comes as a reset; the reply was sent first.
        sent = ask(LISTEN_AT, port, ALLOWED[0], b'GET / HTTP/1.0\r\n\r\n' * 4)
        assert sent.endswith(b'<reset>') or REPLY.fullmatch(sent), sent
    finally:
        status = helper.stop()
    assert helper.stderr() == b'', helper.stderr()
    lines = strace_lines(trace)
    setup = [line for line in lines if line.startswith(('socket(', 'setsockopt(', 'bind(', 'listen('))]
    assert setup == ['socket(AF_INET, SOCK_STREAM|SOCK_CLOEXEC, IPPROTO_TCP) = 3',
                     'setsockopt(3, SOL_SOCKET, SO_REUSEADDR, [1], 4) = 0',
                     f'bind(3, {{sa_family=AF_INET, sin_port=htons({port}), sin_addr=inet_addr("{LISTEN_AT}")}}, 16) = 0',
                     'listen(3, 16) = 0'], setup
    accepted, open_now, writes = [], {}, []
    pattern = re.compile(r'accept4\(3, \{sa_family=AF_INET, sin_port=htons\(\d+\), sin_addr=inet_addr\("([\d.]+)"\)\}, '
                         r'\[16\], SOCK_CLOEXEC\|SOCK_NONBLOCK\) = (\d+)')
    for line in lines:
        if (m := pattern.fullmatch(line)):
            fd = int(m.group(2))
            open_now[fd] = {'peer': m.group(1), 'calls': []}
            accepted.append(open_now[fd])
            continue
        # The accept4 under way when the helper is stopped never returns.
        assert not line.startswith('accept4(') or line.endswith('= ? ERESTARTSYS (To be restarted if SA_RESTART is set)'), (
            'an accept4 not as expected', line)
        call = re.match(r'(\w+)\((\d+)', line)
        if call and int(call.group(2)) in open_now:
            fd = int(call.group(2))
            if call.group(1) == 'close':
                open_now.pop(fd)['calls'].append('close')
            else:
                open_now[fd]['calls'].append(line)
        elif call and call.group(1) in ('write', 'writev', 'pwrite64', 'sendto', 'sendmsg', 'sendmmsg'):
            writes.append(line)
        if line.startswith(('openat(', 'open(')):
            assert 'O_RDONLY' in line and 'O_WRONLY' not in line and 'O_RDWR' not in line and 'O_CREAT' not in line, line
    assert writes == [], ('the helper wrote somewhere other than a connection', writes)
    assert [a['peer'] for a in accepted] == ALLOWED + NOT_ALLOWED + [ALLOWED[0]], [a['peer'] for a in accepted]
    for a in accepted:
        if a['peer'] in ALLOWED:
            assert len(a['calls']) == 2 and re.fullmatch(
                r'sendto\(\d+, "herbert-scope 1 [\d ]+\\n", (\d+), MSG_DONTWAIT\|MSG_NOSIGNAL, NULL, 0\) = \1',
                a['calls'][0]) and a['calls'][1] == 'close', ('not one sendto and close', a)
        else:
            assert a['calls'] == ['close'], ('a peer not allowed got more than a close', a)
    passed('scope-helper-answers-only-allowed-addresses', allowed=ALLOWED, not_allowed_got_zero_bytes=NOT_ALLOWED)
    passed('scope-helper-never-reads-a-connection', connections=len(accepted),
           on_each=['sendto MSG_DONTWAIT|MSG_NOSIGNAL, close (allowed)', 'close (not allowed)'],
           client_that_sent_first=('reset after its reply' if sent.endswith(b'<reset>') else 'its reply'),
           setup=setup, writes_elsewhere=0)


def address_checks(args, evidence, passed):
    """Exactly the given address; and a restart at once on the same port while TIME_WAIT lingers."""
    port = free_port(LISTEN_AT)
    argv = [LISTEN_AT, str(port), LOOPBACK]
    helper = Helper(args, evidence, 'scope-helper-exact', argv, address=LISTEN_AT, port=port)
    refused = []
    try:
        assert REPLY.fullmatch(ask(LISTEN_AT, port)), 'no reply at the listening address'
        for other in (LOOPBACK, '127.0.0.10', SPREAD, HIGH):
            try:
                ask(other, port)
            except ConnectionRefusedError:
                refused.append(other)
        listening = [line.split()[1] for line in Path('/proc/net/tcp').read_text().splitlines()[1:]
                     if line.split()[3] == '0A' and line.split()[1].endswith(':%04X' % port)]
        lingering = tcp_states(LISTEN_AT, port)
    finally:
        status = helper.stop()
    assert refused == [LOOPBACK, '127.0.0.10', SPREAD, HIGH], refused
    assert listening == [hexed(LISTEN_AT, port)], listening
    passed('scope-helper-listens-on-exactly-its-address', address=LISTEN_AT, refused_at=refused)
    # The helper closes first, so its side of that last connection waits out TIME_WAIT on its port: without
    # SO_REUSEADDR a new listener could not bind it for a minute.
    assert '06' in lingering, ('no connection in TIME_WAIT on the helper port; the restart would prove nothing',
                               lingering)
    again = Helper(args, evidence, 'scope-helper-restarted', argv, address=LISTEN_AT, port=port)
    try:
        assert '06' in tcp_states(LISTEN_AT, port), 'TIME_WAIT ended before the restart'
        assert REPLY.fullmatch(ask(LISTEN_AT, port)), 'no reply after the restart'
    finally:
        again.stop()
    assert again.stderr() == b'', again.stderr()
    passed('scope-helper-restarts-at-once', time_wait_on_its_port=True, first_status=status)


def idle_checks(args, evidence, passed):
    """Clients that connect and never read hold nothing up."""
    port = free_port(LISTEN_AT)
    helper = Helper(args, evidence, 'scope-helper-idle', [LISTEN_AT, str(port), LOOPBACK], address=LISTEN_AT,
                    port=port)
    idle, timings = [], []
    try:
        steady = descriptors(helper.pid())
        for _ in range(64):
            client = socket.socket()
            idle.append(client)
            # A helper held by an idle client stops taking connections; this fails then rather than waiting for ever.
            client.settimeout(10)
            client.bind((LOOPBACK, 0))
            client.connect((LISTEN_AT, port))
        # The timing starts once every idle client has its reply waiting, unread: the helper has taken them all,
        # written and closed, and none of them read a byte. Timed earlier, a slow machine times the helper still
        # working through the burst in its accept queue of 16, not idle clients holding it (CI, 2026-11-03: the first
        # timed connection took 1.02 s, the other nine 0.0001 s).
        wait_for(lambda: len(select.select(idle, [], [], 0)[0]) == len(idle),
                 'every idle client has its reply waiting, unread', 30)
        for _ in range(10):
            started = time.monotonic()
            assert REPLY.fullmatch(ask(LISTEN_AT, port, timeout=2))
            timings.append(round(time.monotonic() - started, 4))
        wait_for(lambda: descriptors(helper.pid()) == steady, 'the helper keeps no socket of the idle clients', 2)
        for client in idle:
            client.settimeout(2)
            data = b''
            while (chunk := client.recv(4096)):
                data += chunk
            assert REPLY.fullmatch(data), data
    finally:
        for client in idle:
            client.close()
        helper.stop()
    assert max(timings) < .5, timings
    passed('scope-helper-not-held-by-clients-that-never-read', idle_clients=64, answered_meanwhile_s=timings,
           descriptors=steady)


def flood_checks(args, evidence, passed):
    """20,000 connections, one in five not allowed: memory and descriptors flat."""
    port = free_port(LISTEN_AT)
    helper = Helper(args, evidence, 'scope-helper-flood', [LISTEN_AT, str(port), *ALLOWED], address=LISTEN_AT,
                    port=port)
    total, every, samples = 20000, 2500, []
    sources = ALLOWED + ['127.0.0.2']
    try:
        pid = helper.pid()
        for n in range(1, total + 1):
            source = sources[n % len(sources)]
            got = ask(LISTEN_AT, port, source)
            if source == '127.0.0.2':
                assert got == b'', (n, got)
            else:
                assert REPLY.fullmatch(got), (n, got)
            if n % every == 0:
                sample = process_memory(pid)
                sample['connections'] = n
                sample['descriptors'] = descriptors(pid)
                samples.append(sample)
                (evidence / 'scope-helper-flood.json').write_text(json.dumps(samples, indent=2) + '\n')
                assert sample['descriptors'] == samples[0]['descriptors'], ('descriptors changed', sample)
        assert helper.p.poll() is None, 'the helper ended'
    finally:
        helper.stop()
    assert helper.stderr() == b''
    stable_memory(samples, 'scope-helper answering 20,000 connections')
    rss = [s['Rss'] for s in samples]
    passed('scope-helper-memory-flat', connections=total, not_allowed=total // len(sources), samples=len(samples),
           measured_connections=total - every, vm_size_kib=samples[0]['VmSize'], vm_size_must_not_change=True,
           rss_kib_first=rss[0], rss_kib_last=rss[-1], rss_kib_min=min(rss), rss_kib_max=max(rss),
           rss_tolerance_kib=64, descriptors=samples[0]['descriptors'])


def spin_checks(args, evidence, passed):
    """A failed accept is followed by a pause: strace-injected errors, and a real EMFILE."""
    counts = {}
    for error in ('EMFILE', 'ECONNABORTED', 'EINTR'):
        port = free_port(LISTEN_AT)
        trace = evidence / f'scope-helper-accept-{error}.strace'
        helper = Helper(args, evidence, f'scope-helper-accept-{error}', [LISTEN_AT, str(port), LOOPBACK],
                        prefix=['strace', '-f', '-qq', '-ttt', '-o', str(trace), '-e', 'trace=accept4,nanosleep',
                                '-e', f'inject=accept4:error={error}'], address=LISTEN_AT, port=port)
        try:
            time.sleep(1.6)
        finally:
            helper.stop()
        calls = []
        for line in strace_lines(trace):
            m = re.match(r'(\d+\.\d+) accept4\(3, .*\) = -1 ' + error + r' .*\(INJECTED\)', line)
            if m:
                calls.append(float(m.group(1)))
            elif ' accept4(' in line and 'resumed' not in line and 'unfinished' not in line:
                raise AssertionError(('an accept4 not failed by strace', line))
        pauses = [line for line in strace_lines(trace) if 'nanosleep({tv_sec=0, tv_nsec=100000000}' in line]
        assert len(calls) >= 5, (error, 'too few accepts to judge', calls)
        window = [t for t in calls if calls[0] + .25 <= t < calls[0] + 1.25]
        assert len(window) <= 15, (error, 'accept4 spun', len(window))
        assert len(pauses) >= len(calls) - 1, (error, 'not a pause after each failed accept', len(pauses), len(calls))
        counts[error] = len(window)
    passed('scope-helper-does-not-spin-on-accept-errors', accept4_calls_in_one_second=counts, pause_ms=100,
           how='strace fails every accept4')
    # A real EMFILE: open files limited to 4 (0, 1, 2 and the listening socket; the hard limit stays above, so that
    # the limit can be raised again), a client waiting in the queue, so every accept4 fails at once for as long as
    # the limit stands.
    port = free_port(LISTEN_AT)
    helper = Helper(args, evidence, 'scope-helper-real-emfile', [LISTEN_AT, str(port), LOOPBACK],
                    prefix=['prlimit', '--nofile=4:64', '--'], address=LISTEN_AT, port=port)
    client = socket.socket()
    try:
        client.settimeout(5)
        client.bind((LOOPBACK, 0))
        client.connect((LISTEN_AT, port))
        def cpu():
            fields = Path(f'/proc/{helper.p.pid}/stat').read_text().rsplit(')', 1)[1].split()
            return (int(fields[11]) + int(fields[12])) / os.sysconf('SC_CLK_TCK')
        time.sleep(.2)
        used = cpu()
        time.sleep(1.5)
        used = cpu() - used
        status = Path(f'/proc/{helper.p.pid}/status').read_text()
        assert helper.p.poll() is None, 'the helper ended'
        subprocess.run(['prlimit', f'--pid={helper.p.pid}', '--nofile=64:64'], check=True, timeout=10)
        started = time.monotonic()
        data = b''
        while (chunk := client.recv(4096)):
            data += chunk
        answered = time.monotonic() - started
    finally:
        client.close()
        helper.stop()
    assert used <= .05, ('the helper used the processor while accept4 failed', used)
    assert REPLY.fullmatch(data) and answered < 1, (data, answered)
    switches = re.search(r'voluntary_ctxt_switches:\s+(\d+)', status).group(1)
    passed('scope-helper-does-not-spin-at-a-real-emfile', open_files_limit=4, processor_seconds_in_1_5_s=used,
           answered_after_the_limit_was_raised_s=round(answered, 3), voluntary_switches=int(switches))


def window_checks(args, evidence, passed):
    """Scope's window and the real helper, on a private display."""
    with private_display(evidence, size='1280x900') as display:
        x = XConnection(display)
        try:
            # The helper reads files this check writes, so the figures are exact.
            links = evidence / 'end-to-end-links'
            links.mkdir()
            stat, meminfo = links / 'stat', links / 'meminfo'
            put(stat, STAT_ONE_1)
            put(meminfo, MEM_TYPICAL)
            port = free_port(SPREAD)
            helper = Helper(args, evidence, 'scope-helper-end-to-end',
                            ['--test', str(stat), str(meminfo), SPREAD, str(port), LOOPBACK], address=SPREAD, port=port)
            scope_stat, scope_mem, scope_host = fixed_files(evidence, 'end-to-end-scope-files')
            computers = evidence / 'end-to-end-scope-files' / 'computers.txt'
            computers.write_text(f'noggin {SPREAD} {port}\n')
            app = Scope(args.scope, ['--test', scope_stat, scope_mem, scope_host, '1000', str(computers), '500', '400'],
                        x, display, evidence, 'scope-end-to-end', empty_home(evidence, 'end-to-end'))
            steps = []
            try:
                def step(row, what):
                    show_until(app, {'others': [computer_row('noggin', row)]}, what, 6)
                    steps.append(f'{what}: {row}')
                step(FIRST, 'the first reply')
                put(stat, STAT_ONE_2)
                step('CPU 40%  MEM 75%', 'the helper\'s /proc/stat moved on')
                app.frame('figures')
                put(stat, stat_line(2300, 0, 600, 8550, 550, 0, 0, 0, 0, 0))
                put(meminfo, b'MemTotal:  524288 kB\nMemAvailable:  104858 kB\n')
                step('CPU 100%  MEM 80%', 'busy and memory changed')
                helper.stop()
                step('answers', 'the helper stopped')
                app.tap('Escape')
                app.finish()
            finally:
                app.close()
                helper.stop()
            passed('scope-shows-the-real-helpers-figures', steps=steps)
            # The real /proc.
            port = free_port(HIGH)
            helper = Helper(args, evidence, 'scope-helper-end-to-end-real', [HIGH, str(port), LOOPBACK], address=HIGH,
                            port=port)
            computers.write_text(f'here {HIGH} {port}\n')
            app = Scope(args.scope, ['--test', scope_stat, scope_mem, scope_host, '1000', str(computers), '500', '400'],
                        x, display, evidence, 'scope-end-to-end-real', empty_home(evidence, 'end-to-end-real'))
            try:
                seen = {}
                def figures():
                    row = section(app.frame())[0]
                    seen['row'] = row
                    m = re.fullmatch(r'CPU (\d{1,3})%  MEM (\d{1,3})%', row[3][0])
                    if not m:
                        return False
                    total, available = real_memory()
                    percent = round(100 * (total - available) / total)
                    seen['memory'] = (int(m.group(2)), percent)
                    return abs(int(m.group(2)) - percent) <= 2 and int(m.group(1)) <= 100
                wait_for(figures, 'the real helper\'s figures', 6)
                app.frame('real')
                app.tap('Escape')
                app.finish()
            finally:
                app.close()
                helper.stop()
            passed('scope-shows-the-real-helpers-real-figures', row=seen['row'][3][0],
                   memory_percent_and_proc_meminfo=seen['memory'])
        finally:
            x.close()


SECTIONS = ('refusals', 'replies', 'allowed', 'address', 'idle', 'flood', 'spin', 'window')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--helper', type=Path, default=ROOT / 'build/scope-helper')
    parser.add_argument('--scope', type=Path, default=ROOT / 'build/scope')
    parser.add_argument('--only', choices=['all', *SECTIONS], default='all')
    parser.add_argument('--evidence', type=Path)
    args = parser.parse_args()
    assert shutil.which('strace') and shutil.which('prlimit'), 'strace and prlimit are required (test tools)'
    evidence = (args.evidence or Path(tempfile.mkdtemp(prefix='herbert-hosted-apps-scope-helper-'))).resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(__file__, evidence / 'check_scope_helper.py')
    shutil.copyfile(args.helper, evidence / 'scope-helper.elf')
    combined = args.helper.parent / (args.helper.name + '-work') / 'source.herb'
    if combined.exists():
        shutil.copyfile(combined, evidence / 'scope-helper-source.herb')
    result = {'helper': static_elf(args.helper), 'scope': static_elf(args.scope), 'only': args.only, 'checks': []}
    def passed(name, **details):
        result['checks'].append(dict(name=name, **details))
        print('PASS:', name, json.dumps(details, sort_keys=True) if details else '', flush=True)
        (evidence / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print('Evidence:', evidence, flush=True)
    checks = {'refusals': refusal_checks, 'replies': reply_checks, 'allowed': allow_checks, 'address': address_checks,
              'idle': idle_checks, 'flood': flood_checks, 'spin': spin_checks, 'window': window_checks}
    try:
        for section in SECTIONS:
            if args.only in ('all', section):
                checks[section](args, evidence, passed)
    except BaseException as error:
        result['failure'] = repr(error)
        raise
    finally:
        (evidence / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(f'scope-helper: {len(result["checks"])}/{len(result["checks"])} PASS; evidence {evidence}')


if __name__ == '__main__':
    main()
