#!/usr/bin/env python3
"""Exercise Link 44's actual Bochs retry block with controlled host-command stubs.

This checks attempt isolation and evidence retention, not kernel behavior. No
emulator, disk mount, privileged command or compiler is executed. The real
required-substrate gate must still run separately.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile


HERE = Path(__file__).resolve().parent


def executable(path, text):
    path.write_text(text)
    path.chmod(0o755)


def run_case(directory, scenario):
    directory.mkdir()
    tools = directory / "tools"
    tools.mkdir()
    work = directory / "work"
    work.mkdir()
    for name in ("A.bin", "B.bin", "kernel.elf"):
        (work / name).write_bytes(name.encode())
    executable(tools / "sudo", '''#!/bin/bash
case "$1" in
    losetup) [[ "$2" != -fP ]] || echo /unused-test-loop; exit 0 ;;
    umount) [[ "$SCENARIO" != cleanup-failure ]] || exit 24; exit 0 ;;
    mkfs.vfat|mount|grub-install) exit 0 ;;
esac
exec "$@"
''')
    executable(tools / "dd", '#!/bin/bash\nprintf disk-fixture > disk.img\n')
    executable(tools / "parted", '''#!/bin/bash
if [[ "$SCENARIO" == setup-failure && "$PWD" == *attempt-1.* ]]; then
    echo 'injected partition setup failure' >&2; exit 23
fi
''')
    executable(tools / "find", '#!/bin/bash\necho /unused-test-bios\n')
    executable(tools / "xvfb-run", '#!/bin/bash\nshift\nexec "$@"\n')
    executable(tools / "bochs", '''#!/usr/bin/env python3
import os
from pathlib import Path
import sys
Path("bochs_log.txt").write_text("controlled attempt " + Path.cwd().name + "\\n")
if Path("disk.img.lock").exists():
    raise SystemExit("inherited disk lock: retry isolation failed")
count_file = Path(os.environ["TEST_WORK"]) / "controlled-bochs-count"
count = int(count_file.read_text()) + 1 if count_file.exists() else 1
count_file.write_text(str(count))
if os.environ["SCENARIO"] == "all-fail" or (
        os.environ["SCENARIO"] == "first-fails" and count == 1):
    Path("disk.img.lock").touch()
    with Path("bochs_log.txt").open("a") as log:
        log.write("injected first-attempt disk lock / failure\\n")
    print("injected unfinished boot", flush=True)
    sys.exit(139)
sys.stdout.buffer.write(b"emulator preamble\\n\\x9cCONTROLLED-WITNESS\\nshutdown requested\\n")
''')
    feeder = directory / "feeder.py"
    feeder.write_text('print("LISTENING", flush=True)\nprint("SENT 1 2", flush=True)\n')
    reference = directory / "reference.py"
    reference.write_text('''import os, sys
from pathlib import Path
if sys.argv[1] == "stream":
    print("1 2")
else:
    assert sys.argv[1] == "grade"
    assert b"CONTROLLED-WITNESS" in Path(sys.argv[2]).read_bytes()
    print("controlled grade " + os.environ["SCENARIO"])
    sys.exit(1 if os.environ["SCENARIO"] == "grade-failure" else 0)
''')
    source = (HERE / "run_native_codegen_link44.sh").read_text()
    # Run the production function AND its caller: an independent test loop
    # would miss errors such as retrying a failed completed behavior grade.
    block = source[source.index("bochs_run() {"):]
    driver = directory / "driver.sh"
    driver.write_text('''set -u
work="$TEST_WORK"; script_dir="$TEST_SCRIPTS"
AMOD="$work/A.bin"; BMOD="$work/B.bin"; MKELF="$work/kernel.elf"
REF="$TEST_REF"; feeder="$TEST_FEEDER"
KEND=1; REQUIRE_EMU=1; emu_ran=0; pass=0; fail=0
have_bochs() { return 0; }
free_port() { echo 54321; }
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
fail_test() { echo "FAIL: $1"; fail=$((fail + 1)); }
''' + block)
    env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"],
               SCENARIO=scenario, TEST_WORK=str(work), TEST_SCRIPTS=str(HERE),
               TEST_REF=str(reference), TEST_FEEDER=str(feeder))
    result = subprocess.run(["bash", str(driver)], env=env, capture_output=True, timeout=20)
    (directory / "driver.stdout").write_bytes(result.stdout)
    (directory / "driver.stderr").write_bytes(result.stderr)
    expected_status = 1 if scenario in ("all-fail", "grade-failure", "cleanup-failure") else 0
    assert result.returncode == expected_status, (scenario, result.returncode, result.stdout, result.stderr)
    attempts = sorted(work.glob("b.gx.attempt-*"))
    expected_attempts = {"first-fails": 2, "all-fail": 3, "grade-failure": 1, "setup-failure": 2, "cleanup-failure": 1}[scenario]
    assert len(attempts) == expected_attempts, (scenario, attempts)
    for index, attempt in enumerate(attempts, 1):
        status = (attempt / "process-status.txt").read_text()
        assert f"attempt={index}\n" in status
        assert "feeder_wait_exit=" in status and "disk_setup_exit=" in status
        assert (attempt / "feed.log").read_text().startswith("LISTENING\nSENT")
        if scenario == "cleanup-failure":
            assert "disk_setup_exit=24\n" in status and "disk_umount_exit=24\n" in status
            assert (work / "KEEP-WORK").is_file()
            assert "disk_detach_exit=" not in status
            assert not (attempt / "bochs_out.txt").exists()
            continue
        if scenario == "setup-failure" and index == 1:
            assert "disk_setup_exit=23\n" in status
            assert not (attempt / "bochs_out.txt").exists()
            continue
        assert "xvfb_run_exit=" in status
        pipeline = (attempt / "emulator-pipeline-status.txt").read_text()
        assert "yes_exit=" in pipeline
        failed = scenario == "all-fail" or (scenario == "first-fails" and index == 1)
        assert f"timeout_bochs_exit={139 if failed else 0}\n" in pipeline
        assert (attempt / "disk.img.lock").exists() == failed
        if failed:
            assert not (attempt / "grade.log").exists()
        else:
            assert "grade_exit=" in status and (attempt / "grade.log").is_file()
    # Exercise the production capture path too: every attempt's status/logs and
    # the first lock must survive cleanup's ordinary inventory rules.
    evidence = directory / "captured"
    subprocess.run(["python3", str(HERE / "kernel_evidence.py"), str(work), str(evidence)], check=True)
    capture, = evidence.iterdir()
    inventory = json.loads((capture / "INVENTORY.json").read_text())
    for attempt in attempts:
        assert (capture / attempt.name / "process-status.txt").read_bytes() == (attempt / "process-status.txt").read_bytes()
        assert (capture / attempt.name / "attempt-result.txt").read_bytes() == (attempt / "attempt-result.txt").read_bytes()
    for row in inventory["files"]:
        if row["path"].endswith("disk.img.lock"):
            assert row["retained"] and (capture / row["path"]).is_file()
    print(f"PASS link44 controlled {scenario}: {len(attempts)} isolated, retained attempt(s)")


def main():
    with tempfile.TemporaryDirectory(prefix="herbert-link44-attempt-check-") as temporary:
        root = Path(temporary)
        for scenario in ("first-fails", "all-fail", "grade-failure", "setup-failure", "cleanup-failure"):
            run_case(root / scenario, scenario)
    print("PASS link44 attempt isolation/status retention (controlled commands; no emulator qualification)")


if __name__ == "__main__":
    main()
