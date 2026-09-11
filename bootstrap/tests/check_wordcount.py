#!/usr/bin/env python3
"""Build the actual Herbert utility and check observable results under load."""

from pathlib import Path
import argparse
import hashlib
import os
import resource
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[2]
STACK_BYTES = 8 * 1024 * 1024


def runtime_limits():
    resource.setrlimit(resource.RLIMIT_STACK, (STACK_BYTES, STACK_BYTES))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def require_result(result, stdout, *, status=0, stderr=b""):
    actual = (result.returncode, result.stdout, result.stderr)
    expected = (status, stdout, stderr)
    if actual != expected:
        raise AssertionError(f"expected {expected!r}, got {actual!r}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler", type=Path, help="explicit candidate seed")
    args = parser.parse_args()
    seed = args.compiler or ROOT / "bootstrap/seed/gen1.seed"
    seed_bytes = seed.read_bytes()
    digest = hashlib.sha256(seed_bytes).hexdigest()
    if args.compiler is None:
        pinned = seed.with_suffix(seed.suffix + ".sha256").read_text().split()[0]
        if digest != pinned:
            raise AssertionError("workspace seed checksum mismatch")
    print(f"wordcount compiler SHA-256: {digest}", flush=True)
    with tempfile.TemporaryDirectory(prefix="herbert-wordcount-") as directory:
        work = Path(directory)
        compiler = work / "compiler"
        compiler.write_bytes(seed_bytes)
        compiler.chmod(0o700)
        compiled = subprocess.run(
            [str(compiler)], input=(ROOT / "examples/wordcount.herb").read_bytes(),
            cwd=work, capture_output=True, timeout=30,
        )
        require_result(compiled, b"0\n")
        executable = work / "a.out"
        if executable.read_bytes()[:4] != b"\x7fELF":
            raise AssertionError("compiler did not produce an ELF")
        executable.chmod(0o700)
        # Expected answers are specified independently of the scan algorithm.
        cases = [
            ("empty", b"", (0, 0, 0)),
            ("unterminated", b"one two", (0, 2, 7)),
            ("LF", b"one\ntwo\n", (2, 2, 8)),
            ("whitespace", b" \t\n\r\v\f ", (1, 0, 7)),
            ("CRLF", b"one\r\ntwo\r\n", (2, 2, 10)),
            ("binary", b"\x00\xff \x80\n\x00", (1, 3, 6)),
            ("all-byte-values", bytes(range(256)), (1, 3, 256)),
            ("long-word", b"a" * 2_000_000, (0, 1, 2_000_000)),
            ("many-words", b"a " * 1_000_000, (0, 1_000_000, 2_000_000)),
            ("many-lines", b"a b\n" * 1_000_000, (1_000_000, 2_000_000, 4_000_000)),
        ]
        started = time.monotonic()
        for label, data, counts in cases:
            result = subprocess.run(
                [str(executable)], input=data, capture_output=True, timeout=15,
                preexec_fn=runtime_limits,
            )
            require_result(result, (str(counts) + "\n").encode())
            print(f"PASS wordcount {label}: {len(data)} bytes", flush=True)
        # Multi-megabyte pipe inputs exceed pipe capacity, so successful counts
        # exercise repeated short reads without relying on scheduler timing.
        def closed_stdin():
            runtime_limits()
            os.close(0)

        failed = subprocess.run(
            [str(executable)], stdin=subprocess.DEVNULL, capture_output=True, timeout=15,
            preexec_fn=closed_stdin,
        )
        require_result(failed, b"", status=1, stderr=b"wordcount: cannot read standard input\n")
        print("PASS wordcount closed stdin: no success result", flush=True)
        print(f"wordcount: {len(cases) + 1} cases passed; runtime checks {time.monotonic() - started:.2f}s; stack limit {STACK_BYTES} bytes")


if __name__ == "__main__":
    main()
