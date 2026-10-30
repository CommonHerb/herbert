#!/usr/bin/env python3
"""Check the allowlist scanner (tools/scan.herb) against hand-written answers.

Each case writes a tracked-files list and a BOOTSTRAP-ALLOWLIST into a fresh
directory, runs the scanner there and compares its exit status and stdout with
an answer written out below by hand, never computed by a model of the scanner.
A status of 2 must come with an empty stdout and a message on stderr; 0 and 1
with an empty stderr. `make check` passes the scanner it just built
(--scanner); without it, this script builds one from source with the committed
seed.
"""

from pathlib import Path
import argparse
import hashlib
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[2]
SOURCES = ('lib/linux.herb', 'tools/scan.herb')
OK = ' tracked non-.herb file(s) match BOOTSTRAP-ALLOWLIST\n'
MISSING = object()

# (label, tracked list, allowlist or MISSING, arguments, status, stdout)
CASES = [
    ('clean match', b'a.txt\nb/c.md\nx.herb\n', b'a.txt\nb/c.md\n', None,
     0, 'OK: 2' + OK),
    ('unlisted', b'a.txt\nnew.py\n', b'a.txt\n', None,
     1, 'unlisted: new.py\n'),
    ('stale', b'a.txt\n', b'a.txt\ngone.sh\n', None,
     1, 'stale: gone.sh\n'),
    ('unlisted and stale together, each group sorted', b'z.txt\nb.txt\nm.herb\nc.txt\n',
     b'y.txt\nb.txt\na.txt\n', None,
     1, 'unlisted: c.txt\nunlisted: z.txt\nstale: a.txt\nstale: y.txt\n'),
    ('byte order: punctuation, digits, case, prefixes', b'b\nB\na\nA\n_\n-\n/\n.\n0\n~\nab\naB\na\n', b'#\n', None,
     1, 'unlisted: -\nunlisted: .\nunlisted: /\nunlisted: 0\nunlisted: A\nunlisted: B\nunlisted: _\n'
        'unlisted: a\nunlisted: a\nunlisted: aB\nunlisted: ab\nunlisted: b\nunlisted: ~\n'),
    ('byte order: "-" and "." sort before "/" inside a path', b'dir/f\ndir.x/f\ndir-x/f\n', b'', None,
     1, 'unlisted: dir-x/f\nunlisted: dir.x/f\nunlisted: dir/f\n'),
    ('byte order: bytes above 127 sort last', 'été.md\nz.md\nZ.md\n'.encode(), b'', None,
     1, 'unlisted: Z.md\nunlisted: z.md\nunlisted: été.md\n'),
    ('stale paths sorted too', b'', b'q\nQ\n-q\n', None,
     1, 'stale: -q\nstale: Q\nstale: q\n'),
    ('CRLF lines on both sides', b'a.txt\r\nb.txt\r\n', b'a.txt\r\nb.txt\r\n', None,
     0, 'OK: 2' + OK),
    ('several trailing CRs are all stripped', b'c.txt\r\r\n', b'c.txt\r\r\r\n', None,
     0, 'OK: 1' + OK),
    ('a CR inside a path is kept', b'd\re.txt\n', b'', None,
     1, 'unlisted: d\re.txt\n'),
    ('blank and comment lines in the allowlist', b'a.txt\n\n\n',
     b'# comment\n\n   \n\t# indented comment\n#\na.txt\n', None,
     0, 'OK: 1' + OK),
    ('"#" inside or after text is part of a path', b'a#b\n', b'a#b\n', None,
     0, 'OK: 1' + OK),
    ('the tracked list has no comments', b'# not a comment\n', b'', None,
     1, 'unlisted: # not a comment\n'),
    ('allowlist whitespace is trimmed', b'a.txt\nb.txt\n', b'  a.txt  \n\tb.txt\t\r\n', None,
     0, 'OK: 2' + OK),
    ('tracked whitespace is kept', b' lead.txt\ntrail.txt \n', b' lead.txt\ntrail.txt \n', None,
     1, 'unlisted:  lead.txt\nunlisted: trail.txt \nstale: lead.txt\nstale: trail.txt\n'),
    ('a path tracked twice and listed once', b'a\na\n', b'a\n', None,
     1, 'unlisted: a\n'),
    ('a path listed twice and tracked once', b'a\n', b'a\na\n', None,
     1, 'stale: a\n'),
    ('a path tracked twice and listed twice', b'a\na\nb.herb\nb.herb\n', b'a\na\n', None,
     0, 'OK: 2' + OK),
    ('empty tracked list, empty allowlist', b'', b'', None,
     0, 'OK: 0' + OK),
    ('empty tracked list, listed path', b'', b'a\n', None,
     1, 'stale: a\n'),
    ('.herb files are never listed', b'x.herb\nsub/y.herb\n.herb\n', b'# nothing\n', None,
     0, 'OK: 0' + OK),
    ('a listed .herb file is stale', b'x.herb\n', b'x.herb\n', None,
     1, 'stale: x.herb\n'),
    ('paths that contain .herb without ending in it',
     b'x.herb.md\nx.herbx\nherb\nx.HERB\nx.herb/\nxherb\nx.her\nx.herb \n', b'', None,
     1, 'unlisted: herb\nunlisted: x.HERB\nunlisted: x.her\nunlisted: x.herb \nunlisted: x.herb.md\n'
        'unlisted: x.herb/\nunlisted: x.herbx\nunlisted: xherb\n'),
    ('no final newline', b'a.txt\nb.txt', b'a.txt\nb.txt', None,
     0, 'OK: 2' + OK),
    ('a NUL byte ends the line text', b'a.txt\x00junk\n', b'a.txt\x00\n', None,
     0, 'OK: 1' + OK),
    ('a path longer than 4095 bytes is one path', b'a' * 5000 + b'\n', b'a' * 5000 + b'\n', None,
     0, 'OK: 1' + OK),
    ('missing tracked-list file', MISSING, b'a\n', None,
     2, ''),
    ('tracked list is a directory', 'directory', b'a\n', None,
     2, ''),
    ('missing BOOTSTRAP-ALLOWLIST', b'a\n', MISSING, None,
     2, ''),
    ('BOOTSTRAP-ALLOWLIST is a directory', b'a\n', 'directory', None,
     2, ''),
    ('no argument', b'a\n', b'a\n', [],
     2, ''),
    ('two arguments', b'a\n', b'a\n', ['tracked.txt', 'tracked.txt'],
     2, ''),
    ('an empty argument', b'a\n', b'a\n', [''],
     2, ''),
]


def build(work):
    seed = ROOT/'bootstrap/seed/gen1.seed'
    seed_bytes = seed.read_bytes()
    pinned = (ROOT/'bootstrap/seed/gen1.seed.sha256').read_text().split()[0]
    if hashlib.sha256(seed_bytes).hexdigest() != pinned:
        raise SystemExit('FAIL: allowlist scanner: committed seed checksum mismatch')
    compiler = work/'compiler'
    compiler.write_bytes(seed_bytes)
    compiler.chmod(0o700)
    source = b''.join((ROOT/name).read_bytes() for name in SOURCES)
    compiled = subprocess.run([str(compiler)], input=source, cwd=work, capture_output=True, timeout=60)
    if (compiled.returncode, compiled.stdout, compiled.stderr) != (0, b'0\n', b''):
        raise SystemExit(f'FAIL: allowlist scanner did not compile: {compiled!r}')
    image = work/'a.out'
    image.chmod(0o700)
    return image


def place(path, content):
    if content == 'directory':
        path.mkdir()
    elif content is not MISSING:
        path.write_bytes(content)


def run_case(scanner, work, number, case):
    label, tracked, allow, args, status, stdout = case
    directory = work/f'case-{number:02d}'
    directory.mkdir()
    place(directory/'tracked.txt', tracked)
    place(directory/'BOOTSTRAP-ALLOWLIST', allow)
    argv = [str(scanner)] + (['tracked.txt'] if args is None else args)
    result = subprocess.run(argv, cwd=directory, capture_output=True, timeout=30)
    want = stdout.encode()
    problems = []
    if result.returncode != status:
        problems.append(f'status {result.returncode}, want {status}')
    if result.stdout != want:
        problems.append(f'stdout {result.stdout[:400]!r}, want {want[:400]!r}')
    if status == 2 and not result.stderr:
        problems.append('no message on stderr')
    if status != 2 and result.stderr:
        problems.append(f'unexpected stderr {result.stderr[:200]!r}')
    return [f'{label}: {problem}' for problem in problems]


def large_lists():
    # About 400 KB, larger than the scanner's first 64 KiB read: 20,000 distinct
    # paths (7919 and 20000 share no factor), listed in reverse except the first.
    names = [f'dir{i % 7}/file-{(i * 7919) % 20000:05d}.txt'.encode() for i in range(20000)]
    tracked = b'\n'.join(names) + b'\n'
    allow = b'\n'.join(reversed(names[1:])) + b'\n'
    return tracked, allow, b'unlisted: dir0/file-00000.txt\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--scanner', type=Path, help='scanner executable to check (default: build one)')
    args = parser.parse_args()
    failures = []
    with tempfile.TemporaryDirectory(prefix='herbert-scan-check-') as name:
        work = Path(name)
        scanner = args.scanner.resolve() if args.scanner else build(work)
        for number, case in enumerate(CASES):
            failures += run_case(scanner, work, number, case)
        tracked, allow, want = large_lists()
        directory = work/'large'
        directory.mkdir()
        (directory/'BOOTSTRAP-ALLOWLIST').write_bytes(allow)
        (directory/'tracked.txt').write_bytes(tracked)
        # The second run reads the list through a pipe, which can be read only once.
        for label, argv, stdin in (('large list from a file', ['tracked.txt'], b''),
                                   ('large list through a pipe', ['/dev/stdin'], tracked)):
            result = subprocess.run([str(scanner)] + argv, cwd=directory, input=stdin,
                                    capture_output=True, timeout=60)
            if (result.returncode, result.stdout, result.stderr) != (1, want, b''):
                failures.append(f'{label}: got status {result.returncode}, stdout {result.stdout[:200]!r}, '
                                f'stderr {result.stderr[:200]!r}')
    total = len(CASES) + 2
    if failures:
        for failure in failures:
            print(f'FAIL: allowlist scanner: {failure}')
        print(f'FAIL: allowlist scanner: {len(failures)} problem(s) in {total} cases')
        sys.exit(1)
    print(f'OK: allowlist scanner passed {total} cases with hand-written answers')


if __name__ == '__main__':
    main()
