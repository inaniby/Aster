# Aster — Architecture

**As of v0.23.61-dev.** This document is a structural map of the compiler in
`src/aster.cpp` — a single translation unit, and since v0.23.4-dev one that
carries **no signing key of its own**. It is descriptive, not a feature
catalogue: `FEATURE_STATUS.md` is the authoritative inventory of what the
language and toolchain accept. When code and this file disagree, the code wins
and this file is the bug.

## Shape of the system

One C++17 translation unit, ~13k lines, zero dependencies beyond the standard
library. There is no intermediate representation, no assembler, no external
linker: the parser's AST is consumed directly by a code generator that emits
AArch64 instruction words, which an in-process ELF writer serializes. The APK
packager is likewise in-process (ZIP container, binary AXML manifest, PKCS#7
v1 signature plus an APK Signing Block v2 signature, with an in-file
big-integer implementation).

```
source .ast ──► Lexer ──► Parser ──► Codegen ──► ELF images ──► (link) ──► (build-apk)
                  tokens    AST        instr.      ET_EXEC /     merged      ZIP + AXML
                              (Expr,    words +     ET_DYN /      objects     + RSA v1
                               Stmt)    relocs      ET_REL                    signature
```

## Front end

**Lexer** (`class Lexer`) produces a token vector with `line`/`col` on every
token. It handles `//` and `/* */` comments, decimal integer literals (accepted
up to the signed `i64` maximum `0x7fffffffffffffff`, rejected above it), string
literals with `\n \r \t \0 \\ \"` escapes, and rejects non-ASCII source with a
dedicated diagnostic.

**Parser** (`class Parser`) builds the AST:

- `Expr` — Num, Var, String, Call, Index, Deref, Add, Sub, Mul, Div, Neg,
  **Embed** (v0.23.7-dev) and the six comparisons. Comparisons exist only at the
  top of an expression; chaining them (`a < b < c`) is a parse error.
  `@embed_len("path")` never reaches the AST: the parser reads the file, folds
  the length to an `Expr::Num`, and the value is then an ordinary constant —
  which is what lets it be an array bound or a global initializer.
- `Stmt` — Let (scalar or local `T[N]`, any element type since v0.23.28-dev), Assign, IndexAssign, DerefAssign,
  Return, If (with a mandatory `else`), While, For, Break, Continue.
  `for (init; cond; step)` keeps its three clauses as statements so codegen can
  place the step between the body and the back-edge; `break`/`continue` sites
  are patched after the body (while → condition, for → step).
- `Global` / `Function` — globals may be scalars, arrays with `@align(N)`, or
  run-time initializers; functions declare `i32`/`ptr` params and return type.
- `StructDef` / `StructField` (v0.23.5-dev / P3.3) — `struct Name { field: T, … }`
  is parsed into a global table (`g_structs`, `g_structIndex`) and laid out once
  by `layoutStruct()`: each field is aligned to its own alignment and the struct
  is padded to its widest, recursing into nested structs. The definition is
  entered into the table *before* its fields are read, so a field of the same
  struct resolves and is then rejected — a struct cannot contain itself.
  `Expr` gains `Field`, `AddrOf` and `StructLit`; `Stmt` gains `FieldAssign`.
  Globals may also be struct-typed.
- **`@embed` / `@embed_len` (v0.23.7-dev).** The parser owns them, because both
  have to be answered during parsing. `embedFile(path)` resolves the path
  (relative → the source file's own directory, or `--embed-dir`), `stat`s it,
  reads it, and stores the bytes in `embedBlobs` — a `std::map`, deliberately
  not a `std::vector`, because a reference is handed out and a vector would move
  it when it grows. The bytes become a synthetic `Global` with `isString = true`,
  `rawData = bytes` and `align = 1`, named `__aster_embed_N`; repeating a path
  reuses the same symbol, so one file is one copy. `@embed` produces an
  `Expr::Embed` carrying that name and codegen emits `ADRP`/`ADD` + a `MOV` out
  of `x16`, the same shape a string literal uses. `@embed_len` folds to
  `Expr::Num` at parse time. A missing file names both the path written and the
  path resolved; a directory, an empty file and >16 MiB are each diagnosed
  separately.

**Semantic pass** (`struct Sema`, v0.23.0-dev / P3.1) type-checks every emitted
function **before** code generation starts. It walks the AST with its own scope
stack and infers one of ten kinds — `Ty::I32`, `Ty::U32`, `Ty::U8`, `Ty::U16`,
`Ty::I64`, `Ty::U64`, `Ty::Ptr`, `Ty::Bool`, `Ty::Struct`, `Ty::Enum` — for
every expression. A `Ty` is a
`(Kind, sid)` pair: `sid` names the declaration when the kind is `Struct` or
`Enum`, and names the
struct a `ptr<S>` points at, so `ptr<P>` and `ptr<Q>` are different types (the unified lattice
replaced the older scattered `isPtr`/`isBool` booleans in v0.23.2-dev / P3.2):

- a local `T[N]` binds as a `Ptr` carrying its length and element type (its name decays to the
  frame address, exactly as codegen treats the base slot);
- a non-`extern` function name in a value position is its address (`Ptr`);
- `ptr ± i32` stays `Ptr`, `ptr + ptr` and `i32 - ptr` are rejected;
- comparisons, `&&`/`||`/`!`, bool variables/globals and `-> bool` calls are
  `Bool`; everything else is `I32`.

The pass owns the type rules — declarations, assignments, indexing (including
the constant-folded bounds check), dereference, call arity and argument types,
return types, and the `if`/`while`/`for` condition rule — and reports them with
the same diagnostics codegen always did. Codegen keeps its own checks as a
defensive backstop, so a rule can be duplicated but never silently dropped, and
every program that compiled before still compiles to the same bytes. The
observable consequence: a type error is now reported *instead of* a later
codegen diagnostic (e.g. the "may fall through without returning" check, which
codegen runs first), and nothing is emitted for a rejected program.

Constant folding (`constantInteger`) and comparison classification
(`isComparison`) are file-scope helpers shared by both passes, so the two can
never disagree about whether an index folds or an expression is a comparison.

**Run-time bounds checking** (`--bounds-check`, v0.23.1-dev / P1.5) is a
codegen-only concern, so it lives in `Codegen::emitBoundsCheck` and is called
from the three indexing paths immediately after the index expression has been
materialized into a temporary — global read, local-array read, and
`buf[i] = v` (which covers globals and local arrays alike):

```asm
cmp  w_index, #LENGTH   ; SUBS WZR, w_index, #LENGTH — flags only
b.lo skip               ; unsigned < LENGTH: in range
brk  #1                 ; out of range: SIGTRAP
skip:
```

The flag is a `bool` threaded from `main` through `compileProgram` into the
`Codegen` constructor; with it off, `emitBoundsCheck` returns before emitting
anything, which is what keeps a default build byte-identical. Constant indexes
return even earlier (the semantic pass's fold already rejected them if they were
out of range), and `arrayLengthOf` returning 0 — a pointer subscript, or an
array whose extent is unknown here — also skips the test. `x16` is reserved for
base materialization and the test never touches it, so no caller state moves.

## Code generation

`class Codegen` walks each function's AST and appends 32-bit instruction words
to a vector, recording relocations (`R_AARCH64_CALL26` for calls,
`ADR_PREL_PG_HI21`/`ADD_ABS_LO12_NC` pairs for addresses). Conventions:

- **Fixed 8 KiB frame.** Every function starts with `SUB SP, SP, #8192`.
  Scalars occupy one 8-byte slot each (`slot*8` byte offsets); a local
  `i32[N]` array occupies `ceil(N/2)` slots with elements packed 4 bytes apart
  (since v0.23.28-dev a `T[N]` packs `sizeof(T)` bytes per element, so a
  12-byte struct element takes 3 slots each)
  (element `i` at `slot*8 + i*4`). The 500-slot local limit leaves the spill
  area (`[SP, #4080+]`) and nested-call argument scratch (`[SP, #4160+]`)
  untouched. A struct (v0.23.5-dev) occupies `ceil(size/8)` consecutive slots.
  Above the spill area sit the composite return staging buffer (`[SP, #8168]`),
  the saved sret pointer (`[SP, #8160]`), the struct copy scratch, and the
  destination-address park slot — X8, X16 and X17 are all caller-saved scratch, so
  anything a call could clobber lives in the frame.
- **Register discipline.** `x16` (IP0) is reserved for address
  materialization; expression temporaries are `w0`–`w15` with a hard limit of
  16 live values. The return address is preserved at `[SP, #8184]` for
  non-`main` functions. Bases for indexed access are materialized *after* the
  index and value are evaluated, so a call inside an index cannot clobber them.
- **Addressing.** Array and pointer indexes reuse one scaled form,
  `ADD X16, X16, W(index), UXTW #2` — a 4-byte `i32` element stride for global
  arrays, local arrays and `p[i]` alike. Frame bases use `ADD Xd, SP, #slot*8`
  with the `sh` bit clear; the one time this was wrong (v0.22.49-dev) it was
  invisible at slot 0 and corrupted memory at any other slot, so all three
  emit sites now share a source guard.
- **Composites (v0.23.5-dev).** A struct has no register form: it lives in memory
  and is read and written field by field, and moved as a whole.
  `emitStructAddr()` is the single place that answers "where does this struct
  live" (a variable, a field, a global, a `ptr<S>` deref, an aggregate literal);
  `emitStructCopy(dst, src, size)` moves the bytes; `emitStructStore(e)`
  materializes a value into the memory X16 points at — field by field for a
  literal, by copy for anything else. Crossing a call, `layoutArgs()` assigns
  arguments to registers and stack slots, and **both** the caller (`emitCallSeq`)
  and the callee (the prologue in `run`) call it, so the two sides cannot disagree:
  ≤8 bytes takes one register, 9..16 two consecutive ones (returned in `x0`/`x1`),
  and >16 travels as the address of a copy the caller makes in the outgoing area —
  an 8-byte slot even when the argument itself lands on the stack. A >16-byte
  result comes back through the buffer whose address the caller puts in X8; the
  callee parks that pointer on entry and reloads it for the return, because X8 is
  caller-saved scratch and a nested sret call would overwrite it. Stack arguments
  begin at SP+0 as the callee sees it — the copies and the sret buffer have no
  fixed home, so they sit above the stack area.
- **Control flow.** `if/else` compiles to a compare plus one conditional
  branch per arm; `while` and `for` compile to compare / conditional-exit /
  body / step / unconditional back-edge, with `break` and `continue` sites
  back-patched. Exit is `mov x8, #93; svc #0`.

## Images and linking

| Product | Command | Shape |
| --- | --- | --- |
| Executable | `build-elf` | ELF64 `ET_EXEC`, fixed base `0x400000`, `_start` entry |
| Static PIE | `build-pie` / `link-pie` | `ET_DYN` with `PT_DYNAMIC`, `R_AARCH64_RELATIVE` self-relocation, runs at any base |
| Shared object | `build-so` / `link-so` | `ET_DYN` with `DT_SONAME`, `DT_NEEDED` (auto-emitted for known NDK symbols), `DT_HASH` + `DT_GNU_HASH`, `.plt` stubs and `JUMP_SLOT`/`GLOB_DAT` relocations for imports; `--pic` objects supported |
| Relocatable | `link-obj` | merges ET_REL inputs, resolves `CALL26` and address-pair relocations |
| APK | `build-apk` | ZIP (4 KiB-aligned, stored/uncompressed entries) + binary AXML manifest + NativeActivity glue + launcher icon PNG + binary `resources.arsc` (both since v0.23.6-dev, a real multi-type table since v0.23.7-dev) + PKCS#7 v1 (JAR) signature + v2 APK Signing Block (dual-signed since v0.23.3-dev, keyed by a `SigningKey` chosen at build time since v0.23.4-dev); accepts a `.ast` source directly (one-step) or a `.so` (two-step) |
| APK check | `verify-apk` | re-derives the v1 + v2 chain over an existing APK; `build-apk` runs it on the in-memory APK before writing (since v0.23.4-dev) |

**Launcher icon (v0.23.6-dev).** Two namespaces Aster did not have before.
`PNG` encodes a 192×192 image as **bit depth 2, colour type 3** — a three-entry
palette plus a `tRNS` chunk carrying the alpha, so a three-state picture costs
two bits per pixel (9.5 KB) instead of the 147 KB a 32-bit RGBA encoding needs.
`deflateStored()` emits one stored (uncompressed) block per group of 65535
bytes after the `78 01` zlib header, and `adler32()` closes the stream; every
chunk goes through the existing `crc32`. Scanlines use filter 0 (None). `ARSC`
writes the binary resource table: a `ResTable_header` (`0x0002`), a global
UTF-8 string pool, one `ResTable_package` (`0x0200`, id `0x7f`, 288-byte
header), a type pool (`drawable`), a key pool (`ic_launcher`), a
`ResTable_typeSpec` (`0x0202`) and a `ResTable_type` (`0x0201`) whose
`Res_value` is `TYPE_STRING` pointing into the global pool. Three offsets are
what make or break it: `ResTable_type.headerSize` is `20 + config.size` with
`config.size = 56` for the default configuration, `entriesStart` must skip the
per-entry offset array, and string-pool lengths are two-byte varints read as
`((first & 0x7F) << 8) | second`. The manifest then declares `android:icon`
with data type **`TYPE_REFERENCE` (0x01)** — `TYPE_INT_HEX` (0x11) stores the
same 32 bits and looks identical in a hex dump, but only `0x01` resolves. The
icon is not optional and has no flag: a launcher entry with no icon is the
failure this exists to remove.

**Resource table (v0.23.7-dev).** `ARSC` no longer writes "the icon's table", it
writes *a* table. `ARSC::Table` holds `Entry { type, name, value, isFile }` in
insertion order plus `types` in type-id order, and `Table::resId(type, name)`
computes `(0x7f << 24) | ((typeId + 1) << 16) | entryIndex` — so an id in the
manifest is derived from the table instead of being agreed with it by hand.
`build()` emits, per type, one `ResTable_typeSpec` (`0x0202`, size
`16 + 4 * entryCount`) and one `ResTable_type` (`0x0201`, `headerSize = 76`,
`entriesStart = headerSize + 4 * entryCount`), with each entry a
`ResTable_entry` (`size 8`, `flags 0`, key interned in the key pool) followed by
a `Res_value` (`size 8`, `res0 0`, `dataType TYPE_STRING (0x03)`, data interned
in the global pool). **Both entry kinds are `TYPE_STRING` on the wire**; the
difference is what the string *is*: a `drawable`'s value is a path inside the
APK that the framework opens, a `string`'s value *is* the value. `buildApk`
builds the table first and then asks it for `iconResId` and `labelResId`, so the
manifest cannot name a resource the table does not hold. `android:label` names
`string/app_name`, in one of two spellings: a `TYPE_STRING` with the name spelled
out (the default — readable by any consumer, including an APK viewer that never
opens the table) or a `TYPE_REFERENCE` (`--label-as-reference`, what aapt emits,
where the name exists in one place). The reference is written first and the
literal replaces it in place, so the flag is a one-line substitution and nothing
else about the manifest changes. Either way `string/app_name` is in the table and
has to agree with the manifest, which `validate_apk.py` [4d] checks.
`--string NAME=VALUE` (repeatable, validated, duplicate-rejected) appends
further string resources.

**A program that uses both paths (v0.23.7-dev).** `examples/icon_text_demo.ast`
is the worked example of the split: the framework's resources (`drawable/ic_launcher`,
`string/app_name`) go through the table, and the program's own resources — a
48×48 RGBA icon, a 760-byte 8×8 bitmap font, three text lines — go through
`@embed`. The rendering is deliberately separated from the platform:
`render_rgba(pixels, w, h, stride)` is a pure function over a caller-supplied
buffer, and the NDK appears only in `draw_frame` / `ANativeActivity_onCreate`.
That split is what lets `tests/icon-text-host.c` load the `.so` with `dlopen`
and paint the same frame under qemu — the `.so` exports every function, so
`dlsym` finds `render_rgba` directly, and `DT_INIT_ARRAY` has already written
the `@embed` addresses into the globals before the call. Because Aster has no
shift or bit operators, the font renderer tests a bit with division and modulo
(`p = 128 / 2^col`, then `(byte / p) mod 2`), and colours are passed as one
packed `r*65536 + g*256 + b` integer rather than three arguments — the
eight-argument limit makes packing the smaller trade.

**Linking model.** `link-obj`/`link-so` parse ELF objects section by section
(`ParsedObject`), merge `.text`/`.data`/`.bss`/`.rodata` with alignment, and
resolve every pending relocation (`LinkPending`) against the merged symbol
table. Undefined symbols in a shared object become PLT imports with the
matching dynamic relocation; unresolved symbols at link time are errors.

**APK signing.** `rsaSign(hash, key)` implements PKCS#1 v1.5 over an in-file
big-integer (`modExp`) and takes the key as a parameter; the signature is
left-padded to the modulus width (a stripped leading zero used to fail ~1/256
of verifiers — the v0.22.48-dev fix), and `tests/validate_apk.py` asserts that
width structurally on every run. `rsaVerify(hash, sig, n, e)` is its mirror and
is what makes checking possible at all.

**Signing keys (v0.23.4-dev).** A `SigningKey` bundles the RSA halves with the
certificate, its SubjectPublicKeyInfo, and the serial/issuer lifted out of it.
Which key is used is decided once per build and never defaults to a constant:
`--sign-mode debug` takes the project's own key from `<keystore-dir>/.aster/`,
generating it on first use (`generateKey()`: `/dev/urandom`, Miller-Rabin over a
small-prime sieve, then a self-signed X.509 v3 certificate); `--sign-mode
release` requires `--keystore` and `--cert` and **fails closed** without both.
Key material is read as PEM or DER — PKCS#8 or PKCS#1 private keys, X.509
certificates — and every loaded key goes through `keySelfCheck()`, which proves
the certificate carries this key's public half by signing and verifying a probe
before any work is done. Nothing is hardcoded: `src/aster_apk_key.h` is gone.

**APK v2 signing (v0.23.3-dev).** Namespace `APKv2` owns the whole scheme.
`contentDigest()` chunks the three integrity-protected segments — the ZIP entry
region, the Central Directory and the EOCD — into 1 MiB pieces and hashes each
as `0xa5 || uint32 len || chunk`, then the concatenation as
`0x5a || uint32 chunkCount || digests`. `buildApk` builds the EOCD twice through
one `makeEocd(cdOffsetField)` helper: once with the offset pointing at the
Signing Block (the record that gets hashed) and once with the offset the Central
Directory really lands at (the record that gets written). `signingBlock()`
assembles the pairs; `certSubjectPublicKeyInfo()` lifts the public key out of
the certificate with a shared DER walker rather than keeping a second copy.
Because `rsaSign()` is PKCS#1 v1.5 — deterministic — the whole APK is
reproducible, which `tests/apk-checks.sh` asserts with `cmp`.

**APK verification (v0.23.4-dev).** Namespace `Verify` reads an APK back exactly
the way an installer would: `readZip()` finds the EOCD by searching backwards
and cross-checks it against the Central Directory and every local header's CRC;
the v1 stage re-hashes MANIFEST.MF, CERT.SF and verifies the PKCS#7 signature
over `signedAttrs` re-encoded as a SET OF (RFC 5652 §5.4); the v2 stage walks
the Signing Block's ID-value pairs, re-derives the chunked content digest over
entries + Central Directory + EOCD, and verifies the RSA signature over
signed-data. `verify()` is the single entry point both `aster verify-apk` and
`build-apk`'s pre-write self-check call, so an APK Aster produces is checked by
the same code that checks one Aster did not produce.

**Line-number information (v0.23.12-dev, `-g` / `--debug-line`).** Three pieces.
*Collection*: `Codegen` holds `std::vector<LineRow> lineRows`, and the first
thing `execStmt` does — when the flag is on and the statement carries a line —
is push `{code.size(), s.line}`. Because every nested body reaches `execStmt`,
an `if` arm, a loop body and a nested block each get their own rows. `Function`
carries the position of the token that declared it (`fn`, or the `extern` in
front of it), so `run()` pushes one row at instruction 0 for the **prologue** —
without it, stepping into a function would show the body's first line while the
frame setup has already executed. The rows sit beside the instruction stream and
are never consulted by instruction selection; `layoutObject` drops any row whose
instruction index is past the end of its function, because such a row would
point into the next function.
*Encoding*: `encodeDebugLine()` writes a DWARF v4 line program — `version 4`,
`min_inst_length 4`, `default_is_stmt 1`, `line_base -5`, `line_range 14`,
`opcode_base 13` with the twelve standard-opcode lengths, then
`include_directories` and one `file_names` entry naming the `.ast` source and
its directory (1-based into the include list, so the full path resolves without
any `.debug_info`). The program is `DW_LNE_set_address`, then per row
`advance_pc(Δbytes / 4)` / `advance_line(SLEB Δ)` / `copy`, then
`advance_pc` to the end of text and `end_sequence`. Rows with `line == 0` or an
address past `.text` are dropped, and repeated addresses are collapsed — a
zero-length statement must not claim the next one's line.
*Relocation*: an executable knows its own vaddrs and can write them directly; a
relocatable object does not, so each address operand is written as **0** and its
offset recorded as a patch site, and `.rela.debug_line` carries one
`R_AARCH64_ABS64` (257) per site against a local `STT_SECTION` symbol for
`.text`. Both linkers then raise every site to `textVaddr + objectTextOffset`,
which is also why a two-object link produces **one unit per object** rather than
one table spanning both. Every new section is appended after everything already
laid out and its section index is allocated last, so no existing offset or index
moves: `-g` cannot change a byte of code, and an ordinary build takes none of
these paths.

**Declaration sharing (`include`, v0.23.13-dev).** `include "PATH";` is handled
at the top of `Parser::parse()` and does its work in *another* `Parser`: the
included text gets its own instance, constructed with `dirNameOf(full)` as its
`selfDir` so that **its own** `include` lines resolve against *its* directory and
not against the file that pulled it in. That sub-parser is where the design
decision lives — it produces a separate, inspectable list of declarations, and
`mergeIncluded` then decides what of it crosses:

- a function becomes `external` with its **body dropped**;
- a global is rebuilt field by field (a `Global` owns its initializer through a
  `unique_ptr`, so it cannot be copied) carrying only its name, type, array-ness
  and alignment — `external`, with the initializer left behind;
- a global that `@embed` created is **skipped** (`Global::fromEmbed`), because
  those bytes are the business of the file that embeds them.

Both carry `fromInclude=true`, which is what the supersede rule reads: when this
file declares a name that already arrived through an include, `dropIncluded`
removes the included one and this file's own declaration stands. Two
declarations the file wrote itself are still an error — the check only ever
gives way to an included one.

**Cycle detection needs a stack, not a set.** "Have I seen this file?" cannot
tell a cycle from a diamond: a file reached through a cycle is *part-way through
being parsed*, while one reached twice through a diamond is finished. So
`IncludeState` holds both — a `done` set and a `stack` — and is **shared by
reference** with every sub-parser, because the stack has to outlive the
sub-parser that is part-way through it. The order matters too: the cycle check
runs *before* the `done` check, since a file in a cycle is in `done` as well, and
checking `done` first turns every cycle into a silent no-op. (That is exactly
what happened during development: a self-include was accepted without a
diagnostic.)

**Path resolution is build-wide.** `SrcPathOpts` (`--embed-dir`,
`--include-dir`) is published once, *after* the arguments are read, and both
`resolveEmbedPath` and `resolveIncludePath` use it before falling back to
`selfDir`. Publishing before the argument parse is the failure mode to avoid —
it makes both flags silently do nothing.

**Touch input (v0.23.14-dev example; on-device pipeline fixed in v0.23.15-dev).**
`examples/native_touch.ast` is the first interactive native app, and it is
built entirely out of mechanisms that already existed. It writes
`onNativeWindowDestroyed` / `onInputQueueCreated` / `onInputQueueDestroyed`
into the `ANativeActivityCallbacks` slots at offsets **80/88/96** — the +8
cadence after the device-verified window slots at 56/64/72 — attaches the
queue to the thread's `ALooper` with `AInputQueue_attachLooper`, and drains it
in the callback: `getEvent` while the result is **>= 0** (0 is success; a dry
queue returns negative), `preDispatchEvent` (0 = handle now, anything else =
drop this round without `finishEvent`), then `finishEvent` either way.
v0.23.14-dev wired only two slots at 80/88 — but 80 is `onNativeWindowDestroyed`,
so the framework called a window handler as the input handler, and its drain
loop exited on the success code; on a device the app drew its gradient and
ignored every finger. The one place the language surface is stretched is the
coordinate: `AMotionEvent_getX`/`getY` return `float`, which arrives in **s0** —
and an `extern fn … -> i32` return is read from **w0**, a *different physical
register file* (no aliasing exists; v0.23.14-dev's decode captured garbage).
v0.23.15-dev captures it with a bridge: Aster emits no SIMD instruction and the
PLT is eagerly bound, so the `s0` the call leaves behind survives to the next
call, and a zero-argument `lrintf()` issued immediately after (argument in
`s0`, `long` result in `x0`) hands back the exact integer. The two calls must
be adjacent. This is the one compiler change in v0.23.15-dev: `ndkLibraryFor`
maps `lrint*` → **libm.so**, without which the on-device loader aborts
`dlopen`. The NDK symbol map routes `AInputQueue_*` / `AMotionEvent_*` /
`ALooper_*` to `libandroid.so`, so the `.so` needs no manual `--needed`;
`tests/touch-checks.sh` asserts that `DT_NEEDED` (libandroid/liblog/libm/libc)
rather than assuming it. Because the capture is a real function pair,
`tests/touch-coord-test.ast` runs the `strtof` (float out) → `lrintf` (float
in) chain under qemu over nine known values through a dlopened `.so`
(`tests/touch-coord-host.c`), and the suite's mutation layer — breaking the
bridge exactly as v0.23.14-dev did — proves the test can fail.

## Test architecture

`tests/ci.sh` is the front door: one strict build, then the full suite list —
structural, qemu, differential, mutation, coverage and ratchet checks — plus
three independent APK gates. `tests/smoke.sh` is the fast local subset: it
compiles a fixed group of examples and asserts the ELF shape without qemu.
Suite counts are reproducible in two host configurations — default host
toolchain and `HOSTCC=aarch64-linux-gnu-gcc` — documented in `README.md`.

Three mechanisms keep the suite honest off-device:

- `tests/run-aarch64.sh` executes an AArch64 ELF natively on ARM64 hosts and
  under `qemu-aarch64` (with the sysroot when present) everywhere else; host
  binaries pass through untouched.
- `tests/host-toolchain-probe.sh` makes cross-`HOSTCC` e2e suites **SKIP with
  a visible reason** instead of failing when no AArch64-capable compiler is on
  `PATH`.
- Every language feature's check script pairs **source guards** (grep for the
  exact encodings/structures a refactor must not drop) with **qemu
  self-checks** (programs that return 0 only if the feature works), plus a
  rejection matrix for the misuse cases.

Byte-level no-regression claims are proven by frozen per-version baselines
(`tests/baseline/v*/example-hashes.txt`) recording every example's output
modes; an old snapshot is read-only, and a re-record is a reviewed change with
its own evidence.

## Known limitations (carried, not hidden)

- **No typed IR.** The semantic pass infers types on the fly and codegen
  re-derives them: there is no `TypedExpr` carrying its type, so the two
  passes remain a duplicated rule set rather than one source of truth. A typed
  IR is the structural fix the P2 plan names.
- **Bounds checks are opt-in at run time.** Dynamic subscripts are guarded only
  under `--bounds-check` (v0.23.1-dev), including array parameters since
  v0.23.36-dev; constant subscripts are always proved at compile time, and a
  subscript whose extent is unknown (pointer indexing) is never guarded. A
  default build emits no test.
- **The language is integer-only.** There is no floating-point type: `float`
  and `double` cross only the C ABI, through the `s0` bridge used by
  `native_touch.ast`. There is no string *value* (a literal is a `ptr`), no
  heap operator (the `mmap`/`brk` intrinsics are the surface), and no
  variadics, generics, closures or modules beyond `include`.
- **One translation unit.** Lexer, parser, Sema, codegen, ELF writer, linker,
  APK packager and crypto all live in `src/aster.cpp` (~13k lines). That keeps
  the zero-dependency build honest and the whole compiler readable in one file,
  at the cost of a large edit surface; splitting it behind a unity build is a
  P2 item, not a shipped change.
- **Fixed frames, no tail calls.** Every function reserves 8 KiB and recursion
  depth is bounded by the stack; the bootstrap compiler therefore lowers
  expressions with an explicit work stack rather than by recursion.
- **APK signing is v1 + v2.** There is no v3/v4 key rotation and no AAB output;
  releases are signed with the caller's key (or a generated per-project debug
  key), and deterministic PKCS#1 v1.5 keeps builds reproducible. Device-visible
  behavior closes only on hardware (ROADMAP principle 4); the e2e suites need
  qemu or an AArch64 host.
- **The bootstrap subset is deliberately narrower.** M4 reaches a byte-identical
  fixed point (`boot2 == boot3 == boot4`), but `bootstrap/aster.ast` does not
  accept everything the host does — structs, `bool`, `for`, `switch`, `u64`,
  casts and `sizeof` are among the documented omissions. The guard now also
  executes two programs emitted by the self-host under the same runner
  (`return_42`: exit 42; `globals_and_write`: `s1ok`, exit 163), so loadability
  is tested rather than assumed; wider language coverage still comes from the
  differential suite against the C twin. See `bootstrap/CODEGEN-SPEC.md` §11.
