#!/usr/bin/env python3
"""Stack-headroom guard for the committed seed.

The compiler's type inference recurses once per nesting level; at the default
8 MiB stack the deepest flat sum the compiler survived was about 2,981 terms
(cold audit 2026-10-26, size-headroom). Since 2026-10-27 the compiler
refuses nesting past 2,000 levels with ERR 405, and the conformance case
nesting-flat-sum-2001-refused pins that ceiling from above. This check pins the
headroom from below: it compiles generated programs with an explicit 8 MiB stack
and runs each image against an oracle computed here, so about a 35 percent loss
of headroom (limit below 1,950 terms) goes red while ordinary noise at the edge
(plus or minus one term) does not. Nested ifs at the 2,000-level limit need more
stack than a flat sum (6 to 7 MiB against 5 to 6); nesting-if-1999-compiles is
the case that watches that edge.

--stack-kb N   diagnostic: run with another soft stack limit (regression model).
--compiler P   explicit candidate seed (default: checksum-verified workspace seed).
"""
import argparse
import hashlib
import os
import resource
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SEED = ROOT / "bootstrap" / "seed" / "gen1.seed"
PIN = ROOT / "bootstrap" / "seed" / "gen1.seed.sha256"
DEFAULT_STACK_KB = 8192
FLAT_TERMS = 1950
NEST_DEPTH = 300


def flat(n):
    return "func main():\n    return " + " + ".join(["1"] * n) + "\nend\n", str(n)


def rnest(n):
    e = "1"
    for _ in range(n - 1):
        e = "1 + (" + e + ")"
    return "func main():\n    return " + e + "\nend\n", str(n)


def callnest(n):
    return ("func g(x):\n    return x + 1\nend\nfunc main():\n    return "
            + "g(" * n + "0" + ")" * n + "\nend\n"), str(n)


def ifnest(n):
    lines = ["func main():", "    let x = 1"]
    ind = "    "
    for _ in range(n):
        lines.append(ind + "if x == 1:")
        ind += "  "
    lines.append(ind + "return 7")
    for _ in range(n):
        ind = ind[:-2]
        lines.append(ind + "end")
    lines += ["    return 0", "end"]
    return "\n".join(lines) + "\n", "7"


CASES = [
    ("flat-%d" % FLAT_TERMS, flat(FLAT_TERMS)),
    ("rnest-%d" % NEST_DEPTH, rnest(NEST_DEPTH)),
    ("callnest-%d" % NEST_DEPTH, callnest(NEST_DEPTH)),
    ("ifnest-%d" % NEST_DEPTH, ifnest(NEST_DEPTH)),
]


def limits(stack_kb):
    def apply():
        soft = stack_kb * 1024
        _, hard = resource.getrlimit(resource.RLIMIT_STACK)
        resource.setrlimit(resource.RLIMIT_STACK, (soft, hard))
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    return apply


def verified_seed(path):
    data = path.read_bytes()
    if path == SEED:
        want = PIN.read_text().split()[0]
        got = hashlib.sha256(data).hexdigest()
        if got != want:
            raise SystemExit("seed checksum mismatch: %s != %s" % (got, want))
    if data[:4] != b"\x7fELF":
        raise SystemExit("compiler is not an ELF image: %s" % path)
    return data


def run_case(work, compiler_bytes, name, source, expected, stack_kb, timeout):
    d = work / name
    d.mkdir()
    (d / "compiler").write_bytes(compiler_bytes)
    os.chmod(d / "compiler", 0o700)
    (d / "source.herb").write_text(source)
    (d / "a.out").write_bytes(b"SENTINEL\n")
    t0 = time.monotonic()
    with open(d / "source.herb", "rb") as src:
        comp = subprocess.run(["./compiler"], cwd=d, stdin=src, capture_output=True,
                              timeout=timeout, preexec_fn=limits(stack_kb))
    wall = time.monotonic() - t0
    problems = []
    if comp.returncode != 0:
        problems.append("compiler rc %d" % comp.returncode)
    if comp.stdout != b"0\n":
        problems.append("compiler stdout %r" % comp.stdout[:60])
    if comp.stderr:
        problems.append("compiler stderr %r" % comp.stderr[:120])
    image = (d / "a.out").read_bytes()
    if image[:4] != b"\x7fELF":
        problems.append("no ELF published")
    if not problems:
        os.chmod(d / "a.out", 0o700)
        prog = subprocess.run(["./a.out"], cwd=d, capture_output=True, timeout=timeout)
        if prog.returncode != 0 or prog.stdout.decode(errors="replace").strip() != expected:
            problems.append("program rc %d stdout %r expected %r" % (prog.returncode, prog.stdout[:40], expected))
    return wall, problems


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler", type=Path, default=SEED)
    parser.add_argument("--stack-kb", type=int, default=DEFAULT_STACK_KB)
    parser.add_argument("--timeout", type=float, default=20.0)
    parser.add_argument("--keep-work", action="store_true")
    args = parser.parse_args()
    _, hard = resource.getrlimit(resource.RLIMIT_STACK)
    if hard != resource.RLIM_INFINITY and hard < args.stack_kb * 1024:
        print("stack-headroom: hard stack limit below %d KB" % args.stack_kb, file=sys.stderr)
        return 1
    compiler_bytes = verified_seed(args.compiler.resolve())
    failures = 0
    with tempfile.TemporaryDirectory(prefix="herbert-stack-headroom.") as tmp:
        work = Path(tmp)
        for name, (source, expected) in CASES:
            wall, problems = run_case(work, compiler_bytes, name, source, expected, args.stack_kb, args.timeout)
            status = "PASS" if not problems else "FAIL"
            print("stack-headroom: %s %-14s stack=%dK %.2fs%s" % (status, name, args.stack_kb, wall,
                  "" if not problems else " (" + "; ".join(problems) + ")"))
            failures += bool(problems)
        if args.keep_work:
            print("stack-headroom: work retained at", work)
            os.rename(work, work.with_name(work.name + ".kept"))
    if failures:
        print("stack-headroom: %d of %d cases failed" % (failures, len(CASES)), file=sys.stderr)
        return 1
    print("stack-headroom: %d/%d passed at %d KB stack" % (len(CASES), len(CASES), args.stack_kb))
    return 0


if __name__ == "__main__":
    sys.exit(main())
