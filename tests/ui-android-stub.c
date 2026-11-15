// ui-android-stub.c -- device-free stand-ins for Android's liblog.so and
// libandroid.so, for the AsterUI Android harness (tests/ui-android-harness.c).
//
// Built TWICE from this one file: once as liblog.so (for
// __android_log_print) and once as libandroid.so (for ANativeWindow_*,
// AInputQueue_*, AInputEvent_*, AMotionEvent_* and ALooper_forThread).
// liblog.so is built with -DUI_STUB_LOG_ONLY so it exports ONLY
// __android_log_print: if both libraries exported the Android fakes, the
// backend's calls would bind to the first copy the loader finds
// (liblog.so, first in DT_NEEDED order) while the harness reads the stub
// state from libandroid.so -- two different copies of the globals, so the
// stored looper callback would never be visible to the harness. With the
// split, every Android symbol has exactly one provider.
// Both copies export __android_log_print; the behaviour is identical, so
// it does not matter which one answers a given log call.
//
// The fake window is a malloc'd RGBA8888 buffer (default 400x300, stride =
// width). ANativeWindow_lock fills the ANativeWindow_Buffer the Aster
// backend reads (width@0 height@4 stride@8 format@12 bits@16);
// unlockAndPost records the frame and hashes the buffer. The fake input
// queue is a scriptable list of motion and key events; AMotionEvent_getX/Y are C
// functions returning float (a real f32 return in s0), so the Aster
// f32 capture (M1.2a: declared -> f32, passed to lrintf as an argument)
// sees exactly the value a real device would deliver. attachLooper stores
// the looper callback so the harness can invoke it directly (no real
// looper runs under qemu).
//
// This file is C test infrastructure ONLY, mirroring the repo's own
// lifecycle-harness.c / liblog-stub.c pattern. No framework or app code
// is C.

#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// --- liblog: __android_log_print -> stderr. ---
// This is the only symbol the liblog.so build exports: everything below
// the guard is libandroid-only (see below).

int __android_log_print(int prio, const char *tag, const char *fmt, ...) {
    va_list ap;
    (void)prio;
    fprintf(stderr, "[%s] ", tag ? tag : "");
    va_start(ap, fmt);
    vfprintf(stderr, fmt ? fmt : "", ap);
    va_end(ap);
    fputc('\n', stderr);
    return 0;
}

// Everything below this line is libandroid-only: with -DUI_STUB_LOG_ONLY
// (the liblog.so build) the rest of the file is skipped, so liblog.so
// exports only __android_log_print above.
#ifndef UI_STUB_LOG_ONLY

typedef struct FakeWindow {
    int32_t width, height, stride, format;
    uint32_t *pixels;
    int frames_presented;
} FakeWindow;

// ANativeWindow_Buffer: width@0 height@4 stride@8 format@12 bits@16.
typedef struct AWindowBuffer {
    int32_t width, height, stride, format;
    void *bits;
} AWindowBuffer;

#define MAX_EVENTS 64

typedef struct FakeEvent {
    int32_t type;
    int32_t action;
    int32_t keycode;
    int32_t meta;
    int32_t flags;
    int32_t scan;
    int32_t repeat;
    float x, y;
} FakeEvent;

typedef struct FakeQueue {
    FakeEvent events[MAX_EVENTS];
    int head, tail;
} FakeQueue;

typedef int (*looper_cb_fn)(int fd, int events, void *data);

static looper_cb_fn g_looper_cb = 0;
static void *g_looper_data = 0;
static int g_looper_ident = 0;
static int g_last_finish_handled = -1;
// M3.4 (IME probe): make the next preDispatchEvent answer nonzero, so
// the harness can prove the probe skips (never finishEvent) an event the
// IME pre-dispatched. 0 is the normal path.
static int g_stub_predispatch = 0;

void ui_stub_set_predispatch(int v) { g_stub_predispatch = v; }

// --- libandroid: ANativeWindow. ---

int ANativeWindow_setBuffersGeometry(void *window, int width, int height, int format) {
    FakeWindow *w = (FakeWindow *)window;
    (void)width;
    (void)height;
    if (!w) return -1;
    if (format != 0) w->format = format;
    return 0;
}

int ANativeWindow_lock(void *window, void *outBuffer, void *inOutDirty) {
    FakeWindow *w = (FakeWindow *)window;
    AWindowBuffer *b = (AWindowBuffer *)outBuffer;
    (void)inOutDirty;
    if (!w || !b) return -1;
    b->width = w->width;
    b->height = w->height;
    b->stride = w->stride;
    b->format = w->format;
    b->bits = w->pixels;
    return 0;
}

int ANativeWindow_unlockAndPost(void *window) {
    FakeWindow *w = (FakeWindow *)window;
    if (!w) return -1;
    w->frames_presented++;
    return 0;
}

// --- libandroid: AInputQueue / AInputEvent / AMotionEvent / ALooper. ---

int AInputQueue_attachLooper(void *queue, void *looper, int ident, void *cb, void *data) {
    (void)queue;
    (void)looper;
    memcpy(&g_looper_cb, &cb, sizeof g_looper_cb);
    g_looper_data = data;
    g_looper_ident = ident;
    return 1;
}

int AInputQueue_detachLooper(void *queue) {
    (void)queue;
    g_looper_cb = 0;
    g_looper_data = 0;
    g_looper_ident = 0;
    return 0;
}

int AInputQueue_getEvent(void *queue, void *outEvent) {
    FakeQueue *q = (FakeQueue *)queue;
    if (!q || q->head == q->tail) return -1;
    *(void **)outEvent = &q->events[q->head];
    q->head = (q->head + 1) % MAX_EVENTS;
    return 0;
}

int AInputQueue_preDispatchEvent(void *queue, void *event) {
    (void)queue;
    (void)event;
    return g_stub_predispatch;
}

int AInputQueue_finishEvent(void *queue, void *event, int handled) {
    (void)queue;
    (void)event;
    (void)handled;
    g_last_finish_handled = handled;
    return 0;
}

// M3.4 (IME probe): the handled value of the most recent finishEvent
// (-1 before any). The probe finishes BACK unconsumed (0) and every
// other key consumed (1); the harness asserts both.
int ui_stub_last_finish_handled(void) { return g_last_finish_handled; }

int AInputEvent_getType(void *event) {
    return ((FakeEvent *)event)->type;
}

int AMotionEvent_getAction(void *event) {
    return ((FakeEvent *)event)->action;
}

float AMotionEvent_getX(void *event, int pointerIndex) {
    (void)pointerIndex;
    return ((FakeEvent *)event)->x;
}

float AMotionEvent_getY(void *event, int pointerIndex) {
    (void)pointerIndex;
    return ((FakeEvent *)event)->y;
}

int AKeyEvent_getAction(void *event) {
    return ((FakeEvent *)event)->action;
}

int AKeyEvent_getKeyCode(void *event) {
    return ((FakeEvent *)event)->keycode;
}

// M3.4 (IME probe): the remaining key-event accessors the probe logs.
// AKeyEvent_getUnicodeChar deliberately does NOT exist here: there is no
// such function in the NDK's android/input.h (verified against the AOSP
// header) — getUnicodeChar is a Java KeyEvent method only. Native code
// gets the key code + meta state and maps ASCII itself.
int AKeyEvent_getMetaState(void *event) {
    return ((FakeEvent *)event)->meta;
}

int AKeyEvent_getFlags(void *event) {
    return ((FakeEvent *)event)->flags;
}

int AKeyEvent_getScanCode(void *event) {
    return ((FakeEvent *)event)->scan;
}

int AKeyEvent_getRepeatCount(void *event) {
    return ((FakeEvent *)event)->repeat;
}

// M3.4 (IME probe): ANativeActivity_showSoftInput / hideSoftInput.
// The real ones ask the InputMethodManager to show/hide the keyboard;
// the fake records the calls so the harness can assert the probe asked
// with the right flags (IMPLICIT=1, FORCED=2, NOT_ALWAYS=2).
static int g_soft_show_calls = 0;
static int g_soft_hide_calls = 0;
static int g_soft_last_show_flags = -1;
static int g_soft_last_hide_flags = -1;

void ANativeActivity_showSoftInput(void *activity, uint32_t flags) {
    (void)activity;
    g_soft_show_calls++;
    g_soft_last_show_flags = (int)flags;
}

void ANativeActivity_hideSoftInput(void *activity, uint32_t flags) {
    (void)activity;
    g_soft_hide_calls++;
    g_soft_last_hide_flags = (int)flags;
}

int ui_stub_soft_show_calls(void) { return g_soft_show_calls; }
int ui_stub_soft_hide_calls(void) { return g_soft_hide_calls; }
int ui_stub_soft_last_show_flags(void) { return g_soft_last_show_flags; }
int ui_stub_soft_last_hide_flags(void) { return g_soft_last_hide_flags; }

void *ALooper_forThread(void) {
    return (void *)0x1000;
}

// --- libandroid: AConfiguration (M1.1 SafeArea density estimate). ---
// The backend reads the screen density through AConfiguration_new /
// AConfiguration_fromAssetManager / AConfiguration_getDensity /
// AConfiguration_delete (android/configuration.h, libandroid.so).
// The fake stores one int (the density) per config object; the value
// comes from g_stub_density, set by the harness per scenario
// (480 = xxhigh phone, 0 = unknown -> the backend falls back to 160).
// The asset-manager argument is ignored: there is no real AssetManager
// under qemu, and the density is the only field the backend reads.

static int g_stub_density = 480;

void ui_stub_set_density(int dpi) {
    g_stub_density = dpi;
}

void *AConfiguration_new(void) {
    int *cfg = (int *)calloc(1, sizeof *cfg);
    if (!cfg) return 0;
    *cfg = g_stub_density;
    return cfg;
}

void AConfiguration_fromAssetManager(void *config, void *asset_manager) {
    (void)asset_manager;
    if (config) *(int *)config = g_stub_density;
}

int AConfiguration_getDensity(void *config) {
    if (!config) return g_stub_density;
    return *(int *)config;
}

void AConfiguration_delete(void *config) {
    free(config);
}

// A non-null fake asset manager handle for the fake activity's
// assetManager slot (offset 64). Its value is never dereferenced.
void *ui_stub_asset_manager(void) {
    return (void *)0x4242;
}

// --- Harness helpers (exported from both stub libraries). ---

uint32_t ui_stub_buffer_hash(void *window) {
    FakeWindow *w = (FakeWindow *)window;
    uint32_t h = 2166136261u;
    unsigned char *p;
    size_t n, i;
    if (!w || !w->pixels) return 0;
    p = (unsigned char *)w->pixels;
    n = (size_t)w->width * (size_t)w->height * 4;
    for (i = 0; i < n; i++) {
        h ^= p[i];
        h *= 16777619u;
    }
    return h;
}

void *ui_stub_create_window(int width, int height) {
    FakeWindow *w = (FakeWindow *)calloc(1, sizeof *w);
    if (!w) return 0;
    w->width = width;
    w->height = height;
    w->stride = width;
    w->format = 1; // RGBA_8888, as the backend requests
    w->pixels = (uint32_t *)calloc((size_t)width * (size_t)height, 4);
    if (!w->pixels) {
        free(w);
        return 0;
    }
    return w;
}

void ui_stub_destroy_window(void *window) {
    FakeWindow *w = (FakeWindow *)window;
    if (!w) return;
    free(w->pixels);
    free(w);
}

// Resize the fake window (rotation simulation): fresh zeroed pixels, same
// format; frames_presented is kept so the harness can count across it.
void ui_stub_resize_window(void *window, int width, int height) {
    FakeWindow *w = (FakeWindow *)window;
    uint32_t *px;
    if (!w) return;
    px = (uint32_t *)calloc((size_t)width * (size_t)height, 4);
    if (!px) return;
    free(w->pixels);
    w->pixels = px;
    w->width = width;
    w->height = height;
    w->stride = width;
}

// One pixel as a little-endian word: R in the low byte, A in the high byte
// (the backend writes R, G, B, 255 in that order). 0xFFFFFFFF out of range.
uint32_t ui_stub_pixel(void *window, int x, int y) {
    FakeWindow *w = (FakeWindow *)window;
    if (!w || !w->pixels || x < 0 || y < 0 || x >= w->width || y >= w->height)
        return 0xFFFFFFFFu;
    return w->pixels[(size_t)y * (size_t)w->stride + (size_t)x];
}

int ui_stub_frames_presented(void *window) {
    FakeWindow *w = (FakeWindow *)window;
    return w ? w->frames_presented : -1;
}

void *ui_stub_create_queue(void) {
    return calloc(1, sizeof(FakeQueue));
}

void ui_stub_destroy_queue(void *queue) {
    free(queue);
}

// Script one motion event (type 2, AINPUT_EVENT_TYPE_MOTION --
// AOSP include/android/input.h, frozen enums: KEY=1, MOTION=2).
// action is the low byte: 0 DOWN, 1 UP, 2 MOVE, 3 CANCEL. A full
// queue drops the event rather than corrupting.
void ui_stub_push_motion(void *queue, int action, float x, float y) {
    FakeQueue *q = (FakeQueue *)queue;
    int next;
    if (!q) return;
    next = (q->tail + 1) % MAX_EVENTS;
    if (next == q->head) return;
    q->events[q->tail].type = 2;
    q->events[q->tail].action = action;
    q->events[q->tail].keycode = 0;
    q->events[q->tail].meta = 0;
    q->events[q->tail].flags = 0;
    q->events[q->tail].scan = 0;
    q->events[q->tail].repeat = 0;
    q->events[q->tail].x = x;
    q->events[q->tail].y = y;
    q->tail = next;
}

// Full key event: also script the meta state, flags, scan code and
// repeat count the probe logs (M3.4). meta bit 0 is AMETA_SHIFT_ON.
void ui_stub_push_key_full(void *queue, int action, int keycode,
                           int meta, int flags, int scan, int repeat) {
    FakeQueue *q = (FakeQueue *)queue;
    int next;
    if (!q) return;
    next = (q->tail + 1) % MAX_EVENTS;
    if (next == q->head) return;
    q->events[q->tail].type = 1;
    q->events[q->tail].action = action;
    q->events[q->tail].keycode = keycode;
    q->events[q->tail].meta = meta;
    q->events[q->tail].flags = flags;
    q->events[q->tail].scan = scan;
    q->events[q->tail].repeat = repeat;
    q->events[q->tail].x = 0.0f;
    q->events[q->tail].y = 0.0f;
    q->tail = next;
}

// Script one key event (type 1, AINPUT_EVENT_TYPE_KEY). action is
// 0 DOWN, 1 UP, 2 MULTIPLE (AKEY_EVENT_ACTION_*); keycode is the
// Android key code (e.g. 66 ENTER). Coordinates are 0: a key event
// has none, and AMotionEvent_getX/Y on it answer 0 -- which is
// exactly how the old backend (type 1 treated as motion) turned a
// key event into a "tap down 0 0" line. A full queue drops the event
// rather than corrupting.
void ui_stub_push_key(void *queue, int action, int keycode) {
    ui_stub_push_key_full(queue, action, keycode, 0, 0, 0, 0);
}

// The looper callback attachLooper stored, or 0 when nothing is attached.
void *ui_stub_looper_cb(void) {
    void *p;
    memcpy(&p, &g_looper_cb, sizeof p);
    return p;
}

// Invoke the stored looper callback the way the main looper would
// (ident as attached, no events). Answers the callback's return, or -1
// when nothing is attached.
int ui_stub_fire_looper(void) {
    if (!g_looper_cb) return -1;
    return g_looper_cb(g_looper_ident, 0, g_looper_data);
}

#endif // UI_STUB_LOG_ONLY
