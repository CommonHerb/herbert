# Herbert language guide

This is the canonical practical guide to ordinary hosted Herbert on Linux/x86-64.
Use the source and committed seed from this same checkout; the seed integrity pin
lives in `bootstrap/seed/gen1.seed.sha256`. A cold maintenance exercise records
the guide, compiler-source and seed hashes together before starting. This guide
is not a guarantee that every malformed program is diagnosed cleanly.

Sections 1–7 retain their hosted scope. The September 12 addition below describes
reusable byte mutation and the explicit Linux interface. New OS feature work is
paused; the earlier long64 addendum remains a description of preserved work.
Executable qualification and its limits are described in [VERIFYING.md](../VERIFYING.md).
The examples below are complete programs for the ordinary hosted seed.

## 1. What Herbert is

Herbert is a small, self-hosting statically-typed language whose gen-1 **seed is a compiler** (a freestanding x86-64 ELF): it reads Herbert **source on stdin** and writes a compiled native executable to `./a.out`. A program is a sequence of `func` definitions with a zero-argument `func main()` entry point, whose return value is auto-rendered to stdout. There are **no loops** — iteration is expressed with recursion. The seed implements the native subset described below; semantic coverage and runtime resource handling are not complete.

## 2. THE SEED-NATIVE SUBSET (accept vs reject — read this first)

Stay inside the **accept-list**. Unsupported or malformed programs are not guaranteed to fail cleanly in every case; the explicit boundaries below matter.

**ACCEPTED (proven to compile + run):**
- `func NAME(params): <body> end`, with `func main()` taking **zero** params.
- Statements: `let NAME = EXPR`, `NAME = EXPR` (rebind existing), `return EXPR`, `do CALL(...)` (void builtins only), `if/elif/else/end`.
- Infix arithmetic `+ - *` and all six comparisons `< <= > >= == !=` (all uint64, modular wrap). `/ %` exist but fault on a zero divisor.
- Self, non-tail, and mutual (cross-function) recursion; see G2 for stack-use limits. **No loop keywords exist.**
- Tuples `(a, b, c)` as values and as `main`'s return; positional access `t.0 t.1 …` (chainable `t.2.0`).
- Hosted builtins described here: `new_array` `add` `count` `get` `length` `equal` `index` `new_buffer` `append` `freeze` `flogger` `fwriter` `clogger` `stdin_read` `stderr_write` `process_exit`. Type syntax uses `int bool string buffer array`.
- `--` line comments.

The shared front end also recognizes low-level names used by specialized targets; recognition alone does not put them in this hosted accept-list. Hosted `fwriter(bytes)` publishes to the fixed name `a.out`: it writes an exclusively created temporary file, syncs and closes it, then renames it over the directory entry. It preserves the previous output on a prepublication failure and replaces a destination symlink without following it. Failure exits the process with a diagnostic; it is not a general file API. The directory must be trusted. Publication is atomic for concurrent readers, not a promise of directory durability after power loss; cleanup after failure is best effort.

**THE ERR-419 REJECT TRAP (the one a cold model hits first):** the native subset has **no list/cons/car/cdr primitives**. Any call to a name that is neither a user `func` you defined nor a recognized builtin falls through to `nc_fail(419,…)`. This fires for `empty(x)`, `first(x)`, `rest(x)`, `plus(...)`, `map`, `head`, `nil`, etc. Exact message printed to **stderr**, with exit status **1**, empty stdout, and **no new `a.out`**:

```
line N: native-subset: unknown callee 'first' (ERR 419)
```

Build sequences with `new_array(TYPE)` + `do add(a,x)` + `get(a,i)` + `count(a)` instead of list primitives. (User-defined functions ARE allowed and encouraged — ERR 419 means only "this name resolves to nothing.")

**Native rejection examples:** wrong user-call or ordinary hosted builtin arity `420`; `slice` `438`; `freeze/append` on non-buffer `437`; `get/count` on non-array `435`; array element-type mismatch `436`; type mismatch e.g. `flogger` of a non-string `430`; a void builtin used as a value `440`; tuple `.N` out-of-range/on-non-tuple `431`; `main` returning an array or a tuple containing an array, or exceeding the render-word cap `432`; more than one input operation (`clogger`/`stdin_read` combined) `411`. Empty input or no `main` produces a **program-level** `ERR 429`, not a located line diagnostic; other uses of code 429 can be located. Unknown variable names and assignment to an undefined name currently use `ERR 404`. For supported ordinary calls, argument count is checked before inspecting the arguments; `new_array` type syntax has its separate structural rules. These examples do not promise every malformed builtin invocation has a clean diagnostic or override earlier whole-program checks.

**Compiler rejection envelope:** checked lexical errors (`101`–`110`), checked structural errors (`201`–`212`, plus duplicate parameter `311`), and native rejections print one diagnostic to **stderr**, leave stdout empty, and exit with status **1**. They preserve an existing `a.out`; output existence alone is not success. Checked input failure prints `compiler: stdin read failed (errno N)\n`; output-publication failure prints `compiler: output publication failed\n`. Both use stderr, empty stdout and status 1, and preserve the previous output before publication. Whole-source lexical, structural and AST/operator-class checks precede reachability-based native inference. This does **not** promise the globally earliest source-position error. Uncalled functions and statements after a return are structurally checked, but do not receive uniform semantic checking.

Distinguish the two processes when reading faults. If **the compiler** (`seedbin`) emits `herbert: line N: get: position ... out of range` on stderr while compiling, that is an internal compiler fault; `N` can refer to the compiler's own source. If **your compiled program** (`a.out`) emits the same-shaped message while running, it is an ordinary runtime bounds fault, with the line of your program's offending call. Report the former as a compiler defect; investigate your own indexing or appended byte value for the latter.

Some inherited structural messages are imprecise: ERR 205 says `'do' must be followed by a call` even for some invalid statements without `do`; ERR 208 also covers extra `new_array` arguments; missing clause colons can report an expected expression or `end`. These are known diagnostic-quality defects, not intended explanations of every rejected source. This pack describes the production hosted compiler, not the separate older Klondike semantic driver's error vocabulary.

## 3. Grammar & primitives

**The only function keyword is `func`. There is NO `fn`/`func` alternative and no `while/for/loop`.** 18 reserved words: `func let return do if elif else end and or not true false int bool string buffer array`.

```
program := func*
func    := 'func' NAME '(' params? ')' ':' body 'end'      -- body = 1+ statements (empty body = ERR 209)
params  := NAME (',' NAME)*                                  -- 0 allowed; main() must take 0
stmt    := 'let' NAME '=' expr        -- local binding; see current shadowing behavior below
         | NAME '=' expr              -- rebind an EXISTING binding (undefined = ERR 404; changing width = ERR 433)
         | 'return' expr             -- exactly one value; write an explicit return on every path
         | 'do' call                 -- statement call to a VOID builtin only
         | 'if' expr ':' body ('elif' expr ':' body)* ('else' ':' body)? 'end'
```

The native compiler currently permits repeated `let` bindings in one scope and same-width `int`/`bool` rebinding; do not assume the older full-language `ERR 301` duplicate-let rule is enforced here. Return-path diagnostics are also incomplete: a body with no return can report `ERR 424`, and a partial-return body can reach `ERR 415` rather than a dedicated missing-return error. Do not mistake these observations for a settled, complete semantic contract.

**Comments:** `--` to end of line only. No block comments. A recognized leading `-- emit: ...` marker selects a specialized compiler route before ordinary hosted validation; those routes are outside this pack.

**Expression precedence, loosest → tightest** (all binary tiers left-associative):
`bitwise (& | ^ << >>)` < `or` < `and` < `cmp (== != < > <= >=)` < `add (+ -)` < `mul (* / %)` < `prefix (not, ~)` < `dot (.N)` < atom.
- **There is NO unary minus.** Prefix unary is only `not` (boolean) and `~` (one's-complement int). Write negation-of-a-constant as modular subtraction: `0 - 1` is `18446744073709551615`, not `-1`.
- **Bitwise/shift operands must be parenthesised/atomic and single-class.** Unparenthesised mixing like `a & b | c`, `a << 2 + 3`, `x & 1 == 0` is rejected `ERR 442`. Fully-parenthesised forms parse: `(a & b)`, `(x << 2)`.
- **Atoms:** integer literal, char literal `'x'` (a byte value / int), string literal `"…"`, `true`, `false`, a bare NAME, a call `NAME(args)`, or a parenthesised group/tuple.

**Integer model — 64-bit UNSIGNED, modular:** literals are decimal, unsigned, must fit in 64 bits (`ERR 103` otherwise). `+ - *` keep the low 64 bits (wrap): `18446744073709551615 + 1 == 0`. `/ %` are unsigned and **fault on a zero divisor**. Shifts mask the count with `& 63`. Comparisons are unsigned. There are no negatives and no floats.

**Records = tuples (there are no named-field records).** `(a, b, c)` is a tuple; a single `(e)` is just grouping. Read fields positionally, `.0 .1 .2 …`, chainable (`outer.2.0`). A non-integer token after `.` is a structural `ERR 206`; an out-of-range literal or projection on a non-tuple is a native `ERR 431`.

**Arrays / buffers / strings (the growable collections):**
- `new_array(TYPE)` — the type arg is mandatory (`new_array()` = ERR 208). Grow with `do add(a, v)`; read `get(a, i)`; size `count(a)`.
- `new_buffer()` — a growable byte buffer. `do append(buf, byteVal)` appends one byte; `freeze(buf)` yields an **immutable string**.
- Strings: `length(s)`, `index(s, i)` (returns the byte), `equal(s1, s2)` (returns `bool`, rendered as `true`/`false`, not an integer). (`slice` is NOT in the subset → ERR 438; cut strings by building a buffer.)
- Arrays and buffers are **reference values** — mutation through an alias/parameter is visible everywhere. The current hosted allocator does not reclaim discarded allocations during a run; bounded tail-call stack use does not imply bounded heap use. Avoid allocation-heavy unbounded loops.
- Runtime `get` and `index` check bounds; `append` checks the byte is in `0..255`. A violation terminates the generated program with a located diagnostic on stderr. These runtime faults are separate from compile-time type/arity rejection.
- **TYPE expressions** appear only inside `new_array(...)`: `int | bool | string | buffer | array(T) | (T, T, …)` (tuple type needs ≥2 elems; `(int)` alone = ERR 211).

**Builtins:**
- **VALUE** (usable in expressions): `new_array(T)` `new_buffer()` `freeze(x)` `length(x)` `count(x)` `get(coll,i)` `index(str,i)` `equal(a,b)` `clogger()` `stdin_read()` `stderr_write(str)`.
- **VOID** (MUST be called as `do CALL(...)`): `add(arr,v)` `append(buf,byte)` `flogger(str)` `fwriter(str)` `process_exit(status)`. Using a void builtin as a value = `ERR 440`; ordinary `do` on a value builtin currently reaches native `ERR 404`. A non-call expression after `do` is structural `ERR 205`.

**Recursion is the only iteration.** The "for loop" idiom is a helper that tail-recurses on an index with an accumulator:
```
func loop(i, n, acc):
    if i >= n:
        return acc
    end
    return loop(i + 1, n, acc + i)
end
```
Tail-call optimization is **conditional**, not a general language guarantee yet. The compiler needs a recognized tail position, a resolved callee return type, and matching flattened **argument and return** widths. The loop idiom above meets those conditions; unequal-width mutual tail calls can still use the hardware stack and overflow. Strings and tuples may occupy more than one machine word, so source parameter count alone is not the criterion. **Non-tail** recursion also uses the hardware stack — see G2. The compiler does not diagnose every unsupported tail-call shape.

## 4. THE I/O IDIOM — how a program prints its result

Normal result rendering, raw output, and explicit process termination:

**(a) When `main()` returns normally, its value is auto-rendered to stdout, followed by a single `\n`.** To print an integer, just `return <int-expr>` from `main`. Explicit process termination in (d) bypasses this renderer.
- `int` → unsigned decimal, e.g. `42\n`
- `bool` → `true\n` / `false\n`
- `string` → **with surrounding double-quotes**, e.g. `"hello"\n`
- `tuple` → `(a, b, c)\n` with `", "` separators
- `main` may **not** return an array/buffer (ERR 432).
- **Render-word cap:** an aggregate (tuple) return must flatten to **2..15 words** — `int`=1 word, `bool`=1, `string`=2, nested tuple = sum of children. `>15` → ERR 432 (15 ints OK; 16 ints or 8 strings → ERR 432).

**(b) `do flogger("...")`** — a void statement taking exactly **one string** arg; writes the raw bytes to stdout with **no added newline**. Because `main`'s return is still rendered afterward, `do flogger("hi")` then `return 7` prints `hi7\n`. Build a dynamic string with `new_buffer()`+`do append`+`freeze`, then `do flogger(freeze(buf))`.

**(c) `stderr_write(bytes)`** — a value builtin taking one string; writes raw bytes
to stderr, adding nothing. Returns integer zero after complete transfer, otherwise
a positive Linux errno. It retries interrupted writes and advances after partial
writes. Empty input succeeds without a syscall; zero progress on nonempty input
returns EIO (5). An error can occur after a partial transfer, so retrying the whole
message may duplicate bytes. SIGPIPE handling is inherited and can terminate the
process on a broken pipe. This is a Linux-hosted interface, not a kernel intrinsic.

**(d) `do process_exit(status)`** — takes one integer and exits with its low eight
bits as process status; there is no main-result rendering. Unlike `return 7`
(stdout `7\n`, process status 0), `do process_exit(7)` produces status 7. Keep a
trailing `return` to satisfy the compiler's current return/type analysis; following
statements are still checked. No never-returning type or new return-path analysis
is implemented. These builtin names are reserved against function definitions.

**Input:** prefer `stdin_read()`, which returns `(errno, bytes)`. Zero errno means a complete read through EOF; a positive Linux errno means failure and the returned string is empty. Short reads continue and EINTR is retried. The compiler itself uses checked input before selecting any emit route. The result is a whole-input allocation, not a streaming interface. At arena capacity a one-byte probe distinguishes exact-fit EOF from excess input; excess consumes that byte and returns errno 12 (ENOMEM) with an empty string. Initial arena mapping failure occurs before `main` and is outside this result contract.

Use **at most one syntactic input operation in `main`**, then pass its string to helpers. The limit counts `clogger` and `stdin_read` together, including occurrences in mutually exclusive branches or after a return. Multiple input operations produce ERR 411; a reached helper containing one produces ERR 404. `clogger()` remains available with its older string-only behavior, which can mistake read errors for EOF; new programs should use the checked interface.

```herbert
func main():
    let input = stdin_read()
    if input.0 != 0:
        let ignored = stderr_write("cannot read standard input\n")
        do process_exit(1)
        return 0
    end
    return length(input.1)
end
```

## 5. THE COMPILE + RUN COMMAND

The seed reads source on **stdin** (a filename argument is IGNORED — passing a filename with empty stdin gives ERR 429), writes the ELF to **`./a.out` in the cwd**, and prints just `0` to stdout on success. **`a.out` is created with mode 0644 subject to umask (for example 0600 under umask 077), without execute permission; use `chmod +x` before running it.** Never modify the committed seed; always work on a copy.

```sh
# From the product checkout; change this to your source file.
SOURCE_FILE=my-program.herb
(cd bootstrap/seed && sha256sum -c gen1.seed.sha256) &&
HERB_WORK=$(mktemp -d /tmp/herbert-example.XXXXXXXX) &&
cp bootstrap/seed/gen1.seed "$HERB_WORK/seedbin" &&
cp "$SOURCE_FILE" "$HERB_WORK/prog.herb" &&
chmod u+x "$HERB_WORK/seedbin" &&
printf '0\n' > "$HERB_WORK/expected.stdout" &&
(cd "$HERB_WORK" && ./seedbin < prog.herb > compile.stdout 2> compile.stderr) &&
cmp "$HERB_WORK/expected.stdout" "$HERB_WORK/compile.stdout" &&
test ! -s "$HERB_WORK/compile.stderr" &&
chmod u+x "$HERB_WORK/a.out" &&
(cd "$HERB_WORK" && ./a.out)
# Source, compiler and compiler streams remain in HERB_WORK for inspection.
```

**"Did it compile?"** Require **all** of: a fresh ELF `a.out` in the clean directory, compiler exit status 0, exactly `0\n` on compiler stdout, and empty compiler stderr. Neither exit status nor absence of the word `ERR` alone proves success. `make compiler-conformance` checks that envelope in fresh directories and executes accepted programs. `make compiler-cli-contract` additionally checks preservation of prior output, symlinks and publication failures.

The compiler checks input errors before generating any output. The complete envelope is still useful when invoking a candidate compiler or diagnosing a damaged toolchain. A preserved old output must never be run after a failed invocation.

## 6. GOTCHAS (front-loaded — a cold model WILL hit these)

- **G1 — No loops; recurse.** `while`/`for` are not loop constructs. Use the tail-recursive index+accumulator idiom; malformed statement/header syntax is now checked before AST construction.
- **G2 — Tail form is necessary, not sufficient for bounded stack.** Non-tail recursion (`n + rest`, `n * fact(n-1)`) uses the hardware stack. So can mutual tail calls whose flattened argument widths differ. Stack-overflow depth depends on program layout and host limits; there is no portable safe-depth number. For deep work, use a tested equal-width tail-recursive shape and avoid allocating on every iteration when the loop is unbounded.
- **G3 — The empty/first/rest ERR-419 trap.** No list primitives exist. `empty/first/rest/plus/head/nil/map/cons` → `ERR 419 unknown callee`. Use arrays/buffers (see §2).
- **G4 — The render cap (ERR 432).** `main` returns int/bool/string OR a tuple of ≥2 renderables flattening to 2..15 words. Arrays/buffers as the result or as any tuple element → ERR 432. Strings render **quoted** on normal return; `process_exit` terminates before rendering. The exact over-cap message is misleadingly `main must return int or bool (ERR 432)` — it does NOT mean tuples are banned (2..15-word tuples render fine); it means you exceeded the 15-word cap or returned an array.
- **G5 — Integers are uint64, modular, no negatives.** `0 - 1` renders as `18446744073709551615`. A "-1 not-found sentinel" therefore prints as that huge number. Comparisons are unsigned.
- **G6 — Checked input belongs in `main`.** Bind `let input = stdin_read()`, handle `input.0`, then pass `input.1` to helpers. More than one input operation produces ERR 411; a reached helper containing one produces ERR 404.
- **G7 — `do` is mandatory for void/mutating builtins.** `do append(buf, 65)`, `do add(arr, x)`. `let x = add(a,1)` → ERR 440. Value builtins (`freeze/count/get/length/index/new_array/new_buffer/equal`) are used normally in expressions.
- **G8 — Tuple `.N` must be an in-range integer literal**, checked at compile time (`t.99` on a 3-tuple → ERR 431).
- **G9 — Preserved old output.** A failed compilation leaves the previous `a.out` untouched. Check compiler status and its complete success envelope before executing the result; file existence alone cannot distinguish an old executable from a new one.
- **G10 — Syntax shape.** `func name(args):` … `end`; `if cond:` / `elif cond:` / `else:` … `end`; `let x = …`; entry point `func main():`. No unary minus. Char literals `'K'`, `'\n'` are int byte values. Comments are `-- …`.

## 7. WORKED EXAMPLES (full source + exact stdout — all proven through the seed)

### Example 1 — minimal int return
```herbert
func main():
    return 40 + 2
end
```
**stdout:** `42\n`

### Example 2 — non-tail recursion with a base case
```herbert
func sum(n):
    if n == 0:
        return 0
    else:
        let rest = sum(n - 1)
        return n + rest
    end
end
func main():
    return sum(10)
end
```
**stdout:** `55\n`

### Example 3 — the "loop" idiom: tail recursion + accumulator (TCO-flat, scales)
```herbert
func loop(i, n, acc):
    if i >= n:
        return acc
    end
    return loop(i + 1, n, acc + i)
end
func main():
    return loop(0, 2000, 0)
end
```
**stdout:** `1999000\n`  *(sum 0..1999)*

### Example 4 — if/elif/else dispatch + tuple render
```herbert
func classify(n):
    if n == 0:
        return 100
    elif n == 1:
        return 200
    elif n == 2:
        return 300
    elif n == 3:
        return 400
    else:
        return 999
    end
end
func main():
    let r0  = classify(0)
    let r1  = classify(1)
    let r2  = classify(2)
    let r3  = classify(3)
    let r99 = classify(99)
    return (r0, r1, r2, r3, r99)
end
```
**stdout:** `(100, 200, 300, 400, 999)\n`

### Example 5 — buffers, arrays, freeze, count, length, tuple field, `do`
```herbert
func payload(seed):
    let buf = new_buffer()
    do append(buf, 65)
    do append(buf, 66)
    do append(buf, 67)
    do append(buf, 68)
    let s = freeze(buf)
    let arr = new_array(string)
    do add(arr, s)
    do add(arr, "fixed-literal-payload")
    let t = (s, count(arr), seed)
    return length(s) + t.1
end
func loop(i, n, acc):
    if i >= n:
        return acc
    end
    let r = payload(i)
    return loop(i + 1, n, acc + r)
end
func main():
    return loop(0, 10000, 0)
end
```
**stdout:** `60000\n`  *(each payload = length("ABCD")=4 + count(arr)=2 = 6; ×10000)*

### Bonus — raw stdout via flogger (I/O idiom)
```herbert
func main():
    do flogger("hi")
    return 7
end
```
**stdout:** `hi7\n`  *(flogger writes "hi" with no newline; then main's `7\n` is rendered)*

## Specialized-target addendum — boot-supplied input

The boot-input provider is preserved kernel functionality. Use the specialized
checks in [VERIFYING.md](../VERIFYING.md) for claims about that target; hosted
qualification does not establish kernel behavior or independent seed provenance.

`boot_read()` belongs to `-- emit: multiboot32-long64`. It takes no
arguments and returns an integer byte `0..255`, or `256` at EOF; subsequent EOF
reads keep returning `256`. Calls, including tail calls, share one cursor. A
single-function program using this primitive selects the tap path. Other
long64 language restrictions still apply; the hosted accept-list is not the
long64 accept-list. `stdin_read()` remains hosted I/O, and the old i386
`module_byte()` retains its answer-cell meaning.
`boot_read` is a reserved builtin name in every target, including hosted code;
a user function with that name is rejected.

Exactly one raw Multiboot module supplies the input. The provider validates
magic, metadata spans, module count and ordered payload bounds before main.
Missing, multiple or malformed input fails with `BI\n` on debugcon followed by
grade-1 completion. An empty module is valid, including GRUB's exact `[0,0]`
descriptor sentinel; it is never dereferenced. GRUB launches must use
`module --nounzip` to preserve the supplied file bytes.

Only this input path reserves the complete image, guards and relocated stack
through `esp_val` in ELF `p_memsz`. A non-sentinel module must start at or above
that reservation and end at or below 64 MiB. Reads consume module bytes in
place, independently of the fixed 2 MiB buffer. Non-input images retain their
historical layout. This fixed appliance contract supplies read-only file input,
not a filesystem, hardware-enforced immutability, general RAM discovery or
process isolation.

The forcing program is `examples/hexview_long64.herb`: the guest
renders lowercase hexadecimal, sixteen bytes per row; its host adapter supplies
the module and carries output. Its local runtime qualification remains separate
from the hosted example regression above.

The [ELF inspector](../examples/elfinfo_long64.md) uses the
same provider to inspect the compiler's ELF64 executable and its own ELF32 boot
envelope. Header inspection does not establish that an image can safely load.
It is an application of the existing compiler/seed pin above.

---

*Cold-test tasks and reference answers live in a separate grader-only packet; they are deliberately absent from this guide. That packet is not needed to write or build Herbert programs.*


## Hosted byte storage and Linux interface — September 12

The ordinary hosted compiler also supports these value builtins in main or
helpers; each is reserved as a function name and rejected under `do`:

- `buffer_length(b)` returns the logical byte count without a copy.
- `buffer_get(b, i)` reads an existing byte with bounds checking.
- `buffer_set(b, i, v)` replaces an existing byte, checks the index and 0..255
  value, and returns the written byte. It does not grow or allocate. Aliases see
  mutation; strings previously obtained with `freeze` remain independent copies.
- `buffer_address(b)` borrows the backing-storage address as an integer. This is
  **unsafe**: appending may relocate storage; reacquire after growth. An empty
  buffer supplies no permission to dereference.
- `linux_syscall6(number, a1, a2, a3, a4, a5, a6)` performs the raw Linux/x86-64
  system call, returning its unsigned 64-bit result. All seven arguments are
  integers. **Unsafe**: Linux can access or change memory at supplied addresses;
  the primitive does not validate pointer spans or update buffer lengths. Raw
  errors occupy `0 - 4095` through `0 - 1`; use that unsigned range, not `< 0`.

Create a buffer and append its full initialized capacity once, then reuse those
bytes. This solves repeated updates with bounded storage; it does not introduce
general garbage collection. `freeze` still copies and should not be used as a
per-update view. These primitives do not extend the kernel/module targets.
The support code and programs remain Herbert-authored; Linux and the desktop
are accepted external services, while development/test tools are distinct.
