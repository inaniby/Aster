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
`tests/baseline/v0.23.61-dev/example-hashes.txt`. The ten byte-baseline suites
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
- The random certificate serial is trimmed to minimal DER. A serial starting
  `00 00..7F` was legal BER but non-minimal, and OpenSSL rejected the whole
  certificate as `illegal padding`; the 1-in-256 case is now pinned by a
  source guard in `tests/signing-checks.sh` and the suite's `openssl
  asn1parse` check.
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
`tests/baseline/v0.23.61-dev/example-hashes.txt` pass after the refresh.
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
- **P1 test credibility** is addressed in part by Part III: the 0/77/exit-code
  protocol, dependency-probe classification, build-once cache, self-tests,
  frozen per-release baselines, codegen accept/reject and mutation floors, a
  gate-breadth ratchet, an 80% gcov line-coverage floor and an aggregate
  mutation census (24 suites / 155 mutants) are in place. Nightly execution
  remains open.
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
outstanding P1 item (nightly execution) still gates that claim.

---

## Part III — CI trust layer (P1.1–P1.5, floors and ratchet)

The P1 goal is to make a green run mean something. Four mechanisms do that
here: a real exit-code protocol, an environment probe that separates "tool
missing" from "assertion failed", one strict build reused by every suite, and
per-release frozen byte baselines. A fifth change makes the mechanisms
testable: `tests/ci-protocol-checks.sh` is itself a resident suite and also
holds the evidence floors.

### 1. Exit-code protocol (`tests/lib/verdict.sh`)

| code | meaning |
|---|---|
| `0` | PASS — the suite ran and every assertion held |
| `77` | SKIP — the **whole** suite could not run; a `SKIP: <reason>` line is mandatory |
| `1` | FAIL — an assertion failed, or the suite died |

`aster_skip` refuses to skip without a reason (it exits 1 instead), which is
the exact failure mode the protocol exists to stop. `aster_fail` is the
explicit failure path, and `aster_require_cmd` / `aster_require_file` turn a
missing dependency into a reasoned whole-suite skip.

`tests/ci.sh` classifies each suite by its exit code, not by scraping for
words:

- `rc=77` with a reason and a non-critical suite → SKIP.
- `rc=77` without a reason → FAIL.
- `rc=77` in a critical suite → FAIL (clean-machine CI is expected to have the
  toolchain).
- `rc` other than 0/77 → FAIL, with the log tail printed.
- `rc=0` with `PASS` marks and optional `SKIP:` layers → PASS, counted as a
  partial skip.
- legacy `rc=0` with only `SKIP:` lines → SKIP when non-critical, FAIL when
  critical. This keeps old suites honest without silently trusting them.

The default critical list is APK, signing, TLS, linker, codegen, struct,
enum, resource-table, page-size and version checks.

### 2. Environment probe

Before building, the gate probes the tools the suites depend on. Required:
`CXX`, `python3`, `readelf`, `objdump`, `sha256sum`, and qemu-aarch64 (or a
native AArch64 host). Optional and reported without failing: `openssl`,
`llvm-objdump`, `llvm-dwarfdump`, `zip`/`unzip`, androguard, PIL, and an
AArch64-capable `HOSTCC`. A missing required tool exits 2 with a list before
any suite runs, instead of masquerading as a test failure; `CI_ALLOW_MISSING=1`
converts that into a warning and lets the affected suites skip — but a skip in
a critical suite still fails the run.

### 3. Build once (`tests/lib/cxx-cache.sh`)

`tests/ci.sh` builds the strict binary once (`-std=c++17 -O2 -Wall -Wextra
-Wpedantic -Werror`) into `$CI_OUT/aster`, records the SHA-256 of
`src/aster.cpp`, and exports `ASTER_BIN`, `ASTER_SOURCE_HASH` and `REAL_CXX`.
Every suite is then run with `CXX=tests/lib/cxx-cache.sh`. A suite that asks
for exactly `src/aster.cpp` with the allowlisted strict flags receives a copy
of the cached binary; everything else is forwarded to the real compiler:
`-c`, `-g`, `-D`, sanitizers, `-O0`/`-O3`, `-static`, multiple translation
units, no `-o`, a mutated source, or a source hash that no longer matches.

`tests/apk-checks.sh` and `tests/signing-checks.sh` now invoke
`${CXX:-c++}` for their main build, so their compile step is a cache hit when
run through the gate and still uses `c++` when run standalone. Their
mutation-build paths deliberately keep a direct compiler call: the source is
mutated and must never hit the cache.

The cache is conservative on purpose. A false hit would test the wrong
compiler, so the flag set is an allowlist rather than a denylist; only the
documented strict build is served from cache.

### 4. Frozen per-release baselines

The byte baseline used to be one file named `v0.23.5-dev` that every release
edited in place, so a moved byte and a deliberate re-record looked the same in
review, and a version bump could silently keep comparing against the old
release. It is now a frozen snapshot per release:

- The version is read from `ASTER_VERSION_STRING` in `src/aster.cpp`; the
  snapshot is `tests/baseline/v<version>/example-hashes.txt`.
- `tests/lib/baseline.sh` resolves that path and validates every row: known
  mode suffix, `FAILED` or a 64-hex digest, no duplicate keys, and an existing
  `examples/<name>.ast`.
- A version bump without its own snapshot exits 1 with the path and the
  copy-and-re-record instruction. It never falls back to another release.
- All 13 suites that consume the shared baseline source the helper and use
  `BASE=$(aster_baseline_file)`; `struct-checks.sh` uses the same variable for
  its whole-file diff. No suite names a versioned path any more, and
  `ci-protocol-checks.sh` fails if one is reintroduced.
- The pre-freeze file was renamed to `tests/baseline/v0.23.61-dev/`, which is
  what its 360 rows actually describe after eleven rounds of in-place edits;
  it is now immutable. Future releases copy it and re-record only their own
  additions.

### 5. Twin, mutation, coverage and census floors

The codegen differential in `tests/codegen-checks.sh` [5/6] only failed on a
divergence between `tests/codegen-twin.c` and `bootstrap/aster.ast`. A corpus
that lost its accepted programs — or degraded to "both sides reject everything"
— would still report zero divergences and pass: the strongest claim in the
suite would be vacuously true over an empty evidence set.

The differential now asserts a floor on both buckets:

- at least **40 accepted** programs that produce a byte-identical ELF, and
- at least **55 rejected by both** sides.

The floors sit below the current **48 accepted / 78 rejected (126 total)** so
adding or retiring a handful of examples does not require a test edit, while a
lost layer does. They are source constants, not environment knobs: lowering
them is a reviewed change. On violation the suite reports both measured values,
both floors, and the total, then exits 1.

[6/6] already required **every** mutation probe to diverge and counted the
probes; it did not require the set to stay populated. It now also asserts at
least **7 probes** — the current count — so a suite that silently dropped
probes cannot report a perfect score over an empty set.

The same "no vacuous evidence" rule is applied to the gate's breadth in
`tests/ci-protocol-checks.sh`: the suite list parsed from `DEFAULT_SUITES`
must contain at least **115** entries, every `tests/*-checks.sh` must be
registered, every registered name must exist, and the corpus must keep at
least **120 examples**, **360 baseline rows** and **30 mutation-bearing
suites**. This is a test-mass ratchet: it catches a suite that exists but is
never run, or a corpus that quietly shrank.

`tests/coverage-checks.sh` adds the source-line half. It builds
`src/aster.cpp` with `--coverage -O0`, drives a deterministic corpus through
the public CLI — every example in five modes (`build-elf`, `build-pie`,
`build-obj`, `build-obj --pic`, `build-so`), the three link verbs, keygen,
`build-apk`/`verify-apk`, `-g`, `--bounds-check`, `--page-size 16384`, and the
top-level error paths — and requires gcov line coverage of `src/aster.cpp` to
stay at or above **80%**. The measured value is **84.71% of 7526 executable
lines**, and the suite costs about 28 s (12 s instrumented build, 14 s corpus).
gcov is optional: missing gcov is a whole-suite `SKIP` (77), while a gcov that
cannot read the profile fails. The floor is a source constant, so raising the
corpus means raising the floor in the same review.

`tests/mutation-score-checks.sh` turns the scattered kill assertions into one
aggregate view. It censuses the standardized helpers (`mutate`,
`build_mutant`, `mutate_and_check`) across the suites, requires every
declaring suite to keep at least one survivor assertion, and floors the
result at **24 suites / 150 mutant builds / 2 per suite**. The measured
census is **24 suites / 155 mutants**. Because a surviving mutant fails its
own suite, a green gate means the census is also the denominator of a **100%
(155/155) mutation score**; a suite that loses its kill path or its probes
fails the census before the gate can go green. Bespoke mutation layers that
build their mutants by hand are not counted, so the floor is conservative.

### 6. Parallel isolated suites

The gate still defaults to one job, but `CI_JOBS=N` runs N suites at once.
Isolation is a private copy of the tree per suite: the strict binary, `src`,
`tests`, `examples` and the rest are copied into `$CI_OUT/work/<suite>`, the
suite runs there with its own `TMPDIR`, and the copy is discarded. Suites that
write fixed names such as `tmp-g-rw.o` or `tmp-dyn-a.o` into the repository
root therefore cannot collide. Four suites still contain fixed `/tmp/aster-*`
paths (`apk`, `icon`, `resource-table`, `signing`); they are detected by a
`/tmp/` scan and run one at a time after the parallel batches. The cached
compiler and the AArch64 runner stay absolute and shared, so isolation adds
copy I/O but no rebuilds. A copy failure is a suite failure (125), never a
silent skip; `CI_JOBS=0` or a non-integer exits 2; a custom `CI_SUITE_DIR`, a
missing `tar`, or an in-tree `CI_OUT` other than `ci-artifacts` falls back to
one job with a warning. The first four-job full run finished **115/115 PASS**
in **39.5 minutes**, against 64 minutes serial, on a four-core host.

**Clean checkout.** The same four-job gate was run in a fresh
`git clone --depth=1 https://github.com/inaniby/Aster.git` at `ca7059d`,
outside the working tree: **115/115 PASS, 0 skipped, 0 failed**, APK gate 3/3,
two suites with one optional SKIP layer, **37m53s** on the same four-core host.
The clone started with no root `./aster` (it is gitignored), which is the state
a new contributor or a hosted runner sees; `ci.sh` provisioned it from the
strict build, and every suite that invokes `./aster` passed.
`ci-artifacts/work/` was empty after the run. Fetching the doc-only follow-up
(`1ad9e29`) into the same clone and running `version-checks.sh
ci-protocol-checks.sh` through the gate gave **2/2 PASS**, including the new
CMake and line-count guards. This is the clean-machine evidence P1's exit
criterion asks for, short of the hosted nightly schedule that is still blocked
by token scope.

### 7. Observed evidence

`tests/ci-protocol-checks.sh` — **32/32 checks PASS**, covering:

- the three protocol constants;
- skip with reason (77), skip without reason (1), explicit failure (1);
- `require_cmd` / `require_file` passing and skipping;
- cache hit copies the binary and does not invoke the compiler;
- `/dev/null` and `$ASTER_BIN` targets are no-ops;
- misses for `-O0`, `-static`, `-g`, `-c`, `-D`, sanitizer, a different
  source, two translation units, no `-o`, a mutated source, and no cache
  environment;
- baseline resolution from `ASTER_VERSION_STRING`, and rejection of duplicate
  keys, malformed digests, missing examples, missing snapshots and a missing
  version definition;
- no suite may hardcode a versioned baseline path again;
- `CI_JOBS=0` and `CI_JOBS=abc` exit 2 with the validation message before any
  suite runs;
- the coverage ratchet: 115 registered suites, 121 examples, 360 baseline rows,
  33 mutation-bearing suites, no orphan `*-checks.sh`, no missing registered
  suite.

Runner classification was exercised with fixture suites:

| fixture | expected | observed |
|---|---|---|
| PASS + partial SKIP | PASS (partial) | PASS (partial skips: 1) |
| `77` + reason, non-critical | SKIP | SKIP |
| `77` + reason, critical | FAIL | FAIL |
| `77` without reason | FAIL | FAIL |
| `rc=1` | FAIL | FAIL |
| legacy `rc=0` + only SKIP, non-critical | SKIP | SKIP |
| legacy `rc=0` + only SKIP, critical | FAIL | FAIL |
| missing suite file | FAIL | FAIL |

The green-path check (`pass-partial.sh` + non-critical `skip.sh`) exits 0 with
1 passed / 1 skipped. `CXX=/nonexistent/g++` exits 2 at the probe, before the
build.

Focused runs with the new gate (this host, cross `HOSTCC`):

| command | result | wall time |
|---|---|---|
| `CI_SKIP_APK_GATE=1 CI_SUITES="ci-protocol-checks.sh version-checks.sh enum-checks.sh tls-checks.sh"` | 4/4 PASS, first strict build | 2m11s |
| same tree, repeated with two suites | BUILD CACHED, 2/2 PASS | 0.096s |
| `CI_SKIP_APK_GATE=1 CI_SUITES="signing-checks.sh apk-checks.sh"` | 2/2 PASS (compile steps cached) | 39.9s |
| APK gate only (3 demos) | 3/3 PASS | 2.8s |
| diverse subset (protocol, condition, narrow-int-abi, resource-table, embed, icon, debug-info, c-ptr-structural, e2e-c-abi, bootstrap-loop) | 9 PASS + **1 real failure** | first diverse run |
| `ci-protocol-checks.sh signing-checks.sh icon-checks.sh apk-checks.sh` after the fix | 4/4 PASS | rebuild + suites |
| `ci-protocol-checks.sh enum-checks.sh condition-checks.sh struct-checks.sh` with the frozen baseline | 4/4 PASS | rebuild + suites |
| `CI_SUITES="codegen-checks.sh"` with the floor | 1/1 PASS: 48/126 accepted, 78 rejected, floors 40/55; 7/7 mutation probes diverge (floor 7) | fresh strict build + suite |
| same suite with the floors raised to 1000 (negative test) | FAIL at [5/6] with the measured 48 accepted / 78 rejected | suite time only |
| `CI_SUITES="coverage-checks.sh ci-protocol-checks.sh"` | 2/2 PASS: 84.71% of 7526 lines (floor 80%) | 28 s + protocol |
| `coverage-checks.sh` standalone | PASS, same 84.71% | 28.1 s |
| same suite with the floor raised to 95% (negative test) | FAIL: 84.71% below the 95% floor | suite time only |
| `mutation-score-checks.sh` standalone | PASS: 24 suites, 155 mutants; floors 24/150/2 | < 1 s |
| same suite with the mutant floor raised to 1000 (negative test) | FAIL: 155 mutants below the 1000 floor | < 1 s |
| same suite with a fake one-mutant suite (negative test) | FAIL: below the 2-per-suite floor | < 1 s |
| same suite with a fake suite that has no survivor assertion (negative test) | FAIL: declares mutants but has no survivor assertion | < 1 s |
| full default gate, 115 suites (`CI_KEEP_ARTIFACTS=1 sh tests/ci.sh`) | 115/115 PASS, 0 skipped, 0 failed; APK gate 3/3; 2 suites with one optional SKIP layer | 64 min |
| same gate with `CI_JOBS=4` (private worktrees; fixed-`/tmp` suites serialized) | 115/115 PASS, 0 skipped, 0 failed; APK gate 3/3; 2 partial suites; `work/` empty afterwards | 39.5 min |
| fresh `--depth=1` clone of `origin/main` at `ca7059d`, full gate `CI_JOBS=4 CI_KEEP_ARTIFACTS=1` | 115/115 PASS, 0 skipped, 0 failed; APK gate 3/3; 2 partial suites; root `./aster` provisioned; `work/` empty | 37m53s |
| same clone at doc follow-up `1ad9e29`, `CI_SUITES="version-checks.sh ci-protocol-checks.sh"` | 2/2 PASS; CMake and ARCHITECTURE line-count guards green | cached build |
| eight-suite isolated subset (global/object/so-argument/bootstrap-loop/condition/enum/struct/tls) | 8/8 PASS, including the suites that invoke `./aster` | 1m45s |
| four-suite mixed subset (icon has a fixed `/tmp` path) | 4/4 PASS; one suite serialized, three parallel | 1m57s |
| `CI_JOBS=0` and `CI_JOBS=abc` | exit 2 before the probe: `CI_JOBS must be ...` | immediate |
| missing suite under the refactored runner | FAIL, `0 passed, 1 failed`, log kept | suite time only |

The diverse run was the first time the new gate paid for itself. `icon-checks.sh`
failed not because of the cache but because `openssl smime -verify` rejected
the freshly generated certificate with `illegal padding` in `serialNumber`.
The random serial began `00 28 …`: legal BER, non-minimal DER. Aster's own
in-process verifier accepted it; OpenSSL 3 did not. The fix trims leading zero
bytes before `derInt` (Part II §1.6), and `tests/signing-checks.sh` now pins
the trim plus its existing `openssl asn1parse` check. The rerun of the four
affected suites is green. This is exactly the failure class the protocol is
meant to surface: a 1-in-256 flake that a looser gate could have reported as a
green run had the suite swallowed the external-verifier failure.

### 8. Full default gate

The first complete run of the new runner over the then-**113 default suites**
finished **109 PASS, 0 skipped, 4 FAIL** (plus the 3/3 APK gate; two suites
passed with one optional SKIP layer each: `icon-checks` and
`resource-table-checks`). The four failures were test-side staleness exposed
by bundling the whole suite for the first time, not compiler regressions:

| suite | cause | fix |
|---|---|---|
| `integer-cast-checks` | its baseline filter lacked `^enum_demo\.`, so the frozen snapshot's +3 enum rows made it see 291 where it asserted 288 | added the filter (the other 23 filtered families still leave 288) |
| `cast-conversions-checks`, `literals-checks` | same missing filter; both had not yet run when the fix landed and then passed in the same full run | same |
| `so-scope-checks` | the host-side C helper uses `RTLD_DEFAULT` without `_GNU_SOURCE`; glibc hid the symbol under `-Werror` | added `_GNU_SOURCE` to it and to `so-loader-lifecycle-host.c`, which `e2e-so-scope.sh` shares |
| `wide-int-literal-checks` | source guard and mutation M4 still pinned the pre-v0.23.61 deref leaf, which the typed-deref round changed to `if(tyIs64(want)&&elem==Ty::I32)emit(...)` | updated the guard and M4; the index guard now matches the `(uint32_t(d)<<5)` register shape so it still counts the four index leaves, not the deref leaf |
| `include-checks` | mutation 12b's sed target named `full=resolveIncludePath(...)`, but the include refactor now assigns `requested` first and canonicalizes into `full` | retargeted the mutation to `requested=pathTok.s` |

The five affected suites were rerun through the gate: **5/5 PASS**
(`integer-cast`, `wide-int-literal`, `include`, `so-scope`, `e2e-so-scope`).
This is the second time the trust layer paid for itself: the full run found
three tests that had silently kept pre-enum/pre-refactor assumptions, which
the focused runs could not see because each suite ran against a different
snapshot of the tree.

The follow-up complete run, with every fix in place, finished **113/113 PASS,
0 skipped, 0 failed** (APK gate 3/3; the same two suites kept one optional
SKIP layer each). That run is the first fully green execution of the complete
default gate under the new protocol, cache, frozen baselines and evidence
floors.

`coverage-checks.sh` was added after that run, taking the default set to
**114**. It was validated standalone and through the gate alongside the
protocol self-checks: **2/2 PASS**, coverage 84.71% of 7526 lines against the
80% floor, 28 s. The first complete run of the resulting gate then finished
**114/114 PASS, 0 skipped, 0 failed** in 62 minutes, with the APK gate 3/3 and
the same two suites each keeping one optional SKIP layer.

`mutation-score-checks.sh` then took the set to **115**. It was validated
standalone and through the gate with the protocol self-checks (**2/2 PASS**:
24 suites, 155 mutants), and three negative runs failed as expected — the
mutant floor raised to 1000, a fake one-mutant suite, and a fake suite with
no survivor assertion. The first complete run of the 115-suite gate finished
**115/115 PASS, 0 skipped, 0 failed** in 64 minutes with the APK gate 3/3 and
the same two partial suites. This is the current release-candidate evidence.

### 9. What is still open in P1

- **Nightly execution and governance** remain. A clean `--depth=1` clone runs
  the four-job gate **115/115** (37m53s), so the gate no longer depends on the
  maintainer's tree, but there is still no scheduled workflow in the
  repository: the workflow is ready on a local branch and the fine-grained
  token lacks the `workflow` scope to push it. `LICENSE`, `CONTRIBUTING`,
  `SECURITY` and release tags are still open.
- **Bespoke mutation layers** that build their mutants by hand do not yet
  join the census. The standardized corpus is 24 suites / 155 mutants with
  floors 24/150/2, and a green gate means 155/155 caught; the hand-built
  layers still report kills only inside their own suites.
