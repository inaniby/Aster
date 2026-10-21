/* The C twin of examples/fn_type.ast.
 *
 * Compiled by the same oracle the differential suites use
 * (aarch64-linux-gnu-gcc -O2 -fwrapv) and its exit status must equal the
 * Aster program's. Where the Aster program spells a function type
 * `fn(P1,..,Pn) -> R`, the twin spells the equivalent C function-pointer
 * type; where Aster stages an i64 argument at full width and reads an i64
 * result, the twin's `long` does the same thing the platform ABI does.
 */
static int inc(int x){ return x + 1; }
static long high32(long a){ return a >> 32; }
static int combine(int a, int b){ return a * 3 + b; }
static int apply(int (*op)(int), int x){ return op(x); }

static int (*gop)(int, int);

int main(void){
    int (*fp)(int) = inc;
    int a = fp(41);

    long big = 0;
    big = big + 4294967296L;
    long (*wp)(long) = high32;
    long hi = wp(big);

    int b = apply(fp, a);

    gop = combine;
    int c = gop(7, 8);

    int total = a + b + c + (int)hi;
    return total % 251;
}
