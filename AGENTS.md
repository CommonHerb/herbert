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

**AMENDED 2026-09-02 — the convention now covers PARENT-seat artifacts too.** As first written it said
the durable artifact "lives one repo up, under `MEWTWO/audits/`", a location that cannot express a
review run by the BLUESTONE parent seat, which lives TWO repos up. Reviews reach this repo from both
seats, so the rule is: name the artifact path wherever it lives — `MEWTWO/audits/<dir>/<file>.md` for a
core-seat review, `BLUESTONE/audits/<dir>/<file>.md` for a parent-seat one. The refutation panel behind
the 2026-09-02 harness-repair commit, for instance, is
`BLUESTONE/audits/window-2026-09-01/delta-refutation/DELTA-REFUTATION.md`, and the packet that
chartered those repairs is `BLUESTONE/audits/window-2026-09-01/PACKET-DELTA-FINDINGS.md`. (Found by
the blind Opus 5 refuter, 2026-09-02: the first draft of this section paid one old debt while leaving
the gap that a herbert-only reader still could not find the evidence for the very commit adding it.)

**The convention stands; the one commit that broke it is pointered here.** A census of every herbert
commit since it landed (`ed736a0`, 2026-08-29) found exactly one violation: `6a5c1e9` (2026-08-31)
cites "the tranche-1b blind diff audit (2026-08-31)" and names no `MEWTWO/audits` path
(`git log -1 --format=%B 6a5c1e9 | grep -c 'MEWTWO/audits'` -> `0`); the other seven commits comply.
A pushed commit body is not rewritten here, so the pointer is recorded once, in this file: that
review artifact is **`MEWTWO/audits/discriminator-sweep-2026-07-17/TRANCHE-1B-REMAINDER.md`**, section
`PRE-PUSH BLIND PANEL (2026-08-31)`. What the record actually supports, stated exactly: that section
first appears in MEWTWO commit `68dc3b2` (`2026-08-31 21:19:28 -0500`) and is absent from its
predecessor `2020e48` (`20:02:23`), so it was COMMITTED 1m48s AFTER herbert `6a5c1e9`
(`21:17:40 -0500`) — consistent with a review that ran before the push (`68dc3b2`'s own subject calls
it a pre-push blind panel) and written to canon just after. An earlier draft of this paragraph cited
the artifact's mtime instead; that was wrong on its face (`ls -l --time-style=full-iso` reports
`2026-09-02 00:10:38`, the file having been edited since) and mtime is not provenance evidence in any
case. Corrected 2026-09-02 by the blind Opus 5 refuter, finding 1.
