/* tests/aster-std-str-twin.c — the C twin of tests/stdlib-str-demo.ast.
 * strtoll/strtod/snprintf stand in for the library's parsers and writers, and
 * the summary line must come out byte for byte the same. */
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(void) {
    int ok = 0;
    char b[64];

    /* 1. i64 decimal, including the one magnitude that does not fit */
    long long minv = LLONG_MIN;
    if (snprintf(b, sizeof b, "%lld", minv) == 20) ok++;
    int minlen = (int)strlen(b);
    if (snprintf(b, sizeof b, "%lld", 1234567890123LL) == 13) ok++;
    if (snprintf(b, sizeof b, "%lld", 0LL) == 1) ok++;
    if (snprintf(b, sizeof b, "%lld", -5LL) == 2) ok++;

    /* 2. sixteen hex digits */
    if (snprintf(b, sizeof b, "%016llx", (unsigned long long)-1LL) == 16) ok++;
    int hexfirst = (unsigned char)b[0];
    if (snprintf(b, sizeof b, "%016llx", 0x0102030405060708ULL) == 16) ok++;
    if ((unsigned char)b[15] == '8') ok++;

    /* 3. the integer parser (0b has no C99 strtoll spelling, so the twin
     *    strips the prefix and asks for base 2) */
    const char *s = NULL;
    char *end = NULL;
    long long v = 0;
    s = "42"; v = strtoll(s, &end, 0);
    if (end - s == 2 && v == 42) ok++;
    s = "  -17"; v = strtoll(s, &end, 0);
    if (end - s == 5 && v == -17) ok++;
    s = "0x1f"; v = strtoll(s, &end, 0);
    if (end - s == 4 && v == 31) ok++;
    int parse_val = (int)v;
    s = "0b1011"; v = strtoll(s + 2, &end, 2);
    if (end - (s + 2) == 4 && v == 11) ok++;
    s = "777"; v = strtoll(s, &end, 8);
    if (end - s == 3 && v == 511) ok++;
    s = "zz"; v = strtoll(s, &end, 36);
    if (end - s == 2 && v == 1295) ok++;
    s = "12abc"; v = strtoll(s, &end, 10);
    if (end - s == 2 && v == 12) ok++;
    s = "abc"; v = strtoll(s, &end, 10);
    if (end == s) ok++;

    /* 4. the double parser */
    s = "1.5"; double f = strtod(s, &end);
    if (end - s == 3) ok++;
    if ((int)(f * 10.0) == 15) ok++;
    s = "-2.5e-3"; f = strtod(s, &end);
    if (end - s == 7) ok++;
    int atof_val = (int)(f * 1000.0);
    s = "3.25e2"; f = strtod(s, &end);
    if (end - s == 6) ok++;
    s = "junk"; f = strtod(s, &end);
    if (end == s) ok++;

    /* 5. the string helpers */
    char t[16];
    memcpy(t, "  hi  ", 6);
    char *trimmed = t;
    while (*trimmed == ' ') trimmed++;
    int trimlen = (int)strlen(trimmed);
    while (trimlen > 0 && trimmed[trimlen - 1] == ' ') trimlen--;
    trimmed[trimlen] = 0;
    if (trimlen == 2) ok++;
    if (strncmp(trimmed, "hi", 2) == 0) ok++;          /* starts_with */
    if (strcmp(trimmed, "hi") == 0) ok++;              /* ends_with   */
    if (strcmp(trimmed, "hi") == 0) ok++;              /* streq       */
    if (strncmp(trimmed, "ho", 2) != 0) ok++;          /* starts_with miss */

    /* 6. line iteration over CRLF */
    char text[64];
    memcpy(text, "one\r\ntwo\nthree", 15);
    int lines = 0, first = 0;
    char *ln = text;
    while (ln != NULL) {
        char *nl = strchr(ln, '\n');
        if (nl != NULL) *nl = 0;
        int n = (int)strlen(ln);
        if (n > 0 && ln[n - 1] == '\r') { ln[n - 1] = 0; n--; }
        if (lines == 0) first = n;
        lines++;
        if (nl == NULL) break;
        ln = nl + 1;
    }
    if (lines == 3) ok++;
    if (first == 3) ok++;

    /* 7. a copy (the arena's str_dup) */
    char *dup = strdup("copy");
    if (dup != NULL && strcmp(dup, "copy") == 0) ok++;

    printf("%d|%d|%d|%d|%d|%d|%d\n", ok, minlen, hexfirst, parse_val, atof_val, lines, trimlen);
    return ok == 28 ? 0 : 1;
}
