/*
 * Recursive-descent parser for Herbert. Consumes the token list produced by
 * lex.c and produces a Program: a linked list of Function ASTs, in source
 * order. All function definitions are collected before execution begins so
 * mutual recursion and forward references work.
 *
 * Expression precedence, tightest first (left-associative throughout):
 *   atom / call / tuple / paren
 *   `.N`        postfix tuple access (chains: `t.0.1`)
 *   `not`       prefix unary
 *   `+` `-`     additive
 *   `<` `<=` `>` `>=` `==` `!=`   comparisons
 *   `and`
 *   `or`
 *
 * Type expressions appear only as the single argument to `new_array(...)`.
 * Inside that argument list the parser switches into type-expression mode;
 * elsewhere the type keywords (`int`, `bool`, `string`, `buffer`, `array`)
 * are reserved and cannot appear.
 */

#include "herbert.h"

#include <stdlib.h>
#include <string.h>

bool is_builtin_name(const char *name);

typedef struct {
    Token *t;
    size_t i;
    int    depth;   /* live recursive-descent nesting; shared budget across
                       parse_expr / parse_not / parse_type / parse_block */
} P;

/* Bound recursive-descent nesting so pathologically deep input fails with a
 * clean diagnostic instead of overflowing the C stack (a bare SIGSEGV). One
 * shared budget (P.depth, one limit, one diagnostic) is carried by the four
 * functions that recurse — parse_expr (paren groups, tuple elements, call
 * arguments), parse_block (nested statement arms), parse_not (prefix `not`/`~`
 * chains), parse_type (nested array/tuple types). Each is necessary: e.g.
 * parse_block's increment is what carries the counter up through nested `if`
 * arms (without it, deep statement nesting overflows ~100k deep). Because a
 * single syntactic level can spend more than one increment (a paren level hits
 * both parse_expr and parse_not, ~2), the effective limit is a few hundred
 * nested levels — still vast headroom over the real corpus (max nesting 5) and
 * far below the C-stack overflow, which varies by construct (~35k nested parens,
 * ~100k+ nested statement blocks). */
#define PARSE_MAX_DEPTH 1000

static Token *cur(P *p)   { return &p->t[p->i]; }
static Token *peek1(P *p) { return &p->t[p->i + 1]; }
static void   adv(P *p)   { p->i++; }

static Token *expect_tok(P *p, TokKind k, const char *what) {
    if (cur(p)->kind != k) {
        herr(cur(p)->line, "expected %s", what);
    }
    return &p->t[p->i++];
}

static bool accept_tok(P *p, TokKind k) {
    if (cur(p)->kind == k) { p->i++; return true; }
    return false;
}

/* ---- type expressions (only inside new_array argument) ---- */

static TypeExpr *new_type(TEKind k, int line) {
    TypeExpr *t = (TypeExpr *)xcalloc(1, sizeof(TypeExpr));
    t->kind = k;
    t->line = line;
    return t;
}

static TypeExpr *parse_type(P *p);   /* guarded wrapper, defined below */

static TypeExpr *parse_type_body(P *p) {
    Token *tk = cur(p);
    int    ln = tk->line;
    switch (tk->kind) {
        case TOK_KW_INT:    adv(p); return new_type(TE_INT,  ln);
        case TOK_KW_BOOL:   adv(p); return new_type(TE_BOOL, ln);
        case TOK_KW_STRING: adv(p); return new_type(TE_STR,  ln);
        case TOK_KW_BUFFER: adv(p); return new_type(TE_BUF,  ln);
        case TOK_KW_ARRAY: {
            adv(p);
            expect_tok(p, TOK_LPAREN, "( after array");
            TypeExpr *t = new_type(TE_ARRAY, ln);
            t->elem = parse_type(p);
            expect_tok(p, TOK_RPAREN, ") after array element type");
            return t;
        }
        case TOK_LPAREN: {
            adv(p);
            TypeExpr **items = NULL;
            size_t n = 0, cap = 0;
            for (;;) {
                if (n == cap) {
                    cap = cap ? cap * 2 : 4;
                    items = (TypeExpr **)xrealloc(items, cap * sizeof(TypeExpr *));
                }
                items[n++] = parse_type(p);
                if (!accept_tok(p, TOK_COMMA)) break;
            }
            expect_tok(p, TOK_RPAREN, ") in tuple type");
            if (n < 2) herr(ln, "tuple type must have two or more elements");
            TypeExpr *t = new_type(TE_TUPLE, ln);
            t->items   = items;
            t->n_items = n;
            return t;
        }
        default:
            herr(ln, "expected type expression");
            return NULL;
    }
}

static TypeExpr *parse_type(P *p) {
    TypeExpr *t;
    if (++p->depth > PARSE_MAX_DEPTH)
        herr(cur(p)->line, "nesting too deep (limit %d)", PARSE_MAX_DEPTH);
    t = parse_type_body(p);
    p->depth--;
    return t;
}

/* ---- expressions ---- */

static Expr *parse_expr   (P *p);
static Expr *parse_bitwise(P *p);
static Expr *parse_or     (P *p);
static Expr *parse_and    (P *p);
static Expr *parse_cmp    (P *p);
static Expr *parse_add    (P *p);
static Expr *parse_not    (P *p);
static Expr *parse_dot    (P *p);
static Expr *parse_atom   (P *p);

static Expr *new_expr(EKind k, int line) {
    Expr *e = (Expr *)xcalloc(1, sizeof(Expr));
    e->kind = k;
    e->line = line;
    return e;
}

/* The six bitwise/shift operators form three mutually-exclusive "classes":
 * the AND class (`&`), the OR class (`|`), the XOR class (`^`), and the SHIFT
 * class (`<<` `>>`). Per the settled precedence (Oberon-flat / require-parens-
 * when-mixing), they do NOT join the +/-/cmp/and/or ladder: same-class chaining
 * is left-associative, but mixing a bitwise/shift op with arithmetic, a
 * comparison, a boolean op, or a DIFFERENT bitwise class WITHOUT parentheses is
 * a parse-time error. bit_class() maps a token kind to a class id (0 = not a
 * bitwise/shift op). The SHIFT class lumps `<<` and `>>` together (chaining
 * mixed shifts like `a << b >> c` is same-class and allowed). */
static int bit_class(TokKind k) {
    switch (k) {
        case TOK_AMP:   return 1;  /* AND   */
        case TOK_PIPE:  return 2;  /* OR    */
        case TOK_CARET: return 3;  /* XOR   */
        case TOK_SHL:
        case TOK_SHR:   return 4;  /* SHIFT */
        default:        return 0;
    }
}

static BinOp bit_op(TokKind k) {
    switch (k) {
        case TOK_AMP:   return OP_BAND;
        case TOK_PIPE:  return OP_BOR;
        case TOK_CARET: return OP_BXOR;
        case TOK_SHL:   return OP_SHL;
        default:        return OP_SHR;  /* TOK_SHR */
    }
}

static Expr *parse_expr(P *p) {
    Expr *e;
    if (++p->depth > PARSE_MAX_DEPTH)
        herr(cur(p)->line, "nesting too deep (limit %d)", PARSE_MAX_DEPTH);
    e = parse_bitwise(p);
    p->depth--;
    return e;
}

/* Bitwise/shift level — sits above the classless ladder. Parse a classless
 * expression (parse_or); if a bitwise/shift operator follows, the left operand
 * must be a parenthesised/atomic primary (not a bare classless chain), and the
 * whole chain must stay within a single class. Both rules are enforced so that
 * `a & b | c`, `a << 2 + 3`, `x & 1 == 0`, and `1 + 2 << 1` all reject, while
 * their fully-parenthesised forms parse. */
static Expr *parse_bitwise(P *p) {
    size_t start = p->i;
    Expr  *l     = parse_or(p);
    int    cls   = bit_class(cur(p)->kind);
    if (cls == 0) {
        return l;  /* pure classless expression — ladder unchanged among itself */
    }
    /* A bitwise/shift op follows the left operand. The left operand must be a
     * single primary: parse one primary from `start` and require it to end
     * exactly where parse_or stopped. If parse_or consumed more (an
     * unparenthesised +/-/cmp/and/or), the operator classes are mixed. */
    {
        P probe = { p->t, start, p->depth };
        parse_not(&probe);  /* one prefix-unary primary (~/not/dot/atom/group) */
        if (probe.i != p->i) {
            herr(cur(p)->line,
                 "bitwise/shift operator mixed with another operator class "
                 "without parentheses");
        }
    }
    for (;;) {
        TokKind k   = cur(p)->kind;
        int     kc  = bit_class(k);
        if (kc == 0) {
            /* A non-bitwise binary operator after a committed bitwise chain is
             * a class mix (e.g. the `+` in `1 << 2 + 3`, the `==` in
             * `x & 1 == 0`). Anything that is not a binary operator at all
             * (`)`, `,`, `:`, end, EOF, `.`) simply ends the expression. */
            switch (k) {
                case TOK_PLUS: case TOK_MINUS:
                case TOK_LT: case TOK_LE: case TOK_GT: case TOK_GE:
                case TOK_EQ: case TOK_NE:
                case TOK_AND: case TOK_OR:
                    herr(cur(p)->line,
                         "bitwise/shift operator mixed with another operator "
                         "class without parentheses");
                    break;  /* unreachable (herr is noreturn) */
                default:
                    return l;
            }
        }
        if (kc != cls) {
            herr(cur(p)->line,
                 "different bitwise operator classes mixed without parentheses");
        }
        int ln = cur(p)->line;
        BinOp op = bit_op(k);
        adv(p);
        Expr *e = new_expr(E_BINOP, ln);
        e->op = op;
        e->l  = l;
        e->r  = parse_not(p);  /* operands are primaries, not classless chains */
        l = e;
    }
}

static Expr *parse_or(P *p) {
    Expr *l = parse_and(p);
    while (cur(p)->kind == TOK_OR) {
        int ln = cur(p)->line;
        adv(p);
        Expr *e = new_expr(E_BINOP, ln);
        e->op = OP_OR;
        e->l  = l;
        e->r  = parse_and(p);
        l = e;
    }
    return l;
}

static Expr *parse_and(P *p) {
    Expr *l = parse_cmp(p);
    while (cur(p)->kind == TOK_AND) {
        int ln = cur(p)->line;
        adv(p);
        Expr *e = new_expr(E_BINOP, ln);
        e->op = OP_AND;
        e->l  = l;
        e->r  = parse_cmp(p);
        l = e;
    }
    return l;
}

static Expr *parse_cmp(P *p) {
    Expr *l = parse_add(p);
    for (;;) {
        BinOp op;
        switch (cur(p)->kind) {
            case TOK_LT: op = OP_LT;     break;
            case TOK_LE: op = OP_LE;     break;
            case TOK_GT: op = OP_GT;     break;
            case TOK_GE: op = OP_GE;     break;
            case TOK_EQ: op = OP_EQ_INT; break;
            case TOK_NE: op = OP_NE_INT; break;
            default:     return l;
        }
        int ln = cur(p)->line;
        adv(p);
        Expr *e = new_expr(E_BINOP, ln);
        e->op = op;
        e->l  = l;
        e->r  = parse_add(p);
        l = e;
    }
}

static Expr *parse_add(P *p) {
    Expr *l = parse_not(p);
    for (;;) {
        TokKind k = cur(p)->kind;
        if (k != TOK_PLUS && k != TOK_MINUS) return l;
        int ln = cur(p)->line;
        BinOp op = (k == TOK_PLUS) ? OP_ADD : OP_SUB;
        adv(p);
        Expr *e = new_expr(E_BINOP, ln);
        e->op = op;
        e->l  = l;
        e->r  = parse_not(p);
        l = e;
    }
}

static Expr *parse_not_body(P *p) {
    if (cur(p)->kind == TOK_NOT) {
        int ln = cur(p)->line;
        adv(p);
        Expr *e = new_expr(E_NOT, ln);
        e->child = parse_not(p);
        return e;
    }
    /* `~` is the bitwise (one's-complement) unary. It is a distinct AST kind
     * from boolean `not`, with a distinct type rule (int, not bool); it sits at
     * the same prefix-unary precedence level. */
    if (cur(p)->kind == TOK_TILDE) {
        int ln = cur(p)->line;
        adv(p);
        Expr *e = new_expr(E_BNOT, ln);
        e->child = parse_not(p);
        return e;
    }
    return parse_dot(p);
}

static Expr *parse_not(P *p) {
    Expr *e;
    if (++p->depth > PARSE_MAX_DEPTH)
        herr(cur(p)->line, "nesting too deep (limit %d)", PARSE_MAX_DEPTH);
    e = parse_not_body(p);
    p->depth--;
    return e;
}

static Expr *parse_dot(P *p) {
    Expr *l = parse_atom(p);
    while (cur(p)->kind == TOK_DOT) {
        int ln = cur(p)->line;
        adv(p);
        Token *idx = expect_tok(p, TOK_INT_LIT, "integer literal after .");
        Expr *e = new_expr(E_DOT, ln);
        e->child   = l;
        e->dot_idx = (size_t)idx->int_val;
        l = e;
    }
    return l;
}

static Expr *parse_call_or_name(P *p) {
    Token *id = expect_tok(p, TOK_IDENT, "identifier");
    int    ln = id->line;
    if (cur(p)->kind == TOK_LPAREN) {
        adv(p);
        if (strcmp(id->ident, "new_array") == 0) {
            if (cur(p)->kind == TOK_RPAREN) {
                herr(ln, "new_array requires a type argument");
            }
            Expr *e = new_expr(E_NEW_ARRAY, ln);
            e->name     = xstrdup(id->ident);
            e->type_arg = parse_type(p);
            expect_tok(p, TOK_RPAREN, ") after new_array argument");
            return e;
        }
        Expr **args = NULL;
        size_t n = 0, cap = 0;
        if (cur(p)->kind != TOK_RPAREN) {
            for (;;) {
                if (n == cap) {
                    cap = cap ? cap * 2 : 4;
                    args = (Expr **)xrealloc(args, cap * sizeof(Expr *));
                }
                args[n++] = parse_expr(p);
                if (!accept_tok(p, TOK_COMMA)) break;
            }
        }
        expect_tok(p, TOK_RPAREN, ") after argument list");
        Expr *e = new_expr(E_CALL, ln);
        e->name   = xstrdup(id->ident);
        e->args   = args;
        e->n_args = n;
        return e;
    }
    Expr *e = new_expr(E_NAME, ln);
    e->name = xstrdup(id->ident);
    return e;
}

static Expr *parse_atom(P *p) {
    Token *t  = cur(p);
    int    ln = t->line;
    switch (t->kind) {
        case TOK_INT_LIT: {
            adv(p);
            Expr *e = new_expr(E_INT, ln);
            e->i_val = t->int_val;
            return e;
        }
        case TOK_TRUE: {
            adv(p);
            Expr *e = new_expr(E_BOOL, ln);
            e->b_val = true;
            return e;
        }
        case TOK_FALSE: {
            adv(p);
            Expr *e = new_expr(E_BOOL, ln);
            e->b_val = false;
            return e;
        }
        case TOK_STR_LIT: {
            adv(p);
            Expr *e = new_expr(E_STR, ln);
            e->s_bytes = t->str_bytes;
            e->s_len   = t->str_len;
            return e;
        }
        case TOK_IDENT:
            return parse_call_or_name(p);
        case TOK_LPAREN: {
            adv(p);
            Expr *first = parse_expr(p);
            if (accept_tok(p, TOK_COMMA)) {
                Expr **items = NULL;
                size_t n = 0, cap = 4;
                items = (Expr **)xmalloc(cap * sizeof(Expr *));
                items[n++] = first;
                items[n++] = parse_expr(p);
                while (accept_tok(p, TOK_COMMA)) {
                    if (n == cap) {
                        cap *= 2;
                        items = (Expr **)xrealloc(items, cap * sizeof(Expr *));
                    }
                    items[n++] = parse_expr(p);
                }
                expect_tok(p, TOK_RPAREN, ") after tuple");
                Expr *e = new_expr(E_TUPLE, ln);
                e->args   = items;
                e->n_args = n;
                return e;
            }
            expect_tok(p, TOK_RPAREN, ") after grouping expression");
            return first;
        }
        default:
            herr(ln, "expected expression");
            return NULL;
    }
}

/* ---- statements ---- */

static Stmt *parse_stmt(P *p);

static bool is_block_end(TokKind k) {
    return k == TOK_END || k == TOK_ELIF || k == TOK_ELSE || k == TOK_EOF;
}

static Block parse_block(P *p) {
    Block b = {0};
    size_t cap = 0;
    if (++p->depth > PARSE_MAX_DEPTH)
        herr(cur(p)->line, "nesting too deep (limit %d)", PARSE_MAX_DEPTH);
    while (!is_block_end(cur(p)->kind)) {
        if (b.n == cap) {
            cap = cap ? cap * 2 : 8;
            b.items = (Stmt **)xrealloc(b.items, cap * sizeof(Stmt *));
        }
        b.items[b.n++] = parse_stmt(p);
    }
    p->depth--;
    return b;
}

static Stmt *new_stmt(SKind k, int line) {
    Stmt *s = (Stmt *)xcalloc(1, sizeof(Stmt));
    s->kind = k;
    s->line = line;
    return s;
}

static Stmt *parse_stmt(P *p) {
    Token *t  = cur(p);
    int    ln = t->line;
    switch (t->kind) {
        case TOK_LET: {
            adv(p);
            Token *id = expect_tok(p, TOK_IDENT, "name after let");
            expect_tok(p, TOK_ASSIGN, "= after let name");
            Stmt *s = new_stmt(S_LET, ln);
            s->name = xstrdup(id->ident);
            s->e    = parse_expr(p);
            return s;
        }
        case TOK_RETURN: {
            adv(p);
            Stmt *s = new_stmt(S_RETURN, ln);
            s->e = parse_expr(p);
            return s;
        }
        case TOK_DO: {
            adv(p);
            Expr *e = parse_expr(p);
            if (e->kind != E_CALL) {
                herr(ln, "'do' must be followed by a call expression");
            }
            Stmt *s = new_stmt(S_DO, ln);
            s->e = e;
            return s;
        }
        case TOK_IF: {
            adv(p);
            Expr **conds = NULL;
            Block *arms  = NULL;
            size_t n = 0, cap = 0;
            for (;;) {
                if (n == cap) {
                    cap   = cap ? cap * 2 : 4;
                    conds = (Expr **)xrealloc(conds, cap * sizeof(Expr *));
                    arms  = (Block *)xrealloc(arms,  cap * sizeof(Block));
                }
                conds[n] = parse_expr(p);
                expect_tok(p, TOK_COLON, ": after if/elif condition");
                arms[n]  = parse_block(p);
                if (arms[n].n == 0) {
                    herr(ln, "if/elif arm must contain at least one statement");
                }
                n++;
                if (!accept_tok(p, TOK_ELIF)) break;
            }
            Block else_arm  = {0};
            bool  has_else  = false;
            if (accept_tok(p, TOK_ELSE)) {
                expect_tok(p, TOK_COLON, ": after else");
                else_arm = parse_block(p);
                if (else_arm.n == 0) {
                    herr(ln, "else arm must contain at least one statement");
                }
                has_else = true;
            }
            expect_tok(p, TOK_END, "end to close if");
            Stmt *s     = new_stmt(S_IF, ln);
            s->conds    = conds;
            s->arms     = arms;
            s->n_arms   = n;
            s->else_arm = else_arm;
            s->has_else = has_else;
            return s;
        }
        case TOK_IDENT: {
            if (peek1(p)->kind != TOK_ASSIGN) {
                herr(ln, "expected statement (let/return/do/if or NAME = ...)");
            }
            Token *id = expect_tok(p, TOK_IDENT, "name");
            expect_tok(p, TOK_ASSIGN, "=");
            Stmt *s = new_stmt(S_ASSIGN, ln);
            s->name = xstrdup(id->ident);
            s->e    = parse_expr(p);
            return s;
        }
        default:
            herr(ln, "expected statement");
            return NULL;
    }
}

/* ---- functions ---- */

static Function *parse_function(P *p) {
    Token *kw = expect_tok(p, TOK_FUNC, "func");
    int    ln = kw->line;
    Token *name = expect_tok(p, TOK_IDENT, "function name");
    expect_tok(p, TOK_LPAREN, "( in function definition");
    char **params = NULL;
    size_t n = 0, cap = 0;
    if (cur(p)->kind != TOK_RPAREN) {
        for (;;) {
            Token *pname = expect_tok(p, TOK_IDENT, "parameter name");
            if (n == cap) {
                cap    = cap ? cap * 2 : 4;
                params = (char **)xrealloc(params, cap * sizeof(char *));
            }
            for (size_t k = 0; k < n; k++) {
                if (strcmp(params[k], pname->ident) == 0) {
                    herr(pname->line, "duplicate parameter name '%s'", pname->ident);
                }
            }
            params[n++] = xstrdup(pname->ident);
            if (!accept_tok(p, TOK_COMMA)) break;
        }
    }
    expect_tok(p, TOK_RPAREN, ") in function definition");
    expect_tok(p, TOK_COLON, ": after function header");
    Block body = parse_block(p);
    if (body.n == 0) herr(ln, "function body must contain at least one statement");
    expect_tok(p, TOK_END, "end to close function");

    Function *fn = (Function *)xcalloc(1, sizeof(Function));
    fn->name     = xstrdup(name->ident);
    fn->params   = params;
    fn->n_params = n;
    fn->body     = body;
    fn->line     = ln;
    return fn;
}

void parse_program(TokenList *tl, Program *out) {
    P p = {0};
    p.t = tl->items;
    p.i = 0;
    out->head = NULL;
    out->n    = 0;
    Function **tail = &out->head;
    while (cur(&p)->kind != TOK_EOF) {
        if (cur(&p)->kind != TOK_FUNC) {
            herr(cur(&p)->line, "expected 'func' at top level");
        }
        Function *fn = parse_function(&p);
        if (is_builtin_name(fn->name)) {
            herr(fn->line,
                 "user function cannot reuse built-in name '%s'", fn->name);
        }
        for (Function *e = out->head; e; e = e->next) {
            if (strcmp(e->name, fn->name) == 0) {
                herr(fn->line, "function '%s' already defined", fn->name);
            }
        }
        *tail = fn;
        tail  = &fn->next;
        out->n++;
    }
}

Function *program_lookup(Program *p, const char *name) {
    for (Function *f = p->head; f; f = f->next) {
        if (strcmp(f->name, name) == 0) return f;
    }
    return NULL;
}
