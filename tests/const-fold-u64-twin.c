/* tests/const-fold-u64-twin.c — the host-side oracle for examples/
 * const_fold_u64.ast. C folds unsigned long long initializers with uint64_t
 * wrap semantics; v0.23.74-dev makes Aster agree. The array part is the F-06
 * control: a folded constant index is bounds-checked and the read is exact.
 * Expected exit status: 15. */
#include <stdint.h>

static uint64_t gwrap = 9223372036854775807ULL + 1ULL;
static uint64_t gmul  = 9223372036854775807ULL * 2ULL;
static uint64_t gshl  = 1ULL << 63;
static int32_t  a[4];

int main(void) {
    int r = 0;
    if (gwrap == 9223372036854775808ULL)   r += 1;
    if (gmul  == 18446744073709551614ULL)  r += 2;
    if (gshl  == 9223372036854775808ULL)   r += 4;
    a[0] = 11; a[1] = 22; a[2] = 33; a[3] = 44;
    if (a[1 + 1] == 33)                    r += 8;
    return r;
}
