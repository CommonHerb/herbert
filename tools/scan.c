/*
 * Herbert bootstrap-allowlist scanner.
 *
 * Reads two plain text files — a tracked-files list whose path is passed
 * on the command line (one repository-relative path per line, as produced
 * by `git ls-files`) and BOOTSTRAP-ALLOWLIST at the repository root —
 * partitions the tracked set on the `.herb` suffix, and compares the
 * non-`.herb` set against the listed paths. The two sets must match
 * exactly; any discrepancy is a violation.
 *
 *   - tracked non-`.herb` file not listed   -> "unlisted"
 *   - listed path with no tracked file      -> "stale"
 *   - perfect match                         -> exit 0 with one OK line
 *
 * Output is sorted so identical repository state yields byte-identical
 * output across runs. Plain ISO C; the scanner launches no process and
 * has no external dependency.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    char **items;
    size_t count;
    size_t capacity;
} StrList;

static void *xrealloc(void *p, size_t n) {
    void *r = realloc(p, n);
    if (!r) { perror("realloc"); exit(2); }
    return r;
}

static char *xstrdup(const char *s) {
    size_t n = strlen(s) + 1;
    char *r = (char *)malloc(n);
    if (!r) { perror("malloc"); exit(2); }
    memcpy(r, s, n);
    return r;
}

static void sl_push(StrList *l, const char *s) {
    if (l->count == l->capacity) {
        l->capacity = l->capacity ? l->capacity * 2 : 16;
        l->items = (char **)xrealloc(l->items, l->capacity * sizeof(char *));
    }
    l->items[l->count++] = xstrdup(s);
}

static int cmp_strptr(const void *a, const void *b) {
    return strcmp(*(const char *const *)a, *(const char *const *)b);
}

static void sl_sort(StrList *l) {
    qsort(l->items, l->count, sizeof(char *), cmp_strptr);
}

static int ends_with(const char *s, const char *suf) {
    size_t ls = strlen(s), lt = strlen(suf);
    return ls >= lt && memcmp(s + ls - lt, suf, lt) == 0;
}

/* Read repository-relative paths from a plain text file, one per line.
 * Trailing CR/LF is stripped; empty lines are skipped. */
static void read_tracked(const char *path, StrList *out) {
    FILE *fp = fopen(path, "r");
    if (!fp) { perror(path); exit(2); }

    char line[4096];
    while (fgets(line, sizeof(line), fp)) {
        size_t n = strlen(line);
        while (n > 0 && (line[n-1] == '\n' || line[n-1] == '\r')) {
            line[--n] = '\0';
        }
        if (n > 0) sl_push(out, line);
    }
    fclose(fp);
}

/* Read BOOTSTRAP-ALLOWLIST: one path per line; blank lines and lines whose
 * first non-whitespace character is `#` are ignored. Surrounding whitespace
 * on each path line is trimmed. */
static void read_allowlist(const char *path, StrList *out) {
    FILE *fp = fopen(path, "r");
    if (!fp) { perror(path); exit(2); }

    char line[4096];
    while (fgets(line, sizeof(line), fp)) {
        size_t n = strlen(line);
        while (n > 0 && (line[n-1] == '\n' || line[n-1] == '\r' ||
                         line[n-1] == ' '  || line[n-1] == '\t')) {
            line[--n] = '\0';
        }
        char *p = line;
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '\0' || *p == '#') continue;
        sl_push(out, p);
    }
    fclose(fp);
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s <tracked-files-list>\n",
                argc > 0 ? argv[0] : "scan");
        return 2;
    }

    StrList tracked = {0}, allow = {0}, non_herb = {0};
    StrList unlisted = {0}, stale = {0};

    read_tracked(argv[1], &tracked);
    read_allowlist("BOOTSTRAP-ALLOWLIST", &allow);

    for (size_t i = 0; i < tracked.count; i++) {
        if (!ends_with(tracked.items[i], ".herb")) {
            sl_push(&non_herb, tracked.items[i]);
        }
    }

    sl_sort(&non_herb);
    sl_sort(&allow);

    size_t i = 0, j = 0;
    while (i < non_herb.count && j < allow.count) {
        int c = strcmp(non_herb.items[i], allow.items[j]);
        if (c == 0)      { i++; j++; }
        else if (c < 0)  { sl_push(&unlisted, non_herb.items[i++]); }
        else             { sl_push(&stale,    allow.items[j++]);    }
    }
    while (i < non_herb.count) sl_push(&unlisted, non_herb.items[i++]);
    while (j < allow.count)    sl_push(&stale,    allow.items[j++]);

    if (unlisted.count == 0 && stale.count == 0) {
        printf("OK: %zu tracked non-.herb file(s) match BOOTSTRAP-ALLOWLIST\n",
               non_herb.count);
        return 0;
    }

    for (size_t k = 0; k < unlisted.count; k++) {
        printf("unlisted: %s\n", unlisted.items[k]);
    }
    for (size_t k = 0; k < stale.count; k++) {
        printf("stale: %s\n", stale.items[k]);
    }
    return 1;
}
