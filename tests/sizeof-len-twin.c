// The C twin of examples/sizeof_len.ast. It returns the same exit code (511)
// by measuring storage the way C has always been able to: with the native
// sizeof on real array *types* and locals. Two deliberate notes:
//
//   * An array parameter decays to a pointer in C, so `sizeof(a)` on one would
//     be 8, not the 16 Aster reports for the array the caller passed. The twin
//     therefore measures a real `int32_t[4]` type, which is the storage Aster
//     is describing — the same number, reached without the decay.
//   * `len` is the *total* element count, so the twin divides by the element
//     size (`sizeof(arr)/sizeof(int32_t)`), never by a row (`sizeof(arr)/
//     sizeof(arr[0])`), which would count rows for a multi-dimensional array.
#include <stdint.h>
struct Row { int32_t cells[4]; };
static int32_t ggrid[3][4];

static int32_t paramBytes(int32_t a[4]) { (void)a; return (int32_t)sizeof(int32_t[4]); }
static int32_t paramCount(int32_t a[4]) { (void)a; return (int32_t)(sizeof(int32_t[4]) / sizeof(int32_t)); }
static int32_t gridBytes(int64_t a[2][3]) { (void)a; return (int32_t)sizeof(int64_t[2][3]); }
static int32_t gridCount(int64_t a[2][3]) { (void)a; return (int32_t)(sizeof(int64_t[2][3]) / sizeof(int64_t)); }

int main(void) {
    int32_t r = 0;

    // 1: the type spelling.
    if (sizeof(int32_t) == 4 && sizeof(int64_t) == 8 && sizeof(int32_t[4]) == 16) r += 1;
    if ((int32_t)(sizeof(int32_t[4]) / sizeof(int32_t)) == 4
        && (int32_t)(sizeof(int64_t[2][3]) / sizeof(int64_t)) == 6
        && sizeof(int64_t[2][3]) == 48) r += 2;

    // 2: the expression spelling on a local.
    int32_t w[4] = {0};
    int64_t g[2][3] = {{0}};
    if (sizeof(w) == 16 && (int32_t)(sizeof(w) / sizeof(int32_t)) == 4) r += 4;
    if (sizeof(g) == 48 && (int32_t)(sizeof(g) / sizeof(int64_t)) == 6) r += 8;

    // 3: an array parameter — measured as a real array type (see the note).
    if (paramBytes(w) == 16 && paramCount(w) == 4) r += 16;
    if (gridBytes(g) == 48 && gridCount(g) == 6) r += 32;

    // 4: a global array, both spellings.
    if (sizeof(ggrid) == 48 && (int32_t)(sizeof(ggrid) / sizeof(int32_t)) == 12) r += 64;

    // 5: a struct's own size, and its array field's, in one check.
    struct Row row = {{0}};
    if (sizeof(struct Row) == 16 && sizeof(row) == 16
        && sizeof(row.cells) == 16 && (int32_t)(sizeof(row.cells) / sizeof(int32_t)) == 4) r += 128;

    return r;   // 255
}
