# Validation Report — v0.23.39-dev

**Feature: a discarded-call statement — `foo();` and `h.onClick(41);` run the
callee and drop the result.** This round answers the three questions that
followed the callback-table round (asked in order): *"现在的函数执行还需要一个变量来接收吗？"*
(no); *"那没返回值的函数也需要吗？"* (there is no `void`, so the question does
not arise); *"有什么优劣？"* (the narrow form wins). Aster had **no expression
statement at all** and **no `void`**, so every call result had to land in a
`let`, a `return`, or an arithmetic position. The new statement is the one call
form worth allowing: a call written for its side effect alone, its answer thrown
away.

```
# tests/discard-call-checks.sh [4/8] — the form the round adds

struct H { cb: fn(i32) -> i32 }
let fired: i32 = 0;
fn handler(x: i32) -> i32 { fired = fired + 1; return x; }
fn main() -> i32 {
    let h: H = H { handler };
    h.cb(41);          # discarded field call — the increment runs, i32 dropped
    return fired % 251;
}
```

```
# the narrowing is the feature: a bare variable and an arithmetic value stay refused

fn main() -> i32 { let x: i32 = 3; x; return 0; }   # "expected let, assignment,
                                                     #  return, if, while, for,
                                                     #  break, or continue"
```

## 1. Why this round exists

v0.23.38-dev shipped a callback table (`h.onClick(x)`) and three follow-up
questions surfaced the gap. Aster was deliberately built with **no expression
statement**: the "function always wins" dispatch and the assignment/`++`/`+=`
positions are the only ways a value-producing thing can appear, which keeps
expressions side-effect-free. But a *call* already runs its body whether or not
the caller keeps the answer — `let r = h.onClick(41) + 0;` was always legal — so
the only thing the old rule actually blocked was *writing* the discard, not
*performing* it. The fire-and-forget callback (an event loop that only wants the
side effect) was the concrete case that had no clean spelling.

Two facts shaped the design:

1. **Aster has no `void` and no bare `ptr` spelling for "no return value".** Every
   function returns a value (`->` is mandatory; `main` is `i32`), so "a function
   with no return value" is not a thing in the language — the question *"没返回值
   的函数也需要吗？"* has no instance. The only way to avoid catching a value is
   to drop it at a call site, which is exactly what this round adds.
2. **The discarding must be narrow.** Opening "any expression as a statement"
   would admit `x;` and `a + b;` — meaningless noise — and would weaken the
   side-effect-free design for everything, not just calls. So only a `Call` or a
   `FieldCall` as the outermost node of a statement reaches the new branch.

## 2. The branch runs before the field-assign dispatch, gated by a token-preserving peek

`Statement()` gains a `Stmt::Expr` kind and a new branch that runs **before** the
field-assign dispatch. The gate is `isCallStatement()`:

```cpp
bool isCallStatement() const {
    if(cur().k!=TK::Ident) return false;
    size_t q=p+1;
    if(t[q].k==TK::LParen) return true;          // foo(...)
    if(t[q].k==TK::Dot){                          // h.x.y(...)
        q++;
        while(t[q].k==TK::Ident){
            q++;
            if(t[q].k==TK::LParen) return true;
            if(t[q].k==TK::Dot){ q++; continue; }
            break;
        }
    }
    return false;
}
```

The peek reaches past the dot chain to the `(` **without consuming a token** (the
assignment forms below re-parse from the same spot), so `h.onClick(41)` (a
discarded field call) is told from `h.field = v` (a field store) and from
`h.field` (a bare read). A bare variable `x;` and an arithmetic expression
`a + b;` are not `Call`/`FieldCall` at the outermost node, so they fall through to
the existing dispatch and are still refused with the same diagnostic.

## 3. The discarded call is checked exactly as a kept one

`Sema::checkStmt`'s `Stmt::Expr` case is one line — `typeOf(*s.expr);` — and
nothing else, so the call goes through the identical checks a value call does:

- a discarded `f(1, 2);` is still refused (*"wrong argument count calling f:
  expected 1, got 2"*);
- a discarded `h.tag(1);` where `tag` is an `i32` field is still refused
  (*"cannot call field 'tag': its type is i32, not a function type"*).

The argument-count check also lives independently in codegen, which is exactly
why the mutation layer (m2) proves the Sema check by *removing the field-kind
refusal* rather than the count — dropping the Sema `typeOf` on its own leaves the
codegen count check in place, so a rejected program stays rejected and the
`must_accept` probe must be the field-kind case.

## 4. Codegen emits the call, then releases the result register

`gen`'s `Stmt::Expr` arm:

```cpp
} else if(s.k==Stmt::Expr){
    int d=gen(*s.expr);releaseTemp(d);
}
```

The call is generated at the widths its own type declares — a discarded `i64`
call still stages at full width and still writes its side-effect global, a
`bool`/`ptr` return is read at its width — and the temporary `gen` returned (the
top of the X0–X15 pool) is released the same way an assignment releases the value
it just stored, so the pool cannot leak across statements. The callee's side
effects all run; only the answer is dropped.

## 5. Coverage: one resident suite, [8/8]

`tests/discard-call-checks.sh`, registered in `ci.sh`, with the shipped example
`examples/call-stmt.ast` and its C twin `tests/call-stmt-twin.c` (both exit 56):

1. a strict `-Werror` rebuild;
2. **9 source guards** pinning the `Stmt::Expr` kind, the `isCallStatement()`
   peek, the parser branch and the statement construction, the Sema case and its
   `typeOf`, the codegen arm and its `gen`/`releaseTemp`, and the narrowing
   comment;
3. **9 gcc-differential cases** — a direct call, a struct-field call, an `i64`
   result, zero arguments, a `bool` result, a `ptr` result, ten arguments with
   the last two on the stack, a loop, and a "harmless drop" case whose exit
   depends only on a nearby computation (proof the drop corrupts no register);
4. the example against its twin;
5. **4 rejections** — a bare variable, an arithmetic expression, and wrong
   argument count on a direct and a field discarded call;
6. a 6-row coverage map;
7. **4 mutants** — the parser branch (a discarded field call must stop
   compiling), the Sema check (a non-function field call must become accepted),
   the codegen emit (the side-effect-laden direct call must diverge from C), and
   the `isCallStatement()` peek (a discarded field call must stop compiling).

## 6. What the round had to re-point in the existing suites

The round adds one example (`call-stmt.ast`, three rows) and changes no source
text that an existing guard pins, so the only existing suites that needed a
touch were the **six baseline-filtering suites**
(`array-address-checks`, `array-elem-types-checks`, `multi-dim-array-checks`,
`precedence-checks`, `sizeof-len-checks`, `struct-array-field-checks`). Each
counts baseline rows and had to be told about the new example: its filter gained
`-e '^call-stmt\.'` so the new rows are excluded from the pre-existing
comparison, and its comment counts (318 → 321 recorded, 309 pre-existing, the
eleven example families now filtered) were updated. No behaviour, no other guard,
was disturbed — the full CI caught exactly those six, and nothing else.

## 7. Nothing that exists moves

The discard is pure codegen on top of a normal call. A kept call (`let r =
foo();`) compiles to the same bytes; a bare `ptr` still stages every scalar
argument at 64-bit width and still answers `i32`; a struct with no `fn` field
lays out as it always has. The **309 pre-existing** baseline rows reproduce
byte-identical, and `tests/rebuild-baseline-v0.23.39.sh` lands the total at
**321** (the 318 carried into the round plus `call-stmt`'s 3).

## 8. Deliberately not included

- a bare `x;` or `a + b;` statement — the narrowing is the feature, and the
  side-effect-free design for non-call expressions stands;
- any weakening of the assignment / `++` / `+=` positions;
- a `void` type to make "no return value" a first-class spelling — Aster's
  mandatory `-> Type` and `i32`-defaulted `main` are untouched, and the discard
  is how a fire-and-forget call is written instead.

## 9. What this closes, and what it opens

This closes the *"还需要一个变量来接收吗？"* exchange: a callback no longer
needs a variable whose only purpose is to be ignored. It opens a clean spelling
for event-loop and fire-and-forget callbacks (`h.onClick(41);`) that matches C
and costs no layout, no type change, and no weakening of the language's
side-effect discipline — the only thing it relaxes is "a call's value has to go
somewhere", and only for a call.
