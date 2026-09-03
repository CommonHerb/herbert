# Verifying Herbert

This repo has several verification levels. They are intentionally separate because each one proves a different amount.

## Local Smoke

```bash
make verify-local
```

Runs:

- `make check`: confirms tracked non-`.herb` files exactly match `BOOTSTRAP-ALLOWLIST` (the from-scratch boundary scanner `tools/scan.c` — kept governance meta-tooling, not the retired interpreter).
- `make test-timeout`: checks the repo-local portable `timeout` shim.
- `make test`: the full non-emulator harness (see below).
- `make evaluator-native` / `vm-native` / `parser-native` / `lexer-native` / `klondike-native` / `emitter-native`: the six metacircular fragments compiled to ELF by the committed gen-1 seed and run with **no C**, each diffed against its independently-authored oracle, plus a RED-first mutation proof.
- `make error-vocab-native`: the C-free re-gating of klondike.herb's located **front-end error vocabulary** (ERR 101–316) — the gen-1 seed compiles klondike (a 1-line `main` adapter; `klondike.herb` byte-identical) and feeds it the 54 malformed `error_probes` fixtures; each must emit the hand-authored manifest's ERR code (independent anchor) **and** the committed golden diagnostic (regression pin), with gate-time metamorphic checks (line-shift + payload-rename at five extraction sites) proving the diagnostic tracks the input, plus a RED-first mutation proof. Restores the assurance `castoff` spent when it deleted the C-driven `error_probes` differential (`klaxon`, sovereignty link 19). Distinct from the native-codegen seed's own subset vocabulary (ERR 4xx/5xx), which the native-codegen reject battery gates.
- `make lexer-copy-sync`: checks that accepted-token lexer copies in the stdin/parser/evaluator/emitter and Suke fragments stay synchronized with `stack/lexer_fragment.herb` (the line-aware token contract).
- `make native-codegen-diagnostics`: checks the local helper used to enrich kernel QEMU mismatch logs.
- `make switchover-cfree`: proves the C-free production surface stands with the C interpreter PHYSICALLY ABSENT, then proves it bites RED-first.

This is the fast local confidence command. It does not run the full emulator-heavy kernel suite.

## Full Non-Emulator Suite

```bash
make test
```

Runs the main shell harness in `bootstrap/tests/run_tests.sh`.

This target requires a Linux/x86_64 host because the native-codegen links mint and execute Linux ELF artifacts. The Makefile prepends `tools/` to `PATH`, so Linux hosts without GNU `timeout` can still run bounded test legs.

On macOS or non-x86_64 hosts the aggregate `make verify-local` is NOT runnable: it depends on `make test` (which refuses such hosts) and on the native rungs, which mint and execute Linux/x86_64 ELF artifacts. The individually portable checks are `make check`, `make test-timeout`, and `make lexer-copy-sync`; run everything else in Linux CI or an equivalent Linux/x86_64 environment (a VM is fine).

QEMU-emulated x86_64 Linux on Apple Silicon is useful for targeted reproduction,
but it may be too slow for the default full-suite timeouts in deeper
Klondike/metacircular/native-compile legs. Treat CI or real Linux/x86_64
hardware as the authoritative `make test` lane.

This suite exercises the native gen-1 toolchain, the stack fragments run natively, the metacircular native-execution gates, and the native-codegen links — all **C-free** (the C bootstrap interpreter was retired at the switchover). It is still not the same as the emulator-heavy kernel workflow.

## Kernel/Module Gate

The heavy kernel/module proof chain lives in `.github/workflows/kernel-codegen-l1.yml`.

That workflow installs QEMU, Bochs, GRUB, Xvfb, and disk tooling on Linux, then runs the later native-codegen kernel/module links and mutation gates with `KERNEL_CODEGEN_REQUIRE_EMU=1`.

Local runs can silently shrink if emulator prerequisites are absent. Treat the workflow as the authoritative gate for those links.

**Local emulator convention (2026-08-28; QEMU_PREFIX knob added 2026-08-31):** to run kernel gates
locally against the CI-pinned QEMU version when the distro package lags, set the durable knob:
`QEMU_PREFIX=/opt/qemu-10.2.1 bash bootstrap/tests/run_native_codegen_linkNN.sh` (or the same on
`make kernel-verify`). `QEMU_PREFIX` must be an ABSOLUTE path and `$QEMU_PREFIX/bin/qemu-system-x86_64`
must be a REGULAR executable FILE; that directory is then prepended to PATH. Anything else FAILS
LOUD rather than silently falling back to the system qemu (the silent-downgrade footgun the knob
retires). *(Guard tightened 2026-09-02: it had been a bare `-x` test, which is TRUE for a DIRECTORY
and says nothing about the prefix being absolute — and a relative prefix installs a relative PATH
entry that stops resolving after any `cd`. Both shapes were demonstrated passing the old guard and
then resolving to the system `QEMU emulator version 8.2.2`, the F8-aborting major.)*
**`QEMU_PREFIX` names the PREFIX DIRECTORY, never the binary** — the guard looks for
`$QEMU_PREFIX/bin/qemu-system-x86_64`, so `QEMU_PREFIX=/opt/qemu-10.2.1` is right and
`QEMU_PREFIX=/opt/qemu-10.2.1/bin/qemu-system-x86_64` fails loud. **And what sits at that path must be
the real emulator or an `exec`-style wrapper — never a plain wrapper script.** The guard accepts any
regular executable, and a non-`exec` wrapper exits normally (128+n) when its child is signal-killed,
which hides `WIFSIGNALED` from the status-preserving boot runner: a killed guest can then grade as a
completed boot. `replay_discriminator.sh`'s COVERED / NOT COVERED block states that limit; this is its
operator-facing half. (Blind Opus 5 refuter + Codex refutation leg, 2026-09-02.)
Coverage is EVERY qemu-invoking gate — 101 scripts under `bootstrap/tests` name
`qemu-system-x86_64` and all 101 carry the knob, 29 with the block INLINE and the other 72 by sourcing
`native_codegen_oracle.sh` — and since 2026-09-02 the knob is established BEFORE the gate's own
`command -v qemu-system-x86_64` availability probe in every one of the 99 that carry such a probe (the
remaining 2 carry none, so the ordering question does not arise there). *(Until then 12 gates —
`run_native_codegen_link18..29_mutation.sh` — probed FIRST and sourced the oracle five or six lines
later (six in eleven of them, five in `link29_mutation.sh`, which carries one comment line fewer), so
a correctly pinned prefix made them print `SKIP: … (no qemu)` rc 0, or `FAIL: … (mutation proof
requires QEMU)` rc 1 under `KERNEL_CODEGEN_REQUIRE_EMU=1`, while `$QEMU_PREFIX/bin/qemu-system-x86_64`
sat executable on disk. STANDALONE only — both drivers `export PATH="$QEMU_PREFIX/bin:$PATH"` before
spawning a gate (`run_tests.sh` by sourcing the oracle, `kernel_verify.sh` from its own inline block),
so a full local sweep resolved the pinned emulator anyway, and CI sets no `QEMU_PREFIX` at all;
standalone is nonetheless the exact scenario the knob exists for.)*
**Residual, NOT closed — do not read the coverage sentence above as covering the fail-open `source`
class.** That same 2026-09-02 repair also made those 12 gates fail closed when the oracle cannot be
sourced (`unset CDPATH`, a checked `cd --`, a guarded `source`). It was applied to those 12 ONLY.
`run_native_codegen_link30`/`link31`/`link32_mutation.sh` carry the identical
source-then-probe-then-`exit 0` shape with a bare `source`, and 92 scripts under `bootstrap/tests`
still bare-source the oracle (13 fail closed). With the oracle made unreadable and a valid pinned
prefix on disk:

```
link30 rc=0 | SKIP: native-codegen link30 mutation (no qemu)
link18 rc=1 | FAIL: cannot source .../native_codegen_oracle.sh -- the shared oracle carries this gate's …
```

`native_codegen_oracle.sh`'s own `script_dir` computation is likewise neither CDPATH-protected nor
`|| exit`-checked. STANDALONE invocation is the whole surface: `run_tests.sh` and `kernel_verify.sh`
both `unset CDPATH` — which clears the export for every child they spawn — and establish the knob
before spawning. Named by the blind confirm leg, 2026-09-02; closing this class is a separate packet,
not a side effect of that one.* The block itself lives
**INLINE in 29 files** — `native_codegen_oracle.sh`, `kernel_verify.sh`, `replay_discriminator.sh`,
`larder_phaseA_gate.sh`, and the 25 `*_mutation.sh` gates — which are exactly the files that invoke
qemu while sourcing no oracle. Every OTHER qemu-invoking gate (the `run_native_codegen_linkNN.sh`
gates, none of which carry the block themselves) inherits it by **sourcing**
`native_codegen_oracle.sh`. There is **no shared `qemu_prefix.sh` helper** — a DRY helper was
written and deliberately dropped: it would be a new git-tracked non-`.herb` file, and
`BOOTSTRAP-ALLOWLIST` says the list "shrinks toward empty as Herbert becomes able to host itself"
and that "adding a line here is a deliberate, reviewable act, never incidental" — so growing it is
a call to be made deliberately, not a bug-fix side effect. Inline also keeps each of those 29 files
self-protecting when run STANDALONE, which is the exact scenario the knob exists for. Settled
2026-09-01: keep inline, the boundary does not grow. **(Corrected 2026-08-31 — until then the knob lived in exactly TWO
files, `native_codegen_oracle.sh` and `kernel_verify.sh` (2 of 29), on the false premise that the
oracle was "the one file every gate sources"; the other 27 silently IGNORED it. Found by the
tranche-1b blind diff audit. Corrected again 2026-09-01 — the sentence that replaced it named a
shared `qemu_prefix.sh` that was never committed and does not exist on disk. Corrected a THIRD time
2026-09-02 — this paragraph had itself said the knob lived "only in the oracle", which
`git show --stat --format= d03f516` (it touches `bootstrap/tests/kernel_verify.sh` **and**
`bootstrap/tests/native_codegen_oracle.sh`) and that same commit's own VERIFYING.md line
(`prepended to PATH by ``native_codegen_oracle.sh``/``kernel_verify.sh```) both refute.)** The bare per-shell `PATH=/opt/qemu-10.2.1/bin:$PATH` prefix still works identically.
The gates deliberately resolve `qemu-system-x86_64` from PATH —
nothing in the tree hardcodes a host-local prefix, and CI (which sets neither) is unaffected. The local Bochs is
2.7+dfsg-4build5 vs CI's pinned 2.8+dfsg-1: fine for smoke, and the CI run stays the authoritative
substrate for Bochs legs. F2-hardened gates (bochs_f2_harness.sh) classify harness failures
(missing grub-pc-bin, loop-mount races, dead feeders) instead of mis-scoring them as kernel REDs.

## What These Commands Do Not Prove

- They do not prove arbitrary-program compiler correctness.
- They do not prove a finished OS.
- They do not, on their own, re-establish the trusting-trust provenance of the committed seed (the C bootstrap interpreter has been removed at the switchover; the seed remains C-minted once, and the textual-seed hardening is the remaining deferred sovereignty residue).
- They do not make old archived docs current.

They prove the specific executable surfaces each command invokes.
