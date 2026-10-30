# Herbert application support

These are Herbert source units, with no `main`. The Makefile concatenates the
selected units before their application, then the Herbert seed compiles the
result. This is explicit source composition, not a new import/module system or
another language. Names use prefixes because the current function namespace is
flat. The fixed `make first-steps`, `make maze`, `make notes` and `make scope`
targets report locations in the combined source kept in their build directories.
The developer [`make program` workflow](../docs/BUILDING.md) maps checked compiler rejections
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
  drags and releases, and scroll-wheel notches with a tick count, to the same
  ordered queue as key presses.
- `x11_clipboard.herb`: the desktop clipboard for that window, opt-in. It takes
  CLIPBOARD and answers other applications' requests (UTF8_STRING and
  text/plain;charset=utf-8, with TARGETS and TIMESTAMP), and asks the current owner
  for UTF-8 text with a bounded wait. Incremental transfers are refused, which
  bounds a paste to 65,504 bytes. Taking the clipboard waits for nothing;
  `x11_clip_owned` then asks the server, which silently ignores a claim older than
  the clipboard's last change, and is true only once the server names this window.
  If 256 keys queue first or two seconds pass, it returns false without knowing:
  the window goes on answering for the clipboard as before until the server's
  answer is read and settles it (unless the window has taken the clipboard again
  since), and the paste asks the clipboard's owner as any paste does. When that
  owner is this window, it answers its own request only once the paste has stopped
  waiting, so that paste gets no answer in time. Each paste asks for the
  text in the next of eight properties, emptied first; only an answer carrying
  that paste's time and property (or none, a refusal) counts. Until the server
  has passed this window's answers to other windows, BadWindow on ChangeProperty
  or SendEvent and BadAtom or BadMatch on ChangeProperty are ignored for every
  request sent in that span, which includes an application's own ChangeProperty
  or SendEvent there (Notes sends none that can fail); any other X11 error still
  stops the program. Call `x11_enable_clipboard` at startup and `x11_serve` after
  each `x11_events`.
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
  changes are refused, with one exception a caller asks for: `file_recheck(f)`,
  run before a save, reads the document's status again through the opened
  directory, puts its current permission bits in `f.state.mode` (whenever that
  stat works, also before a refusal), and adopts a change of the permission bits
  alone, with the change time that goes with it, so the save keeps the new bits.
  A change time that moved with the bits as recorded (a permission changed and
  changed back) is still refused. It reads nothing for a document not yet on
  disk, or after a save whose check after the rename failed (the baseline
  unconfirmed): there `file_save`'s own recovery checks the file against what it
  published, and a permission changed since is refused. A caller goes on to
  `file_save` only after 0 or 116 (which `file_save` refuses itself); any other
  result, a refusal `file_save` would give or an error of the stat itself, ends
  that attempt with that result, whatever permission bits were recorded. Notes
  refuses a file whose owner write bit is off only after 0 or 116; any other
  result keeps its own refusal there too.
  The limit: an outside edit that keeps the size
  and the modification time and comes with a permission change is not seen, nor
  are extended attributes set with one, and the save replaces them.
  Post-publication sync or verification failure is reported distinctly.
  An exclusive sibling rescue copy can preserve edits without replacing the original.
  The [Notes guide](../examples/notes.md) gives file and metadata limitations.
  A handle is a `File` record: `f.state` is a reference record (directory
  descriptor, last status, counts, mode), `f.bytes` holds the loaded bytes and
  `f.path` the NUL-terminated path; the stat buffers keep the kernel's layout.
  `file_new(capacity)` allocates a handle's storage once and `file_load(f, path,
  count)` loads a document into it, again and again, without allocating;
  `file_open(path, capacity)` does both from a path string. `file_load`
  changes the handle only once the file is one it will read, or missing (a new
  document): it checks the path (22, then 36 for a leaf over 255 bytes, so a
  path of 4096 bytes or more is 22 whatever its leaf), opens the folder, and
  stats the leaf through that folder first. A load
  refused there (a bad path, a leaf over 255 bytes, a folder missing,
  unopenable, or readable but not searchable, a symlink, not a regular file, a
  second link, another owner) leaves the handle exactly as it was, still on its
  document, and only `file_status(f)` says the refusal; only its scratch (the
  temp-name and stat buffers) was written. After that the handle takes the new
  folder and path, its old document gone, and only a refusal while the file is
  read is left (it cannot be opened or read, too large, changed while read):
  that leaves the handle marked existing, the bytes read so far counted
  (capacity + 1 when too large). Use the handle only after a result of 0:
  nothing marks such a refusal, and a save through it is checked as any save
  is (refused with 116 after a file that could not be opened, whose baseline
  is still the old document's; after a file refused as too large it replaces
  that file). `file_scan(f, scan,
  prefix)` counts the folders in the handle's folder whose names begin with
  `prefix` and keeps the newest by modification time (`file_scan_name(scan)`),
  listing it with getdents64 into storage that `file_scan_new()` allocates
  once; a symlink or a plain file wearing the name is skipped, and nothing
  inside a folder is read. `file_load_inside(g, f, folder, name)` loads one
  file inside one such folder into another handle, through descriptors, never
  following a symlink at either name, and keeps that handle as it was on the
  same refusals as `file_load`. Notes uses the two at open to say that
  session copies sit beside the document.
- `../examples/first_steps.herb`: the application's position, controls and scene.

The compiler has no game/window-specific operation. Seven hosted-only primitives
provide general reusable memory and the Linux x86-64 boundary:

| Primitive | Contract |
| --- | --- |
| `buffer_length(b)` | Current logical byte count, with no copy/allocation. |
| `buffer_get(b, i)` | Byte at `i`; fails with a located bounds diagnostic outside the logical length. |
| `buffer_set(b, i, byte)` | Replace an existing byte; validates index and 0..255 value, returns the byte; does not grow or allocate. Aliases see the change. |
| `buffer_copy(dst, at, src, from, n)` | Move `n` bytes from `src[from..)` to `dst[at..)`, returning `n`; both spans are checked against the initialized lengths before any byte moves (destination first; a located bounds diagnostic names the first position outside the buffer); overlap-safe in both directions; does not grow or allocate. |
| `buffer_fill(b, n, v)` | Append `n` copies of the byte `v` (what `n` appends would leave), returning `n`; the value is checked first (0..255, the located append diagnostic); one allocation sized to the need when the capacity is exceeded, so a fresh buffer filled once takes exactly its size. |
| `buffer_address(b)` | **Unsafe borrowed address** of its backing storage. Appending can relocate it; reacquire after growth. An empty buffer gives no permission to dereference. |
| `linux_syscall6(n, a1, a2, a3, a4, a5, a6)` | **Unsafe** raw Linux/x86-64 system call, all arguments and result are unsigned 64-bit integers. Unused arguments are normally zero. |

All seven names are reserved builtin function names. They are value expressions;
`do buffer_set(b, i, v)` discards the result, as `do` does for any call. They
are refused by the specialized kernel/module targets.
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
and environment helpers allocate at startup. `linux_copy` moves its span with
`buffer_copy`, so overlapping ranges are safe in either direction.

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
