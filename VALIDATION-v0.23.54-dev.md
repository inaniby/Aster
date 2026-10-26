# Validation Report — v0.23.54-dev

**Feature: Android 15+ 16 KB-page support via a new `--page-size` flag.** Aster's
three ELF writers (`writeElfBytes`, `writeSharedObject`, `writeSharedObjectDyn`)
hard-coded `0x1000` (4 KB) for every loadable segment's alignment, offset and
virtual address. That is exactly what Android 15+ rejects: an app with
`targetSdk >= 35` on a 16 KB-page device must have every `PT_LOAD` at
`p_align >= 0x4000` with `p_vaddr`/`p_offset` congruent mod that align, or the
dynamic linker refuses to load it. The new flag — `--page-size 4096|16384`,
default **4096** — threads a single `pageSize` parameter through the three
writers, the two linkers and `build-so`, so Android builds pass `16384` and
**every existing Linux output is byte-for-byte unchanged** (the default path is
the historical 4 KB layout). The full CI is green with zero baseline drift.

```
// the round in one shape — one parameter, three writers, zero codegen change:
//   --page-size 4096   default; identical to the pre-16KB binary (baseline 0 drift)
//   --page-size 16384  every PT_LOAD: p_align 0x4000, p_vaddr/p_offset % 0x4000 == 0
//   ADRP relocations   unchanged: &~0xfff / >>12 are 4 KB-granular, 16 KB is a superset
// the bug the round caught: writeElfBytes() was called without forwarding pageSize,
//   which would have made 16384 a silent no-op (or a latent layout/relocation mismatch).
```

## 1. Why this round exists

A user building an Aster app for Android 15+ reported that both `PT_LOAD`
segments carried `Align 0x1000`, and that a `targetSdk`-bumped app needs
`0x4000`. The complaint is precise and the requirement is real: Android 15
(formally, the rule gated on `targetSdk >= 35`) ships devices whose kernel page
size is 16 KB, and the bionic dynamic linker rejects any ELF whose load segments
are not aligned to the device page size. A 4 KB `p_align` is not *wrong* on a 4
KB device, but it is *rejected* on a 16 KB one — and Aster had no way to emit
anything else.

The obvious fix — bump the constant to `0x4000` — was rejected deliberately:
Aster's Linux output is pinned by a 348-row byte baseline, and the project's
discipline is that an unrelated platform's requirement must not move a single
byte of the default path. So the change is a **parameter**, not a constant: the
historical `0x1000` becomes `pageSize` with `4096` as the default, and the only
callers that ask for `16384` are Android builds.

## 2. What shipped

**One parameter through the whole emit chain.** `pageSize` is threaded from
`parseArgs` (and the `build-apk` inline loop) into `linkObjects`,
`linkSharedObjects`, `buildSoFromSource`, and the three writers:
`writeElfBytes`, `writeSharedObject`, `writeSharedObjectDyn`. Every layout-level
`0x1000` — the text file offset, each `alignUp(..., 0x1000)` for rodata/data/
eh_frame, and every `Phdr::align` — is now `pageSize`. The segment
vaddr/offset arithmetic is unchanged in form; only the granularity varies, so a
`4096` argument reproduces the previous bytes exactly.

**`kSharedTextVaddr` is gone.** The shared-object `.text` base was a dead
`static constexpr uint64_t kSharedTextVaddr = 0x1000;` — a hard-coded 4 KB
constant that the page-size parameter supersedes. It had no other reference, so
removing it is pure dead-code deletion; the two `.so` writers now compute
`textVaddr`/`textOff` from `pageSize`.

**`--page-size` is validated, not trusted.** Both parsers reject anything that
is not `4096` or `16384` (the only two page sizes Android ships) with a clear
message, and `linkObjects`/`writeElfBytes` re-assert `pageSize` at the boundary
("internal error: unsupported page size …"). The `@align(N)` attribute ceiling
was raised from `4096` to `16384` so a user can still request 16 KB section
alignment without tripping the rejection.

**No code-generation change.** The one place relocation math touches the page
granularity is the `ADRP` encoding, which uses `&~uint64_t(0xfff)` and `>> 12`
— a 4 KB scale. 16 KB is a *superset* of 4 KB: every 16 KB-aligned address is
also 4 KB-aligned, so `ADRP` resolves correctly with no edit, and the page size
is purely a layout concern. This is asserted, not assumed (§3).

## 3. The evidence chain

**The three writers share one invariant, checked by a structural reader.** A
Python ELF reader in `tests/page-size-checks.sh` walks every `PT_LOAD` of every
produced image and requires `p_align` and `p_vaddr % p_align == 0` and
`p_offset % p_align == 0`. Under the default it requires `0x1000`; under
`--page-size 16384` it requires `0x4000` — on `build-elf`, `build-pie`,
`build-so`, `link-obj` and `link-pie`, each of which emits three or more
`PT_LOAD` segments (text, rodata, data, and for the `.so` writers the
RELRO/eh_frame loads). A `16 KB` image whose alignment were still `0x1000` —
the exact shape of the bug below — fails this check, so the guard is what makes
the feature real rather than cosmetic.

**The ADRP claim is proven by the byte baseline.** The 348-row example baseline
reproduces byte-for-byte under the default (`4096`) page size (§6). If the 16 KB
work had touched relocation encoding, *every* example with an `ADRP` would have
moved; nothing moved, which is the proof that code generation is untouched.

**The fix's own regression is the strongest guard.** The suite asserts the
`16384` image is **not byte-identical** to the default. That single assertion
would have failed against the first draft of this round — see §4.

## 4. The bug the round caught — a silently-ignored page size

The first working draft threaded `pageSize` through `linkObjects`' own layout
(the text vaddr, the rodata/data offsets) but **forgot to forward it to the
`writeElfBytes` call at the end of `linkObjects`**. `writeElfBytes` therefore
always ran at its `4096` default, while `linkObjects` had computed symbol
addresses against `16384`. For a trivial program with no rodata/data and no
relocations the two layouts happened to coincide, so a naive check passed — but
any program with a data/rodata segment or a relocation would have had its text
laid out at a different address than its symbols and entry point expected, and a
`16 KB` build would have been byte-identical to `4 KB` (a silent no-op that
still fails Android's check). The missing forward is restored; the
"not byte-identical under 16384" assertion in the suite exists specifically to
keep that bug dead.

## 5. What the suites prove

**New: `tests/page-size-checks.sh`** — registered in `ci.sh`. Five sections:

1. a strict `-Werror` rebuild (the CI contract);
2. **source guards** — `kSharedTextVaddr` is gone and no bare `0x1000` literal
   remains in `src/aster.cpp`, so a future edit cannot quietly re-introduce a
   fixed page size;
3. **alignment contract** — default keeps `Align 0x1000` and `16384` switches
   every `PT_LOAD` to `Align 0x4000` with `p_vaddr`/`p_offset` `0x4000`-aligned,
   across all five emit commands, plus the "the two images differ" assertion;
4. **executability** — the `16384` `build-elf` and `build-pie` run under
   `qemu-aarch64` and exit the expected code (a 16 KB image that laid out wrong
   would fault, not return), and the default image still runs;
5. the source guards are re-stated as the closing fence.

The corpus deliberately carries a global (data segment) and a string literal
(rodata segment), so the alignment check fires on every segment kind, not just
`.text`.

**Everything resident stays green.** The full `106`-suite CI: zero failures, zero
skips on a host with the cross toolchain, and the byte baseline asserts zero
drift before this report is written.

## 6. Baseline: not one byte moved (default path)

348 of 348 rows byte-identical under the default page size. This is the expected
result and it is asserted, not assumed: the eight suites that read
`tests/baseline/v0.23.5-dev/example-hashes.txt` re-derive every row they cover
from the freshly built compiler. A change that moved a byte of the default path
would fail there before it reached this report. The `16384` path is *not* in the
baseline — it is new output, covered by `tests/page-size-checks.sh` instead.

## 7. Reproduction

```sh
# 0) the strict build (zero warnings, as always)
g++ -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp -o aster

# 1) the default path is the historical 4 KB layout (every PT_LOAD Align 0x1000)
./aster build-elf examples/hello.ast -o /tmp/elf-4k.elf
readelf -lW /tmp/elf-4k.elf | grep -A1 LOAD        # Align 0x1000

# 2) the Android 16 KB path (every PT_LOAD Align 0x4000, vaddr/offset aligned)
./aster build-elf --page-size 16384 examples/hello.ast -o /tmp/elf-16k.elf
readelf -lW /tmp/elf-16k.elf | grep -A1 LOAD       # Align 0x4000
qemu-aarch64 -L /usr/aarch64-linux-gnu /tmp/elf-16k.elf; echo $?   # runs

# 3) the new regression suite (the alignment contract + the "not a no-op" guard)
sh tests/page-size-checks.sh

# 4) the full CI
LC_ALL=C CXX=g++ HOSTCC=aarch64-linux-gnu-gcc sh tests/ci.sh
```

## 8. Files

- `src/aster.cpp` — `0.23.54-dev`; the three ELF writers
  (`writeElfBytes`, `writeSharedObject`, `writeSharedObjectDyn`), `linkObjects`,
  `linkSharedObjects` and `buildSoFromSource` take a `pageSize` (default `4096`);
  every layout-level `0x1000` is now `pageSize`; dead `kSharedTextVaddr` removed;
  `parseArgs` and the `build-apk` loop accept and validate `--page-size
  4096|16384`; `@align(N)` ceiling raised `4096 -> 16384`; `--page-size` added to
  the usage banner. The `writeElfBytes` call in `linkObjects` now forwards
  `pageSize` (§4).
- `tests/page-size-checks.sh` — the new regression suite (§5), registered in
  `ci.sh`.
- `tests/integer-cast-checks.sh`, `tests/literals-checks.sh` — the asserted
  version string follows the bump.
- `FEATURE_STATUS.md` — a row for `--page-size` / 16 KB alignment; "As of"
  bumped to v0.23.54-dev.
- `ROADMAP.md` — the Android 16 KB page-alignment item marked shipped; "Status
  as of" bumped.
- `VERSION_HISTORY.md`, `README.md` — the version, the entry, and this report.
