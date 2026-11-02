/* The C twin of examples/type_alias.ast.
 *
 * Compiled by the same oracle the differential suites use
 * (aarch64-linux-gnu-gcc -O2 -fwrapv) and its exit status must equal the
 * Aster program's. Where Aster writes `type N = T;` the twin writes the C
 * spelling of the same abbreviation, `typedef T N;` — the point of the pair is
 * that a name for a type is not a new type, so both programs lay out, call
 * and read exactly as they would have with the type written out in full.
 */
typedef struct { int x, y; } Point;
typedef enum { Red = 0, Green = 1, Blue = 2 } Color;

typedef int Coord;
typedef Point *Ptr;
typedef Color Shade;
typedef Coord (*BinOp)(Coord, Coord);
typedef unsigned short W;

typedef struct { Coord a; W b; } Pair;

static Coord gp = 4;

static Coord add(Coord x, Coord y){ return x + y; }
static Coord mul(Coord x, Coord y){ return x * y; }
static Coord use(Ptr q){ return q->x * 10 + q->y; }
static Coord via(BinOp op, Coord x, Coord y){ return op(x, y); }

int main(void){
    Point p = { 3, 7 };
    Ptr q = &p;                        /* 3*10+7 = 37 */
    Shade c = Blue;                    /* 2 */
    Pair pr = { 5, 6 };
    Coord arr[2] = { 9, 9 };
    W w = 30;
    BinOp op = add;
    return use(q) + via(op, 1, 2) + pr.a + pr.b + arr[1] + w + c + gp
           + (int)sizeof(Coord);       /* 100 */
}
