#!/usr/bin/env python3
"""Scope's checks: its figures against hand-written answers, then its window on a private display.

Part one runs `scope --sample STAT1 STAT2 [STAT3 ...] MEMINFO HOSTNAME` on fixed input files and compares every
line it prints with an answer written here by hand: one-processor and 64-processor /proc/stat files, old and new
kernels' field counts, tabs, meminfo fields missing, reordered or malformed, files at the 1 MiB bound, and the edges
of the arithmetic (0 %, 100 %, half a percent and 99.5 % exactly, also past 2^56, a zero-length interval after a
figure, counters that did not move or went back one by one or all together, numbers at and past 2^64, tenths that
carry).

Part two opens the window on a private Xvfb display and drives it with XTest. With the real /proc it must draw this
machine's name, a processor figure, and memory figures that agree with /proc/meminfo read just before and just after
a frame that shows a new reading; it quits on Escape, q, Shift+Q and the window manager's close. With `--test` it
reads files this check writes: the redraw light must change at every reading while nothing else does, and the exact
text, inks and bar lengths are checked for known figures, a zero-length interval, MiB, names of 48 and 60 bytes, and
files that vanish ("unavailable") and come back. Last, for --seconds (default 120) it reads every 10 ms through links
this check turns between the real /proc, files without a final newline (MiB, a 60-byte name), missing files and
malformed files, and must stay the same size in memory.

Python, Xvfb, libX11 and libXtst are test tools only; Scope links none of them. Evidence (frames, input history,
outputs, memory samples) is kept in /tmp/herbert-hosted-apps-scope-*.
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
TITLE, SIZE = b'Herbert - Scope', (640, 370)

# Colours and places from examples/scope.herb (scope_draw, scope_row).
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
    env = dict(os.environ)
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


class Scope(App):
    """check_hosted_apps.App (input, frames, shutdown), started with Scope's own arguments, not a document path."""

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
    """Everything Scope writes, read back from one frame."""
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


def real_checks(args, x, display, evidence, passed):
    # The real /proc: the name, the labels, a processor figure with its bar, and the memory figures exactly as
    # /proc/meminfo gave them when Scope read it; then Escape.
    app = Scope(args.scope, [], x, display, evidence, 'scope-real')
    try:
        name = real_name()
        show_until(app, {'host': (name, {WHITE}), 'labels': LABELS}, 'name and labels', 10)
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
    finally:
        app.close()


def quit_checks(args, x, display, evidence, passed):
    for label, how in (('q', lambda app: app.tap('q')), ('shift-q', lambda app: app.tap('q', 'Shift_L')),
                       ('window-close', lambda app: x.delete(app.window))):
        app = Scope(args.scope, [], x, display, evidence, 'scope-' + label)
        try:
            show_until(app, {'host': (real_name(), {WHITE})}, label + ' window drawn', 10)
            how(app)
            app.finish()
            passed('scope-' + label + '-quits')
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
                  'scope-light')
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
                  'scope-files')
    try:
        show_until(app, {'host': ('test-host', {WHITE}), 'processor': ('-', {GREY}), 'processor-bar': 0,
                         'labels': LABELS, **TYPICAL_SHOWN}, 'first sample only: a dash')
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


def window_checks(args, x, display, evidence, passed):
    real_checks(args, x, display, evidence, passed)
    quit_checks(args, x, display, evidence, passed)
    light_checks(args, x, display, evidence, passed)
    files_checks(args, x, display, evidence, passed)


def io_counts(pid):
    fields = dict(line.split(': ') for line in Path(f'/proc/{pid}/io').read_text().splitlines())
    return int(fields['syscr']), int(fields['rchar'])


def memory_checks(args, x, display, evidence, passed):
    # Every 10 ms, about a hundred times the window's own rate, so that even a few bytes kept per frame add up to more
    # than the tolerance in the time given. Scope reads three links that this check turns, every 0.4 s, through
    # five states: the real /proc; files without a final newline (memory under 1 GiB, a 60-byte name); the next such
    # processor file (a figure from files); all three missing; all three malformed (unavailable). Each state's picture
    # is read back once per turn; every state must have been seen as it should look.
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
    interval = 10
    app = Scope(args.scope, ['--test', str(links / 'stat'), str(links / 'meminfo'), str(links / 'hostname'),
                                 str(interval)], x, display, evidence, 'scope-memory')
    try:
        show_until(app, {'host': (real_name(), {WHITE})}, 'memory run drawn', 10)
        seen = {name: [0, 0] for name, _, _ in states}
        samples, turns, started = [], 0, None
        while True:
            name, targets, check = states[turns % len(states)]
            point(targets)
            turned = time.monotonic()
            time.sleep(.15)
            frame = app.frame()
            reading = dict(shown(frame), frame=frame)
            seen[name][1] += 1
            if check(reading):
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
        point(proc)
        x.delete(app.window)
        app.finish()
        passed('scope-memory-flat', seconds=seconds, samples=len(samples), read_calls=reads,
               frames_at_least=frames_at_least, states_seen_as_they_should_look=seen,
               rss_kib_start=rss[0], rss_kib_end=rss[-1], rss_kib_min=min(rss), rss_kib_max=max(rss),
               rss_tolerance_kib=64, vm_size_kib=samples[0]['VmSize'], vm_size_must_not_change=True)
    finally:
        app.close()


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
