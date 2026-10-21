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
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    void *h = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!h) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 2; }
    int n = load_fn(h, "aster_literal_strlen")();
    int c = load_fn(h, "aster_literal_compare")();
    int e = load_fn(h, "aster_literal_escape_strlen")();
    int ni = load_fn(h, "aster_literal_strlen_internal")();
    int ci = load_fn(h, "aster_literal_compare_internal")();
    int zn = load_fn(h, "aster_literal_embedded_nul_strlen")();
    int qs = load_fn(h, "aster_literal_quote_backslash_strlen")();
    printf("literal_strlen=%d\n", n);
    printf("literal_compare=%d\n", c);
    printf("escaped_strlen=%d\n", e);
    printf("internal_literal_strlen=%d\n", ni);
    printf("internal_literal_compare=%d\n", ci);
    printf("embedded_nul_strlen=%d\n", zn);
    printf("quote_backslash_strlen=%d\n", qs);
    if (n != (int)strlen("Aster v0.22.9-dev") || c != 0 || e != 6 || ni != (int)strlen("Aster v0.22.9-dev") || ci != 0 || zn != 1 || qs != 4) return 1;
    puts("PASS: Aster string literals are NUL-terminated static data");
    puts("PASS: Aster internal pointer arguments and return values");
    puts("PASS: embedded-NUL and quote/backslash escape tests");
    puts("PASS: Aster v0.22.15-dev string literal regression test");
    dlclose(h); return 0;
}
