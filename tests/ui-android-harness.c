// ui-android-harness.c -- device-free driver for the AsterUI Android
// backend (asterui/backend/android.ast).
//
// dlopens the Counter .so, builds a fake ANativeActivity with a zeroed
// 16-entry callback table, and drives it the way Android would: onCreate,
// window created, input queue created, DOWN+UP through the stored looper
// callback, pause/resume, configuration change, teardown. The fake window
// and input queue come from tests/ui-android-stub.c (built as liblog.so
// and libandroid.so); the stub helpers are resolved from the loaded stub
// libraries via the stub handle.
//
// Usage: ui-android-harness <libcounter.so> [--expect-text-pixels] [--lazy-dlopen]
//   --expect-text-pixels: also assert the buffer hash changes after the
//   tap. That needs a rasterizer that draws text (render/raster.ast);
//   the RECT-only stand-in used before it lands leaves the hash unchanged
//   (the count text is not drawn), so the flag stays off until then.
//   --lazy-dlopen: dlopen the .so with RTLD_LAZY instead of RTLD_NOW,
//   so the first-ever AMotionEvent_getX / lrintf calls resolve their
//   PLT slots lazily on the cold first tap, as on Android (M1.2a cold
//   path). The default RTLD_NOW run binds every PLT slot eagerly at
//   load, which is exactly the step qemu used to mask the zero-arg
//   bridge bug; the lazy run is the closest qemu gets to the device.
//
// Prints one PASS line per check group and exits 0 only if all pass.
// Built for AArch64 and run under qemu-aarch64 (see tests/ui-checks.sh
// for the suggested integration; the HOSTCC/RUNNER skip rule mirrors
// tests/lifecycle-callbacks.sh).
//
// Callback table slots (android/native_activity.h, AOSP
// android-7.1.1_r58 -- all pointers, 8 bytes each): 0 onStart,
// 1 onResume, 2 onSaveInstanceState, 3 onPause, 4 onStop, 5 onDestroy,
// 6 onWindowFocusChanged, 7 onNativeWindowCreated, 8 onNativeWindowResized,
// 9 onNativeWindowRedrawNeeded, 10 onNativeWindowDestroyed,
// 11 onInputQueueCreated, 12 onInputQueueDestroyed, 13 onContentRectChanged,
// 14 onConfigurationChanged, 15 onLowMemory.
// M1.2d: the pre-fix table omitted onSaveInstanceState and
// onWindowFocusChanged and put onConfigurationChanged@5 / onLowMemory@6;
// every slot number below is the TRUE one, so a stale .so fails here
// instead of silently driving the wrong handler.
//
// Colour expectations (packed RGB -> little-endian pixel word R | G<<8 |
// B<<16 | 0xFF<<24): UI_COLOR_BG = RGB(32,32,32) -> 0xFF202020;
// UI_COLOR_BUTTON = RGB(58,110,165) -> 0xFFA56E3A (see asterui/view/node.ast).
// Button geometry for the 400x300 Counter (hand-computed in M0, pad 8,
// gap 8: label 64x16 at (8,8), button 88x32 at (8,32)) -- M1.1: the
// 480 dpi top inset (72 px) shifts both down by 72, so the label is at
// (8,80) and the button at (8,104) with centre (52,120). M1.2c: the
// 480 dpi density scale (q8 768, ui_dp(8) = 24) triples the dp sizes
// and the insets shift them down, so the label is at (24,96,
// 192x48) and the button at (24,168, 264x96) with centre (156,216);
// the footer sits at (24,288, 288x96). The 48dp minimum touch
// target is 144 px here, so the button hit rect is y [144,312).

#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

typedef int (*create_fn)(void *, void *, int);
typedef int (*noarg_fn)(void);
typedef long long (*now_fn)(void);
typedef int (*key_fn)(int);
typedef int (*cb1_fn)(void *);
typedef int (*cb2_fn)(void *, void *);
typedef int (*cb2i_fn)(void *, int);

typedef void *(*create_window_fn)(int, int);
typedef void (*destroy_window_fn)(void *);
typedef void (*resize_window_fn)(void *, int, int);
typedef uint32_t (*pixel_fn)(void *, int, int);
typedef uint32_t (*hash_fn)(void *);
typedef int (*frames_fn)(void *);
typedef void *(*create_queue_fn)(void);
typedef void (*destroy_queue_fn)(void *);
typedef void (*push_motion_fn)(void *, int, float, float);
typedef void (*push_key_fn)(void *, int, int);
typedef int (*fire_looper_fn)(void);
typedef void *(*looper_cb_fn)(void);
typedef void (*set_density_fn)(int);
typedef void *(*asset_fn)(void);

// Read a whole file into a malloc'd NUL-terminated buffer, or 0.
static char *read_file(const char *path) {
    FILE *f = fopen(path, "rb");
    long n;
    char *buf;
    if (!f) return 0;
    fseek(f, 0, SEEK_END);
    n = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (n < 0) {
        fclose(f);
        return 0;
    }
    buf = (char *)malloc((size_t)n + 1);
    if (!buf) {
        fclose(f);
        return 0;
    }
    if (n > 0 && fread(buf, 1, (size_t)n, f) != (size_t)n) {
        free(buf);
        fclose(f);
        return 0;
    }
    buf[n] = '\0';
    fclose(f);
    return buf;
}

static int failures = 0;

static void check(int cond, const char *msg) {
    if (!cond) {
        fprintf(stderr, "FAIL: android-harness %s\n", msg);
        failures++;
    }
}

static void check_contains(const char *hay, const char *needle, const char *msg) {
    check(hay != 0 && strstr(hay, needle) != 0, msg);
}

// Occurrences of needle in hay (0 when hay is 0 or needle is absent).
static int count_substr(const char *hay, const char *needle) {
    int n = 0;
    const char *p;
    size_t len;
    if (!hay || !needle || !*needle) return 0;
    len = strlen(needle);
    p = hay;
    while ((p = strstr(p, needle)) != 0) {
        n++;
        p += len;
    }
    return n;
}

// Index of the LAST occurrence of needle in hay, or -1 when absent.
static long last_index(const char *hay, const char *needle) {
    long last = -1;
    const char *p;
    size_t len;
    if (!hay || !needle || !*needle) return -1;
    len = strlen(needle);
    p = hay;
    while ((p = strstr(p, needle)) != 0) {
        last = (long)(p - hay);
        p += len;
    }
    return last;
}

static void *sym(void *h, const char *name) {
    void *p = dlsym(h, name);
    if (!p) {
        fprintf(stderr, "android-harness: dlsym(%s): %s\n", name, dlerror());
        exit(2);
    }
    return p;
}

// A NULL slot answers -1 instead of crashing: a stale .so that never
// installed a slot then fails its check cleanly (group [1] reports
// which slot is missing) instead of segfaulting the harness.
static int call1(void *cbtab[], int slot, void *activity) {
    cb1_fn cb;
    void *p = cbtab[slot];
    if (!p) return -1;
    memcpy(&cb, &p, sizeof cb);
    return cb(activity);
}

static int call2(void *cbtab[], int slot, void *activity, void *arg) {
    cb2_fn cb;
    void *p = cbtab[slot];
    if (!p) return -1;
    memcpy(&cb, &p, sizeof cb);
    return cb(activity, arg);
}

// Two-argument call with an int second argument (onWindowFocusChanged
// takes (activity, int hasFocus)); NULL slot answers -1 as above.
static int call2i(void *cbtab[], int slot, void *activity, int arg) {
    cb2i_fn cb;
    void *p = cbtab[slot];
    if (!p) return -1;
    memcpy(&cb, &p, sizeof cb);
    return cb(activity, arg);
}

int main(int argc, char **argv) {
    const char *path;
    int expect_text_pixels = 0;
    int lazy_dlopen = 0;
    void *h;
    void *stub_h;
    create_fn onCreate;
    noarg_fn counter, frames, paused, layout_dirty;
    noarg_fn dpi, inset_top, inset_bottom, inset_left, inset_right, log_lines;
    noarg_fn density_q8, dp48;
    now_fn now_ms;
    key_fn key_x, key_y, key_cx, key_cy;
    create_window_fn create_window;
    destroy_window_fn destroy_window;
    resize_window_fn resize_window;
    pixel_fn pixel;
    hash_fn buffer_hash;
    frames_fn frames_presented;
    create_queue_fn create_queue;
    destroy_queue_fn destroy_queue;
    push_motion_fn push_motion;
    push_key_fn push_key;
    fire_looper_fn fire_looper;
    looper_cb_fn looper_cb;
    set_density_fn set_density;
    asset_fn stub_asset_manager;
    void *cbtab[16];
    // M1.1: the fake ANativeActivity is 16 words so the backend can
    // read internalDataPath@32 (index 4), externalDataPath@40 (index
    // 5) and assetManager@64 (index 8) without reading past the end.
    // The two data paths point at mkdtemp subdirectories, so the
    // backend's asterui.log files land where this harness can read
    // them back.
    void *activity[16];
    char tmpdir[] = "/tmp/ui-harness-XXXXXX";
    char internal_dir[512];
    char external_dir[512];
    char internal_log[512];
    char external_log[512];
    void *win, *queue;
    int cx, cy, kx, ky;
    uint32_t hash_before, hash_after;
    long long t0, t1, t2;
    long long tc0, tc1;
    size_t out_size;
    int rect_arg[4];
    int lowmem_before, lowmem_after;
    int taps_before;
    long p_pause, p_stop, p_save, p_destroy;
    void *raw;
    char *log_internal, *log_external;

    if (argc < 2) {
        fprintf(stderr, "usage: ui-android-harness <libcounter.so> [--expect-text-pixels] [--lazy-dlopen]\n");
        return 2;
    }
    path = argv[1];
    {
        int ai;
        for (ai = 2; ai < argc; ai++) {
            if (strcmp(argv[ai], "--expect-text-pixels") == 0)
                expect_text_pixels = 1;
            else if (strcmp(argv[ai], "--lazy-dlopen") == 0)
                lazy_dlopen = 1;
            else {
                fprintf(stderr, "usage: ui-android-harness <libcounter.so> [--expect-text-pixels] [--lazy-dlopen]\n");
                return 2;
            }
        }
    }

    h = dlopen(path, lazy_dlopen ? RTLD_LAZY : RTLD_NOW);
    if (!h) {
        fprintf(stderr, "android-harness: dlopen(%s): %s\n", path, dlerror());
        return 2;
    }
    // The stub helpers live in libandroid.so, a dependency of the Counter
    // .so. dlopen() defaults to RTLD_LOCAL, so they are not in RTLD_DEFAULT;
    // open the stub library explicitly (it is already loaded) and resolve
    // the helpers from its handle.
    {
        void *sh = dlopen("libandroid.so", RTLD_NOW);
        if (!sh) {
            fprintf(stderr, "android-harness: dlopen(libandroid.so): %s\n", dlerror());
            return 2;
        }
        stub_h = sh;
    }
    raw = sym(h, "ANativeActivity_onCreate");
    memcpy(&onCreate, &raw, sizeof onCreate);
    raw = sym(h, "asterui_counter");
    memcpy(&counter, &raw, sizeof counter);
    raw = sym(h, "asterui_frames");
    memcpy(&frames, &raw, sizeof frames);
    raw = sym(h, "asterui_paused");
    memcpy(&paused, &raw, sizeof paused);
    raw = sym(h, "asterui_layout_dirty");
    memcpy(&layout_dirty, &raw, sizeof layout_dirty);
    raw = sym(h, "asterui_dpi");
    memcpy(&dpi, &raw, sizeof dpi);
    raw = sym(h, "asterui_inset_top");
    memcpy(&inset_top, &raw, sizeof inset_top);
    raw = sym(h, "asterui_inset_bottom");
    memcpy(&inset_bottom, &raw, sizeof inset_bottom);
    raw = sym(h, "asterui_inset_left");
    memcpy(&inset_left, &raw, sizeof inset_left);
    raw = sym(h, "asterui_inset_right");
    memcpy(&inset_right, &raw, sizeof inset_right);
    raw = sym(h, "asterui_log_lines");
    memcpy(&log_lines, &raw, sizeof log_lines);
    raw = sym(h, "asterui_density_q8");
    memcpy(&density_q8, &raw, sizeof density_q8);
    raw = sym(h, "asterui_dp48");
    memcpy(&dp48, &raw, sizeof dp48);
    raw = sym(h, "ui_android_now_ms");
    memcpy(&now_ms, &raw, sizeof now_ms);
    raw = sym(h, "asterui_key_x");
    memcpy(&key_x, &raw, sizeof key_x);
    raw = sym(h, "asterui_key_y");
    memcpy(&key_y, &raw, sizeof key_y);
    raw = sym(h, "asterui_key_cx");
    memcpy(&key_cx, &raw, sizeof key_cx);
    raw = sym(h, "asterui_key_cy");
    memcpy(&key_cy, &raw, sizeof key_cy);

    raw = sym(stub_h, "ui_stub_create_window");
    memcpy(&create_window, &raw, sizeof create_window);
    raw = sym(stub_h, "ui_stub_destroy_window");
    memcpy(&destroy_window, &raw, sizeof destroy_window);
    raw = sym(stub_h, "ui_stub_resize_window");
    memcpy(&resize_window, &raw, sizeof resize_window);
    raw = sym(stub_h, "ui_stub_pixel");
    memcpy(&pixel, &raw, sizeof pixel);
    raw = sym(stub_h, "ui_stub_buffer_hash");
    memcpy(&buffer_hash, &raw, sizeof buffer_hash);
    raw = sym(stub_h, "ui_stub_frames_presented");
    memcpy(&frames_presented, &raw, sizeof frames_presented);
    raw = sym(stub_h, "ui_stub_create_queue");
    memcpy(&create_queue, &raw, sizeof create_queue);
    raw = sym(stub_h, "ui_stub_destroy_queue");
    memcpy(&destroy_queue, &raw, sizeof destroy_queue);
    raw = sym(stub_h, "ui_stub_push_motion");
    memcpy(&push_motion, &raw, sizeof push_motion);
    raw = sym(stub_h, "ui_stub_push_key");
    memcpy(&push_key, &raw, sizeof push_key);
    raw = sym(stub_h, "ui_stub_fire_looper");
    memcpy(&fire_looper, &raw, sizeof fire_looper);
    raw = sym(stub_h, "ui_stub_looper_cb");
    memcpy(&looper_cb, &raw, sizeof looper_cb);
    raw = sym(stub_h, "ui_stub_set_density");
    memcpy(&set_density, &raw, sizeof set_density);
    raw = sym(stub_h, "ui_stub_asset_manager");
    memcpy(&stub_asset_manager, &raw, sizeof stub_asset_manager);

    // M1.1: log directories for the backend's two asterui.log files.
    check(mkdtemp(tmpdir) != 0, "mkdtemp failed");
    snprintf(internal_dir, sizeof internal_dir, "%s/internal", tmpdir);
    snprintf(external_dir, sizeof external_dir, "%s/external", tmpdir);
    snprintf(internal_log, sizeof internal_log, "%s/internal/asterui.log", tmpdir);
    snprintf(external_log, sizeof external_log, "%s/external/asterui.log", tmpdir);
    check(mkdir(internal_dir, 0700) == 0, "mkdir internal log dir failed");
    check(mkdir(external_dir, 0700) == 0, "mkdir external log dir failed");
    set_density(480);

    // [1] onCreate installs all 16 callbacks.
    memset(cbtab, 0, sizeof cbtab);
    memset(activity, 0, sizeof activity);
    activity[0] = cbtab;
    activity[4] = internal_dir;
    activity[5] = external_dir;
    activity[8] = stub_asset_manager();
    check(onCreate(activity, 0, 0) == 0, "ANativeActivity_onCreate did not return 0");
    {
        int i, all = 1;
        for (i = 0; i < 16; i++) {
            if (!cbtab[i]) {
                fprintf(stderr, "FAIL: android-harness slot %d was not installed\n", i);
                all = 0;
            }
        }
        check(all, "not all 16 callback slots installed");
    }
    check(call1(cbtab, 0, activity) == 0, "onStart did not return 0");
    if (failures == 0)
        printf("PASS: android-harness 16 callbacks installed (onCreate=0, onStart ran)\n");

    // [2] First frame: window created presents into the fake buffer.
    // M1.2c: density 480 -> top inset 72 and q8 768, so the dp-sized
    // Counter is three times the 160 dpi geometry, shifted down by
    // the inset: label (24,96,192x48), button (24,168,264x96) with
    // centre (156,216) -- below the 72 px status-bar estimate. The
    // background still covers (0,0), and the 48dp touch target is
    // 144 px (asterui_dp48).
    win = create_window(400, 300);
    check(win != 0, "could not create the fake window");
    hash_before = 0;
    if (win) {
        check(call2(cbtab, 7, activity, win) == 0, "window-created did not return 0");
        check(frames_presented(win) == 1, "first frame was not presented");
        check(frames() == 1, "asterui_frames() != 1 after window created");
        check(dpi() == 480, "asterui_dpi() != 480");
        check(inset_top() == 72, "asterui_inset_top() != 72 at 480 dpi");
        check(inset_bottom() == 0, "asterui_inset_bottom() != 0");
        check(inset_left() == 0, "asterui_inset_left() != 0");
        check(inset_right() == 0, "asterui_inset_right() != 0");
        check(density_q8() == 768, "asterui_density_q8() != 768 at 480 dpi");
        check(dp48() == 144, "asterui_dp48() != 144 at 480 dpi");
        check(log_lines() > 0, "no log lines written by onCreate/first frame");
        cx = key_cx(2);
        cy = key_cy(2);
        kx = key_x(2);
        ky = key_y(2);
        check(cx == 156 && cy == 216, "button centre is not (156,216) at 480 dpi with top inset 72");
        check(kx == 24 && ky == 168, "button origin is not (24,168) at 480 dpi with top inset 72");
        check(pixel(win, 0, 0) == 0xFF202020u, "background pixel (0,0) is not 0xFF202020");
        check(pixel(win, kx + 2, ky + 2) == 0xFFA56E3Au, "button pixel is not 0xFFA56E3A");
        hash_before = buffer_hash(win);
        printf("android-harness: hash before tap=0x%08x frames=%d counter=%d dpi=%d inset_top=%d\n",
               hash_before, frames(), counter(), dpi(), inset_top());
    } else {
        cx = cy = -1;
    }
    if (failures == 0)
        printf("PASS: android-harness first frame presented (frames=1, button centre=(156,216), bg=0xFF202020, button=0xFFA56E3A, dpi=480, inset_top=72, q8=768, dp48=144)\n");

    // [3] Tap: DOWN+UP at the button centre counts once; an off-button
    // DOWN+UP counts nothing and presents nothing.
    // M1.2a cold path: this is the FIRST-ever coordinate capture in
    // this process -- no f32-returning call precedes it (onCreate /
    // first frame use integers only), and with --lazy-dlopen the
    // getX / lrintf PLT slots resolve lazily on this very tap, as on
    // Android. A capture that read (0,0) would miss the button here,
    // so counter 0->1 through the real input path is the cold-path
    // proof; group [8] extends it to fractional coordinates.
    queue = create_queue();
    check(queue != 0, "could not create the fake input queue");
    if (queue) {
        check(call2(cbtab, 11, activity, queue) == 0, "input-queue-created did not return 0");
        check(looper_cb() != 0, "looper callback was not stored by attachLooper");
        push_motion(queue, 0, (float)cx, (float)cy); // DOWN
        push_motion(queue, 1, (float)cx, (float)cy); // UP
        check(fire_looper() == 1, "looper callback did not return 1");
        check(counter() == 1, "counter != 1 after DOWN+UP on the button");
        check(frames() == 2, "asterui_frames() != 2 after tap (no frame on UP)");
        check(frames_presented(win) == 2, "fake window saw != 2 frames after tap");
        hash_after = buffer_hash(win);
        printf("android-harness: hash after tap=0x%08x frames=%d counter=%d\n",
               hash_after, frames(), counter());
        if (expect_text_pixels) {
            check(hash_after != hash_before, "buffer hash did not change after tap");
        } else {
            printf("android-harness: hash unchanged after tap (expected: RECT-only stand-in raster draws no text; re-run with --expect-text-pixels once render/raster.ast lands)\n");
        }
        push_motion(queue, 0, 5.0f, 5.0f); // DOWN off-button
        push_motion(queue, 1, 5.0f, 5.0f); // UP off-button
        check(fire_looper() == 1, "looper callback did not return 1 on off-button tap");
        check(counter() == 1, "off-button DOWN+UP changed the counter");
        check(frames() == 2, "off-button DOWN+UP presented a frame");
    }
    if (failures == 0)
        printf("PASS: android-harness tap counts (counter=1, frames=2, off-button tap ignored)\n");

    // [4] Pause/resume: no frame while paused, the clock frozen while
    // paused, no jump across a 2 s background interval, counter kept.
    t0 = now_ms();
    check(call1(cbtab, 3, activity) == 0, "onPause did not return 0");
    check(paused() == 1, "asterui_paused() != 1 after onPause");
    check(call2(cbtab, 9, activity, win) == 0, "redraw-needed did not return 0 while paused");
    check(frames() == 2, "a frame was presented while paused");
    sleep(2);
    t1 = now_ms();
    check(t1 >= t0 && t1 - t0 <= 50, "clock advanced while paused");
    check(call1(cbtab, 1, activity) == 0, "onResume did not return 0");
    check(paused() == 0, "asterui_paused() != 0 after onResume");
    check(call2(cbtab, 9, activity, win) == 0, "redraw-needed did not return 0 after resume");
    check(frames() == 3, "asterui_frames() != 3 after resume + redraw");
    check(counter() == 1, "counter changed across pause/resume");
    t2 = now_ms();
    check(t2 >= t0 && t2 - t0 < 1000, "clock jumped across the 2 s pause");
    printf("android-harness: clock before pause=%lldms, while paused=%lldms, after resume=%lldms\n",
           t0, t1, t2);
    if (failures == 0)
        printf("PASS: android-harness pause/resume (no frame while paused, clock frozen, no jump, counter=1)\n");

    // [5] Rotation: config change flags layout-dirty, the resized window
    // re-lays out, state is kept.
    check(call1(cbtab, 14, activity) == 0, "onConfigurationChanged did not return 0");
    check(layout_dirty() == 1, "layout-dirty flag not set by onConfigurationChanged");
    resize_window(win, 300, 400);
    check(call2(cbtab, 8, activity, win) == 0, "window-resized did not return 0");
    check(frames() == 4, "asterui_frames() != 4 after resize");
    check(layout_dirty() == 0, "layout-dirty flag not consumed by the resized frame");
    check(counter() == 1, "counter changed across rotation");
    // M1.2c addendum (input-type fix): the centre x is 150, not 156,
    // after rotation -- the 264 px button is wider than the 252 px
    // avail width of a 300 px window (300 - 2*24 px pad), so
    // ui_measure clamps it to 252 and its centre is 24 + 126 = 150.
    // The y centre stays 216 (width-independent).
    check(key_cx(2) == 150 && key_cy(2) == 216, "button not laid out after rotation (want centre (150,216), top inset 72)");
    check(pixel(win, 0, 0) == 0xFF202020u, "background pixel (0,0) is not 0xFF202020 after rotation");
    if (failures == 0)
        printf("PASS: android-harness rotation keeps state (300x400, frames=4, counter=1)\n");

    // [7] M1.1 SafeArea fallback + log files. An unknown density (0)
    // falls back to 160 dpi -> top inset 24; restoring 480 brings
    // back 72, and the next redraw lays the button out at y 104
    // again. Both asterui.log files hold the onCreate, window, tap
    // and count lines.
    set_density(0);
    check(onCreate(activity, 0, 0) == 0, "onCreate did not return 0 on density re-probe");
    check(dpi() == 0, "asterui_dpi() != 0 after stub density 0");
    check(inset_top() == 24, "asterui_inset_top() != 24 for unknown density (want 160 dpi fallback)");
    check(density_q8() == 256, "asterui_density_q8() != 256 for unknown density (want 160 dpi fallback)");
    check(dp48() == 48, "asterui_dp48() != 48 for unknown density (want 160 dpi fallback)");
    set_density(480);
    check(onCreate(activity, 0, 0) == 0, "onCreate did not return 0 restoring density 480");
    check(dpi() == 480, "asterui_dpi() != 480 after restoring density");
    check(inset_top() == 72, "asterui_inset_top() != 72 after restoring density 480");
    check(density_q8() == 768, "asterui_density_q8() != 768 after restoring density 480");
    check(dp48() == 144, "asterui_dp48() != 144 after restoring density 480");
    check(call2(cbtab, 9, activity, win) == 0, "redraw-needed did not return 0 after inset restore");
    check(frames() == 5, "asterui_frames() != 5 after inset-restore redraw");
    check(key_cy(2) == 216, "button centre y != 216 after inset restore");
    log_internal = read_file(internal_log);
    log_external = read_file(external_log);
    check(log_internal != 0, "internal asterui.log was not written");
    check(log_external != 0, "external asterui.log was not written");
    check_contains(log_internal, "android: onCreate", "internal log has no onCreate line");
    check_contains(log_internal, "insets dpi 480 top 72 bottom 0", "internal log has no insets line");
    check_contains(log_internal, "window 400x300 inset top 72", "internal log has no window line");
    check_contains(log_internal, "tap down 156 216 hit 1", "internal log has no tap-down line");
    check_contains(log_internal, "tap up 156 216 fired 1", "internal log has no tap-up line");
    check_contains(log_internal, "count 1", "internal log has no count line");
    check_contains(log_external, "android: onCreate", "external log has no onCreate line");
    check_contains(log_external, "count 1", "external log has no count line");
    if (log_internal) {
        printf("android-harness: internal log first line: %.*s\n", 60, log_internal);
        free(log_internal);
    }
    if (log_external) free(log_external);
    if (failures == 0)
        printf("PASS: android-harness SafeArea fallback (0 dpi -> top 24, 480 dpi -> top 72) + both asterui.log files hold onCreate/window/tap/count\n");

    // [8] M1.2a touch coordinates: fractional taps, window corner,
    // off-button point. These taps prove the float reached the
    // converter with its fractional part intact: a (156.6, 216.6) tap
    // must log "tap down 157 217 hit 1" (round-half-to-even) and
    // increment the counter -- a (0,0) capture would miss the button
    // entirely -- and a corner tap must log its true coordinates,
    // never 0,0. Button centre is (156,216) at 480 dpi: rotation kept
    // the 72 px top inset, and the window is now 300x400. The corner
    // moved to the top-right (299,10): the bottom-right corner
    // (299,399) is inside the footer's 48dp slop rect at this density
    // (footer hit rect x [24,312), y [264,408)), so it would fire the
    // footer instead of missing. The off-button point is (16,380):
    // inside the window but left of every hit rect (button hit rect
    // x [24,288), y [144,312); footer x [24,312)).
    check(frames() == 5, "frames != 5 entering touch-coordinate group");
    check(counter() == 1, "counter != 1 entering touch-coordinate group");
    push_motion(queue, 0, 156.6f, 216.6f); // DOWN, fractional centre
    push_motion(queue, 1, 156.6f, 216.6f); // UP
    check(fire_looper() == 1, "looper callback did not return 1 on fractional-centre tap");
    check(counter() == 2, "counter != 2 after fractional-centre DOWN+UP");
    check(frames() == 6, "asterui_frames() != 6 after fractional-centre tap");
    push_motion(queue, 0, 299.4f, 10.4f); // DOWN at the top-right window corner
    push_motion(queue, 1, 299.4f, 10.4f); // UP at the top-right window corner
    check(fire_looper() == 1, "looper callback did not return 1 on corner tap");
    check(counter() == 2, "corner DOWN+UP changed the counter");
    check(frames() == 6, "corner DOWN+UP presented a frame");
    push_motion(queue, 0, 15.7f, 380.3f); // DOWN off-button, fractional
    push_motion(queue, 1, 15.7f, 380.3f); // UP off-button
    check(fire_looper() == 1, "looper callback did not return 1 on fractional off-button tap");
    check(counter() == 2, "fractional off-button DOWN+UP changed the counter");
    check(frames() == 6, "fractional off-button DOWN+UP presented a frame");
    log_internal = read_file(internal_log);
    check(log_internal != 0, "internal asterui.log was not readable for coordinate checks");
    check_contains(log_internal, "tap down 157 217 hit 1", "internal log has no fractional-centre tap line (want 157 217, round-half-to-even)");
    check_contains(log_internal, "tap up 157 217 fired 1", "internal log has no fractional-centre tap-up line");
    check_contains(log_internal, "tap down 299 10 hit 0", "internal log has no window-corner tap line (want true coords 299 10, never 0 0)");
    check_contains(log_internal, "tap down 16 380 hit 0", "internal log has no fractional off-button tap line");
    if (log_internal) free(log_internal);
    if (failures == 0)
        printf("PASS: android-harness touch coordinates (fractional centre 156.6,216.6 -> 157,217 counts, corner 299,10 + off-button 16,380 log true coords, counter=2, frames=6)\n");

    // [9] M1.2b clock + M1.2d true 16-slot table: every slot is driven
    // through its TRUE offset and must run the right handler.
    //   Clock: a resume with NO pause behind it must not move the
    //   epoch. Before the M1.2b fix the first such resume shifted the
    //   epoch by the whole raw monotonic time (the stale pause raw was
    //   still 0), so now_ms() went to about minus the device uptime.
    //   Save (slot 2): *outSize = 0, NULL return, log line.
    //   Focus (slot 6): focus log lines, paused stays 0, and the
    //   onLowMemory count does NOT move -- before the M1.2d fix this
    //   slot held on_low_memory, so a focus gain logged onLowMemory.
    //   Content rect (slot 13): log line only. Config (slot 14):
    //   layout-dirty + insets recompute. Low memory (slot 15): the
    //   REAL onLowMemory line + the measurement-cache-drop line.
    //   Memory: the first-frame log holds the pixel-buffer byte size
    //   (400x300x4) and the retained-pool live count.
    check(frames() == 6, "frames != 6 entering lifecycle group");
    check(counter() == 2, "counter != 2 entering lifecycle group");
    tc0 = now_ms();
    check(tc0 >= 0, "clock already negative before the pauseless resume");
    check(call1(cbtab, 1, activity) == 0, "onResume (no pause) did not return 0");
    tc1 = now_ms();
    check(tc1 >= 0, "clock went negative after a resume with no pause (epoch double-count)");
    check(tc1 >= tc0 && tc1 - tc0 < 60000, "clock jumped across a pauseless resume");
    printf("android-harness: clock pauseless resume before=%lldms after=%lldms\n",
           tc0, tc1);
    out_size = 99;
    check(call2(cbtab, 2, activity, &out_size) == 0, "onSaveInstanceState did not return NULL");
    check(out_size == 0, "onSaveInstanceState did not store 0 to *outSize");
    lowmem_before = 0;
    log_internal = read_file(internal_log);
    if (log_internal) {
        lowmem_before = count_substr(log_internal, "onLowMemory");
        free(log_internal);
        log_internal = 0;
    }
    check(call2i(cbtab, 6, activity, 1) == 0, "onWindowFocusChanged(1) did not return 0");
    check(paused() == 0, "focus gain paused the app");
    check(call2i(cbtab, 6, activity, 0) == 0, "onWindowFocusChanged(0) did not return 0");
    check(paused() == 0, "focus loss paused the app");
    rect_arg[0] = 0; rect_arg[1] = 0; rect_arg[2] = 300; rect_arg[3] = 400;
    check(call2(cbtab, 13, activity, rect_arg) == 0, "onContentRectChanged did not return 0");
    check(call1(cbtab, 14, activity) == 0, "onConfigurationChanged (slot 14) did not return 0");
    check(layout_dirty() == 1, "layout-dirty flag not set by onConfigurationChanged (slot 14)");
    check(dpi() == 480, "dpi changed across the slot-14 config change");
    check(inset_top() == 72, "inset_top != 72 after the slot-14 config change");
    check(call1(cbtab, 15, activity) == 0, "onLowMemory (slot 15) did not return 0");
    check(counter() == 2, "counter changed across the lifecycle group");
    check(frames() == 6, "a frame was presented by the lifecycle group");
    log_internal = read_file(internal_log);
    check(log_internal != 0, "internal asterui.log was not readable for lifecycle checks");
    check_contains(log_internal, "android: onSaveInstanceState", "internal log has no onSaveInstanceState line");
    check_contains(log_internal, "android: focus 1", "internal log has no focus-gain line");
    check_contains(log_internal, "android: focus 0", "internal log has no focus-loss line");
    check_contains(log_internal, "android: content rect changed", "internal log has no content-rect line");
    check_contains(log_internal, "android: onConfigurationChanged", "internal log has no slot-14 config line");
    check_contains(log_internal, "android: onLowMemory: measurement cache cleared", "internal log has no real-onLowMemory cache-drop line");
    check_contains(log_internal, "pixel buffer 400x300 bytes 480000", "internal log has no pixel-buffer memory line");
    check_contains(log_internal, "retained pool live", "internal log has no retained-pool memory line");
    if (log_internal) {
        lowmem_after = count_substr(log_internal, "onLowMemory");
        free(log_internal);
        log_internal = 0;
    } else {
        lowmem_after = -1;
    }
    check(lowmem_after == lowmem_before + 1, "onLowMemory count moved by more than the one real slot-15 call (focus must not log it)");
    if (failures == 0)
        printf("PASS: android-harness lifecycle true offsets (pauseless resume clock %lld->%lldms, save/focus/rect/config/lowmem slots, memory lines)\n",
               tc0, tc1);

    // [10] Input event type dispatch (M1.2a addendum): motion is type 2
    // (AINPUT_EVENT_TYPE_MOTION), key is type 1 (AINPUT_EVENT_TYPE_KEY),
    // per AOSP include/android/input.h (frozen enums). The M1 drain
    // treated type 1 as motion, so real motion was silently dropped
    // and real keys were mis-parsed as motion. This group pins both:
    // a type-2 DOWN+UP at the button centre must count (with the old
    // `typ == 1` drain it is dropped and the counter stays 2), and a
    // type-1 key DOWN+UP must NOT tap (counter/frames unchanged, no
    // new "tap down" line) but MUST log "key <code> action <act>".
    // Button centre is re-read, not assumed: rotation kept the 72 px
    // top inset, so it is (150,216) at 480 dpi (M1.2c) -- 150, not
    // 156, because the 264 px button clamps to the 252 px avail width
    // of the 300 px window (see group [5]).
    check(frames() == 6, "frames != 6 entering input-type group");
    check(counter() == 2, "counter != 2 entering input-type group");
    cx = key_cx(2);
    cy = key_cy(2);
    check(cx == 150 && cy == 216, "button centre is not (150,216) entering input-type group");
    push_motion(queue, 0, (float)cx, (float)cy); // DOWN, type 2
    push_motion(queue, 1, (float)cx, (float)cy); // UP, type 2
    check(fire_looper() == 1, "looper callback did not return 1 on type-2 tap");
    check(counter() == 3, "counter != 3 after type-2 DOWN+UP (motion dropped?)");
    check(frames() == 7, "asterui_frames() != 7 after type-2 tap");
    taps_before = 0;
    log_internal = read_file(internal_log);
    if (log_internal) {
        taps_before = count_substr(log_internal, "tap down");
        free(log_internal);
        log_internal = 0;
    }
    push_key(queue, 0, 66); // key DOWN, ENTER, type 1
    push_key(queue, 1, 66); // key UP, ENTER, type 1
    check(fire_looper() == 1, "looper callback did not return 1 on key events");
    check(counter() == 3, "key DOWN+UP changed the counter");
    check(frames() == 7, "key DOWN+UP presented a frame");
    log_internal = read_file(internal_log);
    check(log_internal != 0, "internal asterui.log was not readable for key checks");
    check_contains(log_internal, "key 66 action 0", "internal log has no key-DOWN line (want key 66 action 0)");
    check_contains(log_internal, "key 66 action 1", "internal log has no key-UP line (want key 66 action 1)");
    if (log_internal) {
        check(count_substr(log_internal, "tap down") == taps_before, "a key event produced a tap-down line");
        free(log_internal);
        log_internal = 0;
    }
    if (failures == 0)
        printf("PASS: android-harness input event types (type-2 motion tap counts 2->3, type-1 key 66 logs down/up, no tap, counter=3, frames=7)\n");

    // [6] Teardown, in the true Android exit order: onPause (slot 3),
    // onStop (slot 4), onSaveInstanceState (slot 2), onDestroy
    // (slot 5), then window/input destroyed (slots 10/12). Before
    // the M1.2d fix this drove onStop/onLowMemory/onPause in the
    // wrong order: the real onPause@24 ran on_stop, the real
    // onStop@32 ran on_destroy, and the real onSaveInstanceState@16
    // ran on_pause, so "onPause" logged LAST at exit.
    check(call1(cbtab, 3, activity) == 0, "onPause did not return 0 at teardown");
    check(paused() == 1, "asterui_paused() != 1 after onPause at teardown");
    check(call1(cbtab, 4, activity) == 0, "onStop did not return 0");
    out_size = 99;
    check(call2(cbtab, 2, activity, &out_size) == 0, "onSaveInstanceState did not return NULL at teardown");
    check(out_size == 0, "onSaveInstanceState did not store 0 to *outSize at teardown");
    check(call1(cbtab, 5, activity) == 0, "onDestroy did not return 0");
    check(call2(cbtab, 10, activity, win) == 0, "window-destroyed did not return 0");
    check(call2(cbtab, 12, activity, queue) == 0, "input-queue-destroyed did not return 0");
    check(looper_cb() == 0, "looper callback was not cleared by detachLooper");
    check(counter() == 3, "counter changed across teardown");
    log_internal = read_file(internal_log);
    check(log_internal != 0, "internal asterui.log was not readable for teardown order");
    if (log_internal) {
        p_pause = last_index(log_internal, "android: onPause");
        p_stop = last_index(log_internal, "android: onStop");
        p_save = last_index(log_internal, "android: onSaveInstanceState");
        p_destroy = last_index(log_internal, "android: onDestroy");
        check(p_pause >= 0 && p_stop > p_pause, "teardown log: onStop is not after onPause");
        check(p_save > p_stop, "teardown log: onSaveInstanceState is not after onStop");
        check(p_destroy > p_save, "teardown log: onDestroy is not after onSaveInstanceState");
        free(log_internal);
        log_internal = 0;
    }
    if (failures == 0)
        printf("PASS: android-harness window/input teardown clean (counter=3, exit order onPause<onStop<onSaveInstanceState<onDestroy)\n");

    if (win) destroy_window(win);
    if (queue) destroy_queue(queue);
    if (failures == 0) {
        printf("PASS: ui-android-harness (10/10)\n");
        return 0;
    }
    fprintf(stderr, "FAIL: ui-android-harness (%d check(s) failed)\n", failures);
    return 1;
}
