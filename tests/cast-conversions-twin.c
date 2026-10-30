// The C twin of examples/cast-conversions.ast. Every group mirrors one witness
// of the Aster example; the two must return the same 255 through C's own
// conversion rules, which is what the cast implements. Compiled by the target
// C compiler (aarch64-linux-gnu-gcc) and run under qemu, exactly as the Aster
// output is.
#include <stdint.h>
#include <stdbool.h>

struct Point { int32_t x; int32_t y; };

int main(void) {
    int32_t r = 0;

    // g1: bool -> integer
    _Bool t = 1, f = 0;
    if ((int32_t)t == 1 && (int32_t)f == 0) { r += 1; }

    // g2: bool -> wider integer
    if ((uint64_t)t == 1 && (uint64_t)f == 0) { r += 2; }

    // g3: integer -> bool, nonzero is truthy
    if ((_Bool)7) { r += 4; }

    // g4: integer -> bool, zero is false
    if ((_Bool)0) { } else { r += 8; }

    // g5: integer -> ptr -> integer
    if ((int64_t)(void *)0x10 == 0x10) { r += 16; }

    // g6: ptr -> i32 takes the low 32 bits
    if ((int32_t)(void *)0x20 == 0x20) { r += 32; }

    // g7: ptr<S> -> ptr<U> is a pure reinterpretation
    struct Point pt; pt.x = 9; pt.y = 8;
    struct Point *pp = &pt;
    int32_t *ppa = (int32_t *)pp;
    if (*ppa == 9) { r += 64; }

    // g8: a typed pointer and an untyped one agree on the address
    void *u = (void *)0x40;
    int32_t *ut = (int32_t *)u;
    if ((int32_t)ut == 0x40) { r += 128; }

    return r;
}
