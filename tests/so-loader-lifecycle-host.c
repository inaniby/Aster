/* Exercise RTLD_GLOBAL lookup and dlclose/reopen in separate process modes.
 * The lifecycle mode intentionally uses RTLD_LOCAL only: a prior RTLD_GLOBAL
 * load can remain in a platform linker's global group and is not a valid test
 * of whether a local object's final reference was released. */
#include <dlfcn.h>
#include <stdio.h>
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
static fn_i32 default_fn(const char *name) {
    (void)dlerror();
    void *raw = dlsym(RTLD_DEFAULT, name);
    fn_i32 f = NULL;
    memcpy(&f, &raw, sizeof(f));
    const char *e = dlerror();
    if (e) fprintf(stderr, "FAIL: dlsym(RTLD_DEFAULT, %s): %s\n", name, e);
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
static int global_mode(const char *a_path, const char *b_path) {
    int ok = 1;
    void *ha = dlopen(a_path, RTLD_NOW | RTLD_GLOBAL);
    if (!ha) { fprintf(stderr, "FAIL: dlopen A RTLD_GLOBAL: %s\n", dlerror()); return 1; }
    fn_i32 a_get = symbol_fn(ha, "scope_get");
    fn_i32 a_bump = symbol_fn(ha, "scope_bump");
    fn_i32 global_get = default_fn("scope_get");
    if (!a_get || !a_bump || !global_get) { dlclose(ha); return 1; }
    ok &= check("RTLD_GLOBAL initial state through handle", a_get(), 10);
    ok &= check("RTLD_GLOBAL symbol visible through RTLD_DEFAULT", global_get(), 10);
    ok &= check("RTLD_GLOBAL bump", a_bump(), 11);
    ok &= check("RTLD_DEFAULT observes RTLD_GLOBAL state", global_get(), 11);
    void *hb = dlopen(b_path, RTLD_NOW | RTLD_LOCAL);
    if (!hb) { fprintf(stderr, "FAIL: dlopen B RTLD_LOCAL: %s\n", dlerror()); dlclose(ha); return 1; }
    fn_i32 b_get = symbol_fn(hb, "scope_get");
    if (!b_get) { dlclose(hb); dlclose(ha); return 1; }
    ok &= check("RTLD_LOCAL B keeps independent state beside global A", b_get(), 100);
    global_get = default_fn("scope_get");
    if (!global_get) { dlclose(hb); dlclose(ha); return 1; }
    ok &= check("RTLD_DEFAULT still resolves global A after local B load", global_get(), 11);
    dlclose(hb); dlclose(ha);
    if (!ok) return 1;
    puts("PASS: RTLD_GLOBAL visibility and RTLD_LOCAL coexistence");
    return 0;
}
static int lifecycle_mode(const char *a_path) {
    void *h = dlopen(a_path, RTLD_NOW | RTLD_LOCAL);
    if (!h) { fprintf(stderr, "FAIL: lifecycle dlopen: %s\n", dlerror()); return 1; }
    fn_i32 get = symbol_fn(h, "scope_get");
    fn_i32 bump = symbol_fn(h, "scope_bump");
    if (!get || !bump) { dlclose(h); return 1; }
    int ok = 1;
    ok &= check("reload test initial state", get(), 10);
    ok &= check("reload test mutate before dlclose", bump(), 11);
    if (dlclose(h) != 0) { fprintf(stderr, "FAIL: dlclose before reload: %s\n", dlerror()); return 1; }
    h = dlopen(a_path, RTLD_NOW | RTLD_LOCAL);
    if (!h) { fprintf(stderr, "FAIL: dlopen A after dlclose: %s\n", dlerror()); return 1; }
    get = symbol_fn(h, "scope_get");
    if (!get) { dlclose(h); return 1; }
    ok &= check("state reset after dlclose and reopen", get(), 10);
    dlclose(h);
    if (!ok) return 1;
    puts("PASS: dlclose/reopen lifecycle state reset");
    return 0;
}
static int repeat_mode(const char *a_path) {
    int ok = 1;
    void *h1 = dlopen(a_path, RTLD_NOW | RTLD_LOCAL);
    if (!h1) { fprintf(stderr, "FAIL: repeat dlopen #1: %s\n", dlerror()); return 1; }
    void *h2 = dlopen(a_path, RTLD_NOW | RTLD_LOCAL);
    if (!h2) { fprintf(stderr, "FAIL: repeat dlopen #2: %s\n", dlerror()); dlclose(h1); return 1; }
    fn_i32 get1 = symbol_fn(h1, "scope_get");
    fn_i32 bump1 = symbol_fn(h1, "scope_bump");
    fn_i32 get2 = symbol_fn(h2, "scope_get");
    fn_i32 bump2 = symbol_fn(h2, "scope_bump");
    if (!get1 || !bump1 || !get2 || !bump2) {
        dlclose(h2); dlclose(h1); return 1;
    }
    ok &= check("repeat dlopen initial state through handle 1", get1(), 10);
    ok &= check("repeat dlopen observes shared state through handle 2", get2(), 10);
    ok &= check("repeat dlopen bump through handle 1", bump1(), 11);
    ok &= check("repeat dlopen handle 2 observes handle 1 mutation", get2(), 11);
    if (dlclose(h1) != 0) {
        fprintf(stderr, "FAIL: first dlclose with second reference alive: %s\n", dlerror());
        dlclose(h2); return 1;
    }
    ok &= check("second handle remains usable after first dlclose", bump2(), 12);
    ok &= check("second handle sees state after first dlclose", get2(), 12);
    if (dlclose(h2) != 0) {
        fprintf(stderr, "FAIL: final dlclose after repeated dlopen: %s\n", dlerror());
        return 1;
    }
    void *h3 = dlopen(a_path, RTLD_NOW | RTLD_LOCAL);
    if (!h3) { fprintf(stderr, "FAIL: repeat dlopen after final dlclose: %s\n", dlerror()); return 1; }
    fn_i32 get3 = symbol_fn(h3, "scope_get");
    if (!get3) { dlclose(h3); return 1; }
    ok &= check("state reset after repeated handles fully closed", get3(), 10);
    if (dlclose(h3) != 0) { fprintf(stderr, "FAIL: cleanup dlclose after repeat mode: %s\n", dlerror()); return 1; }
    if (!ok) return 1;
    puts("PASS: repeated dlopen shares state, retains mapping until final close, and reload resets state");
    return 0;
}

static int recovery_mode(const char *a_path) {
    int ok = 1;
    char missing_path[4096];
    int n = snprintf(missing_path, sizeof(missing_path), "%s.missing-v0.22.27", a_path);
    if (n < 0 || (size_t)n >= sizeof(missing_path)) {
        fprintf(stderr, "FAIL: missing-library test path too long\n");
        return 1;
    }
    (void)dlerror();
    void *bad = dlopen(missing_path, RTLD_NOW | RTLD_LOCAL);
    const char *open_error = dlerror();
    if (bad || !open_error) {
        fprintf(stderr, "FAIL: nonexistent library unexpectedly loaded or did not report an error\n");
        if (bad) dlclose(bad);
        return 1;
    }
    puts("PASS: dlopen missing library fails with a diagnostic");

    void *h = dlopen(a_path, RTLD_NOW | RTLD_LOCAL);
    if (!h) { fprintf(stderr, "FAIL: valid dlopen after missing-library failure: %s\n", dlerror()); return 1; }
    (void)dlerror();
    void *missing_raw = dlsym(h, "aster_symbol_that_does_not_exist_v0_22_27");
    const char *symbol_error = dlerror();
    if (missing_raw || !symbol_error) {
        fprintf(stderr, "FAIL: nonexistent symbol unexpectedly resolved or did not report an error\n");
        dlclose(h);
        return 1;
    }
    puts("PASS: dlsym missing symbol fails with a diagnostic");

    fn_i32 get = symbol_fn(h, "scope_get");
    fn_i32 bump = symbol_fn(h, "scope_bump");
    if (!get || !bump) { dlclose(h); return 1; }
    ok &= check("valid symbol remains usable after lookup failure", get(), 10);
    ok &= check("valid call after lookup failure", bump(), 11);
    ok &= check("valid symbol remains usable after failed dlopen and dlsym", get(), 11);
    if (dlclose(h) != 0) { fprintf(stderr, "FAIL: recovery-mode dlclose: %s\n", dlerror()); return 1; }
    if (!ok) return 1;
    puts("PASS: loader error recovery after failed dlopen and dlsym");
    return 0;
}

static int close_order_mode(const char *a_path) {
    int ok = 1;
    void *h1 = dlopen(a_path, RTLD_NOW | RTLD_LOCAL);
    if (!h1) { fprintf(stderr, "FAIL: close-order dlopen #1: %s\n", dlerror()); return 1; }
    void *h2 = dlopen(a_path, RTLD_NOW | RTLD_LOCAL);
    if (!h2) { fprintf(stderr, "FAIL: close-order dlopen #2: %s\n", dlerror()); dlclose(h1); return 1; }
    void *h3 = dlopen(a_path, RTLD_NOW | RTLD_LOCAL);
    if (!h3) { fprintf(stderr, "FAIL: close-order dlopen #3: %s\n", dlerror()); dlclose(h2); dlclose(h1); return 1; }
    fn_i32 get1 = symbol_fn(h1, "scope_get");
    fn_i32 bump1 = symbol_fn(h1, "scope_bump");
    fn_i32 get2 = symbol_fn(h2, "scope_get");
    fn_i32 get3 = symbol_fn(h3, "scope_get");
    fn_i32 bump3 = symbol_fn(h3, "scope_bump");
    if (!get1 || !bump1 || !get2 || !get3 || !bump3) {
        dlclose(h3); dlclose(h2); dlclose(h1); return 1;
    }
    ok &= check("close-order initial state via handle 1", get1(), 10);
    ok &= check("close-order third handle sees shared state", get3(), 10);
    ok &= check("close-order bump before middle close", bump1(), 11);
    if (dlclose(h2) != 0) {
        fprintf(stderr, "FAIL: close middle handle first: %s\n", dlerror());
        dlclose(h3); dlclose(h1); return 1;
    }
    ok &= check("handle 1 remains usable after middle handle closes", get1(), 11);
    ok &= check("handle 3 remains usable after middle handle closes", bump3(), 12);
    ok &= check("handle 1 sees handle 3 mutation", get1(), 12);
    if (dlclose(h1) != 0) {
        fprintf(stderr, "FAIL: close first handle second: %s\n", dlerror());
        dlclose(h3); return 1;
    }
    ok &= check("last handle remains usable after two other handles close", bump3(), 13);
    ok &= check("last handle observes final shared state", get3(), 13);
    if (dlclose(h3) != 0) { fprintf(stderr, "FAIL: close final handle: %s\n", dlerror()); return 1; }
    void *h4 = dlopen(a_path, RTLD_NOW | RTLD_LOCAL);
    if (!h4) { fprintf(stderr, "FAIL: reload after close-order test: %s\n", dlerror()); return 1; }
    fn_i32 get4 = symbol_fn(h4, "scope_get");
    if (!get4) { dlclose(h4); return 1; }
    ok &= check("state reset after close-order final close and reload", get4(), 10);
    if (dlclose(h4) != 0) { fprintf(stderr, "FAIL: cleanup after close-order test: %s\n", dlerror()); return 1; }
    if (!ok) return 1;
    puts("PASS: handles remain valid across middle/first close order and reset after final close");
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 4 && strcmp(argv[1], "global") == 0) return global_mode(argv[2], argv[3]);
    if (argc == 3 && strcmp(argv[1], "lifecycle") == 0) return lifecycle_mode(argv[2]);
    if (argc == 3 && strcmp(argv[1], "repeat") == 0) return repeat_mode(argv[2]);
    if (argc == 3 && strcmp(argv[1], "recovery") == 0) return recovery_mode(argv[2]);
    if (argc == 3 && strcmp(argv[1], "close-order") == 0) return close_order_mode(argv[2]);
    fprintf(stderr, "usage: %s global <lib-a.so> <lib-b.so> | lifecycle <lib-a.so> | repeat <lib-a.so> | recovery <lib-a.so> | close-order <lib-a.so>\n", argv[0]);
    return 2;
}
