// v0.23.58-dev — C ABI harness for Aster's address-of completion. The C side
// hands Aster typed pointers and a struct pointer and checks the values Aster
// reads back through `&` (address taken, then loaded) against C's own array
// indexing and field access. Disagreement means Aster strided an element at the
// wrong width or read a field at the wrong offset.
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef int32_t (*elem_fn)(int32_t *, int32_t);
typedef int64_t (*elem_i64_fn)(int64_t *, int32_t);
typedef int32_t (*thru_fn)(int32_t *);
typedef int32_t (*field_a_fn)(void *);
typedef int32_t (*field_b_fn)(void *);

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "usage: %s shared-object\n", argv[0]); return 2; }
    void *h = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!h) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 1; }

    void *s_elem, *s_i64, *s_thru, *s_fa, *s_fb;
    s_elem = dlsym(h, "aster_elem");
    s_i64  = dlsym(h, "aster_elem_i64");
    s_thru = dlsym(h, "aster_thru");
    s_fa   = dlsym(h, "aster_field_a");
    s_fb   = dlsym(h, "aster_field_b");
    elem_fn      e;  memcpy(&e,  &s_elem, sizeof e);
    elem_i64_fn  ei; memcpy(&ei, &s_i64,  sizeof ei);
    thru_fn      t;  memcpy(&t,  &s_thru, sizeof t);
    field_a_fn   fa; memcpy(&fa, &s_fa,   sizeof fa);
    field_b_fn   fb; memcpy(&fb, &s_fb,   sizeof fb);
    if (!e || !ei || !t || !fa || !fb) {
        fprintf(stderr, "dlsym: missing address-of export\n"); return 1;
    }

    int32_t a[4] = {10, 20, 30, 40};
    int64_t w[3] = {100, 200, 300};
    struct Pt { int32_t a; int32_t b; };
    struct Pt pt = {77, 88};

    // i32 element via &p[k]: stride 4 must hold for k=0 and k=2.
    if (e(a, 0) != a[0]) { fprintf(stderr, "aster_elem[0] mismatch\n"); return 4; }
    if (e(a, 2) != a[2]) { fprintf(stderr, "aster_elem[2] mismatch (stride 4)\n"); return 5; }
    // i64 element via &w[k]: stride 8 — a 4-byte stride would read the low half of w[0].
    if (ei(w, 1) != w[1]) { fprintf(stderr, "aster_elem_i64[1] mismatch (stride 8)\n"); return 6; }
    // through a typed pointer: &p[1] must land on a[1].
    if (t(a) != a[1]) { fprintf(stderr, "aster_thru[1] mismatch\n"); return 7; }
    // struct field address: &pt.a at offset 0, &pt.b at offset 4.
    if (fa(&pt) != pt.a) { fprintf(stderr, "aster_field_a mismatch (offset 0)\n"); return 8; }
    if (fb(&pt) != pt.b) { fprintf(stderr, "aster_field_b mismatch (offset 4)\n"); return 9; }

    puts("PASS: C -> Aster address-of ABI (i32, i64 stride, ptr-base, field)");
    dlclose(h);
    return 0;
}
