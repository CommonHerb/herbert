#!/usr/bin/env python3
"""Display a file using the Herbert-compiled long64 hexadecimal viewer."""

from pathlib import Path
import argparse
import hashlib
import json
import math
import os
import shutil
import stat
import subprocess
import sys
import tempfile

from wordcount_long64 import ProtocolError, qemu_path


ROOT = Path(__file__).resolve().parents[1]
RAM_BYTES = 64 * 1024 * 1024


def snapshot(source, target):
    """Copy a bounded regular file and identify the bytes actually copied."""
    digest = hashlib.sha256()
    size = 0
    # A FIFO or device is not a finite boot file. Nonblocking open lets us
    # reject a FIFO without hanging while waiting for its writer.
    fd = os.open(source, os.O_RDONLY | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as reader:
        info = os.fstat(reader.fileno())
        if not stat.S_ISREG(info.st_mode):
            raise ProtocolError(f"not a regular file: {source}")
        if info.st_size > RAM_BYTES:
            raise ProtocolError(f"file exceeds the 64 MiB appliance: {source}")
        with target.open("xb") as writer:
            while True:
                block = reader.read(1024 * 1024)
                if block is None:
                    raise ProtocolError(f"file input is temporarily unavailable: {source}")
                if block == b"":
                    break
                size += len(block)
                if size > RAM_BYTES:
                    raise ProtocolError(f"file grew beyond the 64 MiB appliance: {source}")
                writer.write(block)
                digest.update(block)
    return {"bytes": size, "sha256": digest.hexdigest()}


def run_file_program(image, input_file, output, *, qemu=None, accel="tcg", timeout=60.0, evidence=None):
    """Boot a snapshotted file; publish guest output only after successful exit.

    The guest reads module bytes and produces the result. This adapter performs
    no parsing or rendering. Serial data stays on disk until completion and is
    copied to the caller's binary output stream with bounded host memory.
    """
    if not math.isfinite(timeout) or timeout <= 0:
        raise ValueError("timeout must be a finite positive number of seconds")
    if accel not in ("tcg", "kvm"):
        raise ValueError("acceleration must be tcg or kvm")
    if accel == "kvm" and not os.access("/dev/kvm", os.R_OK | os.W_OK):
        raise ProtocolError("KVM is not accessible")
    binary = str(Path(qemu_path(qemu)).resolve())
    if evidence is None:
        work = Path(tempfile.mkdtemp(prefix="herbert-long64-file-"))
    else:
        work = Path(evidence).resolve()
        work.mkdir(mode=0o700)
    succeeded = False
    record = {
        "image": str(Path(image).resolve()),
        "input": str(Path(input_file).resolve()),
        "accel": accel,
        "timeout_seconds": timeout,
        "status": "incomplete",
    }
    try:
        record["image_snapshot"] = snapshot(image, work / "kernel.elf")
        record["input_snapshot"] = snapshot(input_file, work / "input.bin")
        cpu = ["-accel", "kvm", "-cpu", "host"] if accel == "kvm" else ["-accel", "tcg", "-cpu", "qemu64"]
        # Fixed relative names avoid QEMU's comma-separated initrd syntax
        # interpreting punctuation in the caller's directory or input name.
        command = [
            binary, "-kernel", "kernel.elf", "-initrd", "input.bin", "-m", "64M",
            "-display", "none", "-monitor", "none", "-nic", "none", "-no-reboot",
            "-serial", "file:serial.bin", "-debugcon", "file:debugcon.bin",
            "-device", "isa-debug-exit,iobase=0xf4,iosize=0x04", *cpu,
        ]
        record["command"] = command
        record["cwd"] = str(work)
        with (work / "qemu.stderr").open("wb") as errors:
            try:
                process = subprocess.run(
                    command, cwd=work, stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL, stderr=errors,
                    timeout=timeout, start_new_session=True,
                )
            except subprocess.TimeoutExpired as exc:
                raise ProtocolError(f"QEMU did not finish within {timeout:g} seconds") from exc
        record["qemu_exit"] = process.returncode
        debug_path = work / "debugcon.bin"
        debugcon = b""
        if debug_path.exists():
            with debug_path.open("rb") as frames:
                debugcon = frames.read(7)
            record["debugcon_bytes"] = debug_path.stat().st_size
        record["debugcon_prefix_hex"] = debugcon.hex()
        if process.returncode != 99 or debugcon != b"\xde\x00\xad":
            if debugcon == b"BI\n\xde\x01\xad":
                raise ProtocolError("guest rejected invalid or unsupported boot input")
            if process.returncode == 97 and debugcon == b"\xde\x01\xad":
                raise ProtocolError("guest rejected the input")
            with (work / "qemu.stderr").open("rb") as errors:
                detail = errors.readline(512).decode("utf-8", errors="replace").strip()
            raise ProtocolError(f"guest did not complete successfully (QEMU exit {process.returncode}): {detail}")
        record["guest_completed"] = True
        serial = work / "serial.bin"
        record["output_bytes"] = serial.stat().st_size
        with serial.open("rb") as reader:
            shutil.copyfileobj(reader, output, length=1024 * 1024)
        output.flush()
        record["status"] = "success"
        succeeded = True
    except BaseException as exc:
        record["status"] = "failure"
        record["error"] = f"{type(exc).__name__}: {exc}"
        if isinstance(exc, (KeyboardInterrupt, SystemExit)):
            raise
        raise ProtocolError(f"{exc}; evidence: {work}") from exc
    finally:
        (work / "run.json").write_text(json.dumps(record, indent=2) + "\n")
        if succeeded and evidence is None:
            shutil.rmtree(work)


# Keep the viewer's existing import interface for its callers and folio gate.
run_viewer = run_file_program


def main(argv=None, *, program="hexview", description=__doc__):
    parser = argparse.ArgumentParser(description=description)
    parser.add_argument("file", type=Path, help="regular file to supply as the boot module")
    parser.add_argument("--image", type=Path, default=ROOT / f"build/{program}-long64.elf")
    parser.add_argument("--qemu", help="QEMU executable (otherwise QEMU_PREFIX or PATH)")
    parser.add_argument("--accel", choices=("tcg", "kvm"), default="tcg")
    parser.add_argument("--timeout", type=float, default=60.0, help="seconds for the complete emulator run")
    parser.add_argument("--evidence", type=Path, help="new directory retaining input, image and raw emulator output")
    args = parser.parse_args(argv)
    try:
        if sys.stdout is None:
            raise ProtocolError("standard output is closed")
        run_file_program(
            args.image, args.file, sys.stdout.buffer, qemu=args.qemu,
            accel=args.accel, timeout=args.timeout, evidence=args.evidence,
        )
    except (OSError, ValueError, ProtocolError) as exc:
        print(f"{program}-long64: {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print(f"{program}-long64: interrupted", file=sys.stderr)
        return 130
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
