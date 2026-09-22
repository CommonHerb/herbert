# Working on the compiler

The production compiler is Herbert source compiled by the committed Linux/x86-64
seed. The source is maintained as ordered stage files under `stack/compiler/`;
`stack/native_compile_fragment.herb` is the tracked assembled artifact consumed
by existing self-hosting, native, kernel and historical gates. This is explicit
source composition, not a module system or a new bootstrap path.

| Source unit | Responsibility |
| --- | --- |
| `frontend_vm.herb` | Shared lexer/parser, diagnostic support, VM and AST/bytecode machinery |
| `types_and_inference.herb` | Native diagnostics, types, signatures and inference |
| `metadata.herb` | Bytecode validation, typed stack analysis and per-instruction metadata |
| `hosted_emitter.herb` | Hosted instruction layout, native runtime and ELF emission |
| `kernel_targets.herb` | Preserved kernel targets, including frozen historical byte fixtures and source-authored long64 paths |
| `driver.herb` | Input checks and top-level target dispatch |

The order is declared once by `COMPILER_SOURCES` in the Makefile. Concatenation
adds no separators, banners or rewritten newlines. The initial split reproduces
the prior complete source exactly. This matters: compiler source locations can
be embedded in emitted diagnostic paths, so even moving unchanged code can
change a seed. Stage files need not compile independently and share function
names through the assembled program. Some stages remain large; this establishes
maintainable boundaries without claiming that the whole compiler is modular.

## Editing and qualification

Edit the appropriate stage file, then run `make compiler-source` to refresh the
assembled source. `make compiler-source-check` rejects any mismatch; `make check`
includes it. Membership checking also rejects missing, duplicate or unlisted
`.herb` stage files and symlinks within the stage directory; declared units must
be regular non-symlink files. Checks never silently regenerate the artifact and hide a stale or
manually edited copy. `compiler-source` retains the previous assembled file in a fresh
`stack/.compiler-source.*` directory when it changes that file, and reports the
path. Inspect both sets of edits before rebuilding; this preserves a mistaken
direct edit for recovery. Failed composition candidates are retained and named.
The seed remains independently pinned by its checksum. `make test` alone does
not check composition; use `make check` or the aggregate `make verify-local`.

For a real compiler change, follow `VERIFYING.md`: qualify behavior and faults,
run `make reseed`, prove the self-hosting fixpoint and execute applicable hosted
and target gates. Include `make compiler-metadata` when changing metadata or its
consumers; `verify-local` includes that check. Expected output changes require independently justified expectations;
do not regenerate frozen C-derived goldens from the seed as a new oracle.
Mutation harnesses may deliberately alter a disposable assembled compiler;
that is a test artifact, not a second authoring location.

`make reseed` checks the previous seed's exact checksum pin before executing it,
requires both generations' complete success envelopes and matching executable
bytes, and runs hosted conformance before publishing a changed candidate. It
retains failed work and refuses inputs changed during qualification. Publication
replaces the seed and checksum separately; an interruption between replacements
can leave a detectable mismatch, with the previous pair retained in the failed
work directory. Use one writer. This does not replace full hosted/target
qualification or establish independent seed provenance.

## Metadata stage contract

`nc_analyze_program(pool, prog, sig)` consumes emitted bytecode and resolved type
signatures. `prog.0` holds functions, `prog.1` strings and `prog.2` the main
index. Each function carries bytecode in field 4, NEW_ARRAY type metadata in
field 5 and source-line metadata in field 6; both metadata arrays must match
the instruction count, and the code must end in RET. It returns `(error, metas, has_input, has_heap)`; on nonzero error,
the partial metadata is not valid emission input. Each successful function has
one metadata record, produced by `nc_build_one_meta`. Layout is in flattened
machine words, not source parameter counts. Types, bytecode opcode numbers and
function layouts are supplied by the preceding stages; the following hosted
emitter consumes the result.

The metadata walk advances through instruction positions in order. Each
successful instruction contributes exactly one entry to each of `tuple_meta`,
`call_meta` and `heap_meta`, including a default entry when that
opcode does not use that stream. Consumers index by instruction position.
A call or tuple operation must never shift later entries. Never rebuild an
instruction-count array merely to change one entry: the runtime's bump allocator
keeps every discarded copy for the compiler process's lifetime.

Control-flow edges are strictly forward. Conditional branches snapshot the
operand stack and local types at their target; short-circuit branches retain
their boolean on the taken edge and pop it on the expression-evaluation edge.
At each instruction, merge only reachable predecessors. A local is definitely
initialized only if every reaching predecessor initializes it. Unconditional
BR and RET have no fallthrough; a returning arm cannot contaminate the types of
the continuing arm. The shared `stmt_ends_return` predicate recognizes exhaustive
nested conditionals for both lowering and inference. A conditional without an
else cannot establish a definite return.

Branch snapshots are separate from frame layout. Each local slot records its
stored types for layout even when its path returns before the final instruction;
that slot still needs storage. The existing supported rebinding rules keep its
flattened width stable: every `let` allocates a fresh slot, scope exit never reuses
it, and assignments resolve a binding whose declaration dominates the store.
Frame layout takes the last stored type under those invariants; any future slot
reuse must revisit layout width validation rather than assuming that remains
safe. The unknown type ID marks an uninitialized local; initialized values with
partially unresolved aggregate types may still be refined at a join.
No per-instruction stack/local snapshot table is built:
states are saved on branch edges. This is a forward join pass, not a fixed-point
algorithm for backward branches, and does not eliminate the existing copying
cost when a local-type array is updated.

The live `nc_fail` emits a diagnostic and exits the process with status 1.
Nominal nonzero-status paths must likewise stop before appending or consuming
failed metadata; partial arrays have no successful-layout contract. Do not
backfill them or emit an image after an error. Changes to tuple,
call or heap layouts need nontrivial controls in those categories, exact compiler
status/stream checks, emitted-byte comparisons where bytes should stay fixed,
and realistic resource measurements. A successful scalar example alone does
not qualify these interfaces.

The fields of a successful function metadata record are:

| Index | Meaning |
| ---: | --- |
| 0–2 | Flattened parameter words, return type, return words |
| 3–5 | Local bases, local widths, total local words |
| 6–8 | Hidden return-pointer slot, call-result scratch base, maximum result scratch words |
| 9 | Legacy empty stack array (not a per-instruction snapshot stream) |
| 10 | Per-instruction tuple metadata |
| 11 | Per-instruction call metadata |
| 12 | Maximum operand-stack words |
| 13 | Input kind: 0 none, 1 clogger, 2 stdin_read |
| 14 | Per-instruction heap metadata |
| 15 | Heap-use flag |

Dense stream indices are bytecode instruction positions, never source-token or
machine-code byte offsets. Tuple entries are `(wholeTupleWords, selectedStartWord,
selectedWords)` with default `(0 - 1, 0 - 1, 0 - 1)` (each word is all 64 bits set). Call entries are `(argWords, retWords,
kind)`, where kind 0/1 means scalar/hidden-return-pointer call and 2/3 the respective
tail-call forms; their default is zero. Heap entries are `(kind, elemWords,
elemType)`, with kinds 1 array creation, 2 get, 3 add and 4 buffer creation;
buffer creation is `(4,0,0)` and the default is zero. There is no later patching.
Stream construction is linear in instruction count. The pre-existing tail-call
check separately scans the function body for each candidate; this does not claim
linear complexity for the full pass or compiler, or control-flow fixed-point
verification.

## Comprehensibility evidence

A source map is not proof that another maintainer can repair the stage. Cold
maintenance exercises pin guide/source/seed hashes, withhold the defect and
expected answer, and execute the returned repair against held tests. The
September 15 quality audit records that bounded exercise separately from model
review. A successful narrow task does not establish comprehension of the whole
compiler, kernel or stack.
