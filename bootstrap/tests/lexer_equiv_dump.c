#include "herbert.h"

#include <ctype.h>
#include <errno.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef enum {
    CK_IDENT = 0,
    CK_INT = 1,
    CK_STRING = 2,
    CK_CHAR = 3,
    CK_PUNCT = 4,
    CK_OP = 5
} CoarseKind;

typedef struct {
    CoarseKind kind;
    size_t start;
    size_t end;
    int line;
} Span;

typedef struct {
    const char *src;
    size_t len;
    size_t pos;
    int line;
} SpanScan;

static void die(const char *msg) {
    fprintf(stderr, "lexer_equiv_dump: %s\n", msg);
    exit(1);
}

static char *read_file(const char *path, size_t *out_len) {
    FILE *fp = fopen(path, "rb");
    if (!fp) {
        perror(path);
        exit(2);
    }
    if (fseek(fp, 0, SEEK_END) != 0) {
        perror("fseek");
        exit(2);
    }
    long n = ftell(fp);
    if (n < 0) {
        perror("ftell");
        exit(2);
    }
    rewind(fp);
    char *buf = (char *)xmalloc((size_t)n + 1);
    size_t got = fread(buf, 1, (size_t)n, fp);
    fclose(fp);
    if (got != (size_t)n) die("short read");
    buf[n] = '\0';
    *out_len = (size_t)n;
    return buf;
}

static char peek(SpanScan *s, size_t off) {
    return s->pos + off < s->len ? s->src[s->pos + off] : '\0';
}

static int is_ident_start(int c) {
    return isalpha((unsigned char)c) || c == '_';
}

static int is_ident_cont(int c) {
    return isalnum((unsigned char)c) || c == '_';
}

static void skip_trivia(SpanScan *s) {
    for (;;) {
        if (s->pos >= s->len) return;
        char c = s->src[s->pos];
        if (c == ' ' || c == '\t' || c == '\r') {
            s->pos++;
        } else if (c == '\n') {
            s->pos++;
            s->line++;
        } else if (c == '-' && peek(s, 1) == '-') {
            while (s->pos < s->len && s->src[s->pos] != '\n') s->pos++;
        } else {
            return;
        }
    }
}

static int span_next(SpanScan *s, Span *out) {
    skip_trivia(s);
    if (s->pos >= s->len) return 0;

    size_t start = s->pos;
    int line = s->line;
    char c = s->src[s->pos];
    char d = peek(s, 1);

    if (is_ident_start((unsigned char)c)) {
        s->pos++;
        while (s->pos < s->len && is_ident_cont((unsigned char)s->src[s->pos])) {
            s->pos++;
        }
        *out = (Span){CK_IDENT, start, s->pos, line};
        return 1;
    }
    if (isdigit((unsigned char)c)) {
        s->pos++;
        while (s->pos < s->len && isdigit((unsigned char)s->src[s->pos])) {
            s->pos++;
        }
        *out = (Span){CK_INT, start, s->pos, line};
        return 1;
    }
    if (c == '"') {
        s->pos++;
        while (s->pos < s->len) {
            char q = s->src[s->pos++];
            if (q == '"') break;
            if (q == '\\') {
                if (s->pos >= s->len) die("unterminated string escape in span scanner");
                s->pos++;
            } else if (q == '\n') {
                die("newline in string span");
            }
        }
        *out = (Span){CK_STRING, start, s->pos, line};
        return 1;
    }
    if (c == '\'') {
        s->pos++;
        if (s->pos >= s->len) die("unterminated char span");
        if (s->src[s->pos] == '\\') {
            s->pos += 2;
        } else {
            s->pos++;
        }
        if (s->pos >= s->len || s->src[s->pos] != '\'') die("char span not closed");
        s->pos++;
        *out = (Span){CK_CHAR, start, s->pos, line};
        return 1;
    }
    if ((c == '<' && (d == '=' || d == '<')) ||
        (c == '>' && (d == '=' || d == '>')) ||
        (c == '=' && d == '=') ||
        (c == '!' && d == '=')) {
        s->pos += 2;
        *out = (Span){CK_OP, start, s->pos, line};
        return 1;
    }
    if (c == '=' || c == '+' || c == '-' || c == '*' || c == '/' ||
        c == '%' || c == '<' || c == '>' || c == '&' || c == '|' ||
        c == '^' || c == '~') {
        s->pos++;
        *out = (Span){CK_OP, start, s->pos, line};
        return 1;
    }
    if (c == '(' || c == ')' || c == ',' || c == ':' || c == '.') {
        s->pos++;
        *out = (Span){CK_PUNCT, start, s->pos, line};
        return 1;
    }
    die("unexpected byte in span scanner");
    return 0;
}

static int span_eq(const char *src, Span sp, const char *lit) {
    size_t n = sp.end - sp.start;
    return strlen(lit) == n && memcmp(src + sp.start, lit, n) == 0;
}

static const char *fixed_text(TokKind k) {
    switch (k) {
        case TOK_FUNC: return "func";
        case TOK_END: return "end";
        case TOK_LET: return "let";
        case TOK_RETURN: return "return";
        case TOK_DO: return "do";
        case TOK_IF: return "if";
        case TOK_ELIF: return "elif";
        case TOK_ELSE: return "else";
        case TOK_AND: return "and";
        case TOK_OR: return "or";
        case TOK_NOT: return "not";
        case TOK_TRUE: return "true";
        case TOK_FALSE: return "false";
        case TOK_KW_INT: return "int";
        case TOK_KW_BOOL: return "bool";
        case TOK_KW_STRING: return "string";
        case TOK_KW_BUFFER: return "buffer";
        case TOK_KW_ARRAY: return "array";
        case TOK_LPAREN: return "(";
        case TOK_RPAREN: return ")";
        case TOK_COMMA: return ",";
        case TOK_COLON: return ":";
        case TOK_DOT: return ".";
        case TOK_PLUS: return "+";
        case TOK_MINUS: return "-";
        case TOK_STAR: return "*";
        case TOK_SLASH: return "/";
        case TOK_PERCENT: return "%";
        case TOK_LT: return "<";
        case TOK_LE: return "<=";
        case TOK_GT: return ">";
        case TOK_GE: return ">=";
        case TOK_EQ: return "==";
        case TOK_NE: return "!=";
        case TOK_AMP: return "&";
        case TOK_PIPE: return "|";
        case TOK_CARET: return "^";
        case TOK_TILDE: return "~";
        case TOK_SHL: return "<<";
        case TOK_SHR: return ">>";
        case TOK_ASSIGN: return "=";
        default: return NULL;
    }
}

static uint8_t decode_escape(char c, char quote) {
    if (c == 'n') return (uint8_t)'\n';
    if (c == '\\') return (uint8_t)'\\';
    if (c == quote) return (uint8_t)quote;
    die("unknown escape in raw literal");
    return 0;
}

static uint64_t parse_raw_int(const char *src, Span sp) {
    uint64_t v = 0;
    for (size_t i = sp.start; i < sp.end; i++) {
        unsigned d = (unsigned)(src[i] - '0');
        if (v > (UINT64_MAX - d) / 10) die("raw int overflow");
        v = v * 10 + d;
    }
    return v;
}

static uint8_t parse_raw_char(const char *src, Span sp) {
    size_t i = sp.start + 1;
    size_t end = sp.end - 1;
    if (i >= end) die("empty raw char");
    if (src[i] == '\\') {
        if (i + 2 != end) die("bad raw char escape length");
        return decode_escape(src[i + 1], '\'');
    }
    if (i + 1 != end) die("bad raw char length");
    return (uint8_t)src[i];
}

static void assert_string_payload(Token *t, const char *src, Span sp) {
    size_t cap = sp.end - sp.start;
    uint8_t *buf = (uint8_t *)xmalloc(cap ? cap : 1);
    size_t n = 0;
    for (size_t i = sp.start + 1; i + 1 < sp.end; i++) {
        if (src[i] == '\\') {
            if (i + 2 >= sp.end) die("bad raw string escape");
            buf[n++] = decode_escape(src[++i], '"');
        } else {
            buf[n++] = (uint8_t)src[i];
        }
    }
    if (t->str_len != n || memcmp(t->str_bytes, buf, n) != 0) {
        die("C string token payload differs from raw span decode");
    }
    free(buf);
}

static CoarseKind assert_token_matches_span(Token *t, const char *src, Span sp) {
    if (t->line != sp.line) die("C token line differs from raw span line");

    if (sp.kind == CK_IDENT) {
        if (t->kind == TOK_IDENT) {
            size_t n = sp.end - sp.start;
            if (strlen(t->ident) != n || memcmp(t->ident, src + sp.start, n) != 0) {
                die("C identifier payload differs from raw span");
            }
            return CK_IDENT;
        }
        const char *kw = fixed_text(t->kind);
        if (kw && span_eq(src, sp, kw)) return CK_IDENT;
        die("C token is not the raw identifier/keyword span");
    }

    if (sp.kind == CK_INT) {
        if (t->kind != TOK_INT_LIT) die("C token is not an int literal");
        if (t->int_val != parse_raw_int(src, sp)) die("C int payload differs from raw span");
        return CK_INT;
    }

    if (sp.kind == CK_CHAR) {
        if (t->kind != TOK_INT_LIT) die("C char token is not stored as int literal");
        if (t->int_val != (uint64_t)parse_raw_char(src, sp)) {
            die("C char payload differs from raw span decode");
        }
        return CK_CHAR;
    }

    if (sp.kind == CK_STRING) {
        if (t->kind != TOK_STR_LIT) die("C token is not a string literal");
        assert_string_payload(t, src, sp);
        return CK_STRING;
    }

    const char *fixed = fixed_text(t->kind);
    if (!fixed || !span_eq(src, sp, fixed)) die("C punctuation/operator differs from raw span");
    if (sp.kind == CK_PUNCT) return CK_PUNCT;
    if (sp.kind == CK_OP) return CK_OP;
    die("unknown coarse span kind");
    return CK_IDENT;
}

static void print_escaped_raw(const char *src, Span sp) {
    for (size_t i = sp.start; i < sp.end; i++) {
        unsigned char c = (unsigned char)src[i];
        if (c == '\n') {
            fputs("\\n", stdout);
        } else if (c == '\\') {
            fputs("\\\\", stdout);
        } else if (c == '"') {
            fputs("\\\"", stdout);
        } else {
            fputc(c, stdout);
        }
    }
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s <source.herb>\n", argc > 0 ? argv[0] : "lexer_equiv_dump");
        return 2;
    }
    if (setjmp(herbert_err_jmp) != 0) {
        fprintf(stderr, "lexer_equiv_dump: C lex failed: %s\n", herbert_err_msg);
        return 1;
    }

    size_t src_len = 0;
    char *src = read_file(argv[1], &src_len);

    TokenList tl = {0};
    lex(src, src_len, argv[1], &tl);

    SpanScan scan = {src, src_len, 0, 1};
    int first = 1;
    fputc('[', stdout);
    for (size_t i = 0; i < tl.n; i++) {
        Token *t = &tl.items[i];
        if (t->kind == TOK_EOF) {
            Span extra;
            if (span_next(&scan, &extra)) die("raw span remains after C EOF token");
            if (i + 1 != tl.n) die("C token stream has tokens after EOF");
            break;
        }

        Span sp;
        if (!span_next(&scan, &sp)) die("C token remains after raw spans are exhausted");
        CoarseKind kind = assert_token_matches_span(t, src, sp);

        if (!first) fputs(", ", stdout);
        first = 0;
        printf("(%d, \"", (int)kind);
        print_escaped_raw(src, sp);
        fputs("\")", stdout);
    }
    fputs("]\n", stdout);
    return 0;
}
