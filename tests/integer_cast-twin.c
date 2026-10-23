// The C twin of examples/integer_cast.ast. It returns the same exit code
// (255) by computing the same witnesses through C's own integer conversion
// rules, which are the rules the Aster cast implements:
//
//   * a conversion to an unsigned type is modulo 2^N — `(uint8_t)300` is 44,
//     `(uint16_t)70000` is 4464, `(uint32_t)(0-1)` is 4294967295;
//   * a conversion to a signed type out of range is implementation-defined,
//     and every compiler here wraps — `(int32_t)(int64_t)-1` is -1;
//   * the u64 literals (2^64-1, 2^63, 12345678901234567890) are spelled with
//     the ull suffix, and the division is unsigned.
//
// The eight groups each carry exactly one bit of the answer, mirroring the
// Aster example bit for bit, so a missing bit names the same group on both
// sides.
#include <stdint.h>

struct Box { uint16_t lo; uint64_t hi; };

static uint64_t gwide = 12345678901234567890ull;   /* beyond int64: only a u64 holds it */

static uint8_t narrow8(int32_t v) { return (uint8_t)v; }
static uint64_t widen64(int32_t v) { return (uint64_t)v; }
static uint64_t passthru(uint64_t v) { return v; }

int main(void) {
    int32_t r = 0;
    uint64_t top = 18446744073709551615ull;         // 2^64 - 1
    uint64_t bit63 = 9223372036854775808ull;        // 2^63: negative as an int64, fine here
    int64_t neg = 0 - 1;
    uint64_t m = 1;
    struct Box b;
    b.lo = (uint16_t)70000;
    b.hi = (uint64_t)(0 - 1);
    uint64_t xs[2] = {0, 0};
    xs[0] = bit63;
    xs[1] = top;

    // 1: the type itself — 8 bytes, and the two literals only it can hold.
    if (sizeof(uint64_t) == 8 && top == 18446744073709551615ull && bit63 == 9223372036854775808ull) r += 1;

    // 2: narrowing — each width's witness, hand-derived.
    if ((uint8_t)300 == 44 && (uint16_t)70000 == 4464 && (uint32_t)(0 - 1) == 4294967295u
        && (uint8_t)(0 - 1) == 255 && (uint16_t)(0 - 1) == 65535) r += 2;

    // 3: widening — sign into u64, zero up from u8, and the u32 top bit.
    if ((uint64_t)(0 - 1) == 18446744073709551615ull && (uint64_t)(uint8_t)200 == 200
        && (uint64_t)(uint32_t)4294967295u == 4294967295ull && (int64_t)(int32_t)(0 - 1) == 0 - 1) r += 4;

    // 4: narrowing off 64 bits — the sign path and the zero path.
    if ((int32_t)neg == 0 - 1 && (uint32_t)neg == 4294967295u && (uint64_t)neg == 18446744073709551615ull) r += 8;

    // 5: through a function, a global, a struct, an array.
    if (narrow8(300) == 44 && widen64(0 - 1) == 18446744073709551615ull
        && passthru(bit63) == 9223372036854775808ull && gwide == 12345678901234567890ull
        && b.lo == 4464 && b.hi == 18446744073709551615ull
        && xs[0] == 9223372036854775808ull && xs[1] == 18446744073709551615ull) r += 16;

    // 6: what the unsigned grid is for — the comparison and the division
    // that would have answered wrong as signed values.
    if (bit63 > 9223372036854775807ull && top / 1000000000000ull == 18446744ull) r += 32;

    // 7: casts compose, and a cast of a folded constant is a folded constant.
    if ((uint8_t)(uint16_t)70000 == 112 && (uint64_t)(uint8_t)300 + 5 == 49) r += 64;

    // 8: the mixed promotion — a u64 plus a small integer stays u64.
    if (m + 1 == 2 && (m + 1) > 1) r += 128;

    return r;   // 255: every group
}
