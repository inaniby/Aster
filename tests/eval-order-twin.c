/*
 * tests/eval-order-twin.c — the C differential twin for eval-order-checks.sh.
 *
 * Every case is the C spelling of one Aster witness. In C the answer is the
 * language's own: an assignment's right-hand side and an element's subscript
 * are evaluated before the store's target address is used, a subscript reads
 * the element it names no matter where the index lives, a store through a
 * pointer writes the pointed-to object's own width, and a truth test of a
 * 64-bit value looks at all 64 bits. Aster v0.23.62-dev had four defects in
 * exactly these four places, so this twin is the outside authority for them.
 *
 * Usage: eval-order-twin <case>   — exits with the case's value.
 */
#include <stdint.h>
#include <string.h>

static int32_t g = 42;      /* the global read as a right-hand side */
static int32_t g7 = 7;      /* the global for the three-dimensional case */
static int32_t gi = 2;      /* the global used as a subscript */
static int64_t q = 0;       /* the object behind a ptr<i64> */

struct S { int32_t xs[4]; };

static int32_t f(void) { return 42; }
static int32_t fi(void) { return 2; }

int main(int argc, char **argv)
{
    const char *c = (argc > 1) ? argv[1] : "";

    /* --- a two-dimensional store: the right-hand side, per kind --- */
    if (!strcmp(c, "A2")) { int32_t m[2][3] = {{0}}; m[0][1] = g;   return m[0][1]; }
    if (!strcmp(c, "A3")) { int32_t m[2][3] = {{0}}; m[0][1] = f(); return m[0][1]; }
    if (!strcmp(c, "A6")) { int32_t m[2][2][2] = {{{0}}}; m[0][1][1] = g7; return m[0][1][1]; }

    /* --- a struct array field: the subscript, per kind --- */
    if (!strcmp(c, "B2")) { struct S s; s.xs[2] = 12; return s.xs[gi]; }
    if (!strcmp(c, "B5")) { struct S s; s.xs[gi] = 42; return s.xs[2]; }

    /* --- a store through a typed pointer: the object's own width --- */
    if (!strcmp(c, "C1")) { int64_t *p = &q; *p = -5;  return (q == -5) ? 1 : 0; }
    if (!strcmp(c, "C3")) { int64_t *p = &q; *p = 300; return (int32_t)q; }

    /* --- a truth test of a 64-bit value: all 64 bits --- */
    if (!strcmp(c, "D2")) { uint64_t a = 4294967296ULL; return a ? 1 : 0; }
    if (!strcmp(c, "D4")) { uint64_t a = 0;             return a ? 1 : 0; }

    return 99;   /* unknown case */
}
