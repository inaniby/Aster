/* tests/parser-twin.c — the C oracle for bootstrap/aster.ast's M3b parser.
 *
 * The same contract: bootstrap/PARSER-SPEC.md (frozen for v0.23.44-dev). The
 * Aster side reads one Aster source from stdin and writes the AST dump to
 * stdout, one node per line; this side does the same, byte for byte, with the
 * same diagnostics — the lexer's E1-E9, which still fire first, the host's
 * P1-P62, the subset's B1-B22 boundaries and the bootstrap's C1-C3 caps — and
 * the same exit statuses (0 clean, 1 error, stdout empty on error).
 * tests/parser-checks.sh runs the two over the same corpus and diffs.
 *
 * This is written from the specification, not transliterated from the Aster
 * source, and the two differ in shape wherever the spec leaves room:
 *
 *   - expressions parse by recursive descent — one function per precedence
 *     level of §6.1's grammar — where the bootstrap runs an explicit work
 *     stack with markers (§7). The two shapes meet in §6.1's tree: the same
 *     precedence, the same left-association, the same one-comparison-per-level
 *     rule, and the same position inheritance (§8, a binary node carries its
 *     left operand's token). The stack's marker discipline reappears here as
 *     the C1 depth counter, which is incremented around exactly the spans the
 *     bootstrap pushes a marker or a prefix for: a group, a call, a subscript
 *     and each unary prefix.
 *   - the AST is a struct array, not seven parallel i32 arrays, and its child
 *     chains link node indices (0-based, -1 = none) rather than handles
 *     (index + 1, 0 = none). One append serves every list, as there.
 *   - the dump recurses and streams through stdio, where the bootstrap walks
 *     an explicit stack into a 64 KiB buffer it flushes by hand. The dump has
 *     no size bound — a left-associative chain of the maximum token count
 *     indents quadratically, past a gigabyte — so neither side could stage it
 *     whole; stdio's own buffering is the twin's answer.
 *   - input goes through stdio (fread), not read(2);
 *   - character classes are the C locale's ctype macros, and the operator
 *     spellings dispatch through the grammar's levels instead of a precedence
 *     table;
 *   - number conversion runs the spec's own too-large checks (§6.2) and then
 *     strtoull — libc witnesses what the bootstrap's hand-rolled accumulator
 *     produces, which is the agreement §6.2 asks the twin's strtoull for;
 *   - the constant folder recurses, where the bootstrap walks an explicit
 *     stack: the deepest tree the caps allow is a left-associative chain, a
 *     few tens of thousands of frames here and the same walk with no frames
 *     there, and neither number is interesting on a host stack.
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
 *       -o parser-twin tests/parser-twin.c
 */
#include <ctype.h>
#include <limits.h>
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

/* ------------------------------------------------------------ the dump (§9) */
static const char *kind_name(int k) {
    if (k < 64) return EK_NAMES[k];
    if (k < 128) return SK_NAMES[k - 64];
    return NK_NAMES[k - 128];
}
static const char *ty_name(int t) { return TY_NAMES[t - 1]; }
static void put_name(int t) {
    fwrite(srcbuf + toks[t].start, 1, (size_t)toks[t].len, stdout);
}
/* The decoded value, re-escaped with exactly the six escapes of §9. */
static void put_escaped(int start, int n) {
    for (int i = 0; i < n; i++) {
        unsigned char b = strpool[start + i];
        switch (b) {
        case '"':  fputs("\\\"", stdout); break;
        case '\\': fputs("\\\\", stdout); break;
        case '\n': fputs("\\n", stdout); break;
        case '\r': fputs("\\r", stdout); break;
        case '\t': fputs("\\t", stdout); break;
        case '\0': fputs("\\0", stdout); break;
        default:   putchar(b);
        }
    }
}
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
static void emit_node(int h, int d) {
    for (int i = 0; i < d; i++) fputs("  ", stdout);
    int k = nodes[h].kind;
    fputs(kind_name(k), stdout);
    putchar(' ');
    int t = nodes[h].tok;
    printf("%d:%d", tok_line(t), tok_col(t));
    if (k == N_Function) {
        putchar(' ');
        put_name(t + 1);                /* the token after `fn` */
        putchar(' ');
        fputs(ty_name(nodes[h].ty), stdout);
        if (fn_extern(h)) fputs(" extern", stdout);
    } else if (k == N_Global) {
        putchar(' ');
        put_name(t);
        putchar(' ');
        fputs(ty_name(nodes[h].ty), stdout);
        printf(" %d", nodes[h].count);
        if (nodes[h].first < 0) fputs(" extern", stdout);
    } else if (k == N_Param || k == S_Let) {
        putchar(' ');
        put_name(t);
        putchar(' ');
        fputs(ty_name(nodes[h].ty), stdout);
    } else if (k == S_Assign || k == S_IndexAssign || k == E_Var
               || k == E_Call || k == E_Index) {
        putchar(' ');
        put_name(t);
    } else if (k == E_Num) {
        convert_num(t);
        printf(" %lld", (long long)numval);
    } else if (k == E_String) {
        putchar(' ');
        put_escaped(toks[t].start, toks[t].len);
    }
    putchar('\n');
}
static void emit(int h, int d) {
    emit_node(h, d);
    for (int c = nodes[h].first; c >= 0; c = nodes[c].next)
        emit(c, d + 1);
}

/* ------------------------------------------------------------------- driver */
/* Three phases (§10): stdin and the scanner, then the parse, then the dump —
 * and nothing reaches stdout unless the parse was clean, which holds here
 * because the dump is a later phase than every diagnostic. */
int main(void) {
    read_source();
    lex();
    int prog = parse_program();
    emit(prog, 0);
    return 0;
}
