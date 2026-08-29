# AGENTS.md - Herbert core agent policy

This file is for Codex/Grok-style agents operating inside the Herbert core repo.
The core's canonical state and proofs live in the repo and MEWTWO canon; do not
treat any model output as a substitute for source reality or gates.

## Grok/xAI authority policy

Grok, Grok Build, Grok Composer, xAI models, and Grok CLI output are **never**
correctness authority in the Herbert core. Their only permitted role is optional,
explicitly labeled, non-blocking brainstorm or adversarial input.

Grok may not approve a landing, close a debt, replace Codex/Claude review,
overrule local gates, or be cited as evidence until every claim is independently
reduced to repo-local proof: reproducible command output, failing/passing tests,
byte-identical gates, line-specific diffs, or source-verified invariants.

If Grok is consulted, label the result as **unverified Grok advisory**. If Grok
conflicts with local gates, canon, Codex, Claude, or source reality, ignore
Grok.

## Cross-model review provenance (commit-message convention, 2026-08-29)

A herbert commit that cites a cross-model verdict (Codex `LAND` / `LAND-WITH-CHANGES(n)` /
`CONFIRM-LAND` / `BLOCK`, or a Claude review) is a POINTER, not proof: the durable review
artifact lives one repo up, under `MEWTWO/audits/<dir>/<file>.md` (CONSTITUTION A7: workflow
transcripts are ephemeral; the verified artifact is what persists). From 2026-08-29 every such
commit names that artifact path in its body, so a herbert-only reader can find the evidence
instead of taking the verdict on faith -- the same bar this file already sets for Grok. Older
commits (before this convention) are covered by the audit directories listed in
`MEWTWO/audits/` by link name.
