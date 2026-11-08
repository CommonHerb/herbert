#!/usr/bin/env python3
"""lib/text.herb's checks: the text toolkit, through a probe compiled from lib/linux.herb, lib/text.herb and a main of
this check's own, by the committed seed.

- The readers on spans of a buffer and of a string (text_whole, text_whole_strict, text_string_whole,
  text_string_whole_strict): every case against Python's own reading of the same bytes: digits only, zeros in front
  allowed or refused, the number at 2^64 - 1 and one past it, spans that start or stop inside a number, empty spans.
- text_digit and text_blank over all 256 bytes, text_fits at the edge of 2^64, text_skip and text_field (every field of
  a line against Python's split on spaces and tabs, a newline and a carriage return staying inside a field),
  text_starts and text_is.
- The writers into a fixed buffer (text_put, text_put_whole, text_put_padded, text_put_tenths): the bytes written, the
  bytes around them untouched, and the offset returned; tenths against exact fractions rounded half up, with the carry
  into the whole part; a write past the buffer's end stopping the program with lib/linux.herb's range message.
- The growing writers (text_add, text_add_span, text_add_whole, text_string).
- linux_argument_count, with empty arguments that linux_argument cannot tell from missing ones.
- That `and` and `or` stop once the answer is known (docs/LANGUAGE.md section 3): a probe that reads past a buffer's end
  unless they do.
- That the readers and fixed-buffer writers allocate nothing: 300,000 rounds of each leave the probe's peak resident
  size (VmHWM, read from /proc while it waits after the rounds) within 64 KiB of 1,000 rounds.

`--library PATH` puts another text.herb in the probe (a mutant, say). Evidence is kept in /tmp/herbert-text-*.
"""
import argparse
from fractions import Fraction
import hashlib
import json
from pathlib import Path
import re
import resource
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
MAX = 2**64 - 1
RANGE_MESSAGE = b'linux: byte-buffer range is outside its allocation\n'


def herb_string(data):
    """data as a Herbert string literal; only printable ASCII, tab, newline and carriage return are used here."""
    out = []
    for byte in data:
        if byte == 9:
            out.append('\\t')
        elif byte == 10:
            out.append('\\n')
        elif byte == 13:
            out.append('\\r')
        elif byte == 34:
            out.append('\\"')
        elif byte == 92:
            out.append('\\\\')
        else:
            assert 32 <= byte <= 126, byte
            out.append(chr(byte))
    return '"' + ''.join(out) + '"'


PROBE_FUNCTIONS = r'''
func probe_put(out, s):
    let i = 0
    while i < length(s):
        do append(out, index(s, i))
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

func probe_bool(out, v):
    if v: return probe_put(out, "true") end
    return probe_put(out, "false")
end

func probe_bytes(out, b, from, stop):
    while from < stop:
        do append(out, buffer_get(b, from))
        from = from + 1
    end
    return 0
end

func probe_buffer(s):
    let b = linux_buffer(length(s))
    do linux_text(b, 0, s)
    return b
end

-- kind 0 text_whole, 1 text_whole_strict, 2 text_string_whole, 3 text_string_whole_strict.
func probe_reader(out, kind, s, at, stop):
    let b = probe_buffer(s)
    let r = text_whole(b, at, stop)
    if kind == 1: r = text_whole_strict(b, at, stop) end
    if kind == 2: r = text_string_whole(s, at, stop) end
    if kind == 3: r = text_string_whole_strict(s, at, stop) end
    if not r.0: return probe_put(out, "no\n") end
    do probe_put(out, "ok ")
    do probe_number(out, r.1)
    do probe_put(out, " ")
    do probe_number(out, r.2)
    return probe_put(out, "\n")
end

func probe_bytes_where(out, blank):
    let i = 0
    while i < 256:
        let yes = text_digit(i)
        if blank: yes = text_blank(i) end
        if yes:
            do probe_number(out, i)
            do probe_put(out, " ")
        end
        i = i + 1
    end
    return probe_put(out, "\n")
end

func probe_fits(out, value, d):
    do probe_bool(out, text_fits(value, d))
    return probe_put(out, "\n")
end

-- Every field from at before stop, each as "start after [bytes]", then the skip from at.
func probe_fields(out, s, at, stop):
    let b = probe_buffer(s)
    do probe_put(out, "skip ")
    do probe_number(out, text_skip(b, at, stop))
    let f = text_field(b, at, stop)
    while f.0 < stop:
        do probe_put(out, " | ")
        do probe_number(out, f.0)
        do probe_put(out, " ")
        do probe_number(out, f.1)
        do probe_put(out, " [")
        do probe_bytes(out, b, f.0, f.1)
        do probe_put(out, "]")
        f = text_field(b, f.1, stop)
    end
    do probe_put(out, " | end ")
    do probe_number(out, f.0)
    do probe_put(out, " ")
    do probe_number(out, f.1)
    return probe_put(out, "\n")
end

func probe_compare(out, s, at, stop, word):
    let b = probe_buffer(s)
    do probe_bool(out, text_starts(b, at, stop, word))
    do probe_put(out, " ")
    do probe_bool(out, text_is(b, at, stop, word))
    return probe_put(out, "\n")
end

-- A buffer of size dots, written at at: kind 0 text_put_whole(n), 1 text_put_padded(n, arg), 2 text_put_tenths(n,
-- arg), 3 text_put(word). The offset returned, then the whole buffer.
func probe_write(out, kind, size, at, n, arg, word):
    let b = new_buffer()
    do buffer_fill(b, size, 46)
    let next = 0
    if kind == 0: next = text_put_whole(b, at, n) end
    if kind == 1: next = text_put_padded(b, at, n, arg) end
    if kind == 2: next = text_put_tenths(b, at, n, arg) end
    if kind == 3: next = text_put(b, at, word) end
    do probe_number(out, next)
    do probe_put(out, " [")
    do probe_bytes(out, b, 0, size)
    return probe_put(out, "]\n")
end

func probe_adds(out):
    let grown = new_buffer()
    do text_add(grown, "one ")
    do text_add(grown, "")
    do text_add_whole(grown, 0)
    do text_add(grown, " ")
    do text_add_whole(grown, 18446744073709551615)
    do text_add(grown, " ")
    let b = probe_buffer("abcdef")
    do text_add_span(grown, b, 2, 3)
    do text_add_span(grown, b, 6, 0)
    let s = text_string(b, 1, 4)
    do text_add(grown, " ")
    do text_add(grown, s)
    do text_add(grown, " ")
    do probe_number(grown, length(s))
    do text_add(grown, " ")
    do probe_number(grown, length(text_string(b, 3, 3)))
    do text_add(grown, " ")
    do text_add_whole(grown, 10)
    do text_add(grown, " ")
    do text_add_whole(grown, 100)
    do text_add(grown, " ")
    do text_add_whole(grown, 9)
    do probe_bytes(out, grown, 0, buffer_length(grown))
    return probe_put(out, "\n")
end

-- and / or: the right side reads past the end of a one-byte buffer, so it must not be looked at.
func probe_short(out):
    let b = linux_buffer(1)
    let i = 1
    let n = 1
    let both = i < n and buffer_get(b, i) == 0
    let either = i >= n or buffer_get(b, i) == 0
    do probe_bool(out, both)
    do probe_put(out, " ")
    do probe_bool(out, either)
    return probe_put(out, "\n")
end

-- rounds of every reader and fixed-buffer writer on fixed buffers: what they found, added up.
func probe_loop(rounds):
    let s = "  12345 678\t0 18446744073709551615"
    let b = linux_buffer(96)
    do linux_text(b, 0, s)
    let total = 0
    let i = 0
    while i < rounds:
        let w = text_whole(b, 2, 7)
        let ws = text_whole_strict(b, 8, 11)
        let sw = text_string_whole(s, 14, length(s))
        let sws = text_string_whole_strict(s, 12, 13)
        let f = text_field(b, 7, length(s))
        let k = text_skip(b, 11, length(s))
        let found = 0
        if text_starts(b, 2, length(s), "123") and text_is(b, 8, 11, "678"): found = 1 end
        if text_digit(i % 256) or text_blank(i % 256) or text_fits(i, 5): found = found + 1 end
        let at = text_put(b, 40, "x")
        at = text_put_whole(b, at, i)
        at = text_put_padded(b, 60, i % 1000, 4)
        at = text_put_tenths(b, 70, i, 1024)
        total = total + w.1 + ws.1 + sw.2 + sws.2 + f.1 + k + found + at
        i = i + 1
    end
    return total
end

-- A write that does not fit: kind 0 text_put, 1 text_put_whole, 2 text_put_padded, 3 text_put_tenths.
func probe_overrun(kind):
    let b = linux_buffer(3)
    if kind == 0: do text_put(b, 1, "abc") end
    if kind == 1: do text_put_whole(b, 1, 123) end
    if kind == 2: do text_put_padded(b, 0, 5, 4) end
    if kind == 3: do text_put_tenths(b, 1, 1024, 1024) end
    return 0
end

func probe_argument(args, k):
    let s = linux_argument(args, k)
    return length(s)
end
'''

PROBE_MAIN = r'''
func main():
    let args = linux_arguments()
    let total = linux_argument_count(args)
    let mode = linux_argument(args, 1)
    let out = new_buffer()
    if equal(mode, "cases"):
        do probe_cases(out)
        do flogger(freeze(out))
        do process_exit(0)
        return 0
    end
    if equal(mode, "count"):
        do probe_number(out, total)
        let k = 0
        while k <= total:
            do probe_put(out, " ")
            do probe_number(out, probe_argument(args, k))
            k = k + 1
        end
        do probe_put(out, "\n")
        do flogger(freeze(out))
        do process_exit(0)
        return 0
    end
    let n = text_string_whole_strict(linux_argument(args, 2), 0, length(linux_argument(args, 2)))
    if equal(mode, "loop") and n.0:
        do probe_number(out, probe_loop(n.1))
        do probe_put(out, "\n")
        do flogger(freeze(out))
        -- Wait for a byte on standard input, so the check can read this process's peak size.
        let one = linux_buffer(1)
        do linux_read(0, one, 0, 1)
        do process_exit(0)
        return 0
    end
    if equal(mode, "overrun") and n.0:
        do probe_overrun(n.1)
        do flogger("returned\n")
        do process_exit(0)
        return 0
    end
    return linux_die("probe: usage\n")
end
'''


# --- Python's own answers -------------------------------------------------------------------------------------------

def ref_whole(data, at, stop, strict):
    i = at
    while i < stop and 48 <= data[i] <= 57:
        i += 1
    if i == at:
        return 'no'
    value = int(data[at:i])
    if value > MAX:
        return 'no'
    if strict and i - at > 1 and data[at] == 48:
        return 'no'
    return f'ok {value} {i}'


def ref_fields(data, at, stop):
    span = data[at:stop]
    parts = []
    for m in re.finditer(rb'[^ \t]+', span):
        parts.append(f' | {at + m.start()} {at + m.end()} [' .encode() + m.group() + b']')
    skip = at + (len(span) - len(span.lstrip(b' \t')))
    return b'skip ' + str(skip).encode() + b''.join(parts) + f' | end {stop} {stop}\n'.encode()


def ref_compare(data, at, stop, word):
    starts = at <= stop and data[at:stop].startswith(word)
    exact = at <= stop and data[at:stop] == word
    return f'{str(starts).lower()} {str(exact).lower()}\n'


def ref_tenths(n, unit):
    tenths = (Fraction(n, unit) * 10 + Fraction(1, 2)).__floor__()
    return f'{tenths // 10}.{tenths % 10}'.encode()


def ref_write(kind, size, at, n, arg, word):
    if kind == 0:
        text = str(n).encode()
    elif kind == 1:
        text = str(n).encode().rjust(arg, b'0')
    elif kind == 2:
        text = ref_tenths(n, arg)
    else:
        text = word
    assert at + len(text) <= size
    buffer = b'.' * at + text + b'.' * (size - at - len(text))
    return str(at + len(text)).encode() + b' [' + buffer + b']\n'


READER_TEXTS = [
    (b'0', 0, 1), (b'7', 0, 1), (b'007', 0, 3), (b'00', 0, 2), (b'01', 0, 2), (b'10', 0, 2), (b'100', 0, 3),
    (b'123', 0, 3), (b'12a', 0, 3), (b'0a', 0, 2), (b'', 0, 0), (b'a1', 0, 2), (b' 1', 0, 2), (b'-1', 0, 2),
    (b'+1', 0, 2), (b'/', 0, 1), (b':', 0, 1), (b'9:', 0, 2), (b'/0', 0, 2),
    (b'18446744073709551615', 0, 20), (b'18446744073709551616', 0, 20), (b'18446744073709551620', 0, 20),
    (b'18446744073709551609', 0, 20), (b'99999999999999999999', 0, 20), (b'184467440737095516150', 0, 21),
    (b'0000000000000000000018446744073709551615', 0, 40), (b'1844674407370955161', 0, 19),
    (b'12345', 1, 3), (b'12345', 2, 2), (b'12345', 4, 5), (b'12345', 5, 5), (b'12345', 3, 2), (b'x42y', 1, 4),
    (b'x042y', 1, 5), (b'x042y', 2, 5), (b'1 2', 0, 3), (b'5\n', 0, 2), (b'65535', 0, 4),
    (b'herbert-scope 1 10000 1500', 16, 26), (b'herbert-scope 1 10000 1500', 22, 26),
]

FIELD_TEXTS = [
    (b'  ab\tc  ', 0, 8), (b'', 0, 0), (b'   ', 0, 3), (b'\t\tx', 0, 3), (b'a b', 0, 3), (b'ab', 0, 2),
    (b'home 127.0.0.1 22', 0, 17), (b'home 127.0.0.1 22', 5, 14), (b'a\nb c', 0, 5), (b'a\r b', 0, 4),
    (b' x  y ', 1, 4), (b'one two', 3, 3), (b'name\t\t10.0.0.1 \t 8 # no', 0, 23),
]

COMPARE_CASES = [
    (b'herbert-scope 1 10', 0, 18, b'herbert-scope 1 '), (b'herbert-scope 1 ', 0, 16, b'herbert-scope 1 '),
    (b'herbert-scope 1 ', 0, 15, b'herbert-scope 1 '), (b'herbert-scope 2 ', 0, 16, b'herbert-scope 1 '),
    (b'nvme', 0, 4, b'nvme'), (b'nvme0', 0, 5, b'nvme'), (b'nvm', 0, 3, b'nvme'), (b'xnvme', 1, 5, b'nvme'),
    (b'abc', 2, 1, b''), (b'abc', 1, 1, b''), (b'abc', 0, 3, b''), (b'unavailable', 0, 11, b'unavailable'),
    (b'unavailablE', 0, 11, b'unavailable'), (b'Unavailable', 0, 11, b'unavailable'),
]

FITS_CASES = [(0, 9), (1844674407370955160, 9), (1844674407370955161, 5), (1844674407370955161, 6),
              (1844674407370955162, 0), (MAX, 0), (184467440737095516, 9)]

WRITE_CASES = [
    (0, 4, 0, 0, 0, b''), (0, 4, 1, 9, 0, b''), (0, 5, 1, 10, 0, b''), (0, 22, 1, MAX, 0, b''),
    (0, 3, 0, 123, 0, b''),
    (1, 4, 1, 7, 2, b''), (1, 4, 1, 7, 1, b''), (1, 4, 1, 7, 0, b''), (1, 5, 1, 123, 2, b''), (1, 5, 1, 0, 3, b''),
    (1, 3, 1, 0, 0, b''), (1, 23, 1, MAX, 22, b''), (1, 7, 1, 42, 5, b''), (1, 22, 1, 1, 20, b''),
    (1, 6, 1, 1234, 4, b''), (1, 5, 0, 12345, 5, b''),
    (2, 6, 1, 0, 1024, b''), (2, 6, 1, 512, 1024, b''), (2, 6, 1, 51, 1024, b''), (2, 6, 1, 52, 1024, b''),
    (2, 6, 1, 972, 1024, b''), (2, 6, 1, 973, 1024, b''), (2, 6, 1, 1023, 1024, b''), (2, 6, 1, 1024, 1024, b''),
    (2, 6, 1, 1, 2, b''), (2, 6, 1, 1, 20, b''), (2, 6, 1, 1, 21, b''), (2, 6, 1, 3, 7, b''),
    (2, 8, 1, 10239, 1024, b''), (2, 8, 1, 10188, 1024, b''), (2, 9, 1, 433836032, 1048576, b''),
    (2, 25, 1, MAX, 1, b''), (2, 6, 1, MAX, 2**60, b''), (2, 25, 1, MAX, 1024, b''), (2, 6, 1, 7, 1, b''),
    (3, 6, 1, 0, 0, b'abc'), (3, 3, 0, 0, 0, b'abc'), (3, 3, 3, 0, 0, b''), (3, 4, 2, 0, 0, b'\t\n'),
]


def build_cases():
    """The probe's case calls, and the bytes they must print."""
    calls, expected = [], []
    for data, at, stop in READER_TEXTS:
        for kind in range(4):
            calls.append(f'    do probe_reader(out, {kind}, {herb_string(data)}, {at}, {stop})')
            expected.append((ref_whole(data, at, stop, kind in (1, 3)) + '\n').encode())
    for blank in ('false', 'true'):
        calls.append(f'    do probe_bytes_where(out, {blank})')
        wanted = [9, 32] if blank == 'true' else list(range(48, 58))
        expected.append(b''.join(b'%d ' % i for i in wanted) + b'\n')
    for value, d in FITS_CASES:
        calls.append(f'    do probe_fits(out, {value}, {d})')
        expected.append(b'true\n' if value * 10 + d <= MAX else b'false\n')
    for data, at, stop in FIELD_TEXTS:
        calls.append(f'    do probe_fields(out, {herb_string(data)}, {at}, {stop})')
        expected.append(ref_fields(data, at, stop))
    for data, at, stop, word in COMPARE_CASES:
        calls.append(f'    do probe_compare(out, {herb_string(data)}, {at}, {stop}, {herb_string(word)})')
        expected.append(ref_compare(data, at, stop, word).encode())
    for kind, size, at, n, arg, word in WRITE_CASES:
        calls.append(f'    do probe_write(out, {kind}, {size}, {at}, {n}, {arg}, {herb_string(word)})')
        expected.append(ref_write(kind, size, at, n, arg, word))
    calls.append('    do probe_adds(out)')
    expected.append(b'one 0 %d cde bcd 3 0 10 100 9\n' % MAX)
    calls.append('    do probe_short(out)')
    expected.append(b'false true\n')
    source = 'func probe_cases(out):\n' + '\n'.join(calls) + '\n    return 0\nend\n'
    return source, b''.join(expected), len(calls)


def compile_probe(work, library, cases_source):
    seed = ROOT / 'bootstrap/seed/gen1.seed'
    expected = (ROOT / 'bootstrap/seed/gen1.seed.sha256').read_text().split()[0]
    assert hashlib.sha256(seed.read_bytes()).hexdigest() == expected, 'committed seed hash mismatch'
    units = [ROOT / 'lib/linux.herb', library]
    source = (b''.join(unit.read_bytes() + b'\n' for unit in units) + PROBE_FUNCTIONS.encode() +
              cases_source.encode() + PROBE_MAIN.encode())
    (work / 'source.herb').write_bytes(source)
    compiler = work / 'compiler'
    shutil.copyfile(seed, compiler)
    compiler.chmod(0o755)
    compiled = subprocess.run([str(compiler)], input=source, cwd=work, capture_output=True, timeout=120,
                              preexec_fn=lambda: resource.setrlimit(resource.RLIMIT_CORE, (0, 0)))
    assert compiled.returncode == 0 and compiled.stdout == b'0\n' and not compiled.stderr, (
        'the probe did not compile', compiled.returncode, compiled.stdout, compiled.stderr[:2000])
    compiler.unlink()
    image = work / 'a.out'
    image.chmod(0o755)
    return image


def run(image, args, work, name):
    """The probe with args: (status, stdout, stderr)."""
    result = subprocess.run([str(image), *args], stdin=subprocess.DEVNULL, capture_output=True, cwd=work, timeout=60,
                            preexec_fn=lambda: resource.setrlimit(resource.RLIMIT_CORE, (0, 0)))
    (work / f'{name}.stdout').write_bytes(result.stdout)
    (work / f'{name}.stderr').write_bytes(result.stderr)
    return result.returncode, result.stdout, result.stderr


def peak(image, rounds, work):
    """The probe's loop of rounds: (total printed, its own peak resident size VmHWM in KiB, read from /proc while it
    waits after the loop, status)."""
    proc = subprocess.Popen([str(image), 'loop', str(rounds)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, cwd=work,
                            preexec_fn=lambda: resource.setrlimit(resource.RLIMIT_CORE, (0, 0)))
    try:
        line = proc.stdout.readline()
        status = Path(f'/proc/{proc.pid}/status').read_text()
        (work / f'loop-{rounds}.status').write_text(status)
        hwm = int(re.search(r'^VmHWM:\s+(\d+) kB$', status, re.M).group(1))
        proc.stdin.write(b'x')
        proc.stdin.close()
        err = proc.stderr.read()
        proc.wait(timeout=60)
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()
    assert proc.returncode == 0 and err == b'' and line.strip().isdigit(), ('loop', rounds, proc.returncode, line, err)
    return int(line), hwm


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', type=Path, help='the text.herb the probe uses (default lib/text.herb)')
    parser.add_argument('--evidence', type=Path)
    args = parser.parse_args()
    library = (args.library or ROOT / 'lib/text.herb').resolve()
    work = (args.evidence or Path(tempfile.mkdtemp(prefix='herbert-text-'))).resolve()
    work.mkdir(parents=True, exist_ok=True)
    print(f'text checks: {library}; evidence: {work}', flush=True)
    results = []

    def passed(name, **facts):
        results.append({'check': name, **facts})
        (work / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        print(f'PASS {name}', flush=True)

    cases_source, expected, calls = build_cases()
    image = compile_probe(work, library, cases_source)
    status, out, err = run(image, ['cases'], work, 'cases')
    (work / 'cases.expected').write_bytes(expected)
    if (status, err) != (0, b'') or out != expected:
        got, want = out.splitlines(), expected.splitlines()
        first = next((i for i in range(min(len(got), len(want))) if got[i] != want[i]), min(len(got), len(want)))
        raise AssertionError(('cases differ', status, err[:500], first,
                              got[first] if first < len(got) else None, want[first] if first < len(want) else None))
    passed('text-readers-writers-and-short-circuit', calls=calls, readers=len(READER_TEXTS) * 4,
           fields=len(FIELD_TEXTS), comparisons=len(COMPARE_CASES), writes=len(WRITE_CASES))

    for argv in (['count'], ['count', '', 'x', ''], ['count', 'a b', '', '', '7']):
        status, out, err = run(image, argv, work, 'count')
        everything = ['probe', *argv]
        want = (str(len(everything)) + ''.join(' ' + str(len(a.encode())) for a in [str(image)] + argv) +
                ' 0\n').encode()
        assert (status, out, err) == (0, want, b''), ('linux_argument_count', argv, status, out, err, want)
    passed('linux-argument-count', runs=3, empty_arguments_counted=True)

    for kind in range(4):
        status, out, err = run(image, ['overrun', str(kind)], work, f'overrun-{kind}')
        assert (status, out, err) == (1, b'', RANGE_MESSAGE), ('a write past the end', kind, status, out, err)
    passed('text-writes-past-the-end-stop', kinds=4, message=RANGE_MESSAGE.decode().strip())

    sizes = {}
    for rounds in (1000, 300000):
        _, sizes[rounds] = peak(image, rounds, work)
    assert sizes[300000] - sizes[1000] <= 64, ('the readers or writers allocate', sizes)
    passed('text-allocates-nothing', rounds=[1000, 300000], peak_resident_kib=sizes)
    print(f'text: {len(results)} checks passed', flush=True)


if __name__ == '__main__':
    try:
        main()
    except AssertionError as error:
        print(f'FAIL text: {error!r}', file=sys.stderr, flush=True)
        sys.exit(1)
