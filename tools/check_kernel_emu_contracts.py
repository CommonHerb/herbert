#!/usr/bin/env python3
"""Guard kernel mutation scripts against emulator-requirement drift."""

from __future__ import annotations

from pathlib import Path
import re
import sys


WORKFLOW = Path(".github/workflows/kernel-codegen-l1.yml")
SCRIPT_RE = re.compile(
    r"KERNEL_CODEGEN_REQUIRE_EMU=1\b.*\bbash\s+"
    r"(bootstrap/tests/run_native_codegen_link\d+_mutation\.sh)"
)


def workflow_mutation_scripts() -> list[Path]:
    if not WORKFLOW.exists():
        raise FileNotFoundError(WORKFLOW)

    scripts: list[Path] = []
    for match in SCRIPT_RE.finditer(WORKFLOW.read_text()):
        path = Path(match.group(1))
        if path not in scripts:
            scripts.append(path)
    return scripts


def first_qemu_missing_block(lines: list[str], start: int) -> tuple[int, str]:
    depth = 0
    body: list[str] = []

    for idx in range(start, len(lines)):
        line = lines[idx]
        stripped = line.strip()
        body.append(line)

        depth += len(re.findall(r"\bif\b", stripped))
        depth -= len(re.findall(r"\bfi\b", stripped))
        if depth <= 0:
            return idx + 1, "".join(body)

    return len(lines), "".join(body)


def qemu_missing_blocks(text: str) -> list[tuple[int, str]]:
    lines = text.splitlines(keepends=True)
    blocks: list[tuple[int, str]] = []
    for idx, line in enumerate(lines):
        if "if ! command -v qemu-system-x86_64" in line or "if ! have_qemu" in line:
            end, body = first_qemu_missing_block(lines, idx)
            blocks.append((idx + 1, body))
            if end <= idx + 1:
                break
    return blocks


def fail_closed(block: str) -> bool:
    if "SKIP" not in block or "qemu" not in block.lower():
        return True

    mentions_require = "KERNEL_CODEGEN_REQUIRE_EMU" in block or "REQUIRE_EMU" in block
    has_failure_path = any(token in block for token in ("FAIL", "fail_test", "bad ", "no "))
    return mentions_require and has_failure_path


def main() -> int:
    try:
        scripts = workflow_mutation_scripts()
    except FileNotFoundError as exc:
        print(f"FAIL: kernel emulator contract guard (missing {exc.filename})", file=sys.stderr)
        return 1

    failures: list[str] = []
    for script in scripts:
        if not script.exists():
            failures.append(f"{script}: workflow references missing script")
            continue

        text = script.read_text()
        blocks = qemu_missing_blocks(text)
        if "qemu-system-x86_64" in text and not blocks:
            failures.append(f"{script}: references qemu-system-x86_64 but has no missing-QEMU guard")
            continue

        for line, block in blocks:
            if not fail_closed(block):
                failures.append(
                    f"{script}:{line}: missing-QEMU path skips without failing under "
                    "KERNEL_CODEGEN_REQUIRE_EMU=1"
                )

    if failures:
        print("FAIL: kernel emulator contract guard")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print(
        "PASS: kernel emulator contract guard "
        f"({len(scripts)} workflow mutation scripts fail closed when emulators are required)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
