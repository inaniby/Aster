/* tests/front-sema-twin.c — the host-side oracle for examples/front_sema.ast.
 * typedef/struct/enum tags live in separate namespaces in C (a struct tag may
 * share a name with a typedef), so this twin only models the *accepted* side:
 * an in-range enum switch, a typed pointer store, and arithmetic over the
 * three declarations. Aster is deliberately stricter about collisions and
 * out-of-range case values; the rejection matrix in front-sema-checks.sh is
 * the Aster-only half of the contract. Expected exit status: 28. */
#include <stdint.h>

typedef int32_t Word;
struct Box { int32_t v; };
enum Color { Red = 0, Green = 1, Blue = 2 };

int main(void) {
    Word w = 3;
    struct Box b = { 4 };
    enum Color c = Green;
    int r = (int)(w + b.v);
    switch (c) {
        case 0:   return 100;
        case 1:   r += 20; break;
        default:  return 200;
    }
    int64_t a = 7;
    int64_t *p = &a;
    *p = 42;
    if (a == 42) r += 1;
    return r;
}
