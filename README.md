# Herbert

Herbert is the living source repo inside the copied MEWTWO stabilization workspace.

This repository is a bootstrapping language/runtime project. Judge it by the code and verification harness, not by archived narrative material outside this repo.

## Layout

- `bootstrap/` contains the committed native gen-1 seed, verification harnesses,
  native-codegen goldens, references, and switchover machinery.
- `stack/` contains the Herbert-written language, VM, and native compiler, and the kernel/module proof
  programs -- with one provenance qualifier a cold reader must have (CONSTITUTION A14, 2026-07-16):
  roughly 45% of `stack/native_compile_fragment.herb` (at `438f7f6`: 555,252 of 1,243,817 bytes in 46
  hex literals across 24 blob families) is **Python-minted x86 machine code replayed byte-for-byte** --
  the `multiboot32-<link>` baked-kernel emit modes for kernel-arc links whose kernels were authored by
  the `bootstrap/tests/*_ref.py` builders (29 of the 49 kernel-arc links are blob replay; 16 early/32-bit
  links are source-emitted; the 4-link long64 spine, `taproot`..`gyre`, is Herbert-authored). A14 froze
  that blob-replay chain as VERIFICATION SUBSTRATE, not as Herbert-authored progress, and for those
  links the byte-pin leg compares against the same `*_ref.build_elf()` that produced the blob. The
  only progress authority is the scorecard one repo up, `BLUESTONE/tools/scorecard.sh` (from this
  directory: `../../tools/scorecard.sh`), which recomputes these figures fresh on every run.
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
