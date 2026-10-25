# Validation Report — v0.23.52-dev

**Feature: toolchain hardening, Round E of the plan — thread-local storage in a
shared object (`.tbss`, `PT_TLS` in a `.so`, initial-exec).** This is the fifth
host-toolchain round (Round A `u64` + `T(x)`, Round B `switch` + labeled jumps,
Round C the literal surface, Round D symbol versioning + static-only TLS + DWARF
typing all shipped). Round D shipped `tls let` for the **static image only**, and
shipped it with an explicit refusal: a shared object rejected `tls` with
`thread-local storage (`tls`) is not supported in shared objects`. This round
lifts that refusal and makes `tls let` work as a **per-thread block every thread
gets its own copy of**, reached through a loader-filled GOT slot (initial-exec) —
and it changes **no byte of any example that does not declare `tls`** (`§6`).

```
// the new shared-object example, under qemu-aarch64 + an AArch64 host loader:
//   aster build-so examples/so_tls_demo.ast -o s.so
//   tests/so-tls-host s.so bump 33 36
//     main: first=33 second=36
//     thread 1: first=33 second=36
//     thread 2: first=33 second=36
//     PASS: every thread got its own block (33 then 36)
//   readelf -lW s.so | grep TLS   -> one PT_TLS, filesz = .tdata, memsz = whole block
//   readelf -S  s.so | grep -E 'tdata|tbss'  -> .tdata PROGBITS WAT, .tbss NOBITS WAT
```

## 1. Why this round exists

Round D's refusal was real but narrow. A `.so` has no fixed load address, so the
**local-exec** access model — `MRS Xt,TPIDR_EL0` plus a link-time constant
offset — genuinely cannot work for a shared object: the linker does not know
where the block will live. But that is a property of the *access model*, not of
thread-local storage itself, and the ELF/g ABI has an answer for exactly this
case — **initial-exec** — where the loader stores the offset in a GOT slot and
fills it at load time. The aarch64 psABI and glibc both support it for a local
`static __thread`. So the refusal was a missing feature, not a hard wall, and
this round closes it.

The semantic decisions: `tls` stays a **context keyword** (reserved-word count
still 26); the block splits into `.tdata` + `.tbss` the way GNU ld splits it;
an access is **initial-exec** in a `.so` and **local-exec** in a static image,
and the two share one block-offset algorithm; `tls extern let` inside a `.so` is
still refused (there is no way to name another module's thread-local through
`.dynsym`).

## 2. What shipped

### 2.1 The access models

A **static image** (`build-elf` / `build-pie` / `link-obj` / `link-pie`) owns one
`PT_TLS` block for the whole process. main's entry stub points `TPIDR_EL0` at the
block's base (`ADRP X17,__aster_tls_block` / `ADD` / `MSR TPIDR_EL0`), so an
access is **local-exec**: `MRS X16,TPIDR_EL0` then `ADD X16,X16,X17`, where
`X17` holds a link-time constant the linker fills into a `MOVZ`/`MOVK` pair
(`kRelTlsOff` = `target - tlsVaddr`, block-relative). This path is unchanged from
Round D except that the block is now two sections.

A **shared object** (`build-so` / `link-so` / `build-apk`) has no base of its
own — the loader decides where this module's block sits — so an access is
**initial-exec**: `MRS X16,TPIDR_EL0` / `ADRP X17,slot` / `ADD X17,X17,#:lo12:slot`
/ `LDR X17,[X17]` / `ADD X16,X16,X17`. The slot holds an *offset from TP*, not
an address — the closing `ADD` is the proof (it adds the slot to the thread
pointer), and it is what makes each thread that dlopens the module get its own
copy. The slot is filled at load time by one **R_AARCH64_TLS_TPREL64 (1030)** per
variable, whose symbol index is **0 (`STN_UNDEF`)** and whose `r_addend` is the
variable's **block offset** — the form GNU ld emits for a local `static
__thread` under `-ftls-model=initial-exec`, read off this machine's own
toolchain (§3.1).

### 2.2 The block is two sections now (`.tdata` + `.tbss`)

`.tdata` (`SHT_PROGBITS`, `SHF_WRITE|SHF_ALLOC|SHF_TLS` — `WAT`, as GNU ld marks
it, `0x1|0x2|0x400`) holds the non-zero initializers and owns file bytes;
`.tbss` (`SHT_NOBITS`, same flags) holds the zero-initialized tail, starts at the
first **16-byte-aligned** offset past `.tdata` (the named `kTlsBlockAlign`), and
owns no file bytes. `PT_TLS` reports `p_filesz` = `.tdata` and `p_memsz` = the
whole block; the difference is `.tbss`, which a loader (or, in a static image,
the kernel, as the `PT_LOAD` bytes past `p_filesz`) zeroes per thread. Both
shared-object writers (`writeSharedObject`, the SysV-`DT_HASH` path, and
`writeSharedObjectDyn`, the GNU-`DT_GNU_HASH` path) emit `PT_TLS` — it sits after
`PT_DYNAMIC` and before `PT_GNU_RELRO`, deliberately outside RELRO, because
`.tdata` is writable.

### 2.3 No compile-time size cap on a shared object's TLS block

The plan and the early drafts of this round carried a **static TLS surplus**
constant (1664 bytes) and turned a block past it into a compile error. That
constant was measured on a *different* glibc and does **not** reproduce here: on
glibc 2.39 (Ubuntu, aarch64) a dlopen'd module's block is allocated
*dynamically* (a `.so` with a **1 MiB** TLS block dlopens cleanly under qemu;
every size from 1664 to 1048576 bytes loads — §3.3). glibc 2.35+ grew the
static TLS area on demand, so the old surplus wall is gone. A fixed constant
would only reject modules that load fine, and could not see the *host* process's
own TLS footprint at compile time. So the writer imposes **no** cap; if a block
genuinely cannot be placed, the loader still reports `cannot allocate memory in
static TLS block` at load time, and that runtime error is the honest contract
(§3.3). The constant and both rejection sites were removed.

### 2.4 `tls extern let` is still refused in a shared object

A shared object has no way to name another module's thread-local through
`.dynsym`, so `tls extern let x;` is refused at `build-so` with `an external
thread-local (`extern tls let`) is not supported in a shared object: global 'x'`.
A plain `tls let` is fine.

## 3. The evidence chain (why the design is this shape)

### 3.1 E1 — the TPREL64 addend is a pure block offset, not TCB_SIZE + offset

Round D's plan assumed aarch64's TLS variant I would make the addend
`TCB_SIZE + offset` (16 + offset). It does not. Measuring a local `static
__thread` on this machine's toolchain (`aarch64-linux-gnu-gcc -c -fPIC
-ftls-model=initial-exec`):

```
$ aarch64-linux-gnu-readelf -S e1.o        # e1.o: __thread int a=3; b; c=0;
  [ 5] .tdata  PROGBITS  …  0000000000000004  0000000000000000  WAT  0  0  4
  [ 6] .tbss   NOBITS    …  0000000000000008  0000000000000000  WAT  0  0  4
```

The relocations that survive into the linked `.so` are `R_AARCH64_TLS_TPREL64`
(1030). What matters for us is the **shape**: the symbol index is **0
(`STN_UNDEF`)** and the `r_addend` is the variable's **block offset**. A control
measurement of `static __thread int b;` relocates with addend **8**, not 24 — a
pure block offset, with the loader's own module offset already accounting for TP
sitting at the TCB. So the `.so` and the static image share one offset algorithm,
and **no code anywhere adds a TCB size**. E1 was run *before* any of this was
written, which is why the round is simpler than planned.

### 3.2 E2 — the initial-exec sequence and segment shape match GNU ld

Disassembling the `.so` GNU ld itself produces for the same source shows the same
five-instruction initial-exec shape Aster emits (the `mrs; adrp; add; ldr; add`
sequence; the closing `add x0,x1,x0` proves the GOT slot holds an offset from
TP). Aster's `tests/tls-checks.sh` disassembles its own `.so` with
`aarch64-linux-gnu-objdump` and asserts that exact sequence (§5, layer 6). The
`PT_TLS` shape also matches: `p_filesz` = `.tdata`, `p_memsz` − `p_filesz` =
`.tbss` — the same invariant GNU ld emits.

### 3.3 E3 — there is no small fixed surplus wall on this glibc

Scanning dlopen of a `.so` with one `__thread char big[N]` for N = 1664, 2048,
3000, 4096, 8192, 16384, 65536, 131072, 262144, 524288, 1048576, all eleven load
and the exported function runs (`ok=123`, exit 0) under qemu-aarch64 + glibc 2.39
(Ubuntu). The plan's "1664 loads, 2048 fails" does **not** reproduce; glibc 2.35+
allocates the dlopen'd block dynamically. This is the evidence behind §2.3 — the
compile-time surplus cap is gone, and the loader's runtime error is the only
contract. (Round D's static-image path is unaffected: its block is in the
executable's own TLS, sized at link time.)

## 4. The defects the round found and fixed

- **D1 — `layoutObject` decided "initialized" from `g.init` alone.** A
  thread-local *array* initializer (`rawData`) was therefore treated as all-zero
  and placed in `.tbss` instead of `.tdata`. Fixed by also consulting
  `rawData`/`init`/`wideInit`.
- **D2 — `mergeIncluded` copied every `Global` field except `tls`.** A `tls` let
  brought in through `include` silently became an ordinary global. Fixed by
  copying `tls`.
- **D4 — `.tdata`'s `addralign` was a hard-coded 16.** Replaced with the named
  `kTlsBlockAlign` so the block alignment is one named constant.
- **D6 — the merged `.tdata` alignment padding was applied *after* symbol offsets
  had been computed** against the unpadded size. A second object whose block
  needed stricter alignment placed every one of its thread-locals too low. Fixed
  by computing the padding before the per-symbol offsets.

## 5. What the suites prove

### 5.1 `tests/tls-checks.sh` — [9/9]

1. **Strict build** (`-Wall -Wextra -pedantic -Werror`, `-O2`).
2. **Source guards** — the `tls` context keyword; both access shapes' exact
   encodings (`0xd53bd050` MRS, `0x8b110210` ADD, `0xd51bd051` MSR, the initial-exec
   `ADRP`/`ADD`/`LDR` trio, `0xf9400231` LDR); `kRelTlsOff=4096`; `kRelTlsTprel=1030`;
   `kTlsBlockAlign=16`; the `PT_TLS` (type 7) headers in all three writers; the
   `.tdata`/`.tbss` section flags; the block-relative `kRelTlsOff` fill; and the
   `build-so` extern-tls rejection.
3. **Parse acceptance** — a scalar and array `tls let` compile, a local named
   `tls` still compiles, reserved words still **26**.
4. **Static-image structure** — exactly one `PT_TLS` (RW, `filesz=8`, `memsz=0x14`),
   `.tdata` WAT with `a=10,b=20`, `.tbss` NOBITS WAT at `+0x10`.
5. **Both models' relocations** — `kRelTlsOff` names each thread-local in the
   `.o`; both `.so` writers carry three `TPREL64` (sym 0, addends 0 / 4 / 0x10).
6. **Independent readers** — `readelf` and `objdump` agree on the segments,
   sections, symbols, and the initial-exec instruction sequence.
7. **Rejection matrix** — `extern tls` still refused with the documented message;
   a 2000-byte block builds and stays well-formed (full-size `PT_TLS`); a plain
   `.so` unaffected.
8. **qemu self-check + dlopen witness** — the static program exits **55** under
   qemu (`build-elf`/`build-pie`/`-g`); the three-thread dlopen witness
   (`tests/so-tls-host.c`, main + 2 pthreads, each must see **33 then 36**) passes
   for both `build-so` and `link-so` outputs.
9. **Mutations** — a halved local-exec offset (wrong exit code) and every
   `TPREL64` addend zeroed (addends `0/0/0`) are both caught.

### 5.2 The byte baseline and the filtering suites

`tests/rebuild-baseline-v0.23.52.sh` re-records
`tests/baseline/v0.23.5-dev/example-hashes.txt` from **345 → 348 rows**: 228 of
230 static rows byte-identical (the two that move are `tls_demo`'s — the block is
now two sections), 114 of 115 `build-so` rows byte-identical (the one that moves
is `tls_demo`'s, which stops being **FAILED** — the lifted refusal, recorded
rather than diffed), and one new example `examples/so_tls_demo.ast` with three
new rows (its `build-elf` row is FAILED by design: it has no `main`, it is a
library). Nine filtering suites (`array-address`, `array-elem-types`,
`integer-cast`, `literals`, `multi-dim-array`, `precedence`, `sizeof-len`,
`struct-array-field`, `switch`) add `^so_tls_demo\.` to the twenty families they
skip, so the 288 pre-existing count stays 288. The rebuild script asserts
byte-identity before it writes and is re-runnable in two modes (delta from the
pre-round 345-row baseline, or identity against the post-round 348-row one).

## 6. Baseline moved only for this round's own rows

342 of the 345 pre-existing rows are byte-identical. The three that move are
`tls_demo`'s (two static rows change shape because the block is now `.tdata` +
`.tbss`, and its `build-so` row flips FAILED → hash). The only genuinely new
bytes are `so_tls_demo.ast`'s three rows. Everything else — every example that
does not declare `tls` — is untouched.

## 7. Reproduction

```sh
# 0) the resident suite (build everything from source)
LC_ALL=C bash tests/tls-checks.sh

# 1) the shared-object TLS example under qemu, called from three threads
aster build-so examples/so_tls_demo.ast -o s.so
aarch64-linux-gnu-gcc -O2 -o so-tls-host tests/so-tls-host.c -ldl -lpthread
tests/run-aarch64.sh ./so-tls-host ./s.so bump 33 36     # 33 then 36 x3

# 2) the block's ELF shape
readelf -lW s.so | grep -A4 TLS        # PT_TLS filesz=.tdata, memsz=whole block
readelf -SW s.so | grep -E 'tdata|tbss' # .tdata PROGBITS WAT, .tbss NOBITS WAT

# 3) the E1/E2/E3 evidence (GNU ld control + the surplus scan)
#    see §3 of VALIDATION-v0.23.52-dev.md

# 4) the byte-identity baseline re-record (re-runnable; asserts before it writes)
LC_ALL=C bash tests/rebuild-baseline-v0.23.52.sh

# 5) the full CI
LC_ALL=C sh tests/ci.sh
```

## 8. Files

- `src/aster.cpp` — `0.23.52-dev`; both `.so` writers gain `PT_TLS` (type 7) +
  `.tdata`/`.tbss` sections (WAT) and the initial-exec access (GOT slot +
  `R_AARCH64_TLS_TPREL64`, sym `STN_UNDEF`, addend the block offset); `S0`–`S8`
  lift the `tls` refusal in `linkSharedObjects` and `buildSoFromSource` while
  keeping `tls extern let` refused; `layoutObject` splits the block into
  `.tdata`/`.tbss`; the static writers carry `PT_TLS` + `kRelTlsOff`; and the
  no-longer-needed `kStaticTlsSurplus` cap is removed.
- `examples/so_tls_demo.ast` — the new shared-object TLS example (`hits=10`,
  `total=20` in `.tdata`, `spare=0` in `.tbss`, `bump` the exported function).
- `tests/so-tls-host.c` — the three-thread dlopen witness.
- `tests/tls-checks.sh` — the new **[9/9]** resident suite (rewritten for the
  round; §5.1).
- `tests/rebuild-baseline-v0.23.52.sh` — baseline re-record (345 → 348),
  re-runnable.
- `examples/tls_demo.ast` — comment updated (its `build-so` is now FAILED by
  design because it has no `main`, not because of a `tls` refusal).
- `docs/language-reference.md`, `FEATURE_STATUS.md`, `ROADMAP.md`,
  `VERSION_HISTORY.md`, `README.md` — the feature, the surplus correction, and
  this report are documented.
