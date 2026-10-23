// The C twin of examples/literals.ast. It returns the same exit code (255) by
// computing the same witnesses through C's own literal rules. The Aster example
// leans on spellings C does not share — `_` digit separators and `0b` binary
// literals are C23, not C11, and a character literal is an Aster Char token —
// so this twin spells the *decoded* values in plain C11 hex and decimal. The
// two sides agree on the one integer that matters: the exit status.
//
//   * a character literal is its byte value — `'A'` is 65, `'\a'` is 7;
//   * a `u`/`l`/`ul` suffix sets the literal's width, exactly as in Aster,
//     so `0xFFFFFFFFu` is unsigned 32-bit and casts back up zero-extended;
//   * a digit separator is invisible, so `1_000_000` is 1000000;
//   * a binary literal is its value, so `0b101010` is 42 and `0b1111_1111`
//     is 255;
//   * the escape table's control codes are the same in C.
//
// The eight groups each carry exactly one bit of the answer, mirrored from the
// Aster example bit for bit, so a missing bit names the same group on both
// sides.
#include <stdint.h>

int main(void) {
    int32_t r = 0;
    uint32_t u = 0xFFFFFFFFu;        // u32, not folded into i64
    int64_t l = -1l;                 // i64, value is the machine -1
    uint64_t big = 0xFFFFFFFFFFFFFFFFull;  // u64, the full unsigned max
    const char *s = "\a\b\f\v";      // the extended escape table

    // 1: character literals are their byte values.
    if ('A' == 65 && '\n' == 10 && '\'' == 39 && '\a' == 7 && '\x41' == 65) r += 1;

    // 2: the u suffix makes the literal u32; cast back up it zero-extends.
    if (u == 4294967295u && (uint64_t)u == 4294967295ull) r += 2;

    // 3: digit separators are invisible — 1000000, 0xFFFF (65535), 123.
    if (1000000 == 1000000 && 0xFFFF == 65535 && 123 == 123) r += 4;

    // 4: binary literals, decoded — 0x2A=42, 1, 0xFF=255, 0xA=10.
    if (0x2A == 42 && 1 == 1 && 0xFF == 255 && 0xA == 10) r += 8;

    // 5: extended escapes in a string — 7, 8, 12, 11.
    if (s[0] == 7 && s[1] == 8 && s[2] == 12 && s[3] == 11) r += 16;

    // 6: separators with hex and binary, decoded — 0xDEADBEEF=3735928559,
    // 0xFFF=4095.
    if (0xDEADBEEF == 3735928559u && 0xFFF == 4095) r += 32;

    // 7: a character literal is an integer — 'B'-'A' == 1, 'a'+1 == 'b'.
    if ('B' - 'A' == 1 && 'a' + 1 == 'b') r += 64;

    // 8: the i64 and u64 suffixes answer their full widths.
    if (l == 0 - 1 && big == 18446744073709551615ull) r += 128;

    return r;   // 255: every group
}
