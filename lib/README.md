# Herbert application support

These are Herbert source units, with no `main`. The Makefile concatenates the
selected units before their application, then the Herbert seed compiles the
result. This is explicit source composition, not a new import/module system or
another language. Names use prefixes because the current function namespace is
flat. Diagnostic lines refer to the combined source kept in the build directory.

- `linux.herb`: fixed byte buffers and endian fields; bounded file/environment
  reading; hostname; monotonic clock; polling; complete socket transfers with
  partial-transfer, EINTR, EOF, broken-peer and deadline handling.
- `x11.herb`: local display/authentication, a fixed-size window, server pixmap,
  keyboard mapping and key/focus/close events, rectangle/ellipse requests and
  presentation. X11 itself remains an external desktop service. Its supported
  profile and limitations are documented in the first-steps guide.
- `pixel_text.herb`: original 5×7 bitmap letter shapes and rectangle placement.
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
