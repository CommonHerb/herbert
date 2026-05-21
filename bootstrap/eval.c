/*
 * Herbert evaluator — interpreter-managed activation stack.
 *
 * Every Herbert function call runs in an Activation. Activations live on a
 * heap-allocated activation stack; each owns a heap-allocated work stack of
 * Ops and a heap-allocated value stack of intermediate results. The outer
 * driver picks the topmost activation and pops Ops one at a time. An Op
 * either pushes more Ops (decomposing a tree into postorder work), combines
 * values already on the value stack, mutates the activation's scope chain,
 * yields to a freshly pushed callee activation, replaces the current
 * activation in place (tail call), or returns a value and ends the
 * activation. No Herbert call consumes a C-stack frame, so call depth is
 * bounded by heap memory only.
 *
 * Tail-call optimisation. A `return CALL(...)` whose callee is any user
 * function — self OR other — is rewritten at op-emission time into a
 * single OP_TAIL_CALL. OP_TAIL_CALL resets the current activation to the
 * callee instead of pushing a new one, so the activation count stays flat
 * across tail-call chains.
 *
 * Block-scoped lets. Each if/elif/else arm enters a fresh scope (child of
 * the activation's current top) and pops it on normal arm exit. A return
 * inside an arm exits the activation without popping the arm scope; the
 * scope memory is reclaimed when the activation is freed.
 *
 * Built-ins are dispatched inline within the current activation; they
 * never push a new activation.
 */

#include "herbert.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static Program *g_program;

/* ---------------------------------------------------------------------- *
 * Scope chain                                                            *
 * ---------------------------------------------------------------------- */

typedef struct Scope {
    char         **names;
    Value         *values;
    size_t         n;
    size_t         cap;
    struct Scope  *parent;
} Scope;

/* Live-scope diagnostics. live_scopes is the number of scopes currently
 * allocated and not yet freed; peak_live_scopes is the high-water mark.
 * Used by the bounded-memory regression check: tail-recursive iteration
 * must keep live_scopes within a small constant, not grow with depth. */
static size_t live_scopes      = 0;
static size_t peak_live_scopes = 0;

static Scope *scope_new(Scope *parent) {
    Scope *s = (Scope *)xcalloc(1, sizeof(Scope));
    s->parent = parent;
    live_scopes++;
    if (live_scopes > peak_live_scopes) peak_live_scopes = live_scopes;
    return s;
}

static void scope_free(Scope *s) {
    for (size_t i = 0; i < s->n; i++) free(s->names[i]);
    free(s->names);
    free(s->values);
    free(s);
    live_scopes--;
}

/* Walk parent links from s and free each scope. Caller must guarantee the
 * chain is unreachable from any other state — see OP_TAIL_CALL for the
 * argument that this holds after act_reset_to. */
static void scope_free_chain(Scope *s) {
    while (s) {
        Scope *p = s->parent;
        scope_free(s);
        s = p;
    }
}

size_t herbert_peak_live_scopes(void) { return peak_live_scopes; }

static void scope_let(Scope *s, const char *name, Value v, int line) {
    for (size_t i = 0; i < s->n; i++) {
        if (strcmp(s->names[i], name) == 0) {
            herr(line, "let: '%s' is already defined in this scope", name);
        }
    }
    if (s->n == s->cap) {
        s->cap    = s->cap ? s->cap * 2 : 8;
        s->names  = (char **)xrealloc(s->names,  s->cap * sizeof(char *));
        s->values = (Value *)xrealloc(s->values, s->cap * sizeof(Value));
    }
    s->names [s->n] = xstrdup(name);
    s->values[s->n] = v;
    s->n++;
}

static bool scope_find(Scope *s, const char *name, Scope **out_s, size_t *out_i) {
    for (Scope *p = s; p; p = p->parent) {
        for (size_t i = 0; i < p->n; i++) {
            if (strcmp(p->names[i], name) == 0) {
                *out_s = p;
                *out_i = i;
                return true;
            }
        }
    }
    return false;
}

static Value scope_get(Scope *s, const char *name, int line) {
    Scope *fs;
    size_t fi;
    if (!scope_find(s, name, &fs, &fi)) {
        herr(line, "undefined name '%s'", name);
    }
    return fs->values[fi];
}

static void scope_assign(Scope *s, const char *name, Value v, int line) {
    Scope *fs;
    size_t fi;
    if (!scope_find(s, name, &fs, &fi)) {
        herr(line, "assignment to undefined name '%s' (use 'let' to introduce)", name);
    }
    fs->values[fi] = v;
}

/* ---------------------------------------------------------------------- *
 * Built-in identity                                                      *
 * ---------------------------------------------------------------------- */

static const char *BUILTIN_NAMES[] = {
    "length", "index", "slice", "equal",
    "new_buffer", "freeze", "clogger",
    "new_array", "get", "count",
    "append", "add",
    NULL
};

static const char *VOIDLESS_NAMES[] = { "append", "add", NULL };

bool is_builtin_name(const char *name) {
    for (int i = 0; BUILTIN_NAMES[i]; i++) {
        if (strcmp(BUILTIN_NAMES[i], name) == 0) return true;
    }
    return false;
}

bool is_builtin_voidless(const char *name) {
    for (int i = 0; VOIDLESS_NAMES[i]; i++) {
        if (strcmp(VOIDLESS_NAMES[i], name) == 0) return true;
    }
    return false;
}

/* ---------------------------------------------------------------------- *
 * Ops (work-stack instructions) and Activations                          *
 * ---------------------------------------------------------------------- */

typedef enum {
    OP_EVAL_EXPR,         /* u.expr: decompose into postorder work          */
    OP_AFTER_NOT,         /* pop bool, push negation                        */
    OP_AFTER_DOT,         /* n=idx: pop tuple, push element                 */
    OP_AFTER_BINOP,       /* binop: pop right, left; push arith/cmp result  */
    OP_AFTER_AND,         /* u.expr=right: short-circuit on left            */
    OP_AFTER_OR,          /* u.expr=right: short-circuit on left            */
    OP_AFTER_AND_R,       /* right value typed-checked, push                */
    OP_AFTER_OR_R,        /* right value typed-checked, push                */
    OP_BUILD_TUPLE,       /* n=arity: pop n vals, push tuple                */
    OP_BUILTIN_CALL,      /* u.expr=call: dispatch, push result             */
    OP_DO_BUILTIN_CALL,   /* u.expr=call: dispatch voidless, no push        */
    OP_USER_CALL,         /* u.fn, n=arity: push child activation, yield    */
    OP_TAIL_CALL,         /* u.fn, n=arity: replace current activation      */
    OP_EXEC_STMT,         /* u.stmt: decompose into ops                     */
    OP_AFTER_LET,         /* u.name: pop val, scope_let                     */
    OP_AFTER_ASSIGN,      /* u.name: pop val, scope_assign                  */
    OP_AFTER_RETURN,      /* pop val, mark activation done                  */
    OP_TRY_ARM,           /* u.stmt=S_IF, n=arm_idx                         */
    OP_AFTER_COND,        /* u.stmt=S_IF, n=arm_idx: pop bool, branch       */
    OP_POP_SCOPE,         /* u.scope=parent to restore                      */
    OP_NO_RETURN_ERROR    /* sentinel at the bottom of a fresh body         */
} OpKind;

typedef struct {
    OpKind  kind;
    BinOp   binop;
    int     line;
    size_t  n;
    union {
        Expr       *expr;
        Stmt       *stmt;
        Function   *fn;
        Scope      *scope;
        const char *name;
    } u;
} Op;

typedef struct Activation {
    Function *fn;
    Scope    *top;
    Op       *ops;
    size_t    op_n;
    size_t    op_cap;
    Value    *vals;
    size_t    val_n;
    size_t    val_cap;
    Value     ret_val;
    bool      done;
} Activation;

typedef struct {
    Activation **items;
    size_t       n;
    size_t       cap;
} ActStack;

static ActStack g_act;

/* ---------------------------------------------------------------------- *
 * Activation / op / value stack management                               *
 * ---------------------------------------------------------------------- */

static void act_push_op(Activation *a, Op op) {
    if (a->op_n == a->op_cap) {
        a->op_cap = a->op_cap ? a->op_cap * 2 : 8;
        a->ops    = (Op *)xrealloc(a->ops, a->op_cap * sizeof(Op));
    }
    a->ops[a->op_n++] = op;
}

static Op act_pop_op(Activation *a) { return a->ops[--a->op_n]; }

static void act_push_val(Activation *a, Value v) {
    if (a->val_n == a->val_cap) {
        a->val_cap = a->val_cap ? a->val_cap * 2 : 8;
        a->vals    = (Value *)xrealloc(a->vals, a->val_cap * sizeof(Value));
    }
    a->vals[a->val_n++] = v;
}

static Value act_pop_val(Activation *a) { return a->vals[--a->val_n]; }

static void push_eval(Activation *a, Expr *e) {
    Op o = {0};
    o.kind   = OP_EVAL_EXPR;
    o.line   = e->line;
    o.u.expr = e;
    act_push_op(a, o);
}

static void push_body_reversed(Activation *a, Block *b) {
    /* Source-order statements pop first. */
    for (size_t i = b->n; i > 0; i--) {
        Op o = {0};
        o.kind   = OP_EXEC_STMT;
        o.line   = b->items[i-1]->line;
        o.u.stmt = b->items[i-1];
        act_push_op(a, o);
    }
}

static void load_body(Activation *a, Function *fn) {
    /* Bottom-of-stack: error if the body completes without returning. */
    Op nr = {0};
    nr.kind = OP_NO_RETURN_ERROR;
    nr.line = fn->line;
    act_push_op(a, nr);
    push_body_reversed(a, &fn->body);
}

static Activation *act_new(Function *fn) {
    Activation *a = (Activation *)xcalloc(1, sizeof(Activation));
    a->fn  = fn;
    a->top = scope_new(NULL);
    load_body(a, fn);
    return a;
}

static void act_reset_to(Activation *a, Function *fn) {
    a->fn    = fn;
    a->top   = scope_new(NULL);
    a->op_n  = 0;
    a->val_n = 0;
    a->done  = false;
    load_body(a, fn);
}

static void act_free(Activation *a) {
    free(a->ops);
    free(a->vals);
    free(a);
}

static void act_push(Activation *a) {
    if (g_act.n == g_act.cap) {
        g_act.cap   = g_act.cap ? g_act.cap * 2 : 16;
        g_act.items = (Activation **)xrealloc(g_act.items, g_act.cap * sizeof(Activation *));
    }
    g_act.items[g_act.n++] = a;
}

/* ---------------------------------------------------------------------- *
 * Built-in dispatch                                                      *
 * ---------------------------------------------------------------------- */

static void check_arity_n(int line, const char *name, size_t want, size_t got) {
    if (got != want) {
        herr(line, "%s: expected %zu arg(s), got %zu", name, want, got);
    }
}

static Value bi_length(int line, Value *args, size_t n) {
    check_arity_n(line, "length", 1, n);
    Value v = args[0];
    if (v.kind == V_BUF) {
        herr(line, "length on a buffer is not implemented in this interpreter version");
    }
    if (v.kind != V_STR) {
        herr(line, "length: expected string, got %s", v_kind_name(v.kind));
    }
    return v_int((uint64_t)v.u.s->len);
}

static Value bi_index(int line, Value *args, size_t n) {
    check_arity_n(line, "index", 2, n);
    Value v = args[0];
    Value p = args[1];
    if (p.kind != V_INT) {
        herr(line, "index: position must be int, got %s", v_kind_name(p.kind));
    }
    if (v.kind == V_BUF) {
        herr(line, "index on a buffer is not implemented in this interpreter version");
    }
    if (v.kind != V_STR) {
        herr(line, "index: expected string, got %s", v_kind_name(v.kind));
    }
    if (p.u.i >= v.u.s->len) {
        herr(line, "index: position %llu out of range (length %zu)",
             (unsigned long long)p.u.i, v.u.s->len);
    }
    return v_int((uint64_t)v.u.s->data[p.u.i]);
}

static Value bi_equal(int line, Value *args, size_t n) {
    check_arity_n(line, "equal", 2, n);
    Value a = args[0];
    Value b = args[1];
    if (a.kind == V_BUF || b.kind == V_BUF) {
        herr(line, "equal on a buffer is not implemented in this interpreter version");
    }
    if (a.kind != V_STR || b.kind != V_STR) {
        herr(line, "equal: expected two strings, got %s and %s",
             v_kind_name(a.kind), v_kind_name(b.kind));
    }
    if (a.u.s->len != b.u.s->len) return v_bool(false);
    return v_bool(memcmp(a.u.s->data, b.u.s->data, a.u.s->len) == 0);
}

static Value bi_new_buffer(int line, Value *args, size_t n) {
    (void)args;
    check_arity_n(line, "new_buffer", 0, n);
    return v_buffer_new();
}

static Value bi_clogger(int line, Value *args, size_t n) {
    (void)args;
    check_arity_n(line, "clogger", 0, n);

    uint8_t *data = NULL;
    size_t len = 0;
    size_t cap = 0;

    int ch;
    while ((ch = fgetc(stdin)) != EOF) {
        if (len == cap) {
            cap = cap ? cap * 2 : 4096;
            data = (uint8_t *)xrealloc(data, cap);
        }
        data[len++] = (uint8_t)ch;
    }
    if (ferror(stdin)) {
        herr(line, "clogger: error reading stdin");
    }
    if (!data) {
        data = (uint8_t *)xmalloc(1);
    }
    return v_string_take(data, len);
}

static Value bi_freeze(int line, Value *args, size_t n) {
    check_arity_n(line, "freeze", 1, n);
    Value v = args[0];
    if (v.kind != V_BUF) {
        herr(line, "freeze: expected buffer, got %s", v_kind_name(v.kind));
    }
    return v_string(v.u.buf->data, v.u.buf->len);
}

static Value bi_get(int line, Value *args, size_t n) {
    check_arity_n(line, "get", 2, n);
    Value a = args[0];
    Value p = args[1];
    if (a.kind != V_ARRAY) {
        herr(line, "get: expected array, got %s", v_kind_name(a.kind));
    }
    if (p.kind != V_INT) {
        herr(line, "get: position must be int, got %s", v_kind_name(p.kind));
    }
    if (p.u.i >= a.u.arr->n) {
        herr(line, "get: position %llu out of range (count %zu)",
             (unsigned long long)p.u.i, a.u.arr->n);
    }
    return a.u.arr->items[p.u.i];
}

static Value bi_count(int line, Value *args, size_t n) {
    check_arity_n(line, "count", 1, n);
    Value a = args[0];
    if (a.kind != V_ARRAY) {
        herr(line, "count: expected array, got %s", v_kind_name(a.kind));
    }
    return v_int((uint64_t)a.u.arr->n);
}

static void bi_append(int line, Value *args, size_t n) {
    check_arity_n(line, "append", 2, n);
    Value b  = args[0];
    Value bv = args[1];
    if (b.kind != V_BUF) {
        herr(line, "append: expected buffer, got %s", v_kind_name(b.kind));
    }
    if (bv.kind != V_INT) {
        herr(line, "append: byte must be int, got %s", v_kind_name(bv.kind));
    }
    if (bv.u.i > 255) {
        herr(line, "append: byte value %llu out of range 0..255",
             (unsigned long long)bv.u.i);
    }
    buffer_append(b.u.buf, (uint8_t)bv.u.i);
}

static void bi_add(int line, Value *args, size_t n) {
    check_arity_n(line, "add", 2, n);
    Value a = args[0];
    Value x = args[1];
    if (a.kind != V_ARRAY) {
        herr(line, "add: expected array, got %s", v_kind_name(a.kind));
    }
    array_add(a.u.arr, x);
}

static Value dispatch_builtin_value(const char *name, int line, Value *args, size_t n) {
    if (strcmp(name, "length")     == 0) return bi_length    (line, args, n);
    if (strcmp(name, "index")      == 0) return bi_index     (line, args, n);
    if (strcmp(name, "slice")      == 0) {
        herr(line, "slice is not implemented in this interpreter version");
    }
    if (strcmp(name, "equal")      == 0) return bi_equal     (line, args, n);
    if (strcmp(name, "new_buffer") == 0) return bi_new_buffer(line, args, n);
    if (strcmp(name, "clogger")    == 0) return bi_clogger   (line, args, n);
    if (strcmp(name, "freeze")     == 0) return bi_freeze    (line, args, n);
    if (strcmp(name, "get")        == 0) return bi_get       (line, args, n);
    if (strcmp(name, "count")      == 0) return bi_count     (line, args, n);
    herr(line, "internal: builtin '%s' has no value form", name);
    return v_int(0);
}

static void dispatch_builtin_void(const char *name, int line, Value *args, size_t n) {
    if (strcmp(name, "append") == 0) { bi_append(line, args, n); return; }
    if (strcmp(name, "add")    == 0) { bi_add   (line, args, n); return; }
    herr(line, "internal: builtin '%s' has no voidless form", name);
}

/* ---------------------------------------------------------------------- *
 * Arithmetic / comparison                                                *
 * ---------------------------------------------------------------------- */

static Value eval_arith(int line, BinOp op, Value l, Value r) {
    if (l.kind != V_INT || r.kind != V_INT) {
        herr(line, "arithmetic/comparison requires ints, got %s and %s",
             v_kind_name(l.kind), v_kind_name(r.kind));
    }
    switch (op) {
        case OP_ADD:    return v_int (l.u.i +  r.u.i);
        case OP_SUB:    return v_int (l.u.i -  r.u.i);
        case OP_LT:     return v_bool(l.u.i <  r.u.i);
        case OP_LE:     return v_bool(l.u.i <= r.u.i);
        case OP_GT:     return v_bool(l.u.i >  r.u.i);
        case OP_GE:     return v_bool(l.u.i >= r.u.i);
        case OP_EQ_INT: return v_bool(l.u.i == r.u.i);
        case OP_NE_INT: return v_bool(l.u.i != r.u.i);
        default: break;
    }
    herr(line, "internal: unexpected binop %d", op);
    return v_int(0);
}

/* ---------------------------------------------------------------------- *
 * Op-emission helpers for compound forms                                 *
 * ---------------------------------------------------------------------- */

static void schedule_call_args(Activation *a, Expr **args, size_t n) {
    /* Reverse push: source-order args pop first, so they land on the value
     * stack in source order at indices [val_n - n, val_n). */
    for (size_t i = n; i > 0; i--) push_eval(a, args[i-1]);
}

static void enter_arm(Activation *a, Block *arm) {
    /* OP_POP_SCOPE runs after all the arm's statements complete; carries
     * the parent scope so the activation's top can be restored. */
    Op pop  = {0};
    pop.kind    = OP_POP_SCOPE;
    pop.line    = 0;
    pop.u.scope = a->top;
    act_push_op(a, pop);
    a->top = scope_new(a->top);
    push_body_reversed(a, arm);
}

/* ---------------------------------------------------------------------- *
 * Activation driver                                                      *
 * ---------------------------------------------------------------------- */

typedef enum { DR_RETURNED, DR_PUSHED_CALLEE } DriveResult;

static DriveResult drive(Activation *a) {
    for (;;) {
        Op op = act_pop_op(a);
        switch (op.kind) {
            case OP_NO_RETURN_ERROR:
                herr(op.line, "function '%s' did not return a value", a->fn->name);
                break; /* unreachable */

            case OP_EVAL_EXPR: {
                Expr *e = op.u.expr;
                switch (e->kind) {
                    case E_INT:       act_push_val(a, v_int (e->i_val));                       break;
                    case E_BOOL:      act_push_val(a, v_bool(e->b_val));                       break;
                    case E_STR:       act_push_val(a, v_string(e->s_bytes, e->s_len));         break;
                    case E_NAME:      act_push_val(a, scope_get(a->top, e->name, e->line));    break;
                    case E_NEW_ARRAY: act_push_val(a, v_array_new(e->type_arg));               break;

                    case E_NOT: {
                        Op af = {0};
                        af.kind = OP_AFTER_NOT;
                        af.line = e->line;
                        act_push_op(a, af);
                        push_eval(a, e->child);
                        break;
                    }

                    case E_DOT: {
                        Op af = {0};
                        af.kind = OP_AFTER_DOT;
                        af.line = e->line;
                        af.n    = e->dot_idx;
                        act_push_op(a, af);
                        push_eval(a, e->child);
                        break;
                    }

                    case E_BINOP: {
                        if (e->op == OP_AND) {
                            Op af = {0};
                            af.kind   = OP_AFTER_AND;
                            af.line   = e->line;
                            af.u.expr = e->r;
                            act_push_op(a, af);
                            push_eval(a, e->l);
                        } else if (e->op == OP_OR) {
                            Op af = {0};
                            af.kind   = OP_AFTER_OR;
                            af.line   = e->line;
                            af.u.expr = e->r;
                            act_push_op(a, af);
                            push_eval(a, e->l);
                        } else {
                            Op af = {0};
                            af.kind  = OP_AFTER_BINOP;
                            af.line  = e->line;
                            af.binop = e->op;
                            act_push_op(a, af);
                            push_eval(a, e->r);
                            push_eval(a, e->l);
                        }
                        break;
                    }

                    case E_TUPLE: {
                        Op af = {0};
                        af.kind = OP_BUILD_TUPLE;
                        af.line = e->line;
                        af.n    = e->n_args;
                        act_push_op(a, af);
                        schedule_call_args(a, e->args, e->n_args);
                        break;
                    }

                    case E_CALL: {
                        const char *name = e->name;
                        if (is_builtin_name(name)) {
                            if (is_builtin_voidless(name)) {
                                herr(e->line, "'%s' has no value; use 'do %s(...)'", name, name);
                            }
                            Op af = {0};
                            af.kind   = OP_BUILTIN_CALL;
                            af.line   = e->line;
                            af.u.expr = e;
                            act_push_op(a, af);
                            schedule_call_args(a, e->args, e->n_args);
                        } else {
                            Function *callee = program_lookup(g_program, name);
                            if (!callee) {
                                herr(e->line, "unknown function '%s'", name);
                            }
                            if (callee->n_params != e->n_args) {
                                herr(e->line, "function '%s' expects %zu arg(s), got %zu",
                                     callee->name, callee->n_params, e->n_args);
                            }
                            Op af = {0};
                            af.kind = OP_USER_CALL;
                            af.line = e->line;
                            af.u.fn = callee;
                            af.n    = e->n_args;
                            act_push_op(a, af);
                            schedule_call_args(a, e->args, e->n_args);
                        }
                        break;
                    }
                }
                break;
            }

            case OP_AFTER_NOT: {
                Value v = act_pop_val(a);
                if (v.kind != V_BOOL) {
                    herr(op.line, "'not' requires bool, got %s", v_kind_name(v.kind));
                }
                act_push_val(a, v_bool(!v.u.b));
                break;
            }

            case OP_AFTER_DOT: {
                Value base = act_pop_val(a);
                if (base.kind != V_TUPLE) {
                    herr(op.line, "'.%zu' requires a tuple, got %s",
                         op.n, v_kind_name(base.kind));
                }
                if (op.n >= base.u.tup->n) {
                    herr(op.line, "tuple index %zu out of range (arity %zu)",
                         op.n, base.u.tup->n);
                }
                act_push_val(a, base.u.tup->items[op.n]);
                break;
            }

            case OP_AFTER_BINOP: {
                Value r = act_pop_val(a);
                Value l = act_pop_val(a);
                act_push_val(a, eval_arith(op.line, op.binop, l, r));
                break;
            }

            case OP_AFTER_AND: {
                Value l = act_pop_val(a);
                if (l.kind != V_BOOL) {
                    herr(op.line, "'and' left operand must be bool, got %s",
                         v_kind_name(l.kind));
                }
                if (!l.u.b) {
                    act_push_val(a, v_bool(false));
                } else {
                    Op af = {0};
                    af.kind = OP_AFTER_AND_R;
                    af.line = op.line;
                    act_push_op(a, af);
                    push_eval(a, op.u.expr);
                }
                break;
            }

            case OP_AFTER_OR: {
                Value l = act_pop_val(a);
                if (l.kind != V_BOOL) {
                    herr(op.line, "'or' left operand must be bool, got %s",
                         v_kind_name(l.kind));
                }
                if (l.u.b) {
                    act_push_val(a, v_bool(true));
                } else {
                    Op af = {0};
                    af.kind = OP_AFTER_OR_R;
                    af.line = op.line;
                    act_push_op(a, af);
                    push_eval(a, op.u.expr);
                }
                break;
            }

            case OP_AFTER_AND_R: {
                Value r = act_pop_val(a);
                if (r.kind != V_BOOL) {
                    herr(op.line, "'and' right operand must be bool, got %s",
                         v_kind_name(r.kind));
                }
                act_push_val(a, r);
                break;
            }

            case OP_AFTER_OR_R: {
                Value r = act_pop_val(a);
                if (r.kind != V_BOOL) {
                    herr(op.line, "'or' right operand must be bool, got %s",
                         v_kind_name(r.kind));
                }
                act_push_val(a, r);
                break;
            }

            case OP_BUILD_TUPLE: {
                size_t n = op.n;
                Value *items = NULL;
                if (n) {
                    items = (Value *)xmalloc(sizeof(Value) * n);
                    memcpy(items, &a->vals[a->val_n - n], sizeof(Value) * n);
                    a->val_n -= n;
                }
                act_push_val(a, v_tuple(items, n));
                break;
            }

            case OP_BUILTIN_CALL: {
                Expr *e = op.u.expr;
                size_t n = e->n_args;
                Value *args = &a->vals[a->val_n - n];
                Value r = dispatch_builtin_value(e->name, op.line, args, n);
                a->val_n -= n;
                act_push_val(a, r);
                break;
            }

            case OP_DO_BUILTIN_CALL: {
                Expr *e = op.u.expr;
                size_t n = e->n_args;
                Value *args = &a->vals[a->val_n - n];
                dispatch_builtin_void(e->name, op.line, args, n);
                a->val_n -= n;
                break;
            }

            case OP_USER_CALL: {
                Function *callee = op.u.fn;
                size_t     na    = op.n;
                Activation *child = act_new(callee);
                for (size_t i = 0; i < na; i++) {
                    Value v = a->vals[a->val_n - na + i];
                    scope_let(child->top, callee->params[i], v, callee->line);
                }
                a->val_n -= na;
                act_push(child);
                return DR_PUSHED_CALLEE;
            }

            case OP_TAIL_CALL: {
                Function *callee = op.u.fn;
                size_t     na    = op.n;
                /* Snapshot args before clearing the activation. The args
                 * were evaluated against the outgoing scope (a->top); their
                 * Values are self-contained (no scope pointer) and continue
                 * to be valid after the outgoing chain is freed. */
                Value *tmp = NULL;
                if (na) {
                    tmp = (Value *)xmalloc(sizeof(Value) * na);
                    memcpy(tmp, &a->vals[a->val_n - na], sizeof(Value) * na);
                }
                /* Save the outgoing chain. After act_reset_to overwrites
                 * a->top and clears a->ops, the old chain is unreachable
                 * (Herbert has no closures, no first-class scope handles;
                 * the cleared op stack drops any OP_POP_SCOPE that held a
                 * parent reference). We free it AFTER binding the new args
                 * so the snapshot's lifetime overlaps the outgoing scope
                 * by the shortest possible window. */
                Scope *outgoing = a->top;
                act_reset_to(a, callee);
                for (size_t i = 0; i < na; i++) {
                    scope_let(a->top, callee->params[i], tmp[i], callee->line);
                }
                free(tmp);
                scope_free_chain(outgoing);
                break;
            }

            case OP_EXEC_STMT: {
                Stmt *s = op.u.stmt;
                switch (s->kind) {
                    case S_LET: {
                        Op af = {0};
                        af.kind   = OP_AFTER_LET;
                        af.line   = s->line;
                        af.u.name = s->name;
                        act_push_op(a, af);
                        push_eval(a, s->e);
                        break;
                    }
                    case S_ASSIGN: {
                        Op af = {0};
                        af.kind   = OP_AFTER_ASSIGN;
                        af.line   = s->line;
                        af.u.name = s->name;
                        act_push_op(a, af);
                        push_eval(a, s->e);
                        break;
                    }
                    case S_RETURN: {
                        Expr *re = s->e;
                        if (re->kind == E_CALL && !is_builtin_name(re->name)) {
                            /* Tail call: any user-function call in return
                             * position reuses the current activation. This
                             * covers self-tail-calls AND cross-function
                             * tail-call chains. */
                            Function *callee = program_lookup(g_program, re->name);
                            if (!callee) {
                                herr(re->line, "unknown function '%s'", re->name);
                            }
                            if (callee->n_params != re->n_args) {
                                herr(re->line, "function '%s' expects %zu arg(s), got %zu",
                                     callee->name, callee->n_params, re->n_args);
                            }
                            Op tc = {0};
                            tc.kind = OP_TAIL_CALL;
                            tc.line = re->line;
                            tc.u.fn = callee;
                            tc.n    = re->n_args;
                            act_push_op(a, tc);
                            schedule_call_args(a, re->args, re->n_args);
                        } else {
                            Op af = {0};
                            af.kind = OP_AFTER_RETURN;
                            af.line = s->line;
                            act_push_op(a, af);
                            push_eval(a, re);
                        }
                        break;
                    }
                    case S_DO: {
                        Expr *e = s->e;
                        if (!is_builtin_voidless(e->name)) {
                            herr(e->line,
                                 "'do' requires a value-less call (append or add); got '%s'",
                                 e->name);
                        }
                        Op af = {0};
                        af.kind   = OP_DO_BUILTIN_CALL;
                        af.line   = s->line;
                        af.u.expr = e;
                        act_push_op(a, af);
                        schedule_call_args(a, e->args, e->n_args);
                        break;
                    }
                    case S_IF: {
                        Op ta = {0};
                        ta.kind   = OP_TRY_ARM;
                        ta.line   = s->line;
                        ta.u.stmt = s;
                        ta.n      = 0;
                        act_push_op(a, ta);
                        break;
                    }
                }
                break;
            }

            case OP_AFTER_LET: {
                Value v = act_pop_val(a);
                scope_let(a->top, op.u.name, v, op.line);
                break;
            }

            case OP_AFTER_ASSIGN: {
                Value v = act_pop_val(a);
                scope_assign(a->top, op.u.name, v, op.line);
                break;
            }

            case OP_AFTER_RETURN: {
                a->ret_val = act_pop_val(a);
                a->done    = true;
                return DR_RETURNED;
            }

            case OP_TRY_ARM: {
                Stmt  *s = op.u.stmt;
                size_t i = op.n;
                if (i < s->n_arms) {
                    Op af = {0};
                    af.kind   = OP_AFTER_COND;
                    af.line   = s->conds[i]->line;
                    af.u.stmt = s;
                    af.n      = i;
                    act_push_op(a, af);
                    push_eval(a, s->conds[i]);
                } else if (s->has_else) {
                    enter_arm(a, &s->else_arm);
                }
                break;
            }

            case OP_AFTER_COND: {
                Stmt  *s = op.u.stmt;
                size_t i = op.n;
                Value  c = act_pop_val(a);
                if (c.kind != V_BOOL) {
                    herr(s->conds[i]->line,
                         "if/elif condition must be bool, got %s", v_kind_name(c.kind));
                }
                if (c.u.b) {
                    enter_arm(a, &s->arms[i]);
                } else {
                    Op ta = {0};
                    ta.kind   = OP_TRY_ARM;
                    ta.line   = s->line;
                    ta.u.stmt = s;
                    ta.n      = i + 1;
                    act_push_op(a, ta);
                }
                break;
            }

            case OP_POP_SCOPE: {
                a->top = op.u.scope;
                break;
            }
        }
    }
}

/* ---------------------------------------------------------------------- *
 * Program entry                                                          *
 * ---------------------------------------------------------------------- */

Value run_program(Program *prog) {
    g_program = prog;
    Function *main_fn = program_lookup(prog, "main");
    if (!main_fn) {
        herr(0, "no 'main' function defined");
    }
    if (main_fn->n_params != 0) {
        herr(main_fn->line, "'main' must take zero parameters");
    }

    g_act.n = 0;
    Activation *root = act_new(main_fn);
    act_push(root);

    Value last_result = v_int(0);
    bool  have_result = false;

    while (g_act.n > 0) {
        Activation *a = g_act.items[g_act.n - 1];
        if (have_result) {
            act_push_val(a, last_result);
            have_result = false;
        }
        DriveResult dr = drive(a);
        if (dr == DR_RETURNED) {
            last_result = a->ret_val;
            have_result = true;
            g_act.n--;
            act_free(a);
        }
        /* DR_PUSHED_CALLEE: new top on g_act, loop. */
    }

    return last_result;
}
