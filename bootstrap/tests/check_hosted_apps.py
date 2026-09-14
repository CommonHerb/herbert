#!/usr/bin/env python3
"""Independent pixel/input/file observations of Herbert's hosted applications.

Xvfb, XTest, Xlib and Python are TEST tools. Only owned private-display windows
receive input. No test hooks, foreign runtime, or graphics library in the apps.
Evidence (including failed frames, input history and memory samples) is retained.
"""
import argparse
import contextlib
import hashlib
import json
import os
from pathlib import Path
import signal
import shutil
import shlex
import struct
import subprocess
import tempfile
import time

from check_grid_map import DEFAULT_MAP
from check_desktop import XConnection, center, memory, private_display, save_png

ROOT = Path(__file__).resolve().parents[2]


def wait_for(predicate, description, timeout=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(.025)
    raise AssertionError('timed out: ' + description)


class App:
    def __init__(self, image, path, title, size, x, display, evidence, label):
        self.x, self.evidence, self.label = x, evidence, label
        self.window = None
        self.inputs = []
        self.started = time.monotonic()
        before = x.windows()
        env = dict(os.environ, DISPLAY=display)
        env.pop('XAUTHORITY', None)
        self.out = (evidence / (label + '.stdout')).open('wb')
        self.err = (evidence / (label + '.stderr')).open('wb')
        self.p = subprocess.Popen([str(image.resolve()), str(path.resolve())], env=env,
                                  stdin=subprocess.DEVNULL, stdout=self.out, stderr=self.err)
        try:
            def created():
                assert self.p.poll() is None, f'{label} exited: {self.p.returncode}'
                candidates = [w for w in x.windows() - before
                              if x.name(w) == title and x.geometry(w) == size]
                assert len(candidates) <= 1, 'ambiguous test window'
                if candidates:
                    self.window = candidates[0]
                    return True
            wait_for(created, label + ' window')
            x.focus(self.window)
            time.sleep(.15)
        except BaseException:
            self.close()
            raise

    def key(self, key, down):
        self.inputs.append([round(time.monotonic() - self.started, 4), key, down])
        self.x.key(self.window, key, down)

    def tap(self, key, modifier=None, pause=.04):
        if modifier:
            self.key(modifier, True)
        self.key(key, True)
        self.key(key, False)
        if modifier:
            self.key(modifier, False)
        if pause:
            time.sleep(pause)

    def type(self, text, pause=.008):
        plain = {' ': 'space', '\n': 'Return', '\t': 'Tab', ',': 'comma', '.': 'period',
                 '-': 'minus', '=': 'equal', '/': 'slash', ';': 'semicolon',
                 "'": 'apostrophe', '[': 'bracketleft', ']': 'bracketright',
                 '\\': 'backslash', '`': 'grave'}
        shifted = dict(zip('!@#$%^&*()_+{}|:"<>?~',
                           ['1','2','3','4','5','6','7','8','9','0','minus','equal',
                            'bracketleft','bracketright','backslash','semicolon',
                            'apostrophe','comma','period','slash','grave']))
        for ch in text:
            if ch.isascii() and ch.isalpha() and ch.isupper():
                self.tap(ch.lower(), 'Shift_L', pause)
            elif ch in shifted:
                self.tap(shifted[ch], 'Shift_L', pause)
            else:
                self.tap(plain.get(ch, ch), pause=pause)

    def stop(self):
        self.p.send_signal(signal.SIGSTOP)
        wait_for(lambda: '\nState:\tT' in Path(f'/proc/{self.p.pid}/status').read_text(),
                 'owned application stopped', timeout=2)

    def frame(self, name=None):
        assert self.p.poll() is None, (self.label, self.p.returncode)
        frame = self.x.snapshot(self.window)
        if name:
            save_png(self.evidence / f'{self.label}-{name}.png', frame)
        return frame

    def finish(self):
        assert self.p.wait(timeout=5) == 0, self.label
        wait_for(lambda: self.window not in self.x.windows(), 'window removal')
        self.out.flush()
        self.err.flush()
        assert not (self.evidence / (self.label + '.stdout')).read_bytes()
        assert not (self.evidence / (self.label + '.stderr')).read_bytes()

    def close(self):
        if self.p.poll() is None:
            # Also resumes our deliberate queue-burst stop on test failure.
            self.p.send_signal(signal.SIGCONT)
            if self.window is not None:
                with contextlib.suppress(Exception):
                    self.frame('final-or-failure')
            self.p.terminate()
            try:
                self.p.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.p.kill()
                self.p.wait()
        self.out.close()
        self.err.close()
        (self.evidence / (self.label + '-input.json')).write_text(json.dumps(self.inputs, indent=2)+'\n')


@contextlib.contextmanager
def application(*args):
    app = App(*args)
    try:
        yield app
    finally:
        app.close()


def rgb_at(frame, x, y):
    offset = (y * frame['width'] + x) * 3
    return int.from_bytes(frame['rgb'][offset:offset+3], 'big')


def region(frame, x, y, w, h):
    return b''.join(frame['rgb'][((y+i)*frame['width']+x)*3:((y+i)*frame['width']+x+w)*3]
                    for i in range(h))


def stable_memory(samples, label):
    # Permit one small allocator/kernel accounting granule, never ongoing growth.
    assert len(samples) >= 2, (label, 'fewer than two memory observations')
    assert max(s['VmSize'] for s in samples) == min(s['VmSize'] for s in samples), (label, samples)
    assert max(s['Rss'] for s in samples) - min(s['Rss'] for s in samples) <= 64, (label, samples)


def maze_checks(args, x, display, evidence, passed):
    path = evidence / 'small-maze.txt'
    path.write_text('#######\n#P..###\n###.###\n###...#\n#######\n')
    with application(args.maze, path, b'Herbert - Maze', (800,640), x, display, evidence, 'maze-rules') as app:
        initial_frame = app.frame('start')
        start = center(initial_frame)
        initial_count = region(initial_frame,94,77,40,14)
        first_dot = (int(start[0])+25, int(start[1])+1)
        assert rgb_at(initial_frame,*first_dot) == 14868688, 'test dot absent'
        # Map layout is a test fixture; positions follow the documented 24px cells.
        def reach(key, target):
            app.key(key, True)
            try:
                wait_for(lambda: all(abs(a-b)<1 for a,b in zip(center(app.frame()), target)),
                         'maze arrival ' + key)
                time.sleep(.2)
                assert all(abs(a-b)<1 for a,b in zip(center(app.frame()), target)), 'wall crossed'
            finally:
                app.key(key, False)
        reach('Left', start)
        reach('Up', start)
        reach('Right', (start[0]+48, start[1]))
        assert rgb_at(app.frame(),*first_dot) == 1384240, 'collected dot still present'
        reach('Down', (start[0]+48, start[1]+48))
        before = app.frame()
        app.key('Right', True)
        try:
            wait_for(lambda: rgb_at(app.frame(), 216,280) == 6867876, 'completion panel')
        finally:
            app.key('Right', False)
        won = app.frame('complete')
        assert region(before, 94,77,40,14) != region(won,94,77,40,14), 'dot counter unchanged'
        app.tap('r')
        def at_start():
            frame = app.frame()
            return frame['bbox'] is not None and all(abs(a-b)<1 for a,b in zip(center(frame),start))
        wait_for(at_start, 'restart position')
        restarted = app.frame()
        assert region(restarted,94,77,40,14) == initial_count, 'initial dot count not restored'
        assert rgb_at(restarted,*first_dot) == 14868688, 'restart did not restore collectible'
        app.tap('Escape')
        app.finish()
        passed('maze-walls-collection-completion-restart-escape')

    stress_map = evidence / 'sustained-maze.txt'
    stress_map.write_bytes(DEFAULT_MAP)
    with application(args.maze, stress_map, b'Herbert - Maze', (800,640), x, display, evidence, 'maze-sustained') as app:
        spawn = center(app.frame('default-map'))
        samples, cycles = [], 0
        trajectory = []
        started = time.monotonic()
        while time.monotonic() - started < args.seconds:
            app.tap('r')
            wait_for(lambda: center(app.frame()) == spawn, 'sustained restart restores spawn')
            app.key('d', True)
            wait_for(lambda: center(app.frame())[0] > spawn[0], 'sustained movement after restart')
            time.sleep(.07)
            app.key('d', False)
            moved = center(app.frame())
            assert moved[0] > spawn[0] and moved[1] == spawn[1], 'movement stopped during restarts'
            cycles += 1
            trajectory.append({'cycle':cycles,'spawn':spawn,'moved':moved})
            (evidence/'maze-trajectory.json').write_text(json.dumps(trajectory, indent=2)+'\n')
            if cycles % 4 == 0:
                sample = memory(app.p.pid)
                sample['seconds'] = round(time.monotonic()-started,3)
                samples.append(sample)
                (evidence/'maze-memory.json').write_text(json.dumps(samples, indent=2)+'\n')
        app.key('d', False)
        assert cycles >= 4
        stable_memory(samples, 'maze restarts and drawing')
        x.delete(app.window)
        app.finish()
        passed('maze-sustained-movement-restarts-memory-wm-close', cycles=cycles, samples=samples)


def notes_checks(args, x, display, evidence, passed):
    path = evidence / 'notes.txt'
    with application(args.notes, path, b'Herbert - Notes', (900,600), x, display, evidence, 'notes-edit') as app:
        blank = app.frame('blank')
        expected = 'Hello, World!\n\tHerbert 123.\n'
        app.type(expected)
        app.tap('s', 'Control_L')
        wait_for(lambda: path.exists() and path.read_bytes()==expected.encode(), 'first exact save')
        assert path.stat().st_mode & 0o777 == 0o600
        typed = app.frame('typed')
        assert (15265527).to_bytes(3,'big') in region(typed,28,102,500,54), 'typed text ink absent'
        assert region(blank,28,102,500,54) != region(typed,28,102,500,54), 'typed text invisible'
        app.tap('Home', 'Control_L')
        for _ in range(5): app.tap('Right')
        app.tap('Delete')
        expected = 'Hello World!\n\tHerbert 123.\n'
        app.tap('End', 'Control_L')
        app.tap('BackSpace')
        expected = expected[:-1]
        app.tap('s', 'Control_L')
        wait_for(lambda: path.read_bytes()==expected.encode(), 'navigation and deletion save')
        app.tap('Caps_Lock')
        app.tap('a')
        app.tap('b', 'Shift_L')
        app.tap('Caps_Lock')
        expected += 'Ab'
        # Force >256 presses to be pending, proving queued input crosses drains.
        app.stop()
        app.type('ab' * 170, pause=0)
        app.p.send_signal(signal.SIGCONT)
        expected += 'ab' * 170
        app.tap('s', 'Control_L')
        wait_for(lambda: path.read_bytes()==expected.encode(), 'ordered burst of 340 characters')
        # Accepted keypresses immediately before focus-out must not disappear.
        app.stop()
        app.type('focus', pause=0)
        x.focus(x.root)
        app.p.send_signal(signal.SIGCONT)
        time.sleep(.15)
        x.focus(app.window)
        time.sleep(.05)
        expected += 'focus'
        app.tap('s', 'Control_L')
        wait_for(lambda: path.read_bytes()==expected.encode(), 'typing before focus-out')
        app.type('!')
        x.delete(app.window)
        time.sleep(.15)
        assert app.p.poll() is None, 'dirty close silently discarded edits'
        wait_for(lambda: (16173151).to_bytes(3,'big') in region(app.frame(),28,560,810,7), 'visible dirty-close prompt')
        app.frame('dirty-close')
        app.tap('Escape')
        app.type('?')
        expected += '!?'
        app.tap('s', 'Control_L')
        wait_for(lambda: path.read_bytes()==expected.encode(), 'cancel close then save')
        app.tap('Home', 'Control_L')
        app.tap('Down')
        saved_first_row = region(app.frame('saved-before-close'),30,102,838,14)
        x.delete(app.window)
        app.finish()
        passed('notes-typing-shift-punctuation-navigation-save-burst-focus-dirtyclose')
    with application(args.notes, path, b'Herbert - Notes', (900,600), x, display, evidence, 'notes-reopen') as app:
        assert region(app.frame('reopened'),30,102,838,14) == saved_first_row, 'reopened glyphs differ from saved text'
        # A visible loaded row plus exact unchanged bytes after Ctrl+S confirms reopen.
        assert (15265527).to_bytes(3,'big') in region(app.frame(),28,102,500,14), 'loaded text ink absent'
        app.tap('s', 'Control_L')
        wait_for(lambda: path.read_bytes()==expected.encode(), 'reopen preserves bytes')
        app.type('discard')
        app.tap('q', 'Control_L')
        app.tap('q', 'Control_L')
        assert app.p.poll() is None, 'repeat quit discarded edits'
        app.tap('y')
        app.finish()
        assert path.read_bytes()==expected.encode()
        passed('notes-reopen-explicit-discard')

    fastclose = evidence / 'fast-close.txt'
    with application(args.notes, fastclose, b'Herbert - Notes', (900,600), x, display, evidence, 'notes-fast-close') as app:
        app.stop()
        app.type('y', pause=0)
        x.delete(app.window)
        app.p.send_signal(signal.SIGCONT)
        time.sleep(.2)
        assert app.p.poll() is None, 'close lost a preceding queued letter or used it as confirmation'
        assert not fastclose.exists(), 'close unexpectedly saved text'
        wait_for(lambda: (16173151).to_bytes(3,'big') in region(app.frame(),28,560,810,7), 'visible close confirmation after queued text')
        app.frame('confirmation')
        app.tap('s', 'Control_L')
        wait_for(lambda: fastclose.exists() and fastclose.read_bytes()==b'y', 'save preceding close-event text')
        x.delete(app.window)
        app.finish()
        passed('notes-queued-text-before-wm-close-needs-confirmation')

    conflict = evidence / 'conflict.txt'
    conflict.write_text('original\n')
    with application(args.notes, conflict, b'Herbert - Notes', (900,600), x, display, evidence, 'notes-conflict') as app:
        app.type('edited ')
        app.tap('Down')
        before_save_frame = app.frame()
        before_failure = region(before_save_frame,28,102,838,14)
        conflict.write_text('external\n')
        app.tap('s', 'Control_L')
        time.sleep(.2)
        assert conflict.read_text()=='external\n', 'external change overwritten'
        refused = app.frame('refused-save')
        assert region(refused,28,102,838,14) == before_failure, 'failed save changed in-memory text'
        assert region(refused,28,560,810,7) != region(before_save_frame,28,560,810,7), 'save warning text absent'
        assert (16173151).to_bytes(3,'big') in region(refused,28,560,810,7), 'save warning ink absent'
        copies_before = set(evidence.glob('herbert-rescue-*.txt'))
        app.key('Control_L', True)
        app.tap('s', 'Shift_L')
        app.key('Control_L', False)
        wait_for(lambda: len(set(evidence.glob('herbert-rescue-*.txt'))-copies_before)==1,
                 'rescue copy published after original conflict')
        rescued = (set(evidence.glob('herbert-rescue-*.txt'))-copies_before).pop()
        assert rescued.read_bytes()==b'edited original\n', 'rescue lost in-memory edits'
        assert rescued.stat().st_mode & 0o777 == 0o600, 'rescue is not private'
        assert conflict.read_bytes()==b'external\n', 'rescue replaced external document'
        wait_for(lambda: region(app.frame(),28,580,810,7)!=region(refused,28,580,810,7),
                 'rescue filename shown in footer')
        ordinary_rescue = app.frame('rescue-saved')
        x.delete(app.window)
        wait_for(lambda: region(app.frame(),28,560,810,7)!=region(ordinary_rescue,28,560,810,7),
                 'close prompt after rescue')
        copies_before = set(evidence.glob('herbert-rescue-*.txt'))
        app.key('Control_L', True)
        app.tap('s', 'Shift_L')
        app.key('Control_L', False)
        wait_for(lambda: len(set(evidence.glob('herbert-rescue-*.txt'))-copies_before)==1,
                 'second rescue from pending close')
        second_rescue = (set(evidence.glob('herbert-rescue-*.txt'))-copies_before).pop()
        assert second_rescue.read_bytes()==b'edited original\n'
        # A rescue while confirming must keep visible instructions for the
        # still-active modal state, unlike the ordinary rescue status.
        def second_rescue_visible():
            frame = app.frame()
            return (region(frame,28,580,84,7)==region(ordinary_rescue,28,580,84,7)
                    and region(frame,28,580,810,7)!=region(ordinary_rescue,28,580,810,7))
        wait_for(second_rescue_visible, 'second rescue basename rendered')
        pending_rescue = app.frame('rescue-with-close-pending')
        assert region(pending_rescue,28,560,810,7)!=region(ordinary_rescue,28,560,810,7), 'rescue hid pending-close status'
        assert conflict.read_bytes()==b'external\n'
        time.sleep(.1)
        assert app.p.poll() is None, 'save failure cleared dirty state'
        app.tap('y')
        app.finish()
        passed('notes-external-change-refused-rescue-copy-and-dirty-state-retained')

    dense = evidence / 'dense.txt'
    initial = ''.join(f'{i:02d}: ' + ''.join(chr(ch) for ch in range(32,127))+'\n' for i in range(32))
    dense.write_text(initial)
    with application(args.notes, dense, b'Herbert - Notes', (900,600), x, display, evidence, 'notes-sustained') as app:
        dense_top = region(app.frame('ascii-dense'),30,102,838,14)
        app.tap('Next'); app.tap('Next')
        wait_for(lambda: region(app.frame(),30,102,838,14) != dense_top, 'page down scrolls visible rows')
        app.frame('paged-down')
        app.tap('Prior'); app.tap('Prior')
        wait_for(lambda: region(app.frame(),30,102,838,14) == dense_top, 'page up restores visible rows')
        app.tap('End', 'Control_L')
        # Warm all drawing/edit/save paths before comparing the reusable footprint.
        app.type('x'); app.tap('BackSpace'); app.tap('s','Control_L')
        samples, cycles = [], 0
        started = time.monotonic()
        while time.monotonic() - started < args.seconds:
            app.type('test')
            app.tap('s', 'Control_L')
            wait_for(lambda: dense.read_text()==initial+'test', 'sustained insertion saved exact bytes')
            app.tap('BackSpace'); app.tap('BackSpace'); app.tap('BackSpace'); app.tap('BackSpace')
            app.tap('s', 'Control_L')
            wait_for(lambda: dense.read_text()==initial, 'sustained deletion saved exact bytes')
            app.tap('Home','Control_L'); app.tap('Next'); app.tap('Prior'); app.tap('End','Control_L')
            cycles += 1
            if cycles % 2 == 0:
                sample = memory(app.p.pid)
                sample['seconds'] = round(time.monotonic()-started,3)
                samples.append(sample)
                (evidence/'notes-memory.json').write_text(json.dumps(samples, indent=2)+'\n')
        assert cycles >= 2
        wait_for(lambda: dense.read_text()==initial, 'repeated edits and saves preserve exact text')
        stable_memory(samples, 'editor edits saves scrolling redraw')
        app.frame('scrolled')
        app.tap('Escape')
        app.finish()
        assert not list(evidence.glob('.herbert-save-*.tmp')), 'normal save leaked temporary files'
        passed('notes-sustained-edit-save-scroll-dense-render-memory', cycles=cycles, samples=samples)


def notes_fault_checks(args, x, display, evidence, passed):
    # A shell/strace launcher exists only in this test's scratch directory.
    # --kill-on-exit prevents an orphaned tracee if test cleanup stops the tracer.
    image = args.notes.resolve()
    gold = (16173151).to_bytes(3, 'big')
    for label,typing in [('edited-document','draft '),('clean-document','')]:
        d=evidence/('save-fault-'+label);d.mkdir();target=d/'notes.txt';target.write_text('base\n')
        launcher=d/'notes-under-fsync-fault'
        launcher.write_text('#!/bin/sh\nexec strace --kill-on-exit -y -o '+shlex.quote(str(d/'strace.log'))+' -e inject=fsync:error=EIO:when=2 '+shlex.quote(str(image))+' "$@"\n');launcher.chmod(0o700)
        with application(launcher,target,b'Herbert - Notes',(900,600),x,display,d,label) as app:
            clean=app.frame('initial-clean')
            saved_label=region(clean,806,542,42,7)
            if typing:app.type(typing)
            expected=(typing+'base\n').encode()
            old_inode=target.stat().st_ino
            before=app.frame('before-save')
            app.tap('s','Control_L')
            wait_for(lambda:target.read_bytes()==expected and target.stat().st_ino!=old_inode,'published expected bytes')
            wait_for(lambda:gold in region(app.frame(),28,560,810,7),'visible written-but-uncertain warning')
            warning=app.frame('published-uncertain')
            assert region(warning,28,560,810,7)!=region(before,28,560,810,7)
            assert region(warning,806,542,42,7)!=saved_label,'publication warning did not mark document unsaved'
            published_inode=target.stat().st_ino
            x.delete(app.window)
            wait_for(lambda:region(app.frame(),28,560,810,7)!=region(warning,28,560,810,7),'dirty-close confirmation prompt')
            prompt=app.frame('dirty-close-prompt')
            assert app.p.poll() is None and target.read_bytes()==expected
            app.tap('Escape')
            app.tap('s','Control_L')
            wait_for(lambda:target.stat().st_ino!=published_inode and region(app.frame(),806,542,42,7)==saved_label,'successful retry clears dirty state')
            retried=app.frame('retried-saved')
            assert gold not in region(retried,28,560,810,7)
            assert target.read_bytes()==expected and not list(d.glob('.herbert-save-*.tmp'))
            app.tap('Escape');app.finish()
        log=(d/'strace.log').read_text()
        injected=[line for line in log.splitlines() if 'fsync(' in line and 'INJECTED' in line]
        assert len(injected)==1 and str(d) in injected[0] and 'EIO' in injected[0],injected
        passed('notes-directory-sync-fault-'+label, expected_file_bytes=expected.decode(), injected_directory_fsync=injected[0])

def static_elf(path):
    data = path.read_bytes()
    assert data[:7] == b'\x7fELF\x02\x01\x01', 'expected little-endian ELF64'
    assert struct.unpack_from('<H', data, 18)[0] == 62, 'expected x86-64'
    offset = struct.unpack_from('<Q', data, 32)[0]
    size, count = struct.unpack_from('<HH', data, 54)
    assert size == 56 and count > 0 and offset + size * count <= len(data)
    types = [struct.unpack_from('<I', data, offset + i*size)[0] for i in range(count)]
    assert 1 in types and 2 not in types and 3 not in types, 'unexpected dynamic loader/dependencies'
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--maze', type=Path, default=ROOT/'build/maze')
    parser.add_argument('--notes', type=Path, default=ROOT/'build/notes')
    parser.add_argument('--seconds', type=float, default=120)
    parser.add_argument('--only', choices=['all','maze','notes'], default='all')
    parser.add_argument('--evidence', type=Path)
    args = parser.parse_args()
    assert args.seconds >= 3, 'at least 3 seconds required; release qualification uses default120'
    evidence = args.evidence or Path(tempfile.mkdtemp(prefix='herbert-hosted-apps-'))
    evidence.mkdir(parents=True, exist_ok=True)
    evidence = evidence.resolve()
    shutil.copyfile(__file__, evidence/'check_hosted_apps.py')
    shutil.copyfile(Path(__file__).with_name('check_desktop.py'), evidence/'check_desktop.py')
    shutil.copyfile(Path(__file__).with_name('check_grid_map.py'), evidence/'check_grid_map.py')
    for name, image in [('maze',args.maze),('notes',args.notes)]:
        shutil.copyfile(image, evidence/(name+'.elf'))
        combined = image.parent/(image.name+'-work')/'source.herb'
        if combined.exists():
            shutil.copyfile(combined, evidence/(name+'-source.herb'))
    result = {'mode':'private-Xvfb-XTest', 'scope':args.only, 'seconds_per_application':args.seconds, 'checks':[],
              'images':{name:static_elf(path)
                        for name,path in [('maze',args.maze),('notes',args.notes)]}}
    def passed(name, **details):
        result['checks'].append(dict(name=name, **details))
        print('PASS:', name, flush=True)
        (evidence/'result.json').write_text(json.dumps(result, indent=2)+'\n')
    print('Evidence:', evidence, flush=True)
    try:
        with private_display(evidence, size='1280x900') as display:
            x = XConnection(display)
            try:
                if args.only != 'notes':
                    maze_checks(args,x,display,evidence,passed)
                if args.only != 'maze':
                    notes_checks(args,x,display,evidence,passed)
                    notes_fault_checks(args,x,display,evidence,passed)
            finally:
                x.close()
    except BaseException as error:
        result['failure'] = repr(error)
        raise
    finally:
        (evidence/'result.json').write_text(json.dumps(result, indent=2)+'\n')
    print(f'hosted apps: {len(result["checks"])}/{len(result["checks"])} PASS')

if __name__ == '__main__':
    main()
