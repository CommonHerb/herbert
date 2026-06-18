#!/usr/bin/env python3
"""Focused checks for the repo-local portable timeout wrapper."""

from __future__ import annotations

import os
import shlex
import subprocess
import sys
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TIMEOUT = ROOT / "tools" / "timeout"


def fail(message: str) -> int:
    print(f"FAIL: timeout wrapper ({message})", file=sys.stderr)
    return 1


def run_case(label: str, argv: list[str]) -> tuple[int, float, subprocess.CompletedProcess[bytes]]:
    start = time.monotonic()
    completed = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return completed.returncode, time.monotonic() - start, completed


def main() -> int:
    if not TIMEOUT.exists():
        return fail(f"missing executable {TIMEOUT}")
    if not os.access(TIMEOUT, os.X_OK):
        return fail(f"not executable {TIMEOUT}")

    rc, _elapsed, completed = run_case(
        "pass-through exit",
        [str(TIMEOUT), "5s", sys.executable, "-c", "import sys; sys.exit(7)"],
    )
    if rc != 7:
        return fail(f"pass-through exit expected 7, got {rc}, stderr={completed.stderr!r}")

    rc, elapsed, completed = run_case(
        "basic timeout",
        [str(TIMEOUT), "0.2s", sys.executable, "-c", "import time; time.sleep(2)"],
    )
    if rc != 124:
        return fail(f"basic timeout expected 124, got {rc}, stderr={completed.stderr!r}")
    if elapsed > 1.5:
        return fail(f"basic timeout took too long: {elapsed:.3f}s")

    rc, elapsed, completed = run_case(
        "signal option",
        [str(TIMEOUT), "-s", "KILL", "0.2s", sys.executable, "-c", "import time; time.sleep(2)"],
    )
    if rc != 124:
        return fail(f"-s KILL timeout expected 124, got {rc}, stderr={completed.stderr!r}")
    if elapsed > 1.5:
        return fail(f"-s KILL timeout took too long: {elapsed:.3f}s")

    rc, _elapsed, completed = run_case(
        "stdio passthrough",
        [
            str(TIMEOUT),
            "5s",
            sys.executable,
            "-c",
            "import sys; sys.stdout.write('out'); sys.stderr.write('err')",
        ],
    )
    if rc != 0 or completed.stdout != b"out" or completed.stderr != b"err":
        return fail(
            "stdio passthrough mismatch "
            f"rc={rc} stdout={completed.stdout!r} stderr={completed.stderr!r}"
        )

    completed = subprocess.run(
        [
            str(TIMEOUT),
            "5s",
            sys.executable,
            "-c",
            "import sys; sys.stdout.buffer.write(sys.stdin.buffer.read().upper())",
        ],
        input=b"abc",
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if completed.returncode != 0 or completed.stdout != b"ABC":
        return fail(
            "stdin passthrough mismatch "
            f"rc={completed.returncode} stdout={completed.stdout!r} stderr={completed.stderr!r}"
        )

    with tempfile.TemporaryDirectory() as td:
        marker = Path(td) / "leaked-child"
        child_code = (
            "import pathlib, sys, time; "
            "time.sleep(1); "
            "pathlib.Path(sys.argv[1]).write_text('leaked')"
        )
        shell = (
            f"{shlex.quote(sys.executable)} -c {shlex.quote(child_code)} "
            f"{shlex.quote(str(marker))} & wait"
        )
        rc, elapsed, completed = run_case(
            "process group timeout",
            [str(TIMEOUT), "0.2s", "bash", "-c", shell],
        )
        time.sleep(1.1)
        if rc != 124:
            return fail(
                "process group timeout expected 124, "
                f"got {rc}, stderr={completed.stderr!r}"
            )
        if elapsed > 1.5:
            return fail(f"process group timeout took too long: {elapsed:.3f}s")
        if marker.exists():
            return fail("process group timeout leaked a surviving child process")

    with tempfile.TemporaryDirectory() as td:
        marker = Path(td) / "interrupted-child"
        child_code = (
            "import pathlib, sys, time; "
            "time.sleep(1); "
            "pathlib.Path(sys.argv[1]).write_text('leaked')"
        )
        shell = (
            f"{shlex.quote(sys.executable)} -c {shlex.quote(child_code)} "
            f"{shlex.quote(str(marker))} & wait"
        )
        proc = subprocess.Popen(
            [str(TIMEOUT), "5s", "bash", "-c", shell],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        time.sleep(0.2)
        proc.terminate()
        stdout, stderr = proc.communicate(timeout=2)
        time.sleep(1.1)
        if marker.exists():
            return fail("interrupted wrapper leaked a surviving child process")
        if proc.returncode != 143:
            return fail(
                "interrupted wrapper expected 143, "
                f"got {proc.returncode}, stdout={stdout!r}, stderr={stderr!r}"
            )

    print("PASS: timeout wrapper")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
