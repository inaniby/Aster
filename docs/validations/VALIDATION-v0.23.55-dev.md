# Validation — v0.23.55-dev

## Android 16 KB-page support, completed: the `.so` ZIP-entry alignment

v0.23.54-dev shipped `--page-size` and threaded it through every ELF writer, so
the *load segments* became 16 KB-aligned. But Android does not only require the
`PT_LOAD` alignment — it **mmaps the shared object straight out of the APK**, so
the `.so`'s data offset *inside the ZIP* must also be congruent to the device
page size. v0.23.54-dev still emitted the `.so` entry at a hard-coded 4 KB
boundary inside the archive, which a 16 KB-page device cannot mmap directly.

v0.23.55-dev closes that gap.

### What changed (source)

- `buildApk()` gains a `uint64_t pageSize = 4096` parameter.
- The ZIP `append()` lambda that pads the shared-object entry now rounds the
  `.so` data offset up to `pageSize` instead of a hard-coded `4096`. The default
  `4096` reproduces the historical byte-for-byte APK layout (verified below), so
  the existing `apk-checks.sh` baseline is unaffected.
- `main()`'s `build-apk` path forwards the parsed `--page-size` into `buildApk()`.
- `validate_apk.py` gains `--page-size 4096|16384` and asserts every `lib/*.so`
  entry's data offset is congruent to that page size. The default 4096 keeps the
  existing APK validation contract; 16384 is the 16 KB-page requirement.

### Why the default is byte-identical

The only thing that moves with `pageSize` is the padding between the preceding
ZIP entry and the `.so` local header. With `pageSize == 4096` the padding
formula reduces exactly to what v0.23.54-dev (and all prior versions) computed,
so the APK's bytes — including the embedded `.so` and its signature — are
unchanged. The `apk-checks.sh` reproducibility check and the 348-row ELF
baseline remain green.

### The 16 KB contract (what bionic requires)

For a `targetSdk >= 35` app on a 16 KB-page device, the dynamic linker needs:

1. every `PT_LOAD` with `p_align == 0x4000` and `p_vaddr ≡ p_offset (mod 0x4000)`
   — handled by v0.23.54-dev; and
2. the `.so`'s data offset inside the APK `≡ 0 (mod 0x4000)` — **handled by this
   release**.

Both are now verified end-to-end by `tests/page-size-checks.sh` `[6/6]`.

### Evidence

```
$ aster build-apk --page-size 16384 examples/native_activity.ast -o a.apk --emit-so a.so ...
$ readelf -lW a.so | grep LOAD
  LOAD  0x000000 0x0 0x0  ... R E 0x4000
  LOAD  0x008000 0x8000 0x8000 ... R   0x4000
  LOAD  0x00c000 0xc000 0xc000 ... RW  0x4000
$ python3 -c 'parse zip local header for lib/arm64-v8a/libnat.so'
  .so data offset = 16384   (16384 % 16384 == 0)   <- mmap-able on 16 KB devices

$ aster build-apk --page-size 4096 examples/native_activity.ast -o a4.apk ...
$ python3 -c '...'
  .so data offset = 12288   (12288 % 4096 == 0, 12288 % 16384 != 0)   <- unchanged default
```

### Test design

`tests/page-size-checks.sh` `[6/6]` builds an APK from a real NativeActivity
source (`.ast -> build-apk`, exercising the internal `build-so` compile with the
chosen page size) at both page sizes and asserts, for each:

- the embedded `.so`'s `PT_LOAD` segments carry `Align 0x1000` (default) or
  `0x4000` (16384);
- the `.so`'s ZIP data offset is `0 (mod 4096)` / `0 (mod 16384)` respectively;
- the 4 KB and 16 KB APKs are **not** byte-identical (the flag is never a silent
  no-op — the exact bug class that bit the `linkObjects` writeElfBytes call in
  v0.23.54-dev);
- the project's own `validate_apk.py` accepts each APK at its respective
  `--page-size`, as an independent cross-check (and would *reject* the 4 KB APK
  if asked to validate at 16384).

### Regression fence

`[4/6]` and `[5/6]` (from v0.23.54-dev) still lock the ELF-segment contract and
the qemu-executability of 16 KB images. The new `[6/6]` adds the APK/ZIP layer.
Together they make a silent 4 KB shift — or a 16 KB value leaking into the
default path — fail the suite.

### CI

`LC_ALL=C CXX=g++ HOSTCC=aarch64-linux-gnu-gcc bash tests/ci.sh` — includes the
extended `page-size-checks.sh` and the unchanged `apk-checks.sh`
(reproducibility + validation, all at the default 4096). Zero failures.
