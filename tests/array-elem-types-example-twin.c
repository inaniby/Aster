// v0.23.28-dev: the C twin of examples/array_elem_types.ast.
//
// Aster's `T[N]` now means what this file says it means: the element type is
// the type written before the `[N]`, for a bool, a struct and a pointer as
// much as for an integer. Both programs compile to exit 127.
//
// Built by tests/array-elem-types-checks.sh with aarch64-linux-gnu-gcc and
// run under qemu, alongside the Aster build of the same program.

#include <stdint.h>

struct Point { int32_t x, y; };
struct Triple { int32_t a, b, c; };

/* Aster fills every element of an array with the initializer, where C's
   `= { … }` fills the first and zeroes the rest — so the twin spells the fill
   out. What is being compared is the element type and the addressing, not
   the initializer syntax. */
static int32_t flags[4] = { 1, 1, 1, 1 };
static struct Point pts[3] = { { 7, 8 }, { 7, 8 }, { 7, 8 } };
static struct Triple tri[2] = { { 1, 2, 3 }, { 1, 2, 3 } };
static struct Point cell = { 42, 43 };

int main(void) {
    int32_t r = 0;

    /* (1) a global bool[4] */
    if (flags[2]) r += 1;

    /* (2) a local bool[3], then an element store */
    int32_t seen[3] = { 0, 0, 0 };
    seen[1] = 1;
    if (seen[1] && !seen[0]) r += 2;

    /* (4) a local ptr[3] */
    void *slots[3] = { 0, 0, 0 };
    slots[1] = &cell;
    if (slots[0] == 0 && slots[1] == &cell) r += 4;

    /* (8) a global Point[3] */
    if (pts[2].x == 7 && pts[2].y == 8) r += 8;

    /* (16) a local Point[3], written through a subscript's field */
    struct Point local_pts[3] = { { 0, 0 }, { 0, 0 }, { 0, 0 } };
    local_pts[2].x = 9;
    if (local_pts[2].x == 9 && local_pts[0].x == 0) r += 16;

    /* (32) a 12-byte element, in both scopes */
    struct Triple local_tri[3] = { { 1, 2, 3 }, { 1, 2, 3 }, { 1, 2, 3 } };
    if (tri[1].c == 3 && local_tri[2].b == 2) r += 32;

    /* (64) &a[i] and a whole-element copy */
    struct Point *p = &local_pts[1];
    struct Point q = local_pts[1];
    if (p == &local_pts[1] && q.y == 0) r += 64;

    return r;                       /* 127 */
}
