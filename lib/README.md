# Herbert application support

These are Herbert source units, with no `main`. The Makefile concatenates the
selected units before their application, then the Herbert seed compiles the
result. This is explicit source composition, not a new import/module system or
another language. Names use prefixes because the current function namespace is
flat. The fixed `make first-steps`, `make maze`, `make notes`, `make scope`, `make scope-helper`
and `make knock` targets report locations in the combined source kept in their build directories.
The developer [`make program` workflow](../docs/BUILDING.md) maps checked compiler rejections
back to original files and lines. Runtime bounds faults still refer to combined
source; the retained source map identifies its original units.

- `linux.herb`: fixed byte buffers and endian fields; bounded file/environment
  reading; startup command-line arguments and their count; unsigned decimal formatting; hostname; monotonic clock;
  polling one descriptor or several at once; complete socket transfers with
  partial-transfer, EINTR, EOF, broken-peer and deadline handling; and the system calls and flags the programs here
  use, by name (`linux_open`, `linux_read`, `linux_statfs`, `linux_socket`, `linux_o_cloexec()`, ...), so no
  program passes Linux a bare number. Its functions are tabled [below](#linuxherb).
- `text.herb`: text in and out, [tabled below](#textherb): whether a byte is a digit or a blank, a whole number
  read from a span of a buffer or a string with the 2^64 check (zeros in front allowed, or refused), the next field
  of a line split on spaces and tabs, a span compared with a string, and text, whole numbers, numbers padded with
  zeros and tenths written into a fixed buffer at an offset, each writer returning the offset after it. None of
  these allocates; the four growing writers at its end (`text_add`, ...) do, for output made once. Requires
  `linux.herb`. Used by knock, Scope and Scope's helper, and by `net.herb` and `figures.herb`, which need it.
- `net.herb`: strict dotted IPv4, port and time-limit parsing, and a TCP knock:
  answered, refused, no answer, unreachable or a named error, within a time
  limit, never sending a byte, the socket closed on every path. A `Net` record
  (`net_new()`, once) holds the state and every buffer a knock uses, so a knock
  allocates nothing. Addresses only, no names. `net_knock` waits for the
  answer; `net_start`, `net_check`, `net_left` and `net_stop` knock without
  waiting, for a program that must keep going meanwhile. `net_start_reading`
  knocks without waiting too and, once the connection is taken, reads what the
  computer sends into the Net's fixed 256-byte reply buffer, never waiting,
  until it closes the connection, 256 bytes have come or the time limit
  passes. `net_sockaddr` fills a sockaddr_in and `net_put_address` writes an
  address in the dotted form `net_ipv4` reads. Requires `text.herb`. Used by
  knock, Scope and Scope's helper.
- `figures.herb`: a computer's figures, [tabled below](#figuresherb): its
  processor and memory counts from `/proc/stat` and `/proc/meminfo`, and the
  first line of a name file, read a byte at a time through one fixed 4096-byte
  chunk, only the first 1 MiB of a file looked at, with a `FiguresScan` record
  (`figures_scan_new()`, once) so reading again allocates nothing; how full the
  disk holding a path is (`statfs`, worked out as `df` does, in a `FiguresDisk`);
  the drive's and the processor's temperatures from Linux's hwmon files, found
  once at startup (`FiguresHeat`), with the drive's limits and colour bands; and
  the one line Scope's helper sends them in (`herbert-scope 2 CPU MEMORY DISK
  DRIVE`, a part `unavailable` when it cannot be read, the drive `none` with no
  drive sensor; Scope still reads version 1, the first two parts alone):
  `figures_reply_put` writes it, `figures_reply_read` reads either version
  strictly. Requires `text.herb`. Used by Scope and Scope's helper, so the two
  work out the figures with the same code.
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

## Function tables

Results in parentheses are tuples, read with `.0`, `.1`, .... "-errno" is Linux's raw error, which `linux_error`
tells from a result; Herbert integers are unsigned, so never test it with `< 0`. A *span* is `b` from `at` up to
`stop`, `stop` not included. A *path* is a NUL-terminated buffer (`linux_cstring(s)` makes one). Functions marked
*allocates* make new storage each call: call them at startup or in output made once, never in a loop that runs for
ever.

### linux.herb

| Function | Gives |
| --- | --- |
| `linux_error(r)` | true when `r` is a raw -errno (`r >= 0 - 4095`) |
| `linux_die(message)` | writes `message` (a string; include the newline) to stderr and exits 1; never returns |
| `linux_buffer(size)` | a buffer of `size` zero bytes; *allocates* |
| `linux_range(b, offset, size)` | true when `size` bytes from `offset` lie inside `b` |
| `linux_require_range(b, offset, size)` | 0, or stops the program with `linux: byte-buffer range is outside its allocation` |
| `linux_u16(b, o)`, `linux_u32(b, o)`, `linux_u64(b, o)` | the little-endian field at `o` |
| `linux_put16(b, o, v)`, `linux_put32(b, o, v)`, `linux_put64(b, o, v)` | 0; stores the low bits of `v` at `o`, little-endian |
| `linux_copy(dst, offset, src, from, n)` | 0; moves `n` bytes, overlap-safe |
| `linux_text(dst, offset, s)` | 0; the bytes of string `s` into `dst` at `offset` (`text_put` also gives the offset after) |
| `linux_cstring(s)` | a path: `s` and a NUL; *allocates* |
| `linux_decimal(b, offset, n)` | the offset after `n` written in decimal (the same as `text_put_whole`) |
| `linux_nul_end(b, from, limit)` | the first NUL at or after `from`, or `limit` |
| `linux_read_file(path, cap)` | (status, buffer, count): the whole file at `path`, a string, of at most `cap` bytes; status 0, -errno, or -27 when larger; *allocates* |
| `linux_environment()` | the environment as a buffer, read once; *allocates* |
| `linux_env(env, name)` | the value of `name` in `env`, `""` when absent or empty; *allocates* |
| `linux_hostname()` | the host name; *allocates* |
| `linux_arguments()` | (buffer, size): the command line, read once; *allocates* |
| `linux_argument(args, k)` | argument `k` (0 is the program) as a string, `""` when missing or empty; *allocates* |
| `linux_argument_count(args)` | how many arguments there are, the program included (1 when none was given) |
| `linux_clock_ms(clockbuf)`, `linux_clock_us(clockbuf)` | milliseconds, microseconds, on the monotonic clock (`clockbuf` at least 16 bytes), or -errno |
| `linux_poll(fd, pollbuf, events, timeout)` | the events ready on `fd`, 0 after `timeout` ms, or -errno (`pollbuf` 8 bytes) |
| `linux_poll_entry(pollbuf, i, fd, events)`, `linux_poll_many(pollbuf, count, timeout)` | entry `i` written, `i + 1`; then how many of `count` entries are ready, 0, or -errno |
| `linux_send_all(fd, b, offset, count, pollbuf, clockbuf)`, `linux_read_exact(...)` | 0 once all `count` bytes moved on a connected socket within 5 s, or -errno |
| `linux_o_nonblock()`, `linux_o_cloexec()` | open's flags (reading is 0, so a file opened to read needs only these, or-ed with `\|`) |
| `linux_af_inet()`, `linux_sock_stream()`, `linux_sock_nonblock()`, `linux_sock_cloexec()`, `linux_ipproto_tcp()` | socket's numbers |
| `linux_sol_socket()`, `linux_so_reuseaddr()`, `linux_so_error()` | socket option level and names |
| `linux_msg_dontwait()`, `linux_msg_nosignal()` | send and receive flags |
| `linux_s_ifmt()`, `linux_s_ifreg()` | a stat's file-type bits and the regular file's value |
| `linux_open(path, flags, mode)` | open(2): a descriptor, or -errno |
| `linux_read(fd, b, at, count)` | read(2) into `b` at `at`: the count read, 0 at the end, or -errno |
| `linux_write(fd, b, at, count)` | write(2) from `b` at `at`: the count written, or -errno (`linux_write(1, b, 0, n)` prints `n` bytes) |
| `linux_close(fd)` | close(2): 0 or -errno |
| `linux_fstat(fd, answer)` | fstat(2) into `answer` (144 bytes; st_mode is `linux_u32(answer, 24)`): 0 or -errno |
| `linux_statfs(path, answer)` | statfs(2) into `answer` (120 bytes): 0 or -errno |
| `linux_socket(domain, kind, protocol)`, `linux_connect(fd, address, size)`, `linux_bind(fd, address, size)`, `linux_listen(fd, backlog)` | socket(2), connect(2), bind(2), listen(2): a descriptor or 0, or -errno |
| `linux_accept(fd, address, size, flags)` | accept4(2): a descriptor, or -errno; `size` a 4-byte buffer set to the room in `address` first |
| `linux_send(fd, b, at, count, flags)`, `linux_receive(fd, b, at, count, flags)` | sendto(2), recvfrom(2) with no address: the count, or -errno |
| `linux_set_option(fd, level, name, b, value)`, `linux_get_option(fd, level, name, b)` | setsockopt(2), getsockopt(2) of a 32-bit option through `b` (4, 8 bytes): 0 or -errno; the value read is `linux_u32(b, 0)` |
| `linux_sleep(timespec)` | nanosleep(2) for the seconds and nanoseconds in `timespec` (16 bytes): 0 or -errno |

`linux_transfer`, `linux_read_file_loop`, `linux_name_matches` and `linux_string_loop` are its internal steps.

### text.herb

| Function | Gives |
| --- | --- |
| `text_digit(byte)` | true for `0` to `9` |
| `text_blank(byte)` | true for a space or a tab |
| `text_fits(value, digit)` | true when `value * 10 + digit` is below 2^64 |
| `text_skip(b, at, stop)` | the first byte from `at` that is not a blank, or `stop` |
| `text_field(b, at, stop)` | (start, after): the next field, blanks skipped; (stop, stop) when none is left |
| `text_whole(b, at, stop)` | (ok, value, next): the digits from `at`, zeros in front allowed; ok false with no digit or past 2^64 - 1; `next == stop` when the span is all number |
| `text_whole_strict(b, at, stop)` | the same, refusing a zero in front of another digit (`07`) |
| `text_string_whole(s, at, stop)`, `text_string_whole_strict(s, at, stop)` | the same two for a string, such as an argument |
| `text_starts(b, at, stop, s)` | true when the bytes of string `s` come at `at` |
| `text_is(b, at, stop, s)` | true when the span is exactly `s` |
| `text_put(b, at, s)` | the offset after string `s`, written at `at` |
| `text_put_whole(b, at, n)` | the offset after `n` in decimal |
| `text_put_padded(b, at, n, width)` | the offset after `n` with zeros in front to `width` digits (`07`) |
| `text_put_tenths(b, at, n, unit)` | the offset after `n / unit` to the nearest tenth, `12.3` (`unit` 1 to 2^60) |
| `text_add(out, s)`, `text_add_span(out, b, from, count)`, `text_add_whole(out, n)` | 0; `s`, `count` bytes of `b`, or `n` in decimal added to the end of `out`; *allocates* as `out` grows |
| `text_string(b, from, stop)` | the bytes from `from` to `stop` as a string; *allocates* |

A line is built by passing each writer's result on, then printed without allocating:

```herbert
func main():
    let line = linux_buffer(64)
    let at = text_put(line, 0, "up ")
    at = text_put_whole(line, at, 2)
    at = text_put(line, at, " days, 6:")
    at = text_put_padded(line, at, 5, 2)
    at = text_put(line, at, "\n")
    do linux_write(1, line, 0, at)
    return 0
end
```

prints `up 2 days, 6:05` and then `main`'s `0` (built with `SUPPORT="linux text"`).

### figures.herb

Readings allocate nothing once their record is made; the records' constructors and `figures_heat_find` allocate,
at startup. Temperatures are in millidegrees Celsius, as Linux gives them.

| Function | Gives |
| --- | --- |
| `figures_scan_new()` | a `FiguresScan` for reading `/proc` files; *allocates* |
| `figures_read_stat(scan, path)` | (readable, total, busy) from a `/proc/stat` file: the first eight counters' sum, and it less idle and iowait; the eight counters stay in `scan.counts` |
| `figures_read_meminfo(scan, path)` | (usable, MemTotal, MemAvailable) in KiB from a `/proc/meminfo` file; a total of zero is unusable |
| `figures_read_name(scan, path)` | the length of the name file's first line, cut at 64 bytes, into `scan.name`; 0 when unreadable |
| `figures_percent(part, whole)` | `part / whole` as a whole percent, a half rounding up, exact for any 64-bit numbers (`whole` above 0, `part` not above it) |
| `figures_disk_new(path)` | a `FiguresDisk` for the disk holding `path` (`""` for none: statfs refuses it); *allocates* |
| `figures_statfs(disk)` | (asked, blocks, bfree, bavail, frsize) from statfs, f_bsize for an f_frsize of 0 |
| `figures_disk_figures(disk, ok, blocks, bfree, bavail, frsize)` | 0; sets `disk.state` (1 shown, 2 not), `used` and `avail` (blocks), `percent`, `size` and `free` (KiB), as `df` works them out |
| `figures_disk_read(disk)` | 0; the two above, again |
| `figures_disk_percent(used, avail)` | in use over in use and free (their sum below 2^64), 100 with neither |
| `figures_kib(n, f)` | (fits, KiB): `n` blocks of `f` bytes, rounded down, without forming `n * f` |
| `figures_read_small(path, b)` | (readable, count): the start of a file into `b`, opened without blocking |
| `figures_read_value(path, b)` | (plain, value): a file holding one whole number and at most one newline |
| `figures_hwmon_path(b, root, which, file)` | the offset of the NUL after `root/hwmonN/file`, written into `b` |
| `figures_hwmon_name(path, b)` | the length of a hwmon name file, less one newline; 0 when unreadable |
| `figures_heat_new()`, `figures_sensor_new()` | a `FiguresHeat` (drive, processor, a 32-byte line) with nothing found, and one `FiguresSensor`; *allocate* |
| `figures_heat_find(heat, root)` | 0; finds the first `nvme` and the first `k10temp` (else `coretemp`) in `root/hwmon0` to `hwmon63`, and the drive's `temp1_max` and `temp1_crit` (0 for none: missing, not plain, 0 or above 200000); *allocates* |
| `figures_sensor_found(sensor, root, which, kind)`, `figures_limit(path, b)` | its steps: a sensor found at `hwmonN` (kind 1 nvme, 2 k10temp, 3 coretemp); a limit read |
| `figures_sensor_read(sensor, b)`, `figures_heat_read(heat)` | 0; a sensor's `temp1_input` again (state 1 and `reading`, or 2 for n/a); both of them |
| `figures_degrees(milli)` | whole degrees, a half rounding up |
| `figures_shade(state, reading, warning)` | a drive's colour: 0 green, 1 amber within 10 °C under `warning`, 2 red at or above it, 3 grey when `state` is not 1; `warning` 0 is none (green) |
| `figures_reply_longest()` | 155: the longest version-2 line, its newline included |
| `figures_reply_put(b, cpu, memory, disk, drive)` | the length of the version-2 line written into `b` from 0, for two readings as `figures_read_stat` and `figures_read_meminfo` give them, a `FiguresDisk` and the drive's `FiguresSensor` |
| `figures_put_half(b, at, reading)`, `figures_put_drive(b, at, drive)` | its steps: a part, two numbers or `unavailable`; the drive's part |
| `figures_reply_new()` | a `FiguresReply` to read replies into; *allocates* |
| `figures_reply_read(r, b, n)` | true when the first `n` bytes of `b` are exactly a line of version 1 or 2, within its rules, and `r` then filled (`version`, `cpu`, `total`, `busy`, `memory`, `mem_total`, `mem_available`, `disk`, `used`, `free`, `drive` 0 none, 1 n/a, 2 `reading` and `limit`) |
| `figures_reply_half(b, at, stop)`, `figures_reply_space(b, at, stop)` | its steps: one part (well-formed, given, first, second, next); a space next |

The other `figures_` functions (`figures_stat_byte`, `figures_mem_byte`, `figures_feed`, `figures_read`, ...) are the
scanner's internal steps.
