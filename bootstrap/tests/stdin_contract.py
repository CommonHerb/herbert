#!/usr/bin/env python3
"""Dependency-free Linux real-fd stdin contract, through the ordinary seed.

Checks emitted stdin_read and compiler-main adoption, independently of ptrace,
GDB, strace, and historical gate membership. Compiler EOF uses valid source;
reader EOF uses an empty pipe. Every failed-input artifact state must survive.
Injected after-prefix/EINTR/capacity-probe cases remain separate manual evidence.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SPEC = Path(__file__).with_name('fixtures') / 'stdin_contract.json'
SEED = ROOT / 'bootstrap/seed/gen1.seed'


def need(condition, message):
    if not condition:
        raise ValueError(message)


def exact(result, status, stdout, stderr):
    need(result.returncode == status, f'status expected {status}, got {result.returncode}')
    need(result.stdout == stdout, f'stdout expected {stdout!r}, got {result.stdout!r}')
    need(result.stderr == stderr, f'stderr expected {stderr!r}, got {result.stderr!r}')


def same_artifacts(before, after):
    need(before == after, 'failed input changed artifact/link state')


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        need(key not in result, f'duplicate JSON key: {key}')
        result[key] = value
    return result


def read_spec(text):
    spec = json.loads(text, object_pairs_hook=unique_object)
    validate_spec(spec)
    return spec


def validate_spec(spec):
    """Fail closed on malformed or incomplete declarations, without executing code."""
    strings = ('scope', 'provenance', 'reader_source', 'valid_source',
               'compiler_eof_control', 'artifact_contract')
    fixed = {'version': 1, 'compile_status': 0, 'compile_stdout': '0\n',
             'compile_stderr': '', 'valid_program_status': 0,
             'valid_program_stdout': '42\n', 'valid_program_stderr': '',
             'reader_status': 0, 'reader_stderr': '', 'compiler_error_status': 1,
             'compiler_error_stdout': '',
             'compiler_error_stderr_template': 'compiler: stdin read failed (errno {errno})\n'}
    need(type(spec) is dict, 'spec must be an object')
    need(set(spec) == set(strings) | set(fixed) |
         {'reader_cases', 'compiler_error_cases', 'artifact_states'}, 'unknown or missing spec field')
    for key in strings:
        need(type(spec[key]) is str and bool(spec[key]), f'{key} must be a nonempty string')
    for key, value in fixed.items():
        need(type(spec[key]) is type(value) and spec[key] == value, f'invalid {key}')
    matrix = [('closed-fd0', 'closed', 9), ('directory-fd0', 'directory', 21),
              ('held-open-empty-pipe', 'pipe-open', 11),
              ('closed-writer-empty-pipe-eof', 'pipe-eof', 0)]
    for key, expected in (('reader_cases', matrix), ('compiler_error_cases', matrix[:3])):
        rows = spec[key]
        need(type(rows) is list, f'{key} must be a list')
        ids, observed = set(), []
        for row in rows:
            fields = {'id', 'method', 'errno'} | ({'stdout'} if key == 'reader_cases' else set())
            need(type(row) is dict and set(row) == fields, f'invalid {key} row fields')
            need(type(row['id']) is str and type(row['method']) is str and
                 type(row['errno']) is int, f'invalid {key} row types')
            need(row['id'] not in ids, f'duplicate {key} case id: {row["id"]}')
            ids.add(row['id'])
            observed.append((row['id'], row['method'], row['errno']))
            if key == 'reader_cases':
                need(type(row['stdout']) is str and row['stdout'] == f'{row["errno"]}\n',
                     'reader stdout must render declared errno exactly')
        need(len(observed) == len(expected) and set(observed) == set(expected),
             f'incomplete or altered {key} method/errno matrix')
    need(spec['artifact_states'] == ['absent', 'regular', 'symlink'], 'incomplete artifact matrix')


def self_test(spec):
    """Portable synthetic oracle/schema checks, not native implementation evidence."""
    rejected = []

    def bites(label, action):
        try:
            action()
        except ValueError:
            rejected.append(label)
            return
        raise ValueError(f'self-test accepted negative control: {label}')

    validate_spec(spec)
    exact(subprocess.CompletedProcess([], 0, b'0\n', b''), 0, b'0\n', b'')
    state = {'a.out': {'sha256': 'sentinel', 'ino': 7, 'nlink': 2},
             'prior.elf': None, 'held-hardlink': {'link': 'prior.elf'}}
    same_artifacts(state, state.copy())
    for label, result in (
            ('wrong-status', subprocess.CompletedProcess([], 1, b'0\n', b'')),
            ('wrong-stdout', subprocess.CompletedProcess([], 0, b'wrong', b'')),
            ('wrong-stderr', subprocess.CompletedProcess([], 0, b'0\n', b'wrong'))):
        bites(label, lambda result=result: exact(result, 0, b'0\n', b''))
    for field, changed in (('sha256', 'changed'), ('ino', 8), ('nlink', 1)):
        altered = json.loads(json.dumps(state))
        altered['a.out'][field] = changed
        bites('changed-artifact-' + field, lambda altered=altered: same_artifacts(state, altered))
    altered = json.loads(json.dumps(state))
    altered['held-hardlink']['link'] = 'changed'
    bites('changed-link-target', lambda: same_artifacts(state, altered))
    top_duplicate = json.dumps(spec).replace('"version": 1', '"version": 1, "version": 1', 1)
    bites('duplicate-json-key', lambda: read_spec(top_duplicate))
    nested_duplicate = json.dumps(spec).replace('"method": "closed"',
                                               '"method": "closed", "method": "closed"', 1)
    bites('nested-duplicate-json-key', lambda: read_spec(nested_duplicate))
    for key in ('reader_cases', 'compiler_error_cases'):
        for fault in ('duplicate-id', 'duplicate-method', 'missing-method', 'wrong-errno'):
            altered = json.loads(json.dumps(spec))
            rows = altered[key]
            if fault == 'duplicate-id':
                rows[1]['id'] = rows[0]['id']
            elif fault == 'duplicate-method':
                rows[1]['method'] = rows[0]['method']
            elif fault == 'missing-method':
                rows.pop()
            else:
                rows[0]['errno'] = 21
                if key == 'reader_cases':
                    rows[0]['stdout'] = '21\n'
            bites(key + '-' + fault, lambda altered=altered: validate_spec(altered))
    altered = json.loads(json.dumps(spec))
    altered['reader_cases'][-1].update(errno=11, stdout='11\n')
    bites('eof-is-not-eagain', lambda: validate_spec(altered))
    altered = json.loads(json.dumps(spec))
    altered['compile_status'] = False
    bites('boolean-is-not-status', lambda: validate_spec(altered))
    altered = json.loads(json.dumps(spec))
    altered['unexpected'] = 1
    bites('unknown-spec-field', lambda: validate_spec(altered))
    need(len(rejected) == 20, 'incomplete self-test negative-control ledger')
    print(f'stdin-contract self-test: 3 positive controls; {len(rejected)} negative controls rejected')
    for label in rejected:
        print('REJECTED: ' + label)


def elf(path):
    need(path.is_file() and not path.is_symlink(), f'missing regular ELF: {path}')
    data = path.read_bytes()
    need(len(data) >= 20 and data[:6] == b'\x7fELF\x02\x01' and data[18:20] == b'\x3e\x00',
         'not an x86-64 little-endian ELF')
    return data


def invoke(binary, directory, method, payload, timeout):
    """Construct real descriptors. The parent holds the EAGAIN writer alive."""
    need(method in ('closed', 'directory', 'pipe-open', 'pipe-eof'), 'unknown fd method')
    held = []
    setup = {'method': method}
    try:
        if method == 'closed':
            fd = subprocess.DEVNULL
            need(not payload, 'closed fd cannot carry payload')
            setup['child_fd0_closed_before_exec'] = True
        elif method == 'directory':
            fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
            held.append(fd)
            need(stat.S_ISDIR(os.fstat(fd).st_mode), 'stdin fd is not a directory')
            need(not payload, 'directory fd cannot carry payload')
            setup['directory_fstat'] = True
        else:
            fd, writer = os.pipe()
            held.extend((fd, writer))
            os.set_blocking(fd, False)
            need(not os.get_blocking(fd), 'stdin pipe is blocking')
            need(stat.S_ISFIFO(os.fstat(fd).st_mode), 'stdin fd is not a pipe')
            setup.update(nonblocking=True, pipe_fstat=True, payload_bytes=len(payload))
            if method == 'pipe-open':
                need(not payload, 'held-open error pipe must be empty')
                setup['writer_held_until_child_exit'] = True
            else:
                need(len(payload) <= 4096, 'EOF control exceeds conservative PIPE_BUF')
                if payload:
                    need(os.write(writer, payload) == len(payload), 'short control pipe write')
                os.close(writer)
                held.remove(writer)
                setup['writer_closed_before_launch'] = True
        (directory / 'descriptor.json').write_text(json.dumps(setup, indent=2) + '\n')

        def child_setup():
            import resource
            resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
            if method == 'closed':
                os.close(0)

        child = subprocess.Popen([str(binary)], cwd=directory, stdin=fd,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 preexec_fn=child_setup, start_new_session=True)
        try:
            out, err = child.communicate(timeout=timeout)
        except subprocess.TimeoutExpired as error:
            os.killpg(child.pid, signal.SIGKILL)
            out, err = child.communicate()
            (directory / 'stdout').write_bytes(out)
            (directory / 'stderr').write_bytes(err)
            (directory / 'status').write_text('TIMEOUT\n')
            raise ValueError(f'process timed out after {timeout:g}s') from error
        result = subprocess.CompletedProcess([str(binary)], child.returncode, out, err)
        (directory / 'stdout').write_bytes(out)
        (directory / 'stderr').write_bytes(err)
        (directory / 'status').write_text(f'{child.returncode}\n')
        return result
    finally:
        for fd in held:
            os.close(fd)


def artifact_state(directory, kind, sentinel):
    if kind == 'regular':
        shutil.copyfile(sentinel, directory / 'a.out')
        (directory / 'a.out').chmod(0o700)
        os.link(directory / 'a.out', directory / 'held-hardlink')
    elif kind == 'symlink':
        shutil.copyfile(sentinel, directory / 'prior.elf')
        (directory / 'prior.elf').chmod(0o700)
        os.link(directory / 'prior.elf', directory / 'held-hardlink')
        (directory / 'a.out').symlink_to('prior.elf')
    else:
        need(kind == 'absent', 'unknown artifact state')


def snapshot(directory):
    result = {}
    for name in ('a.out', 'prior.elf', 'held-hardlink'):
        path = directory / name
        if not os.path.lexists(path):
            result[name] = None
            continue
        info = path.lstat()
        item = {field: getattr(info, 'st_' + field) for field in
                ('dev', 'ino', 'mode', 'size', 'mtime_ns', 'ctime_ns', 'nlink')}
        if path.is_symlink():
            item['link'] = os.readlink(path)
        else:
            item['sha256'] = hashlib.sha256(path.read_bytes()).hexdigest()
        result[name] = item
    return result


def timeout_value(text):
    value = float(text)
    if not math.isfinite(value) or value <= 0:
        raise argparse.ArgumentTypeError('timeout must be finite and positive')
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compiler', type=Path, help='explicit compiler; default checksum-verified workspace seed')
    parser.add_argument('--timeout', type=timeout_value, default=10.0)
    parser.add_argument('--keep-work', action='store_true')
    parser.add_argument('--check-spec', '--self-test', action='store_true',
                        help='portable schema and synthetic oracle self-tests only; no Linux/seed execution')
    args = parser.parse_args()
    work = None
    success = False
    try:
        spec = read_spec(SPEC.read_text())
        if args.check_spec:
            self_test(spec)
            return 0
        need(sys.platform.startswith('linux'), 'requires Linux descriptor semantics')
        source = (args.compiler or SEED).resolve()
        binary = elf(source)
        digest = hashlib.sha256(binary).hexdigest()
        if args.compiler is None:
            fields = SEED.with_suffix('.seed.sha256').read_text().split()
            need(fields == [digest, 'gen1.seed'], 'workspace seed checksum mismatch')
        work = Path(tempfile.mkdtemp(prefix='herbert-stdin-contract.'))
        compiler = work / 'compiler'
        compiler.write_bytes(binary)
        compiler.chmod(0o700)
        print(f'stdin-contract: compiler={source} sha256={digest}', flush=True)
        print(f'stdin-contract: spec-sha256={hashlib.sha256(SPEC.read_bytes()).hexdigest()}', flush=True)
        rows = []

        def check(label, action):
            try:
                action()
                row = {'id': label, 'pass': True}
            except (OSError, ValueError) as error:
                row = {'id': label, 'pass': False, 'error': str(error)}
            rows.append(row)
            print(('PASS: ' if row['pass'] else 'FAIL: ') + label +
                  ('' if row['pass'] else ': ' + row['error']), flush=True)
            return row['pass']

        def compile_fixture(label, text):
            directory = work / label
            directory.mkdir()
            (directory / 'source.herb').write_text(text)
            result = invoke(compiler, directory, 'pipe-eof', text.encode(), args.timeout)
            exact(result, spec['compile_status'], spec['compile_stdout'].encode(), spec['compile_stderr'].encode())
            artifact = directory / 'a.out'
            elf(artifact)
            artifact.chmod(0o700)
            return artifact

        sentinel = work / 'compiler-eof-source' / 'a.out'
        def eof_source():
            artifact = compile_fixture('compiler-eof-source', spec['valid_source'])
            directory = work / 'valid-program'
            directory.mkdir()
            result = invoke(artifact, directory, 'pipe-eof', b'', args.timeout)
            exact(result, spec['valid_program_status'], spec['valid_program_stdout'].encode(),
                  spec['valid_program_stderr'].encode())
        sentinel_ok = check('compiler-eof-source-and-runnable42', eof_source)
        reader_ok = check('reader-fixture-compile', lambda: compile_fixture('reader-compile', spec['reader_source']))
        for case in spec['reader_cases']:
            def reader_case(case=case):
                need(reader_ok, 'reader fixture did not compile')
                directory = work / ('reader-' + case['id'])
                directory.mkdir()
                result = invoke(work / 'reader-compile/a.out', directory, case['method'], b'', args.timeout)
                exact(result, spec['reader_status'], case['stdout'].encode(), spec['reader_stderr'].encode())
            check('reader-' + case['id'], reader_case)
        for case in spec['compiler_error_cases']:
            for state in spec['artifact_states']:
                label = 'compiler-' + case['id'] + '-' + state
                def compiler_case(case=case, state=state, label=label):
                    need(sentinel_ok, 'success control did not produce a runnable sentinel ELF')
                    directory = work / label
                    directory.mkdir()
                    artifact_state(directory, state, sentinel)
                    before = snapshot(directory)
                    (directory / 'artifact-before.json').write_text(json.dumps(before, indent=2) + '\n')
                    result = invoke(compiler, directory, case['method'], b'', args.timeout)
                    after = snapshot(directory)
                    (directory / 'artifact-after.json').write_text(json.dumps(after, indent=2) + '\n')
                    same_artifacts(before, after)
                    exact(result, spec['compiler_error_status'], spec['compiler_error_stdout'].encode(),
                          spec['compiler_error_stderr_template'].format(errno=case['errno']).encode())
                check(label, compiler_case)
        need(len(rows) == 15, 'incomplete executed case ledger')
        passed = sum(row['pass'] for row in rows)
        (work / 'results.json').write_text(json.dumps({'compiler_sha256':digest, 'cases':rows,
                                                    'passed':passed, 'total':15}, indent=2) + '\n')
        print(f'stdin-contract: {passed}/15 passed; {15-passed} failed', flush=True)
        success = passed == 15
        return 0 if success else 1
    except (OSError, ValueError, KeyError) as error:
        print('FAIL: stdin-contract setup: ' + str(error), file=sys.stderr)
        return 1
    finally:
        if work is not None:
            if args.keep_work or not success:
                print('stdin-contract artifacts: ' + str(work), flush=True)
            else:
                shutil.rmtree(work)


if __name__ == '__main__':
    sys.exit(main())
