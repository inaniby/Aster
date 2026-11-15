// ui-ime-harness.c -- device-free driver for the AsterUI IME probe
// (asterui/examples/ime-probe/main.ast, M3.4).
//
// dlopens the probe .so, builds a fake ANativeActivity with a zeroed
// 16-entry callback table, and drives it the way Android would: onCreate,
// window created, input queue created, scripted key/motion events through
// the stored looper callback, content-rect change, teardown. The fake
// window, input queue, key-event accessors and showSoftInput recorders
// come from tests/ui-android-stub.c (built as liblog.so and libandroid.so).
//
// What this proves (and what it does not): it proves the probe's drain
// loop logs every key field, maps ASCII key codes, handles DEL/ENTER/
// BACK/MULTIPLE/UNKNOWN, asks for the keyboard with the right flags on
// each tap zone, records the content rect, and skips pre-dispatched
// events — through the real instructions, under qemu. It does NOT prove
// anything about a real phone: whether the system keyboard appears, what
// a real IME sends, or whether Chinese input produces key events at all.
// Those are the questions the probe APK answers on the user's device.
//
// M4.3: group [5] also proves background taps focus nothing and call
// no showSoftInput, and group [8] proves the SafeArea inset: 24dp
// from the density, raised by the content-rect top, with the density
// floor returning when the rect top drops.
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
typedef const char *(*text_fn)(void);
typedef int (*cb1_fn)(void *);
typedef int (*cb2_fn)(void *, void *);
typedef int (*cb2i_fn)(void *, int);

typedef void *(*create_window_fn)(int, int);
typedef void (*destroy_window_fn)(void *);
typedef int (*frames_fn)(void *);
typedef void *(*create_queue_fn)(void);
typedef void (*destroy_queue_fn)(void *);
typedef void (*push_motion_fn)(void *, int, float, float);
typedef void (*push_key_full_fn)(void *, int, int, int, int, int, int);
typedef int (*fire_looper_fn)(void);
typedef void *(*looper_cb_fn)(void);
typedef void (*set_predispatch_fn)(int);
typedef void (*set_density_fn)(int);
typedef int (*int_fn)(void);
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
        fprintf(stderr, "FAIL: ime-harness %s\n", msg);
        failures++;
    }
}

static void check_contains(const char *hay, const char *needle, const char *msg) {
    check(hay != 0 && strstr(hay, needle) != 0, msg);
}

static void *sym(void *h, const char *name) {
    void *p = dlsym(h, name);
    if (!p) {
        fprintf(stderr, "ime-harness: dlsym(%s): %s\n", name, dlerror());
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

static int call2i(void *cbtab[], int slot, void *activity, int arg) {
    cb2i_fn cb;
    void *p = cbtab[slot];
    if (!p) return -1;
    memcpy(&cb, &p, sizeof cb);
    return cb(activity, arg);
}

int main(int argc, char **argv) {
    const char *path;
    void *h;
    void *stub_h;
    create_fn onCreate;
    noarg_fn keys, rects, pre, show_calls, hide_calls, kb_req, text_len;
    noarg_fn last_act, last_code, last_meta, last_flags, last_scan, last_rep;
    // M4.3 diagnostics: top inset + layout geometry + focus state.
    noarg_fn inset_top, dpi, title_y, field_top, field_bot, btn_top, focused, bg_taps;
    set_density_fn set_density;
    text_fn text;
    create_window_fn create_window;
    destroy_window_fn destroy_window;
    frames_fn frames_presented;
    create_queue_fn create_queue;
    destroy_queue_fn destroy_queue;
    push_motion_fn push_motion;
    push_key_full_fn push_key_full;
    fire_looper_fn fire_looper;
    looper_cb_fn looper_cb;
    set_predispatch_fn set_predispatch;
    int_fn last_finish_handled, soft_show_calls, soft_hide_calls;
    int_fn soft_last_show_flags, soft_last_hide_flags;
    asset_fn stub_asset_manager;
    void *cbtab[16];
    void *activity[16];
    char tmpdir[] = "/tmp/ui-ime-harness-XXXXXX";
    char internal_dir[512];
    char external_dir[512];
    char external_log[512];
    void *win, *queue;
    void *raw;
    char *log_external;
    int rect_arg[4];
    int i;

    if (argc < 2) {
        fprintf(stderr, "usage: ui-ime-harness <libimeprobe.so>\n");
        return 2;
    }
    path = argv[1];

    h = dlopen(path, RTLD_NOW);
    if (!h) {
        fprintf(stderr, "ime-harness: dlopen(%s): %s\n", path, dlerror());
        return 2;
    }
    // The stub helpers live in libandroid.so, a dependency of the probe
    // .so. dlopen() defaults to RTLD_LOCAL, so they are not in
    // RTLD_DEFAULT; open the stub library explicitly (it is already
    // loaded) and resolve the helpers from its handle.
    {
        void *sh = dlopen("libandroid.so", RTLD_NOW);
        if (!sh) {
            fprintf(stderr, "ime-harness: dlopen(libandroid.so): %s\n", dlerror());
            return 2;
        }
        stub_h = sh;
    }
    raw = sym(h, "ANativeActivity_onCreate");
    memcpy(&onCreate, &raw, sizeof onCreate);
    raw = sym(h, "ime_probe_keys");
    memcpy(&keys, &raw, sizeof keys);
    raw = sym(h, "ime_probe_rects");
    memcpy(&rects, &raw, sizeof rects);
    raw = sym(h, "ime_probe_pre");
    memcpy(&pre, &raw, sizeof pre);
    raw = sym(h, "ime_probe_show");
    memcpy(&show_calls, &raw, sizeof show_calls);
    raw = sym(h, "ime_probe_hide");
    memcpy(&hide_calls, &raw, sizeof hide_calls);
    raw = sym(h, "ime_probe_kb");
    memcpy(&kb_req, &raw, sizeof kb_req);
    raw = sym(h, "ime_probe_text_len");
    memcpy(&text_len, &raw, sizeof text_len);
    raw = sym(h, "ime_probe_text");
    memcpy(&text, &raw, sizeof text);
    raw = sym(h, "ime_probe_last_act");
    memcpy(&last_act, &raw, sizeof last_act);
    raw = sym(h, "ime_probe_last_code");
    memcpy(&last_code, &raw, sizeof last_code);
    raw = sym(h, "ime_probe_last_meta");
    memcpy(&last_meta, &raw, sizeof last_meta);
    raw = sym(h, "ime_probe_last_flags");
    memcpy(&last_flags, &raw, sizeof last_flags);
    raw = sym(h, "ime_probe_last_scan");
    memcpy(&last_scan, &raw, sizeof last_scan);
    raw = sym(h, "ime_probe_last_rep");
    memcpy(&last_rep, &raw, sizeof last_rep);
    raw = sym(h, "ime_probe_inset_top");
    memcpy(&inset_top, &raw, sizeof inset_top);
    raw = sym(h, "ime_probe_dpi");
    memcpy(&dpi, &raw, sizeof dpi);
    raw = sym(h, "ime_probe_title_y");
    memcpy(&title_y, &raw, sizeof title_y);
    raw = sym(h, "ime_probe_field_top");
    memcpy(&field_top, &raw, sizeof field_top);
    raw = sym(h, "ime_probe_field_bot");
    memcpy(&field_bot, &raw, sizeof field_bot);
    raw = sym(h, "ime_probe_btn_top");
    memcpy(&btn_top, &raw, sizeof btn_top);
    raw = sym(h, "ime_probe_focused");
    memcpy(&focused, &raw, sizeof focused);
    raw = sym(h, "ime_probe_bg_taps");
    memcpy(&bg_taps, &raw, sizeof bg_taps);

    raw = sym(stub_h, "ui_stub_create_window");
    memcpy(&create_window, &raw, sizeof create_window);
    raw = sym(stub_h, "ui_stub_destroy_window");
    memcpy(&destroy_window, &raw, sizeof destroy_window);
    raw = sym(stub_h, "ui_stub_frames_presented");
    memcpy(&frames_presented, &raw, sizeof frames_presented);
    raw = sym(stub_h, "ui_stub_create_queue");
    memcpy(&create_queue, &raw, sizeof create_queue);
    raw = sym(stub_h, "ui_stub_destroy_queue");
    memcpy(&destroy_queue, &raw, sizeof destroy_queue);
    raw = sym(stub_h, "ui_stub_push_motion");
    memcpy(&push_motion, &raw, sizeof push_motion);
    raw = sym(stub_h, "ui_stub_push_key_full");
    memcpy(&push_key_full, &raw, sizeof push_key_full);
    raw = sym(stub_h, "ui_stub_fire_looper");
    memcpy(&fire_looper, &raw, sizeof fire_looper);
    raw = sym(stub_h, "ui_stub_looper_cb");
    memcpy(&looper_cb, &raw, sizeof looper_cb);
    raw = sym(stub_h, "ui_stub_set_predispatch");
    memcpy(&set_predispatch, &raw, sizeof set_predispatch);
    raw = sym(stub_h, "ui_stub_last_finish_handled");
    memcpy(&last_finish_handled, &raw, sizeof last_finish_handled);
    raw = sym(stub_h, "ui_stub_soft_show_calls");
    memcpy(&soft_show_calls, &raw, sizeof soft_show_calls);
    raw = sym(stub_h, "ui_stub_soft_hide_calls");
    memcpy(&soft_hide_calls, &raw, sizeof soft_hide_calls);
    raw = sym(stub_h, "ui_stub_soft_last_show_flags");
    memcpy(&soft_last_show_flags, &raw, sizeof soft_last_show_flags);
    raw = sym(stub_h, "ui_stub_soft_last_hide_flags");
    memcpy(&soft_last_hide_flags, &raw, sizeof soft_last_hide_flags);
    raw = sym(stub_h, "ui_stub_set_density");
    memcpy(&set_density, &raw, sizeof set_density);
    raw = sym(stub_h, "ui_stub_asset_manager");
    memcpy(&stub_asset_manager, &raw, sizeof stub_asset_manager);

    // M4.3: the harness window is 400x300, and the stub's default
    // density is 480 (inset 72) -- that would crowd the small window.
    // Run the main flow at 160 dpi (inset 24, the density fallback);
    // the density behaviour itself is covered in group [8].
    set_density(160);

    // Log directories for the probe's two ime-probe.log files.
    check(mkdtemp(tmpdir) != 0, "mkdtemp failed");
    snprintf(internal_dir, sizeof internal_dir, "%s/internal", tmpdir);
    snprintf(external_dir, sizeof external_dir, "%s/external", tmpdir);
    snprintf(external_log, sizeof external_log, "%s/external/ime-probe.log", tmpdir);
    check(mkdir(internal_dir, 0700) == 0, "mkdir internal log dir failed");
    check(mkdir(external_dir, 0700) == 0, "mkdir external log dir failed");

    // [1] onCreate installs all 16 callbacks; window + input queue start.
    memset(cbtab, 0, sizeof cbtab);
    activity[0] = cbtab;
    activity[1] = 0;
    activity[4] = internal_dir;
    activity[5] = external_dir;
    activity[8] = stub_asset_manager();
    check(onCreate(activity, 0, 0) == 0, "ANativeActivity_onCreate did not return 0");
    for (i = 0; i < 16; i++)
        check(cbtab[i] != 0, "a callback slot was not installed");
    if (failures == 0)
        printf("PASS: ime-harness 16 callbacks installed (onCreate=0)\n");
    win = create_window(400, 300);
    check(win != 0, "could not create fake window");
    check(call2(cbtab, 7, activity, win) == 0, "window-created did not return 0");
    check(frames_presented(win) == 1, "first frame was not presented");
    queue = create_queue();
    check(queue != 0, "could not create fake input queue");
    check(call2(cbtab, 11, activity, queue) == 0, "input-queue-created did not return 0");
    check(looper_cb() != 0, "looper callback was not attached");
    log_external = read_file(external_log);
    check_contains(log_external, "ime: probe start", "log file has no probe start line");
    free(log_external);
    if (failures == 0)
        printf("PASS: ime-harness window + input queue + log file\n");

    // [2] ASCII keys arrive with all fields and land in the text.
    // 'h' (36) DOWN with the soft-keyboard flag, then UP; 'i' (37) DOWN+UP.
    push_key_full(queue, 0, 36, 0, 2, 0, 0);
    push_key_full(queue, 1, 36, 0, 2, 0, 0);
    push_key_full(queue, 0, 37, 0, 2, 0, 0);
    push_key_full(queue, 1, 37, 0, 2, 0, 0);
    check(fire_looper() == 1, "looper callback did not return 1");
    check(keys() == 4, "key count is not 4 after hi DOWN+UP");
    check(last_act() == 1 && last_code() == 37, "last key is not i UP");
    check(last_meta() == 0 && last_flags() == 2, "last key meta/flags are not 0/2");
    check(last_scan() == 0 && last_rep() == 0, "last key scan/repeat are not 0/0");
    check(text_len() == 2, "typed text length is not 2");
    check(text() != 0 && strcmp(text(), "hi") == 0, "typed text is not hi");
    check(last_finish_handled() == 1, "key was not finished consumed");
    if (failures == 0)
        printf("PASS: ime-harness ASCII keys logged with all fields, text hi\n");

    // [3] Shift, DEL, ENTER, UNKNOWN, MULTIPLE.
    push_key_full(queue, 0, 29, 1, 2, 0, 0); // 'a' with SHIFT -> 'A'
    push_key_full(queue, 1, 29, 1, 2, 0, 0);
    check(fire_looper() == 1, "looper callback did not return 1 (shift)");
    check(text_len() == 3 && strcmp(text(), "hiA") == 0, "shift-a did not append A");
    check(last_meta() == 1, "shift meta was not recorded");
    push_key_full(queue, 0, 67, 0, 2, 0, 0); // DEL
    check(fire_looper() == 1, "looper callback did not return 1 (DEL)");
    check(text_len() == 2 && strcmp(text(), "hi") == 0, "DEL did not remove A");
    push_key_full(queue, 0, 66, 0, 2, 0, 0); // ENTER types nothing
    check(fire_looper() == 1, "looper callback did not return 1 (ENTER)");
    check(text_len() == 2, "ENTER changed the text");
    push_key_full(queue, 0, 0, 0, 2, 0, 0); // UNKNOWN types nothing
    check(fire_looper() == 1, "looper callback did not return 1 (UNKNOWN)");
    check(text_len() == 2 && last_code() == 0, "UNKNOWN key was not logged as code 0");
    push_key_full(queue, 2, 0, 0, 2, 0, 3); // MULTIPLE, repeat 3: logged, not inserted
    check(fire_looper() == 1, "looper callback did not return 1 (MULTIPLE)");
    check(text_len() == 2 && last_act() == 2 && last_rep() == 3,
          "MULTIPLE was not logged with act 2 rep 3 or changed the text");
    if (failures == 0)
        printf("PASS: ime-harness shift/DEL/ENTER/UNKNOWN/MULTIPLE\n");

    // [4] BACK is finished unconsumed so the system still exits the app.
    push_key_full(queue, 0, 4, 0, 0, 0, 0);
    push_key_full(queue, 1, 4, 0, 0, 0, 0);
    check(fire_looper() == 1, "looper callback did not return 1 (BACK)");
    check(last_finish_handled() == 0, "BACK was finished consumed");
    check(text_len() == 2, "BACK changed the text");
    if (failures == 0)
        printf("PASS: ime-harness BACK left unconsumed\n");

    // [5] Taps: SHOW (FORCED=2), HIDE (NOT_ALWAYS=2), field (IMPLICIT=1),
    // and -- M4.3 -- background taps, which must NOT focus and must NOT
    // call showSoftInput. Tap points come from the probe's own layout
    // diagnostics, not hardcoded geometry: at 160 dpi the inset is 24,
    // the field is y 72..136, the buttons y 236..284; the background
    // tap (200,200) sits between the field and the buttons.
    check(dpi() == 160, "density was not recorded as 160");
    check(inset_top() == 24, "inset at 160 dpi is not 24");
    check(title_y() == 24 && title_y() >= inset_top(), "title is not at the inset");
    check(field_top() == 72 && field_top() >= inset_top(), "field is not below the inset");
    check(field_bot() == 136 && btn_top() == 236, "field/button geometry is not 136/236");
    push_motion(queue, 0, 104.0f, (float)(btn_top() + 24));
    push_motion(queue, 1, 104.0f, (float)(btn_top() + 24));
    check(fire_looper() == 1, "looper callback did not return 1 (SHOW tap)");
    check(show_calls() == 1 && soft_show_calls() == 1, "SHOW tap did not call showSoftInput once");
    check(soft_last_show_flags() == 2, "SHOW tap did not use FORCED (2)");
    check(kb_req() == 1, "keyboard was not marked requested after SHOW");
    push_motion(queue, 0, 296.0f, (float)(btn_top() + 24));
    push_motion(queue, 1, 296.0f, (float)(btn_top() + 24));
    check(fire_looper() == 1, "looper callback did not return 1 (HIDE tap)");
    check(hide_calls() == 1 && soft_hide_calls() == 1, "HIDE tap did not call hideSoftInput once");
    check(soft_last_hide_flags() == 2, "HIDE tap did not use NOT_ALWAYS (2)");
    check(kb_req() == 0, "keyboard was still marked requested after HIDE");
    push_motion(queue, 0, 200.0f, 200.0f);
    push_motion(queue, 1, 200.0f, 200.0f);
    check(fire_looper() == 1, "looper callback did not return 1 (background tap)");
    check(show_calls() == 1 && soft_show_calls() == 1, "background tap called showSoftInput");
    check(hide_calls() == 1 && soft_hide_calls() == 1, "background tap called hideSoftInput");
    check(focused() == 0, "background tap focused the field");
    check(bg_taps() == 1, "background tap was not counted");
    log_external = read_file(external_log);
    check_contains(log_external, "ime: background tap 200 200", "log file has no background tap line");
    free(log_external);
    push_motion(queue, 0, 200.0f, (float)((field_top() + field_bot()) / 2));
    push_motion(queue, 1, 200.0f, (float)((field_top() + field_bot()) / 2));
    check(fire_looper() == 1, "looper callback did not return 1 (field tap)");
    check(show_calls() == 2 && soft_show_calls() == 2, "field tap did not call showSoftInput");
    check(soft_last_show_flags() == 1, "field tap did not use IMPLICIT (1)");
    check(kb_req() == 1, "keyboard was not marked requested after field tap");
    check(focused() == 1, "field tap did not focus the field");
    push_motion(queue, 0, 200.0f, 200.0f);
    push_motion(queue, 1, 200.0f, 200.0f);
    check(fire_looper() == 1, "looper callback did not return 1 (background tap 2)");
    check(show_calls() == 2 && soft_show_calls() == 2, "background tap after focus called showSoftInput");
    check(focused() == 1, "background tap unfocused the field");
    check(bg_taps() == 2, "second background tap was not counted");
    if (failures == 0)
        printf("PASS: ime-harness SHOW/HIDE/field taps request keyboard with right flags; background taps focus nothing\n");

    // [6] Content rect: the keyboard-visibility signal.
    rect_arg[0] = 0;
    rect_arg[1] = 0;
    rect_arg[2] = 400;
    rect_arg[3] = 150;
    check(call2(cbtab, 13, activity, rect_arg) == 0, "content-rect did not return 0");
    check(rects() == 1, "content-rect count is not 1");
    log_external = read_file(external_log);
    check_contains(log_external, "crect 0 0 400 150", "log file has no content-rect line");
    free(log_external);
    if (failures == 0)
        printf("PASS: ime-harness content rect logged (0 0 400 150)\n");

    // [7] A pre-dispatched event is skipped, never finished, never logged
    // as a key. The stub's queue already consumed it from getEvent's view;
    // the assertion is that the probe counted no key for it.
    set_predispatch(1);
    push_key_full(queue, 0, 52, 0, 2, 0, 0); // 'x' DOWN, pre-dispatched
    check(fire_looper() == 1, "looper callback did not return 1 (pre-dispatched)");
    set_predispatch(0);
    check(pre() == 1, "pre-dispatched count is not 1");
    check(text_len() == 2, "pre-dispatched key leaked into the text");
    log_external = read_file(external_log);
    check_contains(log_external, "ime: pre-dispatched, skipped", "log file has no pre-dispatched line");
    free(log_external);
    if (failures == 0)
        printf("PASS: ime-harness pre-dispatched event skipped\n");

    // [8] SafeArea (M4.3): the top inset follows the density (24dp) and
    // the content-rect top, whichever is larger; the density floor
    // returns when the rect top drops. 480 dpi -> inset 72, field
    // 120..184; a field tap there still focuses + shows exactly once;
    // a background tap there still shows nothing; rect top 100 ->
    // inset 100; rect top 0 -> inset 24 again.
    set_density(480);
    check(call1(cbtab, 14, activity) == 0, "onConfigurationChanged did not return 0 (480)");
    check(dpi() == 480, "density was not recorded as 480");
    check(inset_top() == 72, "inset at 480 dpi is not 72");
    check(title_y() == 72 && title_y() >= inset_top(), "title is not at the 480 dpi inset");
    check(field_top() == 120 && field_top() >= inset_top(), "field is not below the 480 dpi inset");
    push_motion(queue, 0, 200.0f, (float)((field_top() + field_bot()) / 2));
    push_motion(queue, 1, 200.0f, (float)((field_top() + field_bot()) / 2));
    check(fire_looper() == 1, "looper callback did not return 1 (field tap at 480 dpi)");
    check(show_calls() == 3 && soft_show_calls() == 3, "field tap at 480 dpi did not call showSoftInput once");
    check(soft_last_show_flags() == 1, "field tap at 480 dpi did not use IMPLICIT (1)");
    check(focused() == 1, "field tap at 480 dpi did not focus the field");
    push_motion(queue, 0, 200.0f, 200.0f);
    push_motion(queue, 1, 200.0f, 200.0f);
    check(fire_looper() == 1, "looper callback did not return 1 (background tap at 480 dpi)");
    check(show_calls() == 3 && soft_show_calls() == 3, "background tap at 480 dpi called showSoftInput");
    check(bg_taps() == 3, "background tap at 480 dpi was not counted");
    set_density(160);
    check(call1(cbtab, 14, activity) == 0, "onConfigurationChanged did not return 0 (160)");
    check(dpi() == 160, "density was not recorded as 160 again");
    check(inset_top() == 24, "inset did not return to 24 at 160 dpi");
    check(title_y() == 24 && field_top() == 72, "title/field did not return to the 160 dpi inset");
    rect_arg[0] = 0;
    rect_arg[1] = 100;
    rect_arg[2] = 400;
    rect_arg[3] = 300;
    check(call2(cbtab, 13, activity, rect_arg) == 0, "content-rect (top 100) did not return 0");
    check(rects() == 2, "content-rect count is not 2 after the top-100 rect");
    check(inset_top() == 100, "content-rect top 100 did not raise the inset to 100");
    check(title_y() == 100 && field_top() == 148, "title/field did not move to the rect-top inset");
    log_external = read_file(external_log);
    check_contains(log_external, "ime: inset top 100 crect top 100", "log file has no inset-raised line");
    free(log_external);
    rect_arg[0] = 0;
    rect_arg[1] = 0;
    rect_arg[2] = 400;
    rect_arg[3] = 300;
    check(call2(cbtab, 13, activity, rect_arg) == 0, "content-rect (top 0) did not return 0");
    check(rects() == 3, "content-rect count is not 3 after the top-0 rect");
    check(inset_top() == 24, "content-rect top 0 did not return the inset to the density floor");
    check(title_y() == 24 && field_top() == 72, "title/field did not return to the density floor");
    if (failures == 0)
        printf("PASS: ime-harness SafeArea: density 480 -> inset 72, rect top 100 -> inset 100, floor 24\n");

    // [9] Log file: every key line reached the file, and teardown runs.
    log_external = read_file(external_log);
    check_contains(log_external, "key act 0 code 36 meta 0 flags 2 scan 0 rep 0",
                   "log file has no full key line for h DOWN");
    check_contains(log_external, "ime: showSoftInput FORCED (button)",
                   "log file has no SHOW line");
    check_contains(log_external, "ime: showSoftInput IMPLICIT (field focus)",
                   "log file has no field-focus line");
    check_contains(log_external, "ime: background tap 200 200",
                   "log file has no background tap line");
    check_contains(log_external, "ime: inset top 24 dpi 160",
                   "log file has no inset line from onCreate");
    free(log_external);
    check(call2i(cbtab, 6, activity, 1) == 0, "focus 1 did not return 0");
    check(call2i(cbtab, 6, activity, 0) == 0, "focus 0 did not return 0");
    log_external = read_file(external_log);
    check_contains(log_external, "ime: focus 1", "log file has no focus 1 line");
    check_contains(log_external, "ime: focus 0", "log file has no focus 0 line");
    free(log_external);
    check(call1(cbtab, 3, activity) == 0, "onPause did not return 0");
    check(call1(cbtab, 4, activity) == 0, "onStop did not return 0");
    {
        // onSaveInstanceState answers NULL with *outSize = 0.
        typedef void *(*save_fn)(void *, size_t *);
        save_fn save;
        void *p = cbtab[2];
        size_t outSize = 7;
        memcpy(&save, &p, sizeof save);
        check(p != 0, "onSaveInstanceState was not installed");
        if (p) {
            check(save(activity, &outSize) == 0, "onSaveInstanceState did not return NULL");
            check(outSize == 0, "onSaveInstanceState left *outSize nonzero");
        }
    }
    check(call1(cbtab, 5, activity) == 0, "onDestroy did not return 0");
    check(call2(cbtab, 10, activity, win) == 0, "window-destroyed did not return 0");
    check(call2(cbtab, 12, activity, queue) == 0, "input-queue-destroyed did not return 0");
    log_external = read_file(external_log);
    check_contains(log_external, "ime: onDestroy", "log file has no onDestroy line");
    free(log_external);
    if (failures == 0)
        printf("PASS: ime-harness log file complete + teardown clean\n");

    destroy_window(win);
    destroy_queue(queue);

    if (failures == 0) {
        printf("PASS: ui-ime-harness (9/9)\n");
        return 0;
    }
    fprintf(stderr, "FAIL: ui-ime-harness (%d failures)\n", failures);
    return 1;
}
