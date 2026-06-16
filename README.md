# Herbert

Herbert is the living source repo inside the copied MEWTWO stabilization workspace.

This repository is a bootstrapping language/runtime project. Judge it by the code and verification harness, not by archived narrative material outside this repo.

## Layout

- `bootstrap/` contains the C seed interpreter/runtime, parser, evaluator, value model, garbage collector, and test harness.
- `stack/` contains Herbert-written language, VM, native compiler, and kernel/module proof programs.
- `bootstrap/tests/` contains sample interpreter tests, stack probes, native-codegen links, Python reference builders, golden artifacts, and kernel runners.
- `tools/` contains guard and local verification helpers.
- `.github/workflows/` contains CI verification surfaces.

## Development Rule

Prefer executable verification over claims. If a statement about Herbert cannot be tied to code, a test, a golden, or a runner, treat it as provisional.

Start with `VERIFYING.md` before changing behavior.

Use `CODEX-ROADMAP.md` as the living branch map for what is proven,
aspirational, unknown, and next on the CODEX review lane.
