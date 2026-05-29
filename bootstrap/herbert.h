/*
 * Herbert interpreter — host-language (C) bootstrap.
 *
 * Public declarations shared across the interpreter modules. Defines the
 * token kinds the lexer emits, the AST nodes the parser produces, the
 * tagged value representation the evaluator manipulates, and the program
 * registry threaded through all of them.
 *
 * The interpreter is a hand-written C11 program with no third-party
 * dependencies. Function-call dispatch runs on a heap-allocated activation
 * stack (see eval.c): every Herbert call is an Activation with its own op
 * and value stacks, and no Herbert call consumes a C-stack frame. Tail
 * calls — self OR cross-function — reuse the current activation in place
 * and reclaim the outgoing scope chain, so iteration via tail recursion
 * runs in O(1) scope memory.
 */

#ifndef HERBERT_H
#define HERBERT_H

#include <setjmp.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

/* ---------------------------------------------------------------------- *
 * Error handling                                                         *
 * ---------------------------------------------------------------------- */

extern jmp_buf herbert_err_jmp;
extern char    herbert_err_msg[1024];

#if defined(__GNUC__) || defined(__clang__)
__attribute__((noreturn, format(printf, 2, 3)))
#elif defined(_MSC_VER)
__declspec(noreturn)
#endif
void herr(int line, const char *fmt, ...);

/* ---------------------------------------------------------------------- *
 * Allocation helpers                                                     *
 * ---------------------------------------------------------------------- */

void *xmalloc(size_t n);
void *xcalloc(size_t nmemb, size_t size);
void *xrealloc(void *p, size_t n);
char *xstrdup(const char *s);
char *xstrndup(const char *s, size_t n);

/* ---------------------------------------------------------------------- *
 * Tokens                                                                 *
 * ---------------------------------------------------------------------- */

typedef enum {
    TOK_EOF,
    TOK_FUNC, TOK_END, TOK_LET, TOK_RETURN, TOK_DO,
    TOK_IF, TOK_ELIF, TOK_ELSE,
    TOK_AND, TOK_OR, TOK_NOT,
    TOK_TRUE, TOK_FALSE,
    TOK_KW_INT, TOK_KW_BOOL, TOK_KW_STRING, TOK_KW_BUFFER, TOK_KW_ARRAY,
    TOK_LPAREN, TOK_RPAREN, TOK_COMMA, TOK_COLON, TOK_DOT,
    TOK_PLUS, TOK_MINUS,
    TOK_STAR, TOK_SLASH, TOK_PERCENT,
    TOK_LT, TOK_LE, TOK_GT, TOK_GE, TOK_EQ, TOK_NE,
    TOK_AMP, TOK_PIPE, TOK_CARET, TOK_TILDE, TOK_SHL, TOK_SHR,
    TOK_ASSIGN,
    TOK_INT_LIT,
    TOK_STR_LIT,
    TOK_IDENT
} TokKind;

typedef struct {
    TokKind  kind;
    int      line;
    uint64_t int_val;     /* TOK_INT_LIT, char literals stored as ints */
    char    *ident;       /* TOK_IDENT (owned) */
    uint8_t *str_bytes;   /* TOK_STR_LIT raw bytes (not NUL-terminated) */
    size_t   str_len;     /* TOK_STR_LIT length */
} Token;

typedef struct {
    Token *items;
    size_t n;
    size_t cap;
} TokenList;

void lex(const char *src, size_t len, const char *file, TokenList *out);

/* ---------------------------------------------------------------------- *
 * Type expressions (used only as argument to new_array)                  *
 * ---------------------------------------------------------------------- */

typedef enum {
    TE_INT, TE_BOOL, TE_STR, TE_BUF, TE_TUPLE, TE_ARRAY
} TEKind;

typedef struct TypeExpr {
    TEKind            kind;
    int               line;
    struct TypeExpr **items;   /* TE_TUPLE */
    size_t            n_items; /* TE_TUPLE */
    struct TypeExpr  *elem;    /* TE_ARRAY */
} TypeExpr;

/* ---------------------------------------------------------------------- *
 * Expressions                                                            *
 * ---------------------------------------------------------------------- */

typedef enum {
    E_INT, E_BOOL, E_STR, E_NAME, E_CALL, E_NEW_ARRAY,
    E_TUPLE, E_DOT, E_NOT, E_BNOT, E_BINOP
} EKind;

typedef enum {
    OP_ADD, OP_SUB,
    OP_MUL, OP_DIV, OP_MOD,
    OP_LT, OP_LE, OP_GT, OP_GE, OP_EQ_INT, OP_NE_INT,
    OP_AND, OP_OR,
    OP_BAND, OP_BOR, OP_BXOR, OP_SHL, OP_SHR
} BinOp;

typedef struct Expr Expr;

struct Expr {
    EKind    kind;
    int      line;
    uint64_t i_val;          /* E_INT */
    bool     b_val;          /* E_BOOL */
    uint8_t *s_bytes;        /* E_STR (owned) */
    size_t   s_len;          /* E_STR */
    char    *name;           /* E_NAME, E_CALL */
    Expr   **args;           /* E_CALL, E_TUPLE */
    size_t   n_args;
    TypeExpr *type_arg;      /* E_NEW_ARRAY */
    size_t   dot_idx;        /* E_DOT */
    Expr    *child;          /* E_DOT, E_NOT */
    BinOp    op;             /* E_BINOP */
    Expr    *l, *r;          /* E_BINOP */
};

/* ---------------------------------------------------------------------- *
 * Statements                                                             *
 * ---------------------------------------------------------------------- */

typedef enum {
    S_LET, S_ASSIGN, S_RETURN, S_DO, S_IF
} SKind;

typedef struct Stmt Stmt;

typedef struct {
    Stmt **items;
    size_t n;
} Block;

struct Stmt {
    SKind   kind;
    int     line;
    char   *name;      /* S_LET, S_ASSIGN */
    Expr   *e;         /* S_LET, S_ASSIGN, S_RETURN, S_DO */
    /* S_IF: zero or more (if/elif) condition+arm pairs, plus optional else. */
    Expr  **conds;
    Block  *arms;
    size_t  n_arms;
    Block   else_arm;
    bool    has_else;
};

/* ---------------------------------------------------------------------- *
 * Functions and program                                                  *
 * ---------------------------------------------------------------------- */

typedef struct Function {
    char   *name;
    char  **params;
    size_t  n_params;
    Block   body;
    int     line;
    struct Function *next;   /* registry chain */
} Function;

typedef struct {
    Function *head;
    size_t    n;
} Program;

void parse_program(TokenList *tl, Program *out);
Function *program_lookup(Program *p, const char *name);

/* ---------------------------------------------------------------------- *
 * Values                                                                 *
 * ---------------------------------------------------------------------- */

typedef enum { V_INT, V_BOOL, V_STR, V_BUF, V_TUPLE, V_ARRAY } VKind;

typedef struct Value Value;
typedef struct GCObj GCObj;

struct GCObj {
    VKind  kind;
    GCObj *next;
    bool   marked;
};

typedef struct {
    GCObj   gc;
    size_t   len;
    uint8_t *data;
} StringObj;

typedef struct {
    GCObj   gc;
    size_t   len;
    size_t   cap;
    uint8_t *data;
} BufferObj;

typedef struct {
    GCObj  gc;
    size_t  n;
    Value  *items;
} TupleObj;

typedef struct {
    GCObj    gc;
    TypeExpr *elem_type;
    size_t    n;
    size_t    cap;
    Value    *items;
} ArrayObj;

struct Value {
    VKind kind;
    union {
        uint64_t   i;
        bool       b;
        StringObj *s;
        BufferObj *buf;
        TupleObj  *tup;
        ArrayObj  *arr;
    } u;
};

Value v_int(uint64_t i);
Value v_bool(bool b);
Value v_string(const uint8_t *data, size_t len);
Value v_string_take(uint8_t *data, size_t len);
Value v_buffer_new(void);
Value v_tuple(Value *items, size_t n);
Value v_array_new(TypeExpr *elem);

void buffer_append(BufferObj *b, uint8_t byte);
void array_add    (ArrayObj  *a, Value v);

const char *v_kind_name(VKind k);
void        v_print_canonical(Value v, FILE *fp);

/* Host-internal memory reclamation. */
void   gc_register(GCObj *o, VKind kind, size_t bytes);
void   gc_account_delta(ptrdiff_t delta);
void   gc_mark_value(Value v);
void   gc_maybe_collect(void);
void   gc_protect(Value *slot);
void   gc_protect_span(Value *slots, size_t n);
size_t gc_root_mark(void);
void   gc_unprotect_to(size_t mark);
void   eval_gc_mark_roots(void);

/* ---------------------------------------------------------------------- *
 * Built-in dispatch                                                      *
 * ---------------------------------------------------------------------- */

bool is_builtin_name    (const char *name);
bool is_builtin_voidless(const char *name);

/* ---------------------------------------------------------------------- *
 * Evaluator                                                              *
 * ---------------------------------------------------------------------- */

Value run_program(Program *prog);

/* Diagnostic: high-water mark of scopes simultaneously allocated during
 * the most recent run. Tail-recursive iteration must keep this bounded by
 * a small constant — the bound is enforced by the bounded-memory check
 * in run_tests.sh via the HERBERT_REPORT_PEAK env var. */
size_t herbert_peak_live_scopes(void);
size_t herbert_peak_heap_bytes(void);

#endif /* HERBERT_H */
