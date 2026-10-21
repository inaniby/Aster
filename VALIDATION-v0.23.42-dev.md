# Validation Report — v0.23.42-dev

**Feature: the first slice of an Aster standard library — thirteen routines in
one object, and the round with no compiler change at all.** M0 gave a program
the bytes in and M1 gave it somewhere to put them; this is what a bootstrap
compiler *writes with*. `stdlib/aster_std.ast` implements the four families
`SELFHOSTING-PLAN.md` M2 names — byte primitives, text, number rendering, and
an open-addressing hash table — in pure Aster over the `load_u8`/`store_u8`
intrinsics, and the only edit to `src/aster.cpp` is the version constant. The
round's substance is not new compiler surface: it is proving that the language
as it stands can carry a library, and that the delivery shape survives contact
with the linker. The zero-dependency constraint held and is now *measured*
rather than promised: the library object defines every symbol it uses.

```
# stdlib/aster_std.ast — the four families, and the two idioms that carry them

fn memcpy(dst: ptr<u8>, src: ptr<u8>, n: i32) -> i32 {   // ptr<u8>: takes both
    let i: i32 = 0;                                      // a literal and &arr
    while (i < n) { store_u8(dst + i, load_u8(src + i)); i = i + 1; }
    return n;
}

fn hash_str(s: ptr<u8>) -> i64 {                // FNV-1a, 64-bit
    let h: i64 = -3750763034362895579;          // 0xcbf29ce484222325 as i64
    let i: i32 = 0;
    while (i < 1000000) {
        let b: i32 = load_u8(s + i);
        if (b == 0) { return h; }
        h = (h ^ b) * 1099511628211;
        i = i + 1;
    }
    return h;
}

let hkeys: ptr<u8>[1024] = 0;                   // the symbol table's shape:
let hvals: i64[1024] = 0;                       // two arrays, an empty slot
                                                // is key 0, values non-negative
```

## 1. Why this round exists

The plan's M2 is four families of routine "these ship with the bootstrap and
do not enter the compiler proper" — and the interesting question turned out
not to be *what* to write but *how it ships*. `include` shares declarations
only (v0.23.13-dev): an included function arrives with its body dropped, so a
file that implements something cannot be included into a consumer. A library
is therefore an object, built with `build-obj`, consumed through `extern fn`,
and linked with `link-obj` — the two-object pattern
`examples/global_shared_main.ast` has demonstrated since v0.23.13-dev, now
carrying a real library. Everything else in this report is the evidence that
the pattern holds: the parameter spelling measured before any code existed,
the differential twin that caught two real bugs, and the suite that keeps the
families honest by breaking them on purpose.

## 2. The delivery shape, in the linker and in the type checker

- **`build-obj` → `build-obj` → `link-obj`, main object first.** The library
  compiles to an `ET_REL` (664 instructions, 13 functions, 2 globals), the
  consumer to another, and `link-obj app.o std.o -o app` raises 337
  relocations (151 `CALL26`) into one `ET_EXEC`. Cross-object initialisation
  order follows command-line order (v0.23.13-dev's rule, §"Order" of the
  spec); the library's globals are zero-initialised `.bss`, so there is
  nothing to order.
- **The consumer names what it uses.** `extern fn memcpy(dst: ptr<u8>, src:
  ptr<u8>, n: i32) -> i32;` in the consumer is checked against every call
  site exactly as a same-file declaration would be — the three rejections in
  §5 pin that a bare `ptr` parameter refuses `&arr`, a wrong arity is
  refused, and an undeclared routine is refused before it reaches the linker.
- **One definition per symbol.** A second object defining `memcpy` is refused
  with `duplicate global symbol 'memcpy' across input objects` — a library
  consumer cannot accidentally double-link.
- **Self-containedness is measured, not claimed.** `readelf -sW std.o` shows
  exactly one UND entry: the ELF null symbol at index 0. Thirteen functions
  and two globals defined, nothing imported. That is the zero-dependency
  discipline as a CI assertion.

## 3. The parameter spelling was measured, not chosen

Three candidates were probed before a line of the library was written, because
the wrong choice is silent for half the call sites:

| Candidate | string literal | `&arr` of `u8[N]` |
| --- | --- | --- |
| bare `ptr` parameter | accepted (a literal's type *is* a ptr) | **refused** — `argument type mismatch … expected ptr` |
| `ptr[N]` global element | accepted | **refused** — `expected ptr, got ptr` (a message naming neither, which is why the probe exists) |
| **`ptr<u8>`** | **accepted** | **accepted** |

`ptr<u8>` is the only spelling that takes both, so every byte-buffer parameter
in the library is `ptr<u8>` and the suite's first rejection pins the rule.
Related measurements that shaped the file: `while (true)` bodies are **not**
accepted as terminating (the compiler requires a reachable `return` after the
loop — `strcmp` and `hash_str` carry a million-iteration guard plus a tail
`return`); array *names* decay as arguments exactly as `&arr` does (both
spellings verified equal under qemu); and a `ptr` element compares to the
literal `0` directly (`k == 0`), which is what makes an empty hash slot
cheap to test.

## 4. What the differential caught that inspection did not

The oracle is `tests/aster-std-twin.c`: the same 28 output lines written from
the specification in C, which additionally checks its own `utoa`/`itoa`/
`utohex` against `snprintf` **before printing anything** — so a routine wrong
on both sides is a coincidence the suite refuses to rely on. Two findings
earned the round its keep:

- **An FNV constant computed wrong twice, by the author, not the compiler.**
  The offset basis `0xcbf29ce484222325` does not fit an i64 literal, so it
  enters as its two's-complement value — and the first two attempts at that
  value were wrong by a few billion, which the slot indices disagreed about.
  The proof the *compiler* was innocent is the nice part: `itoa` printed the
  wrong constant back, digit for digit, exactly as the source had asked. The
  correct value is **-3750763034362895579** (`14695981039346656037 - 2^64`),
  now carrying its derivation in a comment, and the lesson generalises: any
  constant past i64 is generated with Python, never written by hand.
- **A `strncpy` return value both sides got wrong** — the one bug class a
  differential *cannot* see. The first cut returned `i` after the NUL-pad loop
  had walked it to `n`, so every short source answered `n` instead of its
  copied length; the twin, written from the same sentence, made the identical
  mistake, and the outputs matched byte for byte. What caught it was reading
  the documented contract (`min(strlen(src), n)`) against the printed line
  (`NP 8` for a two-character source). A differential catches *disagreement*;
  only a stated invariant catches *shared* error.

The suite's mutation layer is the third line of defence, and it is the first
in this project to target **Aster source rather than the compiler**: eight
probes patch `stdlib/aster_std.ast` (the copy offset, the fill constant, the
comparison's sign, the digit base, the strncpy return, the FNV multiplier,
the hash mask, the miss sentinel), rebuild the object, relink and require
divergence from the twin. One of them shipped **blind on the first attempt**:
masking to 511 left all three demo keys unshifted (they hash below 512), and
a probe that cannot fail is decoration — it now breaks the forgotten `-1` on
a power-of-two capacity (`& 1024`), which collapses the table into the first
slots and moves every index.

## 5. Coverage: one resident suite, `tests/stdlib-checks.sh` [8/8]

1. **Strict build** of the compiler (`-Wall -Wextra -pedantic -Werror`).
2. **Oracle located** — `aarch64-linux-gnu-gcc` probed for AArch64 ELF,
   `qemu-aarch64` (or an AArch64 host) for the runner; either missing is a
   clean SKIP, as every e2e suite in this project.
3. **The delivery chain, differentially.** `build-obj stdlib/aster_std.ast` →
   `build-obj examples/stdlib_demo.ast` → `link-obj demo.o std.o` → run under
   the runner → compare against the twin: **28 lines, 274 bytes, exit 0,
   byte-identical** (the mem/str/num/hash case set, in the order §4's table
   lists).
4. **Three rejections** — the bare-`ptr` parameter with `&arr` (`argument
   type mismatch calling memcpy at argument 1: expected ptr`), the arity
   (`wrong argument count calling memcpy: expected 3, got 2`), the
   undeclared routine (`call to undeclared function: strlen`).
5. **Self-containedness** — exactly one UND symbol (the ELF null), asserted
   with `readelf`.
6. **Duplicate definition** — `link-obj demo.o std.o dup_helper.o` refused
   with `duplicate global symbol 'memcpy' across input objects`.
7. **Eight mutation probes** — each asserts the edit applied (a missed anchor
   is a FAIL, not a skip), that the mutated object still builds and links (or
   the probe passes on the build failure), and that the result diverges from
   the twin on stdout or exit status.
8. Registered in `tests/ci.sh`'s suite list, so it runs in the full gate.

## 6. Nothing that exists moves

No codegen path is touched: the only source delta is the version constant, so
every pre-existing output is byte-identical by construction — and this round
that claim is checked, not argued. `tests/rebuild-baseline-v0.23.42.sh`
rebuilt the compiler strictly, re-hashed all 110 examples in all three build
modes, and diffed the result against the recorded baseline: **327 lines in,
327 lines out, byte for byte**, then wrote the new total (330 — the demo's
three rows) back to `tests/baseline/v0.23.5-dev/example-hashes.txt`. The
comparison is wider than any earlier round's: since v0.23.37 the scripts
compared only the 309-row core, filtering the carried `fn_type`/`cb_table`/
`fn_ret`/`call-stmt`/`copy` rows (and `arena`'s three) out of both sides;
with the baseline carrying them, this round keeps all 327 in the diff.

The re-record is load-bearing, not bookkeeping — and it is only the first of
two edits a new example forces. **Ten** resident suites (`condition`,
`null-ptr`, `precedence`, `sizeof-len`, `struct`, `struct-array-field`,
`array-address`, `array-elem-types`, `multi-dim-array`, `narrow-value-coverage`)
read that baseline, and they read it two different ways. Eight of them
full-file diff it, so the first full CI run of this round failed
`condition-checks.sh` with exactly one added line —
`+stdlib_demo.build-elf FAILED` — the signature of an unrecorded example,
which is the failure those suites are built to produce (`re-recording is
tests/rebuild-baseline-*.sh's job`). But six of them (`precedence`,
`array-elem-types`, `struct-array-field`, `array-address`, `multi-dim-array`,
`sizeof-len`) go further: they filter each round's own family out of *both*
sides and then assert the surviving row count equals **288**, so the second
run failed two of them with `expected 288 pre-existing baseline rows, found
291` — the same lesson one level down. Every round since v0.23.30-dev has
paid it: the new example joins the filter list of all six suites, and the
count survives because the filtered total grows by exactly the round's three
rows (330 recorded − 42 filtered = 288, measured, not assumed). The library
is new files (`stdlib/aster_std.ast`, `tests/aster-std-twin.c`,
`tests/stdlib-checks.sh`, `examples/stdlib_demo.ast`) plus the suite
registration, the baseline script and those six filter lines; no example, no
test and no documented behaviour is edited. The new demo joins no baseline
family — its witness is the differential, not the A/B.

## 7. Deliberately not included

- **No allocator.** M1 shipped the raw memory and `examples/arena.ast` shows
  the bump shape; the standard library rides on the same primitives without
  owning an allocator, and a collector stays out of scope (FEATURE_STATUS's
  decided boundary, unchanged).
- **No `munmap`/`mprotect`/generic syscall, no `argc`/`argv`** — the same
  boundaries M0 and M1 recorded; the library needs neither.
- **No growth of the hash table.** 1024 fixed slots, `hash_put` answers `-1`
  when full. A bootstrap's symbol table is bounded by its input; a table that
  full is a bug to report, not a condition to rehash into.
- **`utoa`'s contract is non-negative input.** The signed case is `itoa`'s
  job, and `itoa` refuses nothing at run time — the magnitude of i64's most
  negative value is not representable, so that one input is out of contract
  on both sides, by documentation.
- **The `while (true)` termination rule is unchanged.** The compiler still
  requires a reachable `return` after a constant-condition loop; the library
  works within it rather than asking for it to move.

## 8. What this closes, and what it opens

**Closes M2**: the four families exist, ship as one object, import nothing,
and are differentially pinned by a resident suite with a self-checking oracle
and eight source-level mutation probes. The delivery shape — `build-obj` +
`extern fn` + `link-obj`, `ptr<u8>` buffers — is documented in
`docs/language-spec.md`'s *Libraries ship as objects* and
`docs/language-reference.md` §12.

**Opens M3**: `aster.ast` is the bootstrap compiler itself, and it now has
its tools waiting — `strcmp` for keyword matching, the hash table for the
symbol and label tables, `utoa`/`utohex` for ELF fields and diagnostics, and
`memcpy`/`memset` for the node arrays an explicit-work-stack parser will
allocate from the M1 heap. The plan's own note that M3 needs "no compiler
change, pure library" is what this round just proved end to end.
