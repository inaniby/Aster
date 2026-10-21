/* The C twin of examples/fn_ret.ast.
 *
 * Compiled by the same oracle the differential suites use
 * (aarch64-linux-gnu-gcc -O2 -fwrapv) and its exit status must equal the
 * Aster program's. Aster's `-> fn(i32) -> i32` return type is the C
 * function-pointer return type `int (*)(int)`; the address is the same kind
 * of value in both, and the call through it is the same indirect call.
 */
static int inc(int x){ return x + 1; }
static int dbl(int x){ return x + x; }
static int answer(void){ return 7; }

typedef int (*Unary)(int);

static Unary pick(int which){
    if (which == 0) return inc;
    return dbl;
}
static int (*always(void))(void){ return answer; }

static int apply(Unary op, int v){ return op(v); }

int main(void){
    Unary f = pick(0);
    Unary g = pick(1);

    int h = apply(pick(1), 20);

    int (*z)(void) = always();
    int s = f(20) + g(20) + h + z();
    return s % 251;
}
