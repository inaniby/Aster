# Validation — v0.23.59-dev (`link-so` honors `--page-size`)

**Compiler:** `src/aster.cpp` (`ASTER_VERSION_STRING "0.23.59-dev"`), built
`g++ -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror`.

**Round type:** linker bug fix (no language change). One-line pass-through in the
`link-so` dispatch; `linkSharedObjects` already accepted the `pageSize` argument.

---

## 1. The bug (auditor-flagged P0)

Aster supports an Android 16 KB page-size flag, `--page-size 4096|16384`, on the
ELF/image production verbs. Android 15+ devices (targetSdk >= 35) **reject** any
app whose `PT_LOAD` segments are not aligned to `0x4000`. The flag was verified
on `build-elf` / `build-pie` / `build-so` / `link-obj` / `link-pie` / `build-apk`,
but `link-so` was never in that set.

Root cause, `src/aster.cpp` (dispatch):

```cpp
// before v0.23.59-dev
if(cmd=="link-so"){
    if(!parseArgs(2)||sources.empty()||pic||boundsCheck){std::cerr<<kUsage;return 2;}
    linkSharedObjects(sources,output,soname,needed);   // pageSize NOT passed
    return 0;
}
```

`linkSharedObjects` has signature
`(inputs, output, sonameIn, needed, uint64_t pageSize=4096)` — so omitting the
argument silently fell back to `4096`. The flag was a **silent no-op** for
`link-so`: every shared object it produced was 4 KB-aligned regardless of
`--page-size 16384`.

### Empirical confirmation (before the fix)

Compiling the same PIC object two ways:

```
$ aster link-so lib.o                 -o lib_default.so
$ aster link-so --page-size 16384 lib.o -o lib_16k.so
$ readelf -lW lib_default.so | grep LOAD
  LOAD  0x000000 0x0 0x0 0x001180 0x001180 R E 0x1000
  LOAD  0x002000 0x2000 0x2000 0x001000 0x001000 RW  0x1000
$ readelf -lW lib_16k.so | grep LOAD            # identical — flag was ignored
  LOAD  0x000000 0x0 0x0 0x001180 0x001180 R E 0x1000
  LOAD  0x002000 0x2000 0x2000 0x001000 0x001000 RW  0x1000
```

Both emit `Align 0x1000`. The 16 KB request changed nothing — exactly the defect
the audit predicted.

## 2. The fix

One line: pass `pageSize` through.

```cpp
// v0.23.59-dev
if(cmd=="link-so"){
    if(!parseArgs(2)||sources.empty()||pic||boundsCheck){std::cerr<<kUsage;return 2;}
    linkSharedObjects(sources,output,soname,needed,pageSize);
    return 0;
}
```

`link-obj`/`link-pie` already pass `pageSize` correctly (line ~12288), so the
shared-object path was the only gap. No writer internals changed — the parameter
was already threaded to the segment layout.

## 3. Verification (after the fix)

```
$ aster link-so lib.o                 -o lib_default.so
$ aster link-so --page-size 16384 lib.o -o lib_16k.so
$ readelf -lW lib_default.so | grep LOAD
  LOAD  0x000000 0x0 0x0 0x001180 0x001180 R E 0x1000
  LOAD  0x002000 0x2000 0x2000 0x001000 0x001000 RW  0x1000
$ readelf -lW lib_16k.so | grep LOAD
  LOAD  0x000000 0x0 0x0 0x004180 0x004180 R E 0x4000
  LOAD  0x008000 0x8000 0x8000 0x004000 0x004000 RW  0x4000
```

- default → every `PT_LOAD` `Align 0x1000` (unchanged from before).
- `--page-size 16384` → every `PT_LOAD` `Align 0x4000`, and `p_vaddr`/`p_offset`
  sit on `0x4000` boundaries (the second `LOAD` starts at `0x8000`, not `0x2000`).
  The segment sizes also pad up to the larger page, confirming the value reaches
  the writer rather than being dropped.

This matches the contract the other verbs already satisfy.

## 4. Test additions

`tests/page-size-checks.sh` — the regression guard for 16 KB support — gained
`link-so` in its command matrix (the `CMDS` list at `[4/6]`). The harness already
builds a PIC object (`build-obj --pic`) and passes it to the `link-*` verbs; the
new row reuses that PIC object. The embedded Python ELF reader asserts, for every
produced image:

```python
CMDS = [
    ("build-elf", ["build-elf"], "source.ast"),
    ("build-pie", ["build-pie"], "source.ast"),
    ("build-so",  ["build-so"],  "source.ast"),
    ("link-obj",  ["link-obj",  source.o],      None),
    ("link-pie",  ["link-pie",  source.o],      None),
    ("link-so",   ["link-so",   source-pic.o],  None),   # new in v0.23.59-dev
]
# default  -> every PT_LOAD Align 0x1000
# 16384    -> every PT_LOAD Align 0x4000, vaddr/offset congruent mod 0x4000
```

`check_alignment` fails the suite if any `PT_LOAD` of `link-so-16k` is not
`0x4000`-aligned — so the original silent-no-op can never sneak back.

Suite result (after the fix):

```
PASS: default link-so-4k — 3 PT_LOAD segment(s) all Align 0x1000, vaddr/offset aligned
PASS: page-size=16384 link-so-16k — 3 PT_LOAD segment(s) all Align 0x4000, vaddr/offset aligned
...
=== page-size checks: ALL PASSED ===
```

## 5. What was NOT changed

- The default path is byte-stable: with no `--page-size` flag the emitted
  `link-so` object is identical to before (the only edit is which default
  `pageSize` reaches the writer). `page-size-checks.sh` still asserts the 4 KB and
  16 KB `build-elf` images **differ**, so a silent no-op on any verb still trips.
- No codegen change: the `ADRP` encoding is 4 KB-granular and 16 KB is a superset,
  so the relocated image remains loadable. That property is unchanged.
- No language feature added or removed; this round is purely a linker correctness
  fix for Android 16 KB page compliance.

## 6. Audit-response mapping

| Audit item | Finding | v0.23.59-dev action |
| --- | --- | --- |
| P0 | `link-so` may not pass `--page-size` | Confirmed and fixed (one-line pass-through); verified 4 KB/16 KB `PT_LOAD` alignment directly |
| P1 | `link-so` not in page-size test matrix | Added `link-so` to `page-size-checks.sh` `CMDS`; both page sizes now asserted |
| §2.3 (Android 16 KB) | shared object must meet 16 KB alignment | `link-so` now emits `0x4000`-aligned `PT_LOAD` under `--page-size 16384` |

The audit's other items (struct-parameter ABI under the UI prototype, UI toolchain
lag, Android on-device diagnostics) are test-coverage / engineering-chain gaps,
not compiler defects confirmed here, and are tracked separately.
