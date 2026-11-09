#!/usr/bin/env python3
"""Regression tests for complete transcripts, compiler invocation contracts and the reseed recipe."""
import os
import re
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


# The hosted link gates must send every successful compile through
# native_codegen_compile_success (status 0, stdout exactly "0\n", empty stderr).
# raw_success_compiles is a heuristic, non-exhaustive census of raw compiler
# invocations in them; its docstring names what it is tuned to and known misses.
LINK_GATES = tuple(f'run_native_codegen_link{n}.sh' for n in range(1, 17)) + ('run_native_codegen_rejects.sh',)
# One redirection word: an optional descriptor, the operator, one quoted or one bare target.
_REDIRECTION = r'\d*(?:<<<|<<-?|<[&>]?|&>>?|>[>&|]?)\s*(?:"[^"]*"|\'[^\']*\'|[^\s"\'();&|<>]+)'
# ( cd "<dir>" && [redirections] [timeout <bound>] [redirections] "$<word>" [redirections]
CENSUS_SUBSHELL = re.compile(
    r'\(\s*cd\s+"[^"]+"\s*&&\s*((?:' + _REDIRECTION + r'\s*)*)(?:timeout\s+[^\s<>]+\s*)?'
    r'((?:' + _REDIRECTION + r'\s*)*)"\$[A-Za-z0-9_{}/.]+"((?:\s*' + _REDIRECTION + r')*)')
NAMED_COMPILER = re.compile(r'\$\{?(?:NATIVE_CODEGEN_COMPILER|be_elf|tmp\}?/self_compiler\.elf)')
_REDIRECTION_TARGET = re.compile(r'[<>]&?\s*"?$')
# Simple commands end at ; && || a pipe (not >|) and parentheses; the separators are kept.
_COMMAND_SEPARATOR = re.compile(r'(&&|\|\||(?<!>)\||[;()])')
_GROUP_REDIRECTIONS = re.compile(r'\s*(?:\}|done|fi|esac)?\s*(?:' + _REDIRECTION + r'\s*)+$')


def _substitutions(text):
    """text with each $( ... ) replaced by one word, and the substitutions' own texts."""
    outer, inner, i = [], [], 0
    while (j := text.find('$(', i)) >= 0:
        depth, k = 1, j + 2
        while k < len(text) and depth:
            depth += {'(': 1, ')': -1}.get(text[k], 0)
            k += 1
        outer.append(text[i:j] + 'SUBSTITUTION')
        inner.append(text[j + 2:k - 1])
        i = k
    return ''.join(outer) + text[i:], inner


def _runs_named_compiler(command):
    return any(not _REDIRECTION_TARGET.search(command[:m.start()]) for m in NAMED_COMPILER.finditer(command))


def _raw_compile(text):
    if any('<' in group for census in CENSUS_SUBSHELL.finditer(text) for group in census.groups()):
        return True
    outer, inner = _substitutions(text)
    parts = _COMMAND_SEPARATOR.split(outer)
    commands, separators = parts[0::2], [''] + parts[1::2]
    for index, command in enumerate(commands):
        if separators[index] == '|' and _runs_named_compiler(command):
            return True
        if '<' not in command:
            continue
        if _runs_named_compiler(command):
            return True
        group = separators[index] == ')' or command.lstrip().startswith(('}', 'done', 'fi', 'esac'))
        if group and _GROUP_REDIRECTIONS.match(command) and any(map(_runs_named_compiler, commands[:index])):
            return True
    return any(map(_raw_compile, inner))


def raw_success_compiles(text):
    r"""One (first line number, logical line) pair per completed logical line the heuristic flags.

    A heuristic census of literal shell text, not a shell parser, and not
    exhaustive. It is tuned to the compile shapes these 17 gates have used
    (the named compilers $NATIVE_CODEGEN_COMPILER, $be_elf and
    $tmp/self_compiler.elf fed stdin with <, and the census subshell
    ( cd "<dir>" && ... "$VAR" ... ) with its redirections) and to the planted
    variants in its controls. Any shell form it does not recognise is not
    checked. Known misses found in review include: escaped quotes inside a
    quoted redirection target; a backslash continuation on the file's last
    line; a target mixing quoted and bare text before the compiler word;
    process substitution feeding stdin before the compiler word; computed
    command names; stdin set up on another line; and text run through eval,
    bash -c or source unless the literal shape is on one line. It guards
    against the old raw pattern coming back. It skips full-line comments and
    drops a pending continuation at end of file. The dynamic 17-gate test
    requires every gate to fail with the helper's diagnostic under a
    stdout-noisy and a stderr-noisy compiler; it does not establish
    enforcement at every compile site or test a nonzero compiler status.
    """
    hits, pending, start = [], None, 0
    for number, line in enumerate(text.splitlines(), 1):
        if pending is None:
            if line.lstrip().startswith('#'):
                continue
            pending, start = '', number
        if line.endswith('\\'):
            pending += line[:-1]
            continue
        logical, pending = pending + line, None
        if _raw_compile(logical):
            hits.append((start, logical.strip()))
    return hits


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
        for name in hosted:
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

    def test_compiler_success_bound(self):
        # The fifth argument bounds the compiler. timeout is resolved on the caller's
        # PATH, so a compiler-only PATH of /nonexistent still runs bounded; an
        # exceeded bound records 124; a bound with no timeout refuses unrun, with
        # its message and status 1 even in a caller running set -e, bare or checked.
        sleep = shutil.which('sleep')
        self.assertIsNotNone(sleep)
        with tempfile.TemporaryDirectory() as d:
            p = Path(d); (p/'source.herb').write_bytes(b'')
            compiler = p/'compiler'
            compiler.write_text('#!/bin/sh\n: > "$FIXTURE_MARK"\n'
                                f'[ -z "$FIXTURE_SLEEP" ] || exec {sleep} "$FIXTURE_SLEEP"\n'
                                'printf "0\\n"\n')
            compiler.chmod(0o755)
            code = 'source "$1" || exit 1; PATH="$6" native_codegen_compile_success "$2" "$3" "$4" /nonexistent "$5"'
            call = 'native_codegen_compile_success "$2" "$3" "$4" /nonexistent "$5"'
            # Under set -e a failed lookup used to exit the caller at the lookup,
            # silently. The trailing exit 0 runs only if the helper returned 0.
            bare = f'source "$1" || exit 1; set -eu; PATH="$6"; {call}; exit 0'
            checked = f'source "$1" || exit 1; set -eu; PATH="$6"; if {call}; then exit 0; else exit "$?"; fi'
            caller = os.environ['PATH']
            for label, fixture_sleep, bound, caller_path, status, script in [
                    ('within bound', '', '30s', caller, 0, code),
                    ('exceeded bound', '30', '0.3s', caller, 124, code),
                    ('no timeout on caller PATH', '', '30s', '/nonexistent', None, code),
                    ('no timeout, bare call under set -e', '', '30s', '/nonexistent', None, bare),
                    ('no timeout, checked call under set -e', '', '30s', '/nonexistent', None, checked)]:
                with self.subTest(case=label):
                    work = p/label.replace(' ', '-').replace(',', ''); work.mkdir()
                    mark = work/'compiler-ran'
                    env = dict(os.environ, FIXTURE_MARK=str(mark), FIXTURE_SLEEP=fixture_sleep)
                    r = bash(script, TESTS/'native_codegen_oracle.sh', compiler, p/'source.herb', work,
                             bound, caller_path, env=env, timeout=20)
                    if status is None:
                        self.assertEqual(r.returncode, 1, r.stderr)
                        self.assertIn(b'compiler not run: bound 30s needs a timeout executable', r.stderr)
                        self.assertFalse(mark.exists())
                        self.assertFalse((work/'compile.status').exists())
                        continue
                    self.assertTrue(mark.exists(), r.stderr)
                    self.assertEqual((work/'compile.status').read_text(), f'{status}\n')
                    self.assertEqual(r.returncode == 0, status == 0, r.stderr)
                    if status:
                        self.assertIn(f'compiler success contract failed: status={status}'.encode(), r.stderr)

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

    def test_real_link_gates_reject_compiler_success_violations(self):
        # The real seed compiles and publishes a.out BEFORE the wrapper corrupts one
        # success channel, so only the invocation envelope is wrong. Each gate must
        # fail with the helper's own message: bare rc != 0 is not enough, because
        # link10 also fails any non-ELF compiler at its self-compile altimeter. For
        # the same reason no clean control runs through the wrapper; make test runs
        # the 17 gates green on the real seed. The wrapper corrupts every compile,
        # so this proves each gate's first success compile; the lint below
        # heuristically checks completed logical lines, skipping full-line
        # comments and dropping a pending continuation at end of file.
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)
            seed = p/'seed'; seed.write_bytes((ROOT/'bootstrap/seed/gen1.seed').read_bytes())
            seed.chmod(0o755)
            wrapper = p/'compiler'
            wrapper.write_text('''#!/bin/sh
"$LINK_TEST_SEED"
rc=$?
[ "$rc" -eq 0 ] || exit "$rc"
[ -s a.out ] || exit 93
printf 'seed_status=0 artifact=present\n' >> "$LINK_TEST_RECEIPT"
case "$LINK_TEST_CORRUPTION" in
    stdout) printf 'unexpected compiler stdout\n' ;;
    stderr) printf 'unexpected compiler stderr\n' >&2 ;;
    *) exit 94 ;;
esac
''')
            wrapper.chmod(0o755)
            ambient = ('THRONE_COMPILE_TIMEOUT', 'NATIVE_FIXPOINT_TIMEOUT')
            base = {k: v for k, v in os.environ.items()
                    if not k.startswith('NATIVE_CODEGEN_') and k not in ambient}
            rejected = 0
            for name in LINK_GATES:
                for corruption in ('stdout', 'stderr'):
                    with self.subTest(gate=name, corruption=corruption):
                        receipt = p/f'{name}-{corruption}.receipt'
                        env = dict(base, NATIVE_CODEGEN_COMPILER=str(wrapper), NATIVE_CODEGEN_ORACLE='golden',
                                   HERBERT='/bin/false', LINK_TEST_SEED=str(seed),
                                   LINK_TEST_RECEIPT=str(receipt), LINK_TEST_CORRUPTION=corruption)
                        result = subprocess.run(['bash', str(TESTS/name)], env=env,
                                                capture_output=True, timeout=900)
                        evidence = (name, corruption, result.returncode, result.stdout[-1500:], result.stderr[-1500:])
                        self.assertTrue(receipt.is_file(), evidence)
                        self.assertIn('seed_status=0 artifact=present\n', receipt.read_text())
                        self.assertNotEqual(result.returncode, 0, evidence)
                        self.assertIn(b'compiler success contract failed:', result.stderr, evidence)
                        rejected += 1
            print(f'link compile contract: {rejected} malformed invocations rejected by {len(LINK_GATES)} gates')

    def test_link_gates_route_success_compiles_through_helper(self):
        # The dynamic test above reaches only each gate's first success compile.
        # This lint checks every line of the 17 gates: none may hold a raw compiler
        # invocation of a shape raw_success_compiles recognises (a bounded syntax
        # census, not a shell parser).
        gates = [TESTS/name for name in LINK_GATES]
        self.assertEqual(len(gates), 17)
        for gate in gates:
            with self.subTest(gate=gate.name):
                text = gate.read_text()
                self.assertEqual(raw_success_compiles(text), [])
                calls = [l for l in text.splitlines()
                         if not l.lstrip().startswith('#') and 'native_codegen_compile_success ' in l]
                self.assertTrue(calls, 'gate has no helper call left to guard')
        # Planted mutants: every raw shape the census found, and others the lint
        # claims, must be flagged exactly once at the planted line.
        host = (TESTS/'run_native_codegen_link5.sh').read_text().splitlines()
        anchor = next(i for i, l in enumerate(host) if 'native_codegen_compile_success ' in l)
        planted = [
            '    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < "$probe" > "$out_file" 2>"$err_file" )',
            '( cd "$frag_cdir" && "$NATIVE_CODEGEN_COMPILER" <"$fragment" >"$tmp/frag.cc.out" 2>"$tmp/frag.cc.err" )',
            '        ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" <"$be" >/dev/null 2>&1 )',
            '        ( cd "$cdir" && "$be_elf" <"$probe" >"$out" 2>"$err" )',
            '    ( cd "$nd" && "$tmp/self_compiler.elf" <"$tmp/self_host_probe.herb" >"$tmp/o" 2>"$tmp/e" )',
            '    ( cd "$cdir" && timeout "$compile_bound" "$NATIVE_CODEGEN_COMPILER" <"$probe" >"$tmp/o" 2>"$tmp/e" )',
            '        ( cd "$g2d" && timeout "$fix_timeout" "$tmp/self_compiler.elf" <"$backend" >"$tmp/o" 2>"$tmp/e" )',
            '    ( cd "$cdir" && "$PROBE_COMPILER" <"$probe" >"$out" 2>"$err" )',
            '    "$NATIVE_CODEGEN_COMPILER" <"$probe" >"$out" 2>"$err"',
            '    (cd $cdir && $NATIVE_CODEGEN_COMPILER < $probe)',
            '    ( cd "$cdir" && "${NATIVE_CODEGEN_COMPILER}" <"$probe" )',
            '    ( cd "$nd" && "$tmp/self_compiler.elf" "$extra" <"$probe" )',
            '    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" <<<"$source" )',
            '    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" \\\n        <"$probe" >"$out" 2>"$err" )',
            # stdin before the compiler word or after other redirections (review R2),
            # through process substitution, on a group, or from a pipe
            '    ( cd "$cdir" && <"$probe_file" "$NATIVE_CODEGEN_COMPILER" >"$out_file" 2>"$err_file" )',
            '    <"$src" "$NATIVE_CODEGEN_COMPILER" >"$out" 2>"$err"',
            '    ( cd "$cdir" && <src "$C" >out 2>err )',
            '    ( cd "$cdir" && "$PROBE_COMPILER" >"$out" <"$probe" )',
            '    ( cd "$g2d" && 2>"$err" <"$backend" timeout "$fix_timeout" "$tmp/self_compiler.elf" >"$out" )',
            '    ( cd "$cdir" && <"$probe" timeout "$bound" "$PROBE_COMPILER" )',
            '    "$NATIVE_CODEGEN_COMPILER" "$(printf x)" <"$probe"',
            '    "$NATIVE_CODEGEN_COMPILER" >"$out" 2>"$err" <"$probe"',
            '    "$be_elf" 0<"$probe" >"$out"',
            '    out=$( <"$probe" "$NATIVE_CODEGEN_COMPILER" )',
            '    "$NATIVE_CODEGEN_COMPILER" < <(printf \'%s\\n\' "$source")',
            '    { "$NATIVE_CODEGEN_COMPILER"; } <"$probe" >"$out"',
            '    ( "$NATIVE_CODEGEN_COMPILER" ) <"$probe"',
            '    cat "$probe" | "$NATIVE_CODEGEN_COMPILER" >"$out"',
            # a < with no blank before it (review2 R2), including after the timeout bound
            '    ( cd "$cdir" && $NATIVE_CODEGEN_COMPILER<"$probe_file" >"$out_file" 2>"$err_file" )',
            '    ( cd "$cdir" && >compile.log<"$probe_file" "$NATIVE_CODEGEN_COMPILER" 2>"$err_file" )',
            '    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" >compile.log<"$probe_file" 2>"$err_file" )',
            '    ( cd "$cdir" && timeout "$bound"<"$probe" "$PROBE_COMPILER" )',
            # digits in the census subshell's variable name
            '    ( cd "$cdir" && <"$probe_file" "$PROBE_COMPILER_2" )',
            '    ( cd "$cdir" && <"$probe_file" "${PROBE_COMPILER_2}" )',
            # a raw census subshell after a clean one on the same line
            '    ( cd "$cdir" && "$X" >out ); ( cd "$cdir" && <src "$C" >out )',
            '    ( cd "$cdir" && "$X" >first-output ); ( cd "$cdir" && <"$probe_file" "$C" )',
            # a backslash-newline inside a word, which bash removes without leaving a blank
            '    ( cd "$cdir" && $NATIVE_CODEGEN_\\\nCOMPILER <"$probe_file" )',
            '    ( cd "$cdir" && <"$probe_file" "$PROBE_\\\nCOMPILER_2" )',
        ]
        clean = [
            '    # ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" <"$probe" >"$out" 2>"$err" )',
            '    native_codegen_compile_success "$NATIVE_CODEGEN_COMPILER" "$probe" "$cdir" "$PATH" "$bound" || return 1',
            '    gen1_size=$(wc -c <"$tmp/self_compiler.elf")',
            '    if ! "$elf" <"$rt" >"$actual" 2>/dev/null; then',
            '''    [[ -f "$NATIVE_CODEGEN_COMPILER" ]] && magic=$(head -c4 "$NATIVE_CODEGEN_COMPILER" | xxd -p | tr -d '\\n')''',
            '    native_codegen_compile_success "$NATIVE_CODEGEN_COMPILER" "$probe" "$cdir" || fail_test "$(head -1 <"$cdir/compile.err")"',
            '    native_codegen_compile_success "$be_elf" "$probe" "$cdir" || fail_test "$(<"$cdir/compile.err")"',
            '    fail_test "gen1_size=$(wc -c <"$tmp/self_compiler.elf") gen2_size=$(wc -c <"$g2d/a.out")"',
            '    gen1_size=$(wc -c<"$tmp/self_compiler.elf")',
        ]
        for line in planted + clean:
            with self.subTest(planted=line):
                text = '\n'.join(host[:anchor + 1] + [line] + host[anchor + 1:]) + '\n'
                hits = raw_success_compiles(text)
                if line in planted:
                    self.assertEqual([number for number, _ in hits], [anchor + 2], hits)
                else:
                    self.assertEqual(hits, [])

    def test_ambient_overrides_refused_before_grading(self):
        # Every ambient override run_tests.sh refuses, each set to a value its own check
        # rejects. --check-pinned exits before the suite runs, so no gate or compile starts
        # even if a refusal is lost; the golden hash shows no refusal path rewrote it.
        refused = dict.fromkeys((
            'NATIVE_CODEGEN_GOLDENS_DIR', 'NATIVE_CODEGEN_MANIFEST', 'NATIVE_CODEGEN_ORACLE_CAPTURE',
            'NATIVE_CODEGEN_CAPTURE_MANIFEST', 'NATIVE_CODEGEN_ALLOW_C_MINT',
            'ERROR_VOCAB_CAPTURE', 'ERROR_VOCAB_FRAGMENT'), '1')
        refused['NATIVE_CODEGEN_ORACLE'] = 'c'
        clean = {k: v for k, v in os.environ.items() if k not in refused}
        golden = ROOT/'stack/error_probes_native.expected'
        before = hashlib.sha256(golden.read_bytes()).hexdigest()
        suite = ['bash', str(TESTS/'run_tests.sh'), '--check-pinned']
        control = subprocess.run(suite, env=clean, capture_output=True, timeout=20)
        self.assertEqual(control.returncode, 0, (control.stdout, control.stderr))
        self.assertIn(b'OK: 16 pinned proof scripts present + executable', control.stdout)
        for name, value in refused.items():
            with self.subTest(entrypoint='run_tests.sh', name=name):
                r = subprocess.run(suite, env=dict(clean, **{name: value}), capture_output=True, timeout=20)
                self.assertEqual(r.returncode, 1, (r.stdout, r.stderr))
                self.assertIn(b'Refusing', r.stdout)
                self.assertIn(name.encode(), r.stdout)
                self.assertNotIn(b'pinned proof scripts present', r.stdout)
                self.assertEqual(hashlib.sha256(golden.read_bytes()).hexdigest(), before)

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
            raise RuntimeError('reseed invocation tests require a host C compiler (cc) to build their stand-in compiler')
        image = directory/'protocol'
        result = subprocess.run([compiler, '-std=c99', '-O0', str(source), '-o', str(image)],
                                capture_output=True, timeout=30)
        if result.returncode != 0:
            raise RuntimeError(f'cannot build reseed invocation fixture: {result.stderr!r}')
        cls.image = image.read_bytes()

    CANDIDATE_GATES = (
        ('check_hosted_memory_io', 'hosted memory/I/O: 84 checks passed',
         "AssertionError: controlled-probe: expected b'', got b'unexpected'"),
        ('check_wordcount', 'wordcount: 11 cases passed; runtime checks 0.00s; stack limit 8388608 bytes',
         "AssertionError: expected b'', got b'unexpected'"),
        ('check_stack_headroom', 'stack-headroom: 4/4 passed at 8192 KB stack',
         'stack-headroom: 1 of 4 cases failed'))

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
        # The three candidate gates the recipe runs after conformance. Each
        # checks the same candidate and that it is not yet the seed, records its
        # call and ends with one line in the real script's shape;
        # RESEED_TEST_FAIL_GATE names the one that fails.
        for gate, passed, failed in self.CANDIDATE_GATES:
            (tests/f'{gate}.py').write_text(f'''import os, sys
from pathlib import Path
root = Path(__file__).resolve().parents[2]
candidate = Path(sys.argv[2])
if sys.argv[1] != '--compiler' or candidate.read_bytes() != Path(os.environ['RESEED_TEST_NEXT']).read_bytes():
    raise SystemExit('wrong candidate passed to {gate}')
if (root/'bootstrap/seed/gen1.seed').read_bytes() == candidate.read_bytes():
    raise SystemExit('seed published before {gate}')
with Path(os.environ['RESEED_TEST_GATE_CALLS']).open('a') as f: f.write('{gate}\\n')
if os.environ.get('RESEED_TEST_FAIL_GATE') == '{gate}':
    print({failed!r}, file=sys.stderr)
    raise SystemExit(1)
print({passed!r})
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
                   RESEED_TEST_GATE_RECEIPT=str(directory/'gate'), RESEED_TEST_GATE_CALLS=str(directory/'gates'))
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

    def test_failing_candidate_gate_refuses_before_publication(self):
        gates = [gate for gate, _, _ in self.CANDIDATE_GATES]
        for index, (gate, _, failed) in enumerate(self.CANDIDATE_GATES):
            with self.subTest(gate=gate), tempfile.TemporaryDirectory() as d:
                script, env, inputs = self.prepare(Path(d), changed=True)
                env['RESEED_TEST_FAIL_GATE'] = gate
                result = self.invoke(script, env)
                work = self.retained(result, env, inputs); self.unchanged(inputs)
                self.assertEqual(Path(env['RESEED_TEST_CALLS']).read_text(), 'gen1\ngen2\n')
                self.assertEqual(Path(env['RESEED_TEST_GATE_RECEIPT']).read_text(),
                                 hashlib.sha256(Path(env['RESEED_TEST_NEXT']).read_bytes()).hexdigest())
                self.assertIn(b'controlled candidate conformance pass', result.stdout)
                self.assertEqual(Path(env['RESEED_TEST_GATE_CALLS']).read_text(), ''.join(g + '\n' for g in gates[:index + 1]))
                self.assertIn(f'candidate {gate} failed; seed unchanged'.encode(), result.stderr)
                self.assertIn(failed.encode(), result.stderr)
                self.assertEqual((work/f'{gate}.log').read_text(), failed + '\n')
                for later in gates[index + 1:]:
                    self.assertFalse((work/f'{later}.log').exists(), later)
                self.assertNotIn(b'inputs changed during qualification', result.stderr)
                seed = next(iter(inputs))
                self.assertFalse(list(seed.parent.glob('.reseed.*')))

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
