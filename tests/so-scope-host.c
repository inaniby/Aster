/* Same-named exported data/functions must remain handle-addressable and state-isolated
 * when independent Aster DSOs are loaded RTLD_LOCAL. */
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef int (*fn_i32)(void);
static fn_i32 symbol_fn(void *h, const char *name) {
    (void)dlerror();
    void *raw = dlsym(h, name);
    fn_i32 f = NULL;
    memcpy(&f, &raw, sizeof(f));
    const char *e = dlerror();
    if (e) fprintf(stderr, "FAIL: dlsym(%s): %s\n", name, e);
    return e ? NULL : f;
}
static int check(const char *label, int got, int expected) {
    if (got != expected) {
        fprintf(stderr, "FAIL: %s got=%d expected=%d\n", label, got, expected);
        return 0;
    }
    printf("PASS: %s = %d\n", label, got);
    return 1;
}
int main(int argc, char **argv) {
    if (argc != 4) {
        fprintf(stderr, "usage: %s <lib-a.so> <lib-b.so> <ab|ba>\n", argv[0]);
        return 2;
    }
    const char *first = strcmp(argv[3], "ba") == 0 ? argv[2] : argv[1];
    const char *second = strcmp(argv[3], "ba") == 0 ? argv[1] : argv[2];
    void *h1 = dlopen(first, RTLD_NOW | RTLD_LOCAL);
    if (!h1) { fprintf(stderr, "FAIL: dlopen first: %s\n", dlerror()); return 1; }
    void *h2 = dlopen(second, RTLD_NOW | RTLD_LOCAL);
    if (!h2) { fprintf(stderr, "FAIL: dlopen second: %s\n", dlerror()); dlclose(h1); return 1; }
    void *ha = strcmp(argv[3], "ba") == 0 ? h2 : h1;
    void *hb = strcmp(argv[3], "ba") == 0 ? h1 : h2;
    fn_i32 a_get = symbol_fn(ha, "scope_get");
    fn_i32 a_bump = symbol_fn(ha, "scope_bump");
    fn_i32 b_get = symbol_fn(hb, "scope_get");
    fn_i32 b_bump = symbol_fn(hb, "scope_bump");
    if (!a_get || !a_bump || !b_get || !b_bump) return 1;
    int ok = 1;
    ok &= check("A initial state", a_get(), 10);
    ok &= check("B initial state", b_get(), 100);
    ok &= check("A bump", a_bump(), 11);
    ok &= check("B unaffected by A bump", b_get(), 100);
    ok &= check("B bump", b_bump(), 110);
    ok &= check("A unaffected by B bump", a_get(), 11);
    (void)dlerror();
    void *global = dlsym(RTLD_DEFAULT, "scope_get");
    const char *global_error = dlerror();
    if (global || !global_error) {
        fprintf(stderr, "FAIL: RTLD_LOCAL scope_get unexpectedly visible through RTLD_DEFAULT\n");
        ok = 0;
    } else {
        printf("PASS: RTLD_LOCAL scope_get is not exported into RTLD_DEFAULT lookup scope\n");
    }
    dlclose(h2);
    dlclose(h1);
    if (!ok) return 1;
    printf("PASS: same-name symbol isolation and load-order test (%s)\n", argv[3]);
    return 0;
}
