# Security Policy

Aster is a self-hosting AArch64 compiler: it reads untrusted source files,
emits ELF objects, links them, and can sign and verify APKs. A defect in the
compiler, the linker, or the APK verifier can turn an innocent-looking
program into a wrong binary, so security reports are treated as defects in
the compiler itself, not as support requests.

## Supported versions

Only the current development line is supported. If you are on an older
`v0.23.x-dev`, reproduce against `main` first — the version string is
`ASTER_VERSION_STRING` in `src/aster.cpp`.

| Version | Supported |
| ------- | --------- |
| `main` (`v0.23.80-dev`) | Yes |
| Older `v0.23.x-dev` | No — please re-test on `main` |

## Reporting a vulnerability

Do **not** open a public issue for a vulnerability. Instead, open a private
report through the repository's security advisory flow (GitHub: **Security →
Report a vulnerability**), or email the maintainer if that flow is
unavailable. Include:

1. The exact Aster version (`aster --version` or `ASTER_VERSION_STRING`).
2. A minimal `.ast` program (or ELF/APK input) that reproduces the problem,
   plus the exact command line used.
3. Expected vs. actual behaviour: exit code, output bytes, or the verifier
   verdict you expected.
4. Whether the input came from an untrusted source in your scenario
   (a `.ast` file, a `.o` handed to `link-obj`, an APK handed to
   `verify-apk`).

We will confirm receipt, reproduce with a control case, and keep you
informed until a fix lands. Public disclosure should wait until the fix is
in `main` and a patched version is tagged.

## What counts as a vulnerability here

- **Silent miscompilation**: a program whose emitted code computes a
  different value than the language semantics say (wrong constant folding,
  a spill that lands in another function's frame, a tag collision that
  shadows a declaration). These are the highest-severity reports.
- **Linker / ELF parser memory safety**: an out-of-bounds read or write
  while parsing an untrusted `.o` or `.so` (DWARF, relocations, symbol
  tables). A reproducer plus an AddressSanitizer trace is the ideal report:
  build with `g++ -std=c++17 -O1 -g -fsanitize=address
  -fno-omit-frame-pointer src/aster.cpp` and run with
  `ASAN_OPTIONS=detect_leaks=0`.
- **APK verification bypass**: an APK that `verify-apk` accepts but that
  does not match its signature, manifest, or `--expect-sha256` anchor.
- **Build / cache integrity**: a cache entry, project file, or temporary
  file that lets one build influence another (predictable temp names,
  symlinked paths, unsanitised project names). `aster doctor` and the
  `build/.cache` layout are in scope.
- **Denial of service in the compiler itself**: an input that makes the
  compiler loop or exhaust memory without a diagnostic (unbounded
  recursion in the parser is guarded; a reproducer that escapes a guard
  is a report).

Out of scope: vulnerabilities in the programs Aster compiles (those belong
to the program's author), and issues that need a malicious local user who
can already write to the build directory.

## Hardening already in place

- The compiler builds with `-Wall -Wextra -Wpedantic -Werror`; no warnings
  are tolerated.
- Atomic file writes (`writeFileAtomic`: `mkstemp` + `O_EXCL` + `fsync` +
  `rename`), unpredictable temp names (`mkTempPath`), and a sanitised
  project name.
- `tests/ci.sh` is the regression gate: a suite that exits 0 without a
  `PASS`/`OK` line, or a skipped APK gate without an explicit allow flag,
  fails the run. Every fix in this project ships with a resident suite
  that includes a mutation layer — an edit that removes the fix must be
  caught.
