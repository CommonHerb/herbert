# Native Ecosystem Covenant

This branch grows Herbert's ecosystem without relaxing Herbert's
native-sovereignty goal.

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
| `stack/*.herb` | Herbert-owned lexer, parser, evaluator, VM, compiler, and probes | Native core | Expand only with executable proof |
| `bootstrap/tests/*.sh` | Existing host harnesses for C-free proofs, goldens, mutation gates, and CI-local coordination | Required substrate | Replace gradually with Herbert-owned manifests and native runners after parity |
| `bootstrap/tests/*_ref.py` | Reference builders and graders for kernel/module links | Replaceable later | Preserve until Herbert-native reference builders or substrate witnesses exist |
| `tools/scan.c` | Governance scanner for `BOOTSTRAP-ALLOWLIST` | Replaceable soon | Build a Herbert candidate beside it before deleting C |
| `BOOTSTRAP-ALLOWLIST` | Explicit non-`.herb` boundary | Intentionally external for now | Keep strict; shrink only when replacements are verified |
| `.github/workflows/*` | CI substrate | Required external substrate | Keep as public evidence, not Herbert-native code |
| committed `.expected` and golden artifacts | Regression or oracle data | Required evidence | Keep until Herbert-native generation and checking can prove parity |

## First Mergeable Slice

This branch starts with documentation plus `.herb` programs only: examples that
show what Herbert can make today, and a native ledger candidate that records the
current replacement map from inside Herbert.
