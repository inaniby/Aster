/*
 * tests/type-strictness-twin.c — the C differential twin for
 * type-strictness-checks.sh.
 *
 * The five cases are the C spelling of the programs Aster v0.23.63-dev fixed
 * on the *accepting* side: they are the programs that must still compile and
 * must still answer what C answers. The round's other half is a set of
 * refusals, and a refusal has no C counterpart to differ against — C accepts
 * an implicit narrowing with a warning — so this twin pins the half where an
 * outside authority exists, and the rejection matrix inside the suite pins the
 * other half against the compiler itself.
 *
 * Usage: type-strictness-twin <case>   — exits with the case's value.
 */
#include <stdint.h>
#include <string.h>

enum Color { R, G };

static int64_t gq = 0;      /* the object behind a ptr<i64> */

int main(int argc, char **argv)
{
    const char *c = (argc > 1) ? argv[1] : "";

    /* S1: a wide integer reaches a shift — the program that used to abort the
       compiler with "TypedIR MISMATCH kind=25" (kind 25 is Shl). */
    if (!strcmp(c, "S1")) { int64_t a = 1, b = 2; int64_t v = (a + b) << 2; return (int)v; }

    /* S2: the same, one width narrower, and through a right shift. */
    if (!strcmp(c, "S2")) { uint8_t a = 40, b = 40; int32_t v = (a + b) >> 1; return (int)v; }

    /* S3: a bitwise-not of a wide sum — the third node the exemption missed. */
    if (!strcmp(c, "S3")) { int64_t a = 1, b = 2; int64_t v = ~(a + b); return (int)(v & 0xff); }

    /* S4: two enumerators of the same enum compare — still legal, and true. */
    if (!strcmp(c, "S4")) { enum Color c1 = R; return (c1 == R) ? 1 : 0; }

    /* S5: an enum against an i32 — the underlying storage is i32, so this is
       the comparison an enum keeps. */
    if (!strcmp(c, "S5")) { enum Color c1 = G; return (c1 == 1) ? 1 : 0; }

    /* S6: the truncation the round refuses to do implicitly, asked for
       explicitly — the program the new diagnostic tells you to write. */
    if (!strcmp(c, "S6")) { int64_t x = 300; return (int)(uint8_t)x; }

    /* S7: an arithmetic result returned into its own width — the program that
       a naive narrowing check would have broken. */
    if (!strcmp(c, "S7")) { uint8_t a = 200, b = 55; return (int)(uint8_t)(a + b); }

    /* S8: a u8 element filled from arithmetic, unchanged. */
    if (!strcmp(c, "S8")) { uint8_t a[4] = {0}; int32_t i = 1; a[i] = i * 7 + 3; return (int)a[1]; }

    /* S9: a store through a ptr<i64>, the width rule this round left alone. */
    if (!strcmp(c, "S9")) { int64_t *p = &gq; *p = -5; return (gq == -5) ? 1 : 0; }

    return 99;   /* unknown case */
}
