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
    StringObj *s = (StringObj *)xmalloc(sizeof(StringObj));
    s->len  = len;
    s->data = (uint8_t *)xmalloc(len ? len : 1);
    if (len) memcpy(s->data, data, len);
    Value v;
    v.kind  = V_STR;
    v.u.s   = s;
    return v;
}

Value v_string_take(uint8_t *data, size_t len) {
    StringObj *s = (StringObj *)xmalloc(sizeof(StringObj));
    s->len  = len;
    s->data = data;
    Value v;
    v.kind  = V_STR;
    v.u.s   = s;
    return v;
}

Value v_buffer_new(void) {
    BufferObj *b = (BufferObj *)xmalloc(sizeof(BufferObj));
    b->len  = 0;
    b->cap  = 0;
    b->data = NULL;
    Value v;
    v.kind  = V_BUF;
    v.u.buf = b;
    return v;
}

Value v_tuple(Value *items, size_t n) {
    TupleObj *t = (TupleObj *)xmalloc(sizeof(TupleObj));
    t->n     = n;
    t->items = items;
    Value v;
    v.kind   = V_TUPLE;
    v.u.tup  = t;
    return v;
}

Value v_array_new(TypeExpr *elem) {
    ArrayObj *a = (ArrayObj *)xmalloc(sizeof(ArrayObj));
    a->elem_type = elem;
    a->n     = 0;
    a->cap   = 0;
    a->items = NULL;
    Value v;
    v.kind   = V_ARRAY;
    v.u.arr  = a;
    return v;
}

void buffer_append(BufferObj *b, uint8_t byte) {
    if (b->len == b->cap) {
        b->cap  = b->cap ? b->cap * 2 : 16;
        b->data = (uint8_t *)xrealloc(b->data, b->cap);
    }
    b->data[b->len++] = byte;
}

void array_add(ArrayObj *a, Value v) {
    if (a->n == a->cap) {
        a->cap   = a->cap ? a->cap * 2 : 4;
        a->items = (Value *)xrealloc(a->items, a->cap * sizeof(Value));
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

void v_print_canonical(Value v, FILE *fp) {
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
        case V_TUPLE:
            fputc('(', fp);
            for (size_t i = 0; i < v.u.tup->n; i++) {
                if (i) fputs(", ", fp);
                v_print_canonical(v.u.tup->items[i], fp);
            }
            fputc(')', fp);
            return;
        case V_ARRAY:
            fputc('[', fp);
            for (size_t i = 0; i < v.u.arr->n; i++) {
                if (i) fputs(", ", fp);
                v_print_canonical(v.u.arr->items[i], fp);
            }
            fputc(']', fp);
            return;
    }
}
