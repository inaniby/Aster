# Validation — v0.23.10-dev

**Semantic errors point at the line too (P4.1 completion).**

The question that started this release: *v0.23.9-dev draws a caret under parser
errors — so why does `unknown variable: missing at 2:12` still print one bare
line?* Because only the parser had a source position to give: the AST nodes
carried none, so the semantic pass — where a type error is actually detected —
could only fall back to a single-line message. This release threads source
positions through the AST itself, and every semantic diagnostic now renders the
same way a parse error does: `file:L:C: error: <message>`, the source line, and
a `^` under the exact column.

---

## What changed, and what did not

- **Added:** `line`/`col` fields on every `Expr` and `Stmt` node, filled by the
  parser at construction time from the token that *introduces* the node.
- **Added:** one helper `loc(line, col, msg)` that appends ` at L:C` — or
  returns the message unchanged when `line == 0`, which is how a genuinely
  location-less error stays compact.
- **Touched:** every throw site in the semantic pass (`Sema::check*`) and in the
  global-declaration path (`foldConst`, `structConstantImage`,
  `structDeclaration`, `globalDeclaration`, `letStatement`) now routes through
  `loc()`. **No diagnostic string was edited** — the suffix is appended, never
  substituted — so the message text every `grep -F` assertion matches
  (`type mismatch initializing 'b': expected bool`, `unknown variable: x`, …)
  is printed verbatim, exactly as before.
- **Touched:** the version constant (`kVersion` line 24, `kUsage` line 3878).
  **No code-generation path was modified**, so every emitted ELF / `.so` / APK
  payload from a successful compile is byte-identical to v0.23.9-dev; semantic
  errors abort compilation, so the caret renderer cannot change an artifact.

## Where each node takes its position

| node kind | position source |
| --- | --- |
| `Num` / `String` / `Embed` / `Var` | the literal or identifier token |
| `Deref` `*` / `AddrOf` `&` / `Neg` `-` / `Not` `!` | the operand expression |
| `Call` / `Index` | the callee / array-name token |
| `Field` | the field-name token after `.` |
| binary `Mul`/`Div`/`Add`/`Sub`/cmp/`&&`/`||` | the left operand |
| `Let` / `Assign` / `IndexAssign` / `FieldAssign` / `DerefAssign` | the leading token (`let`, name, `*`) |
| `If` / `While` / `For` / `Return` / `Break` / `Continue` | the statement's keyword token |
| struct-literal field values, call arguments, array index | the value expression itself |

The rule is uniform: a node points at the text that introduces it, and an error
raised *about* a sub-expression points at that sub-expression.

## The regression this release survived

The first cut of the parser changes moved each child into its parent
(`z->a = std::move(x)`) and *then* read the child's position
(`z->line = x->line`) — reading a moved-from `unique_ptr`, i.e. a null
dereference. Six sites crashed the compiler with SIGSEGV, and they crashed it
on **valid programs**: `*` (deref), `&` (address-of), `-` (negate), `!` (not),
and the two assignment-target statements. A negative literal, a `!`, a `*p = v`
— all of them took the compiler down.

The strict rebuild was clean and `diagnostics-checks.sh` passed, because
neither exercises a unary prefix. **It was `tests/ci.sh` that caught it**: nine
suites segfaulted (bool, struct, sema, wide-int, array-bounds, local-array,
runtime-bounds, linker, object) plus both APK gates. The fix was to read the
position *before* the move (or from the new owner afterwards), verified by a
full scan of every `std::move(` site in the file.

This is the third release in a row where the one-command CI gate earned its
keep: a change can compile warning-free, pass its own focused suite, and still
be broken.

## The diagnostics regression test, step by step

`tests/diagnostics-checks.sh` (6 checks, builds `aster` with `-Werror` first):

1. **Message preserved.** A located parse error still contains its original
   text (`integer literal is too large at 1:27`).
2. **Source line echoed.** The offending line is printed back.
3. **Caret aligned.** The script reads the column from Aster's own
   `file:1:27:` prefix and asserts the `^` sits at `4 (indent) + col - 1`
   spaces — column-agnostic, so it verifies alignment rather than a hardcoded
   number.
4. **Multi-line.** An error on line 2 reports line 2 and realigns.
5. **Semantic caret (new).** `let ok: bool = 5;` must print the original
   `type mismatch initializing 'ok': expected bool` text, echo line 2, and
   align `^` to the column Aster itself reports — the same alignment rule as
   check 3, so it works for any column.
6. **Compact fall-through (new).** `fn main() -> i32 { let x: i32 = 1; }` has
   no per-node location (the error is about the function as a whole) and must
   print exactly one line.

## Evidence

| Stage | Result |
| --- | --- |
| Strict build (`-Werror`) | zero warnings, `BUILD OK` |
| `tests/diagnostics-checks.sh` | PASS (6/6) |
| `tests/ci.sh` (full gate) | **43 passed, 23 skipped, 0 failed** (of 66 checks), exit 0 |
| APK gate (inside `ci.sh`) | `native_render` PASS, `icon_text_demo` PASS (`validate_apk.py` + `verify-apk`) |
| Delivered APK rebuild | `icon-text-demo.apk` rebuilt with v0.23.10-dev and re-verified: `validate_apk.py` ALL CHECKS PASSED, `aster verify-apk` OK (v1 + v2) |
| Exit status | 0 |

The 43/23/0 result matches the v0.23.9-dev baseline exactly: the same suites,
the same verdicts. The 23 skips are the e2e C-ABI suites, which self-skip on
the x86_64 sandbox by design and run for real on an AArch64 runner. The first
full run of this gate **failed** — nine suites plus both APK gates segfaulted
on the moved-from-`unique_ptr` bug described above; after the fix the identical
command ends green, which is the regression being closed here.

## Byte-level A/B against v0.23.9-dev

The v0.23.9-dev `aster` was rebuilt from the delivered zip and both compilers
compiled every `examples/*.ast`:

- **40 examples** build standalone under both versions; **all 40 ELF outputs
  are byte-identical** (`cmp` clean, 0 differing).
- The remaining 44 sources are not standalone-buildable by design (extern
  split declarations, `.so` part files, the three NativeActivity demos, and
  the C-ABI fixtures that need an external symbol); both versions reject them
  identically, so they are not part of the comparison.
- Semantic errors abort compilation, so the caret renderer cannot reach an
  emitted artifact; the only source-level changes a *successful* build could
  observe are the version banner and the APK manifest's `Created-By` line.

## Regression proof

- **Strict compile:** `g++ -std=c++17 -O2 -Wall -Wextra -pedantic -Werror
  src/aster.cpp -o aster` → no warnings.
- **Code generation:** unchanged from v0.23.9-dev; the only source deltas are
  the version constant and the location fields (which no codegen path reads).
  Successful-compilation artifacts remain byte-identical.
- **Diagnostics:** semantic errors (`unknown variable`, `type mismatch`,
  `assignment to unknown variable`, out-of-bounds, `!` on an i32, …) now render
  the source line and caret; the message text each `grep -F` assertion matches
  is unchanged.

## How to see it

```sh
# A semantic error now shows the line and a caret, like a parse error:
$ printf 'fn main() -> i32 {\n  let x: i32 = 1;\n  return y;\n}\n' > /tmp/t.ast
$ ./aster build-elf /tmp/t.ast -o /tmp/t
aster: /tmp/t.ast:3:10: error: unknown variable: y at 3:10
      return y;
             ^
```

And an error with no per-node location stays on a single line:

```sh
$ printf 'fn main() -> i32 { let x: i32 = 1; }\n' > /tmp/t2.ast
$ ./aster build-elf /tmp/t2.ast -o /tmp/t2
aster: error: main may fall through without returning i32; add a return or make both if/else branches return
```

## How to run the gate

```sh
sh tests/ci.sh                                  # full gate, HOSTCC probed from host arch
HOSTCC=aarch64-linux-gnu-gcc sh tests/ci.sh      # force real e2e on an AArch64 runner
```
