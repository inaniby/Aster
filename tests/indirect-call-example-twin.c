// C twin of examples/indirect_call.ast (v0.23.24-dev) — differential oracle.
// Each Aster step is spelled with the C construct it models: a local function
// pointer, its reassignment, a trampoline taking the callee as a parameter, a
// global pointer reassigned at runtime, and a pointer read out of a struct
// field (Aster's load_ptr(&s)). Exit status must be 144.
#include <stdio.h>

static int inc(int x){ return x+1; }
static int dec(int x){ return x-1; }
static int twice(int x){ return x*2; }

static int apply(int (*op)(int), int x){ return op(x); }

struct Slot { int (*op)(int); };

static int (*dispatched)(int) = inc;

int main(void){
    int (*a)(int) = inc;
    int r1 = a(40);            // 41
    a = twice;
    int r2 = a(20);            // 40
    int r3 = apply(dec, 10);   // 9
    int r4 = dispatched(6);    // 7
    dispatched = dec;
    int r5 = dispatched(6);    // 5
    struct Slot s = {0};
    s.op = twice;
    int (*q)(int) = *(&s.op);  // Aster's load_ptr(&s)
    int r6 = q(21);            // 42
    int sum = r1+r2+r3+r4+r5+r6;
    fprintf(stderr, "r1=%d r2=%d r3=%d r4=%d r5=%d r6=%d sum=%d\n",
            r1, r2, r3, r4, r5, r6, sum);
    return sum % 251;
}
