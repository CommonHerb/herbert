#!/usr/bin/env python3
"""Check Herbert's tile-map parser against independently specified fixtures.

The real linux.herb and grid_map.herb are compiled by the Herbert seed. Python
only supplies inputs and checks observable output; it is not an app dependency.
Optional --maze also checks the built game's file/argument error paths without
opening a desktop. Failures retain source, inputs and raw process output.
"""

import argparse
import ast
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]

# Frozen test fixture, independent of the editable default game asset.
DEFAULT_MAP = b"""#########################
#P....#...........#.....#
#.###.#.###.#####.#.###.#
#...#...#...#...#...#...#
###.#####.###.#.#####.###
#...#.....#...#.....#...#
#.###.#####.#######.###.#
#.....#...........#.....#
#.###.#.###.###.#.#.###.#
#...#...#...#...#...#...#
###.#####.###.#####.#.###
#...#.....#...#.....#...#
#.###.#####.#.#.#######.#
#.....#.....#...#.......#
#.###.#.#######.#.#####.#
#...#...........#.......#
#########################
"""

# Errors specify the public status and one-based error location. Successful
# fixtures additionally specify width, height, spawn index and dot count.
CASES = [
    ("default", DEFAULT_MAP, (0, 0, 0), (25, 17, 26, 198)),
    ("empty", b"", (1, 0, 0), None),
    ("small", b"##\n##", (2, 0, 0), None),
    ("wide", b"#" * 32 + b"\n", (3, 1, 32), None),
    ("tall", b"###\n#P#\n#.#\n" + b"###\n" * 17, (3, 20, 1), None),
    ("ragged", b"#####\n#P.#\n#####", (4, 2, 5), None),
    ("blank-row", b"#####\n\n#P..#\n#####", (5, 2, 1), None),
    ("unknown", b"#####\n#Px.#\n#####", (6, 2, 3), None),
    ("nul", b"#####\n#P\x00.#\n#####", (6, 2, 3), None),
    ("open-edge", b"## ##\n#P..#\n#####", (7, 1, 3), None),
    ("duplicate", b"#####\n#PP.#\n#####", (8, 2, 3), None),
    ("missing-spawn", b"#####\n# ..#\n#####", (9, 0, 0), None),
    ("no-dots", b"#####\n#P  #\n#####", (10, 0, 0), None),
    ("unreachable", b"#######\n#P.#..#\n#######", (11, 2, 5), None),
    ("bare-cr", b"#####\r#P..#\n#####", (12, 1, 6), None),
    ("cr-at-end", b"#####\n#P..#\n#####\r", (12, 3, 6), None),
    ("minimal", b"###\n#P#\n#.#\n###", (0, 0, 0), (3, 4, 4, 1)),
    ("no-final-newline", b"#####\n#P..#\n#####", (0, 0, 0), (5, 3, 6, 2)),
    ("crlf", b"#####\r\n#P..#\r\n#####\r\n", (0, 0, 0), (5, 3, 6, 2)),
    ("extra-final-newline", b"#####\n#P..#\n#####\n\n", (5, 4, 1), None),
]

PROBE = """
func main():
    let loaded = linux_read_file("map.txt", 4096)
    if loaded.0 != 0: return (99,0,0,0,0,0,0,0) end
    let map = grid_map_parse(loaded.1, loaded.2, 31, 19)
    if map.0 == 0:
        -- Emit actual normalized cells before the ordinary result tuple.
        let written = linux_syscall6(1, 1, buffer_address(map.5), buffer_length(map.5), 0, 0, 0)
        if written != buffer_length(map.5): do process_exit(2) end
        let newline = linux_cstring("\\n")
        let ended = linux_syscall6(1, 1, buffer_address(newline), 1, 0, 0, 0)
        if ended != 1: do process_exit(2) end
    end
    return (map.0,map.1,map.2,map.3,map.4,map.6,map.7,buffer_length(map.5))
end
"""


def require(actual, expected, label):
    if actual != expected:
        raise AssertionError(f"{label}: expected {expected!r}, got {actual!r}")


def run_recorded(command, directory, label, **kwargs):
    result = subprocess.run(command, cwd=directory, capture_output=True, timeout=30, **kwargs)
    (directory / (label + ".stdout")).write_bytes(result.stdout)
    (directory / (label + ".stderr")).write_bytes(result.stderr)
    (directory / (label + ".exit")).write_text(str(result.returncode) + "\n")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler", type=Path, help="explicit candidate seed")
    parser.add_argument("--maze", type=Path, help="also check this built maze's CLI errors")
    parser.add_argument("--keep-work", action="store_true")
    args = parser.parse_args()
    seed = args.compiler or ROOT / "bootstrap/seed/gen1.seed"
    seed_bytes = seed.read_bytes()
    digest = hashlib.sha256(seed_bytes).hexdigest()
    if args.compiler is None:
        require(digest, seed.with_suffix(seed.suffix + ".sha256").read_text().split()[0], "seed checksum")
    work = Path(tempfile.mkdtemp(prefix="herbert-grid-map-"))
    print(f"grid-map compiler SHA-256: {digest}; evidence: {work}", flush=True)
    compiler = work / "compiler"
    compiler.write_bytes(seed_bytes)
    compiler.chmod(0o700)
    results = []
    success = False
    try:
        source = b"\n".join((ROOT / path).read_bytes()
                            for path in ("lib/linux.herb", "lib/grid_map.herb")) + PROBE.encode()
        (work / "source.herb").write_bytes(source)
        built = run_recorded([str(compiler)], work, "compile", input=source)
        require((built.returncode, built.stdout, built.stderr), (0, b"0\n", b""), "parser compile")
        image = work / "a.out"
        require(image.read_bytes()[:4], b"\x7fELF", "parser ELF")
        image.chmod(0o700)
        for name, data, outcome, shape in CASES:
            directory = work / name
            directory.mkdir()
            (directory / "map.txt").write_bytes(data)
            result = run_recorded([str(image)], directory, "runtime")
            require((result.returncode, result.stderr), (0, b""), name + " process")
            output = result.stdout
            if shape is not None:
                # Only line separators disappear; spaces and P stay verbatim.
                cells = b"".join(data.splitlines())
                emitted, separator, output = output.partition(b"\n")
                require((emitted, separator), (cells, b"\n"), name + " normalized cells")
            summary = ast.literal_eval(output.decode())
            if not isinstance(summary, tuple) or len(summary) != 8:
                raise AssertionError(f"{name}: malformed parser result {summary!r}")
            require((summary[0], summary[5], summary[6]), outcome, name + " status/location")
            if shape is not None:
                require(summary[1:5], shape, name + " dimensions/spawn/dots")
                require(summary[7], shape[0] * shape[1], name + " packed cell count")
            results.append({"case": name, "status_row_column": outcome, "pass": True})
            (work / "results.json").write_text(json.dumps(results, indent=2) + "\n")
            print(f"PASS grid-map {name}", flush=True)

        if args.maze is not None:
            maze = args.maze.resolve()
            (work / "maze.sha256").write_text(hashlib.sha256(maze.read_bytes()).hexdigest() + "\n")
            cli = work / "cli"
            cli.mkdir()
            (cli / "oversize.txt").write_bytes(b"#" * 4097)
            (cli / "invalid.txt").write_bytes(b"#####\n#Px.#\n#####")
            (cli / "unreachable.txt").write_bytes(b"#######\n#P.#..#\n#######")
            cli_cases = [
                ("missing", ["absent.txt"], b"maze: cannot read map file; check its path and permissions\n"),
                ("oversize", ["oversize.txt"], b"maze: map file exceeds 4096 bytes\n"),
                ("invalid", ["invalid.txt"], b"maze: unknown map symbol; use # . space or P (row 2, column 3)\n"),
                ("unreachable", ["unreachable.txt"], b"maze: a dot cannot be reached from P (row 2, column 5)\n"),
                ("extra-arguments", ["one", "two"], b"maze: usage: maze [map-file]\n"),
            ]
            env = dict(os.environ)
            env.pop("DISPLAY", None)
            for name, arguments, error in cli_cases:
                result = run_recorded([str(maze), *arguments], cli, name, env=env)
                require((result.returncode, result.stdout, result.stderr), (1, b"", error), "maze CLI " + name)
                results.append({"case": "maze-cli-" + name, "pass": True})
                (work / "results.json").write_text(json.dumps(results, indent=2) + "\n")
                print(f"PASS maze CLI {name}", flush=True)
        print(f"grid-map: {len(CASES)} parser cases passed" +
              ("; 5 maze CLI cases passed" if args.maze else ""), flush=True)
        success = True
    finally:
        if success and not args.keep_work:
            shutil.rmtree(work)
        else:
            print(f"retained evidence: {work}", flush=True)


if __name__ == "__main__":
    main()
