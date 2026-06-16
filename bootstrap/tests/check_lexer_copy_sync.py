#!/usr/bin/env python3
"""Guard accepted-token lexer copies against silent drift."""

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


def main() -> int:
    base = normalized_code(lexer_block(SOURCE))
    ok = True
    for rel in COPIES:
        path = ROOT / rel
        got = normalized_code(lexer_block(path))
        if got == base:
            continue
        ok = False
        diff = difflib.unified_diff(
            base.splitlines(),
            got.splitlines(),
            fromfile="stack/lexer_fragment.herb",
            tofile=rel,
            lineterm="",
        )
        print(f"FAIL: lexer copy sync ({rel} differs from stack/lexer_fragment.herb)")
        print("\n".join(diff))
    if not ok:
        return 1
    print(f"PASS: lexer copy sync ({len(COPIES)} accepted-token copies match stack/lexer_fragment.herb)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
