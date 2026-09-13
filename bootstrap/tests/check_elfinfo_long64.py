#!/usr/bin/env python3
"""Check the Herbert ELF inspector with real images and bounded ELF fixtures."""

import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import hexview_long64 as driver
from check_boot_input import bochs_boot

EHDR = struct.Struct("<16sHHIQQQIHHHHHH")
PHDR = struct.Struct("<IIQQQQQQ")
EHDR32 = struct.Struct("<16sHHIIIIIHHHHHH")
PHDR32 = struct.Struct("<IIIIIIII")


def expected(data):
    """Interpret standard ELF field layouts independently of the guest's stream parser."""
    is32 = data[4] == 1
    header = (EHDR32 if is32 else EHDR).unpack_from(data)
    lines = ["ELF32 i386" if is32 else "ELF64 x86-64",
             f"ENTRY {header[4]:016x}", f"PH {header[10]:04x}"]
    for index in range(header[10]):
        fields = (PHDR32 if is32 else PHDR).unpack_from(data, header[5] + index * header[9])
        if is32:
            fields = (fields[0], fields[6], fields[1], fields[2], fields[3], fields[4], fields[5], fields[7])
        lines.append(" ".join(f"{value:0{8 if i < 2 else 16}x}" for i, value in enumerate(fields)))
    return ("\n".join(lines) + "\n").encode("ascii")


def fixture():
    """A non-default table offset, three headers, high-bit fields and a trailing load extent."""
    data = bytearray(400)
    ident = b"\x7fELF\x02\x01\x01" + bytes(9)
    EHDR.pack_into(data, 0, ident, 2, 62, 1, 0xFEDCBA9876543210,
                   160, 0, 0, 64, 56, 3, 0, 0, 0)
    PHDR.pack_into(data, 160, 1, 5, 384, 0x8000000000001000,
                   0xABCDEF0123456789, 16, 0x8000000000001000, 4096)
    # PT_NULL fields have no loading semantics, but their exact bits remain reportable.
    PHDR.pack_into(data, 216, 0, 0xA5A55A5A, 0xF000000000000123,
                   0x123456789ABCDEF0, 0xFFFFFFFFFFFFFFFF,
                   0x8000000000000001, 0x7FFFFFFFFFFFFFFF, 0)
    PHDR.pack_into(data, 272, 1, 6, 0, 0x400000, 0x400000, 64, 4096, 0x200000)
    data[384:] = bytes(range(16))
    return bytes(data)


def altered(data, offset, fmt, value):
    changed = bytearray(data)
    struct.pack_into(fmt, changed, offset, value)
    return bytes(changed)


def fixture32():
    data = bytearray(192)
    ident = b"\x7fELF\x01\x01\x01" + bytes(9)
    EHDR32.pack_into(data, 0, ident, 2, 3, 1, 0xFEDCBA98,
                     80, 0, 0, 52, 32, 2, 0, 0, 0)
    PHDR32.pack_into(data, 80, 1, 176, 0x80001000, 0xC2345678, 16, 0xF0001234, 7, 4096)
    PHDR32.pack_into(data, 112, 0, 0xF0000001, 0x12345678, 0xFFFFFFFF,
                     0x80000001, 0x7FFFFFFF, 0xFEDCBA98, 0)
    data[176:] = bytes(range(16))
    return bytes(data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", type=Path, default=ROOT / "build/elfinfo-long64.elf")
    parser.add_argument("--evidence", type=Path, help="new directory for actual inputs and guest captures")
    parser.add_argument("--require-bochs", action="store_true")
    args = parser.parse_args()
    work = args.evidence.resolve() if args.evidence else Path(tempfile.mkdtemp(prefix="elfinfo-check-"))
    if args.evidence:
        work.mkdir(mode=0o700)
    image = args.image.resolve()
    outcomes = []
    succeeded = False
    try:
        image_hash = hashlib.sha256(image.read_bytes()).hexdigest()
        have_bochs = all(shutil.which(name) for name in
                         ("bochs", "parted", "losetup", "mkfs.vfat", "grub-install", "xvfb-run", "sudo"))
        have_bochs = have_bochs and subprocess.run(["sudo", "-n", "true"], capture_output=True).returncode == 0
        if args.require_bochs and not have_bochs:
            raise AssertionError("required Bochs toolchain is unavailable")
        valid = fixture()
        valid32 = fixture32()
        cases = [
            ("compiler", (ROOT / "bootstrap/seed/gen1.seed").read_bytes(), True),
            ("self", image.read_bytes(), True),
            ("header-fields", valid, True),
            ("header32-fields", valid32, True),
            ("short-header", valid[:63], False),
            ("short-table", valid[:327], False),
            ("short-load", valid[:-1], False),
            ("filesz-exceeds-memsz", altered(valid, 160 + 40, "<Q", 15), False),
            ("unsupported-endian", altered(valid, 5, "B", 2), False),
            ("oversized-offset", altered(valid, 32, "<Q", (1 << 32) + 160), False),
            ("extended-count", altered(valid, 56, "<H", 65535), False),
            ("short32-table", valid32[:143], False),
            ("mismatched-machine", altered(valid32, 18, "<H", 62), False),
        ]
        for label, data, accepted in cases:
            source = work / f"{label}.elf"
            source.write_bytes(data)
            capture = work / label
            want = expected(data) if accepted else b""
            if label == "compiler":
                # Exercise the ordinary user command, including its program-specific wrapper.
                command = [sys.executable, str(ROOT / "tools/elfinfo_long64.py"), str(source),
                           "--image", str(image), "--evidence", str(capture)]
                process = subprocess.run(command, capture_output=True, timeout=70)
                (work / "compiler-cli.stdout").write_bytes(process.stdout)
                (work / "compiler-cli.stderr").write_bytes(process.stderr)
                assert process.returncode == 0 and process.stdout == want and process.stderr == b"", label
            else:
                output = io.BytesIO()
                try:
                    driver.run_file_program(image, source, output, evidence=capture)
                except driver.ProtocolError:
                    assert not accepted, label
                    record = json.loads((capture / "run.json").read_text())
                    # A host error or bad boot handoff cannot pass as an application rejection.
                    assert record["qemu_exit"] == 97, (label, record)
                    assert (capture / "debugcon.bin").read_bytes() == b"\xde\x01\xad", label
                else:
                    assert accepted, label
                assert output.getvalue() == want, label
            outcomes.append(label)
            print(f"PASS elfinfo {label}", flush=True)
        if os.access("/dev/kvm", os.R_OK | os.W_OK):
            output = io.BytesIO()
            driver.run_file_program(image, work / "header-fields.elf", output,
                                    accel="kvm", evidence=work / "kvm-header-fields")
            assert output.getvalue() == expected(valid)
            outcomes.append("kvm-header-fields")
            print("PASS elfinfo kvm-header-fields", flush=True)
        else:
            print("SKIP elfinfo KVM: /dev/kvm unavailable", flush=True)
        if have_bochs:
            # Reuse folio's checked disk setup and exact completion/serial oracle.
            bochs_boot(work, "bochs-header32-fields", image, valid32, expected(valid32))
            outcomes.append("bochs-header32-fields")
        else:
            print("SKIP elfinfo Bochs: toolchain unavailable", flush=True)
        (work / "RESULT.json").write_text(json.dumps({
            "image_sha256": image_hash, "passed": outcomes,
            "scope": "Actual CLI/compiler/self images and focused ELF acceptance/refusal cases; no new kernel gate.",
        }, indent=2) + "\n")
        succeeded = True
        print(f"elfinfo-long64: {len(outcomes)} checks passed", flush=True)
        return 0
    except Exception as error:
        print(f"FAIL elfinfo-long64: {type(error).__name__}: {error}; evidence: {work}", file=sys.stderr)
        return 1
    finally:
        if succeeded and args.evidence is None:
            shutil.rmtree(work)


if __name__ == "__main__":
    raise SystemExit(main())
