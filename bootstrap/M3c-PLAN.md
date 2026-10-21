# M3c Planning — the semantic / type-check pass

> **Status:** contract **frozen** for v0.23.45-dev in `bootstrap/SEMANTIC-SPEC.md`
> (13 sections, mirroring `PARSER-SPEC.md`), written *before any semantic code*
> — the same discipline that caught two real bugs in M3b. This memo is the
> rationale; the spec is the source of truth.
>
> **Round framing (unchanged):** M3c is a no-compiler-change round. The only
> edit to `src/aster.cpp` is the version constant. `bootstrap/aster.ast` gains
> a semantic pass; the host compiler is untouched.

## 0. Where M3c sits

`SELFHOSTING-PLAN.md` M3 pipeline: **lex → parse → type check → generate
AArch64 bytes → write ELF**. M3a shipped lex, M3b shipped parse + AST dump, M3c
is the **type-check** stage. The tree M3b emits (40 node kinds over seven
parallel `i32` arrays) is exactly what M3c reads — the plan's own shape held
again: each stage needs no compiler change, only the previous stage's output.

M3c's artifact is **still not an executable**: it is a validation gate. Like the
host's `Sema` (which runs ahead of `gen` and emits nothing visible), M3c checks
the tree and either re-emits the same AST dump or reports a semantic error. The
*executable* output is M3d's job (codegen + ELF). M3d will re-walk the AST and
build its own type tables — the host keeps `Sema` and `gen` separate for exactly
this reason, so the type-derivation logic is shared by re-derivation, never by
an intermediate format.

## 1. The observable output (the key decision)

- **Success:** a byte-identical **AST dump** to M3b — same `Kind line:col`
  format, same one-line-per-node shape. Rationale: M3c is a *pure checker* this
  round. Re-emitting the same dump keeps all 312 existing `parser-checks.sh`
  PASS lines green (every pinned example and diagnostic is well-typed and
  semantically valid), and makes the round minimal and testable. No output
  format changes → no blast radius on the frozen contract.
- **Failure:** a **semantic error** on stderr —
  `aster: <file>:<line>:<col>: error: <message>` — exit status 1, **empty
  stdout**. Same format as the parser's `P`/`B` errors, new catalog `S1`–`Sn`.
- **Two-phase rule (inherited from M3b §10):** nothing is written to stdout
  until the dump completes; a semantic error leaves stdout byte-empty, exactly
  like a parse error.

Consequence: M3c's *new* observable behaviour is the **rejection** of programs
that M3b accepted but that are ill-typed. The validation corpus is anchored on
those rejections, plus the unchanged accepts (which must stay byte-identical).

## 2. Type-system subset

The parser (M3b `PARSER-SPEC.md` §2.4, §11) emits only a narrow set, and
`bootstrap/aster.ast` **uses only five types** (measured, not assumed):

| type | occurrences in `bootstrap/aster.ast` | in `stdlib/aster_std.ast` |
|---|---|---|
| `i32` | 405 | 33 |
| `i64` | 14 (+2 returns) | 7 |
| `u8` | 5 | 0 |
| `ptr<u8>` | 18 | 20 |
| `ptr` | 4 | 0 |

`bool`, `u16`, `u32`, `u64` and `struct` are **rejected by the parser as out of
subset** (`bootstrap/aster.ast:2113` — *"struct declarations are not in the
bootstrap subset"*; §2.4's `ptr<i32>`/`ptr<i64>` tags exist but are unused by
Aster's own source).

**Decision:** M3c validates exactly `{i32, i64, u8, ptr, ptr<u8>}` (and the
unused `ptr<i32>`/`ptr<i64>` tags, which cost nothing extra to accept). It is
*structurally* ready to admit `u16`/`u32`/`bool`/`struct` later, but exercises
only the subset — because the parser will not hand M3c such types without a
parser change, which is a different theme and is **deferred**. The frozen
`SEMANTIC-SPEC.md` pins precisely this set.

## 3. What the semantic pass does (checklist → becomes the S-catalog)

A single iterative walk over the AST sibling chains (no deep recursion — same
8KB-frame discipline as the parser), in source order:

1. **Top-level scope build** — collect every `fn` / `let` / `extern fn` /
   `extern let` into the global symbol table; reject duplicate top-level names;
   record each function's signature (param types + return type) and each
   global's type + initializer.
2. **Declaration checks** — arity (≤32 params, ≤32 args — parser-gated,
   re-checked), `main must return i32` + `main must not have parameters`
   (host `src/aster.cpp` ~2156/2165), `function body cannot be empty`,
   `a function cannot return an array` (host ~2153).
3. **Per-function scope** — build a scope of params + `let` locals; resolve
   every `Var` / `Call` / `FieldCall` name; reject **undeclared** names; reject
   use of a `let` before its declaration (one pass, source order); reject
   duplicate local names.
4. **Expression typing** — compute a type for every `E_*` node and enforce
   operand rules: arithmetic on integer types only (no `bool`, no stray pointer
   arithmetic), comparisons yield `bool`, logical ops on `bool`, `Index`
   requires an array/pointer, `Call`/`FieldCall` checks the signature against
   actual arg count *and* types, `Num` is `i32`/`i64` by value, `String` is
   `ptr<u8>`.
5. **Statement checks** — `Assign`/`IndexAssign` type-compatibility (the host's
   `let b: u8 = 300` range hole, v0.23.27-dev, must be caught here); `If`/
   `While`/`For` conditions accept any integer (0 = false, non-zero = true,
   v0.23.25-dev); `Return` type matches the function return; `Expr` statement is
   a call.
6. **Constant-expression validation** — global initializers and array lengths
   must be constant (host: *"global variable initializer must be a constant
   expression"*); this is where any constant folding M3b performed is verified.
7. **Capacity limits** (bootstrap-only, fixed arrays) — each its own `S`-error
   (see §6).

## 4. Data model under the constraints

The bootstrap has **no struct, no union, no allocator**; arrays are fixed-size
globals; frames stay within 8KB. The symbol table therefore mirrors the AST's
own representation:

- **Parallel fixed arrays, handle-indexed** (0 = none), exactly like the
  seven AST arrays:
  - `sname` — id → the name token index
  - `skind` — fn / global / param / local / extern-fn / extern-let
  - `sty` — type **tag** (i32 index into `tytab`)
  - `selem` — element type tag (for `ptr<T>`; `-1` for bare scalar/ptr)
  - `sowner` — owning function id (locals/params); 0 for top-level
  - `snext` — next symbol in the same scope chain
  - `schild0` — first local/param of a function (scope head)
- Scope resolution walks outward from the current function's chain. To respect
  the **no-union** limit, a type is stored as `(tag, elemTag)` — two `i32`s —
  not a `Ty` struct.
- **All capacities are frozen constants** in `SEMANTIC-SPEC.md`, proven bounded
  exactly as `PARSER-SPEC.md` §10/§11 proved C1/C2/C3: symbol count ≤ a fixed
  cap, scope depth ≤ C2 (96, shared with the parser), type nesting ≤ a fixed
  cap, identifier length ≤ the lexer's name buffer.

## 5. The differential oracle (twin)

Extend `tests/parser-twin.c` with a **semantic pass** that mirrors the
bootstrap's: same symbol-table shape (a C struct array + parallel arrays), same
type rules, same error messages. It already compiles clean under
`-std=c11 -O2 -Wall -Wextra -Werror -fwrapv -fno-builtin`. Keep its outputs
byte-identical to the bootstrap's: same AST dump on accept, same `S`-error bytes
on reject. The twin is plain C, so it uses a real struct array + a linear/array
symbol table — the independence the differential needs.

## 6. Capacity limits & errors (bootstrap-only)

| gate | value (proposed) | error |
|---|---|---|
| symbol-table size | 4096 symbols | `S?` "too many symbols" |
| scope depth | 96 (shares C2) | `S?` "scopes nest too deeply (limit 96)" |
| type nesting (ptr depth) | 16 | `S?` "type nests too deeply" |
| identifier length | lexer name buffer (≤ 1 MiB / per-token cap) | lexer `E`-error already |

Each is proven unreachable in normal use but bounded so a pathological input
fails cleanly rather than overrunning a fixed array — the same defensive posture
as `C3` in M3b.

## 7. The resident suite (extends `tests/parser-checks.sh`)

Keep the project's "one suite covers the full pipeline" discipline (M3b absorbed
`lexer-checks.sh`; M3c extends the same file). New sections, all additive — the
existing 312 checks stay green because `aster.ast` is well-typed and
semantically valid:

- **§13 Semantic diagnostics** — the frozen `S`-catalog, each with exact
  message + position + exit 1 + empty stdout, on minimal complete programs (the
  same shape as the `P`/`B` sections).
- **§14 Semantic accept/reject corpus** — a differential corpus (like the
  59-case boundary corpus) separating "accepted" (well-typed, dump identical to
  M3b) from "rejected for the right reason" (frozen `S`-error).
- **§15 Self-semantic** — run the stage *with the semantic pass* over its own
  source and the library; the dump must be **byte-identical to M3b's** (since
  Aster's own source is well-typed) — proof that M3c does not perturb accepted
  output.
- **§16 Semantic mutation probes** — a new source-level mutation layer targeting
  the semantic logic (proposed: `m_s_undeclared`, `m_s_arity`, `m_s_ret_type`,
  `m_s_dup`, `m_s_const_init`, `m_s_symtab_cap`), each asserted to apply, still
  build/link, and diverge from the twin.

## 8. Deliberately not in M3c (deferred)

- **No codegen, no ELF** — M3d's work. M3c's artifact is the AST dump (or a
  rejection), not an executable.
- **No new type tags** (`u16`/`u32`/`bool`/`struct`) — requires a parser change;
  deferred to a wider round. M3c validates the subset the parser emits.
- **No constant-folding extension** — M3c *validates* constness, it does not
  widen folding.
- **No `union`/nested-struct in the AST** — keep the parallel-array discipline.

## 9. Task breakdown (proposed)

| # | task | lands in |
|---|---|---|
| #242 | Freeze `bootstrap/SEMANTIC-SPEC.md` (13 sections): type subset, symbol-table semantics, `S1`–`Sn` catalog, success = AST dump, two-phase rule, capacity limits | `bootstrap/` |
| #243 | Implement the semantic pass in `bootstrap/aster.ast` (symbol table as parallel arrays; iterative AST walk; 8KB-frame discipline) | `bootstrap/aster.ast` |
| #244 | Extend `tests/parser-twin.c` with the semantic oracle | `tests/` |
| #245 | Extend `tests/parser-checks.sh`: §13 semantic diagnostics, §14 accept/reject corpus, §15 self-semantic (byte-identical to M3b), §16 semantic mutation probes | `tests/` |
| #246 | Verify: strict build, deliverable chain + zero-dependency (one UND), full CI, baseline byte-identical | — |
| #247 | Docs: README / ROADMAP / FEATURE_STATUS / SELFHOSTING-PLAN / `VALIDATION-v0.23.45-dev.md`; bump version constant to `v0.23.45-dev` | root + `docs/` |

## 10. Verification gates (unchanged discipline)

- Contract frozen **before** code; the spec is the single source of truth, golden
  examples/diagnostics extracted from it at runtime.
- Twin matches byte-for-byte on every frozen `S`-diagnostic, the accept/reject
  corpus, and self-semantic.
- Mutation probes each diverge.
- **No compiler change** → the A/B baseline stays at **330 lines, byte for
  byte** (verified by `tests/rebuild-baseline-v0.23.45.sh`).

## 11. What this opens

M3d (codegen → ELF): the bootstrap walks the now-validated AST and builds the
same type tables M3c built, then lowers to AArch64 bytes and writes the ELF.
M3c's symbol table and type-derivation logic are the reference M3d reuses. After
M3d, M4 closes the loop: `aster.ast` compiles itself to an executable, compared
byte-for-byte against the C++ `aster` and a qemu twin.
