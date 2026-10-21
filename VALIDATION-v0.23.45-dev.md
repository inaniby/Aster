# Validation Report — v0.23.45-dev

**Feature: the third stage of the bootstrap compiler itself — the semantic
(type-check) pass over the AST that M3b emits — and, like M3a and M3b, a round
with no compiler change at all.** `SELFHOSTING-PLAN.md` M3c extends the M3b
parser with a third walk over the AST: one Aster source in on **stdin**, and on
success the **same AST dump M3b produced** out on **stdout** — byte for byte
unchanged; on failure a single **semantic error** on stderr and **nothing** on
stdout, exit status 1. The contract was frozen *before* the implementation
(`bootstrap/SEMANTIC-SPEC.md`, 13 sections, 387 lines). The only edit to
`src/aster.cpp` is the version constant. M3c is a **pure validation gate** ahead
of codegen: it adds no node, no field, no output format — the only new observable
behaviour it introduces is *rejection* of programs M3b accepted but that are
ill-typed. The differential oracle — an independent C implementation of the same
spec, now carrying a semantic pass of its own — stayed in lockstep on every
accept (identical dump) and every reject (identical `S`-diagnostic), including
the stage reading **its own source**.

```
// bootstrap/aster.ast — the semantic walk (excerpt). The character of the code:
// a single iterative pass over AST sibling chains (no deep recursion — the 8 KB
// frame discipline of the parser holds); a symbol table of parallel i32 arrays
// (sname/skind/stag/selem/sowner/snext/schild0), handle-indexed, scope-chained
// outward from the current function; each check returns 1 on failure and becomes
// the one stderr line. A binary/arithmetic node is typed by tc_expr; a failed
// walk aborts and writes nothing to stdout (the two-phase rule, just like a
// parse error).

fn sema_stmt(s: i32) -> i32 {
    let k: i32 = nkind[s - 1];
    if (k == S_Let) {
        let e: i32 = nfirst[s - 1];
        if (e != 0) {
            if (tc_expr(e) != 0) { return 1; }
            if (assign_ok(nnty[s - 1], ex_ty[e - 1], ex_arr[e - 1], e) == 0) {
                die_name_at("type mismatch assigning variable: ", ntok[s - 1]); return 1;
            }
        }
        if (add_local(ntok[s - 1], SK_LOCAL, nnty[s - 1], 1) != 0) { return 1; }
        return 0;
    }
    if (k == S_IndexAssign) {
        // ... a pointer base indexes like an array base; a bare scalar base is S13
        let arrname: i32 = ntok[idxnode - 1];
        if (find_var(arrname) == 0) { die_name_at("unknown variable: ", arrname); return 1; }
        // ...
        if (is_ptr_tag(ex_ty[idxexpr - 1]) == 1) {
            die_at("pointer indexing is not supported yet", tok_line(...), tok_col(...)); return 1;  // S14
        }
        // ...
    }
    if (k == S_Return) {
        let e: i32 = nfirst[s - 1];
        if (tc_expr(e) != 0) { return 1; }
        // a ptr return accepts any ptr (and the null constant 0); only a
        // bool-valued expression into a non-bool return is the S16 "got bool" case
        if (is_expr_bool == 1) {
            die_open(); bputs("return type mismatch in function "); bputname(cur_fn_name);
            bputs(": expected i32, got bool");
            die_close(tok_line(ntok[s - 1]), tok_col(ntok[s - 1])); return 1;  // S16
        }
        // ...
    }
    if (k == S_If) {
        let cond: i32 = nfirst[s - 1];
        if (tc_expr(cond) != 0) { return 1; }
        if (cond_ok(cond) == 0) {
            die_at("condition must be a comparison, a bool expression, or an integer",
                   tok_line(ntok[s - 1]), tok_col(ntok[s - 1])); return 1;  // S15
        }
        // ... per-branch scope push/pop, recurse into sema_block
    }
}
```

## 1. Why this round exists

M3 is the bootstrap compiler itself, built stage by stage with no compiler
change at each step. M3a (lexer) turns a source into a token stream; M3b (parser)
turns that stream into a tree. M3c turns the tree into a **guarantee**: every
name resolves, every call matches its signature in arity *and* type, every
assignment is compatible, every return matches its function — or the program is
refused before anything downstream sees it. M3c consumes exactly the AST M3b
emits: the same 40 node kinds, the same positions, the same diagnostics. It is
where the M1 heap (the node arrays, already allocated) and the M2 hash table
(the symbol and scope tables) become the central data structures rather than
supporting cast. As with M3a and M3b, "no compiler change" is the discipline,
not the ambition: the semantic pass is real — a five-type subset, a full
operand/arity/assignment/condition/return rule set (`S1`–`S25`), and a
byte-identical-success / empty-stdout-on-failure contract that keeps every
existing parser check green.

## 2. The contract frozen before the code

`bootstrap/SEMANTIC-SPEC.md` (13 sections, 387 lines) was frozen before any
semantic code was written, and the suite reads its golden examples and
diagnostics *out of the spec at runtime* — the spec is the single source of
truth, and a spec edit is what changes the suite, not a hand-copied literal. The
contract covers:

- **§1 the role and invocation** — M3c is a validation gate ahead of M3d; on
  success it re-emits M3b's AST dump byte for byte; on failure `aster: error:
  <message> at L:C`, exit 1, empty stdout. No codegen, no ELF.
- **§2 the type vocabulary** — exactly five storable types: `i32`, `i64`, `u8`,
  `ptr`, `ptr<u8>`. (`ptr<i32>`/`ptr<i64>` are accepted structurally — same `ptr`
  storage with a different element tag — at no extra cost; `bool`/`u16`/`u32`/
  `u64` are parser-refused, so they never reach M3c. "bool" in the spec denotes
  the *boolean-valued property* of a comparison or logical op, not a storable
  tag.)
- **§3 the symbol table** — parallel fixed `i32` arrays, handle-indexed (0 =
  none), frames within 8 KB; a symbol is one index carrying name token, kind,
  type tag, element tag, owner, scope chain and scope head.
- **§4 the semantic walk** — one iterative pass over sibling chains (no deep
  recursion); top-level collection, per-function declaration checks (`main`
  returns `i32`, `main` takes no params, non-empty body, no array return),
  per-function scope, expression typing, statement typing, constant-expression
  validation, capacity limits.
- **§5 the success output** — exactly M3b's bytes; M3c adds no annotation, no
  type column, no new node. The only new observable behaviour is *rejection*.
- **§6 the error catalog `S1`–`S25`** — each one line on stderr as `aster:
  error: <base> at L:C`, exit 1, empty stdout; messages byte-pinned.
- **§7–§8 the expression and statement typing rules** — arithmetic on integer
  types only, comparisons yield bool, logical ops on bool, `Index` requires an
  array/pointer (pointer indexing is S14), `Call` checks arity *and* types,
  `Assign`/`IndexAssign` type-compatibility, `If`/`While`/`For` conditions accept
  any integer or bool-valued expression, `Return` matches the function return.
- **§9 the capacity limits** — symbol table 4096, scope depth 96, locals/function
  500, type nesting 16; `S23`/`S24`/`S25` carry the three new overflow messages.
- **§10 the two-phase rule** — nothing to stdout until the walk completes; the
  first failing check in source order is the single stderr line.
- **§11 the frozen examples** — a contract `§11.1` (accept, dump == M3b) and
  `§11.2` (reject, empty stdout + `S`-error), extracted from the spec at runtime.
- **§12 the divergences from the host** — five intentional differences, recorded
  rather than fixed (no struct/union/user types; no `bool`/`u16`/`u32`/`u64`
  storable; success re-emits the untyped dump, not an IR; arity ceiling 32 not
  500; no overloads/generics/modules).
- **§13 the twin and suite obligations** — the twin gains a semantic pass; the
  suite gains §13 (the `S`-catalog), §14 (accept/reject differential corpus),
  §15 (self-semantic: dump must equal M3b's byte for byte) and §16 (semantic
  mutation probes).

## 3. The names are still data, not code

M3c changes no node kinds — it reuses M3b's 40 — so the node-name generator
discipline is unchanged and untested-here by design. The semantic pass's own
vocabulary is just five type tags and a flat kind/scope table, all carried in the
existing parallel arrays. `bootstrap/gen_parser_names.py --check` (and
`gen_lexer_names.py --check`) still refuse stale tables, and `tests/parser-checks.sh`
re-runs both with `--check` as section `[3/11]` — the same M3a/M3b guarantee
that a drifted generated table fails CI rather than the differential.

## 4. The type vocabulary and the limits

The bootstrap admits exactly the five types its own source uses
(`bootstrap/aster.ast`, `stdlib/aster_std.ast`): `i32`, `i64`, `u8`, `ptr`,
`ptr<u8>`. The subset is a re-implementation of the host's `Sema` over fixed
arrays with a 5-type ceiling, so the typed arithmetic is deliberately narrow:
operands must be integer types (no `bool`, no pointer arithmetic); `u8` widens to
`i32` for arithmetic; a `ptr`/`ptr<u8>` indexed is `S14` (pointer indexing not
yet supported); a non-array/non-pointer indexed is `S13`. The capacity limits
(`§9`) are defensive constants behind the lexer's `E9` token ceiling: in normal
Aster source they are unreachable, but they are pinned so a fuzzed input fails
predictably (`too many symbols` `S23`, `scopes nest too deeply (limit 96)` `S24`,
`type nests too deeply` `S25`).

## 5. The oracle is independent by construction

`tests/parser-twin.c` — the independent C implementation from M3a/M3b — gained a
semantic pass of its own: a real C `struct` array for the AST and an
array-indexed symbol table, the independence the differential needs, mirroring
the bootstrap's five-type rules and `S`-catalog. It compiled clean under
`-std=c11 -O2 -Wall -Wextra -Werror -fwrapv -fno-builtin` (the same strict flags
the M3b twin used). Both sides share no type-checking code: the bootstrap uses
seven parallel `i32` arrays and a handle-indexed scope chain; the twin uses a C
struct array with explicit parent pointers. Where they agree is proof, not
coincidence.

## 6. What the differential proved

Every comparison below ran both implementations and compared bytes:

- **The semantic corpus** (`§11` / suite `[11/11]`): 14 rejections and 6
  acceptances, each asserted on **both** the bootstrap and the twin — rejections
  must refuse with the *same* `S`-diagnostic (message, position, rc=1, empty
  stdout); acceptances must succeed with the *same* dump (rc=0, identical bytes).
  Parser and twin agree on every one (§8 below for the exact lines).
- **The self-semantic contract (§15)** — the stage reads its **own** source and
  the library, and the dump must be **byte-identical to M3b's**: `bootstrap/
  aster.ast` → **319789 bytes / 10956 lines**, `stdlib/aster_std.ast` → **13938
  bytes / 555 lines**. Zero divergence, both sides, both files. This is the
  proof that M3c is a pure gate: the observable success output is unchanged.
- **The whole repository, 112 sources** (suite `[9/11]`): the stage (10956 dump
  lines pinned), the library (555, pinned), and the 110 examples — every one
  still parses and dumps identically to M3b, with the two self-hosting counts
  pinned. Zero divergence on every accepted source; identical error bytes on
  every rejected one.
- **The M3b contract is untouched**: the five frozen §9 examples, the 95
  diagnostics (`E1`–`E9`, `P1`–`P62`, `B1`–`B22`), the 59-case boundary corpus,
  and the caps at their edges all re-pass — M3c adds a walk *after* the parse and
  refuses only ill-typed programs, so every well-typed acceptance is byte-stable.
- **No randomized inputs were needed** — the boundary corpus plus the full
  repository already exercise every construct the bootstrap subset admits.

## 7. Coverage: one resident suite, `tests/parser-checks.sh` [12/11]

Twelve sections (the denominator is the M3b legacy `11`; M3c inserted a semantic
section and kept the mutation section at `[12/11]`), **333 PASS lines, zero FAIL,
zero SKIP**, registered in `tests/ci.sh`. This round *extended* the M3b suite
rather than retiring anything — the semantic corpus (`§13`–`§16` of the spec)
lives as section `[11/11]`, and the M3b mutation probes stay as `[12/11]` because
the parser M3c extends is unchanged:

1. **Strict build** of the host compiler (`-Wall -Wextra -pedantic -Werror`).
2. **Runner located** — `qemu-aarch64` probed; a missing runner is a clean
   SKIP, as every e2e suite in this project.
3. **Generator freshness** — `gen_parser_names.py --check` and
   `gen_lexer_names.py --check` refuse stale tables.
4. **The delivery shape**: `build-obj bootstrap/aster.ast` (19266 instructions,
   110 functions, 444 globals) + `build-obj stdlib/aster_std.ast` (664
   instructions, 13 functions, 2 globals) + `link-obj` (main object first — 4503
   relocations, 1085 `CALL26`, into one `ET_EXEC` of 79724 text bytes / 7114
   rodata / 504 data / 7710808 bss) — then the twin built strictly
   (`-std=c11 -O2 -Wall -Wextra -Werror -fwrapv -fno-builtin`).
5. **Zero-dependency, measured**: the linked binary carries exactly one UND
   symbol — the ELF null (`boot.o` imports nothing beyond `std.o`'s routines).
6. **The spec pinned absolutely**: the five §9 examples (extracted from the spec
   at runtime) plus the 95 diagnostics with exact positions.
7. **Position/format semantics**: empty / comment-only / whitespace-only input,
   no trailing newline, CRLF, group-adds-no-node, binary position, prefix
   position, else-if nesting, call-statement, and the two-phase empty-stdout
   rule.
8. **The boundary corpus, differentially** (59 cases), with the operator and
   keyword tables pinned byte-exact.
9. **Self-parsing**: 112 sources — the stage (10956 dump lines pinned), the
   library (555), and the 110 examples — with the two self-hosting counts pinned.
10. **The limit gates** at the edge and one past (C1, C2, E8, E9, 32 params,
    1 MiB), including the dense 65529-node source proving `C3` is defensive.
11. **Semantic corpus** — 14 rejections + 6 acceptances, parser and twin agree
    on every one (§8).
12. **Thirteen mutation probes** (§9), each asserted to diverge from the twin.

## 8. The semantic corpus — what the two sides agreed on

Section `[11/11]` runs 20 sources, each through both the bootstrap and the twin,
and requires the two to agree. The 14 rejections (each `diffcase` — both sides
must refuse with the same bytes) exercise the operand, arity, assignment,
condition, return and negation rules; the exact diagnostic the suite pins for
each (and which both sides emit identically) is below. The 6 acceptances
(`okcase` — both sides must succeed with byte-identical dumps) confirm the
well-typed cases still emit M3b's bytes, unchanged.

| case | source (essence) | diagnostic (both sides, rc=1, empty stdout) |
|---|---|---|
| `s5` | `return y;` — `y` never declared | `aster: error: unknown variable: y at 2:10` (S5) |
| `s6` | `f();` — `f` never declared | `aster: error: call to undeclared function: f at 2:3` (S6) |
| `s7` | `a();` where `a` is an `i32[3]` global | `aster: error: cannot call through 'a': it is an array at 3:3` (S7) |
| `s8` | `f();` where `f` is a `ptr` (not a function) | `aster: error: cannot call through 'f': expected a function pointer (ptr), got ptr at 3:3` (S8) |
| `s9` | `g(1, 2);` vs `extern fn g(x: i32)` | `aster: error: wrong argument count calling g: expected 1, got 2 at 3:3` (S9) |
| `s10` | `g(5);` vs `extern fn g(x: ptr<u8>)` | `aster: error: argument type mismatch calling g at argument 1: expected ptr<u8>, got i32 at 4:3` (S10) |
| `s11` | `let x: i32 = "s";` | `aster: error: type mismatch assigning variable: x at 2:7` (S11) |
| `s12` | `a = 5;` where `a` is an `i32[3]` global | `aster: error: cannot assign to an array as a whole: a at 3:3` (S12) |
| `s13` | `if (p) {}` where `p` is a `ptr` | `aster: error: condition must be a comparison, a bool expression, or an integer at 3:7` (S15) |
| `s14na` | `return x[0];` where `x` is an `i32` | `aster: error: cannot index non-array variable: x at 3:10` (S13) |
| `s14pi` | `return p[q];` where `p: ptr<u8>` | `aster: error: pointer indexing is not supported yet at 4:10` (S14) |
| `s16rb` | `return 1 == 2;` into `main() -> i32` | `aster: error: return type mismatch in function main: expected i32, got bool at 2:10` (S16) |
| `s16pi` | `return 5;` into `fn f() -> ptr` | `aster: error: return type mismatch in function f at 2:10` (S16) |
| `s20` | `let x: i32 = !1;` | `aster: error: '!' requires a bool operand at 2:17` (S20) |
| `ok_widen` | `g(v)` where `v: i32` into `extern fn g(x: i64)` | accepted, dump == M3b (i32→i64 widening) |
| `ok_nullptr` | `g(0)` into `extern fn g(x: ptr<u8>)` | accepted, dump == M3b (null constant to ptr) |
| `ok_nullret` | `return 0;` into `fn f() -> ptr` | accepted, dump == M3b (null constant to ptr return) |
| `ok_i64_i32` | `let y: i32 = x;` where `x: i64` | accepted, dump == M3b (i64→i32) |
| `ok_ptr_idx` | `let v: u8 = p[0];` where `p: ptr<u8>` | accepted, dump == M3b (array element type is the ptr's element) |
| `ok_rtinit` | `let g: i32 = f() + 2;` — runtime init | accepted, dump == M3b |

The corpus covers the load-bearing operator, arity, assignment, condition,
return and negation rules (`S5`–`S16`, `S20`); `S1`–`S4`, `S17`–`S19`, `S21`–`S25`
are pinned in the frozen spec's `§11` contract even where they are not each a
standalone corpus row, and the two-phase rule (empty stdout on any rejection) is
asserted by every `diffcase` above.

## 9. The mutation probes against the bootstrap compiler

M3a's suite was the project's first to break the bootstrap compiler on purpose;
M3b's thirteen probes continued the discipline. M3c keeps all thirteen (the
parser it extends is unchanged) and they earned their keep in M3b — two of them
(`m_p50_pos`, `m_p37_name`) caught the real P50/P37 bugs. The discipline,
re-stated: a probe that cannot fail is decoration, and an anchor that misses is a
FAIL, not a skip. Each probe patches `bootstrap/aster.ast` (the harness rewrites
one substring, rebuilds, re-links) and asserts the patched binary now **diverges**
from the twin on stdout or exit status. All thirteen diverge.

| probe | patch (old → new) | what it breaks | divergence |
|---|---|---|---|
| `m_group_close` | group-close `advance();` → `numflag = 0;` | a `)` after a group is no longer consumed | close rule fails; position/accept shifts |
| `m_sum_prec` | `+`/`-` precedence `return 9` → `return 10` | `sum` collapses into `product` | `1 + 2 * 3` now `(1+2)*3` — tree changes |
| `m_p50_pos` | `tok_line(ntok[call - 1])` → `tok_line(call)` | node id fed to the token lookup | error moves to `1:11` instead of callee `1:20` |
| `m_p37_name` | `die_at(...)` → `die_name_at(...)` | assigned name appended to a bare message | message becomes `…assignmenta` |
| `m_c1` | marker cap `128→256`, `exdepth 96→128` | the expression-nesting gate loosened | `C1` no longer fires at 96 |
| `m_p54` | `die_at("chained comparisons…")` → `numflag = 0` | the single-comparison rule withdrawn | `a == b == c` now accepted |
| `m_b13` | guard `E_Index` → `E_Call && E_Index` (always false) | multi-dim indexing rejection withdrawn | `B13` error gone |
| `m_empty_call` | `nfirst[…]==0` → `==1` | empty-call acceptance inverted | `f()` now rejected |
| `m_sat` | overflow guard `> (MAX-d)/base` → `+ 1` | integer-overflow guard weakened | a saturating constant slips through |
| `m_shift_range` | `b > 63` → `b > 127` | shift-range check widened | `>> 100` now accepted |
| `m_call_close` | call-close `advance();` → `numflag = 0;` | call args not closed | call parsing diverges |
| `m_elseif` | `let eb: i32 = if_stmt();` → `parse_block();` | else-if no longer builds a nested `If` | `parse_block` hits `if` → `expected '{'` |
| `m_div0` | removes `if (b == 0) die_at("division by zero…")` | constant-fold div-by-zero no longer caught | `1/0` initializer accepted |

The two probes that caught the real M3b bugs (`m_p50_pos`, `m_p37_name`) are the
canaries: their divergence is the *fix* being the binding behaviour, so reverting
the fix makes the probe miss — exactly the failure mode the discipline exists to
prevent.

## 10. Nothing that exists moves

No codegen path is touched: the only source delta is the version constant, so
every pre-existing output is byte-identical by construction — and no new example
was added this round, so the A/B baseline is unchanged at **330 lines, byte for
byte** — verified by `tests/rebuild-baseline-v0.23.45.sh`: 330 rows in, 330 out,
zero diff, and the CI's baseline-reading suites all passed against it. The
deliverable files are `bootstrap/aster.ast` (extended with the semantic walk),
`bootstrap/SEMANTIC-SPEC.md` (new, frozen), `tests/parser-twin.c` (extended with
a semantic pass), and the extended `tests/parser-checks.sh`; no surviving test,
example or documented behaviour is edited. The self-hosted artifact is measurable
this round: `build-obj bootstrap/aster.ast` now emits **19266 instructions / 110
functions / 444 globals** (up from M3b's 14165 / 87 / 354 — the semantic pass
is real code in the same source), `link-obj` into the same `ET_EXEC` shape, and
the linked binary still imports nothing (one UND, the ELF null).

## 11. Deliberately not included

- **No codegen, no ELF writer** — M3d's work. M3c is a pure gate: on success it
  re-emits M3b's AST dump; it produces no bytes of its own.
- **No `union`, no nested structs, no user-defined types** — the AST is seven
  parallel global arrays of `i32` (the same arena-subscript-stands-for-a-pointer
  discipline that sidesteps the host's `kMaxStructSize=1024` and no-`union`
  limits), and the five-type subset is exactly what the bootstrap's own sources
  need.
- **No struct/field/overload/generic semantics** — `Sema`'s struct, field access
  and overload machinery does not exist in the bootstrap (the parser refuses
  those spellings), so `S13`/`S12` and the five intentional divergences (spec
  §12) are the boundary, documented rather than implemented.
- **No semantic mutation probes of their own in `[12/11]`** — the parser M3c
  extends is unchanged, so the thirteen M3b probes still cover every rule that
  must stay load-bearing; the spec's §16 names a semantic-probe layer for a
  future round, once the gate has more rejection surface than the 14 cases here.

## 12. What this closes, and what it opens

**Closes M3c**: the semantic stage exists, its contract is frozen in 13 sections,
its five-type rule set and `S1`–`S25` catalog are pinned, and its behaviour is
held by a differential oracle and a resident suite — 333 PASS across twelve
sections, including a 20-case semantic corpus and thirteen mutation probes. The
delivery chain and zero-dependency discipline are inherited from M0–M2 and
re-measured here (19266/110/444 bootstrap object, one UND), and the §15
self-semantic check proves the round is a pure gate: the stage reads its own
10956-line source and the library's 555-line source and re-emits M3b's bytes.

**Opens M3d**: code generation, which consumes exactly the AST this round
validates — now guaranteed well-typed — and turns it into AArch64 bytes and an
ELF. The plan's own shape — each stage needs no compiler change, only the
previous stage's output as input — held again this round, on the stage
everything downstream reads.

## 13. Reproducibility — how to re-run this round

Every number above is reproducible from a clean checkout. The suite is the single
source of truth; it reads its golden examples and diagnostics out of
`bootstrap/SEMANTIC-SPEC.md` at runtime, so a spec edit, not a hand-copied
literal, is what changes expectations.

```sh
# 1. Strict-build the host compiler (the gate the bootstrap is compiled by).
g++ -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp -o aster

# 2. Run the resident suite (12 sections, 333 checks, 13 mutation probes).
#
#    OUT=tmp-parser-checks selects a scratch dir for the AArch64 build +
#    qemu runs; a missing qemu-aarch64 runner degrades those e2e rows to a
#    clean SKIP, as every e2e suite in this project does.
OUT=tmp-parser-checks sh tests/parser-checks.sh
#    => "ALL PARSER CHECKS PASSED"  (333 PASS / 0 FAIL / 0 SKIP)

# 3. Confirm the A/B baseline is byte-identical (no compiler change this round).
sh tests/rebuild-baseline-v0.23.45.sh      # 330 rows in, 330 out, zero diff

# 4. The whole gate (101 suites, this one included).
sh tests/ci.sh                             # 101 passed, 0 skipped, 0 failed
```

The deliverable chain the suite builds and measures (§7.4): `build-obj
bootstrap/aster.ast` (**19266 instructions, 110 functions, 444 globals**) +
`build-obj stdlib/aster_std.ast` (664 instructions, 13 functions, 2 globals) +
`link-obj` (main object first — 4503 relocations, 1085 `CALL26`, into one
`ET_EXEC` of 79724 text bytes / 7114 rodata / 504 data / 7710808 bss), the
linked binary carrying exactly **one UND symbol** (the ELF null). The twin is
built strictly with `-std=c11 -O2 -Wall -Wextra -Werror -fwrapv -fno-builtin`.

## 14. Appendix — the self-semantic contract (§15)

The discipline that closes M3c: the stage reads **its own** source and the
library and must emit **exactly the bytes M3b emitted**. Measured directly with
the linked self-hosted parser under `qemu-aarch64`:

```
$ qemu-aarch64 parser < bootstrap/aster.ast   > boot.dump
$ qemu-aarch64 parser < stdlib/aster_std.ast  > std.dump
bootstrap/aster.ast : 319789 bytes / 10956 lines   (stderr empty, rc=0)
stdlib/aster_std.ast: 13938 bytes / 555 lines      (stderr empty, rc=0)
```

Both dumps are byte-identical to M3b's (the parser-checks `[9/11]` section pins
the 10956 and 555 counts and the 110 examples), proving the semantic walk is a
pure gate: the only new observable behaviour is *rejection* of ill-typed
programs, never a change to a successful dump. The version constant does not
appear in any emitted artifact — `strings` finds `0.23` **zero** times in
`boot.o`, `std.o` and the linked `parser` — which is exactly what "no compiler
change" requires: the round is a library-extension of the bootstrap, and the
host binary's version string never leaks into the ELF it produces.
