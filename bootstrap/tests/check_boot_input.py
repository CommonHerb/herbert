#!/usr/bin/env python3
"""Focused link67 checks. Host expectations describe bytes/layout, not a guest interpreter.

Each compile and boot has a fresh directory. Shell cleanup retains these through
the existing kernel evidence collector; no attempt overwrites an earlier stream.
"""
import argparse
from datetime import datetime, timezone
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import signal
import struct
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
from hexview_long64 import ProtocolError, run_viewer

MIB = 1024 * 1024
GOOD = b"\xde\x00\xad"
BAD_INPUT = b"BI\n\xde\x01\xad"


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def identity(path):
    with path.open("rb") as source:
        return {"bytes": path.stat().st_size,
                "sha256": hashlib.file_digest(source, "sha256").hexdigest()}


def record(path, data):
    path.write_text(json.dumps(data, indent=2) + "\n")


def execute(command, directory, timeout, stem, stdin=None):
    """Record actual status, including timeout; stop children before evidence cleanup."""
    receipt = {"command": command, "cwd": str(directory),
               "started_utc": datetime.now(timezone.utc).isoformat()}
    process = None
    try:
        with (directory / (stem + ".stdout")).open("wb") as out, \
                (directory / (stem + ".stderr")).open("wb") as err:
            process = subprocess.Popen(command, cwd=directory, stdin=stdin,
                                       stdout=out, stderr=err, start_new_session=True)
            try:
                return process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                receipt["timeout"] = timeout
                raise
    finally:
        if process is not None:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
            receipt["exit"] = process.returncode
        receipt["finished_utc"] = datetime.now(timezone.utc).isoformat()
        record(directory / (stem + ".json"), receipt)


def compile_image(work, compiler, label, source):
    directory = work / ("compile-" + label)
    directory.mkdir()
    probe = directory / "source.herb"
    probe.write_text(source)
    with probe.open("rb") as stdin:
        status = execute([str(compiler)], directory, 60, "compile", stdin)
    require((status, (directory / "compile.stdout").read_bytes(),
             (directory / "compile.stderr").read_bytes()) == (0, b"0\n", b""),
            f"{label}: compiler did not return the exact success transcript")
    image = directory / "a.out"
    require(image.is_file() and image.read_bytes()[:4] == b"\x7fELF", f"{label}: missing ELF")
    record(directory / "identity.json", {"source": identity(probe), "image": identity(image)})
    return image


def layout(image, uses_buffer=False):
    """Derive guards/stack from file extent, never from the reservation being checked."""
    raw = image.read_bytes()
    require(len(raw) >= 84 and raw[:7] == b"\x7fELF\x01\x01\x01", "not ELF32 little endian")
    header = struct.unpack_from("<HHIIIIIHHHHHH", raw, 16)
    require(header[0:2] == (2, 3) and header[4] == 52
            and header[7:10] == (52, 32, 1), "unexpected ELF header/program table")
    kind, offset, vaddr, paddr, filesz, memsz, flags, align = struct.unpack_from("<8I", raw, 52)
    require((kind, offset, vaddr, paddr) == (1, 4096, 0x100000, 0x100000)
            and filesz >= 4096 and len(raw) >= offset + filesz, "unexpected load segment")
    first_guard = ((paddr + filesz + 2 * MIB - 1) // (2 * MIB)) * (2 * MIB)
    stack_top = first_guard + (8 if uses_buffer else 4) * MIB
    guards = {first_guard // (2 * MIB)}
    if uses_buffer:
        guards.add(first_guard // (2 * MIB) + 2)
    entries = struct.unpack_from("<512Q", raw, offset + filesz - 4096)
    require(all(value == (0 if i in guards else i * 2 * MIB + 131)
                for i, value in enumerate(entries)), "guard/identity mappings disagree with file-derived layout")
    require(paddr + memsz == stack_top <= 64 * MIB, "ELF does not reserve the full relocated stack")
    return {"entry": header[3], "filesz": filesz, "memsz": memsz, "stack_top": stack_top,
            "buffer": uses_buffer, "guards": sorted(guards)}


def qemu_boot(work, binary, label, image, modules, expected, *, accel="tcg", inject=None,
              stack_top=None, reject=False, timeout=120):
    directory = work / label
    directory.mkdir()
    shutil.copyfile(image, directory / "kernel.elf")
    for i, data in enumerate(modules):
        (directory / f"input{i}.bin").write_bytes(data)
    command = [binary, "-kernel", "kernel.elf", "-m", "64M", "-display", "none",
               "-monitor", "none", "-nic", "none", "-no-reboot", "-serial", "file:serial.bin",
               "-debugcon", "file:debugcon.bin", "-device", "isa-debug-exit,iobase=0xf4,iosize=0x04",
               "-accel", accel, "-cpu", "host" if accel == "kvm" else "qemu64"]
    if modules:
        command += ["-initrd", ",".join(f"input{i}.bin" for i in range(len(modules)))]
    receipt = {"command": command, "cwd": str(directory), "image": identity(directory / "kernel.elf"),
               "modules": [identity(directory / f"input{i}.bin") for i in range(len(modules))],
               "expected_serial_hex": expected.hex(), "expected_debugcon_hex": (BAD_INPUT if reject else GOOD).hex(),
               "started_utc": datetime.now(timezone.utc).isoformat(), "status": "incomplete"}
    process = None
    try:
        if inject:
            sock = directory / "gdb.sock"
            command += ["-chardev", f"socket,path={sock},server=on,wait=off,id=gdb0", "-gdb", "chardev:gdb0", "-S"]
        with (directory / "qemu.stdout").open("wb") as out, (directory / "qemu.stderr").open("wb") as err:
            process = subprocess.Popen(command, cwd=directory, stdin=subprocess.DEVNULL,
                                       stdout=out, stderr=err, start_new_session=True)
            if inject:
                deadline = time.monotonic() + 10
                while not sock.exists() and process.poll() is None and time.monotonic() < deadline:
                    time.sleep(0.02)
                require(sock.exists(), "QEMU did not expose its private GDB socket")
                entry = struct.unpack_from("<I", image.read_bytes(), 24)[0]
                edits = {
                    "magic": "set $eax = 0\n",
                    "info-span": "set $ebx = 0x9fff0\n",
                    "descriptor-span": "set {unsigned int} ($mbi + 24) = 0x9fff8\n",
                    "stack-overlap": f"set {{unsigned int}} $mods = {stack_top - 16}\nset {{unsigned int}} ($mods + 4) = {stack_top}\n",
                    "past-ram": f"set {{unsigned int}} ($mods + 4) = {64 * MIB + 1}\n",
                }
                commands = f"""set pagination off
set confirm off
set remotetimeout 10
target remote {sock}
hbreak *{entry:#x}
continue
if $pc != {entry:#x}
  quit 3
end
if (unsigned int)$eax != 0x2badb002
  quit 4
end
set $mbi = (unsigned int)$ebx
set $mods = *(unsigned int*)($mbi + 24)
printf "ENTRY eax=%#x ebx=%#x modules=%#x start=%#x end=%#x\\n", $eax, $ebx, $mods, *(unsigned int*)$mods, *(unsigned int*)($mods+4)
{edits[inject]}printf "INJECTED {inject} eax=%#x ebx=%#x modules=%#x start=%#x end=%#x\\n", $eax, $ebx, *(unsigned int*)($mbi+24), *(unsigned int*)$mods, *(unsigned int*)($mods+4)
delete breakpoints
detach
quit
"""
                (directory / "inject.gdb").write_text(commands)
                status = execute(["gdb", "--batch", "--nx", "-x", "inject.gdb"], directory, 30, "gdb", subprocess.DEVNULL)
                require(status == 0 and f"INJECTED {inject} ".encode() in (directory / "gdb.stdout").read_bytes(),
                        f"{inject}: GDB did not attest the entry-time mutation")
            receipt["qemu_exit"] = process.wait(timeout=timeout)
        raw = (directory / "debugcon.bin").read_bytes()
        serial = (directory / "serial.bin").read_bytes()
        receipt.update(debugcon_hex=raw.hex(), serial=identity(directory / "serial.bin"))
        # Shared epilogue: ((grade ^ 0x31) << 1) | 1, hence grade 1 exits 97.
        require(receipt["qemu_exit"] == (97 if reject else 99)
                and raw == (BAD_INPUT if reject else GOOD), f"{label}: wrong completion {raw.hex()}/{receipt['qemu_exit']}")
        require(not (directory / "qemu.stderr").read_bytes(), f"{label}: unexpected emulator stderr")
        require(serial == expected, f"{label}: serial bytes differ")
        receipt["status"] = "success"
    except BaseException as error:
        receipt["error"] = f"{type(error).__name__}: {error}"
        raise
    finally:
        if process is not None and process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
        if process is not None:
            receipt["final_process_exit"] = process.returncode
        receipt["finished_utc"] = datetime.now(timezone.utc).isoformat()
        record(directory / "run.json", receipt)
    print(f"PASS folio {label}", flush=True)


def bochs_boot(work, label, image, data, expected):
    directory = work / label
    directory.mkdir()
    shutil.copyfile(image, directory / "kernel.elf")
    (directory / "input.bin").write_bytes(data)
    helper = ROOT / "bootstrap/tests/bochs_f2_harness.sh"
    config = 'set timeout=0\nset default=0\nmenuentry "folio" {\n multiboot /boot/kernel.elf\n module --nounzip /boot/input.bin\n boot\n}\n'
    (directory / "grub.cfg").write_text(config)
    receipt = {"image": identity(directory / "kernel.elf"), "input": identity(directory / "input.bin"),
               "expected_serial_hex": expected.hex(), "status": "incomplete"}
    try:
        # Remove this marker only after the checked builder reports full cleanup.
        (work / "PRESERVE").write_text(str(directory) + "\n")
        status = execute(["bash", "-c", 'unset CDPATH; source "$1" || exit 1; f2__disk_build_class "$2" "$3" "$2/kernel.elf:boot/kernel.elf" "$2/input.bin:boot/input.bin"',
                          "folio-disk", str(helper), str(directory), config], directory, 120, "disk-build", subprocess.DEVNULL)
        require(status == 0 and not (directory / "disk-build.stdout").read_bytes(), "Bochs disk build failed")
        (work / "PRESERVE").unlink()
        status = execute(["bash", "-c", 'unset CDPATH; source "$1" || exit 1; f2__bios_find || exit 1; f2__boot "$2" 120 64 "com1: enabled=1, mode=file, dev=serial.bin"',
                          "folio-bochs", str(helper), str(directory)], directory, 135, "boot", subprocess.DEVNULL)
        raw = (directory / "bochs_out.txt").read_bytes()
        before, found, after = raw.partition(GOOD)
        text_only = lambda value: all(b in (9, 10, 13) or 32 <= b < 127 for b in value)
        require(status == 1 and found and text_only(before) and text_only(after)
                and b"shutdown requested" in after, "Bochs did not attest exactly one successful completion")
        serial = directory / "serial.bin"
        require((serial.read_bytes() if serial.exists() else b"") == expected, f"{label}: serial bytes differ")
        receipt.update(status="success", boot_exit=status, serial_exists=serial.exists())
    except BaseException as error:
        receipt["error"] = f"{type(error).__name__}: {error}"
        raise
    finally:
        record(directory / "run.json", receipt)
    print(f"PASS folio {label}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("normal", "mutation"), required=True)
    parser.add_argument("--compiler", type=Path, required=True)
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--emit-header", required=True)
    args = parser.parse_args()
    require(args.emit_header == "-- emit: multiboot32-long64", "wrong probe target")
    work, compiler = args.work.resolve(), args.compiler.resolve()
    declaration = args.emit_header + "\n"
    provenance = {"compiler": identity(compiler), "backend": identity(ROOT / "stack/native_compile_fragment.herb"),
                  "checker": identity(Path(__file__)), "mode": args.mode}
    for name, command in {"head": ["git", "rev-parse", "HEAD"], "working_tree": ["git", "status", "--porcelain"]}.items():
        provenance[name] = subprocess.check_output(command, cwd=ROOT).decode()
    record(work / "PROVENANCE.json", provenance)
    viewer = compile_image(work, compiler, "viewer", (ROOT / "examples/hexview_long64.herb").read_text())
    geometry = layout(viewer)
    record(work / "viewer-layout.json", geometry)
    # Starts with a real gzip stream: GRUB must deliver it verbatim, then every byte value.
    binary = gzip.compress(b"raw boot file\n", mtime=0) + bytes(range(256)) + b"\xff\x00\x7f"
    render = lambda data: b"".join(data[i:i+16].hex(" ").encode() + b"\n" for i in range(0, len(data), 16))
    qemu = shutil.which("qemu-system-x86_64")
    require_emu = os.environ.get("KERNEL_CODEGEN_REQUIRE_EMU", "0") == "1"
    if args.mode == "mutation":
        mutant = work / "short-reservation.elf"
        changed = bytearray(viewer.read_bytes())
        struct.pack_into("<I", changed, 72, geometry["filesz"] + 16384)
        mutant.write_bytes(changed)
        try:
            layout(mutant)
        except AssertionError as error:
            require(str(error) == "ELF does not reserve the full relocated stack", "mutation failed an unrelated layout condition")
        else:
            raise AssertionError("reduced reservation passed the normal layout check")
        print("PASS folio reduced reservation rejected by file-derived layout", flush=True)
        if qemu:
            qemu_boot(work, qemu, "mutation-control", viewer, [b"\xff"], b"ff\n")
            supplied = work / "mutation-input.bin"
            supplied.write_bytes(b"\xff")
            published = io.BytesIO()
            attempt = work / "mutation-short-reservation"
            try:
                run_viewer(mutant, supplied, published, qemu=qemu, evidence=attempt)
            except ProtocolError:
                pass
            else:
                raise AssertionError("viewer adapter accepted the reduced reservation")
            refusal = json.loads((attempt / "run.json").read_text())
            require(refusal["qemu_exit"] == 97 and refusal["status"] == "failure"
                    and (attempt / "debugcon.bin").read_bytes() == BAD_INPUT
                    and not (attempt / "qemu.stderr").read_bytes()
                    and not (attempt / "serial.bin").read_bytes()
                    and published.getvalue() == b"",
                    "mutation lacked an explicit boot-input refusal or published output")
            print("PASS folio reservation refusal through adapter; no output published", flush=True)
        else:
            require(not require_emu, "QEMU required for mutation witness")
            print("SKIP folio mutation boot: QEMU unavailable", flush=True)
        return
    count = len(binary)
    calls = compile_image(work, compiler, "calls-eof", declaration + f"""func pull(): return boot_read() end
func relay(n):
    if n == 0:
        if pull() != 256: return 1 end
        if pull() != 256: return 2 end
        return 0
    end
    let b = pull()
    if b == 256: return 3 end
    let out = output_byte(b)
    return relay(n - 1)
end
func main(): return relay({count}) * 4294967296 end
""")
    single = compile_image(work, compiler, "single", declaration + """func main():
    if boot_read() != 255: return 4294967296 end
    if boot_read() != 256: return 8589934592 end
    if boot_read() != 256: return 12884901888 end
    let out = output_byte(83)
    return 0
end
""")
    buffer = compile_image(work, compiler, "buffer", declaration + """func main():
    let base = bufbase()
    let saved = bufset(base, 0, boot_read())
    if boot_read() != 0: return 4294967296 end
    if bufget(base, 0) != 255: return 8589934592 end
    if boot_read() != 256: return 12884901888 end
    if boot_read() != 256: return 17179869184 end
    let out = output_byte(66)
    return 0
end
""")
    large = bytes(range(256)) * 8193 + b"\xff"
    large_probe = compile_image(work, compiler, "large", declaration + f"""func pull(): return boot_read() end
func scan(n, sum):
    let b = pull()
    if b == 256:
        if n != {len(large)}: return 1 end
        if sum != {sum(large)}: return 2 end
        if pull() != 256: return 3 end
        let out = output_byte(76)
        return 0
    end
    return scan(n + 1, sum + b)
end
func main(): return scan(0, 0) * 4294967296 end
""")
    for label, image, uses_buffer in [("calls-eof", calls, False), ("single", single, False),
                                       ("buffer", buffer, True), ("large", large_probe, False)]:
        record(work / (label + "-layout.json"), layout(image, uses_buffer))
    print("PASS folio file-derived reservations and guard mappings, with and without buffer", flush=True)
    if qemu:
        require(shutil.which("gdb"), "GDB required for boot metadata checks")
        supplied = work / "viewer-input.bin"
        supplied.write_bytes(binary)
        published = io.BytesIO()
        run_viewer(viewer, supplied, published, qemu=qemu, evidence=work / "tcg-viewer")
        require(published.getvalue() == render(binary), "viewer adapter published incorrect bytes")
        print("PASS folio tcg-viewer through the file adapter", flush=True)
        qemu_boot(work, qemu, "tcg-empty", viewer, [b""], b"")
        qemu_boot(work, qemu, "tcg-missing", viewer, [], b"", reject=True)
        qemu_boot(work, qemu, "tcg-multiple", viewer, [b"a", b"b"], b"", reject=True)
        qemu_boot(work, qemu, "tcg-calls-eof", calls, [binary], binary)
        qemu_boot(work, qemu, "tcg-single", single, [b"\xff"], b"S")
        qemu_boot(work, qemu, "tcg-buffer", buffer, [b"\xff\x00"], b"B")
        qemu_boot(work, qemu, "tcg-large", large_probe, [large], b"L")
        for corruption in ("magic", "info-span", "descriptor-span", "stack-overlap", "past-ram"):
            qemu_boot(work, qemu, "tcg-" + corruption, viewer, [b"\xff"], b"", inject=corruption,
                      stack_top=geometry["stack_top"], reject=True)
        if os.access("/dev/kvm", os.R_OK | os.W_OK):
            qemu_boot(work, qemu, "kvm-viewer", viewer, [binary], render(binary), accel="kvm")
            qemu_boot(work, qemu, "kvm-calls-eof", calls, [binary], binary, accel="kvm")
        else:
            print("SKIP folio KVM: /dev/kvm unavailable", flush=True)
    else:
        require(not require_emu, "QEMU required")
        print("SKIP folio QEMU/GDB/KVM: QEMU unavailable", flush=True)
    needed = ("bochs", "parted", "losetup", "mkfs.vfat", "grub-install", "xvfb-run", "sudo")
    bochs = all(shutil.which(name) for name in needed)
    bochs = bochs and subprocess.run(["sudo", "-n", "true"], capture_output=True).returncode == 0
    if bochs:
        bochs_boot(work, "bochs-viewer", viewer, binary, render(binary))
        bochs_boot(work, "bochs-empty", viewer, b"", b"")
    else:
        require(not require_emu, "Bochs disk/boot prerequisites required")
        print("SKIP folio Bochs: prerequisites unavailable", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, OSError, ProtocolError, subprocess.SubprocessError) as error:
        print(f"FAIL: folio: {error}", file=sys.stderr)
        raise SystemExit(1)
