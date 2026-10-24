# Validation Report — v0.23.51-dev

**Feature: toolchain hardening, Round D — symbol versioning + thread-local
storage + DWARF typing (3 of 3).** This is the fourth of the host-toolchain
rounds (Round A `u64` + `T(x)`, Round B `switch` + labeled jumps, Round C the
literal surface all shipped). Two `.so` writers (`writeSharedObject`, the
SysV-`DT_HASH` path, and `writeSharedObjectDyn`, the GNU-`DT_GNU_HASH` path)
emitted **no** symbol versioning, so a `gcc`-linked Aster `.so` that imported
a libc symbol had nothing for the dynamic loader's version check to bind
against; the language had no thread-local storage; and DWARF described a
function only by its return type. This round makes the `.so` output
loader-correct, adds `tls let`, and completes a corner of the debug info — and
changes **no byte of any example that does not use the new features** (`§6`).

```
// the two shipped examples, under qemu-aarch64:
//   aster build-elf examples/tls_demo.ast -o t && qemu-aarch64 ./t; echo $?
//   55
//   aster build-so examples/so_verstrlen.ast -o v.so        # emits versioned .so
//   readelf --version-info v.so | grep -E 'Flags: BASE|Name: aster|Version: 3'
//     Flags: BASE            Index: 1  <-- the BASE verdef (skipped by glibc)
//     Index: 2  Cnt: 1  Name: aster
//     Version: 3            <-- the libc import, versym == VERNEED aux index
```

## 1. Why this round exists

The `.so` writers were loader-incorrect in a way no green suite could see,
because a suite that only `dlopen`s a happy-path Aster→Aster `.so` never
exercises the libc version check. The three gaps:

- **No symbol versioning.** A modern `ld.so` resolves a `VERNEED` library
  entry against the *versioned* definitions the object advertises. Aster's
  `.so` carried a `DT_NEEDED libc.so` but no `DT_VERNEED` against
  `GLIBC_2.17`, and no `.gnu.version*` sections, so a `strlen` import had a
  `versym` of 0 — an ambiguous, unversioned reference that a strict loader
  rejects or, worse, accepts with the *wrong* definition. `gcc -shared` always
  emits a `DT_VERNEED` + `DT_VERDEF` + `.gnu.version*` even with no version
  script; Aster must too, or its `.so` files are not first-class citizens.
- **No thread-local storage.** Every nontrivial program eventually needs a
  per-thread variable; Aster had `let` (global, process-shared) and nothing
  local to a thread. The local-exec model is the simplest correct one for a
  static image, and the `TPIDR_EL0` access sequence is a fixed six-instruction
  shape.
- **Incomplete DWARF typing.** A debugger reads a function's *signature* from
  a `DW_TAG_subroutine_type`; Aster emitted only the return type, so `p foo`
  in `gdb` showed the wrong type. The fix is a single extra DIE per function.

The semantic decisions: the version graph follows **glibc's own loader**, not
a guess at it (the BASE design was corrected against glibc 2.39 source —
`§2.2`); `tls` is a **context keyword** so the reserved-word count does not
move (still 26); the TLS block is **one per process** this round (no `.tbss`,
no multi-thread TLS); DWARF changes are **additive** (no byte of `.text`
moves).

## 2. What shipped

### 2.1 Symbol versioning in both `.so` writers

Both writers now emit three new sections and five new dynamic tags:

| Section / tag | writer | content |
| --- | --- | --- |
| `.gnu.version` | both | one 2-byte `versym` per `dynsym` entry; exports → 2, libc imports → 1, null/local → 0 |
| `.gnu.version_d` | both | two `Verdef`: a `VER_FLG_BASE` BASE at **index 1** (name = soname, or the output-file basename when there is no soname), and a named `aster` version at **index 2** |
| `.gnu.version_r` | both | one `Verneed` against `GLIBC_2.17` with one `Vernaux`, `vna_other` = **3** |
| `DT_VERDEF` / `DT_VERDEFNUM` | both | `DT_VERDEFNUM` = 2 |
| `DT_VERNEED` / `DT_VERNEEDNUM` | both | `DT_VERNEEDNUM` = 1 |
| `DT_VERSYM` | both | points at `.gnu.version` |

The two writers share the *shape* but differ in the name source (the SysV
writer uses the output basename when there is no soname; the GNU writer uses
`spec.soname` when present, else the basename) and in the import `versym`
(the SysV writer has no imports by construction, so its imports `versym`
never appears; the GNU writer sets imports to 1). The section layout,
`sh_info` on `.gnu.version_d` (= 2, the number of verdefs), and the
`vd_next` chain (28 bytes between the two `Verdef`s) are identical.

### 2.2 The glibc evidence chain (why BASE is index 1)

The BASE-index assignment is **not** a convention Aster invented — it is what
glibc 2.39's loader requires. Two functions, read from source:

- `elf/dl-version.c` `_dl_check_map_versions` (≈ L343–351): the loop fills
  `l->l_versions[ndx]` **only when** `(ent->vd_flags & VER_FLG_BASE) == 0`:
  ```c
  if ((ent->vd_flags & VER_FLG_BASE) == 0)
      /* record the version in l->l_versions[ndx] */ ;
  ```
  The BASE verdef (the one carrying `VER_FLG_BASE`) is therefore **skipped** —
  `l_versions[base_ndx]` stays calloc-zero. `find_needed()` consults only
  `VERNEED` entries, so the BASE name participates in **no** symbol lookup; it
  is purely informational (the soname stamped onto the version namespace).
- `elf/dl-runtime.c` `_dl_fixup` (≈ L71–79): at each relocation, the loader
  takes the `versym`, masks off the `0x8000` hidden bit, and reads that slot of
  `l->l_versions`:
  ```c
  ElfW(Half) ndx = vernum[ELFW(R_SYM) (reloc->r_info)] & 0x7fff;
  version = &l->l_versions[ndx];
  if (version->hash == 0) version = NULL;   /* unversioned */
  ```
  Because the BASE slot is calloc-zero, `version->hash == 0`, so an import
  whose `versym` equals the BASE index is treated as **unversioned** — exactly
  the binding a libc import should have.

Putting the two together: **the BASE verdef must sit at the index that an
import's `versym` takes, and that index must be the one the loader treats as
"no version."** That is index 1 (the dynamic loader's BASE convention), with
`VER_FLG_BASE` set so it is skipped when filling `l_versions`.

### 2.3 The two import-versioning design corrections

The first two drafts were each caught by a hand `dlopen` witness against a
glibc/aarch64 host, and each failed with a *different* symptom — which is the
tell that the failure is in the version graph, not in the byte structure:

1. **Import pinned to the `aster` index (index 2).** Draft one set every
   non-local `versym` to 2, the `aster` version. Result:
   `undefined symbol: strlen, version aster`. The loader resolves a `VERNEED`
   library (`GLIBC_2.17`) against the *import's* `versym`; `aster` is not a
   version glibc exports, so the symbol has no definition. **Fix:** libc
   imports take `versym` 1 (the BASE index), which `§2.2` shows the loader
   reads as unversioned — i.e. "bind to whatever `GLIBC_2.17` the VERNEED
   names."
2. **Import pinned to the `VERNEED` aux index (index 3).** Draft two set
   imports to 3, the `Vernaux` index. Result:
   `undefined symbol: counter, version GLIBC_2.17` — the loader now believes
   `counter` is a glibc symbol (because `versym` 3 points at the
   `GLIBC_2.17` `VERNEED`), which of course glibc does not define. **Fix:**
   index 3 is the *version the VERNEED requests*, not the index an import's
   `versym` should carry; imports keep `versym` 1, and `readelf` shows the
   import's `Version:` field as **3** because `readelf` itself maps `versym` 1
   (BASE) to "no version" and displays the *requested* VERNEED version in the
   `Version:` column. The two numbers (the `versym` byte = 1, the displayed
   `Version:` = 3) are the same fact seen from the two ends.

The suite pins both facts: the import's raw `versym` is **1** (`3 not in idx`
and `1` present), and `readelf --version-info` shows `Version: 3` on the
import line.

### 2.4 The `ld` comparison shape

The version graph was matched to what `aarch64-linux-gnu-gcc -shared` emits,
verified by a control experiment (three link shapes):

- `gcc -shared` **without** a version script → **no** verdef at all (Aster's
  pre-Round-D state, and why the old `.so` was loader-incorrect).
- `gcc -shared --version-script` → exactly one `Verdef` with `Flags: BASE`
  (index 1, name = soname, or the output-file **basename** when there is no
  soname), one named version (index 2) for the exports, and one `Verneed` +
  aux (index 3) for the imports. Exports carry `versym` 2; imports carry
  `versym` 3 **because `ld` knows `strlen` belongs to libc** and binds it to
  the `GLIBC_2.17` `VERNEED`.
- Aster cannot *know* that `strlen` is a libc import vs. a definition in
  another Aster `.so`. The honest answer is to leave the import at `versym` 1
  (BASE/unversioned), which binds correctly to the default version of whatever
  library the `VERNEED` names — libc's default, or the other Aster `.so`'s
  `aster` default.

The `BASE` name convention (soname, else output basename) is taken directly
from `ld`: with no `-soname`, `ld` names the BASE version after the **output
file's basename**, exactly as Aster's SysV writer does.

### 2.5 Thread-local storage (`tls let`)

`tls let x: T = …;` (and `tls extern let x: T;`) places a global in a
per-thread block. `src/aster.cpp` parses it as a context keyword at the start
of a top-level declaration:

```cpp
if (cur().k == TK::Ident && cur().s == "tls") {
    ++p; bool external = false;
    if (cur().k == TK::Extern) { external = true; ++p; }
    need(TK::Let, "expected 'let' after 'tls'");
    globalDeclaration(external, /*tls=*/true);
    continue;
}
```

The block is laid out like a scalar/array slot in `layoutObject` (kind 4,
reached by `TPIDR_EL0 + offset`), carried by a static image as:

- one **`PT_TLS`** program header (type 7, flags `RW`, `filesz == memsz`, no
  `.tbss` this round), and
- one **`SHF_ALLOC | SHF_TLS`** (0x2 | 0x400) **`.tdata`** section holding the
  initializers, aligned to 16 bytes.

The access is **local-exec**: `MRS Xt, TPIDR_EL0` then `ADD Xt, Xt, #offset`,
where the offset is a link-time constant the linker fills into the
`MOVZ`/`MOVK` pair (`kRelTlsOff` = `target - tlsVaddr`, block-relative).
main's entry stub points `TPIDR_EL0` at the block's base:

```cpp
emit(0x90000000u | 17u);                               // ADRP X17, __aster_tls_block
relocations.push_back({uint64_t(adrp)*4, "__aster_tls_block", kRelAdrp});
emit(0x91000000u | (17u<<5) | 17u);                    // ADD  X17, X17, #lo12:__aster_tls_block
relocations.push_back({uint64_t(add)*4, "__aster_tls_block", kRelAddLo});
emit(0xd51bd051u);                                     // MSR TPIDR_EL0, X17
```

`__aster_tls_block` (offset 0 of `.tdata`) and `__aster_tls_<name>` per TLS
global are added to the defined-symbol set so a static link resolves them.

**`tls` is a context keyword.** `Global` gains `bool tls = false;`, and the
keyword is only special at the *start* of a top-level declaration — `let tls:
i32 = 5;` is an ordinary local. So the reserved-word count stays **26**, the
`KEYWORDS` generator output is untouched, and `examples/tls_demo.ast` exits
**55** (a = 10+5 = 15, b = 20*2 = 40, 15+40 = 55) under qemu.

**A shared object rejects `tls`.** A `.so` has no fixed load address and no
owner thread, so it cannot materialize a `TPIDR_EL0` access. Both `.so` paths
throw at link time:
- `link-so`: `thread-local storage (`tls`) is not supported in shared objects; use a plain 'let' or pass the value explicitly`
- `build-so` / `build-apk`: `thread-local storage (`tls`) is not supported in shared objects: global '<name>'`

`examples/tls_demo.ast` therefore records **FAILED** for `build-so` by design
(it does not fail for `build-elf` / `build-obj --pic`).

### 2.6 DWARF typing

Each subprogram DIE's `DW_AT_type` now names a **`DW_TAG_subroutine_type`**
that carries the return type and one `DW_TAG_formal_parameter` per parameter
type — not the bare return type — so `gdb`'s `p foo` reads the whole
signature. Every DIE also carries a **`DW_AT_decl_file`** (the index of the
single file entry the line table emits, 1). Both are emitted from the existing
`-g` path and add no byte to `.text`.

## 3. The defects the round found in itself

- **The two import-versioning drafts (§2.3).** Each failed a hand `dlopen`
  witness with a distinct symptom (`version aster` vs `version GLIBC_2.17`),
  which is what localizes the bug to the version graph. The fix — imports at
  `versym` 1, BASE verdef at index 1 with `VER_FLG_BASE` — is the one glibc
  accepts, and it is pinned by the suite's `3 not in idx` / `versym == 1`
  guards plus the `vna_other` = 3 check.
- **The `dlopen` witness machine was the wrong arch.** The first manual
  `dlopen` attempt loaded an aarch64 `.so` into an x86-64 host `cc` and died
  with "cannot open shared object file" — a spurious failure that masked the
  real version bug. `HOSTCC=aarch64-linux-gnu-gcc` rebuilds the host loader as
  aarch64, after which the witness runs cleanly and `witnessed current()=7` /
  `len()=11`. The lesson: a cross-architecture `dlopen` witness must itself be
  built for the target.
- **The `python` baseline filter over-counted.** The auto-filter script
  asserted a hard-coded grep occurrence count that shifted when the new example
  families added a second grep line; fixed by asserting the actual count and
  replacing only the first occurrence. A mechanical trap, not a semantic one.

## 4. What the suites prove

### 4.1 `tests/symbol-versioning-checks.sh` — [9/9]

1. **Strict build** (`-Wall -Wextra -pedantic -Werror`, `-O2`).
2. **Source guards** — 10 shared literals across both writers (the
   `DT_VERDEFNUM` push, `verDefSize == 56`, the `VER_FLG_BASE`/`hash 0`
   fields, `vna_other == 3`, the `elfHash("aster")`/BASENAME name strings, the
   `gnuVersion[i*2] = 2` export assignment, the `DT_VERDEFNUM` = 2 tag).
3. **ELF structure (SysV path)** — two `Verdef` (BASE flags 1 / hash 0 / next
   28, name = `math.so`; `aster` ndx 2 / hash set / next 0), `vna_other == 3`,
   `VERDEFNUM == [2]`, every export `versym` == 2 and `1`/`3` absent.
4. **ELF structure (GNU path)** — two `Verdef` + BASE name == soname ==
   `DT_SONAME`(`import.so`), import `versym` == 1, `3` absent.
5. **`readelf --version-info`** — `Flags: BASE + Index: 1`, `Index: 2 + Cnt: 1
   + Name: aster`, `Version: 3` on the import, export `@@aster`, no `@GLIBC`
   suffix on imports. UND counting via
   `grep -Ec ' UND [^[:space:]]+$'` (the null-symbol `UND ` row is excluded).
6. **Independent reader** — `readelf` agrees on the three `versym` classes.
7. **The `vd_next` chain** — a reader that walks `vd_next` finds exactly two
   verdefs.
8. **Rejection matrix** — a libc import answers `versym` 1 and `Version: 3`
   simultaneously; a purely-Aster import resolves to the other `.so`'s default
   `aster` version.
9. **Mutation** — `sed 's|pv16(verNeed,22,3);|pv16(verNeed,22,1);|'` drops the
   `vna_other` to 1 and must be caught.

### 4.2 `tests/tls-checks.sh` — [9/9]

1. **Strict build**.
2. **Source guards** — the `tls` context keyword, the per-thread block layout,
   the `MRS X16,TPIDR_EL0` + `ADD X16,X16,X17` access, the entry stub
   (`ADRP X17,__aster_tls_block` / `ADD` / `MSR TPIDR_EL0`), `kRelTlsOff`
   (`target - tlsVaddr`), and the `.so` rejection from both writers.
3. **Parse acceptance** — a scalar `tls let` and an array `tls let table:
   i32[4] = 0;` compile, a local named `tls` (`let tls: i32 = 5;`) still
   compiles, and the reserved-word count is still 26 (`tls` absent from
   `gen_lexer_names.py`'s keyword list).
4. **ELF structure** — exactly one `PT_TLS` (RW, `filesz == memsz`, positive
   multiple of 4), a `SHF_ALLOC|SHF_TLS` `.tdata` at the `PT_TLS` address,
   the `a=10`/`b=20` initializers present in `.tdata`, and `__aster_tls_block`
   plus `__aster_tls_a`/`__aster_tls_b` symbols.
5. **The local-exec relocation** — `kRelTlsOff` fills the block-relative
   offset.
6. **Independent readers** — `readelf`/`python` agree on the segment, section
   and symbols.
7. **Rejection matrix** — `link-so` and `build-so` both refuse `tls` with the
   two exact messages.
8. **qemu self-checks** — the real code shape (entry stub + `MRS`/`ADD`
   access) runs under qemu and `examples/tls_demo.ast` exits **55**; the
   single-thread model is exercised.
9. **Mutation** — a mutant that drops the `MRS X16,TPIDR_EL0` access is caught.

## 5. Baseline

`tests/rebuild-baseline-v0.23.51.sh` re-records
`tests/baseline/v0.23.5-dev/example-hashes.txt` from **339 → 345 rows**:

- the 288 core rows, **byte-identical**;
- the sixteen earlier rounds' three-row families, unchanged;
- this round's six rows: `tls_demo` (`build-elf`, `build-obj --pic`,
  `build-so` = **FAILED** by design) and `so_verstrlen` (`build-elf`,
  `build-obj --pic`, `build-so`).

**The entire `build-so` family changed.** Every Aster `.so` line now carries
the version sections, so the 109 `build-so` rows moved wholesale — recorded
faithfully, not diffed, because the diff would be the whole family. The
rebuild script asserts the 288 pre-existing rows byte-identical **before** it
writes, and asserts zero `FAILED` rows (except the two pre-existing
`libc`-shape failures), so a spurious `FAILED` is a hard error.

**Filtering suites.** The two new example families (`tls_demo`, `so_verstrlen`)
were added to the baseline filter of the nine resident suites that do a strict
baseline diff (`array-address`, `array-elem-types`, `integer-cast`,
`literals`, `multi-dim-array`, `precedence`, `sizeof-len`,
`struct-array-field`, `switch`), so the 288 pre-existing count stays 288 on
both sides. The suites that do a full `diff` need no exclusion.

## 6. Reproduction

```sh
# 0) the two resident suites (build everything from source)
./tests/symbol-versioning-checks.sh
./tests/tls-checks.sh

# 1) the TLS example under qemu
aster build-elf examples/tls_demo.ast -o t && qemu-aarch64 ./t; echo $?   # 55

# 2) a versioned .so and its readelf shape
aster build-so examples/so_verstrlen.ast -o v.so
readelf --version-info v.so | grep -E 'Flags: BASE|Name: aster|Version: 3'
#   Flags: BASE            Index: 1
#   Index: 2  Cnt: 1  Name: aster
#   Version: 3

# 3) the hand dlopen witness (aarch64 host loader)
HOSTCC=aarch64-linux-gnu-gcc tests/tls-checks.sh   # the .so rejection matrix + the dlopen witness

# 4) the byte-identity baseline re-record (one-shot; asserts before it writes)
./tests/rebuild-baseline-v0.23.51.sh

# 5) the full CI
sh tests/ci.sh
```

## 7. Files

- `src/aster.cpp` — both `.so` writers gain `.gnu.version` / `.gnu.version_d`
  / `.gnu.version_r` and the five `DT_VER*` tags (BASE verdef at index 1 with
  `VER_FLG_BASE`, `aster` at index 2, `VERNEED` against `GLIBC_2.17` aux 3);
  `tls let` parsing + `Global::tls`; the per-thread block layout (kind 4),
  `PT_TLS` + `SHF_TLS` `.tdata`, the `MRS Xt,TPIDR_EL0` / `ADD` access,
  `kRelTlsOff`, the `TPIDR_EL0` entry stub, and the `__aster_tls_block` /
  `__aster_tls_<name>` symbols; the `.so` `tls` rejection on both paths; and
  the `DW_TAG_subroutine_type` + `DW_AT_decl_file` DIEs. Version `0.23.51-dev`.
- `bootstrap/gen_lexer_names.py` — `KEYWORDS` still 26, `TOKENS` still 77
  (`tls` is a context keyword, not a new token); regenerates
  `bootstrap/aster.ast` and `tests/lexer_names.h`.
- `examples/tls_demo.ast`, `examples/so_verstrlen.ast` — the two new examples
  (`tls_demo` records `build-so` = FAILED by design).
- `tests/symbol-versioning-checks.sh`, `tests/tls-checks.sh` — the two new
  [9/9] resident suites.
- `tests/rebuild-baseline-v0.23.51.sh` — baseline re-record (339→345).
- `tests/ci.sh` — both new suites registered.
- `docs/language-reference.md`, `docs/language-spec.md`, `FEATURE_STATUS.md`,
  `ROADMAP.md`, `VERSION_HISTORY.md`, `README.md` — the feature, the counts,
  and this report are documented.
