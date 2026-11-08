/* v0.23.75-dev F-07 C oracle for examples/signedness.ast.
 *
 * C's usual arithmetic conversions agree with Aster's promoteInt for every
 * pair exercised here: int64_t represents every uint32_t/uint16_t, so the
 * narrow unsigned operand is promoted to a signed 64-bit value and the
 * ordered comparisons and division are signed. gcc must return the same 63
 * as the Aster program; a host compiler that instead emitted LO/UDIV would
 * disagree. No -Wall: the mixed-sign comparisons are deliberate. */
#include <stdint.h>

int main(void) {
    int32_t r = 0;
    int64_t a = -84;
    uint32_t b = 5;
    uint16_t c = 84;
    int64_t d = -5;
    if (a < b)  r += 1;
    if (a <= b) r += 2;
    if (b > a)  r += 4;
    if (c > d)  r += 8;
    int64_t q = a / b;
    if (q == -16) r += 16;
    int64_t m = a % b;
    if (m == -4)  r += 32;
    return r;
}
