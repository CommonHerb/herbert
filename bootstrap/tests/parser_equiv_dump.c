/* parser_equiv_dump.c -- independent C-side AST dumper for the parser-
 * equivalence altimeter.
 *
 * Builds against the C bootstrap's OWN parser (bootstrap/parse.c) and walks
 * the resulting typed tree (Program -> Function -> Block -> Stmt -> Expr /
 * TypeExpr, defined in bootstrap/herbert.h) to emit a normalized S-expression.
 *
 * INDEPENDENCE (the load-bearing property): this dumper is derived ONLY from
 * the C structs/enums in herbert.h + the grammar in parse.c. It does NOT read,
 * include, or copy any Herbert-side serializer. The S-expression SCHEMA below
 * is the written contract that BOTH sides implement independently:
 *
 *   node    := '(' tag (' ' atom)* (' ' node)* ')'        [atoms then kids]
 *   dot     := '(dot ' node ' ' idx ')'                   [kid then atom]
 *   program := (program  <func>...)
 *   func    := (func NAME (params P...) (body S...))
 *   stmt    := (let NAME e) | (assign NAME e) | (return e) | (do e)
 *            | (if (clause cond (body...))... (else (body...))?)
 *   expr    := (int N) | (bool true|false) | (name X)
 *            | (str LEN BYTE...)            [LEN then each decoded byte, decimal]
 *            | (call NAME arg...)           [new_array(T) => (call new_array <type>)]
 *            | (tuple e...) | (dot e idx) | (not e) | (bnot e)
 *            | (<binop> l r)               [add sub mul div mod lt le gt ge eq ne
 *                                           and or band bor bxor shl shr]
 *   type    := (type int|bool|string|buffer)
 *            | (type-array <type>) | (type-tuple <type>...)
 *
 * CHAR CANONICALIZATION: a Herbert char literal ('a') is an int value; the C
 * lexer already stores it as TOK_INT_LIT (-> E_INT), so it dumps as (int N).
 * The Herbert side canonicalizes its "char" tag to "int" to match. Only the TAG
 * is canonicalized, never the value -- a real value/structure divergence still
 * shows. This is the ONE deliberate, documented equivalence between the sides.
 */
#include "herbert.h"

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void die(const char *msg) {
    fprintf(stderr, "parser_equiv_dump: %s\n", msg);
    exit(1);
}

static char *read_file(const char *path, size_t *out_len) {
    FILE *fp = fopen(path, "rb");
    if (!fp) { perror(path); exit(2); }
    if (fseek(fp, 0, SEEK_END) != 0) { perror("fseek"); exit(2); }
    long n = ftell(fp);
    if (n < 0) { perror("ftell"); exit(2); }
    rewind(fp);
    char *buf = (char *)xmalloc((size_t)n + 1);
    size_t got = fread(buf, 1, (size_t)n, fp);
    fclose(fp);
    if (got != (size_t)n) die("short read");
    buf[n] = '\0';
    *out_len = (size_t)n;
    return buf;
}

static const char *binop_tag(BinOp op) {
    switch (op) {
        case OP_ADD: return "add";
        case OP_SUB: return "sub";
        case OP_MUL: return "mul";
        case OP_DIV: return "div";
        case OP_MOD: return "mod";
        case OP_LT:  return "lt";
        case OP_LE:  return "le";
        case OP_GT:  return "gt";
        case OP_GE:  return "ge";
        case OP_EQ_INT: return "eq";
        case OP_NE_INT: return "ne";
        case OP_AND: return "and";
        case OP_OR:  return "or";
        case OP_BAND: return "band";
        case OP_BOR:  return "bor";
        case OP_BXOR: return "bxor";
        case OP_SHL:  return "shl";
        case OP_SHR:  return "shr";
    }
    die("unknown binop");
    return NULL;
}

static void dump_type(TypeExpr *t) {
    if (!t) die("null type");
    switch (t->kind) {
        case TE_INT:  fputs("(type int)", stdout); return;
        case TE_BOOL: fputs("(type bool)", stdout); return;
        case TE_STR:  fputs("(type string)", stdout); return;
        case TE_BUF:  fputs("(type buffer)", stdout); return;
        case TE_ARRAY:
            fputs("(type-array ", stdout);
            dump_type(t->elem);
            fputc(')', stdout);
            return;
        case TE_TUPLE:
            fputs("(type-tuple", stdout);
            for (size_t i = 0; i < t->n_items; i++) {
                fputc(' ', stdout);
                dump_type(t->items[i]);
            }
            fputc(')', stdout);
            return;
    }
    die("unknown type kind");
}

static void dump_expr(Expr *e) {
    if (!e) die("null expr");
    switch (e->kind) {
        case E_INT:
            printf("(int %" PRIu64 ")", e->i_val);
            return;
        case E_BOOL:
            printf("(bool %s)", e->b_val ? "true" : "false");
            return;
        case E_STR:
            /* s_bytes is uint8_t* here, but the (unsigned char) cast is kept
             * defensively: on a signed-char platform a plain (unsigned) cast
             * would sign-extend a high-bit byte (0xFF -> 4294967295, not 255)
             * and diverge from the Herbert dump (which emits the byte value). */
            printf("(str %zu", e->s_len);
            for (size_t i = 0; i < e->s_len; i++) printf(" %u", (unsigned)(unsigned char)e->s_bytes[i]);
            fputc(')', stdout);
            return;
        case E_NAME:
            printf("(name %s)", e->name);
            return;
        case E_CALL:
            printf("(call %s", e->name);
            for (size_t i = 0; i < e->n_args; i++) {
                fputc(' ', stdout);
                dump_expr(e->args[i]);
            }
            fputc(')', stdout);
            return;
        case E_NEW_ARRAY:
            fputs("(call new_array ", stdout);
            dump_type(e->type_arg);
            fputc(')', stdout);
            return;
        case E_TUPLE:
            fputs("(tuple", stdout);
            for (size_t i = 0; i < e->n_args; i++) {
                fputc(' ', stdout);
                dump_expr(e->args[i]);
            }
            fputc(')', stdout);
            return;
        case E_DOT:
            fputs("(dot ", stdout);
            dump_expr(e->child);
            printf(" %zu)", e->dot_idx);
            return;
        case E_NOT:
            fputs("(not ", stdout);
            dump_expr(e->child);
            fputc(')', stdout);
            return;
        case E_BNOT:
            fputs("(bnot ", stdout);
            dump_expr(e->child);
            fputc(')', stdout);
            return;
        case E_BINOP:
            printf("(%s ", binop_tag(e->op));
            dump_expr(e->l);
            fputc(' ', stdout);
            dump_expr(e->r);
            fputc(')', stdout);
            return;
    }
    die("unknown expr kind");
}

static void dump_block(Block *b) {
    fputs("(body", stdout);
    for (size_t i = 0; i < b->n; i++) {
        fputc(' ', stdout);
        Stmt *s = b->items[i];
        switch (s->kind) {
            case S_LET:
                printf("(let %s ", s->name);
                dump_expr(s->e);
                fputc(')', stdout);
                break;
            case S_ASSIGN:
                printf("(assign %s ", s->name);
                dump_expr(s->e);
                fputc(')', stdout);
                break;
            case S_RETURN:
                fputs("(return ", stdout);
                dump_expr(s->e);
                fputc(')', stdout);
                break;
            case S_DO:
                fputs("(do ", stdout);
                dump_expr(s->e);
                fputc(')', stdout);
                break;
            case S_IF:
                fputs("(if", stdout);
                for (size_t a = 0; a < s->n_arms; a++) {
                    fputs(" (clause ", stdout);
                    dump_expr(s->conds[a]);
                    fputc(' ', stdout);
                    dump_block(&s->arms[a]);
                    fputc(')', stdout);
                }
                if (s->has_else) {
                    fputs(" (else ", stdout);
                    dump_block(&s->else_arm);
                    fputc(')', stdout);
                }
                fputc(')', stdout);
                break;
            default:
                die("unknown stmt kind");
        }
    }
    fputc(')', stdout);
}

static void dump_function(Function *f) {
    printf("(func %s (params", f->name);
    for (size_t i = 0; i < f->n_params; i++) printf(" %s", f->params[i]);
    fputs(") ", stdout);
    dump_block(&f->body);
    fputc(')', stdout);
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s <source.herb>\n", argc > 0 ? argv[0] : "parser_equiv_dump");
        return 2;
    }
    if (setjmp(herbert_err_jmp) != 0) {
        /* Parse/lex error: print the located C diagnostic for error-parity. */
        fprintf(stderr, "%s\n", herbert_err_msg);
        return 1;
    }

    size_t src_len = 0;
    char *src = read_file(argv[1], &src_len);

    TokenList tl = {0};
    lex(src, src_len, argv[1], &tl);

    Program prog = {0};
    parse_program(&tl, &prog);

    fputs("(program", stdout);
    for (Function *f = prog.head; f; f = f->next) {
        fputc(' ', stdout);
        dump_function(f);
    }
    fputs(")\n", stdout);
    return 0;
}
