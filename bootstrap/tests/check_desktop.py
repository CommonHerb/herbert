#!/usr/bin/env python3
"""Observe the Herbert desktop program through X11, not its implementation.

Python, libX11, libXtst and Xvfb are test tools only. The executable under test
does not link them. Default runs use a private Xvfb server: genuine keyboard
events and focus changes cannot reach the user's desktop. --desktop instead
sends events addressed only to the newly created test window, without moving
the user's focus. Its smaller smoke test covers pixels, idle updates, one
synthetic held key/release and close. Real focus changes interrupt that input
check explicitly; they are not overridden or reported as a pass.
"""

import argparse
import contextlib
import ctypes as C
import ctypes.util
import hashlib
import json
import os
from pathlib import Path
import select
import struct
import subprocess
import tempfile
import time
import zlib


ROOT = Path(__file__).resolve().parents[2]
TITLE = b"Herbert - First steps"
CHARACTER_RGB = 0xF6C85F


class XKeyEvent(C.Structure):
    _fields_ = [
        ("type", C.c_int), ("serial", C.c_ulong), ("send_event", C.c_int),
        ("display", C.c_void_p), ("window", C.c_ulong), ("root", C.c_ulong),
        ("subwindow", C.c_ulong), ("time", C.c_ulong),
        ("x", C.c_int), ("y", C.c_int), ("x_root", C.c_int), ("y_root", C.c_int),
        ("state", C.c_uint), ("keycode", C.c_uint), ("same_screen", C.c_int),
    ]


class XClientData(C.Union):
    _fields_ = [("b", C.c_char * 20), ("s", C.c_short * 10), ("l", C.c_long * 5)]


class XClientMessageEvent(C.Structure):
    _fields_ = [
        ("type", C.c_int), ("serial", C.c_ulong), ("send_event", C.c_int),
        ("display", C.c_void_p), ("window", C.c_ulong),
        ("message_type", C.c_ulong), ("format", C.c_int), ("data", XClientData),
    ]


class XFocusChangeEvent(C.Structure):
    _fields_ = [
        ("type", C.c_int), ("serial", C.c_ulong), ("send_event", C.c_int),
        ("display", C.c_void_p), ("window", C.c_ulong), ("mode", C.c_int), ("detail", C.c_int),
    ]


class XEvent(C.Union):
    _fields_ = [("key", XKeyEvent), ("client", XClientMessageEvent),
                ("focus", XFocusChangeEvent), ("pad", C.c_long * 24)]


class XImage(C.Structure):
    _fields_ = [
        ("width", C.c_int), ("height", C.c_int), ("xoffset", C.c_int),
        ("format", C.c_int), ("data", C.c_void_p), ("byte_order", C.c_int),
        ("bitmap_unit", C.c_int), ("bitmap_bit_order", C.c_int),
        ("bitmap_pad", C.c_int), ("depth", C.c_int), ("bytes_per_line", C.c_int),
        ("bits_per_pixel", C.c_int), ("red_mask", C.c_ulong),
        ("green_mask", C.c_ulong), ("blue_mask", C.c_ulong),
    ]


class XConnection:
    def __init__(self, display):
        self.x = C.CDLL(ctypes.util.find_library("X11"))
        self.xtst = C.CDLL(ctypes.util.find_library("Xtst"))
        # An unrelated desktop window can disappear between XQueryTree and
        # XFetchName. Keep Xlib's default error handler from exiting Python
        # (which would bypass cleanup); each operation checks its own result.
        self.error_handler = C.CFUNCTYPE(C.c_int, C.c_void_p, C.c_void_p)(lambda *_: 0)
        self.x.XSetErrorHandler.argtypes = [C.c_void_p]
        self.x.XSetErrorHandler.restype = C.c_void_p
        self.previous_error_handler = self.x.XSetErrorHandler(self.error_handler)
        specs = {
            "XOpenDisplay": (C.c_void_p, [C.c_char_p]),
            "XCloseDisplay": (C.c_int, [C.c_void_p]),
            "XDefaultRootWindow": (C.c_ulong, [C.c_void_p]),
            "XQueryTree": (C.c_int, [C.c_void_p, C.c_ulong, C.POINTER(C.c_ulong),
                                    C.POINTER(C.c_ulong), C.POINTER(C.POINTER(C.c_ulong)),
                                    C.POINTER(C.c_uint)]),
            "XFetchName": (C.c_int, [C.c_void_p, C.c_ulong, C.POINTER(C.c_char_p)]),
            "XFree": (C.c_int, [C.c_void_p]),
            "XSync": (C.c_int, [C.c_void_p, C.c_int]),
            "XGetGeometry": (C.c_int, [C.c_void_p, C.c_ulong, C.POINTER(C.c_ulong),
                                      C.POINTER(C.c_int), C.POINTER(C.c_int),
                                      C.POINTER(C.c_uint), C.POINTER(C.c_uint),
                                      C.POINTER(C.c_uint), C.POINTER(C.c_uint)]),
            "XGetImage": (C.POINTER(XImage), [C.c_void_p, C.c_ulong, C.c_int, C.c_int,
                                             C.c_uint, C.c_uint, C.c_ulong, C.c_int]),
            "XDestroyImage": (C.c_int, [C.POINTER(XImage)]),
            "XSetInputFocus": (C.c_int, [C.c_void_p, C.c_ulong, C.c_int, C.c_ulong]),
            "XGetInputFocus": (C.c_int, [C.c_void_p, C.POINTER(C.c_ulong), C.POINTER(C.c_int)]),
            "XSelectInput": (C.c_int, [C.c_void_p, C.c_ulong, C.c_long]),
            "XCheckWindowEvent": (C.c_int, [C.c_void_p, C.c_ulong, C.c_long, C.POINTER(XEvent)]),
            "XStringToKeysym": (C.c_ulong, [C.c_char_p]),
            "XKeysymToKeycode": (C.c_ubyte, [C.c_void_p, C.c_ulong]),
            "XGetKeyboardMapping": (C.POINTER(C.c_ulong), [C.c_void_p, C.c_ubyte, C.c_int, C.POINTER(C.c_int)]),
            "XChangeKeyboardMapping": (C.c_int, [C.c_void_p, C.c_int, C.c_int, C.POINTER(C.c_ulong), C.c_int]),
            "XSendEvent": (C.c_int, [C.c_void_p, C.c_ulong, C.c_int, C.c_long, C.POINTER(XEvent)]),
            "XInternAtom": (C.c_ulong, [C.c_void_p, C.c_char_p, C.c_int]),
        }
        for name, (restype, args) in specs.items():
            function = getattr(self.x, name)
            function.restype, function.argtypes = restype, args
        self.xtst.XTestFakeKeyEvent.argtypes = [C.c_void_p, C.c_uint, C.c_int, C.c_ulong]
        self.xtst.XTestFakeKeyEvent.restype = C.c_int
        self.display = self.x.XOpenDisplay(display.encode())
        if not self.display:
            raise AssertionError(f"cannot open test X display {display!r}")
        self.root = self.x.XDefaultRootWindow(self.display)
        self.held = set()
        self.started = time.monotonic()

    def close(self):
        for keycode in self.held:
            self.xtst.XTestFakeKeyEvent(self.display, keycode, 0, 0)
        self.x.XSync(self.display, 0)
        self.x.XCloseDisplay(self.display)
        self.x.XSetErrorHandler(self.previous_error_handler)

    def windows(self):
        # Read only IDs/names; never save unrelated window content or properties.
        result, pending = set(), [self.root]
        while pending:
            window = pending.pop()
            root, parent, count = C.c_ulong(), C.c_ulong(), C.c_uint()
            children = C.POINTER(C.c_ulong)()
            if self.x.XQueryTree(self.display, window, C.byref(root), C.byref(parent),
                                 C.byref(children), C.byref(count)):
                found = [children[i] for i in range(count.value)]
                pending.extend(found)
                result.update(found)
                if children:
                    self.x.XFree(children)
        return result

    def name(self, window):
        name = C.c_char_p()
        self.x.XFetchName(self.display, window, C.byref(name))
        value = name.value
        if name:
            self.x.XFree(name)
        return value

    def focus(self, window):
        self.x.XSetInputFocus(self.display, window, 1, 0)
        self.x.XSync(self.display, 0)

    def synthetic_focus(self, window):
        event = XEvent()
        event.focus.type, event.focus.display, event.focus.window = 9, self.display, window
        event.focus.mode, event.focus.detail = 0, 3
        if not self.x.XSendEvent(self.display, window, 0, 1 << 21, C.byref(event)):
            raise AssertionError("targeted focus event could not be sent")
        self.x.XSync(self.display, 0)

    def watch_focus(self, window):
        # Event selection is per client; this does not alter the app's mask.
        self.x.XSelectInput(self.display, window, 1 << 21)
        self.x.XSync(self.display, 0)

    def owns_focus(self, window):
        focused, revert = C.c_ulong(), C.c_int()
        self.x.XGetInputFocus(self.display, C.byref(focused), C.byref(revert))
        # Do not record the identity of any unrelated focused window.
        return focused.value == window

    def focus_events(self, window):
        found, event = [], XEvent()
        while self.x.XCheckWindowEvent(self.display, window, 1 << 21, C.byref(event)):
            found.append({"seconds": round(time.monotonic() - self.started, 3),
                          "event": "in" if event.focus.type == 9 else "out",
                          "synthetic": bool(event.focus.send_event),
                          "mode": event.focus.mode, "detail": event.focus.detail})
        return found

    def swap_keys(self, first, second):
        codes = [self.x.XKeysymToKeycode(self.display, self.x.XStringToKeysym(k.encode()))
                 for k in (first, second)]
        rows = []
        for code in codes:
            count = C.c_int()
            pointer = self.x.XGetKeyboardMapping(self.display, code, 1, C.byref(count))
            if not pointer:
                raise AssertionError("cannot read isolated keyboard mapping")
            rows.append((C.c_ulong * count.value)(*(pointer[i] for i in range(count.value))))
            self.x.XFree(pointer)
        for code, row in zip(codes, reversed(rows)):
            self.x.XChangeKeyboardMapping(self.display, code, len(row), row, 1)
        self.x.XSync(self.display, 0)
        # Read the server mapping itself, independent of Xlib's keysym cache.
        for code, expected in zip(codes, reversed(rows)):
            count = C.c_int()
            pointer = self.x.XGetKeyboardMapping(self.display, code, 1, C.byref(count))
            if not pointer:
                raise AssertionError("cannot read back isolated keyboard mapping")
            try:
                if count.value == 0 or pointer[0] != expected[0]:
                    raise AssertionError("isolated keyboard mapping swap did not take effect")
            finally:
                self.x.XFree(pointer)
        return codes

    def key(self, window, key, down, *, synthetic=False):
        code = self.x.XKeysymToKeycode(self.display, self.x.XStringToKeysym(key.encode()))
        if not code:
            raise AssertionError(f"server has no keycode for {key}")
        if synthetic:
            event = XEvent()
            event.key.type = 2 if down else 3
            event.key.display, event.key.window, event.key.root = self.display, window, self.root
            event.key.keycode, event.key.same_screen = code, 1
            if not self.x.XSendEvent(self.display, window, 0, 1 if down else 2, C.byref(event)):
                raise AssertionError("targeted key event could not be sent")
        else:
            if not self.xtst.XTestFakeKeyEvent(self.display, code, int(down), 0):
                raise AssertionError("XTest keyboard injection failed")
            if down:
                self.held.add(code)
            else:
                self.held.discard(code)
        self.x.XSync(self.display, 0)

    def delete(self, window):
        event = XEvent()
        event.client.type, event.client.display, event.client.window = 33, self.display, window
        event.client.message_type = self.x.XInternAtom(self.display, b"WM_PROTOCOLS", 0)
        event.client.format = 32
        event.client.data.l[0] = self.x.XInternAtom(self.display, b"WM_DELETE_WINDOW", 0)
        if not self.x.XSendEvent(self.display, window, 0, 0, C.byref(event)):
            raise AssertionError("WM_DELETE_WINDOW could not be sent")
        self.x.XSync(self.display, 0)

    def geometry(self, window):
        root = C.c_ulong()
        x, y = C.c_int(), C.c_int()
        width, height, border, depth = (C.c_uint() for _ in range(4))
        if not self.x.XGetGeometry(self.display, window, C.byref(root), C.byref(x), C.byref(y),
                                  C.byref(width), C.byref(height), C.byref(border), C.byref(depth)):
            raise AssertionError("cannot query test window geometry")
        return width.value, height.value

    def snapshot(self, window):
        width, height = self.geometry(window)
        pointer = self.x.XGetImage(self.display, window, 0, 0, width, height,
                                   C.c_ulong(-1).value, 2)
        if not pointer:
            raise AssertionError("cannot read test window pixels")
        try:
            im = pointer.contents
            if (im.bits_per_pixel, im.byte_order, im.red_mask, im.green_mask, im.blue_mask) != (
                    32, 0, 0xFF0000, 0xFF00, 0xFF):
                raise AssertionError("test image decoder requires observed 32bpp LSB TrueColor format")
            raw = C.string_at(im.data, im.bytes_per_line * im.height)
            rgb = bytearray(im.width * im.height * 3)
            xs, ys = [], []
            needle = struct.pack("<I", CHARACTER_RGB)[:3]
            for row in range(im.height):
                pixels = raw[row * im.bytes_per_line:row * im.bytes_per_line + im.width * 4]
                offset = row * im.width * 3
                rgb[offset:offset + im.width * 3:3] = pixels[2::4]
                rgb[offset + 1:offset + im.width * 3:3] = pixels[1::4]
                rgb[offset + 2:offset + im.width * 3:3] = pixels[0::4]
                at = pixels.find(needle)
                while at != -1:
                    if at % 4 == 0:
                        xs.append(at // 4)
                        ys.append(row)
                    at = pixels.find(needle, at + 1)
            bbox = (min(xs), min(ys), max(xs), max(ys)) if xs else None
            return {"width": im.width, "height": im.height, "rgb": bytes(rgb), "bbox": bbox,
                    "digest": hashlib.sha256(rgb).hexdigest()}
        finally:
            self.x.XDestroyImage(pointer)


def save_png(path, frame):
    def chunk(kind, data):
        return struct.pack("!I", len(data)) + kind + data + struct.pack("!I", zlib.crc32(kind + data))
    w, h, rgb = frame["width"], frame["height"], frame["rgb"]
    rows = b"".join(b"\0" + rgb[y*w*3:(y+1)*w*3] for y in range(h))
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack("!IIBBBBB", w, h, 8, 2, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def center(frame):
    box = frame["bbox"]
    if box is None:
        raise AssertionError("gold character pixels absent")
    if not (15 <= box[2] - box[0] <= 40 and 15 <= box[3] - box[1] <= 40):
        raise AssertionError(f"unexpected character bounds {box}")
    return ((box[0] + box[2]) / 2, (box[1] + box[3]) / 2)


def memory(pid):
    values = {}
    for line in Path(f"/proc/{pid}/status").read_text().splitlines():
        if line.startswith(("VmRSS:", "VmSize:", "VmHWM:")):
            key, value, _ = line.split()
            values[key[:-1]] = int(value)
    # smaps_rollup avoids the kernel's batched RSS accounting for tiny processes.
    for line in Path(f"/proc/{pid}/smaps_rollup").read_text().splitlines():
        if line.startswith("Rss:"):
            values["Rss"] = int(line.split()[1])
    return values


@contextlib.contextmanager
def private_display(directory):
    readfd, writefd = os.pipe()
    log = (directory / "xvfb.log").open("wb")
    process = subprocess.Popen(["Xvfb", "-displayfd", str(writefd), "-screen", "0", "800x600x24",
                                "-nolisten", "tcp"], pass_fds=(writefd,), stdout=log, stderr=log)
    os.close(writefd)
    try:
        if not select.select([readfd], [], [], 10)[0]:
            raise AssertionError("private Xvfb did not become ready")
        display = os.read(readfd, 64).decode().strip()
        if not display.isdigit():
            raise AssertionError("private Xvfb returned no display number")
        yield ":" + display
    finally:
        os.close(readfd)
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        log.close()


class Application:
    def __init__(self, args, connection, display, evidence, label):
        self.connection, self.label = connection, label
        before = connection.windows()
        env = dict(os.environ, DISPLAY=display)
        if not args.desktop:
            env.pop("XAUTHORITY", None)
        self.stdout = (evidence / f"{label}.stdout").open("wb")
        self.stderr = (evidence / f"{label}.stderr").open("wb")
        self.process = subprocess.Popen([str(args.image.resolve())], env=env, stdin=subprocess.DEVNULL,
                                         stdout=self.stdout, stderr=self.stderr)
        self.window = None
        try:
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                if self.process.poll() is not None:
                    raise AssertionError(f"application exited during startup: {self.process.returncode}")
                candidates = [w for w in connection.windows() - before
                              if connection.name(w) == TITLE and connection.geometry(w) == (640, 480)]
                if len(candidates) == 1:
                    self.window = candidates[0]
                    time.sleep(0.15)
                    return
                if len(candidates) > 1:
                    raise AssertionError(f"ambiguous newly created 640x480 test clients: {candidates}")
                time.sleep(0.02)
            raise AssertionError("application did not create its window")
        except BaseException:
            self.cleanup()
            raise

    def finished(self):
        try:
            status = self.process.wait(timeout=3)
        except subprocess.TimeoutExpired as error:
            raise AssertionError("application did not shut down within 3 seconds") from error
        self.stdout.flush()
        self.stderr.flush()
        if status != 0:
            raise AssertionError(f"application exited with status {status}")
        deadline = time.monotonic() + 2
        while self.window in self.connection.windows():
            if time.monotonic() >= deadline:
                raise AssertionError("window survived successful application exit")
            time.sleep(0.02)

    def cleanup(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.stdout.close()
        self.stderr.close()


def error_cases(args, display, evidence, passed):
    base = dict(os.environ, DISPLAY=display)
    if not args.desktop:
        base.pop("XAUTHORITY", None)
    missing_display = dict(base)
    missing_display.pop("DISPLAY", None)
    missing_auth = dict(base, XAUTHORITY=str((evidence / "absent.xauthority").resolve()))
    malformed = evidence / "malformed.xauthority"
    fake_secret = b"TEST_SECRET_MUST_NOT_APPEAR_IN_DIAGNOSTICS"
    malformed.write_bytes(b"\x01\x00\xff\xff" + fake_secret)
    malformed_auth = dict(base, XAUTHORITY=str(malformed.resolve()))
    for label, env, expected in (
            ("missing-display", missing_display, b"DISPLAY is missing"),
            ("unreadable-auth", missing_auth, b"cannot read Xauthority"),
            ("malformed-auth", malformed_auth, b"Xauthority")):
        before = time.monotonic()
        result = subprocess.run([str(args.image.resolve())], env=env, stdin=subprocess.DEVNULL,
                                capture_output=True, timeout=5)
        (evidence / f"{label}.stdout").write_bytes(result.stdout)
        (evidence / f"{label}.stderr").write_bytes(result.stderr)
        assert result.returncode == 1 and not result.stdout, (label, result.returncode)
        assert expected in result.stderr and fake_secret not in result.stderr, label
        passed(label, status=result.returncode, seconds=round(time.monotonic() - before, 3))

    # Terminate only a server we just started, after closing our test-side
    # Xlib connection. The Herbert program must observe EOF and exit itself.
    directory = evidence / "disconnect"
    directory.mkdir()
    disconnected = None
    try:
        with private_display(directory) as isolated:
            conn = XConnection(isolated)
            try:
                private_args = argparse.Namespace(image=args.image, desktop=False)
                disconnected = Application(private_args, conn, isolated, directory, "disconnect")
                center(conn.snapshot(disconnected.window))
            finally:
                conn.close()
        before = time.monotonic()
        status = disconnected.process.wait(timeout=3)
        disconnected.stdout.flush()
        disconnected.stderr.flush()
        assert status == 1, f"display disconnect returned status {status}"
        assert not (directory / "disconnect.stdout").read_bytes()
        assert b"desktop:" in (directory / "disconnect.stderr").read_bytes()
        passed("display-disconnect", status=status, seconds=round(time.monotonic() - before, 3))
    finally:
        if disconnected:
            disconnected.cleanup()


def run(args, display, evidence):
    connection = XConnection(display)
    result = {"mode": "desktop-targeted-synthetic-events" if args.desktop else "private-Xvfb-XTest",
              "scope": "desktop-smoke" if args.desktop else "full-interactive-and-errors",
              "image_sha256": hashlib.sha256(args.image.read_bytes()).hexdigest(),
              "checks": [], "focus_events": []}
    application = None

    def passed(label, **data):
        result["checks"].append({"check": label, **data})
        print(f"PASS desktop {label}: {json.dumps(data, sort_keys=True)}", flush=True)

    try:
        if not args.desktop:
            # This server belongs solely to this test. The application's
            # mapping query must discover Right at its nondefault keycode.
            old_codes = connection.swap_keys("Right", "F6")
            passed("isolated-keymap-remapped", original_right_keycode=old_codes[0],
                   remapped_right_keycode=old_codes[1], server_readback_verified=True)
        application = Application(args, connection, display, evidence, "interactive")
        window = application.window
        connection.watch_focus(window)
        if not args.desktop:
            connection.focus(window)
        else:
            connection.synthetic_focus(window)
        def snapshot():
            result["focus_events"].extend(connection.focus_events(window))
            return connection.snapshot(window)
        key = lambda name, down: connection.key(window, name, down, synthetic=args.desktop)
        initial = snapshot()
        assert (initial["width"], initial["height"]) == (640, 480), "window dimensions changed"
        initial_position = center(initial)
        save_png(evidence / "initial.png", initial)
        passed("window-and-character", size=[640, 480], center=initial_position)

        idle = {initial["digest"]}
        idle_deadline = time.monotonic() + 3
        while len(idle) < 2 and time.monotonic() < idle_deadline:
            time.sleep(0.12)
            frame = snapshot()
            idle.add(frame["digest"])
            assert center(frame) == initial_position, "character drifts without input"
        assert len(idle) >= 2, "window has no ongoing visible screen updates"
        passed("idle-updates", distinct_frames=len(idle))

        # Physical key holds cross the usual repeat delay; three successive
        # readings must move, so a single key-press step cannot pass.
        key("Right", True)
        positions = [initial_position]
        for _ in range(3):
            time.sleep(0.22)
            positions.append(center(snapshot()))
        key("Right", False)
        time.sleep(0.10)
        released = center(snapshot())
        time.sleep(0.25)
        stopped = center(snapshot())
        interrupted = args.desktop and any(e["event"] == "out" and not e["synthetic"]
                                           for e in result["focus_events"])
        if interrupted:
            result["checks"].append({"check": "held-right-and-release", "status": "INTERRUPTED",
                                      "reason": "actual desktop FocusOut", "positions": positions})
            print("UNVERIFIED desktop held-right-and-release: actual FocusOut interrupted synthetic input", flush=True)
        else:
            assert all(b[0] > a[0] and b[1] == a[1] for a, b in zip(positions, positions[1:])), positions
            assert stopped == released, "character keeps moving after release"
            passed("held-right-and-release", positions=positions, stopped=released)
        save_png(evidence / "moved.png", snapshot())

        if args.desktop:
            connection.delete(window)
            application.finished()
            passed("window-manager-clean-exit")
            result["status"] = "PARTIAL" if interrupted else "PASS"
            print(f"desktop smoke: {result['status']}; targeted synthetic input; evidence {evidence}", flush=True)
            return 2 if interrupted else 0

        for name, axis, sign in (("Left", 0, -1), ("Up", 1, -1), ("Down", 1, 1),
                                 ("a", 0, -1), ("w", 1, -1), ("d", 0, 1), ("s", 1, 1)):
            before = center(snapshot())
            key(name, True)
            time.sleep(0.16)
            key(name, False)
            time.sleep(0.05)
            after = center(snapshot())
            assert sign * (after[axis] - before[axis]) > 0, (name, before, after)
            assert after[1-axis] == before[1-axis], (name, before, after)
        passed("arrows-and-wasd")

        if not args.desktop:
            key("Left", True)
            time.sleep(0.18)
            connection.focus(connection.root)
            time.sleep(0.08)
            lost = center(snapshot())
            time.sleep(0.25)
            assert center(snapshot()) == lost, "held key keeps moving after focus loss"
            key("Left", False)
            connection.focus(window)
            time.sleep(0.15)
            assert center(snapshot()) == lost, "refocus resurrects a released key"
            passed("focus-loss-clears-held-key", stopped=lost)

        # Sustained alternating motion checks resource use while the program
        # draws and accepts input, rather than sleeping at a static image.
        samples, frames, moved = [], set(), 0
        started = time.monotonic()
        cycle = ("Right", "Down", "Left", "Up")
        previous = center(snapshot())
        index = 0
        while time.monotonic() - started < args.seconds:
            name = cycle[index % len(cycle)]
            key(name, True)
            time.sleep(0.22)
            key(name, False)
            frame = snapshot()
            now = center(frame)
            moved += now != previous
            previous = now
            frames.add(frame["digest"])
            samples.append({"seconds": round(time.monotonic() - started, 3), **memory(application.process.pid)})
            index += 1
            if index % 100 == 0:
                print(f"desktop sustained: {index} motion samples, {samples[-1]}", flush=True)
        assert moved >= len(samples) * 0.9, "sustained input stopped changing character position"
        rss = [s["Rss"] for s in samples]
        vsize = [s["VmSize"] for s in samples]
        (evidence / "memory.json").write_text(json.dumps(samples, indent=2) + "\n")
        assert max(rss) - min(rss) <= 256, f"sustained RSS grew by {max(rss)-min(rss)} KiB"
        decile = max(1, len(rss) // 10)
        rss_trend = (sum(rss[-decile:]) - sum(rss[:decile])) / decile
        assert rss_trend <= 64, f"sustained RSS first-to-last-decile mean grew by {rss_trend:.2f} KiB"
        assert max(vsize) - min(vsize) <= 4096, "sustained virtual address space grew"
        passed("sustained-motion-memory", seconds=round(time.monotonic()-started, 2), samples=len(samples),
               distinct_frames=len(frames), moved_samples=moved, rss_kib_min=min(rss), rss_kib_max=max(rss),
               rss_decile_growth_kib=round(rss_trend, 3),
               vm_size_kib_min=min(vsize), vm_size_kib_max=max(vsize))

        edges = []
        for name, axis, limit in (("Right", 0, 598), ("Down", 1, 402),
                                  ("Left", 0, 42), ("Up", 1, 118)):
            key(name, True)
            began = time.monotonic()
            path = []
            while True:
                time.sleep(0.20)
                edge = center(snapshot())
                path.append({"center": edge, "seconds": round(time.monotonic() - began, 3),
                             "owns_actual_focus": connection.owns_focus(window)})
                if abs(edge[axis] - limit) <= 0.5:
                    break
                assert time.monotonic() - began < 8, (name, "did not reach edge", path)
            time.sleep(0.15)
            later = center(snapshot())
            assert later == edge, (name, "edge does not clamp", edge, later)
            key(name, False)
            # X11 fills may put the pixel bounding center half a pixel below
            # the integer logical center for an even-sized character.
            assert abs(edge[axis] - limit) <= 0.5, (name, edge, limit)
            edges.append({"key": name, "center": edge, "seconds": round(time.monotonic() - began, 3)})
        passed("playfield-clamps-all-directions", edges=edges)

        key("Escape", True)
        if not args.desktop:
            # Release on the isolated server even if the app already exited.
            connection.key(window, "Escape", False)
        application.finished()
        passed("escape-clean-exit")
        application.cleanup()
        application = Application(args, connection, display, evidence, "wm-delete")
        connection.delete(application.window)
        application.finished()
        passed("window-manager-clean-exit")
        error_cases(args, display, evidence, passed)
        result["status"] = "PASS"
    except BaseException as error:
        result["status"] = "FAIL"
        result["error"] = f"{type(error).__name__}: {error}"
        if application and application.window and application.process.poll() is None:
            try:
                result["owns_actual_focus_at_failure"] = connection.owns_focus(application.window)
                result["focus_events"].extend(connection.focus_events(application.window))
                save_png(evidence / "failure.png", connection.snapshot(application.window))
            except Exception:
                pass
        raise
    finally:
        if application:
            application.cleanup()
        connection.close()
        (evidence / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(f"desktop: {len(result['checks'])} checks passed; evidence {evidence}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", type=Path, default=ROOT / "build/first-steps")
    parser.add_argument("--desktop", action="store_true", help="test our new window on existing DISPLAY")
    parser.add_argument("--seconds", type=float, default=120, help="private-display sustained-update duration")
    parser.add_argument("--evidence", type=Path, help="retain logs, pixel captures and memory samples")
    args = parser.parse_args()
    if args.seconds < 1:
        parser.error("--seconds must be at least 1")
    if not args.image.is_file():
        parser.error(f"executable does not exist: {args.image}")
    evidence = args.evidence or Path(tempfile.mkdtemp(prefix="herbert-desktop-check-"))
    evidence.mkdir(parents=True, exist_ok=True)
    if args.desktop:
        display = os.environ.get("DISPLAY")
        if not display:
            parser.error("--desktop needs DISPLAY")
        status = run(args, display, evidence)
        if status:
            raise SystemExit(status)
    else:
        with private_display(evidence) as display:
            run(args, display, evidence)


if __name__ == "__main__":
    main()
