/* tests/codegen-twin.c — the C oracle for bootstrap/aster.ast's M3d codegen.
 *
 * The contract (bootstrap/CODEGEN-SPEC.md, frozen for v0.23.46-dev): the
 * Aster side reads one Aster source on stdin and writes one AArch64 ELF64
 * ET_EXEC on stdout; on failure it prints a single `aster: error: <Cxx> at
 * L:C` to stderr, leaves stdout empty, and exits 1. This side reproduces that
 * byte for byte on every accepted program — the same ELF layout (§9: base
 * 0x400000, .text@0x401000 / .rodata@0x600000 / .data@0x800000, three
 * PT_LOAD segments), the same three passes (cg_collect address/label
 * allocation -> cg_gen_program linearisation into textw: i32[262144] ->
 * elf_emit fixup back-patch + section/segment emission), and the same
 * diagnostics — and the same exit statuses (0 clean, 1 error, stdout empty
 * on error). tests/codegen-checks.sh builds this twin and the reference
 * compiler (bootstrap/aster.ast build-obj'd + stdlib/aster_std.ast, linked
 * into "verifybin") and diffs the two's ELF output across the corpus.
 *
 * This is written from the specification, not transliterated from the Aster
 * source, and the two differ in shape wherever the spec leaves room:
 *
 *   - the node graph is a struct array, not the bootstrap's seven parallel
 *     i32 arrays; child chains link node indices (0-based, -1 = none) rather
 *     than handles (index + 1, 0 = none). The NK/NF/NN/NT/NTY/ETY/EAR macros
 *     map -1 to 0 so the bootstrap's 1-based ported logic can be reused
 *     unchanged.
 *   - expressions lower through an explicit work stack (gen_expr_at(node,
 *     state, want) with a (node,state,want) triple and a gx_top cursor), not
 *     recursion — the same discipline the bootstrap uses so a 30k+ node
 *     left-associative chain (dense.ast-class corpora) cannot blow the host
 *     or guest call stack.
 *   - temporaries come from a LIFO free list over X0-X15 (alloc_tmp /
 *     free_tmp); a release that is not the top of the stack trips the leak
 *     guard C12, exactly as in the bootstrap.
 *   - the input goes through stdio (fread), not read(2); the emitted bytes go
 *     through putb/putn + flush_out(), the same output channel the bootstrap
 *     uses, so the two streams meet in one buffer.
 *
 * Three arithmetic corners are spelled out because the bootstrap's host
 * compiler emits AArch64 instructions whose wrap the C standards leave
 * undefined: INT64_MIN / -1 and INT64_MIN % -1 answer INT64_MIN and 0 (SDIV
 * and MSUB wrap, they do not trap), and >> on a signed left operand is an
 * arithmetic shift (ASR). -fwrapv covers addition, subtraction and
 * multiplication; the shift is computed through unsigned to keep the
 * overflow test's bit pattern the host's.
 *
 * Build (same flags as the other twins, tests/stdlib-checks.sh's convention):
 *   gcc -std=c11 -O2 -Wall -Wextra -Werror -fwrapv -fno-builtin \
 *       -I. -o codegen-twin tests/codegen-twin.c
 */
#include <ctype.h>
#include <limits.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lexer_names.h"   /* generated: TK_* codes, TK_NAMES, KEYWORDS */
#include "parser_names.h"  /* generated: E_/S_/N_ codes, the name tables */

#define SRCMAX 1048576
#define TOKMAX 65536
#define NODEMAX 65536
#define NESTMAX 96          /* C1: markers + prefixes open at once */
#define BLOCKMAX 96         /* C2: blocks entered + else-if links taken */
#define MAXPARAMS 32        /* P7 fires at the 33rd parameter */
#define MAXARGS 32          /* P50 fires at the 33rd argument */
#define MAXDIM 1048576      /* the array-length range, P25 */

/* ------------------------------------------------------------------ tokens */
struct tok {
    int kind;   /* TK_* */
    int start;  /* srcbuf offset, or strpool offset for TK_String */
    int len;    /* text length in bytes */
    int line;
    int col;
};

static unsigned char srcbuf[SRCMAX];    /* the source text */
static unsigned char strpool[SRCMAX];   /* decoded string-literal values */
static struct tok toks[TOKMAX];         /* the tokens, End excluded */

static int srclen;                      /* bytes read from stdin */
static int spool;                       /* strpool fill level */
static int ntok;                        /* tokens stored */
static int pos;                         /* cursor into srcbuf */
static int line = 1, col = 1;           /* position of the byte at pos */
static int eline = 1, ecol = 1;         /* the End token's position */

/* --------------------------------------------------------------------- AST */
struct node {
    int kind;      /* E_/S_/N_ (§2) */
    int tok;       /* introducing token index; -1 = the End token */
    int first;     /* first child of the sibling chain, -1 = none */
    int last;      /* last of that chain, so an append is O(1) */
    int next;      /* next sibling in the chain */
    int ty;        /* type tag (§2.4): Param, Global, Function, Let */
    int count;     /* a Global's array element count, 1 for a scalar */
};

static struct node nodes[NODEMAX];
static int nnodes;

/* The declared names, for the duplicate checks (P17, P21, P18). A name is a
 * token index: two names are equal when their spans are. Both tables are
 * sized by the node cap — every item allocates one node, and C3 fires first —
 * so neither can overrun. */
static int fntok[NODEMAX];
static int gltok[NODEMAX];
static int ptok[MAXPARAMS + 1];         /* P7 fires at the 33rd */
static int nfuncs, nglobs, nparams;

/* The parser's cursor and the two nesting counters the caps police. */
static int p;                           /* index of the current token */
static int exdepth;                     /* C1 */
static int sdepth;                      /* C2 */

/* The converted number (§6.2): the value, why it is not exact (1 too large
 * for u64, 2 saturated above i64 max), and the array-length reading. */
static int64_t numval;
static int numflag;
static int numcnt;

/* Diagnostics stage here; every interpolated byte comes from the source or
 * from framing, so the source cap bounds the longest line. */
static char msgbuf[SRCMAX + 512];

/* ----------------------------------------------------------- diagnostics */
/* One line on stderr, `aster: error: <message>`, exit 1 (spec §1, §11). None
 * of these ever returns; the twin has no first-error flag to thread because
 * the first diagnostic ends the run, exactly as the bootstrap's does. */
static void die_np(const char *msg) {
    fprintf(stderr, "aster: error: %s\n", msg);
    exit(1);
}
static void die_at(const char *msg, int l, int c) {
    fprintf(stderr, "aster: error: %s at %d:%d\n", msg, l, c);
    exit(1);
}
static void die_c1(void) { die_np("expression nests too deeply (limit 96)"); }
static void die_c2(void) { die_np("statements nest too deeply (limit 96)"); }
static void die_c3(void) { die_np("too many AST nodes (limit 65536)"); }
/* E6: the only diagnostic whose suffix follows the position. */
static void die_e6(int l, int c) {
    fprintf(stderr, "aster: error: non-ASCII character at %d:%d"
                    " (Aster source must be ASCII)\n", l, c);
    exit(1);
}

/* The messages that interpolate a name. `%.*s` prints the token's span with
 * no copy and no truncation — the buffer is sized for the source cap. */
static int tok_line(int t);
static int tok_col(int t);
static void die_name_np(const char *msg, int nt) {
    snprintf(msgbuf, sizeof msgbuf, "%s%.*s", msg,
             toks[nt].len, srcbuf + toks[nt].start);
    die_np(msgbuf);
}
static void die_name_at(const char *msg, int nt) {
    snprintf(msgbuf, sizeof msgbuf, "%s%.*s", msg,
             toks[nt].len, srcbuf + toks[nt].start);
    die_at(msgbuf, tok_line(nt), tok_col(nt));
}

/* ---------------------------------------------------------------- cursor */
static int tok_line(int t) {
    return (t < 0 || t >= ntok) ? eline : toks[t].line;
}
static int tok_col(int t) {
    return (t < 0 || t >= ntok) ? ecol : toks[t].col;
}
static int cur(void)  { return p >= ntok ? TK_End : toks[p].kind; }
static int ahead(void) { return p + 1 >= ntok ? TK_End : toks[p + 1].kind; }
static void adv(void) { if (p < ntok) p++; }

/* ---------------------------------------------------------------- names */
static int name_eq(int a, int b) {
    if (toks[a].len != toks[b].len) return 0;
    return memcmp(srcbuf + toks[a].start, srcbuf + toks[b].start,
                  (size_t)toks[a].len) == 0;
}
static int name_is(const char *lit) {
    int start = toks[p].start, n = toks[p].len, i = 0;
    while (lit[i]) {
        if (i >= n) return 0;
        if ((unsigned char)lit[i] != srcbuf[start + i]) return 0;
        i++;
    }
    return i == n;
}

/* --------------------------------------------------------------- the pool */
static int newnode(int kind, int tok) {
    if (nnodes >= NODEMAX) die_c3();
    nodes[nnodes].kind = kind;
    nodes[nnodes].tok = tok;
    nodes[nnodes].first = -1;
    nodes[nnodes].last = -1;
    nodes[nnodes].next = -1;
    nodes[nnodes].ty = 0;
    nodes[nnodes].count = 0;
    return nnodes++;
}
static void append(int parent, int child) {
    if (nodes[parent].last < 0) nodes[parent].first = child;
    else nodes[nodes[parent].last].next = child;
    nodes[parent].last = child;
}

/* ------------------------------------------------------------ the scanner */
/* LEXER-SPEC.md §3-§6, unchanged: the M3b parser's input is the M3a token
 * stream, and its diagnostics (E1-E9) still fire first (PARSER-SPEC §12.1). */
static int push(int kind, int start, int len, int tl, int tc) {
    if (ntok >= TOKMAX) die_np("too many tokens (limit 65536)");
    toks[ntok].kind = kind;
    toks[ntok].start = start;
    toks[ntok].len = len;
    toks[ntok].line = tl;
    toks[ntok].col = tc;
    ntok++;
    return 0;
}
static int keyword_kind(const unsigned char *id, int n) {
    for (int i = 0; i < KW_COUNT; i++) {
        const char *sp = KEYWORDS[i].spelling;
        if ((int)strlen(sp) == n && memcmp(sp, id, (size_t)n) == 0)
            return KEYWORDS[i].kind;
    }
    return TK_Ident;
}
/* peek answers 0 at end-of-input — and on an embedded NUL, which therefore
 * ends the scan exactly as in the host compiler. */
static int peek(void) { return pos >= srclen ? 0 : srcbuf[pos]; }
static int peek2(void) { return pos + 1 >= srclen ? 0 : srcbuf[pos + 1]; }
static int take(void) {
    int c = peek();
    if (c != 0) {
        pos++;
        if (c == '\n') { line++; col = 1; } else { col++; }
    }
    return c;
}
static int read_source(void) {
    srclen = 0;
    while (srclen < SRCMAX) {
        size_t n = fread(srcbuf + srclen, 1, (size_t)(SRCMAX - srclen), stdin);
        if (n == 0) return 0;
        srclen += (int)n;
    }
    if (fgetc(stdin) != EOF) die_np("source exceeds 1048576 bytes");
    return 0;
}
static int scan_one(void) {
    int l = line, c = col;
    int ch = peek();

    if (isalpha((unsigned char)ch) || ch == '_') {
        int start = pos;
        while (isalnum((unsigned char)peek()) || peek() == '_') take();
        int len = pos - start;
        return push(keyword_kind(srcbuf + start, len), start, len, l, c);
    }
    if (isdigit((unsigned char)ch)) {
        int start = pos;
        while (isdigit((unsigned char)peek())) take();
        if (pos - start == 1 && srcbuf[start] == '0'
            && (peek() == 'x' || peek() == 'X')) {
            take();
            if (!isxdigit((unsigned char)peek()))
                die_at("hexadecimal literal has no digits", l, c);
            while (isxdigit((unsigned char)peek())) take();
        }
        return push(TK_Number, start, pos - start, l, c);
    }
    if (ch == '"') {
        int vstart = spool;
        int closed = 0;
        take();
        while (peek() != 0) {
            int q = take();
            if (q == '"') { closed = 1; break; }
            if (q == '\n' || q == '\r')
                die_at("newline in string literal", l, c);
            if (q == '\\') {
                int e = take();
                if (e == 0) break;              /* \ at end-of-input: E5 */
                switch (e) {
                case 'n':  strpool[spool++] = '\n'; break;
                case 'r':  strpool[spool++] = '\r'; break;
                case 't':  strpool[spool++] = '\t'; break;
                case '0':  strpool[spool++] = '\0'; break;
                case '\\': strpool[spool++] = '\\'; break;
                case '"':  strpool[spool++] = '"';  break;
                default:
                    /* the position after the escape byte, which take() has
                     * already consumed (spec §6.4) */
                    die_at("unsupported string escape", line, col);
                }
            } else {
                strpool[spool++] = (unsigned char)q;
            }
        }
        if (!closed) die_at("unterminated string literal", l, c);
        return push(TK_String, vstart, spool - vstart, l, c);
    }
    if (ch > 127) die_e6(l, c);

    {
        int start = pos;
        take();
        switch (ch) {
        case '(': return push(TK_LParen, start, pos - start, l, c);
        case ')': return push(TK_RParen, start, pos - start, l, c);
        case '{': return push(TK_LBrace, start, pos - start, l, c);
        case '}': return push(TK_RBrace, start, pos - start, l, c);
        case ':': return push(TK_Colon, start, pos - start, l, c);
        case ';': return push(TK_Semi, start, pos - start, l, c);
        case ',': return push(TK_Comma, start, pos - start, l, c);
        case '[': return push(TK_LBracket, start, pos - start, l, c);
        case ']': return push(TK_RBracket, start, pos - start, l, c);
        case '@': return push(TK_At, start, pos - start, l, c);
        case '~': return push(TK_Tilde, start, pos - start, l, c);
        case '?': return push(TK_Question, start, pos - start, l, c);
        case '.': return push(TK_Dot, start, pos - start, l, c);
        case '=':
            if (peek() == '=') { take(); return push(TK_EqEq, start, pos - start, l, c); }
            return push(TK_Eq, start, pos - start, l, c);
        case '!':
            if (peek() == '=') { take(); return push(TK_Ne, start, pos - start, l, c); }
            return push(TK_Not, start, pos - start, l, c);
        case '+':
            if (peek() == '+') { take(); return push(TK_PlusPlus, start, pos - start, l, c); }
            if (peek() == '=') { take(); return push(TK_PlusEq, start, pos - start, l, c); }
            return push(TK_Plus, start, pos - start, l, c);
        case '-':
            if (peek() == '>') { take(); return push(TK_Arrow, start, pos - start, l, c); }
            if (peek() == '-') { take(); return push(TK_MinusMinus, start, pos - start, l, c); }
            if (peek() == '=') { take(); return push(TK_MinusEq, start, pos - start, l, c); }
            return push(TK_Minus, start, pos - start, l, c);
        case '*':
            if (peek() == '=') { take(); return push(TK_StarEq, start, pos - start, l, c); }
            return push(TK_Star, start, pos - start, l, c);
        case '/':
            if (peek() == '=') { take(); return push(TK_SlashEq, start, pos - start, l, c); }
            return push(TK_Slash, start, pos - start, l, c);
        case '%':
            if (peek() == '=') { take(); return push(TK_PercentEq, start, pos - start, l, c); }
            return push(TK_Percent, start, pos - start, l, c);
        case '^':
            if (peek() == '=') { take(); return push(TK_XorEq, start, pos - start, l, c); }
            return push(TK_BitXor, start, pos - start, l, c);
        case '&':
            if (peek() == '&') { take(); return push(TK_And, start, pos - start, l, c); }
            if (peek() == '=') { take(); return push(TK_AndEq, start, pos - start, l, c); }
            return push(TK_Amp, start, pos - start, l, c);
        case '|':
            if (peek() == '|') { take(); return push(TK_Or, start, pos - start, l, c); }
            if (peek() == '=') { take(); return push(TK_OrEq, start, pos - start, l, c); }
            return push(TK_BitOr, start, pos - start, l, c);
        case '<':
            if (peek() == '=') { take(); return push(TK_Le, start, pos - start, l, c); }
            if (peek() == '<') {
                take();
                if (peek() == '=') { take(); return push(TK_ShlEq, start, pos - start, l, c); }
                return push(TK_Shl, start, pos - start, l, c);
            }
            return push(TK_Lt, start, pos - start, l, c);
        case '>':
            if (peek() == '=') { take(); return push(TK_Ge, start, pos - start, l, c); }
            if (peek() == '>') {
                take();
                if (peek() == '=') { take(); return push(TK_ShrEq, start, pos - start, l, c); }
                return push(TK_Shr, start, pos - start, l, c);
            }
            return push(TK_Gt, start, pos - start, l, c);
        default:
            die_at("unexpected character", l, c);
        }
    }
    return 0;
}
static int lex(void) {
    for (;;) {
        for (;;) {
            while (isspace((unsigned char)peek())) take();
            if (peek() == '/' && peek2() == '/') {
                while (peek() != 0 && peek() != '\n') take();
                continue;
            }
            if (peek() == '/' && peek2() == '*') {
                int bl = line, bc = col;        /* the open position, for E1 */
                take();
                take();
                int closed = 0;
                while (peek() != 0) {
                    if (peek() == '*' && peek2() == '/') {
                        take();
                        take();
                        closed = 1;
                        break;
                    }
                    take();
                }
                if (!closed) die_at("unterminated block comment", bl, bc);
                continue;
            }
            break;
        }
        if (peek() == 0) {
            eline = line;
            ecol = col;
            return 0;
        }
        scan_one();
    }
}

/* --------------------------------------------------------- numbers (§6.2) */
/* Byte-wise "is the digit text at s greater than this literal?", for
 * equal-length texts only — which for digits is numeric order. */
static int gt_lit(const unsigned char *s, const char *lit) {
    for (int i = 0; lit[i]; i++) {
        if (s[i] > (unsigned char)lit[i]) return 1;
        if (s[i] < (unsigned char)lit[i]) return 0;
    }
    return 0;
}
static void convert_num(int t) {
    const unsigned char *s = srcbuf + toks[t].start;
    int n = toks[t].len;
    int base = 10, i = 0;
    if (n > 1 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) {
        base = 16;
        i = 2;
    }
    /* leading zeros go, but one digit stays: an all-zero text is the value 0 */
    while (i < n - 1 && s[i] == '0') i++;
    int dcount = n - i;
    numflag = 0;
    /* too large for u64: more than 20 decimal digits, more than 16 hex ones,
     * or a 20-digit decimal past 18446744073709551615. A 16-digit hex text is
     * always inside u64 — its digits never exceed 'f' byte-wise — so the
     * comparison it would need is vacuous and is not written. */
    if (base == 10) {
        if (dcount > 20) numflag = 1;
        else if (dcount == 20 && gt_lit(s + i, "18446744073709551615")) numflag = 1;
    } else {
        if (dcount > 16) numflag = 1;
    }
    if (numflag != 0) {
        /* both readings are unreachable past a too-large flag (the literal
         * takes P52, the array length P53); leave them defined anyway */
        numval = 0;
        numcnt = MAXDIM + 1;
        return;
    }
    /* the spec's own accumulator and strtoull, on the same digit run: libc
     * witnesses the subset's guard-for-guard equivalent (§6.2 step 4), and
     * the too-large checks above are what keep strtoull from ever seeing a
     * text it would saturate on. */
    char buf[24];
    memcpy(buf, s + i, (size_t)dcount);
    buf[dcount] = '\0';
    unsigned long long v = strtoull(buf, NULL, base);
    if (v > (unsigned long long)INT64_MAX) {
        numval = INT64_MAX;            /* saturated, and flagged */
        numflag = 2;
    } else {
        numval = (int64_t)v;
    }
    numcnt = v > (unsigned long long)MAXDIM ? MAXDIM + 1 : (int)v;
}

/* ----------------------------------------------------- expressions (§6-§7) */
static int expr(void);

/* The boundary checks of the work stack's have-value state (§7.2), which run
 * after every value completes. A recursive descent's most recently completed
 * value is what unary() returns — with any prefix already applied, which is
 * the order the stack's prefix reducer guarantees too — so this runs there,
 * once per value, at the product level that consumes unary. */
static void postfix_check(int v) {
    int k = cur();
    if (k == TK_LParen) {
        if (nodes[v].kind == E_Call || nodes[v].kind == E_Index)
            die_at("cannot call the result of this expression: assign it to "
                   "a fn(...) variable or a fn(...) field first",
                   tok_line(p), tok_col(p));
    } else if (k == TK_LBracket) {
        if (nodes[v].kind == E_Index)
            die_at("multi-dimensional indexing is not in the bootstrap subset",
                   tok_line(p), tok_col(p));
        die_at("cannot index this expression", tok_line(p), tok_col(p));
    } else if (k == TK_Dot) {
        die_at("'.' field access is not in the bootstrap subset",
               tok_line(p), tok_col(p));
    } else if (k == TK_Question) {
        die_at("the '?:' operator is not in the bootstrap subset",
               tok_line(p), tok_col(p));
    }
}

/* A binary node inherits its left operand's token (§8), as the stack's
 * reduce_one does. */
static int mkbin(int kind, int a, int b) {
    int z = newnode(kind, nodes[a].tok);
    append(z, a);
    append(z, b);
    return z;
}

static int primary(void) {
    int k = cur();
    if (k == TK_Ident || k == TK_Main) {
        int nt = p;
        if (ahead() == TK_LParen) {
            adv();                       /* the name */
            adv();                       /* the '(' */
            int c = newnode(E_Call, nt);
            if (exdepth >= NESTMAX) die_c1();
            exdepth++;
            if (cur() != TK_RParen) {
                for (;;) {
                    int a = expr();
                    append(c, a);
                    if (cur() == TK_Comma) { adv(); continue; }
                    break;
                }
            }
            if (cur() != TK_RParen)
                die_at("expected ')' after function arguments",
                       tok_line(p), tok_col(p));
            adv();
            exdepth--;
            /* the count is read off the chain, as the stack reads it at the
             * marker close (§7.3) */
            int cnt = 0;
            for (int ch = nodes[c].first; ch >= 0; ch = nodes[ch].next) cnt++;
            if (cnt > MAXARGS)
                die_at("function calls support at most 32 arguments",
                       tok_line(nt), tok_col(nt));
            return c;
        }
        if (ahead() == TK_LBracket) {
            adv();                       /* the name */
            adv();                       /* the '[' */
            if (exdepth >= NESTMAX) die_c1();
            exdepth++;
            int e = expr();
            if (cur() != TK_RBracket)
                die_at("expected ']' after array index",
                       tok_line(p), tok_col(p));
            adv();
            exdepth--;
            int z = newnode(E_Index, nt);
            append(z, e);
            return z;
        }
        adv();
        return newnode(E_Var, nt);
    }
    if (k == TK_Number) {
        int nt = p;
        adv();
        convert_num(nt);
        if (numflag == 1) die_at("integer literal is too large",
                                 tok_line(nt), tok_col(nt));
        if (numflag == 2) die_at("integer literal exceeds i64 range",
                                 tok_line(nt), tok_col(nt));
        return newnode(E_Num, nt);
    }
    if (k == TK_String) {
        int nt = p;
        adv();
        return newnode(E_String, nt);
    }
    if (k == TK_LParen) {
        adv();
        if (exdepth >= NESTMAX) die_c1();
        exdepth++;
        int e = expr();
        if (cur() != TK_RParen)
            die_at("expected ')' ", tok_line(p), tok_col(p));
        adv();
        exdepth--;
        /* the host's (expr) returns the inner expression unchanged, so a
         * group adds no node (§7.3) */
        return e;
    }
    die_at("expected expression", tok_line(p), tok_col(p));
    return 0;                            /* unreachable */
}

static int unary(void) {
    int k = cur();
    if (k == TK_Minus || k == TK_Not) {
        adv();
        if (exdepth >= NESTMAX) die_c1();
        exdepth++;
        int a = unary();
        exdepth--;
        int z = newnode(k == TK_Minus ? E_Neg : E_Not, nodes[a].tok);
        append(z, a);
        return z;
    }
    if (k == TK_Tilde)
        die_at("'~' is not in the bootstrap subset", tok_line(p), tok_col(p));
    if (k == TK_Star)
        die_at("'*' dereference is not in the bootstrap subset",
               tok_line(p), tok_col(p));
    if (k == TK_Amp)
        die_at("'&' address-of is not in the bootstrap subset",
               tok_line(p), tok_col(p));
    if (k == TK_At)
        die_at("@embed is not in the bootstrap subset",
               tok_line(p), tok_col(p));
    if (k == TK_True || k == TK_False)
        die_at("true/false are not in the bootstrap subset",
               tok_line(p), tok_col(p));
    if (k == TK_Ident && (name_is("sizeof") || name_is("len")))
        die_at("sizeof/len are not in the bootstrap subset",
               tok_line(p), tok_col(p));
    if (k == TK_Bool)
        die_at("type bool is not in the bootstrap subset",
               tok_line(p), tok_col(p));
    if (k == TK_U16)
        die_at("type u16 is not in the bootstrap subset",
               tok_line(p), tok_col(p));
    if (k == TK_U32)
        die_at("type u32 is not in the bootstrap subset",
               tok_line(p), tok_col(p));
    return primary();
}

/* unary, then the have-value checks: the one place a value completes in this
 * shape. */
static int operand(void) {
    int v = unary();
    postfix_check(v);
    return v;
}

static int product(void) {
    int l = operand();
    for (;;) {
        int k = cur();
        if (k != TK_Star && k != TK_Slash && k != TK_Percent) break;
        adv();
        int r = operand();
        l = mkbin(k == TK_Star ? E_Mul : k == TK_Slash ? E_Div : E_Mod, l, r);
    }
    return l;
}
static int sum(void) {
    int l = product();
    for (;;) {
        int k = cur();
        if (k != TK_Plus && k != TK_Minus) break;
        adv();
        int r = product();
        l = mkbin(k == TK_Plus ? E_Add : E_Sub, l, r);
    }
    return l;
}
static int shift_(void) {
    int l = sum();
    for (;;) {
        int k = cur();
        if (k != TK_Shl && k != TK_Shr) break;
        adv();
        int r = product();
        l = mkbin(k == TK_Shl ? E_Shl : E_Shr, l, r);
    }
    return l;
}
static int relational(void) {
    int l = shift_();
    int k = cur();
    if (k == TK_Lt || k == TK_Le || k == TK_Gt || k == TK_Ge) {
        adv();
        int r = shift_();
        l = mkbin(k == TK_Lt ? E_Lt : k == TK_Le ? E_Le
                   : k == TK_Gt ? E_Gt : E_Ge, l, r);
        /* one per level, not chained: the second operator is P54 at itself */
        k = cur();
        if (k == TK_Lt || k == TK_Le || k == TK_Gt || k == TK_Ge)
            die_at("chained comparisons are not supported",
                   tok_line(p), tok_col(p));
    }
    return l;
}
static int equality(void) {
    int l = relational();
    int k = cur();
    if (k == TK_EqEq || k == TK_Ne) {
        adv();
        int r = relational();
        l = mkbin(k == TK_EqEq ? E_Eq : E_Ne, l, r);
        k = cur();
        if (k == TK_EqEq || k == TK_Ne)
            die_at("chained comparisons are not supported",
                   tok_line(p), tok_col(p));
    }
    return l;
}
static int bitand_(void) {
    int l = equality();
    while (cur() == TK_Amp) {
        adv();
        int r = equality();
        l = mkbin(E_BitAnd, l, r);
    }
    return l;
}
static int bitxor_(void) {
    int l = bitand_();
    while (cur() == TK_BitXor) {
        adv();
        int r = bitand_();
        l = mkbin(E_BitXor, l, r);
    }
    return l;
}
static int bitor_(void) {
    int l = bitxor_();
    while (cur() == TK_BitOr) {
        adv();
        int r = bitxor_();
        l = mkbin(E_BitOr, l, r);
    }
    return l;
}
static int logicaland_(void) {
    int l = bitor_();
    while (cur() == TK_And) {
        adv();
        int r = bitor_();
        l = mkbin(E_And, l, r);
    }
    return l;
}
static int expr(void) {
    int l = logicaland_();
    while (cur() == TK_Or) {
        adv();
        int r = logicaland_();
        l = mkbin(E_Or, l, r);
    }
    return l;
}

/* -------------------------------------------------------------- types (§4.2) */
static int bad_type_spelling(int k) {
    if (k == TK_Bool)
        die_at("type bool is not in the bootstrap subset",
               tok_line(p), tok_col(p));
    if (k == TK_U16)
        die_at("type u16 is not in the bootstrap subset",
               tok_line(p), tok_col(p));
    if (k == TK_U32)
        die_at("type u32 is not in the bootstrap subset",
               tok_line(p), tok_col(p));
    if (k == TK_Fn)
        die_at("fn(...) types are not in the bootstrap subset",
               tok_line(p), tok_col(p));
    return 0;
}
static int ptr_type(void) {
    adv();                               /* the 'ptr' */
    if (cur() != TK_Lt) return TY_PTR;
    adv();                               /* the '<' */
    int k = cur();
    if (k == TK_I32 || k == TK_I64 || k == TK_U8) {
        adv();
        int ty = k == TK_I64 ? TY_PTR_I64 : k == TK_U8 ? TY_PTR_U8 : TY_PTR_I32;
        if (cur() != TK_Gt)
            die_at("expected '>' after the type in a ptr<...> type",
                   tok_line(p), tok_col(p));
        adv();
        return ty;
    }
    if (k == TK_Ptr)
        die_at("ptr<ptr<...>> is not in the bootstrap subset",
               tok_line(p), tok_col(p));
    bad_type_spelling(k);
    /* Anything else is the host's struct-name path, and the subset has no
     * structs: P58 when the token is not a name at all, P62 when the '>' is
     * missing after one, P59 once a name is there — the host's three steps in
     * the host's order, with its third step always failing. */
    if (k != TK_Ident)
        die_at("expected a struct name after 'ptr<'",
               tok_line(p), tok_col(p));
    int idt = p;
    adv();
    if (cur() != TK_Gt)
        die_at("expected '>' after the struct name in a ptr<...> type",
               tok_line(p), tok_col(p));
    adv();
    snprintf(msgbuf, sizeof msgbuf, "unknown struct type in ptr<%.*s>",
             toks[idt].len, srcbuf + toks[idt].start);
    die_at(msgbuf, tok_line(idt), tok_col(idt));
    return 0;                            /* unreachable */
}
static int parse_type(void) {
    int k = cur();
    if (k == TK_I32) { adv(); return TY_I32; }
    if (k == TK_I64) { adv(); return TY_I64; }
    if (k == TK_U8)  { adv(); return TY_U8; }
    if (k == TK_Ptr) return ptr_type();
    bad_type_spelling(k);
    die_at("expected i32, i64, u8, u16, u32, ptr, ptr<S>, bool, or a struct name",
           tok_line(p), tok_col(p));
    return 0;                            /* unreachable */
}

/* ------------------------------------------------------- declarations (§4) */
static void array_dim(int g) {
    adv();                               /* the '[' */
    if (cur() != TK_Number)
        die_at("expected array length", tok_line(p), tok_col(p));
    int nt = p;
    adv();
    convert_num(nt);
    if (numflag == 1)
        die_at("array length is too large", tok_line(nt), tok_col(nt));
    if (numcnt < 1 || numcnt > MAXDIM) {
        snprintf(msgbuf, sizeof msgbuf,
                 "array length must be between 1 and 1048576: %.*s",
                 toks[nodes[g].tok].len, srcbuf + toks[nodes[g].tok].start);
        die_at(msgbuf, tok_line(nt), tok_col(nt));
    }
    if (cur() != TK_RBracket)
        die_at("expected ']' after array length", tok_line(p), tok_col(p));
    adv();
    nodes[g].count = numcnt;
}

static int is_const(int h);
static int64_t fold(int h);

static int global_decl(int external) {
    if (cur() != TK_Ident)
        die_at("expected global variable name", tok_line(p), tok_col(p));
    int nt = p;
    adv();
    if (cur() != TK_Colon) die_at("expected ':'", tok_line(p), tok_col(p));
    adv();
    int ty = parse_type();
    int g = newnode(N_Global, nt);
    nodes[g].ty = ty;
    nodes[g].count = 1;
    int isarr = 0;
    if (cur() == TK_LBracket) {
        array_dim(g);
        isarr = 1;
    }
    if (cur() == TK_At)
        die_at("global alignment is not in the bootstrap subset",
               tok_line(p), tok_col(p));
    for (int i = 0; i < nglobs; i++) {
        if (name_eq(gltok[i], nt))
            die_name_np("duplicate global variable: ", nt);
    }
    gltok[nglobs++] = nt;
    if (external == 1) {
        if (cur() != TK_Semi)
            die_at("expected ';' after extern global declaration",
                   tok_line(p), tok_col(p));
        adv();
        return g;
    }
    if (cur() != TK_Eq)
        die_at("expected '=' in global variable declaration",
               tok_line(p), tok_col(p));
    adv();
    int init = expr();
    if (cur() != TK_Semi) die_at("expected ';'", tok_line(p), tok_col(p));
    adv();
    append(g, init);
    /* An array's initializer must be a constant (P27); a scalar's may be one
     * — folded and range-checked (P29) — or not, in which case the host keeps
     * it as a runtime initializer and so does this stage. */
    if (isarr == 0 && !is_const(init)) return g;
    if (isarr == 1 && !is_const(init))
        die_name_np("array initializer must be a constant expression: ", nt);
    int64_t v = fold(init);
    if (!(ty == TY_U8 ? (v >= 0 && v <= 255) : 1)) {
        snprintf(msgbuf, sizeof msgbuf, "%s does not fit in %s: %.*s (%lld)",
                 isarr ? "array initializer" : "global initializer",
                 ty == TY_I32 ? "i32" : ty == TY_I64 ? "i64"
                 : ty == TY_U8 ? "u8" : "ptr",
                 toks[nt].len, srcbuf + toks[nt].start, (long long)v);
        die_np(msgbuf);
    }
    return g;
}

/* Forward declarations: the grammar is mutually recursive (a declaration's
 * body is a block, a block is a statement list, a statement can declare). */
static int parse_block(void);
static int is_compound(int k);

static int function_decl(int external) {
    if (cur() != TK_Fn) die_at("expected fn", tok_line(p), tok_col(p));
    int ft = p;
    adv();
    int f = newnode(N_Function, ft);
    if (cur() != TK_Ident && cur() != TK_Main)
        die_at("expected function name", tok_line(p), tok_col(p));
    int nt = p;
    adv();
    if (cur() != TK_LParen)
        die_at("expected '(' after function name", tok_line(p), tok_col(p));
    adv();
    nparams = 0;
    if (cur() != TK_RParen) {
        for (;;) {
            if (cur() != TK_Ident)
                die_at("expected parameter name", tok_line(p), tok_col(p));
            int pt = p;
            adv();
            if (cur() != TK_Colon)
                die_at("expected ':' after parameter name",
                       tok_line(p), tok_col(p));
            adv();
            int pty = parse_type();
            if (cur() == TK_LBracket)
                die_at("array parameters are not in the bootstrap subset",
                       tok_line(p), tok_col(p));
            for (int i = 0; i < nparams; i++) {
                if (name_eq(ptok[i], pt)) {
                    snprintf(msgbuf, sizeof msgbuf,
                             "duplicate parameter name in function %.*s: %.*s",
                             toks[nt].len, srcbuf + toks[nt].start,
                             toks[pt].len, srcbuf + toks[pt].start);
                    die_np(msgbuf);
                }
            }
            int pn = newnode(N_Param, pt);
            nodes[pn].ty = pty;
            ptok[nparams++] = pt;
            append(f, pn);
            if (nparams > MAXPARAMS)
                die_name_np("functions support at most 32 parameters: ", nt);
            if (cur() == TK_Comma) { adv(); continue; }
            break;
        }
    }
    if (cur() != TK_RParen)
        die_at("expected ')' after parameters", tok_line(p), tok_col(p));
    adv();
    if (cur() != TK_Arrow) die_at("expected ->", tok_line(p), tok_col(p));
    adv();
    int rty = parse_type();
    if (cur() == TK_LBracket) {
        snprintf(msgbuf, sizeof msgbuf,
                 "a function cannot return an array: return ptr<%s>, or take "
                 "the array as a parameter and let the caller's storage be "
                 "written through",
                 rty == TY_I32 ? "i32" : rty == TY_I64 ? "i64"
                 : rty == TY_U8 ? "u8" : "ptr");
        die_at(msgbuf, tok_line(p), tok_col(p));
    }
    /* `main` is a keyword, so the name token's kind is the whole test. */
    if (toks[nt].kind == TK_Main && rty != TY_I32)
        die_np("main must return i32");
    nodes[f].ty = rty;
    if (external == 1) {
        if (cur() != TK_Semi)
            die_at("expected ';' after extern function declaration",
                   tok_line(p), tok_col(p));
        adv();
    } else {
        int b = parse_block();
        append(f, b);
        if (nodes[b].first < 0)
            die_name_np("function body cannot be empty: ", nt);
    }
    for (int i = 0; i < nfuncs; i++) {
        if (name_eq(fntok[i], nt))
            die_name_np("duplicate function declaration: ", nt);
    }
    fntok[nfuncs++] = nt;
    return f;
}

/* --------------------------------------------------------- statements (§5) */
static int statement(void);

static int parse_block(void) {
    if (cur() != TK_LBrace) die_at("expected '{'", tok_line(p), tok_col(p));
    if (sdepth >= BLOCKMAX) die_c2();
    int bt = p;
    adv();
    int b = newnode(N_Block, bt);
    sdepth++;
    while (cur() != TK_RBrace && cur() != TK_End) {
        int s = statement();
        append(b, s);
    }
    sdepth--;
    if (cur() != TK_RBrace) die_at("expected '}'", tok_line(p), tok_col(p));
    adv();
    return b;
}

/* An if statement, and the else-if chain: `else if` desugars to a nested If
 * in the else position — not a Block (§9) — and each link holds one C2 level
 * while it is open. */
static int if_stmt(void) {
    if (cur() != TK_LParen)
        die_at("expected '(' after if", tok_line(p), tok_col(p));
    adv();
    int cond = expr();
    if (cur() != TK_RParen)
        die_at("expected ')' after condition", tok_line(p), tok_col(p));
    adv();
    int s = newnode(S_If, nodes[cond].tok);
    append(s, cond);
    int tb = parse_block();
    append(s, tb);
    if (cur() == TK_Else) {
        adv();
        if (cur() == TK_If) {
            adv();
            if (sdepth >= BLOCKMAX) die_c2();
            sdepth++;
            int eb = if_stmt();
            sdepth--;
            append(s, eb);
        } else {
            int eb = parse_block();
            append(s, eb);
        }
    }
    return s;
}

static int let_stmt(void) {
    if (cur() != TK_Ident)
        die_at("expected variable name", tok_line(p), tok_col(p));
    int nt = p;
    adv();
    if (cur() != TK_Colon) die_at("expected ':'", tok_line(p), tok_col(p));
    adv();
    int ty = parse_type();
    if (cur() == TK_LBracket)
        die_at("local arrays are not in the bootstrap subset",
               tok_line(p), tok_col(p));
    if (cur() == TK_At) die_name_at("local alignment is not supported: ", nt);
    if (cur() != TK_Eq) die_at("expected '='", tok_line(p), tok_col(p));
    adv();
    int e = expr();
    int s = newnode(S_Let, nt);
    nodes[s].ty = ty;
    append(s, e);
    if (cur() != TK_Semi) die_at("expected ';'", tok_line(p), tok_col(p));
    adv();
    return s;
}

/* `a[i] = v`: one subscript — the subset has one dimension — then '='. A
 * compound token here is B10, and anything else is P37 at the name token. */
static int index_assign_stmt(void) {
    int nt = p;
    adv();
    if (cur() != TK_LBracket) die_at("expected '['", tok_line(p), tok_col(p));
    adv();
    int idx = expr();
    if (cur() != TK_RBracket)
        die_at("expected ']' after array index", tok_line(p), tok_col(p));
    adv();
    int inode = newnode(E_Index, nt);
    append(inode, idx);
    int s = newnode(S_IndexAssign, nt);
    append(s, inode);
    if (cur() != TK_Eq) {
        if (is_compound(cur()))
            die_at("compound assignment is not in the bootstrap subset",
                   tok_line(p), tok_col(p));
        /* the host's assignOp throws the bare sentence at the name token —
         * no name is interpolated (§11.1 P37) */
        die_at("expected '=' in array element assignment",
               tok_line(nt), tok_col(nt));
    }
    adv();
    int e = expr();
    append(s, e);
    if (cur() != TK_Semi) die_at("expected ';'", tok_line(p), tok_col(p));
    adv();
    return s;
}

/* `x = v`: the dispatch has already established that '=' is here — a
 * compound token took B10 instead — so P40 is the host's message for
 * anything else, at the name token. */
static int assign_stmt(void) {
    int nt = p;
    adv();
    /* as above: the host's sentence, no name (§11.1 P40) */
    if (cur() != TK_Eq)
        die_at("expected '=' after variable name", tok_line(nt), tok_col(nt));
    adv();
    int e = expr();
    int s = newnode(S_Assign, nt);
    append(s, e);
    if (cur() != TK_Semi) die_at("expected ';'", tok_line(p), tok_col(p));
    adv();
    return s;
}

/* `a[i].f` at the head of a statement: only the token after the matched
 * brackets tells it from `a[i] = v`, so the brackets are matched here (they
 * nest). Answers the '.' token's index, or 0 when the shape is not there. */
static int indexed_then_field(void) {
    if (cur() != TK_Ident || ahead() != TK_LBracket) return 0;
    int i = p + 1;
    int depth = 0;
    while (i < ntok) {
        int k = toks[i].kind;
        if (k == TK_LBracket) {
            depth++;
        } else if (k == TK_RBracket) {
            depth--;
            if (depth == 0) { i++; break; }
        }
        i++;
    }
    if (depth != 0) return 0;
    if (i < ntok && toks[i].kind == TK_Dot) return i;
    return 0;
}

static int is_compound(int k) {
    switch (k) {
    case TK_PlusEq: case TK_MinusEq: case TK_StarEq: case TK_SlashEq:
    case TK_PercentEq: case TK_ShlEq: case TK_ShrEq: case TK_AndEq:
    case TK_OrEq: case TK_XorEq:
        return 1;
    default:
        return 0;
    }
}

static int statement(void) {
    int k = cur();
    if (k == TK_Star)
        die_at("'*' dereference is not in the bootstrap subset",
               tok_line(p), tok_col(p));
    if (k == TK_Let) { adv(); return let_stmt(); }
    if (k == TK_Return) {
        adv();
        int e = expr();
        int s = newnode(S_Return, nodes[e].tok);
        append(s, e);
        if (cur() != TK_Semi) die_at("expected ';'", tok_line(p), tok_col(p));
        adv();
        return s;
    }
    if (k == TK_If) { adv(); return if_stmt(); }
    if (k == TK_PlusPlus || k == TK_MinusMinus)
        die_at("'++' and '--' are not in the bootstrap subset",
               tok_line(p), tok_col(p));
    if (k == TK_While) {
        adv();
        if (cur() != TK_LParen)
            die_at("expected '(' after while", tok_line(p), tok_col(p));
        adv();
        int e = expr();
        if (cur() != TK_RParen)
            die_at("expected ')' after condition", tok_line(p), tok_col(p));
        adv();
        int s = newnode(S_While, nodes[e].tok);
        append(s, e);
        int b = parse_block();
        append(s, b);
        return s;
    }
    if (k == TK_For)
        die_at("the 'for' statement is not in the bootstrap subset",
               tok_line(p), tok_col(p));
    if (k == TK_Break) {
        int bt = p;
        adv();
        int s = newnode(S_Break, bt);
        if (cur() != TK_Semi)
            die_at("expected ';' after break", tok_line(p), tok_col(p));
        adv();
        return s;
    }
    if (k == TK_Continue) {
        int ct = p;
        adv();
        int s = newnode(S_Continue, ct);
        if (cur() != TK_Semi)
            die_at("expected ';' after continue", tok_line(p), tok_col(p));
        adv();
        return s;
    }
    /* A discarded call: an identifier followed directly by '('. `main` is a
     * keyword, not an identifier, so `main();` falls through to P57 — the
     * host's isCallStatement reads the same way. */
    if (k == TK_Ident && ahead() == TK_LParen) {
        int lead = p;
        int e = expr();
        if (cur() != TK_Semi)
            die_at("expected ';' after call statement",
                   tok_line(p), tok_col(p));
        adv();
        int s = newnode(S_Expr, lead);
        append(s, e);
        return s;
    }
    if (k == TK_Ident) {
        int dot = indexed_then_field();
        if (dot != 0)
            die_at("'.' field access is not in the bootstrap subset",
                   tok_line(dot), tok_col(dot));
        if (ahead() == TK_Dot)
            die_at("'.' field access is not in the bootstrap subset",
                   tok_line(p + 1), tok_col(p + 1));
        if (ahead() == TK_LBracket) return index_assign_stmt();
        if (ahead() == TK_PlusPlus || ahead() == TK_MinusMinus)
            die_at("'++' and '--' are not in the bootstrap subset",
                   tok_line(p + 1), tok_col(p + 1));
        if (ahead() == TK_Eq) return assign_stmt();
        if (is_compound(ahead()))
            die_at("compound assignment is not in the bootstrap subset",
                   tok_line(p + 1), tok_col(p + 1));
    }
    die_at("expected let, assignment, return, if, while, for, break, or continue",
           tok_line(p), tok_col(p));
    return 0;                            /* unreachable */
}

/* ----------------------------------------------------------- program (§4.1) */
static int parse_program(void) {
    int prog = newnode(N_Program, ntok == 0 ? -1 : 0);
    while (cur() != TK_End) {
        int k = cur();
        if (k == TK_Include)
            die_at("include is not in the bootstrap subset",
                   tok_line(p), tok_col(p));
        if (k == TK_Struct)
            die_at("struct declarations are not in the bootstrap subset",
                   tok_line(p), tok_col(p));
        if (k == TK_Let) {
            adv();
            int g = global_decl(0);
            append(prog, g);
            continue;
        }
        if (k == TK_Extern && ahead() == TK_Let) {
            adv();
            adv();
            int g = global_decl(1);
            append(prog, g);
            continue;
        }
        int external = 0;
        if (k == TK_Extern) { external = 1; adv(); }
        int f = function_decl(external);
        append(prog, f);
    }
    /* the host's closing pass over the two name tables (P18) */
    for (int gi = 0; gi < nglobs; gi++) {
        for (int fi = 0; fi < nfuncs; fi++) {
            if (name_eq(gltok[gi], fntok[fi]))
                die_name_np("global variable conflicts with function: ",
                            gltok[gi]);
        }
    }
    return prog;
}

/* ------------------------------------------------ constant folding (§6.2's kin) */
/* The host's isConstExpr and foldConst. The kinds the folder accepts: Num,
 * Neg and the ten arithmetic and bitwise binaries. The comparisons and the
 * logical operators are deliberately absent — `let g: i32 = 1 < 2;` is a
 * runtime initializer in the host, not a folded constant, and the array
 * path's P27 turns on that distinction. */
static int is_fold_binary(int k) {
    switch (k) {
    case E_Add: case E_Sub: case E_Mul: case E_Div: case E_Mod:
    case E_Shl: case E_Shr: case E_BitAnd: case E_BitOr: case E_BitXor:
        return 1;
    default:
        return 0;
    }
}
static int is_const(int h) {
    int k = nodes[h].kind;
    if (k == E_Num) return 1;
    if (k == E_Neg) return is_const(nodes[h].first);
    if (is_fold_binary(k))
        return is_const(nodes[h].first)
            && is_const(nodes[nodes[h].first].next);
    return 0;
}
static int64_t fold_bin(int k, int64_t a, int64_t b, int n) {
    switch (k) {
    case E_Add: return a + b;
    case E_Sub: return a - b;
    case E_Mul: return a * b;
    case E_Div:
        if (b == 0)
            die_at("division by zero in global variable initializer",
                   tok_line(nodes[n].tok), tok_col(nodes[n].tok));
        if (a == INT64_MIN && b == -1) return INT64_MIN;   /* SDIV wraps */
        return a / b;
    case E_Mod:
        if (b == 0)
            die_at("division by zero in global variable initializer",
                   tok_line(nodes[n].tok), tok_col(nodes[n].tok));
        if (a == INT64_MIN && b == -1) return 0;           /* MSUB wraps */
        return a % b;
    case E_Shl:
    case E_Shr:
        if (b < 0 || b > 63) {
            snprintf(msgbuf, sizeof msgbuf,
                     "shift count %lld is out of range (0..63) in global "
                     "variable initializer", (long long)b);
            die_at(msgbuf, tok_line(nodes[n].tok), tok_col(nodes[n].tok));
        }
        if (k == E_Shr) return a >> b;                     /* ASR */
        /* A left shift is refused when its result leaves i64. At a count of
         * 63 the host's C++ multiply accepts exactly a in {0, 1} — 0, and
         * INT64_MIN — and the wrap-and-shift-back test below would refuse
         * the 1, so that pair is spelled out (§12.8). */
        if (b == 63) {
            if (a == 0) return 0;
            if (a == 1) return INT64_MIN;
            die_at("left shift overflows i64 in global variable initializer",
                   tok_line(nodes[n].tok), tok_col(nodes[n].tok));
        }
        {
            int64_t r = (int64_t)((uint64_t)a << b);
            if ((r >> b) != a)
                die_at("left shift overflows i64 in global variable initializer",
                       tok_line(nodes[n].tok), tok_col(nodes[n].tok));
            return r;
        }
    case E_BitAnd: return a & b;
    case E_BitOr:  return a | b;
    case E_BitXor: return a ^ b;
    default:       return 0;           /* unreachable: is_const went first */
    }
}
static int64_t fold(int h) {
    int k = nodes[h].kind;
    if (k == E_Num) {
        /* the value was validated where the node was built (§7.1), so this
         * conversion cannot fail and the flag is provably clear */
        convert_num(nodes[h].tok);
        return numval;
    }
    if (k == E_Neg) return -fold(nodes[h].first);
    return fold_bin(k, fold(nodes[h].first),
                    fold(nodes[nodes[h].first].next), h);
}

/* ------------------------------------------------------------ type names */
/* ty_name mirrors parser_names.h's TY_NAMES; the codegen twin's diagnostics
 * (bputtybase) print through it. The old AST dump (kind_name / put_name /
 * put_escaped) is gone — the twin now emits an ELF, not a node dump. */
static const char *ty_name(int t) { return TY_NAMES[t - 1]; }
/* Whether a Function node is external — read off the child shape rather than
 * a flag of its own: a defined function always has its body Block (an empty
 * body is P16, and the node exists either way), an external one has its
 * parameters and nothing more. The same reading tells an external global
 * (no initializer child) from a defined one. */
static int fn_extern(int h) {
    for (int c = nodes[h].first; c >= 0; c = nodes[c].next)
        if (nodes[c].kind == N_Block) return 0;
    return 1;
}
/* ============================================================ SEMANTIC PASS
 * The bootstrap's type-check pass (SEMANTIC-SPEC §13-§16), mirrored so the twin
 * is a faithful oracle for the same sources: on success it leaves the AST
 * untouched (the dump below is therefore byte-identical to the no-sema parse),
 * and on a type error it emits the same S-code diagnostic the bootstrap does.
 * The same contract as M3c: a pure validation gate, never a rewriter.
 */
static int ety[NODEMAX];   /* per-node result type tag (-2 == bool-valued) */
static int earr[NODEMAX];  /* per-node "is a whole array value" (always 0 here) */

/* Forward declarations (C11: no implicit declarations across the mutually
 * recursive sema walk). */
static int tc_combine(int n);
static int sema_block(int b);

/* --- type helpers (§2.4) --- */
static int is_int_tag(int t)  { return (t == TY_I32 || t == TY_I64 || t == TY_U8); }
static int is_ptr_tag(int t) {
    return (t == TY_PTR || t == TY_PTR_U8 || t == TY_PTR_I32 || t == TY_PTR_I64);
}
static int ptr_to(int elem) {
    if (elem == TY_I32) return TY_PTR_I32;
    if (elem == TY_I64) return TY_PTR_I64;
    if (elem == TY_U8)  return TY_PTR_U8;
    return TY_PTR;
}
/* The element type of a pointer tag — what `p[i]` loads (host typeOf): ptr<i32>
 * -> i32, ptr<i64> -> i64, ptr<u8> -> u8, bare ptr (no element) -> i32. */
static int ptr_elem(int t) {
    if (t == TY_PTR_I32) return TY_I32;
    if (t == TY_PTR_I64) return TY_I64;
    if (t == TY_PTR_U8)  return TY_U8;
    return TY_I32;
}
static const char *ty_str(int t) {
    switch (t) {
    case TY_I32: return "i32";
    case TY_I64: return "i64";
    case TY_U8:  return "u8";
    case TY_PTR: return "ptr";
    case TY_PTR_U8: return "ptr<u8>";
    case TY_PTR_I32: return "ptr<i32>";
    case TY_PTR_I64: return "ptr<i64>";
    default: return "ptr";
    }
}
/* The "got" side: a bool-valued expr (-2) spells as i32 in a message. */
static const char *ty_str_got(int t, int a) {
    (void)a;
    if (t == -2) return "i32";
    return ty_str(t);
}
/* S10 arg assignability — mirrors the host's tyAssignable over the 5-type
 * subset. Integers: exact match, widen (narrow -> wide, or to i64), or a
 * constant that fits the narrow slot; a non-constant narrowing is rejected.
 * Pointers: any ptr is mutually compatible with any other ptr; a ptr slot
 * accepts only the null constant (0) from an integer. */
static int ty_assignable(int to_tag, int to_arr, int from_tag, int from_arr,
                         int is_const, int64_t cval) {
    if (to_arr != from_arr) return 0;
    if (is_ptr_tag(to_tag) && is_ptr_tag(from_tag)) return 1;
    if (is_ptr_tag(to_tag)) {
        if (is_const && cval == 0) return 1;
        return 0;
    }
    if (is_ptr_tag(from_tag)) return 0;
    if (to_tag == from_tag) return 1;
    if (to_tag == TY_I64) return 1;
    if (is_const) {
        if (to_tag == TY_U8) return (cval >= 0 && cval <= 255);
        return 1;
    }
    int wt = (to_tag == TY_I64) ? 8 : (to_tag == TY_U8) ? 1 : 4;
    int wf = (from_tag == TY_I64) ? 8 : (from_tag == TY_U8) ? 1 : 4;
    return (wt >= wf);
}
/* A constant integer's value, for the narrow-slot fit test above. */
static int64_t rc_val;
static int expr_const_int(int h) {
    if (nodes[h].kind == E_Num) {
        convert_num(nodes[h].tok);
        rc_val = numval;
        return 1;
    }
    return 0;
}
/* S11's own rule — the host's local-let/assign checks are *category* checks,
 * not tyAssignable's: an integer slot takes any integer value (i64 -> i32
 * narrowing is fine), a ptr slot takes a pointer or the null constant, and a
 * bool-valued expression is rejected into an integer slot. */
static int assign_ok(int to_tag, int from_tag, int from_arr, int e) {
    if (from_arr != 0) return 0;
    if (is_ptr_tag(to_tag)) {
        if (is_ptr_tag(from_tag)) return 1;
        if (expr_const_int(e) && rc_val == 0) return 1;
        return 0;
    }
    if (is_ptr_tag(from_tag)) return 0;
    if (from_tag == -2) return 0;
    return 1;
}
/* A condition is accepted iff it is integer-valued or bool-valued. */
static int cond_ok(int c) {
    int t = ety[c];
    if (t == -2) return 1;
    if (earr[c] == 1) return 0;
    if (is_int_tag(t)) return 1;
    return 0;
}

/* --- the cross-function symbol table (functions + globals + externs) --- */
#define SYMMAX 4096
static int st_kind[SYMMAX];   /* 0=fn, 1=extern_fn, 2=global, 3=extern_global */
static int st_name[SYMMAX];   /* name token index */
static int st_tag[SYMMAX];
static int st_cnt[SYMMAX];    /* array element count (globals) */
static int st_node[SYMMAX];   /* the Function/Global AST node */
static int nsym;

static int rs_tag, rs_cnt, rs_kind;   /* find_var result scratch */

/* --- the scoped local/param table (per function) --- */
#define LOCALMAX 600
static int lc_name[LOCALMAX];
static int lc_kind[LOCALMAX];   /* 0 = param, 1 = local */
static int lc_tag[LOCALMAX];
static int lc_cnt[LOCALMAX];
static int nlocs;
static int sc_start[128];
static int sc_depth;

static void add_local(int t, int kind, int tag, int cnt) {
    if (nlocs >= LOCALMAX)
        die_np("too many local declarations (limit 600, including parameters)");
    lc_name[nlocs] = t; lc_kind[nlocs] = kind;
    lc_tag[nlocs]  = tag; lc_cnt[nlocs]  = cnt;
    nlocs++;
}
static void push_scope(void) { sc_start[sc_depth] = nlocs; sc_depth++; }
static void pop_scope(void)  { sc_depth--; nlocs = sc_start[sc_depth]; }

static void build_symtab(int prog) {
    nsym = 0;
    for (int c = nodes[prog].first; c >= 0; c = nodes[c].next) {
        int k = nodes[c].kind;
        if (k == N_Function) {
            if (nsym >= SYMMAX) die_np("too many symbols");
            st_kind[nsym] = fn_extern(c) ? 1 : 0;
            /* A Function node's tok is the `fn` keyword; the name is the next
             * token (the dump renders it with put_name(tok + 1)). A Global
             * node's tok is the name directly. */
            st_name[nsym] = (nodes[c].kind == N_Function)
                          ? nodes[c].tok + 1 : nodes[c].tok;
            st_tag[nsym]  = nodes[c].ty;
            st_cnt[nsym]  = 1;
            st_node[nsym] = c;
            nsym++;
        } else if (k == N_Global) {
            if (nsym >= SYMMAX) die_np("too many symbols");
            int ext = (nodes[c].first < 0) ? 1 : 0;
            st_kind[nsym] = ext ? 3 : 2;
            st_name[nsym] = nodes[c].tok;
            st_tag[nsym]  = nodes[c].ty;
            st_cnt[nsym]  = nodes[c].count;
            st_node[nsym] = c;
            nsym++;
        }
    }
}

/* Resolve a variable name: the current scope chain, then the global table. */
static int sym_find_var(int t) {
    for (int d = sc_depth - 1; d >= 0; d--) {
        int lo = sc_start[d];
        int hi = (d + 1 < sc_depth) ? sc_start[d + 1] : nlocs;
        for (int i = lo; i < hi; i++) {
            if (name_eq(lc_name[i], t)) {
                rs_tag = lc_tag[i]; rs_cnt = lc_cnt[i]; rs_kind = lc_kind[i];
                return 1;
            }
        }
    }
    for (int s = 0; s < nsym; s++) {
        if (st_kind[s] == 2 || st_kind[s] == 3) {   /* global / extern global */
            if (name_eq(st_name[s], t)) {
                rs_tag = st_tag[s]; rs_cnt = st_cnt[s];
                rs_kind = (st_kind[s] == 3) ? 1 : 2;
                return 1;
            }
        }
    }
    return 0;
}

/* Resolve a call callee name: 1 = function (rs_fnsym set), 2 = a variable
 * (rs_* set, for S7/S8), 0 = neither (S6). */
static int rcall_intrinsic;
static int rcall_rtyp;
static int rs_fnsym;   /* symbol index into st_*, or -1 for an intrinsic */

static int tok_eq_tok(int t, const char *lit) {
    int start = toks[t].start, n = toks[t].len, i = 0;
    while (lit[i]) {
        if (i >= n) return 0;
        if ((unsigned char)lit[i] != srcbuf[start + i]) return 0;
        i++;
    }
    return i == n;
}
static int sym_find_call(int t) {
    rcall_intrinsic = 0;
    for (int s = 0; s < nsym; s++) {
        if (st_kind[s] == 0 || st_kind[s] == 1) {
            if (name_eq(st_name[s], t)) { rs_fnsym = s; return 1; }
        }
    }
    /* Host intrinsics (§3): declared nowhere in source, known to the compiler;
     * a real declared function above wins, else these are always callable.
     * load_u8/store_u8 return i32 (the byte is zero-extended).
     * The ids mirror bootstrap/aster.ast's IC_* block exactly. */
    if (tok_eq_tok(t, "load_ptr"))  { rcall_intrinsic = 1;  rcall_rtyp = TY_PTR;  rs_fnsym = -1; return 1; }
    if (tok_eq_tok(t, "mmap"))      { rcall_intrinsic = 2;  rcall_rtyp = TY_PTR;  rs_fnsym = -1; return 1; }
    if (tok_eq_tok(t, "brk"))       { rcall_intrinsic = 3;  rcall_rtyp = TY_PTR;  rs_fnsym = -1; return 1; }
    if (tok_eq_tok(t, "load_i64"))  { rcall_intrinsic = 4;  rcall_rtyp = TY_I64;  rs_fnsym = -1; return 1; }
    if (tok_eq_tok(t, "store_i64")) { rcall_intrinsic = 5;  rcall_rtyp = TY_I64;  rs_fnsym = -1; return 1; }
    if (tok_eq_tok(t, "load_u8"))   { rcall_intrinsic = 6;  rcall_rtyp = TY_I32;  rs_fnsym = -1; return 1; }
    if (tok_eq_tok(t, "store_u8"))  { rcall_intrinsic = 7;  rcall_rtyp = TY_I32;  rs_fnsym = -1; return 1; }
    if (tok_eq_tok(t, "load_u16"))  { rcall_intrinsic = 8;  rcall_rtyp = TY_I32;  rs_fnsym = -1; return 1; }
    if (tok_eq_tok(t, "store_u16")) { rcall_intrinsic = 9;  rcall_rtyp = TY_I32;  rs_fnsym = -1; return 1; }
    if (tok_eq_tok(t, "read"))      { rcall_intrinsic = 10; rcall_rtyp = TY_I32;  rs_fnsym = -1; return 1; }
    if (tok_eq_tok(t, "write"))     { rcall_intrinsic = 11; rcall_rtyp = TY_I32;  rs_fnsym = -1; return 1; }
    if (tok_eq_tok(t, "exit"))      { rcall_intrinsic = 12; rcall_rtyp = TY_I32;  rs_fnsym = -1; return 1; }
    if (tok_eq_tok(t, "openat"))    { rcall_intrinsic = 13; rcall_rtyp = TY_I32;  rs_fnsym = -1; return 1; }
    if (tok_eq_tok(t, "close"))     { rcall_intrinsic = 14; rcall_rtyp = TY_I32;  rs_fnsym = -1; return 1; }
    if (tok_eq_tok(t, "fstat"))     { rcall_intrinsic = 15; rcall_rtyp = TY_I32;  rs_fnsym = -1; return 1; }
    if (sym_find_var(t)) return 2;
    return 0;
}

/* A diagnostic with a name + numbers, then die_at (which adds the prefix and
 * the "at L:C" position). */
static void die_msg_at(int l, int c, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msgbuf, sizeof msgbuf, fmt, ap);
    va_end(ap);
    die_at(msgbuf, l, c);
}

/* Compute one expression's type (iterative post-order; a deep left chain would
 * blow a C stack, so this reuses the bootstrap's explicit work-stack shape).
 * Children's ety/earr are filled before the parent is combined; a type error
 * reports the matching S-diagnostic and returns 1. */
/* The work-stack can hold up to ~2*tree-depth entries on a fully left-deep
 * chain; the densest E9-legal source (65529 nodes) peaks near 65525, so the
 * logical cap mirrors the bootstrap's (65535) with a little headroom against an
 * out-of-bounds write on the overflow path. */
static int wstk[NODEMAX + 256];
static int wmark[NODEMAX + 256];
static int tc_expr(int h) {
    int sp = 0;
    wstk[sp] = h; wmark[sp] = 0; sp = 1;
    while (sp > 0) {
        sp--;
        int n = wstk[sp];
        int m = wmark[sp];
        if (m == 1) { if (tc_combine(n) != 0) return 1; continue; }
        if (sp > NODEMAX - 1) die_np("internal: tc stack overflow");
        wstk[sp] = n; wmark[sp] = 1; sp++;
        int kids[64];
        int nk = 0;
        for (int ch = nodes[n].first; ch >= 0; ch = nodes[ch].next) {
            if (nk < 64) kids[nk] = ch;
            nk++;
        }
        for (int i = nk - 1; i >= 0; i--) {
            wstk[sp] = kids[i]; wmark[sp] = 0; sp++;
        }
    }
    return 0;
}

/* Combine a node: derive its type from its children and enforce the operand
 * rules (§7). Returns 1 on the first type error. */
static int tc_combine(int n) {
    int k = nodes[n].kind;
    if (k == E_Num) {
        convert_num(nodes[n].tok);
        if (numval >= -2147483648LL && numval <= 2147483647LL) ety[n] = TY_I32;
        else ety[n] = TY_I64;
        earr[n] = 0;
        return 0;
    }
    if (k == E_String) { ety[n] = TY_PTR_U8; earr[n] = 0; return 0; }
    if (k == E_Var) {
        int t = nodes[n].tok;
        if (sym_find_var(t) == 0) die_name_at("unknown variable: ", t);
        if (rs_cnt > 1) { ety[n] = ptr_to(rs_tag); earr[n] = 0; return 0; }
        ety[n] = rs_tag; earr[n] = 0; return 0;
    }
    if (k == E_Call) {
        int callee = nodes[n].tok;
        int r = sym_find_call(callee);
        if (r == 0) die_name_at("call to undeclared function: ", callee);
        if (r == 2) {
            if (rs_cnt > 1)
                die_msg_at(tok_line(callee), tok_col(callee),
                           "cannot call through '%.*s': it is an array",
                           toks[callee].len, srcbuf + toks[callee].start);
            snprintf(msgbuf, sizeof msgbuf,
                     "cannot call through '%.*s': expected a function pointer "
                     "(ptr), got %s",
                     toks[callee].len, srcbuf + toks[callee].start,
                     is_ptr_tag(rs_tag) ? "ptr" : ty_str(rs_tag));
            die_at(msgbuf, tok_line(callee), tok_col(callee));
        }
        if (rs_fnsym == -1) { ety[n] = rcall_rtyp; earr[n] = 0; return 0; }
        int fnode = st_node[rs_fnsym];
        int argc = 0;
        for (int a = nodes[n].first; a >= 0; a = nodes[a].next) argc++;
        int nparams = 0;
        for (int p = nodes[fnode].first; p >= 0; p = nodes[p].next)
            if (nodes[p].kind == N_Param) nparams++;
        if (argc != nparams)
            die_msg_at(tok_line(callee), tok_col(callee),
                       "wrong argument count calling %.*s: expected %d, got %d",
                       toks[callee].len, srcbuf + toks[callee].start,
                       nparams, argc);
        int ai = 0;
        for (int arg = nodes[n].first; arg >= 0; arg = nodes[arg].next) {
            int pj = nodes[fnode].first, pi = 0;
            while (pj >= 0) {
                if (nodes[pj].kind == N_Param) { if (pi == ai) break; pi++; }
                pj = nodes[pj].next;
            }
            int ptag = nodes[pj].ty;
            int c0 = expr_const_int(arg);
            if (ty_assignable(ptag, 0, ety[arg], earr[arg], c0, rc_val) == 0) {
                snprintf(msgbuf, sizeof msgbuf,
                         "argument type mismatch calling %.*s at argument %d: "
                         "expected %s, got %s",
                         toks[callee].len, srcbuf + toks[callee].start, ai + 1,
                         ty_str(ptag), ty_str_got(ety[arg], earr[arg]));
                die_at(msgbuf, tok_line(callee), tok_col(callee));
            }
            ai++;
        }
        ety[n] = st_tag[rs_fnsym]; earr[n] = 0;
        return 0;
    }
    if (k == E_Index) {
        int base = nodes[n].tok;
        if (sym_find_var(base) == 0) die_name_at("unknown variable: ", base);
        if (rs_cnt > 1) { ety[n] = rs_tag; earr[n] = 0; return 0; }
        if (is_ptr_tag(rs_tag)) {
            int etag = ptr_elem(rs_tag);
            int idxexpr = nodes[n].first;   /* already type-checked */
            if (is_ptr_tag(ety[idxexpr]))
                die_at("pointer indexing is not supported yet",
                       tok_line(base), tok_col(base));
            ety[n] = etag; earr[n] = 0; return 0;
        }
        die_name_at("cannot index non-array variable: ", base);
    }
    if (k == E_Not) {
        int op = nodes[n].first;
        if (ety[op] != -2)
            die_at("'!' requires a bool operand",
                   tok_line(nodes[n].tok), tok_col(nodes[n].tok));
        ety[n] = -2; earr[n] = 0; return 0;
    }
    if (k == E_Neg) {
        int op = nodes[n].first;
        ety[n] = ety[op]; earr[n] = earr[op]; return 0;
    }
    /* binary: arithmetic / shift / comparison / logical / bitwise */
    int l = nodes[n].first;
    int r = nodes[l].next;
    int lt = ety[l], rt = ety[r];
    if (k == E_Eq || k == E_Ne || k == E_Lt || k == E_Le || k == E_Gt || k == E_Ge) {
        ety[n] = -2; earr[n] = 0; return 0;
    }
    if (k == E_And || k == E_Or) {
        ety[n] = -2; earr[n] = 0; return 0;
    }
    if (k == E_Shl || k == E_Shr) {
        ety[n] = lt; earr[n] = earr[l]; return 0;
    }
    /* Pointer arithmetic: ptr +/- integer keeps the pointer type. */
    if (k == E_Add || k == E_Sub) {
        if (is_ptr_tag(lt) && !is_ptr_tag(rt)) { ety[n] = lt; earr[n] = 0; return 0; }
        if (is_ptr_tag(rt) && !is_ptr_tag(lt)) { ety[n] = rt; earr[n] = 0; return 0; }
    }
    /* + - * / % & | ^ : the wider integer (i64 if either is i64, else i32;
     * u8 widens to i32). No pinned S-error fires for non-integer operands. */
    if (lt == TY_I64 || rt == TY_I64) ety[n] = TY_I64;
    else if (lt == TY_I32 && rt == TY_I32) ety[n] = TY_I32;
    else ety[n] = TY_I32;
    earr[n] = 0;
    return 0;
}

static int cur_ret_ty;
static int cur_fn_tok;

/* Type-check one statement; returns 1 on the first S-error. */
static int sema_stmt(int s) {
    int k = nodes[s].kind;
    if (k == S_Let) {
        int e = nodes[s].first;
        if (e >= 0) {
            if (tc_expr(e) != 0) return 1;
            if (assign_ok(nodes[s].ty, ety[e], earr[e], e) == 0)
                die_name_at("type mismatch assigning variable: ", nodes[s].tok);
        }
        add_local(nodes[s].tok, 1, nodes[s].ty, 1);
        return 0;
    }
    if (k == S_Assign) {
        int t = nodes[s].tok;
        if (sym_find_var(t) == 0) die_name_at("unknown variable: ", t);
        if (rs_cnt > 1) die_name_at("cannot assign to an array as a whole: ", t);
        int vtag = rs_tag;            /* copy out before tc_expr overwrites rs_* */
        int e = nodes[s].first;
        if (tc_expr(e) != 0) return 1;
        if (assign_ok(vtag, ety[e], earr[e], e) == 0)
            die_name_at("type mismatch assigning variable: ", t);
        return 0;
    }
    if (k == S_IndexAssign) {
        int idxnode = nodes[s].first;
        int rhs = nodes[idxnode].next;
        int arrname = nodes[idxnode].tok;
        if (sym_find_var(arrname) == 0) die_name_at("unknown variable: ", arrname);
        int vtag = 0;
        if (rs_cnt > 1) vtag = rs_tag;
        else if (is_ptr_tag(rs_tag)) vtag = ptr_elem(rs_tag);
        else die_name_at("cannot index non-array variable: ", arrname);
        int idxexpr = nodes[idxnode].first;
        if (tc_expr(idxexpr) != 0) return 1;
        if (is_ptr_tag(ety[idxexpr]))
            die_at("pointer indexing is not supported yet",
                   tok_line(nodes[idxnode].tok), tok_col(nodes[idxnode].tok));
        if (tc_expr(rhs) != 0) return 1;
        if (assign_ok(vtag, ety[rhs], earr[rhs], rhs) == 0)
            die_name_at("type mismatch assigning variable: ", arrname);
        return 0;
    }
    if (k == S_Return) {
        int e = nodes[s].first;
        if (tc_expr(e) != 0) return 1;
        int is_ret_ptr  = is_ptr_tag(cur_ret_ty);
        int is_expr_ptr = (earr[e] == 0 && is_ptr_tag(ety[e]));
        int is_expr_bool = (ety[e] == -2);
        if (is_expr_ptr != is_ret_ptr) {
            if (is_ret_ptr) {
                int c0 = expr_const_int(e);
                if (c0 == 1 && rc_val == 0) { /* null constant -> ok */ }
                else
                    die_msg_at(tok_line(nodes[s].tok), tok_col(nodes[s].tok),
                               "return type mismatch in function %.*s",
                               toks[cur_fn_tok].len, srcbuf + toks[cur_fn_tok].start);
            } else {
                die_msg_at(tok_line(nodes[s].tok), tok_col(nodes[s].tok),
                           "return type mismatch in function %.*s",
                           toks[cur_fn_tok].len, srcbuf + toks[cur_fn_tok].start);
            }
        }
        if (is_expr_bool) {
            die_msg_at(tok_line(nodes[s].tok), tok_col(nodes[s].tok),
                       "return type mismatch in function %.*s: expected i32, got bool",
                       toks[cur_fn_tok].len, srcbuf + toks[cur_fn_tok].start);
        }
        if (nodes[e].kind == E_Var) {
            if (sym_find_var(nodes[e].tok) == 1 && rs_kind == 0 && rs_cnt > 1)
                die_name_at("cannot return a local array (its frame storage "
                            "does not outlive the call): ", nodes[e].tok);
        }
        return 0;
    }
    if (k == S_If) {
        int cond = nodes[s].first;
        if (tc_expr(cond) != 0) return 1;
        if (cond_ok(cond) == 0)
            die_at("condition must be a comparison, a bool expression, or an integer",
                   tok_line(nodes[s].tok), tok_col(nodes[s].tok));
        int tb = nodes[cond].next;
        push_scope();
        if (sema_block(tb) != 0) return 1;
        pop_scope();
        int el = nodes[tb].next;
        if (el >= 0) {
            push_scope();
            if (nodes[el].kind == N_Block) { if (sema_block(el) != 0) return 1; }
            else { if (sema_stmt(el) != 0) return 1; }
            pop_scope();
        }
        return 0;
    }
    if (k == S_While) {
        int cond = nodes[s].first;
        if (tc_expr(cond) != 0) return 1;
        if (cond_ok(cond) == 0)
            die_at("condition must be a comparison, a bool expression, or an integer",
                   tok_line(nodes[s].tok), tok_col(nodes[s].tok));
        int b = nodes[cond].next;
        push_scope();
        if (sema_block(b) != 0) return 1;
        pop_scope();
        return 0;
    }
    if (k == S_Expr) {
        int e = nodes[s].first;
        if (tc_expr(e) != 0) return 1;
        return 0;
    }
    return 0;
}

static int sema_block(int b) {
    for (int s = nodes[b].first; s >= 0; s = nodes[s].next) {
        if (sema_stmt(s) != 0) return 1;
    }
    return 0;
}

static int sema_function(int f) {
    nlocs = 0;
    sc_depth = 0;
    sc_start[0] = 0;
    sc_depth = 1;
    cur_ret_ty = nodes[f].ty;
    cur_fn_tok = nodes[f].tok + 1;   /* the name token follows the `fn` keyword */
    for (int c = nodes[f].first; c >= 0; c = nodes[c].next)
        if (nodes[c].kind == N_Param)
            add_local(nodes[c].tok, 0, nodes[c].ty, 1);
    if (tok_eq_tok(cur_fn_tok, "main")) {
        int np = 0;
        for (int pc = nodes[f].first; pc >= 0; pc = nodes[pc].next)
            if (nodes[pc].kind == N_Param) np++;
        if (np > 0)
            die_at("main must not have parameters",
                   tok_line(cur_fn_tok), tok_col(cur_fn_tok));
    }
    int body = 0;
    for (int bc = nodes[f].first; bc >= 0; bc = nodes[bc].next)
        if (nodes[bc].kind == N_Block) { body = bc; break; }
    if (body >= 0) { if (sema_block(body) != 0) return 1; }
    sc_depth = 0;
    return 0;
}

/* Phase 2.5: build the cross-function symbol table, then check each function
 * body. Returns 1 on the first S-error. */
static int sema(int prog) {
    build_symtab(prog);
    for (int c = nodes[prog].first; c >= 0; c = nodes[c].next) {
        if (nodes[c].kind == N_Function) {
            if (sema_function(c) != 0) return 1;
        }
    }
    return 0;
}

/* ===== codegen back-end: independent C implementation of CODEGEN-SPEC.md =====
 * Ports the bootstrap's three-pass AArch64 code generator verbatim from the
 * frozen spec (§2-§10), operating on this twin's own AST (struct node, 0-based
 * indices) instead of the bootstrap's parallel i32 arrays. The AST shape is
 * the twin's; the bytes it emits must match the bootstrap word for word.
 *
 * Mapping bootstrap handles (n, where n = idx+1) -> twin nodes (idx):
 *   NK(n) nodes[n].kind   NF(n) nodes[n].first   NN(n) nodes[n].next
 *   NT(n) nodes[n].tok     NTY(n) nodes[n].ty     ETY(n) ety[n]  EAR(n) earr[n]
 * Symbol table st_kind: 0=fn 1=extern_fn 2=global 3=extern_global (SK_*).
 */

/* ---- node/token accessors ---- */
/* The bootstrap's node graph is 1-based (handle h = idx+1, 0 == none); this
 * twin's struct node is 0-based (-1 == none). The codegen below was ported
 * verbatim from the bootstrap and therefore tests "no node" with 0. Map the
 * twin's -1 sentinel to 0 here so every `x != 0` / `x == 0` child-chain test
 * reads correctly without touching the ported logic. (gx_val is never keyed
 * by a -1 node, so collapsing -1 -> 0 cannot alias a real node index.) */
#define NK(n)  nodes[(n)].kind
#define NF(n)  ((nodes[(n)].first < 0) ? 0 : nodes[(n)].first)
#define NN(n)  ((nodes[(n)].next  < 0) ? 0 : nodes[(n)].next)
#define NT(n)  nodes[(n)].tok
#define NTY(n) nodes[(n)].ty
#define ETY(n) ety[(n)]
#define EAR(n) earr[(n)]

/* ---- type tags (mirror parser_names.h TY_*) ---- */
/* TY_I32=1 TY_I64=2 TY_U8=3 TY_PTR=4 TY_PTR_U8=5 TY_PTR_I32=6 TY_PTR_I64=7 */
#define is_ptr_tag_t(t) ((t)==4||(t)==5||(t)==6||(t)==7)
static int ptr_elem_t(int t){
    if (t==6) return 1;   /* i32 */
    if (t==7) return 2;   /* i64 */
    if (t==5) return 3;   /* u8  */
    return 1;             /* bare ptr -> i32 */
}
static int ty_width_t(int t){
    if (t==1) return 4;   /* i32 */
    if (t==2) return 8;   /* i64 */
    if (t==3) return 1;   /* u8  */
    return 8;             /* every pointer is 8 bytes */
}
static int ty_is64_t(int t){ return (t==2) || is_ptr_tag_t(t); }
static int ty_is_uns_t(int t){ return (t==3); }
static int log2w_t(int w){ if (w==1) return 0; if (w==4) return 2; return 3; }
static int mem_scale_t(int w){ if (w==1) return 0; if (w==4) return 2; return 3; }

/* ---- output channel (byte-identical to the bootstrap's write(1,...)) ---- */
static unsigned char outbuf[16*1048576];
static int outlen;
static void putb(int c){ if (outlen < (int)sizeof(outbuf)) outbuf[outlen++] = (unsigned char)c; }
static void putn(const unsigned char *p, int n){ for (int i=0;i<n;i++) putb(p[i]); }
static int flush_out(void){ fwrite(outbuf,1,(size_t)outlen,stdout); return 0; }

/* ---- ELF little-endian field writers ---- */
static void elf_put16(int v){ putb(v&0xff); putb((v>>8)&0xff); }
static void elf_put32(int64_t v){ putb(v&0xff); putb((v>>8)&0xff); putb((v>>16)&0xff); putb((v>>24)&0xff); }
static void elf_put64(int64_t v){ elf_put32(v & 0xffffffffLL); elf_put32((v>>32)&0xffffffffLL); }

/* ---- codegen diagnostics ---- */
static int cg_l=1, cg_c=1;
static int cg_die(const char *msg){ die_at(msg, cg_l, cg_c); return 1; }
static int cg_die_at_node(const char *msg, int n){
    cg_l = tok_line(NT(n)); cg_c = tok_col(NT(n)); return cg_die(msg);
}
static int cg_die_name_at(const char *msg, int t){ die_name_at(msg, t); return 1; }
/* The bootstrap's builder-style diagnostic (die_open / bputname / bputs /
 * die_close) reimplemented against this twin's token buffer; exits 1, same
 * shape as the frontend's `aster: error: <msg> at L:C`. */
static void die_open(void){ fprintf(stderr, "aster: error: "); }
static void bputname(int t){ fprintf(stderr, "%.*s", toks[t].len, srcbuf + toks[t].start); }
static void bputs(const char *s){ fputs(s, stderr); }
static int die_close(int l, int c){ fprintf(stderr, " at %d:%d\n", l, c); exit(1); }
/* Print a type tag's name to stderr (mirrors the frontend's ty_name). */
static void bputtybase(int t){ fputs(ty_name(t), stderr); }

/* ---- §4/§5: the instruction stream and temporary pool ---- */
static int textw[262144];
static int textlen;
static int tmp_free[16];
static int tmp_top;
/* Address/layout state allocated during cg_collect, referenced by the code
 * emitter; declared here (ahead of first use) so the file compiles clean. */
static int str_addr[65536];      /* per E_String node: .rodata address */
static int g_addr[4096];         /* per global symbol: absolute address */
static int g_sec[4096];          /* 0=.bss 1=.data */
/* codegen/emit shared state, hoisted ahead of first use */
static int fn_lab[4096], main_sym=-1, init_lab=0, has_stub=0, init_words=0, fn_words[4096];
static int gia_ew=0, gia_ety=0;
static int cg_init_pool(void){
    for (int i=0;i<16;i++) tmp_free[i]=i;
    tmp_top=0; textlen=0; return 0;
}
static int alloc_tmp(void){
    if (tmp_top >= 16){ cg_die("expression too complex: temporary register limit exceeded"); return -1; }
    int r = tmp_free[tmp_top]; tmp_top++; return r;
}
static int free_tmp(int r){
    if (tmp_top<=0 || tmp_free[tmp_top-1]!=r){ cg_die("internal compiler error: temporary register leak"); return 1; }
    tmp_top--; return 0;
}
static int emit_word(int64_t w){
    if (textlen >= 262144){ return cg_die(".text exceeds the 1 MiB instruction buffer"); }
    textw[textlen] = (int)(w & 0xffffffffLL); textlen++; return 0;
}

/* ---- §7 labels and fixups ---- */
static int labels[65536];
static int nlabels;
static int fx_pos[65536], fx_kind[65536], fx_label[65536], fx_cond[65536], nfix;
static int new_label(void){
    if (nlabels >= 65536){ cg_die("too many labels"); return -1; }
    int l=nlabels; nlabels++; return l;
}
static int place_label(int l){ labels[l]=textlen; return 0; }
static int push_fix(int kind, int label, int cond){
    if (nfix >= 65536){ return cg_die("fixup table overflow"); }
    fx_pos[nfix]=textlen-1; fx_kind[nfix]=kind; fx_label[nfix]=label; fx_cond[nfix]=cond; nfix++; return 0;
}

/* ---- §4.1 immediate moves ---- */
static int emit_movz(int rd,int imm,int hw,int is64){
    int64_t base = 0x52800000LL; if (is64==1) base=0xd2800000LL;
    return emit_word(base | (((int64_t)hw<<21) | ((int64_t)imm<<5) | rd));
}
static int emit_movk(int rd,int imm,int hw,int is64){
    int64_t base = 0x72800000LL; if (is64==1) base=0xf2800000LL;
    return emit_word(base | (((int64_t)hw<<21) | ((int64_t)imm<<5) | rd));
}
static int emit_mov_rr(int rd,int rm,int is64){
    int64_t base = 0x2a0003e0LL; if (is64==1) base=0xaa0003e0LL;
    return emit_word(base | (((int64_t)rm<<16) | rd));
}
static int emit_mov_zero(int rd,int is64){
    int64_t base = 0x2a1f03e0LL; if (is64==1) base=0xaa1f03e0LL;
    return emit_word(base | rd);
}
static int emit_imm64(int rd,int64_t v){
    int c0=(int)(v&0xffff), c1=(int)((v>>16)&0xffff), c2=(int)((v>>32)&0xffff), c3=(int)((v>>48)&0xffff);
    int rc=emit_movz(rd,c0,0,1); if(rc) return rc;
    if ((v>>16)!=0){ rc=emit_movk(rd,c1,1,1); if(rc) return rc; }
    if ((v>>32)!=0){ rc=emit_movk(rd,c2,2,1); if(rc) return rc; }
    if ((v>>48)!=0){ rc=emit_movk(rd,c3,3,1); if(rc) return rc; }
    return 0;
}
static int emit_addr64(int rd,int64_t v){
    int c0=(int)(v&0xffff), c1=(int)((v>>16)&0xffff), c2=(int)((v>>32)&0xffff), c3=(int)((v>>48)&0xffff);
    int rc=emit_movz(rd,c0,0,1); if(rc) return rc;
    rc=emit_movk(rd,c1,1,1); if(rc) return rc;
    rc=emit_movk(rd,c2,2,1); if(rc) return rc;
    return emit_movk(rd,c3,3,1);
}
/* ---- §4.2 arithmetic / logic / shift ---- */
static int emit_addsub_imm(int rd,int rn,int imm,int is_sub,int is64){
    int64_t base=0x11000000LL;
    if (is64==1){ base = is_sub?0xd1000000LL:0x91000000LL; }
    else { base = is_sub?0x51000000LL:0x11000000LL; }
    int sh=0, im=imm;
    if (imm>4095){
        if (imm%4096!=0 || imm/4096>4095){ return cg_die("internal compiler error: immediate out of range"); }
        im=imm/4096; sh=1;
    }
    return emit_word(base | (((int64_t)sh<<22) | ((int64_t)im<<10) | ((int64_t)rn<<5) | rd));
}
static int emit_addsub_rr(int rd,int rn,int rm,int is_sub,int is64){
    int64_t base=0x0b000000LL;
    if (is64==1){ base = is_sub?0xcb000000LL:0x8b000000LL; }
    else { base = is_sub?0x4b000000LL:0x0b000000LL; }
    return emit_word(base | (((int64_t)rm<<16) | ((int64_t)rn<<5) | rd));
}
static int emit_mul(int rd,int rn,int rm,int is64){
    int64_t base=0x1b007c00LL; if (is64==1) base=0x9b007c00LL;
    return emit_word(base | (((int64_t)rm<<16) | ((int64_t)rn<<5) | rd));
}
static int emit_div(int rd,int rn,int rm,int is64,int uns){
    int64_t base=0x1ac00c00LL;
    if (is64==1) base=0x9ac00c00LL;
    if (uns==1) base = base - 1024;
    return emit_word(base | (((int64_t)rm<<16) | ((int64_t)rn<<5) | rd));
}
static int emit_msub(int rd,int rn,int rm,int ra,int is64){
    int64_t base=0x1b008000LL; if (is64==1) base=0x9b008000LL;
    return emit_word(base | (((int64_t)rm<<16) | ((int64_t)ra<<10) | ((int64_t)rn<<5) | rd));
}
static int emit_shift(int rd,int rn,int rm,int is64,int kind){
    int64_t base=0x1ac02000LL; if (is64==1) base=0x9ac02000LL;
    return emit_word(base | (((int64_t)kind<<10) | ((int64_t)rm<<16) | ((int64_t)rn<<5) | rd));
}
static int emit_logic(int rd,int rn,int rm,int is64,int kind){
    int64_t base=0x0a000000LL; if (is64==1) base=0x8a000000LL;
    if (kind==1) base+=0x20000000LL;
    if (kind==2) base+=0x40000000LL;
    return emit_word(base | (((int64_t)rm<<16) | ((int64_t)rn<<5) | rd));
}
static int emit_neg(int rd,int rm,int is64){
    int64_t base=0x4b0003e0LL; if (is64==1) base=0xcb0003e0LL;
    return emit_word(base | (((int64_t)rm<<16) | rd));
}
static int emit_sxtw(int rd,int rn){ return emit_word(0x93407c00LL | (((int64_t)rn<<5)|rd)); }
/* ---- §4.3 pointer arithmetic (extended register) ---- */
static int emit_addsub_ext(int rd,int rn,int rm,int is_sub,int option,int sh){
    int64_t base=0x8b200000LL; if (is_sub==1) base=0xcb200000LL;
    return emit_word(base | (((int64_t)rm<<16) | ((int64_t)option<<13) | ((int64_t)sh<<10) | ((int64_t)rn<<5) | rd));
}
/* ---- §4.4 compare / condition / branch ---- */
static int emit_cmp_rr(int rn,int rm,int is64){
    int64_t base=0x6b00001fLL; if (is64==1) base=0xeb00001fLL;
    return emit_word(base | (((int64_t)rm<<16) | ((int64_t)rn<<5)));
}
static int emit_cmp_imm(int rn,int imm,int is64){
    int64_t base=0x7100001fLL; if (is64==1) base=0xf100001fLL;
    if (imm<0 || imm>4095){ return cg_die("internal compiler error: compare immediate out of range"); }
    return emit_word(base | (((int64_t)imm<<10) | ((int64_t)rn<<5)));
}
static int emit_cset(int rd,int cond){ return emit_word(0x1a9f07e0LL | ((((int64_t)cond^1)<<12) | rd)); }
static int emit_bcond(int cond,int label){
    int rc=emit_word(0x54000000LL | cond); if(rc) return rc;
    return push_fix(0,label,cond);
}
static int emit_b(int label){
    int rc=emit_word(0x14000000LL); if(rc) return rc;
    return push_fix(1,label,0);
}
static int emit_bl(int label){
    int rc=emit_word(0x94000000LL); if(rc) return rc;
    return push_fix(2,label,0);
}
static int emit_ret(void){ return emit_word(0xd65f03c0LL); }
static int emit_svc(void){ return emit_word(0xd4000001LL); }
/* ---- §4.5 load/store ---- */
static int emit_mem(int is_store,int scale,int rt,int rn,int off){
    int64_t base=0xf9400000LL;
    if (is_store==1){
        if (scale==0) base=0x39000000LL; else if (scale==1) base=0x79000000LL;
        else if (scale==2) base=0xb9000000LL; else base=0xf9000000LL;
    } else {
        if (scale==0) base=0x39400000LL; else if (scale==1) base=0x79400000LL;
        else if (scale==2) base=0xb9400000LL; else base=0xf9400000LL;
    }
    int imm = off>>scale;
    if (imm<0 || imm>4095){ return cg_die("internal compiler error: frame offset out of range"); }
    return emit_word(base | (((int64_t)imm<<10) | ((int64_t)rn<<5) | rt));
}

/* ---- §6.0 the frame's local-variable table (rebuilt per function) ---- */
static int cg_loc_tok[512], cg_loc_slot[512], cg_loc_ty[512], cg_loc_cnt[512];
static int cg_nlocs, cg_next_slot, cg_scope[128], cg_sc_depth, cg_grid_hi;
static int cg_reset_frame(void){ cg_nlocs=0; cg_next_slot=32; cg_sc_depth=0; cg_grid_hi=0; return 0; }
static int cg_push_scope(void){
    if (cg_sc_depth>=128){ return cg_die("internal compiler error: scope stack overflow"); }
    cg_scope[cg_sc_depth]=cg_nlocs; cg_sc_depth++; return 0;
}
static int cg_pop_scope(void){
    if (cg_sc_depth<=0){ return cg_die("internal compiler error: scope stack underflow"); }
    cg_sc_depth--; cg_nlocs=cg_scope[cg_sc_depth]; return 0;
}
static int cg_add_local(int tok,int ty,int cnt){
    if (cg_nlocs>=500 || cg_next_slot>=532){
        cg_l=tok_line(tok); cg_c=tok_col(tok);
        if (cg_die("too many local declarations (limit 500, including parameters)")) return -1;
    }
    cg_loc_tok[cg_nlocs]=tok; cg_loc_slot[cg_nlocs]=cg_next_slot; cg_loc_ty[cg_nlocs]=ty; cg_loc_cnt[cg_nlocs]=cnt;
    cg_nlocs++; cg_next_slot++; return cg_loc_slot[cg_nlocs-1];
}
static int cg_find_local(int tok){
    for (int i=cg_nlocs-1;i>=0;i--) if (name_eq(cg_loc_tok[i],tok)==1) return i;
    return -1;
}
static int cg_find_global(int tok){
    for (int s=0;s<nsym;s++) if (st_kind[s]==2 && name_eq(st_name[s],tok)==1) return s;
    return -1;
}
static int emit_frame_addr(int d,int off){
    if (off<=4095 || off%4096==0){ return emit_addsub_imm(d,31,off,0,1); }
    if (off/4096>4095){ return cg_die("internal compiler error: frame offset out of range"); }
    if (emit_addsub_imm(d,31,(off/4096)*4096,0,1)) return 1;
    return emit_addsub_imm(d,d,off%4096,0,1);
}

/* ---- §3 the intrinsic signatures (CODEGEN-SPEC.md §8) ---- */
#define IC_LOAD_PTR 1
#define IC_MMAP     2
#define IC_BRK      3
#define IC_LOAD_I64 4
#define IC_STORE_I64 5
#define IC_LOAD_U8  6
#define IC_STORE_U8 7
#define IC_LOAD_U16 8
#define IC_STORE_U16 9
#define IC_READ     10
#define IC_WRITE    11
#define IC_EXIT     12
#define IC_OPENAT   13
#define IC_CLOSE    14
#define IC_FSTAT    15
static int ic_sig(int ic){
    if (ic==IC_LOAD_PTR)  return 1 | (4<<3);
    if (ic==IC_LOAD_I64)  return 1 | (4<<3);
    if (ic==IC_LOAD_U8)   return 1 | (4<<3);
    if (ic==IC_LOAD_U16)  return 1 | (4<<3);
    if (ic==IC_STORE_I64) return 2 | (4<<3) | (2<<6);
    if (ic==IC_STORE_U8)  return 2 | (4<<3) | (1<<6);
    if (ic==IC_STORE_U16) return 2 | (4<<3) | (1<<6);
    if (ic==IC_WRITE)     return 3 | (1<<3) | (4<<6) | (1<<9) | (64<<21);
    if (ic==IC_READ)      return 3 | (1<<3) | (4<<6) | (1<<9) | (63<<21);
    if (ic==IC_OPENAT)    return 4 | (1<<3) | (4<<6) | (1<<9) | (1<<12) | (56<<21);
    if (ic==IC_CLOSE)     return 1 | (1<<3) | (57<<21);
    if (ic==IC_FSTAT)     return 2 | (1<<3) | (4<<6) | (80<<21);
    if (ic==IC_MMAP)      return 6 | (4<<3) | (2<<6) | (1<<9) | (1<<12) | (1<<15) | (2<<18) | (222<<21);
    if (ic==IC_BRK)       return 1 | (4<<3) | (214<<21);
    return 1 | (1<<3) | (93<<21);   /* IC_EXIT */
}
static int ic_argc(int s){ return s & 7; }
static int ic_argty(int s,int i){ return (s>>(3+3*i)) & 7; }
static int ic_nr(int s){ return (s>>21) & 255; }
static const char *ic_ordinal(int i){
    if (i==0) return " first";
    if (i==1) return " second";
    if (i==2) return " third";
    if (i==3) return " fourth";
    if (i==4) return " fifth";
    return " sixth";
}
static const char *ic_count_msg(int ic){
    if (ic==IC_LOAD_PTR||ic==IC_LOAD_I64||ic==IC_LOAD_U8||ic==IC_LOAD_U16) return " expects exactly one ptr argument";
    if (ic==IC_STORE_I64) return " expects (ptr, i64)";
    if (ic==IC_STORE_U8||ic==IC_STORE_U16) return " expects (ptr, i32)";
    if (ic==IC_WRITE||ic==IC_READ) return " expects (fd: i32, buf: ptr, len: i32)";
    if (ic==IC_OPENAT) return " expects (fd: i32, path: ptr, flags: i32, mode: i32)";
    if (ic==IC_CLOSE) return " expects (fd: i32)";
    if (ic==IC_FSTAT) return " expects (fd: i32, buf: ptr)";
    if (ic==IC_MMAP) return " expects (addr: ptr, length: i64, prot: i32, flags: i32, fd: i32, offset: i64)";
    if (ic==IC_BRK) return " expects (addr: ptr)";
    return " expects (code: i32)";
}

/* ---- §6.1 gen_expr: the iterative lowering machine ---- */
static int gx_node[65536], gx_state[65536], gx_want[65536], gx_val[65536], gx_top;
static int gx_push_bin(int n,int wantL,int wantR,int wt){
    if (gx_top+3>65536){ return cg_die_at_node("internal compiler error: expression stack overflow", n); }
    int l=NF(n), r=NN(l);
    gx_node[gx_top]=n; gx_state[gx_top]=1; gx_want[gx_top]=wt; gx_top++;
    gx_node[gx_top]=r; gx_state[gx_top]=0; gx_want[gx_top]=wantR; gx_top++;
    gx_node[gx_top]=l; gx_state[gx_top]=0; gx_want[gx_top]=wantL; gx_top++;
    return 0;
}
static int gx_push_un(int n,int wantC,int wt){
    if (gx_top+2>65536){ return cg_die_at_node("internal compiler error: expression stack overflow", n); }
    gx_node[gx_top]=n; gx_state[gx_top]=1; gx_want[gx_top]=wt; gx_top++;
    gx_node[gx_top]=NF(n); gx_state[gx_top]=0; gx_want[gx_top]=wantC; gx_top++;
    return 0;
}
static int gx_dispatch(int n,int wt){
    int k=NK(n);
    if (k==E_Index) return gx_push_un(n,1,wt);
    if (k==E_Neg||k==E_Not) return gx_push_un(n,wt,wt);
    int l=NF(n), r=NN(l), lt=ETY(l), rt=ETY(r);
    if (k==E_Shl||k==E_Shr){
        int ow=wt; if (ty_is64_t(wt)||ty_is64_t(lt)) ow=2;
        return gx_push_bin(n,ow,1,wt);
    }
    if (k==E_Add||k==E_Sub){
        int lp=is_ptr_tag_t(lt), rp=is_ptr_tag_t(rt);
        if (lp==1 && rp==0) return gx_push_bin(n,2,1,wt);
        if (k==E_Add && lp==0 && rp==1) return gx_push_bin(n,1,2,wt);
        int ow=wt; if (ty_is64_t(wt)||ty_is64_t(lt)||ty_is64_t(rt)) ow=2;
        return gx_push_bin(n,ow,ow,wt);
    }
    if (k==E_Eq||k==E_Ne||k==E_Lt||k==E_Le||k==E_Gt||k==E_Ge){
        int cw=1; if (ty_is64_t(lt)||ty_is64_t(rt)) cw=2;
        return gx_push_bin(n,cw,cw,wt);
    }
    if (k==E_And||k==E_Or) return gx_push_bin(n,1,1,wt);
    int ow=wt; if (ty_is64_t(wt)||ty_is64_t(lt)||ty_is64_t(rt)) ow=2;
    return gx_push_bin(n,ow,ow,wt);
}
static int gen_var(int n,int want);
static int gen_call(int n,int want);
static int gen_combine(int n,int want);
static int gen_index(int n,int want);
static int gen_stmt(int s);
static int gen_index_addr(int tok,int idxexpr);
static int expr_yields_ptr(int h);
static int gen_expr_at(int h,int want,int base){
    gx_node[base]=h; gx_state[base]=0; gx_want[base]=want; gx_top=base+1;
    while (gx_top>base){
        gx_top--;
        int n=gx_node[gx_top], st=gx_state[gx_top], wt=gx_want[gx_top];
        if (st==1){ if (gen_combine(n,wt)) return -1; continue; }
        int k=NK(n);
        if (k==E_Num||k==E_String||k==E_Var){
            int r=0;
            if (k==E_Num){
                convert_num(NT(n));
                int d=alloc_tmp(); if (d<0) return -1;
                if (ty_is64_t(wt)==1){
                    if (emit_imm64(d,numval)) return -1;
                } else {
                    int lo=(int)(numval&0xffff), hi=(int)((numval>>16)&0xffff);
                    if (emit_movz(d,lo,0,0)) return -1;
                    if (hi!=0){ if (emit_movk(d,hi,1,0)) return -1; }
                }
                r=d;
            } else if (k==E_String){
                int d=alloc_tmp(); if (d<0) return -1;
                if (emit_addr64(d, str_addr[n])) return -1;
                r=d;
            } else {
                r=gen_var(n,wt);
            }
            if (r<0) return -1;
            gx_val[n]=r; continue;
        }
        if (k==E_Call){ int r=gen_call(n,wt); if (r<0) return -1; gx_val[n]=r; continue; }
        if (gx_dispatch(n,wt)) return -1;
    }
    return gx_val[h];
}
static int gen_expr(int h,int want){ return gen_expr_at(h,want,0); }

static int param_type(int fnode,int i){
    int p=NF(fnode), pi=0;
    while (p!=0){
        if (NK(p)==N_Param){ if (pi==i) return NTY(p); pi++; }
        p=NN(p);
    }
    return 1;
}
static int cmp_cond(int k,int lt,int rt){
    int uns=0; if (lt==3||rt==3) uns=1;
    if (k==E_Eq) return 0;
    if (k==E_Ne) return 1;
    if (k==E_Lt){ return uns?3:11; }
    if (k==E_Le){ return uns?9:13; }
    if (k==E_Gt){ return uns?8:12; }
    if (k==E_Ge){ return uns?2:10; }
    return 0;
}
static int gen_combine(int n,int want){
    int k=NK(n);
    if (k==E_Index) return gen_index(n,want);
    if (k==E_Neg){
        int a=gx_val[NF(n)], is64 = ty_is64_t(want)?1:0;
        if (emit_neg(a,a,is64)) return 1;
        gx_val[n]=a; return 0;
    }
    if (k==E_Not){
        int op=NF(n), a=gx_val[op], is64 = ty_is64_t(ETY(op))?1:0;
        if (emit_cmp_imm(a,0,is64)) return 1;
        if (emit_cset(a,0)) return 1;
        gx_val[n]=a; return 0;
    }
    int l=NF(n), r=NN(l), lt=ETY(l), rt=ETY(r), a=gx_val[l], b=gx_val[r];
    if (k==E_Add||k==E_Sub){
        int lp=is_ptr_tag_t(lt), rp=is_ptr_tag_t(rt);
        if (k==E_Add && lp==1 && rp==1){ return cg_die_at_node("invalid pointer arithmetic: expected ptr +/- i32 or i32 + ptr", n); }
        if (k==E_Sub && rp==1){ return cg_die_at_node("invalid pointer arithmetic: expected ptr +/- i32 or i32 + ptr", n); }
        if (lp==1 && rp==0){
            int sub = (k==E_Sub)?1:0;
            if (emit_addsub_ext(a,a,b,sub,6,0)) return 1;
            if (free_tmp(b)) return 1;
            gx_val[n]=a; return 0;
        }
        if (k==E_Add && lp==0 && rp==1){
            if (emit_addsub_ext(a,b,a,0,6,0)) return 1;
            if (free_tmp(b)) return 1;
            gx_val[n]=a; return 0;
        }
        int is64=0; if (ty_is64_t(want)||ty_is64_t(lt)||ty_is64_t(rt)) is64=1;
        int sub=(k==E_Sub)?1:0;
        if (emit_addsub_rr(a,a,b,sub,is64)) return 1;
        if (free_tmp(b)) return 1;
        gx_val[n]=a; return 0;
    }
    if (k==E_Mul||k==E_Div||k==E_Mod){
        if (is_ptr_tag_t(lt)||is_ptr_tag_t(rt)){ return cg_die_at_node("invalid pointer arithmetic: expected ptr +/- i32 or i32 + ptr", n); }
        int is64=0; if (ty_is64_t(want)||ty_is64_t(lt)||ty_is64_t(rt)) is64=1;
        int uns=0; if (ty_is_uns_t(lt)||ty_is_uns_t(rt)) uns=1;
        if (k==E_Mul){ if (emit_mul(a,a,b,is64)) return 1; if (free_tmp(b)) return 1; gx_val[n]=a; return 0; }
        if (k==E_Div){ if (emit_div(a,a,b,is64,uns)) return 1; if (free_tmp(b)) return 1; gx_val[n]=a; return 0; }
        int q=alloc_tmp(); if (q<0) return -1;
        if (emit_div(q,a,b,is64,uns)) return 1;
        if (emit_msub(a,a,b,q,is64)) return 1;
        if (free_tmp(q)) return 1;
        if (free_tmp(b)) return 1;
        gx_val[n]=a; return 0;
    }
    if (k==E_Shl||k==E_Shr){
        if (is_ptr_tag_t(lt)){ return cg_die_at_node("invalid pointer arithmetic: expected ptr +/- i32 or i32 + ptr", n); }
        int is64=0; if (ty_is64_t(want)||ty_is64_t(lt)) is64=1;
        int shk=0; if (k==E_Shr){ shk = ty_is_uns_t(lt)?1:2; }
        if (emit_shift(a,a,b,is64,shk)) return 1;
        if (free_tmp(b)) return 1;
        gx_val[n]=a; return 0;
    }
    if (k==E_BitAnd||k==E_BitOr||k==E_BitXor){
        if (is_ptr_tag_t(lt)||is_ptr_tag_t(rt)){ return cg_die_at_node("invalid pointer arithmetic: expected ptr +/- i32 or i32 + ptr", n); }
        int is64=0; if (ty_is64_t(want)||ty_is64_t(lt)||ty_is64_t(rt)) is64=1;
        int lk=0; if (k==E_BitOr) lk=1; if (k==E_BitXor) lk=2;
        if (emit_logic(a,a,b,is64,lk)) return 1;
        if (free_tmp(b)) return 1;
        gx_val[n]=a; return 0;
    }
    if (k==E_Eq||k==E_Ne||k==E_Lt||k==E_Le||k==E_Gt||k==E_Ge){
        int is64=0; if (ty_is64_t(lt)||ty_is64_t(rt)) is64=1;
        if (emit_cmp_rr(a,b,is64)) return 1;
        if (free_tmp(b)) return 1;
        if (free_tmp(a)) return 1;
        int d=alloc_tmp(); if (d<0) return -1;
        if (emit_cset(d,cmp_cond(k,lt,rt))) return 1;
        gx_val[n]=d; return 0;
    }
    if (k==E_And||k==E_Or){
        int isAnd=(k==E_And)?1:0;
        int is64=0; if (ty_is64_t(lt)) is64=1;
        if (emit_cmp_imm(a,0,is64)) return 1;
        if (isAnd==1){ if (emit_mov_zero(a,0)) return 1; } else { if (emit_movz(a,1,0,0)) return 1; }
        int lend=new_label(); if (lend<0) return -1;
        if (isAnd==1){ if (emit_bcond(0,lend)) return 1; } else { if (emit_bcond(1,lend)) return 1; }
        if (emit_mov_rr(a,b,0)) return 1;
        if (free_tmp(b)) return 1;
        if (place_label(lend)) return 1;
        gx_val[n]=a; return 0;
    }
    return cg_die_at_node("internal compiler error: unlowered expression", n);
}

static int gen_var(int n,int want){
    int tok=NT(n);
    int e=cg_find_local(tok);
    if (e>=0){
        int cnt=cg_loc_cnt[e], ty=cg_loc_ty[e];
        if (cnt>1){
            int d=alloc_tmp(); if (d<0) return -1;
            if (emit_frame_addr(d, cg_loc_slot[e]*8)) return -1;
            return d;
        }
        int d=alloc_tmp(); if (d<0) return -1;
        if (emit_mem(0, mem_scale_t(ty_width_t(ty)), d, 31, cg_loc_slot[e]*8)) return -1;
        if (ty==1 && ty_is64_t(want)==1){ if (emit_sxtw(d,d)) return -1; }
        return d;
    }
    int s=cg_find_global(tok);
    if (s<0){ return cg_die_name_at("unknown variable: ", tok); }
    if (st_kind[s]==3){ return cg_die_name_at("cannot reference external global: ", tok); }
    if (st_cnt[s]>1){
        int d=alloc_tmp(); if (d<0) return -1;
        if (emit_addr64(d, g_addr[s])) return -1;
        return d;
    }
    int d=alloc_tmp(); if (d<0) return -1;
    int t=alloc_tmp(); if (t<0) return -1;
    if (emit_addr64(t, g_addr[s])) return -1;
    if (emit_mem(0, mem_scale_t(ty_width_t(st_tag[s])), d, t, 0)) return -1;
    if (free_tmp(t)) return -1;
    if (st_tag[s]==1 && ty_is64_t(want)==1){ if (emit_sxtw(d,d)) return -1; }
    return d;
}

static int gen_index(int n,int want){
    int tok=NT(n), idx=NF(n), i=gx_val[idx], a=-1, ew=0;
    int e=cg_find_local(tok);
    if (e>=0){
        int cnt=cg_loc_cnt[e], ty=cg_loc_ty[e];
        if (cnt>1){ ew=ty_width_t(ty); a=alloc_tmp(); if (a<0) return -1; if (emit_frame_addr(a, cg_loc_slot[e]*8)) return -1; }
        else if (is_ptr_tag_t(ty)==1){ ew=ty_width_t(ptr_elem_t(ty)); a=alloc_tmp(); if (a<0) return -1; if (emit_mem(0,3,a,31,cg_loc_slot[e]*8)) return -1; }
        else { return cg_die_name_at("cannot index non-array variable: ", tok); }
    } else {
        int s=cg_find_global(tok);
        if (s<0){ return cg_die_name_at("unknown variable: ", tok); }
        if (st_kind[s]==3){ return cg_die_name_at("cannot reference external global: ", tok); }
        if (st_cnt[s]>1){ ew=ty_width_t(st_tag[s]); a=alloc_tmp(); if (a<0) return -1; if (emit_addr64(a, g_addr[s])) return -1; }
        else if (is_ptr_tag_t(st_tag[s])==1){ ew=ty_width_t(ptr_elem_t(st_tag[s])); a=alloc_tmp(); if (a<0) return -1; int t=alloc_tmp(); if (t<0) return -1; if (emit_addr64(t, g_addr[s])) return -1; if (emit_mem(0,3,a,t,0)) return -1; if (free_tmp(t)) return -1; }
        else { return cg_die_name_at("cannot index non-array variable: ", tok); }
    }
    if (emit_addsub_ext(i,a,i,0,2,log2w_t(ew))) return -1;
    if (free_tmp(a)) return -1;
    if (emit_mem(0, mem_scale_t(ew), i, i, 0)) return -1;
    if (ew==4 && ty_is64_t(want)==1){ if (emit_sxtw(i,i)) return -1; }
    gx_val[n]=i;
    return 0;
}

/* ---- §8 intrinsic dispatch ---- */
static int ic_check(int n,int ic){
    int s=ic_sig(ic), argc=ic_argc(s), cnt=0;
    int a=NF(n);
    while (a!=0){ cnt++; a=NN(a); }
    int callee=NT(n); cg_l=tok_line(callee); cg_c=tok_col(callee);
    if (cnt!=argc){
        die_open(); bputname(callee); bputs(ic_count_msg(ic)); return die_close(cg_l,cg_c);
    }
    int i=0; int arg=NF(n);
    while (arg!=0){
        int t=ETY(arg), slot=ic_argty(s,i), bad=0;
        if (is_ptr_tag_t(slot)==1){ if (is_ptr_tag_t(t)==0) bad=1; }
        else if (slot==2){ if (is_ptr_tag_t(t)==1 || t==-2) bad=1; }
        else { if (is_ptr_tag_t(t)==1) bad=1; }
        if (bad){
            die_open(); bputname(callee);
            if (ic_nr(s)==0 && argc==1){ bputs(" expects a ptr argument"); }
            else { if (argc>1) bputs(ic_ordinal(i)); bputs(" argument must be ");
                   if (is_ptr_tag_t(slot)==1) bputs("ptr"); else if (slot==2) bputs("i64"); else bputs("i32"); }
            return die_close(cg_l,cg_c);
        }
        i++; arg=NN(arg);
    }
    return 0;
}
static int gen_mem_intrinsic(int n,int ic,int s){
    int a0=NF(n);
    if (ic_argc(s)==1){
        int a=gen_expr_at(a0,2,gx_top); if (a<0) return -1;
        int scale=3; if (ic==IC_LOAD_U8) scale=0; if (ic==IC_LOAD_U16) scale=1;
        if (emit_mem(0,scale,a,a,0)) return -1;
        return a;
    }
    int a1=NN(a0), vty=ic_argty(s,1);
    int v=gen_expr_at(a1,vty,gx_top); if (v<0) return -1;
    int a=gen_expr_at(a0,2,gx_top); if (a<0) return -1;
    if (emit_mem(1, mem_scale_t(ty_width_t(vty)), v, a, 0)) return -1;
    if (free_tmp(a)) return -1;
    return v;
}
static int gen_intrinsic(int n,int want){
    int ic=rcall_intrinsic;
    if (ic_check(n,ic)) return -1;
    int s=ic_sig(ic), argc=ic_argc(s), nr=ic_nr(s);
    if (nr==0) return gen_mem_intrinsic(n,ic,s);
    int base=cg_grid_hi;
    if (base+argc>100){ cg_l=tok_line(NT(n)); cg_c=tok_col(NT(n)); if (cg_die("nested function-call arguments exceed compiler limit (100 scratch slots)")) return -1; }
    int parked_n=tmp_top; int pr=0;
    while (pr<parked_n){ if (emit_mem(1,3,tmp_free[pr],31,(900+pr)*8)) return -1; pr++; }
    tmp_top=0;
    int i=0; int arg=NF(n);
    while (arg!=0){
        int pty=ic_argty(s,i); cg_grid_hi=base+i;
        int v=gen_expr_at(arg,pty,gx_top); if (v<0) return -1;
        if (emit_mem(1, mem_scale_t(ty_width_t(pty)), v, 31, (800+base+i)*8)) return -1;
        if (free_tmp(v)) return -1;
        i++; arg=NN(arg);
    }
    cg_grid_hi=base;
    i=0; while (i<argc){ int pty=ic_argty(s,i); if (emit_mem(0, mem_scale_t(ty_width_t(pty)), i, 31, (800+base+i)*8)) return -1; i++; }
    if (emit_movz(8,nr,0,1)) return -1;
    if (emit_svc()) return -1;
    if (emit_mem(1,3,0,31,1022*8)) return -1;
    pr=0; while (pr<parked_n){ if (emit_mem(0,3,tmp_free[pr],31,(900+pr)*8)) return -1; pr++; }
    tmp_top=parked_n;
    int d=alloc_tmp(); if (d<0) return -1;
    int rty=rcall_rtyp;
    if (emit_mem(0, mem_scale_t(ty_width_t(rty)), d, 31, 1022*8)) return -1;
    if (rty==1 && ty_is64_t(want)==1){ if (emit_sxtw(d,d)) return -1; }
    return d;
}
static int gen_call(int n,int want){
    int callee=NT(n);
    int r=sym_find_call(callee);
    if (r!=1){ return cg_die_name_at("call to undeclared function: ", callee); }
    int fsym=rs_fnsym;
    if (fsym==-1) return gen_intrinsic(n,want);
    if (st_kind[fsym]==1){ return cg_die_name_at("cannot call external function: ", callee); }
    int fnode=st_node[fsym], argc=0;
    int a0=NF(n); while (a0!=0){ argc++; a0=NN(a0); }
    int base=cg_grid_hi;
    if (base+argc>100){ cg_l=tok_line(callee); cg_c=tok_col(callee); if (cg_die("nested function-call arguments exceed compiler limit (100 scratch slots)")) return -1; }
    int parked_n=tmp_top; int pr=0;
    while (pr<parked_n){ if (emit_mem(1,3,tmp_free[pr],31,(900+pr)*8)) return -1; pr++; }
    tmp_top=0;
    int i=0; int arg=NF(n);
    while (arg!=0){
        int pty=param_type(fnode,i); cg_grid_hi=base+i;
        int v=gen_expr_at(arg,pty,gx_top); if (v<0) return -1;
        if (emit_mem(1, mem_scale_t(ty_width_t(pty)), v, 31, (800+base+i)*8)) return -1;
        if (free_tmp(v)) return -1;
        i++; arg=NN(arg);
    }
    cg_grid_hi=base;
    i=0; while (i<argc && i<8){ int pty=param_type(fnode,i); if (emit_mem(0, mem_scale_t(ty_width_t(pty)), i, 31, (800+base+i)*8)) return -1; i++; }
    while (i<argc){ if (emit_mem(0,3,9,31,(800+base+i)*8)) return -1; if (emit_mem(1,3,9,31,(i-8)*8)) return -1; i++; }
    if (emit_bl(fn_lab[fsym])) return -1;
    if (emit_mem(1,3,0,31,1022*8)) return -1;
    pr=0; while (pr<parked_n){ if (emit_mem(0,3,tmp_free[pr],31,(900+pr)*8)) return -1; pr++; }
    tmp_top=parked_n;
    int d=alloc_tmp(); if (d<0) return -1;
    if (emit_mem(0, mem_scale_t(ty_width_t(st_tag[fsym])), d, 31, 1022*8)) return -1;
    if (st_tag[fsym]==1 && ty_is64_t(want)==1){ if (emit_sxtw(d,d)) return -1; }
    return d;
}

/* ---- §6.3 the loop label stack ---- */
static int lp_exit[64], lp_cont[64], lp_depth;
static int cg_ret_ty=0, cg_is_main=0;

static int gen_block(int b){
    int s=NF(b);
    while (s!=0){ if (gen_stmt(s)) return 1; s=NN(s); }
    return 0;
}
static int gen_stmt(int s){
    int k=NK(s);
    if (k==S_Let){
        int slot=cg_add_local(NT(s), NTY(s), 1); if (slot<0) return 1;
        int v=gen_expr(NF(s), NTY(s)); if (v<0) return 1;
        if (emit_mem(1, mem_scale_t(ty_width_t(NTY(s))), v, 31, slot*8)) return 1;
        if (free_tmp(v)) return 1;
        return 0;
    }
    /* (S_Assign continues below) */
    if (k==S_Assign){
        int tok=NT(s), e=NF(s), li=cg_find_local(tok);
        if (li>=0){
            int ty=cg_loc_ty[li], v=gen_expr(e,ty); if (v<0) return 1;
            if (emit_mem(1, mem_scale_t(ty_width_t(ty)), v, 31, cg_loc_slot[li]*8)) return 1;
            if (free_tmp(v)) return 1;
            return 0;
        }
        int gs=cg_find_global(tok);
        if (gs<0){ return cg_die_name_at("unknown variable: ", tok); }
        if (st_kind[gs]==3){ return cg_die_name_at("cannot reference external global: ", tok); }
        int ty=st_tag[gs], v=gen_expr(e,ty); if (v<0) return 1;
        int t=alloc_tmp(); if (t<0) return 1;
        if (emit_addr64(t, g_addr[gs])) return 1;
        if (emit_mem(1, mem_scale_t(ty_width_t(ty)), v, t, 0)) return 1;
        if (free_tmp(t)) return 1;
        if (free_tmp(v)) return 1;
        return 0;
    }
    if (k==S_IndexAssign){
        int inode=NF(s), rhs=NN(inode);
        int a=gen_index_addr(NT(inode), NF(inode)); if (a<0) return 1;
        int ew=gia_ew, v=gen_expr(rhs, gia_ety); if (v<0) return 1;
        if (emit_mem(1, mem_scale_t(ew), v, a, 0)) return 1;
        if (free_tmp(v)) return 1;
        if (free_tmp(a)) return 1;
        return 0;
    }
    if (k==S_Return){
        int v=gen_expr(NF(s), cg_ret_ty); if (v<0) return 1;
        int is64 = ty_is64_t(cg_ret_ty)?1:0;
        if (emit_mov_rr(0,v,is64)) return 1;
        if (free_tmp(v)) return 1;
        if (cg_is_main==1){
            if (emit_movz(8,93,0,1)) return 1;
            if (emit_svc()) return 1;
            return 0;
        }
        if (emit_mem(0,3,30,31,1023*8)) return 1;
        if (emit_addsub_imm(31,31,8192,0,1)) return 1;
        if (emit_ret()) return 1;
        return 0;
    }
    if (k==S_If){
        int cond=NF(s), r=gen_expr(cond,1); if (r<0) return 1;
        int is64 = ty_is64_t(ETY(cond))?1:0;
        if (emit_cmp_imm(r,0,is64)) return 1;
        if (free_tmp(r)) return 1;
        int lelse=new_label(); if (lelse<0) return 1;
        if (emit_bcond(0,lelse)) return 1;
        int tb=NN(cond);
        if (cg_push_scope()) return 1;
        if (gen_block(tb)) return 1;
        if (cg_pop_scope()) return 1;
        int lend=new_label(); if (lend<0) return 1;
        if (emit_b(lend)) return 1;
        if (place_label(lelse)) return 1;
        int el=NN(tb);
        if (el!=0){
            if (cg_push_scope()) return 1;
            int erc; if (NK(el)==N_Block) erc=gen_block(el); else erc=gen_stmt(el);
            if (erc) return 1;
            if (cg_pop_scope()) return 1;
        }
        if (place_label(lend)) return 1;
        return 0;
    }
    if (k==S_While){
        int cond=NF(s), lcond=new_label(); if (lcond<0) return 1;
        int lexit=new_label(); if (lexit<0) return 1;
        if (place_label(lcond)) return 1;
        int r=gen_expr(cond,1); if (r<0) return 1;
        int is64 = ty_is64_t(ETY(cond))?1:0;
        if (emit_cmp_imm(r,0,is64)) return 1;
        if (free_tmp(r)) return 1;
        if (emit_bcond(0,lexit)) return 1;
        if (lp_depth>=64){ return cg_die_at_node("loops nested too deeply (limit 64)", s); }
        lp_exit[lp_depth]=lexit; lp_cont[lp_depth]=lcond; lp_depth++;
        if (cg_push_scope()) return 1;
        if (gen_block(NN(cond))) return 1;
        if (cg_pop_scope()) return 1;
        lp_depth--;
        if (emit_b(lcond)) return 1;
        if (place_label(lexit)) return 1;
        return 0;
    }
    if (k==S_Break){ if (lp_depth==0) return cg_die_at_node("break used outside a loop", s); if (emit_b(lp_exit[lp_depth-1])) return 1; return 0; }
    if (k==S_Continue){ if (lp_depth==0) return cg_die_at_node("continue used outside a loop", s); if (emit_b(lp_cont[lp_depth-1])) return 1; return 0; }
    int v=gen_expr(NF(s),1); if (v<0) return 1;
    if (free_tmp(v)) return 1;
    return 0;
}
/* gia_ew / gia_ety declared earlier (hoisted) */
static int gen_index_addr(int tok,int idxexpr){
    int i=gen_expr(idxexpr,1); if (i<0) return -1;
    int a=alloc_tmp(); if (a<0) return -1;
    int e=cg_find_local(tok);
    if (e>=0){
        int cnt=cg_loc_cnt[e], ty=cg_loc_ty[e];
        if (cnt>1){ gia_ety=ty; if (emit_frame_addr(a, cg_loc_slot[e]*8)) return -1; }
        else if (is_ptr_tag_t(ty)==1){ gia_ety=ptr_elem_t(ty); if (emit_mem(0,3,a,31,cg_loc_slot[e]*8)) return -1; }
        else { return cg_die_name_at("cannot index non-array variable: ", tok); }
    } else {
        int s=cg_find_global(tok);
        if (s<0){ return cg_die_name_at("unknown variable: ", tok); }
        if (st_kind[s]==3){ return cg_die_name_at("cannot reference external global: ", tok); }
        if (st_cnt[s]>1){ gia_ety=st_tag[s]; if (emit_addr64(a, g_addr[s])) return -1; }
        else if (is_ptr_tag_t(st_tag[s])==1){ gia_ety=ptr_elem_t(st_tag[s]); int t=alloc_tmp(); if (t<0) return -1; if (emit_addr64(t, g_addr[s])) return -1; if (emit_mem(0,3,a,t,0)) return -1; if (free_tmp(t)) return -1; }
        else { return cg_die_name_at("cannot index non-array variable: ", tok); }
    }
    gia_ew=ty_width_t(gia_ety);
    if (emit_addsub_ext(i,a,i,0,2,log2w_t(gia_ew))) return -1;
    if (free_tmp(a)) return -1;
    return i;
}

/* ---- §6.3 function lowering ---- */
static int block_returns(int b){
    int k=NK(b);
    if (k==N_Block){
        int s=NF(b);
        while (s!=0){ if (block_returns(s)) return 1; s=NN(s); }
        return 0;
    }
    if (k==S_Return) return 1;
    if (k==S_If){
        int cond=NF(b), tb=NN(cond), el=NN(tb);
        int tr=0, er=0;
        if (tb!=0) tr=block_returns(tb);
        if (el!=0) er=block_returns(el);
        return tr && er;
    }
    return 0;
}
static int gen_function(int f){
    int name_tok=NT(f)+1, is_main=0;
    if (tok_eq_tok(name_tok,"main")==1) is_main=1;
    int body=0, bc=NF(f);
    while (bc!=0){ if (NK(bc)==N_Block){ body=bc; break; } bc=NN(bc); }
    if (block_returns(body)==0){
        cg_l=tok_line(name_tok); cg_c=tok_col(name_tok);
        die_open(); bputname(name_tok); bputs(" may fall through without returning ");
        if (is_ptr_tag_t(NTY(f))==1) bputs("ptr"); else bputs("i32");
        bputs("; add a return or make both if/else branches return");
        return die_close(cg_l,cg_c);
    }
    if (cg_reset_frame()) return 1;
    cg_ret_ty=NTY(f); cg_is_main=is_main; lp_depth=0;
    if (emit_addsub_imm(31,31,8192,1,1)) return 1;
    if (is_main==0){ if (emit_mem(1,3,30,31,1023*8)) return 1; }
    int i=0; int p=NF(f);
    while (p!=0){
        if (NK(p)==N_Param){
            int slot=cg_add_local(NT(p), NTY(p), 1); if (slot<0) return 1;
            if (i<8){ if (emit_mem(1, mem_scale_t(ty_width_t(NTY(p))), i, 31, slot*8)) return 1; }
            else { if (emit_mem(0,3,9,31,8192+8*(i-8))) return 1; if (emit_mem(1,3,9,31,slot*8)) return 1; }
            i++;
        }
        p=NN(p);
    }
    if (gen_block(body)) return 1;
    if (tmp_top!=0){ return cg_die("internal compiler error: temporary register leak"); }
    return 0;
}
static int gen_init(int prog){
    if (cg_reset_frame()) return 1;
    cg_ret_ty=1; cg_is_main=0; lp_depth=0;
    if (emit_addsub_imm(31,31,8192,1,1)) return 1;
    if (emit_mem(1,3,30,31,1023*8)) return 1;
    int c=NF(prog);
    while (c!=0){
        if (NK(c)==N_Global){
            int init=NF(c);
            if (init!=0 && is_const(init)==0){
                int s=cg_find_global(NT(c)); if (s<0) return cg_die("internal compiler error: global symbol mismatch");
                int v=gen_expr(init, st_tag[s]); if (v<0) return 1;
                int t=alloc_tmp(); if (t<0) return 1;
                if (emit_addr64(t, g_addr[s])) return 1;
                if (emit_mem(1, mem_scale_t(ty_width_t(st_tag[s])), v, t, 0)) return 1;
                if (free_tmp(t)) return 1;
                if (free_tmp(v)) return 1;
            }
        }
        c=NN(c);
    }
    if (emit_mem(0,3,30,31,1023*8)) return 1;
    if (emit_addsub_imm(31,31,8192,0,1)) return 1;
    if (emit_ret()) return 1;
    return 0;
}
/* ---- §6.3 the second pass (stub, __aster_init, main, the rest) ---- */
/* (fn_lab / main_sym / init_lab / has_stub / init_words / fn_words hoisted) */
static int symrow_of_name(int t){
    for (int s=0;s<nsym;s++) if (name_eq(st_name[s], t)==1) return s;
    return -1;
}
static int cg_gen_program(int prog){
    if (cg_init_pool()!=0) return 1;
    if (has_stub==1){
        if (emit_bl(init_lab)) return 1;
        if (emit_b(fn_lab[main_sym])) return 1;
        if (place_label(init_lab)) return 1;
        if (gen_init(prog)) return 1;
        init_words = textlen - labels[init_lab];
    }
    if (place_label(fn_lab[main_sym])) return 1;
    if (gen_function(st_node[main_sym])) return 1;
    fn_words[main_sym] = textlen - labels[fn_lab[main_sym]];
    int c=NF(prog);
    while (c!=0){
        if (NK(c)==N_Function){
            int fsym=symrow_of_name(NT(c)+1);
            if (fsym>=0 && st_kind[fsym]==0 && tok_eq_tok(NT(c)+1,"main")==0){
                if (place_label(fn_lab[fsym])) return 1;
                if (gen_function(st_node[fsym])) return 1;
                fn_words[fsym] = textlen - labels[fn_lab[fsym]];
            }
        }
        c=NN(c);
    }
    return 0;
}

/* ---- §9 address allocation (str_addr / g_addr / g_sec declared earlier) ---- */
static int rodata_size, data_size, bss_size;
static int64_t bss_base;
static int ninit, g_init[4096];
static int sstk[65536];
static int align_up(int64_t v,int a){ return (int)((v+a-1)/a*a); }

static int cg_strings(int root){
    int esp=0, h=NF(root);
    while (1){
        while (h!=0){
            if (NK(h)==E_String){
                int t=NT(h);
                str_addr[h] = 0x600000 + rodata_size;
                rodata_size = rodata_size + toks[t].len + 1;
            }
            int nx=NN(h);
            if (nx!=0){ sstk[esp]=nx; esp++; }
            h=NF(h);
        }
        if (esp==0) break;
        esp--; h=sstk[esp];
    }
    return 0;
}
static int cg_globals(int prog){
    int s=0;
    int c=NF(prog);
    while (c!=0){
        if (NK(c)==N_Global){
            while (s<nsym && name_eq(st_name[s], NT(c))==0) s=s+1;
            if (s>=nsym){ return cg_die("internal compiler error: global symbol mismatch"); }
            int init=NF(c);
            if (init!=0){
                int w=ty_width_t(st_tag[s]), total=w*st_cnt[s], sec=0;
                if (is_const(init)==1){
                    int64_t val=fold(init);
                    if (val!=0) sec=1;
                } else {
                    if (tc_expr(init)) return 1;
                    cg_l=tok_line(NT(c)); cg_c=tok_col(NT(c));
                    if (is_ptr_tag_t(st_tag[s])==0 && expr_yields_ptr(init)==1){
                        die_open(); bputs("type mismatch initializing global '"); bputname(NT(c));
                        bputs("': expected "); bputtybase(st_tag[s]); bputs(", got ptr");
                        return die_close(cg_l,cg_c);
                    }
                    if (assign_ok(st_tag[s], ETY(init), EAR(init), init)==0){
                        die_name_at("type mismatch assigning variable: ", NT(c)); return 1;
                    }
                    g_init[ninit]=s; ninit=ninit+1;
                }
                if (sec==1){
                    data_size = align_up(data_size, w);
                    g_addr[s] = 0x800000 + data_size;
                    g_sec[s]=1; data_size = data_size + total;
                } else {
                    bss_size = align_up(bss_size, w);
                    g_addr[s] = bss_size; g_sec[s]=0; bss_size = bss_size + total;
                }
            }
            s=s+1;
        }
        c=NN(c);
    }
    return 0;
}
static int cg_functions(void){
    int s=0;
    while (s<nsym){
        if (st_kind[s]==0){
            fn_lab[s]=new_label(); if (fn_lab[s]<0) return 1;
            if (tok_eq_tok(st_name[s],"main")==1) main_sym=s;
        }
        s=s+1;
    }
    if (ninit>0){ init_lab=new_label(); if (init_lab<0) return 1; has_stub=1; }
    if (main_sym<0){
        cg_l=1; cg_c=1;
        return cg_die("no main function: this backend emits a standalone ELF and needs an entry point");
    }
    return 0;
}
static int cg_collect(int prog){
    if (cg_strings(prog)) return 1;
    if (cg_globals(prog)) return 1;
    if (rodata_size>2097152) return cg_die(".rodata exceeds its 2 MiB window");
    if (data_size>1069547519 || bss_size>1069547519) return cg_die("global data exceeds the address space");
    bss_base = align_up(0x800000LL + data_size, 8);
    int s=0; while (s<nsym){ if (st_kind[s]==2 && g_sec[s]==0) g_addr[s]=g_addr[s]+bss_base; s++; }
    return cg_functions();
}

/* The bootstrap's exprYieldsPtr over the M3d subset (iterative). */
static int pstk[65536];
static int expr_yields_ptr(int h){
    int esp=0; pstk[0]=h; esp=1;
    while (esp>0){
        esp--; int n=pstk[esp], k=NK(n);
        if (k==E_String) return 1;
        if (k==E_Var){ if (sym_find_var(NT(n))==1 && rs_cnt>1) return 1; continue; }
        if (k==E_Call){
            if (sym_find_call(NT(n))==1){
                if (rs_fnsym==-1){ if (rcall_rtyp==4) return 1; }
                else if (is_ptr_tag_t(st_tag[rs_fnsym])==1) return 1;
            }
            continue;
        }
        if (k==E_Add||k==E_Sub){
            int l=NF(n);
            if (esp+2>65536){ cg_die("internal compiler error: walk stack overflow"); return 0; }
            pstk[esp]=NN(l); esp++; pstk[esp]=l; esp++;
            continue;
        }
    }
    return 0;
}

/* ---- §9.1/§9.2/§9.3 string & symbol tables ---- */
static unsigned char strtab[1048576]; static int strtab_len;
static unsigned char shstr[128]; static int shstr_len;
static int strtab_add(const unsigned char *p,int n){
    if (strtab_len+n+1>1048576) return cg_die(".strtab exceeds its 1 MiB window");
    int off=strtab_len, i=0;
    while (i<n){ strtab[strtab_len]=p[i]; strtab_len++; i++; }
    strtab[strtab_len]=0; strtab_len++;
    return off;
}
static int strtab_add_tok(int t){ return strtab_add(srcbuf + toks[t].start, toks[t].len); }
static int strtab_add_lit(const char *lit){
    int n=0; while (lit[n]) n++;
    return strtab_add((const unsigned char*)lit, n);
}
static int shstr_add(const char *lit){
    int n=0; while (lit[n]) n++;
    if (shstr_len+n+1>128) return cg_die(".shstrtab exceeds its window");
    int off=shstr_len, i=0;
    while (i<n){ shstr[shstr_len]=lit[i]; shstr_len++; i++; }
    shstr[shstr_len]=0; shstr_len++;
    return off;
}
static int sym_name[4160], sym_info[4160], sym_shndx[4160];
static int64_t sym_val[4160], sym_size[4160];
static int elf_nsym;
static int sym_add(int name_off,int info,int shndx,int64_t val,int64_t size){
    if (elf_nsym>=4160) return cg_die("too many symbols");
    sym_name[elf_nsym]=name_off; sym_info[elf_nsym]=info; sym_shndx[elf_nsym]=shndx;
    sym_val[elf_nsym]=val; sym_size[elf_nsym]=size; elf_nsym++;
    return 0;
}
static int sh_ro, sh_da, sh_bs, sh_sym, sh_str, sh_shstr;
static int elf_collect_syms(int prog){
    if (sym_add(0,0,0,0,0)) return 1;
    int start_size=fn_words[main_sym];
    if (has_stub==1) start_size=16;
    if (sym_add(strtab_add_lit("_start"), 0x12, 1, 0x401000LL, start_size)) return 1;
    if (has_stub==1){
        if (sym_add(strtab_add_lit("__aster_init"), 0x12, 1, 0x401000LL + (int64_t)labels[init_lab]*4, init_words)) return 1;
    }
    if (sym_add(strtab_add_tok(st_name[main_sym]), 0x12, 1, 0x401000LL + (int64_t)labels[fn_lab[main_sym]]*4, fn_words[main_sym])) return 1;
    int c=NF(prog);
    while (c!=0){
        if (NK(c)==N_Function){
            int fsym=symrow_of_name(NT(c)+1);
            if (fsym>=0 && st_kind[fsym]==0 && tok_eq_tok(NT(c)+1,"main")==0){
                if (sym_add(strtab_add_tok(st_name[fsym]), 0x12, 1, 0x401000LL + (int64_t)labels[fn_lab[fsym]]*4, fn_words[fsym])) return 1;
            }
        }
        c=NN(c);
    }
    int s=0; while (s<nsym){
        if (st_kind[s]==2){
            int shndx=sh_bs; if (g_sec[s]==1) shndx=sh_da;
            if (sym_add(strtab_add_tok(st_name[s]), 0x11, shndx, g_addr[s], (int64_t)st_cnt[s]*ty_width_t(st_tag[s]))) return 1;
        }
        s++;
    }
    return 0;
}
static int elf_written;
static int elf_pad_to(int target){
    while (elf_written<target){ putb(0); elf_written++; }
    return 0;
}
static int elf_shdr(int name,int ty,int64_t flags,int64_t addr,int64_t off,int64_t size,int link,int info,int64_t align,int64_t ent){
    elf_put32(name); elf_put32(ty); elf_put64(flags); elf_put64(addr);
    elf_put64(off); elf_put64(size); elf_put32(link); elf_put32(info);
    elf_put64(align); elf_put64(ent); elf_written=elf_written+64;
    return 0;
}
static int elf_emit(int prog){
    int i=0;
    while (i<nfix){
        int delta=labels[fx_label[i]] - fx_pos[i];
        if (fx_kind[i]==0){
            if (delta<-262144 || delta>262143) return cg_die("conditional branch out of range");
            textw[fx_pos[i]] = textw[fx_pos[i]] | ((delta & 0x7ffff) << 5) | fx_cond[i];
        } else {
            if (delta<-33554432 || delta>33554431) return cg_die("branch out of range");
            textw[fx_pos[i]] = textw[fx_pos[i]] | (delta & 0x3ffffff);
        }
        i++;
    }
    int textbytes=textlen*4;
    int nseg=1;
    if (rodata_size>0) nseg++;
    if (data_size+bss_size>0) nseg++;
    int nsh=2;
    if (rodata_size>0){ sh_ro=nsh; nsh++; }
    if (data_size>0){ sh_da=nsh; nsh++; }
    if (bss_size>0){ sh_bs=nsh; nsh++; }
    sh_sym=nsh; nsh++;
    sh_str=nsh; nsh++;
    sh_shstr=nsh; nsh++;
    strtab_len=0; strtab[0]=0; strtab_len=1;
    shstr_len=0; elf_nsym=0; shstr[0]=0; shstr_len=1;
    int nm_text=shstr_add(".text");
    int nm_ro=0, nm_da=0, nm_bs=0;
    if (rodata_size>0) nm_ro=shstr_add(".rodata");
    if (data_size>0) nm_da=shstr_add(".data");
    if (bss_size>0) nm_bs=shstr_add(".bss");
    int nm_sym=shstr_add(".symtab");
    int nm_str=shstr_add(".strtab");
    int nm_shstr=shstr_add(".shstrtab");   /* name offset for the .shstrtab section header */
    if (elf_collect_syms(prog)) return 1;
    int rodata_off=(0x1000+textbytes+4095)/4096*4096;
    int data_off=(rodata_off+rodata_size+4095)/4096*4096;
    int tail_base=0x1000+textbytes;
    if (rodata_size>0) tail_base=rodata_off+rodata_size;
    if (data_size>0) tail_base=data_off+data_size;
    int symtab_off=(tail_base+7)/8*8;
    int strtab_off=symtab_off+elf_nsym*24;
    int shstr_off=strtab_off+strtab_len;
    int shoff=(shstr_off+shstr_len+7)/8*8;
    elf_written=0;
    putb(0x7f); putb(69); putb(76); putb(70); putb(2); putb(1); putb(1); putb(0);
    int z=0; while (z<8){ putb(0); z++; }
    elf_put16(2); elf_put16(183); elf_put32(1);
    elf_put64(0x401000LL); elf_put64(64); elf_put64(shoff);
    elf_put32(0); elf_put16(64); elf_put16(56); elf_put16(nseg);
    elf_put16(64); elf_put16(nsh); elf_put16(sh_shstr);
    elf_put32(1); elf_put32(5);
    elf_put64(0); elf_put64(0x400000LL); elf_put64(0x400000LL);
    elf_put64(0x1000+textbytes); elf_put64(0x1000+textbytes); elf_put64(0x1000);
    if (rodata_size>0){
        elf_put32(1); elf_put32(4);
        elf_put64(rodata_off); elf_put64(0x600000LL); elf_put64(0x600000LL);
        elf_put64(rodata_size); elf_put64(rodata_size); elf_put64(0x1000);
    }
    if (data_size+bss_size>0){
        elf_put32(1); elf_put32(6);
        elf_put64(data_off); elf_put64(0x800000LL); elf_put64(0x800000LL);
        elf_put64(data_size); elf_put64(data_size+bss_size); elf_put64(0x1000);
    }
    elf_written = 64 + nseg*56;
    if (elf_pad_to(0x1000)) return 1;
    i=0; while (i<textlen){
        int v=textw[i];
        putb(v&0xff); putb((v>>8)&0xff); putb((v>>16)&0xff); putb((v>>24)&0xff);
        elf_written=elf_written+4; i++;
    }
        if (rodata_size>0){
            if (elf_pad_to(rodata_off)) return 1;
            int esp=0, h=NF(prog);
            while (1){
                while (h!=0){
                    if (NK(h)==E_String){
                        int t=NT(h);
                        putn(strpool + toks[t].start, toks[t].len); putb(0);
                        elf_written=elf_written+toks[t].len+1;
                    }
                    int nx=NN(h);
                    if (nx!=0){ sstk[esp]=nx; esp++; }
                    h=NF(h);
                }
            if (esp==0) break;
            esp--; h=sstk[esp];
        }
    }
    if (data_size>0){
        if (elf_pad_to(data_off)) return 1;
        int c=NF(prog);
        while (c!=0){
            if (NK(c)==N_Global){
                int s=cg_find_global(NT(c));
                if (s>=0 && g_sec[s]==1){
                    int target=data_off + (int)(g_addr[s] - 0x800000);
                    if (elf_pad_to(target)) return 1;
                    int64_t v=fold(NF(c));
                    int w2=ty_width_t(st_tag[s]), el=0;
                    while (el<st_cnt[s]){
                        int bi=0;
                        while (bi<w2){ putb((int)((v>>(8*bi))&0xff)); elf_written++; bi++; }
                        el++;
                    }
                }
            }
            c=NN(c);
        }
    }
    if (elf_pad_to(symtab_off)) return 1;
    i=0; while (i<elf_nsym){
        elf_put32(sym_name[i]); putb(sym_info[i]); putb(0); elf_put16(sym_shndx[i]);
        elf_put64(sym_val[i]); elf_put64(sym_size[i]); elf_written=elf_written+24; i++;
    }
    putn(strtab, strtab_len); elf_written=elf_written+strtab_len;
    putn(shstr, shstr_len); elf_written=elf_written+shstr_len;
    if (elf_pad_to(shoff)) return 1;
    elf_shdr(0,0,0,0,0,0,0,0,0,0);
    elf_shdr(nm_text,1,6,0x401000LL,0x1000,textbytes,0,0,4,0);
    if (rodata_size>0) elf_shdr(nm_ro,1,4,0x600000LL,rodata_off,rodata_size,0,0,1,0);
    if (data_size>0) elf_shdr(nm_da,1,3,0x800000LL,data_off,data_size,0,0,8,0);
    if (bss_size>0) elf_shdr(nm_bs,8,3,bss_base,data_off+data_size,bss_size,0,0,8,0);
    elf_shdr(nm_sym,2,0,0,symtab_off,(int64_t)elf_nsym*24,sh_str,1,8,24);
    elf_shdr(nm_str,3,0,0,strtab_off,strtab_len,0,0,1,0);
    elf_shdr(nm_shstr,3,0,0,shstr_off,shstr_len,0,0,1,0);
    return 0;
}
/* ------------------------------------------------------------------- driver */
/* §10 read; then sema; then the codegen chain cg_collect -> cg_gen_program ->
 * elf_emit -> flush_out, which emits a byte-identical ELF to the bootstrap
 * (CODEGEN-SPEC.md) on every accepted program. */
int main(void) {
    read_source();
    lex();
    int prog = parse_program();
    if (sema(prog) != 0) return 1;
    if (cg_collect(prog) != 0) return 1;
    if (cg_gen_program(prog) != 0) return 1;
    if (elf_emit(prog) != 0) return 1;
    flush_out();
    return 0;
}
