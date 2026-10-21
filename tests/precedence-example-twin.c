// v0.23.27-dev: the C twin of examples/precedence.ast.
//
// This is the file that settles the four questions. Aster's reading of each
// expression below was checked against this one, compiled by gcc, and the two
// must now agree (exit 127). Where they disagreed, Aster moved — not C.
//
//   * `a || b && c`        -> `a || (b && c)`   (&& binds tighter)
//   * `*s.p`               -> `*(s.p)`          (prefix reaches the field)
//   * `-s.v` / `!s.ok`     -> `-(s.v)` / `!(s.ok)`
//   * `a < b == 1`         -> `(a < b) == 1`    (a level crossing, not a chain)
//
// Built by tests/precedence-checks.sh [4/9] with aarch64-linux-gnu-gcc and run
// under qemu, alongside the Aster build of the same program.

#include <stdint.h>

struct S { void *p; int32_t v; int32_t ok; };

static int32_t buf[4] = { 9, 9, 9, 9 };

int main(void) {
    int32_t r = 0;

    /* (1) && binds tighter than || */
    if (1 == 1 || 1 == 1 && 1 == 2) r += 1;

    struct S s;
    s.p = buf;
    s.v = 5;
    s.ok = 1;

    /* (2) *(s.p) */
    if (*(int32_t *)s.p == 9) r += 2;

    /* (2) -(s.v) */
    if (-s.v == 0 - 5) r += 4;

    /* (2) !(s.ok) */
    if (!s.ok) r += 100; else r += 8;

    /* (3) (a < b) == 1 */
    int32_t a = 1, b = 2;
    if ((a < b) == 1) r += 16;

    /* (4) a narrow local at the top of its range */
    uint8_t u = 255;
    if (u == 255) r += 32;

    uint8_t arr[2];
    arr[0] = 200; arr[1] = 200;
    if (arr[0] == 200) r += 64;

    return r;                       /* 127 */
}
