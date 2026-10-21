# Validation — v0.23.14-dev

**Touch input: an Aster-built app answers a finger (P2.3).**

> **Corrigendum (v0.23.15-dev).** This release's feature did not work on a
> real device: the user installed the APK, saw the gradient, and got no
> response to any touch. Three of the claims below were wrong. (1) The
> input-queue slots are **not** at 80/88 — 80 is `onNativeWindowDestroyed`;
> the correct set is window 56/64/72, `onNativeWindowDestroyed` at 80, input
> queue 88/96. (2) The drain condition is `got >= 0`, not "until the queue is
> empty" as the loop's `got == 1` actually implemented — `AInputQueue_getEvent`
> returns **0** on success. (3) `s0` does **not** alias the low 32 bits of
> `w0` — they are different physical register files, so the capture read
> garbage. Additionally, the touch overlay's pixel-format test was inverted.
> The qemu test was green throughout because it fed the decoder hand-written
> bit patterns and never executed the capture path — it tested the half that
> was not broken. The corrected release is v0.23.15-dev; see
> `VALIDATION-v0.23.15-dev.md`. The text below is kept as written, because
> that is what was believed and shipped.

The question that started this release: *can an Aster program respond to input?*
Until now, no. `native_render.ast` draws a gradient — later an icon and text —
into an `ANativeWindow`, but it is **display-only**: the
`ANativeActivityCallbacks` slots it wires are the window ones at offsets
56/64/72, and the input-queue slots right behind them were never filled, so a
tap on the screen did nothing at all. `examples/native_touch.ast` fills the two
remaining slots, attaches the `AInputQueue` to Android's main looper, and
repaints a 40×40 white dot at the finger on every motion event.

---

## What is asserted, and by whom

`tests/touch-checks.sh` (4 layers, registered in `ci.sh`; `native_touch` also
joins the APK verification gate). The assertion that matters is not "the APK
builds" — the feature's risky half is the coordinate conversion, and because it
is integer-only it is executable here, with no Android present:

> `motion_coord`, given the raw IEEE-754 bits that `AMotionEvent_getX`/`getY`
> deliver, must decode `0.0` / `1042.0` / `768.0` / `3000.0` / `123.0` /
> `1042.5` to `0` / `1042` / `768` / `3000` / `123` / `1042` — under qemu.

## The four layers

| # | Layer |
| --- | --- |
| 1 | **The decode, under qemu** — `tests/touch-coord-test.ast` builds with `build-elf` and runs via `tests/run-aarch64.sh`; six known bit patterns, exit 0 only when all six decode correctly (each mismatch has its own exit code) |
| 2 | **Source guards** — the three externs (`AInputQueue_attachLooper`, `AMotionEvent_getX`, `ALooper_forThread`), the 80/88 wiring and the looper attach are all still in `examples/native_touch.ast` |
| 3 | **The APK gate** — the one-step `.ast` → `build-apk` path, then `validate_apk.py` and `aster verify-apk`, and `readelf -d` on the emitted `.so` requires `libandroid.so` in `DT_NEEDED` (the NDK symbol auto-map, asserted rather than assumed) |
| 4 | **The suite can still fail** — a mutation that shifts the decode by one (`150 - exp` → `151 - exp`) must make the qemu test exit non-zero |

Layer 4 is what makes the green run mean something: a decode test that cannot
fail is not evidence. The mutation is anchored — the suite asserts its anchor
appears exactly once before editing — so a refactor cannot silently disarm it.

## Why no compiler change was needed

This release touches only the version string in `src/aster.cpp`. That is a
statement about what was already in the toolchain:

- **The `w0` return path.** An `extern fn … -> i32` return is read with
  `MOV Wd, W0`. The NDK's `float` comes back in `s0`, whose low 32 bits alias
  `w0` — so declaring `AMotionEvent_getX`/`getY` as `-> i32` captures the raw
  IEEE-754 bit pattern with no new codegen.
- **The NDK symbol map.** `AInputQueue_*`, `AMotionEvent_*` and `ALooper_*`
  already route to `libandroid.so`, so the `.so` needs no manual `--needed` —
  and layer 3 asserts the resulting `DT_NEEDED` instead of trusting it.
- **The callback offsets.** The window slots at 56/64/72 are device-verified;
  the callbacks struct is a plain array of function pointers in declaration
  order, so the input-queue slots follow at 80/88 by the same +8 cadence. The
  example spells every offset out with its authority, the way `native_render`
  does.

The decode itself (`motion_coord`) is division arithmetic: sign and exponent
from the top bits, the mantissa scaled by a `v = v / 2` loop — no shift
operator exists — with the all-zero pattern special-cased rather than divided
by 2¹²⁷.

## Byte-level invariance

| Comparison | Result |
| --- | --- |
| `tests/struct-checks.sh` [4/8] | **261 recorded outputs reproduced byte for byte** — the baseline grew by exactly the three `native_touch` modes (`build-so`, `build-elf` FAILED, `build-obj --pic`); no pre-existing line moved |
| Byte-level A/B vs v0.23.13-dev | **212/212** byte-identical (40/40 `build-elf`, 86/86 `build-obj`, 86/86 `build-so`), 0 differing |

`native_touch.build-elf` is `FAILED` on both sides: the executable links
against `libandroid.so`, which exists on a device and not on this host — the
same reason `native_render.build-elf` has always been `FAILED`.

## The one boundary that stays open

Everything provable off-device is proven here: the decode, the wiring, the
signing, the linking, the packaging. The *visible* dot under a real finger is
observable only on an arm64 device — exactly the boundary `native_render.ast`
ships under. The example documents the install-and-tap procedure for when a
device is at hand.

## Release gate

| Stage | Result |
| --- | --- |
| Strict build (`-Werror`) | zero warnings, `BUILD OK` |
| `tests/touch-checks.sh` | PASS (4/4) |
| `tests/struct-checks.sh` | PASS — 261 recorded outputs reproduced byte for byte |
| `tests/version-checks.sh` | PASS (6/6) |
| Injected mutation (one-step decode shift) | caught (qemu exit 2) |
| Byte-level A/B vs v0.23.13-dev | **212/212** byte-identical, 0 differing |
| `tests/ci.sh` (full gate) | **49 passed, 23 skipped, 0 failed** (of 72 checks), exit 0 |
| Exit status | 0 |

The gate total rises from 47 to **49** passed because `touch-checks.sh` and the
`native_touch` APK gate join it; every suite that passed in v0.23.13-dev still
passes. The 23 skips are the e2e C-ABI suites, which self-skip on the x86_64
sandbox by design and run for real on an AArch64 runner. All three APK gates
(`native_render`, `icon_text_demo`, `native_touch`) are green, each verified
two independent ways.
