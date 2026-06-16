# Bootstrap Responsibility Map

This table is the working map for shrinking Herbert's host-language bootstrap.
It does not mark anything as replaceable by itself. A component becomes a
deletion candidate only after the missing proof is executable and reviewable.

## Replacement Readiness

| Host component | Current responsibility | Closest Herbert-owned surface | Current proof | Missing replacement proof |
| --- | --- | --- | --- | --- |
| `bootstrap/lex.c` | Tokenize source, comments, literals, operators, and line-sensitive diagnostics. | `stack/lexer_fragment.herb`, `stack/lexer_stdin_driver.herb`, `stack/lexer_error_driver.herb`, copied lexer sections in parser/evaluator/compiler fragments, `stack/error_probes/*.herb`. | `bootstrap/tests/run_tests.sh` drives `stack/lexer_probe`; `bootstrap/tests/run_lexer_equivalence.sh` normalizes C `lex()` output for an accepted-source corpus and diffs it against the Herbert stdin lexer driver, then checks the existing `lex_10x` malformed probes against the Herbert lexer diagnostic driver for ERR code, line, and message parity; the full error-probe battery still runs through C bootstrap and Klondike. | Add synchronization coverage for copied lexer sections before considering any C lexer deletion. |
| `bootstrap/parse.c` | Parse Herbert syntax into the C AST and report parse errors. | `stack/parser_fragment.herb`, parser sections in `stack/klondike.herb`, `stack/native_compile_fragment.herb`, and diagnostic fragments. | Parser probe output is compared against `stack/parser_probe.expected`; parse error probes are compared against `stack/error_probes.expected`. | A C-AST-to-Herbert-AST equivalence check over accepted programs plus parse-error equivalence over rejected programs. |
| `bootstrap/eval.c` | Execute Herbert programs, builtins, calls, control flow, mutation, and diagnostics. | `stack/vm_fragment.herb`, `stack/evaluator_fragment.herb`, `stack/klondike.herb`, `stack/suke_*_fragment.herb`. | Smoke tests, evaluator/vm probes, Klondike bundled runs, Suke echo/compute probes, and heap/scope caps run through the C interpreter. | A hosted-vs-Herbert VM differential runner over the smoke suite and selected stack probes, including stdout/stderr/exit behavior. |
| `bootstrap/value.c` | Represent runtime values, strings, arrays, tuples, buffers, and equality. | Herbert value encodings inside `stack/evaluator_fragment.herb`, `stack/vm_fragment.herb`, and `stack/klondike.herb`. | Existing VM/evaluator probes cover value operations indirectly through program output and heap/scope checks. | Focused value-model probes that compare equality, aliasing, mutation, string/buffer conversion, tuple access, array growth, and boundary errors across both implementations. |
| `bootstrap/reclaim.c` | Reclaim runtime objects and preserve bounded tail-recursive execution. | Tail-recursive scanner/parser/evaluator/VM loops in stack fragments. | `HERBERT_REPORT_PEAK` and `.maxscopes` / `.maxheap` checks guard selected smoke and Klondike cases. | A replacement-memory contract that records live scopes and heap behavior for both host and Herbert-owned execution on growing inputs. |
| `bootstrap/util.c` | Shared host helpers for allocation, strings, buffers, files, diagnostics, and fatal errors. | Herbert helper routines spread across stack fragments; no single module boundary exists yet. | Utility behavior is covered indirectly by all interpreter and stack runs. | A named utility contract with direct tests for each helper class before any helper can be replaced or removed. |
| `bootstrap/main.c` | CLI entrypoint, source loading, stdin handling, execution, and report flags. | `stack/output_echo_fragment.herb`, `stack/klondike.herb` stdin/bundle paths, Suke probes. | Output echo, Klondike IO, metacircular, and Suke probes exercise stdin/stdout behavior through the C entrypoint. | A runner contract for argv/stdin/stdout/stderr/exit/report flags, with Herbert-owned driver behavior compared to the current C CLI. |
| `bootstrap/herbert.h` | Shared host-language types, declarations, and ownership contracts. | No direct Herbert equivalent yet; closest surface is the emergent data contracts in stack fragments. | The C build and tests prove the header is internally consistent for the current host implementation. | A written and executable interface contract that names the data shapes Herbert must own before the C API can shrink. |

## Next Reviewable Slice

Continue with lexer equivalence. It is the smallest surface with a clear
Herbert-owned counterpart and existing probes. The C-vs-Herbert token-shape
oracle now covers a small accepted-source corpus plus lexer ERR code, line, and
message parity for the existing malformed lexical probes, but it still needs
copied-fragment synchronization before any C lexer code can be retired.

Candidate next tests:

- Keep accepted-source corpus growth cheap and focused on lexical constructs
  that have appeared in native/compiler probes.
- Add a copied-lexer synchronization check or remove unnecessary copied lexer
  bodies once a shared Herbert-owned surface exists.

The expected outcome of that slice is a new failing regression test first, then
the minimum harness code needed to make broader lexer equivalence visible. No
bootstrap file should be deleted in that slice.
