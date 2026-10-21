# Validation Report — v0.23.32-dev

**Feature: `-g` grows a second section — DWARF v4 `.debug_info` (and its
`.debug_abbrev`) beside the `.debug_line` Aster has emitted since v0.23.12-dev.**
A compilation unit per object, a `DW_TAG_subprogram` per function, and a
`DW_TAG_variable` per global, local and parameter — each naming the type it was
declared with, and each reachable at run time from `SP`.

```
$ ./aster build-elf examples/multi_dim_array.ast -g -o mda
$ readelf -S -W mda | grep debug
  [ 4] .debug_line       PROGBITS
  [ 5] .debug_abbrev     PROGBITS
  [ 6] .debug_info       PROGBITS
$ llvm-dwarfdump --debug-info mda | head -20
0x0000000b: DW_TAG_compile_unit
              DW_AT_producer  ("Aster v0.23.32-dev")
              DW_AT_language  (DW_LANG_C89)
              DW_AT_name      ("multi_dim_array.ast")
              DW_AT_low_pc    (0x0000000000401000)
```

## 1. Why this round exists

The user was offered four candidate rounds at once — a struct array field,
taking the address of a whole array, multi-dimensional arrays, and DWARF
`.debug_info` — and answered *"这4项一起做"*. The roadmap's first principle is
that **one version is one coherent theme**, so the four became three versions:

| Version | Contents | Kind |
| --- | --- | --- |
| v0.23.29-dev | a struct field that is an array | language — shipped |
| v0.23.30-dev | `&arr` → `ptr` | language — shipped |
| v0.23.31-dev | `T[N][M]` | language — shipped |
| **v0.23.32-dev** | DWARF `.debug_info` | **toolchain — this round** |

This one adds **nothing a program can write**. It is not a language change and
it does not belong in a language release; it is the follow-up to P4.2, and the
roadmap line that scheduled it is also the scope it was held to: *"compilation
unit, base types, function and variable DIEs"*.

What `-g` could answer before: *"which `.ast` line is this instruction?"*
What it could not: *"what is this slot called, and what type is it?"* There
were no names, no types and no frame description anywhere in the output.

## 2. The observation the round is built on: the frame base is free

Every Aster frame is a fixed **8192 bytes** — one `SUB SP, SP, #8192` in the
prologue — and SP does not move again anywhere inside a body. So:

* `DW_AT_frame_base` = `DW_OP_breg31 + 0` — *SP itself*;
* a variable's `DW_AT_location` = `DW_OP_fbreg(slot * 8)`.

That is the whole trick, and it is why this round is small: **no CFA rules, no
`.eh_frame`, no return-address column**. A debugger that can read SP can read
every local in the language.

Parameters ride the same rule. AAPCS64 arguments arrive in `x0`–`x7` and Aster
spills them into frame slots 0..n-1 on entry (a struct taking `ceil(size/8)` of
them), so a `DW_TAG_formal_parameter` is described exactly like a local and the
encoder needs no separate notion of where a parameter lives. In the round's
own test source, `fn scale(p: Point, k: i32)` gives `p` at `fbreg+0`, `k` at
`fbreg+8` and the local `t` at `fbreg+16` — parameters first, in declaration
order, then locals.

## 3. What is emitted

| DIE | Attributes | Where the value comes from |
| --- | --- | --- |
| `DW_TAG_compile_unit` | `producer`, `language` (`DW_LANG_C89`), `name`, `comp_dir`, `low_pc`, `high_pc`, `stmt_list` | `low_pc` = `.text`'s address, `high_pc` = its length; `name`/`comp_dir` split from the source path |
| `DW_TAG_base_type` | `name`, `byte_size`, `encoding` | `i32`/`u32`/`u8`/`u16`/`i64`/`bool`, with `DW_ATE_signed`/`unsigned`/`boolean` |
| `DW_TAG_structure_type` | `name`, `byte_size` | `layoutStruct`, so `Point { x, y }` is 8 bytes |
| `DW_TAG_member` | `name`, `type`, `data_member_location` | the field's own offset |
| `DW_TAG_array_type` + `DW_TAG_subrange_type` | `type`, `upper_bound` | **recursive**: `i32[2][3]` is two elements of `i32[3]`, as in C |
| `DW_TAG_pointer_type` | `byte_size` (8), `type` | a `ptr<S>`; an untyped `ptr` points at `DW_TAG_unspecified_type` |
| `DW_TAG_subprogram` | `name`, `low_pc`, `high_pc`, `frame_base`, `type`, `decl_line`, `external` | `low_pc`/`high_pc` from the function's own symbol |
| `DW_TAG_formal_parameter` | `name`, `type`, `location`, `decl_line` | `DW_OP_fbreg(slot*8)` |
| `DW_TAG_variable` (local) | `name`, `type`, `location`, `decl_line` | `DW_OP_fbreg(slot*8)` |
| `DW_TAG_variable` (global) | `name`, `type`, `location`, `external` | `DW_OP_addr` |

**Types are emitted before anything that names them**, because a `DW_FORM_ref4`
is a *forward* offset — a DIE can only point at one that already exists — and
de-duplicated through one cache (`DwarfDieWriter::types`). A `ptr<S>` reserves
its 4-byte reference and fills it *after* the recursive call, which is what lets
a pointer point at the struct it is a field of.

## 4. How the addresses get there: patch, don't guess

The line table raised all of its addresses by one text base. `.debug_info`
cannot: a subprogram's `low_pc` is **that function's** address and a global's is
**that object's**. So every address field is written as zero and recorded as
`(offset, symbol, addend)`:

| Patch symbol | Meaning | Written by | Resolved by |
| --- | --- | --- | --- |
| `.text` | the unit's `low_pc` | `encodeDebugInfo` | every writer, at the address it computes |
| a function's name | that subprogram's `low_pc` | `encodeDebugInfo` | the symbol map / export list |
| a global's name | that variable's `DW_OP_addr` | `encodeDebugInfo` | the segment it was laid out in |

In an `ET_REL` object these become `.rela.debug_info` entries of type
**`R_AARCH64_ABS64` (257)** against real symbol indices — the same relocation
type the line table already used — so `readelf -r` shows them:

```
Relocation section '.rela.debug_info'
    Offset             Info             Type            Symbol's Name + Addend
0000000000000029  0000000500000101 R_AARCH64_ABS64  .text + 0
000000000000008a  0000000300000101 R_AARCH64_ABS64  gcounter + 0
00000000000000af  0000000100000101 R_AARCH64_ABS64  _start + 0
00000000000000ff  0000000200000101 R_AARCH64_ABS64  scale + 0
```

This is what lets **one encoder serve five consumers**: `writeObject` records
the relocations, `linkObjects` and `linkSharedObjects` resolve them from the
merged symbol map, and `writeSharedObject` / `writeSharedObjectDyn` resolve them
from the segment addresses those two compute. Nothing is told an address twice.

## 5. Coverage: `tests/debug-info-checks.sh` [9/9]

Registered in `tests/ci.sh` beside `debugline-checks.sh`. Its decoder,
`tests/debuginfo-decode.py`, reads `.debug_abbrev` and `.debug_info` straight
out of the ELF section table — no pyelftools, no objdump — and rebuilds the DIE
tree, so the suite proves what **aster** wrote rather than what a tool chose to
show.

| Step | What it proves |
| --- | --- |
| 1 | **Off by default** — no `.debug_info` and no `.debug_abbrev` in an executable, a PIE, an object or a shared object built without `-g` |
| 2 | **Additive** — `.text` compared byte for byte with and without the flag; `.rela.debug_info` carries `R_AARCH64_ABS64` against `.text`, a function and a global |
| 3 | **The unit is anchored** — `low_pc`/`high_pc` read back from `readelf`, not trusted; `producer` names the version the source says it is; `comp_dir` is the source's directory |
| 4 | **One subprogram per function** — each `low_pc` and size equal to its own symbol's value and size in the symbol table, frame base `breg31+0`, `decl_line` the line `fn` is written on |
| 5 | **Every variable reachable** — a local or parameter at an ascending 8-byte slot, the first at the frame base itself, on the source line it is declared on, with the declared type; a global at `DW_OP_addr` equal to its symbol's address |
| 6 | **The type DIEs are real** — a struct's byte size and member offsets, an array's subrange, `i32[2][3]` spelled as an array *of* `i32[3]`, an 8-byte pointer, and no reference pointing outside the unit |
| 7 | **An independent reader agrees** — `llvm-dwarfdump` must produce the same functions and the same variables, DIE for DIE |
| 8 | **It survives linking** — `link-obj` and `link-so` each give one unit per object, each raised to that object's own text address; both `.so` paths and a PIE keep theirs |
| 9 | **The suite can still fail** — a copy of the source with every frame slot shifted by one must be caught |

Steps 3–6 are the ones that matter: they check the compiler **against the symbol
table and against the source**, not against a number the compiler also produced.
A subprogram whose `low_pc` disagrees with `readelf -sW`, or a local whose
`decl_line` disagrees with `grep -n`, fails — and no amount of self-consistency
in the encoder can hide it.

### 5a. The mutation layer (step 9)

`src/aster.cpp`'s `fbregOps` emits `DW_OP_fbreg` with a SLEB128 of `slot * 8`.
The suite rewrites it to `slot * 8 + 8`, rebuilds, and requires the parameter
that must sit at `fbreg+0` to move:

```
$ sed 's|slot\*8);return e;|slot*8+8);return e;|' src/aster.cpp > mutant.cpp
$ ./aster-mutant build-elf dbg.ast -g -o mutant.elf
$ python3 tests/debuginfo-decode.py --vars mutant.elf
main a local i32 fbreg+8 13          # was fbreg+0 — caught
```

If the `sed` ever stops applying, step 9 fails on its own, so the guard gets
fixed instead of quietly passing.

## 6. What the round found

Four defects, each found by something other than reading the code.

**(a) `DW_FORM_ref4` counts from the unit header, not from the first DIE.**
`llvm-dwarfdump` rendered every type reference one DIE short — `i32[2]` where
the source says `i32[2][3]` — because the writer handed out offsets into its own
DIE buffer and the 11-byte CU header is prepended afterwards. The writer's
`dieOffset()` now adds `kCuHeaderSize`.

**(b) `DW_TAG_unspecified_type` is `0x3b`, not `0x3c`.** `0x3c` is
`DW_TAG_partial_unit`, and `llvm-dwarfdump` said so. Both (a) and (b) are
invisible to a decoder that trusts what it is given — which is the argument for
the external witness being part of the suite and not merely a debugging aid.

**(c) The linker raised every unit's `low_pc` to the image's text base.** Two
`-g` objects linked to two units both claiming `0x401000`, while `add2` sat at
`0x401030`. The unit's patch names `.text`, and the linker gives `.text` one
address for the whole image. The line table never had this problem because it
raises by an object-relative offset, so the fix carries the same thing: a
`.text` patch's **addend becomes that object's offset in the merged text**, and
`symbolVaddr[".text"] + addend` is then right for every object at once.

**(d) The suite's own decoder made the same mistake as (c).** Reading the linked
image it printed `<bad-ref:70>` for every type in the second unit: a `ref4` is
relative to the unit that holds it, and the decoder was treating it as an offset
into `.debug_info` — which is the same thing only for the first unit.
`llvm-dwarfdump`, which parses unit by unit, resolved them correctly, and the
disagreement between the two readers is what identified which one was wrong.

## 7. Four write paths, not one

| Path | Reached by | Resolution |
| --- | --- | --- |
| `writeObject` | `build-obj` | records `.rela.debug_info` |
| `writeElfBytes` | `build-elf`, `build-pie`, `link-obj` | merged symbol map |
| `writeSharedObjectDyn` | `build-so --soname`, `link-so` | its own segment addresses |
| `writeSharedObject` | `build-so` with no soname and no imports | its own segment addresses |

The last two are the ones that were easy to forget. `build-so` has **two**
paths — the SysV-hash writer predates the gnu-hash one — and `link-so` is a
*third* linker. Left alone, `-g` would have produced a `.so` with a line table
and no `.debug_info`, which is exactly the kind of inconsistency a user finds
and a suite does not. All four now carry the sections, laid out **after**
everything that already existed.

## 8. Nothing that exists moves

```
$ sh tests/rebuild-baseline-v0.23.32.sh
OK: 303 pre-existing lines byte-identical; 303 lines total (0 new)
```

The three new sections are numbered after every section that existed before and
written only when `-g` asked for them, so an ordinary build is unchanged byte
for byte. The suite asserts this twice: through the baseline script, and
directly, by comparing `readelf -x .text` of a `-g` build against the same
build without the flag (step 2). This round adds no example, which is why the
row count does not grow.

## 9. Deliberately not included

* **`.eh_frame` / CFA rules.** SP *is* the frame base, so a debugger can print
  locals without them — but it still cannot **walk** a stack.
  `DW_AT_call_frame_info` is absent.
* **Location lists.** An Aster local lives at one slot for its whole life, so a
  single `DW_OP_fbreg` is the whole truth; nothing moves and nothing is
  optimized away (there is no optimizer).
* **`DW_TAG_lexical_block`**, `DW_AT_decl_file` / `DW_AT_decl_column` for a
  variable, and a type DIE for a **function type** — so `let fp: ptr = f;` still
  has no signature a debugger could print.
* **DWARF v5**, and `.debug_str`: this unit's strings are a few hundred bytes
  and go out as `DW_FORM_string`.
* **Line information inside `.debug_info`** beyond `DW_AT_stmt_list = 0`: the
  unit points at the line table, which remains the only place rows live.

## 10. Full CI

```
$ sh tests/ci.sh
=== ... ===
89 passed / 0 skipped / 0 failed
```

One suite is new (`debug-info-checks.sh`); every pre-existing suite passes
unchanged, including `debugline-checks.sh`, which still proves the line table on
its own terms.
