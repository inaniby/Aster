/* tests/char-return-twin.c — the C oracle for examples/char_return.ast.
 * Mirrors every operation the Aster program performs, using `unsigned char`
 * (1-byte, zero-extended on promotion, exactly the model `char` uses), so the
 * two must agree on the exit status under qemu. Compile + run:
 *   aarch64-linux-gnu-gcc char-return-twin.c -static -o twin && qemu-aarch64 twin
 * Expects exit 0. */
struct S { unsigned char c; int n; };

static unsigned char toUpper(unsigned char c) { return (unsigned char)(c - 32); }

unsigned char g = 'm';   /* 'm' = 109 */

int main(void) {
    unsigned char a = 'A';
    unsigned char b = 'B';
    unsigned char s = a + b;            /* 65 + 66 = 131 */
    unsigned char arr[4] = {0};
    arr[0] = 'x';                       /* 120 */
    arr[1] = 'y';                       /* 121 */
    struct S st = { 'q', 7 };           /* 'q' = 113 */
    unsigned char r = toUpper('a');     /* 65 */
    int wide = g;                       /* widening to int, 109 */
    unsigned char narrowed = (unsigned char)300; /* truncation, 44 */
    int total = (int)s + (int)arr[0] + (int)arr[1] + (int)st.c + (int)r + wide + (int)narrowed;
    if (total == 703) { return 0; }
    return 1;
}
