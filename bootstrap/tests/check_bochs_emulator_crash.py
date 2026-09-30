#!/usr/bin/env python3
"""Bite proof: a Bochs that dies of a signal after its exit banner is never graded.

Red-run sweep 2026-09-29 (FLAKE-LOG "Bochs crash at exit"). In GitHub run 36583224514 Bochs 2.8
died of SIGSEGV after printing its shutdown banner; bash's job report for the boot pipeline landed
in the merged capture; the strict frame grammar refused it, rightly, and link39 went RED. Three
re-rolls then booted clean and were thrown away: a parse error graded on attempt 1 made each later
attempt's cleanup exit inside the replay driver's command substitution, so they were logged with a
blank class. bochs_f2_harness.sh now classes a boot whose pipeline ended by a signal after the
banner as EMULATOR-CRASH (from the exit status, never the capture text), re-rolls it on a fresh
disk and never grades it, and runs each attempt's own cleanup in the attempt's parse-error scope.

The real shared harness and the real binary-safe frame parser run against controlled stubs (the
host-command stubs of check_bochs_xvfb_capture.py, under both of the wrapper's stderr routings). No emulator, mount,
privileged command or compiler runs. The Bochs stand-in writes guest bytes on stdout and its exit
banner on stderr, as real Bochs does, then per boot either exits 1 as Bochs does after "shutdown
requested", or dies of a genuine SIGSEGV or SIGKILL with core dumps disabled first (so no core
file or crash report is written), or prints unknown text and exits normally. The boot runs through
the harness's own `bash -c "yes c | timeout -s KILL ... bochs ..."` line.

Only a positively identified emulator crash re-rolls (Astra R1): a death after the banner by SIGILL,
SIGABRT, SIGBUS, SIGFPE or SIGSEGV. Any other signal after the banner is KILLED-AFTER-BANNER, a kill (a
timeout, or an external kill), which is terminal: never re-rolled, never graded, and its leg fails.

The status is the boot pipeline's own, which its inner command writes to bochs_out.txt.pipeline-status
before the wrapper's EXIT-trap cleanup can replace the wrapper's status (Astra R2); classification reads
only that file, and a missing, empty or non-numeric one is NO-STATUS, a harness class.

CLASS-TABLE: the harness's own classifier over every status 0..255: exactly 132, 134, 135, 136 and 139
are EMULATOR-CRASH, every other 129..192 is terminal KILLED-AFTER-BANNER, and the rest are finished boots.
STATUS-FILE-TABLE: the status file's reader: missing, empty, non-numeric, padded, out of range or
multi-line content is NO-STATUS; a plain number is classified as CLASS-TABLE says.
TREE rows (this tree's harness, under both routings):
  crash-then-ok     SIGSEGV after the banner on attempt 1: EMULATOR-CRASH (status 139) re-rolled on a
                    fresh disk, attempt 2 graded GREEN; the crashed capture is never graded
  abort-then-ok     SIGABRT after the banner: EMULATOR-CRASH (status 134), the same
  kill-then-ok      SIGKILL after the banner (a kill; GNU timeout reports its own kill the same way): KILLED-AFTER-BANNER
                    (status 137), terminal: one boot, never re-rolled, never graded, exit 1, no GREEN
  wrong-kill-then-ok  a WRONG answer, the banner, then SIGKILL, followed by a clean boot: still RED, one
                    boot; the clean boot is never reached (Astra's R1 reproduction)
  term-then-ok      SIGTERM after the banner: KILLED-AFTER-BANNER (status 143), terminal, RED
  crash-always      every attempt crashes: three EMULATOR-CRASH re-rolls, HARNESS-ERROR, exit 1, no
                    kernel-RED line, never GREEN
  early-crash       SIGSEGV before the banner stays NO-SHUTDOWN (link66's fault legs rely on that)
  malformed-normal  unknown text after the banner and a normal exit: graded once, RED
  feed-replay       link39's path, f2_bochs_feed_leg_replay: crash then clean, GREEN, no REPLAY
  kill-replay       the same path, a kill after the banner: terminal, one boot, no REPLAY, RED
  replay-then-kill  a completed RED whose same-input replay is killed after the banner: UNADJUDICATED,
                    fail_test'd, two boots, RED (never re-rolled past the kill)
  poisoned-replay   a gate shaped like link39 (a parse-error file that its fail_test and EXIT trap
                    exit 1 on): attempt 1 exits normally with a malformed capture and is graded RED;
                    its replay boots clean and its real result is logged (FLAKE-DISCRIMINATED); the
                    gate still ends RED on the parse error, reported once
  ci-shape          link39's run 36583224514 shape: that gate, a crash on attempt 1, then clean
                    boots: EMULATOR-CRASH re-rolled, GREEN
  overwrite-*       the wrapper's cleanup fails on every boot and exits 5 in place of the command's
                    status (F12): a crash is still EMULATOR-CRASH from the pipeline's own status
                    (re-rolled, never graded; three fail closed with zero grades), a kill is still
                    terminal, and a normal wrong answer is still graded RED
  nostatus-*        the pipeline's status file cannot be written: NO-STATUS, re-rolled, never graded;
                    three fail closed
  link62-overwrite  the REAL link62 bochs_run and its raw-frame grader (which ignores trailing text),
                    lifted from the gate: a crash after a correct proof frame with the wrapper's status
                    overwritten is re-rolled, and only the clean boot is graded (Astra's R2 case)
LINK66 rows: link66 drives f2_bochs_feed_attempt from its own retry loops (the gate's bochs_draw and
bochs_boundary_fault, the mutation proof's bochs_probe and its seed-pin loop), so the shared legs' terminal
stop does not reach them. Each loop is lifted from its script and run with f2_bochs_feed_attempt replaced by
a fixture: attempt 1 writes a wrong completion (the marker, an answer byte, the banner) and the given
pipeline status, every later attempt the clean fault the leg expects, and each then runs the real classifier.
  *-kill, *-term    status 137 or 143 on attempt 1: KILLED-AFTER-BANNER ends the leg at once, one boot,
                    nothing graded, the harness summary fails (main graded that completion RED)
  boundary-crash    status 139: EMULATOR-CRASH re-rolled, the clean fault graded GREEN
  boundary-timeout  status 124, what the runner's timeout reports when it fires: a finished boot, graded
                    RED, one boot
Mutation columns, each the tree's harness with a pre-fix line restored:
  CRASHALL     kill-then-ok with every signal counted as a crash (the first cut, 1699359): the kill is
               re-rolled and the leg passes GREEN, which is the loosening the TREE row refuses
  NOSTATUS     crash-then-ok: the classifier ignores the status, so the crashed capture is graded
               and is RED
  WRAPPERSTATUS  the attempts classify from the wrapper's status file (the first cut's source): under
               a cleanup overwrite the crashed capture is graded, RED on the frame parser and GREEN
               on link62's raw-frame grader, which is the false GREEN of Astra's R2
  SHAREDSCOPE  poisoned-replay: the attempts clean up in the gate-wide parse-error scope, so the
               replay's class is lost (blank) and the parse error is printed again per attempt
  PREFIX       ci-shape with both restored: the CI log (a REPLAY on the crash's parse error, three
               blank-class re-rolls, the parse error printed four times), exit 1
  NOTERMINAL   a LINK66 kill row with that loop's terminal-class stop removed (the loop as this stack
               first carried it): the kill is re-rolled and the clean fault passes, the RED-to-GREEN of
               Astra's R6 that the LINK66 row refuses
"""
if not __debug__:
    raise SystemExit('verification requires Python assertions; remove -O/-OO and PYTHONOPTIMIZE')

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import check_bochs_xvfb_capture as xc  # noqa: E402  (its host-command stubs; its main() does not run)

HARNESS = HERE / 'bochs_f2_harness.sh'
ROUTINGS = xc.ROUTINGS
PARSE_ERROR = 'holler malformed/truncated debugcon record at byte 0 of'
WRONG_ANSWER = xc.WRONG_ANSWER
PIPELINE_STATUS = 'bochs_out.txt.pipeline-status'
WRAPPER_STATUS = 'bochs_out.txt.wrapper-status'
STATUS_CHECK = '    if ! cls="$(f2__status_class "$stfile")"; then echo "$cls"; return; fi\n'
CLASSIFY_FROM = f'"$W/{PIPELINE_STATUS}")"'
CLASSIFY_FROM_WRAPPER = f'"$W/{WRAPPER_STATUS}")"'
CRASH_LIST = 'F2_CRASH_SIGNALS=(4 6 7 8 11)'
CRASH_ALL = 'F2_CRASH_SIGNALS=($(seq 1 64))'
CRASH_STATUSES = {132: 4, 134: 6, 135: 7, 136: 8, 139: 11}   # SIGILL SIGABRT SIGBUS SIGFPE SIGSEGV
SCOPED_CLEANUP = 'f2__attempt_cleanup "$W"'
SHARED_CLEANUP = 'kernel_test_cleanup "$W"'
LINK66_GATE = HERE / 'run_native_codegen_link66.sh'
LINK66_PROOF = HERE / 'run_native_codegen_link66_mutation.sh'
LINK66_STOP = 'f2__terminal_class'   # the one line in each lifted loop that stops on a terminal class
# (label, script, first line, end marker): each lifted loop runs exactly as its script has it
LINK66_LOOPS = (('boundary', LINK66_GATE, '        bochs_boundary_fault() {', '\n        }\n'),
                ('draw', LINK66_GATE, '        bochs_draw() {', '\n        }\n'),
                ('probe', LINK66_PROOF, '    bochs_probe() {', '\n    }\n'),
                ('seedpin', LINK66_PROOF, '            for _attempt in 1 2 3; do\n', '\n            done\n'))

BOCHS = r'''#!/usr/bin/env python3
# Bochs stand-in. CRASH_PLAN lists one action per boot (the last repeats); CRASH_COUNTER counts boots.
import ctypes
import os
from pathlib import Path
import signal
import sys
if not Path('bochsrc.txt').is_file():
    sys.exit('bochs stand-in: f2__boot wrote no bochsrc.txt')
counter = Path(os.environ['CRASH_COUNTER'])
n = int(counter.read_text()) + 1 if counter.exists() else 1
counter.write_text(f'{n}\n')
plan = os.environ['CRASH_PLAN'].split(',')
action = plan[min(n, len(plan)) - 1]
out, err = sys.stdout.buffer, sys.stderr.buffer
def emit(stream, data):
    stream.write(data)
    stream.flush()
def die(sig):
    # A genuine death by signal. PR_SET_DUMPABLE=0 first: no core file and no crash report.
    if ctypes.CDLL(None, use_errno=True).prctl(4, 0, 0, 0, 0) != 0:
        sys.exit('bochs stand-in: prctl(PR_SET_DUMPABLE, 0) failed; refusing to risk a core dump')
    signal.raise_signal(sig)
    sys.exit('bochs stand-in: survived a fatal signal')
emit(err, b'controlled Bochs stand-in preamble\n')
if action == 'nostatus':
    # A directory where the inner command writes the pipeline's status: that write fails, so the boot
    # leaves no readable status (the NO-STATUS class), whatever it prints.
    Path('bochs_out.txt.pipeline-status').mkdir()
if action == 'early-segv':
    die(signal.SIGSEGV)
answer = '01' if action == 'wrongkill' else os.environ['GUEST_ANSWER']   # wrongkill: a WRONG answer, then the kill
emit(out, b'\x9c\xde' + bytes.fromhex(answer) + b'\xad')
emit(err, BOCHS_TAIL_BYTES)
if action == 'segv':
    die(signal.SIGSEGV)
if action == 'abort':
    die(signal.SIGABRT)
if action in ('kill', 'wrongkill'):
    die(signal.SIGKILL)
if action == 'term':
    die(signal.SIGTERM)
if action == 'junk':
    emit(out, b'bochs: unexpected diagnostic\n')
sys.exit(1)   # real Bochs exits 1 after "shutdown requested"
'''.replace('BOCHS_TAIL_BYTES', repr(xc.BOCHS_TAIL))

FEEDER = '''import sys
# stand-in for kernel_input_feed.py: announce LISTENING and SENT, then exit
print("LISTENING", flush=True)
print("SENT", flush=True)
'''

DRIVER = r'''set -u
unset CDPATH
ulimit -c 0 2>/dev/null
source "$TEST_SCRIPTS/qemu_prefix.sh" || exit 96
source "$TEST_HARNESS" || exit 97
fail=0
free_port() { echo 1; }
feeder="$TEST_FEEDER"
grade_plain() { # LOG WANT -- as the plain-leg gates grade: the binary-safe parser decides; RED reports FAIL
    local out
    if out="$(python3 "$TEST_GRADER" "$1" "$2" 2>&1)"; then return 0; fi
    fail_test "probe Bochs grade RED -> ${out##*$'\n'}"
    return 1
}
grade_replay() { # LOG WANT -- the replay contract: never fail_test; print the signature; 0 GREEN, else RED
    python3 "$TEST_GRADER" "$1" "$2" 2>&1 | tr '\n' ' '
    return "${PIPESTATUS[0]}"
}
FILES=("$TEST_FIX/kernel.elf:boot/kernel.elf")
case "$TEST_MODE" in
    plain)
        fail_test() { echo "FAIL: $1"; fail=$((fail + 1)); }
        f2_bochs_leg probe grade_plain "$TEST_OUT/probe.log" "$TEST_CFG" 30 32 "${FILES[@]}" -- "$TEST_WANT"
        ;;
    feed-replay)
        fail_test() { echo "FAIL: $1"; fail=$((fail + 1)); }
        f2_bochs_feed_leg_replay probe grade_replay "20 --hold 25" "$TEST_OUT/feed.log" "$TEST_OUT/probe.log" \
            "$TEST_CFG" 30 32 "${FILES[@]}" -- "$TEST_WANT"
        ;;
    link62)   # run_native_codegen_link62.sh's own bochs_run and raw-frame grader, lifted from the gate
        fail_test() { echo "FAIL: $1"; fail=$((fail + 1)); }
        source "$TEST_LINK62" || exit 94
        host_proof() { echo 42; }   # proof byte 2a: the stand-in's answer frame is de2aad
        tmp="$TEST_OUT"
        bochs_run probe "$TEST_FIX/kernel.elf" 0
        ;;
    poisoned-replay)   # run_native_codegen_link39.sh's own shape (its lines 64-68)
        work="$(mktemp -d)"; export KERNEL_PARSE_ERROR_FILE="$work/parser-errors.txt"
        trap 'kernel_test_cleanup "$work"' EXIT
        fail_test() { [[ ! -s "$KERNEL_PARSE_ERROR_FILE" ]] || exit 1; echo "FAIL: $1"; fail=$((fail + 1)); }
        f2_bochs_feed_leg_replay probe grade_replay "20 --hold 25" "$TEST_OUT/feed.log" "$TEST_OUT/probe.log" \
            "$TEST_CFG" 30 32 "${FILES[@]}" -- "$TEST_WANT"
        ;;
    *) exit 95 ;;
esac
rc=$?
f2_harness_summary || exit 1
[[ $rc -eq 0 && $fail -eq 0 && ! -s "${KERNEL_PARSE_ERROR_FILE:-/dev/null}" ]] || exit 1
echo "GREEN probe"
'''

LINK66_DRIVER = r"""set -u
unset CDPATH
source "$TEST_SCRIPTS/kernel_evidence.sh" || exit 96
source "$TEST_HARNESS" || exit 97
tmp="$TEST_OUT"
MARKER=41 L66_GRUBCFG=unused LINK66_N=1 LINK66_Q=1 DRIVER_PAY=0 DRIVER_QRY=0 N=1 Q=1
_bs=0123456789abcdef0123456789abcdef
pass=0; fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
fail_test() { bad "$1"; }
derive() { echo "ab cd"; }
frame_count() { echo 0; }
f2_bochs_feed_attempt() {   # fixture: attempt 1 is FIRST_STATUS on a wrong completion, later ones a clean fault
    local n=0 feedlog="$2" outlog="$6" bootdir
    [[ ! -f "$TEST_OUT/boots" ]] || read -r n < "$TEST_OUT/boots"
    n=$((n + 1)); printf '%s\n' "$n" > "$TEST_OUT/boots"
    bootdir="$TEST_OUT/boot-$n"; mkdir "$bootdir"
    : > "$outlog"
    printf 'LISTENING\nSENT\n' > "$feedlog"
    if [[ "$n" == 1 ]]; then
        printf '\x41\x00' > "${feedlog%/*}/cap.bin"
        printf '\xde\x00\xad\n[UNMAP ] Shutdown port: shutdown requested\n' > "$bootdir/bochs_out.txt"
        printf '%s\n' "$FIRST_STATUS" > "$bootdir/bochs_out.txt.pipeline-status"
    else
        printf '\x41' > "${feedlog%/*}/cap.bin"
        printf 'booted; marker sent; no completion\n' > "$bootdir/bochs_out.txt"
        printf '124\n' > "$bootdir/bochs_out.txt.pipeline-status"
    fi
    f2__classify_boot "$bootdir" "$outlog" "$bootdir/bochs_out.txt.pipeline-status"
}
case "$TEST_CALL" in
    boundary) source "$TEST_LEG" || exit 98; bochs_boundary_fault boundary-over-bochs unused.elf ;;
    draw)     source "$TEST_LEG" || exit 98; bochs_draw draw1-bochs unused.elf 0 ;;
    probe)    source "$TEST_LEG" || exit 98; bochs_probe control-bochs unused.elf fault ;;
    seedpin)  _W="$tmp/seedpin.b"; mkdir -p "$_W"; _cls=""
              source "$TEST_LEG" || exit 98
              [[ "$_cls" == NO-SHUTDOWN ]] ;;
    *) exit 95 ;;
esac
leg_rc=$?
summary_rc=0; f2_harness_summary > /dev/null || summary_rc=$?
echo "RESULT: boots=$(cat "$TEST_OUT/boots") leg_rc=$leg_rc summary_rc=$summary_rc pass=$pass fail=$fail"
"""

FAILURES = []


def expect(label, condition, detail):
    if not condition:
        FAILURES.append(f'{label}: {detail}')
        print(f'FAIL {label}: {detail}', flush=True)
    return bool(condition)


class Bench(xc.Bench):
    def __init__(self, root):
        super().__init__(root)
        xc.executable(root / 'tools' / 'bochs', BOCHS)   # replaces the xvfb bench's stand-in
        (root / 'feeder.py').write_text(FEEDER)
        self.crash_driver = root / 'crash-driver.sh'
        self.crash_driver.write_text(DRIVER)
        self.env = {k: v for k, v in self.env.items() if k != 'PYTHONFAULTHANDLER'}
        self.env['TEST_FEEDER'] = str(root / 'feeder.py')
        gate = (HERE / 'run_native_codegen_link62.sh').read_text()
        start = gate.index('bochs_run() {')
        (root / 'link62_bochs_run.sh').write_text(gate[start:gate.index('\n}\n', start) + 3])
        self.env['TEST_LINK62'] = str(root / 'link62_bochs_run.sh')

    def crash_run(self, label, harness, *, routing, mode, plan, xvfb='clean', guest='00'):
        directory = self.root / label
        directory.mkdir()
        out, tmp, evidence = directory / 'out', directory / 'tmp', directory / 'evidence'
        out.mkdir()
        tmp.mkdir()
        env = dict(self.env, TEST_HARNESS=str(harness), TEST_MODE=mode, TEST_OUT=str(out), XVFB_MODE=xvfb,
                   XVFB_ROUTING=routing, GUEST_ANSWER=guest, TMPDIR=str(tmp), KERNEL_EVIDENCE_DIR=str(evidence),
                   CRASH_PLAN=plan, CRASH_COUNTER=str(directory / 'boots'))
        try:
            result = subprocess.run(['bash', str(self.crash_driver)], env=env, capture_output=True, timeout=180)
            rc, stdout, stderr = result.returncode, result.stdout, result.stderr
        except subprocess.TimeoutExpired as error:
            rc, stdout, stderr = 'timeout', error.stdout or b'', error.stderr or b''
        (directory / 'driver.stdout').write_bytes(stdout)
        (directory / 'driver.stderr').write_bytes(stderr)
        attempts = []   # one per boot directory the harness retained, in order
        for capture in sorted(evidence.glob('capture-*')) if evidence.is_dir() else []:
            inventory = json.loads((capture / 'INVENTORY.json').read_text())
            paths = {row['path'] for row in inventory['files']}
            if 'bochsrc.txt' in paths:
                attempts.append({p: (capture / p).read_bytes() for p in ('bochs_out.txt', PIPELINE_STATUS, WRAPPER_STATUS)
                                 if (capture / p).is_file()})
        boots = directory / 'boots'
        probe = out / 'probe.b' / 'bochs_out.txt' if mode == 'link62' else out / 'probe.log'
        return dict(label=label, rc=rc, out_lines=stdout.decode(errors='replace').splitlines(),
                    err_lines=stderr.decode(errors='replace').splitlines(), attempts=attempts,
                    boots=int(boots.read_text()) if boots.exists() else 0,
                    probe=probe.read_bytes() if probe.exists() else None)


def lines(r, prefix, stream='err_lines'):
    return [line for line in r[stream] if line.startswith(prefix)]


def check(r, *, rc, rerolls, fails=0, harness_errors=0, green, parser_errors=0):
    """rerolls: the class expected on each HARNESS re-roll line, in order ('' = a blank class)."""
    label = r['label']
    tail = f"stdout={r['out_lines'][-3:]} stderr={r['err_lines'][-3:]}"
    ok = expect(label, r['rc'] == rc, f"exit {r['rc']}, want {rc}; {tail}")
    got = lines(r, 'HARNESS re-roll:')
    ok &= expect(label, len(got) == len(rerolls) and all(f' = {want} (' in line if not want else f' = {want}' in line
                                                         for line, want in zip(got, rerolls)),
                 f're-roll lines {got}, want classes {rerolls}')
    failed = lines(r, 'FAIL: ', 'out_lines')
    ok &= expect(label, len(failed) == fails, f'{len(failed)} FAIL: line(s), want {fails}: {failed}')
    errors = lines(r, 'HARNESS-ERROR', 'out_lines')
    ok &= expect(label, len(errors) == harness_errors, f'{len(errors)} HARNESS-ERROR line(s), want {harness_errors}')
    ok &= expect(label, ('GREEN probe' in r['out_lines']) == green, f'GREEN probe printed: {not green}')
    parser = lines(r, 'PARSER-ERROR:')
    ok &= expect(label, len(parser) == parser_errors, f'{len(parser)} PARSER-ERROR line(s), want {parser_errors}')
    return ok


def crash_then_clean(r, status, wrapper=None):
    """The crashed attempt's capture holds the banner and more (bash's job report); it was not graded.

    Its pipeline status file holds the crash's status; wrapper, when given, is the status the wrapper
    returned on both boots (its cleanup's 5, which the classification never read)."""
    label = r['label']
    ok = expect(label, len(r['attempts']) == 2, f"{len(r['attempts'])} retained boot attempt(s), want 2")
    if ok:
        crashed, clean = r['attempts']
        got = [(a.get(PIPELINE_STATUS), a.get(WRAPPER_STATUS)) for a in (crashed, clean)]
        want = [(f'{status}\n'.encode(), f'{wrapper or status}\n'.encode()), (b'1\n', f'{wrapper or 1}\n'.encode())]
        ok &= expect(label, got == want, f'(pipeline, wrapper) status files {got!r}, want {want!r}')
        c, g = crashed.get('bochs_out.txt', b''), clean.get('bochs_out.txt', b'')
        ok &= expect(label, b'shutdown requested' in c and c.startswith(g) and len(c) > len(g),
                     'the crashed capture should be the clean capture plus a trailer (the job report)')
        ok &= expect(label, r['probe'] == g, 'the graded log must be the clean attempt, byte for byte')
    return ok


def class_table(bench, rows):
    """The harness's own post-banner classifier over every status 0..255, in one bash run."""
    label = 'CLASS-TABLE'
    probe = ('source "$1" || exit 97; for st in $(seq 0 255) "" abc; do '
             'cls="$(f2__post_banner_class "$st")"; rc=$?; term=0; f2__terminal_class "$cls" && term=1; '
             'printf "%s\\t%s\\t%s\\t%s\\n" "$st" "$rc" "$term" "$cls"; done; '
             'for cls in COMPLETED NO-OUTPUT NO-SHUTDOWN "EMULATOR-CRASH(status 139 = signal 11 after the shutdown banner)" '
             '"DISK-BUILD(mkfs)"; do f2__terminal_class "$cls" && echo "TERMINAL $cls"; done; exit 0')
    r = subprocess.run(['bash', '-c', probe, 'class-table', str(HARNESS)], env=bench.env, capture_output=True, timeout=60)
    got = {}
    for line in r.stdout.decode().splitlines():
        if line.startswith('TERMINAL '):
            expect(label, False, f'f2__terminal_class accepts a non-terminal class: {line}')
            continue
        st, rc, term, cls = line.split('\t')
        got[st] = (int(rc), term == '1', cls)
    ok = expect(label, r.returncode == 0 and len(got) == 258, f'rc={r.returncode} rows={len(got)} {r.stderr[-300:]!r}')
    for st in range(256):
        rc, term, cls = got.get(str(st), (None, None, None))
        if st in CRASH_STATUSES:
            want = (1, False, f'EMULATOR-CRASH(status {st} = signal {CRASH_STATUSES[st]} after the shutdown banner)')
            ok &= expect(label, (rc, term, cls) == want, f'status {st}: {(rc, term, cls)!r}, want {want!r}')
        elif 128 < st <= 192:
            ok &= expect(label, rc == 2 and term and cls.startswith(f'KILLED-AFTER-BANNER(status {st} = signal {st - 128}: ')
                         and '(a timeout, or an external kill), not an emulator crash' in cls,
                         f'status {st}: {(rc, term, cls)!r}, want a terminal KILLED-AFTER-BANNER naming a kill')
        else:
            ok &= expect(label, (rc, term, cls) == (0, False, ''), f'status {st}: {(rc, term, cls)!r}, want a finished boot')
    for st in ('', 'abc'):
        ok &= expect(label, got.get(st) == (0, False, ''), f'status {st!r}: {got.get(st)!r}, want no class')
    rows.append((f'{label}: exactly 132/134/135/136/139 re-roll as EMULATOR-CRASH; every other 129..192 is a '
                 'terminal KILLED-AFTER-BANNER; every other status is a finished boot', ok))


def status_file_table(bench, rows):
    """f2__status_class, the pipeline status file's reader, over crafted files, in one bash run."""
    label = 'STATUS-FILE-TABLE'
    cases = {'missing': None, 'empty': b'', 'newline': b'\n', 'word': b'abc\n', 'suffix': b'12a\n',
             'leading-space': b' 1\n', 'trailing-space': b'1 \n', 'over-255': b'256\n', 'negative': b'-1\n',
             'leading-zero': b'01\n', 'two-lines': b'1\n2\n', 'directory': 'DIR',
             'bochs-exit': b'1\n', 'zero-no-newline': b'0', 'wrapper-like-5': b'5\n',
             'segv': b'139\n', 'kill-no-newline': b'137'}
    box = bench.root / 'status-files'
    box.mkdir()
    for name, content in cases.items():
        if content == 'DIR':
            (box / name).mkdir()
        elif content is not None:
            (box / name).write_bytes(content)
    probe = ('source "$1" || exit 97; shift; for f in "$@"; do cls="$(f2__status_class "$f")"; rc=$?; '
             'printf "%s\t%s\t%s\n" "${f##*/}" "$rc" "$cls"; done; exit 0')
    r = subprocess.run(['bash', '-c', probe, 'status-table', str(HARNESS), *(str(box / n) for n in cases)],
                       env=bench.env, capture_output=True, timeout=60)
    got = {name: (int(rc), cls) for name, rc, cls in (line.split('\t') for line in r.stdout.decode().splitlines())}
    ok = expect(label, r.returncode == 0 and len(got) == len(cases), f'rc={r.returncode} {got} {r.stderr[-300:]!r}')
    for name in cases:
        rc, cls = got.get(name, (None, ''))
        if name in ('bochs-exit', 'zero-no-newline', 'wrapper-like-5'):
            ok &= expect(label, (rc, cls) == (0, ''), f'{name}: {(rc, cls)!r}, want a finished boot')
        elif name == 'segv':
            ok &= expect(label, rc == 1 and cls.startswith('EMULATOR-CRASH(status 139 = signal 11'), f'{name}: {(rc, cls)!r}')
        elif name == 'kill-no-newline':
            ok &= expect(label, rc == 2 and cls.startswith('KILLED-AFTER-BANNER(status 137 = signal 9'), f'{name}: {(rc, cls)!r}')
        else:
            ok &= expect(label, rc == 1 and cls.startswith('NO-STATUS(') and f'/{name}:' in cls,
                         f'{name}: {(rc, cls)!r}, want NO-STATUS naming the file')
    rows.append((f'{label}: {len(cases)} status files; only a plain number 0..255 is read, anything else is NO-STATUS', ok))


def terminal(r, status, signal_number, *, boots=1):
    """One boot killed after the banner: the leg ended at once, nothing graded, and the marker says it was a kill."""
    label = r['label']
    errors = lines(r, 'HARNESS-ERROR', 'out_lines')
    want = f'= KILLED-AFTER-BANNER(status {status} = signal {signal_number}: a kill after the shutdown banner'
    ok = expect(label, r['boots'] == boots, f"{r['boots']} boot(s), want {boots}: a terminal class is never re-rolled")
    ok &= expect(label, not r['probe'], f"the graded log holds {r['probe']!r}; a killed boot is never graded")
    ok &= expect(label, errors and want in errors[0] and 'not an emulator crash' in errors[0] and 'not re-rolled' in errors[0]
                 and 'not graded' in errors[0], f'terminal marker {errors[:1]!r}, want one naming {want!r}')
    return ok


def link66_rows(root, rows):
    """The LINK66 rows and their NOTERMINAL column (the module docstring)."""
    lifted = {}
    for call, script, first, end in LINK66_LOOPS:
        text = script.read_text()
        ok = expect(f'LINK66-{call}-lift', text.count(first) == 1, f'{text.count(first)} copies of {first.strip()!r} in {script.name}')
        start = text.index(first)
        body = textwrap.dedent(text[start:text.index(end, start) + len(end)])
        stops = [line for line in body.splitlines(keepends=True) if LINK66_STOP in line]
        ok &= expect(f'LINK66-{call}-lift', len(stops) == 1, f'{len(stops)} terminal-class stop line(s) in the lifted {call} loop, want 1')
        if ok:
            lifted[call] = (body, body.replace(stops[0], ''))
    driver = root / 'link66-driver.sh'
    driver.write_text(LINK66_DRIVER)

    def run(label, call, status, *, stop=True):
        directory = root / label
        directory.mkdir()
        leg = directory / 'leg.sh'
        leg.write_text(lifted[call][0 if stop else 1])
        env = dict(os.environ, TEST_SCRIPTS=str(HERE), TEST_HARNESS=str(HARNESS), TEST_LEG=str(leg), TEST_CALL=call,
                   TEST_OUT=str(directory), FIRST_STATUS=str(status), F2_GATE='link66', KERNEL_EVIDENCE_DIR='',
                   KERNEL_PARSE_ERROR_FILE='')
        r = subprocess.run(['bash', str(driver)], env=env, capture_output=True, timeout=60)
        (directory / 'driver.stdout').write_bytes(r.stdout)
        (directory / 'driver.stderr').write_bytes(r.stderr)
        out, err = r.stdout.decode(errors='replace').splitlines(), r.stderr.decode(errors='replace').splitlines()
        result = [line for line in out if line.startswith('RESULT: ')]
        return label, out, err, result[-1] if result else f'no RESULT line (exit {r.returncode}): {err[-3:]}'

    def terminal(label, out, err, result, status, signal_number, boots=1):
        want = f'= KILLED-AFTER-BANNER(status {status} = signal {signal_number}: a kill after the shutdown banner'
        errors = [line for line in out if line.startswith('HARNESS-ERROR')]
        ok = expect(label, result == f'RESULT: boots={boots} leg_rc=1 summary_rc=1 pass=0 fail=0', result)
        ok &= expect(label, len(errors) == 1 and 'attempt 1 ' + want in errors[0] and 'not re-rolled' in errors[0]
                     and 'not graded' in errors[0], f'terminal marker {errors!r}, want one naming {want!r}')
        ok &= expect(label, not [line for line in err if line.startswith('HARNESS re-roll:')], f'a terminal class was re-rolled: {err}')
        return ok

    if set(lifted) != {call for call, *_ in LINK66_LOOPS}:
        rows.append(('LINK66 loops lifted', False))
        return
    for call, status, signal_number in (('boundary', 137, 9), ('boundary', 143, 15), ('draw', 137, 9), ('probe', 137, 9),
                                        ('seedpin', 137, 9)):
        label, out, err, result = run(f'LINK66-{call}-{"kill" if status == 137 else "term"}', call, status)
        rows.append((label, terminal(label, out, err, result, status, signal_number)))
    label, out, err, result = run('LINK66-boundary-crash', 'boundary', 139)
    rerolls = [line for line in err if line.startswith('HARNESS re-roll:')]
    ok = expect(label, result == 'RESULT: boots=2 leg_rc=0 summary_rc=0 pass=1 fail=0', result)
    ok &= expect(label, len(rerolls) == 1 and 'EMULATOR-CRASH(status 139 = signal 11' in rerolls[0], f're-roll lines {rerolls}')
    rows.append((label, ok))
    label, out, err, result = run('LINK66-boundary-timeout', 'boundary', 124)
    ok = expect(label, result == 'RESULT: boots=1 leg_rc=1 summary_rc=0 pass=0 fail=1', result)
    ok &= expect(label, not [line for line in err if line.startswith('HARNESS re-roll:')], f'a finished boot was re-rolled: {err}')
    rows.append((label, ok))
    for call, green in (('boundary', 'RESULT: boots=2 leg_rc=0 summary_rc=0 pass=1 fail=0'),
                        ('probe', 'RESULT: boots=2 leg_rc=0 summary_rc=0 pass=0 fail=0'),
                        ('seedpin', 'RESULT: boots=2 leg_rc=0 summary_rc=0 pass=0 fail=0')):
        label, out, err, result = run(f'NOTERMINAL-{call}-kill', call, 137, stop=False)
        rerolls = [line for line in err if line.startswith('HARNESS re-roll:')]
        ok = expect(label, result == green, f'{result}; without the stop the kill must re-roll into GREEN, want {green}')
        ok &= expect(label, len(rerolls) == 1 and 'KILLED-AFTER-BANNER(status 137' in rerolls[0], f're-roll lines {rerolls}')
        rows.append((label, ok))


def main():
    rows = []
    with tempfile.TemporaryDirectory(prefix='herbert-emulator-crash-check-') as temporary:
        bench = Bench(Path(temporary))
        class_table(bench, rows)
        status_file_table(bench, rows)
        source = HARNESS.read_text()
        mutants = {}
        counts = {STATUS_CHECK: lambda n: n == 1, SCOPED_CLEANUP: lambda n: n >= 4, CRASH_LIST: lambda n: n == 1,
                  CLASSIFY_FROM: lambda n: n == 2}
        for name, pairs in (('CRASHALL', [(CRASH_LIST, CRASH_ALL)]),
                            ('NOSTATUS', [(STATUS_CHECK, '')]),
                            ('WRAPPERSTATUS', [(CLASSIFY_FROM, CLASSIFY_FROM_WRAPPER)]),
                            ('SHAREDSCOPE', [(SCOPED_CLEANUP, SHARED_CLEANUP)]),
                            ('PREFIX', [(STATUS_CHECK, ''), (SCOPED_CLEANUP, SHARED_CLEANUP)])):
            text = source
            for old, new in pairs:
                count = text.count(old)
                expect(f'{name}-copy', counts[old](count), f'{count} occurrence(s) of {old!r} in {HARNESS.name}')
                text = text.replace(old, new)
            path = bench.root / name.lower() / HARNESS.name
            path.parent.mkdir()
            path.write_text(text)
            mutants[name] = path
        for routing in ROUTINGS:
            run = lambda row, mode, plan, harness=HARNESS, column='TREE', **extra: bench.crash_run(
                f'{column}-{routing}-{row}', harness, routing=routing, mode=mode, plan=plan, **extra)
            r = run('crash-then-ok', 'plain', 'segv,ok')
            rows.append((r['label'], check(r, rc=0, rerolls=['EMULATOR-CRASH(status 139 = signal 11'], green=True)
                         & crash_then_clean(r, 139)))
            r = run('abort-then-ok', 'plain', 'abort,ok')
            rows.append((r['label'], check(r, rc=0, rerolls=['EMULATOR-CRASH(status 134 = signal 6'], green=True)
                         & crash_then_clean(r, 134)))
            r = run('kill-then-ok', 'plain', 'kill,ok')
            rows.append((r['label'], check(r, rc=1, rerolls=[], harness_errors=2, green=False) & terminal(r, 137, 9)))
            r = run('wrong-kill-then-ok', 'plain', 'wrongkill,ok')
            rows.append((r['label'], check(r, rc=1, rerolls=[], harness_errors=2, green=False) & terminal(r, 137, 9)))
            r = run('term-then-ok', 'plain', 'term,ok')
            rows.append((r['label'], check(r, rc=1, rerolls=[], harness_errors=2, green=False) & terminal(r, 143, 15)))
            r = run('crash-always', 'plain', 'segv')
            ok = check(r, rc=1, rerolls=['EMULATOR-CRASH(status 139'] * 3, harness_errors=2, green=False)
            ok &= expect(r['label'], r['boots'] == 3 and not r['probe'], 'three boots and nothing graded')
            rows.append((r['label'], ok))
            r = run('early-crash', 'plain', 'early-segv,ok')
            rows.append((r['label'], check(r, rc=0, rerolls=['NO-SHUTDOWN'], green=True)))
            r = run('malformed-normal', 'plain', 'junk')
            ok = check(r, rc=1, rerolls=[], fails=1, green=False)
            ok &= expect(r['label'], all(PARSE_ERROR in line for line in lines(r, 'FAIL: ', 'out_lines')),
                         'the RED must be the parser refusing the unknown text')
            rows.append((r['label'], ok))
            r = run('feed-replay', 'feed-replay', 'segv,ok')
            ok = check(r, rc=0, rerolls=['EMULATOR-CRASH(status 139'], green=True)
            ok &= expect(r['label'], not any('REPLAY' in line for line in r['err_lines']), 'a crash must not start a replay')
            rows.append((r['label'], ok))
            r = run('kill-replay', 'feed-replay', 'kill,ok')
            ok = check(r, rc=1, rerolls=[], harness_errors=2, green=False) & terminal(r, 137, 9)
            ok &= expect(r['label'], not any('REPLAY' in line for line in r['err_lines']), 'a kill must not start a replay')
            rows.append((r['label'], ok))
            r = run('replay-then-kill', 'feed-replay', 'junk,kill')
            ok = check(r, rc=1, rerolls=[], fails=1, green=False)
            ok &= expect(r['label'], r['boots'] == 2 and len(lines(r, '  REPLAY probe:')) == 1,
                         f"{r['boots']} boot(s), want 2: the completed RED and its replay, killed and not re-rolled")
            ok &= expect(r['label'], all('UNADJUDICATED' in line and 'KILLED-AFTER-BANNER(status 137' in line
                                         for line in lines(r, 'FAIL: ', 'out_lines')),
                         'the killed replay must leave the completed RED unadjudicated, fail_test\'d')
            rows.append((r['label'], ok))
            r = run('poisoned-replay', 'poisoned-replay', 'junk,ok')
            ok = check(r, rc=1, rerolls=[], green=False, parser_errors=1)
            ok &= expect(r['label'], len(lines(r, '  REPLAY probe:')) == 1
                         and sum('FLAKE-DISCRIMINATED' in line for line in r['out_lines']) == 1,
                         "attempt 1's graded RED and its replay's real result must both be logged")
            ok &= expect(r['label'], r['boots'] == 2, f"{r['boots']} boots, want 2 (the RED and its replay)")
            rows.append((r['label'], ok))
            r = run('ci-shape', 'poisoned-replay', 'segv,ok')
            ok = check(r, rc=0, rerolls=['EMULATOR-CRASH(status 139'], green=True)
            ok &= expect(r['label'], not any('REPLAY' in line for line in r['err_lines']), 'a crash must not start a replay')
            rows.append((r['label'], ok))
            # The wrapper's EXIT-trap cleanup fails on every boot and exits 5 in place of the command's status.
            r = run('overwrite-crash-then-ok', 'plain', 'segv,ok', xvfb='cleanup-error')
            rows.append((r['label'], check(r, rc=0, rerolls=['EMULATOR-CRASH(status 139 = signal 11'], green=True)
                         & crash_then_clean(r, 139, wrapper=5)))
            r = run('overwrite-crash-always', 'plain', 'segv', xvfb='cleanup-error')
            ok = check(r, rc=1, rerolls=['EMULATOR-CRASH(status 139'] * 3, harness_errors=2, green=False)
            ok &= expect(r['label'], r['boots'] == 3 and not r['probe'], 'three boots and nothing graded')
            ok &= expect(r['label'], [a.get(WRAPPER_STATUS) for a in r['attempts']] == [b'5\n'] * 3,
                         f"wrapper status files {[a.get(WRAPPER_STATUS) for a in r['attempts']]!r}, want 5 on each boot")
            rows.append((r['label'], ok))
            r = run('overwrite-kill-then-ok', 'plain', 'kill,ok', xvfb='cleanup-error')
            rows.append((r['label'], check(r, rc=1, rerolls=[], harness_errors=2, green=False) & terminal(r, 137, 9)))
            r = run('overwrite-wrong-answer', 'plain', 'ok', xvfb='cleanup-error', guest='01')
            ok = check(r, rc=1, rerolls=[], fails=1, green=False)
            ok &= expect(r['label'], all(WRONG_ANSWER in line for line in lines(r, 'FAIL: ', 'out_lines')),
                         'a normal wrong answer under the overwrite must still be graded RED')
            rows.append((r['label'], ok))
            r = run('nostatus-then-ok', 'plain', 'nostatus,ok')
            ok = check(r, rc=0, rerolls=['NO-STATUS('], green=True)
            ok &= expect(r['label'], r['boots'] == 2 and len(r['attempts']) == 2 and PIPELINE_STATUS not in r['attempts'][0]
                         and r['probe'] == r['attempts'][1].get('bochs_out.txt'),
                         'the boot without a readable status is not graded; the next one is')
            rows.append((r['label'], ok))
            r = run('nostatus-always', 'plain', 'nostatus')
            ok = check(r, rc=1, rerolls=['NO-STATUS('] * 3, harness_errors=2, green=False)
            ok &= expect(r['label'], r['boots'] == 3 and not r['probe'], 'three boots and nothing graded')
            rows.append((r['label'], ok))
            r = run('link62-overwrite', 'link62', 'segv,ok', xvfb='cleanup-error', guest='2a')
            ok = check(r, rc=0, rerolls=['EMULATOR-CRASH(status 139 = signal 11'], green=True) & crash_then_clean(r, 139, wrapper=5)
            rows.append((r['label'], ok))
            if routing != 'no-merge':   # the mutation columns under GitHub's routing only
                continue
            r = run('kill-then-ok', 'plain', 'kill,ok', mutants['CRASHALL'], 'CRASHALL')
            ok = check(r, rc=0, rerolls=['EMULATOR-CRASH(status 137 = signal 9'], green=True)
            ok &= expect(r['label'], r['boots'] == 2, 'with every signal counted as a crash the kill is re-rolled into a pass')
            rows.append((r['label'], ok))
            r = run('crash-then-ok', 'plain', 'segv,ok', mutants['NOSTATUS'], 'NOSTATUS')
            ok = check(r, rc=1, rerolls=[], fails=1, green=False)
            ok &= expect(r['label'], all(PARSE_ERROR in line for line in lines(r, 'FAIL: ', 'out_lines')),
                         'without the status the crashed capture is graded, and the parser refuses its trailer')
            rows.append((r['label'], ok))
            r = run('overwrite-crash-then-ok', 'plain', 'segv,ok', mutants['WRAPPERSTATUS'], 'WRAPPERSTATUS',
                    xvfb='cleanup-error')
            ok = check(r, rc=1, rerolls=[], fails=1, green=False)
            ok &= expect(r['label'], r['boots'] == 1 and all(PARSE_ERROR in line for line in lines(r, 'FAIL: ', 'out_lines')),
                         "from the wrapper's overwritten status the crashed capture is graded, and the parser refuses it")
            rows.append((r['label'], ok))
            r = run('link62-overwrite', 'link62', 'segv,ok', mutants['WRAPPERSTATUS'], 'WRAPPERSTATUS',
                    xvfb='cleanup-error', guest='2a')
            ok = check(r, rc=0, rerolls=[], green=True)
            ok &= expect(r['label'], r['boots'] == 1 and r['probe'] and b'Segmentation fault' in r['probe'],
                         "from the wrapper's overwritten status link62's raw-frame grader passes the crashed capture "
                         'GREEN (the false GREEN the tree refuses)')
            rows.append((r['label'], ok))
            r = run('poisoned-replay', 'poisoned-replay', 'junk,ok', mutants['SHAREDSCOPE'], 'SHAREDSCOPE')
            ok = check(r, rc=1, rerolls=['', '', ''], green=False, parser_errors=4)
            ok &= expect(r['label'], not any('FLAKE-DISCRIMINATED' in line for line in r['out_lines']),
                         "the shared scope must lose the replay's result")
            rows.append((r['label'], ok))
            r = run('ci-shape', 'poisoned-replay', 'segv,ok', mutants['PREFIX'], 'PREFIX')
            ok = check(r, rc=1, rerolls=['', '', ''], green=False, parser_errors=4)
            ok &= expect(r['label'], len(lines(r, '  REPLAY probe:')) == 1 and r['boots'] == 4,
                         f"want one REPLAY on the crash's parse error and four boots, got {r['boots']}")
            rows.append((r['label'], ok))
        link66_dir = bench.root / 'link66'
        link66_dir.mkdir()
        link66_rows(link66_dir, rows)
    for label, ok in rows:
        print(f"{'PASS' if ok else 'FAIL'} {label}")
    if FAILURES:
        print(f'FAIL bochs emulator crash: {len(FAILURES)} check(s) failed')
        sys.exit(1)
    print(f'PASS bochs emulator crash: {len(rows)} rows; only a positively identified emulator crash after the '
          'banner is re-rolled, a kill after it ends its leg at once and is never graded, a malformed capture from '
          "a normal exit is still RED, and each attempt's real result is logged (controlled commands; no emulator "
          'qualification)')


if __name__ == '__main__':
    main()
