# Bootstrap Responsibility Map — RETIRED (the switchover is complete)

This file was the working map for **shrinking** Herbert's host-language (C)
bootstrap: a table of what each C source did, its Herbert-owned counterpart, and
the proof still owed before that C file could be deleted. **That migration is
finished.** At the switchover (sovereignty link 18) the C bootstrap interpreter
was retired and the native gen-1 ELF compiler — the committed
`bootstrap/seed/gen1.seed`, run as the production toolchain — became the sole way
Herbert source becomes machine code. The map has nothing left to track.

Where the retired C responsibilities now live (all C-free, all proven per push):

| Retired C source | C-free successor |
| --- | --- |
| `bootstrap/lex.c` | `stack/lexer_fragment.herb`, run natively by the seed (`run_lexer_native.sh`) |
| `bootstrap/parse.c` | `stack/parser_fragment.herb`, run natively (`run_parser_native.sh`); the production parser also self-hosts in `native_compile_fragment.herb` |
| `bootstrap/eval.c` | `stack/evaluator_fragment.herb` (tree-walk) + `stack/vm_fragment.herb` (bytecode), run natively (`run_evaluator_native.sh`, `run_vm_native.sh`) |
| `bootstrap/value.c` | the runtime value model lowered by the native back end (the fragments + the native-codegen gates) |
| `bootstrap/reclaim.c` | the C GC instrumentation assertions retired with C (`bootstrap/tests/run_tests.sh`'s muster classification); the later far-axis native reclamation surface is the kernel-arc tenement gate (`bootstrap/tests/run_native_codegen_link47.sh` plus its mutation proof, run as L31 in `.github/workflows/kernel-codegen-l1.yml`) |
| `bootstrap/util.c` | host helpers folded into the native back end |
| `bootstrap/main.c` | the native gen-1 driver + the harness; the metacircular toolchain runs via `run_klondike_native.sh` / `run_emitter_native.sh` |
| `bootstrap/herbert.h` | the native back end's own data contracts |

Self-consistency is guarded by the native self-hosting **fixpoint** `gen2 == gen1`
(checked per push); front-end and engine correctness by the six metacircular
**native-execution gates** (lexer/parser/evaluator/vm/klondike/emitter) against
independently-authored oracles; the kernel arc by the far-axis QEMU+Bochs
dual-substrate oracle. None of these uses C.

**Still C, by design:** `tools/scan.c` — the from-scratch boundary scanner
(`make check`) — is governance meta-tooling, not the Herbert interpreter, and is
kept. Its rehoming to Herbert is a separate, later sovereignty sub-link. The
committed seed remains C-minted **once** (the trusting-trust *textual-seed*
hardening is the remaining, deferred sovereignty residue).
