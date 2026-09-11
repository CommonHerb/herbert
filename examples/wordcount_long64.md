# Count a stream on Herbert's own runtime

[`wordcount_long64.herb`](wordcount_long64.herb) counts lines, words and bytes
inside a source-compiled long64 guest. It uses the committed Herbert compiler
and existing boot, serial I/O, tail calls and guarded buffer primitives.

On Linux/x86-64, with Python 3 and `qemu-system-x86_64` available:

```sh
make long64-wordcount
printf 'one two\n' | python3 tools/wordcount_long64.py
# (1, 2, 8)

python3 tools/wordcount_long64.py < README.md
```

The build verifies the seed checksum and writes `build/wordcount-long64.elf`.
No reseed or foreign compiler is needed. To select the local pinned emulator,
set `QEMU_PREFIX=/opt/qemu-10.2.1`; a nonempty prefix must be absolute and must
contain `bin/qemu-system-x86_64`. An explicit `--qemu PATH` takes precedence.
`--accel kvm` requires usable KVM; the default is QEMU software emulation.

Lines count LF bytes. Words are runs separated by ASCII space, tab, LF, vertical
tab, form feed or CR. All other byte values, including NUL and non-ASCII bytes,
are ordinary word contents. Empty input returns `(0, 0, 0)`. This matches the
[hosted counter](wordcount.md), which remains the simpler everyday utility.

The Python adapter reads at most 255 input bytes at a time and forwards them to
the guest. It does not calculate counts. It prints the guest's answer only
after the complete result, closed serial connection, success frame and QEMU
success exit have all arrived. Input read failures, lost transport, invalid
records and failed guest completion produce a nonzero exit and no count result.
`--timeout SECONDS` bounds each guest response and emulator completion, not
the whole input stream or a blocking host stdin read.

The guest keeps three 20-digit decimal counters in 60 buffer slots (480 bytes).
Its memory and call depth do not grow with input length. The existing runtime
still reserves its fixed guarded buffer and stack; this is not a 480-byte total
memory claim. Each counter can hold up to 10^20−1. Overflow rejects the stream
without publishing a successful result. Decimal digits avoid adding division,
formatting or new language primitives just for this program.

The host records wire traffic on disk while running, so its scratch storage
grows with input. Successful default runs remove it; failed runs retain it and
report its location. `--evidence NEW_DIRECTORY` retains both successful and
failed attempts, including the actual boot image, sent/received bytes, QEMU
stderr, debugcon and `run.json`. Treat these files like the input itself.

## Serial contract

After initialization the guest sends `HWC1\n`. A host chunk is one length byte
(1–255), followed by exactly that many payload bytes. Length zero explicitly
ends the stream. Every wire byte receives ACK (`0x06`); the host waits for that
ACK before sending another byte. Payload ACK follows the counter updates.
The final zero header receives ACK, then `R(lines, words, bytes)\n`.
Capacity failure sends NAK (`0x15`) followed by `1\n` instead of the expected
ACK and emits no result. UART silence or disconnection is never EOF.

One byte in flight keeps this compatible with the existing polling UART path.
It also limits throughput. This is a useful integration example, not a serial
performance benchmark or a new filesystem input API. Physical UART errors,
filesystem EOF, process isolation and compiling Herbert on its own OS remain
separate work.

## Verification

`make check-long64-wordcount` exercises the actual compiled image under QEMU,
using literal expected counts, sustained input, two faulty source variants and
a near-capacity counter variant. A small transport fixture checks truncated
results. For the additional local KVM case and retained evidence:

```sh
python3 bootstrap/tests/check_wordcount_long64.py \
  --image build/wordcount-long64.elf --kvm --evidence /tmp/wordcount-check
```

This application check runs once in the existing kernel CI workflow. It does
not add a kernel proof link or change any compiler, seed or golden bytes.
