#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Exported from the host executable so the Aster DSO resolves its PLT import. */
int32_t aster_c_sum32_mixed(void *p0, int32_t a1, void *p2, int32_t a3, void *p4, int32_t a5, void *p6, int32_t a7, void *p8, int32_t a9, void *p10, int32_t a11, void *p12, int32_t a13, void *p14, int32_t a15, void *p16, int32_t a17, void *p18, int32_t a19, void *p20, int32_t a21, void *p22, int32_t a23, void *p24, int32_t a25, void *p26, int32_t a27, void *p28, int32_t a29, void *p30, int32_t a31) {
    if (p0 != (void *)(uintptr_t)0x1000 || p2 != (void *)(uintptr_t)0x1100 || p4 != (void *)(uintptr_t)0x1200 || p6 != (void *)(uintptr_t)0x1300 || p8 != (void *)(uintptr_t)0x1400 || p10 != (void *)(uintptr_t)0x1500 || p12 != (void *)(uintptr_t)0x1600 || p14 != (void *)(uintptr_t)0x1700 || p16 != (void *)(uintptr_t)0x1800 || p18 != (void *)(uintptr_t)0x1900 || p20 != (void *)(uintptr_t)0x1a00 || p22 != (void *)(uintptr_t)0x1b00 || p24 != (void *)(uintptr_t)0x1c00 || p26 != (void *)(uintptr_t)0x1d00 || p28 != (void *)(uintptr_t)0x1e00 || p30 != (void *)(uintptr_t)0x1f00) return -999;
    return a1 + a3 + a5 + a7 + a9 + a11 + a13 + a15 + a17 + a19 + a21 + a23 + a25 + a27 + a29 + a31;
}

typedef int32_t (*call32_fn)(void *, int32_t, void *, int32_t, void *, int32_t, void *, int32_t, void *, int32_t, void *, int32_t, void *, int32_t, void *, int32_t, void *, int32_t, void *, int32_t, void *, int32_t, void *, int32_t, void *, int32_t, void *, int32_t, void *, int32_t, void *, int32_t);

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
    void *raw = load_symbol(h, "aster_call_c_sum32_mixed");
    call32_fn call = NULL;
    if (sizeof(call) != sizeof(raw)) return 3;
    memcpy(&call, &raw, sizeof call);
    int32_t result = call((void *)(uintptr_t)0x1000, 1, (void *)(uintptr_t)0x1100, 3, (void *)(uintptr_t)0x1200, 5, (void *)(uintptr_t)0x1300, 7, (void *)(uintptr_t)0x1400, 9, (void *)(uintptr_t)0x1500, 11, (void *)(uintptr_t)0x1600, 13, (void *)(uintptr_t)0x1700, 15, (void *)(uintptr_t)0x1800, 17, (void *)(uintptr_t)0x1900, 19, (void *)(uintptr_t)0x1a00, 21, (void *)(uintptr_t)0x1b00, 23, (void *)(uintptr_t)0x1c00, 25, (void *)(uintptr_t)0x1d00, 27, (void *)(uintptr_t)0x1e00, 29, (void *)(uintptr_t)0x1f00, 31);
    printf("aster_to_c_32_arg_result=%d expected=256\n", result);
    if (result != 256) return 1;
    puts("PASS: Aster-to-C 32 mixed ptr/i32 arguments across AAPCS64 registers and stack");
    if (dlclose(h) != 0) { fprintf(stderr, "dlclose: %s\n", dlerror()); return 4; }
    return 0;
}
