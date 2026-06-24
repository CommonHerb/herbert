# Herbert

Herbert is the living source repo inside the copied MEWTWO stabilization workspace.

This repository is a bootstrapping language/runtime project. Judge it by the code and verification harness, not by archived narrative material outside this repo.

## Layout

- `bootstrap/` contains the committed native gen-1 seed, verification harnesses,
  native-codegen goldens, references, and switchover machinery.
- `stack/` contains Herbert-written language, VM, native compiler, and kernel/module proof programs.
- `bootstrap/tests/` contains sample interpreter tests, stack probes, native-codegen links, Python reference builders, golden artifacts, and kernel runners.
- `tools/` contains guard and verification helpers, including the remaining C
  governance scanner.
- `.github/workflows/` contains CI verification surfaces.

## Development Rule

Prefer executable verification over claims. If a statement about Herbert cannot be tied to code, a test, a golden, or a runner, treat it as provisional.

Start with `VERIFYING.md` before changing behavior.

Use `ROADMAP.md` as the living map for what is proven, aspirational, unknown,
and next.
Use `BOOTSTRAP-RESPONSIBILITIES.md` to choose the next host-bootstrap
replacement proof.
