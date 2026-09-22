#!/usr/bin/env python3
"""Bound compiler memory for dense CALL, tuple, heap and branch/local metadata.

The straight-line inputs have 2,000 operations and independently known results.
The pre-repair compiler crosses the sampled RSS stop threshold on the first case;
appending metadata keeps those cases below the RSS ceiling. A fourth input has
200 locals and 200 conditionals, exercising returning arms and live-state joins.
Its smaller scale leaves room under the same RSS ceiling despite pre-existing
local-environment copying in other passes. This is a focused
regression, not a general linear-memory guarantee for every compiler stage.
Python and GNU time are test tools only; the programs use the Herbert seed.
The sampled supervisor covers these single-process, single-thread Herbert
programs and GNU time's direct child. It is not a general process-tree sandbox;
only compilation has a post-exit high-water RSS assertion.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import shutil
import signal
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parents[2]
SEED = ROOT / "bootstrap/seed/gen1.seed"
MAX_RSS_KIB = 128 * 1024
# Herbert reserves a large virtual arena even when it touches very few pages.
# Bound physical use separately instead of forbidding that reservation.
MAX_ADDRESS_BYTES = 4 * 1024 * 1024 * 1024
TIMEOUT_SECONDS = 30
OPERATIONS = 2000
BRANCH_LOCALS = 200


def require(condition, message):
    if not condition:
        raise ValueError(message)


def limits():
    resource.setrlimit(resource.RLIMIT_AS, (MAX_ADDRESS_BYTES, MAX_ADDRESS_BYTES))
    resource.setrlimit(resource.RLIMIT_CPU, (20, 20))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def invoke(command, directory, phase):
    # File capture retains partial evidence even if the process times out. Each
    # invocation owns a fresh process group; only that group can be terminated.
    with ((directory / "source.herb") if phase == "compile" else Path("/dev/null")).open("rb") as inp, \
            (directory / f"{phase}.stdout").open("wb") as out, \
            (directory / f"{phase}.stderr").open("wb") as err:
        process = subprocess.Popen(command, stdin=inp, stdout=out,
                                   stderr=err, cwd=directory, preexec_fn=limits,
                                   start_new_session=True)
        deadline = time.monotonic() + TIMEOUT_SECONDS
        stopped = None
        try:
            while process.poll() is None:
                # GNU time is the parent of the actual compiler; runtime has no
                # wrapper. Post-exit GNU time still supplies exact high-water RSS.
                pids = [str(process.pid)]
                try:
                    pids += Path(f"/proc/{process.pid}/task/{process.pid}/children").read_text().split()
                except (FileNotFoundError, ProcessLookupError):
                    if process.poll() is None:
                        raise ValueError(f"{phase}: live process /proc children unavailable; cannot enforce RSS")
                for pid in pids:
                    try:
                        for line in Path(f"/proc/{pid}/status").read_text().splitlines():
                            if line.startswith(("VmRSS:", "VmHWM:")) and int(line.split()[1]) > MAX_RSS_KIB:
                                stopped = f"RSS stop threshold {MAX_RSS_KIB} KiB exceeded"
                    except (FileNotFoundError, ProcessLookupError):
                        if pid == str(process.pid) and process.poll() is None:
                            raise ValueError(f"{phase}: live process /proc status unavailable; cannot enforce RSS")
                        # A short-lived child may exit between these reads.
                if stopped is None and time.monotonic() >= deadline:
                    stopped = f"wall limit {TIMEOUT_SECONDS}s exceeded"
                if stopped:
                    break
                time.sleep(0.005)
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        if stopped:
            (directory / f"{phase}.status").write_text(stopped + "\n")
            raise ValueError(f"{phase}: {stopped} (supervisor stopped the owned process group)")
    (directory / f"{phase}.status").write_text(f"{process.returncode}\n")
    return (process.returncode, (directory / f"{phase}.stdout").read_bytes(),
            (directory / f"{phase}.stderr").read_bytes())


def cases():
    yield ("calls", "func f(x): return x + 1 end\nfunc main():\nlet x = 0\n"
           + "x = f(x)\n" * OPERATIONS + "return x\nend\n", OPERATIONS)
    yield ("tuples", "func main():\nlet x = 0\n"
           + "x = (x + 1, (2, 3)).0\n" * OPERATIONS + "return x\nend\n", OPERATIONS)
    # Width-two array elements exercise ADD/GET metadata alongside projections.
    # Buffer construction covers the remaining metadata-bearing heap opcode.
    yield ("heap", "func main():\nlet a = new_array((int, int))\nlet x = 0\n"
           + "".join(f"do add(a, ({i}, {i + 1}))\nx = x + get(a, {i}).1\n"
                     for i in range(OPERATIONS))
           + "let b = new_buffer()\ndo append(b, 65)\n"
           + "return x + get(a, 0).1 + get(a, 1).0 + length(freeze(b))\nend\n",
           OPERATIONS * (OPERATIONS + 1) // 2 + 3)
    # Every conditional has a returning arm and two continuing predecessors.
    # Keep all locals live across the joins; main exercises both surviving
    # paths and an early return. The oracle is arithmetic, not compiler-derived.
    n = BRANCH_LOCALS
    lines = ["func branch_dense(mode):", "let total = 0"]
    lines += [f"let v{i} = {i + 1}" for i in range(n)]
    for i in range(n):
        lines += [f"if mode == {i}:", f"return total + v{i}",
                  f"elif mode == {n + i}:", f"v{i} = v{i} + 3",
                  "else:", f"v{i} = v{i} + 7", "end",
                  f"total = total + v{i}"]
    halfway = n // 2
    lines += ["return total", "end", "func main():",
              f"return (branch_dense({2*n}), branch_dense({n+halfway}), branch_dense({halfway}))",
              "end", ""]
    full = n * (n + 1) // 2 + 7 * n
    early = (halfway + 1) * (halfway + 2) // 2 + 7 * halfway
    yield ("branches", "\n".join(lines), f"({full}, {full - 4}, {early})")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler", type=Path, help="explicit candidate/baseline seed")
    parser.add_argument("--keep-work", action="store_true")
    args = parser.parse_args()
    work = None
    success = False
    try:
        seed = (args.compiler or SEED).resolve()
        image = seed.read_bytes()
        require(image[:6] == b"\x7fELF\x02\x01" and image[18:20] == b"\x3e\x00",
                "compiler must be an x86-64 little-endian ELF")
        digest = hashlib.sha256(image).hexdigest()
        if args.compiler is None:
            require(SEED.with_suffix(".seed.sha256").read_text().split()
                    == [digest, "gen1.seed"], "workspace seed checksum mismatch")
        require(os.access("/usr/bin/time", os.X_OK), "GNU /usr/bin/time is required")
        require(Path(f"/proc/self/task/{os.getpid()}/children").is_file(),
                "readable Linux /proc children/status records are required for RSS supervision")
        work = Path(tempfile.mkdtemp(prefix="compiler-metadata-"))
        compiler = work / "compiler"
        compiler.write_bytes(image)
        compiler.chmod(0o700)
        print(f"compiler-metadata: compiler={seed} sha256={digest}; evidence={work}", flush=True)
        print(f"compiler-metadata: RSS ceiling={MAX_RSS_KIB} KiB; "
              f"address-space limit={MAX_ADDRESS_BYTES} bytes", flush=True)
        results = []
        for label, source, answer in cases():
            operations = BRANCH_LOCALS if label == "branches" else OPERATIONS
            directory = work / label
            directory.mkdir()
            (directory / "source.herb").write_text(source)
            result = invoke(["/usr/bin/time", "-f", "%M", "-o", "rss-kib.txt",
                             str(compiler)], directory, "compile")
            require(result == (0, b"0\n", b""), f"{label}: compiler result {result!r}")
            measurement = (directory / "rss-kib.txt").read_text().strip()
            require(measurement.isascii() and measurement.isdecimal() and int(measurement) > 0,
                    f"{label}: missing/invalid RSS measurement: {measurement!r}")
            rss = int(measurement)
            require(rss <= MAX_RSS_KIB, f"{label}: compiler RSS {rss} KiB exceeds {MAX_RSS_KIB}")
            artifact = directory / "a.out"
            require(artifact.is_file() and not artifact.is_symlink()
                    and artifact.read_bytes()[:4] == b"\x7fELF", f"{label}: missing ELF")
            artifact.chmod(0o700)
            result = invoke([str(artifact)], directory, "run")
            require(result == (0, f"{answer}\n".encode(), b""),
                    f"{label}: runtime result {result!r}")
            results.append(dict(case=label, operations=operations, rss_kib=rss,
                                source_bytes=len(source), compiler_sha256=digest,
                                image_sha256=hashlib.sha256(artifact.read_bytes()).hexdigest()))
            (work / "results.json").write_text(json.dumps(results, indent=2) + "\n")
            print(f"PASS: compiler-metadata {label}: {operations} operations; "
                  f"{rss} KiB RSS; {len(source)} source bytes; exact runtime result; "
                  f"image_sha256={results[-1]['image_sha256']}", flush=True)
        success = True
        print(f"PASS: compiler-metadata ({len(results)} bounded compilation/runtime cases)", flush=True)
        return 0
    except (OSError, ValueError) as error:
        print(f"FAIL: compiler-metadata: {error}", file=sys.stderr, flush=True)
        return 1
    finally:
        if work is not None:
            if args.keep_work or not success:
                print(f"compiler-metadata artifacts: {work}", flush=True)
            else:
                shutil.rmtree(work)


if __name__ == "__main__":
    sys.exit(main())
