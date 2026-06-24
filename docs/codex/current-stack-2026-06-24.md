# Herbert Current Stack Handoff - 2026-06-24

Snapshot taken: `2026-06-24T21:23:12Z`

This note is a current navigation surface for the stacked Codex PRs after PR #5
and before this cleanup branch is published. It supersedes old todo
interpretation, not historical evidence. Keep the older append-only notes as
records of what was true when each note was written.

## Current PR Stack

- PR #3: `codex/sovereignty-audit-20260624` into `main`
  - URL: `https://github.com/CommonHerb/herbert/pull/3`
  - Head at snapshot: `e192db7b34e1f3a8f0023176a16b89c67a77409e`
- PR #4: `codex/fresh-eyes-breather-20260624` into
  `codex/sovereignty-audit-20260624`
  - URL: `https://github.com/CommonHerb/herbert/pull/4`
  - Head at snapshot: `eeb923f9925086ea2d31efb570d61f6e3494e838`
- PR #5: `codex/kernel-proof-hygiene-20260624` into
  `codex/fresh-eyes-breather-20260624`
  - URL: `https://github.com/CommonHerb/herbert/pull/5`
  - Head at snapshot: `0da5fe49926f78bcd1327339f3a25147120f9ffc`
  - Base for this current-stack cleanup branch.

At the snapshot time, PR #5 was the top published autonomous PR: open, draft,
mergeable, and clean. Its visible checks were green for
`0da5fe49926f78bcd1327339f3a25147120f9ffc`:

- Push or PR `check`: success, run `28125905631`.
- Push or PR `check`: success, run `28125931023`.
- `kernel-codegen-l1` / `l1-dual-substrate`: success, run `28125930972`.

Re-check GitHub before treating those check results as current.

## How To Read The Existing Notes

- `docs/codex/status-2026-06-24.md` is an append-only PR #3 status log. Its
  "this still needs commit/push/remote checks" lines were true at the time of
  those sections. Do not use them as the current todo list without checking
  later closeouts, branch tips, and GitHub.
- `docs/codex/sovereignty-audit.md` is the original PR #3 audit. Some of its
  recommended next steps were later completed by PR #4 and PR #5.
- `docs/codex/fresh-eyes-breather-2026-06-24.md` is the PR #4 handoff from
  `codex/sovereignty-audit-20260624`.
- `docs/codex/proof-hygiene-2026-06-24.md` is the PR #5 proof-contract note and
  is the most recent branch-local status note before this handoff.

## Current Proof Boundaries

- Local portable proof is `make verify-local`. It checks source/governance
  surfaces and static emulator-contract guards. It does not prove Linux/x86_64
  native execution, Bochs, KVM, or the full kernel workflow.
- `make test` and `make verify-linux` are Linux/x86_64 lanes. Do not claim them
  from a Darwin/arm64 run.
- The authoritative public kernel/module lane is
  `.github/workflows/kernel-codegen-l1.yml` with QEMU plus Bochs. KVM evidence is
  conditional on `/dev/kvm` being available in that run and reported green.
- Treat older "silicon" wording in scripts, comments, or logs as historical
  vocabulary unless the same run summary names which substrates actually ran.
- The kernel arc through native-codegen Link 52 is proof-mode frontier work. It
  is not a finished general OS, a general ELF loader, arbitrary-program compiler
  correctness, or SMP-safe TLB shootdown proof.
- `bootstrap/seed/gen1.seed` remains a once-C-minted trust root. Textual-seed /
  trusting-trust hardening remains deferred.

## Handoff Rule

Before continuing from this stack, re-anchor with:

```bash
git status -sb
git rev-parse HEAD
gh pr list --state open --limit 30
gh pr view 5 --json headRefName,baseRefName,headRefOid,statusCheckRollup
```

Then treat the current branch, SHA, PR state, and fresh check output as
authority. The docs are claim surfaces to audit, not authority by themselves.
