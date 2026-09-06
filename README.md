# Herbert

Herbert is the living source repo inside the copied MEWTWO stabilization workspace.

This repository is a bootstrapping language/runtime project. Judge it by the code and verification harness, not by archived narrative material outside this repo.

## Layout

- `bootstrap/` contains the committed native gen-1 seed, verification harnesses,
  native-codegen goldens, references, and switchover machinery.
- `stack/` contains the Herbert-written language, VM, and native compiler, and the kernel/module proof
  programs -- with one provenance qualifier a cold reader must have (CONSTITUTION A14, 2026-07-16):
  roughly 45% of `stack/native_compile_fragment.herb` (at `438f7f6`: 555,252 of 1,243,817 bytes in 46
  hex literals across 24 blob families) is **Python-minted x86 machine code replayed byte-for-byte** --
  the `multiboot32-<link>` baked-kernel emit modes for kernel-arc links whose kernels were authored by
  the `bootstrap/tests/*_ref.py` builders (29 of the 49 kernel-arc links are blob replay; 16 early/32-bit
  links are source-emitted; the 4-link long64 spine, `taproot`..`gyre`, is Herbert-authored). A14 froze
  that blob-replay chain as VERIFICATION SUBSTRATE, not as Herbert-authored progress, and for those
  links the byte-pin leg compares against the same `*_ref.build_elf()` that produced the blob. The
  only progress authority is the scorecard one repo up, `BLUESTONE/tools/scorecard.sh` (from this
  directory: `../../tools/scorecard.sh`), which recomputes these figures fresh on every run.
- `bootstrap/tests/` contains sample interpreter tests, stack probes, native-codegen links, Python reference builders, golden artifacts, and kernel runners.
- `tools/` contains guard and verification helpers, including the remaining C
  governance scanner.
- `.github/workflows/` contains CI verification surfaces.

## Development Rule

Prefer executable verification over claims. If a statement about Herbert cannot be tied to code, a test, a golden, or a runner, treat it as provisional.

Start with `VERIFYING.md` before changing behavior.

Use `ROADMAP.md` as the living map for what is proven, aspirational, unknown,
and next.
Use `BOOTSTRAP-RESPONSIBILITIES.md` to choose the next host-bootstrap
replacement proof.

## Hosted process output

Ordinary Linux/x86_64 programs can use `stderr_write(bytes)` with one string
argument. It writes raw bytes to standard error and returns an integer: zero
after complete transfer, otherwise a positive Linux errno. It retries EINTR and
continues after partial writes; a nonempty write making zero progress returns
EIO (5). Empty input succeeds without a syscall. Failure may follow a partial
transfer: the result is not a byte count or an all-or-nothing guarantee. The
inherited SIGPIPE disposition is unchanged, so a broken pipe may terminate the
process rather than return an error.

Use `stderr_write` in an expression (for example, bind its result with `let`);
`do stderr_write(...)` is rejected because it produces a value.

`do process_exit(status)` accepts one integer and terminates the process with
its low eight bits as the exit status, without rendering `main`'s return value.
It is not a value expression. The compiler still requires the existing return
structure and checks statements following this call; it does not infer a
never-returning type. Both names are reserved builtin function names. These
operations are not additions to the VM or kernel target interfaces.

This is a capability-only addition. Normal `main` return rendering and the old
`clogger`, `flogger`, and `fwriter` behavior are unchanged. The compiler itself
does not yet use the new operations: its legacy status-zero/stdout diagnostics
and unsafe fixed-name output publication still need separate repairs.
