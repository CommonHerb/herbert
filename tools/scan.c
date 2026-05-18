/*
 * Herbert bootstrap-allowlist scanner.
 *
 * Reads the set of git-tracked files via `git ls-files -z`, partitions on
 * the `.herb` suffix, and compares the non-`.herb` set against the lines of
 * BOOTSTRAP-ALLOWLIST at the repository root. The two sets must match
 * exactly; any discrepancy is a violation.
 *
 *   - tracked non-`.herb` file not listed   -> "unlisted"
 *   - listed path with no tracked file       -> "stale"
 *   - perfect match                          -> exit 0 with one OK line
 *
 * Output is sorted so identical repository state yields byte-identical
 * output across runs. Uses only the C standard library (and POSIX popen).
 */

#define _POSIX_C_SOURCE 200809L

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

/* Read NUL-separated paths from `git ls-files -z` into out. */
static void read_tracked(StrList *out) {
    FILE *fp = popen("git ls-files -z", "r");
    if (!fp) { perror("popen: git ls-files"); exit(2); }

    size_t cap = 4096, len = 0;
    char *buf = (char *)xrealloc(NULL, cap);
    int c;
    while ((c = fgetc(fp)) != EOF) {
        if (len + 1 >= cap) {
            cap *= 2;
            buf = (char *)xrealloc(buf, cap);
        }
        if (c == '\0') {
            buf[len] = '\0';
            if (len > 0) sl_push(out, buf);
            len = 0;
        } else {
            buf[len++] = (char)c;
        }
    }
    if (len > 0) {
        buf[len] = '\0';
        sl_push(out, buf);
    }
    free(buf);

    int rc = pclose(fp);
    if (rc != 0) {
        fprintf(stderr, "scan: `git ls-files -z` failed (status %d)\n", rc);
        exit(2);
    }
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

int main(void) {
    StrList tracked = {0}, allow = {0}, non_herb = {0};
    StrList unlisted = {0}, stale = {0};

    read_tracked(&tracked);
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
