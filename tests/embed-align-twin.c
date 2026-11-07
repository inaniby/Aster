/* tests/embed-align-twin.c — the C spelling of examples/embed_align.ast.
 *
 * gcc is the outside authority for what a power-of-two alignment request
 * means: three constant arrays with 1-, 64- and 16-byte alignment, the
 * 64-byte one named twice. The suite compares the exit status under qemu and
 * reads gcc's own .rodata section header to pin "declared alignment" to the
 * tool's behaviour rather than to Aster's guess.
 */
static const unsigned char head[1] = { 0x41 };
static const unsigned char tail[2] __attribute__((aligned(64))) = { 0x42, 0x43 };
static const unsigned char third[3] __attribute__((aligned(16))) = { 0x44, 0x45, 0x46 };

int main(void) {
    return head[0]
         + tail[0] + tail[1]
         + tail[0]                       /* the second @embed of the same path */
         + third[0] + third[1] + third[2];
}
