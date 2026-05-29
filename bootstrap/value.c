/*
 * Value constructors, the growable backing stores for the two reference
 * types (BufferObj and ArrayObj), and the canonical-form printer used to
 * render main()'s return value to standard output.
 *
 * Printing rules (per IMPL-ENTRY):
 *   integer            decimal digits                e.g. 42
 *   boolean            true | false
 *   string             "..." with \n \\ \" escaped   other bytes pass through
 *   buffer             <buffer len=N>
 *   tuple              (v1, v2, ...)                 elements rendered recursively
 *   array              [v1, v2, ...]                 elements rendered recursively
 *
 * Rendering is deterministic: identical values yield byte-identical output.
 */

#include "herbert.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

Value v_int(uint64_t i) {
    Value v;
    v.kind  = V_INT;
    v.u.i   = i;
    return v;
}

Value v_bool(bool b) {
    Value v;
    v.kind  = V_BOOL;
    v.u.b   = b;
    return v;
}

Value v_string(const uint8_t *data, size_t len) {
    gc_maybe_collect();
    StringObj *s = (StringObj *)xmalloc(sizeof(StringObj));
    s->len  = len;
    s->data = (uint8_t *)xmalloc(len ? len : 1);
    if (len) memcpy(s->data, data, len);
    gc_register(&s->gc, V_STR, sizeof(StringObj) + len);
    Value v;
    v.kind  = V_STR;
    v.u.s   = s;
    return v;
}

Value v_string_take(uint8_t *data, size_t len) {
    gc_maybe_collect();
    StringObj *s = (StringObj *)xmalloc(sizeof(StringObj));
    s->len  = len;
    s->data = data;
    gc_register(&s->gc, V_STR, sizeof(StringObj) + len);
    Value v;
    v.kind  = V_STR;
    v.u.s   = s;
    return v;
}

Value v_buffer_new(void) {
    gc_maybe_collect();
    BufferObj *b = (BufferObj *)xmalloc(sizeof(BufferObj));
    b->len  = 0;
    b->cap  = 0;
    b->data = NULL;
    gc_register(&b->gc, V_BUF, sizeof(BufferObj));
    Value v;
    v.kind  = V_BUF;
    v.u.buf = b;
    return v;
}

Value v_tuple(Value *items, size_t n) {
    gc_maybe_collect();
    TupleObj *t = (TupleObj *)xmalloc(sizeof(TupleObj));
    t->n     = n;
    t->items = items;
    gc_register(&t->gc, V_TUPLE, sizeof(TupleObj) + n * sizeof(Value));
    Value v;
    v.kind   = V_TUPLE;
    v.u.tup  = t;
    return v;
}

Value v_array_new(TypeExpr *elem) {
    gc_maybe_collect();
    ArrayObj *a = (ArrayObj *)xmalloc(sizeof(ArrayObj));
    a->elem_type = elem;
    a->n     = 0;
    a->cap   = 0;
    a->items = NULL;
    gc_register(&a->gc, V_ARRAY, sizeof(ArrayObj));
    Value v;
    v.kind   = V_ARRAY;
    v.u.arr  = a;
    return v;
}

void buffer_append(BufferObj *b, uint8_t byte) {
    gc_maybe_collect();
    if (b->len == b->cap) {
        size_t old_cap = b->cap;
        b->cap  = b->cap ? b->cap * 2 : 16;
        b->data = (uint8_t *)xrealloc(b->data, b->cap);
        gc_account_delta((ptrdiff_t)(b->cap - old_cap));
    }
    b->data[b->len++] = byte;
}

void array_add(ArrayObj *a, Value v) {
    gc_maybe_collect();
    if (a->n == a->cap) {
        size_t old_cap = a->cap;
        a->cap   = a->cap ? a->cap * 2 : 4;
        a->items = (Value *)xrealloc(a->items, a->cap * sizeof(Value));
        gc_account_delta((ptrdiff_t)((a->cap - old_cap) * sizeof(Value)));
    }
    a->items[a->n++] = v;
}

const char *v_kind_name(VKind k) {
    switch (k) {
        case V_INT:   return "int";
        case V_BOOL:  return "bool";
        case V_STR:   return "string";
        case V_BUF:   return "buffer";
        case V_TUPLE: return "tuple";
        case V_ARRAY: return "array";
    }
    return "?";
}

static void print_string_lit(StringObj *s, FILE *fp) {
    fputc('"', fp);
    for (size_t i = 0; i < s->len; i++) {
        uint8_t c = s->data[i];
        if      (c == '\n') fputs("\\n",  fp);
        else if (c == '\\') fputs("\\\\", fp);
        else if (c == '"')  fputs("\\\"", fp);
        else                fputc((int)c, fp);
    }
    fputc('"', fp);
}

typedef struct {
    const void **items;
    size_t      n;
    size_t      cap;
} PrintPath;

static bool print_path_contains(PrintPath *path, const void *obj) {
    for (size_t i = 0; i < path->n; i++) {
        if (path->items[i] == obj) return true;
    }
    return false;
}

/* Bound print recursion the way the parser is bounded. A runtime value (nested
 * tuples/arrays) can be built arbitrarily deep by recursion, and
 * v_print_canonical_rec descends it on the C stack; without a cap a deep value
 * SIGSEGVs the printer instead of failing cleanly. PrintPath->n already tracks
 * the live nesting depth (for cycle detection), so the cap lives here, at the
 * one push site. Real printed values nest a handful deep; 10000 is ample
 * headroom and far below the C-stack overflow. */
#define PRINT_MAX_DEPTH 10000

static void print_path_push(PrintPath *path, const void *obj) {
    if (path->n >= PRINT_MAX_DEPTH)
        herr(0, "value nested too deep to print (limit %d)", PRINT_MAX_DEPTH);
    if (path->n == path->cap) {
        path->cap = path->cap ? path->cap * 2 : 32;
        path->items = (const void **)xrealloc(path->items,
                                              path->cap * sizeof(void *));
    }
    path->items[path->n++] = obj;
}

static void print_path_pop(PrintPath *path) {
    path->n--;
}

static void v_print_canonical_rec(Value v, FILE *fp, PrintPath *path) {
    switch (v.kind) {
        case V_INT:
            fprintf(fp, "%llu", (unsigned long long)v.u.i);
            return;
        case V_BOOL:
            fputs(v.u.b ? "true" : "false", fp);
            return;
        case V_STR:
            print_string_lit(v.u.s, fp);
            return;
        case V_BUF:
            fprintf(fp, "<buffer len=%zu>", v.u.buf->len);
            return;
        case V_TUPLE: {
            TupleObj *t = v.u.tup;
            if (print_path_contains(path, t)) {
                herr(0, "cyclic value cannot be printed");
            }
            print_path_push(path, t);
            fputc('(', fp);
            for (size_t i = 0; i < t->n; i++) {
                if (i) fputs(", ", fp);
                v_print_canonical_rec(t->items[i], fp, path);
            }
            fputc(')', fp);
            print_path_pop(path);
            return;
        }
        case V_ARRAY: {
            ArrayObj *a = v.u.arr;
            if (print_path_contains(path, a)) {
                herr(0, "cyclic value cannot be printed");
            }
            print_path_push(path, a);
            fputc('[', fp);
            for (size_t i = 0; i < a->n; i++) {
                if (i) fputs(", ", fp);
                v_print_canonical_rec(a->items[i], fp, path);
            }
            fputc(']', fp);
            print_path_pop(path);
            return;
        }
    }
}

void v_print_canonical(Value v, FILE *fp) {
    PrintPath path = {0};
    v_print_canonical_rec(v, fp, &path);
    free(path.items);
}
