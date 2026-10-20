# Herbert application support

These are Herbert source units, with no `main`. The Makefile concatenates the
selected units before their application, then the Herbert seed compiles the
result. This is explicit source composition, not a new import/module system or
another language. Names use prefixes because the current function namespace is
flat. The fixed `make first-steps`, `make maze` and `make notes` targets report
locations in the combined source kept in their build directories. The developer
[`make program` workflow](../docs/BUILDING.md) maps checked compiler rejections
back to original files and lines. Runtime bounds faults still refer to combined
source; the retained source map identifies its original units.

- `linux.herb`: fixed byte buffers and endian fields; bounded file/environment
  reading; startup command-line arguments; unsigned decimal formatting; hostname; monotonic clock; polling; complete socket transfers with
  partial-transfer, EINTR, EOF, broken-peer and deadline handling.
- `x11.herb`: local display/authentication, a fixed-size window, server pixmap,
  keyboard mapping and key/focus/close events, rectangle/ellipse requests and
  presentation. X11 itself remains an external desktop service. Its supported
  profile and limitations are documented in the first-steps guide. A connection
  is an `X11` record: `c.state` is a reference record (descriptor, server ids,
  flags), and `c.poll` and `c.clock` are the scratch buffers callers pass to
  `linux_poll` and `linux_clock_ms`.
  `x11_enable_pointer` (opt-in, after `x11_enable_text`) adds left-button presses,
  drags and releases to the same ordered queue as key presses.
- `x11_clipboard.herb`: the desktop clipboard for that window, opt-in. It takes
  CLIPBOARD and answers other applications' requests (UTF8_STRING and
  text/plain;charset=utf-8, with TARGETS and TIMESTAMP), and asks the current owner
  for UTF-8 text with a bounded wait. Incremental transfers are refused, which
  bounds a paste to 65,504 bytes. X11 errors from answering a window that has
  already gone are ignored; any other X11 error still stops the program. Call
  `x11_enable_clipboard` at startup and `x11_serve` after each `x11_events`.
- `pixel_text.herb`: original 5×7 printable ASCII glyphs, strings, buffer spans
  and decimal numbers, rendered without temporary per-frame strings.
- `grid_map.herb`: bounded rectangular ASCII tile maps with enclosure, unique
  spawn and reachable collectible checks. Used by the maze.
- `utf8.herb`: strict scalar decoding/encoding without allocation or normalization.
- `unicode_tables.herb` and `unicode_grapheme.herb`: pinned Unicode 18 data and
  extended grapheme boundaries. Data provenance and regeneration are documented
  in [the Unicode guide](../docs/UNICODE.md).
- `unicode_display.herb`: original Latin prose and punctuation glyphs, with
  supported combining accents and an explicit marker for unavailable glyphs.
- `text_buffer.herb`: fixed-capacity UTF-8 text with byte offsets constrained to
  grapheme boundaries, whole-cluster deletion/navigation, four-column tabs and
  wrapped literal search. History retains up to 256 operations and at most
  `capacity` payload bytes, or the budget given to `text_buffer_history(capacity,
  history)`; whole oldest records are evicted to fit. `text_replace` swaps a span
  for new text as one undo step; a budget of twice the capacity holds any
  whole-text replace. All editing storage is allocated at construction and reused. Loading marks every
  boundary once; an edit re-marks only the lines it touched, and `text_row` and `text_row_offset` count rows
  from one remembered line instead of the start. The state is the reference record `TextState` inside the value
  record `Text`, which names its buffers (`t.bytes` is the logical text). Uniform LF/CRLF loads retain
  their style; internal logical bytes use LF. Save with `text_file_bytes(t)` and
  `text_file_length(t)` to preserve exact encoding and the on-disk capacity bound.
  A CRLF newline is one logical edit. Used by Notes.
- `session_recovery.herb`: descriptor-relative private Notes session directories
  and reusable atomic plain-text checkpoints. Copies persist until explicit user
  cleanup; reopening never adopts the original document. `recovery_reset(r)` ends
  a session so the next checkpoint starts a new one beside whichever document it
  names, without allocating. See the Notes guide.
- `file_io.herb`: open a bounded regular file and save through an exclusive
  temporary file and atomic rename in its opened directory. Detected external
  changes are refused; post-publication sync or verification failure is reported distinctly.
  An exclusive sibling rescue copy can preserve edits without replacing the original.
  The [Notes guide](../examples/notes.md) gives file and metadata limitations.
  A handle is a `File` record: `f.state` is a reference record (directory
  descriptor, last status, counts, mode), `f.bytes` holds the loaded bytes and
  `f.path` the NUL-terminated path; the stat buffers keep the kernel's layout.
  `file_new(capacity)` allocates a handle's storage once and `file_load(f, path,
  count)` loads a document into it, again and again, without allocating;
  `file_open(path, capacity)` does both from a path string.
- `../examples/first_steps.herb`: the application's position, controls and scene.

The compiler has no game/window-specific operation. Five hosted-only primitives
provide general reusable memory and the Linux x86-64 boundary:

| Primitive | Contract |
| --- | --- |
| `buffer_length(b)` | Current logical byte count, with no copy/allocation. |
| `buffer_get(b, i)` | Byte at `i`; fails with a located bounds diagnostic outside the logical length. |
| `buffer_set(b, i, byte)` | Replace an existing byte; validates index and 0..255 value, returns the byte; does not grow or allocate. Aliases see the change. |
| `buffer_address(b)` | **Unsafe borrowed address** of its backing storage. Appending can relocate it; reacquire after growth. An empty buffer gives no permission to dereference. |
| `linux_syscall6(n, a1, a2, a3, a4, a5, a6)` | **Unsafe** raw Linux/x86-64 system call, all arguments and result are unsigned 64-bit integers. Unused arguments are normally zero. |

All five names are reserved builtin function names. They are value expressions,
not `do` calls, and they are refused by the specialized kernel/module targets.
Existing scalar/collection behavior is unchanged. A `freeze` snapshot is still
independent of later buffer changes; it copies, so it is not a per-frame view.
Bounds diagnostics currently use the existing `get` wording and invalid byte
diagnostics the existing `append` wording.

System-call errors retain Linux's negative errno bits. Because Herbert integers
are unsigned, use `linux_error(r)` or compare to `0 - errno`, never `r < 0`.
Linux may modify memory at supplied addresses, and a read does not change the
buffer's logical length: allocate/initialize its full destination span first.
Raw calls and addresses can violate memory safety, terminate the process or
alter files; they are an explicit low-level escape hatch, not checked resource
handles. Higher-level helpers check the spans they expose to Linux.

No new memory collector is claimed. `linux_buffer(n)` creates an initialized
fixed-size byte buffer; the app and its I/O routines reuse those buffers. File
and environment helpers allocate at startup. `linux_copy` is forward copying;
overlapping ranges need destination at or below the source offset.

The hosted implementation owns the compiler, emitted runtime, these source
units and the application. Linux syscall services, procfs, X11/XWayland, the
desktop compositor and drivers are accepted dependencies. Existing development
and independent test tools are a different boundary. No third-party graphics
library, C/Python/Java runtime, or foreign compiler is linked into the program.

Protocol/layout references (specifications, not copied implementation code):
[Linux syscall ABI](https://man7.org/linux/man-pages/man2/syscall.2.html),
[X11 core protocol](https://www.x.org/releases/X11R7.6/doc/xproto/x11protocol.html).

The X11 text-input interface is opt-in: call `x11_enable_text(c)` once, then
call `x11_events(c)` and drain `x11_next_key(c, event)` into a caller-owned
16-byte buffer. Four little-endian u32 fields hold keysym, modifier state,
raw keycode and timestamp. The fixed 256-event queue yields to its consumer
when full; later events stay in the socket. Accepted text survives focus loss;
held movement keys clear on focus loss. `x11_ack_close(c)` lets an application
acknowledge a close request while asking about unsaved edits.

Keyboard translation uses the first two core keymap columns and ASCII
Shift/Caps Lock. `x11_text_scalar` maps Latin-1 and direct Unicode keysyms to
scalar values; applications enforce their own text policy. Legacy script-specific
keysyms, compose/IME, full XKB groups and NumLock translation are unsupported. A mapping refresh becomes active when its reply is
processed; keys received before that use the last completed keymap snapshot.
Already queued keys retain their symbols. This is not an atomic layout switch
while typing. Drawing requests flush bounded batches into the retained pixmap;
`x11_present` copies the finished frame into the window.
