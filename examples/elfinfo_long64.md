# Inspect executables on Herbert's own runtime

`elfinfo_long64.herb` reads an ELF executable through boot-file input and reports
its entry point and program headers. Parsing, bounds checks and hexadecimal
formatting run in the Herbert guest. The shared host adapter supplies the file
and publishes the result after successful guest completion.

On Linux/x86-64 with Python 3 and QEMU available:

```sh
make long64-elfinfo
python3 tools/elfinfo_long64.py bootstrap/seed/gen1.seed
python3 tools/elfinfo_long64.py build/elfinfo-long64.elf
```

The first command inspects the compiler's ELF64 executable. The second lets the
inspector inspect its own ELF32 boot image. The latter envelope describes the
32-bit loader entry; its code then enters 64-bit mode. Both are built through
the same committed Herbert compiler; this application adds no compiler backend
or kernel interface.

Output begins with `ELF64 x86-64` or `ELF32 i386`, an `ENTRY` line with the
16-digit hexadecimal entry address, and a `PH` line with the four-digit
hexadecimal header count.
Each following line reports one program header in file order:

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

Fields are separated by one space. Leading zeros and all 64 address bits are
preserved, including high-bit values. ELF32 fields are zero-extended to the same
column widths. Section headers are not needed for this report.

Both supported profiles are little endian, version 1 and executable type
`ET_EXEC`: ELF64/x86-64 with a 64-byte ELF header and 56-byte program headers,
or ELF32/i386 with a 52-byte ELF header and 32-byte program headers.
The program table must follow the profile's ELF header. Counts from 1 through
65534 are supported; the section-based extended-count convention is not implemented.
Truncated headers, tables or load-file extents are refused, as is a loadable
segment whose file size exceeds its memory size. The guest scans through EOF
before success, including bytes after the program table. Host output remains
empty on refusal, even if the guest had already formatted some rows.

This is a header inspector. It does not validate executable instructions,
entry-point reachability, segment permissions/overlaps, alignment constraints
or section contents, and does not establish that an image can safely be loaded.
It leaves the compiler's existing byte pins and independent loader/provenance
checks in place.

The regular-file, fixed 64 MiB boot-appliance and timeout limits are shared with
the [hexadecimal viewer](hexview_long64.md). `--image`, `--qemu`, `--accel kvm`,
`--timeout` and `--evidence NEW_DIRECTORY` have the same meanings. Successful
default runs remove their temporary captures; failures retain the input, image
and raw guest streams and report their location. The guest uses a fixed header
buffer and bounded call depth; host captures grow with input and output.

`make check-long64-elfinfo` checks the actual compiler executable, the inspector's
own image, multi-header fixtures with high-bit fields in both formats, and a
focused malformed input panel. It also uses KVM and Bochs when available. CI requires Bochs for its
application check and keeps its raw evidence in the existing kernel-job artifact.
This is application qualification; the kernel gate count is unchanged.
