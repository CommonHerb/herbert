# Native Ecosystem Covenant

This covenant governs how Herbert's ecosystem grows without relaxing
Herbert's native-sovereignty goal.

## Hard Rule

New executable project code must be Herbert, Herb, or a clearly named
Herbert-family language created inside the Herbert ecosystem. Shell, Python, C,
Rust, Node, Docker, CI, and host operating systems may remain as existing
substrate for invocation and verification, but they are not deliverables and do
not count as Herbert-native progress.

## Surface Classification

| Surface | Current Role | Classification | Replacement Direction |
| --- | --- | --- | --- |
| `bootstrap/seed/gen1.seed` | Production compiler seed; Linux/x86_64 ELF | Required substrate | Preserve while pursuing textual-seed hardening and self-hosting fixpoints |
| `stack/*.herb` and `stack/compiler/*.herb` | Herbert-owned lexer, parser, evaluator, VM, compiler, and probes | Native core | Expand only with executable proof |
| `checks/*.herb` and `checks/*.cases` | The checks and their cases: programs with their right answers, built and run by the seed | Native core | The Python and shell checks they replaced left on 2026-11-25 (tag `python-checks-2026-11-25`) |
| `tools/scan.herb` | Governance scanner for `BOOTSTRAP-ALLOWLIST`, built by the seed | Native core | Replaced the C scanner after a differential against it; checked by `checks/scans.herb` |
| `tools/reseed.herb` | The seed maker behind `make reseed`, built by the seed | Native core | Took over from a shell script after both gave the same seeds; checked by `checks/seeds.herb` |
| `BOOTSTRAP-ALLOWLIST` | Explicit non-`.herb` boundary | Intentionally external for now | Keep strict; shrink only when replacements are verified |
| `.github/workflows/*` | CI substrate | Required external substrate | Keep as public evidence, not Herbert-native code |

## Native Ledger Candidate

`stack/native_surface_ledger.herb` is the first Herbert-authored surface ledger
candidate; a case in `checks/fragments.cases` holds what it lists. It does not
replace `BOOTSTRAP-ALLOWLIST` or the allowlist scanner.
