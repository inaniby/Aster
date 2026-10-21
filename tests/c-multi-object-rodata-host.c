#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef int (*fn_i32)(void);
static fn_i32 load_fn(void *h, const char *name) {
    void *p = dlsym(h, name); fn_i32 f = NULL;
    if (!p) { fprintf(stderr, "dlsym(%s): %s\n", name, dlerror()); exit(2); }
    memcpy(&f, &p, sizeof f); return f;
}
static int check_library(const char *path, const char *label, int print_values) {
    void *h = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!h) { fprintf(stderr, "dlopen(%s): %s\n", path, dlerror()); return 2; }
    fn_i32 a_fn = load_fn(h, "aster_multi_rodata_a");
    fn_i32 helper_fn = load_fn(h, "aster_multi_rodata_helper");
    fn_i32 b_fn = load_fn(h, "aster_multi_rodata_b");
    fn_i32 c_fn = load_fn(h, "aster_multi_rodata_c");
    fn_i32 chain_fn = load_fn(h, "aster_multi_rodata_chain_helper");
    fn_i32 d_fn = load_fn(h, "aster_multi_rodata_d");
    fn_i32 e_fn = load_fn(h, "aster_multi_rodata_e");
    int a_before = a_fn();
    int helper = helper_fn();
    int b = b_fn();
    int c = c_fn();
    int chain = chain_fn();
    int d_before = d_fn();
    int e = e_fn();
    int a_after = a_fn();
    int d_after = d_fn();
    if (print_values) {
        printf("%s_multi_object_a_before=%d\n", label, a_before);
        printf("%s_multi_object_helper=%d\n", label, helper);
        printf("%s_multi_object_b=%d\n", label, b);
        printf("%s_multi_object_c=%d\n", label, c);
        printf("%s_multi_object_chain_helper=%d\n", label, chain);
        printf("%s_multi_object_d_before=%d\n", label, d_before);
        printf("%s_multi_object_e_after_add=%d\n", label, e);
        printf("%s_multi_object_a_after=%d\n", label, a_after);
        printf("%s_multi_object_d_after=%d\n", label, d_after);
    }
    int ok = a_before == 50 && helper == 2 && b == 8 && c == 8 && chain == 1 &&
             d_before == 40 && e == 45 && a_after == 55 && d_after == 45;
    if (!ok) fprintf(stderr, "FAIL: %s object-order result mismatch\n", label);
    dlclose(h);
    if (!ok) return 1;
    printf("PASS: five-object shared data/string/call-chain test (%s order)\n", label);
    return 0;
}
int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s <forward.so> <reverse.so>\n", argv[0]);
        return 2;
    }
    if (check_library(argv[1], "forward", 1) != 0) return 1;
    if (check_library(argv[2], "reverse", 0) != 0) return 1;
    puts("PASS: input object order does not change observable results");
    puts("PASS: Aster v0.22.20-dev five-object mutable-global regression test");
    return 0;
}
