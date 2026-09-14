# First steps: Herbert on your Linux desktop

From the Herbert repository:

```sh
make first-steps && ./build/first-steps
```

Run this in a terminal inside your graphical Linux session. A 640×480 window
opens. Hold an arrow key or W/A/S/D to move the yellow character. Movement stops
at the edge of the play area. Escape or the window's close button exits normally.
Changing focus clears held keys; press again after returning to the window.
The character blinks and the small green indicator changes while idle.

This is the first interactive checkpoint for making Herbert useful for ordinary
programs. There is no maze, collision with obstacles, score, audio or full game
yet. Development stops here for Ben to try it before the game expands.

## What runs

The build joins `lib/linux.herb`, `lib/x11.herb`, `lib/pixel_text.herb` and
`examples/first_steps.herb` as source and compiles them with the committed
Herbert compiler. Make, a shell, `cat` and permission/checksum utilities are build
tools; no C compiler, assembler, foreign runtime or graphics library is linked
into the program. The resulting static Linux/x86-64 executable runs directly.

Herbert performs the application logic, request encoding, input processing and
bitmap-letter placement. It speaks the X11 core protocol directly over a local
Unix socket. The existing X server performs rectangle/ellipse rasterization and
copies the completed off-screen pixmap into the window. This is a dependency on
the desktop's drawing services, not an independently implemented renderer.
Linux, the display server/compositor and device drivers remain external software.

On the inspected machine the desktop is GNOME/Wayland, using its existing
XWayland 23.2.6 server. The connection contract is X11 core protocol 11.0 over
Linux x86-64 system calls. No native Wayland client is claimed. A desktop with
no X11/XWayland connection is not supported by this checkpoint.

## Limits and failure behavior

- Local `DISPLAY=:N` or `unix:N`, optionally `.0`; screen 0 only. No SSH/TCP
  display forwarding. The normal local socket must exist in `/tmp/.X11-unix`.
- Requires a depth-24 TrueColor root visual with RGB masks
  `ff0000/00ff00/0000ff`. Unsupported display profiles are refused.
- Reads the exec-time environment through `/proc/self/environ`. Uses
  `XAUTHORITY`, falling back to `$HOME/.Xauthority`, and supports the local
  MIT-MAGIC-COOKIE-1 authentication record. Authentication contents are never
  printed. It never disables display access control.
- Fixed-size window. This is a small X11 support surface, not a complete window
  toolkit. Graphics acceleration APIs, high-DPI scaling, text entry, Unicode
  layout, mouse controls, multiple windows and clipboard are outside this example.
- Keycodes are discovered from the server's mapping; movement uses the first
  keysym column. Arrow keys are the most layout-independent controls. This is
  key input, not a text-input method.
- Updates aim for a 16 ms interval; scheduling and desktop load affect the
  actual rate. Positions are clamped; diagonal movement is not normalized.
- Connection/setup failures print a short error on stderr and exit 1. Successful
  Escape/window-close exits 0 with no terminal output. Socket operations handle
  partial transfers, retry interrupted calls and bound exact transfers to five
  seconds. Startup file reads assume ordinary local files or procfs.

Steady-state frames reuse byte buffers and a server pixmap. This does not add
general garbage collection to Herbert. Its hosted runtime still reserves a
3.5 GiB virtual arena; reservation is not physical memory consumption. The new
raw system-call and buffer-address interfaces are deliberately unsafe; the
library checks its buffer spans before passing pointers to Linux.

## Verification

```sh
make hosted-memory-io
make check-desktop
```

`check-desktop` uses a private Xvfb display, real XTest keyboard events, pixel
readback and Linux process-memory observations over sustained updates. Python,
libX11, libXtst and Xvfb belong to the independent tests, not to the executable.
`--desktop` on `bootstrap/tests/check_desktop.py` runs a narrower real-display
smoke check: window, idle animation, held Right/release, and window-manager close.
It addresses synthetic events only to its test window. The full control and
sustained-memory checks run on the private display.
Ben reported a successful manual trial on September 13 and authorized the maze
and notes-editor expansion. His report is separate from automated observations
and does not identify the cause of the original Down-test failure.

Build diagnostics refer to the combined source retained at
`build/first-steps-work/source.herb`. Source ownership and the low-level interfaces
are described in [`lib/README.md`](../lib/README.md).
