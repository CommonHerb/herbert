/*
 * Herbert evaluator.
 *
 * Execution is driven by run_call(), which sets up a fresh scope chain for
 * the callee, then enters a wrap-around loop that re-executes the body when
 * exec_body() signals a tail-self call. The signal is propagated up through
 * exec_stmt/exec_body as a typed ExecResult, so a tail-self call inside
 * nested if-arms still triggers frame reuse rather than C-stack nesting.
 * This is the mechanism that satisfies IMPL-TCO.
 *
 * Block-scoped lets: every entry into an if/elif/else arm pushes a new
 * scope onto the frame's scope chain, and the scope is popped on arm exit.
 * `let` always introduces in the topmost scope. `NAME = expr` walks the
 * chain from the top until it finds a binding, then rebinds it in place.
 *
 * Non-tail user-function calls recurse through C (this is the only place
 * the C stack grows linearly with Herbert call depth). The spec's MANDATORY
 * deep-recursion test (TESTS, test 10) is a tail-self call and runs in flat
 * stack space; non-tail recursion is exercised only on small inputs.
 *
 * Built-ins are dispatched by name from eval_call. The deferred operations
 * (slice on string/buffer; index/length/equal on buffer) parse normally
 * but raise a clear "not implemented in this interpreter version" error
 * if actually invoked, per SCOPE.
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

typedef struct {
    Function *fn;
    Scope    *top;
} Frame;

typedef enum { EX_FALL, EX_RETURN, EX_TAIL_SELF } ExStatus;

typedef struct {
    ExStatus status;
    Value    value;        /* EX_RETURN */
    Value   *tail_args;    /* EX_TAIL_SELF — owned */
    size_t   tail_nargs;
} ExecResult;

static Scope *scope_new(Scope *parent) {
    Scope *s = (Scope *)xcalloc(1, sizeof(Scope));
    s->parent = parent;
    return s;
}

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
    "new_buffer", "freeze",
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
 * Forward declarations                                                   *
 * ---------------------------------------------------------------------- */

static Value      eval_expr(Frame *f, Expr *e);
static ExecResult exec_stmt(Frame *f, Stmt *s);
static ExecResult exec_body(Frame *f, Block *b);
static Value      eval_call(Frame *f, Expr *e, bool allow_voidless);
static Value      run_call (Function *fn, Value *args, size_t nargs, int line);

/* ---------------------------------------------------------------------- *
 * Built-in implementations                                               *
 * ---------------------------------------------------------------------- */

static void check_arity(Expr *e, size_t want) {
    if (e->n_args != want) {
        herr(e->line, "%s: expected %zu arg(s), got %zu",
             e->name, want, e->n_args);
    }
}

static Value bi_length(Frame *f, Expr *e) {
    check_arity(e, 1);
    Value v = eval_expr(f, e->args[0]);
    if (v.kind == V_BUF) {
        herr(e->line, "length on a buffer is not implemented in this interpreter version");
    }
    if (v.kind != V_STR) {
        herr(e->line, "length: expected string, got %s", v_kind_name(v.kind));
    }
    return v_int((uint64_t)v.u.s->len);
}

static Value bi_index(Frame *f, Expr *e) {
    check_arity(e, 2);
    Value v = eval_expr(f, e->args[0]);
    Value n = eval_expr(f, e->args[1]);
    if (n.kind != V_INT) {
        herr(e->line, "index: position must be int, got %s", v_kind_name(n.kind));
    }
    if (v.kind == V_BUF) {
        herr(e->line, "index on a buffer is not implemented in this interpreter version");
    }
    if (v.kind != V_STR) {
        herr(e->line, "index: expected string, got %s", v_kind_name(v.kind));
    }
    if (n.u.i >= v.u.s->len) {
        herr(e->line, "index: position %llu out of range (length %zu)",
             (unsigned long long)n.u.i, v.u.s->len);
    }
    return v_int((uint64_t)v.u.s->data[n.u.i]);
}

static Value bi_slice(Frame *f, Expr *e) {
    (void)f;
    herr(e->line, "slice is not implemented in this interpreter version");
    return v_int(0);
}

static Value bi_equal(Frame *f, Expr *e) {
    check_arity(e, 2);
    Value a = eval_expr(f, e->args[0]);
    Value b = eval_expr(f, e->args[1]);
    if (a.kind == V_BUF || b.kind == V_BUF) {
        herr(e->line, "equal on a buffer is not implemented in this interpreter version");
    }
    if (a.kind != V_STR || b.kind != V_STR) {
        herr(e->line, "equal: expected two strings, got %s and %s",
             v_kind_name(a.kind), v_kind_name(b.kind));
    }
    if (a.u.s->len != b.u.s->len) return v_bool(false);
    return v_bool(memcmp(a.u.s->data, b.u.s->data, a.u.s->len) == 0);
}

static Value bi_new_buffer(Frame *f, Expr *e) {
    (void)f;
    check_arity(e, 0);
    return v_buffer_new();
}

static Value bi_freeze(Frame *f, Expr *e) {
    check_arity(e, 1);
    Value v = eval_expr(f, e->args[0]);
    if (v.kind != V_BUF) {
        herr(e->line, "freeze: expected buffer, got %s", v_kind_name(v.kind));
    }
    return v_string(v.u.buf->data, v.u.buf->len);
}

static Value bi_get(Frame *f, Expr *e) {
    check_arity(e, 2);
    Value a = eval_expr(f, e->args[0]);
    Value n = eval_expr(f, e->args[1]);
    if (a.kind != V_ARRAY) {
        herr(e->line, "get: expected array, got %s", v_kind_name(a.kind));
    }
    if (n.kind != V_INT) {
        herr(e->line, "get: position must be int, got %s", v_kind_name(n.kind));
    }
    if (n.u.i >= a.u.arr->n) {
        herr(e->line, "get: position %llu out of range (count %zu)",
             (unsigned long long)n.u.i, a.u.arr->n);
    }
    return a.u.arr->items[n.u.i];
}

static Value bi_count(Frame *f, Expr *e) {
    check_arity(e, 1);
    Value a = eval_expr(f, e->args[0]);
    if (a.kind != V_ARRAY) {
        herr(e->line, "count: expected array, got %s", v_kind_name(a.kind));
    }
    return v_int((uint64_t)a.u.arr->n);
}

static void bi_append(Frame *f, Expr *e) {
    check_arity(e, 2);
    Value b = eval_expr(f, e->args[0]);
    Value n = eval_expr(f, e->args[1]);
    if (b.kind != V_BUF) {
        herr(e->line, "append: expected buffer, got %s", v_kind_name(b.kind));
    }
    if (n.kind != V_INT) {
        herr(e->line, "append: byte must be int, got %s", v_kind_name(n.kind));
    }
    if (n.u.i > 255) {
        herr(e->line, "append: byte value %llu out of range 0..255",
             (unsigned long long)n.u.i);
    }
    buffer_append(b.u.buf, (uint8_t)n.u.i);
}

static void bi_add(Frame *f, Expr *e) {
    check_arity(e, 2);
    Value a = eval_expr(f, e->args[0]);
    Value x = eval_expr(f, e->args[1]);
    if (a.kind != V_ARRAY) {
        herr(e->line, "add: expected array, got %s", v_kind_name(a.kind));
    }
    array_add(a.u.arr, x);
}

/* ---------------------------------------------------------------------- *
 * Call dispatch                                                          *
 * ---------------------------------------------------------------------- */

static Value eval_call(Frame *f, Expr *e, bool allow_voidless) {
    const char *name = e->name;

    if (strcmp(name, "length")     == 0) return bi_length    (f, e);
    if (strcmp(name, "index")      == 0) return bi_index     (f, e);
    if (strcmp(name, "slice")      == 0) return bi_slice     (f, e);
    if (strcmp(name, "equal")      == 0) return bi_equal     (f, e);
    if (strcmp(name, "new_buffer") == 0) return bi_new_buffer(f, e);
    if (strcmp(name, "freeze")     == 0) return bi_freeze    (f, e);
    if (strcmp(name, "get")        == 0) return bi_get       (f, e);
    if (strcmp(name, "count")      == 0) return bi_count     (f, e);
    if (strcmp(name, "append")     == 0) {
        if (!allow_voidless) {
            herr(e->line, "'append' has no value; use 'do append(...)'");
        }
        bi_append(f, e);
        return v_int(0);
    }
    if (strcmp(name, "add") == 0) {
        if (!allow_voidless) {
            herr(e->line, "'add' has no value; use 'do add(...)'");
        }
        bi_add(f, e);
        return v_int(0);
    }

    Function *fn = program_lookup(g_program, name);
    if (!fn) herr(e->line, "unknown function '%s'", name);
    if (fn->n_params != e->n_args) {
        herr(e->line, "function '%s' expects %zu arg(s), got %zu",
             fn->name, fn->n_params, e->n_args);
    }

    Value *args = NULL;
    if (e->n_args) {
        args = (Value *)xmalloc(sizeof(Value) * e->n_args);
        for (size_t i = 0; i < e->n_args; i++) {
            args[i] = eval_expr(f, e->args[i]);
        }
    }
    Value r = run_call(fn, args, e->n_args, e->line);
    free(args);
    return r;
}

/* ---------------------------------------------------------------------- *
 * Expression evaluation                                                  *
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

static Value eval_expr(Frame *f, Expr *e) {
    switch (e->kind) {
        case E_INT:  return v_int (e->i_val);
        case E_BOOL: return v_bool(e->b_val);
        case E_STR:  return v_string(e->s_bytes, e->s_len);
        case E_NAME: return scope_get(f->top, e->name, e->line);

        case E_TUPLE: {
            Value *items = (Value *)xmalloc(sizeof(Value) * e->n_args);
            for (size_t i = 0; i < e->n_args; i++) {
                items[i] = eval_expr(f, e->args[i]);
            }
            return v_tuple(items, e->n_args);
        }

        case E_DOT: {
            Value base = eval_expr(f, e->child);
            if (base.kind != V_TUPLE) {
                herr(e->line, "'.%zu' requires a tuple, got %s",
                     e->dot_idx, v_kind_name(base.kind));
            }
            if (e->dot_idx >= base.u.tup->n) {
                herr(e->line, "tuple index %zu out of range (arity %zu)",
                     e->dot_idx, base.u.tup->n);
            }
            return base.u.tup->items[e->dot_idx];
        }

        case E_NOT: {
            Value v = eval_expr(f, e->child);
            if (v.kind != V_BOOL) {
                herr(e->line, "'not' requires bool, got %s", v_kind_name(v.kind));
            }
            return v_bool(!v.u.b);
        }

        case E_BINOP: {
            BinOp op = e->op;
            if (op == OP_AND) {
                Value l = eval_expr(f, e->l);
                if (l.kind != V_BOOL) {
                    herr(e->line, "'and' left operand must be bool, got %s",
                         v_kind_name(l.kind));
                }
                if (!l.u.b) return v_bool(false);
                Value r = eval_expr(f, e->r);
                if (r.kind != V_BOOL) {
                    herr(e->line, "'and' right operand must be bool, got %s",
                         v_kind_name(r.kind));
                }
                return r;
            }
            if (op == OP_OR) {
                Value l = eval_expr(f, e->l);
                if (l.kind != V_BOOL) {
                    herr(e->line, "'or' left operand must be bool, got %s",
                         v_kind_name(l.kind));
                }
                if (l.u.b) return v_bool(true);
                Value r = eval_expr(f, e->r);
                if (r.kind != V_BOOL) {
                    herr(e->line, "'or' right operand must be bool, got %s",
                         v_kind_name(r.kind));
                }
                return r;
            }
            Value lv = eval_expr(f, e->l);
            Value rv = eval_expr(f, e->r);
            return eval_arith(e->line, op, lv, rv);
        }

        case E_CALL:      return eval_call(f, e, false);
        case E_NEW_ARRAY: return v_array_new(e->type_arg);
    }
    herr(e->line, "internal: unexpected expr kind");
    return v_int(0);
}

/* ---------------------------------------------------------------------- *
 * Statement execution                                                    *
 * ---------------------------------------------------------------------- */

static bool is_self_call(Function *fn, Expr *e) {
    return e->kind == E_CALL && strcmp(e->name, fn->name) == 0
        && !is_builtin_name(e->name);
}

static ExecResult exec_stmt(Frame *f, Stmt *s) {
    switch (s->kind) {
        case S_LET: {
            Value v = eval_expr(f, s->e);
            scope_let(f->top, s->name, v, s->line);
            ExecResult r = { .status = EX_FALL };
            return r;
        }
        case S_ASSIGN: {
            Value v = eval_expr(f, s->e);
            scope_assign(f->top, s->name, v, s->line);
            ExecResult r = { .status = EX_FALL };
            return r;
        }
        case S_RETURN: {
            Expr *e = s->e;
            if (is_self_call(f->fn, e)) {
                if (e->n_args != f->fn->n_params) {
                    herr(s->line, "function '%s' expects %zu arg(s), got %zu",
                         f->fn->name, f->fn->n_params, e->n_args);
                }
                Value *args = NULL;
                if (e->n_args) {
                    args = (Value *)xmalloc(sizeof(Value) * e->n_args);
                    for (size_t i = 0; i < e->n_args; i++) {
                        args[i] = eval_expr(f, e->args[i]);
                    }
                }
                ExecResult r = {
                    .status     = EX_TAIL_SELF,
                    .tail_args  = args,
                    .tail_nargs = e->n_args
                };
                return r;
            }
            Value v = eval_expr(f, e);
            ExecResult r = { .status = EX_RETURN, .value = v };
            return r;
        }
        case S_DO: {
            Expr *e = s->e;
            if (!is_builtin_voidless(e->name)) {
                herr(e->line,
                     "'do' requires a value-less call (append or add); got '%s'",
                     e->name);
            }
            (void)eval_call(f, e, true);
            ExecResult r = { .status = EX_FALL };
            return r;
        }
        case S_IF: {
            for (size_t i = 0; i < s->n_arms; i++) {
                Value cond = eval_expr(f, s->conds[i]);
                if (cond.kind != V_BOOL) {
                    herr(s->conds[i]->line,
                         "if/elif condition must be bool, got %s",
                         v_kind_name(cond.kind));
                }
                if (cond.u.b) {
                    Scope *saved = f->top;
                    f->top = scope_new(saved);
                    ExecResult r = exec_body(f, &s->arms[i]);
                    f->top = saved;
                    return r;
                }
            }
            if (s->has_else) {
                Scope *saved = f->top;
                f->top = scope_new(saved);
                ExecResult r = exec_body(f, &s->else_arm);
                f->top = saved;
                return r;
            }
            ExecResult r = { .status = EX_FALL };
            return r;
        }
    }
    herr(s->line, "internal: unexpected stmt kind");
    ExecResult r = { .status = EX_FALL };
    return r;
}

static ExecResult exec_body(Frame *f, Block *b) {
    for (size_t i = 0; i < b->n; i++) {
        ExecResult r = exec_stmt(f, b->items[i]);
        if (r.status != EX_FALL) return r;
    }
    ExecResult r = { .status = EX_FALL };
    return r;
}

/* ---------------------------------------------------------------------- *
 * Per-call driver — the TCO wrap-loop                                    *
 * ---------------------------------------------------------------------- */

static Value run_call(Function *fn, Value *args, size_t nargs, int line) {
    (void)line;
    Frame f;
    f.fn  = fn;
    f.top = scope_new(NULL);
    for (size_t i = 0; i < nargs; i++) {
        scope_let(f.top, fn->params[i], args[i], fn->line);
    }
    for (;;) {
        ExecResult r = exec_body(&f, &fn->body);
        if (r.status == EX_RETURN) return r.value;
        if (r.status == EX_TAIL_SELF) {
            f.top = scope_new(NULL);
            for (size_t i = 0; i < r.tail_nargs; i++) {
                scope_let(f.top, fn->params[i], r.tail_args[i], fn->line);
            }
            free(r.tail_args);
            continue;
        }
        herr(fn->line, "function '%s' did not return a value", fn->name);
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
    return run_call(main_fn, NULL, 0, main_fn->line);
}
