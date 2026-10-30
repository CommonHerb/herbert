# Herbert roadmap

Herbert is meant to be used: a language, fully its own, for building programs its owner actually runs, worked on over
decades. Programs come first, and each one shows what the language needs next. Every piece stays understandable and
checkable on demand.

## Next: programs people use

- **A live window on the owner's computers**: whether each of them answers, and how busy this one is. It is expected
  to need Herbert to reach the network and read the machine's own load, and to run for days without growing.
- Notes, Maze, First steps and the word counter keep working, and change when using them shows a need.

## Memory

A Herbert program never gives memory back while it runs, so long-lived programs build their storage once and reuse it.
In order:

1. Measure where memory goes in real programs, the compiler included.
2. An in-place `set` for arrays, so updating an element needs no new array.
3. Opt-in scratch areas whose memory is freed at once when the program is done with them.

## A family of languages

Herbert is the base of a family. Sister languages are welcome: each would translate into Herbert and go through
Herbert's one compiler, with its own front end written in Herbert.

## The paused OS work

Herbert's own operating system is further out. Its work is paused, not dropped: the kernel experiments (links 17–67),
their tests and the long64 runtime's [three tools](docs/os-tools.md) are kept, and the kernel CI still runs them
when the compiler or the kernel code changes ([VERIFYING.md](VERIFYING.md)). The compiler running on that OS waits
with it.

## What stays true

- No foreign compiler, language runtime or graphics library goes into Herbert programs. Linux, its desktop display
  server and drivers are host services we accept for now.
- Tools that are not Herbert are listed in `BOOTSTRAP-ALLOWLIST` and replaced with Herbert when a replacement is
  useful; the next is `tools/scan.c`, the last C file.
- A claim counts when a test shows it. Tests are tied to real behavior, and a passing part is never called a passing
  whole.
