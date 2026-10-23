#include <stdint.h>

/* The C twin of examples/switch.ast (v0.23.49-dev). Aster's switch is
 * Pascal-shaped (no fallthrough, no per-case break) and its labeled
 * break/continue steer named loops; this C reproduces the same control flow
 * with explicit breaks and a goto for `continue outer`. The program returns
 * the same 212 Aster does. */
static int32_t lookup(int32_t x) {
    switch (x) {
        case 1: return 100;
        case 2: return 200;
        case 3: return 300;
        default: return 0;
    }
}

int main(void) {
    int32_t total = 0;
    for (int32_t k = 0; k < 3; k = k + 1) {
        int32_t i = 0;
        while (i < 4) {
            i = i + 1;
            if (i == 3) { goto outer_continue; }
            total = total + 1;
        }
    outer_continue:;
    }
    int32_t n = 0;
    int32_t w = 0;
    while (w < 5) {
        w = w + 1;
        switch (w) {
            case 1: n = n + 1; break;
            case 2: n = n + 2; break;
            case 3: n = n + 3; break;
            default: n = n + 0; break;
        }
    }
    total = total + n;
    total = total + lookup(2);
    total = total + lookup(9);
    return total;
}
