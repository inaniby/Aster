# Running a Native Activity built by Aster on a real device

This document shows how to turn an Aster source file into an installable,
runnable Android app **without any Java/Kotlin, NDK, aapt, d8, or Gradle** —
Aster emits the native library and the APK directly.

## What Aster produces

`build-apk` emits a **NativeActivity** APK:

- `AndroidManifest.xml` — binary AXML (`android.app.NativeActivity` as the
  launcher activity, plus a `meta-data android.app.lib_name` pointing at your
  shared object).
- `lib/<abi>/lib<libname>.so` — your compiled AArch64 ELF, 4-KiB aligned.
- `META-INF/{MANIFEST.MF, CERT.SF, CERT.RSA}` — the **v1 (JAR) signature**.
- An **APK Signing Block** between the last entry and the central directory —
  the **v2 signature**.

It is **v1 + v2 dual-signed**, by default with your project's own debug key
(`aster keygen`, stored in `.aster/` next to your project root) or, with
`--sign-mode release --keystore <key.pem> --cert <cert.pem>`, with your release
key. Aster ships with no key of its own.

Everything is hand-encoded; there is no subprocess and no external toolchain.

## Prerequisites

- An `adb`-reachable device or emulator running **arm64-v8a** Android
  (API 24 / Android 7.0 or newer is a safe floor; set `--min-sdk` accordingly).
- `adb` on your PATH.
- The `aster` binary built from `src/aster.cpp`:
  ```sh
  c++ -std=c++17 -O2 -Wall -Wextra -Werror -o aster src/aster.cpp
  ```

> Aster does **not** transpile to another language and uses **no external
> toolchain** — it encodes instructions/ELF/APK bytes directly.

## Step 1 — compile the native entry point

`examples/native_activity.ast` defines `ANativeActivity_onCreate`, which the
system calls when the activity is created. Aster resolves the extern NDK call
`__android_log_print` against the device's `liblog` at load time (the required
`DT_NEEDED` is emitted automatically).

```sh
aster build-so examples/native_activity.ast -o libnativeapp.so
```

> `build-so` now auto-emits the required `DT_NEEDED` entries for every `extern`
> import (e.g. `__android_log_print` → `liblog.so`, `ANativeActivity_finish` →
> `libandroid.so`) via a built-in NDK symbol→library map. You no longer need to
> pass `--needed` by hand. If you do pass `--needed LIB`, those entries are kept
> and de-duplicated with the auto-inferred ones.

## Step 1b — (optional) draw a visible frame instead of a black screen

The log-only example shows a **black screen** (NativeActivity has no UI toolkit, and
this app has no drawing code). `examples/native_render.ast` **software-renders a
gradient frame** straight into the window's pixel buffer, so the app shows a picture you
can verify **by eye** — handy when `adb logcat` is unavailable.

It exercises the Aster capabilities added for rendering:

- **A function name is its address.** `ANativeActivity_onCreate` reads the activity's
  callback table (`load_ptr(activity)`) and installs handlers by writing function
  pointers into the table: `*(cb + 56) = on_native_window_created`,
  `*(cb + 64) = on_native_window_resized`, `*(cb + 72) = on_native_window_redraw_needed`.
- **A global array is its address.** `g_winbuf` is an `i32[32]` scratch area passed as
  `&g_winbuf` to `ANativeWindow_lock`, which fills it with the buffer geometry and its
  `bits` pointer.
- **`load_ptr(p)`** loads an 8-byte pointer (here the `bits` pointer at `g_winbuf + 16`).
- **`store_u8(p, i32)`** writes one pixel byte; `*p = <ptr>` stores a pointer (`STR X`).
- **Plain calls between Aster functions.** The shared `draw_frame(window)` body is
  called from all three callbacks (`return draw_frame(window);`); the callbacks receive
  the window pointer as their second argument, so no global state is needed.

> **Why redraw on resize:** `onNativeWindowCreated` fires while the Surface is
> still small. Registering `onNativeWindowResized` + `onNativeWindowRedrawNeeded`
> and repainting at the current geometry guarantees every geometry change is
> followed by a full repaint. (An earlier version of this note blamed the
> "stripes + black area" artifact on a single stale scaled-up frame; the real
> cause was the byte-offset bug below. The callbacks remain correct and useful.)

> **Pixel offsets — `stride` counts PIXELS (this caused a real device bug):**
> `ANativeWindow_Buffer.stride` is the number of **pixels** per row (it can exceed
> `width` because of alignment padding). The byte offset of pixel (x, y) is
> therefore `(y * stride + x) * bytes_per_pixel` — the row term must be scaled
> too. Writing `y * stride + x * 4` instead lands every row 1/4 of the way down:
> four source rows overlap into each display row (a sawtooth with period
> `stride/4`) and only the top quarter of the buffer is covered. That is exactly
> what a v0.22.45-dev device screenshot showed (bands repeating every 304 px on a
> 1216-stride window, content only in the top ~675 of 2688 rows), and no static
> check can see it — `tests/pixel-offset-checks.sh` now guards both the source
> pattern and the runtime layout.

> **Pixel format:** `draw_frame` requests `WINDOW_FORMAT_RGBA_8888` via
> `ANativeWindow_setBuffersGeometry` and then reads the format the buffer actually
> reports (`ANativeWindow_Buffer.format@12`). 32-bit formats (`RGBA_8888`=1,
> `RGBX_8888`=2) take 4 bytes per pixel; `RGB_565`(=4) takes 2 bytes, encoded
> `r5 g6 b5` little-endian. Aster has no shift operator, so the 565 value is
> assembled with division/multiplication (`(r/8)*2048 + (g/4)*32 + 16`) and split
> into bytes with `v-(v/256)*256` / `v/256`. An unknown format (e.g. YV12) is
> skipped with a log line rather than smeared. `ANativeWindow_lock` failures are
> checked before the buffer fields are used.

### The struct offsets are load-bearing (and where they come from)

A wrong offset passes every static check and only crashes on the device — which is
exactly what happened until v0.22.43-dev. The offsets below were pinned down from
**two independent sources** (the `ndk-sys` bindgen bindings on docs.rs, and the Rust
`android_ffi` bindings), because neither the disassembly nor the APK validator can
see a semantic offset error:

| struct | field | offset | note |
| --- | --- | --- | --- |
| `ANativeActivity` | `callbacks` | **0** | first field of the struct |
| `ANativeActivity` | `sdkVersion` | 48 | `int32` — **not a pointer** (this was the crash) |
| `ANativeActivityCallbacks` | `onNativeWindowCreated` | **56** | 8th function pointer; `onSaveInstanceState` sits in 3rd place, which is why it is 56 and not 48 |
| `ANativeActivityCallbacks` | `onNativeWindowResized` | **64** | repaint when the window changes size |
| `ANativeActivityCallbacks` | `onNativeWindowRedrawNeeded` | **72** | repaint on a redraw request |
| `ANativeWindow_Buffer` | `width` / `height` / `stride` / `format` | 0 / 4 / 8 / 12 | `i32` fields |
| `ANativeWindow_Buffer` | `bits` | **16** | the pixel buffer pointer |

```sh
aster build-so examples/native_render.ast -o libnativeapp.so
aster build-apk libnativeapp.so -o nativeapp.apk \
    --package com.aster.nativeapp --libname nativeapp \
    --label "Aster Native" --min-sdk 24 --target-sdk 34 \
    --version-code 1 --version-name "1.0"
```

> Aster still requires a call to be used as a value: assign it to a `let` or `return`
> it. A bare `store_u8(p, v);` is **not** a statement — write
> `let s: i32 = store_u8(p, v);`.

## Step 2 — package the APK

One command is enough — `build-apk` compiles the `.ast` itself (v0.22.47-dev+),
running the same `build-so` pipeline internally:

```sh
aster build-apk examples/native_render.ast -o nativeapp.apk \
    --package com.aster.nativeapp \
    --libname nativeapp \
    --label "Aster Native" \
    --min-sdk 24 --target-sdk 34 \
    --version-code 1 --version-name "1.0"
```

Compilation and packaging are still separate concerns; the intermediate `.so` is
simply no longer a manual step. Whenever you want it — for `objdump`,
`readelf -d`, or qemu — either use the two-step form or add `--emit-so`:

```sh
aster build-so examples/native_render.ast -o libnativeapp.so   # two-step form
aster build-apk libnativeapp.so -o nativeapp.apk --package com.aster.nativeapp ...

aster build-apk examples/native_render.ast -o nativeapp.apk \  # one-step + keep .so
    --package com.aster.nativeapp --emit-so libnativeapp.so ...
```

The one-step build packages a `.so` with `DT_SONAME lib<libname>.so` (matching
the path it is packaged at), byte-identical to the two-step build with the same
`--soname` — `tests/apk-checks.sh` asserts exactly that.

Key flags:

| flag | meaning |
|------|---------|
| `--package`   | Java-style application id (reverse-DNS). **Required.** |
| `--libname`   | basename of the `.so` (without `lib`/`so`); the `lib_name` meta-data. |
| `--abi`       | ABI folder under `lib/` (default `arm64-v8a`). |
| `--label`     | launcher label for the app. |
| `--min-sdk`   | `minSdkVersion`. |
| `--target-sdk`| `targetSdkVersion`. |
| `--version-code` / `--version-name` | version metadata. |
| `--emit-so`   | keep the `.so` compiled from `.ast` input (inspection artifact). |

## Step 3 — install and run

```sh
adb install -r nativeapp.apk
adb shell am start -n com.aster.nativeapp/android.app.NativeActivity
```

Watch the log — the example prints `Hello from Aster` through `liblog`:

```sh
adb logcat -s Aster
```

The example logs `Hello from Aster` via `liblog` and then returns, leaving the
activity alive. A **black screen is expected** — `NativeActivity` has no UI
toolkit, so there is nothing to draw. The proof of success is the log line, not
the screen. (An earlier version called `ANativeActivity_finish` on create, which
closed the app immediately; that is gone.)

## Signature / install notes

- **Debug builds** (`--sign-mode debug`, the default) are signed with a
  self-signed development certificate Aster generates for the project on first
  use (`.aster/debug.key.pem` + `.aster/debug.crt.pem`, CN=Aster Dev Signing
  Key). Install requires allowing apps from unknown sources, or side-loading
  via `adb install`. It is **not** a Google Play production key.
- **Release builds** (`--sign-mode release --keystore <key.pem> --cert <cert.pem>`)
  are signed with your key. Both options are required: a release build without
  them stops instead of quietly falling back to a debug key.
- Every build is **v1 + v2 dual-signed**, and Aster re-verifies the APK in
  memory before writing it (`--no-verify` bypasses only that check). You can
  re-check a file at any time:

  ```sh
  aster verify-apk nativeapp.apk
  ```

- Key material is read as PEM or DER: PKCS#8 or PKCS#1 private keys
  (unencrypted) and X.509 certificates, so anything `openssl` or `keytool`
  wrote can be used directly.

## Verify the artifact

```sh
python3 tests/validate_apk.py nativeapp.apk \
    --package com.aster.nativeapp --libname nativeapp
```

It re-derives ZIP/CRC-32 integrity, the APK layout, 4-KiB `.so` alignment,
the binary AXML fields, and the full v1 signature chain (including an
`openssl smime -verify` cross-check) — all with the Python standard library.

## Troubleshooting: "the app opens then immediately closes"

The two real launch-time causes are listed first; both are caught by
`validate_apk.py`, so run it before reaching for `logcat`.

1. **Corrupt binary Manifest (the most common silent failure).** If string
   attributes in `AndroidManifest.xml` are mis-encoded, the framework reads the
   wrong values — `android:name` can become the literal `package` (a class that
   does not exist) and `android.app.lib_name` can point nowhere, so
   `NativeActivity` cannot find or load the `.so`:

   ```
   E AndroidRuntime: java.lang.RuntimeException: Unable to start activity ComponentInfo{...}:
       java.lang.ClassNotFoundException: Didn't find class "package" on path: ...
   ```
   This happens when a string attribute's `typedValue.data` is `0` (the loader
   then reads string-pool index 0). Current Aster writes the correct pool index
   into `data`; rebuild with a current `aster`. `validate_apk.py` now fails
   loudly if any string attribute's `data` is zero, or if the manifest lacks
   `android.app.NativeActivity` / a non-empty `lib_name` — run it to confirm.

2. **Dynamic-linker failure at `dlopen` (missing `DT_NEEDED`).** If your `.so`
   calls an `extern` NDK function but has no matching `DT_NEEDED`, Android's
   RTLD_NOW loader aborts the load:

   ```
   E native  : cannot locate symbol "__android_log_print" referenced by ".../libnativeapp.so"
   ```
   Current Aster auto-emits the correct `DT_NEEDED` for known NDK symbols; verify
   with `readelf -d libnativeapp.so` (you should see `liblog.so`, etc.).

Other things to confirm:

- **Stripes, a repeating sawtooth, or a picture that only covers part of the
  screen (no crash, no log output).** If the app draws but the image repeats
  every `stride/bpp` pixels and/or only the top slice of the window is covered,
  the pixel byte offset is wrong: `stride` counts **pixels**, so use
  `(y * stride + x) * bpp`. `y * stride + x * bpp` writes each row 1/bpp of the
  way down — four overlapping source rows per display row (the sawtooth) and an
  untouched bottom region. This was the v0.22.45-dev device bug; confirm the fix
  in the disassembly (`mul` for `y*stride`, then `add x`, then `mul` by 4 or 2
  before the `strb`s) and run `tests/pixel-offset-checks.sh`.
- **A wrong NDK struct offset in *your* code (SIGSEGV, no logcat output).** If the
  app dies before anything is drawn or logged, suspect a raw struct offset: reading
  a non-pointer field as a pointer (or vice versa) and then dereferencing it kills
  the process with no managed exception. This is what `load_ptr(activity + 48)`
  did until v0.22.43-dev — offset 48 is `sdkVersion` (an `int32`), not `callbacks`
  (offset 0), so the callback table write hit address ~89. Pin every offset against
  a real source (`ndk-sys`'s bindgen output mirrors the NDK headers exactly), then
  confirm the generated code with `llvm-objdump -d` — `ANativeActivity_onCreate`
  should read `ldr x0,[x0]` (offset 0) before any callback store.
- **Missing `ANativeActivity_onCreate`.** Must be exported by plain name (no C++
  mangling). `readelf --dyn-syms libnativeapp.so | grep ANativeActivity_onCreate`.
- **`android:exported` on API 31+.** The launcher `<activity>` must declare
  `android:exported="true"` (Aster sets this) or Android 12+ refuses to launch it.
- **A black screen is NOT a crash.** `NativeActivity` has no UI; after `onCreate`
  logs `Hello from Aster` the activity simply stays alive. Watch `adb logcat -s Aster`.
  With `examples/native_render.ast` the screen shows a gradient instead.
