# VALIDATION-v0.23.70-dev — `union`

**Version:** `0.23.70-dev` · **Theme:** close the fifth and last language gap in
`AUDIT-v0.23.61-dev.md` part 3 · **Compiler:** `src/aster.cpp` (13,723 lines,
single C++17 translation unit) · **Gate:** 127 suites, 0 failed, APK 3/3.

The audit's five gaps were `typedef` (1), `const` (2), `void` (3), `char` (4),
`union` (5), to be closed in that order. v0.23.67 / .68 / .69 closed the first
four; this round closes the fifth. Its prescription was to reuse the struct
layout and only overlap the offsets, for C header interop. That is what shipped:
a union stays a `Ty::Struct`, distinguished by one `StructDef::isUnion` bit.

## 1. Strict build and the generated-table contract

| Check | Result |
| --- | --- |
| `g++ -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp` | PASS |
| `python3 bootstrap/gen_lexer_names.py --check` | PASS |
| `python3 bootstrap/gen_parser_names.py --check` | PASS |
| Quoted version literal `"0.23.70-dev"` in `src/aster.cpp` | exactly 1 |
| `./aster --version` | `Aster bootstrap compiler v0.23.70-dev` |

`bootstrap/gen_lexer_names.py` is the source of truth: `TOKENS` 82 → 83,
`KEYWORDS` 31 → 32, both appended at the end so no existing ordinal moves. The
generator refreshed `bootstrap/aster.ast` (`K_Union = 82`, `ident_is("union")`)
and `tests/lexer_names.h` (`TK_COUNT 83`, `KW_COUNT 32`, `TK_Union`,
`{ "union", TK_Union }`). `check_list()`'s two hard-coded counts were updated
to 83 / 32; a miss would have `die()`d.

## 2. Implementation, by the code that carries it

| Piece | Change |
| --- | --- |
| Declaration | `structDeclaration(bool isUnion)` is the shared parser; `void structDeclaration(){ structDeclaration(false); }` keeps the struct entry point and its source guard unchanged. `parse()` adds `if(eat(TK::Union)){structDeclaration(true);continue;}`. Six diagnostics now say `union` for a union and are byte-for-byte the old words for a struct. |
| Layout | `layoutStruct` takes an early `if (s.isUnion)` branch: `f.offset = 0` for every member, `align = max(tyAlign(f.ty))`, `size = round_up(maxFieldSize, align)`. Overflow names `*widest`, not `fields.back()`. The original struct loop and `s.fields.back()` are untouched. |
| Literals | `checkStructLit`, `structConstantImage` and `emitStructStore` each fork their value count to exactly one for a union. The constant image stays `std::vector<uint8_t> raw(sd.size, 0)`, so the tail is zero by construction. |
| Run-time zeroing | Inside `emitStructStore`, **only** `if (sd.isUnion)` emits `storeAtT(31, 17, b, Ty::I64/I32/U16/U8)` over the whole object before the single member store. `reg = 31` is XZR/WZR. Struct codegen never reaches it. |
| Array rule | `structHasArrayField` checks only `fields.front()` for a union, so an array in a later member cannot block a literal. |
| DWARF | `kAbbrUnion = 15`, a `{kAbbrUnion, 0x17, 1, …}` entry **unconditionally** in `defs[]`, `typeRef` selects `sd.isUnion ? kAbbrUnion : kAbbrStruct`, and `tests/debuginfo-decode.py` learns `0x17: "UNION_TYPE"`. |

**Zero-change list** (inherited, deliberately untouched): `Ty::ofStruct`,
`tySize` / `tyAlign`, `sizeofTypeValue`, `elemShiftOf`, `tyName`,
`structBaseId` / `structFieldOf`, `emitStructAddr`'s `if (f->offset)` gate,
all AAPCS64 aggregate classification, `tyAssignable`, `initializerFits`,
`caseValueFits`, `castConstValue`, and `kTypeExpected`.

## 3. The nine-layer suite `tests/union-checks.sh` [9/9]

| Layer | Evidence |
| --- | --- |
| [1/9] Strict build | `-Wall -Wextra -pedantic -Werror`, clean |
| [2/9] Source guards | **24** guards: `bool isUnion = false;`, `structKindName`, `void structDeclaration(bool isUnion){`, `s.isUnion=isUnion;`, the no-arg forwarder, the `TK::Union` dispatch, the lexer chain, `Union };`, `if (s.isUnion) {`, `f.offset = 0;`, `tooLarge(*widest,size);`, the first-member array branch, `union literal for`, both `want` forks, `raw(sd.size,0)`, `storeAtT(31,17,b,Ty::I64)`, `const size_t n=…`, `kAbbrUnion=15`, the defs entry, the `typeRef` selection, plus the decoder's `0x17`, `TK_Union` and `K_Union` in the generated files, and a Python assertion that `KEYWORDS` is 32 words with `union` present and `tls` absent |
| [3/9] Independent reader | A C `main` links Aster's `fn pack(i32) -> U` / `fn widen(U) -> i64` from a `build-obj --pic` object with `-static`, under qemu exits **0**; `u.q == 5` proves both the 8-byte return path and the upper-four-byte zero fill. A pure-C mirror also exits 0 |
| [4/9] gcc differential | **6** cases, each an `.ast` and a `.c`, compared by exit status only: `union_zerofill`, `union_overlap`, `union_punning`, `union_size_align`, `union_struct_field`, `union_param_ret` — all exit 0 on both sides |
| [5/9] Refusals | **13** exact messages: 0 values, 4 values, field type mismatch, empty union, duplicate field, self containment, duplicate declaration, global/function name conflict, first-field array, `is too large`, non-literal global init, literal in an `i32` slot. Plus a **positive** control: an array in a non-first member does not block a literal |
| [6/9] Example vs twin | `examples/union_layout.ast` and `tests/union-layout-twin.c` both exit **0** |
| [7/9] Coverage | guards ≥ 15 (24), refusals ≥ 10 (13), differential ≥ 6 (6), mutants ≥ 6 (6) |
| [8/9] Mutations | **6**, each applied by `sed`, confirmed to hit with `cmp -s`, rebuilt under `-w`, and witnessed without touching any `return`: (a) declaration bit → `U { 5 }` flips BUILD→REJECT; (b) `checkStructLit` value-count fork → `U { 1, 2 }` flips REJECT→BUILD; (c) XZR→X0 → product sha256 differs; (d) first-member-only array rule → flips BUILD→REJECT; (e) union layout branch → product sha256 differs; (f) DWARF tag → `-g` sha256 differs and the decoder's `UNION_TYPE` DIE disappears |
| [9/9] Byte baseline | The three `union_layout` rows reproduce exactly, with output basenames `<example>.<mode>` (a `build-so` basename lands in `.dynstr`, so a different name changes the hash) |

## 4. Semantic evidence

`examples/union_layout.ast` (and its C twin) verify, in order: `sizeof(U) == 8`
and `sizeof(Box) == 16`; `U { 0x11223344 }` leaves `u.q == 0x11223344` (upper
four bytes zeroed, little-endian) and `u.lo == u.c == 0x44` (overlap at offset
0); `u.q = 0x1122334455667788` makes `u.w == 0x55667788` and `u.lo == 0x88`
(type punning); `Box { 7, U { 9 } }` reads back `tag == 7` / `u.w == 9`;
`boxTag(b) == 16` exercises a 16-byte two-register aggregate argument; and
`id(U { 5 })` / `make(11)` exercise the 8-byte one-register parameter/return
path. Both programs return 0.

`-g` decoding of the example yields `UNION_TYPE name=U byte_size=8` with four
`MEMBER` children, every one at `data_member_location=0`, and
`STRUCTURE_TYPE name=Box byte_size=16`.

## 5. Zero byte drift

`tests/baseline/v0.23.70-dev/example-hashes.txt` is **375 rows**: the 372 rows
of v0.23.69-dev plus three `union_layout` rows. Two independent suites confirm
the pre-existing bytes did not move:

- `alias-const-checks.sh`: `pre-existing rows unchanged    372`
- `elf-metadata-checks.sh`: `baseline rows reproduced       375`

`struct-checks.sh` [4/8] and `debug-info-checks.sh` also pass unmodified,
confirming the struct diagnostics are byte-for-byte the old words and that the
unconditional abbrev entry does not disturb the main (non-`-g`) baseline.

## 6. Realignment and registration

| Item | Change |
| --- | --- |
| Version guards | 11 suites × 2 lines `0.23.69-dev` → `0.23.70-dev`; the two history comments in `char-checks.sh:6` and `tls-checks.sh:38` are left alone |
| Reserved words | 4 suites `== 31` → `== 32` plus their printed strings |
| Baseline row counts | 13 suites `291` → `294` (both assertions each), 2 suites `372` → `375`; every FILTER left untouched |
| `tests/ci.sh` | `union-checks.sh` added to both `CRITICAL` (17 → 18) and `DEFAULT_SUITES` (126 → 127) |
| Docs | `CMakeLists.txt`, `README.md`, `VERSION_HISTORY.md`, `FEATURE_STATUS.md`, `ARCHITECTURE.md`, `ROADMAP.md`, `docs/language-reference.md` (§2/§5/§5.4/§8), `AUDIT-v0.23.61-dev.md` |

## 7. Gate

```
LC_ALL=C CXX=g++ HOSTCC=aarch64-linux-gnu-gcc bash tests/ci.sh
```

127 suites, **0 failed**, APK 3/3. `version-checks.sh` and `git diff --check`
both clean. Three commits in the project's order: **impl → tests → docs**,
then `git push origin main`.
