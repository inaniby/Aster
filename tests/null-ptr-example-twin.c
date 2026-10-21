// The C twin of examples/null_ptr.ast — the same search, the same null test.
// Compiled by aarch64-linux-gnu-gcc and run under qemu by
// tests/null-ptr-checks.sh; the two exit statuses must agree.
//
// C spells the null pointer constant the same way Aster now does: `0` in a
// pointer context. Pointer arithmetic scales by the element, so `base + i`
// here is the address Aster computes as `base + i * 4`.

static int buf[8];

static int* find(int needle) {
    int* base = buf;
    int i = 0;
    while (i < 8) {
        if (buf[i] == needle) return base + i;
        i = i + 1;
    }
    return 0;                       /* not found */
}

int main(void) {
    buf[2] = 7;
    buf[5] = 42;
    int r = 0;
    int* hit = find(42);            /* present */
    int* miss = find(99);           /* absent -> null */
    if (hit != 0) r = r + 1;        /* +1   found */
    if (hit == 0) r = r + 100;      /* not taken */
    if (miss == 0) r = r + 10;      /* +10  not found */
    if (miss != 0) r = r + 1000;    /* not taken */
    if (hit != miss) r = r + 2;     /* +2   one of them is null */
    int* both = 0;                  /* a null local */
    if (both == miss) r = r + 20;   /* +20  two nulls are equal */
    return r;                       /* 33 */
}
