/* Test client -> middle -> base DT_NEEDED lifetime and two independent clients. */
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

typedef int (*fn0)(void);
static fn0 get_fn(void *h, const char *name) {
    (void)dlerror();
    void *raw = dlsym(h, name);
    fn0 fn = NULL;
    memcpy(&fn, &raw, sizeof(fn));
    const char *err = dlerror();
    if (err) fprintf(stderr, "FAIL: dlsym(%s): %s\n", name, err);
    return err ? NULL : fn;
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
        fprintf(stderr, "usage: %s <base.so> <client-a.so> <client-b.so>\n", argv[0]);
        return 2;
    }
    int ok = 1;
    void *base = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!base) { fprintf(stderr, "FAIL: dlopen base: %s\n", dlerror()); return 1; }
    fn0 base_value = get_fn(base, "value");
    if (!base_value) { dlclose(base); return 1; }
    ok &= check("base initial state", base_value(), 3);

    void *a = dlopen(argv[2], RTLD_NOW | RTLD_LOCAL);
    if (!a) { fprintf(stderr, "FAIL: dlopen client A dependency chain: %s\n", dlerror()); dlclose(base); return 1; }
    void *b = dlopen(argv[3], RTLD_NOW | RTLD_LOCAL);
    if (!b) { fprintf(stderr, "FAIL: dlopen client B dependency chain: %s\n", dlerror()); dlclose(a); dlclose(base); return 1; }
    fn0 a_read = get_fn(a, "client_read"), a_bump = get_fn(a, "client_bump");
    fn0 a_add = get_fn(a, "client_add");
    fn0 b_read = get_fn(b, "client_read"), b_bump = get_fn(b, "client_bump");
    fn0 b_add = get_fn(b, "client_add"), b_global = get_fn(b, "client_global_read");
    if (!a_read || !a_bump || !a_add || !b_read || !b_bump || !b_add || !b_global) {
        dlclose(b); dlclose(a); dlclose(base); return 1;
    }
    puts("PASS: client -> middle -> base dependency chain loaded");
    ok &= check("client A reads base through two dependency edges", a_read(), 3);
    ok &= check("client A calls base add through middle", a_add(), 42);
    ok &= check("client A bumps shared base state", a_bump(), 4);
    ok &= check("client B sees state mutated by client A", b_read(), 4);
    ok &= check("client B reads base global through middle", b_global(), 4);

    if (dlclose(a) != 0) { fprintf(stderr, "FAIL: close client A: %s\n", dlerror()); dlclose(b); dlclose(base); return 1; }
    puts("PASS: client A closed while client B remains loaded");
    ok &= check("client B remains usable after client A closes", b_bump(), 5);
    ok &= check("client B still calls through middle into base", b_add(), 42);

    if (dlclose(base) != 0) { fprintf(stderr, "FAIL: close explicit base handle: %s\n", dlerror()); dlclose(b); return 1; }
    puts("PASS: explicit base handle closed while dependency chain remains loaded");
    ok &= check("client B still reads base after explicit base close", b_read(), 5);
    ok &= check("client B still mutates base after explicit base close", b_bump(), 6);
    if (dlclose(b) != 0) { fprintf(stderr, "FAIL: close final client B: %s\n", dlerror()); return 1; }
    puts("PASS: final client handle closed");

    b = dlopen(argv[3], RTLD_NOW | RTLD_LOCAL);
    if (!b) { fprintf(stderr, "FAIL: reload client B: %s\n", dlerror()); return 1; }
    b_read = get_fn(b, "client_read");
    if (!b_read) { dlclose(b); return 1; }
    ok &= check("base state resets after complete chain unload and reload", b_read(), 3);
    if (dlclose(b) != 0) { fprintf(stderr, "FAIL: close reloaded client B: %s\n", dlerror()); return 1; }
    if (!ok) return 1;
    puts("PASS: dependency chain, multi-client lifetime, close order, and final reload tests");
    return 0;
}
