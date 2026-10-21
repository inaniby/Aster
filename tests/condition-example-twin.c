/* C twin of examples/condition.ast — v0.23.25-dev.
 *
 * The same program in C: the bool literals are int 0/1 there, and the integer
 * conditions are the same zero-is-false rule C has always had. The suite
 * builds this with the target C compiler, runs it and the Aster build through
 * the same runner, and requires the same exit status.
 */
#include <stdio.h>

static int steps(int n) {
    int c = 0;
    while (n) {
        if (n < 0) n = n + 1; else n = n - 1;
        c = c + 1;
    }
    return c;
}

int main(void) {
    int on = 1;    /* true  */
    int off = 0;   /* false */
    int r = 0;
    if (on) r = r + steps(9);
    if (off) r = r + 100; else r = r + steps(-4);
    for (int i = 0; i < 3; i = i + 1) r = r + 1;
    int zero = 0;
    if (zero) r = r + 1000;
    if (r - 16) return 1;
    fprintf(stderr, "steps(9)=%d steps(-4)=%d r=%d\n", steps(9), steps(-4), r);
    return r % 251;
}
