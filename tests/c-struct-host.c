/* v0.23.5-dev: does Aster's struct ABI actually agree with C?
 *
 * Linked statically against examples/c_struct_abi.ast (built with
 * `aster build-obj`), this program exercises both directions of all three
 * AAPCS64 composite classes:
 *
 *   <= 8 bytes   one general-purpose register
 *   9..16 bytes  two consecutive general-purpose registers
 *   > 16 bytes   a caller-made copy; a >16-byte result returns through X8
 *
 * The C compiler is a witness here, not a tool in the pipeline: Aster compiles
 * its own half and owns every byte of it.
 */
#include <stdint.h>
#include <stdio.h>

/* The three classes, spelled the way C spells them. Field types match Aster's
   exactly: i32 -> int32_t, i64 -> int64_t. */
struct P { int32_t x, y; };                /*  8 bytes: one register       */
struct T { int32_t a, b, c; };             /* 12 bytes: a register pair    */
struct B { int64_t a, b, c; };             /* 24 bytes: a caller-made copy */

/* --- the Aster half (examples/c_struct_abi.ast) ------------------------- */
extern int32_t aster_sum_p(struct P p);
extern int32_t aster_sum_t(struct T t);
extern int64_t aster_sum_b(struct B b);
extern struct P aster_mk_p(int32_t v);
extern struct T aster_mk_t(int32_t v);
extern struct B aster_mk_b(int64_t v);
extern int32_t aster_call_c_p(void);
extern int32_t aster_call_c_t(void);
extern int64_t aster_call_c_b(void);
extern int64_t aster_call_c_mk_b(int64_t v);

/* --- the C half, imported by the Aster half ----------------------------- */
int32_t c_sum_p(struct P p) { return p.x + p.y; }
int32_t c_sum_t(struct T t) { return t.a + t.b + t.c; }
int64_t c_sum_b(struct B b) { return b.a + b.b + b.c; }
struct B c_mk_b(int64_t v) {
    struct B r;
    r.a = v; r.b = v + 1; r.c = v + 2;
    return r;
}

static int failures = 0;
static void expect(const char *what, long long got, long long want) {
    printf("%-26s got=%-12lld expected=%lld\n", what, got, want);
    if (got != want) ++failures;
}

int main(void) {
    struct P p; p.x = 3; p.y = 4;
    struct T t; t.a = 5; t.b = 6; t.c = 7;
    struct B b; b.a = 100; b.b = 200; b.c = 300;

    /* C -> Aster: a composite argument in each class. */
    expect("c->aster arg  8B", aster_sum_p(p), 7);
    expect("c->aster arg 12B", aster_sum_t(t), 18);
    expect("c->aster arg 24B", aster_sum_b(b), 600);

    /* C -> Aster: a composite result in each class — the 24-byte one comes
       back through the buffer C hands over in X8. */
    struct P rp = aster_mk_p(9);
    struct T rt = aster_mk_t(9);
    struct B rb = aster_mk_b(1000);
    expect("c->aster ret  8B .x", rp.x, 9);
    expect("c->aster ret  8B .y", rp.y, 10);
    expect("c->aster ret 12B .a", rt.a, 9);
    expect("c->aster ret 12B .b", rt.b, 10);
    expect("c->aster ret 12B .c", rt.c, 11);
    expect("c->aster ret 24B .a", rb.a, 1000);
    expect("c->aster ret 24B .b", rb.b, 1001);
    expect("c->aster ret 24B .c", rb.c, 1002);

    /* Aster -> C: the same three classes in the other direction. */
    expect("aster->c arg  8B", aster_call_c_p(), c_sum_p(p));
    expect("aster->c arg 12B", aster_call_c_t(), c_sum_t(t));
    expect("aster->c arg 24B", aster_call_c_b(), c_sum_b(b));
    expect("aster->c ret 24B sret", aster_call_c_mk_b(1000), 3003);

    if (failures) { printf("FAIL: %d struct ABI mismatch(es)\n", failures); return 1; }
    puts("PASS: Aster and C agree on 8-byte, 12-byte and 24-byte composites in both directions");
    return 0;
}
