#!/usr/bin/env python3
"""Bite proof: xvfb-run's own diagnostics never reach a graded Bochs capture.

FLAKE-LOG F12. The real shared harness (bochs_f2_harness.sh: f2_bochs_leg,
f2__boot and its load guard) and the real binary-safe frame parser run against
controlled host-command stubs. The wrapper's stub keeps the real xvfb-run's
stream topology in both packaged routings of the wrapped command's stderr:
merge (xvfb 2:21.1.12-1ubuntu1.8, `"$@" 2>&1` at /usr/bin/xvfb-run:184) and
no-merge (xvfb 2:21.1.22-1ubuntu1.2, `"$@" 3>&-` at :200). In both, the
wrapper's own error() goes to its stderr. The Bochs stand-in writes guest bytes
on stdout and its exit banner on stderr, as real Bochs does. A stub that
printed its error on stdout would make both harness versions RED and prove
nothing. No emulator, mount, privileged command or compiler runs; the
real-Bochs kernel matrix remains a separate qualification.

Every leg row runs under both routings, on this tree's harness (TREE) and on a
copy whose kernel_xvfb_capture call is restored to the pre-fix line (LEGACY);
TREE must give byte-identical captures and side files under both. The LEGACY
column is a permanent mutation proof. Reverting that one line brings back the
false RED seen on link41/44/46 on 2026-09-28, while a wrong guest answer and
unknown emulator-side text stay RED in both columns. A third column
(UNSHIMMED) runs this tree's harness with the helper's exec shim removed, which
is 9c7004f's helper: GREEN under merge, and under no-merge the NO-SHUTDOWN
re-rolls and HARNESS-ERROR of GitHub run 36493751576. The helper's argument
split and the command line of the process it leaves running are checked too.

Row J is a static census of the tracked files, Markdown documents aside: it
fails on a literal direct call of the wrapper anywhere but inside
kernel_xvfb_capture (kernel_evidence.sh), the one sanctioned call, in the
shell and Python forms listed above CENSUS_INVOCATION. A reverted or copied
inline boot in one of those forms therefore goes RED. Row J-census-planted
proves each shell form on a real gate file. The census is a guard for those
forms, not proof that no direct call exists: one made through a variable,
alias or function, or kept in an untracked file, is not seen.
"""
if not __debug__:
    raise SystemExit('verification requires Python assertions; remove -O/-OO and PYTHONOPTIMIZE')

import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time


HERE = Path(__file__).resolve().parent
HARNESS = HERE / 'bochs_f2_harness.sh'
HELPER = HERE / 'kernel_evidence.sh'
# Assembled by concatenation so a scan for direct wrapper invocations never
# matches this file.
WRAPPER = 'xvfb-' + 'run'
ROUTINGS = ('merge', 'no-merge')
TREE_LINE = ('      kernel_xvfb_capture bochs_out.txt -a bash -c '
             '"yes c | timeout -s KILL ${tmo} bochs -q -f bochsrc.txt" )\n')
LEGACY_LINE = ('      ' + WRAPPER + ' -a bash -c '
               '"yes c | timeout -s KILL ${tmo} bochs -q -f bochsrc.txt" > bochs_out.txt 2>&1 )\n')
# The helper's wrapper call, and the same call with its exec shim removed
# (9c7004f's helper, which left the merge to xvfb-run).
SHIM_LINE = ('    ' + WRAPPER + ' "${options[@]}" sh -c \'exec "$@" 2>&1\' kernel_xvfb_capture "$@" '
             '> "$capture" 2> "$side" || rc=$?\n')
UNSHIMMED_LINE = '    ' + WRAPPER + ' "${options[@]}" "$@" > "$capture" 2> "$side" || rc=$?\n'
CLEANUP_ERROR = WRAPPER + ': error: problem while cleaning up temporary directory\n'
XAUTH_MISSING = WRAPPER + ': error: xauth command not found\n'
YES_LINE = b'yes: standard output: Broken pipe\n'
UNKNOWN_LINE = b'bochs: unexpected diagnostic\n'
# An emulator that cannot open its display and exits before booting. The
# message is the string in Bochs's X GUI plugin (libbx_x_gui.so); the banner
# framing is illustrative. What matters is that no shutdown marker follows.
STARTUP_ERROR = (b'=' * 72 + b'\nBochs is exiting with the following message:\n'
                 b'[XGUI  ] Cannot connect to X display\n' + b'=' * 72 + b'\n')
# The shutdown tail of the failing link41 capture (b.cy, 2026-09-28) without
# the wrapper's line: Bochs's exit banner and one debugger line.
BOCHS_TAIL = (b'=' * 72 + b'\nBochs is exiting with the following message:\n'
              b'[UNMAP ] Shutdown port: shutdown requested\n' + b'=' * 72 + b'\n'
              b'(0).[457765977] [0x00000010603e] 0008:000000000010603e (unk. ctxt): '
              b'out dx, al                ; ee\n')
SIDE = 'bochs_out.txt.xvfb-run.stderr'
EXIT = 'bochs_out.txt.xvfb-run.exit'
PARSE_ERROR = 'holler malformed/truncated debugcon record at byte 0 of'
WRONG_ANSWER = 'answer de01ad != de00ad'

# Row J, the census. It scans every tracked file in the repository except
# Markdown documents (git ls-files; without git the row fails closed), one
# line at a time. It skips full-line comments (first non-blank character '#',
# in shell, Python and embedded stub text alike), the body of
# kernel_xvfb_capture() in kernel_evidence.sh (the sanctioned call), and a
# name that directly follows an availability probe (`command -v`,
# `command -V`, `type`, `which`). Anywhere else the wrapper's name counts as an
# invocation when it is
#   1. bare or at the end of a path (NAME, /usr/bin/NAME, \NAME), or
#   2. quoted as one whole word, a path included ("NAME", 'NAME', $'NAME',
#      "/usr/bin/NAME"),
# and is followed by
#   - blanks and the start of an argument word: a letter, digit, '_', quote,
#     '$', '/', '.', '~', '{', '\', '`' or '-' (after a quoted name, not the
#     Python words and, or, not, in, is, if, else, for, which no wrapper call
#     has as its command); this covers the scope's pre-registered predicate,
#     \bNAME\s+-;
#   - a redirection, with or without blanks: NAME > CAP 2>&1 -a ...,
#     NAME>CAP ..., NAME < /dev/null ..., NAME &> CAP ...;
#   - a backslash that continues the line: NAME \, NAME\, "NAME" \;
# or, in Python, it is 3. one argv element followed on the same line by an
# option: ['NAME', '-a', ...]. Whatever comes before the name is irrelevant,
# so assignments, env, command, exec, timeout, sudo, leading redirections, a
# subshell, a brace group, a pipeline or a command substitution around the
# call do not hide it. A pipe, list operator, parenthesis or comment right
# after the name is not an argument: a bare name has no command to run.
# The census guards these literal forms and no others. It does not see a call
# through a variable, alias or function, or through a path computed at run
# time ("$(command -v NAME)"); a name split or glued by quoting or by a line
# continuation inside it; a Python argv whose next element is not an option
# or that is split across lines; a name built by concatenation (as this file
# builds it); a file that is not tracked; or a Markdown document. Each shell
# shape in CENSUS_SHAPES is run once against a stub wrapper, so it is known to
# invoke it, and planted in a scratch copy of a real gate file, where the
# census must name it (row J-census-planted). A real-Bochs matrix's capture
# grep sees a missed call only on a boot where the wrapper's intermittent
# error happens to occur.
_NAME = re.escape(WRAPPER)
_ARGUMENT = r'''[\w"'$/.~{\\`-]'''
_REDIRECT = r'\s*(?:[<>]|&>)'
_CONTINUED = r'\s*\\\r?$'
_PYTHON_WORD = r'(?:and|or|not|in|is|if|else|for)\b'
CENSUS_INVOCATION = re.compile(
    r'\b' + _NAME + r'(?:\s+' + _ARGUMENT + '|' + _REDIRECT + '|' + _CONTINUED + ')'
    + r'''|(["'])(?:[^"']*/)?''' + _NAME + r'\1(?:\s+(?!' + _PYTHON_WORD + ')' + _ARGUMENT
    + '|' + _REDIRECT + '|' + _CONTINUED + ')'
    + r'|\b' + _NAME + r'''["']\s*,\s*[rRbBuUfF]*["']-''')
CENSUS_PROBE = re.compile(r'''\b(?:command\s+-[vV]|type(?:\s+-[a-zA-Z]+)*|which)\s+\$?["']?(?:[^\s"']*/)?$''')
HELPER_FILE = 'bootstrap/tests/kernel_evidence.sh'
HELPER_OPEN = 'kernel_xvfb_capture() {'
# The rule's own bite proof: each line must be flagged outside the helper's
# body, and none of the clean ones anywhere.
CENSUS_FLAGGED = tuple(line.replace('NAME', WRAPPER) for line in (
    '      NAME -a bash -c "yes c | timeout -s KILL 90 bochs -q -f bochsrc.txt" > bochs_out.txt 2>&1 )',
    '    ( cd "$d"; rm -f disk.img.lock; NAME -a bash -c "yes c | bochs -q -f $d/b.txt" > "$logf" 2>&1 )   # note',
    'NAME bash -c "bochs -q -f bochsrc.txt" > bochs_out.txt 2>&1',
    'exec /usr/bin/NAME --auto-servernum bochs -q',
    'timeout 300 NAME -a bochs -q',
    '"NAME" -a bochs -q',
    "subprocess.run(['NAME', '-a', 'bochs'])",
    'subprocess.run("NAME -a bochs -q", shell=True)',
    '    NAME "$@" > "$capture" 2> "$side" || rc=$?',
    '    NAME \\',
    '    "NAME" \\',
    '"NAME" bash -c "printf GUEST" > capture.txt 2>&1',
    'NAME > capture.txt 2>&1 -a bash -c "printf GUEST"',
    "'/usr/bin/NAME' \"${command[@]}\"",
    'NAME `command -v bochs` -q -f bochsrc.txt',
    '    NAME\\',
    'command -v NAME >/dev/null && NAME -a bochs -q',
))
CENSUS_CLEAN = tuple(line.replace('NAME', WRAPPER) for line in (
    '    && command -v NAME >/dev/null 2>&1 && sudo -n true 2>/dev/null; }',
    'command -v NAME 2>/dev/null || exit 1',
    '    # NAME -a bash -c "..." > bochs_out.txt 2>&1 merged the wrapper\'s stderr',
    'fail_test "Bochs required but bochs/parted/grub-install/NAME/sudo not available"',
    '    side="$capture.NAME.stderr"',
    'needed = ("bochs", "grub-install", "NAME", "sudo")',
    'assert b"NAME" not in capture',
    'CLEANUP_ERROR = "NAME: error: problem while cleaning up temporary directory\\n"',
    'executable(tools / "NAME", STUB)',
    'if "NAME" in line and tool == "NAME" or tool is None:',
    'command -v "NAME" >/dev/null 2>&1',
    'type -P NAME > /dev/null || which NAME>/dev/null || command -V /usr/bin/NAME >/dev/null',
    '    # NAME > bochs_out.txt 2>&1 -a bash -c "..." (redirections first)',
    '"""Bite proof: NAME\'s own diagnostics never reach a graded Bochs capture.',
    '    printf \'%s\\n\' "$rc" > "$capture.NAME.exit"',
    'merge (xvfb 2:21.1.12-1ubuntu1.8, `"$@" 2>&1` at /usr/bin/NAME:184) and',
))
# Shell invocation shapes for the planted mutants (J-census-planted). Each is
# run once under bash with CMD = bash -c "printf GUEST" and a stub wrapper
# first on PATH (BIN = ./bin), which must run and write GUEST into CAP; then it
# replaces a real call site in a scratch copy of its gate file (BIN =
# /usr/bin, and that site's own capture and inner command), which must still
# pass bash -n, and the census must name exactly the line that holds the name.
CENSUS_SHAPES = (
    ('pre-fix-line', 'NAME -a CMD > CAP 2>&1'),
    ('no-option', 'NAME CMD > CAP 2>&1'),
    ('double-quoted-name', '"NAME" -a CMD > CAP 2>&1'),
    ('single-quoted-name', "'NAME' -a CMD > CAP 2>&1"),
    ('ansi-c-quoted-name', "$'NAME' -a CMD > CAP 2>&1"),
    ('quoted-name-no-option', '"NAME" CMD > CAP 2>&1'),
    ('quoted-path-no-option', '"BIN/NAME" CMD > CAP 2>&1'),
    ('path', 'BIN/NAME -a CMD > CAP 2>&1'),
    ('escaped-name', '\\NAME -a CMD > CAP 2>&1'),
    ('redirect-before-arguments', 'NAME > CAP 2>&1 -a CMD'),
    ('glued-redirect-before-arguments', 'NAME>CAP 2>&1 -a CMD'),
    ('stderr-redirect-before-arguments', 'NAME 2>&1 >CAP -a CMD'),
    ('both-streams-redirect-before-arguments', 'NAME &>CAP -a CMD'),
    ('input-redirect-before-arguments', 'NAME </dev/null >CAP 2>&1 -a CMD'),
    ('quoted-name-redirect-before-arguments', '"NAME" >CAP 2>&1 CMD'),
    ('redirections-before-name', '>CAP 2>&1 NAME -a CMD'),
    ('assignment-prefix', 'LC_ALL=C NAME -a CMD > CAP 2>&1'),
    ('env-prefix', 'env LC_ALL=C NAME -a CMD > CAP 2>&1'),
    ('command-prefix', 'command NAME -a CMD > CAP 2>&1'),
    ('exec-prefix', 'exec NAME -a CMD > CAP 2>&1'),
    ('timeout-prefix', 'timeout 300 NAME -a CMD > CAP 2>&1'),
    ('brace-group', '{ NAME -a CMD; } > CAP 2>&1'),
    ('pipeline', 'NAME -a CMD 2>&1 | cat > CAP'),
    ('command-substitution', 'printf %s "$(NAME -a CMD 2>&1)" > CAP'),
    ('continuation', 'NAME \\\n          -a CMD > CAP 2>&1'),
    ('glued-continuation', 'NAME\\\n          -a CMD > CAP 2>&1'),
    ('quoted-name-continuation', '"NAME" \\\n          -a CMD > CAP 2>&1'),
    ('continuation-before-name', 'LC_ALL=C \\\n          NAME -a CMD > CAP 2>&1'),
)
# A converted call site: kernel_xvfb_capture CAPTURE -a bash -c "INNER".
CENSUS_CALL = re.compile(r'^(?P<pre>.*?)kernel_xvfb_capture (?P<cap>"[^"]*"|[^\s"]+) -a '
                         r'(?P<cmd>bash -c "(?:[^"\\]|\\.)*")(?P<post>.*)$')
CENSUS_STUB = '''#!/bin/bash
# Census stand-in: records that it ran, then runs the command after -a.
printf 'ran\\n' >> "$CENSUS_STUB_LOG"
if [[ "${1-}" == -a ]]; then shift; fi
exec "$@"
'''

SUDO = r'''#!/bin/bash
# Disk-build stand-in: no privilege, no loop device, no mount.
case "$1" in
    losetup) if [[ "$2" == -fP ]]; then : > "$PWD/loop0p1" || exit 1; echo "$PWD/loop0"; fi; exit 0 ;;
    mkfs.vfat|mount|umount|grub-install) exit 0 ;;
    mkdir|cp|tee) exec "$@" ;;
esac
echo "unexpected privileged command in the capture test: $*" >&2
exit 97
'''

XVFB_RUN = r'''#!/bin/bash
# Mirrors /usr/bin/xvfb-run for each mode used here, in the routing of the
# wrapped command's stderr that XVFB_ROUTING names:
#   merge: xvfb 2:21.1.12-1ubuntu1.8 (Ubuntu 24.04) runs the command as
#     `"$@" 2>&1` (line 184), so its stdout AND stderr go to this process's
#     stdout.
#   no-merge: xvfb 2:21.1.22-1ubuntu1.2 (Ubuntu 26.04, GitHub's ubuntu-26.04
#     runner) runs it as `"$@" 3>&-` (line 200), so its stdout goes to this
#     process's stdout and its stderr to this process's stderr.
# The two scripts are identical through line 141 except where xauth and kill
# send their output (lines 82 and 91); the later one inserts an fd-3 block at
# lines 142-157, so its later lines are 16 higher. Numbers below are
# 21.1.12/21.1.22 where they differ. In both, the wrapper's own error() goes
# to its stderr (lines 35-37). The harness always passes -a, which sets
# AUTONUM (line 110).
#   clean: the command runs, its status is returned (lines 182-189/198-205);
#     the EXIT trap's cleanup succeeds silently (lines 80-93).
#   cleanup-error, cleanup-error-leak: the command runs, then the EXIT trap's
#     failed rm -r prints the error and exits 5 (lines 84-88) before the kill
#     that would stop the server (lines 90-92).
#   xauth-missing: a pre-command failure. xauth is not found, so the wrapper
#     prints the error and exits 3 (lines 137-140), before the EXIT trap is set
#     (line 143/159), before any server starts and before the command runs.
#   start-exhausted: every Xvfb start fails. With -a each failure takes the
#     `continue` at lines 171-175/187-191, so the error at lines 177-179/193-195
#     is skipped; after ten tries the loop ends and the command runs anyway
#     (line 184/200), with no wrapper diagnostic. The EXIT trap then kills the
#     last, dead server PID (line 91); that kill's stderr goes to ERRORFILE
#     (/dev/null, line 15; through fd 3 in 21.1.22), and set -e (line 186/202)
#     turns its failure into status 1 whatever the command returned. Without -a
#     the first failure prints the error and exits 1 before the command runs
#     (lines 177-179/193-195).
# XVFB_ARGV_LOG, when set, records each call's arguments (argument-split rows).
[[ -z "${XVFB_ARGV_LOG:-}" ]] || printf '%s\n' "$*" >> "$XVFB_ARGV_LOG"
case "${XVFB_ROUTING:-}" in
    merge|no-merge) ;;
    *) echo "WRAPPER stub: unknown XVFB_ROUTING '${XVFB_ROUTING:-}'" >&2; exit 98 ;;
esac
autonum=
while [[ "${1:-}" == -a || "${1:-}" == --auto-servernum ]]; do autonum=yes; shift; done
if [[ "${XVFB_MODE:-}" == xauth-missing ]]; then
    echo 'WRAPPER: error: xauth command not found' >&2
    exit 3
fi
if [[ "${XVFB_MODE:-}" == start-exhausted && -z "$autonum" ]]; then
    echo 'WRAPPER: error: Xvfb failed to start' >&2
    exit 1
fi
if [[ "${XVFB_MODE:-}" == cleanup-error-leak ]]; then
    # Stands in for the server the real trap leaks: named Xvfb, cwd = the boot
    # directory. It ends itself once the test releases it; nothing signals it.
    "$FAKE_XVFB" "$FAKE_XVFB_RELEASE" < /dev/null > /dev/null 2>&1 &
    printf '%s\n' "$!" > "$FAKE_XVFB_PIDFILE"
fi
if [[ "$XVFB_ROUTING" == merge ]]; then
    "$@" 2>&1
else
    "$@" 3>&-
fi
rc=$?
if [[ "${XVFB_MODE:-}" == cleanup-error* ]]; then
    echo 'WRAPPER: error: problem while cleaning up temporary directory' >&2
    exit 5
fi
if [[ "${XVFB_MODE:-}" == start-exhausted ]]; then
    exit 1
fi
exit "$rc"
'''.replace('WRAPPER', WRAPPER)

BOCHS = f'''#!/usr/bin/env python3
# Real Bochs writes the guest's port-e9 bytes on stdout and its own log lines
# and exit banner ("... shutdown requested") on stderr: on GitHub's
# ubuntu-26.04 runner (run 36493751576) the banner was missing from every
# capture and Bochs's startup log lines were in xvfb-run's stderr. Which stream
# carries the debugger line after the banner is not established; here it goes
# with the banner. Each write is flushed before the other stream is written,
# so a merged capture keeps write order.
import os
from pathlib import Path
import sys
if not Path('bochsrc.txt').is_file():
    sys.exit('bochs stand-in: f2__boot wrote no bochsrc.txt')
out, err = sys.stdout.buffer, sys.stderr.buffer
def emit(stream, data):
    stream.write(data)
    stream.flush()
if os.environ.get('EMULATOR_EXTRA') == 'startup-error':
    emit(err, {STARTUP_ERROR!r})
    sys.exit(1)
emit(err, b'controlled Bochs stand-in preamble\\n')
emit(out, b'\\x9c\\xde' + bytes.fromhex(os.environ['GUEST_ANSWER']) + b'\\xad')
emit(err, {BOCHS_TAIL!r})
if os.environ.get('EMULATOR_EXTRA') == 'unknown-stdout':
    emit(out, {UNKNOWN_LINE!r})
if os.environ.get('EMULATOR_EXTRA') == 'wrapped-stderr':
    emit(err, {YES_LINE!r})
sys.exit(1)   # real Bochs exits 1 after "shutdown requested"
'''

FAKE_XVFB = r'''#!/bin/bash
# Test stand-in for a leaked server (comm "Xvfb"). It ends itself.
while [[ ! -e "$1" ]] && (( SECONDS < 60 )); do sleep 0.05; done
'''

GRADER = r'''import os
import sys
sys.path.insert(0, os.environ['TEST_SCRIPTS'])
import debugcon_frames
raw = debugcon_frames.extract_bochs(open(sys.argv[1], 'rb').read())
if raw[:1] != b'\x9c':
    sys.exit('no OWN-table boundary in the capture')
records = debugcon_frames.parse(raw[1:], 'holler', 0)   # an uncaught TraceError exits 1: RED
want = bytes.fromhex('de' + sys.argv[2] + 'ad')
if records[-1].raw != want:
    sys.exit(f'answer {records[-1].raw.hex()} != {want.hex()}')
'''

DRIVER = r'''set -u
unset CDPATH
if [[ "$TEST_PRELOAD" == 1 ]]; then
    source "$TEST_SCRIPTS/qemu_prefix.sh" || exit 96
fi
if [[ -n "${TEST_HELPER:-}" ]]; then   # a mutant helper, defined before the harness's load guard runs
    source "$TEST_HELPER" || exit 98
fi
source "$TEST_HARNESS" || exit 97
fail=0
fail_test() { echo "FAIL: $1"; fail=$((fail + 1)); }
grade() { # LOG WANT -- as the gates grade: the binary-safe parser decides; RED reports FAIL
    local out
    if out="$(python3 "$TEST_GRADER" "$1" "$2" 2>&1)"; then return 0; fi
    fail_test "probe Bochs grade RED -> ${out##*$'\n'}"
    return 1
}
case "$TEST_MODE" in
    leg)
        f2_bochs_leg probe grade "$TEST_OUT/probe.log" "$TEST_CFG" 30 32 "$TEST_FIX/kernel.elf:boot/kernel.elf" -- "$TEST_WANT"
        rc=$?
        f2_harness_summary || exit 1
        [[ $rc -eq 0 && $fail -eq 0 ]] || exit 1
        echo "GREEN probe"
        ;;
    boot)   # a direct call, as check_boot_input.py makes it; there the status is graded too
        f2__bios_find || exit 90
        W="$TEST_OUT/boot"
        mkdir -- "$W" || exit 91
        f2__disk_build_class "$W" "$TEST_CFG" "$TEST_FIX/kernel.elf:boot/kernel.elf" || exit 92
        f2__boot "$W" 30 32 ""
        echo "boot_rc=$?"
        ;;
    *) exit 95 ;;
esac
'''

FAILURES = []


def expect(label, condition, detail):
    if not condition:
        FAILURES.append(f'{label}: {detail}')
        print(f'FAIL {label}: {detail}', flush=True)
    return bool(condition)


def executable(path, text):
    path.write_text(text)
    path.chmod(0o755)


def sha(data):
    return hashlib.sha256(data).hexdigest() if data is not None else None


class Bench:
    def __init__(self, root):
        self.root = root
        tools = root / 'tools'
        tools.mkdir()
        executable(tools / 'sudo', SUDO)
        executable(tools / 'dd', '#!/bin/bash\nprintf disk-fixture > disk.img\n')
        executable(tools / 'parted', '#!/bin/bash\nexit 0\n')
        executable(tools / 'find', '#!/bin/bash\necho "/nonexistent-test-bios/$3"\n')
        executable(tools / 'yes', '#!/bin/bash\nexit 0\n')
        executable(tools / 'bochs', BOCHS)
        executable(tools / WRAPPER, XVFB_RUN)
        leak = root / 'leak'
        leak.mkdir()
        executable(leak / 'Xvfb', FAKE_XVFB)
        self.fake_xvfb = leak / 'Xvfb'
        fixture = root / 'fixture'
        fixture.mkdir()
        (fixture / 'kernel.elf').write_bytes(b'\x7fELF controlled fixture')
        (root / 'grader.py').write_text(GRADER)
        self.driver = root / 'driver.sh'
        self.driver.write_text(DRIVER)
        env = {k: v for k, v in os.environ.items()
               if k not in ('KERNEL_EVIDENCE_DIR', 'KERNEL_PARSE_ERROR_FILE', 'QEMU_PREFIX',
                            'F2_GATE', 'BASH_ENV', 'ENV', 'CDPATH')}
        env.update(PATH=str(tools) + os.pathsep + os.environ['PATH'], PYTHONDONTWRITEBYTECODE='1',
                   TEST_SCRIPTS=str(HERE), TEST_GRADER=str(root / 'grader.py'),
                   TEST_FIX=str(fixture), TEST_WANT='00',
                   TEST_CFG='set timeout=0\nmenuentry "probe" {\n multiboot /boot/kernel.elf\n boot\n}\n')
        self.env = env

    def run(self, label, harness, *, routing, mode='leg', xvfb='clean', guest='00', extra='',
            preload=True, leak=None, helper=None):
        directory = self.root / label
        directory.mkdir()
        out = directory / 'out'
        out.mkdir()
        tmp = directory / 'tmp'
        tmp.mkdir()
        evidence = directory / 'evidence'
        env = dict(self.env, TEST_HARNESS=str(harness), TEST_MODE=mode, TEST_OUT=str(out),
                   TEST_PRELOAD='1' if preload else '0', XVFB_MODE=xvfb, GUEST_ANSWER=guest,
                   EMULATOR_EXTRA=extra, TMPDIR=str(tmp), XVFB_ROUTING=routing)
        if helper is not None:
            env['TEST_HELPER'] = str(helper)
        if mode == 'leg':
            env['KERNEL_EVIDENCE_DIR'] = str(evidence)
        if leak is not None:
            env.update(FAKE_XVFB=str(self.fake_xvfb), FAKE_XVFB_RELEASE=str(leak['release']),
                       FAKE_XVFB_PIDFILE=str(leak['pidfile']))
        try:
            result = subprocess.run(['bash', str(self.driver)], env=env, capture_output=True,
                                    timeout=120)
            rc, stdout, stderr = result.returncode, result.stdout, result.stderr
        except subprocess.TimeoutExpired as error:
            rc, stdout, stderr = 'timeout', error.stdout or b'', error.stderr or b''
        (directory / 'driver.stdout').write_bytes(stdout)
        (directory / 'driver.stderr').write_bytes(stderr)
        probe = out / 'probe.log'
        snapshots = []
        if evidence.is_dir():
            for capture in sorted(evidence.glob('capture-*')):
                inventory = json.loads((capture / 'INVENTORY.json').read_text())
                files = {row['path']: (capture / row['path']).read_bytes()
                         for row in inventory['files'] if row['retained']}
                snapshots.append(dict(source=inventory['source'], files=files,
                                      paths=sorted(row['path'] for row in inventory['files'])))
        boot = out / 'boot'
        return dict(label=label, rc=rc, stdout=stdout, stderr=stderr,
                    out_lines=stdout.decode(errors='replace').splitlines(),
                    err_lines=stderr.decode(errors='replace').splitlines(),
                    probe=probe.read_bytes() if probe.exists() else None,
                    snapshots=snapshots,
                    boot={p.name: p.read_bytes() for p in boot.iterdir() if p.is_file()}
                    if boot.is_dir() else {})


def notes(r):
    return [line for line in r['err_lines'] if line.startswith('HARNESS-NOTE:')]


def verdict(r, *, rc, fails, harness_errors, notes_count, fail_text=None, forbid_text=None):
    label = r['label']
    tail = f"stdout={r['out_lines'][-4:]} stderr={r['err_lines'][-4:]}"
    ok = expect(label, r['rc'] == rc, f"exit {r['rc']}, want {rc}; {tail}")
    failed = [line for line in r['out_lines'] if line.startswith('FAIL: ')]
    ok &= expect(label, len(failed) == fails, f'{len(failed)} FAIL: line(s), want {fails}: {failed}')
    errors = [line for line in r['out_lines'] if line.startswith('HARNESS-ERROR')]
    ok &= expect(label, len(errors) == harness_errors,
                 f'{len(errors)} HARNESS-ERROR line(s), want {harness_errors}: {errors}')
    ok &= expect(label, len(notes(r)) == notes_count,
                 f'{len(notes(r))} HARNESS-NOTE line(s) on stderr, want {notes_count}: {notes(r)}')
    ok &= expect(label, not any('HARNESS-NOTE' in line for line in r['out_lines']),
                 'a HARNESS-NOTE reached stdout (it would corrupt a class string)')
    if fail_text is not None:
        ok &= expect(label, failed and all(fail_text in line for line in failed),
                     f'FAIL line(s) lack {fail_text!r}: {failed}')
    if forbid_text is not None:
        ok &= expect(label, not any(forbid_text in line for line in failed),
                     f'FAIL line(s) contain {forbid_text!r}: {failed}')
    return ok


def one_snapshot(r):
    ok = expect(r['label'], len(r['snapshots']) == 1,
                f"{len(r['snapshots'])} attempt snapshot(s), want 1")
    return r['snapshots'][0] if ok else None


def side_free(r):
    return expect(r['label'], all(not any('.xvfb-run.' in path for path in s['paths'])
                                  for s in r['snapshots']),
                  f"a {WRAPPER} side file was retained on a path where {WRAPPER} wrote nothing")


def side_kept(r, snapshot, text, status, note):
    """The capture holds no wrapper bytes; the side file and status are retained; the note names them."""
    label = r['label']
    files = snapshot['files']
    ok = expect(label, WRAPPER.encode() not in files.get('bochs_out.txt', b'x' + WRAPPER.encode()),
                'the graded capture still holds wrapper bytes')
    ok &= expect(label, files.get(SIDE) == text.encode(), f'side file {files.get(SIDE)!r}, want {text!r}')
    ok &= expect(label, files.get(EXIT) == f'{status}\n'.encode(),
                 f'exit file {files.get(EXIT)!r}, want {status!r}')
    absolute = snapshot['source'] + '/' + SIDE
    ok &= expect(label, note is not None and f'exited {status} ' in note and absolute in note
                 and text.strip() in note,
                 f'note does not name status {status}, {absolute} and the diagnostic: {note!r}')
    return ok


def run_rows(bench, column, harness, rows, routing):
    tree = column == 'TREE'
    result = {}
    for name, xvfb, guest, extra in (('A-clean', 'clean', '00', ''),
                                     ('B-cleanup-error', 'cleanup-error', '00', ''),
                                     ('C-wrong-cleanup-error', 'cleanup-error', '01', ''),
                                     ('D-wrong-clean', 'clean', '01', ''),
                                     ('E-wrapped-stderr', 'clean', '00', 'wrapped-stderr'),
                                     ('G-unknown-emulator-text', 'clean', '00', 'unknown-stdout'),
                                     ('F-xauth-missing', 'xauth-missing', '00', ''),
                                     ('H-start-exhausted', 'start-exhausted', '00', 'startup-error')):
        result[name] = bench.run(f'{column}-{routing}-{name}', harness, routing=routing, xvfb=xvfb,
                                 guest=guest, extra=extra)
    a, b, c, d, e, g, f, h = (result[k] for k in ('A-clean', 'B-cleanup-error', 'C-wrong-cleanup-error',
                                                 'D-wrong-clean', 'E-wrapped-stderr',
                                                 'G-unknown-emulator-text', 'F-xauth-missing',
                                                 'H-start-exhausted'))
    ok = verdict(a, rc=0, fails=0, harness_errors=0, notes_count=0)
    ok &= expect(a['label'], a['probe'] and a['probe'].endswith(BOCHS_TAIL), f"probe.log {a['probe']!r}")
    ok &= side_free(a) and one_snapshot(a) is not None
    rows.append((a['label'], ok))

    if tree:
        ok = verdict(b, rc=0, fails=0, harness_errors=0, notes_count=1)
        ok &= expect(b['label'], b['probe'] == a['probe'],
                     'the graded capture differs from the clean boot (it must be byte-identical)')
        snapshot = one_snapshot(b)
        ok &= snapshot is not None and side_kept(b, snapshot, CLEANUP_ERROR, 5, (notes(b) or [None])[0])
    else:
        ok = verdict(b, rc=1, fails=1, harness_errors=0, notes_count=0, fail_text=PARSE_ERROR)
        ok &= expect(b['label'], b['probe'] and b['probe'].endswith(CLEANUP_ERROR.encode()),
                     'the pre-fix capture should end with the wrapper line')
    rows.append((b['label'], ok))

    if tree:
        ok = verdict(c, rc=1, fails=1, harness_errors=0, notes_count=1, fail_text=WRONG_ANSWER,
                     forbid_text='malformed')
        snapshot = one_snapshot(c)
        ok &= snapshot is not None and side_kept(c, snapshot, CLEANUP_ERROR, 5, (notes(c) or [None])[0])
    else:
        ok = verdict(c, rc=1, fails=1, harness_errors=0, notes_count=0, fail_text=PARSE_ERROR)
    rows.append((c['label'], ok))

    ok = verdict(d, rc=1, fails=1, harness_errors=0, notes_count=0, fail_text=WRONG_ANSWER)
    ok &= side_free(d)
    rows.append((d['label'], ok))

    ok = verdict(e, rc=0, fails=0, harness_errors=0, notes_count=0)
    ok &= expect(e['label'], e['probe'] and e['probe'].endswith(BOCHS_TAIL + YES_LINE),
                 "the wrapped command's stderr must still reach the capture")
    ok &= side_free(e)
    rows.append((e['label'], ok))

    ok = verdict(g, rc=1, fails=1, harness_errors=0, notes_count=0, fail_text=PARSE_ERROR)
    ok &= expect(g['label'], g['probe'] and UNKNOWN_LINE in g['probe'], 'unknown emulator text missing')
    ok &= side_free(g)
    rows.append((g['label'], ok))

    # A pre-command wrapper failure: the boot never ran. TREE keeps the capture
    # empty (NO-OUTPUT) and retains the diagnostic; LEGACY puts it in the
    # capture (NO-SHUTDOWN). Both exhaust their re-rolls and fail closed.
    rerolls = [line for line in f['err_lines'] if line.startswith('HARNESS re-roll:')]
    want_class = 'NO-OUTPUT' if tree else 'NO-SHUTDOWN'
    ok = verdict(f, rc=1, fails=0, harness_errors=2, notes_count=3 if tree else 0)
    ok &= expect(f['label'], len(rerolls) == 3 and all(f'= {want_class} ' in line for line in rerolls),
                 f'want three {want_class} re-rolls: {rerolls}')
    ok &= expect(f['label'], len(f['snapshots']) == 3, f"{len(f['snapshots'])} attempt snapshot(s), want 3")
    # Pad the notes so every snapshot is checked even when a note is missing.
    for snapshot, note in zip(f['snapshots'], (notes(f) if tree else []) + [None] * 3):
        if tree:
            ok &= expect(f['label'], snapshot['files'].get('bochs_out.txt') == b'',
                         'a boot that never ran must leave an empty capture')
            ok &= side_kept(f, snapshot, XAUTH_MISSING, 3, note)
        else:
            ok &= expect(f['label'], snapshot['files'].get('bochs_out.txt') == XAUTH_MISSING.encode(),
                         'the pre-fix capture should hold the xauth diagnostic')
    rows.append((f['label'], ok))

    # Every -a server start fails: xvfb-run runs the command anyway and writes
    # nothing of its own, so both columns see the same capture (the emulator's
    # startup error, no shutdown marker), the same class and no note.
    rerolls = [line for line in h['err_lines'] if line.startswith('HARNESS re-roll:')]
    ok = verdict(h, rc=1, fails=0, harness_errors=2, notes_count=0)
    ok &= expect(h['label'], len(rerolls) == 3 and all('= NO-SHUTDOWN ' in line for line in rerolls),
                 f'want three NO-SHUTDOWN re-rolls: {rerolls}')
    ok &= expect(h['label'], len(h['snapshots']) == 3, f"{len(h['snapshots'])} attempt snapshot(s), want 3")
    ok &= expect(h['label'], all(s['files'].get('bochs_out.txt') == STARTUP_ERROR for s in h['snapshots']),
                 'each capture must be exactly the emulator startup error: '
                 f"{[s['files'].get('bochs_out.txt') for s in h['snapshots']]}")
    ok &= side_free(h)
    rows.append((h['label'], ok))
    return result


def direct_boot(bench, column, harness, rows, preload, routing):
    clean = bench.run(f'{column}-{routing}-I-direct-clean', harness, routing=routing, mode='boot',
                      preload=preload)
    dirty = bench.run(f'{column}-{routing}-I-direct-cleanup-error', harness, routing=routing, mode='boot',
                      preload=preload, xvfb='cleanup-error')
    ok = expect(clean['label'], clean['rc'] == 0 and clean['out_lines'] == ['boot_rc=1'],
                f"want boot_rc=1: rc={clean['rc']} {clean['out_lines']} {clean['err_lines'][-3:]}")
    capture = clean['boot'].get('bochs_out.txt', b'')
    ok &= expect(clean['label'], b'shutdown requested' in capture and WRAPPER.encode() not in capture,
                 f'clean capture {capture!r}')
    ok &= expect(clean['label'], SIDE not in clean['boot'] and EXIT not in clean['boot'],
                 'side files left on the clean path')
    rows.append((clean['label'], ok))
    ok = expect(dirty['label'], dirty['rc'] == 0 and dirty['out_lines'] == ['boot_rc=5'],
                f"want boot_rc=5: rc={dirty['rc']} {dirty['out_lines']} {dirty['err_lines'][-3:]}")
    if column == 'TREE':
        ok &= expect(dirty['label'], dirty['boot'].get('bochs_out.txt') == capture,
                     'the capture differs from the clean boot')
        ok &= expect(dirty['label'], dirty['boot'].get(SIDE) == CLEANUP_ERROR.encode()
                     and dirty['boot'].get(EXIT) == b'5\n', f"side files {dirty['boot'].get(SIDE)!r}")
        ok &= expect(dirty['label'], len(notes(dirty)) == 1, f'notes {notes(dirty)}')
    else:
        ok &= expect(dirty['label'], dirty['boot'].get('bochs_out.txt', b'').endswith(CLEANUP_ERROR.encode()),
                     'the pre-fix capture should end with the wrapper line')
    rows.append((dirty['label'], ok))
    return dict(clean=clean, dirty=dirty)


def leak_report(bench, rows, routing):
    release = bench.root / f'leak-release-{routing}'
    pidfile = bench.root / f'leak-{routing}.pid'
    pid = None
    try:
        r = bench.run(f'TREE-{routing}-K-leak-report', HARNESS, routing=routing, xvfb='cleanup-error-leak',
                      leak=dict(release=release, pidfile=pidfile))
        ok = verdict(r, rc=0, fails=0, harness_errors=0, notes_count=1)
        pid = pidfile.read_text().strip() if pidfile.exists() else None
        note = (notes(r) or [''])[0]
        ok &= expect(r['label'], pid is not None and note.endswith(f'(not signalled): {pid}'),
                     f'note does not name the stand-in server {pid}: {note!r}')
        try:
            alive = Path(f'/proc/{pid}/comm').read_text() == 'Xvfb\n'
        except OSError:
            alive = False
        ok &= expect(r['label'], alive, 'the named server is gone; the helper must never signal it')
        rows.append((r['label'], ok))
    finally:
        release.write_text('release\n')
        deadline = time.monotonic() + 30
        while pid and Path(f'/proc/{pid}').exists() and time.monotonic() < deadline:
            time.sleep(0.05)


def load_guard(bench, rows):
    relocated = bench.root / 'relocated'
    relocated.mkdir()
    copy = relocated / HARNESS.name
    copy.write_text(HARNESS.read_text())
    probe = ('source "$1"; echo "rc=$?"; declare -F f2_harness_summary f2__boot >/dev/null && echo defined; '
             'declare -F kernel_xvfb_capture >/dev/null && echo helper')
    env = dict(bench.env)
    lone = subprocess.run(['bash', '-c', probe, 'guard', str(copy)], env=env, capture_output=True, timeout=30)
    ok = expect('TREE-L-load-guard-missing', lone.stdout == b'rc=1\ndefined\n'
                and b'HARNESS-ERROR: bochs_f2_harness.sh cannot load kernel_evidence.sh' in lone.stderr,
                f'a relocated harness without the helper must fail loudly: {lone.stdout!r} {lone.stderr!r}')
    rows.append(('TREE-L-load-guard-missing', ok))
    preloaded = subprocess.run(['bash', '-c', 'source "$2" || exit 9; ' + probe, 'guard', str(copy),
                                str(HERE / 'kernel_evidence.sh')], env=env, capture_output=True, timeout=30)
    ok = expect('TREE-L-load-guard-preloaded', preloaded.stdout == b'rc=0\ndefined\nhelper\n'
                and preloaded.stderr == b'', f'declare -F must be tested first: {preloaded.stdout!r} '
                f'{preloaded.stderr!r}')
    rows.append(('TREE-L-load-guard-preloaded', ok))
    alone = subprocess.run(['bash', '-c', probe, 'guard', str(HARNESS)], env=env, capture_output=True, timeout=30)
    ok = expect('TREE-L-load-guard-alone', alone.stdout == b'rc=0\ndefined\nhelper\n' and alone.stderr == b'',
                f'the harness sourced alone must load its helper: {alone.stdout!r} {alone.stderr!r}')
    rows.append(('TREE-L-load-guard-alone', ok))


def unshimmed_rows(bench, rows, routing, helper):
    """This tree's harness with the helper's exec shim removed (9c7004f's helper).

    Under merge it is GREEN, as it was on Ubuntu 24.04. Under no-merge Bochs's
    exit banner goes to the side file, so a correct guest re-rolls NO-SHUTDOWN
    three times and fails closed as HARNESS-ERROR, and a wrong guest is never
    graded: GitHub run 36493751576. If this column ever passes under no-merge,
    the stub no longer models that routing and the TREE rows prove nothing.
    """
    a = bench.run(f'UNSHIMMED-{routing}-A-clean', HARNESS, routing=routing, helper=helper)
    b = bench.run(f'UNSHIMMED-{routing}-B-cleanup-error', HARNESS, routing=routing, helper=helper,
                  xvfb='cleanup-error')
    d = bench.run(f'UNSHIMMED-{routing}-D-wrong-clean', HARNESS, routing=routing, helper=helper, guest='01')
    if routing == 'merge':
        ok = verdict(a, rc=0, fails=0, harness_errors=0, notes_count=0)
        ok &= expect(a['label'], a['probe'] and a['probe'].endswith(BOCHS_TAIL), f"probe.log {a['probe']!r}")
        rows.append((a['label'], ok))
        ok = verdict(b, rc=0, fails=0, harness_errors=0, notes_count=1)
        snapshot = one_snapshot(b)
        ok &= snapshot is not None and side_kept(b, snapshot, CLEANUP_ERROR, 5, (notes(b) or [None])[0])
        rows.append((b['label'], ok))
        rows.append((d['label'], verdict(d, rc=1, fails=1, harness_errors=0, notes_count=0,
                                         fail_text=WRONG_ANSWER)))
        return
    for r, status, trailer in ((a, 1, b''), (b, 5, CLEANUP_ERROR.encode()), (d, 1, b'')):
        rerolls = [line for line in r['err_lines'] if line.startswith('HARNESS re-roll:')]
        ok = verdict(r, rc=1, fails=0, harness_errors=2, notes_count=3)
        ok &= expect(r['label'], len(rerolls) == 3 and all('= NO-SHUTDOWN ' in line for line in rerolls),
                     f'want three NO-SHUTDOWN re-rolls: {rerolls}')
        ok &= expect(r['label'], len(r['snapshots']) == 3, f"{len(r['snapshots'])} attempt snapshot(s), want 3")
        ok &= expect(r['label'], all(f'exited {status} ' in note for note in notes(r)), f'notes {notes(r)}')
        for snapshot in r['snapshots']:
            files = snapshot['files']
            ok &= expect(r['label'], b'shutdown requested' not in files.get('bochs_out.txt', b'')
                         and files.get(SIDE, b'').endswith(BOCHS_TAIL + trailer)
                         and files.get(EXIT) == f'{status}\n'.encode(),
                         f"the shutdown banner should be in the side file, not the capture: {files.get('bochs_out.txt')!r} "
                         f'{files.get(SIDE)!r} {files.get(EXIT)!r}')
        rows.append((r['label'], ok))


def helper_cmdline(bench, rows, routing):
    """The shim execs: the process left running keeps the caller's own argv
    (scoped `pkill -f` patterns and bash's job reports see the same text), its
    parent is the wrapper itself, and its stdout and stderr both reach the capture
    in write order."""
    label = f'TREE-{routing}-N-cmdline'
    directory = bench.root / label
    directory.mkdir()
    inner = ('printf "OUT-1\\n"; printf "ERR-1\\n" >&2; '
             'cat /proc/$$/cmdline > "$FACTS/self"; cat /proc/$PPID/cmdline > "$FACTS/parent"; '
             'readlink /proc/$$/fd/1 /proc/$$/fd/2 > "$FACTS/fds"; '
             'printf "OUT-2\\n"; printf "ERR-2\\n" >&2; exit 7')
    probe = 'source "$1" || exit 99; kernel_xvfb_capture capture -a bash -c "$2"; echo "rc=$?"'
    env = dict(bench.env, XVFB_ROUTING=routing, XVFB_MODE='clean', FACTS=str(directory))
    r = subprocess.run(['bash', '-c', probe, 'cmdline', str(HELPER), inner], cwd=directory, env=env,
                       capture_output=True, timeout=30)

    def read(name):
        path = directory / name
        return path.read_bytes() if path.exists() else b''
    capture = directory / 'capture'
    ok = expect(label, r.stdout == b'rc=7\n' and r.stderr == b'', f'{r.stdout!r} {r.stderr!r}')
    ok &= expect(label, read('capture') == b'OUT-1\nERR-1\nOUT-2\nERR-2\n',
                 f"capture {read('capture')!r}; side {read('capture.xvfb-run.stderr')!r}")
    ok &= expect(label, not (directory / 'capture.xvfb-run.stderr').exists(), 'a side file was left')
    ok &= expect(label, read('self').split(b'\0') == [b'bash', b'-c', inner.encode(), b''],
                 f"the running command's argv is not the caller's own: {read('self')!r}")
    parent = read('parent').split(b'\0')
    ok &= expect(label, parent[1:] == [str(bench.root / 'tools' / WRAPPER).encode(), b'-a', b'sh', b'-c',
                                       b'exec "$@" 2>&1', b'kernel_xvfb_capture', b'bash', b'-c',
                                       inner.encode(), b''],
                 f'the parent is not {WRAPPER} running the shim: {parent!r}')
    ok &= expect(label, read('fds').decode().splitlines() == [str(capture.resolve())] * 2,
                 f"stdout and stderr are not both the capture: {read('fds')!r}")
    rows.append((label, ok))


def helper_shapes(bench, rows):
    """Only CAPTURE [-a|--auto-servernum]... COMMAND... reaches the wrapper.
    Any other shape is refused on stderr with status 2, the capture emptied
    and nothing run, because the shim can go only between options it knows
    take no argument and the command."""
    probe = 'source "$1" || exit 99; shift; kernel_xvfb_capture "$@"; echo "rc=$?"'
    command = ['bash', '-c', 'printf ran']
    shim = 'sh -c exec "$@" 2>&1 kernel_xvfb_capture bash -c printf ran'
    shapes = (('option-with-argument', ['cap', '-n', '5', *command], None),
              ('error-file', ['cap', '-a', '-e', 'errors.txt', *command], None),
              ('server-args', ['cap', '-a', '-s', '-screen 0 640x480x24', *command], None),
              ('long-with-value', ['cap', '--server-num=5', *command], None),
              ('bundled', ['cap', '-an', '5', *command], None),
              ('end-of-options', ['cap', '-a', '--', *command], None),
              ('no-command', ['cap', '-a'], None),
              ('capture-only', ['cap'], None),
              ('no-arguments', [], None),
              ('capture-omitted', ['-a', *command], None),
              ('empty-capture', ['', '-a', *command], None),
              ('auto', ['cap', '-a', *command], '-a ' + shim),
              ('no-options', ['cap', *command], shim),
              ('long-auto', ['cap', '--auto-servernum', *command], '--auto-servernum ' + shim),
              ('repeated', ['cap', '-a', '-a', *command], '-a -a ' + shim))
    for name, args, wrapper_args in shapes:
        label = f'TREE-O-shape-{name}'
        directory = bench.root / label
        directory.mkdir()
        (directory / 'cap').write_bytes(b'STALE\n')
        log = directory / 'argv.log'
        env = dict(bench.env, XVFB_ROUTING='no-merge', XVFB_MODE='clean', XVFB_ARGV_LOG=str(log))
        r = subprocess.run(['bash', '-c', probe, 'shape', str(HELPER), *args], cwd=directory, env=env,
                           capture_output=True, timeout=30)
        calls = log.read_text().splitlines() if log.exists() else []
        capture = (directory / 'cap').read_bytes()
        stray = sorted(p.name for p in directory.iterdir() if p.name not in ('cap', 'argv.log'))
        if wrapper_args is None:
            valid_capture = bool(args) and args[0] == 'cap'
            ok = expect(label, r.stdout == b'rc=2\n', f'want rc=2 on stdout only: {r.stdout!r}')
            ok &= expect(label, r.stderr.startswith(b'HARNESS-ERROR: ') and r.stderr.count(b'\n') == 1,
                         f'want one HARNESS-ERROR line on stderr: {r.stderr!r}')
            ok &= expect(label, calls == [], f'{WRAPPER} was run: {calls}')
            ok &= expect(label, capture == (b'' if valid_capture else b'STALE\n'),
                         f'capture {capture!r} (a named capture is emptied; nothing else is touched)')
            ok &= expect(label, stray == [], f'files created: {stray}')
        else:
            ok = expect(label, r.stdout == b'rc=0\n' and r.stderr == b'', f'{r.stdout!r} {r.stderr!r}')
            ok &= expect(label, calls == [wrapper_args], f'{WRAPPER} arguments {calls}, want {[wrapper_args]}')
            ok &= expect(label, capture == b'ran', f'capture {capture!r}')
        rows.append((label, ok))


def evidence_bytes(r):
    return [(s['paths'], s['files'].get('bochs_out.txt'), s['files'].get(SIDE), s['files'].get(EXIT))
            for s in r['snapshots']]


def routing_independent(column, results, boots, rows):
    """Every row gives the same status, capture, side file and layout under both routings."""
    merge, no_merge = (results[routing] for routing in ROUTINGS)
    ok = True
    for name in merge:
        a, b = merge[name], no_merge[name]
        ok &= expect(f'{column}-ROUTING-{name}', a['rc'] == b['rc'] and a['probe'] == b['probe']
                     and evidence_bytes(a) == evidence_bytes(b),
                     f"merge rc={a['rc']} {evidence_bytes(a)!r} / no-merge rc={b['rc']} {evidence_bytes(b)!r}")
    for kind in ('clean', 'dirty'):
        a, b = (boots[routing][kind]['boot'] for routing in ROUTINGS)
        ok &= expect(f'{column}-ROUTING-I-{kind}', {k: a.get(k) for k in ('bochs_out.txt', SIDE, EXIT)}
                     == {k: b.get(k) for k in ('bochs_out.txt', SIDE, EXIT)},
                     f'direct boot files differ: {a!r} / {b!r}')
    rows.append((f'{column}-ROUTING byte-identical captures, side files and statuses under both routings', ok))


def census_lines(path, text):
    """Invocation-shaped lines of one file, outside and inside the helper's body."""
    lines = text.split('\n')
    body = None
    if path == HELPER_FILE:
        starts = [i for i, line in enumerate(lines) if line.startswith(HELPER_OPEN)]
        if len(starts) == 1:
            end = next((j for j in range(starts[0] + 1, len(lines)) if lines[j] == '}'), None)
            if end is not None:
                body = (starts[0], end)
    found, sanctioned = [], []
    for i, line in enumerate(lines):
        if line.lstrip().startswith('#'):
            continue
        if not any(not CENSUS_PROBE.search(line[:m.start()]) for m in CENSUS_INVOCATION.finditer(line)):
            continue
        inside = body is not None and body[0] < i < body[1]
        (sanctioned if inside else found).append((i + 1, line.strip()))
    return found, sanctioned, body


def tracked_files(root):
    """Every tracked file except Markdown documents, or None without git."""
    try:
        top = subprocess.run(['git', '-C', str(root), 'rev-parse', '--show-toplevel'],
                             capture_output=True, text=True, timeout=60)
        if top.returncode != 0 or Path(top.stdout.strip()).resolve() != root.resolve():
            return None
        listing = subprocess.run(['git', '-C', str(root), 'ls-files', '-z'], capture_output=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if listing.returncode != 0:
        return None
    return [name for name in listing.stdout.decode().split('\0') if name and not name.endswith('.md')]


def census(rows):
    # The rule bites: every flagged example is caught, no clean one is, and the
    # helper exemption covers the helper's body and nothing after it.
    ok = True
    for line in CENSUS_FLAGGED:
        ok &= expect('J-census-rule', census_lines('probe.sh', line)[0] == [(1, line.strip())],
                     f'not flagged: {line!r}')
    for line in CENSUS_CLEAN:
        ok &= expect('J-census-rule', census_lines('probe.sh', line) == ([], [], None),
                     f'flagged: {line!r}')
    fake = '\n'.join((HELPER_OPEN + ' # CAPTURE ARGS', CENSUS_FLAGGED[-1],
                      f'    echo "HARNESS-NOTE: {WRAPPER} exited $rc"', '}', CENSUS_FLAGGED[0]))
    found, sanctioned, _ = census_lines(HELPER_FILE, fake)
    ok &= expect('J-census-rule', found == [(5, CENSUS_FLAGGED[0].strip())] and len(sanctioned) == 2,
                 f'helper exemption: outside {found}, inside {sanctioned}')
    found, sanctioned, _ = census_lines('bootstrap/tests/other.sh', fake)
    ok &= expect('J-census-rule', len(found) == 3 and not sanctioned,
                 f'the exemption must hold only in {HELPER_FILE}: {found} {sanctioned}')
    rows.append((f'J-census-rule: {len(CENSUS_FLAGGED)} invocation shapes flagged, '
                 f'{len(CENSUS_CLEAN)} non-invocations clean', ok))

    root = HERE.parent.parent
    scan = census_scan(root)
    if not expect('J-census', scan is not None,
                  f'cannot list tracked files with git at {root}; the census fails closed'):
        rows.append(('J-census', False))
        return
    scanned, sites, helper, sanctioned = scan
    for name, number, line in sites:
        expect('J-census', False, f'direct {WRAPPER} invocation at {name}:{number}: {line}')
    ok = not sites
    ok &= expect('J-census', helper is not None and sanctioned,
                 f'no {WRAPPER} call inside kernel_xvfb_capture() in {HELPER_FILE}: {helper} {sanctioned}')
    this = str(Path(__file__).resolve().relative_to(root.resolve()))
    ok &= expect('J-census', this in scanned and HELPER_FILE in scanned,
                 f'the census did not scan {this} and {HELPER_FILE}')
    rows.append((f'J-census: {len(scanned)} tracked files (all but Markdown), {len(sites)} direct '
                 f'{WRAPPER} invocation(s) outside kernel_xvfb_capture()', ok))
    census_planted(rows, root, scanned)


def census_scan(root):
    """(scanned files, invocation sites, helper body, sanctioned lines) over the
    tracked files of the repository at root, or None without git."""
    names = tracked_files(root)
    if names is None:
        return None
    scanned, sites, helper, sanctioned = [], [], None, []
    for name in names:
        path = root / name
        if not path.is_file():
            continue
        found, own, body = census_lines(name, path.read_bytes().decode('utf-8', errors='replace'))
        scanned.append(name)
        sites += [(name, number, line) for number, line in found]
        if name == HELPER_FILE:
            helper, sanctioned = body, own
    return scanned, sites, helper, sanctioned


def census_planted(rows, root, scanned):
    """Tracked-file mutation controls for row J. Every shape in CENSUS_SHAPES
    is first run against a stub wrapper (so it really invokes it), then planted
    over a real call site in a scratch Git copy of the gate files, where the
    same scan row J runs must name exactly that line. The unplanted copy and a
    commented-out call must scan clean."""
    label = 'J-census-planted'
    sites = []
    for name in scanned:
        if not name.endswith('.sh') or name == HELPER_FILE:
            continue
        for number, line in enumerate((root / name).read_bytes().decode('utf-8', 'surrogateescape')
                                      .split('\n'), 1):
            m = CENSUS_CALL.match(line)
            if m and not line.lstrip().startswith('#'):
                sites.append((name, number, m))
    if not expect(label, sites, f'no converted kernel_xvfb_capture call site found under {root}'):
        rows.append((label, False))
        return
    files = sorted({name for name, _, _ in sites})

    def instantiate(template, cap, cmd, bin_dir):
        values = {'NAME': WRAPPER, 'BIN': bin_dir, 'CAP': cap, 'CMD': cmd}
        return re.sub('NAME|BIN|CAP|CMD', lambda k: values[k.group()], template)

    ok = True
    with tempfile.TemporaryDirectory(prefix='herbert-census-planted-') as temporary:
        temporary = Path(temporary)
        # 1. Each shape invokes the wrapper: a stub first on PATH must run.
        for shape, template in CENSUS_SHAPES:
            box = temporary / 'run' / shape
            (box / 'bin').mkdir(parents=True)
            executable(box / 'bin' / WRAPPER, CENSUS_STUB)
            command = instantiate(template, 'capture.txt', 'bash -c "printf GUEST"', './bin')
            if not expect(label, '/usr/' not in command, f'{shape}: would run a real program: {command!r}'):
                ok = False
                continue
            env = dict(os.environ, PATH=f"{box / 'bin'}{os.pathsep}{os.environ.get('PATH', '')}",
                       CENSUS_STUB_LOG=str(box / 'ran.log'))
            r = subprocess.run(['bash', '-c', command], cwd=box, env=env, capture_output=True, timeout=30)
            ran = (box / 'ran.log').read_text() if (box / 'ran.log').exists() else ''
            capture = (box / 'capture.txt').read_bytes() if (box / 'capture.txt').exists() else b''
            ok &= expect(label, r.returncode == 0 and ran == 'ran\n' and b'GUEST' in capture,
                         f'{shape}: {command!r} did not run the stub wrapper: rc={r.returncode} ran={ran!r} '
                         f'capture={capture!r} stderr={r.stderr!r}')
        # 2. A scratch Git repository holding the real gate files and the helper.
        scratch = temporary / 'repo'
        originals = {}
        for name in files + [HELPER_FILE]:
            originals[name] = (root / name).read_bytes()
            (scratch / name).parent.mkdir(parents=True, exist_ok=True)
            (scratch / name).write_bytes(originals[name])
        for git in (['git', 'init', '-q'], ['git', 'add', '--', *originals]):
            r = subprocess.run(git, cwd=scratch, capture_output=True, timeout=60)
            if not expect(label, r.returncode == 0, f'{" ".join(git[:2])} in the scratch copy: {r.stderr!r}'):
                rows.append((label, False))
                return

        def scan(name, text):
            (scratch / name).write_bytes(text.encode('utf-8', 'surrogateescape'))
            try:
                result = census_scan(scratch)
                syntax = subprocess.run(['bash', '-n', str(scratch / name)], capture_output=True, timeout=60)
            finally:
                (scratch / name).write_bytes(originals[name])
            return result, syntax

        result = census_scan(scratch)
        ok &= expect(label, result is not None and result[1] == [] and set(result[0]) == set(originals)
                     and result[3], f'the unplanted scratch copy must scan clean: {result}')
        # 3. Each shape over a real call site (a different one each time, in turn).
        for index, (shape, template) in enumerate(CENSUS_SHAPES):
            name, number, m = sites[index % len(sites)]
            planted = m['pre'] + instantiate(template, m['cap'], m['cmd'], '/usr/bin') + m['post']
            lines = originals[name].decode('utf-8', 'surrogateescape').split('\n')
            text = '\n'.join(lines[:number - 1] + [planted] + lines[number:])
            parts = planted.split('\n')
            at = next(i for i, part in enumerate(parts) if WRAPPER in part)
            want = [(name, number + at, parts[at].strip())]
            result, syntax = scan(name, text)
            ok &= expect(label, syntax.returncode == 0, f'{shape} at {name}:{number} is not valid shell: '
                         f'{syntax.stderr!r}')
            ok &= expect(label, result is not None and result[1] == want,
                         f'{shape} planted at {name}:{number + at} not named by the census: '
                         f'want {want}, got {result and result[1]}')
        # 4. The same call commented out is not an invocation.
        name, number, m = sites[0]
        lines = originals[name].decode('utf-8', 'surrogateescape').split('\n')
        commented = (m['pre'][:len(m['pre']) - len(m['pre'].lstrip())] + '# '
                     + instantiate(CENSUS_SHAPES[0][1], m['cap'], m['cmd'], '/usr/bin'))
        result, _ = scan(name, '\n'.join(lines[:number - 1] + [commented] + lines[number:]))
        ok &= expect(label, result is not None and result[1] == [],
                     f'a commented-out call at {name}:{number} was flagged: {result and result[1]}')
    rows.append((f'{label}: {len(CENSUS_SHAPES)} shell shapes each run a stub wrapper and, planted over '
                 f'one of {len(sites)} real call sites in a scratch Git copy of the {len(files)} files '
                 'that hold them, are each named by the census; the unplanted copy and a commented-out '
                 'call scan clean', ok))


def main():
    rows = []
    census(rows)
    with tempfile.TemporaryDirectory(prefix='herbert-xvfb-capture-check-') as temporary:
        bench = Bench(Path(temporary))
        source = HARNESS.read_text()
        legacy = unshimmed = None
        if expect('LEGACY-copy', source.count(TREE_LINE) == 1,
                  f'{source.count(TREE_LINE)} kernel_xvfb_capture boot line(s) in {HARNESS.name}, want 1'):
            legacy = bench.root / 'legacy' / HARNESS.name
            legacy.parent.mkdir()
            legacy.write_text(source.replace(TREE_LINE, LEGACY_LINE, 1))
        helper_source = HELPER.read_text()
        if expect('UNSHIMMED-copy', helper_source.count(SHIM_LINE) == 1,
                  f'{helper_source.count(SHIM_LINE)} shimmed {WRAPPER} line(s) in {HELPER.name}, want 1'):
            unshimmed = bench.root / 'unshimmed' / HELPER.name
            unshimmed.parent.mkdir()
            unshimmed.write_text(helper_source.replace(SHIM_LINE, UNSHIMMED_LINE, 1))
        tree, tree_boot, old, old_boot = {}, {}, {}, {}
        for routing in ROUTINGS:
            tree[routing] = run_rows(bench, 'TREE', HARNESS, rows, routing)
            # check_boot_input.py sources only the harness: its load guard must supply the helper.
            tree_boot[routing] = direct_boot(bench, 'TREE', HARNESS, rows, False, routing)
            leak_report(bench, rows, routing)
            helper_cmdline(bench, rows, routing)
            if legacy is not None:
                old[routing] = run_rows(bench, 'LEGACY', legacy, rows, routing)
                old_boot[routing] = direct_boot(bench, 'LEGACY', legacy, rows, True, routing)
            if unshimmed is not None:
                unshimmed_rows(bench, rows, routing, unshimmed)
        load_guard(bench, rows)
        helper_shapes(bench, rows)
        routing_independent('TREE', tree, tree_boot, rows)
        if legacy is not None:
            routing_independent('LEGACY', old, old_boot, rows)
            for routing in ROUTINGS:
                new, pre = tree[routing], old[routing]
                ok = expect('CROSS-A', sha(new['A-clean']['probe']) == sha(pre['A-clean']['probe']),
                            'the clean-path capture changed')
                ok &= expect('CROSS-A', [s['paths'] for s in new['A-clean']['snapshots']]
                             == [s['paths'] for s in pre['A-clean']['snapshots']],
                             'the clean-path evidence layout changed')
                ok &= expect('CROSS-E', new['E-wrapped-stderr']['probe'] == pre['E-wrapped-stderr']['probe'],
                             "the wrapped command's stderr is captured differently")
                ok &= expect('CROSS-I', tree_boot[routing]['clean']['boot'].get('bochs_out.txt')
                             == old_boot[routing]['clean']['boot'].get('bochs_out.txt'),
                             'the direct-boot clean capture changed')
                rows.append((f'CROSS-{routing}-A/E/I byte-identical clean captures and layout', ok))
                ok = expect('CROSS-H', [s['files'].get('bochs_out.txt') for s in new['H-start-exhausted']['snapshots']]
                            == [s['files'].get('bochs_out.txt') for s in pre['H-start-exhausted']['snapshots']],
                            'the start-exhausted child captures differ between the columns')
                ok &= expect('CROSS-H', [s['paths'] for s in new['H-start-exhausted']['snapshots']]
                             == [s['paths'] for s in pre['H-start-exhausted']['snapshots']],
                             'the start-exhausted evidence layout differs between the columns')
                rows.append((f'CROSS-{routing}-H byte-identical start-exhausted captures and layout', ok))
    for label, ok in rows:
        print(f"{'PASS' if ok else 'FAIL'} {label}")
    if FAILURES:
        print(f'FAIL bochs {WRAPPER} capture: {len(FAILURES)} check(s) failed')
        sys.exit(1)
    print(f'PASS bochs {WRAPPER} capture: {len(rows)} rows under both {WRAPPER} stderr routings; the capture '
          "holds the command's whole stream and none of the wrapper's own diagnostics, verdicts unchanged "
          '(controlled commands; no emulator qualification)')


if __name__ == '__main__':
    main()
