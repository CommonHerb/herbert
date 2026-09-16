# The C-free gen-1 seed (`michoi`)

`gen1.seed` is the native x86-64 ELF **gen-1 compiler** — the Herbert backend
(`stack/native_compile_fragment.herb`) compiled to a runnable binary. It is the
committed **C-free seed**: the test suite mints the production compiler by
running this seed, **not** by running the retired C bootstrap interpreter. Since
`castoff` (sovereignty link 18), the C interpreter is gone from the checkout;
the remaining tracked C source is `tools/scan.c`, a governance scanner used by
`make check`, not a Herbert execution path.

## What seed reproduction establishes

The emitter is a **pure, deterministic function of the backend source** — no
timestamp, PID, cwd, hostname, or randomness (verified). So the seed is
**byte-reproducible**: running the seed on the backend reproduces the seed
exactly (this is the `link10` self-hosting fixpoint, now C-free). Given the existing seed, anyone can reproduce its bytes from the corresponding
readable source and compare them. This establishes consistency and determinism;
the seed remains a trusted executable input to that process. Reproducing it is
not an independent derivation of its original provenance.

**Honest limit (trusting-trust):** the seed lineage began with a compiler minted
by the C interpreter. Later revisions are minted by earlier Herbert seeds. This
chain removes C from current mints but does not independently rule out a flaw
inherited from that original bootstrap. A fully
human-auditable *textual* seed (hex/asm that reproducibly materializes the same
bytes) is the deferred Oberon-ideal hardening.

## Structure

- Freestanding **static EXEC** ELF64, x86-64, entry `0x400078`, one `PT_LOAD`
  program header, zero sections, no `PT_INTERP`, raw Linux syscalls. No dynamic
  linker, no libc.
- Integrity is pinned by `gen1.seed.sha256` -- that file is the single authority for the
  value (it is NOT repeated here: a hash copied into prose rots on every legitimate
  reseed, and this README carried a stale one until the 2026-08-29 blind audit).
  The suite validates magic + sha256 before use and fails closed if either is wrong.

## Re-seeding (when the backend legitimately changes)

Edit the [compiler source stages](../../docs/COMPILER.md) and run
`make compiler-source` to refresh the checked assembled artifact first.
Any change to `stack/native_compile_fragment.herb` that shifts gen-1's bytes —
including a **comment edit that changes the net line count**, because the
compiler embeds source line numbers — makes this seed stale and the michoi seed
gate goes **RED**. That RED means *re-seed*, not *regression*:

```
make reseed          # re-mints gen-1 C-FREE: the committed seed recompiles the
                     # backend to its own fixpoint, checks it self-reproduces,
                     # rewrites gen1.seed + .sha256 (no C interpreter involved)
git add bootstrap/seed/gen1.seed bootstrap/seed/gen1.seed.sha256
make check && make test
```

(Post-switchover — sovereignty link `castoff` — the C bootstrap is gone, so the
seed re-mints **itself**: the old seed compiles the new backend to the new gen-1,
proven legitimate by the self-hosting fixpoint, not by a C diff.)

A builtin-emitter change can require a staged bootstrap: the old compiler may
embed its old implementation into the first new compiler, which then emits a
different second generation. `make reseed` intentionally refuses that mismatch
and leaves the seed unchanged. Retain an explicit generation chain, establish
byte-identical consecutive generations, then run the ordinary strict reseed
and behavioral gates. Never remove the fixpoint check to advance a bootstrap.
A newly introduced builtin also needs a capability stage before the compiler
source can adopt it; the checked-stdin landing followed that order.
