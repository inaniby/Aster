/* tests/aster-std-twin.c — the C oracle for stdlib/aster_std.ast.
 *
 * The same twelve routines, the same case set, the same output bytes as
 * examples/stdlib_demo.ast performs against the Aster library. This side is
 * written from the specification, not transliterated from the Aster source,
 * and the num family additionally checks itself against libc's snprintf
 * before any output happens — so a routine that is wrong on BOTH sides is a
 * coincidence, not a possibility the suite relies on.
 *
 * Built and run by tests/stdlib-checks.sh, which compares stdout bytes and
 * the exit status against the Aster driver. -fwrapv keeps the FNV multiply
 * wrapping the way the Aster i64 arithmetic does (same 64-bit pattern).
 */
#include <stdio.h>
#include <string.h>
#include <unistd.h>

/* ------------------------------------------------------------------ mem */
static int t_memcpy(unsigned char *dst, const unsigned char *src, int n) {
    for (int i = 0; i < n; i++) dst[i] = src[i];
    return n;
}
static int t_memset(unsigned char *dst, int c, int n) {
    for (int i = 0; i < n; i++) dst[i] = (unsigned char)c;   /* truncates */
    return n;
}
static int t_memcmp(const unsigned char *a, const unsigned char *b, int n) {
    for (int i = 0; i < n; i++) {
        int x = a[i], y = b[i];
        if (x != y) return x - y;                            /* unsigned */
    }
    return 0;
}

/* ------------------------------------------------------------------ str */
static int t_strlen(const unsigned char *s) {
    int i = 0;
    while (s[i] != 0) i++;
    return i;
}
static int t_strcmp(const unsigned char *a, const unsigned char *b) {
    int i = 0;
    for (;;) {
        int x = a[i], y = b[i];
        if (x != y) return x - y;
        if (x == 0) return 0;
        i++;
    }
}
static int t_strncpy(unsigned char *dst, const unsigned char *src, int n) {
    int i = 0;
    while (i < n) {
        unsigned char c = src[i];
        dst[i] = c;
        if (c == 0) break;
        i++;
    }
    int copied = i;                       /* source characters copied */
    while (i < n) { dst[i] = 0; i++; }
    return copied;                        /* min(strlen(src), n) */
}

/* ------------------------------------------------------------------ num */
static int t_reverse(unsigned char *buf, int i) {
    int j = 0, k = i - 1;
    while (j < k) {
        unsigned char t = buf[j];
        buf[j] = buf[k];
        buf[k] = t;
        j++; k--;
    }
    buf[i] = 0;
    return i;
}
static int t_utoa(long long v, unsigned char *buf) {         /* v >= 0 */
    if (v == 0) { buf[0] = '0'; buf[1] = 0; return 1; }
    int i = 0;
    while (v > 0) {
        buf[i++] = (unsigned char)('0' + (int)(v % 10));
        v /= 10;
    }
    return t_reverse(buf, i);
}
static int t_itoa(long long v, unsigned char *buf) {
    if (v < 0) {
        buf[0] = '-';
        return 1 + t_utoa(-v, buf + 1);   /* i64 most-negative: out of contract */
    }
    return t_utoa(v, buf);
}
static int t_utohex(long long v, unsigned char *buf) {
    if (v == 0) { buf[0] = '0'; buf[1] = 0; return 1; }
    int i = 0;
    while (v > 0) {
        int d = (int)(v % 16);
        buf[i++] = (unsigned char)(d > 9 ? 'a' + d - 10 : '0' + d);
        v /= 16;
    }
    return t_reverse(buf, i);
}

/* ------------------------------------------------------------------ hash */
static unsigned char *hkeys[1024];
static long long hvals[1024];

static unsigned long t_hash_str(const unsigned char *s) {    /* FNV-1a 64 */
    unsigned long h = 0xcbf29ce484222325UL;
    while (*s) {
        h = (h ^ (unsigned long)*s) * 0x100000001b3UL;
        s++;
    }
    return h;
}
static int t_hash_put(const unsigned char *key, long long val) {
    int i = (int)(t_hash_str(key) & 1023);
    int probes = 0;
    while (probes < 1024) {
        if (hkeys[i] == 0) {
            hkeys[i] = (unsigned char *)key;
            hvals[i] = val;
            return i;
        }
        if (t_strcmp(hkeys[i], key) == 0) {
            hvals[i] = val;
            return i;
        }
        i = (i + 1) % 1024;
        probes++;
    }
    return -1;
}
static long long t_hash_get(const unsigned char *key) {
    int i = (int)(t_hash_str(key) & 1023);
    int probes = 0;
    while (probes < 1024) {
        if (hkeys[i] == 0) return -1;
        if (t_strcmp(hkeys[i], key) == 0) return hvals[i];
        i = (i + 1) % 1024;
        probes++;
    }
    return -1;
}

/* --------------------------------------------------------------- helpers */
static unsigned char ob[32];

static void out_s(const char *s) { fputs(s, stdout); }
static void out_i(long long v) {
    int n = t_itoa(v, ob);
    fwrite(ob, 1, (size_t)n, stdout);
}
static void out_sp(void) { putchar(' '); }
static void out_nl(void) { putchar('\n'); }

/* The dump the strncpy cases share with the Aster driver: eight bytes, a NUL
 * shown as '.', no separators. */
static void dump8(const unsigned char *b) {
    for (int i = 0; i < 8; i++) putchar(b[i] ? b[i] : '.');
}

int main(void) {
    unsigned char a[16], b[16], pad[8];

    /* ---- mem ---- */
    for (int i = 0; i < 12; i++) a[i] = (unsigned char)(i * 7 + 3);
    t_memcpy(b, a, 12);
    int sum = 0;
    for (int i = 0; i < 12; i++) sum += b[i];
    out_s("MC "); out_i(sum); out_sp(); out_i(t_memcpy(b, a, 12)); out_nl();

    t_memset(b, 0xA5, 10);
    sum = 0;
    for (int i = 0; i < 10; i++) sum += b[i];
    out_s("MS "); out_i(sum); out_sp(); out_i(10); out_nl();

    t_memset(b, 300, 1);               /* 300 & 0xFF == 44 */
    out_s("MT "); out_i(b[0]); out_nl();

    /* A string literal is char* in C but the Aster parameter is ptr<u8>
       (bytes), so the twin casts: the unsigned comparison below is the
       behaviour under test, and the cast says so at every call. */
    out_s("ME "); out_i(t_memcmp((const unsigned char *)"abc", (const unsigned char *)"abc", 3)); out_nl();
    out_s("ML "); out_i(t_memcmp((const unsigned char *)"abc", (const unsigned char *)"abd", 3)); out_nl();
    {
        unsigned char hi[2] = {0x80, 0x00}, lo[2] = {0x7F, 0x00};
        out_s("MH "); out_i(t_memcmp(hi, lo, 1)); out_nl();   /* unsigned: 1 */
    }
    out_s("MN "); out_i(t_memcmp((const unsigned char *)"abc", (const unsigned char *)"abd", 0)); out_nl();

    /* ---- str ---- */
    out_s("SL "); out_i(t_strlen((const unsigned char *)"aster stdlib"));
    out_sp(); out_i(t_strlen((const unsigned char *)"")); out_nl();
    out_s("SC "); out_i(t_strcmp((const unsigned char *)"same",
                                 (const unsigned char *)"same"));
    out_sp(); out_i(t_strcmp((const unsigned char *)"abc",
                             (const unsigned char *)"abd"));
    out_sp(); out_i(t_strcmp((const unsigned char *)"abc",
                             (const unsigned char *)"abcd")); out_nl();

    for (int i = 0; i < 8; i++) pad[i] = '?';
    {
        int n = t_strncpy(pad, (const unsigned char *)"abcdefgh", 4);
        out_s("NC "); out_i(n); out_sp(); dump8(pad); out_nl();
    }
    for (int i = 0; i < 8; i++) pad[i] = '?';
    {
        int n = t_strncpy(pad, (const unsigned char *)"ab", 8);
        out_s("NP "); out_i(n); out_sp(); dump8(pad); out_nl();
    }
    for (int i = 0; i < 8; i++) pad[i] = '?';
    {
        int n = t_strncpy(pad, (const unsigned char *)"abcdefgh", 0);
        out_s("N0 "); out_i(n); out_sp(); dump8(pad); out_nl();
    }

    /* ---- num: the twin checks its own hand-written converters against
     * snprintf before printing anything, so the printed digits below are
     * witnessed twice. ---- */
    {
        char ref[32], got[32];
        long long vs[] = {0, 1, 42, 123456789012345LL};
        for (unsigned k = 0; k < sizeof vs / sizeof vs[0]; k++) {
            int n = t_utoa(vs[k], (unsigned char *)got);
            got[n] = 0;
            snprintf(ref, sizeof ref, "%lld", vs[k]);
            if (strcmp(ref, got) != 0) {
                printf("twin-internal: utoa(%lld) = %s, snprintf says %s\n",
                       vs[k], got, ref);
                return 1;
            }
        }
        long long si[] = {0, -1, 9223372036854775807LL, -9223372036854775807LL};
        for (unsigned k = 0; k < sizeof si / sizeof si[0]; k++) {
            int n = t_itoa(si[k], (unsigned char *)got);
            got[n] = 0;
            snprintf(ref, sizeof ref, "%lld", si[k]);
            if (strcmp(ref, got) != 0) {
                printf("twin-internal: itoa(%lld) = %s, snprintf says %s\n",
                       si[k], got, ref);
                return 1;
            }
        }
        long long hs[] = {0, 255, 4096, 3735928559LL};        /* 0xdeadbeef */
        for (unsigned k = 0; k < sizeof hs / sizeof hs[0]; k++) {
            int n = t_utohex(hs[k], (unsigned char *)got);
            got[n] = 0;
            snprintf(ref, sizeof ref, "%llx", (unsigned long long)hs[k]);
            if (strcmp(ref, got) != 0) {
                printf("twin-internal: utohex(%llx) = %s, snprintf says %s\n",
                       (unsigned long long)hs[k], got, ref);
                return 1;
            }
        }
    }
    out_s("U0 "); out_i(0); out_nl();
    out_s("U1 "); out_i(1); out_nl();
    out_s("U2 "); out_i(42); out_nl();
    out_s("U3 ");
    {
        long long v = 123456789012345LL;
        int n = t_utoa(v, ob);
        fwrite(ob, 1, (size_t)n, stdout);
        out_nl();
    }
    out_s("I0 "); out_i(0); out_nl();
    out_s("I1 "); out_i(-1); out_nl();
    out_s("I2 ");
    {
        long long v = 9223372036854775807LL;
        int n = t_itoa(v, ob);
        fwrite(ob, 1, (size_t)n, stdout);
        out_nl();
    }
    out_s("I3 ");
    {
        long long v = -9223372036854775807LL;
        int n = t_itoa(v, ob);
        fwrite(ob, 1, (size_t)n, stdout);
        out_nl();
    }
    out_s("H0 "); out_i(0); out_nl();
    out_s("H1 "); { int n = t_utohex(255, ob); fwrite(ob, 1, (size_t)n, stdout); } out_nl();
    out_s("H2 "); { int n = t_utohex(4096, ob); fwrite(ob, 1, (size_t)n, stdout); } out_nl();
    out_s("H3 "); { int n = t_utohex(3735928559LL, ob); fwrite(ob, 1, (size_t)n, stdout); } out_nl();

    /* ---- hash ---- */
    out_s("HS ");
    out_i(t_hash_put((const unsigned char *)"alpha", 1)); out_sp();
    out_i(t_hash_put((const unsigned char *)"beta", 2)); out_sp();
    out_i(t_hash_put((const unsigned char *)"gamma", 3)); out_nl();
    out_s("HG ");
    out_i(t_hash_get((const unsigned char *)"alpha")); out_sp();
    out_i(t_hash_get((const unsigned char *)"beta")); out_sp();
    out_i(t_hash_get((const unsigned char *)"gamma")); out_nl();
    out_s("HU ");
    out_i(t_hash_put((const unsigned char *)"beta", 99)); out_sp();
    out_i(t_hash_get((const unsigned char *)"beta")); out_nl();
    out_s("HX "); out_i(t_hash_get((const unsigned char *)"delta")); out_nl();

    return 0;
}
