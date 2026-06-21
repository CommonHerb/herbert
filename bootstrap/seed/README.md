# The C-free gen-1 seed (`michoi`)

`gen1.seed` is the native x86-64 ELF **gen-1 compiler** — the Herbert backend
(`stack/native_compile_fragment.herb`) compiled to a runnable binary. It is the
committed **C-free seed**: the test suite mints the production compiler by
running this seed, **not** by running the C bootstrap interpreter. This removes
the C interpreter from the gen-1 *mint* path (the first step of retiring the C
bootstrap). C is still present for the differential oracle and the interpreted
stack/metacircular probes — those are later links.

## Why a committed binary is sound here

The emitter is a **pure, deterministic function of the backend source** — no
timestamp, PID, cwd, hostname, or randomness (verified). So the seed is
**byte-reproducible**: running the seed on the backend reproduces the seed
exactly (this is the `link10` self-hosting fixpoint, now C-free). The seed is
therefore not an opaque trust anchor you must take on faith — it is a *cache* of
an artifact anyone can regenerate from readable source and `cmp`.

**Honest limit (trusting-trust):** these bytes were minted by the C interpreter
*once*, at seed-creation time. The seed removes C from all *future* mints, but it
does not by itself prove the bytes carry no C-introduced flaw. A fully
human-auditable *textual* seed (hex/asm that reproducibly materializes the same
bytes) is the deferred Oberon-ideal hardening.

## Structure

- Freestanding **static EXEC** ELF64, x86-64, entry `0x400078`, one `PT_LOAD`
  program header, zero sections, no `PT_INTERP`, raw Linux syscalls. No dynamic
  linker, no libc.
- Integrity is pinned by `gen1.seed.sha256`
  (`4af3dbee…ec7a0`). The suite validates magic + sha256 before use and fails
  closed if either is wrong.

## Re-seeding (when the backend legitimately changes)

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
