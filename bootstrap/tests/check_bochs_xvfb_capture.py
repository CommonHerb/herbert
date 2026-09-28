#!/usr/bin/env python3
"""Bite proof: xvfb-run's own diagnostics never reach a graded Bochs capture.

FLAKE-LOG F12. The real shared harness (bochs_f2_harness.sh: f2_bochs_leg,
f2__boot and its load guard) and the real binary-safe frame parser run against
controlled host-command stubs. The xvfb-run stub keeps the real wrapper's
stream topology: the wrapped command's stdout AND stderr go to the wrapper's
stdout (/usr/bin/xvfb-run:184) and the wrapper's own error() goes to its
stderr. A stub that printed its error on stdout would make both harness
versions RED and prove nothing. No emulator, mount, privileged command or
compiler runs; the real-Bochs kernel matrix remains a separate qualification.

Every leg row runs twice: on this tree's harness (TREE) and on a copy whose
kernel_xvfb_capture call is restored to the pre-fix line (LEGACY). The LEGACY
column is a permanent mutation proof. Reverting that one line brings back the
false RED seen on link41/44/46 on 2026-09-28, while a wrong guest answer and
unknown emulator-side text stay RED in both columns.
"""
if not __debug__:
    raise SystemExit('verification requires Python assertions; remove -O/-OO and PYTHONOPTIMIZE')

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time


HERE = Path(__file__).resolve().parent
HARNESS = HERE / 'bochs_f2_harness.sh'
# Assembled by concatenation so a scan for direct wrapper invocations never
# matches this file.
WRAPPER = 'xvfb-' + 'run'
TREE_LINE = ('      kernel_xvfb_capture bochs_out.txt -a bash -c '
             '"yes c | timeout -s KILL ${tmo} bochs -q -f bochsrc.txt" )\n')
LEGACY_LINE = ('      ' + WRAPPER + ' -a bash -c '
               '"yes c | timeout -s KILL ${tmo} bochs -q -f bochsrc.txt" > bochs_out.txt 2>&1 )\n')
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
# Mirrors /usr/bin/xvfb-run (xvfb 2:21.1.12-1ubuntu1.8) for each mode used here.
# All modes: the wrapped command's stdout AND stderr go to this process's stdout
# ("$@" 2>&1, line 184); the wrapper's own error() goes to its stderr (lines
# 30-37). The harness always passes -a, which sets AUTONUM (line 110).
#   clean: the command runs, its status is returned (lines 182-189); the EXIT
#     trap's cleanup succeeds silently (lines 80-93).
#   cleanup-error, cleanup-error-leak: the command runs, then the EXIT trap's
#     failed rm -r prints the error and exits 5 (lines 84-88) before the kill
#     that would stop the server (lines 90-92).
#   xauth-missing: a pre-command failure. xauth is not found, so the wrapper
#     prints the error and exits 3 (lines 137-140), before the EXIT trap is set
#     (line 143), before any server starts and before the command runs.
#   start-exhausted: every Xvfb start fails. With -a each failure takes the
#     `continue` at lines 171-175, so the error at lines 177-179 is skipped;
#     after ten tries the loop ends and the command runs anyway (line 184),
#     with no wrapper diagnostic. The EXIT trap then kills the last, dead
#     server PID (line 91); that kill's stderr goes to ERRORFILE (/dev/null,
#     line 15), and set -e (line 186) turns its failure into status 1 whatever
#     the command returned. Without -a the first failure prints the error and
#     exits 1 before the command runs (lines 177-179).
autonum=
[[ "${1:-}" == -a ]] && { autonum=yes; shift; }
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
"$@" 2>&1
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
import os
from pathlib import Path
import sys
if not Path('bochsrc.txt').is_file():
    sys.exit('bochs stand-in: f2__boot wrote no bochsrc.txt')
if os.environ.get('EMULATOR_EXTRA') == 'startup-error':
    sys.stderr.buffer.write({STARTUP_ERROR!r})
    sys.stderr.flush()
    sys.exit(1)
out = sys.stdout.buffer
out.write(b'controlled Bochs stand-in preamble\\n\\x9c')
out.write(b'\\xde' + bytes.fromhex(os.environ['GUEST_ANSWER']) + b'\\xad')
out.write({BOCHS_TAIL!r})
if os.environ.get('EMULATOR_EXTRA') == 'unknown-stdout':
    out.write({UNKNOWN_LINE!r})
out.flush()
if os.environ.get('EMULATOR_EXTRA') == 'wrapped-stderr':
    sys.stderr.buffer.write({YES_LINE!r})
    sys.stderr.flush()
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

    def run(self, label, harness, *, mode='leg', xvfb='clean', guest='00', extra='',
            preload=True, leak=None):
        directory = self.root / label
        directory.mkdir()
        out = directory / 'out'
        out.mkdir()
        tmp = directory / 'tmp'
        tmp.mkdir()
        evidence = directory / 'evidence'
        env = dict(self.env, TEST_HARNESS=str(harness), TEST_MODE=mode, TEST_OUT=str(out),
                   TEST_PRELOAD='1' if preload else '0', XVFB_MODE=xvfb, GUEST_ANSWER=guest,
                   EMULATOR_EXTRA=extra, TMPDIR=str(tmp))
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


def run_rows(bench, column, harness, rows):
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
        result[name] = bench.run(f'{column}-{name}', harness, xvfb=xvfb, guest=guest, extra=extra)
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


def direct_boot(bench, column, harness, rows, preload):
    clean = bench.run(f'{column}-I-direct-clean', harness, mode='boot', preload=preload)
    dirty = bench.run(f'{column}-I-direct-cleanup-error', harness, mode='boot', preload=preload,
                      xvfb='cleanup-error')
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
    return clean


def leak_report(bench, rows):
    release = bench.root / 'leak-release'
    pidfile = bench.root / 'leak.pid'
    pid = None
    try:
        r = bench.run('TREE-K-leak-report', HARNESS, xvfb='cleanup-error-leak',
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


def main():
    rows = []
    with tempfile.TemporaryDirectory(prefix='herbert-xvfb-capture-check-') as temporary:
        bench = Bench(Path(temporary))
        tree = run_rows(bench, 'TREE', HARNESS, rows)
        # check_boot_input.py sources only the harness: its load guard must supply the helper.
        tree_boot = direct_boot(bench, 'TREE', HARNESS, rows, preload=False)
        leak_report(bench, rows)
        load_guard(bench, rows)
        source = HARNESS.read_text()
        if expect('LEGACY-copy', source.count(TREE_LINE) == 1,
                  f'{source.count(TREE_LINE)} kernel_xvfb_capture boot line(s) in {HARNESS.name}, want 1'):
            legacy = bench.root / 'legacy' / HARNESS.name
            legacy.parent.mkdir()
            legacy.write_text(source.replace(TREE_LINE, LEGACY_LINE, 1))
            old = run_rows(bench, 'LEGACY', legacy, rows)
            old_boot = direct_boot(bench, 'LEGACY', legacy, rows, preload=True)
            ok = expect('CROSS-A', sha(tree['A-clean']['probe']) == sha(old['A-clean']['probe']),
                        'the clean-path capture changed')
            ok &= expect('CROSS-A', [s['paths'] for s in tree['A-clean']['snapshots']]
                         == [s['paths'] for s in old['A-clean']['snapshots']],
                         'the clean-path evidence layout changed')
            ok &= expect('CROSS-E', tree['E-wrapped-stderr']['probe'] == old['E-wrapped-stderr']['probe'],
                         "the wrapped command's stderr is captured differently")
            ok &= expect('CROSS-I', tree_boot['boot'].get('bochs_out.txt') == old_boot['boot'].get('bochs_out.txt'),
                         'the direct-boot clean capture changed')
            rows.append(('CROSS-A/E/I byte-identical clean captures and layout', ok))
            ok = expect('CROSS-H', [s['files'].get('bochs_out.txt') for s in tree['H-start-exhausted']['snapshots']]
                        == [s['files'].get('bochs_out.txt') for s in old['H-start-exhausted']['snapshots']],
                        'the start-exhausted child captures differ between the columns')
            ok &= expect('CROSS-H', [s['paths'] for s in tree['H-start-exhausted']['snapshots']]
                         == [s['paths'] for s in old['H-start-exhausted']['snapshots']],
                         'the start-exhausted evidence layout differs between the columns')
            rows.append(('CROSS-H byte-identical start-exhausted captures and layout', ok))
    for label, ok in rows:
        print(f"{'PASS' if ok else 'FAIL'} {label}")
    if FAILURES:
        print(f'FAIL bochs {WRAPPER} capture: {len(FAILURES)} check(s) failed')
        sys.exit(1)
    print(f'PASS bochs {WRAPPER} capture: {len(rows)} rows; its own diagnostics stay out of the graded '
          'capture, verdicts unchanged (controlled commands; no emulator qualification)')


if __name__ == '__main__':
    main()
