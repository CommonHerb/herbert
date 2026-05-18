/*
 * Small allocation and error-reporting helpers used by every module of the
 * Herbert interpreter. Errors raised through herr() format into a shared
 * buffer and longjmp back to main, which prints the message and exits 1.
 */

#include "herbert.h"

#include <stdlib.h>
#include <string.h>

jmp_buf herbert_err_jmp;
char    herbert_err_msg[1024];

void herr(int line, const char *fmt, ...) {
    char *p   = herbert_err_msg;
    char *end = herbert_err_msg + sizeof(herbert_err_msg);

    if (line > 0) {
        int n = snprintf(p, (size_t)(end - p), "line %d: ", line);
        if (n > 0 && n < (int)(end - p)) p += n;
    }

    va_list ap;
    va_start(ap, fmt);
    vsnprintf(p, (size_t)(end - p), fmt, ap);
    va_end(ap);

    longjmp(herbert_err_jmp, 1);
}

static void oom(void) {
    fprintf(stderr, "herbert: out of memory\n");
    exit(2);
}

void *xmalloc(size_t n) {
    void *p = malloc(n ? n : 1);
    if (!p) oom();
    return p;
}

void *xcalloc(size_t nmemb, size_t size) {
    void *p = calloc(nmemb ? nmemb : 1, size ? size : 1);
    if (!p) oom();
    return p;
}

void *xrealloc(void *p, size_t n) {
    void *r = realloc(p, n ? n : 1);
    if (!r) oom();
    return r;
}

char *xstrdup(const char *s) {
    size_t n = strlen(s);
    char *r  = (char *)xmalloc(n + 1);
    memcpy(r, s, n + 1);
    return r;
}

char *xstrndup(const char *s, size_t n) {
    char *r = (char *)xmalloc(n + 1);
    memcpy(r, s, n);
    r[n] = '\0';
    return r;
}
