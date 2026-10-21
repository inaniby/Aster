# Verifying the icon + text demo on Termux

Termux is the ideal place to check this release, because it is the target: an
AArch64 Linux userland running on Android. Everything below runs **natively** —
no qemu, no NDK, no aapt, no apksigner, no adb required (adb is optional, for
installing).

## 0. What you need

```sh
pkg update
pkg install clang python       # clang for the compiler itself, python for the checks
```

That is the whole dependency list. Aster is one C++17 file with no external
dependencies; `python3` here uses only the standard library for the demo
(preview PNG included — zlib + struct, no Pillow).

Unpack the source and go in:

```sh
unzip aster-v0.23.7-dev.zip
cd aster-v0.22.38-dev
```

> **Run from the project root.** `@embed("demo_assets/icon48.bin")` resolves
> against the *source file's own directory* (C `#include` rules), so
> `examples/icon_text_demo.ast` finds `examples/demo_assets/` no matter where
> you invoke the compiler from — as long as the two travel together.

## 1. Where the source is

| Path | Bytes | What it is |
| --- | --- | --- |
| `examples/icon_text_demo.ast` | 10,701 | the whole app: the drawing, the font renderer, the Android glue |
| `examples/demo_assets/icon48.bin` | 9,216 | 48×48 RGBA icon, drawn by the app at run time |
| `examples/demo_assets/font8x8.bin` | 760 | 95 glyphs × 8 rows × 8 bits |
| `examples/demo_assets/title.txt` | 13 | `ASTER V0.23.7` |
| `examples/demo_assets/line2.txt` | 11 | `ICON + TEXT` |
| `examples/demo_assets/line3.txt` | 13 | `BOTH EMBEDDED` |
| `examples/demo_assets/icon48.png` | 1,001 | the same icon as a PNG, for looking at — **not** compiled in |
| `tests/icon-text-host.c` | 2,419 | the host that renders the frame with no Android present |
| `tests/icon-text-demo-checks.sh` | — | the [5/5] suite: build, embed, render, package, verify |

All of it is inside `aster-v0.23.7-dev.zip`.

## 2. Build the compiler

```sh
c++ -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o aster
```

On Termux `c++` is clang++. Strict and warning-free on **both** gcc and clang:
clang's `-Wunused-function` fires on an inline function that nothing calls, gcc's
does not, so the four `Ty` comparison operators that a given release happens not
to use are marked `[[maybe_unused]]` rather than deleted.

If a future clang version finds something else to complain about, drop `-Werror`
for a local build — the warnings are worth reading, but they are not the point:

```sh
c++ -std=c++17 -O2 src/aster.cpp -o aster
```

Proving it does not matter which compiler built Aster: `252/252` recorded outputs
are byte-identical between a gcc-built and a clang-built `aster`.

## 3. One command for the whole demo

```sh
termux-setup-storage          # only if you want the files in /sdcard
PREVIEW_OUT=~/storage/shared/icon-text-preview.png \
APK_OUT=~/storage/shared/icon-text-demo.apk \
    sh tests/icon-text-demo-checks.sh
```

Five layers, and it ends with `ALL ICON+TEXT DEMO CHECKS PASSED`:

1. **Strict build** of the compiler (the command in §2).
2. **`build-so`** — `examples/icon_text_demo.ast` → a 35,272-byte `ET_DYN`
   AArch64 object, checked to be ELF64/LE/ET_DYN.
3. **Byte-level asset check** — all five assets appear in the object **exactly
   once**. (The same path embedded twice is embedded once, so "exactly once" is
   the assertion, not "at least once".)
4. **Render** — `tests/icon-text-host.c` `dlopen`s the object and calls
   `render_rgba()` **on this device**, into a 360×640 buffer that was pre-filled
   with magenta. Any pixel Aster fails to draw stays magenta and is *counted*;
   the census is asserted (icon plate > 12,000 px, white title > 1,500 px, grey
   body > 1,500 px, magenta 0). On Termux this step runs natively — no qemu.
5. **Package** — `build-apk` from the `.ast` in one step, then `validate_apk.py`
   and `aster verify-apk` (v1 + v2), the five assets re-found inside
   `lib/arm64-v8a/libicontext.so`, and proof that the app name **is** in
   `AndroidManifest.xml` (see §5.1 for why that matters more than it sounds).

`PREVIEW_OUT` and `APK_OUT` are optional; without them the artifacts are deleted
with the scratch directory. With them you get a PNG to open and an APK to tap.

## 4. Just build the APK

```sh
./aster build-apk examples/icon_text_demo.ast -o icon-text-demo.apk \
    --package com.aster.icontext --libname icontext --abi arm64-v8a \
    --label "Aster 图标文字" \
    --string app_subtitle="ICON + TEXT" \
    --string greeting="Hello from resources.arsc" \
    --min-sdk 24 --target-sdk 34 --version-code 1 --version-name "1.0"
```

Two-step, if you want to keep the object for `readelf`/`objdump`:

```sh
./aster build-so examples/icon_text_demo.ast -o libicontext.so
./aster build-apk libicontext.so -o icon-text-demo.apk --package com.aster.icontext ...
```

or pass `--emit-so libicontext.so` to the one-step form.

## 5. Verify it

```sh
./aster verify-apk icon-text-demo.apk
#   aster: verify-apk: icon-text-demo.apk: OK (v1 + v2 signatures verified)

python3 tests/validate_apk.py icon-text-demo.apk \
    --package com.aster.icontext --libname icontext --label "Aster 图标文字"
#   === RESULT: ALL CHECKS PASSED ===
```

`validate_apk.py` is self-contained (stdlib only): ZIP structure and CRCs, the
binary AXML manifest, `resources.arsc` walked from scratch, the v1 JAR signature
and the v2 APK Signing Block.

To read the table back the way the framework will:

```sh
unzip -p icon-text-demo.apk resources.arsc | xxd | head -20
```

Four entries, 876 bytes: `0x7f010000 drawable/ic_launcher`,
`0x7f020000 string/app_name`, `0x7f020001 string/app_subtitle`,
`0x7f020002 string/greeting`.

### 5.1 Why the app name is spelled out in the manifest

`android:label` has two legal spellings and Aster writes the one that every
consumer can read:

| spelling | bytes | who can read it |
| --- | --- | --- |
| `TYPE_STRING` — the name spelled out **(default)** | `android:label="Aster 图标文字"` | everyone: the framework, the launcher, and any APK viewer |
| `TYPE_REFERENCE` — a pointer into `resources.arsc` (what aapt writes) | `android:label="@0x7f020000"` | the framework, and any viewer that opens the table |

The reference is the tidier of the two — the name lives in exactly one place —
but it is only a *promise to go open the table*. The framework does that on
install, so an installed app shows its name either way; a third-party APK viewer
that parses the binary manifest and stops there never opens it, and shows a
**blank name** for an app that is completely fine. That is the whole reason the
default is the literal.

`--label-as-reference` asks for the aapt spelling back:

```sh
./aster build-apk examples/icon_text_demo.ast -o icon-text-demo-ref.apk \
    --package com.aster.icontext --libname icontext \
    --label "Aster 图标文字" --label-as-reference
```

The table is byte-identical either way — `string/app_name` is still there and is
still what the framework reads — and `validate_apk.py` [4d] requires the two to
agree, so they cannot drift apart. Pin the check if you want to prove which one
you got:

```sh
python3 tests/validate_apk.py icon-text-demo.apk     --label "Aster 图标文字" --label-literal
python3 tests/validate_apk.py icon-text-demo-ref.apk --label "Aster 图标文字" --label-reference
```

## 6. Install and run

```sh
pkg install android-tools                       # for adb
adb install -r icon-text-demo.apk               # wireless debugging: adb pair first
adb shell am start -n com.aster.icontext/android.app.NativeActivity
```

Or without adb:

```sh
termux-setup-storage
cp icon-text-demo.apk ~/storage/shared/
```

then tap it in a file manager (Android will ask once about installing from an
unknown source — the APK is signed with a **debug** key generated on this
machine, which is exactly what a debug key means: fine for your own device,
never for release; use `--sign-mode release --keystore … --cert …` for that).

What you should see: a vertical gradient from near-black to indigo, the indigo
rounded-square icon with a white "A" centred in the upper half, and three lines
of text underneath. The launcher entry shows the same icon and the name
"Aster 图标文字" — the icon and the name come from `resources.arsc`, everything
on screen comes from `@embed`.

## 7. The rest of the suite

```sh
sh tests/smoke.sh          # 256 PASS / 0 FAIL, all suites
```

On Termux this runs everything **natively**: `HOSTCC` defaults to `cc` (clang,
which emits AArch64 ELF here), and `tests/run-aarch64.sh` executes AArch64
binaries directly instead of under qemu. Two suites want extra python packages —
`pip install androguard pillow` for `icon-checks.sh` and
`resource-table-checks.sh`; everything else is stdlib only.

## 8. If something goes wrong

| `SKIP: openssl is not on PATH` | Not a failure. The v1 signature was still verified — in-process, from the certificate inside `CERT.RSA`. Install `pkg install openssl` if you want a second opinion; the result is `ALL CHECKS PASSED` either way. (An older `validate_apk.py` reported `FAIL: openssl smime -verify failed` here, which was wrong: it was the tool that was missing, not a broken APK.) |
| --- | --- |
| `dlopen failed: libandroid.so` | The object lists `libandroid.so`/`liblog.so` in `DT_NEEDED`. The suite builds stubs and points `LD_LIBRARY_PATH` at them; if you call `render_rgba` yourself, do the same (see `tests/icon-text-demo-checks.sh` [4/5]). |
| `SKIP: … (cc cannot emit AArch64 ELF)` | `$HOSTCC` is not an AArch64 compiler. On Termux `cc` is, so this means `HOSTCC` was set to something else — leave it unset. |
| `cannot open demo_assets/…` | The compiler was invoked from somewhere other than the project root, or `demo_assets/` was not copied along with the `.ast`. `--embed-dir DIR` overrides the base if you want to lay it out differently. |
| App installs but the launcher shows a generic icon | The resource id did not resolve. `python3 tests/validate_apk.py …` will say which of `[4a]–[4d]` failed; in practice it is a table the manifest disagrees with. |
| An APK viewer shows a **blank app name**, but the installed app is fine | You are looking at the reference spelling. Rebuild without `--label-as-reference` (the default writes the name as a literal), or check with `--label-literal`. See §5.1. |
