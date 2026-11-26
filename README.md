# Aster Bootstrap Compiler v0.23.82-dev

Aster is a self-hosting compiler for AArch64: one C++17 program that reads
Aster source and directly emits AArch64 machine code and ELF files — no
assembler, no system linker, no LLVM, no libc in the generated program.
Generated code talks to the kernel with raw SVC system calls. The language
is bilingual: the same compiler accepts Chinese and English source
(`build-cn-obj`, `--language zh|en`), with Chinese command aliases for the
project commands.

## Quick start

Build the compiler (strict build, no warnings):

```sh
g++ -std=c++17 -O2 -Wall -Wextra -pedantic src/aster.cpp -o aster
```

Hello world — `hello.ast`:

```rust
fn main() : i32 { return 42; }
```

```sh
./aster build-elf hello.ast -o hello
qemu-aarch64 ./hello; echo $?   # 42 (on an AArch64 host, run ./hello directly)
```

Scaffold a project instead of a single file:

```sh
./aster new myapp && cd myapp
./aster build        # build the project (aster.proj)
./aster run          # build and run it
./aster test         # run the project's tests
```

## Commands

| Command | What it does |
| --- | --- |
| `build-elf SRC -o OUT` | Fixed-address AArch64 `ET_EXEC` executable (link base `0x400000`) |
| `build-pie SRC -o OUT` | Static PIE (`ET_DYN`, no interpreter, no dynamic section) |
| `build-obj [--pic] SRC -o OUT.o` | Relocatable `ET_REL` object (`--pic` for linking into a `.so`) |
| `build-so SRC -o OUT.so` | Shared object (SysV `DT_HASH` + GNU `DT_GNU_HASH`) |
| `link-obj / link-pie / link-so` | Link `ET_REL` objects into an executable, a static PIE, or a `.so` |
| `build-apk INPUT -o APP.apk` | Installable Android APK from a `.so` or directly from `.ast` |
| `keygen` | Generate the project's RSA debug key + self-signed certificate |
| `verify-apk APP.apk` | Check an APK's own v1 + v2 + v3 signatures |
| `new / add / build / run / test` | Scaffold, register sources, build, run, and test a project |
| `doctor` | Check the host and the current project |
| `build-cn-obj` | Compile bilingual (Chinese/English) source to an object |
| `pack / complete` | Build the standard-library package / complete package symbols |
| `pkg install\|upgrade\|list\|remove` | Install and manage packages from a local directory or Git |
| `fmt / deps` | Format Aster source / emit make rules for `include`/`@embed` inputs |

`build-apk` signs with one of two keys, never with a key baked into the
compiler: `--sign-mode debug` (default) uses the project's own key in
`.aster/` (generated on first use), `--sign-mode release` requires your
`--keystore` + `--cert` and fails without them. Every APK is verified in
memory before it is written, and is v1 + v2 + v3 triple-signed by default.
Run `./aster` with no arguments for the full usage text, including the
Chinese command aliases.

Common flags: `-g` / `--debug-line` emits DWARF v4 `.debug_line`,
`.debug_info` and `.eh_frame` (off by default; an ordinary build emits
byte-for-byte what it always did); `--bounds-check` traps on an out-of-bounds
array index at run time (`BRK #1`, off by default); `--page-size 4096|16384`
selects the load-segment alignment (16384 for Android 15+ 16 KiB-page
devices).

## Key features

- **Direct code generation.** One compiler, one code generator: the ELF
  writer, the linker, the APK packager and the v1/v2/v3 signer are all
  Aster's own code. There is no subprocess and no external toolchain.
- **Bilingual source.** Chinese and English keywords, diagnostics and
  standard-library documentation in one compiler, selected per file
  (`--language`, file declaration, `aster.proj`, default zh).
- **A real language, not a toy subset.** Structs (by value, AAPCS64),
  enums, `fn` types and callbacks, multi-dimensional arrays, `ptr<T>`
  with strides, TLS and symbol versioning, `include`, `@embed` /
  `@embed_len`, `switch`, labeled `break` / `continue`, and a standalone
  semantic pass that rejects a bad program before any code is emitted.
- **Packages.** The standard library ships as a versioned package
  (`aster pack`); projects declare dependencies in `aster.proj` and
  install them with `aster pkg`, with manifest-hash and version checks
  and a lock file (`packages/.aster-pkg-sources`).
- **Android, first class.** `build-apk` emits a NativeActivity APK with a
  generated `resources.arsc`, a self-encoded launcher icon and
  triple-signed v1+v2+v3 signatures — no Java/Kotlin, NDK, aapt, d8 or
  Gradle. See [docs/TERMUX.md](docs/TERMUX.md) for building and verifying
  on a phone.
- **Self-hosting.** The bootstrap compiler in `bootstrap/` is written in
  Aster itself (lexer, parser, semantic pass, code generation); the
  standard library in `stdlib/` is pure Aster with no libc.
- **Debuggable output.** Every final product carries a source-level
  symbol table (`.symtab` + `.strtab`), so `readelf -s`, `nm` and
  `objdump -t` name source functions and globals; `-g` adds DWARF.

## Language at a glance

Top-level declarations are `include "path.ast";` (declarations only),
`struct Name { field: T, … }`, `enum Name { A, B = 7 }`, scalar and array
globals with optional `@align(N)`, `tls [extern] let`, `extern let`, and
`[extern] fn`. The types are `i32`, `u32`, `i64`, `u64`, `u8`, `u16`,
`bool`, `ptr`, `ptr<T>`, `ptr<S>`, `fn(P, …) : R`, a struct, and an enum.
Statements cover `let`, assignment (including `+=` and `++`/`--`),
`return`, `if` / `else if` / `else`, `while`, `for`, `switch` (Pascal
semantics: a match self-ends), labeled loops, and bare call statements.
Expressions cover integer, character and string literals, `@embed`,
calls (including typed function pointers and `h.onClick(…)` field calls),
indexing (`a[i]`, `a[i][j]`, rows), field access (auto-dereferencing
through `ptr<S>`), `&` / `*`, pointer arithmetic, casts `T(x)`,
`sizeof` / `len`, and `?:`. Arithmetic wraps at its operand width;
division by zero and signed division overflow are unchecked, and codegen
does not optimize. The full rules are in
[docs/language-reference.md](docs/language-reference.md).

## Project structure

| Path | What lives there |
| --- | --- |
| `src/aster.cpp` | The compiler: one C++17 translation unit, `src/aster.cpp` is 32,184 lines with no dependencies beyond the standard library |
| `stdlib/` | The standard library, written in Aster (`aster_std.ast`) |
| `bootstrap/` | The self-hosting compiler, written in Aster (lexer → parser → semantic pass → codegen) |
| `examples/` | Example programs, including the Android `native_activity`, `native_render` and `native_touch` demos |
| `tests/` | The test suites (`*-checks.sh`, e2e suites, frozen baselines under `tests/baseline/`) |
| `docs/` | Maintained documentation: language reference, architecture, roadmap, feature status, history, audits, validation reports |
| `logs/` | The original version-by-version log moved out of this file (see below) |

## Testing

```sh
./tests/smoke.sh     # curated quick subset
./tests/ci.sh        # one-command full gate (see below)
```

The gate enforces an exit-code protocol: **0 = PASS**, **77 = the whole
suite could not run** (a `SKIP: <reason>` line is mandatory), and anything
else = FAIL. The gate now runs **173** suites — the count in
`DEFAULT_SUITES` in `tests/ci.sh` — and `tests/coverage-checks.sh` floors
`src/aster.cpp` line coverage at **80%**. `tests/mutation-score-checks.sh`
censuses the standardized mutation corpus — 41 suites declaring 254 mutant builds — and a green gate reports **254/254 caught**.
The e2e suites
execute generated AArch64 binaries natively on an ARM64 host and under
`qemu-aarch64` elsewhere (`HOSTCC=aarch64-linux-gnu-gcc` for the
cross-compiled harnesses).

## Documentation

| Document | What it answers |
| --- | --- |
| [docs/language-reference.md](docs/language-reference.md) | The lookup tables: reserved words, operators, precedence, grammar, quotas — every rule checked against the binary |
| [docs/language-spec.md](docs/language-spec.md) | The language grammar and semantics, feature by feature |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | How the compiler is built: pipeline, frame/register conventions, image formats, signing, test architecture |
| [docs/FEATURE_STATUS.md](docs/FEATURE_STATUS.md) | What exists today (and since when), what is planned, what is out of scope |
| [docs/ROADMAP.md](docs/ROADMAP.md) | Where the project is going: planned versions, backlog, deliberate non-goals |
| [docs/SELFHOSTING-PLAN.md](docs/SELFHOSTING-PLAN.md) | The self-hosting bootstrap plan (M0–M5) |
| [docs/VERSION_HISTORY.md](docs/VERSION_HISTORY.md) | What actually shipped, version by version (condensed history) |
| [docs/audits/](docs/audits/) | Full source audits (`AUDIT-v*.md`) |
| [docs/validations/](docs/validations/) | Per-release verification reports (`VALIDATION-v*.md` — evidence, not claims) |
| [docs/TERMUX.md](docs/TERMUX.md) | Building and verifying the icon + text demo **on a phone**, in Termux |
| [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md) | How to contribute: the release-bump procedure, the impl → tests → docs rule |
| [docs/SECURITY.md](docs/SECURITY.md) | How to report a security issue |

## Version history

The per-version log that used to fill this file now lives in
[logs/](logs/) (the original wording, grouped by version range — see
[logs/README.md](logs/README.md) for the version index). The condensed,
maintained history is [docs/VERSION_HISTORY.md](docs/VERSION_HISTORY.md);
each release also has its own verification report in
[docs/validations/](docs/validations/).

## License

Apache License 2.0 — see [LICENSE](LICENSE).
