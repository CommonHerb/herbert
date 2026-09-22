#!/usr/bin/env python3
"""Regression tests for complete transcripts and fail-closed emulator selection."""
import os
import re
import json
import hashlib
import shutil
import sys
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
    def test_assertion_dependent_entrypoints_refuse_optimization(self):
        # Imported desktop guards also protect the two consuming entrypoints.
        hosted = ('check_desktop.py', 'check_notes_support.py',
                  'check_hosted_apps.py', 'check_x11_text.py', 'check_utf8_text.py')
        env = dict(os.environ)
        env.pop('PYTHONOPTIMIZE', None)
        for name in hosted:
            with self.subTest(entrypoint=name, mode='normal-help'):
                result = subprocess.run([sys.executable, str(TESTS/name), '--help'],
                                        env=env, capture_output=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(b'usage:', result.stdout)
                self.assertEqual(result.stderr, b'')
        for name in (*hosted, 'check_link44_attempts.py'):
            for flag, optimize in [('-O', None), ('-OO', None), ('', '1'), ('', '2')]:
                with self.subTest(entrypoint=name, flag=flag, optimize=optimize):
                    child_env = dict(env)
                    if optimize is not None:
                        child_env['PYTHONOPTIMIZE'] = optimize
                    command = [sys.executable] + ([flag] if flag else [])
                    result = subprocess.run(command + [str(TESTS/name), '--help'],
                                            env=child_env, capture_output=True, timeout=10)
                    self.assertEqual(result.returncode, 1, (result.stdout, result.stderr))
                    self.assertEqual(result.stdout, b'')
                    self.assertEqual(result.stderr,
                                     b'verification requires Python assertions; remove -O/-OO and PYTHONOPTIMIZE\n')

    def test_link34_failure_evidence_and_grader_errors(self):
        # Exercise the real shell gate and evidence cleanup with inert protocol
        # fixtures. This tests harness verdicts/retention, not guest execution.
        with tempfile.TemporaryDirectory() as d:
            p = Path(d); tests = p/'tests'; tests.mkdir()
            for name in ('run_native_codegen_link34_mutation.sh', 'qemu_prefix.sh',
                         'kernel_evidence.sh', 'kernel_evidence.py'):
                (tests/name).write_bytes((TESTS/name).read_bytes())
            (tests/'trikon_ref.py').write_text('''import os, sys
from pathlib import Path
cmd = sys.argv[1]
if cmd in ('module', 'mutate'):
    Path(sys.argv[3]).write_text(sys.argv[2])
elif cmd == 'cleanelf':
    Path(sys.argv[2]).write_text('clean')
elif cmd == 'kend':
    print('123')
elif cmd == 'grade':
    if 'tssesp0' in sys.argv[2]:
        if os.environ['LINK34_TEST_MODE'] == 'grader-silent':
            sys.exit(1)
        if os.environ['LINK34_TEST_MODE'] == 'grader-status':
            print('RED')
            sys.exit(7)
    raw = Path(sys.argv[2]).read_text()
    print('GREEN' if raw == 'clean' else 'RED')
    sys.exit(0 if raw == 'clean' else 1)
''')
            bindir = p/'pinned/bin'; bindir.mkdir(parents=True)
            qemu = bindir/'qemu-system-x86_64'
            qemu.write_text('''#!/usr/bin/env python3
import os, sys
from pathlib import Path
a = sys.argv[1:]
kernel = Path(a[a.index('-kernel') + 1])
out = Path(a[a.index('-debugcon') + 1].removeprefix('file:'))
mode = os.environ['LINK34_TEST_MODE']
if mode == 'grader-error' and kernel.stem == 'tssesp0':
    sys.exit(0)  # missing raw file makes the real Python grade process raise
out.write_text(kernel.read_text())
if mode == 'emulator-error' and kernel.stem == 'clean':
    print('injected emulator error first line', file=sys.stderr)
    print('injected emulator error second line', file=sys.stderr)
if mode == 'parser-error' and kernel.stem == 'tssesp0':
    Path(os.environ['KERNEL_PARSE_ERROR_FILE']).write_text('injected parser failure\\n')
sys.exit(215)  # legitimate guest exit codes above 124 are not harness verdicts
''')
            qemu.chmod(0o755)
            for mode, retain in [('clean', True), ('grader-error', True),
                                 ('emulator-error', True), ('grader-error', False),
                                 ('grader-silent', True), ('grader-status', True),
                                 ('parser-error', True), ('parser-error', False), ('clean', False)]:
                with self.subTest(mode=mode, retain=retain):
                    run = p/f'{mode}-{retain}'; run.mkdir(); tmp = run/'tmp'; tmp.mkdir()
                    env = dict(os.environ, QEMU_PREFIX=str(bindir.parent), TMPDIR=str(tmp),
                               LINK34_TEST_MODE=mode, KERNEL_CODEGEN_REQUIRE_EMU='1')
                    env.pop('KERNEL_EVIDENCE_DIR', None)
                    if retain:
                        env['KERNEL_EVIDENCE_DIR'] = str(run/'evidence')
                    r = subprocess.run(['bash', str(tests/'run_native_codegen_link34_mutation.sh')],
                                       env=env, capture_output=True, timeout=30)
                    self.assertEqual(r.returncode, 0 if mode == 'clean' else 1,
                                     (r.stdout, r.stderr))
                    if retain:
                        captures = list((run/'evidence').glob('capture-*'))
                        self.assertEqual(len(captures), 1)
                        capture = captures[0]
                        self.assertFalse(list(tmp.iterdir()))
                    elif mode == 'clean':
                        self.assertFalse(list(tmp.iterdir()))
                        continue
                    else:
                        captures = list(tmp.iterdir()); self.assertEqual(len(captures), 1)
                        capture = captures[0]
                        self.assertIn(f'failed work retained at {capture}'.encode(), r.stderr)
                        self.assertTrue((capture/'tssesp0.elf').is_file())
                    self.assertEqual(len(list(capture.glob('*.e9.bin.status'))), 13)
                    self.assertTrue((capture/'hardcodeaddr.elf-benign.e9.bin').is_file())
                    if mode.startswith('grader-'):
                        self.assertIn(b'grader diagnostics for tssesp0.elf-benign', r.stderr)
                        self.assertIn('tssesp0.elf-benign (grader)',
                                      (capture/'harness-failures.txt').read_text())
                    if mode == 'grader-error':
                        self.assertIn('FileNotFoundError',
                                      (capture/'tssesp0.elf-benign.e9.bin.grade.qerr').read_text())
                    if mode == 'emulator-error':
                        self.assertIn(b'injected emulator error second line', r.stderr)
                        self.assertIn('grader_status=0',
                                      (capture/'clean.elf-benign.e9.bin.status').read_text())
                    if mode == 'parser-error':
                        self.assertIn(b'PARSER-ERROR:', r.stderr)
                        self.assertNotIn(b'PASS:', r.stdout)

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

    def test_compiler_success_bytes(self):
        # Exercise the byte contract independently of artifact/runtime checks.
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)
            (p/'source.herb').write_text('source for the invocation fixture\n')
            compiler = p/'compiler'
            compiler.write_text('#!/bin/sh\n/bin/cat "$FIXTURE_STDOUT"\n'
                                '/bin/cat "$FIXTURE_STDERR" >&2\nexit "$FIXTURE_STATUS"\n')
            compiler.chmod(0o755)
            cases = [(0, b'0\n', b'', True), (7, b'0\n', b'', False),
                     (0, b'0', b'', False), (0, b'0\n\n', b'', False),
                     (0, b'0\n\x00', b'', False), (0, b'0\r\n', b'', False),
                     (0, b'', b'', False), (0, b'0\n', b'warning\n', False),
                     (0, b'0\n', b'\x00', False)]
            for status, out, err, valid in cases:
                with self.subTest(status=status, stdout=out, stderr=err):
                    (p/'out').write_bytes(out); (p/'err').write_bytes(err)
                    env = dict(os.environ, FIXTURE_STATUS=str(status),
                               FIXTURE_STDOUT=str(p/'out'), FIXTURE_STDERR=str(p/'err'))
                    result = bash('source "$1" || exit 1; native_codegen_compile_success "$2" "$3" "$4" /nonexistent',
                                  TESTS/'native_codegen_oracle.sh', compiler, p/'source.herb', p, env=env)
                    self.assertEqual(result.returncode == 0, valid, result.stderr)
                    self.assertEqual((p/'compile.status').read_text(), f'{status}\n')

    def test_compiler_path_scope(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d); (p/'source.herb').write_bytes(b'')
            compiler = p/'compiler'
            compiler.write_text('#!/bin/sh\ncat < /dev/null || exit 7\nprintf "0\\n"\n')
            compiler.chmod(0o755)
            code = 'source "$1" || exit 1; native_codegen_compile_success "$2" "$3" "$4"'
            normal = bash(code, TESTS/'native_codegen_oracle.sh', compiler, p/'source.herb', p)
            self.assertEqual(normal.returncode, 0, normal.stderr)
            scrubbed = bash(code+' /nonexistent', TESTS/'native_codegen_oracle.sh', compiler, p/'source.herb', p)
            self.assertNotEqual(scrubbed.returncode, 0)
            self.assertEqual((p/'compile.status').read_text(), '7\n')
            self.assertIn(b'compiler success contract failed: status=7', scrubbed.stderr)

    def test_real_fragment_gates_reject_compiler_failures(self):
        # The real seed emits a valid ELF BEFORE the wrapper corrupts only the
        # invocation envelope. This reproduces artifact-exists false greens;
        # no helper or runtime oracle is replaced. /bin/sh + absolute seed keep
        # the emitter gate's PATH=/nonexistent compile condition intact.
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)
            seed = p/'seed'; seed.write_bytes((ROOT/'bootstrap/seed/gen1.seed').read_bytes())
            seed.chmod(0o755)
            wrapper = p/'compiler'
            wrapper.write_text('''#!/bin/sh
"$FRAGMENT_TEST_SEED"
rc=$?
[ "$rc" -eq 0 ] || exit "$rc"
[ -s a.out ] || exit 93
printf 'seed_status=0 artifact=present\n' >> "$FRAGMENT_TEST_RECEIPT"
case "$FRAGMENT_TEST_CORRUPTION" in
    clean) exit 0 ;;
    status) exit 7 ;;
    stdout) printf 'unexpected compiler stdout\n' ;;
    stderr) printf 'unexpected compiler stderr\n' >&2 ;;
    *) exit 94 ;;
esac
''')
            wrapper.chmod(0o755)
            controls = rejected = 0
            for kind in ('evaluator', 'vm', 'parser', 'lexer', 'klondike', 'emitter', 'aggregate_render', 'error_vocab'):
                for suffix in ('', '_mutation'):
                    gate = TESTS/f'run_{kind}_native{suffix}.sh'
                    for corruption in ('clean', 'status', 'stdout', 'stderr'):
                        with self.subTest(gate=gate.name, corruption=corruption):
                            receipt = p/f'{kind}{suffix}-{corruption}.receipt'
                            env = dict(os.environ, NATIVE_CODEGEN_COMPILER=str(wrapper),
                                       FRAGMENT_TEST_SEED=str(seed), FRAGMENT_TEST_RECEIPT=str(receipt),
                                       FRAGMENT_TEST_CORRUPTION=corruption,
                                       **{f'{kind.upper()}_NATIVE_NO_C': '1'})
                            result = subprocess.run(['bash', str(gate)], env=env,
                                                    capture_output=True, timeout=240)
                            self.assertTrue(receipt.is_file(), (gate.name, result.stdout, result.stderr))
                            self.assertIn('seed_status=0 artifact=present\n', receipt.read_text())
                            if corruption == 'clean':
                                self.assertEqual(result.returncode, 0, (gate.name, result.stdout, result.stderr))
                                controls += 1
                            else:
                                self.assertNotEqual(result.returncode, 0, (gate.name, corruption, result.stdout))
                                if gate.name == 'run_error_vocab_native_mutation.sh':
                                    self.assertIn(b'CONTROL went RED', result.stdout)
                                else:
                                    self.assertIn(b'compiler success contract failed:', result.stderr)
                                rejected += 1
            print(f'native compile contract: {controls} controls green; {rejected} malformed invocations rejected')

    def test_kernel_summary_reports_gate_status_only(self):
        # Deliberately inert fixtures establish exactly what the aggregate
        # knows: successful scripts do not demonstrate any substrate boot.
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); tests = root/'bootstrap/tests'; tests.mkdir(parents=True)
            for name in ('kernel_verify.sh', 'qemu_prefix.sh', 'kernel_evidence.sh'):
                (tests/name).write_bytes((TESTS/name).read_bytes())
            bindir = root/'bin'; bindir.mkdir()
            qemu = bindir/'qemu-system-x86_64'
            qemu.write_text('#!/bin/sh\nexit 91\n'); qemu.chmod(0o755)
            gate = tests/'run_native_codegen_link40.sh'
            mutation = tests/'run_native_codegen_link40_mutation.sh'
            gate.write_text('[ "$KERNEL_CODEGEN_REQUIRE_EMU" = 1 ] || exit 92\nexit 0\n')
            mutation.write_text('[ "$KERNEL_CODEGEN_MUTATION" = 1 ] || exit 93\nexit 0\n')
            env = dict(os.environ, PATH=str(bindir)+os.pathsep+os.environ['PATH'],
                       KERNEL_VERIFY_LO='40', KERNEL_VERIFY_HI='40')
            env.pop('QEMU_PREFIX', None)
            result = subprocess.run(['bash', str(tests/'kernel_verify.sh')], env=env,
                                    capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(b'GREEN (1 gates + 1 mutation proofs passed;', result.stdout)
            self.assertIn(b'no aggregate per-substrate execution receipts, including KVM.', result.stdout)
            self.assertNotIn(b'+ KVM', result.stdout)
            # A KVM member still enforces device access separately from the
            # always-run summary assertions above, even on inaccessible hosts.
            for name in ('run_native_codegen_link39.sh', 'run_native_codegen_link39_mutation.sh'):
                (tests/name).write_text('exit 0\n')
            member = subprocess.run(['bash', str(tests/'kernel_verify.sh')],
                                    env=dict(env, KERNEL_VERIFY_LO='39', KERNEL_VERIFY_HI='39'),
                                    capture_output=True, timeout=10)
            if Path('/dev/kvm').exists() and not os.access('/dev/kvm', os.R_OK | os.W_OK):
                self.assertNotEqual(member.returncode, 0)
                self.assertIn(b'/dev/kvm exists but is not usable', member.stderr)
            else:
                self.assertEqual(member.returncode, 0, member.stderr)
                self.assertIn(b'no aggregate per-substrate execution receipts, including KVM.', member.stdout)
                self.assertNotIn(b'+ KVM', member.stdout)
            gate.write_text('exit 7\n')
            result = subprocess.run(['bash', str(tests/'kernel_verify.sh')], env=env,
                                    capture_output=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn(b'kernel-verify: GREEN', result.stdout)

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
            (source/'gen1x.compiler').write_bytes(b'\x7fELFcompiler variant')
            (source/'gen1x.raw').write_bytes(raw)
            (source/'escape').symlink_to('/etc/passwd')
            probe=p/'probe.out'; probe.write_bytes(raw)
            (p/'probe.out.qerr').write_bytes(b'actual stderr\n')
            env = dict(os.environ, KERNEL_EVIDENCE_DIR=str(evidence))
            result = bash('source "$1" || exit 1; kernel_test_record_boot "$2" "$3" "$2/gen1x.compiler" "$2/gen1x.raw"; kernel_test_cleanup "$2"', TESTS/'qemu_prefix.sh', source, probe, env=env)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(source.exists())
            captures = list(evidence.glob('capture-*'))
            self.assertEqual(len(captures), 1)
            self.assertEqual((captures[0]/'arbitrary-output-name').read_bytes(), raw)
            self.assertFalse((captures[0]/'escape').exists())
            self.assertFalse((captures[0]/'disk.img').exists())
            self.assertFalse((captures[0]/'gen1x.compiler').exists())
            self.assertEqual((captures[0]/'gen1x.raw').read_bytes(), raw)
            self.assertEqual((captures[0]/'probe.out').read_bytes(), raw)
            self.assertEqual((captures[0]/'probe.out.qerr').read_bytes(), b'actual stderr\n')
            self.assertIn(hashlib.sha256(raw).hexdigest(), (captures[0]/'BOOT-SHA256.txt').read_text())
            inventory = json.loads((captures[0]/'INVENTORY.json').read_text())
            self.assertLessEqual(inventory['started_utc'], inventory['completed_utc'])
            records = inventory['files']
            row = next(r for r in records if r['path']=='arbitrary-output-name')
            self.assertEqual(row['sha256'], hashlib.sha256(raw).hexdigest())
            compiler = next(r for r in records if r['path']=='gen1x.compiler')
            self.assertEqual(compiler['sha256'], hashlib.sha256(b'\x7fELFcompiler variant').hexdigest())
            self.assertFalse(compiler['retained'])
            omitted = next(r for r in records if r['path']=='disk.img')
            self.assertEqual(omitted['sha256'], hashlib.sha256(b'not an output').hexdigest())
            # Capture failure in an EXIT trap must preserve failure status and
            # turn success red; it must also stop an in-script directory reuse.
            source.mkdir(); (source/'raw').write_bytes(raw)
            (source/'probe.out').mkdir()  # destination conflict: copying must fail closed even inside a subshell
            result = bash('source "$1" || exit 1; (kernel_test_record_boot "$2" "$3" "$2/raw" "$2/raw") || true; kernel_test_cleanup "$2"; echo BAD',
                          TESTS/'qemu_prefix.sh', source, probe, env=env)
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertNotIn(b'BAD', result.stdout)
            (source/'probe.out').rmdir()
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


class Reseed(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # An actual executable ELF exercises the script's image checks. This is
        # a host-built invocation fixture, never a Herbert compiler or runtime.
        cls.fixture_work = tempfile.TemporaryDirectory(prefix='reseed-protocol-fixture-')
        cls.addClassCleanup(cls.fixture_work.cleanup)
        directory = Path(cls.fixture_work.name)
        source = directory/'protocol.c'
        source.write_text(r'''#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
int main(void) {
    char directory[4096], buffer[4096]; size_t n;
    if (!getcwd(directory, sizeof directory)) return 90;
    const char *phase = strrchr(directory, '/') + 1;
    FILE *in = fopen(getenv("RESEED_TEST_NEXT"), "rb");
    FILE *out = fopen("a.out", "wb");
    if (!in || !out) return 91;
    while ((n = fread(buffer, 1, sizeof buffer, in)))
        if (fwrite(buffer, 1, n, out) != n) return 92;
    if (ferror(in) || fclose(out) || fclose(in)) return 93;
    FILE *receipt = fopen(getenv("RESEED_TEST_CALLS"), "a");
    if (!receipt) return 94;
    fprintf(receipt, "%s\n", phase); fclose(receipt);
    const char *edit = getenv("RESEED_TEST_COMPILE_EDIT");
    if (edit && !strcmp(phase, "gen2")) {
        FILE *file = fopen(edit, "ab"); if (!file) return 95;
        fputs("changed by fixture\n", file); fclose(file);
    }
    fputs("0\n", stdout);
    const char *bad_phase = getenv("RESEED_TEST_BAD_PHASE");
    if (bad_phase && !strcmp(phase, bad_phase)) {
        const char *kind = getenv("RESEED_TEST_BAD_KIND");
        if (!strcmp(kind, "status")) return 7;
        if (!strcmp(kind, "stdout")) fputs("unexpected\n", stdout);
        if (!strcmp(kind, "stderr")) fputs("unexpected\n", stderr);
    }
    return 0;
}
''')
        compiler = shutil.which('cc')
        if compiler is None:
            raise RuntimeError('reseed invocation tests require the host C compiler used by make check')
        image = directory/'protocol'
        result = subprocess.run([compiler, '-std=c99', '-O0', str(source), '-o', str(image)],
                                capture_output=True, timeout=30)
        if result.returncode != 0:
            raise RuntimeError(f'cannot build reseed invocation fixture: {result.stderr!r}')
        cls.image = image.read_bytes()

    def prepare(self, directory, changed=False):
        root = directory/'repo'
        tests = root/'bootstrap/tests'; tests.mkdir(parents=True)
        seeds = root/'bootstrap/seed'; seeds.mkdir()
        stack = root/'stack'; stack.mkdir()
        (tests/'reseed_gen1.sh').write_bytes((TESTS/'reseed_gen1.sh').read_bytes())
        # Controlled gate checks sequencing and failure handling. The real
        # conformance matrix is exercised separately against the real candidate.
        (tests/'compiler_conformance.py').write_text('''import hashlib, os, sys
from pathlib import Path
root = Path(__file__).resolve().parents[2]
candidate = Path(sys.argv[2])
if sys.argv[1] != '--compiler' or candidate.read_bytes() != Path(os.environ['RESEED_TEST_NEXT']).read_bytes():
    raise SystemExit('wrong candidate passed to conformance')
if (root/'bootstrap/seed/gen1.seed').read_bytes() != Path(os.environ['RESEED_TEST_ORIGINAL']).read_bytes():
    raise SystemExit('seed published before conformance')
Path(os.environ['RESEED_TEST_GATE_RECEIPT']).write_text(hashlib.sha256(candidate.read_bytes()).hexdigest())
edit = os.environ.get('RESEED_TEST_GATE_EDIT')
if edit:
    with Path(edit).open('ab') as f: f.write(b'changed by fixture\\n')
print('controlled candidate conformance ' + os.environ.get('RESEED_TEST_GATE', 'pass'))
raise SystemExit(1 if os.environ.get('RESEED_TEST_GATE') == 'reject' else 0)
''')
        seed = seeds/'gen1.seed'; seed.write_bytes(self.image)
        pin = seeds/'gen1.seed.sha256'
        pin.write_text(hashlib.sha256(self.image).hexdigest() + '  gen1.seed\n')
        backend = stack/'native_compile_fragment.herb'; backend.write_text('controlled backend\n')
        original = directory/'original.seed'; original.write_bytes(self.image)
        candidate = directory/'candidate.seed'
        candidate.write_bytes(self.image + (b'changed ELF fixture\n' if changed else b''))
        temporary = directory/'tmp'; temporary.mkdir()
        env = dict(os.environ, TMPDIR=str(temporary), RESEED_TEST_NEXT=str(candidate),
                   RESEED_TEST_ORIGINAL=str(original), RESEED_TEST_CALLS=str(directory/'calls'),
                   RESEED_TEST_GATE_RECEIPT=str(directory/'gate'))
        inputs = {seed: seed.read_bytes(), pin: pin.read_bytes(), backend: backend.read_bytes()}
        return tests/'reseed_gen1.sh', env, inputs

    def invoke(self, script, env):
        return subprocess.run(['bash', str(script)], env=env, capture_output=True, timeout=15)

    def retained(self, result, env, inputs):
        self.assertNotEqual(result.returncode, 0, (result.stdout, result.stderr))
        work, = Path(env['TMPDIR']).iterdir()
        self.assertIn(f'failed work retained at {work}'.encode(), result.stderr)
        for name, data in zip(('previous.seed', 'previous.sha256', 'source.herb'), inputs.values()):
            self.assertEqual((work/name).read_bytes(), data)
        return work

    def unchanged(self, inputs):
        for path, before in inputs.items():
            self.assertEqual(path.read_bytes(), before, str(path))

    def test_malformed_pin_refused_before_execution(self):
        for mode in ('wrong-digest', 'wrong-name', 'trailing-line', 'truncated'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as d:
                script, env, inputs = self.prepare(Path(d))
                pin = next(p for p in inputs if p.suffix == '.sha256')
                correct = pin.read_bytes()
                bad = {'wrong-digest': b'0'*64 + b'  gen1.seed\n',
                       'wrong-name': correct.replace(b'gen1.seed', b'other.seed'),
                       'trailing-line': correct + b'unexpected\n',
                       'truncated': correct.rstrip(b'\n')}[mode]
                pin.write_bytes(bad); inputs[pin] = bad
                result = self.invoke(script, env)
                self.retained(result, env, inputs); self.unchanged(inputs)
                self.assertIn(b'current seed checksum mismatch; no compiler executed', result.stderr)
                self.assertFalse(Path(env['RESEED_TEST_CALLS']).exists())
                self.assertFalse(Path(env['RESEED_TEST_GATE_RECEIPT']).exists())

    def test_both_generation_envelopes_despite_valid_artifact(self):
        for phase in ('gen1', 'gen2'):
            for kind in ('status', 'stdout', 'stderr'):
                with self.subTest(phase=phase, kind=kind), tempfile.TemporaryDirectory() as d:
                    script, env, inputs = self.prepare(Path(d), changed=True)
                    env.update(RESEED_TEST_BAD_PHASE=phase, RESEED_TEST_BAD_KIND=kind)
                    result = self.invoke(script, env)
                    work = self.retained(result, env, inputs); self.unchanged(inputs)
                    self.assertEqual((work/phase/'a.out').read_bytes(), Path(env['RESEED_TEST_NEXT']).read_bytes())
                    self.assertEqual((work/phase/'compiler.status').read_text(), '7\n' if kind == 'status' else '0\n')
                    self.assertEqual((work/phase/'compiler.stdout').read_bytes(),
                                     b'0\nunexpected\n' if kind == 'stdout' else b'0\n')
                    self.assertEqual((work/phase/'compiler.stderr').read_bytes(),
                                     b'unexpected\n' if kind == 'stderr' else b'')
                    self.assertIn(b'compiler exited 7' if kind == 'status' else
                                  b'compiler success envelope failed', result.stderr)
                    self.assertEqual(Path(env['RESEED_TEST_CALLS']).read_text(),
                                     'gen1\n' if phase == 'gen1' else 'gen1\ngen2\n')
                    self.assertFalse(Path(env['RESEED_TEST_GATE_RECEIPT']).exists())

    def test_changed_candidate_gate_before_publication(self):
        for changed, gate in ((False, 'pass'), (True, 'pass'), (True, 'reject')):
            with self.subTest(changed=changed, gate=gate), tempfile.TemporaryDirectory() as d:
                script, env, inputs = self.prepare(Path(d), changed=changed)
                env['RESEED_TEST_GATE'] = gate
                result = self.invoke(script, env)
                self.assertEqual(Path(env['RESEED_TEST_CALLS']).read_text(), 'gen1\ngen2\n')
                receipt = Path(env['RESEED_TEST_GATE_RECEIPT'])
                self.assertEqual(receipt.exists(), changed)
                if changed:
                    self.assertEqual(receipt.read_text(), hashlib.sha256(Path(env['RESEED_TEST_NEXT']).read_bytes()).hexdigest())
                if gate == 'reject':
                    work = self.retained(result, env, inputs); self.unchanged(inputs)
                    self.assertIn(b'candidate conformance failed; seed unchanged', result.stderr)
                    self.assertIn('controlled candidate conformance reject', (work/'conformance.log').read_text())
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertFalse(list(Path(env['TMPDIR']).iterdir()))
                    seed, pin, backend = inputs
                    self.assertEqual(seed.read_bytes(), Path(env['RESEED_TEST_NEXT']).read_bytes())
                    self.assertEqual(pin.read_text(), hashlib.sha256(seed.read_bytes()).hexdigest() + '  gen1.seed\n')
                    self.assertEqual(backend.read_bytes(), inputs[backend])

    def test_input_edits_refused_before_current_exit_and_after_gate(self):
        for changed in (False, True):
            for index in range(3):
                with self.subTest(changed=changed, input=index), tempfile.TemporaryDirectory() as d:
                    script, env, inputs = self.prepare(Path(d), changed=changed)
                    path = list(inputs)[index]
                    env['RESEED_TEST_GATE_EDIT' if changed else 'RESEED_TEST_COMPILE_EDIT'] = str(path)
                    result = self.invoke(script, env)
                    self.retained(result, env, inputs)
                    self.assertIn(b'inputs changed during qualification; refusing publication', result.stderr)
                    self.assertNotIn(b'already current', result.stdout)
                    for current, before in inputs.items():
                        self.assertEqual(current.read_bytes(), before + (b'changed by fixture\n' if current == path else b''))

    def test_second_rename_failure_retains_recoverable_prior_pair(self):
        with tempfile.TemporaryDirectory() as d:
            directory = Path(d)
            script, env, inputs = self.prepare(directory, changed=True)
            binary = directory/'bin'; binary.mkdir()
            real_mv = shutil.which('mv')
            self.assertIsNotNone(real_mv)
            wrapper = binary/'mv'
            wrapper.write_text('#!/bin/bash\n[[ "${@: -1}" != *.sha256 ]] || exit 88\nexec "$RESEED_TEST_MV" "$@"\n')
            wrapper.chmod(0o755)
            env.update(PATH=str(binary) + os.pathsep + os.environ['PATH'], RESEED_TEST_MV=real_mv)
            result = self.invoke(script, env)
            work = self.retained(result, env, inputs)
            self.assertEqual(result.returncode, 88, result.stderr)
            self.assertIn(b'publication staging retained at', result.stderr)
            seed, pin, backend = inputs
            self.assertEqual(seed.read_bytes(), Path(env['RESEED_TEST_NEXT']).read_bytes())
            self.assertEqual(pin.read_bytes(), inputs[pin])
            self.assertEqual(backend.read_bytes(), inputs[backend])
            stage, = seed.parent.glob('.reseed.*')
            self.assertEqual((stage/'gen1.seed.sha256').read_text(), hashlib.sha256(seed.read_bytes()).hexdigest() + '  gen1.seed\n')
            self.assertNotEqual(hashlib.sha256(seed.read_bytes()).hexdigest(), pin.read_text().split()[0])
            calls = Path(env['RESEED_TEST_CALLS']).read_bytes()
            retry = self.invoke(script, env)
            self.assertNotEqual(retry.returncode, 0)
            self.assertIn(b'current seed checksum mismatch; no compiler executed', retry.stderr)
            self.assertEqual(Path(env['RESEED_TEST_CALLS']).read_bytes(), calls)
            self.assertEqual((work/'previous.seed').read_bytes(), inputs[seed])


if __name__ == '__main__':
    unittest.main()
