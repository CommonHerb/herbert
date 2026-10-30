# The OS work's three tools

Herbert's operating-system work is paused, not dropped. Part of it is a source-authored long64 runtime: the committed
compiler's `-- emit: multiboot32-long64` route turns a Herbert program into a small boot image with boot, device
input/output, tail calls and guarded indexed memory ([the language guide](LANGUAGE.md), §8). Its language surface is
narrower than hosted Herbert, and it is not a complete OS or a general memory-safe runtime. Three small tools run on it
under QEMU: a word counter, a hex viewer and an ELF header inspector. In each, the Herbert guest does the work; a
Python adapter in `tools/` only carries bytes in and out, and publishes the guest's result only after the guest has
completed successfully. None of them adds a compiler backend, a kernel interface or a foreign compiler.

## Building and running

On Linux/x86-64 with Python 3 and `qemu-system-x86_64`:

```sh
make long64-wordcount long64-hexview long64-elfinfo

printf 'one two\n' | python3 tools/wordcount_long64.py
# (1, 2, 8)
python3 tools/wordcount_long64.py < README.md

printf 'Herbert\n' > /tmp/herbert-example.bin
python3 tools/hexview_long64.py /tmp/herbert-example.bin
# 48 65 72 62 65 72 74 0a

python3 tools/elfinfo_long64.py bootstrap/seed/gen1.seed
python3 tools/elfinfo_long64.py build/elfinfo-long64.elf
```

Each build checks the seed's checksum and writes `build/<name>-long64.elf` with the committed compiler; no reseed or
foreign compiler is needed. The three adapters share these options:

- `--image PATH`: another boot image (default `build/<name>-long64.elf`).
- `--qemu PATH`: the emulator to use. Otherwise a nonempty `QEMU_PREFIX` selects one (it must be absolute and contain
  `bin/qemu-system-x86_64`, for example `/opt/qemu-10.2.1` for the pinned local build), and otherwise `PATH`.
- `--accel kvm`: requires usable KVM; the default is QEMU software emulation.
- `--timeout SECONDS`: for the word counter, each guest response and the emulator's completion (not the whole input
  stream or a blocking host stdin read); for the viewer and the inspector, the complete emulator run, 60 s by default.
- `--evidence NEW_DIRECTORY`: keep the run's files whether it succeeds or fails: the boot image, the input copy or the
  sent and received bytes, serial output, debugcon, QEMU stderr and `run.json`. These hold the input and its result;
  treat them like the input itself. Without this option a successful run deletes its temporary directory, and a failed
  run keeps it (input, image and raw guest streams) and reports where.

## The word counter

[`wordcount_long64.herb`](../examples/wordcount_long64.herb) counts lines, words and bytes inside the guest, using
boot, serial I/O, tail calls and guarded buffer primitives. Its rules match the
[hosted counter](../examples/wordcount.md), which remains the simpler everyday tool: lines count LF bytes; words are
runs separated by ASCII space, tab, LF, vertical tab, form feed or CR; every other byte, NUL and non-ASCII included, is
word content; empty input gives `(0, 0, 0)`.

The adapter reads unbuffered stdin, so pipe fragments are forwarded without waiting to fill a chunk, and sends at most
255 bytes at a time. It does not count. It prints the guest's answer only after the complete result, the closed serial
connection, the success frame and QEMU's success exit have all arrived. Input read failures, lost transport, invalid
records and failed guest completion give a nonzero exit and no count. Temporarily unavailable nonblocking input is an
error, even after a valid prefix; it is never treated as EOF. The host records wire traffic on disk while running, so
its scratch storage grows with input.

The guest keeps three 20-digit decimal counters in 60 buffer slots (480 bytes); its memory and call depth do not grow
with input length. The runtime still reserves its fixed guarded buffer and stack, so this is not a 480-byte total. Each
counter holds up to 10^20−1; overflow rejects the stream without a successful result. Decimal digits avoid adding
division, formatting or new language primitives just for this program.

**Serial contract.** After initialization the guest sends `HWC1\n`. A host chunk is one length byte (1–255) followed
by exactly that many payload bytes; length zero ends the stream. Every wire byte receives ACK (`0x06`), and the host
waits for that ACK before sending another byte; payload ACK follows the counter updates. The final zero header
receives ACK, then `R(lines, words, bytes)\n`. Capacity failure sends NAK (`0x15`) followed by `1\n` instead of the
expected ACK and emits no result. UART silence or disconnection is never EOF. One byte in flight keeps this compatible
with the polling UART path, and also limits throughput: this is an integration example, not a serial benchmark or a
filesystem input API. Physical UART errors, filesystem EOF and process isolation are not handled.

## The hex viewer

[`hexview_long64.herb`](../examples/hexview_long64.herb) reads one boot-supplied file and renders its bytes as
lowercase hexadecimal, sixteen bytes per row; reading and rendering both run in the guest. The input must be a regular
file. The adapter copies its bytes into a private temporary directory and has QEMU's Multiboot loader supply that copy
as one module. It sends no serial input and does no conversion: the guest consumes the file, writes its text on COM1
and exits, and only after successful guest completion does the adapter copy the output to stdout. Failed boot input,
failed guest completion or a timeout publishes nothing. A valid empty file succeeds and produces no text.

Large files take longer: serial output and the deliberately small long64 arithmetic subset limit throughput. The guest
reads the module in place, so input can exceed the runtime's 2 MiB buffer; the viewer uses no growing heap or call
stack. Host disk use grows with input and output; copying uses bounded host memory. Changing the file while it is
copied is not an atomic snapshot; the retained hash identifies exactly the bytes copied.

## The ELF inspector

[`elfinfo_long64.herb`](../examples/elfinfo_long64.herb) reads an ELF executable through the same boot-file input and
reports its entry point and program headers; parsing, bounds checks and hexadecimal formatting run in the guest. The
first command above inspects the compiler's ELF64 executable; the second has the inspector inspect its own ELF32 boot
image, whose envelope describes the 32-bit loader entry (its code then enters 64-bit mode).

Output begins with `ELF64 x86-64` or `ELF32 i386`, an `ENTRY` line with the 16-digit hexadecimal entry address, and a
`PH` line with the four-digit hexadecimal header count. Each following line reports one program header in file order:

| Field | Hex digits | Meaning |
|---|---:|---|
| `p_type` | 8 | Header kind; `00000001` is a loadable segment |
| `p_flags` | 8 | Segment flags; read/write/execute use masks 4/2/1 |
| `p_offset` | 16 | Byte offset in the input file |
| `p_vaddr` | 16 | Virtual address |
| `p_paddr` | 16 | Physical address field |
| `p_filesz` | 16 | File-backed byte count |
| `p_memsz` | 16 | In-memory byte count |
| `p_align` | 16 | Alignment field |

Fields are separated by one space. Leading zeros and all 64 address bits are kept, including high-bit values; ELF32
fields are zero-extended to the same column widths. Section headers are not needed for this report.

Both supported profiles are little endian, version 1 and executable type `ET_EXEC`: ELF64/x86-64 with a 64-byte ELF
header and 56-byte program headers, or ELF32/i386 with a 52-byte ELF header and 32-byte program headers. The program
table must follow the profile's ELF header. Counts from 1 through 65534 are supported; the section-based
extended-count convention is not implemented. Truncated headers, tables or load-file extents are refused, as is a
loadable segment whose file size exceeds its memory size. The guest scans through EOF before success, including bytes
after the program table. Output stays empty on refusal, even if the guest had already formatted some rows. The guest
uses a fixed header buffer and bounded call depth; host captures grow with input and output.

This is a header inspector. It does not validate instructions, entry-point reachability, segment permissions or
overlaps, alignment or section contents, and does not establish that an image can safely be loaded.

## Boot-supplied input

The language side, `boot_read()`, is in [the language guide](LANGUAGE.md), §8. On the boot side, the provider accepts
exactly one raw Multiboot module. It validates the boot magic, metadata spans, module count and ordered payload bounds
before `main`. Missing, multiple or malformed input emits `BI\n` on debugcon followed by grade-1 completion; success
has only the normal `de00ad` completion and QEMU exit 99. An empty module is valid, including GRUB's exact `[0,0]`
descriptor sentinel, which is never dereferenced. An empty file and an absent module are different: only the former is
valid input.

Only this input path reserves the complete image, guards and relocated stack (through `esp_val`) in the ELF header's
`p_memsz`. A non-sentinel module must start at or above that reservation and end at or below 64 MiB, so input must fit
the 64 MiB appliance after the image, guards, stack and loader metadata. Reads consume module bytes in place,
independently of the fixed 2 MiB buffer. Programs that do not use `boot_read()` keep their emitted bytes and layout.

A GRUB boot must preserve the input bytes with `--nounzip`, so a compressed file stays the bytes that were asked for:

```text
menuentry "hexview" {
    multiboot /boot/kernel.elf
    module --nounzip /boot/input.bin
    boot
}
```

This is a fixed, read-only input interface over boot-provided memory. It is not a filesystem, a memory allocator or
general memory-map discovery, and the privileged raw buffer operations enforce neither hardware immutability nor
process isolation.

## Checks

- `make check-long64-wordcount` builds the counter and checks the real image under QEMU: literal expected counts,
  sustained input, two faulty source variants, a near-capacity counter variant, a real nonblocking pipe (a valid prefix
  then unavailable input must give no result) and truncated results from a transport fixture. For the extra local KVM
  case with kept evidence:

  ```sh
  python3 bootstrap/tests/check_wordcount_long64.py \
    --image build/wordcount-long64.elf --kvm --evidence /tmp/wordcount-check
  ```
- `make check-long64-elfinfo` builds the inspector and checks the real compiler and inspector images, multi-header
  fixtures with high-bit fields in both formats, and a malformed-input panel. It also uses KVM and Bochs when available.
- Link 67's gate and mutation proof (`KERNEL_VERIFY_LO=67 KERNEL_VERIFY_HI=67 make kernel-verify`) exercise the
  provider and the viewer with QEMU and Bochs, plus KVM when available: binary files, stable EOF, call continuity,
  input larger than the fixed buffer, the ELF stack reservation and deliberate bad boot metadata (GDB changes boot
  registers and metadata at the real kernel entry, with no hooks in the production image). The reservation mutation
  must be rejected. GRUB boots use `module --nounzip`; Bochs exercises GRUB's empty-file sentinel; QEMU checks
  missing input.
- In CI, the kernel workflow's 60–61 job runs both application checks once and keeps their evidence in that job's
  artifact. The ELF check requires Bochs there; the counter's CI checks use QEMU software emulation and claim no
  Bochs run. These application checks add no kernel gate and change no compiler, seed or golden bytes.

How the kernel suite runs is in [VERIFYING.md](../VERIFYING.md).
