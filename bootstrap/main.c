/*
 * Driver for the Herbert interpreter.
 *
 * Reads a single .herb file from the path passed on the command line,
 * tokenises it, parses it into a Program, runs main(), prints the return
 * value in canonical form (followed by a newline), and exits 0.
 *
 * Errors anywhere in the pipeline — parse, lookup, runtime type mismatch,
 * invocation of a deferred operation — abort through herr(), which longjmps
 * to the buffer set up here. The driver then prints the message to stderr
 * and exits non-zero.
 */

#include "herbert.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char *read_file(const char *path, size_t *out_len) {
    FILE *fp = fopen(path, "rb");
    if (!fp) {
        fprintf(stderr, "herbert: cannot open '%s'\n", path);
        exit(2);
    }
    if (fseek(fp, 0, SEEK_END) != 0) {
        fprintf(stderr, "herbert: fseek failed on '%s'\n", path);
        exit(2);
    }
    long n = ftell(fp);
    if (n < 0) {
        fprintf(stderr, "herbert: ftell failed on '%s'\n", path);
        exit(2);
    }
    rewind(fp);
    char *buf = (char *)xmalloc((size_t)n + 1);
    size_t got = fread(buf, 1, (size_t)n, fp);
    fclose(fp);
    if (got != (size_t)n) {
        fprintf(stderr, "herbert: short read on '%s'\n", path);
        exit(2);
    }
    buf[n] = '\0';
    *out_len = (size_t)n;
    return buf;
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s <file.herb>\n",
                argc > 0 ? argv[0] : "herbert");
        return 2;
    }

    if (setjmp(herbert_err_jmp) != 0) {
        fprintf(stderr, "herbert: %s\n", herbert_err_msg);
        return 1;
    }

    size_t src_len;
    char  *src = read_file(argv[1], &src_len);

    TokenList tl = {0};
    lex(src, src_len, argv[1], &tl);

    Program prog = {0};
    parse_program(&tl, &prog);

    Value v = run_program(&prog);
    v_print_canonical(v, stdout);
    fputc('\n', stdout);

    return 0;
}
