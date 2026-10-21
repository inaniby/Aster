/* Exercise loader failure through indirect DT_NEEDED edges, then recover. */
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

typedef int (*fn0)(void);
static int expect_failed_load(const char *label, const char *path, const char *needle) {
    (void)dlerror();
    void *h = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (h) {
        fprintf(stderr, "FAIL: %s unexpectedly loaded\n", label);
        dlclose(h);
        return 0;
    }
    const char *err = dlerror();
    if (!err) {
        fprintf(stderr, "FAIL: %s failed without dlerror text\n", label);
        return 0;
    }
    if (needle && !strstr(err, needle)) {
        fprintf(stderr, "FAIL: %s diagnostic did not contain '%s': %s\n", label, needle, err);
        return 0;
    }
    printf("PASS: %s rejected by loader: %s\n", label, err);
    return 1;
}
static fn0 get_fn(void *h, const char *name) {
    (void)dlerror();
    void *raw = dlsym(h, name);
    fn0 fn = NULL;
    memcpy(&fn, &raw, sizeof(fn));
    const char *err = dlerror();
    if (err) fprintf(stderr, "FAIL: dlsym(%s): %s\n", name, err);
    return err ? NULL : fn;
}
int main(int argc, char **argv) {
    if (argc != 5) {
        fprintf(stderr, "usage: %s <missing-client.so> <unresolved-client.so> <base.so> <valid-client.so>\n", argv[0]);
        return 2;
    }
    int ok = 1;
    /* Repeat each negative case: loader errors must be consumable and must not
       poison later dlopen attempts, even when the same path fails repeatedly. */
    for (int attempt = 1; attempt <= 3; ++attempt) {
        char label[128];
        (void)snprintf(label, sizeof(label), "missing indirect dependency attempt %d/3", attempt);
        ok &= expect_failed_load(label, argv[1], "libaster_missing_dependency.so");
        (void)snprintf(label, sizeof(label), "unresolved indirect symbol attempt %d/3", attempt);
        ok &= expect_failed_load(label, argv[2], "aster_missing_function");
        const char *stale = dlerror();
        if (stale) {
            fprintf(stderr, "FAIL: dlerror state remained set after diagnostic was consumed: %s\n", stale);
            ok = 0;
        }
    }

    (void)dlerror();
    void *base = dlopen(argv[3], RTLD_NOW | RTLD_LOCAL);
    if (!base) {
        fprintf(stderr, "FAIL: valid base load after failures: %s\n", dlerror());
        return 1;
    }
    void *client = dlopen(argv[4], RTLD_NOW | RTLD_LOCAL);
    if (!client) {
        fprintf(stderr, "FAIL: valid dependency chain load after failures: %s\n", dlerror());
        dlclose(base);
        return 1;
    }
    fn0 read = get_fn(client, "client_read");
    fn0 bump = get_fn(client, "client_bump");
    if (!read || !bump) ok = 0;
    else if (read() != 3) {
        fprintf(stderr, "FAIL: valid chain returned %d after prior failures, expected 3\n", read());
        ok = 0;
    } else puts("PASS: valid dependency chain loads and calls successfully after both failures");

    /* A failed dlopen must not disturb a different, already-live dependency
       chain or its mutable state. Keep both client and explicit base handles
       open while repeating both negative cases. */
    if (bump) {
        int bumped = bump();
        if (bumped != 4) {
            fprintf(stderr, "FAIL: live chain bump returned %d, expected 4\n", bumped);
            ok = 0;
        }
    }
    ok &= expect_failed_load("missing indirect dependency while valid chain remains loaded", argv[1], "libaster_missing_dependency.so");
    if (read) {
        int after_missing = read();
        if (after_missing != 4) {
            fprintf(stderr, "FAIL: live dependency chain changed after missing-dependency failure: got %d, expected 4\n", after_missing);
            ok = 0;
        } else puts("PASS: live dependency chain preserves state = 4 after missing-dependency failure");
    }
    /* Prove the still-live chain remains writable between distinct failures. */
    if (bump) {
        int bumped_again = bump();
        if (bumped_again != 5) {
            fprintf(stderr, "FAIL: live chain second bump returned %d, expected 5\n", bumped_again);
            ok = 0;
        }
    }
    ok &= expect_failed_load("unresolved indirect symbol while valid chain remains loaded", argv[2], "aster_missing_function");
    if (read) {
        int after_unresolved = read();
        if (after_unresolved != 5) {
            fprintf(stderr, "FAIL: live dependency chain changed after unresolved-symbol failure: got %d, expected 5\n", after_unresolved);
            ok = 0;
        } else puts("PASS: live dependency chain preserves state = 5 after unresolved-symbol failure");
    }
    if (dlclose(client) != 0) { fprintf(stderr, "FAIL: close valid client: %s\n", dlerror()); ok = 0; }
    if (dlclose(base) != 0) { fprintf(stderr, "FAIL: close valid base: %s\n", dlerror()); ok = 0; }

    /* After every reference is closed, a fresh chain must load and initialize
       normally; this catches stale failed-load state and retained mappings. */
    (void)dlerror();
    client = dlopen(argv[4], RTLD_NOW | RTLD_LOCAL);
    if (!client) {
        fprintf(stderr, "FAIL: valid dependency chain reload after final close: %s\n", dlerror());
        ok = 0;
    } else {
        read = get_fn(client, "client_read");
        if (!read) ok = 0;
        else if (read() != 3) {
            fprintf(stderr, "FAIL: reloaded valid chain returned %d, expected initial state 3\n", read());
            ok = 0;
        } else puts("PASS: valid dependency chain reloads after final close with initial state = 3");
        if (dlclose(client) != 0) { fprintf(stderr, "FAIL: close reloaded valid client: %s\n", dlerror()); ok = 0; }
    }
    if (!ok) return 1;
    puts("PASS: repeated indirect dependency failures, dlerror consumption, per-failure live-chain integrity, recovery, and final-close reload tests");
    return 0;
}
