/* tests/arena-twin.c — the C oracle for examples/arena.ast.
 *
 * Same bump allocator, same three nodes, same payloads, same reclaim-and-
 * reuse arithmetic — performed with libc's mmap. The suite compiles both and
 * compares stdout bytes and the exit status, so a cursor that fails to move,
 * a payload that is stored at the wrong width, or an arena that does not hand
 * back the same address after reclaim each diverge. */
#include <sys/mman.h>
#include <unistd.h>

static unsigned char *heap;
static int cursor;

static unsigned char *alloc(int n) {
    unsigned char *p = heap + cursor;
    cursor += n;
    return p;
}
static void reclaim(void) { cursor = 0; }

int main(void) {
    heap = mmap(0, 65536, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (heap == 0) { write(1, "MAP-FAIL\n", 10); return 1; }

    unsigned char *a = alloc(16), *b = alloc(16), *c = alloc(16);
    a[0] = 65; *(long long *)(a + 8) = 0x1122334455667788LL;
    b[0] = 66; *(long long *)(b + 8) = 0x0123456789ABCDEFLL;
    c[0] = 67; *(long long *)(c + 8) = 0;

    write(1, a + 8, 8);
    int sum = 0;
    for (int i = 0; i < 8; i++) sum += a[8 + i];

    reclaim();
    unsigned char *a2 = alloc(16);
    int same = (a2 == a);
    a2[0] = 68;
    int tag = a2[0];

    return same * 100 + tag + sum;
}
