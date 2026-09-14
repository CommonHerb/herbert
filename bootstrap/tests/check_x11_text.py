#!/usr/bin/env python3
"""Exercise the owned X11 text queue with a Herbert-compiled probe on private Xvfb.

Python/libX11/libXtst/Xvfb are independent test tools. The probe is compiled
only by the committed Herbert seed and links no foreign runtime or library.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import signal
import struct
import subprocess
import tempfile
import time

import check_desktop as desktop

ROOT = Path(__file__).resolve().parents[2]
PROBE = r"""
func probe_write(b):
    let n = linux_syscall6(1, 1, buffer_address(b), 16, 0, 0, 0)
    return x11_need(n == 16, "probe: output failed\n")
end
func probe_keys(c, b):
    if not x11_next_key(c, b): return 0 end
    let wrote = probe_write(b)
    return probe_keys(c, b)
end
func probe_loop(c, b, pause):
    let got = x11_events(c)
    if x11_closed(c):
        let closed = x11_close(c)
        do process_exit(0)
        return 0
    end
    let tag = linux_put32(b, 0, 4294967295)
    let pending = linux_put32(b, 4, linux_u32(c.0, 112))
    let wanted = linux_put32(b, 8, linux_u32(c.0, 96))
    let sequence = linux_put32(b, 12, linux_u64(c.0, 8))
    let wrote = probe_write(b)
    let keys = probe_keys(c, b)
    let slept = linux_syscall6(35, buffer_address(pause), 0, 0, 0, 0, 0)
    return probe_loop(c, b, pause)
end
func main():
    let c = x11_open(640, 480, "Herbert - Key queue probe")
    let enabled = x11_enable_text(c)
    let b = linux_buffer(16)
    let pause = linux_buffer(16)
    let seconds = linux_put64(pause, 0, 0)
    let nanos = linux_put64(pause, 8, 100000000)
    return probe_loop(c, b, pause)
end
"""


def run(evidence):
    result = {"status": "RUNNING", "mode": "private-Xvfb-XTest"}
    app = None
    old_title = desktop.TITLE
    desktop.TITLE = b"Herbert - Key queue probe"
    try:
        seed = ROOT / "bootstrap/seed/gen1.seed"
        expected = (ROOT / "bootstrap/seed/gen1.seed.sha256").read_text().split()[0]
        result["compiler_seed_sha256"] = hashlib.sha256(seed.read_bytes()).hexdigest()
        assert result["compiler_seed_sha256"] == expected, "committed seed hash mismatch"
        source = b"\n".join((ROOT / name).read_bytes() for name in ("lib/linux.herb", "lib/x11.herb")) + b"\n" + PROBE.encode()
        (evidence / "source.herb").write_bytes(source)
        result["source_sha256"] = hashlib.sha256(source).hexdigest()
        compiler = evidence / "compiler"
        shutil.copyfile(seed, compiler)
        compiler.chmod(0o755)
        compiled = subprocess.run([str(compiler)], input=source, cwd=evidence,
                                  capture_output=True, timeout=30)
        (evidence / "compiler.stdout").write_bytes(compiled.stdout)
        (evidence / "compiler.stderr").write_bytes(compiled.stderr)
        assert compiled.returncode == 0 and compiled.stdout == b"0\n" and not compiled.stderr, (compiled.returncode, compiled.stdout, compiled.stderr)
        image = evidence / "a.out"
        image.chmod(0o755)
        result["image_sha256"] = hashlib.sha256(image.read_bytes()).hexdigest()
        args = argparse.Namespace(image=image, desktop=False)

        def records():
            raw = (evidence / "probe.stdout").read_bytes()
            return list(struct.iter_unpack("<IIII", raw[:len(raw) // 16 * 16]))

        def await_condition(predicate, explanation):
            deadline = time.monotonic() + 8
            while time.monotonic() < deadline:
                current = records()
                if predicate(current):
                    return current
                assert app.process.poll() is None, ("probe exited", app.process.returncode)
                time.sleep(0.005)
            raise AssertionError(explanation)

        def stopped():
            app.process.send_signal(signal.SIGSTOP)
            deadline = time.monotonic() + 2
            while "\nState:\tT" not in Path(f"/proc/{app.process.pid}/status").read_text():
                assert time.monotonic() < deadline, "probe did not stop"
                time.sleep(0.005)

        with desktop.private_display(evidence) as display:
            connection = desktop.XConnection(display)
            try:
                app = desktop.Application(args, connection, display, evidence, "probe")
                connection.focus(app.window)
                time.sleep(0.15)
                code = connection.x.XKeysymToKeycode(connection.display, connection.x.XStringToKeysym(b"a"))
                other = connection.x.XKeysymToKeycode(connection.display, connection.x.XStringToKeysym(b"c"))

                def burst(count):
                    for index in range(count):
                        keycode = code if index % 2 == 0 else other
                        assert connection.xtst.XTestFakeKeyEvent(connection.display, keycode, 1, 0)
                        assert connection.xtst.XTestFakeKeyEvent(connection.display, keycode, 0, 0)
                    connection.x.XSync(connection.display, 0)

                stopped()
                burst(40)
                connection.focus(connection.root)
                connection.focus(app.window)
                connection.swap_keys("a", "b")
                burst(260)
                # This second notification lies beyond the first queue/drain
                # batch. The first batch requests a map; the next encounters
                # this notification with that reply still behind queued input.
                connection.swap_keys("a", "b")
                burst(300)
                app.process.send_signal(signal.SIGCONT)
                current = await_condition(lambda rs: len([r for r in rs if r[0] != 0xffffffff]) >= 600,
                                          "600 presses not preserved")
                keys = [r for r in current if r[0] != 0xffffffff]
                assert [r[0] for r in keys] == [97, 99] * 300, (len(keys), [r[0] for r in keys])
                current = await_condition(lambda rs: len({r[1] for r in rs if r[0] == 0xffffffff and r[1]}) >= 2
                                          and rs[-1][0] == 0xffffffff and rs[-1][1] == 0,
                                          "second refresh lost while first reply pending")
                assert any(r[0] == 0xffffffff and r[1] and r[2] for r in current), "no refresh notification observed while a reply was pending"
                result["notification_while_reply_pending"] = True
                result["queued_press_count"] = len(keys)
                result["queued_symbols_in_order"] = "a,c repeated 300 times"
                result["pending_sequences"] = sorted({r[1] for r in current if r[0] == 0xffffffff and r[1]})
                # A completed runtime remap changes subsequent symbols.
                before = len(current)
                connection.swap_keys("a", "b")
                await_condition(lambda rs: any(r[0] == 0xffffffff and r[1] for r in rs[before:])
                                and rs[-1][0] == 0xffffffff and rs[-1][1] == 0,
                                "final remap did not finish")
                burst(1)
                current = await_condition(lambda rs: len([r for r in rs if r[0] != 0xffffffff]) >= 601,
                                          "post-refresh key missing")
                keys = [r for r in current if r[0] != 0xffffffff]
                assert len(keys) == 601 and keys[-1][0] == 98, keys[-1]
                result["post_refresh_symbol"] = keys[-1][0]
                # Focus and mapping have settled. A pure burst now reaches the
                # queue limit itself, rather than spending the drain budget on
                # interleaved focus/mapping events. Status records delimit each
                # application iteration's actual queue drain.
                stopped()
                saturation_start = len(records())
                burst(300)
                app.process.send_signal(signal.SIGCONT)
                current = await_condition(lambda rs: len([r for r in rs if r[0] != 0xffffffff]) >= 901,
                                          "saturation burst lost presses")
                saturated_keys = [r[0] for r in current[saturation_start:] if r[0] != 0xffffffff]
                assert saturated_keys == [98, 99] * 150, saturated_keys
                batches = []
                for record in current[saturation_start:]:
                    if record[0] == 0xffffffff:
                        batches.append(0)
                    else:
                        assert batches, "key appeared before its batch status"
                        batches[-1] += 1
                assert 256 in batches and max(batches) == 256, ("queue capacity was not exercised", batches)
                result["saturation_press_count"] = len(saturated_keys)
                result["saturation_symbols_in_order"] = "b,c repeated 150 times"
                result["saturation_batch_sizes"] = batches
                connection.delete(app.window)
                app.finished()
                assert not (evidence / "probe.stderr").read_bytes()
                result["status"] = "PASS"
            finally:
                if app:
                    if app.process.poll() is None:
                        app.process.send_signal(signal.SIGCONT)
                    app.cleanup()
                connection.close()
    except BaseException as error:
        result["status"] = "FAIL"
        result["error"] = f"{type(error).__name__}: {error}"
        raise
    finally:
        desktop.TITLE = old_title
        (evidence / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print("PASS X11 text: 600 ordered focus/remap presses, 300 saturation presses including a 256-key batch, new symbol and clean close")
    print(f"X11 text evidence: {evidence}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", type=Path, help="retain compile, protocol and result evidence")
    args = parser.parse_args()
    evidence = (args.evidence or Path(tempfile.mkdtemp(prefix="herbert-x11-text-check-"))).resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    if any(evidence.iterdir()):
        parser.error("--evidence must be empty, so a previous run is not overwritten")
    run(evidence)


if __name__ == "__main__":
    main()
