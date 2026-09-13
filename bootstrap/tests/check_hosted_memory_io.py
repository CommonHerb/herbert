#!/usr/bin/env python3
"""Exercise the unsafe Linux boundary and safe reusable bytes in real programs.

Python is test orchestration only. Each probe is compiled by Herbert and uses
Herbert's emitted Linux syscalls without a foreign runtime or shared library.
Expected outputs, error codes, byte boundaries and mmap file offset are authored
here independently of the compiler. This is not an arbitrary-syscall safety test:
linux_syscall6 and buffer_address deliberately give trusted code raw OS access.
"""

from pathlib import Path
import argparse
import hashlib
import select
import shutil
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[2]
FILL = """func fill(b, n):
    if n == 0:
        return b
    end
    do append(b, 0)
    return fill(b, n - 1)
end
"""


def require(actual, expected, label):
    if actual != expected:
        raise AssertionError(f"{label}: expected {expected!r}, got {actual!r}")


def process_result(result):
    return result.returncode, result.stdout, result.stderr


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler", type=Path, help="explicit candidate seed")
    parser.add_argument("--keep-work", action="store_true")
    args = parser.parse_args()
    seed = args.compiler or ROOT / "bootstrap/seed/gen1.seed"
    seed_bytes = seed.read_bytes()
    digest = hashlib.sha256(seed_bytes).hexdigest()
    if args.compiler is None:
        require(digest, seed.with_suffix(".seed.sha256").read_text().split()[0], "seed checksum")
    work = Path(tempfile.mkdtemp(prefix="herbert-hosted-memory-"))
    print(f"hosted memory/I/O compiler SHA-256: {digest}; evidence: {work}", flush=True)
    compiler = work / "compiler"
    compiler.write_bytes(seed_bytes)
    compiler.chmod(0o700)
    passed = 0

    def compile_probe(label, source, reject_code=None):
        nonlocal passed
        directory = work / label
        directory.mkdir()
        (directory / "source.herb").write_text(source)
        result = subprocess.run([str(compiler)], input=source.encode(), cwd=directory,
                                capture_output=True, timeout=30)
        (directory / "compiler.stdout").write_bytes(result.stdout)
        (directory / "compiler.stderr").write_bytes(result.stderr)
        executable = directory / "a.out"
        if reject_code is not None:
            require((result.returncode, result.stdout, executable.exists()), (1, b"", False), label)
            if f"(ERR {reject_code})".encode() not in result.stderr:
                raise AssertionError(f"{label}: wrong diagnostic: {result.stderr!r}")
            passed += 1
            print(f"PASS {label}: rejected ERR {reject_code}", flush=True)
            return None
        require(process_result(result), (0, b"0\n", b""), label + " compile")
        require(executable.read_bytes()[:4], b"\x7fELF", label + " ELF")
        executable.chmod(0o700)
        return executable

    def run_probe(label, source, stdout, *, stdin=b"", status=0, stderr=b""):
        nonlocal passed
        executable = compile_probe(label, source)
        result = subprocess.run([str(executable)], input=stdin, cwd=executable.parent,
                                capture_output=True, timeout=15)
        (executable.parent / "runtime.stdout").write_bytes(result.stdout)
        (executable.parent / "runtime.stderr").write_bytes(result.stderr)
        require(process_result(result), (status, stdout, stderr), label)
        passed += 1
        print(f"PASS {label}", flush=True)

    success = False
    try:
        run_probe("bytes-alias-and-snapshot", FILL + """func setbyte(b, k, v):
    return buffer_set(b, k, v)
end
func main():
    let b = fill(new_buffer(), 4)
    let before = freeze(b)
    let a = b
    let x = setbyte(a, 0, 255)
    let z = setbyte(b, 3, 128)
    return (x, z, buffer_get(b, 0), buffer_get(a, 3), buffer_length(b), index(before, 0), buffer_length(new_buffer()))
end
""", b"(255, 128, 255, 128, 4, 0, 0)\n")
        run_probe("kernel-read-writes-backing", FILL + """func main():
    let b = fill(new_buffer(), 4)
    let n = linux_syscall6(0, 0, buffer_address(b), 4, 0, 0, 0)
    let w = linux_syscall6(1, 1, buffer_address(b) + 1, 2, 0, 0, 0)
    return (n, w, buffer_get(b, 0), buffer_get(b, 3), buffer_length(b))
end
""", b"\x00\xff(4, 2, 65, 128, 4)\n", stdin=b"A\x00\xff\x80")
        run_probe("linux-raw-errors", """func main():
    return (linux_syscall6(99999, 0, 0, 0, 0, 0, 0), linux_syscall6(3, 99999, 0, 0, 0, 0, 0), linux_syscall6(1, 1, 0, 1, 0, 0, 0))
end
""", b"(18446744073709551578, 18446744073709551607, 18446744073709551602)\n")

        # mmap exercises the non-C ABI registers r10/r8/r9 with distinct flags,
        # a live inherited descriptor and a nonzero page-aligned file offset.
        mmap_source = """func main():
    let p = linux_syscall6(9, 0, 4096, 1, 2, FD, 4096)
    if p >= 0 - 4095:
        do process_exit(2)
        return 0
    end
    let n = linux_syscall6(1, 1, p, 4, 0, 0, 0)
    let closed = linux_syscall6(3, FD, 0, 0, 0, 0, 0)
    let freed = linux_syscall6(11, p, 4096, 0, 0, 0, 0)
    return n + closed + freed
end
"""
        backing = work / "mmap.data"
        backing.write_bytes(b"x" * 4096 + b"MAP!" + b"y" * 4092)
        with backing.open("rb") as file:
            executable = compile_probe("syscall-six-argument-order", mmap_source.replace("FD", str(file.fileno())))
            result = subprocess.run([str(executable)], capture_output=True, timeout=15, pass_fds=(file.fileno(),))
            require(process_result(result), (0, b"MAP!4\n", b""), "mmap offset/register order")
        passed += 1
        print("PASS syscall-six-argument-order", flush=True)

        for label, expression, diagnostic in [
            ("get-past-end", "buffer_get(b, 2)", "get: position 2 out of range (count 2)"),
            ("get-negative", "buffer_get(b, 0 - 1)", "get: position 18446744073709551615 out of range (count 2)"),
            ("set-past-end", "buffer_set(b, 2, 7)", "get: position 2 out of range (count 2)"),
            ("set-negative", "buffer_set(b, 0 - 1, 7)", "get: position 18446744073709551615 out of range (count 2)"),
            ("set-nonbyte", "buffer_set(b, 0, 256)", "append: byte value 256 out of range 0..255"),
            ("set-negative-byte", "buffer_set(b, 0, 0 - 1)", "append: byte value 18446744073709551615 out of range 0..255"),
        ]:
            source = "func main():\n    let b = new_buffer()\n    do append(b, 0)\n    do append(b, 0)\n    return " + expression + "\nend\n"
            run_probe(label, source, b"", stderr=f"herbert: line 5: {diagnostic}\n".encode(), status=1)

        builtins = {
            "linux_syscall6": ["1", "1", "0", "0", "0", "0", "0"],
            "buffer_address": ["new_buffer()"],
            "buffer_length": ["new_buffer()"],
            "buffer_get": ["new_buffer()", "0"],
            "buffer_set": ["new_buffer()", "0", "0"],
        }
        for name, valid_args in builtins.items():
            for suffix, arglist in [("too-few", valid_args[:-1]), ("too-many", valid_args + ["0"])]:
                compile_probe(name + "-" + suffix, f"func main():\n    return {name}({', '.join(arglist)})\nend\n", 420)
            for idx in range(len(valid_args)):
                bad_args = valid_args.copy()
                bad_args[idx] = "true"
                compile_probe(f"{name}-type-{idx}", f"func main():\n    return {name}({', '.join(bad_args)})\nend\n", 430)
            compile_probe(name + "-void-use", f"func main():\n    do {name}({', '.join(valid_args)})\n    return 0\nend\n", 404)
            compile_probe(name + "-reserved", f"func {name}():\n    return 0\nend\nfunc main():\n    return 0\nend\n", 429)

        for target, code in [("multiboot32", 451), ("multiboot32-long64", 502)]:
            # These targets have independent whitelist/depth paths. The scalar
            # syscall alone excludes rejection merely due to new_buffer.
            source = f"-- emit: {target}\nfunc main():\n    return linux_syscall6(39, 0, 0, 0, 0, 0, 0)\nend\n"
            compile_probe("reject-target-" + target, source, code)
        compile_probe("reject-target-module-chiefturbo", """-- emit: module-chiefturbo
func main():
    let input = sys_read()
    let sent = sys_write(input)
    let read = bufget(bufbase(), 0)
    return linux_syscall6(39, 0, 0, 0, 0, 0, 0)
end
""", 595)

        sustained = compile_probe("sustained-reuse", FILL + """func update(b, delay, i):
    if i == 2000000:
        return i
    end
    let written = buffer_set(b, i % 4096, i % 256)
    if buffer_get(b, i % 4096) != written:
        do process_exit(2)
        return 0
    end
    if i % 1000 == 0:
        let slept = linux_syscall6(35, buffer_address(delay), 0, 0, 0, 0, 0)
        if slept != 0:
            do process_exit(3)
            return 0
        end
    end
    return update(b, delay, i + 1)
end
func main():
    let b = fill(new_buffer(), 4096)
    let delay = fill(new_buffer(), 16)
    let d0 = buffer_set(delay, 8, 128)
    let d1 = buffer_set(delay, 9, 132)
    let d2 = buffer_set(delay, 10, 30)
    let ready = stderr_write("ready\\n")
    return update(b, delay, 0)
end
""")
        proc = subprocess.Popen([str(sustained)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        samples = []
        started = time.monotonic()
        try:
            if not select.select([proc.stderr], [], [], 5)[0]:
                raise AssertionError("sustained update did not become ready")
            require(proc.stderr.readline(), b"ready\n", "sustained ready")
            while proc.poll() is None:
                if time.monotonic() - started > 15:
                    raise AssertionError("sustained update timeout")
                try:
                    status = Path(f"/proc/{proc.pid}/status").read_text()
                    fields = {line.split()[0].rstrip(":"): int(line.split()[1])
                              for line in status.splitlines() if line.startswith(("VmRSS:", "VmSize:", "VmStk:"))}
                    if len(fields) == 3:
                        samples.append(fields)
                except FileNotFoundError:
                    break
                time.sleep(0.05)
            stdout, stderr = proc.communicate(timeout=2)
            require((proc.returncode, stdout, stderr), (0, b"2000000\n", b""), "sustained result")
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.communicate()
        if len(samples) < 20:
            raise AssertionError(f"too few memory samples: {len(samples)}")
        rss = [sample["VmRSS"] for sample in samples[2:]]
        if max(rss) - min(rss) > 256:
            raise AssertionError(f"resident memory grew: {min(rss)}..{max(rss)} KiB")
        require(len({sample["VmSize"] for sample in samples}), 1, "stable virtual size")
        require(len({sample["VmStk"] for sample in samples}), 1, "stable stack mapping")
        (sustained.parent / "memory.tsv").write_text("VmRSS_KiB\tVmSize_KiB\tVmStk_KiB\n" + "".join(f"{s['VmRSS']}\t{s['VmSize']}\t{s['VmStk']}\n" for s in samples))
        passed += 1
        print(f"PASS sustained-reuse: 2,000,000 writes+reads, {len(samples)} samples, RSS {min(rss)}..{max(rss)} KiB; stable virtual/stack mappings", flush=True)
        print(f"hosted memory/I/O: {passed} checks passed", flush=True)
        success = True
    finally:
        if success and not args.keep_work:
            shutil.rmtree(work)
        else:
            print(f"retained evidence: {work}", flush=True)


if __name__ == "__main__":
    main()
