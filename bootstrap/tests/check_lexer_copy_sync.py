#!/usr/bin/env python3
"""Guard copied lexer fragments against silent drift."""

from __future__ import annotations

import difflib
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "stack/lexer_fragment.herb"
COPIES = [
    "stack/lexer_stdin_driver.herb",
    "stack/parser_fragment.herb",
    "stack/evaluator_fragment.herb",
    "stack/emitter_fragment.herb",
    "stack/suke_echo_fragment.herb",
    "stack/suke_compute_fragment.herb",
]
LINE_AWARE_COPIES = [
    "stack/klondike.herb",
    "stack/native_compile_fragment.herb",
]


def lexer_block(path: Path) -> str:
    text = path.read_text(encoding="utf-8")
    start = text.find("func is_digit")
    if start < 0:
        raise ValueError(f"{path.relative_to(ROOT)} has no lexer block start")
    lex_source = text.find("\nfunc lex_source", start)
    if lex_source < 0:
        raise ValueError(f"{path.relative_to(ROOT)} has no lex_source")
    end = text.find("\nend\n", lex_source)
    if end < 0:
        raise ValueError(f"{path.relative_to(ROOT)} has no lex_source end")
    return text[start : end + len("\nend\n")]


def normalized_code(block: str) -> str:
    lines = []
    for line in block.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("--"):
            continue
        lines.append(stripped)
    return "\n".join(lines) + "\n"


def line_aware_expected(base: str) -> str:
    expected = []
    skip_next_plain_ws_scan = False
    for line in base.splitlines():
        if skip_next_plain_ws_scan:
            skip_next_plain_ws_scan = False
            if line == "return scan(src, i + 1, n, out)":
                continue

        if line == "func scan(src, i, n, out):":
            expected.append("func scan(src, i, n, line, out):")
        elif line == "if is_ws(c):":
            expected.extend([
                "if is_ws(c):",
                "if c == '\\n':",
                "return scan(src, i + 1, n, line + 1, out)",
                "end",
                "return scan(src, i + 1, n, line, out)",
            ])
            skip_next_plain_ws_scan = True
        elif line.startswith("do add(out, (") and line.endswith("))"):
            expected.append(line[:-2] + ", line))")
        elif line == "return scan(src, 0, length(src), new_array((int, string)))":
            expected.append("return scan(src, 0, length(src), 1, new_array((int, string, int)))")
        elif line.startswith("return scan(src, ") and line.endswith(", n, out)"):
            expected.append(line.replace(", n, out)", ", n, line, out)"))
        else:
            expected.append(line)
    return "\n".join(expected) + "\n"


def report_diff(kind: str, rel: str, expected: str, got: str) -> None:
    diff = difflib.unified_diff(
        expected.splitlines(),
        got.splitlines(),
        fromfile="stack/lexer_fragment.herb",
        tofile=rel,
        lineterm="",
    )
    print(f"FAIL: lexer copy sync ({kind}: {rel} differs from stack/lexer_fragment.herb)")
    print("\n".join(diff))


def main() -> int:
    base = normalized_code(lexer_block(SOURCE))
    line_aware = line_aware_expected(base)
    ok = True
    for rel in COPIES:
        path = ROOT / rel
        got = normalized_code(lexer_block(path))
        if got == base:
            continue
        ok = False
        report_diff("accepted-token", rel, base, got)
    for rel in LINE_AWARE_COPIES:
        path = ROOT / rel
        got = normalized_code(lexer_block(path))
        if got == line_aware:
            continue
        ok = False
        report_diff("line-aware", rel, line_aware, got)
    if not ok:
        return 1
    total = len(COPIES) + len(LINE_AWARE_COPIES)
    print(f"PASS: lexer copy sync ({total} copied lexer blocks match stack/lexer_fragment.herb contracts)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
