#!/usr/bin/env python3
"""Lookout's checks: its figures against hand-written answers, then its window on a private display.

Part one runs `lookout --sample STAT1 STAT2 MEMINFO HOSTNAME` on fixed input files and compares every line it prints
with an answer written here by hand: one-processor and 64-processor /proc/stat files, old and new kernels' field
counts, meminfo fields missing, reordered or malformed, and the edges of the arithmetic (0 %, 100 %, half a percent,
a zero-length interval, counters that did not move or went back, numbers at and past 2^64, tenths that carry).

Part two opens the window on a private Xvfb display and drives it with XTest: the window appears, draws this
machine's name and both figures (read back from its pixels against /proc), redraws, and quits on Escape, on q and on
the window manager's close. With `--test` it reads files this check writes, so the exact text and bar lengths are
checked for known figures, and for files that vanish (the "unavailable" state) and come back. Last, it reads the real
/proc files every 10 ms for --seconds (default 120) and must stay the same size in memory.

Python, Xvfb, libX11 and libXtst are test tools only; Lookout links none of them. Evidence (frames, input history,
outputs, memory samples) is kept in /tmp/herbert-hosted-apps-lookout-*.
"""

if not __debug__:
    raise SystemExit('verification requires Python assertions; remove -O/-OO and PYTHONOPTIMIZE')

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time

from check_desktop import private_display, XConnection
from check_desktop import memory as process_memory
from check_hosted_apps import App, glyphs, stable_memory, static_elf, wait_for

ROOT = Path(__file__).resolve().parents[2]
TITLE, SIZE = b'Herbert - Lookout', (640, 370)

# Colours and places from examples/lookout.herb (lookout_draw, lookout_row).
BACKGROUND, PANEL, TRACK = 1054759, 1384240, 2767956
WHITE, AMBER, GREY = 15265527, 16173151, 11255503
CPU_FILL, MEMORY_FILL = 6867876, 7317724
HOST_AT = (28, 96)
CPU_ROW, MEMORY_ROW = 146, 212          # a row's label; its bar is 22 below, its figure 26 below at x=464
BAR_X, BAR_LENGTH = 46, 400
DETAIL_AT = (46, 270)


def stat_line(*fields):
    return b'cpu  ' + b' '.join(str(n).encode() for n in fields) + b'\n'


# A one-processor /proc/stat, laid out as Linux writes it (proc_stat(5)).
STAT_ONE_TAIL = (b'cpu0 %s\nintr 114930548 113199788 3 0 5 263 0 4 0 0 0 0 0 0 0 0\nctxt 1990473\n'
                 b'btime 1062191376\nprocesses 2915\nprocs_running 1\nprocs_blocked 0\n'
                 b'softirq 183433 0 21755 12 39 0 0 0 0 1 161626\n')
STAT_ONE_1 = stat_line(1000, 0, 500, 8000, 500, 0, 0, 0, 0, 0) + STAT_ONE_TAIL % b'1000 0 500 8000 500 0 0 0 0 0'
STAT_ONE_2 = stat_line(1300, 0, 600, 8550, 550, 0, 0, 0, 0, 0) + STAT_ONE_TAIL % b'1300 0 600 8550 550 0 0 0 0 0'


def stat_many(*fields):
    """64 processors and an interrupt line of about 18 KB, longer than Lookout's 4096-byte reads."""
    cpus = b''.join(b'cpu%d 100000 0 25000 875000 0 0 0 0 0 0\n' % n for n in range(64))
    return stat_line(*fields) + cpus + b'intr ' + b' '.join(b'%d' % (n * 7) for n in range(4000)) + b'\nctxt 9\n'


MEM_TYPICAL = b"""MemTotal:       16384000 kB
MemFree:         1024000 kB
MemAvailable:    4096000 kB
Buffers:          204800 kB
Cached:          2867200 kB
SwapCached:            0 kB
Active:          8192000 kB
Inactive:        4096000 kB
SwapTotal:       2097148 kB
SwapFree:        2097148 kB
Dirty:               128 kB
AnonPages:       6144000 kB
Shmem:            512000 kB
KReclaimable:     409600 kB
Slab:             614400 kB
VmallocTotal:   34359738367 kB
HugePages_Total:       0
HugePages_Free:        0
Hugepagesize:       2048 kB
DirectMap4k:      524288 kB
DirectMap2M:    16252928 kB
"""


def meminfo(total, available, *, before=b'', between=b'', after=b''):
    return before + b'MemTotal:       %d kB\n' % total + between + b'MemAvailable:   %d kB\n' % available + after


# Every case starts from these four files and this answer, then changes what it names. Each answer was worked out
# by hand from the case's own numbers: busy = total - idle - iowait, where total is the first eight fields; the
# figure is the change in busy over the change in total, to the nearest percent; a bar is four pixels a percent.
FILES = {'stat1': STAT_ONE_1, 'stat2': STAT_ONE_2, 'meminfo': MEM_TYPICAL, 'host': b'test-host\n'}
ANSWER = {'stat1': '10000 1500', 'stat2': '11000 1900', 'meminfo': '16384000 4096000', 'host': 'test-host',
          'processor': '40%', 'processor-bar': '160', 'memory': '75%', 'memory-bar': '300',
          'detail': '11.7 GiB of 15.6 GiB in use'}
UNREADABLE = {'processor': 'unavailable', 'processor-bar': '0'}
NO_MEMORY = {'meminfo': 'unavailable', 'memory': 'unavailable', 'memory-bar': '0', 'detail': ''}
LONG_LINE = b'intr ' + b'0 ' * 10000 + b'\n'
STRADDLE = b'intr ' + b'7' * 4084 + b'\n'          # 4090 bytes, so the cpu line crosses the first 4096-byte read

CASES = [
    # name, files that differ, answer lines that differ
    ('one-processor', {}, {}),
    ('64-processors-and-an-18-KB-line', {'stat1': stat_many(6400000, 0, 1600000, 56000000, 0, 0, 0, 0, 0, 0),
                                         'stat2': stat_many(6464000, 0, 1616000, 56320000, 0, 0, 0, 0, 0, 0)},
     {'stat1': '64000000 8000000', 'stat2': '64400000 8080000', 'processor': '20%', 'processor-bar': '80'}),
    ('guest-time-is-inside-user-already', {'stat1': stat_line(100, 0, 0, 900, 0, 0, 0, 0, 50, 50),
                                           'stat2': stat_line(200, 0, 0, 1000, 0, 0, 0, 0, 150, 50)},
     {'stat1': '1000 100', 'stat2': '1200 200', 'processor': '50%', 'processor-bar': '200'}),
    ('irq-softirq-and-steal-are-busy', {'stat1': stat_line(0, 0, 0, 1000, 0, 0, 0, 0, 0, 0),
                                        'stat2': stat_line(0, 0, 0, 1100, 0, 20, 30, 50, 0, 0)},
     {'stat1': '1000 0', 'stat2': '1200 100', 'processor': '50%', 'processor-bar': '200'}),
    ('four-fields-of-an-old-kernel', {'stat1': b'cpu 10 0 10 80\n', 'stat2': b'cpu 20 0 20 160\n'},
     {'stat1': '100 20', 'stat2': '200 40', 'processor': '20%', 'processor-bar': '80'}),
    ('iowait-is-not-busy', {'stat1': stat_line(100, 0, 0, 800, 100, 0, 0, 0, 0, 0),
                            'stat2': stat_line(100, 0, 0, 800, 1100, 0, 0, 0, 0, 0)},
     {'stat1': '1000 100', 'stat2': '2000 100', 'processor': '0%', 'processor-bar': '0'}),
    ('zero-length-interval', {'stat2': STAT_ONE_1},
     {'stat2': '10000 1500', 'processor': '-', 'processor-bar': '0'}),
    ('busy-counters-did-not-move', {'stat1': stat_line(500, 0, 500, 1000, 0, 0, 0, 0, 0, 0),
                                    'stat2': stat_line(500, 0, 500, 3000, 0, 0, 0, 0, 0, 0)},
     {'stat1': '2000 1000', 'stat2': '4000 1000', 'processor': '0%', 'processor-bar': '0'}),
    ('idle-counters-did-not-move', {'stat1': stat_line(500, 0, 500, 1000, 0, 0, 0, 0, 0, 0),
                                    'stat2': stat_line(1500, 0, 500, 1000, 0, 0, 0, 0, 0, 0)},
     {'stat1': '2000 1000', 'stat2': '3000 2000', 'processor': '100%', 'processor-bar': '400'}),
    ('half-a-percent-rounds-up', {'stat1': stat_line(0, 0, 0, 0, 0, 0, 0, 0, 0, 0),
                                  'stat2': stat_line(1, 0, 0, 199, 0, 0, 0, 0, 0, 0)},
     {'stat1': '0 0', 'stat2': '200 1', 'processor': '1%', 'processor-bar': '4'}),
    ('just-under-half-a-percent', {'stat1': stat_line(0, 0, 0, 0, 0, 0, 0, 0, 0, 0),
                                   'stat2': stat_line(1, 0, 0, 200, 0, 0, 0, 0, 0, 0)},
     {'stat1': '0 0', 'stat2': '201 1', 'processor': '0%', 'processor-bar': '0'}),
    ('two-thirds', {'stat1': stat_line(0, 0, 0, 0, 0, 0, 0, 0, 0, 0), 'stat2': stat_line(2, 0, 0, 1, 0, 0, 0, 0, 0, 0)},
     {'stat1': '0 0', 'stat2': '3 2', 'processor': '67%', 'processor-bar': '268'}),
    ('99.5-percent-shows-100', {'stat1': stat_line(0, 0, 0, 0, 0, 0, 0, 0, 0, 0),
                                'stat2': stat_line(199, 0, 0, 1, 0, 0, 0, 0, 0, 0)},
     {'stat1': '0 0', 'stat2': '200 199', 'processor': '100%', 'processor-bar': '400'}),
    ('counters-went-back-start-again', {'stat1': STAT_ONE_2, 'stat2': STAT_ONE_1},
     {'stat1': '11000 1900', 'stat2': '10000 1500', 'processor': '-', 'processor-bar': '0'}),
    ('busy-went-back-counts-none', {'stat1': stat_line(100, 0, 0, 800, 100, 0, 0, 0, 0, 0),
                                    'stat2': stat_line(50, 0, 0, 1000, 100, 0, 0, 0, 0, 0)},
     {'stat1': '1000 100', 'stat2': '1150 50', 'processor': '0%', 'processor-bar': '0'}),
    ('counters-near-2^64', {'stat1': stat_line(4611686018427387904, 0, 0, 4611686018427387904, 0, 0, 0, 0, 0, 0),
                            'stat2': stat_line(6917529027641081856, 0, 0, 6917529027641081856, 0, 0, 0, 0, 0, 0)},
     {'stat1': '9223372036854775808 4611686018427387904', 'stat2': '13835058055282163712 6917529027641081856',
      'processor': '50%', 'processor-bar': '200'}),
    ('largest-number', {'stat1': b'cpu  18446744073709551615 0 0 0\n', 'stat2': b'cpu  18446744073709551615 0 0 0\n'},
     {'stat1': '18446744073709551615 18446744073709551615', 'stat2': '18446744073709551615 18446744073709551615',
      'processor': '-', 'processor-bar': '0'}),
    ('number-past-2^64', {'stat2': b'cpu  18446744073709551616 0 0 0\n'}, {'stat2': 'unavailable', **UNREADABLE}),
    ('total-past-2^64', {'stat2': b'cpu  18446744073709551615 1 0 0\n'}, {'stat2': 'unavailable', **UNREADABLE}),
    ('letter-in-a-field', {'stat2': b'cpu  100 0 x0 800 0 0 0 0 0 0\n'}, {'stat2': 'unavailable', **UNREADABLE}),
    ('three-fields', {'stat2': b'cpu  100 0 0\n'}, {'stat2': 'unavailable', **UNREADABLE}),
    ('label-alone', {'stat2': b'cpu\nintr 5\n'}, {'stat2': 'unavailable', **UNREADABLE}),
    ('no-cpu-line', {'stat2': b'cpu0 1 2 3 4\ncpux 1 2 3 4\nintr 1 2 3\n'}, {'stat2': 'unavailable', **UNREADABLE}),
    ('empty-stat', {'stat2': b''}, {'stat2': 'unavailable', **UNREADABLE}),
    ('missing-stat', {'stat2': None}, {'stat2': 'unavailable', **UNREADABLE}),
    ('first-sample-missing', {'stat1': None}, {'stat1': 'unavailable', 'processor': '-', 'processor-bar': '0'}),
    ('cpu-line-after-a-20-KB-line', {'stat1': LONG_LINE + STAT_ONE_1}, {}),
    ('cpu-line-across-a-read', {'stat2': STRADDLE + STAT_ONE_2}, {}),
    ('cpu-line-without-newline', {'stat2': b'cpu  1300 0 600 8550 550 0 0 0 0 0'}, {}),
    ('past-1-MiB-before-the-cpu-line', {'stat2': b'intr ' + b'0 ' * 600000 + b'\n' + STAT_ONE_2},
     {'stat2': 'unavailable', **UNREADABLE}),
    ('meminfo-reordered', {'meminfo': b'MemAvailable:    3145728 kB\nMemFree: 5 kB\nCached: 6 kB\n'
                                      b'MemTotal:        4194304 kB\n'},
     {'meminfo': '4194304 3145728', 'memory': '25%', 'memory-bar': '100', 'detail': '1.0 GiB of 4.0 GiB in use'}),
    ('meminfo-without-MemAvailable', {'meminfo': b'MemTotal:       16384000 kB\nMemFree:  1024000 kB\n'}, NO_MEMORY),
    ('meminfo-without-MemTotal', {'meminfo': b'MemFree:  1024000 kB\nMemAvailable:    4096000 kB\n'}, NO_MEMORY),
    ('meminfo-total-zero', {'meminfo': meminfo(0, 0)},
     {'meminfo': '0 0', 'memory': 'unavailable', 'memory-bar': '0', 'detail': ''}),
    ('more-available-than-total', {'meminfo': meminfo(2097152, 3000000)},
     {'meminfo': '2097152 3000000', 'memory': '0%', 'memory-bar': '0', 'detail': '0.0 GiB of 2.0 GiB in use'}),
    ('nothing-available', {'meminfo': meminfo(2097152, 0)},
     {'meminfo': '2097152 0', 'memory': '100%', 'memory-bar': '400', 'detail': '2.0 GiB of 2.0 GiB in use'}),
    ('under-1-GiB-in-MiB', {'meminfo': meminfo(524288, 104858)},
     {'meminfo': '524288 104858', 'memory': '80%', 'memory-bar': '320', 'detail': '409.6 MiB of 512.0 MiB in use'}),
    ('tenths-carry', {'meminfo': meminfo(10433332, 1)},
     {'meminfo': '10433332 1', 'memory': '100%', 'memory-bar': '400', 'detail': '9.9 GiB of 10.0 GiB in use'}),
    ('exactly-1-GiB', {'meminfo': meminfo(1048576, 524288)},
     {'meminfo': '1048576 524288', 'memory': '50%', 'memory-bar': '200', 'detail': '0.5 GiB of 1.0 GiB in use'}),
    ('1-KiB-under-1-GiB', {'meminfo': meminfo(1048575, 0)},
     {'meminfo': '1048575 0', 'memory': '100%', 'memory-bar': '400', 'detail': '1024.0 MiB of 1024.0 MiB in use'}),
    ('largest-memory', {'meminfo': meminfo(18446744073709551615, 0)},
     {'meminfo': '18446744073709551615 0', 'memory': '100%', 'memory-bar': '400',
      'detail': '17592186044416.0 GiB of 17592186044416.0 GiB in use'}),
    ('memory-past-2^64', {'meminfo': b'MemTotal:  18446744073709551616 kB\nMemAvailable:  5 kB\n'}, NO_MEMORY),
    ('look-alike-names', {'meminfo': meminfo(2097152, 1048576, before=b'MemTotalHuge:  5 kB\nMemAvail:  7 kB\n'
                                             b'XMemTotal:  9 kB\nmemtotal:  11 kB\nMemTotal  13 kB\n')},
     {'meminfo': '2097152 1048576', 'memory': '50%', 'memory-bar': '200', 'detail': '1.0 GiB of 2.0 GiB in use'}),
    ('first-of-two-MemTotal-lines', {'meminfo': meminfo(2097152, 1048576, between=b'MemTotal:  4194304 kB\n')},
     {'meminfo': '2097152 1048576', 'memory': '50%', 'memory-bar': '200', 'detail': '1.0 GiB of 2.0 GiB in use'}),
    ('value-without-unit', {'meminfo': b'MemTotal:       2097152\nMemAvailable:   1048576 kB\n'}, NO_MEMORY),
    ('unit-not-kB', {'meminfo': b'MemTotal:       2097152 MB\nMemAvailable:   1048576 kB\n'}, NO_MEMORY),
    ('meminfo-without-final-newline', {'meminfo': b'MemTotal:  2097152 kB\nMemAvailable:  524288 kB'},
     {'meminfo': '2097152 524288', 'memory': '75%', 'memory-bar': '300', 'detail': '1.5 GiB of 2.0 GiB in use'}),
    ('missing-meminfo', {'meminfo': None}, NO_MEMORY),
    ('name-without-newline', {'host': b'lookout-box'}, {'host': 'lookout-box'}),
    ('name-on-the-first-line-only', {'host': b'first\nsecond\n'}, {'host': 'first'}),
    ('name-of-70-bytes-shows-64', {'host': b'a' * 70 + b'\n'}, {'host': 'a' * 64}),
    ('empty-name', {'host': b''}, {'host': 'unavailable'}),
    ('name-file-a-newline', {'host': b'\n'}, {'host': 'unavailable'}),
    ('missing-name', {'host': None}, {'host': 'unavailable'}),
    ('everything-missing', {'stat1': None, 'stat2': None, 'meminfo': None, 'host': None},
     {'stat1': 'unavailable', 'stat2': 'unavailable', 'host': 'unavailable', **UNREADABLE, **NO_MEMORY}),
]

ORDER = ('stat1', 'stat2', 'meminfo', 'host', 'processor', 'processor-bar', 'memory', 'memory-bar', 'detail')


def sample_checks(args, evidence, passed):
    root = evidence / 'sample'
    root.mkdir()
    env = dict(os.environ)
    env.pop('DISPLAY', None)
    names = set()
    for name, files, changes in CASES:
        assert name not in names, name
        names.add(name)
        directory = root / name
        directory.mkdir()
        paths = []
        for key in ('stat1', 'stat2', 'meminfo', 'host'):
            data = files.get(key, FILES[key])
            path = directory / key
            if data is not None:
                path.write_bytes(data)
            paths.append(str(path))
        result = subprocess.run([str(args.lookout.resolve()), '--sample', *paths], cwd=directory, env=env,
                                capture_output=True, timeout=30)
        (directory / 'stdout').write_bytes(result.stdout)
        (directory / 'stderr').write_bytes(result.stderr)
        answer = dict(ANSWER, **changes)
        expected = ''.join(f'{key}={answer[key]}\n' for key in ORDER).encode()
        assert (result.returncode, result.stderr) == (0, b''), (name, result.returncode, result.stderr)
        assert result.stdout == expected, (name, result.stdout.decode(errors='replace'), expected.decode())
        passed('lookout-sample-' + name)

    for label, extra, message in (
            ('extra-argument', ['x'], b'lookout: usage: lookout\n'),
            ('sample-needs-four-files', ['--sample', 'a', 'b', 'c'], b'lookout: usage: lookout\n'),
            ('test-interval-zero', ['--test', 'a', 'b', 'c', '0'], b'lookout: usage: lookout\n'),
            ('test-interval-over-a-minute', ['--test', 'a', 'b', 'c', '60001'], b'lookout: usage: lookout\n'),
            ('test-interval-not-a-number', ['--test', 'a', 'b', 'c', '1x'], b'lookout: usage: lookout\n'),
            ('no-display', [], None)):
        result = subprocess.run([str(args.lookout.resolve()), *extra], cwd=root, env=env, capture_output=True,
                                timeout=30)
        (root / (label + '.stderr')).write_bytes(result.stderr)
        assert result.returncode == 1 and result.stdout == b'', (label, result.returncode, result.stdout)
        if message is None:
            assert result.stderr == b'desktop: DISPLAY is missing; run from your desktop terminal\n', result.stderr
        else:
            assert result.stderr == message, (label, result.stderr)
        passed('lookout-refuses-' + label)


class Lookout(App):
    """check_hosted_apps.App (input, frames, shutdown), started with Lookout's own arguments, not a document path."""

    def __init__(self, image, arguments, x, display, evidence, label):
        self.x, self.evidence, self.label = x, evidence, label
        self.window = None
        self.inputs = []
        self.started = time.monotonic()
        before = x.windows()
        env = dict(os.environ, DISPLAY=display)
        env.pop('XAUTHORITY', None)
        self.out = (evidence / (label + '.stdout')).open('wb')
        self.err = (evidence / (label + '.stderr')).open('wb')
        self.p = subprocess.Popen([str(image.resolve()), *arguments], env=env, stdin=subprocess.DEVNULL,
                                  stdout=self.out, stderr=self.err)
        try:
            def created():
                assert self.p.poll() is None, f'{label} exited: {self.p.returncode}'
                candidates = [w for w in x.windows() - before if x.name(w) == TITLE and x.geometry(w) == SIZE]
                assert len(candidates) <= 1, 'ambiguous test window'
                if candidates:
                    self.window = candidates[0]
                    return True
            wait_for(created, label + ' window')
            # As App: ask for focus until the server gives it, then see the FocusIn, so keys are not dropped.
            x.watch_focus(self.window)
            def focused():
                x.focus(self.window)
                return x.owns_focus(self.window)
            wait_for(focused, label + ' keyboard focus')
            wait_for(lambda: any(event['event'] == 'in' for event in x.focus_events(self.window)),
                     label + ' focus-in delivered')
            time.sleep(.15)
        except BaseException:
            self.close()
            raise


def colour(frame, px, py):
    at = (py * frame['width'] + px) * 3
    return int.from_bytes(frame['rgb'][at:at + 3], 'big')


def read_text(frame, x, y, cells, background, scale=1):
    """pixel_text read back at any scale: the characters from (x, y), trailing blanks dropped, and the inks. A cell
    that matches no glyph, has ink in its gap column or a block of two colours reads as NUL."""
    table = glyphs()
    text, inks = [], set()
    for cell in range(cells):
        bits, stray = [], False
        for row in range(7):
            for col in range(6):
                block = {colour(frame, x + (cell * 6 + col) * scale + i, y + row * scale + j)
                         for i in range(scale) for j in range(scale)}
                lit = block != {background}
                stray = stray or len(block) > 1 or (lit and col == 5)
                if lit:
                    inks.update(block)
                if col < 5:
                    bits.append('1' if lit else '0')
        text.append('\0' if stray else table.get(''.join(bits), '\0'))
    return ''.join(text).rstrip(' '), inks


def bar(frame, row, fill):
    """The filled length of a row's bar, in pixels, checked along its middle line: fill, then track, nothing else."""
    y = row + 22 + 11
    pixels = [colour(frame, BAR_X + i, y) for i in range(BAR_LENGTH)]
    filled = 0
    while filled < BAR_LENGTH and pixels[filled] == fill:
        filled += 1
    assert all(p == TRACK for p in pixels[filled:]), ('bar has stray colours', row, sorted(set(pixels)))
    return filled


def shown(frame):
    """Everything Lookout writes, read back from one frame."""
    host = read_text(frame, *HOST_AT, 48, BACKGROUND, 2)
    if '\0' in host[0]:
        host = read_text(frame, *HOST_AT, 64, BACKGROUND, 1)
    return {'host': host,
            'processor': read_text(frame, 464, CPU_ROW + 26, 11, PANEL, 2),
            'processor-bar': bar(frame, CPU_ROW, CPU_FILL),
            'memory': read_text(frame, 464, MEMORY_ROW + 26, 11, PANEL, 2),
            'memory-bar': bar(frame, MEMORY_ROW, MEMORY_FILL),
            'detail': read_text(frame, *DETAIL_AT, 64, PANEL),
            'labels': (read_text(frame, BAR_X, CPU_ROW, 9, PANEL, 2), read_text(frame, BAR_X, MEMORY_ROW, 6, PANEL, 2),
                       read_text(frame, 28, 318, 17, BACKGROUND))}


def show_until(app, wanted, description, timeout=5):
    """Wait until every key of wanted reads back as given; return that frame's readings."""
    seen = {}
    def ready():
        seen.update(shown(app.frame()))
        return all(seen[key] == value for key, value in wanted.items())
    try:
        wait_for(ready, description, timeout)
    except AssertionError as error:
        raise AssertionError(f'{error}; last read {seen}') from None
    return seen


def real_name():
    return Path('/proc/sys/kernel/hostname').read_bytes().split(b'\n')[0][:64].decode('ascii', 'replace')


def real_memory():
    fields = dict(line.split(':', 1) for line in Path('/proc/meminfo').read_text().splitlines())
    total, available = (int(fields[k].split()[0]) for k in ('MemTotal', 'MemAvailable'))
    return total, available


def tenths(kib, unit):
    whole, rest = divmod(kib, unit)
    tenth = (rest * 10 + unit // 2) // unit
    return f'{whole + tenth // 10}.{tenth % 10}'


def window_checks(args, x, display, evidence, passed):
    # The real /proc: the name, both figures and their bars, the redraw light; then Escape.
    app = Lookout(args.lookout, [], x, display, evidence, 'lookout-real')
    try:
        first = app.frame('start')
        name = real_name()
        reading = shown(first)
        assert reading['host'] == (name, {WHITE}), (reading['host'], name)
        assert reading['labels'] == (('PROCESSOR', {WHITE}), ('MEMORY', {WHITE}), ('ESC OR Q TO CLOSE', {GREY})), \
            reading['labels']
        def figure():
            reading.update(shown(app.frame()))
            return re.fullmatch(r'\d{1,3}%', reading['processor'][0]) is not None
        wait_for(figure, 'a processor figure after the second sample', 4)
        frame = app.frame('figures')
        reading = shown(frame)
        cpu = int(reading['processor'][0][:-1])
        assert 0 <= cpu <= 100 and reading['processor'][1] == {WHITE}, reading['processor']
        assert reading['processor-bar'] == 4 * cpu, (reading['processor-bar'], cpu)
        total, available = real_memory()
        unit, unit_name = (1048576, 'GiB') if total >= 1048576 else (1024, 'MiB')
        detail = re.fullmatch(r'(\d+\.\d) (GiB|MiB) of (\d+\.\d) (GiB|MiB) in use', reading['detail'][0])
        assert detail and detail.group(2) == detail.group(4) == unit_name, reading['detail']
        assert detail.group(3) == tenths(total, unit), (reading['detail'], total)
        mem = int(reading['memory'][0][:-1])
        mine = round(100 * (total - available) / total)
        assert abs(mem - mine) <= 5 and reading['memory-bar'] == 4 * mem, (reading['memory'], mine)
        passed('lookout-shows-this-machine', name_matches_proc=True, processor=cpu, memory=mem, memory_now=mine,
               detail=reading['detail'][0])
        digests = {first['digest'], frame['digest']}
        started = time.monotonic()
        while len(digests) < 3 and time.monotonic() - started < 5:
            time.sleep(.25)
            digests.add(app.frame()['digest'])
        assert len(digests) >= 3, 'the window does not keep redrawing'
        passed('lookout-redraws', distinct_frames=len(digests), seconds=round(time.monotonic() - started, 2))
        app.tap('Escape')
        app.finish()
        passed('lookout-escape-quits')
    finally:
        app.close()

    for label, how in (('q', lambda app: app.tap('q')), ('window-close', lambda app: x.delete(app.window))):
        app = Lookout(args.lookout, [], x, display, evidence, 'lookout-' + label)
        try:
            show_until(app, {'host': (real_name(), {WHITE})}, label + ' window drawn')
            how(app)
            app.finish()
            passed('lookout-' + label + '-quits')
        finally:
            app.close()

    # Files this check writes: exact text and bars for known figures, the unavailable state, and recovery.
    files = evidence / 'window-files'
    files.mkdir()
    stat, mem, host = files / 'stat', files / 'meminfo', files / 'hostname'
    def put(path, data):
        spare = path.with_suffix('.new')
        spare.write_bytes(data)
        os.replace(spare, path)
    put(stat, STAT_ONE_1); put(mem, MEM_TYPICAL); put(host, b'test-host\n')
    app = Lookout(args.lookout, ['--test', str(stat), str(mem), str(host), '100'], x, display, evidence,
                  'lookout-files')
    try:
        memory_shown = {'memory': ('75%', {WHITE}), 'memory-bar': 300,
                        'detail': ('11.7 GiB of 15.6 GiB in use', {GREY})}
        show_until(app, {'host': ('test-host', {WHITE}), 'processor': ('-', {GREY}), 'processor-bar': 0,
                         **memory_shown}, 'first sample only: a dash')
        app.frame('dash')
        steps = [(STAT_ONE_2, '40%', 160),
                 (stat_line(2300, 0, 600, 8550, 550, 0, 0, 0, 0, 0), '100%', 400),
                 (stat_line(2300, 0, 600, 9550, 550, 0, 0, 0, 0, 0), '0%', 0)]
        for data, text, width in steps:
            put(stat, data)
            show_until(app, {'processor': (text, {WHITE}), 'processor-bar': width, **memory_shown}, 'processor ' + text)
            app.frame('processor-' + text.rstrip('%'))
        passed('lookout-draws-exact-figures-and-bars', processor=[s[1] for s in steps], memory='75%')
        stat.unlink()
        show_until(app, {'processor': ('unavailable', {AMBER}), 'processor-bar': 0, **memory_shown},
                   'processor unavailable')
        mem.unlink()
        show_until(app, {'memory': ('unavailable', {AMBER}), 'memory-bar': 0, 'detail': ('', set())},
                   'memory unavailable')
        host.unlink()
        show_until(app, {'host': ('unavailable', {AMBER})}, 'name unavailable')
        app.frame('unavailable')
        passed('lookout-shows-unavailable-and-keeps-running')
        put(stat, stat_line(2300, 0, 600, 9550, 550, 0, 0, 0, 0, 0))
        put(mem, MEM_TYPICAL)
        put(host, b'test-host\n')
        show_until(app, {'host': ('test-host', {WHITE}), 'processor': ('-', {GREY}), **memory_shown},
                   'files back: a new first sample')
        put(stat, stat_line(2800, 0, 700, 10050, 650, 0, 0, 0, 0, 0))
        show_until(app, {'processor': ('50%', {WHITE}), 'processor-bar': 200}, 'processor after recovery')
        app.frame('recovered')
        passed('lookout-recovers-when-the-files-return')
        app.tap('Escape')
        app.finish()
    finally:
        app.close()


def io_counts(pid):
    fields = dict(line.split(': ') for line in Path(f'/proc/{pid}/io').read_text().splitlines())
    return int(fields['syscr']), int(fields['rchar'])


def memory_checks(args, x, display, evidence, passed):
    # The real /proc files every 10 ms: about a hundred times the window's own rate, so that even a few bytes kept
    # per frame would add up to more than the tolerance in the time given.
    interval = 10
    app = Lookout(args.lookout, ['--test', '/proc/stat', '/proc/meminfo', '/proc/sys/kernel/hostname', str(interval)],
                 x, display, evidence, 'lookout-memory')
    try:
        show_until(app, {'host': (real_name(), {WHITE})}, 'memory run drawn')
        time.sleep(2)
        samples, digests = [], set()
        started = time.monotonic()
        while True:
            sample = process_memory(app.p.pid)
            sample['seconds'] = round(time.monotonic() - started, 3)
            sample['syscr'], sample['rchar'] = io_counts(app.p.pid)
            samples.append(sample)
            (evidence / 'lookout-memory.json').write_text(json.dumps(samples, indent=2) + '\n')
            digests.add(app.frame()['digest'])
            if time.monotonic() - started >= args.seconds:
                break
            time.sleep(2)
        seconds = samples[-1]['seconds']
        # A frame reads three files, with at most two read calls each (the data, and one more at the end of a file
        # whose figure the first read did not finish); the display socket's receives are not read calls. So a sixth
        # of the read calls is a lower bound on the frames drawn.
        reads = samples[-1]['syscr'] - samples[0]['syscr']
        frames_at_least = reads // 6
        assert frames_at_least >= seconds * 1000 / interval / 10, ('too few frames to judge memory', reads, seconds)
        assert len(digests) >= 2, 'the window did not change during the run'
        stable_memory(samples, 'lookout reading /proc and redrawing every 10 ms')
        rss = [s['Rss'] for s in samples]
        x.delete(app.window)
        app.finish()
        passed('lookout-memory-flat', seconds=seconds, samples=len(samples), read_calls=reads,
               frames_at_least=frames_at_least, distinct_frames=len(digests),
               rss_kib_start=rss[0], rss_kib_end=rss[-1], rss_kib_min=min(rss), rss_kib_max=max(rss),
               rss_tolerance_kib=64, vm_size_kib=samples[0]['VmSize'], vm_size_must_not_change=True)
    finally:
        app.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--lookout', type=Path, default=ROOT / 'build/lookout')
    parser.add_argument('--seconds', type=float, default=120, help='length of the memory run')
    parser.add_argument('--only', choices=['all', 'sample', 'window', 'memory'], default='all')
    parser.add_argument('--evidence', type=Path)
    args = parser.parse_args()
    assert args.seconds >= 3, 'at least 3 seconds required; release qualification uses the default 120'
    evidence = (args.evidence or Path(tempfile.mkdtemp(prefix='herbert-hosted-apps-lookout-'))).resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(__file__, evidence / 'check_lookout.py')
    shutil.copyfile(args.lookout, evidence / 'lookout.elf')
    combined = args.lookout.parent / (args.lookout.name + '-work') / 'source.herb'
    if combined.exists():
        shutil.copyfile(combined, evidence / 'lookout-source.herb')
    result = {'mode': 'sample-files and private-Xvfb-XTest', 'scope': args.only, 'memory_seconds': args.seconds,
              'image': static_elf(args.lookout), 'checks': []}
    def passed(name, **details):
        result['checks'].append(dict(name=name, **details))
        print('PASS:', name, json.dumps(details, sort_keys=True) if details else '', flush=True)
        (evidence / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print('Evidence:', evidence, flush=True)
    try:
        if args.only in ('all', 'sample'):
            sample_checks(args, evidence, passed)
        if args.only in ('all', 'window', 'memory'):
            with private_display(evidence, size='1280x900') as display:
                x = XConnection(display)
                try:
                    if args.only in ('all', 'window'):
                        window_checks(args, x, display, evidence, passed)
                    if args.only in ('all', 'memory'):
                        memory_checks(args, x, display, evidence, passed)
                finally:
                    x.close()
    except BaseException as error:
        result['failure'] = repr(error)
        raise
    finally:
        (evidence / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(f'lookout: {len(result["checks"])}/{len(result["checks"])} PASS; evidence {evidence}')


if __name__ == '__main__':
    main()
