#!/usr/bin/env python3
"""Check the source-authored streaming counter on actual long64 guest images."""

import argparse
import hashlib
import io
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import wordcount_long64 as driver

# Literal expected counts reuse the hosted utility's byte semantics. They are
# not obtained by translating or executing the guest's scan algorithm.
CASES = [
    ("empty", b"", (0, 0, 0)),
    ("unterminated", b"one two", (0, 2, 7)),
    ("whitespace", b" \t\n\r\v\f ", (1, 0, 7)),
    ("CRLF", b"one\r\ntwo\r\n", (2, 2, 10)),
    ("all-byte-values", bytes(range(256)), (1, 3, 256)),
    ("chunk-crossing", b"x" * 255 + b"y z\n", (1, 2, 259)),
    ("sustained", b"a b\n" * 25_000, (25_000, 50_000, 100_000)),
]
COMBINED = (bytes(range(256)) + b"\r\n" + b"x" * 512 + b" \tend\x00\xff")
COMBINED_EXPECTED = (2, 5, 777)


def expected_bytes(counts):
    return (str(counts) + "\n").encode("ascii")


def truncated_result():
    """A peer that accepts EOF but closes halfway through its answer is not success."""
    host, peer = socket.socketpair()
    errors = []
    sent, received = io.BytesIO(), io.BytesIO()

    def serve():
        try:
            with peer:
                peer.settimeout(3)
                peer.sendall(b"HWC1\n")
                if peer.recv(1) != b"\x00":
                    raise AssertionError("expected the explicit EOF command")
                peer.sendall(b"\x06R(0, 0,")
        except BaseException as error:
            errors.append(error)

    thread = threading.Thread(target=serve)
    thread.start()
    try:
        with host:
            try:
                driver.exchange(host, io.BytesIO(b""), timeout=3,
                                sent_log=sent, received_log=received)
            except driver.ProtocolError:
                pass
            else:
                raise AssertionError("truncated result was accepted")
    finally:
        thread.join(4)
    if thread.is_alive() or errors:
        raise AssertionError(f"truncated-result peer failed: {errors!r}")
    return sent.getvalue(), received.getvalue()


def compile_mutants(work, seed, *, only=None):
    compiler_bytes = seed.read_bytes()
    digest = hashlib.sha256(compiler_bytes).hexdigest()
    if seed == ROOT / "bootstrap/seed/gen1.seed":
        pinned = seed.with_suffix(".seed.sha256").read_text().split()[0]
        if digest != pinned:
            raise AssertionError("workspace seed checksum mismatch")
    compiler = work / "compiler"
    compiler.write_bytes(compiler_bytes)
    compiler.chmod(0o700)
    source = (ROOT / "examples/wordcount_long64.herb").read_text()
    edits = {
        "wrong-space": ("elif c == 32:", "elif c == 33:"),
        "bad-completion": ("return status * 4294967296", "return (status + 1) * 4294967296"),
    }
    # Test-only initialization makes the 20-digit boundary reachable in two
    # bytes. The ordinary guest keeps its zero initialization and has no hook.
    seed_capacity = """func seed_capacity(base, i):
    if i == 20:
        return 0
    end
    if i == 0:
        let low = bufset(base, 40, 8)
        return seed_capacity(base, 1)
    end
    let high = bufset(base, 40 + i, 9)
    return seed_capacity(base, i + 1)
end

"""
    edits["near-capacity"] = ("func main():", seed_capacity + "func main():")
    images = {}
    for label, (old, new) in edits.items():
        if only is not None and label not in only:
            continue
        if source.count(old) != 1:
            raise AssertionError(f"mutation anchor no longer unique: {label}")
        directory = work / label
        directory.mkdir()
        changed = source.replace(old, new)
        if label == "near-capacity":
            anchor = "    let ready = startup()"
            if changed.count(anchor) != 1:
                raise AssertionError("capacity initialization anchor is not unique")
            changed = changed.replace(anchor, "    let seeded = seed_capacity(base, 0)\n" + anchor)
        changed = changed.encode()
        (directory / "source.herb").write_bytes(changed)
        result = subprocess.run([str(compiler)], input=changed, cwd=directory,
                                capture_output=True, timeout=30)
        (directory / "compile.stdout").write_bytes(result.stdout)
        (directory / "compile.stderr").write_bytes(result.stderr)
        if (result.returncode, result.stdout, result.stderr) != (0, b"0\n", b""):
            raise AssertionError(f"{label} did not compile successfully: {result!r}")
        image = directory / "a.out"
        if image.read_bytes()[:4] != b"\x7fELF":
            raise AssertionError(f"{label} produced no ELF image")
        images[label] = image
    print(f"wordcount-long64 compiler SHA-256: {digest}", flush=True)
    return images



def check_capacity(image, evidence, qemu, timeout):
    expected = b"(0, 0, 99999999999999999999)\n"
    actual = driver.run_qemu(image, io.BytesIO(b" "), qemu=qemu, accel="tcg",
                             timeout=timeout, evidence=evidence / "capacity-last")
    if actual != expected:
        raise AssertionError(f"20-digit count was not rendered exactly: {actual!r}")
    print("PASS wordcount-long64 last representable count: 20 digits", flush=True)
    try:
        driver.run_qemu(image, io.BytesIO(b"  "), qemu=qemu, accel="tcg",
                        timeout=timeout, evidence=evidence / "capacity-overflow")
    except driver.ProtocolError as error:
        received = (evidence / "capacity-overflow" / "received.bin").read_bytes()
        # Header and first byte were ACKed. The overflowing second byte receives
        # the explicit NAK/error code, never its ACK or a result record.
        if "counter capacity exceeded" not in str(error) or received != b"HWC1\n\x06\x06\x151\n":
            raise AssertionError(f"missing explicit overflow witness: {received!r}")
    else:
        raise AssertionError("counter overflow was accepted")
    print("PASS wordcount-long64 overflow: explicit capacity rejection, no result", flush=True)


def check_nonblocking_prefix(image, evidence, qemu, timeout):
    """EAGAIN after real input progress must not become an explicit guest EOF."""
    read_fd, write_fd = os.pipe()
    directory = evidence / "nonblocking-prefix"
    try:
        os.set_blocking(read_fd, False)
        if os.write(write_fd, b"one two\n") != 8:
            raise AssertionError("nonblocking-prefix fixture did not write its prefix")
        # Keep BufferedReader: read1 returns b"" on EAGAIN, unlike read's None.
        # The writer stays open throughout the guest run, so no real EOF exists.
        with os.fdopen(read_fd, "rb") as source:
            read_fd = None
            try:
                driver.run_qemu(image, source, qemu=qemu, accel="tcg",
                                timeout=timeout, evidence=directory)
            except driver.ProtocolError as error:
                sent = (directory / "sent.bin").read_bytes()
                received = (directory / "received.bin").read_bytes()
                if ("input is temporarily unavailable; stream is incomplete" not in str(error)
                        or sent != b"\x08one two\n"
                        or received != b"HWC1\n" + b"\x06" * 9):
                    raise AssertionError(
                        f"nonblocking prefix lacked exact progress/refusal: {error}; "
                        f"sent={sent!r}, received={received!r}")
            else:
                raise AssertionError("nonblocking EAGAIN was accepted as source EOF")
    finally:
        try:
            if read_fd is not None:
                os.close(read_fd)
        finally:
            os.close(write_fd)
    print("PASS wordcount-long64 nonblocking prefix: progress, no EOF or result", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", required=True, type=Path)
    parser.add_argument("--compiler", type=Path, default=ROOT / "bootstrap/seed/gen1.seed")
    parser.add_argument("--qemu")
    parser.add_argument("--kvm", action="store_true", help="also require one real-silicon run")
    parser.add_argument("--timeout", type=float, default=180)
    parser.add_argument("--evidence", type=Path, help="fresh directory for actual attempts")
    args = parser.parse_args()
    image = args.image.resolve(strict=True)
    qemu = driver.qemu_path(args.qemu)
    if args.evidence:
        evidence = args.evidence.resolve()
        evidence.mkdir(parents=True, exist_ok=False)
    else:
        evidence = Path(tempfile.mkdtemp(prefix="herbert-wordcount-long64-"))
    print(f"wordcount-long64 evidence: {evidence}", flush=True)
    manifest = {"scope": "ordinary literal-count cases; fault and capacity attempts have separate logs",
                "image_sha256": hashlib.sha256(image.read_bytes()).hexdigest(),
                "cases": []}

    def run(label, data, counts, *, accel="tcg", guest=image):
        manifest["cases"].append({"name": label, "accel": accel,
                                  "input_bytes": len(data), "input_sha256": hashlib.sha256(data).hexdigest(),
                                  "expected": list(counts)})
        (evidence / "cases.json").write_text(json.dumps(manifest, indent=2) + "\n")
        actual = driver.run_qemu(guest, io.BytesIO(data), qemu=qemu, accel=accel,
                                 timeout=args.timeout, evidence=evidence / label)
        if actual != expected_bytes(counts):
            raise AssertionError(f"{label}: expected {expected_bytes(counts)!r}, got {actual!r}")
        print(f"PASS wordcount-long64 {label}: {len(data)} bytes", flush=True)

    sent, received = truncated_result()
    (evidence / "truncated.sent.bin").write_bytes(sent)
    (evidence / "truncated.received.bin").write_bytes(received)
    print("PASS wordcount-long64 truncated result: no success", flush=True)
    for label, data, counts in CASES:
        run(label, data, counts)
    if args.kvm:
        run("KVM-combined", COMBINED, COMBINED_EXPECTED, accel="kvm")

    check_nonblocking_prefix(image, evidence, qemu, args.timeout)
    mutants = compile_mutants(evidence, args.compiler.resolve())
    probe = b"one two\n"
    expected = b"(1, 2, 8)\n"
    actual = driver.run_qemu(mutants["wrong-space"], io.BytesIO(probe), qemu=qemu,
                             accel="tcg", timeout=args.timeout, evidence=evidence / "wrong-space-run")
    if actual == expected:
        raise AssertionError("wrong whitespace classification escaped the literal count check")
    print(f"PASS wordcount-long64 wrong-space mutant: completed but count differs ({actual!r})", flush=True)
    try:
        driver.run_qemu(mutants["bad-completion"], io.BytesIO(probe), qemu=qemu,
                        accel="tcg", timeout=args.timeout, evidence=evidence / "bad-completion-run")
    except driver.ProtocolError:
        # Confirm the complete-looking answer was really emitted: a dead guest
        # cannot satisfy this negative completion witness.
        received = (evidence / "bad-completion-run" / "received.bin").read_bytes()
        debugcon = (evidence / "bad-completion-run" / "debugcon.bin").read_bytes()
        if not received.endswith(b"R" + expected) or debugcon != b"\xde\x01\xad":
            raise AssertionError("bad-completion mutant did not reach its intended witness")
    else:
        raise AssertionError("complete-looking result with failed guest completion was accepted")
    print("PASS wordcount-long64 bad completion: valid counts refused", flush=True)
    check_capacity(mutants["near-capacity"], evidence, qemu, args.timeout)
    print(f"wordcount-long64: {len(CASES) + int(args.kvm) + 6} checks passed", flush=True)


if __name__ == "__main__":
    main()
