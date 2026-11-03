// tests/void-return-twin.c — the C spelling of examples/void_return.ast.
// gcc's own `void` is the oracle: every Aster void function has an exact C
// twin, and the two must agree on the exit status under qemu.
static int g = 0;

static void bump(void) {
    g = g + 1;
}

static void add(int n) {
    int i = 0;
    while (i < n) {
        bump();
        i = i + 1;
    }
}

static void no_return(void) {
    g = g + 5;
}

static void maybe(int v) {
    if (v > 0) {
        g = g + 10;
    }
}

int main(void) {
    bump();        /* g = 1 */
    add(3);        /* g = 4 */
    no_return();   /* g = 9 */
    maybe(1);      /* g = 19 */
    maybe(0);      /* unchanged */
    return g;      /* 19 */
}
