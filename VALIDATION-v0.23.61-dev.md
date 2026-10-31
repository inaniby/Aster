# Validation — v0.23.61-dev (enumerations and audit hardening)

**Compiler:** `src/aster.cpp` (`ASTER_VERSION_STRING "0.23.61-dev"`), built
`g++ -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror`.

This release contains two independent workstreams: the `enum` language
feature and an adversarial-audit correctness/security hardening round.
Both were validated on the same source tree; each keeps its own change
summary and evidence below.

---

## Part I — Enumerations (`enum Name { … }`)

This part documents the nominal, `i32`-backed enumeration type, its
type rules, and the dedicated `tests/enum-checks.sh` suite.

### 1. The change

| Aspect | Behaviour in v0.23.61-dev |
| --- | --- |
| Declaration | `enum Name { A, B=20, C }` — auto-increment from `0`, explicit `= value` (any `constantInteger`-foldable integer, so `= -1` works), trailing comma allowed, **≥1 enumerator required** |
| Enumerators | Named `i32` constants. `primary()` rewrites an enumerator `Ident` into a `Num` of its value (flagged `enumConst`) *before* any other interpretation |
| Nominal isolation | `enum Color` ≠ `enum Dir` even at equal values. `enum<->enum` needs the same `sid`; `enum <- i32` only from a fitting **constant**; `i32 <- enum` is free; everything else refused |
| Storage | 4 bytes, align 4 — `sizeof(Color) == 4`. `tySize`/`tyAlign` land on `default: 4` |
| Integer-like | `tyIsInteger` includes `Ty::Enum`, so an enum value is a legal `if`/`while` condition (zero vs non-zero) and a legal arithmetic/comparison operand alongside `i32` |
| Debug info | DWARF `DW_TAG_enumeration_type`, `DW_AT_byte_size 4`, `DW_AT_type_encoding 0x05` (signed) |

#### Why nominal, not C-loose

C lets any two enums and their underlying `int` mix freely. Aster makes the enum
type **nominal**: `enum Color { Red }` and `enum Dir { North }` are distinct
types even though both hold `0`. The conversion matrix (enforced in
`tyAssignable`'s new enum branch, resolved right after the identity
short-circuit and ahead of the `Ptr`/`Bool` gates):

| Assignment | Result |
| --- | --- |
| `enum<same>  ←  enum<same>` | allowed (`to.sid == from.sid`) |
| `enum E  ←  i32 constant` | allowed **only** if `initializerFits` (e.g. `let c: Color = 99;` fits; `let c: Color = Red;` is the constant `0`) |
| `enum E  ←  i32 variable` | **refused** — a variable is not a compile-time constant |
| `i32  ←  enum E` | **free** — an enum value is already `i32` |
| cross-enum, `enum ← ptr/bool`, `ptr ← enum` | **refused** |

This also closed a latent gap: `checkStmt`'s `Let` and `Assign` scalar integer
paths had previously bypassed `tyAssignable` and only scatteredly rejected
`ptr`/`bool`. A cross-enum assignment (`let a: Color = greenFromOther;`) and an
`i32` variable into an enum (`let c: Color = someVar;`) therefore slipped
through. Both paths now route the enum case through `tyAssignable`.

#### Type-system and codegen edits (all pinned by `tests/enum-checks.sh` `[2/9]`)

- **Lexer / token:** `enum` is a new keyword (`TK::Enum`), rejected as an
  identifier like the other type names.
- **`Ty::Kind`:** a new `Enum` is inserted *immediately before* `Struct` — the
  `enum Kind { I32,` prefix and `Struct };` suffix are pinned by the struct
  suites' source guards, so the insertion point is load-bearing for those guards.
  `Ty` carries its enum id in `sid`; `Ty::ofEnum(id)` mirrors `ofStruct`.
- **`tyIsInteger`** gains `|| t.k == Ty::Enum`; **`tyName`** answers
  `enumNameOf(sid)` for an enum; **`parseType`** resolves an `Ident` against
  `g_enumIndex` after the struct index.
- **`primary()`:** an `Ident` naming an enumerator folds to `Expr::Num` (value,
  `enumConst=true`) before the call/paren branch — so `Red + Green` is integer
  addition, `Red == Green` an integer comparison.
- **`tyAssignable`:** the enum branch above. **`checkStmt`:** `Let`/`Assign`
  scalar paths route enum cases through `tyAssignable`.
- **`enumDeclaration()`:** mirrors `structDeclaration()`'s name-conflict check,
  parses `{ Enumerator (= constant)? , … }`, auto-increments from `0`, folds
  negative constants through `constantInteger`, range-checks
  `[-2147483648, 2147483647]`, populates `g_enumConsts`, and requires ≥1
  enumerator.
- **DWARF (`typeRef`):** `case Ty::Enum: nm=enumNameOf(t.sid); size=4; enc=0x05;`.

---

### 2. The test suite — `tests/enum-checks.sh` (9 layers)

| Layer | What it proves |
| --- | --- |
| `[1/9]` strict build | the compiler builds under `-Werror` |
| `[2/9]` source guards | `enum` is pinned in the source (10 greps: `TK::Enum`, the `Kind` insertion, `tyIsInteger`, `tyAssignable` branch, `enumDeclaration`, DWARF `0x05`, the three `0.23.61-dev` version guards, the `Enum` insertion point) |
| `[3/9]` qemu witnesses | 9 programs each returning a **distinct** exit code: auto-increment (`Blue==2`), explicit (`South==20`), negative (`-West==1`), enum→i32 free (`2`), i32-const→enum (`5`), arithmetic (`5`), sizeof (`4`), comparison (`7`), distinct enums equal (`1`) |
| `[4/9]` gcc differential | `examples/enum_demo.ast` exits `255`, equal to its C twin `tests/enum-demo-twin.c` |
| `[5/9]` rejection matrix | 5 refusals, each with its exact compiler message: cross-enum init, i32 variable → enum, out-of-range enumerator, duplicate enum name, duplicate enumerator |
| `[6/9]` coverage | the 9 behavioural shapes are all exercised (count ≥ 9) |
| `[7/9]` mutation layer | 2 mutants, each losing exactly one rule and caught by a named case: `m1` removes `|| t.k == Ty::Enum` from `tyIsInteger` → an enum value as an `if` condition is refused; `m2` removes the free `enum→i32` → assigning an enum into an `i32` is refused |
| `[8/9]` byte baseline | the 288 pre-existing rows reproduce byte for byte; the 3 `enum_demo.*` rows are recorded (the 10 byte-baseline suites gained `^enum_demo\.` filters; the three whole-baseline suites balance the new rows) |
| `[9/9]` example e2e | `examples/enum_demo.ast` runs under qemu and returns `255`, equal to the C twin |

#### Observed run (this round)

```
[3/9] qemu: enum, every witness
  auto-increment: Blue == 2              2
  explicit values: South == 20           20
  negative: -West == 1                   1
  enum -> i32 is free                    2
  i32 constant -> enum                   5
  enum arithmetic                        5
  sizeof(enum) == 4                      4
  enum comparison                        7
  distinct enums, same value, compared   1
[5/9] Rejection matrix  PASS: the rejection matrix holds
[7/9] Mutation layer
  enum-as-condition under tyIsInteger    caught
  enum -> i32                            caught
[8/9] Byte-identity baseline
  pre-existing rows byte-identical       288
  new example rows recorded              3
[9/9] The example, end to end  enum_demo.ast  255
=== enum checks: ALL PASSED ===
```

---

### 3. Byte-identity baseline

The enum round adds one example, `examples/enum_demo.ast`. Its three build modes
(`build-so`, `build-elf`, `build-obj --pic`) are recorded in
`tests/baseline/v0.23.5-dev/example-hashes.txt`. The ten byte-baseline suites
exclude `enum_demo.*` via `^enum_demo\.` filters (so the pre-existing **288**
rows stay byte-identical), and the three whole-baseline suites
(`condition`/`null-ptr`/`struct-checks`) compare the new rows directly.

One correction during validation: the originally-recorded `enum_demo.build-so`
hash was computed with a throwaway output filename; because a shared object
embeds its output filename into the dynamic string table, that hash was stale.
It was recomputed with the suite's own output name (`enum_demo.build-so`) and
the baseline now matches the compiler's deterministic output byte for byte
(`548cb5e8…`). This is a **test-harness** correction only — the compiler's
`build-so` output is deterministic once the output path is fixed, as every
other example already proves.

---

### 4. Coverage of every enum shape

Each behavioural row below is exercised by at least one `[3/9]` witness or
`[5/9]` refusal:

| Shape | Exercised by |
| --- | --- |
| auto-increment enumerators | `Blue == 2` |
| explicit `= value` | `South == 20` |
| negative explicit value | `-West == 1` |
| enum → i32 (free) | `enum -> i32 is free` (2) |
| i32 constant → enum (fits) | `i32 constant -> enum` (5) |
| enum arithmetic (folded consts) | `enum arithmetic` (5) |
| `sizeof(enum) == 4` | `sizeof(enum) == 4` (4) |
| enum comparison | `enum comparison` (7) |
| distinct enums, equal value, compared | `distinct enums, same value, compared` (1) |
| cross-enum assignment refused | `[5/9]` cross-enum init |
| i32 variable → enum refused | `[5/9]` i32 variable → enum |
| out-of-range enumerator refused | `[5/9]` enumerator out of i32 range |
| duplicate enum name refused | `[5/9]` duplicate enum name |
| duplicate enumerator refused | `[5/9]` duplicate enumerator |

---

### 5. Conclusion

`enum` ships as a nominal, `i32`-backed enumeration: enumerators are real `i32`
constants that fold into the existing integer machinery, the type is isolated by
`sid` so cross-enum and `i32`-variable-into-enum assignments are refused, `i32 ←
enum` is free, and size/condition/arithmetic semantics all fall out of
`tyIsInteger` including `Ty::Enum`. The suite exercises every shape, refuses the
five illegal programs with their exact diagnostics, and the two mutants each lose
exactly one rule and are caught. The pre-existing **288** byte-baseline rows are
unchanged, and `examples/enum_demo.ast` agrees with its C twin (exit `255`) under
both gcc and qemu. Evidence: `tests/enum-checks.sh` `[9/9]` and
`examples/enum_demo.ast` / `tests/enum-demo-twin.c`.


---

## Part II — Correctness and security hardening

This part documents the P0 findings from the adversarial audit: codegen
widths, type and constant rules, front-end limits, untrusted APK input,
linker hardening, crypto/key handling, and the regression evidence.

### 1. What changed

#### 1.1 One width rule in codegen (W1)

- Call-clobbered temporaries are saved and restored at their real width. A
  `STR W`/`LDR W` round-trip no longer truncates an `i64`, a pointer, a
  syscall argument or the buffer address passed to the `write` builtin; those
  use `STR X`/`LDR X`. The width is chosen from the temporary's type at every
  spill site, not guessed at the call.
- A struct return stores exactly `tySize` bytes. The previous unconditional
  8-byte `STR X` could overwrite a neighbouring field for a 4-byte struct and
  write 1–7 bytes past the end for sizes 9–15.
- `u8`/`u16` returns are truncated at the return boundary, so a value such as
  `u8(200) + 100` is 44 in the caller, not 300.
- Dereference and assignment derive their load/store width from the pointee
  type: `LDRB`/`LDRH`/`LDR`/`LDRSW`/`LDR X`, `STRB`/`STRH`/`STR`/`STR X`.
  `ptr<u8>` writes one byte, `ptr<i64>` reads eight, and a `ptr` (untyped)
  keeps its historical 32-bit view.

#### 1.2 Type rules and constants (W2, W3)

- Global assignment reuses the local pointer rules: `g = &x` into an integer
  and `g = 12345` into a `ptr` are rejected, and the initializer path applies
  the same rule.
- `u32` literals are bounded to 32 bits; narrow assignment/index/cast
  conversions have an explicit policy rather than silent truncation.
- `INT64_MIN / -1` and `INT64_MIN % -1` in constant initializers produce a
  diagnostic/defined result; zero divisors are rejected; array dimension,
  element-count and byte-size limits are checked before allocation; oversized
  dimensions such as `[311][642][541][835]` and seven-dimensional `1000^7`
  are rejected without a crash.

#### 1.3 Front-end robustness (W4)

- Syntax recursion is capped at 256 (`expression`, `statement`), and
  expression/Sema/constant-folding/codegen walks at 2048, turning a stack
  overflow into a diagnostic.
- `include` resolves a canonical path and detects cycles with the chain in the
  message.
- 20,000-deep parentheses, 20,000 unary operators, 5,000 nested blocks and
  3,000 nested `if`s all return diagnostics (exit 1), not signals.

#### 1.4 Untrusted APK/ZIP input (W5)

- `readZip` checks every central-directory name against its local header
  byte-for-byte, rejects names containing NUL, `\`, an absolute path or `..`,
  and bounds every offset/length against the file.
- `verify-apk` requires the v1 manifest to cover every payload entry, fails
  closed on a compressed entry whose digest it cannot verify (rather than
  silently skipping it), consumes every v2 signer sequence completely, and
  enforces size/count limits.
- `build-apk` validates the package name (segments, 127-byte ceiling), ABI
  (`[A-Za-z0-9_-]{1,64}`), library name (`[A-Za-z0-9_.-]{1,255}`, not `.`/`..`),
  rejects `--string` names that collide with the built-in `string/app_name`
  or `drawable/ic_launcher`, rejects duplicate resource entries at
  `ARSC::Table::add`, and rejects duplicate or unsafe ZIP entry names at the
  writer.

#### 1.5 Linker (W6)

- Relocation addends are applied with explicit signed overflow/underflow
  checks; `ADD_LO12` is only accepted for type 277 and every other relocation
  type is rejected by name.
- `__aster_tls_block` must be unique, name `.tdata` or `.tbss`, sit at offset
  0 and span the whole thread-local section. Input objects carrying
  `R_AARCH64_TLS_TPREL64` are rejected with a clear message (Aster emits its
  own local-exec sequence).
- One `.eh_frame` CIE per link is enforced; a differing CIE is a hard error.
- Section alignment is a power of two between 1 and 65536.
- `_start` must be a function defined in `.text`.
- Layout is `.data | .tdata | .tbss | .bss` in the static ELF writer and in
  both shared-object writers. With TLS present, `.bss` is no longer written to
  the file: a TLS object with a 4 MB `.bss` produced an 8,808-byte static ELF
  and a 13,608-byte `.so`.

#### 1.6 Crypto and key handling (W7, W8)

- BigInt `divmod` no longer takes the one-limb fast path with an unsafe index;
  shifts by zero and oversized counts are handled.
- RSA keys below 2048 bits are refused; keygen accepts only 2048/3072/4096.
- Debug keys are written through `mkstemp` with mode 0600 (no predictable
  temp name, no follow-through symlink).
- AXML/ARSC lengths are encoded as UTF-16 code units with overlong-sequence
  and surrogate rejection; 200-byte Chinese labels encode correctly.
- CLI integers are parsed with `from_chars` and bounded
  (`--version-code` 0..2100000000, SDK levels 0..2147483647, `--page-size`
  0..16384); `--version-code -1`, `99999999999999999999` and
  `--target-sdk abc` exit 2 with a diagnostic.
- `android:debuggable` is false unless `--debuggable` is given.

#### 1.7 Version single source (P1.8)

`ASTER_VERSION_STRING`, `kVersion`, the usage banner, the three test pins
(`literals-checks.sh`, `integer-cast-checks.sh`, `cast-conversions-checks.sh`),
`CMakeLists.txt`, README, VERSION_HISTORY, FEATURE_STATUS, ROADMAP and this
report all name `0.23.61-dev`.

---

### 2. Evidence

#### 2.1 Strict build

```
g++ -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp
BUILD OK   (zero warnings; banner: Aster bootstrap compiler v0.23.61-dev)
```

#### 2.2 Targeted regression suites

| Suite | Result |
|---|---|
| `tests/tls-checks.sh` | PASS |
| `tests/signing-checks.sh` | PASS |
| `tests/resource-table-checks.sh` | PASS |
| `tests/eh-frame-checks.sh` | PASS |
| `tests/linker-checks.sh` | PASS |
| `tests/page-size-checks.sh` | PASS (4 KB / 16 KB, all verbs + APK ZIP offset) |
| `tests/pie-so-checks.sh` | PASS |
| `tests/so-dyn-checks.sh` | PASS |
| `tests/gnu-hash-checks.sh` | PASS |
| `tests/relro-checks.sh` | PASS |
| `tests/icon-checks.sh` | PASS |
| `tests/codegen-checks.sh` | PASS |
| `tests/apk-checks.sh` | PASS |
| `tests/smoke.sh` (meta-runner) | PASS (rc=0) |

Specific witnesses:

- Multi-object TLS static link (`a.o` + `b.o`) runs under qemu and returns 33;
  PT_TLS has `filesz=0x14`, `memsz=0x14`.
- TLS + 4 MB `.bss`: static ELF 8,808 bytes and `.so` 13,608 bytes (the file
  contains no `.bss` payload); the `.bss` section and its symbols sit inside
  the RW `PT_LOAD` at `0x402004`, and the program runs to 3.
- Malformed TLS marker (duplicate, wrong section, non-zero offset, wrong size)
  and `R_AARCH64_TLS_TPREL64` input are each rejected with a named diagnostic.
- `_start` as a `.data` object: `error: ... _start must be a function defined
  in .text`.
- Differing `.eh_frame` CIE: `error: ... .eh_frame CIE differs from the first
  input object; this link supports one CIE`.
- `--abi "../../../data"`, `--libname "../x"`, `com..x`, `com.9x`, `x`,
  `com.x-y` and a 200-character package each exit 2; `com.X9_z` builds.
- `--string app_name` and `--string ic_launcher` are rejected as collisions.
- A ZIP whose local header name disagrees with the central directory and a
  name containing NUL are both rejected by `verify-apk`.
- A stored-manifest APK with a compressed payload entry is rejected with
  `MANIFEST.MF digest for ... cannot be verified`, not silently accepted.

#### 2.2.1 The six silent-miscompile reproductions

Each case is built with the strict binary and executed under qemu-aarch64.

| Case | Expected | Result |
|---|---|---|
| `i64` live across a call (`4294967296 + one()`) | exit 0 | exit 0; disassembly uses `str x0`/`ldr x0` |
| 4-byte struct return into `Outer.s`, neighbour `o.j` | exit 0 | exit 0; `mk` stores exactly one `str w0, [x17]` |
| `u8` return `u8(200) + 100` compared to 44 | exit 0 | exit 0; `uxtb w0, w0` before return |
| `u16` return `2 + 65535` compared to 1 | exit 0 | exit 0; `uxth w0, w0` |
| `*ptr<i64>` reading `4294967296` | exit 0 | exit 0; `ldr x0, [x0]` |
| global `g = &x` where `g: i32` | diagnostic | exit 1, names the pointer-to-integer assignment |
| `let x: u8 = 300` | diagnostic | exit 1, literal does not fit |

#### 2.2.2 A generator bug found by the new checks

Tightening the object reader exposed two real writer bugs that the old tests
could not see because nothing read the writer's own output strictly:

- A global whose type was 24 bytes long got `sh_addralign=24` (the writer used
  `max(natural alignment, tySize)`). 24 is not a power of two. The section
  alignment now comes from the type's natural alignment only, and the reader
  rejects anything outside `1..65536` that is not a power of two.
- In the static ELF writer, the TLS block's end was tracked as a file offset
  but then used as a virtual address: `.bss` landed at `0x2004` instead of
  `0x402004`, outside its `PT_LOAD`. Addresses now add `base`; sizes subtract
  the segment's file offset. `tests/tls-checks.sh` [4/9] now asserts that a
  TLS block followed by a 4000-byte `.bss` keeps both the section and its
  symbol inside the RW `PT_LOAD`.

#### 2.3 Sanitizers (W9)

Built with
`g++ -std=c++17 -O1 -g -fsanitize=address,undefined -fno-sanitize-recover=all`.

| Corpus | Inputs | Sanitizer/crash reports |
|---|---|---|
| `examples/*.ast` through `build-elf` | 120 (64 are standalone programs; 56 are link-only, shared-object or host-style examples) | 0 |
| Generated syntax corpus (`tests/fuzz-gen.py`) | 300 | 0 |
| Mutated/truncated/random `.o` through `link-obj` | 650 | 0 |
| Mutated/truncated/targeted-corruption APK through `verify-apk` | 800 | 0 |
| Deep/malformed sources (20k parens, 20k unary, 5k blocks, 3k ifs, 7-D `1000^7`, include cycle) | 9 | 0 (all exit 1 with a diagnostic) |
| `keygen --bits 2048`, `build-apk`, `verify-apk` | 1 APK | 0 |

`--bits 512` exits 2 with `--bits must be 2048, 3072 or 4096`; a 2048-bit
keygen, a dual-signed APK build and its verification all complete under
ASan+UBSan with no report.

#### 2.4 Suite matrix

A full `tests/ci.sh` run was started, but each suite rebuilds the 12,000-line
compiler for its mutation layer; the audit recorded the same multi-hour cost.
The full gate was therefore not used as the final oracle. Instead every suite
that covers a changed subsystem, and every suite that compares against the
byte baseline, was run individually:

`tls-checks`, `signing-checks`, `resource-table-checks`, `eh-frame-checks`,
`linker-checks`, `page-size-checks`, `pie-so-checks`, `so-dyn-checks`,
`gnu-hash-checks`, `relro-checks`, `icon-checks`, `codegen-checks`,
`apk-checks`, `comment-checks`, `version-checks`, `address-of-checks`,
`global-checks`, `narrow-int-abi-checks`, `struct-checks`,
`struct-array-field-checks`, `switch-checks`, `integer-cast-checks`,
`cast-conversions-checks`, `condition-checks`, `array-address-checks`,
`array-elem-types-checks`, `multi-dim-array-checks`, `null-ptr-checks`,
`sizeof-len-checks`, `literals-checks`, `precedence-checks`, `fuzz-checks`.

On the hardening branch, all 32 targeted suites passed. The twelve
baseline-bearing suites are included, so the refreshed hashes are exercised
end to end rather than only by a hash script.

The repository's own `tests/smoke.sh` was then run as a single end-to-end
gate and exited 0. It executed 25 suites, including several not in the
targeted matrix (`error-checks`, `object-checks`, `so-negative-checks`,
`pixel-offset-checks`, `array-bounds-checks`, `local-array-checks`,
`pointer-index-checks`, `for-loop-checks`, `bool-checks`, `sema-checks`,
`runtime-bounds-checks`, `wide-int-checks`, `embed-checks`), and ran the
`apk`, `signing`, `struct`, `icon`, `resource-table`, `relro`, `gnu-hash`,
`so-dyn`, `pie-so`, `linker`, `global`, `comment` suites again on the final
source. Five host-compiler-dependent scripts (`e2e-so-import`,
`e2e-so-negative`, `e2e-c-ptr-index`, `e2e-c-struct`,
`icon-text-demo`) printed SKIP because this runner has no AArch64-capable
host `cc`; `resource-table-checks` additionally skipped its optional
androguard cross-check. Nothing failed.

After rebasing the hardening commit onto the `enum` commit, the combined tree
was rebuilt with the same strict command, `tests/enum-checks.sh` passed all
nine layers, `tests/smoke.sh` again exited 0 with the same 25 suites and the
same five host-compiler skips, `tests/tls-checks.sh` passed all nine layers,
and a direct replay of the baseline recipe reproduced all **360** rows byte
for byte (the 357 rows of the audit round plus the three `enum_demo.*` rows).

The full run itself did find one genuine test bug: `comment-checks.sh` used
`llvm-objdump`, which is not installed on this runner, and reported the missing
tool as "the commented program did not compile". It now runs the produced
binary through `tests/run-aarch64.sh` and asserts the exit status, so the check
is behavioural and tool-independent.

#### 2.5 Byte baseline

The width and layout fixes deliberately change the machine code of examples
that exercise them (a typed `i64` dereference now emits `LDR X`, a spill uses
`STR X`, and the `sh_addralign`/`PT_LOAD` layout is corrected). 65 of the
357 rows present before this round moved; all 65 were regenerated from the
fixed compiler and the unchanged rows were left byte-identical. The merged
baseline now has 360 rows because the `enum` round added three, and all 360
reproduce byte for byte. The twelve suites that compare against
`tests/baseline/v0.23.5-dev/example-hashes.txt` pass after the refresh.
Every changed example's behavioural layer passes as well, so the new bytes
are not blessed on the strength of a hash alone.

#### 2.6 Sanitizers, final source

The sanitizer build was repeated after the two writer fixes above, on the
hardening source before rebasing onto `enum`; the combined tree was then
covered by `enum-checks`, `smoke` and the full baseline replay.

| Corpus | Inputs | Reports |
|---|---|---|
| `examples/*.ast` | 120 (66 standalone images) | 0 |
| Generated syntax corpus | 300 | 0 |
| Malformed APK through `verify-apk` | 800 | 0 |
| Mutated/truncated `.o` through `link-obj` | 650 | 0 |
| Deep/malformed sources | 9 | 0 (diagnostics) |
| `keygen`, `build-apk`, `verify-apk` | 1 APK | 0 |

---

### 3. Remaining known limitations

- **v1 verification of compressed payload entries** fails closed instead of
  decompressing (the verifier supports stored entries only). An APK that
  compresses a payload is rejected, not accepted unverified; deflate support
  would remove the limitation.
- **Weak symbol definitions** are refused explicitly; weak semantics
  (resolution preference, zero initialisation of unresolved weak references)
  are not implemented.
- **P1 test credibility** is only partially addressed: the version single
  source is fixed, but the 0/77/exit-code protocol, dependency-probe
  classification, frozen per-version baselines and mutation score reporting
  remain open. `tests/ci.sh` still classifies a suite as SKIP from its log.
- **P2/P3** (module split, typed IR, bootstrap M5, fuzzing targets, product
  direction) were not part of this round.

---

### 4. Conclusion

The six silent-miscompile classes are covered by code-level fixes and
qemu/regression evidence; the audit's four memory-safety reproductions
(`verify-apk` central-directory read, relocation addend wrap, parser depth,
BigInt/APK hardening) no longer reproduce and the sanitizer corpora report
zero errors. The version is now single-sourced at `0.23.61-dev`. This round
does not claim production readiness: the remaining limitations above, and the
P1 signal-quality work, still gate that claim.
