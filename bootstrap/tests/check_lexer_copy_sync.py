#!/usr/bin/env python3
"""Guard copied lexer fragments against silent drift."""

from __future__ import annotations

import difflib
import re
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
# These two files share a token-producing checked lexer. Include its result
# constructors and integer-accumulation helper, but not checked parsing, semantic
# checks, or diagnostic rendering. Its plain lexer helpers are guarded above.
CHECKED_SOURCE = "stack/klondike.herb"
CHECKED_COPY = "stack/native_compile_fragment.herb"
CHECKED_FUNCTIONS = [
    "err_ok_tag", "err_err_tag", "err_no_diag", "err_diag",
    "err_empty_tokens", "err_lex_ok", "err_lex_fail", "err_pos_ok", "err_pos_fail",
    "err_is_valid_punct", "err_end_of_int", "err_string_escape_ok",
    "err_char_escape_ok", "err_end_of_string", "err_check_char_close",
    "err_end_of_char", "err_scan", "err_lex_source", "times10",
]
# lexer_error_driver is a DIFFERENT, diagnostic-only scanner, not a third
# err_scan copy. Only these genuinely identical classifiers/skippers are shared;
# its scan/scan_int/scan_string/scan_char and diagnostic tuples remain outside
# this copy guard, rather than inventing an equivalence between implementations.
DIAGNOSTIC_DRIVER = "stack/lexer_error_driver.herb"
DIAGNOSTIC_SHARED_FUNCTIONS = [
    "is_digit", "is_lower", "is_upper", "is_alpha", "is_ident_start",
    "is_ident_cont", "is_ws", "is_two_byte_op_start", "is_shift_op_start",
    "is_one_byte_op", "end_of_ident", "end_of_line",
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


def named_functions(path: Path, names: list[str]) -> str:
    text = path.read_text(encoding="utf-8")
    declarations = list(re.finditer(
        r"^[ \t]*func[ \t]+([A-Za-z_][A-Za-z0-9_]*)[ \t]*\(", text, re.MULTILINE,
    ))
    blocks = []
    for name in names:
        hits = [i for i, declaration in enumerate(declarations) if declaration[1] == name]
        if len(hits) != 1:
            raise ValueError(
                f"{path.relative_to(ROOT)}: function anchor {name} occurs {len(hits)}x (expected 1)"
            )
        i = hits[0]
        end = declarations[i + 1].start() if i + 1 < len(declarations) else len(text)
        block = normalized_code(text[declarations[i].start():end])
        if block.splitlines()[-1] != "end":
            raise ValueError(f"{path.relative_to(ROOT)}: function {name} has no closing end")
        blocks.append(block)
    return "".join(blocks)


def line_aware_expected(base: str) -> str:
    expected = []
    skip_next_plain_ws_scan = False
    hits = {"scan_sig": 0, "is_ws": 0, "init": 0, "do_add": 0}
    for line in base.splitlines():
        if skip_next_plain_ws_scan:
            skip_next_plain_ws_scan = False
            if line == "return scan(src, i + 1, n, out)":
                continue

        if line == "func scan(src, i, n, out):":
            expected.append("func scan(src, i, n, line, out):")
            hits["scan_sig"] += 1
        elif line == "if is_ws(c):":
            expected.extend([
                "if is_ws(c):",
                "if c == '\\n':",
                "return scan(src, i + 1, n, line + 1, out)",
                "end",
                "return scan(src, i + 1, n, line, out)",
            ])
            skip_next_plain_ws_scan = True
            hits["is_ws"] += 1
        elif line.startswith("do add(out, (") and line.endswith("))"):
            expected.append(line[:-2] + ", line))")
            hits["do_add"] += 1
        elif line == "return scan(src, 0, length(src), new_array((int, string)))":
            expected.append("return scan(src, 0, length(src), 1, new_array((int, string, int)))")
            hits["init"] += 1
        elif line.startswith("return scan(src, ") and line.endswith(", n, out)"):
            expected.append(line.replace(", n, out)", ", n, line, out)"))
        else:
            expected.append(line)
    # The line-aware contract is mechanically derived from the plain lexer by
    # rewriting a fixed set of anchor lines. If the plain lexer is reworded or
    # reformatted so an anchor stops matching (e.g. is_ws renamed), the transform
    # would SILENTLY emit a wrong line-aware contract -- e.g. drop line tracking --
    # and still pass. Assert every load-bearing anchor fired exactly as expected so
    # source drift breaks LOUDLY here instead of silently corrupting the contract.
    required = {"scan_sig": 1, "is_ws": 1, "init": 1}
    problems = [f"{k} fired {hits[k]}x (expected {n})" for n, k in ((1, "scan_sig"), (1, "is_ws"), (1, "init")) if hits[k] != required[k]]
    if hits["do_add"] < 1:
        problems.append("do_add fired 0x (expected >=1)")
    if problems:
        raise ValueError(
            "line_aware_expected: lexer-contract anchors changed in "
            "stack/lexer_fragment.herb; the line-aware transform is stale -- "
            + "; ".join(problems)
        )
    return "\n".join(expected) + "\n"


def report_diff(kind: str, rel: str, expected: str, got: str,
                source: str = "stack/lexer_fragment.herb") -> None:
    diff = difflib.unified_diff(
        expected.splitlines(),
        got.splitlines(),
        fromfile=source,
        tofile=rel,
        lineterm="",
    )
    print(f"FAIL: lexer copy sync ({kind}: {rel} differs from {source})")
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
    checked = named_functions(ROOT / CHECKED_SOURCE, CHECKED_FUNCTIONS)
    got_checked = named_functions(ROOT / CHECKED_COPY, CHECKED_FUNCTIONS)
    if got_checked != checked:
        ok = False
        report_diff("checked-lexer", CHECKED_COPY, checked, got_checked, CHECKED_SOURCE)
    shared = named_functions(SOURCE, DIAGNOSTIC_SHARED_FUNCTIONS)
    got_shared = named_functions(ROOT / DIAGNOSTIC_DRIVER, DIAGNOSTIC_SHARED_FUNCTIONS)
    if got_shared != shared:
        ok = False
        report_diff("diagnostic-lexer shared helpers", DIAGNOSTIC_DRIVER, shared, got_shared)
    if not ok:
        return 1
    total = len(COPIES) + len(LINE_AWARE_COPIES)
    print(f"PASS: lexer copy sync ({total} copied lexer blocks match stack/lexer_fragment.herb contracts)")
    print(f"PASS: checked lexer copy sync ({len(CHECKED_FUNCTIONS)} functions match between {CHECKED_SOURCE} and {CHECKED_COPY})")
    print(f"PASS: diagnostic lexer helper sync ({len(DIAGNOSTIC_SHARED_FUNCTIONS)} shared helpers in {DIAGNOSTIC_DRIVER} match stack/lexer_fragment.herb; diagnostic-only scanner excluded)")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError) as error:
        print(f"FAIL: lexer copy sync ({error})", file=sys.stderr)
        sys.exit(1)
