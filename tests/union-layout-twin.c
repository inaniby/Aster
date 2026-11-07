/* tests/union-layout-twin.c — the C oracle for examples/union_layout.ast.
 * Mirrors every operation the Aster program performs, in the same order and
 * with the same failure codes, so the two must agree on the exit status under
 * qemu. The union is spelled with the C equivalents of Aster's types:
 *   i32 -> int32_t, i64 -> int64_t, u8 -> uint8_t, char -> unsigned char
 * Compile + run:
 *   aarch64-linux-gnu-gcc -O2 -fwrapv -static union-layout-twin.c -o twin
 *   qemu-aarch64 twin
 * Expects exit 0. */
#include <stdint.h>

union U { int32_t w; int64_t q; uint8_t lo; unsigned char c; };
struct Box { int32_t tag; union U u; };

_Static_assert(sizeof(union U) == 8, "union U must be 8 bytes");
_Static_assert(sizeof(struct Box) == 16, "Box must be 16 bytes");

static union U make(int32_t v) { union U u = { .w = v }; return u; }
static union U id(union U u) { return u; }
static int32_t boxTag(struct Box b) { return b.tag + b.u.w; }

int main(void) {
    if (sizeof(union U) != 8) { return 11; }
    if (sizeof(struct Box) != 16) { return 12; }

    /* { 0x11223344 } initializes w (the first member); C zeroes the rest. */
    union U u = { 0x11223344 };
    if (u.q != 0x11223344) { return 1; }
    if ((int32_t)u.lo != 0x44) { return 2; }
    if ((int32_t)u.c != 0x44) { return 3; }

    /* Type punning: write q, read w and lo. */
    u.q = 0x1122334455667788LL;
    if (u.w != 0x55667788) { return 4; }
    if ((int32_t)u.lo != 0x88) { return 5; }

    struct Box b = { 7, { 9 } };
    if (b.tag != 7) { return 6; }
    if (b.u.w != 9) { return 7; }
    if (boxTag(b) != 16) { return 8; }

    union U t = id((union U){ 5 });
    if (t.w != 5) { return 9; }
    union U m = make(11);
    if (m.w != 11) { return 10; }
    return 0;
}
