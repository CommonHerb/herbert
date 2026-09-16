# Building a Herbert program

On Linux/x86-64, run this from a Git checkout of the repository:

```sh
make program SOURCE='my program.herb'
./build/program
```

The committed Herbert seed compiles the source directly to an ELF executable.
`SOURCE` names the main source file; `OUTPUT` defaults to `build/program`.
Quote arguments that contain spaces or shell characters; names are treated literally:

```sh
make program SOURCE='my program.herb' OUTPUT='build/my program'
```

To use the [Herbert support units](../lib/README.md), list their names in dependency
order. Each name selects the matching `lib/NAME.herb`, placed before your source:

```sh
make program SOURCE=examples/notes.herb \
  SUPPORT='linux x11 pixel_text file_io text_buffer session_recovery' OUTPUT=build/my-notes
```

Support names contain only letters, digits and underscores and must name an
existing library source. Paths and unknown names are rejected. Dependencies are
explicit: the build does not infer, fetch or reorder them. This is the same source
concatenation used by the existing application targets, not a module system.

Each source unit gets a final newline if it lacks one. This keeps a final comment
from swallowing the next file. The recorded source map accounts for those exact
bytes and maps end-of-file diagnostics to the original file’s EOF line. Located compiler rejections such as `line 12: ...`
are displayed with the original source path and line; internal diagnostics such as
`herbert: line N: ...` remain unchanged. The original compiler stderr is retained.
Paths with spaces are supported; tabs and newlines in paths are rejected.

A build publishes only after the compiler exits 0, writes exactly `0\n` to stdout,
writes nothing to stderr, and produces an ELF image. A failure preserves any
previous output. The target refuses to replace any input source, the seed, this checkout’s tracked
project files, repository metadata, symlinks or directories. A successful build
replaces the chosen output by a same-filesystem atomic rename; it does not promise
power-loss durability or safety against concurrent hostile directory changes.

Every compilation keeps a fresh `.herbert-build.*` directory alongside the output.
The command prints its path. It contains the source snapshots, concatenated source,
source map, compiler copy and hash, exact status/stdout/stderr, and the emitted
image and hash. The image remains in that evidence directory after publication.
These directories are Git-ignored and retained on success and failure; no automatic
cleanup runs.

`make program-contract` verifies this interface with the real seed, located source
and library rejections, path/overwrite protection, malformed compiler envelopes
and a failed publication command. It runs in `make verify-local` and hosted CI;
its `/tmp/herbert-program-build-*` evidence is uploaded even if the check fails.
Make, Bash, coreutils, diffutils, awk and Git are development tooling. The resulting program
has no added foreign compiler, language runtime or build-tool dependency.
