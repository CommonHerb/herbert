# The C-retirement SWITCHOVER — historical record (sovereignty links 17-18)

This file is the historical record of the irreversible event in which the C
bootstrap interpreter was deleted and the native gen-1 seed became Herbert's
sole production toolchain. The event was executed by `castoff`:
`e231a7127a2d576e9caf5704b6e80e47cfe0b475` (sovereignty link 18).

The pre-event recipe `bootstrap/tests/apply_switchover.sh` and the dry-run
machinery are kept for auditability and regression pressure around C absence.
Current operating truth lives in the Makefile, `VERIFYING.md`,
`BOOTSTRAP-RESPONSIBILITIES.md`, the switchover gates, and CI results.

> **Status: EXECUTED.** The prose below preserves the original decisions and
> dispositions around the switchover. Read future-tense language as historical
> pre-`castoff` planning unless a current gate or source file says otherwise.

---

## 1. What the switchover was (and was not)

The C interpreter could not be de-C'd piecewise — you could not delete `parse.c`
while `eval.c` still `#include`d the tree it built. It was a **single event**:
the native ELF compiler (already minting the production compiler from the
committed `bootstrap/seed/gen1.seed`) became the toolchain, and the C interpreter
+ its sources + the tests that existed only to grade it were removed **at once**.

**Scope of the event (the C-interpreter retirement):**
- the C interpreter: `bootstrap/{eval,lex,main,parse,reclaim,util,value}.c` + `bootstrap/herbert.h`
- the 2 C equivalence dumpers: `bootstrap/tests/{lexer,parser}_equiv_dump.c`
- the 5 retire-tests (below)
- the inline C-grading residue of `run_tests.sh` (the classification in §3)
- the C-coupled Makefile targets + CI steps (§4)

**Explicitly NOT in this event** (separate, later sovereignty questions — see §2):
- `tools/scan.c` (the `make check` from-scratch guard) — a governance meta-tool, not
  the Herbert interpreter; its rehoming-to-Herbert is its own tee'd-up sub-link.
- the trust-root **textual seed** (provenance hardening of `gen1.seed`).
- the `.sh`/`.bin`/`.expected` test scaffold sovereignty question.

---

## 2. Decided dispositions (the open questions, resolved)

| # | question | decision | why |
|---|---|---|---|
| 1 | `tools/scan.c` — retire or keep? | **KEEP** through this event; rehome-to-Herbert is a separate tee'd-up sub-link | `scan.c` is the `make check` from-scratch *governance guard*, not the Herbert interpreter or any Herbert run-path. Deleting it AT the sovereignty switchover would silently drop the Constitution's day-one boundary enforcement. Retiring the interpreter ≠ retiring the meta-tooling. The headline "the C **interpreter** is retired" is true; "zero C bytes in the repo" is honestly not-yet (scan.c remains until separately rehomed). **Surfaced to Ben for veto.** |
| 2 | parser-equivalence's 39-file corpus + structure-twins breadth, lost vs `run_parser_native`'s 1 probe | **ACCEPT the loss** | The C-vs-Herbert equivalence altimeters (`harlan`/lexer-equiv/parser-equiv) are **pre-switchover instruments**: their value (de-risking the production parser/lexer against C) is realized *while C exists*. Post-switch, the C parser IS gone — there is nothing to be equivalent *to*. Native parser correctness post-switch is covered by `run_parser_native` + every `run_native_codegen_link*` gate (the parser parses the whole backend each self-compile) + the fixpoint. The corpus could optionally be retained as a native-only golden test later; not required. |
| 3 | GC instrumentation metrics (`peak-heap`/`peak-scopes`; smoke + test_10/13/14a/14b) lost | **ACCEPT** (retire-with-C) | These metrics are emitted only by the C interpreter and guard **C's own** mark-sweep GC (`gulpin`). With C gone there is no C GC to guard. The *native* heap-reclamation question is **D16**, which `muster` established is **not** a switchover prerequisite (far-axis-tethered, retires-with-C by Ben's policy). You stop testing the thing you deleted. |
| 4 | `run_beta_full.sh` (L2 metacircular nesting under C) lost | **ACCEPT** (retire-with-C) | Tests the C interpreter's own metacircular capability. The *native* metacircular capability is the self-hosting fixpoint `gen2==gen1` (checked per push). |
| 5 | the 3 "C-did-not-grade" fence pretests (turnstile/tollgate/muster fence-mutation) | **RETIRE** at the switch | Each deliberately invokes C to prove "the default run did NOT grade with C." Post-C that property is **vacuously true** (C cannot be invoked) and unprovable. They are scaffolding for the *transition*, not permanent gates. |
| 6 | `SWITCHOVER_DRY_RUN` / dry-run scaffolding fate | **TRANSITIONAL** → folds into the deletion | The dry-run gate (`run_switchover_dryrun.sh`) and recipe (`apply_switchover.sh`) are switchover-machinery. After the event, the bite-proofs they exercise are simply the normal C-free gates; the recipe + the `RETIRE_*` manifest classes are spent and are removed in the same commit (or kept as a historical record — Ben's call). |
| 7 | the `switchover-cfree` bite-proof's C-coupling (M-leak / M-incomplete) | **M-leak RETIRES, M-incomplete RETARGETS** | `apply_switchover.sh` performs this: M-leak ("the tombstone detects C use") is inherently vacuous when C cannot be invoked → retire-with-C; M-incomplete (drops the deleted `run_smoke.sh` row) retargets to a surviving CFREE_KERNEL row. Validated green post-deletion. |
| 8 | CI target topology post-switch | `check.yml` drops `make smoke` + the implicit C build; `make test` runs the C-free suite; `kernel-codegen-l1.yml` drops its "build the C bootstrap" step (the kernel gates are seed-emit already). `make check` is **unchanged** (scan.c kept, disposition #1). |
| 9 | platform scope | unchanged — the native toolchain is **x86-64-Linux by construction**; the switchover does not change the target. |
| 10 | cache / clean state | the event must run from a **clean build** (`make clean`); no stale `build/herbert`/`build/scan`/`*.o` may be reused. The dry-run asserts this (`run_switchover_dryrun.sh` clean-state precondition). |

---

## 3. The inline `run_tests.sh` classification (the residue muster/drydock left)

`drydock` classified the `run_*.sh` gates; `muster` classified the 15 foundational
`test_*.herb`. The **inline** residue of `run_tests.sh` (graded directly under the C
interpreter, not via a `run_*.sh`) was lumped as one opaque `HARNESS` row. A full
C-absent run (this link's empirical map) enumerates it. **Every inline test is
classified below; none is in limbo.** All are **RETIRE_WITH_C** (each tests the C
interpreter itself, or is the C-interp leg of a test whose C-free **native** gate is
the enduring leg and survives):

| inline family | count | disposition | reason / C-free successor |
|---|---|---|---|
| `test_02/11/12` (foundational, whole) | 3 | RETIRE_WITH_C | native diverges on output (muster) |
| `test_10/13/14a/14b` GC assertion | 4 | RETIRE_WITH_C | `.maxscopes`/`.maxheap` = C GC instrumentation (muster); output stays native-graded |
| recursion-depth guard probes | 7 | RETIRE_WITH_C | tests the **C** parser/printer depth diagnostic (2026-05-28 root hardening) |
| `stack/error_probes/*` (lex/parse/sem/count) | ~60 | RETIRE_WITH_C | tests the **C bootstrap's** located error diagnostics (line-numbered) |
| fragment C-interp forcing (`lexer/parser/evaluator/vm/emitter_probe`) | ~6 | RETIRE_WITH_C | the C-interp leg; the **native** gate (`run_{lexer,parser,evaluator,vm,emitter}_native.sh`, in the frozen 24-surface) is the enduring C-free leg |
| klondike-under-C metacircular (`klondike_io/metacircular_compute/pipeline/tail_dispatch_probe`, beta-medium nest) | ~6 | RETIRE_WITH_C | metacircular run under C; the native klondike gate (`run_klondike_native.sh`) is the enduring leg; fixpoint covers self-hosting |
| suke (`suke_compute/suke_echo_probe`) | ~6 | RETIRE_WITH_C | runs the suke fragments under C |
| `output_echo_fragment` (ordinary/binary payload) | 2 | RETIRE_WITH_C | runs the output-echo fragment under C |
| C-grade fence pretests (turnstile/tollgate/muster mutation) | 3 | RETIRE (disposition #5) | prove "C did not grade" — vacuous post-C |
| retireable C cross-checks (aggregate-render M-sep; the native gates' `*_NO_C` legs) | n | RETIRE_WITH_C | default-on opt-out C cross-checks; the enduring native leg survives |

The **C-free remainder** of `run_tests.sh` (what survives) is exactly: the 12 muster
native-output foundational tests (graded by `run_aggregate_render_native.sh`), the 6
fragment **native** gates, the `run_native_codegen_link*` gates, the aggregate-render
gate, and the 7 bite-proofs' enduring legs — i.e. **drydock's frozen 24-gate surface +
the bite-proofs**, every one already proven to stand C-absent (drydock + this link).

---

## 4. The ordered recipe (what the irreversible event did)

`bootstrap/tests/apply_switchover.sh <clean-checkout>` was the pre-event
executable recipe for **steps 1–3 + 7** and the mechanical proof of **4–5**. The
`castoff` commit completed the remaining `run_tests.sh`, Makefile, CI, allowlist,
responsibility-map, and reseed surgery in the live tree.

1. `make clean` (no stale C artifact may survive — disposition #10).
2. **delete** the C interpreter (8 files), the 2 dumpers, the 5 retire-tests (§1).
3. **reconcile** `switchover_manifest.tsv` — drop the `RETIRE_WITH_C` + `RETIRE_AT_SWITCH`
   rows (their scripts are gone); the partition stays exhaustive over the survivors.
4. **reconcile** the `switchover-cfree` bite-proof — retire M-leak, retarget M-incomplete
   (disposition #7).
5. **excise** `run_tests.sh`'s inline C-residue (§3): remove the foundational retire-set
   routing, the recursion-depth guard, the `error_probes` loop, the fragment C-interp
   forcing tests, the klondike-under-C + suke + output-echo blocks, the 3 fence pretests,
   and the `$HERBERT` precondition; flip the native gates' retireable `*_NO_C` cross-checks
   permanently off.
6. **edit the Makefile**: drop `$(HERBERT)` + its `HERBERT_SRCS` rule, the `smoke` /
   `lexer-equivalence` / `parser-equivalence` / `beta-full` / `reseed` targets, the
   `$(HERBERT)` prerequisites + the `test` target's `$(MAKE) $(HERBERT)`; `make check`
   (scan.c) is unchanged (disposition #1).
7. **edit CI**: `check.yml` drops `make smoke` + the implicit C build;
   `kernel-codegen-l1.yml` drops "build the C bootstrap (build/herbert)".
8. update `BOOTSTRAP-ALLOWLIST` (remove the deleted C-source entries) +
   `BOOTSTRAP-RESPONSIBILITIES.md`.
9. **verify**: `make check` green; `make test` (now C-free) green; the native
   self-host fixpoint `gen2==gen1` holds (it never used C); `make switchover-cfree` green.

After the event, `bootstrap/seed/gen1.seed` is the sole trust root (still C-minted
ONCE — the textual-seed hardening, disposition's separate sub-question, remains).

---

## 5. Irreversibility after the greenlight

This event **deletes** the only differential oracle the project has had since day one.
After it, there is no `C_interp` to diff native behavior against — the native toolchain
is self-validated (the fixpoint) + substrate-validated (the far-axis QEMU+Bochs oracle).
That is **by design** (sovereignty = the stack owes nothing to C), and the foundation
carries it (`muster` proved D13/D16 were not switchover prerequisites; every C-free gate
was proven to stand C-absent). Ben gave the greenlight and `castoff` performed the
irreversible deletion. New work should treat C as gone, not as a hidden fallback, and
should label any claim that still depends on the once-C-minted seed or host harnesses
as a remaining trust boundary.
