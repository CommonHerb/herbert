#!/usr/bin/env python3
"""Regression tests for complete transcripts and fail-closed emulator selection."""
import os
import re
import json
import hashlib
from pathlib import Path
import subprocess
import tempfile
import unittest

TESTS = Path(__file__).resolve().parent
ROOT = TESTS.parent.parent


def bash(code, *args, env=None, timeout=90):
    return subprocess.run(['bash', '-c', code, 'verification-test', *map(str, args)],
                          env=env, capture_output=True, timeout=timeout)


class Helpers(unittest.TestCase):
    def test_transcript_bytes(self):
        # Include embedded/trailing NUL, CRLF, missing LF, extra unterminated line,
        # extra blank lines, and correct output accompanied by stderr.
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)
            cases = [(b'result\n0\n', b'', True),
                     (b'result\n0\nGARBAGE', b'', False),
                     (b'result\n0\n\x00', b'', False),
                     (b'result\n0', b'', False),
                     (b'result\n0\r\n', b'', False),
                     (b'result\n0\n\n', b'', False),
                     (b'result\n0\n', b'warning', False),
                     (b'result\n0\n', b'\x00', False),
                     (b'', b'', False)]
            for out, err, valid in cases:
                with self.subTest(stdout=out, stderr=err):
                    (p/'out').write_bytes(out); (p/'err').write_bytes(err)
                    result = bash('source "$1" || exit; native_codegen_transcript_line1 "$2" "$3" "$4"',
                                  TESTS/'native_codegen_oracle.sh', p/'out', p/'err', p/'line')
                    self.assertEqual(result.returncode == 0, valid, result.stderr)

    def test_prefix_selection(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d); bindir = p/'pinned/bin'; bindir.mkdir(parents=True)
            exe = bindir/'qemu-system-x86_64'
            exe.write_text('#!/bin/sh\nprintf "pinned\\n"\n'); exe.chmod(0o755)
            env = dict(os.environ, QEMU_PREFIX=str(bindir.parent))
            code = '''qemu-system-x86_64() { printf 'shadow\n'; }; export -f qemu-system-x86_64
source "$1" || exit 1
cd / || exit 1
qemu-system-x86_64'''
            r = bash(code, TESTS/'qemu_prefix.sh', env=env)
            self.assertEqual((r.returncode, r.stdout), (0, b'pinned\n'), r.stderr)
            for prefix in ['relative', str(p/'missing'), str(exe)]:
                r = bash('source "$1" || exit 1', TESTS/'qemu_prefix.sh', env=dict(env, QEMU_PREFIX=prefix))
                self.assertNotEqual(r.returncode, 0, prefix)
            exe.unlink(); exe.mkdir()
            r = bash('source "$1" || exit 1', TESTS/'qemu_prefix.sh', env=env)
            self.assertNotEqual(r.returncode, 0, 'directory accepted as executable')
            exe.rmdir(); exe.write_text('not executable'); exe.chmod(0o644)
            r = bash('source "$1" || exit 1', TESTS/'qemu_prefix.sh', env=env)
            self.assertNotEqual(r.returncode, 0, 'non-executable accepted')

    def test_missing_oracle_cannot_skip(self):
        with tempfile.TemporaryDirectory() as d:
            for name in ['run_native_codegen_link18_mutation.sh', 'run_native_codegen_link30_mutation.sh',
                         'run_native_codegen_link32_mutation.sh']:
                p = Path(d)/name; p.write_bytes((TESTS/name).read_bytes())
                r = subprocess.run(['bash', str(p)], env=dict(os.environ, KERNEL_CODEGEN_MUTATION='1'), capture_output=True, timeout=10)
                self.assertNotEqual(r.returncode, 0, name)
                self.assertNotIn(b'SKIP:', r.stdout, name)

    def test_missing_prefix_helper_cannot_skip(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)/'native_codegen_oracle.sh'; p.write_bytes((TESTS/p.name).read_bytes())
            r = bash('source "$1" || exit 1; echo BAD', p)
            self.assertNotEqual(r.returncode, 0)
            self.assertNotIn(b'BAD', r.stdout)

    def test_raw_evidence_survives_cleanup(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d); source = p/'attempt'; source.mkdir(); evidence = p/'evidence'
            raw = bytes(range(256)) + b'\x00\nUNTERMINATED'
            (source/'arbitrary-output-name').write_bytes(raw)
            (source/'disk.img').write_bytes(b'not an output')
            (source/'escape').symlink_to('/etc/passwd')
            env = dict(os.environ, KERNEL_EVIDENCE_DIR=str(evidence))
            result = bash('source "$1" || exit 1; kernel_test_cleanup "$2"', TESTS/'qemu_prefix.sh', source, env=env)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(source.exists())
            captures = list(evidence.glob('capture-*'))
            self.assertEqual(len(captures), 1)
            self.assertEqual((captures[0]/'arbitrary-output-name').read_bytes(), raw)
            self.assertFalse((captures[0]/'escape').exists())
            self.assertFalse((captures[0]/'disk.img').exists())
            inventory = json.loads((captures[0]/'INVENTORY.json').read_text())
            self.assertLessEqual(inventory['started_utc'], inventory['completed_utc'])
            records = inventory['files']
            row = next(r for r in records if r['path']=='arbitrary-output-name')
            self.assertEqual(row['sha256'], hashlib.sha256(raw).hexdigest())
            omitted = next(r for r in records if r['path']=='disk.img')
            self.assertEqual(omitted['sha256'], hashlib.sha256(b'not an output').hexdigest())
            # Capture failure in an EXIT trap must preserve failure status and
            # turn success red; it must also stop an in-script directory reuse.
            source.mkdir(); (source/'raw').write_bytes(raw)
            bad_env = dict(env, KERNEL_EVIDENCE_DIR=str(source/'nested'))
            for status in (0, 7):
                result = bash('''source "$1" || exit 1; trap 'kernel_test_cleanup "$2"' EXIT; exit "$3"''',
                              TESTS/'qemu_prefix.sh', source, status, env=bad_env)
                self.assertEqual(result.returncode, status or 1, result.stderr)
                self.assertTrue(source.exists())
            result = bash('source "$1" || exit 1; kernel_test_cleanup "$2"; echo REUSED',
                          TESTS/'qemu_prefix.sh', source, env=bad_env)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn(b'REUSED', result.stdout)

    def test_group_keeps_running_after_failure(self):
        workflow = (ROOT/'.github/workflows/kernel-codegen-l1.yml').read_text()
        ranges = re.findall(r'\{lo: (\d+), hi: (\d+)\}', workflow)
        bounds = re.search(r'^GATE_LO=(\d+); GATE_HI=(\d+)$',
                           (TESTS/'kernel_verify.sh').read_text(), re.M)
        self.assertIsNotNone(bounds)
        self.assertEqual([n for lo, hi in ranges for n in range(int(lo), int(hi)+1)],
                         list(range(int(bounds[1]), int(bounds[2])+1)))
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); tests = root/'bootstrap/tests'; tests.mkdir(parents=True)
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            subprocess.run(['git', '-C', str(root), '-c', 'user.name=Test', '-c', 'user.email=test@invalid', 'commit', '--allow-empty', '-qm', 'fixture'], check=True)
            (root/'bootstrap/seed').mkdir(); (root/'bootstrap/seed/gen1.seed').write_bytes(b'seed')
            (root/'stack').mkdir(); (root/'stack/native_compile_fragment.herb').write_bytes(b'source')
            driver = tests/'kernel_ci_group.sh'; driver.write_bytes((TESTS/driver.name).read_bytes())
            for name in ('qemu_prefix.sh', 'kernel_evidence.sh'):
                (tests/name).write_bytes((TESTS/name).read_bytes())
            for name, status in [('run_native_codegen_link17', 7), ('run_native_codegen_link18', 0),
                                 ('run_native_codegen_link18_mutation', 0)]:
                (tests/(name+'.sh')).write_text(f'echo {name}; exit {status}\n')
            result = subprocess.run(['bash', str(driver), '17', '18'], capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 1)
            rows = (root/'_kernel_evidence/RESULTS.tsv').read_text().splitlines()
            self.assertEqual(len(rows), 3)
            self.assertTrue(rows[0].endswith('\t7'))
            self.assertTrue(rows[-1].endswith('\t0'))

    def test_real_native_gates_reject_extra_output(self):
        with tempfile.TemporaryDirectory() as d:
            for kind in ['evaluator', 'parser', 'lexer', 'vm']:
                source = (ROOT/f'stack/{kind}_fragment.herb').read_text()
                anchor = '    do flogger("\\n")\n    return 0\nend\n'
                self.assertEqual(source.count(anchor), 1, kind)
                env = dict(os.environ, **{f'{kind.upper()}_NATIVE_NO_C': '1'})
                gate = TESTS/f'run_{kind}_native.sh'
                # The genuine control establishes that all following failures are
                # transcript qualification, not a broken compiler or harness.
                result = subprocess.run(['bash', str(gate)], env=env, capture_output=True, timeout=120)
                self.assertEqual(result.returncode, 0, (kind, result.stdout, result.stderr))
                for label, replacement in [
                    ('trailing', '    do flogger("\\n0\\nUNTERMINATED GARBAGE")\n    do process_exit(0)\n    return 0\nend\n'),
                    ('stderr', '    do flogger("\\n")\n    let sent = stderr_write("X")\n    return 0\nend\n')]:
                    with self.subTest(kind=kind, corruption=label):
                        fragment = Path(d)/f'{kind}-{label}.herb'
                        fragment.write_text(source.replace(anchor, replacement))
                        result = subprocess.run(['bash', str(gate), '--fragment', str(fragment)],
                                                env=env, capture_output=True, timeout=120)
                        self.assertNotEqual(result.returncode, 0, (kind, label, result.stdout))
                        self.assertIn(b'native stdout is not exactly', result.stdout,
                                      'must compile and run, then fail transcript qualification')


if __name__ == '__main__':
    unittest.main()
