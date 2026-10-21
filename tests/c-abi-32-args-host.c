#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef int32_t (*sum32_fn)(void *, int32_t, void *, int32_t, void *, int32_t, void *, int32_t, void *, int32_t, void *, int32_t, void *, int32_t, void *, int32_t, void *, int32_t, void *, int32_t, void *, int32_t, void *, int32_t, void *, int32_t, void *, int32_t, void *, int32_t, void *, int32_t);
typedef void *(*ptr32_fn)(int32_t, void *, int32_t, void *, int32_t, void *, int32_t, void *, int32_t, void *, int32_t, void *, int32_t, void *, int32_t, void *, int32_t, void *, int32_t, void *, int32_t, void *, int32_t, void *, int32_t, void *, int32_t, void *, int32_t, void *, int32_t, void *);

static void *load_symbol(void *h, const char *name) {
    dlerror();
    void *p = dlsym(h, name);
    const char *e = dlerror();
    if (e || !p) { fprintf(stderr, "dlsym(%s): %s\n", name, e ? e : "null symbol"); exit(2); }
    return p;
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    void *h = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!h) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 2; }
    void *s1 = load_symbol(h, "aster_sum32_mixed_forward");
    void *s2 = load_symbol(h, "aster_last_stack_ptr32_forward");
    sum32_fn sum = NULL;
    ptr32_fn last_ptr = NULL;
    if (sizeof(sum) != sizeof(s1) || sizeof(last_ptr) != sizeof(s2)) return 3;
    memcpy(&sum, &s1, sizeof sum);
    memcpy(&last_ptr, &s2, sizeof last_ptr);
    void *p0 = (void *)(uintptr_t)0x1000;
    void *p2 = (void *)(uintptr_t)0x1100;
    void *p4 = (void *)(uintptr_t)0x1200;
    void *p6 = (void *)(uintptr_t)0x1300;
    void *p8 = (void *)(uintptr_t)0x1400;
    void *p10 = (void *)(uintptr_t)0x1500;
    void *p12 = (void *)(uintptr_t)0x1600;
    void *p14 = (void *)(uintptr_t)0x1700;
    void *p16 = (void *)(uintptr_t)0x1800;
    void *p18 = (void *)(uintptr_t)0x1900;
    void *p20 = (void *)(uintptr_t)0x1a00;
    void *p22 = (void *)(uintptr_t)0x1b00;
    void *p24 = (void *)(uintptr_t)0x1c00;
    void *p26 = (void *)(uintptr_t)0x1d00;
    void *p28 = (void *)(uintptr_t)0x1e00;
    void *p30 = (void *)(uintptr_t)0x1f00;
    void *q1 = (void *)(uintptr_t)0x5100;
    void *q3 = (void *)(uintptr_t)0x5300;
    void *q5 = (void *)(uintptr_t)0x5500;
    void *q7 = (void *)(uintptr_t)0x5700;
    void *q9 = (void *)(uintptr_t)0x5900;
    void *q11 = (void *)(uintptr_t)0x5b00;
    void *q13 = (void *)(uintptr_t)0x5d00;
    void *q15 = (void *)(uintptr_t)0x5f00;
    void *q17 = (void *)(uintptr_t)0x6100;
    void *q19 = (void *)(uintptr_t)0x6300;
    void *q21 = (void *)(uintptr_t)0x6500;
    void *q23 = (void *)(uintptr_t)0x6700;
    void *q25 = (void *)(uintptr_t)0x6900;
    void *q27 = (void *)(uintptr_t)0x6b00;
    void *q29 = (void *)(uintptr_t)0x6d00;
    void *q31 = (void *)(uintptr_t)0x6f00;
    int32_t total = sum(p0, 1, p2, 3, p4, 5, p6, 7, p8, 9, p10, 11, p12, 13, p14, 15, p16, 17, p18, 19, p20, 21, p22, 23, p24, 25, p26, 27, p28, 29, p30, 31);
    void *last = last_ptr(0, q1, 2, q3, 4, q5, 6, q7, 8, q9, 10, q11, 12, q13, 14, q15, 16, q17, 18, q19, 20, q21, 22, q23, 24, q25, 26, q27, 28, q29, 30, q31);
    printf("mixed_32_arg_sum=%d expected=256\n", total);
    printf("last_stack_ptr=%p expected=%p\n", last, q31);
    if (total != 256 || last != q31) return 1;
    puts("PASS: 32 mixed ptr/i32 arguments across AAPCS64 registers and stack");
    puts("PASS: last stack-passed pointer survives Aster-to-Aster forwarding");
    if (dlclose(h) != 0) { fprintf(stderr, "dlclose: %s\n", dlerror()); return 4; }
    return 0;
}
