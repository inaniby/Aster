/* The C twin of examples/const_binding.ast.
 *
 * Compiled by the same oracle the differential suites use
 * (aarch64-linux-gnu-gcc -O2 -fwrapv) and its exit status must equal the
 * Aster program's. Where Aster writes `const x : T = e;` the twin writes
 * `const T x = e;` — the same promise in both languages, and the same
 * consequence in both: a const is read, never written, so the two programs
 * are free to agree on a value neither of them can change afterwards.
 */
typedef struct { int x, y; } Pt;

static int bump(int v){ return v + 1; }

static const int kBase = 10;
static const Pt kHome = { 1, 2 };

int main(void){
    const int k = 5;
    const int xs[3] = { 7, 7, 7 };
    const Pt home = { 3, 4 };
    const int n = bump(k);            /* an initializer may be a call */
    return kBase + kHome.x + kHome.y + k + xs[0] + xs[2] + home.x + home.y + n;
    /* 45 */
}
