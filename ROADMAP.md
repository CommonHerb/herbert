# Herbert roadmap

Herbert is a language, fully its own, for building programs its owner actually runs. It is worked on over decades
and nothing here has a date. The plan has four stages, in order.

## 1. A language worth choosing (now)

The compiler is solid: it is written in Herbert and rebuilds itself byte for byte. The language around it is still
thin, and an everyday job takes many times the lines it would elsewhere. This stage closes the basics on purpose:

- negative numbers and decimals;
- real text: joining, cutting, comparing and formatting without building it a byte at a time;
- programs split into named parts, in place of one flat list of names;
- function values, so one function can be handed to another;
- memory handed back while a program runs;
- errors that point at the right line.

The yardstick is an ordinary small tool costing about what it would in Python. Each addition earns its place by making
a real program here shorter, or a wanted one possible: Notes, Scope and the compiler itself are the measure.

The checks move too. Herbert's tests were written in Python and shell; they are being replaced by a small set written
in Herbert: the compiler rebuilds itself exactly, a folder of programs gives the right answers, and the applications
are checked where a fault would cost their user something. No new Python or shell is added.

## 2. The language things get built in

When its owner has an idea, Herbert is the first tool reached for. That needs the larger pieces: the network done
properly (names, the web, encryption, all written here), pictures and sound, and the first sister language. A sister
language is a front end written in Herbert that translates into Herbert and goes through Herbert's one compiler.

## 3. Herbert's own machine

An operating system of its own, written fresh in the grown language and running a real computer. The first kernel
experiments, from 2026, are kept whole at the tag `os-experiments-2026-11-09`; this stage does not resume them.

## 4. The world

The long dream: a system that is also a simulated world, in the line of small personal systems like Oberon.

## What stays true

- No foreign compiler, language runtime or graphics library goes into Herbert programs. Linux, its desktop display
  server and drivers are host services accepted for now.
- Old programs may break when the language changes; the programs here are updated in the same change, and every old
  compiler stays in history.
- A claim counts when a run shows it.
