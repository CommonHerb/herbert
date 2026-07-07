# Native Ecosystem Covenant Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the first mergeable native-only Herbert ecosystem slice: a covenant/audit document, Herbert-authored examples that run today, and a Herbert-authored candidate ledger tool.

**Architecture:** Keep executable deliverables in `.herb` files only. Non-`.herb` files are documentation, expected outputs, or existing host substrate declarations tracked by `BOOTSTRAP-ALLOWLIST`; they do not become new project tooling. Verification uses the existing C-free `bootstrap/seed/gen1.seed` on Linux/x86_64 and the existing Mac-valid guard commands.

**Tech Stack:** Herbert `.herb`; existing Makefile guard; existing Linux/x86_64 seed compiler; existing GitHub branch workflow.

## Global Constraints

- Work only on the isolated branch `native-ecosystem-covenant-20260625`; do not merge to `main`.
- Do not add new non-native executable project code.
- New executable project code must be Herbert, Herb, or a clearly named Herbert-family language created inside this repository.
- Shell, Python, C, CI, Docker, Colima, and macOS may be used only as existing invocation or verification substrate.
- Do not weaken existing gates or delete existing host surfaces prematurely.
- Every tracked non-`.herb` file added by this plan must be listed in `BOOTSTRAP-ALLOWLIST`.
- Verify behavioral claims with executable evidence from current files and command output.

---

### Task 1: Native Covenant And Surface Audit

**Files:**
- Create: `docs/native-ecosystem.md`
- Modify: `BOOTSTRAP-ALLOWLIST`

**Interfaces:**
- Consumes: `README.md`, `ROADMAP.md`, `VERIFYING.md`, `SWITCHOVER.md`, `BOOTSTRAP-RESPONSIBILITIES.md`, `Makefile`, `BOOTSTRAP-ALLOWLIST`
- Produces: `docs/native-ecosystem.md`, the branch's human-readable covenant and surface classification

- [ ] **Step 1: Write the covenant document**

Create `docs/native-ecosystem.md` with these sections:

```markdown
# Native Ecosystem Covenant

This branch grows Herbert's ecosystem without relaxing Herbert's native-sovereignty goal.

## Hard Rule

New executable project code must be Herbert, Herb, or a clearly named Herbert-family language created inside the Herbert ecosystem. Shell, Python, C, Rust, Node, Docker, CI, and host operating systems may remain as existing substrate for invocation and verification, but they are not deliverables and do not count as Herbert-native progress.

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

This branch starts with documentation plus `.herb` programs only: examples that show what Herbert can make today, and a native ledger candidate that records the current replacement map from inside Herbert.
```

- [ ] **Step 2: Add the document to the allowlist**

Insert this exact line under the stable docs group in `BOOTSTRAP-ALLOWLIST`:

```text
docs/native-ecosystem.md
```

- [ ] **Step 3: Stage the document and verify the guard**

Run:

```bash
git add BOOTSTRAP-ALLOWLIST docs/native-ecosystem.md
make check
```

Expected:

```text
OK: 353 tracked non-.herb file(s) match BOOTSTRAP-ALLOWLIST
```

- [ ] **Step 4: Commit**

Run:

```bash
git commit -m "docs: define native ecosystem covenant"
```

### Task 2: Herbert Examples That Run Today

**Files:**
- Create: `examples/native_today_arithmetic.herb`
- Create: `examples/native_today_collections.herb`
- Create: `examples/native_today_io.herb`
- Create: `examples/native_today_arithmetic.expected`
- Create: `examples/native_today_collections.expected`
- Create: `examples/native_today_io.expected`
- Modify: `BOOTSTRAP-ALLOWLIST`

**Interfaces:**
- Consumes: existing Herbert language subset proven by `bootstrap/tests/test_01_arith.herb`, `test_07_array.herb`, `test_08_strings_buffer.herb`, `test_09_ref_vs_value.herb`, and `stack/klondike_io_probe.herb`
- Produces: small `.herb` example programs and byte-exact expected outputs

- [ ] **Step 1: Write `examples/native_today_arithmetic.herb`**

```text
-- Native-today example: arithmetic, comparisons, recursion, and tuples.

func fib(n):
    if n <= 1:
        return n
    end
    return fib(n - 1) + fib(n - 2)
end

func main():
    let a = 21 + 21
    let b = fib(8)
    let ok = a == 42 and b == 21
    return (a, b, ok)
end
```

- [ ] **Step 2: Write `examples/native_today_arithmetic.expected`**

```text
(42, 21, true)
```

- [ ] **Step 3: Write `examples/native_today_collections.herb`**

```text
-- Native-today example: arrays, buffers, strings, and reference semantics.

func append_marker(xs, marker):
    do add(xs, marker)
    return count(xs)
end

func main():
    let xs = new_array(int)
    do add(xs, 5)
    do add(xs, 8)
    let n = append_marker(xs, 13)

    let b = new_buffer()
    do append(b, 'h')
    do append(b, 'e')
    do append(b, 'r')
    do append(b, 'b')
    let s = freeze(b)

    return (n, get(xs, 0), get(xs, 2), length(s), equal(s, "herb"))
end
```

- [ ] **Step 4: Write `examples/native_today_collections.expected`**

```text
(3, 5, 13, 4, true)
```

- [ ] **Step 5: Write `examples/native_today_io.herb`**

```text
-- Native-today example: runtime input and output through the current native ABI.

func main():
    let incoming = clogger()
    do flogger("HERBERT-NATIVE-TODAY\n")
    return length(incoming)
end
```

- [ ] **Step 6: Write `examples/native_today_io.expected`**

```text
HERBERT-NATIVE-TODAY
5
```

- [ ] **Step 7: Add expected files to the allowlist**

Insert these exact lines in `BOOTSTRAP-ALLOWLIST`:

```text
examples/native_today_arithmetic.expected
examples/native_today_collections.expected
examples/native_today_io.expected
```

- [ ] **Step 8: Stage support files and verify each example under the seed**

Use the existing Linux/x86_64 seed compiler. For each example, compile with `bootstrap/seed/gen1.seed`, run the emitted `a.out`, and compare stdout to the matching `.expected`.

Run before `make check` so the guard sees the new `.expected` files as tracked:

```bash
git add BOOTSTRAP-ALLOWLIST examples/
```

Expected outputs are byte-exact:

```text
examples/native_today_arithmetic.herb -> (42, 21, true)
examples/native_today_collections.herb -> (3, 5, 13, 4, true)
examples/native_today_io.herb with stdin "abcde" -> HERBERT-NATIVE-TODAY\n5
```

- [ ] **Step 9: Commit**

Run:

```bash
git commit -m "examples: add native-today Herbert programs"
```

### Task 3: Herbert-Written Native Surface Ledger Candidate

**Files:**
- Create: `stack/native_surface_ledger.herb`
- Create: `stack/native_surface_ledger.expected`
- Modify: `BOOTSTRAP-ALLOWLIST`
- Modify: `docs/native-ecosystem.md`

**Interfaces:**
- Consumes: surface classification from Task 1
- Produces: a `.herb` program that emits the first native-owned ledger of substrate classes

- [ ] **Step 1: Write `stack/native_surface_ledger.herb`**

```text
-- Herbert-written candidate ledger for native ecosystem surface tracking.
-- It does not replace BOOTSTRAP-ALLOWLIST yet; it proves the ledger can exist
-- inside Herbert before any host scanner or manifest is deleted.

func line(s):
    do flogger(s)
    do flogger("\n")
    return 0
end

func main():
    do line("native: stack/*.herb")
    do line("required-substrate: bootstrap/seed/gen1.seed")
    do line("required-substrate: .github/workflows")
    do line("replace-soon: tools/scan.c")
    do line("replace-later: bootstrap/tests/*.sh")
    do line("replace-later: bootstrap/tests/*_ref.py")
    do line("evidence: committed expected/golden artifacts")
    return 7
end
```

- [ ] **Step 2: Write `stack/native_surface_ledger.expected`**

```text
native: stack/*.herb
required-substrate: bootstrap/seed/gen1.seed
required-substrate: .github/workflows
replace-soon: tools/scan.c
replace-later: bootstrap/tests/*.sh
replace-later: bootstrap/tests/*_ref.py
evidence: committed expected/golden artifacts
7
```

- [ ] **Step 3: Add the expected file to the allowlist**

Insert this exact line in `BOOTSTRAP-ALLOWLIST`:

```text
stack/native_surface_ledger.expected
```

- [ ] **Step 4: Link the ledger from the covenant**

Append this paragraph to `docs/native-ecosystem.md`:

```markdown
## Native Ledger Candidate

`stack/native_surface_ledger.herb` is the first Herbert-authored surface ledger candidate. It does not replace `BOOTSTRAP-ALLOWLIST`, `tools/scan.c`, or any shell/Python harness. It exists beside them until a future branch proves parity and makes deletion safe.
```

- [ ] **Step 5: Stage support files and verify the ledger under the seed**

Run before `make check` so the guard sees the new `.expected` file as tracked:

```bash
git add BOOTSTRAP-ALLOWLIST docs/native-ecosystem.md stack/native_surface_ledger.herb stack/native_surface_ledger.expected
```

Compile and run `stack/native_surface_ledger.herb` with `bootstrap/seed/gen1.seed` on Linux/x86_64 and compare stdout to `stack/native_surface_ledger.expected`.

Expected stdout begins with:

```text
native: stack/*.herb
```

Expected stdout ends with:

```text
7
```

- [ ] **Step 6: Commit**

Run:

```bash
git commit -m "stack: add native surface ledger candidate"
```

### Task 4: Branch Verification And Push

**Files:**
- No new files

**Interfaces:**
- Consumes: all files changed in Tasks 1-3
- Produces: pushed branch with evidence

- [ ] **Step 1: Run Mac-valid guards**

Run:

```bash
make check
make test-timeout
make lexer-copy-sync
make native-codegen-diagnostics
```

Expected:

```text
OK: tracked non-.herb file(s) match BOOTSTRAP-ALLOWLIST
PASS: timeout wrapper
PASS: lexer copy sync
PASS: native-codegen qemu diagnostics
```

- [ ] **Step 2: Record the expected Mac host boundary**

Run:

```bash
make test
```

Expected on Darwin/arm64:

```text
FAIL: make test requires a Linux/x86_64 host.
```

- [ ] **Step 3: Run Linux/x86_64 seed smoke for new `.herb` files**

Use the existing `herbert-x86` Colima profile or another Linux/x86_64 host. Compile and run:

```text
examples/native_today_arithmetic.herb
examples/native_today_collections.herb
examples/native_today_io.herb
stack/native_surface_ledger.herb
```

Compare each stdout to its `.expected`.

- [ ] **Step 4: Push the branch**

Run:

```bash
git status --short
git log --oneline --decorate -n 5
git push -u origin native-ecosystem-covenant-20260625
```

Expected:

```text
branch 'native-ecosystem-covenant-20260625' set up to track 'origin/native-ecosystem-covenant-20260625'
```
