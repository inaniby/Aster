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
// The example installs the ten non-window/input slots of the 16-slot
// ANativeActivityCallbacks table (M3.6: the old seven-slot install at
// 0..48 was wrong — it omitted onSaveInstanceState@16 and
// onWindowFocusChanged@48 and put onConfigurationChanged@40 /
// onLowMemory@48). The window/input slots 7..12 (56..96) belong to the
// render and touch examples and must stay empty here. Counters are read
// back by index in slot order (0 onStart .. 9 onLowMemory); see
// examples/lifecycle.ast.
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
    // sixteen entries and starts all zero.
    void *cbtab[16];
    memset(cbtab, 0, sizeof cbtab);
    void *activity[2];
    activity[0] = cbtab;
    activity[1] = 0;

    if (onCreate(activity, 0, 0) != 0) {
        fprintf(stderr, "lifecycle: ANativeActivity_onCreate did not return 0\n");
        return 2;
    }

    // The ten installed slots, in table order. Slots 7..12 are the
    // window/input slots and must stay empty in this example.
    static const int installed[10] = {0, 1, 2, 3, 4, 5, 6, 13, 14, 15};
    static const char *names[10] = {"onStart", "onResume", "onSaveInstanceState",
                                    "onPause", "onStop", "onDestroy",
                                    "onWindowFocusChanged", "onContentRectChanged",
                                    "onConfigurationChanged", "onLowMemory"};
    int i;
    for (i = 0; i < 10; ++i) {
        if (!cbtab[installed[i]]) {
            fprintf(stderr, "lifecycle: slot %d (%s) was not installed\n",
                    installed[i], names[i]);
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

    // Drive the one-argument slots: start, resume, pause, stop, destroy,
    // config, lowmem (slots 0, 1, 3, 4, 5, 14, 15).
    static const int one_arg[7] = {0, 1, 3, 4, 5, 14, 15};
    for (i = 0; i < 7; ++i) {
        cb_fn cb;
        void *p = cbtab[one_arg[i]];
        memcpy(&cb, &p, sizeof cb);
        if (cb(activity) != 0) {
            // The callbacks return the log call's result; any value is
            // accepted here — the counters below are the assertion.
        }
    }
    // onSaveInstanceState (slot 2) takes an outSize pointer and answers
    // NULL with *outSize = 0.
    {
        typedef void *(*save_fn)(void *, size_t *);
        save_fn save;
        void *p = cbtab[2];
        memcpy(&save, &p, sizeof save);
        size_t outSize = 7;
        void *ret = save(activity, &outSize);
        if (ret != NULL) {
            fprintf(stderr, "lifecycle: onSaveInstanceState returned non-NULL\n");
            return 3;
        }
        if (outSize != 0) {
            fprintf(stderr, "lifecycle: onSaveInstanceState left *outSize = %zu, want 0\n",
                    outSize);
            return 3;
        }
    }
    // onWindowFocusChanged (slot 6) takes an int: drive it once focused and
    // once unfocused, so both log branches run.
    {
        typedef int (*focus_fn)(void *, int);
        focus_fn focus;
        void *p = cbtab[6];
        memcpy(&focus, &p, sizeof focus);
        focus(activity, 1);
        focus(activity, 0);
    }
    // onContentRectChanged (slot 13) takes a rect pointer; the example only
    // logs, so a plausible rect is enough.
    {
        typedef int (*rect_fn)(void *, void *);
        rect_fn rect;
        void *p = cbtab[13];
        memcpy(&rect, &p, sizeof rect);
        int fake_rect[4] = {0, 0, 400, 300};
        rect(activity, fake_rect);
    }
    // Counters are indexed in slot order: 0 start, 1 resume, 2 save,
    // 3 pause, 4 stop, 5 destroy, 6 focus, 7 rect, 8 config, 9 lowmem.
    // Focus ran twice, everything else once.
    static const int want[10] = {1, 1, 1, 1, 1, 1, 2, 1, 1, 1};
    for (i = 0; i < 10; ++i) {
        int c = count(i);
        if (c != want[i]) {
            fprintf(stderr, "lifecycle: count(%d) [%s] = %d, want %d\n",
                    i, names[i], c, want[i]);
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
    if (count(10) != -1) {
        fprintf(stderr, "lifecycle: count(10) = %d, want -1\n", count(10));
        return 4;
    }
    printf("lifecycle: 10 callbacks installed at offsets 0..120 and driven; "
           "count(0)=%d after one extra call, out-of-range count(10)=%d\n",
           count(0), count(10));
    return 0;
}
