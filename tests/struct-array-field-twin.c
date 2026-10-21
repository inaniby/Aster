// v0.23.29-dev: the C twin of examples/struct_array_field.ast.
//
// Aster's struct array field — `xs: T[N]` inside a struct — means what this
// file says it means: the element type is the field's declared type, and each
// element is a value of that type once indexed. Both programs exit 63.
//
// Built by tests/struct-array-field-checks.sh with aarch64-linux-gnu-gcc and
// run under qemu, alongside the Aster build of the same program.

#include <stdint.h>

struct Vec3 { int32_t a, b, c; };

struct Buffers {
    int32_t nums[4];
    int8_t  flags[3];
    void   *ptrs[4];
    struct Vec3 pts[2];
};

static struct Buffers gb;   /* zero-filled in .bss, like the Aster global */

int main(void) {
    int32_t r = 0;
    struct Buffers b;        /* local, zero-filled */
    struct Vec3 anchor = { 1, 2, 3 };

    /* (1) scalar element write/read */
    b.nums[0] = 11;
    b.nums[3] = 33;
    if (b.nums[3] == 33 && b.nums[0] == 11) r += 1;

    /* (2) bool element */
    b.flags[0] = 1;
    b.flags[2] = 1;
    if (b.flags[0] && b.flags[2] && !b.flags[1]) r += 2;

    /* (4) ptr element */
    b.ptrs[1] = &anchor;
    if (b.ptrs[1] == &anchor && b.ptrs[0] == 0) r += 4;

    /* (8) struct element field access (12-byte element) */
    b.pts[1].a = 100;
    b.pts[1].c = 200;
    if (b.pts[1].a == 100 && b.pts[1].c == 200 && b.pts[0].a == 0) r += 8;

    /* (16) address of a struct element */
    struct Vec3 *pp = &b.pts[1];
    if (pp == &b.pts[1] && (*pp).a == 100) r += 16;

    /* (32) a global struct with array fields */
    gb.nums[2] = 77;
    gb.pts[0].b = 55;
    if (gb.nums[2] == 77 && gb.pts[0].b == 55 && gb.flags[1] == 0) r += 32;

    return r;               /* 63 */
}
