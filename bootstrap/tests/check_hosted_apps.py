#!/usr/bin/env python3
"""Independent pixel/input/file observations of Herbert's hosted applications.

Xvfb, XTest, Xlib and Python are TEST tools. Only owned private-display windows
receive input. No test hooks, foreign runtime, or graphics library in the apps.
Evidence (including failed frames, input history and memory samples) is retained.
"""
import argparse
import contextlib
import ctypes as C
import ctypes.util
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
    def __init__(self, image, path, title, size, x, display, evidence, label, cwd=None):
        self.x, self.evidence, self.label = x, evidence, label
        self.window = None
        self.inputs = []
        self.started = time.monotonic()
        before = x.windows()
        env = dict(os.environ, DISPLAY=display)
        env.pop('XAUTHORITY', None)
        self.out = (evidence / (label + '.stdout')).open('wb')
        self.err = (evidence / (label + '.stderr')).open('wb')
        # With cwd, the path is passed exactly as given, relative paths included.
        argument = str(path) if cwd else str(path.resolve())
        self.p = subprocess.Popen([str(image.resolve()), argument], env=env, cwd=cwd,
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
            # The window can match its title and size before the map request lands.
            # X answers focus on an unmapped window with BadMatch, and this harness's
            # error handler makes that error silent, so focus stays where it was. The
            # application then receives keys by pointer position but drops them,
            # because it accepts input only after it has seen FocusIn. Keep asking for
            # focus until the server reports the window owns it, then wait until this
            # harness connection has observed the FocusIn. That is not an application
            # acknowledgment: the server queues the focus transition ahead of any later
            # injected key on the application's own stream, which reads sequentially,
            # so the application sets its focus flag before the first key is dispatched.
            x.watch_focus(self.window)
            def focused():
                x.focus(self.window)
                return x.owns_focus(self.window)
            wait_for(focused, label + ' keyboard focus')
            wait_for(lambda: any(event['event'] == 'in' for event in x.focus_events(self.window)),
                     label + ' focus-in delivered')
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

    def move(self, px, py):
        """Move the real (XTest) pointer to a point given in window coordinates."""
        pointer_api(self.x)
        rx, ry, child = C.c_int(), C.c_int(), C.c_ulong()
        assert self.x.x.XTranslateCoordinates(self.x.display, self.window, self.x.root, px, py,
                                              C.byref(rx), C.byref(ry), C.byref(child))
        self.inputs.append([round(time.monotonic() - self.started, 4), 'pointer', px, py])
        assert self.x.xtst.XTestFakeMotionEvent(self.x.display, -1, rx.value, ry.value, 0)
        self.x.x.XSync(self.x.display, 0)

    def button(self, down):
        pointer_api(self.x)
        self.inputs.append([round(time.monotonic() - self.started, 4), 'button1', down])
        assert self.x.xtst.XTestFakeButtonEvent(self.x.display, 1, int(down), 0)
        self.x.x.XSync(self.x.display, 0)

    def click(self, px, py, modifier=None, pause=.04):
        if modifier:
            self.key(modifier, True)
        self.move(px, py)
        self.button(True)
        self.button(False)
        if modifier:
            self.key(modifier, False)
        if pause:
            time.sleep(pause)

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


class XSelectionRequestEvent(C.Structure):
    _fields_ = [('type', C.c_int), ('serial', C.c_ulong), ('send_event', C.c_int), ('display', C.c_void_p),
                ('owner', C.c_ulong), ('requestor', C.c_ulong), ('selection', C.c_ulong), ('target', C.c_ulong),
                ('property', C.c_ulong), ('time', C.c_ulong)]


class XSelectionEvent(C.Structure):
    _fields_ = [('type', C.c_int), ('serial', C.c_ulong), ('send_event', C.c_int), ('display', C.c_void_p),
                ('requestor', C.c_ulong), ('selection', C.c_ulong), ('target', C.c_ulong),
                ('property', C.c_ulong), ('time', C.c_ulong)]


class PeerEvent(C.Union):
    _fields_ = [('type', C.c_int), ('request', XSelectionRequestEvent), ('selection', XSelectionEvent),
                ('pad', C.c_long * 24)]


class ClipboardPeer:
    """Another X11 application on its own connection, single-threaded: it owns
    CLIPBOARD with chosen bytes and answers (or ignores) one request per serve(),
    or asks the current owner for a target. Xlib, ctypes and Python are TEST tools."""
    def __init__(self, display):
        self.x = x = C.CDLL(ctypes.util.find_library('X11'))
        specs = {
            'XOpenDisplay': (C.c_void_p, [C.c_char_p]),
            'XCloseDisplay': (C.c_int, [C.c_void_p]),
            'XDefaultRootWindow': (C.c_ulong, [C.c_void_p]),
            'XCreateSimpleWindow': (C.c_ulong, [C.c_void_p, C.c_ulong, C.c_int, C.c_int, C.c_uint, C.c_uint,
                                                C.c_uint, C.c_ulong, C.c_ulong]),
            'XDestroyWindow': (C.c_int, [C.c_void_p, C.c_ulong]),
            'XInternAtom': (C.c_ulong, [C.c_void_p, C.c_char_p, C.c_int]),
            'XSetSelectionOwner': (C.c_int, [C.c_void_p, C.c_ulong, C.c_ulong, C.c_ulong]),
            'XGetSelectionOwner': (C.c_ulong, [C.c_void_p, C.c_ulong]),
            'XConvertSelection': (C.c_int, [C.c_void_p, C.c_ulong, C.c_ulong, C.c_ulong, C.c_ulong, C.c_ulong]),
            'XChangeProperty': (C.c_int, [C.c_void_p, C.c_ulong, C.c_ulong, C.c_ulong, C.c_int, C.c_int,
                                          C.c_char_p, C.c_int]),
            'XGetWindowProperty': (C.c_int, [C.c_void_p, C.c_ulong, C.c_ulong, C.c_long, C.c_long, C.c_int,
                                             C.c_ulong, C.POINTER(C.c_ulong), C.POINTER(C.c_int),
                                             C.POINTER(C.c_ulong), C.POINTER(C.c_ulong), C.POINTER(C.c_void_p)]),
            'XSendEvent': (C.c_int, [C.c_void_p, C.c_ulong, C.c_int, C.c_long, C.POINTER(PeerEvent)]),
            'XPending': (C.c_int, [C.c_void_p]),
            'XNextEvent': (C.c_int, [C.c_void_p, C.POINTER(PeerEvent)]),
            'XFlush': (C.c_int, [C.c_void_p]),
            'XSync': (C.c_int, [C.c_void_p, C.c_int]),
            'XFree': (C.c_int, [C.c_void_p]),
        }
        for name, (restype, argtypes) in specs.items():
            function = getattr(x, name)
            function.restype, function.argtypes = restype, argtypes
        self.d = x.XOpenDisplay(display.encode())
        assert self.d, 'peer cannot open the test display'
        self.root = x.XDefaultRootWindow(self.d)
        self.w = x.XCreateSimpleWindow(self.d, self.root, 0, 0, 1, 1, 0, 0, 0)
        self.clipboard, self.utf8 = self.atom(b'CLIPBOARD'), self.atom(b'UTF8_STRING')
        self.targets, self.prop = self.atom(b'TARGETS'), self.atom(b'PEER_PASTE')
        self.data, self.answer = None, True
        x.XSync(self.d, 0)

    def atom(self, name):
        return self.x.XInternAtom(self.d, name, 0)

    def close(self):
        self.x.XCloseDisplay(self.d)

    def owner(self):
        return self.x.XGetSelectionOwner(self.d, self.clipboard)

    def own(self, data, answer=True):
        self.data, self.answer = data, answer
        self.x.XSetSelectionOwner(self.d, self.clipboard, self.w, 0)
        self.x.XSync(self.d, 0)
        assert self.owner() == self.w, 'peer could not take the clipboard'

    def disown(self):
        self.x.XSetSelectionOwner(self.d, self.clipboard, 0, 0)
        self.x.XSync(self.d, 0)

    def serve(self, seconds=4):
        """Answer the next request; False if it was deliberately ignored, None if none came."""
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            while self.x.XPending(self.d):
                event = PeerEvent()
                self.x.XNextEvent(self.d, C.byref(event))
                if event.type != 30:
                    continue
                request = event.request
                if not self.answer:
                    return False
                reply = PeerEvent()
                s = reply.selection
                s.type, s.display, s.requestor = 31, self.d, request.requestor
                s.selection, s.target, s.time, s.property = request.selection, request.target, request.time, 0
                if request.target == self.utf8 and self.data is not None:
                    self.x.XChangeProperty(self.d, request.requestor, request.property, self.utf8, 8, 0,
                                           self.data, len(self.data))
                    s.property = request.property
                self.x.XSendEvent(self.d, request.requestor, 0, 0, C.byref(reply))
                self.x.XFlush(self.d)
                return True
            time.sleep(.01)
        return None

    def request(self, target=None, seconds=4):
        """Ask the clipboard's owner for target: (type, format, value), or None if refused."""
        self.x.XConvertSelection(self.d, self.clipboard, target or self.utf8, self.prop, self.w, 0)
        self.x.XFlush(self.d)
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            while self.x.XPending(self.d):
                event = PeerEvent()
                self.x.XNextEvent(self.d, C.byref(event))
                if event.type != 31 or event.selection.requestor != self.w:
                    continue
                if event.selection.property == 0:
                    return None
                kind, fmt = C.c_ulong(), C.c_int()
                count, after, data = C.c_ulong(), C.c_ulong(), C.c_void_p()
                assert self.x.XGetWindowProperty(self.d, self.w, self.prop, 0, 1 << 20, 1, 0, C.byref(kind),
                                                 C.byref(fmt), C.byref(count), C.byref(after), C.byref(data)) == 0
                try:
                    if fmt.value == 8:
                        value = C.string_at(data, count.value)
                    else:
                        value = list((C.c_ulong * count.value).from_address(data.value))
                finally:
                    if data:
                        self.x.XFree(data)
                assert after.value == 0, 'peer read a partial property'
                return kind.value, fmt.value, value
            time.sleep(.01)
        raise AssertionError('timed out: the clipboard owner never answered')

    def request_from_gone_window(self, owner):
        """Send owner a request whose requestor window no longer exists."""
        gone = self.x.XCreateSimpleWindow(self.d, self.root, 0, 0, 1, 1, 0, 0, 0)
        self.x.XDestroyWindow(self.d, gone)
        event = PeerEvent()
        r = event.request
        r.type, r.display, r.owner, r.requestor = 30, self.d, owner, gone
        r.selection, r.target, r.property, r.time = self.clipboard, self.utf8, self.prop, 0
        assert self.x.XSendEvent(self.d, owner, 0, 0, C.byref(event))
        self.x.XSync(self.d, 0)


def pointer_api(x):
    if getattr(x, 'pointer_ready', False):
        return
    x.x.XTranslateCoordinates.argtypes = [C.c_void_p, C.c_ulong, C.c_ulong, C.c_int, C.c_int,
                                          C.POINTER(C.c_int), C.POINTER(C.c_int), C.POINTER(C.c_ulong)]
    x.x.XTranslateCoordinates.restype = C.c_int
    x.xtst.XTestFakeMotionEvent.argtypes = [C.c_void_p, C.c_int, C.c_int, C.c_int, C.c_ulong]
    x.xtst.XTestFakeMotionEvent.restype = C.c_int
    x.xtst.XTestFakeButtonEvent.argtypes = [C.c_void_p, C.c_uint, C.c_int, C.c_ulong]
    x.xtst.XTestFakeButtonEvent.restype = C.c_int
    x.pointer_ready = True


@contextlib.contextmanager
def application(*args, **kwargs):
    app = App(*args, **kwargs)
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
        retained=list(evidence.glob(f'.herbert-notes-{app.p.pid}-*/recovery.txt'))
        assert len(retained)==1 and retained[0].read_bytes()==expected.encode(), 'clean close removed recovery'
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
        retained=list(evidence.glob(f'.herbert-notes-{app.p.pid}-*/recovery.txt'))
        assert len(retained)==1 and retained[0].read_bytes()==b'discard'+expected.encode(), 'explicit discard removed recovery'
        passed('notes-reopen-explicit-discard-recovery-retained')

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

    for style in ('lf', 'crlf'):
        notes_sustained_checks(args, x, display, evidence, passed, style)


def notes_sustained_checks(args, x, display, evidence, passed, style):
    dense = evidence / ('dense-' + style + '.txt')
    logical = ''.join(f'{i:02d}: é e\u0301 — → 👩\u200d💻 ' + ''.join(chr(ch) for ch in range(32,127))+'\n' for i in range(32))
    newline = b'\r\n' if style == 'crlf' else b'\n'
    initial = logical.encode('utf-8').replace(b'\n', newline)
    dense.write_bytes(initial)
    with application(args.notes, dense, b'Herbert - Notes', (900,600), x, display, evidence, 'notes-sustained-' + style) as app:
        # Unicode must be inside the initial 70-column viewport, not merely in
        # the saved bytes. Witness accent ink and the unsupported emoji marker
        # before the sustained redraw/edit/save loop starts.
        dense_frame = app.frame('utf8-dense')
        accent = region(dense_frame,28+4*12,102,10,20)
        assert accent == region(dense_frame,28+6*12,102,10,20)
        ink = (15265527).to_bytes(3,'big')
        assert ink in accent, 'visible Unicode accent has no ink'
        assert ink in region(dense_frame,28+12*12,102,10,20), 'visible emoji marker has no ink'
        dense_top = region(dense_frame,30,102,838,14)
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
            wait_for(lambda: dense.read_bytes()==initial+b'test', 'sustained insertion saved exact bytes')
            app.tap('z','Control_L');app.tap('s','Control_L')
            wait_for(lambda:dense.read_bytes()==initial+b'tes','sustained undo saved exact bytes')
            app.tap('y','Control_L');app.tap('s','Control_L')
            wait_for(lambda:dense.read_bytes()==initial+b'test','sustained redo saved exact bytes')
            app.tap('f','Control_L');app.type('test');app.tap('F3');app.tap('Escape');app.tap('End','Control_L')
            app.tap('BackSpace'); app.tap('BackSpace'); app.tap('BackSpace'); app.tap('BackSpace')
            app.tap('s', 'Control_L')
            wait_for(lambda: dense.read_bytes()==initial, 'sustained deletion saved exact bytes')
            app.tap('Home','Control_L'); app.tap('Next'); app.tap('Prior'); app.tap('End','Control_L')
            cycles += 1
            if cycles % 2 == 0:
                sample = memory(app.p.pid)
                sample['seconds'] = round(time.monotonic()-started,3)
                samples.append(sample)
                (evidence/('notes-memory-' + style + '.json')).write_text(json.dumps(samples, indent=2)+'\n')
        assert cycles >= 2
        wait_for(lambda: dense.read_bytes()==initial, 'repeated edits and saves preserve exact text')
        stable_memory(samples, style + ' editor edits saves scrolling redraw')
        app.frame('scrolled')
        app.tap('Escape')
        app.finish()
        assert not list(evidence.glob('.herbert-save-*.tmp')), 'normal save leaked temporary files'
        passed('notes-sustained-' + style + '-edit-save-scroll-dense-render-memory',
               newline_style=style, unicode_prefix_visible=True, seconds_requested=args.seconds, cycles=cycles, samples=samples)


def unicode_entry(app, scalar):
    app.key('Control_L',True)
    app.tap('u','Shift_L',pause=0)
    app.key('Control_L',False)
    app.type(format(scalar,'x'),pause=0)
    app.tap('Return')


def notes_unicode_checks(args, x, display, evidence, passed):
    # Expectations come from literal UTF-8 bytes and user actions, not renderer
    # output or a copy of the Herbert segmentation algorithm.
    for style,newline in [('lf',b'\n'),('crlf',b'\r\n')]:
        d=evidence/('unicode-'+style);d.mkdir();target=d/'existing.txt'
        logical='é e\u0301 — – - − “quoted”… → ≥ ≠\nAéB\n👩\u200d💻\n'
        original=logical.encode().replace(b'\n',newline);target.write_bytes(original)
        with application(args.notes,target,b'Herbert - Notes',(900,600),x,display,d,'unicode') as app:
            app.tap('End','Control_L')
            initial=app.frame('readable-prose')
            # Same visible glyph for canonical decompositions, with no byte
            # normalization; punctuation must not all collapse to a fallback box.
            assert region(initial,28,102,10,20)==region(initial,52,102,10,20),'accent decompositions render differently'
            marks=[region(initial,28+column*12,102,10,20) for column in (4,6,8,10)]
            assert len(set(marks))==4,'em/en dash, hyphen and minus must remain distinguishable'
            assert (15265527).to_bytes(3,'big') in region(initial,28,142,10,20),'unsupported cluster vanished'
            inode=target.stat().st_ino
            app.tap('s','Control_L')
            wait_for(lambda:target.stat().st_ino!=inode and target.read_bytes()==original,'UTF8 unchanged save publishes exact bytes')
            app.tap('Home','Control_L');app.tap('Down');app.tap('Right');app.tap('Right');app.tap('BackSpace')
            wanted=original.replace('AéB'.encode(),b'AB')
            app.tap('s','Control_L');wait_for(lambda:target.read_bytes()==wanted,'backspace removes whole multibyte character')
            app.tap('z','Control_L');app.tap('s','Control_L');wait_for(lambda:target.read_bytes()==original,'undo restores exact UTF8')
            app.tap('Left');app.tap('Delete');app.tap('s','Control_L')
            wait_for(lambda:target.read_bytes()==wanted,'delete removes whole multibyte character')
            app.tap('z','Control_L');app.tap('s','Control_L');wait_for(lambda:target.read_bytes()==original,'second undo restores exact UTF8')
            app.tap('f','Control_L');unicode_entry(app,0x2014);app.tap('Escape');app.tap('Delete');app.tap('s','Control_L')
            wait_for(lambda:target.read_bytes()==original.replace('—'.encode(),b'',1),'Unicode query positions whole-character delete')
            app.tap('z','Control_L');app.tap('s','Control_L');wait_for(lambda:target.read_bytes()==original,'undo searched deletion')
            app.tap('End','Control_L');app.type('e');unicode_entry(app,0x301)
            edited=original+'e\u0301'.encode()
            app.tap('s','Control_L');wait_for(lambda:target.read_bytes()==edited,'combining input preserves decomposition')
            app.tap('BackSpace');app.tap('s','Control_L');wait_for(lambda:target.read_bytes()==original,'backspace removes combined visible character')
            app.tap('z','Control_L');app.tap('s','Control_L');wait_for(lambda:target.read_bytes()==edited,'undo restores complete combining cluster')
            app.tap('y','Control_L');app.tap('s','Control_L');wait_for(lambda:target.read_bytes()==original,'redo complete combining deletion')
            # Last original row is one joined emoji cluster followed by newline.
            app.tap('BackSpace');app.tap('BackSpace');app.tap('s','Control_L')
            without=original[:-len('👩\u200d💻'.encode())-len(newline)]
            wait_for(lambda:target.read_bytes()==without,'joined emoji is one deletion')
            wait_for(lambda:region(app.frame(),450,542,300,7)!=region(initial,450,542,300,7),'removing visible unsupported document glyph clears its label')
            app.tap('z','Control_L');app.tap('z','Control_L');app.tap('s','Control_L')
            wait_for(lambda:target.read_bytes()==original,'undo emoji and original newline')
            wait_for(lambda:region(app.frame(),450,542,300,7)==region(initial,450,542,300,7),'restored unsupported document glyph restores its label')
            app.tap('End','Control_L');unicode_entry(app,0xE9)
            edited=original+'é'.encode()
            wait_for(lambda:any(p.read_bytes()==edited for p in d.glob('.herbert-notes-*/recovery.txt')),'UTF8 recovery acknowledged')
            app.key('Control_L',True);app.tap('s','Shift_L');app.key('Control_L',False)
            wait_for(lambda:any(p.read_bytes()==edited for p in d.glob('herbert-rescue-*.txt')),'UTF8 rescue exact bytes')
            assert target.read_bytes()==original,'rescue overwrote original'
            # Invalid scalar entry and cancellation do not alter acknowledged text.
            unicode_entry(app,0xD800);app.tap('Escape')
            app.key('Control_L',True);app.tap('u','Shift_L');app.key('Control_L',False)
            app.type('41');app.tap('Escape');app.tap('s','Control_L')
            wait_for(lambda:target.read_bytes()==edited,'invalid/cancelled Unicode entry preserves text')
            app.frame('edited-utf8');app.tap('q','Control_L');app.finish()
        with application(args.notes,target,b'Herbert - Notes',(900,600),x,display,d,'reopened') as app:
            app.tap('End','Control_L');app.tap('BackSpace');app.tap('s','Control_L')
            wait_for(lambda:target.read_bytes()==original,'reopened UTF8 remains editable')
            app.tap('q','Control_L');app.finish()
        passed('notes-utf8-'+style+'-glyphs-edit-search-undo-save-rescue-recovery-reopen')

    # Direct X11 Latin-1 and Unicode keysyms through a private server mapping.
    d=evidence/'unicode-keysyms';d.mkdir();target=d/'keys.txt'
    keycode=x.x.XKeysymToKeycode(x.display,x.x.XStringToKeysym(b'F12'))
    stride=C.c_int();pointer=x.x.XGetKeyboardMapping(x.display,keycode,1,C.byref(stride))
    assert pointer and stride.value>=2
    old=[pointer[i] for i in range(stride.value)];x.x.XFree(pointer)
    replacement=(C.c_ulong*len(old))(*([0xE9,0x01002014]+[0]*(len(old)-2)))
    try:
        x.x.XChangeKeyboardMapping(x.display,keycode,len(old),replacement,1);x.x.XSync(x.display,0)
        with application(args.notes,target,b'Herbert - Notes',(900,600),x,display,d,'mapped') as app:
            def raw_key():
                app.inputs.append([round(time.monotonic()-app.started,4),'mapped-code-'+str(keycode),'press/release'])
                assert x.xtst.XTestFakeKeyEvent(x.display,keycode,1,0)
                assert x.xtst.XTestFakeKeyEvent(x.display,keycode,0,0)
                x.x.XSync(x.display,0)
            raw_key();app.key('Shift_L',True);raw_key();app.key('Shift_L',False)
            app.tap('s','Control_L')
            wait_for(lambda:target.exists() and target.read_bytes()=='é—'.encode(),'Latin1 and Unicode keysyms insert scalars')
            app.tap('q','Control_L');app.finish()
    finally:
        restore=(C.c_ulong*len(old))(*old)
        x.x.XChangeKeyboardMapping(x.display,keycode,len(old),restore,1);x.x.XSync(x.display,0)
    passed('notes-core-latin1-and-direct-unicode-keysyms')

    for name in ('docs/BUILDING.md','docs/LANGUAGE.md'):
        d=evidence/('unicode-project-'+Path(name).stem);d.mkdir();target=d/Path(name).name
        original=(ROOT/name).read_bytes();target.write_bytes(original)
        with application(args.notes,target,b'Herbert - Notes',(900,600),x,display,d,'project-document') as app:
            app.tap('End','Control_L');app.type('\nEdited with Herbert Notes.');app.tap('s','Control_L')
            wait_for(lambda:target.read_bytes()==original+b'\nEdited with Herbert Notes.','project document exact saved edit')
            app.frame('project-edited');app.tap('q','Control_L');app.finish()
        assert (ROOT/name).read_bytes()==original,'test touched original project document'
        passed('notes-existing-utf8-project-document-'+Path(name).stem)


def notes_unicode_limits_checks(args, x, display, evidence, passed):
    d=evidence/'unicode-limits';d.mkdir();target=d/'limits.txt'
    first=('a'*62+'é').encode();second=b'a'*64
    original=b'anchor\n'+first+b'\n'+second+b'\n';target.write_bytes(original)
    with application(args.notes,target,b'Herbert - Notes',(900,600),x,display,d,'limits') as app:
        def open_hex():
            app.key('Control_L',True);app.tap('u','Shift_L');app.key('Control_L',False)
        def status(): return region(app.frame(),28,560,780,7)
        def encoding(): return region(app.frame(),450,542,300,7)
        ready=status();plain_encoding=encoding()
        open_hex();app.tap('Escape')
        wait_for(lambda:status()==ready,'cancelling clean Unicode entry keeps neutral status')
        app.tap('End','Control_L');app.type('x');app.tap('z','Control_L')
        app.key('Control_L',True);app.tap('z','Shift_L');app.tap('z','Shift_L');app.key('Control_L',False)
        wait_for(lambda:(16173151).to_bytes(3,'big') in status(),'redo exhaustion warning is drawn')
        app.frame('shift-redo-exhausted');shift_status=status()
        app.tap('y','Control_L')
        wait_for(lambda:status()==shift_status,'both redo shortcuts give the same exhausted message')
        app.tap('s','Control_L');wanted=original+b'x'
        wait_for(lambda:target.read_bytes()==wanted,'redo exhaustion does not edit text')

        app.tap('f','Control_L');unicode_entry(app,0x1F600)
        wait_for(lambda:encoding()!=plain_encoding,'visible unsupported query labels the fallback')
        app.frame('unsupported-query-labelled')
        open_hex()
        wait_for(lambda:encoding()==plain_encoding,'hidden query does not claim visible fallback')
        app.tap('Escape')
        wait_for(lambda:encoding()!=plain_encoding,'returning to query restores fallback label')
        app.tap('BackSpace')
        wait_for(lambda:encoding()==plain_encoding,'removing unsupported query clears fallback label')
        # A published rescue must expose its basename even when input panels
        # were active. Pending hex input is cancelled; typing resumes editing.
        open_hex();app.type('41')
        app.key('Control_L',True);app.tap('s','Shift_L');app.key('Control_L',False)
        wait_for(lambda:any(p.read_bytes()==wanted for p in d.glob('herbert-rescue-*.txt')),'rescue during Unicode/Find keeps exact bytes')
        app.frame('rescue-leaves-input-panels')
        app.type('!');app.tap('s','Control_L');wanted+=b'!'
        wait_for(lambda:target.read_bytes()==wanted,'published rescue leaves input panels for editing')
        app.tap('End','Control_L')

        open_hex();app.tap('Return');app.tap('Escape')
        open_hex();app.type('0000e90');app.tap('space')
        open_hex();app.type('20140');app.tap('BackSpace');app.tap('space')
        app.tap('s','Control_L');wanted+='é—'.encode()
        wait_for(lambda:target.read_bytes()==wanted,'empty hex rejected, seventh digit ignored, hex backspace and Space commit')
        app.frame('hex-limits-saved')

        # 62 ASCII bytes + a two-byte scalar exactly fills the 64-byte query.
        # A further scalar must leave that query intact. Re-run the query from
        # another cursor position before deletion so a stale match cannot pass.
        app.tap('f','Control_L');app.type('a'*62,pause=0);unicode_entry(app,0xE9)
        unicode_entry(app,0x1F600);app.tap('Escape');app.tap('Home','Control_L');app.tap('F3');app.tap('Delete');app.tap('s','Control_L')
        after=wanted.replace(first,first[1:],1)
        wait_for(lambda:target.read_bytes()==after,'64-byte UTF8 query survives overflow unchanged and matches')
        app.tap('z','Control_L');app.tap('s','Control_L')
        wait_for(lambda:target.read_bytes()==wanted,'undo boundary-query deletion')

        # 63 + 2 must reject the entire scalar. TAB/LF hexadecimal entry is
        # also rejected in Find without altering the query or document.
        app.tap('f','Control_L');app.type('a'*63,pause=0);unicode_entry(app,0xE9)
        unicode_entry(app,9);app.tap('Escape');unicode_entry(app,10);app.tap('Escape')
        app.tap('Escape');app.tap('Home','Control_L');app.tap('F3');app.tap('Delete');app.tap('s','Control_L')
        after=wanted.replace(b'\n'+second+b'\n',b'\n'+second[1:]+b'\n',1)
        wait_for(lambda:target.read_bytes()==after,'oversized scalar and query controls leave the 63-byte query intact')
        app.tap('z','Control_L');app.tap('s','Control_L')
        wait_for(lambda:target.read_bytes()==wanted,'all rejected input preserves saved Unicode bytes')
        app.tap('q','Control_L');app.finish()
    passed('notes-unicode-input-query-limits-and-feedback')


def notes_newline_checks(args, x, display, evidence, passed):
    d=evidence/'newline-editing';d.mkdir();target=d/'existing.txt'
    original=b'first\r\n\tsecond\r\nlast';target.write_bytes(original)
    with application(args.notes,target,b'Herbert - Notes',(900,600),x,display,d,'crlf') as app:
        initial=app.frame('loaded-crlf')
        original_inode=target.stat().st_ino
        app.tap('s','Control_L')
        # Save replaces the target atomically even when its text is unchanged.
        # Requiring a new inode prevents an ignored Ctrl+S from passing here.
        wait_for(lambda:target.stat().st_ino!=original_inode and target.read_bytes()==original,
                 'unedited CRLF save publishes a replacement with exact bytes')
        app.tap('Down');app.tap('Right');app.type('!')
        wanted=b'first\r\n\t!second\r\nlast'
        # Delete at End removes the entire line separator; one undo restores it.
        app.tap('Home','Control_L');app.tap('End');app.tap('Delete')
        app.tap('s','Control_L')
        wait_for(lambda:target.read_bytes()==b'first\t!second\r\nlast','delete whole CRLF')
        app.tap('z','Control_L');app.tap('s','Control_L')
        wait_for(lambda:target.read_bytes()==wanted,'undo restores whole CRLF')
        app.tap('End','Control_L');app.tap('Return');app.type('!')
        wanted+=b'\r\n!'
        app.tap('s','Control_L')
        wait_for(lambda:target.read_bytes()==wanted,'new line uses original CRLF style')
        app.key('Control_L',True);app.tap('s','Shift_L');app.key('Control_L',False)
        wait_for(lambda:any(p.read_bytes()==wanted for p in d.glob('herbert-rescue-*.txt')),'CRLF rescue exact bytes')
        snapshots=list(d.glob('.herbert-notes-*/recovery.txt'))
        assert len(snapshots)==1 and snapshots[0].read_bytes()==wanted
        app.frame('saved-crlf');app.tap('q','Control_L');app.finish()
    # Reopening a recovery file stays a separate document and retains its style.
    snapshot=snapshots[0]
    with application(args.notes,snapshot,b'Herbert - Notes',(900,600),x,display,d,'recovered-crlf') as app:
        app.tap('End','Control_L');app.tap('Return');app.type('recovered')
        app.tap('s','Control_L')
        wait_for(lambda:snapshot.read_bytes()==wanted+b'\r\nrecovered','reopened recovery retains CRLF')
        assert target.read_bytes()==wanted
        app.tap('q','Control_L');app.finish()
    # Equal logical text renders equally. Only the visible newline-style label
    # differs between the loaded LF and CRLF representations.
    lf=d/'existing-lf.txt';lf.write_bytes(original.replace(b'\r\n',b'\n'))
    with application(args.notes,lf,b'Herbert - Notes',(900,600),x,display,d,'lf') as app:
        frame=app.frame('loaded-lf')
        assert region(initial,30,102,838,54)==region(frame,30,102,838,54)
        assert region(initial,402,542,24,7)!=region(frame,402,542,24,7)
        app.tap('q','Control_L');app.finish()
    passed('notes-crlf-render-navigation-newline-undo-save-rescue-recovery-reopen')


def notes_editing_checks(args, x, display, evidence, passed):
    d=evidence/'editing-features';d.mkdir()
    target=d/'notes.txt';target.write_text('alpha beta alpha beta')
    with application(args.notes,target,b'Herbert - Notes',(900,600),x,display,d,'history-find') as app:
        app.tap('F3');app.tap('Escape')
        assert app.p.poll() is None,'F3 without a query did not open search'
        def saved(wanted):
            app.tap('s','Control_L')
            wait_for(lambda:target.read_bytes()==wanted,'history/search exact saved bytes')
        app.type('XYZ')
        app.tap('z','Control_L');saved(b'XYalpha beta alpha beta')
        app.tap('z','Control_L');app.tap('y','Control_L');saved(b'XYalpha beta alpha beta')
        app.key('Control_L',True);app.tap('z','Shift_L');app.key('Control_L',False)
        saved(b'XYZalpha beta alpha beta')
        app.tap('z','Control_L');app.type('Q');app.tap('y','Control_L')
        saved(b'XYQalpha beta alpha beta')
        # Search finds without changing document bytes. Insertion after leaving
        # search independently reveals the exact cursor target, including wrap.
        app.tap('Home','Control_L');app.tap('f','Control_L');app.type('alpha')
        app.frame('find-first')
        app.tap('Return');app.tap('Escape');app.type('!')
        saved(b'XYQalpha beta !alpha beta')
        app.tap('F3');app.type('?')
        saved(b'XYQ?alpha beta !alpha beta')
        app.tap('F3','Shift_L');app.type('#')
        saved(b'XYQ?alpha beta !#alpha beta')
        app.tap('f','Control_L');app.tap('Return')
        empty=app.frame('find-empty')
        assert (16173151).to_bytes(3,'big') not in region(empty,28,560,810,7)
        app.type('NO MATCH')
        missing=app.frame('find-no-match')
        assert (16173151).to_bytes(3,'big') in region(missing,28,560,810,7)
        app.tap('f','Control_L');app.type('alpha');app.tap('Escape')
        saved(b'XYQ?alpha beta !#alpha beta')
        app.tap('f','Control_L');app.tap('q','Control_L');app.finish()
        passed('notes-undo-redo-divergence-find-next-previous-wrap')

    d=evidence/'queued-discard-recovery';d.mkdir();target=d/'original.txt';target.write_text('base')
    with application(args.notes,target,b'Herbert - Notes',(900,600),x,display,d,'queued-discard') as app:
        app.stop();app.type('latest ',pause=0);app.tap('q','Control_L',pause=0);app.tap('y',pause=0)
        app.p.send_signal(signal.SIGCONT);app.finish()
        snapshot=next(d.glob('.herbert-notes-*/recovery.txt'))
        assert snapshot.read_bytes()==b'latest base' and target.read_bytes()==b'base'
        passed('notes-queued-edit-quit-discard-checkpoints-before-exit')

    # Both absent recovery and an older successful copy must show the explicit
    # incomplete-current-recovery prompt. Compare the actual pixels against a
    # successful recovery prompt and against each other, never just amber ink.
    close_prompts=[]
    for label,fault,first,latest in [('complete',None,'x','x'),
                                   ('absent','mkdirat:error=EACCES:when=1+','x','x'),
                                   ('older','fsync:error=EIO:when=4+','x','xy')]:
        d=evidence/('discard-'+label);d.mkdir();target=d/'original.txt';target.write_text('base')
        image=args.notes
        if fault:
            image=d/'launch'
            image.write_text('#!/bin/sh\nexec strace --kill-on-exit -o '+shlex.quote(str(d/'strace.log'))+' -e inject='+fault+' '+shlex.quote(str(args.notes.resolve()))+' "$@"\n');image.chmod(0o700)
        with application(image,target,b'Herbert - Notes',(900,600),x,display,d,label) as app:
            app.type(first)
            if label=='older':
                wait_for(lambda:any(p.read_bytes()==b'xbase' for p in d.glob('.herbert-notes-*/recovery.txt')),'older copy exists before fault')
                app.type('y')
            if fault:
                wait_for(lambda:(16173151).to_bytes(3,'big') in region(app.frame(),28,85,830,7),'recovery incomplete before discard')
            app.tap('q','Control_L')
            wait_for(lambda:(16173151).to_bytes(3,'big') in region(app.frame(),28,560,810,7),'close prompt actually rendered')
            frame=app.frame('close-prompt')
            assert (16173151).to_bytes(3,'big') in region(frame,28,560,810,7)
            close_prompts.append(region(frame,28,560,810,7))
            # Mod4/Super is not an unmodified affirmative response.
            app.tap('y','Super_L');assert app.p.poll() is None,'modified Y discarded edits'
            app.tap('y');app.finish()
            assert target.read_bytes()==b'base'
            copies=list(d.glob('.herbert-notes-*/recovery.txt'))
            if label=='absent':assert not copies
            else:assert len(copies)==1 and copies[0].read_bytes()==b'xbase'
    assert close_prompts[0]!=close_prompts[1] and close_prompts[1]==close_prompts[2]
    passed('notes-discard-distinguishes-complete-absent-and-stale-recovery')

    # A completed, visible input batch has already been checkpointed before
    # drawing. Abrupt process death and loss of the X connection retain it.
    x.x.XKillClient.argtypes=[C.c_void_p,C.c_ulong]
    x.x.XKillClient.restype=C.c_int
    for failure in ['process-kill','display-loss']:
        d=evidence/('recovery-'+failure);d.mkdir();target=d/'original.txt'
        target.write_bytes(b'original text')
        with application(args.notes,target,b'Herbert - Notes',(900,600),x,display,d,failure) as app:
            initial=app.frame()
            app.type('unsaved ')
            wait_for(lambda:len(list(d.glob('.herbert-notes-*/recovery.txt')))==1,'first recovery copy')
            snapshot=next(d.glob('.herbert-notes-*/recovery.txt'))
            wait_for(lambda:snapshot.read_bytes()==b'unsaved original text','complete recovery checkpoint')
            wait_for(lambda:region(app.frame(),28,85,830,7)!=region(initial,28,85,830,7),'recovery path acknowledged on screen')
            app.frame('checkpoint-visible')
            assert snapshot.stat().st_mode&0o777==0o600 and snapshot.parent.stat().st_mode&0o777==0o700
            if failure=='process-kill':
                app.p.kill();assert app.p.wait(timeout=5)==-signal.SIGKILL
            else:
                x.x.XKillClient(x.display,app.window);x.x.XSync(x.display,False)
                assert app.p.wait(timeout=5)!=0
            assert snapshot.read_bytes()==b'unsaved original text' and target.read_bytes()==b'original text'
        # External original edits between failure and reopening are never adopted
        # or overwritten; recovered bytes are a separate ordinary document.
        target.write_bytes(b'external original')
        with application(args.notes,snapshot,b'Herbert - Notes',(900,600),x,display,d,'reopened-copy') as app:
            app.tap('End','Control_L');app.type(' recovered');app.tap('s','Control_L')
            wait_for(lambda:snapshot.read_bytes()==b'unsaved original text recovered','reopened checkpoint editable')
            assert target.read_bytes()==b'external original'
            app.tap('Escape');app.finish()
        passed('notes-recovery-'+failure+'-reopen-separate-original-preserved')

    # A recovery failure is visible independently of save status; a new edit
    # retries. Inject a bounded delay to observe responsiveness after slow fsync.
    for label,fault in [('create-failure','mkdirat:error=EACCES:when=1'),
                        ('sync-failure','fsync:error=EIO:when=1'),
                        ('slow-sync','fsync:delay_enter=200ms:when=1')]:
        d=evidence/('recovery-'+label);d.mkdir();target=d/'document.txt';target.write_text('base')
        launcher=d/'launch'
        launcher.write_text('#!/bin/sh\nexec strace --kill-on-exit -o '+shlex.quote(str(d/'strace.log'))+' -e inject='+fault+' '+shlex.quote(str(args.notes.resolve()))+' "$@"\n');launcher.chmod(0o700)
        with application(launcher,target,b'Herbert - Notes',(900,600),x,display,d,label) as app:
            started=time.monotonic();app.type('x')
            if label!='slow-sync':
                wait_for(lambda:(16173151).to_bytes(3,'big') in region(app.frame(),28,85,830,7),'visible recovery warning')
                app.frame('recovery-warning')
                if label=='sync-failure':app.tap('s','Control_L')
                else:app.type('y')
            wanted=b'xybase' if label=='create-failure' else b'xbase'
            wait_for(lambda:any(p.read_bytes()==wanted for p in d.glob('.herbert-notes-*/recovery.txt')),'checkpoint succeeds after fault')
            wait_for(lambda:(16173151).to_bytes(3,'big') not in region(app.frame(),28,85,830,7),'recovery warning clears after retry')
            elapsed=time.monotonic()-started
            if label=='slow-sync':assert .18<=elapsed<5,elapsed
            assert target.read_bytes()==(b'xbase' if label=='sync-failure' else b'base')
            app.tap('s','Control_L');wait_for(lambda:target.read_bytes()==wanted,'normal save remains usable')
            app.tap('Escape');app.finish()
        passed('notes-recovery-'+label,seconds=round(elapsed,3))

    d=evidence/'idle-expose';d.mkdir();target=d/'notes.txt';target.write_text('Expose retains this text.')
    launcher=d/'launch';trace=d/'strace.log'
    launcher.write_text('#!/bin/sh\nexec strace --kill-on-exit -o '+shlex.quote(str(trace))+' -e trace=poll,sendto '+shlex.quote(str(args.notes.resolve()))+' "$@"\n');launcher.chmod(0o700)
    with application(launcher,target,b'Herbert - Notes',(900,600),x,display,d,'idle') as app:
        time.sleep(.6);before=trace.read_text().count('sendto(')
        time.sleep(2);sent=trace.read_text().count('sendto(')-before
        assert 2<=sent<=12,('idle sends',sent)
        reference=region(app.frame(),30,102,838,14)
        x.x.XClearArea.argtypes=[C.c_void_p,C.c_ulong,C.c_int,C.c_int,C.c_uint,C.c_uint,C.c_int]
        x.x.XClearArea.restype=C.c_int
        x.x.XClearArea(x.display,app.window,24,96,852,428,True);x.x.XSync(x.display,False)
        wait_for(lambda:region(app.frame(),30,102,838,14)==reference,'Expose restores retained text')
        app.tap('Escape');app.finish()
    passed('notes-idle-blink-only-present-and-expose',sends_in_two_seconds=sent)


def notes_fault_checks(args, x, display, evidence, passed):
    # A shell/strace launcher exists only in this test's scratch directory.
    # Deny session-directory creation here so recovery fsyncs cannot consume
    # the original-document fault injection; recovery faults have their own tests.
    # --kill-on-exit prevents an orphaned tracee if test cleanup stops the tracer.
    image = args.notes.resolve()
    gold = (16173151).to_bytes(3, 'big')
    close_prompts={}
    for label,typing in [('edited-document','draft '),('clean-document','')]:
        d=evidence/('save-fault-'+label);d.mkdir();target=d/'notes.txt';target.write_text('base\n')
        launcher=d/'notes-under-fsync-fault'
        launcher.write_text('#!/bin/sh\nexec strace --kill-on-exit -y -o '+shlex.quote(str(d/'strace.log'))+' -e inject=mkdirat:error=EACCES:when=1+ -e inject=fsync:error=EIO:when=2 '+shlex.quote(str(image))+' "$@"\n');launcher.chmod(0o700)
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
            close_prompts[label]=region(prompt,28,560,810,7)
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
    assert close_prompts['edited-document']!=close_prompts['clean-document'],'save-only warning incorrectly claims unsaved edits or recovery'

def notes_open_checks(args, x, display, evidence, passed):
    d = evidence/'open'; sub = d/'sub'; sub.mkdir(parents=True)
    first = d/'a.txt'; first.write_bytes(b'first file\n')
    second = sub/'b.txt'; second.write_bytes(b'second\r\nfile\r\n')
    # Same name as first, one folder down: a field that ignored the document's
    # folder would open this one instead.
    decoy = sub/'a.txt'; decoy.write_bytes(b'decoy\n')
    bad = sub/'bad.txt'; bad.write_bytes(b'\xff\n')
    warning = (16173151).to_bytes(3,'big')
    def warned():
        return warning in region(app.frame(),28,560,810,7)
    def recoveries(folder):
        return sorted(p.read_bytes() for p in folder.glob(f'.herbert-notes-{app.p.pid}-*/recovery.txt'))
    def opened(path):
        app.tap('o','Control_L'); app.type(path); app.tap('Return')
    with application(args.notes, Path('../a.txt'), b'Herbert - Notes', (900,600), x, display, d, 'notes-open', cwd=sub) as app:
        app.type('A')
        app.tap('o','Control_L')
        wait_for(warned, 'Ctrl+O with unsaved edits refused visibly')
        app.type('z'); app.tap('s','Control_L')
        wait_for(lambda: first.read_bytes()==b'Azfirst file\n', 'refused open left typing in the document')
        # Launched from sub as ../a.txt: the field starts with that folder, so
        # a.txt names the open document itself, not the decoy beside the cwd.
        opened('a.txt')
        app.type('Q'); app.tap('s','Control_L')
        wait_for(lambda: first.read_bytes()==b'QAzfirst file\n', 'reopened document saved at its own path')
        assert decoy.read_bytes()==b'decoy\n', 'open ignored the document folder'
        opened('sub/b.txt')
        app.type('B'); app.tap('s','Control_L')
        wait_for(lambda: second.read_bytes()==b'Bsecond\r\nfile\r\n', 'second file saved in its own CRLF style')
        assert first.read_bytes()==b'QAzfirst file\n', 'save after open wrote the previous file'
        wait_for(lambda: recoveries(sub)==[b'Bsecond\r\nfile\r\n'], 'recovery beside the newly opened file')
        assert recoveries(d)==[b'Azfirst file\n', b'QAzfirst file\n'], ('earlier sessions kept', recoveries(d))
        before = region(app.frame('before-refusals'),28,102,838,60)
        for name, typed in [('missing-folder','missing/c.txt'), ('invalid-text','bad.txt'), ('folder','../sub')]:
            opened(typed)
            wait_for(warned, name + ' open refused visibly')
            app.frame('refused-' + name)
            # Compare until the blinking cursor matches; text must not change.
            wait_for(lambda: region(app.frame(),28,102,838,60)==before, name + ' refusal kept the document view')
            app.tap('Escape')
        app.type('C'); app.tap('s','Control_L')
        wait_for(lambda: second.read_bytes()==b'BCsecond\r\nfile\r\n', 'refusals kept text, cursor and save target')
        assert bad.read_bytes()==b'\xff\n' and not (sub/'missing').exists()
        fresh = sub/'new.txt'
        opened('new.txt')
        time.sleep(.2)
        assert not fresh.exists(), 'opening a new name created the file'
        app.type('N'); app.tap('s','Control_L')
        wait_for(lambda: fresh.exists() and fresh.read_bytes()==b'N', 'new file created by save')
        assert fresh.stat().st_mode & 0o777 == 0o600
        assert second.read_bytes()==b'BCsecond\r\nfile\r\n'
        (sub/'x.txt').write_bytes(b'x file\n'); (sub/'y.txt').write_bytes(b'y file\n')
        views = {}
        for name in ('x.txt', 'y.txt'):
            opened(name)
            time.sleep(.2)
            views[name] = region(app.frame(),28,102,838,14)
        assert views['x.txt'] != views['y.txt']
        samples = []
        for cycle in range(1, 21):
            for name in ('x.txt', 'y.txt'):
                opened(name)
                wait_for(lambda: region(app.frame(),28,102,838,14)==views[name], name + ' shown after open')
            if cycle % 2 == 0:
                samples.append(memory(app.p.pid))
        (d/'notes-open-memory.json').write_text(json.dumps(samples, indent=2)+'\n')
        stable_memory(samples, 'alternating opens')
        app.tap('Escape')
        app.finish()
        assert not list(d.glob('**/.herbert-save-*.tmp')), 'open or save leaked temporary files'
        passed('notes-open-refuses-unsaved-opens-beside-saves-new-target-keeps-recovery-refusals-intact-memory-flat',
               samples=samples)


def notes_selection_checks(args, x, display, evidence, passed):
    d = evidence/'selection'; d.mkdir()
    mark, match = (3033707).to_bytes(3,'big'), (6969880).to_bytes(3,'big')
    warning = (16173151).to_bytes(3,'big')
    def shift(key, n=1):
        app.key('Shift_L', True)
        for _ in range(n): app.tap(key)
        app.key('Shift_L', False)
    def saved(path, wanted, what):
        app.tap('s','Control_L')
        wait_for(lambda: path.read_bytes()==wanted, what)
    def shows(colour):
        return colour in region(app.frame(),26,98,848,424)
    def warned():
        return warning in region(app.frame(),28,560,810,7)
    doc = d/'notes.txt'; doc.write_bytes(b'alpha beta\ngamma delta\nend\n')
    with application(args.notes, doc, b'Herbert - Notes', (900,600), x, display, d, 'selection') as app:
        assert not shows(mark)
        shift('Right', 5)
        wait_for(lambda: shows(mark), 'keyboard selection highlighted')
        app.frame('selected')
        app.tap('c','Control_L'); app.tap('End')
        wait_for(lambda: not shows(mark), 'movement without Shift drops the selection')
        app.tap('v','Control_L')
        saved(doc, b'alpha betaalpha\ngamma delta\nend\n', 'copy, then paste at the end of the line')
        app.tap('Home'); [app.tap('Right') for _ in range(6)]; shift('Right', 4); app.tap('x','Control_L')
        saved(doc, b'alpha alpha\ngamma delta\nend\n', 'cut removes the selection')
        app.tap('z','Control_L'); saved(doc, b'alpha betaalpha\ngamma delta\nend\n', 'one undo restores the cut')
        app.tap('y','Control_L'); saved(doc, b'alpha alpha\ngamma delta\nend\n', 'one redo cuts again')
        app.tap('Home','Control_L'); app.tap('Down'); shift('End'); app.type('Z')
        saved(doc, b'alpha alpha\nZ\nend\n', 'typing replaces the selection')
        app.tap('z','Control_L'); saved(doc, b'alpha alpha\ngamma delta\nend\n', 'one undo restores replaced text')
        app.tap('y','Control_L'); saved(doc, b'alpha alpha\nZ\nend\n', 'one redo replaces it again')
        app.tap('Home','Control_L'); shift('Right', 3); app.tap('Left'); app.type('<')
        saved(doc, b'<alpha alpha\nZ\nend\n', 'Left goes to the selection start')
        app.tap('Home','Control_L'); shift('Right', 3); app.tap('Right'); app.type('>')
        saved(doc, b'<al>pha alpha\nZ\nend\n', 'Right goes to the selection end')
        app.tap('Home','Control_L'); shift('Right', 4); app.tap('BackSpace')
        saved(doc, b'pha alpha\nZ\nend\n', 'Backspace removes the selection')
        app.tap('Home','Control_L'); shift('Down'); app.tap('x','Control_L'); app.tap('End','Control_L'); app.tap('v','Control_L')
        saved(doc, b'Z\nend\npha alpha\n', 'multi-line cut and paste')
        app.tap('a','Control_L'); wait_for(lambda: shows(mark), 'Ctrl+A highlights')
        app.type('X'); saved(doc, b'X', 'Ctrl+A then typing replaces everything')
        app.tap('z','Control_L'); saved(doc, b'Z\nend\npha alpha\n', 'one undo restores everything')
        # A pasted search finds the copied word; leaving Find leaves no selection.
        app.tap('Home','Control_L'); app.tap('Down'); app.tap('Down'); [app.tap('Right') for _ in range(4)]
        shift('Right', 5); app.tap('c','Control_L')
        app.tap('Home','Control_L'); app.tap('f','Control_L'); app.tap('v','Control_L')
        wait_for(lambda: shows(match) and not shows(mark), 'pasted search highlights its match')
        app.frame('find-match')
        app.tap('Escape')
        wait_for(lambda: not shows(match), 'leaving Find removes the match highlight')
        app.type('^'); saved(doc, b'Z\nend\npha ^alpha\n', 'pasted search found the copied word')
        app.tap('a','Control_L'); app.tap('c','Control_L'); app.tap('End','Control_L')
        app.tap('f','Control_L'); app.tap('v','Control_L')
        wait_for(warned, 'a multi-line paste into Find is refused')
        app.tap('Escape'); app.tap('s','Control_L')
        assert doc.read_bytes()==b'Z\nend\npha ^alpha\n'
        # Copy, paste, undo cycles reuse fixed storage.
        samples = []
        for cycle in range(1, 21):
            app.tap('a','Control_L'); app.tap('c','Control_L'); app.tap('End','Control_L'); app.tap('v','Control_L')
            app.tap('z','Control_L')
            saved(doc, b'Z\nend\npha ^alpha\n', 'paste and undo cycle')
            if cycle % 2 == 0: samples.append(memory(app.p.pid))
        stable_memory(samples, 'select copy paste undo')
        shift('Left')
        wait_for(lambda: shows(mark), 'selection before Escape')
        app.tap('Escape')
        wait_for(lambda: not shows(mark), 'first Escape drops the selection')
        assert app.p.poll() is None, 'Escape with a selection closed Notes'
        app.tap('Escape')
        app.finish()
    names = d/'names.txt'; names.write_bytes(b'other.txt\n')
    other = d/'other.txt'; other.write_bytes(b'second\n')
    with application(args.notes, names, b'Herbert - Notes', (900,600), x, display, d, 'selection-open') as app:
        shift('End'); app.tap('c','Control_L')
        app.tap('o','Control_L'); app.tap('v','Control_L'); app.tap('Return')
        app.type('Q'); saved(other, b'Qsecond\n', 'a pasted name opens in Ctrl+O')
        assert names.read_bytes()==b'other.txt\n'
        app.tap('Escape'); app.finish()
    crlf = d/'crlf.txt'; crlf.write_bytes(b'one\r\ntwo\r\n')
    big = d/'big.txt'; content = b'X'*30000 + b'\n' + b'Y'*30000; big.write_bytes(content)
    with application(args.notes, crlf, b'Herbert - Notes', (900,600), x, display, d, 'selection-crlf') as app:
        shift('Down'); app.tap('c','Control_L'); app.tap('End','Control_L'); app.tap('v','Control_L')
        saved(crlf, b'one\r\ntwo\r\none\r\n', 'copied line keeps the CRLF style')
        app.tap('Escape'); app.finish()
    with application(args.notes, big, b'Herbert - Notes', (900,600), x, display, d, 'selection-big') as app:
        # Replacing 60,002 bytes with 60,001 needs both in history: one undo step.
        app.tap('a','Control_L'); app.tap('c','Control_L'); app.tap('End','Control_L'); app.type('!')
        app.tap('a','Control_L'); app.tap('v','Control_L')
        saved(big, content, 'whole-document paste over a whole-document selection')
        app.tap('z','Control_L'); saved(big, content + b'!', 'one undo restores the replaced document')
        app.tap('y','Control_L'); saved(big, content, 'one redo replaces it again')
        app.tap('Escape'); app.finish()
    passed('notes-selection-highlight-cut-copy-paste-one-undo-step-fields-crlf-whole-document-memory-flat',
           samples=samples)


def notes_clipboard_checks(args, x, display, evidence, passed):
    d = evidence/'clipboard'; d.mkdir()
    warning = (16173151).to_bytes(3,'big')
    def shift(key, n=1):
        app.key('Shift_L', True)
        for _ in range(n): app.tap(key)
        app.key('Shift_L', False)
    def saved(path, wanted, what):
        app.tap('s','Control_L')
        wait_for(lambda: path.read_bytes()==wanted, what)
    def warned():
        return warning in region(app.frame(),28,560,810,7)
    def calm():
        app.tap('s','Control_L')
        wait_for(lambda: not warned(), 'footer back to normal before the next paste')
    peer = ClipboardPeer(display)
    try:
        doc = d/'notes.txt'; original = 'naïve café\r\nsecond\r\n'.encode(); doc.write_bytes(original)
        with application(args.notes, doc, b'Herbert - Notes', (900,600), x, display, d, 'clipboard') as app:
            shift('Down'); app.tap('c','Control_L')
            wait_for(lambda: peer.owner()==app.window, 'Ctrl+C takes the desktop clipboard')
            assert peer.request()==(peer.utf8, 8, 'naïve café\n'.encode()), 'copied text with an LF newline'
            mime = peer.atom(b'text/plain;charset=utf-8')
            assert peer.request(mime)==(mime, 8, 'naïve café\n'.encode())
            kind, fmt, offered = peer.request(peer.targets)
            assert (kind, fmt) == (4, 32) and {peer.targets, peer.utf8, mime} <= set(offered), offered
            assert peer.request(peer.atom(b'STRING')) is None, 'an unoffered format is refused'
            peer.own('café\r\nline two\n'.encode())
            app.tap('End','Control_L'); app.tap('v','Control_L')
            assert peer.serve() is True, 'Ctrl+V asked the other application'
            saved(doc, original + 'café\r\nline two\r\n'.encode(), 'a pasted mix of CRLF and LF follows the CRLF style')
            app.tap('z','Control_L'); saved(doc, original, 'one undo removes the paste')
            for name, data in [('control', b'bad\x01text'), ('bare-cr', b'a\rb'), ('invalid', b'\xff\xfe'),
                               ('too-large', b'x' * 70000)]:
                calm()
                peer.own(data); app.tap('v','Control_L')
                assert peer.serve() is True, name
                wait_for(warned, name + ' paste refused visibly')
                app.frame('refused-' + name)
                assert doc.read_bytes()==original, name
            calm(); peer.disown(); app.tap('v','Control_L')
            wait_for(warned, 'a paste with no clipboard owner is reported')
            calm(); peer.own(b'never', answer=False); app.tap('v','Control_L')
            assert peer.serve() is False
            wait_for(warned, 'an unanswered paste is reported', timeout=6)
            app.type('Q'); expected = original + b'Q'
            saved(doc, expected, 'Notes keeps working after an unanswered paste')
            # Another application taking the clipboard ends Notes' ownership.
            app.tap('Home','Control_L'); shift('Right'); app.tap('c','Control_L')
            wait_for(lambda: peer.owner()==app.window, 'Notes takes the clipboard again')
            peer.own(b'from peer'); app.tap('End','Control_L'); app.tap('v','Control_L')
            assert peer.serve() is True, 'after losing the clipboard Notes asks its new owner'
            expected += b'from peer'; saved(doc, expected, 'the new owner\'s text pasted')
            # A request from a window that is already gone cannot stop Notes.
            app.tap('Home','Control_L'); shift('Right'); app.tap('c','Control_L')
            wait_for(lambda: peer.owner()==app.window, 'Notes owns the clipboard for the vanished request')
            peer.request_from_gone_window(app.window)
            time.sleep(.3)
            assert app.p.poll() is None, 'a vanished requestor stopped Notes'
            app.tap('End','Control_L'); app.type('!'); expected += b'!'
            saved(doc, expected, 'Notes keeps working after answering a vanished window')
            samples = []
            for cycle in range(1, 11):
                peer.own(b'cycle'); app.tap('v','Control_L')
                assert peer.serve() is True
                app.tap('z','Control_L'); saved(doc, expected, 'external paste and undo cycle')
                if cycle % 2 == 0: samples.append(memory(app.p.pid))
            stable_memory(samples, 'external paste undo')
            app.tap('Escape'); app.finish()
        big = d/'big.txt'; content = (b'x' * 1023 + b'\n') * 64; big.write_bytes(content)
        with application(args.notes, big, b'Herbert - Notes', (900,600), x, display, d, 'clipboard-big') as app:
            app.tap('a','Control_L'); app.tap('c','Control_L')
            wait_for(lambda: peer.owner()==app.window, 'Notes owns a 65,536-byte copy')
            assert peer.request()==(peer.utf8, 8, content), 'a 65,536-byte copy arrives whole'
            app.tap('Escape'); app.tap('Escape'); app.finish()
        names = d/'names.txt'; names.write_bytes(b'just a note\n')
        other = d/'other.txt'; other.write_bytes(b'second\n')
        with application(args.notes, names, b'Herbert - Notes', (900,600), x, display, d, 'clipboard-open') as app:
            peer.own(b'other.txt\n'); app.tap('o','Control_L'); app.tap('v','Control_L')
            assert peer.serve() is True
            app.tap('Return'); app.type('Q'); saved(other, b'Qsecond\n', 'a name pasted from another application opens')
            app.tap('Escape'); app.finish()
    finally:
        peer.close()
    passed('notes-desktop-clipboard-copy-offer-paste-crlf-refusals-timeout-ownership-vanished-requestor-64kib-field-memory',
           samples=samples)


def cpu_seconds(pid):
    fields = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
    return (int(fields[11]) + int(fields[12])) / os.sysconf('SC_CLK_TCK')


def notes_big_checks(args, x, display, evidence, passed):
    d = evidence/'big'; d.mkdir()
    limit = 1048576
    warning = (16173151).to_bytes(3,'big')
    def warned():
        return warning in region(app.frame(),28,560,810,7)
    def saved(path, wanted, what):
        app.tap('s','Control_L')
        wait_for(lambda: path.read_bytes()==wanted, what, timeout=10)
    # A document of exactly the limit: numbered lines of accented, combining,
    # arrow and CJK text, the last line padded to land on the limit.
    lines, size, i = [], 0, 0
    while size < limit - 200:
        line = f'{i:06d} é é → 漢字 {"abcdefghij"*5}\n'.encode(); lines.append(line); size += len(line); i += 1
    initial = b''.join(lines); initial += b'z' * (limit - len(initial) - 1) + b'\n'
    assert len(initial) == limit
    doc = d/'limit.txt'; doc.write_bytes(initial)
    over = d/'over.txt'; over.write_bytes(initial + b'!')
    env = dict(os.environ, DISPLAY=display); env.pop('XAUTHORITY', None)
    refused = subprocess.run([str(args.notes.resolve()), str(over)], env=env, stdin=subprocess.DEVNULL,
                             capture_output=True, timeout=30)
    (d/'over.stderr').write_bytes(refused.stderr)
    assert refused.returncode != 0 and refused.stdout == b'', refused
    assert refused.stderr == b'notes: file exceeds the 1048576-byte limit. No file changed.\n', refused.stderr
    assert over.read_bytes() == initial + b'!' and not list(d.glob('.herbert-notes-*'))
    with application(args.notes, doc, b'Herbert - Notes', (900,600), x, display, d, 'notes-big') as app:
        top = region(app.frame('opened'),28,102,838,14)
        app.type('x')
        wait_for(warned, 'typing into a full document is refused visibly')
        app.tap('End','Control_L')
        wait_for(lambda: region(app.frame(),28,102,838,14) != top, 'Ctrl+End shows the last lines')
        app.frame('end')
        for _ in range(20): app.tap('BackSpace')
        app.type('Q')
        expected = initial[:-20] + b'Q'
        saved(doc, expected, 'an edit at the end of a 1 MiB document saved')
        app.tap('Home','Control_L')
        wait_for(lambda: region(app.frame(),28,102,838,14) == top, 'Ctrl+Home shows the first line again')
        cpu = cpu_seconds(app.p.pid)
        typed = 'Herbert'
        app.type(typed)
        expected = typed.encode() + expected
        saved(doc, expected, 'typing at the start of the document saved')
        cpu = cpu_seconds(app.p.pid) - cpu
        for _ in range(len(typed) - 1): app.tap('z','Control_L')
        expected = typed[:1].encode() + expected[len(typed):]
        saved(doc, expected, 'undo at the start of a 1 MiB document saved')
        for _ in range(12): app.tap('Next')
        app.tap('Down'); app.type('M')
        moved = region(app.frame('paged'),28,102,838,14)
        assert moved != top, 'Page Down scrolled the view'
        # Page Down moves 20 rows, keeping the column (1, after the H).
        row = 12 * 20 + 1
        offset = sum(len(line) for line in expected.split(b'\n')[:row]) + row + 1
        expected = expected[:offset] + b'M' + expected[offset:]
        saved(doc, expected, 'an edit 241 rows down landed on that row')
        app.tap('a','Control_L'); app.tap('c','Control_L')
        wait_for(warned, 'copying a selection larger than the clipboard is refused visibly')
        app.tap('Escape'); app.tap('s','Control_L'); time.sleep(.3)
        wait_for(lambda: not warned(), 'footer back to normal')
        app.tap('a','Control_L'); app.tap('x','Control_L')
        wait_for(warned, 'cutting a selection larger than the clipboard is refused visibly')
        # The save's footer shows once the keys before it are handled.
        app.tap('Escape'); app.tap('s','Control_L')
        wait_for(lambda: not warned(), 'footer back to normal after the refused cut', timeout=10)
        assert doc.read_bytes() == expected, 'the refused cut left the document whole'
        app.tap('o','Control_L'); app.type('over.txt'); app.tap('Return')
        wait_for(warned, 'Ctrl+O of a file over the limit is refused visibly')
        app.tap('Escape')
        app.tap('Home','Control_L')
        samples = []
        # Each save waits for a different file, so no cycle ends before its keys.
        for cycle in range(1, 7):
            app.type('w'); saved(doc, b'w' + expected, 'an insertion at the start saved')
            app.tap('BackSpace'); saved(doc, expected, 'its deletion saved')
            if cycle % 2 == 0: samples.append(memory(app.p.pid))
        (d/'notes-big-memory.json').write_text(json.dumps(samples, indent=2)+'\n')
        stable_memory(samples, '1 MiB document edits and saves')
        # A batch's checkpoint follows its keys, a save among them included.
        recoveries = lambda: sorted(p.read_bytes() for p in d.glob(f'.herbert-notes-{app.p.pid}-*/recovery.txt'))
        wait_for(lambda: recoveries() == [expected], 'the recovery copy holds the latest text', timeout=10)
        app.tap('Escape')
        app.finish()
    assert over.read_bytes() == initial + b'!'
    assert not list(d.glob('.herbert-save-*.tmp')), 'big saves leaked temporary files'
    passed('notes-1mib-limit-refusals-edits-at-both-ends-paging-clipboard-refusal-recovery-memory',
           document_bytes=limit, typed=len(typed), cpu_seconds_typing_at_start=round(cpu, 3), samples=samples)


def notes_mouse_checks(args, x, display, evidence, passed):
    d = evidence/'mouse'; d.mkdir()
    mark = (3033707).to_bytes(3,'big')
    def at(row, col, right=False):
        # A point in a character cell; the right half rounds to the boundary after it.
        return 28 + col * 12 + (9 if right else 3), 100 + row * 20 + 10
    def saved(path, wanted, what):
        app.tap('s','Control_L')
        wait_for(lambda: path.read_bytes()==wanted, what)
    def shows(colour):
        return colour in region(app.frame(),26,98,848,424)
    doc = d/'notes.txt'; doc.write_bytes(b'alpha beta\ngamma delta\nend\n')
    with application(args.notes, doc, b'Herbert - Notes', (900,600), x, display, d, 'mouse') as app:
        app.click(*at(1, 5, right=True)); app.type('#')
        saved(doc, b'alpha beta\ngamma #delta\nend\n', 'a click places the cursor at the nearest boundary')
        app.move(*at(0, 0)); app.button(True); app.move(*at(0, 2)); app.move(*at(0, 4, right=True)); app.button(False)
        wait_for(lambda: shows(mark), 'a drag highlights its selection')
        app.frame('dragged')
        app.tap('x','Control_L'); saved(doc, b' beta\ngamma #delta\nend\n', 'a drag selects what it covers')
        app.tap('z','Control_L'); saved(doc, b'alpha beta\ngamma #delta\nend\n', 'one undo restores the dragged cut')
        app.click(*at(0, 0)); app.click(*at(1, 4, right=True), 'Shift_L'); app.type('Z')
        saved(doc, b'Z #delta\nend\n', 'Shift+click extends the selection from the cursor')
        app.tap('End','Control_L'); app.click(450, 30); app.type('!')
        saved(doc, b'Z #delta\nend\n!', 'a click outside the text leaves the cursor')
        app.tap('f','Control_L'); app.type('delta'); app.click(*at(1, 1)); app.tap('Escape'); app.type('^')
        saved(doc, b'Z #^delta\nend\n!', 'a click while Find is open is ignored')
        # Keys and clicks queued together are handled in the order they happened.
        app.stop()
        app.type('1', pause=0); app.click(*at(0, 0), pause=0); app.type('2', pause=0)
        app.p.send_signal(signal.SIGCONT)
        saved(doc, b'2Z #^1delta\nend\n!', 'type, click, type keeps its order')
        samples = []
        for cycle in range(1, 21):
            app.move(*at(0, 0)); app.button(True); app.move(*at(1, 3)); app.button(False)
            app.click(*at(1, 0))
            if cycle % 2 == 0:
                app.frame(); samples.append(memory(app.p.pid))
        stable_memory(samples, 'clicks and drags')
        app.tap('Escape'); app.finish()
    long = d/'long.txt'; text = b''.join(b'line %02d\n' % i for i in range(80)); long.write_bytes(text)
    with application(args.notes, long, b'Herbert - Notes', (900,600), x, display, d, 'mouse-scroll') as app:
        app.move(*at(0, 0)); app.button(True); app.move(450, 560)
        time.sleep(3)
        app.button(False)
        app.frame('scrolled-drag')
        app.tap('x','Control_L'); app.tap('s','Control_L')
        wait_for(lambda: long.read_bytes()!=text, 'the scrolled selection cut')
        removed = 80 - long.read_bytes().count(b'\n')
        assert removed >= 30, ('a drag held below the text selects past one screen', removed)
        app.tap('Escape'); app.finish()
    passed('notes-mouse-click-drag-shift-click-outside-find-order-edge-scroll-memory', samples=samples,
           rows_selected_by_held_drag=removed)


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
                    notes_unicode_checks(args,x,display,evidence,passed)
                    notes_unicode_limits_checks(args,x,display,evidence,passed)
                    notes_newline_checks(args,x,display,evidence,passed)
                    notes_checks(args,x,display,evidence,passed)
                    notes_fault_checks(args,x,display,evidence,passed)
                    notes_editing_checks(args,x,display,evidence,passed)
                    notes_open_checks(args,x,display,evidence,passed)
                    notes_selection_checks(args,x,display,evidence,passed)
                    notes_clipboard_checks(args,x,display,evidence,passed)
                    notes_mouse_checks(args,x,display,evidence,passed)
                    notes_big_checks(args,x,display,evidence,passed)
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
