/* The C twin of examples/cb_table.ast.
 *
 * Compiled by the same oracle the differential suites use
 * (aarch64-linux-gnu-gcc -O2 -fwrapv) and its exit status must equal the
 * Aster program's. The Aster program's `ptr<Handlers>` parameter is a
 * `struct Handlers *` here, and each `fn(...) -> ...` field is the
 * equivalent C function-pointer field; the calls through them are the same
 * indirect calls the AAPCS64 describes.
 */
struct Handlers {
    int (*onClick)(int);
    int (*onMove)(int, int);
};

static int click(int x){ return x + 1; }
static int dbl(int x){ return x + x; }
static int move2(int a, int b){ return a * 10 + b; }

static int run(struct Handlers *h){
    return h->onClick(41) + h->onMove(2, 3);
}

int main(void){
    struct Handlers h = { click, move2 };
    int a = run(&h);

    h.onClick = dbl;
    int b = h.onClick(10);

    int (*f)(int) = h.onClick;
    int c = f(1);

    return (a + b + c) % 251;
}
