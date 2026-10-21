// A host that drives examples/lifecycle.ast's shared object the way Android
// would: build an ANativeActivity whose `callbacks` points at an empty table,
// call ANativeActivity_onCreate, then call each entry it installed and read the
// counters back through aster_lifecycle_count.
//
// This is what makes the lifecycle wiring observable without a device. The
// instructions are the ones Android runs — the .so is loaded, its PLT is bound
// and its callbacks are called through the same function pointers — only the
// loader (glibc under qemu, not bionic on a phone) and the provider of
// __android_log_print differ. On Android that symbol comes from liblog.so; the
// test supplies a host-side liblog.so stub (tests/liblog-stub.c) that prints to
// stderr, mirroring the device without needing bionic. Device-side confirmation
// remains a separate open item; what this closes is "does the callback table
// get filled in, at the right offsets, with functions that run".
//
// Built by tests/lifecycle-callbacks.sh for AArch64 and run under qemu-aarch64.

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef int (*create_fn)(void *, void *, int);
typedef int (*count_fn)(int);
typedef int (*cb_fn)(void *);

static void *sym(void *h, const char *name) {
    void *p = dlsym(h, name);
    if (!p) {
        fprintf(stderr, "lifecycle: dlsym(%s): %s\n", name, dlerror());
        exit(2);
    }
    return p;
}

int main(int argc, char **argv) {
    const char *path = (argc > 1) ? argv[1] : "lifecycle.so";
    void *h = dlopen(path, RTLD_NOW);
    if (!h) {
        fprintf(stderr, "lifecycle: dlopen(%s): %s\n", path, dlerror());
        return 2;
    }
    void *raw;
    create_fn onCreate;
    count_fn count;
    raw = sym(h, "ANativeActivity_onCreate");
    memcpy(&onCreate, &raw, sizeof onCreate);
    raw = sym(h, "aster_lifecycle_count");
    memcpy(&count, &raw, sizeof count);

    // ANativeActivity.callbacks is the struct's first pointer; the table has
    // thirteen entries (7 lifecycle + 6 window/input) and starts all zero.
    void *cbtab[13];
    memset(cbtab, 0, sizeof cbtab);
    void *activity[2];
    activity[0] = cbtab;
    activity[1] = 0;

    if (onCreate(activity, 0, 0) != 0) {
        fprintf(stderr, "lifecycle: ANativeActivity_onCreate did not return 0\n");
        return 2;
    }

    static const char *names[7] = {"onStart", "onResume", "onPause", "onStop",
                                   "onDestroy", "onConfigurationChanged", "onLowMemory"};
    int i;
    for (i = 0; i < 7; ++i) {
        if (!cbtab[i]) {
            fprintf(stderr, "lifecycle: slot %d (%s) was not installed\n", i, names[i]);
            return 3;
        }
    }
    // The window and input slots belong to the render and touch examples; this
    // one must leave them alone.
    for (i = 7; i < 13; ++i) {
        if (cbtab[i]) {
            fprintf(stderr, "lifecycle: slot %d (window/input) installed unexpectedly\n", i);
            return 3;
        }
    }

    for (i = 0; i < 7; ++i) {
        cb_fn cb;
        void *p = cbtab[i];
        memcpy(&cb, &p, sizeof cb);
        cb(activity);
    }
    for (i = 0; i < 7; ++i) {
        int c = count(i);
        if (c != 1) {
            fprintf(stderr, "lifecycle: count(%d) [%s] = %d, want 1\n", i, names[i], c);
            return 4;
        }
    }
    // A second call to one slot: the counters accumulate rather than saturate.
    {
        cb_fn cb;
        void *p = cbtab[0];
        memcpy(&cb, &p, sizeof cb);
        cb(activity);
    }
    if (count(0) != 2) {
        fprintf(stderr, "lifecycle: count(0) after two onStart calls = %d, want 2\n", count(0));
        return 4;
    }
    if (count(7) != -1) {
        fprintf(stderr, "lifecycle: count(7) = %d, want -1\n", count(7));
        return 4;
    }
    printf("lifecycle: 7 callbacks installed at offsets 0..48 and driven; "
           "count(0)=%d after one extra call, out-of-range count(7)=%d\n",
           count(0), count(7));
    return 0;
}
