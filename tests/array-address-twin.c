/* The C twin of examples/array_address.ast — v0.23.30-dev.
 *
 * Aster's `&buf` on a `T[N]` is the address of the array's first element, so
 * the faithful C spelling of it is `&buf[0]` (C's own `&buf` would be a
 * pointer to the whole array). Everything else is written the same way in both
 * languages: `p[i]` on an int32_t* is `*(p + i*4)`, which is exactly the
 * stride Aster's `ptr` indexing uses.
 *
 * Compile with the target C compiler and compare the exit status — no
 * expectation in this file is hand-computed. */
#include <stdint.h>

struct Row { int32_t cells[4]; };

static int32_t gscores[4] = { 11, 11, 11, 11 };

static int32_t sum4(int32_t *p) {
    int32_t t = 0;
    for (int32_t i = 0; i < 4; i++) t += p[i];
    return t;
}

static int32_t fill(int32_t *p, int32_t v) {
    for (int32_t i = 0; i < 4; i++) p[i] = v;
    return p[0];
}

static int32_t countFlags(int32_t *p) {
    int32_t n = 0;
    if (p[0] != 0) n++;
    if (p[1] != 0) n++;
    if (p[2] != 0) n++;
    return n;
}

static int32_t rowSum(struct Row *pr) {
    int32_t *p = &pr->cells[0];
    return sum4(p);
}

int main(void) {
    int32_t buf[4] = { 7, 7, 7, 7 };
    int32_t flags[3] = { 1, 1, 1 };
    struct Row row;
    int32_t r = 0;
    row.cells[0] = 1; row.cells[1] = 2; row.cells[2] = 3; row.cells[3] = 4;
    if (sum4(&buf[0]) == 28) r += 1;
    if (fill(&buf[0], 5) == 5 && buf[3] == 5) r += 2;
    if (sum4(&gscores[0]) == 44) r += 4;
    if (countFlags(&flags[0]) == 3) r += 8;
    if (rowSum(&row) == 10) r += 16;
    {
        int32_t *p = &buf[0];
        if (p[0] == 5 && p[3] == 5) r += 32;
    }
    return r;
}
