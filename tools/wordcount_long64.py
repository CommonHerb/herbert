#!/usr/bin/env python3
"""Forward stdin to Herbert's long64 word counter and print its guest result."""

from pathlib import Path
import argparse
import hashlib
import json
import math
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
READY = b"HWC1\n"
ACK = b"\x06"
NAK = b"\x15"
DIGITS = rb"(?:0|[1-9][0-9]{0,19})"
RESULT = re.compile(rb"R\(" + DIGITS + rb", " + DIGITS + rb", " + DIGITS + rb"\)\n")
MAX_RESULT = 68


class ProtocolError(RuntimeError):
    """The input stream, guest protocol, or emulator did not complete correctly."""


def qemu_path(explicit=None):
    if explicit:
        candidate = str(explicit)
    elif os.environ.get("QEMU_PREFIX"):
        prefix = Path(os.environ["QEMU_PREFIX"])
        if not prefix.is_absolute():
            raise ProtocolError("QEMU_PREFIX must be an absolute directory")
        candidate = str(prefix / "bin/qemu-system-x86_64")
    else:
        candidate = "qemu-system-x86_64"
    resolved = shutil.which(candidate)
    if resolved is None:
        raise ProtocolError(f"QEMU executable not found: {candidate}")
    return resolved


def _timeout(value):
    if not math.isfinite(value) or value <= 0:
        raise ValueError("timeout must be a finite positive number of seconds")
    return value


def _receive(peer, amount, received_log):
    result = bytearray()
    while len(result) < amount:
        # Strict request/reply traffic otherwise hits Linux's delayed-ACK timer.
        if hasattr(socket, "TCP_QUICKACK") and peer.family == socket.AF_INET:
            peer.setsockopt(socket.IPPROTO_TCP, socket.TCP_QUICKACK, 1)
        part = peer.recv(amount - len(result))
        if not part:
            raise ProtocolError("guest connection closed before completion")
        received_log.write(part)
        result.extend(part)
    return bytes(result)


def exchange(peer, source, *, timeout=30.0, sent_log, received_log):
    """Transfer bytes without counting them; return the guest's framed answer.

    The caller owns emulator completion and the final EOF/no-extra-bytes check.
    Source EOF is only b"". A read error or nonblocking None is never an end marker.
    Logs record transport bytes, not an independent receipt or execution claim.
    """
    peer.settimeout(_timeout(timeout))
    if peer.family == socket.AF_INET:
        peer.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    if _receive(peer, len(READY), received_log) != READY:
        raise ProtocolError("guest did not send the word-counter greeting")

    def send_byte(value):
        wire = bytes((value,))
        peer.sendall(wire)
        sent_log.write(wire)
        reply = _receive(peer, 1, received_log)
        if reply == NAK:
            if _receive(peer, 2, received_log) == b"1\n":
                raise ProtocolError("guest counter capacity exceeded")
            raise ProtocolError("guest sent an unknown rejection")
        if reply != ACK:
            raise ProtocolError("guest did not acknowledge the input byte")

    while True:
        # BufferedReader.read1 can return b"" on EAGAIN, even with a live writer.
        # read preserves None as unavailable input instead of mistaking it for EOF.
        block = source.read(255)
        if block is None:
            raise ProtocolError("input is temporarily unavailable; stream is incomplete")
        if not isinstance(block, bytes) or len(block) > 255:
            raise ProtocolError("input did not provide a bounded binary read")
        send_byte(len(block))
        if not block:
            break
        for byte in block:
            send_byte(byte)

    result = bytearray()
    for _ in range(MAX_RESULT):
        result.extend(_receive(peer, 1, received_log))
        if result[-1] == 10:
            if RESULT.fullmatch(result) is None:
                raise ProtocolError("guest returned an invalid count record")
            return bytes(result[1:])
    raise ProtocolError("guest count record exceeds its declared capacity")


def run_qemu(image, source, *, qemu=None, accel="tcg", timeout=30.0, evidence=None):
    """Run one immutable image copy; publish no counts before full completion.

    Default temporary evidence is removed on success and retained on failure.
    An explicitly selected evidence directory must be new and is always retained.
    """
    _timeout(timeout)
    if accel not in ("tcg", "kvm"):
        raise ValueError("accel must be tcg or kvm")
    binary = qemu_path(qemu)
    kernel = Path(image).read_bytes()
    if kernel[:4] != b"\x7fELF":
        raise ProtocolError("image is not an ELF; build with make long64-wordcount")
    if evidence is None:
        work = Path(tempfile.mkdtemp(prefix="herbert-wordcount-long64-"))
    else:
        work = Path(evidence).resolve()
        work.mkdir(parents=True, exist_ok=False)
    process = None
    succeeded = False
    record = {
        "image": str(Path(image).resolve()),
        "image_sha256": hashlib.sha256(kernel).hexdigest(),
        "accel": accel,
        "response_timeout_seconds": timeout,
        "status": "incomplete",
    }
    try:
        # The recorded hash identifies the actual bytes handed to QEMU, even if
        # the caller later rebuilds the source image at the same pathname.
        boot_image = work / "kernel.elf"
        boot_image.write_bytes(kernel)
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen(1)
            port = listener.getsockname()[1]
            cpu = ["-accel", "kvm", "-cpu", "host"] if accel == "kvm" else ["-accel", "tcg", "-cpu", "qemu64"]
            command = [
                binary, "-kernel", str(boot_image), "-m", "64M",
                "-display", "none", "-monitor", "none", "-nic", "none",
                "-no-reboot", "-debugcon", f"file:{work / 'debugcon.bin'}",
                "-device", "isa-debug-exit,iobase=0xf4,iosize=0x04",
                "-chardev", f"socket,id=s0,host=127.0.0.1,port={port},server=off,nodelay=on",
                "-serial", "chardev:s0", *cpu,
            ]
            record["command"] = command
            with (work / "qemu.stderr").open("wb") as errors, \
                    (work / "sent.bin").open("wb") as sent, \
                    (work / "received.bin").open("wb") as received:
                process = subprocess.Popen(
                    command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                    stderr=errors, start_new_session=True,
                )
                deadline = time.monotonic() + timeout
                while True:
                    if process.poll() is not None:
                        with (work / "qemu.stderr").open("rb") as detail:
                            reason = detail.readline(512).decode("utf-8", errors="replace").strip()
                        raise ProtocolError(f"QEMU exited before connecting ({process.returncode}): {reason}")
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise ProtocolError("QEMU did not connect before the startup timeout")
                    listener.settimeout(min(0.1, remaining))
                    try:
                        peer, _ = listener.accept()
                        break
                    except socket.timeout:
                        continue
                with peer:
                    result = exchange(peer, source, timeout=timeout, sent_log=sent, received_log=received)
                    extra = peer.recv(1)
                    if extra:
                        received.write(extra)
                        raise ProtocolError("guest sent bytes after the completed result")
                status = process.wait(timeout=timeout)
                record["qemu_exit"] = status
                debugcon = (work / "debugcon.bin").read_bytes()
                record["debugcon_hex"] = debugcon.hex()
                if status != 99 or debugcon != b"\xde\x00\xad":
                    raise ProtocolError(f"guest did not complete successfully (QEMU exit {status})")
        record["result"] = result.decode("ascii")
        record["status"] = "success"
        succeeded = True
        return result
    except BaseException as exc:
        record["status"] = "failure"
        record["error"] = f"{type(exc).__name__}: {exc}"
        if isinstance(exc, (KeyboardInterrupt, SystemExit)):
            raise
        raise ProtocolError(f"{exc}; evidence: {work}") from exc
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        if process is not None:
            record["qemu_exit"] = process.returncode
        (work / "run.json").write_text(json.dumps(record, indent=2) + "\n")
        if succeeded and evidence is None:
            shutil.rmtree(work)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", type=Path, default=ROOT / "build/wordcount-long64.elf")
    parser.add_argument("--qemu", help="QEMU executable (otherwise QEMU_PREFIX or PATH)")
    parser.add_argument("--accel", choices=("tcg", "kvm"), default="tcg")
    parser.add_argument("--timeout", type=float, default=30.0, help="seconds per guest response or completion")
    parser.add_argument("--evidence", type=Path, help="new directory retaining image, wire bytes and emulator logs")
    args = parser.parse_args()
    try:
        if sys.stdin is None:
            raise ProtocolError("standard input is closed")
        result = run_qemu(
            # No buffered stdin reads precede this call. FileIO preserves short
            # pipe reads without read1's ambiguous empty result on EAGAIN.
            args.image, sys.stdin.buffer.raw, qemu=args.qemu, accel=args.accel,
            timeout=args.timeout, evidence=args.evidence,
        )
        sys.stdout.buffer.write(result)
        sys.stdout.buffer.flush()
    except (OSError, ValueError, ProtocolError) as exc:
        print(f"wordcount-long64: {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("wordcount-long64: interrupted", file=sys.stderr)
        return 130
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
