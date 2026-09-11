#!/usr/bin/env python3
"""Compiler invocation contract: real artifacts, exact channels, atomic publication.

Default checks need only Linux/Python. --faults additionally requires strace,
GDB and GNU binutils and fails closed if unavailable. Tests never derive source
rejection expectations from the candidate. An explicit --compiler supports
baseline/mutant qualification; workspace mode verifies its seed checksum.
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
GOOD = b'func main():\n    return 42\nend\n'
OLD = b'previous complete artifact\x00\xff\n'
FAIL = b'compiler: output publication failed\n'


def need(ok, message):
    if not ok:
        raise ValueError(message)


def exact(result, status, stdout, stderr):
    need((result.returncode, result.stdout, result.stderr) == (status, stdout, stderr),
         f'expected {(status, stdout, stderr)!r}, got {(result.returncode, result.stdout, result.stderr)!r}')


def invoke(compiler, directory, source=GOOD, prefix=(), umask=-1):
    (directory / 'source.herb').write_bytes(source)
    result = subprocess.run([*prefix, str(compiler)], input=source, cwd=directory,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            timeout=30, umask=umask)
    (directory / 'stdout').write_bytes(result.stdout)
    (directory / 'stderr').write_bytes(result.stderr)
    (directory / 'status').write_text(str(result.returncode)+'\n')
    return result


def no_temporary(directory):
    need(not list(directory.glob('.herbert*.tmp')), 'temporary artifact leaked')


def preserved(directory):
    need((directory / 'a.out').read_bytes() == OLD, 'previous artifact changed')
    no_temporary(directory)


def run_cases(compiler, work, faults):
    rows = []
    def case(name, action):
        directory = work / name
        directory.mkdir()
        try:
            action(directory)
            rows.append({'case': name, 'passed': True})
            print('PASS: '+name, flush=True)
        except (ValueError, OSError, subprocess.SubprocessError) as error:
            rows.append({'case': name, 'passed': False, 'error': str(error)})
            print('FAIL: '+name+': '+str(error), flush=True)

    reference = work / 'reference'
    reference.mkdir()
    exact(invoke(compiler, reference), 0, b'0\n', b'')
    image = (reference / 'a.out').read_bytes()
    need(image[:4] == b'\x7fELF', 'successful compilation did not produce ELF')

    def succeeds(d):
        (d / 'a.out').write_bytes(OLD)
        exact(invoke(compiler, d), 0, b'0\n', b'')
        need((d / 'a.out').read_bytes() == image, 'successful artifact differs')
        no_temporary(d)
    case('replace-regular', succeeds)

    rejects = [
        ('lexical', b'func main():\n    return $\nend\n', b'line 2: unexpected character (ERR 101)\n'),
        ('structural', b'func main():\n    return 42\n', b'line 3: expected end (ERR 203)\n'),
        ('native', b'func main():\n    return unknown\nend\n', b"line 2: native-subset: forbidden construct 'undefined-name' (ERR 404)\n"),
    ]
    for name, source, diagnostic in rejects:
        def reject(d, source=source, diagnostic=diagnostic):
            (d / 'a.out').write_bytes(OLD)
            exact(invoke(compiler, d, source), 1, b'', diagnostic)
            preserved(d)
        case('reject-'+name, reject)

    def symlink(d):
        victim = d / 'victim'
        victim.write_bytes(OLD)
        (d / 'a.out').symlink_to(victim.name)
        exact(invoke(compiler, d), 0, b'0\n', b'')
        need(not (d / 'a.out').is_symlink(), 'output symlink was retained')
        need(victim.read_bytes() == OLD, 'symlink target was changed')
        need((d / 'a.out').read_bytes() == image, 'output differs')
        no_temporary(d)
    case('replace-symlink', symlink)

    def hardlink(d):
        (d / 'victim').write_bytes(OLD)
        os.link(d / 'victim', d / 'a.out')
        exact(invoke(compiler, d), 0, b'0\n', b'')
        need((d / 'victim').read_bytes() == OLD, 'hardlink target was changed')
        need((d / 'a.out').read_bytes() == image, 'output differs')
        no_temporary(d)
    case('replace-hardlink', hardlink)

    def directory_output(d):
        (d / 'a.out').mkdir()
        (d / 'a.out' / 'keep').write_bytes(OLD)
        exact(invoke(compiler, d), 1, b'', FAIL)
        need((d / 'a.out' / 'keep').read_bytes() == OLD, 'destination directory changed')
        no_temporary(d)
    case('directory-destination', directory_output)

    def mask(d):
        exact(invoke(compiler, d, umask=0o077), 0, b'0\n', b'')
        need((d / 'a.out').stat().st_mode & 0o777 == 0o600, 'umask ignored')
    case('umask-respected', mask)

    def empty_writer(d):
        source = b'func main():\n    do fwriter("")\n    return 0\nend\n'
        exact(invoke(compiler, d, source), 0, b'0\n', b'')
        writer = d / 'writer'
        (d / 'a.out').rename(writer)
        writer.chmod(0o700)
        exact(invoke(writer, d, b''), 0, b'0\n', b'')
        need((d / 'a.out').read_bytes() == b'', 'empty publication differs')
        no_temporary(d)
    case('empty-fwriter', empty_writer)

    def mid_program_writer(d):
        source = b'func preserve(seed):\n    let b = new_buffer()\n    do append(b, 65)\n    let xs = new_array(int)\n    do add(xs, seed)\n    do fwriter(freeze(b))\n    do append(b, 66)\n    do add(xs, seed + 1)\n    let c = new_buffer()\n    do append(c, 67)\n    return (freeze(b), get(xs, 0) + get(xs, 1), freeze(c))\nend\nfunc main():\n    return preserve(20)\nend\n'
        exact(invoke(compiler, d, source), 0, b'0\n', b'')
        writer = d / 'writer'
        (d / 'a.out').rename(writer)
        writer.chmod(0o700)
        exact(invoke(writer, d, b''), 0, b'("AB", 41, "C")\n', b'')
        need((d / 'a.out').read_bytes() == b'A', 'mid-program publication differs')
        no_temporary(d)
    case('mid-program-fwriter-preserves-state', mid_program_writer)

    def concurrent(d):
        other = work / 'other-reference'; other.mkdir()
        source2 = GOOD.replace(b'42', b'43')
        exact(invoke(compiler, other, source2), 0, b'0\n', b'')
        allowed = {OLD, image, (other / 'a.out').read_bytes()}
        (d / 'a.out').write_bytes(OLD)
        def compile_one(source):
            return subprocess.run([str(compiler)], input=source, cwd=d,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
        samples = 0
        with ThreadPoolExecutor(max_workers=8) as pool:
            futures = [pool.submit(compile_one, GOOD if i % 2 else source2) for i in range(32)]
            while not all(f.done() for f in futures):
                need((d / 'a.out').read_bytes() in allowed, 'observed partial/foreign artifact')
                samples += 1
                time.sleep(0.0005)
            for future in futures:
                exact(future.result(), 0, b'0\n', b'')
        need(samples > 0, 'concurrency observer made no observations')
        need((d / 'a.out').read_bytes() in allowed - {OLD}, 'no completed publication')
        no_temporary(d)
        (d / 'samples').write_text(str(samples)+'\n')
    case('concurrent-complete-publication', concurrent)

    if faults:
        for tool in ('strace', 'gdb', 'as', 'objcopy'):
            need(shutil.which(tool), 'required fault/layout tool missing: '+tool)
        injection_cases = [
            ('directory-open-error', 'openat:error=EACCES:when=1', False),
            ('temporary-open-error', 'openat:error=EACCES:when=2', False),
            ('random-error', 'getrandom:error=EIO:when=1', False),
            ('random-unavailable', 'getrandom:error=ENOSYS:when=1', False),
            ('random-zero-progress', 'getrandom:retval=0:when=1', False),
            ('write-error', 'write:error=ENOSPC:when=1', False),
            ('write-zero-progress', 'write:retval=0:when=1', False),
            ('fsync-error', 'fsync:error=EIO:when=1', False),
            ('close-error', 'close:error=EIO:when=1', False),
            ('close-eintr', 'close:error=EINTR:when=1', False),
            ('rename-error', 'renameat:error=EACCES:when=1', False),
            ('directory-open-eintr', 'openat:error=EINTR:when=1', True),
            ('temporary-open-eintr', 'openat:error=EINTR:when=2', True),
            ('temporary-collision', 'openat:error=EEXIST:when=2', True),
            ('random-eintr', 'getrandom:error=EINTR:when=1', True),
            ('write-eintr', 'write:error=EINTR:when=1', True),
            ('fsync-eintr', 'fsync:error=EINTR:when=1', True),
            ('rename-eintr', 'renameat:error=EINTR:when=1', True),
        ]
        for name, injection, success in injection_cases:
            def injected(d, injection=injection, success=success):
                (d / 'a.out').write_bytes(OLD)
                trace = d / 'strace'
                result = invoke(compiler, d, prefix=['strace', '-qq', '-o', str(trace), '-e', 'inject='+injection])
                trace_text = trace.read_text()
                need('(INJECTED)' in trace_text, 'fault injection did not execute')
                if success:
                    exact(result, 0, b'0\n', b'')
                    need((d / 'a.out').read_bytes() == image, 'retry changed artifact')
                    no_temporary(d)
                else:
                    exact(result, 1, b'', FAIL)
                    preserved(d)
                    if injection.startswith('close:'):
                        # Injected close is not executed by strace; compiler must
                        # not retry it. Process exit eventually releases the fd.
                        closes = re.findall(r'^close\((\d+)\)', trace_text, re.M)
                        need(len(closes) == len(set(closes)), 'close retried a consumed descriptor')
            case(name, injected)

        def partial(d):
            source = d / 'source.herb'; source.write_bytes(GOOD)
            commands = d / 'commands.gdb'
            commands.write_text('''set pagination off
set confirm off
set startup-with-shell on
set debuginfod enabled off
set disable-randomization off
set $hits = 0
catch syscall write
commands
silent
if $rax == -38 && $rdi > 2 && $rdx > 7
set $rdx = 7
set $hits = $hits + 1
end
continue
end
run < source.herb > stdout 2> stderr
printf "PARTIAL_HITS=%d\\n", $hits
''')
            result = subprocess.run(['gdb', '-q', '-nx', '-batch', '-x', str(commands), str(compiler)],
                                    cwd=d, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
            (d / 'gdb.stdout').write_bytes(result.stdout)
            (d / 'gdb.stderr').write_bytes(result.stderr)
            need(result.returncode == 0, 'GDB failed')
            hits = re.search(rb'PARTIAL_HITS=([0-9]+)', result.stdout)
            need(hits and int(hits[1]) > 1, 'actual partial write mechanism did not execute')
            need((d / 'stdout').read_bytes() == b'0\n' and (d / 'stderr').read_bytes() == b'', 'partial-write compile failed')
            need((d / 'a.out').read_bytes() == image, 'real partial writes changed artifact')
            no_temporary(d)
        case('real-partial-writes', partial)

        def assembly(d):
            asm = ROOT / 'bootstrap/tests/fixtures/fwriter_linux_x86_64.s'
            subprocess.run(['as', '--64', str(asm), '-o', str(d / 'writer.o')], check=True, timeout=10)
            subprocess.run(['objcopy', '-O', 'binary', '-j', '.text', str(d / 'writer.o'), str(d / 'writer.bin')], check=True, timeout=10)
            expected = (d / 'writer.bin').read_bytes()
            source = b'func main():\n    do fwriter("abc")\n    return 0\nend\n'
            exact(invoke(compiler, d, source), 0, b'0\n', b'')
            need((d / 'a.out').read_bytes().count(expected) == 1, 'emitted fwriter differs from instruction reference')
        case('instruction-reference', assembly)

    (work / 'results.json').write_text(json.dumps(rows, indent=2)+'\n')
    return all(row['passed'] for row in rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compiler', type=Path)
    parser.add_argument('--faults', action='store_true')
    parser.add_argument('--keep-work', action='store_true')
    args = parser.parse_args()
    work = Path(tempfile.mkdtemp(prefix='herbert-cli-contract.'))
    passed = False
    try:
        original = (args.compiler or ROOT / 'bootstrap/seed/gen1.seed').resolve()
        data = original.read_bytes()
        digest = hashlib.sha256(data).hexdigest()
        if args.compiler is None:
            need(original.with_suffix('.seed.sha256').read_text().split() == [digest, 'gen1.seed'], 'seed checksum mismatch')
        need(data[:4] == b'\x7fELF', 'compiler is not ELF')
        compiler = work / 'compiler'; compiler.write_bytes(data); compiler.chmod(0o700)
        print('compiler-cli-contract: sha256='+digest, flush=True)
        passed = run_cases(compiler, work, args.faults)
        return 0 if passed else 1
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print('FAIL: compiler-cli-contract setup: '+str(error), file=sys.stderr)
        return 1
    finally:
        if args.keep_work or not passed:
            print('compiler-cli-contract evidence: '+str(work), flush=True)
        else:
            shutil.rmtree(work)


if __name__ == '__main__':
    sys.exit(main())
