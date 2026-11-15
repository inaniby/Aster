// ui-android-gallery-harness.c -- device-free driver for the AsterUI
// Android backend (asterui/backend/android.ast) with the GALLERY app,
// proving the M3.1b layer tap routing: dialog buttons, menu items, the
// scrim, the menu background and menu tap-outside, through the real
// input path (DOWN+UP via the stored looper callback).
//
// Why a separate file from tests/ui-android-harness.c: that harness is
// Counter-specific (hardcoded Increment geometry, counter()==1, 480 dpi
// layout) and the parent is integrating M3 suite cases against it in
// parallel, so its flow is left untouched. This file reuses the same
// stub/dlopen pattern and the same file-local helpers (check, sym,
// call1/call2/call2i, read_file), but drives libgallery.so at 160 dpi
// with its own groups. Each harness stays independently verifiable.
//
// Usage: ui-android-gallery-harness <libgallery.so> [--lazy-dlopen]
//   --lazy-dlopen: dlopen the .so with RTLD_LAZY instead of RTLD_NOW,
//   so the first-ever layer call (ui_layer_hit_in, ui_menu_outside)
//   resolves its PLT slot lazily on the first layer tap, as on Android
//   (same cold-path argument as the Counter harness [12/18]).
//
// The tap points come from the backend's own geometry diagnostics
// (asterui_key_cx/cy for the main tree, asterui_layer_key_x/y/w/h for
// the layer tree) -- no hardcoded layout numbers. Density is 160 dpi,
// so the Gallery geometry matches the headless gallery_test (400x300,
// inset top 24): the dialog card is 152 px wide, centred, and the
// scrim point (5,5) is above/left of it.
//
// Frame accounting (each fired tap presents exactly one frame; a
// menu-outside DOWN presents one frame for the close; a cancelled
// tap presents none; a dragging MOVE presents one frame, a
// within-slop MOVE presents none):
//   window created 1; Layers tab 2; dialog open 3, OK 4; dialog
//   open 5, Cancel 6; dialog open 7, scrim 8, Cancel 9; menu open 10,
//   item pick 11; menu open 12, outside tap 13; dialog open 14,
//   scrim-blocked page tap 15, Cancel 16; dialog open 17, drag-off
//   (no frame) 17, OK 18; menu open 19, menu drag-off (no frame) 19,
//   padding tap 20, outside tap 21. M4.2: Scroll tab 22; drag 100 px
//   23; two bottom swipes 24, 25; in-list button tap 26; slop tap
//   27; drag-off (MOVE presents) 28; Layers tab 29; dialog open 30,
//   scrim drag (UP presents) 31, Cancel 32; menu open 33, menu drag
//   (no frame) 33, outside tap 34. Teardown presents nothing.
//
// Prints one PASS line per check group and exits 0 only if all pass.
// Built for AArch64 and run under qemu-aarch64 (see tests/ui-checks.sh
// for the suggested integration).
//
// Callback table slots (android/native_activity.h, AOSP
// android-7.1.1_r58): 0 onStart, 1 onResume, 2 onSaveInstanceState,
// 3 onPause, 4 onStop, 5 onDestroy, 6 onWindowFocusChanged,
// 7 onNativeWindowCreated, 8 onNativeWindowResized,
// 9 onNativeWindowRedrawNeeded, 10 onNativeWindowDestroyed,
// 11 onInputQueueCreated, 12 onInputQueueDestroyed,
// 13 onContentRectChanged, 14 onConfigurationChanged, 15 onLowMemory.
//
// Layer keys (asterui/apps/gallery.ast, runtime/layers.ast): dialog
// content OK 601 / Cancel 602, dialog card bg 8100+i, scrim 8000+i,
// menu bg 9099, menu items 9100+i. Menu picks write the item index
// (First 0, Second 1, Third 2) into the menu result; dialog OK writes
// 1 and Cancel writes 2 into the dialog result.

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
typedef int (*key_fn)(int);
typedef int (*cb1_fn)(void *);
typedef int (*cb2_fn)(void *, void *);
typedef int (*cb2i_fn)(void *, int);

typedef void *(*create_window_fn)(int, int);
typedef void (*destroy_window_fn)(void *);
typedef uint32_t (*pixel_fn)(void *, int, int);
typedef uint32_t (*hash_fn)(void *);
typedef int (*frames_fn)(void *);
typedef void *(*create_queue_fn)(void);
typedef void (*destroy_queue_fn)(void *);
typedef void (*push_motion_fn)(void *, int, float, float);
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
        fprintf(stderr, "FAIL: android-gallery-harness %s\n", msg);
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
        fprintf(stderr, "android-gallery-harness: dlsym(%s): %s\n", name, dlerror());
        exit(2);
    }
    return p;
}

// A NULL slot answers -1 instead of crashing: a stale .so that never
// installed a slot then fails its check cleanly instead of segfaulting.
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

int main(int argc, char **argv) {
    const char *path;
    int lazy_dlopen = 0;
    void *h;
    void *stub_h;
    create_fn onCreate;
    noarg_fn counter, frames, paused, layout_dirty;
    noarg_fn dpi, inset_top, log_lines;
    noarg_fn density_q8, dp48;
    noarg_fn dialog_open, menu_open, dialog_result, menu_result;
    noarg_fn scroll_taps;
    key_fn key_x, key_y, key_cx, key_cy;
    key_fn layer_key_x, layer_key_y, layer_key_w, layer_key_h;
    create_window_fn create_window;
    destroy_window_fn destroy_window;
    pixel_fn pixel;
    hash_fn buffer_hash;
    frames_fn frames_presented;
    create_queue_fn create_queue;
    destroy_queue_fn destroy_queue;
    push_motion_fn push_motion;
    fire_looper_fn fire_looper;
    looper_cb_fn looper_cb;
    set_density_fn set_density;
    asset_fn stub_asset_manager;
    void *cbtab[16];
    // The fake ANativeActivity is 16 words so the backend can read
    // internalDataPath@32 (index 4), externalDataPath@40 (index 5)
    // and assetManager@64 (index 8) without reading past the end.
    void *activity[16];
    char tmpdir[] = "/tmp/ui-gallery-harness-XXXXXX";
    char internal_dir[512];
    char external_dir[512];
    char internal_log[512];
    char external_log[512];
    void *win, *queue;
    uint32_t hash_before, hash_after;
    size_t out_size;
    long p_pause, p_stop, p_save, p_destroy;
    void *raw;
    char *log_internal;
    // Geometry, all read from the backend's diagnostics.
    int tab112_x, tab112_y;
    int b400_x, b400_y, b401_x, b401_y;
    int sv_x, sv_y, sv_w, sv_cx, row0_y, thumb_x;
    int drag_x, drag_y, btn_x, btn_y;
    int ok_x, ok_y, cancel_x, cancel_y;
    int card_x, card_y, card_w, card_h;
    int menu_x, menu_y, menu_w, menu_h;
    int item_x, item_y, pad_x, pad_y, item0_y;
    char line[128];
    int before_down, before_up, after_down, after_up;

    if (argc < 2) {
        fprintf(stderr, "usage: ui-android-gallery-harness <libgallery.so> [--lazy-dlopen]\n");
        return 2;
    }
    path = argv[1];
    {
        int ai;
        for (ai = 2; ai < argc; ai++) {
            if (strcmp(argv[ai], "--lazy-dlopen") == 0)
                lazy_dlopen = 1;
            else {
                fprintf(stderr, "usage: ui-android-gallery-harness <libgallery.so> [--lazy-dlopen]\n");
                return 2;
            }
        }
    }

    h = dlopen(path, lazy_dlopen ? RTLD_LAZY : RTLD_NOW);
    if (!h) {
        fprintf(stderr, "android-gallery-harness: dlopen(%s): %s\n", path, dlerror());
        return 2;
    }
    // The stub helpers live in libandroid.so, a dependency of the
    // Gallery .so. dlopen() defaults to RTLD_LOCAL, so they are not
    // in RTLD_DEFAULT; open the stub library explicitly (it is
    // already loaded) and resolve the helpers from its handle.
    {
        void *sh = dlopen("libandroid.so", RTLD_NOW);
        if (!sh) {
            fprintf(stderr, "android-gallery-harness: dlopen(libandroid.so): %s\n", dlerror());
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
    raw = sym(h, "asterui_log_lines");
    memcpy(&log_lines, &raw, sizeof log_lines);
    raw = sym(h, "asterui_density_q8");
    memcpy(&density_q8, &raw, sizeof density_q8);
    raw = sym(h, "asterui_dp48");
    memcpy(&dp48, &raw, sizeof dp48);
    raw = sym(h, "asterui_dialog_open");
    memcpy(&dialog_open, &raw, sizeof dialog_open);
    raw = sym(h, "asterui_menu_open");
    memcpy(&menu_open, &raw, sizeof menu_open);
    raw = sym(h, "asterui_dialog_result");
    memcpy(&dialog_result, &raw, sizeof dialog_result);
    raw = sym(h, "asterui_menu_result");
    memcpy(&menu_result, &raw, sizeof menu_result);
    raw = sym(h, "asterui_scroll_taps");
    memcpy(&scroll_taps, &raw, sizeof scroll_taps);
    raw = sym(h, "asterui_key_x");
    memcpy(&key_x, &raw, sizeof key_x);
    raw = sym(h, "asterui_key_y");
    memcpy(&key_y, &raw, sizeof key_y);
    raw = sym(h, "asterui_key_cx");
    memcpy(&key_cx, &raw, sizeof key_cx);
    raw = sym(h, "asterui_key_cy");
    memcpy(&key_cy, &raw, sizeof key_cy);
    raw = sym(h, "asterui_layer_key_x");
    memcpy(&layer_key_x, &raw, sizeof layer_key_x);
    raw = sym(h, "asterui_layer_key_y");
    memcpy(&layer_key_y, &raw, sizeof layer_key_y);
    raw = sym(h, "asterui_layer_key_w");
    memcpy(&layer_key_w, &raw, sizeof layer_key_w);
    raw = sym(h, "asterui_layer_key_h");
    memcpy(&layer_key_h, &raw, sizeof layer_key_h);

    raw = sym(stub_h, "ui_stub_create_window");
    memcpy(&create_window, &raw, sizeof create_window);
    raw = sym(stub_h, "ui_stub_destroy_window");
    memcpy(&destroy_window, &raw, sizeof destroy_window);
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
    raw = sym(stub_h, "ui_stub_fire_looper");
    memcpy(&fire_looper, &raw, sizeof fire_looper);
    raw = sym(stub_h, "ui_stub_looper_cb");
    memcpy(&looper_cb, &raw, sizeof looper_cb);
    raw = sym(stub_h, "ui_stub_set_density");
    memcpy(&set_density, &raw, sizeof set_density);
    raw = sym(stub_h, "ui_stub_asset_manager");
    memcpy(&stub_asset_manager, &raw, sizeof stub_asset_manager);

    check(mkdtemp(tmpdir) != 0, "mkdtemp failed");
    snprintf(internal_dir, sizeof internal_dir, "%s/internal", tmpdir);
    snprintf(external_dir, sizeof external_dir, "%s/external", tmpdir);
    snprintf(internal_log, sizeof internal_log, "%s/internal/asterui.log", tmpdir);
    snprintf(external_log, sizeof external_log, "%s/external/asterui.log", tmpdir);
    check(mkdir(internal_dir, 0700) == 0, "mkdir internal log dir failed");
    check(mkdir(external_dir, 0700) == 0, "mkdir external log dir failed");
    // 160 dpi: the Gallery geometry matches the headless gallery_test
    // (inset top 24, q8 256, 48dp target 48 px); the dialog card is
    // 152 px wide, centred in the 400x300 window.
    set_density(160);

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
                fprintf(stderr, "FAIL: android-gallery-harness slot %d was not installed\n", i);
                all = 0;
            }
        }
        check(all, "not all 16 callback slots installed");
    }
    check(call1(cbtab, 0, activity) == 0, "onStart did not return 0");
    if (failures == 0)
        printf("PASS: android-gallery-harness 16 callbacks installed (onCreate=0, onStart ran)\n");

    // [2] First frame: window created presents the Gallery (Input tab)
    // on the dark theme (M1.2c default): bg 0x121212.
    win = create_window(400, 300);
    check(win != 0, "could not create the fake window");
    hash_before = 0;
    if (win) {
        check(call2(cbtab, 7, activity, win) == 0, "window-created did not return 0");
        check(frames_presented(win) == 1, "first frame was not presented");
        check(frames() == 1, "asterui_frames() != 1 after window created");
        check(dpi() == 160, "asterui_dpi() != 160");
        check(inset_top() == 24, "asterui_inset_top() != 24 at 160 dpi");
        check(density_q8() == 256, "asterui_density_q8() != 256 at 160 dpi");
        check(dp48() == 48, "asterui_dp48() != 48 at 160 dpi");
        check(log_lines() > 0, "no log lines written by onCreate/first frame");
        // NOT asserted: layout_dirty() is still 1 here. The flag is
        // set by on_native_window_created and consumed only in the
        // already-created branch of android_present; the lazy
        // first-window branch creates the Runtime from the buffer
        // size directly and never clears it, so it stays set until
        // the second present consumes it (harmless: the next
        // present re-reads the same viewport and clears it). That
        // staleness is pre-existing backend behaviour, not part of
        // the tap-routing fix; see the M3.1b report.
        check(counter() == 0, "home counter != 0 at start");
        check(dialog_open() == 0, "dialog open at start");
        check(menu_open() == 0, "menu open at start");
        check(dialog_result() == 0, "dialog result != 0 at start");
        check(menu_result() == 0, "menu result != 0 at start");
        check(key_x(112) >= 0, "Layers tab button (key 112) not found");
        check(pixel(win, 0, 0) == 0xFF121212u, "background pixel (0,0) is not 0xFF121212 (dark theme)");
        hash_before = buffer_hash(win);
        printf("android-gallery-harness: hash before=0x%08x frames=%d dpi=%d inset_top=%d\n",
               hash_before, frames(), dpi(), inset_top());
    }
    queue = create_queue();
    check(queue != 0, "could not create the fake input queue");
    if (queue) {
        check(call2(cbtab, 11, activity, queue) == 0, "input-queue-created did not return 0");
        check(looper_cb() != 0, "looper callback was not stored by attachLooper");
    }
    if (failures == 0)
        printf("PASS: android-gallery-harness first frame presented (frames=1, dpi=160, inset_top=24, dark bg 0xFF121212)\n");

    // [3] Layers tab: tap the tab bar's Layers button (main tree,
    // key 112). The Show dialog button (key 400) appears.
    tab112_x = key_cx(112);
    tab112_y = key_cy(112);
    check(tab112_x > 0 && tab112_y > 0, "Layers tab centre not found");
    push_motion(queue, 0, (float)tab112_x, (float)tab112_y);
    push_motion(queue, 1, (float)tab112_x, (float)tab112_y);
    check(fire_looper() == 1, "looper callback did not return 1 on tab tap");
    check(frames() == 2, "asterui_frames() != 2 after Layers tab tap");
    check(key_x(400) >= 0, "Show dialog button (key 400) not found on Layers tab");
    check(key_x(401) >= 0, "Show menu button (key 401) not found on Layers tab");
    check(counter() == 0, "home counter changed across tab switch");
    b400_x = key_cx(400);
    b400_y = key_cy(400);
    b401_x = key_cx(401);
    b401_y = key_cy(401);
    if (failures == 0)
        printf("PASS: android-gallery-harness Layers tab (tap 112, frames=2, Show dialog/menu found)\n");

    // [4] Dialog OK: tap Show dialog (main tree), then OK (layer
    // key 601). The dialog closes and the result is 1. The OK tap
    // must log layer hit/fired lines with its true coordinates.
    push_motion(queue, 0, (float)b400_x, (float)b400_y);
    push_motion(queue, 1, (float)b400_x, (float)b400_y);
    check(fire_looper() == 1, "looper callback did not return 1 opening the dialog");
    check(frames() == 3, "asterui_frames() != 3 after opening the dialog");
    check(dialog_open() == 1, "dialog did not open after tapping Show dialog");
    hash_after = buffer_hash(win);
    check(hash_after != hash_before, "buffer hash did not change after opening the dialog (scrim+card)");
    ok_x = layer_key_x(601) + layer_key_w(601) / 2;
    ok_y = layer_key_y(601) + layer_key_h(601) / 2;
    check(layer_key_x(601) >= 0 && ok_x > 0, "dialog OK button (layer key 601) not found");
    check(layer_key_w(601) == 64, "dialog OK button width != 64 (M3.1 equal widths)");
    check(layer_key_w(602) == 64, "dialog Cancel button width != 64 (M3.1 equal widths)");
    push_motion(queue, 0, (float)ok_x, (float)ok_y);
    push_motion(queue, 1, (float)ok_x, (float)ok_y);
    check(fire_looper() == 1, "looper callback did not return 1 on OK tap");
    check(frames() == 4, "asterui_frames() != 4 after OK tap");
    check(dialog_open() == 0, "dialog did not close on OK");
    check(dialog_result() == 1, "dialog result != 1 after OK");
    check(counter() == 0, "home counter changed across dialog OK");
    log_internal = read_file(internal_log);
    check(log_internal != 0, "internal asterui.log was not readable for OK checks");
    snprintf(line, sizeof line, "tap down %d %d hit 1", ok_x, ok_y);
    check_contains(log_internal, line, "internal log has no OK tap-down line");
    snprintf(line, sizeof line, "tap up %d %d fired 1", ok_x, ok_y);
    check_contains(log_internal, line, "internal log has no OK tap-up line");
    if (log_internal) free(log_internal);
    if (failures == 0)
        printf("PASS: android-gallery-harness dialog OK (layer key 601, result=1, frames=4)\n");

    // [5] Dialog Cancel: reopen, tap Cancel (layer key 602).
    push_motion(queue, 0, (float)b400_x, (float)b400_y);
    push_motion(queue, 1, (float)b400_x, (float)b400_y);
    check(fire_looper() == 1, "looper callback did not return 1 reopening the dialog");
    check(frames() == 5, "asterui_frames() != 5 after reopening the dialog");
    check(dialog_open() == 1, "dialog did not reopen");
    cancel_x = layer_key_x(602) + layer_key_w(602) / 2;
    cancel_y = layer_key_y(602) + layer_key_h(602) / 2;
    check(layer_key_x(602) >= 0 && cancel_x > 0, "dialog Cancel button (layer key 602) not found");
    push_motion(queue, 0, (float)cancel_x, (float)cancel_y);
    push_motion(queue, 1, (float)cancel_x, (float)cancel_y);
    check(fire_looper() == 1, "looper callback did not return 1 on Cancel tap");
    check(frames() == 6, "asterui_frames() != 6 after Cancel tap");
    check(dialog_open() == 0, "dialog did not close on Cancel");
    check(dialog_result() == 2, "dialog result != 2 after Cancel");
    log_internal = read_file(internal_log);
    check(log_internal != 0, "internal asterui.log was not readable for Cancel checks");
    snprintf(line, sizeof line, "tap down %d %d hit 1", cancel_x, cancel_y);
    check_contains(log_internal, line, "internal log has no Cancel tap-down line");
    snprintf(line, sizeof line, "tap up %d %d fired 1", cancel_x, cancel_y);
    check_contains(log_internal, line, "internal log has no Cancel tap-up line");
    if (log_internal) free(log_internal);
    if (failures == 0)
        printf("PASS: android-gallery-harness dialog Cancel (layer key 602, result=2, frames=6)\n");

    // [6] Scrim: reopen, tap (5,5) -- outside the centred card, so on
    // the scrim. The dialog stays open and the result is unchanged;
    // the scrim callback is a no-op, so the tap logs hit 1 / fired 1
    // (the callback ran) and presents one frame.
    push_motion(queue, 0, (float)b400_x, (float)b400_y);
    push_motion(queue, 1, (float)b400_x, (float)b400_y);
    check(fire_looper() == 1, "looper callback did not return 1 reopening the dialog for scrim");
    check(frames() == 7, "asterui_frames() != 7 after reopening the dialog for scrim");
    check(dialog_open() == 1, "dialog did not reopen for scrim");
    card_x = layer_key_x(8100);
    card_y = layer_key_y(8100);
    card_w = layer_key_w(8100);
    card_h = layer_key_h(8100);
    check(card_x == 124 && card_w == 152, "dialog card is not (124,*,152,*) at 160 dpi (M3.1)");
    check(5 < card_x || 5 >= card_x + card_w || 5 < card_y || 5 >= card_y + card_h,
          "scrim point (5,5) is inside the dialog card, not on the scrim");
    push_motion(queue, 0, 5.0f, 5.0f);
    push_motion(queue, 1, 5.0f, 5.0f);
    check(fire_looper() == 1, "looper callback did not return 1 on scrim tap");
    check(frames() == 8, "asterui_frames() != 8 after scrim tap (scrim callback fired, one frame)");
    check(dialog_open() == 1, "scrim tap closed the dialog");
    check(dialog_result() == 2, "scrim tap changed the dialog result");
    log_internal = read_file(internal_log);
    check(log_internal != 0, "internal asterui.log was not readable for scrim checks");
    check_contains(log_internal, "tap down 5 5 hit 1", "internal log has no scrim tap-down line");
    check_contains(log_internal, "tap up 5 5 fired 1", "internal log has no scrim tap-up line");
    if (log_internal) free(log_internal);
    // Close the dialog with Cancel to reset for the menu groups.
    push_motion(queue, 0, (float)cancel_x, (float)cancel_y);
    push_motion(queue, 1, (float)cancel_x, (float)cancel_y);
    check(fire_looper() == 1, "looper callback did not return 1 closing the dialog after scrim");
    check(frames() == 9, "asterui_frames() != 9 after Cancel closes the scrim dialog");
    check(dialog_open() == 0, "dialog did not close on Cancel after scrim");
    check(dialog_result() == 2, "dialog result changed closing the scrim dialog");
    if (failures == 0)
        printf("PASS: android-gallery-harness scrim tap consumes, dialog stays open (frames=9, result=2)\n");

    // [7] Menu item: tap Show menu (main tree), then Second (layer
    // key 9101). The menu closes and the result is 1.
    push_motion(queue, 0, (float)b401_x, (float)b401_y);
    push_motion(queue, 1, (float)b401_x, (float)b401_y);
    check(fire_looper() == 1, "looper callback did not return 1 opening the menu");
    check(frames() == 10, "asterui_frames() != 10 after opening the menu");
    check(menu_open() == 1, "menu did not open after tapping Show menu");
    check(layer_key_w(9100) == 64 && layer_key_w(9101) == 64 && layer_key_w(9102) == 64,
          "menu item widths != 64/64/64 (M3.1 stretch)");
    item_x = layer_key_x(9101) + layer_key_w(9101) / 2;
    item_y = layer_key_y(9101) + layer_key_h(9101) / 2;
    check(layer_key_x(9101) >= 0 && item_x > 0, "menu item Second (layer key 9101) not found");
    push_motion(queue, 0, (float)item_x, (float)item_y);
    push_motion(queue, 1, (float)item_x, (float)item_y);
    check(fire_looper() == 1, "looper callback did not return 1 on menu item tap");
    check(frames() == 11, "asterui_frames() != 11 after menu item tap");
    check(menu_open() == 0, "menu did not close after pick");
    check(menu_result() == 1, "menu result != 1 after picking Second");
    check(counter() == 0, "home counter changed across menu pick");
    log_internal = read_file(internal_log);
    check(log_internal != 0, "internal asterui.log was not readable for menu item checks");
    snprintf(line, sizeof line, "tap down %d %d hit 1", item_x, item_y);
    check_contains(log_internal, line, "internal log has no menu item tap-down line");
    snprintf(line, sizeof line, "tap up %d %d fired 1", item_x, item_y);
    check_contains(log_internal, line, "internal log has no menu item tap-up line");
    if (log_internal) free(log_internal);
    if (failures == 0)
        printf("PASS: android-gallery-harness menu item pick (layer key 9101 Second, result=1, frames=11)\n");

    // [8] Menu tap-outside closes WITHOUT activating underneath: reopen
    // the menu, then tap the centre of Show dialog (key 400) -- a
    // main-tree button OUTSIDE the menu rect. The menu must close,
    // the dialog must NOT open, and the result must not move. The
    // DOWN closes the menu (one frame) and the UP fires nothing.
    push_motion(queue, 0, (float)b401_x, (float)b401_y);
    push_motion(queue, 1, (float)b401_x, (float)b401_y);
    check(fire_looper() == 1, "looper callback did not return 1 reopening the menu");
    check(frames() == 12, "asterui_frames() != 12 after reopening the menu");
    check(menu_open() == 1, "menu did not reopen");
    menu_x = layer_key_x(9099);
    menu_y = layer_key_y(9099);
    menu_w = layer_key_w(9099);
    menu_h = layer_key_h(9099);
    check(menu_x >= 0 && menu_w == 80, "menu bg (layer key 9099) is not 80 wide (M3.1)");
    check(b400_x < menu_x || b400_x >= menu_x + menu_w || b400_y < menu_y || b400_y >= menu_y + menu_h,
          "Show dialog centre is inside the menu rect, not outside it");
    log_internal = read_file(internal_log);
    snprintf(line, sizeof line, "tap down %d %d hit 1", b400_x, b400_y);
    before_down = count_substr(log_internal, line);
    snprintf(line, sizeof line, "tap up %d %d fired 0", b400_x, b400_y);
    before_up = count_substr(log_internal, line);
    if (log_internal) free(log_internal);
    push_motion(queue, 0, (float)b400_x, (float)b400_y);
    push_motion(queue, 1, (float)b400_x, (float)b400_y);
    check(fire_looper() == 1, "looper callback did not return 1 on menu tap-outside");
    check(frames() == 13, "asterui_frames() != 13 after menu tap-outside (DOWN closes + presents, UP nothing)");
    check(menu_open() == 0, "menu did not close on tap-outside");
    check(dialog_open() == 0, "tap-outside on Show dialog OPENED the dialog (underneath fired)");
    check(menu_result() == 1, "tap-outside changed the menu result");
    check(counter() == 0, "home counter changed across menu tap-outside");
    log_internal = read_file(internal_log);
    check(log_internal != 0, "internal asterui.log was not readable for tap-outside checks");
    snprintf(line, sizeof line, "tap down %d %d hit 1", b400_x, b400_y);
    after_down = count_substr(log_internal, line);
    snprintf(line, sizeof line, "tap up %d %d fired 0", b400_x, b400_y);
    after_up = count_substr(log_internal, line);
    check(after_down == before_down + 1, "menu tap-outside DOWN did not log one more hit-1 line");
    check(after_up == before_up + 1, "menu tap-outside UP did not log one more fired-0 line");
    if (log_internal) free(log_internal);
    if (failures == 0)
        printf("PASS: android-gallery-harness menu tap-outside closes, underneath stays silent (frames=13)\n");

    // [9] Page behind a modal dialog fires nothing: open the dialog,
    // then tap the centre of Show menu (key 401) -- a main-tree
    // button behind the scrim. The dialog stays open, the menu
    // never opens, nothing underneath fires.
    push_motion(queue, 0, (float)b400_x, (float)b400_y);
    push_motion(queue, 1, (float)b400_x, (float)b400_y);
    check(fire_looper() == 1, "looper callback did not return 1 opening the dialog for modal block");
    check(frames() == 14, "asterui_frames() != 14 after opening the dialog for modal block");
    check(dialog_open() == 1, "dialog did not open for modal block");
    push_motion(queue, 0, (float)b401_x, (float)b401_y);
    push_motion(queue, 1, (float)b401_x, (float)b401_y);
    check(fire_looper() == 1, "looper callback did not return 1 on page tap behind dialog");
    check(frames() == 15, "asterui_frames() != 15 after page tap behind dialog (scrim fired, one frame)");
    check(dialog_open() == 1, "page tap behind dialog closed the dialog");
    check(menu_open() == 0, "page tap behind dialog OPENED the menu (scrim did not block)");
    check(dialog_result() == 2, "page tap behind dialog changed the dialog result");
    check(counter() == 0, "home counter changed across modal block");
    log_internal = read_file(internal_log);
    check(log_internal != 0, "internal asterui.log was not readable for modal block checks");
    snprintf(line, sizeof line, "tap down %d %d hit 1", b401_x, b401_y);
    check_contains(log_internal, line, "internal log has no modal-block tap-down line (scrim hit)");
    snprintf(line, sizeof line, "tap up %d %d fired 1", b401_x, b401_y);
    check_contains(log_internal, line, "internal log has no modal-block tap-up line (scrim fired)");
    if (log_internal) free(log_internal);
    // Close the dialog with Cancel to reset for the drag-off group.
    cancel_x = layer_key_x(602) + layer_key_w(602) / 2;
    cancel_y = layer_key_y(602) + layer_key_h(602) / 2;
    push_motion(queue, 0, (float)cancel_x, (float)cancel_y);
    push_motion(queue, 1, (float)cancel_x, (float)cancel_y);
    check(fire_looper() == 1, "looper callback did not return 1 closing the dialog after modal block");
    check(frames() == 16, "asterui_frames() != 16 after Cancel closes the modal dialog");
    check(dialog_open() == 0, "dialog did not close on Cancel after modal block");
    if (failures == 0)
        printf("PASS: android-gallery-harness modal dialog blocks the page (frames=16)\n");

    // [10] DOWN on OK + UP elsewhere fires nothing: open the dialog,
    // press OK, release on the scrim point. The dialog stays open
    // and the result is unchanged; no frame is presented. A full OK
    // tap afterwards still works (the cancelled press left nothing
    // behind).
    push_motion(queue, 0, (float)b400_x, (float)b400_y);
    push_motion(queue, 1, (float)b400_x, (float)b400_y);
    check(fire_looper() == 1, "looper callback did not return 1 opening the dialog for drag-off");
    check(frames() == 17, "asterui_frames() != 17 after opening the dialog for drag-off");
    check(dialog_open() == 1, "dialog did not open for drag-off");
    ok_x = layer_key_x(601) + layer_key_w(601) / 2;
    ok_y = layer_key_y(601) + layer_key_h(601) / 2;
    push_motion(queue, 0, (float)ok_x, (float)ok_y);
    check(fire_looper() == 1, "looper callback did not return 1 on OK DOWN");
    check(frames() == 17, "OK DOWN presented a frame (DOWN must present nothing)");
    push_motion(queue, 1, 5.0f, 5.0f);
    check(fire_looper() == 1, "looper callback did not return 1 on scrim UP");
    check(frames() == 17, "drag-off UP presented a frame (cancelled tap must present nothing)");
    check(dialog_open() == 1, "drag-off UP closed the dialog");
    check(dialog_result() == 2, "drag-off UP changed the dialog result");
    log_internal = read_file(internal_log);
    check(log_internal != 0, "internal asterui.log was not readable for drag-off checks");
    snprintf(line, sizeof line, "tap down %d %d hit 1", ok_x, ok_y);
    check_contains(log_internal, line, "internal log has no drag-off OK tap-down line");
    check_contains(log_internal, "tap up 5 5 fired 0", "internal log has no drag-off UP fired-0 line");
    if (log_internal) free(log_internal);
    push_motion(queue, 0, (float)ok_x, (float)ok_y);
    push_motion(queue, 1, (float)ok_x, (float)ok_y);
    check(fire_looper() == 1, "looper callback did not return 1 on OK tap after drag-off");
    check(frames() == 18, "asterui_frames() != 18 after OK tap following drag-off");
    check(dialog_open() == 0, "dialog did not close on OK after drag-off");
    check(dialog_result() == 1, "dialog result != 1 after OK following drag-off");
    if (failures == 0)
        printf("PASS: android-gallery-harness drag-off cancels, OK still works after (frames=18, result=1)\n");

    // [11] Menu drag-off + padding swallow: open the menu, press
    // Second, release outside the menu at (390,290) -- the menu
    // stays open and the result is unchanged (the press cancels;
    // only a DOWN outside closes). Then tap the popup's top padding
    // strip (inside the menu rect, above the first item): the menu
    // background swallows it (reference D.31.4 "-2 padding"), the
    // menu stays open and nothing underneath fires. Close with an
    // outside tap on Show dialog to finish.
    push_motion(queue, 0, (float)b401_x, (float)b401_y);
    push_motion(queue, 1, (float)b401_x, (float)b401_y);
    check(fire_looper() == 1, "looper callback did not return 1 opening the menu for drag-off");
    check(frames() == 19, "asterui_frames() != 19 after opening the menu for drag-off");
    check(menu_open() == 1, "menu did not open for drag-off");
    menu_x = layer_key_x(9099);
    menu_y = layer_key_y(9099);
    menu_w = layer_key_w(9099);
    menu_h = layer_key_h(9099);
    item_x = layer_key_x(9101) + layer_key_w(9101) / 2;
    item_y = layer_key_y(9101) + layer_key_h(9101) / 2;
    check(390 < menu_x || 390 >= menu_x + menu_w || 290 < menu_y || 290 >= menu_y + menu_h,
          "(390,290) is inside the menu rect, not outside it");
    push_motion(queue, 0, (float)item_x, (float)item_y);
    check(fire_looper() == 1, "looper callback did not return 1 on menu item DOWN");
    check(frames() == 19, "menu item DOWN presented a frame (DOWN must present nothing)");
    push_motion(queue, 1, 390.0f, 290.0f);
    check(fire_looper() == 1, "looper callback did not return 1 on outside UP");
    check(frames() == 19, "menu drag-off UP presented a frame (cancelled tap must present nothing)");
    check(menu_open() == 1, "menu drag-off UP closed the menu (only a DOWN outside closes)");
    check(menu_result() == 1, "menu drag-off UP changed the menu result");
    log_internal = read_file(internal_log);
    check(log_internal != 0, "internal asterui.log was not readable for menu drag-off checks");
    check_contains(log_internal, "tap up 390 290 fired 0", "internal log has no menu drag-off UP fired-0 line");
    if (log_internal) free(log_internal);
    // Padding strip: 4 px inside the menu rect's top-left corner --
    // inside the rect but above the first item (padding 8).
    pad_x = menu_x + 4;
    pad_y = menu_y + 4;
    item0_y = layer_key_y(9100);
    check(pad_x > menu_x && pad_x < menu_x + menu_w, "padding point x is outside the menu rect");
    check(pad_y > menu_y && pad_y < item0_y, "padding point y is not between the menu top and the first item");
    push_motion(queue, 0, (float)pad_x, (float)pad_y);
    push_motion(queue, 1, (float)pad_x, (float)pad_y);
    check(fire_looper() == 1, "looper callback did not return 1 on padding tap");
    check(frames() == 20, "asterui_frames() != 20 after padding tap (bg callback fired, one frame)");
    check(menu_open() == 1, "padding tap closed the menu");
    check(menu_result() == 1, "padding tap changed the menu result");
    check(dialog_open() == 0, "padding tap opened the dialog (fell through to the page)");
    check(counter() == 0, "home counter changed across padding tap");
    // Outside tap on Show dialog closes the menu, as in [8].
    push_motion(queue, 0, (float)b400_x, (float)b400_y);
    push_motion(queue, 1, (float)b400_x, (float)b400_y);
    check(fire_looper() == 1, "looper callback did not return 1 closing the menu at the end");
    check(frames() == 21, "asterui_frames() != 21 after final menu tap-outside");
    check(menu_open() == 0, "menu did not close on final tap-outside");
    check(dialog_open() == 0, "final tap-outside on Show dialog opened the dialog");
    if (failures == 0)
        printf("PASS: android-gallery-harness menu drag-off cancels, padding swallowed (frames=21)\n");

    // [13] Scroll tab + full width (M4.2): tap the tab bar's Scroll
    // button (main tree, key 114). The ScrollView (key 701) must
    // FILL the width the Gallery offers it -- 384 px in this 400 px
    // window (root pad 8 on each side) -- not the 128 px
    // widest-child width the old measure produced (the "Tap me in
    // list" button: 128 dp, 416 px at 520 dpi in a 1216 px window
    // on the user's phone). The scrollbar thumb sits at the
    // viewport's right edge (thumb x = sv x + sv w - 6): thumb
    // grey at (thumb_x, vy+5), track grey at (thumb_x, vy+100).
    // NOTE the thumb constant: the rasterizer stores RGBA8888
    // bytes [R,G,B,255], so a little-endian u32 read of thumb
    // 0xAF04CC is 0xFFCC04AF, not 0xFFAF04CC. The code's thumb
    // constant is 11470028 = 0xAF04CC (scene.ast); M3-NOTES.md
    // says 0xAEB8CC, which is a different value (11450572) --
    // the code is the ground truth, the doc is a transcription
    // slip, recorded in M4-NOTES.md. The track 0x555555 is
    // byte-symmetric, so 0xFF555555 reads back unchanged.
    push_motion(queue, 0, (float)key_cx(114), (float)key_cy(114));
    push_motion(queue, 1, (float)key_cx(114), (float)key_cy(114));
    check(fire_looper() == 1, "looper callback did not return 1 on Scroll tab tap");
    check(frames() == 22, "asterui_frames() != 22 after Scroll tab tap");
    check(key_x(701) >= 0, "ScrollView (key 701) not found on Scroll tab");
    sv_x = key_x(701);
    sv_y = key_y(701);
    sv_cx = key_cx(701);
    sv_w = (sv_cx - sv_x) * 2;
    check(sv_w == 384, "ScrollView width != 384 (M4.2 fill: must fill the offered width, not the widest child)");
    thumb_x = sv_x + sv_w - 6;
    // The pixel checks use the EXPECTED full-width edge (sv_x +
    // 384 - 6), not the measured one, so they fail on the old
    // narrow width too: on old code the thumb/track sit at x=130
    // and (386, vy+5) is background.
    check(pixel(win, sv_x + 384 - 6, sv_y + 5) == 0xFFCC04AFu, "scrollbar thumb pixel is not 0xFFCC04AF at the viewport right edge");
    check(pixel(win, sv_x + 384 - 6, sv_y + 100) == 0xFF555555u, "scrollbar track pixel is not 0xFF555555 below the thumb");
    check(key_y(710) == sv_y, "Row 0 (key 710) is not at the viewport top at offset 0");
    row0_y = key_y(710);
    check(scroll_taps() == 0, "list taps != 0 before any scroll/button tap");
    if (failures == 0)
        printf("PASS: android-gallery-harness Scroll tab full width (sv w=384, thumb at right edge, frames=22)\n");

    // [14] Drag scrolls (M4.2): DOWN on Row 0, MOVE 100 px up, UP.
    // The offset moves 0 -> 100 (Row 0 shifts up by exactly 100),
    // the thumb travels down (thumb grey at vy+50, track grey at
    // vy+5), exactly one frame is presented (the dragging MOVE;
    // DOWN and drag-UP present nothing), and no tap fires.
    drag_x = key_cx(710);
    drag_y = key_cy(710);
    push_motion(queue, 0, (float)drag_x, (float)drag_y);
    push_motion(queue, 2, (float)drag_x, (float)(drag_y - 100));
    push_motion(queue, 1, (float)drag_x, (float)(drag_y - 100));
    check(fire_looper() == 1, "looper callback did not return 1 on scroll drag");
    check(frames() == 23, "asterui_frames() != 23 after scroll drag (only the dragging MOVE presents)");
    check(key_y(710) == row0_y - 100, "Row 0 did not shift up by exactly 100 after drag");
    check(key_y(701) == sv_y, "ScrollView moved while dragging (viewport must not move)");
    check(pixel(win, thumb_x, sv_y + 50) == 0xFFCC04AFu, "scrollbar thumb did not travel down after drag (vy+50 is not thumb grey)");
    check(pixel(win, thumb_x, sv_y + 5) == 0xFF555555u, "scrollbar thumb still at the top after drag (vy+5 is not track grey)");
    check(scroll_taps() == 0, "scroll drag fired a tap");
    check(dialog_open() == 0 && menu_open() == 0, "scroll drag opened a dialog/menu");
    if (failures == 0)
        printf("PASS: android-gallery-harness drag scrolls 100 px, thumb travels, no tap (frames=23)\n");

    // [15] Scroll to the bottom by drag, tap the in-list button,
    // tap-within-slop, drag-off (M4.2). Two swipes of 200 px from
    // offset 100 reach the max 448 (clamped); the button (key 740)
    // is then inside the viewport and a plain tap counts List taps
    // 0 -> 1. A 4 px move stays inside the 8dp slop: the tap still
    // fires (2) and the offset does not move. A drag starting on
    // the button and ending off it scrolls (offset 448 -> 438) but
    // the button must NOT fire.
    push_motion(queue, 0, 200.0f, 250.0f);
    push_motion(queue, 2, 200.0f, 50.0f);
    push_motion(queue, 1, 200.0f, 50.0f);
    check(fire_looper() == 1, "looper callback did not return 1 on first bottom swipe");
    check(frames() == 24, "asterui_frames() != 24 after first bottom swipe");
    check(key_y(710) == row0_y - 300, "Row 0 did not shift to offset 300 after first bottom swipe");
    push_motion(queue, 0, 200.0f, 250.0f);
    push_motion(queue, 2, 200.0f, 50.0f);
    push_motion(queue, 1, 200.0f, 50.0f);
    check(fire_looper() == 1, "looper callback did not return 1 on second bottom swipe");
    check(frames() == 25, "asterui_frames() != 25 after second bottom swipe");
    check(key_y(710) == row0_y - 448, "Row 0 did not shift to max offset 448 after second bottom swipe");
    btn_x = key_cx(740);
    btn_y = key_cy(740);
    check(key_y(740) >= sv_y && key_y(740) + 32 <= sv_y + 160, "in-list button is not inside the viewport at max offset");
    push_motion(queue, 0, (float)btn_x, (float)btn_y);
    push_motion(queue, 1, (float)btn_x, (float)btn_y);
    check(fire_looper() == 1, "looper callback did not return 1 tapping the in-list button");
    check(frames() == 26, "asterui_frames() != 26 after tapping the in-list button");
    check(scroll_taps() == 1, "List taps != 1 after tapping the in-list button at the bottom");
    btn_x = key_cx(740);
    btn_y = key_cy(740);
    push_motion(queue, 0, (float)btn_x, (float)btn_y);
    push_motion(queue, 2, (float)btn_x, (float)(btn_y + 4));
    push_motion(queue, 1, (float)btn_x, (float)(btn_y + 4));
    check(fire_looper() == 1, "looper callback did not return 1 on slop tap");
    check(frames() == 27, "asterui_frames() != 27 after slop tap (the UP must fire and present)");
    check(scroll_taps() == 2, "List taps != 2 after tap-within-slop (slop move must not cancel the tap)");
    check(key_y(710) == row0_y - 448, "offset moved on a tap-within-slop");
    btn_x = key_cx(740);
    btn_y = key_cy(740);
    push_motion(queue, 0, (float)btn_x, (float)btn_y);
    push_motion(queue, 2, 390.0f, 290.0f);
    push_motion(queue, 1, 390.0f, 290.0f);
    check(fire_looper() == 1, "looper callback did not return 1 on drag-off");
    check(frames() == 28, "asterui_frames() != 28 after drag-off (only the dragging MOVE presents)");
    check(scroll_taps() == 2, "drag-off fired the in-list button");
    check(key_y(710) == row0_y - 438, "drag-off did not scroll (offset must be 438 after a +10 px drag)");
    if (failures == 0)
        printf("PASS: android-gallery-harness drag to bottom, list button counts 1, slop tap counts, drag-off silent (frames=28)\n");

    // [16] Drag arbitration with layers (M4.2): a drag that starts
    // on a modal never scrolls the page behind it and never fires
    // anything underneath. Back on the Layers tab, open the dialog
    // and drag across the scrim: the DOWN is swallowed by the
    // scrim (no scroll capture), the MOVE presents nothing, the UP
    // on the scrim fires only the scrim no-op (one frame) and the
    // dialog stays open. Then open the menu and drag off a menu
    // item: the MOVE presents nothing, the UP fires nothing, the
    // menu stays open and the result is unchanged. Close the menu
    // with an outside tap to finish.
    push_motion(queue, 0, (float)key_cx(112), (float)key_cy(112));
    push_motion(queue, 1, (float)key_cx(112), (float)key_cy(112));
    check(fire_looper() == 1, "looper callback did not return 1 switching back to the Layers tab");
    check(frames() == 29, "asterui_frames() != 29 after switching back to the Layers tab");
    push_motion(queue, 0, (float)b400_x, (float)b400_y);
    push_motion(queue, 1, (float)b400_x, (float)b400_y);
    check(fire_looper() == 1, "looper callback did not return 1 opening the dialog for modal drag");
    check(frames() == 30, "asterui_frames() != 30 after opening the dialog for modal drag");
    check(dialog_open() == 1, "dialog did not open for modal drag");
    push_motion(queue, 0, 5.0f, 5.0f);
    push_motion(queue, 2, 5.0f, 150.0f);
    push_motion(queue, 1, 5.0f, 150.0f);
    check(fire_looper() == 1, "looper callback did not return 1 on scrim drag");
    check(frames() == 31, "asterui_frames() != 31 after scrim drag (only the scrim UP presents; the MOVE must present nothing)");
    check(dialog_open() == 1, "scrim drag closed the dialog");
    check(dialog_result() == 1, "scrim drag changed the dialog result");
    check(menu_open() == 0, "scrim drag opened the menu");
    cancel_x = layer_key_x(602) + layer_key_w(602) / 2;
    cancel_y = layer_key_y(602) + layer_key_h(602) / 2;
    push_motion(queue, 0, (float)cancel_x, (float)cancel_y);
    push_motion(queue, 1, (float)cancel_x, (float)cancel_y);
    check(fire_looper() == 1, "looper callback did not return 1 closing the dialog after modal drag");
    check(frames() == 32, "asterui_frames() != 32 after Cancel closes the modal-drag dialog");
    check(dialog_open() == 0, "dialog did not close on Cancel after modal drag");
    push_motion(queue, 0, (float)b401_x, (float)b401_y);
    push_motion(queue, 1, (float)b401_x, (float)b401_y);
    check(fire_looper() == 1, "looper callback did not return 1 opening the menu for modal drag");
    check(frames() == 33, "asterui_frames() != 33 after opening the menu for modal drag");
    check(menu_open() == 1, "menu did not open for modal drag");
    item_x = layer_key_x(9101) + layer_key_w(9101) / 2;
    item_y = layer_key_y(9101) + layer_key_h(9101) / 2;
    push_motion(queue, 0, (float)item_x, (float)item_y);
    push_motion(queue, 2, (float)item_x, (float)(item_y - 100));
    push_motion(queue, 1, 390.0f, 290.0f);
    check(fire_looper() == 1, "looper callback did not return 1 on menu item drag");
    check(frames() == 33, "asterui_frames() != 33 after menu item drag (a layer drag must present nothing)");
    check(menu_open() == 1, "menu item drag closed the menu (only a DOWN outside closes)");
    check(menu_result() == 1, "menu item drag changed the menu result");
    check(dialog_open() == 0, "menu item drag opened the dialog");
    push_motion(queue, 0, (float)b400_x, (float)b400_y);
    push_motion(queue, 1, (float)b400_x, (float)b400_y);
    check(fire_looper() == 1, "looper callback did not return 1 closing the menu at the end of modal drag");
    check(frames() == 34, "asterui_frames() != 34 after final menu tap-outside");
    check(menu_open() == 0, "menu did not close on final tap-outside");
    check(dialog_open() == 0, "final tap-outside on Show dialog opened the dialog");
    if (failures == 0)
        printf("PASS: android-gallery-harness modal drags present nothing on MOVE, fire nothing underneath (frames=34)\n");

    // [17] Teardown, in the true Android exit order: onPause (slot 3),
    // onStop (slot 4), onSaveInstanceState (slot 2), onDestroy
    // (slot 5), then window/input destroyed (slots 10/12).
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
    check(counter() == 0, "home counter changed across teardown");
    check(frames() == 34, "a frame was presented by teardown");
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
        printf("PASS: android-gallery-harness window/input teardown clean (counter=0, exit order onPause<onStop<onSaveInstanceState<onDestroy)\n");

    if (win) destroy_window(win);
    if (queue) destroy_queue(queue);
    if (failures == 0) {
        printf("PASS: ui-android-gallery-harness (17/17)\n");
        return 0;
    }
    fprintf(stderr, "FAIL: ui-android-gallery-harness (%d check(s) failed)\n", failures);
    return 1;
}
