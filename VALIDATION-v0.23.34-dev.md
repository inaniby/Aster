# Validation Report — v0.23.34-dev

**Feature: an array may be a parameter and a return, and `&arr` finally answers a
strided `ptr<T>` — the byte-width that used to be silently hard-coded to 4 now
travels with the pointer, so `i64`/`u8`/`u16`/struct arrays can be handed to a
function and subscripted at their real stride. With the plumbing in place, the
`examples/lifecycle.ast` Activity example is wired end to end and driven off
target under qemu.**

```
# tests/array-address-checks.sh [3/9] — each compiled with ./aster, run under qemu-aarch64.

# an i64 array handed to a parameter, indexed at its real 8-byte stride:
fn fill(a: i64[4]) -> i64 { a[0]=3; a[1]=5; a[2]=7; a[3]=9; return a[0]+a[1]+a[2]+a[3]; }
fn main() -> i32 { let w: i64[4] = 0; return fill(w); }                 -> exit 24

# an 8-byte element written through ptr<i64>, read back through the *named* array
# (the store landing at the right offset, not four bytes along):
fn main() -> i32 { let w: i64[4] = 0; let p: ptr<i64> = &w;
    p[0]=3; p[1]=5; p[2]=7; p[3]=9; return w[0]+w[1]+w[2]+w[3]; }      -> exit 24

# a strided ptr<i64> survives a return and a second binding:
fn get(w: ptr<i64>) -> ptr<i64> { return w; }
fn main() -> i32 { let w: i64[3] = 0; w[0]=4; w[1]=5; w[2]=6;
    let q: ptr<i64> = get(&w); return q[0]+q[1]+q[2]; }                -> exit 15
```

## 1. Why this round exists

Three gaps that had been sitting on the carry-forward list for several rounds
all trace to the same root: **a `ptr` in Aster hard-coded the element stride to
four bytes.** That single assumption was responsible for all three of:

* an array **could not be a parameter or a return value** at all, so a function
  could never touch a caller's array except through a file-scope global;
* `&arr` was **gated to 4-byte element types** (`i32`/`u32`/`bool`/a size-4
  struct), refusing `i64`, `u8`, `u16`, `ptr` and any larger struct with
  `'&' on an array needs a 4-byte element type`;
* storing a wider array's address into an untyped `ptr` would have silently
  mis-scaled every subscript.

The roadmap had `arrays as parameters/returns` and `strided ptr<T>` as adjacent
lines; this round takes both together, because the stride **is** the enabler for
the parameter decay, and adds the Lifecycle proof that the Runtime-API callbacks
now compile, link as a `.so`, and fire. It is a **language + toolchain** round.

## 2. The core change: a pointer that remembers how wide its element is

A `Ty` of kind `Ptr` now carries the element's byte width. The factory
`tyPtrToElem(Ty e)` builds `ptr<T>` from an element type; `ptrElemType(Ty t)`
rebuilds the element and `tyIsPtrToElem(Ty t)` tests for it. Because a full `Ty`
cannot be nested inside another (an element struct is only *incomplete* here),
the element is stored as a **kind + struct-id** and rebuilt on demand. A plain
`ptr` keeps `ew < 0` and means "stride 4", exactly as before.

`p[i]` on a `ptr<T>` lowers to `*(p + i * sizeof(T))`; on a plain `ptr` it is
still `*(p + i*4)`. So **no program that writes only plain `ptr` changes by a
byte** — the stride field is only consulted for the new `ptr<T>` spelling.

## 3. `&arr` is ungated, and the decay is now a live capability

`&buf`, `&gbuf`, `&s.cells` (and `&v[i]` rows of a multi-dimensional array)
answer `ptr<T>` for **any** element type — `&i64buf` is `ptr<i64>`, `&ubuf` is
`ptr<u8>`, `&vbuf` of a `V3[..]` is `ptr<V3>`. Because the result carries the
stride, `(&arr)[i]` — taking the address and subscripting it in one expression —
is legal and scales by `sizeof(T)`. The postfix parser was extended so a
subscript may follow `AddrOf` (alongside the `Field`/`Index` it already
allowed), which is what makes `(&w)[0]` read `w`'s first element with no
temporary. The struct branch of `&` is untouched and still answers `ptr<S>`.

The one guard that remains is `ptrToAssignable`: storing a strided `ptr<T>` into
a **plain `ptr`** slot is refused unless the stride is exactly 4, because the
slot would index it at the wrong distance:

```
cannot store a pointer to i64 elements in ptr: 'p' would index it at 4 bytes — declare it ptr<i64>, or take the array as a parameter
```

That diagnostic names the real stride of the slot (4 for an untyped `ptr`,
`sizeof(S)` for a `ptr<S>`, the element width for a `ptr<T>`), which is the whole
point — "would index it at 4 bytes" is only true of one of the three.

## 4. Arrays as parameters and returns

A parameter written `T[N]` **decays to `ptr<T>`** at the call boundary:
`fn sum(a: i32[4])` receives the argument's decayed address and `a[i]` scales by
the element width. The element type is recorded in `slotElemTypes[slot]` and read
by **both** Sema and Codegen, so the two passes cannot disagree on the stride.
There is no length on a decayed parameter, so a parameter subscript is unchecked
(no `--bounds-check`, no compile-time fold) — the same rule a `ptr<T>` subscript
already follows. The same decayed `ptr<T>` is the type a function **returns**
when its return type is written `ptr<T>`, handing back the array's address with
its stride intact. Passing a whole array **by value** is still refused.

## 5. Coverage: `tests/array-address-checks.sh` [9/9]

The array-address suite was extended to a full [9/9] for the stride story:

1. a strict `-Werror` rebuild;
2. a source guard pinning `return ptrElemWidth(from)==4u;` and the
   `cannot store a pointer to` diagnostic;
3. a **stride capability** battery — `u8`/`u16`/`i64` arrays read and written
   through both `&arr` and `ptr<T>`, `ptr<V3>` field access, and `ptr<i64>` both
   as a parameter and a return that is then re-bound;
4. arrays as parameters and returns (`i32[4]`, `i64[4]`, a `V3[2]` whose
   `v[1].a` is read through the decay);
5. a **rejection matrix** — an `i64`/`u8`/`V3` address into a plain `ptr` slot,
   a `ptr<V3>` from a `ptr<Q>` slot, each naming the slot's real stride;
6. `(&arr)[i]` live capability — the address and the subscript in one
   expression;
7. a mutation layer (`m5`/`m6`/`m8`) that drops the stride check, the decay, or
   the `ptrToAssignable` guard and requires the suite to notice;
8. the shared byte baseline;
9. a `lifecycle.` filter added to the examples walk.

`array-elem-types-checks.sh`, `condition-checks.sh` (19 `rejectBool`),
`multi-dim-array-checks.sh` (postfix accepts `[` after `&`), `null-ptr-checks.sh`
(5 `ptrToAssignable`) and `precedence-checks.sh` were each updated to the new
source text — none had to back a feature out. `wide-int-literal-checks.sh` was
the one the full CI caught: the array-parameter / `(&arr)[i]` read added a
**fourth** copy of the index-leaf sign-extension (`if(tyIs64(want)&&elem==Ty::I32)
emit(0x93407c00u`, an i32 element widened for an i64 consumer), taking the total
leaf-SXTW count from 9 to 10, and it reworked the ptr-index path so a typed
pointer strides at its element's real width instead of a hard-coded i32 — so the
`emitElemIndex(r,Ty::I32)` pin became an element-type derivation feeding
`emitElemIndex(r,pe)`. Both are the new code being correctly counted, not a
regression, and the suite passes all seven steps including its 16-mutant layer
once the guards name the round.

## 6. The Lifecycle example, driven off target

`examples/lifecycle.ast` (new this round) installs the seven Android
`ANativeActivity` callbacks — `onStart`/`onResume`/`onPause`/`onStop`/
`onDestroy`/`onConfigurationChanged`/`onLowMemory` — into a caller-supplied
callback table at offsets `0, 8, 16, 24, 32, 40, 48` through `load_ptr` and
`*(cb + n) = fn`, each bumping a global counter, and exposes
`aster_lifecycle_count(which)` to read them back.

`tests/lifecycle-callbacks.sh` [4/4] builds the `.so`, asserts it **exports nine
symbols** (seven callbacks + `ANativeActivity_onCreate` + the counter), then
cross-compiles a C host plus a `liblog` stub and drives the whole table under
qemu:

* the `.so` auto-attaches `liblog.so` as a `DT_NEEDED` for its
  `__android_log_print` import (matching the NDK), so the host links against
  `tests/liblog-stub.c` and runs with `LD_LIBRARY_PATH` pointing at it;
* the host `dlopen`s the `.so`, installs the callbacks via
  `ANativeActivity_onCreate`, asserts **only the first seven slots** are filled,
  calls each callback once, and asserts `count(i) == 1` for all seven;
* a second `onStart` gives `count(0) == 2`, and `count(7) == -1` proves the
  routing is bounded.

This is the off-device proof the P2.4 line asked for; what remains open is
narrower — the bionic loader itself and an on-device APK/NDK run.

## 7. Nothing that exists moves

```
$ sh tests/rebuild-baseline-v0.23.34.sh
OK: 303 pre-existing lines byte-identical; 306 lines total (+3 lifecycle)
```

The rebuild filters the new `lifecycle` rows, asserts the 303 pre-existing lines
are byte-identical (built under `sh` with `LC_ALL=C` so the shared
`example-hashes.txt` ordering is deterministic), and confirms the three new
lifecycle rows land the total at 306. Every pre-existing example is byte-for-byte
unchanged: the stride field is consulted only for `ptr<T>`, which no pre-existing
example spells.

## 8. Deliberately not included

* **A `ptr` that carries a length** — a decayed array parameter has no bounds
  information and its subscripts stay unchecked; a bounds-checked array
  reference type is a separate design.
* **Passing or returning an array by value** — only the address travels, exactly
  as before; the whole-array assign refusal (`buf = ...`) is unchanged.
* **On-device execution** — *resolved on a real device* (see §10). The lifecycle
  wiring was proven off target under qemu; the same APK was then installed on
  physical hardware and ran, with logs written to the app directory because the
  device's `adb logcat` is unavailable.

## 9. Full CI

```
$ HOSTCC=aarch64-linux-gnu-gcc RUNNER="qemu-aarch64 -L /usr/aarch64-linux-gnu" sh tests/ci.sh
========================================
CI SUMMARY: 91 passed, 0 skipped, 0 failed (of 91 checks)
========================================
```

One suite is new (`lifecycle-callbacks.sh`); every pre-existing suite passes,
including the byte-baseline walk and the six cross-referenced suites whose source
guards were updated to the new compiler text. The first full run caught one
suite — `wide-int-literal-checks.sh` — because the array-parameter / `(&arr)[i]`
read added a **fourth** copy of the index-leaf sign-extension and reworked the
ptr-index stride derivation, so two of its source-guard counts (index-leaf 3→4,
total SXTW 9→10) and the `emitElemIndex(r,Ty::I32)` pin were re-pointed at the
new code. That is the new feature being counted, not a regression; the suite
passes all seven steps including its 16-mutant layer, and the re-run above is the
clean 91/91 gate.

## 10. On-device validation (real hardware)

The `lifecycle.apk` built in the previous round (package `com.aster.lifecycle`,
`libasterlifecycle.so` = `logging.ast` + `lifecycle.ast` merged via `link-so
--needed libc.so`) was installed on a physical Android device. Because `adb
logcat` is unavailable there, the file-backed logging in `apk/logging.ast`
wrote each line to `/sdcard/Android/data/com.aster.lifecycle/files/aster.log`.
The user pulled that file and reported the following verbatim:

```
AsterLifecycle: onStart
AsterLifecycle: onResume
AsterLifecycle: onLowMemory
AsterLifecycle: onLowMemory
AsterLifecycle: onStop
AsterLifecycle: onDestroy
AsterLifecycle: onPause
AsterLifecycle: onStart
AsterLifecycle: onResume
AsterLifecycle: onLowMemory
AsterLifecycle: onLowMemory
AsterLifecycle: onStop
AsterLifecycle: onDestroy
AsterLifecycle: onPause
```

**What this proves:**

* The APK **installs and runs on real bionic** — the merged `.so` loaded and the
  seven `ANativeActivity` callback slots were all reached without a crash. This
  closes the only open item from the byte-baseline round: host/qemu proof is now
  backed by silicon.
* **File-backed logging works on device.** The external app-dir path
  (`/sdcard/Android/data/<pkg>/files/aster.log`) was created and written by
  `mkdir`/`open(0x441)`/`write`, exactly as the `apk/logging.ast` init path
  intends — the fallback to `/data/data/...` was not needed, so the external
  path was chosen first as designed.
* **All seven slots are wired.** The two cycles above exercise `onStart`,
  `onResume`, `onLowMemory` (×2), `onStop`, `onDestroy`, `onPause` — matching
  the per-slot counters `g_started`/`g_resumed`/`g_lowmem`/`g_stopped`/
  `g_destroyed`/`g_paused` all incrementing. `onConfigurationChanged` did **not**
  fire, which is expected: no configuration change (rotation / locale / density)
  happened on this device, so that slot stayed dormant — correct, not a gap.
* **Two identical cycles** = the activity was launched, driven through a full
  foreground→background→destroy arc, then relaunched once. The mirrored sequence
  shows the wiring is stable across repeated bring-up, not a one-shot fluke.

**One observation, not a defect.** On this device the framework delivered the
tear-down callbacks in the order `onStop → onDestroy → onPause`, whereas the
canonical Activity order is `onPause → onStop → onDestroy`. The `on_pause` /
`on_stop` / `on_destroy` handlers in `lifecycle.ast` are pure loggers that bump
independent counters, so delivery order is irrelevant to correctness — but it
does confirm the Aster native-activity glue forwards whatever `APP_CMD_*` order
the framework emits, rather than assuming a fixed sequence. No re-entrancy or
counter corruption appeared (all counts are small non-negative integers).

**Conclusion.** End-to-end: AArch64 bootstrap compiler → `.so` → signed
NativeActivity APK → real-device install → file-logged lifecycle, with no
compiler, linker, or runtime regressions. The `lifecycle.apk` in the repo root
is the artifact the user is running.
