/*
 * Hand-written tokenizer for Herbert. Produces a flat list of tokens with
 * source line numbers. The token kind enum is closed (see herbert.h); the
 * lexer raises a clear error via herr() on any unrecognised byte.
 *
 * Lexical rules implemented:
 *   - whitespace (space, tab, CR, LF) is a separator
 *   - `--` introduces a comment that ends at the next newline
 *   - integer literals: one or more decimal digits, parsed as uint64
 *   - string literals: "..." with escapes \n \\ \"
 *   - character literals: '.' single byte, with escapes \n \\ \'
 *   - identifiers: [A-Za-z_][A-Za-z0-9_]*; the keyword set listed below
 *     becomes a distinct token kind rather than TOK_IDENT
 *   - punctuation tokens: ( ) , : . + - = == != < <= > >=
 */

#include "herbert.h"

#include <ctype.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    const char *src;
    size_t      len;
    size_t      pos;
    int         line;
    TokenList  *out;
} L;

static void tl_push(TokenList *tl, Token t) {
    if (tl->n == tl->cap) {
        tl->cap = tl->cap ? tl->cap * 2 : 128;
        tl->items = (Token *)xrealloc(tl->items, tl->cap * sizeof(Token));
    }
    tl->items[tl->n++] = t;
}

static char peek(L *l, size_t off) {
    return l->pos + off < l->len ? l->src[l->pos + off] : '\0';
}

static void skip_trivia(L *l) {
    for (;;) {
        if (l->pos >= l->len) return;
        char c = l->src[l->pos];
        if (c == ' ' || c == '\t' || c == '\r') {
            l->pos++;
        } else if (c == '\n') {
            l->pos++;
            l->line++;
        } else if (c == '-' && peek(l, 1) == '-') {
            while (l->pos < l->len && l->src[l->pos] != '\n') l->pos++;
        } else {
            return;
        }
    }
}

static int is_ident_start(int c) { return isalpha(c) || c == '_'; }
static int is_ident_cont(int c)  { return isalnum(c) || c == '_'; }

static struct { const char *s; TokKind k; } KW[] = {
    {"func",   TOK_FUNC},
    {"end",    TOK_END},
    {"let",    TOK_LET},
    {"return", TOK_RETURN},
    {"do",     TOK_DO},
    {"if",     TOK_IF},
    {"elif",   TOK_ELIF},
    {"else",   TOK_ELSE},
    {"and",    TOK_AND},
    {"or",     TOK_OR},
    {"not",    TOK_NOT},
    {"true",   TOK_TRUE},
    {"false",  TOK_FALSE},
    {"int",    TOK_KW_INT},
    {"bool",   TOK_KW_BOOL},
    {"string", TOK_KW_STRING},
    {"buffer", TOK_KW_BUFFER},
    {"array",  TOK_KW_ARRAY},
    {NULL,     TOK_EOF}
};

static Token make_tok(TokKind k, int line) {
    Token t = {0};
    t.kind = k;
    t.line = line;
    return t;
}

static void lex_ident(L *l) {
    size_t start = l->pos;
    int    line  = l->line;
    while (l->pos < l->len && is_ident_cont((unsigned char)l->src[l->pos])) l->pos++;
    size_t n = l->pos - start;
    for (int i = 0; KW[i].s; i++) {
        size_t kl = strlen(KW[i].s);
        if (kl == n && memcmp(l->src + start, KW[i].s, n) == 0) {
            tl_push(l->out, make_tok(KW[i].k, line));
            return;
        }
    }
    Token t = make_tok(TOK_IDENT, line);
    t.ident = xstrndup(l->src + start, n);
    tl_push(l->out, t);
}

static void lex_int(L *l) {
    int line = l->line;
    uint64_t v = 0;
    bool started = false;
    while (l->pos < l->len && isdigit((unsigned char)l->src[l->pos])) {
        unsigned d = (unsigned)(l->src[l->pos] - '0');
        if (v > (UINT64_MAX - d) / 10) {
            herr(line, "integer literal does not fit in 64 bits");
        }
        v = v * 10 + d;
        l->pos++;
        started = true;
    }
    if (!started) herr(line, "expected digit");
    Token t = make_tok(TOK_INT_LIT, line);
    t.int_val = v;
    tl_push(l->out, t);
}

static uint8_t lex_escape(L *l, char quote) {
    if (l->pos >= l->len) herr(l->line, "unterminated escape");
    char c = l->src[l->pos++];
    if (c == 'n')         return (uint8_t)'\n';
    if (c == '\\')        return (uint8_t)'\\';
    if (c == quote)       return (uint8_t)quote;
    herr(l->line, "unknown escape sequence \\%c", c);
    return 0;
}

static void lex_string(L *l) {
    int line = l->line;
    l->pos++; /* consume opening " */
    uint8_t *buf = NULL;
    size_t   n = 0, cap = 0;
    while (l->pos < l->len) {
        char c = l->src[l->pos];
        if (c == '"') {
            l->pos++;
            Token t   = make_tok(TOK_STR_LIT, line);
            t.str_bytes = buf ? buf : (uint8_t *)xmalloc(1);
            t.str_len   = n;
            tl_push(l->out, t);
            return;
        }
        uint8_t byte;
        if (c == '\\') {
            l->pos++;
            byte = lex_escape(l, '"');
        } else if (c == '\n') {
            herr(line, "newline in string literal (use \\n)");
        } else {
            byte = (uint8_t)c;
            l->pos++;
        }
        if (n == cap) {
            cap = cap ? cap * 2 : 16;
            buf = (uint8_t *)xrealloc(buf, cap);
        }
        buf[n++] = byte;
    }
    herr(line, "unterminated string literal");
}

static void lex_char(L *l) {
    int line = l->line;
    l->pos++; /* consume opening ' */
    if (l->pos >= l->len) herr(line, "unterminated character literal");
    uint8_t byte;
    char c = l->src[l->pos];
    if (c == '\\') {
        l->pos++;
        byte = lex_escape(l, '\'');
    } else if (c == '\n') {
        herr(line, "newline in character literal");
    } else if (c == '\'') {
        herr(line, "empty character literal");
    } else {
        byte = (uint8_t)c;
        l->pos++;
    }
    if (l->pos >= l->len || l->src[l->pos] != '\'') {
        herr(line, "character literal not closed");
    }
    l->pos++;
    Token t = make_tok(TOK_INT_LIT, line);
    t.int_val = (uint64_t)byte;
    tl_push(l->out, t);
}

static void lex_punct(L *l) {
    int  line = l->line;
    char c    = l->src[l->pos];
    char d    = peek(l, 1);
    /* Two-character operators are matched before the single-character forms
     * below (longest match): `<=`/`>=`/`==`/`!=`, and the new shifts `<<`/`>>`
     * which must win over a bare `<`/`>`. */
    if (c == '<' && d == '=') { l->pos += 2; tl_push(l->out, make_tok(TOK_LE, line)); return; }
    if (c == '>' && d == '=') { l->pos += 2; tl_push(l->out, make_tok(TOK_GE, line)); return; }
    if (c == '=' && d == '=') { l->pos += 2; tl_push(l->out, make_tok(TOK_EQ, line)); return; }
    if (c == '!' && d == '=') { l->pos += 2; tl_push(l->out, make_tok(TOK_NE, line)); return; }
    if (c == '<' && d == '<') { l->pos += 2; tl_push(l->out, make_tok(TOK_SHL, line)); return; }
    if (c == '>' && d == '>') { l->pos += 2; tl_push(l->out, make_tok(TOK_SHR, line)); return; }
    l->pos++;
    switch (c) {
        case '(': tl_push(l->out, make_tok(TOK_LPAREN, line)); return;
        case ')': tl_push(l->out, make_tok(TOK_RPAREN, line)); return;
        case ',': tl_push(l->out, make_tok(TOK_COMMA,  line)); return;
        case ':': tl_push(l->out, make_tok(TOK_COLON,  line)); return;
        case '.': tl_push(l->out, make_tok(TOK_DOT,    line)); return;
        case '+': tl_push(l->out, make_tok(TOK_PLUS,   line)); return;
        case '-': tl_push(l->out, make_tok(TOK_MINUS,  line)); return;
        case '*': tl_push(l->out, make_tok(TOK_STAR,    line)); return;
        case '/': tl_push(l->out, make_tok(TOK_SLASH,   line)); return;
        case '%': tl_push(l->out, make_tok(TOK_PERCENT, line)); return;
        case '<': tl_push(l->out, make_tok(TOK_LT,     line)); return;
        case '>': tl_push(l->out, make_tok(TOK_GT,     line)); return;
        case '=': tl_push(l->out, make_tok(TOK_ASSIGN, line)); return;
        case '&': tl_push(l->out, make_tok(TOK_AMP,    line)); return;
        case '|': tl_push(l->out, make_tok(TOK_PIPE,   line)); return;
        case '^': tl_push(l->out, make_tok(TOK_CARET,  line)); return;
        case '~': tl_push(l->out, make_tok(TOK_TILDE,  line)); return;
        default:
            herr(line, "unexpected character '%c' (0x%02x)", c, (unsigned char)c);
    }
}

void lex(const char *src, size_t len, const char *file, TokenList *out) {
    (void)file;
    L l = {0};
    l.src  = src;
    l.len  = len;
    l.pos  = 0;
    l.line = 1;
    l.out  = out;

    for (;;) {
        skip_trivia(&l);
        if (l.pos >= l.len) {
            tl_push(out, make_tok(TOK_EOF, l.line));
            return;
        }
        char c = l.src[l.pos];
        if (is_ident_start((unsigned char)c))       lex_ident(&l);
        else if (isdigit((unsigned char)c))         lex_int(&l);
        else if (c == '"')                          lex_string(&l);
        else if (c == '\'')                         lex_char(&l);
        else                                        lex_punct(&l);
    }
}
