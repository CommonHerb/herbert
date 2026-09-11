# Counting real input with Herbert

`wordcount.herb` counts LF line endings, words separated by ASCII whitespace
(bytes 9–13 and 32), and bytes. NUL and non-ASCII bytes are ordinary word
content; no text decoding or locale is involved. An unterminated last line
does not add an LF count. The output is one tuple: `(lines, words, bytes)`.

From the repository root, compile and run:

```sh
mkdir -p build/wordcount
cp bootstrap/seed/gen1.seed build/wordcount/compiler
chmod +x build/wordcount/compiler
(cd build/wordcount && ./compiler < ../../examples/wordcount.herb) &&
    chmod +x build/wordcount/a.out &&
    ./build/wordcount/a.out < README.md
```

Check the compiler's exit status before running the output. Successful
compilation prints `0`; the program prints its counts. A failed compilation
preserves an existing output, so that file alone is not evidence of success.
The program reports failed input reads on standard error and exits with status 1.

This is a useful exercise of the hosted compiler's supported operating model:
checked input, byte indexing, decisions, tuple results and a long tail-recursive
scan. The scan calls itself with the same argument widths, which the current
compiler lowers to constant-stack iteration. It creates no per-byte buffers,
arrays or strings. `make wordcount` checks exact results, binary input, a closed input descriptor, and multi-megabyte pipe input under a fixed
8 MiB stack limit.

The program reads the entire input into memory before scanning. It is not a
streaming implementation: memory grows with input size, and the native arena
currently reserves 3.5 GiB. Input exceeding the available capacity produces the
same input-error message and status 1; the program does not print numeric errno.
General heap reclamation and tail calls between
functions with unequal argument widths remain open language work. This
program demonstrates sustained processing within those limits; it does not
close those debts.
