# Validation — v0.23.15-dev

**Touch input, take two: the pipeline that was inert on a device now answers a finger (P2.3 hotfix).**

The report that started this release was one sentence from a real install:
*"安装后，启动是渐变色背景，手指按下/拖动没有效果，没有40x40白点"* — the app
launched, the gradient drew, and no touch did anything. v0.23.14-dev had
shipped a pipeline that was structurally complete, green in every suite, and
**dead on hardware**. This release finds out why, fixes it, and — the part that
matters — changes the tests so the same class of bug cannot be green again.

---

## The three stacked defects

Every one of them was individually invisible: the app installed, drew, and ran.
Together they made the input path a no-op.

### 1. The callbacks were wired at the wrong offsets

`ANativeActivityCallbacks` is a plain array of function pointers in
declaration order. v0.23.14-dev continued the "device-verified window slots at
56/64/72" cadence to 80/88 for the input queue. But the declaration order is
`onStart` … `onNativeWindowCreated`@56, `onNativeWindowResized`@64,
`onNativeWindowRedrawNeeded`@72, **`onNativeWindowDestroyed`@80**,
**`onInputQueueCreated`@88**, **`onInputQueueDestroyed`@96**. So the example
wrote its input-queue handlers into the *window-destroyed* and
*input-queue-created* slots — and when the framework created the input queue it
called the example's "queue destroyed" handler, which detached a looper that
was never attached. Nothing crashed; nothing ever listened.

The fix wires all six slots by their declared names (56/64/72/80/88/96), and
`onNativeWindowDestroyed` now clears the window state it should clear.

### 2. The drain loop exited on the success code

`AInputQueue_getEvent` returns **0 on success** and a negative value only when
the queue is dry (the 1/0 convention belongs to `AInputQueue_hasEvents`).
v0.23.14-dev's loop ran `while (got == 1)` — a condition that is false on the
very first successful event, so the loop body never executed even when events
were waiting. The condition is `while (got >= 0)`. The sibling call
`AInputQueue_preDispatchEvent` returns 0 = "handle it now"; a non-zero result
means the event was pre-dispatched elsewhere and **must not** be
`finishEvent`-ed this round — the fixed loop drops it and lets it reappear,
instead of consuming an event it did not handle.

### 3. The coordinates were read from the wrong register file

Aster has no `float` type, so `AMotionEvent_getX`/`getY` are declared
`-> i32`. The C `float` result arrives in **s0**; an Aster call reads its
`i32` result with `MOV Wd, W0` — **w0**. v0.23.14-dev believed these were the
same bits ("s0 aliases the low 32 bits of w0"). They are not: they are
different physical register files, and the call read whatever `w0` happened to
hold. On the device that meant the dot position was garbage even if defects 1
and 2 had been fixed.

The fix is a bridge, not a codegen feature. Aster emits no SIMD instruction of
its own and its PLT is eagerly bound (`DT_BIND_NOW`), so the `s0` a
float-returning call leaves behind survives to the next call — and a
zero-argument `lrintf()` issued **immediately** after `getX`/`getY` (argument
read from `s0`, `long` result in `x0`, whose low 32 bits Aster reads as its
`i32` return) hands back the exact integer:

```aster
fn event_x(ev: ptr) -> i32 {
    let junk: i32 = AMotionEvent_getX(ev, 0);   // float -> s0
    return lrintf();                            // s0 -> x0
}
```

The two calls must be adjacent — any Aster call between them could clobber
`s0`. This is the release's **one compiler change**: `ndkLibraryFor` now maps
`lrintf`/`lrint`/`llrint`/`llrintf` → **libm.so**. Without it the emitted
`.so` has no `DT_NEEDED` for libm and the on-device loader aborts `dlopen`
with "cannot locate symbol" — verified against bionic's `libm.map.txt`
(`lrintf` is exported with no API-level restriction, safe at `min-sdk 24`).

### The fourth defect, found while fixing the first three

The touch overlay's pixel-format test was inverted: it wrote 4 opaque bytes
per pixel for `RGBA_8888`-class formats and only 2 for `RGB_565` — the exact
reverse of correct, and a 2-byte write per pixel into a 4-byte-per-pixel
window is a framebuffer overrun waiting for a tall screen. Fixed in the same
commit as the callback rewiring.

---

## What is asserted, and by whom

`tests/touch-checks.sh` (4 layers, registered in `ci.sh`; `native_touch` also
joins the APK verification gate). The assertion that matters is the **capture**,
not a decode of hand-written bits:

> `strtof` — a C function that, like `AMotionEvent_getX`, returns its result as
> a `float` in `s0` — followed immediately by `lrintf()`, must convert
> `0.0` / `1042.0` / `768.0` / `3000.0` / `123.0` / `1042.5` / `1919.5` /
> `-12.0` / `12.5` to `0` / `1042` / `768` / `3000` / `123` / `1042` / `1920` /
> `-12` / `12` — under qemu, through a `.so` dlopened by
> `tests/touch-coord-host.c`.

## The four layers

| # | Layer |
| --- | --- |
| 1 | **The capture chain, under qemu** — `tests/touch-coord-test.ast` builds with `build-so` (the `extern` chain needs the PLT path; `build-elf` cannot resolve `strtof`/`lrintf` at all), `tests/touch-coord-host.c` cross-compiles and `dlopen`s it, the guest loader is given `libc.so`/`libm.so` aliases by `tests/guest-libc-alias.sh`, and `coord_check` must return 0 — one exit code per mismatching value |
| 2 | **Source guards** — the externs (now including `extern fn lrintf() -> i32;`), the six callback offsets (56/64/72/80/88/96), `while (got >= 0) {`, `if (pre == 0) {`, the two bridge helpers, and the *absence* of the superseded `motion_coord` are all asserted against `examples/native_touch.ast`; an awk pass additionally proves every `AMotionEvent_getX`/`getY` call is immediately followed by its `lrintf()` |
| 3 | **The APK gate** — the one-step `.ast` → `build-apk` path, then `validate_apk.py` and `aster verify-apk`, and `readelf -d` on the emitted `.so` requires `libandroid.so`, `liblog.so`, **`libm.so`** and `libc.so` in `DT_NEEDED` — the auto-map and the new libm mapping asserted rather than assumed |
| 4 | **The suite can still fail** — a mutation that breaks the bridge exactly as v0.23.14-dev did (`return lrintf();` → `return junk;`) must make the qemu test exit non-zero |

Layer 4 is what makes the green run mean something, and it is the layer
v0.23.14-dev was missing in spirit: its mutation shifted a *decode* constant
while its test fed the decoder bits by hand, so the test proved the decoder
could fail — and the *capture*, which was what was broken, was never executed.
The new mutation is the v0.23.14-dev bug itself.

### The CI run caught a bug in the new test itself

The first full CI run of this release failed `touch-checks.sh` with
`dlopen failed: ... No such file or directory` — on a suite that had passed
when run by hand. The cause was environmental, and it is worth writing down:
the suite picked its C compiler with "use `$HOSTCC` if set, else auto-detect
the cross compiler", but `ci.sh` **sets `HOSTCC=cc` on x86 runners** (the
native compiler), so the harness was built for x86 and then asked to `dlopen`
an AArch64 `.so` — glibc reports that arch mismatch as a missing file. The
suite had only ever been exercised in the two environments where it happened
to work (no `HOSTCC` at all, or the cross compiler explicitly). The fix
probes for AArch64 capability instead of testing for emptiness — the same test
`tests/host-toolchain-probe.sh` makes — and falls back to the cross toolchain,
so the suite is correct under `HOSTCC=cc`, `HOSTCC` unset and
`HOSTCC=aarch64-linux-gnu-gcc` alike (all three verified). The mutation layer
now gates on the harness binary existing rather than on `$HOSTCC` being set.
The lesson is the release's own lesson one level up: a test that has only run
in the environment it was written in has not been tested.

## Why the old test was green

This is the part worth internalizing. v0.23.14-dev's qemu test declared
`motion_coord` as a **pure Aster function** and fed it six known IEEE-754 bit
patterns. It never called `AMotionEvent_getX` — it could not, no Android
presents one — so it tested the decoder in isolation and the decoder was fine.
The bug lived in the step *before* the decoder: how the bits got out of the
NDK call. A test that exercises only the safe half of a pipeline will stay
green through a broken pipeline. The fix was to move the test boundary
outward: `strtof` is a real C float-returning function available on this host,
so the qemu test now executes the actual capture path — float out of a PLT
call, straight into `lrintf` — and only the NDK function *names* stay
device-only.

## On-device diagnosability

`examples/native_touch.ast` now narrates its pipeline to logcat under the
`AsterTouch` tag on fixed strings (`__android_log_print`): every looper
callback entry, every event action (down/move/up/cancel), pre-dispatch skips,
window create/destroy. Aster cannot format numbers into strings, so the
traces are categorical — but "touch: event pre-dispatched, skipped" versus
silence is the difference between a five-minute diagnosis and another shipped
release.

## Byte-level invariance

| Comparison | Result |
| --- | --- |
| `tests/struct-checks.sh` [4/8] | **261 recorded outputs** — the two `native_touch` lines recomputed for v0.23.15-dev (`build-so` and `build-obj --pic`; `build-elf` stays `FAILED` on both sides, it links `libandroid.so` which exists on a device and not on this host), the other 259 lines byte for byte unchanged |
| Byte-level A/B, old side (v0.23.14 sources, both compilers) | **212/212** byte-identical (40/40 `build-elf`, 86/86 `build-obj`, 86/86 `build-so`) — the release changed nothing for pre-existing code |
| Byte-level A/B, new side (current sources) | **211/212**, the single delta being `native_touch.build-so`: 23256 bytes on both sides, 670 bytes differing — exactly the `lrintf` → `libm.so` `DT_NEEDED` remap, which is the intended change and nothing else |

## Release gate

| Stage | Result |
| --- | --- |
| Strict build (`-Werror`) | zero warnings, `BUILD OK` |
| `tests/touch-checks.sh` | PASS (4/4) |
| `tests/struct-checks.sh` | PASS — 261 recorded outputs reproduced |
| `tests/version-checks.sh` | PASS (6/6) |
| Injected mutation (bridge broken, the v0.23.14-dev bug) | caught (qemu exit non-zero) |
| Byte-level A/B vs v0.23.14-dev | old side **212/212** byte-identical; new side 211/212 with the one intended `DT_NEEDED` delta |
| `tests/ci.sh` (full gate) | **49 passed, 23 skipped, 0 failed** (of 72 checks), exit 0 — identical totals to v0.23.14-dev, with `touch-checks.sh` green |
| Rebuilt APK | `native-touch-v0.23.15-dev.apk` — `validate_apk.py` + `verify-apk` green, `DT_NEEDED` carries libandroid/liblog/libm/libc |
| Exit status | 0 |

The 23 skips are unchanged from v0.23.14-dev: the e2e C-ABI suites self-skip on
the x86_64 sandbox by design — they execute their C host natively, which needs
an AArch64 runner (or the `RUNNER`/qemu routing a future cleanup could add) —
and run for real there. What is new is that this release's own suite runs for
real here: `touch-checks.sh` [1/4] and [4/4] execute the capture chain under
qemu on every host, because the harness was written to be cross-compiled and
qemu-run rather than host-native. The three APK gates (`native_render`,
`icon_text_demo`, `native_touch`) are green, each verified two independent
ways.

## The one boundary that stays open

Everything provable off-device is proven here: the capture chain, the wiring,
the offsets' authority (the NDK header's declaration order, cross-checked
against the published `android/native_activity.h`), the drain and
pre-dispatch contracts, the signing, the linking, the packaging. The *visible*
dot under a real finger is observable only on an arm64 device — the same
boundary `native_render.ast` ships under, and the same boundary that produced
the bug report this release answers. The logcat traces exist so that the next
device run, pass or fail, comes back with evidence instead of a sentence.

## Known follow-up (not a regression, deliberately not fixed here)

`ndkLibraryFor` maps `ALooper_*` and `AInputQueue_*` to `libandroid.so` but has
no `AMotionEvent_*` rule, so `AMotionEvent_getX`/`getY`/`getAction` fall
through to the default `libc.so` mapping. It is harmless today — every motion
event necessarily arrives through an `AInputQueue_*` call, so `libandroid.so`
is always in the dynamic scope when the loader resolves the symbol — and it is
invisible in the A/B evidence, which is why it is left for a dedicated cleanup
rather than smuggled into a hotfix. The `DT_NEEDED` assertion in
`tests/touch-checks.sh` [3/4] (libandroid/liblog/libm/libc all present) is what
would catch it if the scope argument ever stopped holding.
