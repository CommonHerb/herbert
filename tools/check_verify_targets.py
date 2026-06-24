#!/usr/bin/env python3
"""Guard the local-vs-Linux verification target split."""

from __future__ import annotations

from pathlib import Path
import sys


MAKEFILE = Path("Makefile")
HOST_GUARD = Path("tools/check_full_test_host.sh")

EXPECTED_VERIFY_LOCAL = [
    "verify-targets",
    "check",
    "test-timeout",
    "lexer-copy-sync",
    "native-codegen-diagnostics",
    "kernel-emu-contracts",
]

EXPECTED_VERIFY_LINUX = [
    "verify-targets",
    "check",
    "test-timeout",
    "test",
    "evaluator-native",
    "vm-native",
    "parser-native",
    "lexer-native",
    "klondike-native",
    "emitter-native",
    "error-vocab-native",
    "lexer-copy-sync",
    "native-codegen-diagnostics",
    "kernel-emu-contracts",
    "switchover-cfree",
    "switchover-dry-run",
]

LINUX_ONLY_TARGETS = {
    "test",
    "evaluator-native",
    "vm-native",
    "parser-native",
    "lexer-native",
    "klondike-native",
    "emitter-native",
    "error-vocab-native",
    "switchover-cfree",
    "switchover-dry-run",
    "reseed",
}


def parse_targets(text: str) -> dict[str, list[str]]:
    targets: dict[str, list[str]] = {}
    logical_lines: list[str] = []
    current = ""

    for raw in text.splitlines():
        if not raw or raw.startswith("\t"):
            continue
        if raw.rstrip().endswith("\\"):
            current += raw.rstrip()[:-1] + " "
            continue
        logical_lines.append(current + raw)
        current = ""

    for line in logical_lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or ":" not in stripped:
            continue
        name_part, _, prereq_part = stripped.partition(":")
        if "=" in name_part:
            continue
        for name in name_part.split():
            prereqs = prereq_part.split("#", 1)[0].split()
            if "|" in prereqs:
                prereqs = prereqs[: prereqs.index("|")]
            targets[name] = prereqs

    return targets


def require_equal(name: str, got: list[str], want: list[str], failures: list[str]) -> None:
    if got != want:
        failures.append(
            f"{name} prerequisites drifted:\n"
            f"  got:  {' '.join(got) if got else '<none>'}\n"
            f"  want: {' '.join(want)}"
        )


def main() -> int:
    if not MAKEFILE.exists():
        print("FAIL: verify target guard (missing Makefile)", file=sys.stderr)
        return 1
    if not HOST_GUARD.exists():
        print("FAIL: verify target guard (missing host guard)", file=sys.stderr)
        return 1

    targets = parse_targets(MAKEFILE.read_text())
    failures: list[str] = []

    verify_local = targets.get("verify-local")
    if verify_local is None:
        failures.append("missing verify-local target")
    else:
        require_equal("verify-local", verify_local, EXPECTED_VERIFY_LOCAL, failures)
        leaked = sorted(set(verify_local) & LINUX_ONLY_TARGETS)
        if leaked:
            failures.append(
                "verify-local includes Linux/x86_64-only target(s): " + ", ".join(leaked)
            )

    verify_linux = targets.get("verify-linux")
    if verify_linux is None:
        failures.append("missing verify-linux target for the full Linux/x86_64 ladder")
    else:
        require_equal("verify-linux", verify_linux, EXPECTED_VERIFY_LINUX, failures)

    verify_targets = targets.get("verify-targets")
    if verify_targets is None:
        failures.append("missing verify-targets guard target")
    elif verify_targets != []:
        failures.append("verify-targets should not have prerequisites")

    phony = set(targets.get(".PHONY", []))
    for name in ("verify-targets", "verify-local", "verify-linux"):
        if name not in phony:
            failures.append(f"{name} is missing from .PHONY")

    host_guard = HOST_GUARD.read_text()
    for required in ("make verify-local", "make test", "make verify-linux"):
        if required not in host_guard:
            failures.append(f"host guard message should mention '{required}'")

    if failures:
        print("FAIL: verify target guard")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("PASS: verify target guard (verify-local is portable; verify-linux keeps the full Linux/x86_64 ladder)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
