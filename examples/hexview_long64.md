# View a file on Herbert's own runtime

[`hexview_long64.herb`](hexview_long64.herb) reads a boot-supplied file and
renders its bytes as lowercase hexadecimal, sixteen bytes per row. Both the
reader and the rendering run in the source-compiled long64 guest.

On Linux/x86-64 with Python 3 and `qemu-system-x86_64` available:

```sh
make long64-hexview
printf 'Herbert\n' > /tmp/herbert-example.bin
python3 tools/hexview_long64.py /tmp/herbert-example.bin
# 48 65 72 62 65 72 74 0a
```

`QEMU_PREFIX=/opt/qemu-10.2.1` selects the pinned local emulator;
`--qemu PATH` takes precedence. The default is software emulation.
`--accel kvm` requires usable KVM. The existing committed compiler builds the
image; no foreign compiler is used.

The input must be a regular file. The adapter copies its actual bytes into a
private temporary directory and asks QEMU's Multiboot loader to supply that
copy as one module. It supplies no serial input and performs no hexadecimal
conversion. The guest consumes the file, emits its text on COM1, and exits.
Only after successful guest completion does the adapter copy the output to
stdout. Failed boot input, failed guest completion or a timeout publishes no
viewer output. A valid empty file succeeds and produces no text.

`--timeout SECONDS` bounds the complete emulator run, with a default of 60
seconds. Large files take longer to render; serial output and the deliberately
small long64 arithmetic subset limit throughput. Input must fit the 64 MiB
appliance after the image, guards, relocated stack and loader metadata. The
guest reads module bytes in place, so input can exceed the runtime's separate
2 MiB buffer. The viewer uses no growing heap or call stack.

`--evidence NEW_DIRECTORY` retains the actual input copy, boot image, serial
output, debugcon, QEMU stderr and `run.json`. Successful default runs delete
their temporary directory; failed runs preserve it and report its location.
These captures contain the input and its rendered contents. Host disk use
grows with input/output; copying uses bounded host memory. Changing a source
file during copying is not an atomic snapshot operation—the retained hash
identifies exactly the bytes actually copied.

## The input contract

`boot_read()` takes no arguments and returns one integer: a byte from 0 through
255, or 256 at EOF. Further reads at EOF keep returning 256. Ordinary calls and
tail calls share the same input position. The primitive is available in the
`multiboot32-long64` target, including a single-function program that uses it.
Hosted and earlier i386 targets retain their own input contracts.
`boot_read` is reserved as a builtin name in every target; a user function with
that name is rejected, as with `stdin_read`.

The provider accepts exactly one raw Multiboot module. It validates the boot
magic, metadata spans, module count and payload extent before entering main.
This path reserves the entire image-through-stack extent in its ELF header;
the module must lie at or above that reservation and within 64 MiB. An empty
descriptor `[0,0]`, as supplied by GRUB, is also valid and is never dereferenced.
Bad input emits `BI\n` followed by grade-1 completion on debugcon. Success has
only the normal `de00ad` completion and QEMU exit 99.

For a GRUB boot, preserve arbitrary input bytes with:

```text
menuentry "hexview" {
    multiboot /boot/kernel.elf
    module --nounzip /boot/input.bin
    boot
}
```

The `--nounzip` option matters: a compressed file must remain the bytes the
viewer was asked to inspect. An empty file and an absent module are different;
only the former is valid input.

This is a read-only input interface over boot-provided memory. It supplies
neither a filesystem nor a general memory allocator, and the privileged raw
buffer operations do not enforce hardware immutability or process isolation.
The fixed RAM/placement contract is not general memory-map discovery. Earlier
programs that do not use `boot_read()` retain their emitted bytes and layout.

## Verification

The folio link67 gates exercise the actual provider and viewer with binary
files, stable EOF, call continuity, an input larger than the fixed buffer,
and deliberate bad boot metadata. Their reservation mutation must be rejected.
They use QEMU and Bochs, plus KVM when available. The existing kernel CI runs
them with its pinned emulators and retains actual attempts; see
[`VERIFYING.md`](../VERIFYING.md) for commands and scope.
