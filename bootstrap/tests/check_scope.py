#!/usr/bin/env python3
"""Scope's checks: its figures against hand-written answers, then its window on a private display.

Part one runs `scope --sample STAT1 STAT2 [STAT3 ...] MEMINFO HOSTNAME` on fixed input files and compares every
line it prints with an answer written here by hand: one-processor and 64-processor /proc/stat files, old and new
kernels' field counts, tabs, meminfo fields missing, reordered or malformed, files at the 1 MiB bound, and the edges
of the arithmetic (0 %, 100 %, half a percent and 99.5 % exactly, also past 2^56, a zero-length interval after a
figure, counters that did not move or went back one by one or all together, numbers at and past 2^64, tenths that
carry).

Then `scope --computers [FILE]` reads lists of other computers this check writes (86 of them, from good lines,
comments, tabs and CRLF to every malformed address and port check_net knows, 7 computers, more problems than rows and
the 64 KiB bound), files that are not lists (a FIFO, /dev/zero, a directory) and the list in HOME; every line it
prints is compared with an answer written by hand, and strace makes socket() fail so nothing could be knocked.

Part two opens the window on a private Xvfb display and drives it with XTest. Every run has a HOME of this check's
own (or none), so no run can read the owner's list of computers, and every knock goes to 127.x, to listeners and
ports this check opens (check_net's Listener, ClosedPort and BlackHole). With the real /proc it must draw this
machine's name, a processor figure, and memory figures that agree with /proc/meminfo read just before and just after
a frame that shows a new reading, and the computers in its HOME's list answering; it quits on Escape, q, Shift+Q and
the window manager's close. With `--test` it reads files this check writes: the redraw light must change at every
reading while nothing else does, and the exact text, inks and bar lengths are checked for known figures, a
zero-length interval, MiB, names of 48 and 60 bytes, and files that vanish ("unavailable") and come back. The other
computers' rows are read back from pixels too: checking, answers (a listener, and a closed port's refusal), no answer
(a full accept queue), kept while the next knock is under way, problems, a seventh computer never knocked, and
unreachable and error made by strace failing the knocks' connects. A knock that never answers must hold nothing up:
the light changes on time and Escape closes the window within 300 ms. Under strace, the knocks' interval and time
limit are read from their own clock. Last, for --seconds (default 120) it reads every 10 ms through links this check
turns between the real /proc, files without a final newline (MiB, a 60-byte name), missing files and malformed
files, while knocking every 20 ms on three computers, and must stay the same size in memory with no socket outliving
its knock.

Python, strace, Xvfb, libX11 and libXtst are test tools only; Scope links none of them. Evidence (frames, input
history, outputs, traces, memory samples) is kept in /tmp/herbert-hosted-apps-scope-*.
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
import signal
import socket
import stat as stat_module
import subprocess
import tempfile
import time

from check_desktop import private_display, XConnection
from check_desktop import memory as process_memory
from check_hosted_apps import App, glyphs, stable_memory, static_elf, wait_for
from check_net import (BlackHole, ClosedPort, HIGH, Listener, LOOPBACK, MALFORMED_ADDRESSES, MALFORMED_PORTS, SPREAD,
                       pending)

ROOT = Path(__file__).resolve().parents[2]
TITLE = b'Herbert - Scope'

# Colours and places from examples/scope.herb (scope_draw, scope_row, scope_others, scope_status).
BACKGROUND, PANEL, TRACK = 1054759, 1384240, 2767956
WHITE, AMBER, GREY = 15265527, 16173151, 11255503
CPU_FILL, MEMORY_FILL = 6867876, 7317724
GREEN, HEADING, DIM = 6867876, 8820395, 5793911
HOST_AT = (28, 96)
CPU_ROW, MEMORY_ROW = 146, 212          # a row's label; its bar is 22 below, its figure 26 below at x=464
BAR_X, BAR_LENGTH = 46, 400
DETAIL_AT = (46, 270)
# The other computers' section: its heading, then a panel from y=334 with a row every 34 pixels from y=348: the main
# text at x=46, scale 2, the detail 19 below at scale 1, and a computer's result at x=352 (scale 2, and under it what
# Linux said, scale 1). The panel ends at 354 + 34 * rows; the footer lines are 22 and 44 below it, and the window is
# 74 taller than that: 428 + 34 * rows in all, one row at least (a note) and eight at most.
OTHERS_AT = (28, 318)
ROW_TOP, ROW_STEP, DETAIL_DY, STATUS_X = 348, 34, 19, 352


def height(rows):
    return 428 + ROW_STEP * rows


def bottom(rows):
    return 354 + ROW_STEP * rows


def rows_of(frame):
    rows, rest = divmod(frame['height'] - 428, ROW_STEP)
    assert frame['width'] == 640 and rest == 0 and 1 <= rows <= 8, ('window size', frame['width'], frame['height'])
    return rows


def stat_line(*fields):
    return b'cpu  ' + b' '.join(str(n).encode() for n in fields) + b'\n'


# A one-processor /proc/stat, laid out as Linux writes it (proc_stat(5)).
STAT_ONE_TAIL = (b'cpu0 %s\nintr 114930548 113199788 3 0 5 263 0 4 0 0 0 0 0 0 0 0\nctxt 1990473\n'
                 b'btime 1062191376\nprocesses 2915\nprocs_running 1\nprocs_blocked 0\n'
                 b'softirq 183433 0 21755 12 39 0 0 0 0 1 161626\n')
STAT_ONE_1 = stat_line(1000, 0, 500, 8000, 500, 0, 0, 0, 0, 0) + STAT_ONE_TAIL % b'1000 0 500 8000 500 0 0 0 0 0'
STAT_ONE_2 = stat_line(1300, 0, 600, 8550, 550, 0, 0, 0, 0, 0) + STAT_ONE_TAIL % b'1300 0 600 8550 550 0 0 0 0 0'


def stat_many(*fields):
    """64 processors and an interrupt line of about 18 KB, longer than Scope's 4096-byte reads."""
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


# Every case starts from these four files and this answer, then changes what it names; a case may add stat3 and
# stat4, read in order after stat2. Each answer was worked out by hand from the case's own numbers. A statN line is
# that sample's total (its first eight counters) and busy (the total less idle and iowait). The figure is worked out
# counter by counter: each counter's rise since the last sample (none if it went back) is its time; the figure is the
# rise of all but idle and iowait over the rise of all eight, to the nearest percent, a half rounding up. A sample
# whose total went back shows a dash; one with no rise at all leaves the figure as it was. A bar is four pixels a
# percent.
FILES = {'stat1': STAT_ONE_1, 'stat2': STAT_ONE_2, 'meminfo': MEM_TYPICAL, 'host': b'test-host\n'}
ANSWER = {'stat1': '10000 1500', 'stat2': '11000 1900', 'meminfo': '16384000 4096000', 'host': 'test-host',
          'processor': '40%', 'processor-bar': '160', 'memory': '75%', 'memory-bar': '300',
          'detail': '11.7 GiB of 15.6 GiB in use'}
UNREADABLE = {'processor': 'unavailable', 'processor-bar': '0'}
NO_MEMORY = {'meminfo': 'unavailable', 'memory': 'unavailable', 'memory-bar': '0', 'detail': ''}
LONG_LINE = b'intr ' + b'0 ' * 10000 + b'\n'
STRADDLE = b'intr ' + b'7' * 4084 + b'\n'          # 4090 bytes, so the cpu line crosses the first 4096-byte read
MIB = 1048576
FIRST_MIB = b'intr ' + b'0' * (MIB - 6) + b'\n'      # one line of exactly 1 MiB
CPU_LINE_2 = b'cpu  1300 0 600 8550 550 0 0 0 0 0\n'  # STAT_ONE_2's first line


def ending_at_1_mib(tail):
    """A long first line, then tail, the whole exactly 1 MiB."""
    return b'intr ' + b'0' * (MIB - len(tail) - 6) + b'\n' + tail


# Large numbers for the exact percent, where rounding by halving went wrong: 2^64 - 9216 with a busy part just over
# half a percent; a memory total of 2^56 + 65 with just under half a percent in use; 2^56 + 264 with exactly 99.5 %
# and 1 KiB less.
BIG_TOTAL, BIG_BUSY = 18446744073709542400, 92233720368547839
BIG_MEMORY, BIG_USED = 72057594037928001, 360287970189640
HALF_TOTAL, HALF_PART = 72057594037928200, 71697306067738559

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
    ('zero-length-interval-keeps-the-figure', {'stat3': STAT_ONE_2},
     {'stat3': '11000 1900'}),
    ('next-interval-starts-at-the-zero-length-sample', {'stat3': STAT_ONE_2,
                                                        'stat4': stat_line(1400, 0, 600, 8650, 550, 0, 0, 0, 0, 0)},
     {'stat3': '11000 1900', 'stat4': '11200 2000', 'processor': '50%', 'processor-bar': '200'}),
    ('total-went-back-after-a-figure', {'stat3': STAT_ONE_1},
     {'stat3': '10000 1500', 'processor': '-', 'processor-bar': '0'}),
    ('iowait-went-back', {'stat1': stat_line(100, 0, 0, 800, 100, 0, 0, 0, 0, 0),
                          'stat2': stat_line(101, 0, 0, 899, 1, 0, 0, 0, 0, 0)},
     {'stat1': '1000 100', 'stat2': '1001 101', 'processor': '1%', 'processor-bar': '4'}),
    ('user-went-back-then-on', {'stat1': b'cpu  500 0 0 500 0 0 0 0\n', 'stat2': b'cpu  400 0 0 600 0 0 0 0\n',
                                'stat3': b'cpu  450 0 0 650 0 0 0 0\n'},
     {'stat1': '1000 500', 'stat2': '1000 400', 'stat3': '1100 450', 'processor': '50%', 'processor-bar': '200'}),
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
    ('just-over-half-a-percent-near-2^64-and-just-under-past-2^56',
     {'stat1': b'cpu 0 0 0 0\n', 'stat2': b'cpu %d 0 0 %d\n' % (BIG_BUSY, BIG_TOTAL - BIG_BUSY),
      'meminfo': meminfo(BIG_MEMORY, BIG_MEMORY - BIG_USED)},
     {'stat1': '0 0', 'stat2': '18446744073709542400 92233720368547839', 'processor': '1%', 'processor-bar': '4',
      'meminfo': '72057594037928001 71697306067738361', 'memory': '0%', 'memory-bar': '0',
      'detail': '343597383.7 GiB of 68719476736.0 GiB in use'}),
    ('exactly-99.5-percent-past-2^56', {'stat1': b'cpu 0 0 0 0\n',
                                        'stat2': b'cpu %d 0 0 %d\n' % (HALF_PART, HALF_TOTAL - HALF_PART),
                                        'meminfo': meminfo(HALF_TOTAL, HALF_TOTAL - HALF_PART)},
     {'stat1': '0 0', 'stat2': '72057594037928200 71697306067738559', 'processor': '100%', 'processor-bar': '400',
      'meminfo': '72057594037928200 360287970189641', 'memory': '100%', 'memory-bar': '400',
      'detail': '68375879352.3 GiB of 68719476736.0 GiB in use'}),
    ('just-under-99.5-percent-past-2^56', {'stat1': b'cpu 0 0 0 0\n',
                                           'stat2': b'cpu %d 0 0 %d\n' % (HALF_PART - 1, HALF_TOTAL - HALF_PART + 1),
                                           'meminfo': meminfo(HALF_TOTAL, HALF_TOTAL - HALF_PART + 1)},
     {'stat1': '0 0', 'stat2': '72057594037928200 71697306067738558', 'processor': '99%', 'processor-bar': '396',
      'meminfo': '72057594037928200 360287970189642', 'memory': '99%', 'memory-bar': '396',
      'detail': '68375879352.3 GiB of 68719476736.0 GiB in use'}),
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
    ('number-of-21-digits', {'stat2': b'cpu  100000000000000000000 0 0 0\n'}, {'stat2': 'unavailable', **UNREADABLE}),
    ('tabs-between-fields', {'stat2': CPU_LINE_2.replace(b' ', b'\t'),
                             'meminfo': b'MemTotal:\t16384000 kB\nMemAvailable:\t4096000\tkB\n'}, {}),
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
    ('cpu-line-starting-at-1-MiB', {'stat2': FIRST_MIB + CPU_LINE_2}, {'stat2': 'unavailable', **UNREADABLE}),
    ('cpu-line-starting-at-1-MiB-without-newline', {'stat2': FIRST_MIB + CPU_LINE_2[:-1]},
     {'stat2': 'unavailable', **UNREADABLE}),
    ('cpu-line-ending-at-1-MiB', {'stat2': ending_at_1_mib(CPU_LINE_2)}, {}),
    ('file-of-1-MiB-ending-in-the-cpu-line', {'stat2': ending_at_1_mib(CPU_LINE_2[:-1])}, {}),
    ('cpu-line-newline-past-1-MiB', {'stat2': ending_at_1_mib(CPU_LINE_2[:-1]) + b'\n'},
     {'stat2': 'unavailable', **UNREADABLE}),
    ('meminfo-after-1-MiB', {'meminfo': FIRST_MIB + meminfo(16384000, 4096000)}, NO_MEMORY),
    ('name-on-a-line-past-1-MiB', {'host': b'my-box-' + b'a' * MIB}, {'host': 'my-box-' + 'a' * 57}),
    ('meminfo-reordered', {'meminfo': b'MemAvailable:    3145728 kB\nMemFree: 5 kB\nCached: 6 kB\n'
                                      b'MemTotal:        4194304 kB\n'},
     {'meminfo': '4194304 3145728', 'memory': '25%', 'memory-bar': '100', 'detail': '1.0 GiB of 4.0 GiB in use'}),
    ('meminfo-without-MemAvailable', {'meminfo': b'MemTotal:       16384000 kB\nMemFree:  1024000 kB\n'}, NO_MEMORY),
    ('meminfo-without-MemTotal', {'meminfo': b'MemFree:  1024000 kB\nMemAvailable:    4096000 kB\n'}, NO_MEMORY),
    ('meminfo-total-zero', {'meminfo': meminfo(0, 0)}, NO_MEMORY),
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
    ('name-without-newline', {'host': b'scope-box'}, {'host': 'scope-box'}),
    ('name-on-the-first-line-only', {'host': b'first\nsecond\n'}, {'host': 'first'}),
    ('name-of-70-bytes-shows-64', {'host': b'a' * 70 + b'\n'}, {'host': 'a' * 64}),
    ('empty-name', {'host': b''}, {'host': 'unavailable'}),
    ('name-file-a-newline', {'host': b'\n'}, {'host': 'unavailable'}),
    ('missing-name', {'host': None}, {'host': 'unavailable'}),
    ('everything-missing', {'stat1': None, 'stat2': None, 'meminfo': None, 'host': None},
     {'stat1': 'unavailable', 'stat2': 'unavailable', 'host': 'unavailable', **UNREADABLE, **NO_MEMORY}),
]

ORDER = ('meminfo', 'host', 'processor', 'processor-bar', 'memory', 'memory-bar', 'detail')


def sample_checks(args, evidence, passed):
    root = evidence / 'sample'
    root.mkdir()
    env = dict(os.environ, HOME=str(empty_home(evidence, 'sample')))
    env.pop('DISPLAY', None)
    names = set()
    for name, files, changes in CASES:
        assert name not in names, name
        names.add(name)
        directory = root / name
        directory.mkdir()
        stats = sorted((key for key in set(FILES) | set(files) if key.startswith('stat')), key=lambda k: int(k[4:]))
        assert stats == [f'stat{n}' for n in range(1, len(stats) + 1)], (name, stats)
        paths = []
        for key in (*stats, 'meminfo', 'host'):
            data = files.get(key, FILES.get(key))
            path = directory / key
            if data is not None:
                path.write_bytes(data)
            paths.append(str(path))
        result = subprocess.run([str(args.scope.resolve()), '--sample', *paths], cwd=directory, env=env,
                                capture_output=True, timeout=30)
        (directory / 'stdout').write_bytes(result.stdout)
        (directory / 'stderr').write_bytes(result.stderr)
        answer = dict(ANSWER, **changes)
        expected = ''.join(f'{key}={answer[key]}\n' for key in (*stats, *ORDER)).encode()
        assert (result.returncode, result.stderr) == (0, b''), (name, result.returncode, result.stderr)
        assert result.stdout == expected, (name, result.stdout.decode(errors='replace'), expected.decode())
        passed('scope-sample-' + name)

    for label, extra, message in (
            ('extra-argument', ['x'], b'scope: usage: scope\n'),
            ('sample-needs-two-processor-files', ['--sample', 'a', 'b', 'c'], b'scope: usage: scope\n'),
            ('test-interval-zero', ['--test', 'a', 'b', 'c', '0'], b'scope: usage: scope\n'),
            ('test-interval-over-a-minute', ['--test', 'a', 'b', 'c', '60001'], b'scope: usage: scope\n'),
            ('test-interval-not-a-number', ['--test', 'a', 'b', 'c', '1x'], b'scope: usage: scope\n'),
            ('test-knock-interval-zero', ['--test', 'a', 'b', 'c', '100', 'list', '0', '100'], b'scope: usage: scope\n'),
            ('test-knock-limit-over-a-minute', ['--test', 'a', 'b', 'c', '100', 'list', '100', '60001'],
             b'scope: usage: scope\n'),
            ('test-knock-limit-missing', ['--test', 'a', 'b', 'c', '100', 'list', '100'], b'scope: usage: scope\n'),
            ('test-interval-zero-with-a-list', ['--test', 'a', 'b', 'c', '0', 'list', '100', '100'],
             b'scope: usage: scope\n'),
            ('computers-two-files', ['--computers', 'a', 'b'], b'scope: usage: scope\n'),
            ('no-display', [], None)):
        result = subprocess.run([str(args.scope.resolve()), *extra], cwd=root, env=env, capture_output=True,
                                timeout=30)
        (root / (label + '.stderr')).write_bytes(result.stderr)
        assert result.returncode == 1 and result.stdout == b'', (label, result.returncode, result.stdout)
        if message is None:
            assert result.stderr == b'desktop: DISPLAY is missing; run from your desktop terminal\n', result.stderr
        else:
            assert result.stderr == message, (label, result.stderr)
        passed('scope-refuses-' + label)


def empty_home(evidence, label):
    """A home directory of this check's own, with no list of other computers in it."""
    home = evidence / 'homes' / label
    home.mkdir(parents=True)
    return home


# What scope --computers prints for a list: one line a row, (kind, main, detail), as the window draws it. Written by
# hand from the rules in examples/scope.md. Every address in these lists is a documentation address (RFC 5737) or
# 127.x; scope --computers knocks on nothing, and runs here with socket() made to fail so that no build could.
R_WORDS = 'write a name, an address and a port, with spaces between'
R_NAME = 'the name must be 1 to 24 characters, ASCII only, no spaces'
R_ADDRESS = 'the address must be four numbers 0 to 255 joined by dots'
R_PORT = 'the port must be a number 1 to 65535'
R_SEVENTH = 'Scope shows at most 6 other computers'
NONE_LISTED = ('note', 'none listed', 'list them in ~/.config/herbert/computers.txt, one per line: name address port')
UNREADABLE = ('problem', 'could not read the list', '~/.config/herbert/computers.txt')
TOO_LARGE = ('problem', 'could not read the list', '~/.config/herbert/computers.txt is over 64 KiB')
NOGGIN = ('computer', 'noggin', '192.0.2.5 port 9')
BOX = ('computer', 'box', '198.51.100.7 port 22')
SIX = b''.join(b'c%d 192.0.2.%d %d\n' % (n, n, 100 + n) for n in range(1, 7))
SIX_ROWS = [('computer', 'c1', '192.0.2.1 port 101'), ('computer', 'c2', '192.0.2.2 port 102'),
            ('computer', 'c3', '192.0.2.3 port 103'), ('computer', 'c4', '192.0.2.4 port 104'),
            ('computer', 'c5', '192.0.2.5 port 105'), ('computer', 'c6', '192.0.2.6 port 106')]
EXACTLY_64_KIB = b'noggin 192.0.2.5 9\n#' + b'x' * 65515 + b'\n'
assert len(EXACTLY_64_KIB) == 65536
ROWS_FULL = (b'c1 192.0.2.1 101\nx\nc2 192.0.2.2 102\nc3 192.0.2.3 103\np 192.0.2.9 0\nc4 192.0.2.4 104\n'
             b'c5 192.0.2.5 105\nc6 192.0.2.6 106\nc7 192.0.2.7 107\n')

LIST_CASES = [
    ('one-computer', b'noggin 192.0.2.5 9\n', [NOGGIN]),
    ('comments-and-blank-lines', b'# my computers\n\n   \n\t\n  \t# indented\nnoggin 192.0.2.5 9\n#\n# box 1.2.3.4 5\n',
     [NOGGIN]),
    ('tabs-and-spaces', b'\t noggin \t 192.0.2.5\t\t9 \t\n', [NOGGIN]),
    ('crlf', b'# list\r\nnoggin 192.0.2.5 9\r\n\r\nbox 198.51.100.7 22\r\n', [NOGGIN, BOX]),
    ('no-final-newline', b'noggin 192.0.2.5 9\nbox 198.51.100.7 22', [NOGGIN, BOX]),
    ('crlf-without-final-newline', b'noggin 192.0.2.5 9\r', [NOGGIN]),
    ('carriage-return-inside-the-name', b'nog\rgin 192.0.2.5 9\n', [('problem', 'line 1 not understood', R_NAME)]),
    ('carriage-return-between-words', b'noggin 192.0.2.5\r9\n', [('problem', 'line 1 not understood', R_WORDS)]),
    ('two-carriage-returns', b'noggin 192.0.2.5 9\r\r\n', [('problem', 'line 1 not understood', R_PORT)]),
    ('name-of-1-byte', b'a 203.0.113.1 1\n', [('computer', 'a', '203.0.113.1 port 1')]),
    ('name-of-24-bytes', b'abcdefghijklmnopqrstuvwx 203.0.113.1 65535\n',
     [('computer', 'abcdefghijklmnopqrstuvwx', '203.0.113.1 port 65535')]),
    ('name-of-25-bytes', b'abcdefghijklmnopqrstuvwxy 203.0.113.1 22\n', [('problem', 'line 1 not understood', R_NAME)]),
    ('names-of-marks', b'a#b!"$%&\'()*+,-./:;<=>?@ 192.0.2.5 9\n[\\]^_`{|}~ 192.0.2.6 10\n',
     [('computer', 'a#b!"$%&\'()*+,-./:;<=>?@', '192.0.2.5 port 9'), ('computer', '[\\]^_`{|}~', '192.0.2.6 port 10')]),
    ('a-hash-first-is-a-comment', b'#box 192.0.2.5 9\n', [NONE_LISTED]),
    ('non-ascii-name', 'nöggin 192.0.2.5 9\n'.encode(), [('problem', 'line 1 not understood', R_NAME)]),
    ('control-byte-in-the-name', b'nog\x01gin 192.0.2.5 9\n', [('problem', 'line 1 not understood', R_NAME)]),
    ('delete-byte-in-the-name', b'nog\x7fgin 192.0.2.5 9\n', [('problem', 'line 1 not understood', R_NAME)]),
    ('nul-byte-in-the-name', b'nog\x00gin 192.0.2.5 9\n', [('problem', 'line 1 not understood', R_NAME)]),
    ('one-word', b'noggin\n', [('problem', 'line 1 not understood', R_WORDS)]),
    ('two-words', b'noggin 192.0.2.5\n', [('problem', 'line 1 not understood', R_WORDS)]),
    ('four-words', b'noggin 192.0.2.5 9 22\n', [('problem', 'line 1 not understood', R_WORDS)]),
    ('comment-after-a-computer', b'noggin 192.0.2.5 9 # home\n', [('problem', 'line 1 not understood', R_WORDS)]),
    ('words-before-the-name', 'nöggin 192.0.2.5\n'.encode(), [('problem', 'line 1 not understood', R_WORDS)]),
    ('name-before-the-address', 'nöggin 192.0.2 9\n'.encode(), [('problem', 'line 1 not understood', R_NAME)]),
    ('address-before-the-port', b'noggin 192.0.2 0\n', [('problem', 'line 1 not understood', R_ADDRESS)]),
    ('address-and-port-edges', b'zero 0.0.0.0 1\nall 255.255.255.255 65535\nmixed 1.20.199.250 65534\nten 10.0.0.1 80\n',
     [('computer', 'zero', '0.0.0.0 port 1'), ('computer', 'all', '255.255.255.255 port 65535'),
      ('computer', 'mixed', '1.20.199.250 port 65534'), ('computer', 'ten', '10.0.0.1 port 80')]),
    ('the-same-name-twice', b'box 192.0.2.1 22\nbox 192.0.2.2 22\n',
     [('computer', 'box', '192.0.2.1 port 22'), ('computer', 'box', '192.0.2.2 port 22')]),
    ('six-computers', SIX, SIX_ROWS),
    ('seven-computers', SIX + b'c7 192.0.2.7 107\n', SIX_ROWS + [('problem', 'line 7: more than 6 listed', R_SEVENTH)]),
    ('eight-computers', SIX + b'c7 192.0.2.7 107\nc8 192.0.2.8 108\n',
     SIX_ROWS + [('problem', 'line 7: more than 6 listed', R_SEVENTH),
                 ('problem', 'line 8: more than 6 listed', R_SEVENTH)]),
    ('a-bad-seventh-line', SIX + b'c7 192.0.2 107\n', SIX_ROWS + [('problem', 'line 7 not understood', R_ADDRESS)]),
    ('more-problems-than-rows-left', ROWS_FULL,
     SIX_ROWS + [('problem', 'line 2 not understood', R_WORDS), ('problem', 'and 2 more problems from line 5', '')]),
    ('only-problems', b'x\n' * 10, [('problem', f'line {n} not understood', R_WORDS) for n in range(1, 8)]
     + [('problem', 'and 3 more problems from line 8', '')]),
    ('lines-count-comments-and-blanks', b'# a\n\n  \nnoggin 192.0.2.5 9\n# b\nbad\n',
     [NOGGIN, ('problem', 'line 6 not understood', R_WORDS)]),
    ('line-40000', b'\n' * 39999 + b'bad\n', [('problem', 'line 40000 not understood', R_WORDS)]),
    ('empty-file', b'', [NONE_LISTED]),
    ('only-comments-and-blanks', b'# one\n\n# two\r\n \t \n', [NONE_LISTED]),
    ('exactly-64-KiB', EXACTLY_64_KIB, [NOGGIN]),
    ('one-byte-over-64-KiB', EXACTLY_64_KIB[:-1] + b'x\n', [TOO_LARGE]),
    ('1-MiB', b'#' + b'x' * 1048574 + b'\n', [TOO_LARGE]),
]
# Malformed addresses and ports from check_net, each on a line of its own; those with a space or tab in them are
# other words on a line here, and the empty one is no word at all.
LIST_CASES += [(f'bad-address-{n}', b'box %s 9\n' % a.encode(), [('problem', 'line 1 not understood', R_ADDRESS)])
               for n, a in enumerate(MALFORMED_ADDRESSES) if a and not set(a) & set(' \t')]
LIST_CASES += [(f'bad-port-{n}', b'box 192.0.2.5 %s\n' % q.encode(), [('problem', 'line 1 not understood', R_PORT)])
               for n, q in enumerate(MALFORMED_PORTS) if q and not set(q) & set(' \t')]


def list_run(args, directory, label, extra, home, timeout=10):
    """scope --computers [FILE] under strace with socket() made to fail: (lines, seconds). Nothing may be asked of
    the network, and the program must finish within timeout."""
    env = {k: v for k, v in os.environ.items() if k not in ('DISPLAY', 'HOME')}
    if home is not None:
        env['HOME'] = home
    trace = directory / (label + '.strace')
    started = time.monotonic()
    result = subprocess.run(['strace', '-f', '-qq', '-o', str(trace), '-e', 'trace=socket,connect', '-e',
                             'inject=socket:error=EPERM', str(args.scope.resolve()), '--computers', *extra],
                            env=env, stdin=subprocess.DEVNULL, capture_output=True, timeout=timeout)
    seconds = time.monotonic() - started
    (directory / (label + '.stdout')).write_bytes(result.stdout)
    assert (result.returncode, result.stderr) == (0, b''), (label, result.returncode, result.stderr)
    assert trace.read_text() == '', ('scope --computers asked for a socket', label, trace.read_text())
    return result.stdout.decode().splitlines(), seconds


def list_expected(rows):
    return ['\t'.join(row) for row in rows] + [f'height\t{height(len(rows))}']


def list_checks(args, evidence, passed):
    """scope --computers on lists this check writes, every printed line against an answer written by hand."""
    assert shutil.which('strace'), 'strace is required (a test tool; CI installs it)'
    root = evidence / 'lists'
    root.mkdir()
    names = set()
    for name, data, rows in LIST_CASES:
        assert name not in names, name
        names.add(name)
        path = root / (name + '.txt')
        path.write_bytes(data)
        lines, _ = list_run(args, root, name, [str(path)], str(root))
        assert lines == list_expected(rows), (name, lines, list_expected(rows))
    passed('scope-list-read-as-written', lists=len(LIST_CASES))
    # Files that are not lists: missing, a dangling link, a directory, a FIFO (no writer: a plain open would wait for
    # one for ever), a link to /dev/zero (endless), a link to a good list, and one this user may not read.
    odd = root / 'odd'
    odd.mkdir()
    good = odd / 'good.txt'
    good.write_bytes(b'noggin 192.0.2.5 9\n')
    os.symlink(odd / 'nothing-here', odd / 'dangling')
    (odd / 'directory').mkdir()
    os.mkfifo(odd / 'fifo')
    os.symlink('/dev/zero', odd / 'zero')
    os.symlink(good, odd / 'link')
    locked = odd / 'locked'
    locked.write_bytes(b'noggin 192.0.2.5 9\n')
    locked.chmod(0)
    cases = [('missing', odd / 'missing', [NONE_LISTED]), ('dangling-link', odd / 'dangling', [NONE_LISTED]),
             ('directory', odd / 'directory', [UNREADABLE]), ('fifo', odd / 'fifo', [UNREADABLE]),
             ('link-to-dev-zero', odd / 'zero', [UNREADABLE]), ('link-to-a-list', odd / 'link', [NOGGIN])]
    not_run = []
    if os.geteuid() != 0:
        cases.append(('no-permission', locked, [UNREADABLE]))
    else:
        not_run.append('no-permission: this check runs as root, who may read any file')
    timings = {}
    try:
        for name, path, rows in cases:
            lines, seconds = list_run(args, root, name, [str(path)], str(root))
            assert lines == list_expected(rows), (name, lines, list_expected(rows))
            timings[name] = round(seconds, 3)
    finally:
        # Readable again, pass or fail: CI packs the evidence folder with tar, which stops at a file it cannot read.
        locked.chmod(0o600)
    assert max(timings['fifo'], timings['link-to-dev-zero']) < 2, ('reading the list stalled', timings)
    passed('scope-list-files-that-are-not-lists', cases=[c[0] for c in cases], seconds=timings, not_run=not_run)
    # Without FILE, the owner's list: $HOME/.config/herbert/computers.txt.
    home = root / 'home'
    (home / '.config/herbert').mkdir(parents=True)
    (home / '.config/herbert/computers.txt').write_bytes(b'box 198.51.100.7 22\n')
    for name, value, rows in (('home-list', str(home), [BOX]), ('home-without-a-list', str(odd), [NONE_LISTED]),
                              ('home-unset', None, [UNREADABLE]), ('home-empty', '', [UNREADABLE])):
        lines, _ = list_run(args, root, name, [], value)
        assert lines == list_expected(rows), (name, lines, list_expected(rows))
    passed('scope-list-is-read-from-home', home=['list', 'no list', 'unset', 'empty'])


class Scope(App):
    """check_hosted_apps.App (input, frames, shutdown), started with Scope's own arguments, not a document path.
    HOME is always a directory of this check's own (home), or unset when home is None, so no run can read the owner's
    list of computers and knock on them; rows is the number of rows the section must have, which sets the window's
    height. prefix runs Scope under another program (strace), whose exit status is Scope's."""

    def __init__(self, image, arguments, x, display, evidence, label, home, rows=1, prefix=()):
        self.x, self.evidence, self.label, self.prefix = x, evidence, label, prefix
        self.window = None
        self.inputs = []
        self.started = time.monotonic()
        before = x.windows()
        env = dict(os.environ, DISPLAY=display)
        env.pop('XAUTHORITY', None)
        env.pop('HOME', None)
        if home is not None:
            env['HOME'] = str(home)
        self.out = (evidence / (label + '.stdout')).open('wb')
        self.err = (evidence / (label + '.stderr')).open('wb')
        self.p = subprocess.Popen([*prefix, str(image.resolve()), *arguments], env=env, stdin=subprocess.DEVNULL,
                                  stdout=self.out, stderr=self.err)
        size = (640, height(rows))
        try:
            def created():
                assert self.p.poll() is None, f'{label} exited: {self.p.returncode}'
                candidates = [w for w in x.windows() - before if x.name(w) == TITLE and x.geometry(w) == size]
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

    def pid(self):
        """Scope's own process: the one started, or, under a prefix, that program's one child."""
        if not self.prefix:
            return self.p.pid
        children = Path(f'/proc/{self.p.pid}/task/{self.p.pid}/children').read_text().split()
        assert len(children) == 1, ('the prefix program has not exactly one child', children)
        return int(children[0])


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
    """Everything Scope writes, read back from one frame."""
    host = read_text(frame, *HOST_AT, 48, BACKGROUND, 2)
    if '\0' in host[0]:
        host = read_text(frame, *HOST_AT, 64, BACKGROUND, 1)
    footer = bottom(rows_of(frame))
    return {'host': host,
            'processor': read_text(frame, 464, CPU_ROW + 26, 11, PANEL, 2),
            'processor-bar': bar(frame, CPU_ROW, CPU_FILL),
            'memory': read_text(frame, 464, MEMORY_ROW + 26, 11, PANEL, 2),
            'memory-bar': bar(frame, MEMORY_ROW, MEMORY_FILL),
            'detail': read_text(frame, *DETAIL_AT, 64, PANEL),
            'labels': (read_text(frame, BAR_X, CPU_ROW, 9, PANEL, 2), read_text(frame, BAR_X, MEMORY_ROW, 6, PANEL, 2),
                       read_text(frame, 28, footer + 22, 17, BACKGROUND)),
            'others': section(frame),
            'furniture': (read_text(frame, *OTHERS_AT, 15, BACKGROUND), read_text(frame, 28, footer + 44, 15, BACKGROUND))}


FURNITURE = (('OTHER COMPUTERS', {HEADING}), ('MADE IN HERBERT', {DIM}))


def section(frame):
    """The other computers' rows, read back. A row whose first cells are white is a computer's: ('computer', name,
    address line, result, what Linux said under it); any other is ('text', main, detail). Each part is (text, inks)."""
    rows = []
    for i in range(rows_of(frame)):
        y = ROW_TOP + ROW_STEP * i
        first = read_text(frame, 46, y, 24, PANEL, 2)
        if first[1] == {WHITE}:
            rows.append(('computer', first, read_text(frame, 46, y + DETAIL_DY, 51, PANEL),
                         read_text(frame, STATUS_X, y, 21, PANEL, 2), read_text(frame, STATUS_X, y + DETAIL_DY, 43, PANEL)))
        else:
            rows.append(('text', read_text(frame, 46, y, 47, PANEL, 2), read_text(frame, 46, y + DETAIL_DY, 94, PANEL)))
    return rows


def computer_row(name, where, result, said=''):
    """A computer's row as section() reads it: the name in white, the address line in grey, the result in green
    (answers), grey (checking) or amber, and what Linux said under an error in amber."""
    ink = GREEN if result == 'answers' else GREY if result == 'checking' else AMBER
    return ('computer', (name, {WHITE}), (where, {GREY}), (result, {ink}), (said, {AMBER} if said else set()))


def text_row(kind, main, detail):
    """A problem (amber) or a note (grey) row, from the line scope --computers prints for it."""
    return ('text', (main, {AMBER if kind == 'problem' else GREY}), (detail, {GREY} if detail else set()))


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


def memory_expected(total, available):
    """What Scope shows for these two figures, worked out exactly: the percent rounded half up, and the used and
    total amounts in tenths of the unit, rounded half up, with the unit's name."""
    used = total - available if available < total else 0
    quotient, rest = divmod(100 * used, total)
    unit, name = (1048576, 'GiB') if total >= 1048576 else (1024, 'MiB')
    def tenths(kib):
        whole, part = divmod(kib, unit)
        return whole * 10 + (part * 10 + unit // 2) // unit
    return quotient + (2 * rest >= total), tenths(used), tenths(total), name


LIGHT_AT, LIGHT_BOX = (604, 44), (596, 36, 16, 16)    # the light's middle, and a box round it (scope_draw)
LIGHT_DIM, LIGHT_BRIGHT = 3832176, 6867876
LABELS = (('PROCESSOR', {WHITE}), ('MEMORY', {WHITE}), ('ESC OR Q TO CLOSE', {GREY}))
TYPICAL_SHOWN = {'memory': ('75%', {WHITE}), 'memory-bar': 300, 'detail': ('11.7 GiB of 15.6 GiB in use', {GREY})}


def light(frame):
    return colour(frame, *LIGHT_AT)


def without_light(frame):
    """A digest of the frame with the light's box blanked: everything else Scope draws."""
    rgb, width = bytearray(frame['rgb']), frame['width']
    x, y, w, h = LIGHT_BOX
    for row in range(y, y + h):
        rgb[(row * width + x) * 3:(row * width + x + w) * 3] = bytes(w * 3)
    return hashlib.sha256(rgb).hexdigest()


def put(path, data):
    spare = path.with_name(path.name + '.new')
    spare.write_bytes(data)
    os.replace(spare, path)


def memory_at_a_reading(app, evidence, attempts=6):
    """Scope's memory figures against /proc/meminfo at the moment it read them. Frames are taken back to back, with
    /proc/meminfo read just before and just after each; when the light changes, the reading it shows was taken between
    the last two frames, so it must lie between the figures read around them. That bracket, about a tenth of a second
    wide, is the only tolerance; a reading that falls outside it (memory moving faster than that) is tried again, up
    to attempts readings."""
    tries = []
    last = light(app.frame())
    around = [real_memory()]
    deadline = time.monotonic() + 30
    while len(tries) < attempts and time.monotonic() < deadline:
        before = real_memory()
        frame = app.frame()
        after = real_memory()
        if light(frame) == last:
            around = [before, after]
            continue
        last = light(frame)
        expected = [memory_expected(*reading) for reading in around + [before, after]]
        around = [before, after]
        reading = shown(frame)
        detail = re.fullmatch(r'(\d+)\.(\d) (GiB|MiB) of (\d+)\.(\d) (GiB|MiB) in use', reading['detail'][0])
        figure = re.fullmatch(r'(\d{1,3})%', reading['memory'][0])
        got = None
        if detail and figure:
            got = (int(figure.group(1)), int(detail.group(1)) * 10 + int(detail.group(2)),
                   int(detail.group(4)) * 10 + int(detail.group(5)), detail.group(3), detail.group(6))
        tries.append({'shown': [reading['memory'], reading['memory-bar'], reading['detail']],
                      'expected_range': expected})
        if (got is not None and reading['memory'][1] == {WHITE} and reading['detail'][1] == {GREY}
                and min(e[0] for e in expected) <= got[0] <= max(e[0] for e in expected)
                and min(e[1] for e in expected) <= got[1] <= max(e[1] for e in expected)
                and got[2] == expected[0][2] and got[3] == got[4] == expected[0][3]
                and reading['memory-bar'] == 4 * got[0]):
            (evidence / 'scope-real-memory-tries.json').write_text(json.dumps(tries, indent=2, default=list) + '\n')
            return reading, len(tries)
    (evidence / 'scope-real-memory-tries.json').write_text(json.dumps(tries, indent=2, default=list) + '\n')
    assert tries, 'no new reading seen in 30 seconds: the light never changed'
    raise AssertionError(('memory figures never matched /proc/meminfo at a reading', tries))


def write_list(home, text):
    """A list of other computers at home/.config/herbert/computers.txt."""
    (home / '.config/herbert').mkdir(parents=True)
    (home / '.config/herbert/computers.txt').write_text(text)


def real_checks(args, x, display, evidence, passed):
    # The real /proc: the name, the labels, a processor figure with its bar, and the memory figures exactly as
    # /proc/meminfo gave them when Scope read it; then Escape. With no arguments Scope reads the list in its HOME, a
    # directory of this check's own, which names a listener and a closed port on this computer: both answer.
    home = empty_home(evidence, 'real')
    listener, closed = Listener(), ClosedPort(HIGH)
    write_list(home, f'# made by check_scope.py\nhere 127.0.0.1 {listener.port}\nshut {HIGH} {closed.port}\n')
    app = Scope(args.scope, [], x, display, evidence, 'scope-real', home, rows=2)
    try:
        name = real_name()
        others = [computer_row('here', f'127.0.0.1 port {listener.port}', 'answers'),
                  computer_row('shut', f'{HIGH} port {closed.port}', 'answers')]
        show_until(app, {'host': (name, {WHITE}), 'labels': LABELS, 'furniture': FURNITURE, 'others': others},
                   'name, labels and the other computers', 10)
        assert listener.connections >= 1 and listener.received == 0, (listener.connections, listener.received)
        reading = {}
        def figure():
            reading.update(shown(app.frame()))
            return re.fullmatch(r'\d{1,3}%', reading['processor'][0]) is not None
        wait_for(figure, 'a processor figure after the second sample', 10)
        cpu = int(reading['processor'][0][:-1])
        assert cpu <= 100 and reading['processor'][1] == {WHITE}, reading['processor']
        assert reading['processor-bar'] == 4 * cpu, (reading['processor-bar'], cpu)
        memory, tries = memory_at_a_reading(app, evidence)
        app.frame('figures')
        passed('scope-shows-this-machine', name_matches_proc=True, processor=cpu, memory=memory['memory'][0],
               detail=memory['detail'][0], readings_tried=tries)
        app.tap('Escape')
        app.finish()
        passed('scope-escape-quits')
        passed('scope-reads-the-list-in-home', rows=['here answers', 'shut answers (refused)'])
    finally:
        app.close()
        listener.close()
        closed.close()


def quit_checks(args, x, display, evidence, passed):
    # Each quits a window whose list is missing (one grey note), unreadable (a directory where the list should be)
    # or unknown (HOME not set): the section is one row, saying so.
    unreadable = empty_home(evidence, 'quit-unreadable')
    (unreadable / '.config/herbert/computers.txt').mkdir(parents=True)
    for label, how, home, note in (
            ('q', lambda app: app.tap('q'), empty_home(evidence, 'quit-q'), NONE_LISTED),
            ('shift-q', lambda app: app.tap('q', 'Shift_L'), unreadable, UNREADABLE),
            ('window-close', lambda app: x.delete(app.window), None, UNREADABLE)):
        app = Scope(args.scope, [], x, display, evidence, 'scope-' + label, home)
        try:
            show_until(app, {'host': (real_name(), {WHITE}), 'labels': LABELS, 'others': [text_row(*note)]},
                       label + ' window drawn', 10)
            how(app)
            app.finish()
            passed('scope-' + label + '-quits', list={'q': 'missing', 'shift-q': 'a directory',
                                                      'window-close': 'HOME not set'}[label], note=note[1])
        finally:
            app.close()


def light_checks(args, x, display, evidence, passed):
    # Files that never change, read every 200 ms: the figures stay as they are, so the light alone shows the readings.
    # It must change again and again while nothing else in the window does. The first frame looked at comes a second
    # after the start, so a slow start changes nothing here.
    files = evidence / 'light-files'
    files.mkdir()
    stat, mem, host = files / 'stat', files / 'meminfo', files / 'hostname'
    put(stat, STAT_ONE_1); put(mem, MEM_TYPICAL); put(host, b'test-host\n')
    app = Scope(args.scope, ['--test', str(stat), str(mem), str(host), '200'], x, display, evidence,
                'scope-light', empty_home(evidence, 'light'))
    try:
        time.sleep(1)
        show_until(app, {'host': ('test-host', {WHITE}), 'processor': ('-', {GREY}), 'processor-bar': 0,
                         **TYPICAL_SHOWN}, 'steady figures', 10)
        lights, rest, changes = [], set(), 0
        started = time.monotonic()
        while changes < 8 and time.monotonic() - started < 20:
            frame = app.frame()
            assert light(frame) in (LIGHT_DIM, LIGHT_BRIGHT), ('light colour', light(frame))
            rest.add(without_light(frame))
            changes += bool(lights) and light(frame) != lights[-1]
            lights.append(light(frame))
            time.sleep(.03)
        assert changes >= 8, ('the light does not change at each reading', changes, len(lights))
        assert len(rest) == 1, 'more than the light changed while the figures stood still'
        app.frame('light')
        app.tap('Escape')
        app.finish()
        passed('scope-light-changes-at-every-reading', changes=changes, frames_looked_at=len(lights),
               seconds=round(time.monotonic() - started, 2), rest_of_window_unchanged=True)
    finally:
        app.close()


def files_checks(args, x, display, evidence, passed):
    # Files this check writes: exact text, inks and bars for known figures, the unavailable state, and recovery.
    files = evidence / 'window-files'
    files.mkdir()
    stat, mem, host = files / 'stat', files / 'meminfo', files / 'hostname'
    put(stat, STAT_ONE_1); put(mem, MEM_TYPICAL); put(host, b'test-host\n')
    app = Scope(args.scope, ['--test', str(stat), str(mem), str(host), '100'], x, display, evidence,
                'scope-files', empty_home(evidence, 'files'))
    try:
        show_until(app, {'host': ('test-host', {WHITE}), 'processor': ('-', {GREY}), 'processor-bar': 0,
                         'labels': LABELS, 'furniture': FURNITURE, 'others': [text_row(*NONE_LISTED)],
                         **TYPICAL_SHOWN}, 'first sample only: a dash')
        app.frame('dash')
        steps = [(STAT_ONE_2, '40%', 160),
                 (stat_line(2300, 0, 600, 8550, 550, 0, 0, 0, 0, 0), '100%', 400),
                 (stat_line(2300, 0, 600, 9550, 550, 0, 0, 0, 0, 0), '0%', 0)]
        for data, text, width in steps:
            put(stat, data)
            show_until(app, {'processor': (text, {WHITE}), 'processor-bar': width, **TYPICAL_SHOWN},
                       'processor ' + text)
            app.frame('processor-' + text.rstrip('%'))
        passed('scope-draws-exact-figures-and-bars', processor=[s[1] for s in steps], memory='75%')
        # The same file again and again: every interval is zero-length, and the figure must stay.
        put(stat, stat_line(2600, 0, 600, 9750, 550, 0, 0, 0, 0, 0))
        show_until(app, {'processor': ('60%', {WHITE}), 'processor-bar': 240}, 'processor 60%')
        time.sleep(.6)
        kept = shown(app.frame())
        assert (kept['processor'], kept['processor-bar']) == (('60%', {WHITE}), 240), kept['processor']
        passed('scope-zero-length-interval-keeps-the-figure', figure='60%', seconds_unchanged=0.6)
        put(mem, meminfo(524288, 104858))
        show_until(app, {'memory': ('80%', {WHITE}), 'memory-bar': 320,
                         'detail': ('409.6 MiB of 512.0 MiB in use', {GREY})}, 'memory in MiB')
        app.frame('mib')
        put(mem, MEM_TYPICAL)
        show_until(app, TYPICAL_SHOWN, 'memory in GiB again')
        passed('scope-draws-memory-in-mib-and-gib', mib='409.6 MiB of 512.0 MiB in use',
               gib='11.7 GiB of 15.6 GiB in use')
        name48 = ('forty-eight-' + 'abcdefghij' * 4)[:48]
        name60 = ('sixty-' + 'abcdefghij' * 6)[:60]
        put(host, name48.encode() + b'\n')
        wait_for(lambda: read_text(app.frame(), *HOST_AT, 48, BACKGROUND, 2) == (name48, {WHITE}), '48-byte name')
        put(host, name60.encode() + b'\n')
        wait_for(lambda: read_text(app.frame(), *HOST_AT, 64, BACKGROUND, 1) == (name60, {WHITE}),
                 '60-byte name drawn smaller')
        app.frame('long-name')
        put(host, b'test-host\n')
        show_until(app, {'host': ('test-host', {WHITE})}, 'short name again')
        passed('scope-draws-a-name-over-48-bytes-smaller', name_48_scale=2, name_60_scale=1)
        stat.unlink()
        show_until(app, {'processor': ('unavailable', {AMBER}), 'processor-bar': 0, **TYPICAL_SHOWN},
                   'processor unavailable')
        mem.unlink()
        show_until(app, {'memory': ('unavailable', {AMBER}), 'memory-bar': 0, 'detail': ('', set())},
                   'memory unavailable')
        host.unlink()
        show_until(app, {'host': ('unavailable', {AMBER})}, 'name unavailable')
        app.frame('unavailable')
        passed('scope-shows-unavailable-and-keeps-running')
        put(stat, stat_line(2600, 0, 600, 9750, 550, 0, 0, 0, 0, 0))
        put(mem, MEM_TYPICAL)
        put(host, b'test-host\n')
        show_until(app, {'host': ('test-host', {WHITE}), 'processor': ('-', {GREY}), **TYPICAL_SHOWN},
                   'files back: a new first sample')
        put(stat, stat_line(3000, 0, 700, 10150, 650, 0, 0, 0, 0, 0))
        show_until(app, {'processor': ('50%', {WHITE}), 'processor-bar': 200}, 'processor after recovery')
        app.frame('recovered')
        passed('scope-recovers-when-the-files-return')
        app.tap('Escape')
        app.finish()
    finally:
        app.close()


def fixed_files(evidence, label):
    """Steady /proc stand-ins for a window whose figures do not matter: (stat, meminfo, hostname) paths."""
    files = evidence / label
    files.mkdir()
    stat, mem, host = files / 'stat', files / 'meminfo', files / 'hostname'
    put(stat, STAT_ONE_1); put(mem, MEM_TYPICAL); put(host, b'test-host\n')
    return str(stat), str(mem), str(host)


def sockets(pid):
    """The process's open sockets, {descriptor: inode}."""
    held = {}
    for fd in os.listdir(f'/proc/{pid}/fd'):
        try:
            link = os.readlink(f'/proc/{pid}/fd/{fd}')
        except FileNotFoundError:
            continue
        if link.startswith('socket:['):
            held[int(fd)] = int(link[8:-1])
    return held


def knocks_open(pid):
    """Scope's sockets but the display's: its knocks under way. The display's is the lowest-numbered socket, since
    Scope opens it before its first knock and keeps it."""
    held = sockets(pid)
    return {fd: inode for fd, inode in held.items() if fd != min(held)}


def knock_ports(pid):
    """The ports Scope's knocks under way are knocking on, from the kernel's table of TCP sockets."""
    inodes = set(knocks_open(pid).values())
    ports = []
    for line in Path(f'/proc/{pid}/net/tcp').read_text().splitlines()[1:]:
        fields = line.split()
        if int(fields[9]) in inodes:
            ports.append(int(fields[2].split(':')[1], 16))
    return sorted(ports)


def pending_checks(args, x, display, evidence, passed):
    # A computer that never answers (check_net's black hole), knocked with a 10-second limit, beside two that answer
    # at once. While that knock is under way its row says checking, in grey, the other rows show their answers, the
    # light changes at every reading (every 200 ms) and Escape closes the window within 300 ms. A window that waited
    # on the knock would show nothing new and not close for up to 10 seconds; 300 ms is far below that and leaves
    # room for a busy machine (the window normally closes within a few ms of the key).
    stat, mem, host = fixed_files(evidence, 'pending-files')
    hole, listener, closed = BlackHole(), Listener(SPREAD), ClosedPort(HIGH)
    computers = evidence / 'pending-files' / 'computers.txt'
    computers.write_text(f'far 127.0.0.1 {hole.port}\nnear {SPREAD} {listener.port}\nshut {HIGH} {closed.port}\n')
    app = Scope(args.scope, ['--test', stat, mem, host, '200', str(computers), '20000', '10000'], x, display, evidence,
                'scope-pending', empty_home(evidence, 'pending'), rows=3)
    try:
        rows = [computer_row('far', f'127.0.0.1 port {hole.port}', 'checking'),
                computer_row('near', f'{SPREAD} port {listener.port}', 'answers'),
                computer_row('shut', f'{HIGH} port {closed.port}', 'answers')]
        show_until(app, {'others': rows, 'furniture': FURNITURE}, 'far checking, near and shut answering')
        app.frame('checking')
        knock = knocks_open(app.pid())
        assert len(knock) == 1 and knock_ports(app.pid()) == [hole.port], ('not one knock under way, to far', knock,
                                                                           knock_ports(app.pid()))
        changes, frames = [], 0
        started = time.monotonic()
        last = light(app.frame())
        while time.monotonic() - started < 2.5:
            frame = app.frame()
            frames += 1
            assert section(frame) == rows, ('a row changed while far was being knocked', section(frame))
            if light(frame) != last:
                changes.append(time.monotonic())
                last = light(frame)
            time.sleep(.02)
        gaps = [round(b - a, 3) for a, b in zip([started] + changes, changes)]
        assert len(changes) >= 8 and max(gaps) <= .6, ('the light stopped changing while a knock was under way',
                                                        len(changes), gaps)
        assert knocks_open(app.pid()) == knock, ('the knock to far ended or changed', knock, knocks_open(app.pid()))
        held, how = pending(hole.port, 100)
        assert held, ('the black hole stopped being one', how)
        since = time.monotonic() - app.started
        assert since < 8, ('too slow to press Escape while the 10-second knock is under way', since)
        before = time.monotonic()
        app.key('Escape', True)
        app.key('Escape', False)
        status = app.p.wait(timeout=11)
        took = time.monotonic() - before
        assert status == 0 and took <= .3, ('Escape did not close the window at once', status, round(took, 3))
        app.finish()
        passed('scope-checking-until-the-first-knock-ends', row='far checking (grey)', others='answers')
        passed('scope-knocks-never-hold-the-window', limit_ms=10000, light_changes=len(changes), frames=frames,
               largest_gap_s=max(gaps), escape_closed_in_s=round(took, 3), escape_bound_s=.3,
               seconds_into_the_knock=round(since, 2))
    finally:
        app.close()
        for fixture in (hole, listener, closed):
            fixture.close()


def results_checks(args, x, display, evidence, passed):
    # Every row the list can make, on the window: answers (a listener), answers again for a refusal (a port held
    # closed), checking then no answer (the black hole), a 24-byte name, a line not understood, and a seventh computer,
    # never knocked. A row keeps its last result while its next knock is under way.
    stat, mem, host = fixed_files(evidence, 'results-files')
    hole, near, shut, here, there, never = (BlackHole(), Listener(SPREAD), ClosedPort(HIGH), Listener(), ClosedPort(),
                                            Listener())
    name24 = 'abcdefghijklmnopqrstuvwx'
    computers = evidence / 'results-files' / 'computers.txt'
    computers.write_text(f'far 127.0.0.1 {hole.port}\nnear {SPREAD} {near.port}\nshut {HIGH} {shut.port}\n'
                         f'# a comment\nbad line\nhere 127.0.0.1 {here.port}\nthere 127.0.0.1 {there.port}\n'
                         f'{name24} {SPREAD} {near.port}\nseventh 127.0.0.1 {never.port}\n')
    app = Scope(args.scope, ['--test', stat, mem, host, '300', str(computers), '3000', '2000'], x, display, evidence,
                'scope-results', empty_home(evidence, 'results'), rows=8)
    try:
        def rows(far):
            return [computer_row('far', f'127.0.0.1 port {hole.port}', far),
                    computer_row('near', f'{SPREAD} port {near.port}', 'answers'),
                    computer_row('shut', f'{HIGH} port {shut.port}', 'answers'),
                    computer_row('here', f'127.0.0.1 port {here.port}', 'answers'),
                    computer_row('there', f'127.0.0.1 port {there.port}', 'answers'),
                    computer_row(name24, f'{SPREAD} port {near.port}', 'answers'),
                    text_row('problem', 'line 5 not understood', R_WORDS),
                    text_row('problem', 'line 9: more than 6 listed', R_SEVENTH)]
        show_until(app, {'others': rows('checking'), 'labels': LABELS, 'furniture': FURNITURE},
                   'eight rows, far checking')
        first = knocks_open(app.pid())
        assert len(first) == 1 and knock_ports(app.pid()) == [hole.port], ('not one knock under way, to far', first)
        app.frame('checking')
        show_until(app, {'others': rows('no answer')}, 'far: no answer', 5)
        app.frame('no-answer')
        # The next knock to far starts 3 s after the first and is under way for 2 s: the row must say no answer all
        # the while, and some frame must be read while that knock (a socket other than the first's) is open.
        kept, frames = None, 0
        started = time.monotonic()
        while time.monotonic() - started < 3.5:
            frame = app.frame()
            frames += 1
            assert section(frame) == rows('no answer'), ('a row changed', section(frame))
            open_now = knocks_open(app.pid())
            if set(open_now.values()) - set(first.values()) and hole.port in knock_ports(app.pid()):
                kept = round(time.monotonic() - app.started, 2)
            time.sleep(.03)
        assert kept is not None, 'no frame was read while the second knock to far was under way'
        assert never.connections == 0, ('the seventh computer was knocked', never.connections)
        assert near.connections >= 2 and here.connections >= 1, (near.connections, here.connections)
        assert near.received == here.received == 0, ('a knock sent bytes', near.received, here.received)
        app.tap('Escape')
        app.finish()
        passed('scope-draws-every-kind-of-row', rows=8, answers=['near', 'here', name24], refused_shows='answers',
               no_answer='far', problems=['line 5 not understood', 'line 9: more than 6 listed'],
               seventh_knocked=never.connections)
        passed('scope-row-keeps-its-result-while-the-next-knock-is-under-way', frames=frames,
               second_knock_seen_at_s=kept)
    finally:
        app.close()
        for fixture in (hole, near, shut, here, there, never):
            fixture.close()


def strace_lines(trace):
    return [re.sub(r'^\d+ +', '', line) for line in trace.read_text().splitlines()]


def injected_checks(args, x, display, evidence, passed):
    # unreachable and error cannot be made on loopback without privileges, so strace makes each knock's connect fail
    # with that error instead (the first connect, the display's, is left alone): the knock never reaches the
    # listener, and the row shows the result, and under error what Linux said, or its number when it has no words.
    stat, mem, host = fixed_files(evidence, 'injected-files')
    listener = Listener()
    computers = evidence / 'injected-files' / 'computers.txt'
    computers.write_text(f'lost 127.0.0.1 {listener.port}\n')
    seen = {}
    try:
        for errno, result, said in (('EHOSTUNREACH', 'unreachable', ''), ('EACCES', 'error', 'permission denied'),
                                    ('EBADMSG', 'error', 'Linux error 74')):
            trace = evidence / f'scope-{errno}.strace'
            prefix = ['strace', '-f', '-qq', '-o', str(trace), '-e', 'trace=connect', '-e',
                      f'inject=connect:error={errno}:when=2+']
            app = Scope(args.scope, ['--test', stat, mem, host, '1000', str(computers), '20000', '2000'], x, display,
                        evidence, 'scope-' + errno, empty_home(evidence, errno), prefix=prefix)
            try:
                row = computer_row('lost', f'127.0.0.1 port {listener.port}', result, said)
                show_until(app, {'others': [row]}, f'{errno}: {result} {said}')
                app.frame('row')
                app.tap('Escape')
                app.finish()
            finally:
                app.close()
            lines = strace_lines(trace)
            assert len(lines) >= 2 and lines[0].startswith('connect(') and 'AF_UNIX' in lines[0], lines
            assert 'INJECTED' not in lines[0], lines[0]
            knock = (f'connect(4, {{sa_family=AF_INET, sin_port=htons({listener.port}), '
                     f'sin_addr=inet_addr("127.0.0.1")}}, 16) = -1 {errno} ')
            assert all(line.startswith(knock) and line.endswith('(INJECTED)') for line in lines[1:]), lines
            seen[errno] = [result, said]
        assert listener.connections == 0, ('an injected knock reached the listener', listener.connections)
    finally:
        listener.close()
    passed('scope-draws-unreachable-and-errors', rows=seen, how='strace makes connect fail')


CLOCK = re.compile(r'clock_gettime\(CLOCK_MONOTONIC, \{tv_sec=(\d+), tv_nsec=(\d+)\}\) = 0')
KNOCK_SOCKET = re.compile(r'socket\(AF_INET, (\S+), IPPROTO_TCP\) = (\d+)')
KNOCK_CONNECT = re.compile(r'connect\((\d+), \{sa_family=AF_INET, sin_port=htons\((\d+)\), '
                           r'sin_addr=inet_addr\("([\d.]+)"\)\}, 16\) = (.*)')
LOOK = re.compile(r'poll\(\[\{fd=(\d+), events=POLLOUT\}\], 1, 0\) = (\d+)')
WAIT = re.compile(r'poll\(\[\{fd=\d+, events=POLLIN\}(.*?)\], (\d+), (\d+)\) = ')    # the window's: display first
CLOSE = re.compile(r'close\((\d+)\) += ')
SENT = re.compile(r'(write|writev|sendto|sendmsg)\((\d+),')


def knocks_traced(lines):
    """Each knock in a trace of Scope: its socket's flags, descriptor and port, its start (the clock reading just
    before its socket, ns), its looks (zero-wait polls on it alone: the clock just before, what it found), whether
    every wait of the window's loop while it was under way included it, its close (the clock just after, ns) and
    whether that came at the window's end (after the Escape: the knock given up)."""
    knocks, live, clock = [], {}, None
    for line in lines:
        if (m := CLOCK.fullmatch(line)):
            clock = int(m.group(1)) * 10**9 + int(m.group(2))
            for knock in knocks:
                if knock.get('closing'):
                    knock['end'], knock['closing'] = clock, False
        elif (m := KNOCK_SOCKET.fullmatch(line)):
            knock = {'flags': set(m.group(1).split('|')), 'fd': int(m.group(2)), 'start': clock, 'looks': [],
                     'waits': 0, 'waits_without': 0, 'sent': []}
            knocks.append(knock)
            live[knock['fd']] = knock
        elif (m := KNOCK_CONNECT.fullmatch(line)) and int(m.group(1)) in live:
            live[int(m.group(1))].update(port=int(m.group(2)), address=m.group(3), connect=m.group(4))
        elif (m := LOOK.match(line)) and int(m.group(1)) in live:
            live[int(m.group(1))]['looks'].append((clock, int(m.group(2))))
        elif (m := WAIT.match(line)):
            listed = {int(fd) for fd in re.findall(r'fd=(\d+), events=POLLOUT', m.group(1))}
            for fd, knock in live.items():
                knock['waits'] += 1
                knock['waits_without'] += fd not in listed
        elif (m := CLOSE.match(line)) and int(m.group(1)) in live:
            knock = live.pop(int(m.group(1)))
            knock['closing'] = True
        elif (m := SENT.match(line)) and int(m.group(2)) in live:
            live[int(m.group(2))]['sent'].append(line)
        elif line.startswith('exit_group('):
            break
    return knocks, live


def timing_checks(args, x, display, evidence, passed):
    # Under strace, with knocks every 700 ms and a limit of 300 ms, and readings only every minute, so that nothing
    # but the knocks and the display wakes the window: the knocks to each computer start 700 ms apart; one to the
    # black hole says no answer only after a look with no wait, at or past 300 ms from its start (its own clock), and
    # ends within 100 ms of the limit; one that is answered or refused ends within 50 ms (the window wakes for its
    # socket); every wait of the window includes each knock under way; nothing is ever sent on a knock's socket; and
    # the knock still under way at Escape is closed before Scope exits.
    every, limit = 700, 300
    stat, mem, host = fixed_files(evidence, 'timing-files')
    hole, near, shut = BlackHole(), Listener(SPREAD), ClosedPort(HIGH)
    computers = evidence / 'timing-files' / 'computers.txt'
    computers.write_text(f'far 127.0.0.1 {hole.port}\nnear {SPREAD} {near.port}\nshut {HIGH} {shut.port}\n')
    trace = evidence / 'scope-timing.strace'
    prefix = ['strace', '-f', '-qq', '--seccomp-bpf', '-o', str(trace), '-e',
              'trace=clock_gettime,socket,connect,poll,getsockopt,close,write,writev,sendto,sendmsg,exit_group']
    app = Scope(args.scope, ['--test', stat, mem, host, '60000', str(computers), str(every), str(limit)], x, display,
                evidence, 'scope-timing', empty_home(evidence, 'timing'), rows=3, prefix=prefix)
    try:
        show_until(app, {'others': [computer_row('far', f'127.0.0.1 port {hole.port}', 'no answer'),
                                    computer_row('near', f'{SPREAD} port {near.port}', 'answers'),
                                    computer_row('shut', f'{HIGH} port {shut.port}', 'answers')]}, 'the knocks shown')
        time.sleep(max(0, 4.5 - (time.monotonic() - app.started)))
        wait_for(lambda: knock_ports(app.pid()) == [hole.port], 'a knock to far under way', 3)
        app.tap('Escape')
        app.finish()
    finally:
        app.close()
        for fixture in (hole, near, shut):
            fixture.close()
    knocks, left = knocks_traced(strace_lines(trace))
    assert not left, ('sockets still open when Scope exited', left)
    ports = {hole.port: 'far', near.port: 'near', shut.port: 'shut'}
    report = {}
    for port, name in ports.items():
        mine = [k for k in knocks if k.get('port') == port]
        starts = [k['start'] for k in mine]
        gaps = [round((b - a) / 10**6, 3) for a, b in zip(starts, starts[1:])]
        assert len(mine) >= 5, (name, 'too few knocks', len(mine))
        # Start to start on the window's millisecond clock; a knock's own clock, read just after, may be up to a
        # few ms later than the window's reading for the one before, so the gap may read that much short.
        assert all(every - 5 <= gap <= every + 100 for gap in gaps), (name, 'knocks not 700 ms apart', gaps)
        report[name] = {'knocks': len(mine), 'gaps_ms': gaps}
        for k in mine:
            assert k['flags'] == {'SOCK_STREAM', 'SOCK_CLOEXEC', 'SOCK_NONBLOCK'}, k['flags']
            assert k['sent'] == [], (name, 'bytes sent on a knock', k['sent'])
            assert k['waits_without'] == 0, (name, 'the window waited without a knock under way', k)
            took = (k['end'] - k['start']) / 10**6
            if name == 'far' and k is not mine[-1]:
                assert k['waits'] >= 1, (name, 'the window never waited while this knock was under way', k)
                assert k['looks'] and all(found == 0 for _, found in k['looks']), (name, 'a look found something', k)
                assert (k['looks'][-1][0] - k['start']) / 10**6 >= limit, (name, 'no answer before the limit', k)
                assert limit <= took <= limit + 100, (name, 'no answer not within 100 ms of the limit', took)
            elif name != 'far':
                assert took <= 50, (name, 'an answer was not seen at once', took)
        report[name]['ms'] = [round((k['end'] - k['start']) / 10**6, 1) for k in mine]
    last = [k for k in knocks if k.get('port') == hole.port][-1]
    assert (last['end'] - last['start']) / 10**6 < limit, ('the last knock to far was not under way at Escape', last)
    passed('scope-knocks-keep-their-interval-and-limit', every_ms=every, limit_ms=limit, knocks=report,
           given_up_at_escape='closed before exit')


def window_checks(args, x, display, evidence, passed):
    real_checks(args, x, display, evidence, passed)
    quit_checks(args, x, display, evidence, passed)
    light_checks(args, x, display, evidence, passed)
    files_checks(args, x, display, evidence, passed)
    pending_checks(args, x, display, evidence, passed)
    results_checks(args, x, display, evidence, passed)
    injected_checks(args, x, display, evidence, passed)
    timing_checks(args, x, display, evidence, passed)


def io_counts(pid):
    fields = dict(line.split(': ') for line in Path(f'/proc/{pid}/io').read_text().splitlines())
    return int(fields['syscr']), int(fields['rchar'])


def memory_checks(args, x, display, evidence, passed):
    # Every 10 ms, about a hundred times the window's own rate, so that even a few bytes kept per frame add up to more
    # than the tolerance in the time given. Scope reads three links that this check turns, every 0.4 s, through
    # five states: the real /proc; files without a final newline (memory under 1 GiB, a 60-byte name); the next such
    # processor file (a figure from files); all three missing; all three malformed (unavailable). Each state's picture
    # is read back once per turn; every state must have been seen as it should look.
    # All the while it knocks on three computers every 20 ms, 250 times its own rate, with a 10 ms limit: a listener
    # (answers), a port held closed (refused) and the black hole (no answer); their rows must look so in every state
    # seen. At every sample its descriptors must be the same, but for knocks under way: at most three sockets besides
    # the display's, none of them one seen at the sample before (a knock lasts 10 ms; samples are 2 s apart), so no
    # knock leaves its socket open. At the end the closed port becomes a black hole and the black hole a listener,
    # and both rows must follow, so those two were still being knocked.
    fixtures, links = evidence / 'memory-fixtures', evidence / 'memory-links'
    fixtures.mkdir()
    links.mkdir()
    long_name = ('a-name-longer-than-48-bytes-' + 'x' * 40)[:60]
    # stat-a to stat-b: user +100, system +50, idle +50, iowait +10: 150 of 210, 71 %.
    for name, data in (('stat-a', CPU_LINE_2[:-1]), ('stat-b', b'cpu  1400 0 650 8600 560 0 0 0 0 0'),
                       ('stat-bad', b'cpu  1 2 x 4\n'),
                       ('meminfo-small', b'MemTotal:  524288 kB\nMemAvailable:  104858 kB'),
                       ('meminfo-bad', b'MemTotal:  524288 kB\n'), ('name-long', long_name.encode()),
                       ('name-empty', b'')):
        (fixtures / name).write_bytes(data)
    def missing(reading):
        return (reading['host'] == ('unavailable', {AMBER}) and reading['processor'] == ('unavailable', {AMBER})
                and reading['memory'] == ('unavailable', {AMBER}) and reading['detail'] == ('', set()))
    def live(reading):
        return (reading['host'] == (real_name(), {WHITE}) and re.fullmatch(r'\d{1,3}%|-', reading['processor'][0])
                and re.fullmatch(r'\d{1,3}%', reading['memory'][0]) is not None)
    def files_shown(processor, width):
        def check(reading):
            return (read_text(reading['frame'], *HOST_AT, 64, BACKGROUND, 1) == (long_name, {WHITE})
                    and reading['processor'][0] == processor and reading['processor-bar'] == width
                    and reading['memory'] == ('80%', {WHITE})
                    and reading['detail'] == ('409.6 MiB of 512.0 MiB in use', {GREY}))
        return check
    proc = {'stat': '/proc/stat', 'meminfo': '/proc/meminfo', 'hostname': '/proc/sys/kernel/hostname'}
    states = [('live', proc, live),
              ('files', {'stat': fixtures / 'stat-a', 'meminfo': fixtures / 'meminfo-small',
                         'hostname': fixtures / 'name-long'}, files_shown('-', 0)),
              ('files-moving', {'stat': fixtures / 'stat-b', 'meminfo': fixtures / 'meminfo-small',
                                'hostname': fixtures / 'name-long'}, files_shown('71%', 284)),
              ('missing', {'stat': None, 'meminfo': None, 'hostname': None}, missing),
              ('malformed', {'stat': fixtures / 'stat-bad', 'meminfo': fixtures / 'meminfo-bad',
                             'hostname': fixtures / 'name-empty'}, missing)]
    def point(targets):
        for key, target in targets.items():
            link = links / key
            if target is None:
                if link.is_symlink():
                    link.unlink()
            else:
                spare = links / (key + '.new')
                os.symlink(target, spare)
                os.replace(spare, link)
    point(proc)
    interval, every, limit = 10, 20, 10
    here, shut, far = Listener(), ClosedPort(), BlackHole()
    computers = fixtures / 'computers.txt'
    computers.write_text(f'here 127.0.0.1 {here.port}\nshut 127.0.0.1 {shut.port}\nfar 127.0.0.1 {far.port}\n')
    def others(here_shows, shut_shows, far_shows):
        return [computer_row('here', f'127.0.0.1 port {here.port}', here_shows),
                computer_row('shut', f'127.0.0.1 port {shut.port}', shut_shows),
                computer_row('far', f'127.0.0.1 port {far.port}', far_shows)]
    knocking = others('answers', 'answers', 'no answer')
    app = Scope(args.scope, ['--test', str(links / 'stat'), str(links / 'meminfo'), str(links / 'hostname'),
                             str(interval), str(computers), str(every), str(limit)], x, display, evidence,
                'scope-memory', empty_home(evidence, 'memory'), rows=3)
    fixtures_open = [here, shut, far]
    try:
        show_until(app, {'host': (real_name(), {WHITE}), 'others': knocking}, 'memory run drawn', 10)
        seen = {name: [0, 0] for name, _, _ in states}
        samples, turns, started, steady, before = [], 0, None, None, set()
        while True:
            name, targets, check = states[turns % len(states)]
            point(targets)
            turned = time.monotonic()
            time.sleep(.15)
            frame = app.frame()
            reading = dict(shown(frame), frame=frame)
            seen[name][1] += 1
            if check(reading) and reading['others'] == knocking:
                seen[name][0] += 1
            elif seen[name][1] <= 2 * len(states):
                app.frame(f'state-{name}-not-yet')
            turns += 1
            # Two whole turns of every state before the first sample, so each path has run before it is measured.
            if started is None and turns == 2 * len(states):
                started = time.monotonic()
                last_sample = None
            if started is not None and (last_sample is None or time.monotonic() - last_sample >= 2):
                last_sample = time.monotonic()
                sample = process_memory(app.p.pid)
                sample['seconds'] = round(last_sample - started, 3)
                sample['syscr'], sample['rchar'] = io_counts(app.p.pid)
                # One listing of the descriptors, so a knock that opens or closes meanwhile is seen once, as it is.
                fds = {}
                for fd in os.listdir(f'/proc/{app.p.pid}/fd'):
                    try:
                        fds[int(fd)] = os.readlink(f'/proc/{app.p.pid}/fd/{fd}')
                    except FileNotFoundError:
                        pass
                held = {fd: int(link[8:-1]) for fd, link in fds.items() if link.startswith('socket:[')}
                knocks = {inode for fd, inode in held.items() if fd != min(held)}
                sample['descriptors'] = sorted((fd, link) for fd, link in fds.items()
                                               if fd not in held or fd == min(held))
                sample['knock_sockets'] = sorted(knocks)
                sample['listener_connections'] = here.connections
                steady = steady or sample['descriptors']
                assert sample['descriptors'] == steady, ('descriptors changed', steady, sample['descriptors'])
                assert len(knocks) <= 3 and not knocks & before, ('a knock kept its socket', knocks, before)
                before = knocks
                samples.append(sample)
                (evidence / 'scope-memory.json').write_text(json.dumps(samples, indent=2) + '\n')
                if last_sample - started >= args.seconds:
                    break
            time.sleep(max(0, .4 - (time.monotonic() - turned)))
        seconds = samples[-1]['seconds']
        (evidence / 'scope-memory-states.json').write_text(json.dumps(seen, indent=2) + '\n')
        assert all(matched for matched, _ in seen.values()), ('a state never looked as it should', seen)
        # Every file in this run gives its figure, or shows its end, by its second read call: the live /proc files
        # finish within their first read (their figures come first, and a read takes up to 4096 bytes), the files
        # written here are shorter than one read, so a second read finds their end, and a missing file is not read.
        # The display socket's receives are not read calls. So a sixth of the read calls is a lower bound on frames.
        reads = samples[-1]['syscr'] - samples[0]['syscr']
        frames_at_least = reads // 6
        assert frames_at_least >= seconds * 1000 / interval / 10, ('too few frames to judge memory', reads, seconds)
        stable_memory(samples, 'scope redrawing every 10 ms through the real /proc, odd, missing and bad files')
        rss = [s['Rss'] for s in samples]
        answered = samples[-1]['listener_connections'] - samples[0]['listener_connections']
        assert answered >= seconds * 1000 / every / 4, ('too few knocks answered to judge memory', answered, seconds)
        assert here.received == 0 and not here.errors, ('a knock sent bytes', here.received, here.errors[:3])
        point(proc)
        shut_port, far_port = shut.port, far.port
        shut.close()
        far.close()
        fixtures_open = [here, BlackHole(port=shut_port), Listener(port=far_port)]
        show_until(app, {'others': others('answers', 'no answer', 'answers')},
                   'the closed port now a black hole, the black hole a listener', 5)
        x.delete(app.window)
        app.finish()
        passed('scope-memory-flat', seconds=seconds, samples=len(samples), read_calls=reads,
               frames_at_least=frames_at_least, states_seen_as_they_should_look=seen,
               rss_kib_start=rss[0], rss_kib_end=rss[-1], rss_kib_min=min(rss), rss_kib_max=max(rss),
               rss_tolerance_kib=64, vm_size_kib=samples[0]['VmSize'], vm_size_must_not_change=True)
        passed('scope-memory-flat-while-knocking', every_ms=every, limit_ms=limit,
               knocks_answered_while_measured=answered, rows=['answers', 'answers (refused)', 'no answer'],
               descriptors=steady, knock_sockets_at_samples=[s['knock_sockets'] for s in samples],
               still_knocked_at_the_end={'shut': 'no answer', 'far': 'answers'})
    finally:
        app.close()
        for fixture in fixtures_open:
            fixture.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--scope', type=Path, default=ROOT / 'build/scope')
    parser.add_argument('--seconds', type=float, default=120, help='length of the memory run')
    parser.add_argument('--only', choices=['all', 'sample', 'window', 'memory'], default='all')
    parser.add_argument('--evidence', type=Path)
    args = parser.parse_args()
    assert args.seconds >= 3, 'at least 3 seconds required; release qualification uses the default 120'
    evidence = (args.evidence or Path(tempfile.mkdtemp(prefix='herbert-hosted-apps-scope-'))).resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(__file__, evidence / 'check_scope.py')
    shutil.copyfile(args.scope, evidence / 'scope.elf')
    combined = args.scope.parent / (args.scope.name + '-work') / 'source.herb'
    if combined.exists():
        shutil.copyfile(combined, evidence / 'scope-source.herb')
    result = {'mode': 'sample-files and private-Xvfb-XTest', 'scope': args.only, 'memory_seconds': args.seconds,
              'image': static_elf(args.scope), 'checks': []}
    def passed(name, **details):
        result['checks'].append(dict(name=name, **details))
        print('PASS:', name, json.dumps(details, sort_keys=True) if details else '', flush=True)
        (evidence / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print('Evidence:', evidence, flush=True)
    try:
        if args.only in ('all', 'sample'):
            sample_checks(args, evidence, passed)
            list_checks(args, evidence, passed)
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
    print(f'scope: {len(result["checks"])}/{len(result["checks"])} PASS; evidence {evidence}')


if __name__ == '__main__':
    main()
