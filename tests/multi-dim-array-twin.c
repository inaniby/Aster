/* The C twin of examples/multi_dim_array.ast — v0.23.31-dev.
 *
 * Aster's `a[i]` on an `i32[2][3]` is a row — the address of the row's first
 * element — exactly as in C, where `a[i]` on an `int[2][3]` decays to
 * `&a[i][0]`. The outer subscript strides by the inner length times the
 * element size, and the innermost one by the element size alone, which is the
 * one stride a one-dimensional array has always had. A row therefore travels
 * to a function as the pointer it is, in both languages.
 *
 * Compile with the target C compiler and compare the exit status — no
 * expectation in this file is hand-computed. */
#include <stdint.h>

struct Grid { int32_t cells[2][3]; };

static int32_t gscores[2][3];

static int32_t rowSum(int32_t *p, int32_t n) {
    int32_t t = 0;
    for (int32_t i = 0; i < n; i++) t += p[i];
    return t;
}

int main(void) {
    int32_t r = 0;

    int32_t a[2][3];
    for (int32_t i = 0; i < 2; i++)
        for (int32_t j = 0; j < 3; j++)
            a[i][j] = i * 3 + j + 1;
    if (a[0][0] == 1 && a[0][2] == 3 && a[1][0] == 4 && a[1][2] == 6) r += 1;
    if (rowSum(a[0], 3) == 6 && rowSum(a[1], 3) == 15) r += 2;

    for (int32_t gi = 0; gi < 2; gi++)
        for (int32_t gj = 0; gj < 3; gj++)
            gscores[gi][gj] = (gi + 1) * 10 + gj;
    if (gscores[0][1] == 11 && gscores[1][2] == 22) r += 4;

    int32_t c[2][2][2];
    c[0][0][0] = 1; c[0][0][1] = 2; c[0][1][0] = 3; c[0][1][1] = 4;
    c[1][0][0] = 5; c[1][0][1] = 6; c[1][1][0] = 7; c[1][1][1] = 8;
    if (c[1][1][1] == 8 && c[0][1][0] == 3) r += 8;
    if (rowSum(c[1][0], 2) == 11) r += 16;

    struct Grid g;
    for (int32_t ei = 0; ei < 2; ei++)
        for (int32_t ej = 0; ej < 3; ej++)
            g.cells[ei][ej] = ei * 3 + ej + 1;
    if (g.cells[0][1] == 2 && g.cells[1][2] == 6) r += 32;

    int64_t w[2][3];
    w[0][0] = 100; w[0][1] = 200; w[0][2] = 300;
    w[1][0] = 400; w[1][1] = 500; w[1][2] = 600;
    if (w[1][2] == 600 && w[0][0] == 100) r += 64;

    uint8_t n[2][3];
    n[0][0] = 1; n[0][1] = 2; n[0][2] = 3;
    n[1][0] = 4; n[1][1] = 5; n[1][2] = 6;
    if (n[1][1] == 5 && n[0][2] == 3) r += 128;

    return r;
}
