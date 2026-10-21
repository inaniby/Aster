#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef int32_t (*sum_fn)(void *, int32_t, void *, int32_t, void *, int32_t, void *, int32_t, void *, int32_t);
typedef void *(*ptr_fn)(void *, int32_t, void *, int32_t, void *, int32_t, void *, int32_t, void *, int32_t);
static void *load_symbol(void *h, const char *name) {
    void *p = dlsym(h, name);
    if (!p) { fprintf(stderr, "dlsym(%s): %s\n", name, dlerror()); exit(2); }
    return p;
}
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    void *h = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!h) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 2; }
    void *p0 = (void *)(uintptr_t)0x1110, *p2 = (void *)(uintptr_t)0x2220;
    void *p4 = (void *)(uintptr_t)0x4440, *p6 = (void *)(uintptr_t)0x6660;
    void *p8 = (void *)(uintptr_t)0x8880;
    void *s1 = load_symbol(h, "aster_mixed_sum10_forward"), *s2 = load_symbol(h, "aster_mixed_last_ptr_forward");
    sum_fn sum = NULL; ptr_fn getptr = NULL;
    if (sizeof(sum) != sizeof(s1) || sizeof(getptr) != sizeof(s2)) return 3;
    memcpy(&sum, &s1, sizeof sum); memcpy(&getptr, &s2, sizeof getptr);
    int32_t result = sum(p0, 1, p2, 2, p4, 4, p6, 8, p8, 16);
    void *last = getptr(p0, 1, p2, 2, p4, 4, p6, 8, p8, 16);
    printf("mixed_sum=%d\n", result);
    printf("stack_ptr=%p expected=%p\n", last, p8);
    if (result != 31 || last != p8) return 1;
    puts("PASS: mixed ptr/i32 AAPCS64 arguments across registers and stack");
    puts("PASS: internal mixed-signature calls preserve stack-passed pointer");
    dlclose(h); return 0;
}
