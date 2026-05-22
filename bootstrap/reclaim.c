/*
 * Host-internal heap accounting and reclamation for Herbert value objects.
 *
 * The collector is non-moving and precise: roots are explicitly enumerated
 * by eval.c plus the short-lived C-local shadow root stack below.
 */

#include "herbert.h"

#include <stdlib.h>

#define GC_FLOOR ((size_t)1024 * 1024)
#define GC_GROW  ((size_t)2)

static GCObj *g_all_objects;
static size_t g_live_bytes;
static size_t g_peak_heap;
static size_t g_gc_threshold = GC_FLOOR;

static Value  *g_mark_stack;
static size_t  g_mark_n;
static size_t  g_mark_cap;

static Value **g_shadow_roots;
static size_t  g_shadow_n;
static size_t  g_shadow_cap;

static void gc_collect(void);

static void gc_note_peak(void) {
    if (g_live_bytes > g_peak_heap) g_peak_heap = g_live_bytes;
}

static size_t gc_grown_threshold(size_t live) {
    if (live > (size_t)-1 / GC_GROW) return (size_t)-1;
    live *= GC_GROW;
    return live < GC_FLOOR ? GC_FLOOR : live;
}

static void mark_stack_push(Value v) {
    if (g_mark_n == g_mark_cap) {
        g_mark_cap = g_mark_cap ? g_mark_cap * 2 : 256;
        g_mark_stack = (Value *)xrealloc(g_mark_stack,
                                         g_mark_cap * sizeof(Value));
    }
    g_mark_stack[g_mark_n++] = v;
}

static size_t gc_object_bytes(GCObj *o) {
    switch (o->kind) {
        case V_STR: {
            StringObj *s = (StringObj *)o;
            return sizeof(StringObj) + s->len;
        }
        case V_BUF: {
            BufferObj *b = (BufferObj *)o;
            return sizeof(BufferObj) + b->cap;
        }
        case V_TUPLE: {
            TupleObj *t = (TupleObj *)o;
            return sizeof(TupleObj) + t->n * sizeof(Value);
        }
        case V_ARRAY: {
            ArrayObj *a = (ArrayObj *)o;
            return sizeof(ArrayObj) + a->cap * sizeof(Value);
        }
        case V_INT:
        case V_BOOL:
            break;
    }
    herr(0, "internal: invalid GC object kind %d", (int)o->kind);
    return 0;
}

static void gc_free_obj(GCObj *o) {
    switch (o->kind) {
        case V_STR: {
            StringObj *s = (StringObj *)o;
            free(s->data);
            free(s);
            return;
        }
        case V_BUF: {
            BufferObj *b = (BufferObj *)o;
            free(b->data);
            free(b);
            return;
        }
        case V_TUPLE: {
            TupleObj *t = (TupleObj *)o;
            free(t->items);
            free(t);
            return;
        }
        case V_ARRAY: {
            ArrayObj *a = (ArrayObj *)o;
            free(a->items);
            free(a);
            return;
        }
        case V_INT:
        case V_BOOL:
            break;
    }
    herr(0, "internal: invalid GC object kind %d", (int)o->kind);
}

void gc_register(GCObj *o, VKind kind, size_t bytes) {
    o->kind   = kind;
    o->next   = g_all_objects;
    o->marked = false;
    g_all_objects = o;
    g_live_bytes += bytes;
    gc_note_peak();
}

void gc_account_delta(ptrdiff_t delta) {
    if (delta < 0) {
        size_t d = (size_t)(-delta);
        g_live_bytes = d > g_live_bytes ? 0 : g_live_bytes - d;
        return;
    }
    g_live_bytes += (size_t)delta;
    gc_note_peak();
}

void gc_maybe_collect(void) {
    if (g_live_bytes >= g_gc_threshold) {
        gc_collect();
        g_gc_threshold = gc_grown_threshold(g_live_bytes);
    }
}

void gc_mark_value(Value v) {
    GCObj *o = NULL;
    switch (v.kind) {
        case V_STR:   o = &v.u.s->gc;   break;
        case V_BUF:   o = &v.u.buf->gc; break;
        case V_TUPLE: o = &v.u.tup->gc; break;
        case V_ARRAY: o = &v.u.arr->gc; break;
        case V_INT:
        case V_BOOL:
            return;
    }
    if (!o || o->marked) return;

    o->marked = true;
    if (v.kind == V_TUPLE) {
        for (size_t i = 0; i < v.u.tup->n; i++) {
            mark_stack_push(v.u.tup->items[i]);
        }
    } else if (v.kind == V_ARRAY) {
        for (size_t i = 0; i < v.u.arr->n; i++) {
            mark_stack_push(v.u.arr->items[i]);
        }
    }
}

static void gc_drain_marks(void) {
    while (g_mark_n > 0) {
        Value v = g_mark_stack[--g_mark_n];
        gc_mark_value(v);
    }
}

void gc_protect(Value *slot) {
    if (g_shadow_n == g_shadow_cap) {
        g_shadow_cap = g_shadow_cap ? g_shadow_cap * 2 : 64;
        g_shadow_roots = (Value **)xrealloc(g_shadow_roots,
                                            g_shadow_cap * sizeof(Value *));
    }
    g_shadow_roots[g_shadow_n++] = slot;
}

void gc_protect_span(Value *slots, size_t n) {
    for (size_t i = 0; i < n; i++) {
        gc_protect(&slots[i]);
    }
}

size_t gc_root_mark(void) {
    return g_shadow_n;
}

void gc_unprotect_to(size_t mark) {
    if (mark <= g_shadow_n) g_shadow_n = mark;
}

size_t herbert_peak_heap_bytes(void) {
    return g_peak_heap;
}

static void gc_collect(void) {
    g_mark_n = 0;
    for (GCObj *o = g_all_objects; o; o = o->next) {
        o->marked = false;
    }

    eval_gc_mark_roots();
    for (size_t i = 0; i < g_shadow_n; i++) {
        gc_mark_value(*g_shadow_roots[i]);
    }
    gc_drain_marks();

    GCObj **link = &g_all_objects;
    while (*link) {
        GCObj *o = *link;
        if (o->marked) {
            link = &o->next;
            continue;
        }

        size_t bytes = gc_object_bytes(o);
        *link = o->next;
        gc_free_obj(o);
        g_live_bytes = bytes > g_live_bytes ? 0 : g_live_bytes - bytes;
    }
}
