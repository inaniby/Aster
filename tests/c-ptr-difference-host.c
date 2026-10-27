// v0.23.57-dev — C ABI harness for Aster pointer difference. The C side hands
// Aster two pointers into the same array and checks that Aster's `p - q` agrees
// with C's own `p - q` (compiled by the host compiler), for every element
// stride Aster supports: an untyped `ptr` and `ptr<i32>` (4-byte), `ptr<u8>`
// (1-byte), `ptr<i64>` (8-byte), and `ptr<V3>` (12-byte struct stride).
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef int32_t (*diff_fn)(void *, void *);
typedef int32_t (*diff_u8_fn)(uint8_t *, uint8_t *);
typedef int32_t (*diff_i64_fn)(int64_t *, int64_t *);

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "usage: %s shared-object\n", argv[0]); return 2; }
    void *h = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!h) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 1; }

    void *s_diff = dlsym(h, "aster_ptr_diff");
    void *s_i32  = dlsym(h, "aster_ptr_diff_i32");
    void *s_u8   = dlsym(h, "aster_ptr_diff_u8");
    void *s_i64  = dlsym(h, "aster_ptr_diff_i64");
    void *s_v3   = dlsym(h, "aster_ptr_diff_v3");
    if (!s_diff || !s_i32 || !s_u8 || !s_i64 || !s_v3) {
        fprintf(stderr, "dlsym: missing pointer-difference export\n"); return 1;
    }
    diff_fn     diff = NULL; memcpy(&diff, &s_diff, sizeof diff);
    diff_fn     di32 = NULL; memcpy(&di32,  &s_i32,  sizeof di32);
    diff_u8_fn  du8  = NULL; memcpy(&du8,   &s_u8,   sizeof du8);
    diff_i64_fn di64 = NULL; memcpy(&di64,  &s_i64,  sizeof di64);
    diff_fn     dv3  = NULL; memcpy(&dv3,   &s_v3,   sizeof dv3);

    // i32 array: Aster's untyped `ptr` and `ptr<i32>` must both stride 4 bytes.
    int32_t a[8];
    int32_t *a_hi = &a[5], *a_lo = &a[0];
    int32_t a_exp = (int32_t)(a_hi - a_lo);          // C's own element count
    if (diff((void *)a_hi, (void *)a_lo) != a_exp) { fprintf(stderr, "untyped ptr - ptr mismatch (i32)\n"); return 4; }
    if (diff((void *)a_lo, (void *)a_hi) != -a_exp) { fprintf(stderr, "untyped ptr - ptr reversed mismatch\n"); return 5; }
    if (di32(a_hi, a_lo) != a_exp) { fprintf(stderr, "ptr<i32> - ptr<i32> mismatch\n"); return 6; }

    // u8 array: 1-byte stride, so the byte gap is the count (no shift).
    uint8_t b[8];
    uint8_t *b_hi = &b[6], *b_lo = &b[0];
    int32_t b_exp = (int32_t)(b_hi - b_lo);
    if (du8(b_hi, b_lo) != b_exp) { fprintf(stderr, "ptr<u8> - ptr<u8> mismatch\n"); return 7; }

    // i64 array: 8-byte stride.
    int64_t c[8];
    int64_t *c_hi = &c[5], *c_lo = &c[0];
    int32_t c_exp = (int32_t)(c_hi - c_lo);
    if (di64(c_hi, c_lo) != c_exp) { fprintf(stderr, "ptr<i64> - ptr<i64> mismatch\n"); return 8; }

    // struct array: 12-byte stride is not a power of two, so Aster must use a
    // signed divide. C's struct pointer subtraction yields the element count
    // directly; Aster's must match it.
    struct V3 { int32_t x, y, z; };
    struct V3 vs[4];
    struct V3 *v_hi = &vs[2], *v_lo = &vs[0];
    int32_t v_exp = (int32_t)(v_hi - v_lo);
    if (dv3((void *)v_hi, (void *)v_lo) != v_exp) { fprintf(stderr, "ptr<V3> - ptr<V3> mismatch\n"); return 9; }

    puts("PASS: C -> Aster pointer difference (untyped, i32, u8, i64, struct)");
    puts("PASS: Aster v0.23.57-dev pointer difference ABI test");
    dlclose(h);
    return 0;
}
