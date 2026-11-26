# Validation Report — v0.23.37-dev

**Feature: function types — `fn(P1,..,Pn) -> R` gives a function pointer a
signature, so an indirect call is checked and code-generated like the direct
call it stands for.** The v0.23.24-dev round shipped calls through a `ptr`
variable with one design decision stated outright — *"There is no function
type, so there is no signature"* — and named its own follow-up: *"a function
type (typed variables, signature checking — the larger round that would retire
the 64-bit staging rule)"*. This is that round. `let fp: fn(i32) -> i32 = inc;`
declares a function pointer **with** a signature, and `fp(x)` then runs the
same argument-count and per-argument type checks a direct call runs, stages
each argument at the width its signature declares (an `i32` in a `W` register,
an `i64` in a full `X` register), lays a struct argument out as a composite
instead of refusing it, and answers the signature's return type — where a
bare-`ptr` call answered `i32`. The signature rides **beside** the ptr, never
inside `Ty`: the storage type stays `Ty::Ptr`, so a bare `ptr` keeps the legacy
64-bit staging and `i32` answer, every pre-existing program compiles to the same
bytes (**309 of 309** baseline rows reproduce), and `tests/indirect-call-checks.sh`
— its guards re-pointed at the new staging signature, its bare-`ptr` fallback
still pinned — passes unchanged.

```
# tests/function-type-checks.sh [4/8] — the width centrepiece, against the C oracle

fn high32(a: i64) -> i64 { return a >> 32; }
fn main() -> i32 {
    let wp: fn(i64) -> i64 = high32;
    let big: i64 = 4294967296;          // 2^32
    let hi: i64 = wp(big);              // 1 — a full-width stage and a full-width read
    return hi;                          // both sides exit 1
}
```

## 1. Why this round exists

Since v0.23.24-dev a function's address could be stored, passed and called —
but only as a bare `ptr`, and the round was explicit about what that cost: no
arity check, no parameter types, and a fixed `i32` answer. The staging rule
that made one width serve both kinds of callee — every scalar argument rides at
64 bits — was the round's honest compromise, and it left three holes a typed
call closes:

1. **An `i32`-declaring callee and an `i64`-declaring one shared one stage.**
   It worked (a 32-bit callee reads the low half; AAPCS64 leaves the upper half
   of a sub-64-bit argument unspecified, and `gen()` already extends each
   source the right way), but nothing *checked* that the callee the pointer
   actually held could accept the arguments being handed to it.
2. **The answer was always `i32`.** A callee returning `i64` had its low half
   delivered; the whole 64 bits required wrapping the value in the callee.
3. **A struct argument was refused** — *"a composite needs a signature to lay
   it out"* — because a bare `ptr` has none.

The roadmap named the fix in the same breath as the gap (*"a function type …
the larger round that would retire the 64-bit staging rule"*), and every round
since left it standing. This round retires the rule for typed callees and
leaves it standing, untouched, for bare `ptr` — which is the whole design
constraint, and the reason the byte baseline holds.

## 2. The signature rides beside the ptr, never inside `Ty`

The one decision everything else follows from: a function pointer **is** an
address, its storage type stays `Ty::Ptr`, and the signature is carried in
parallel — exactly the pattern `paramDims`/`slotDims` set for array dimensions
in v0.23.35-dev:

```cpp
struct FuncSig { std::vector<Ty> params; Ty ret=Ty::I32; };
```

carried on the three declaration records and the two passes:

| Where | Field | Filled by |
| --- | --- | --- |
| local `let` / global | `Stmt::funcSig` + `isFunc`, `Global::funcSig` + `isFunc` | the parser's capture at each declaration site |
| parameter | `Function::paramFuncSig[i]` + `paramIsFunc[i]` | the parameter parse loop |
| Sema | `Binding::funcSig` + `isFunc` (local/parameter), `globalFuncSig` map (file scope) | `Sema::check`, built once in `compileProgram` |
| Codegen | `slotFuncSig[slot]` + `slotIsFunc[slot]` (local/parameter), `globalFuncSig` map | the parameter-setup pass and the local-let path |

Because `Ty` itself never changes, every existing type test — `tyIsPtr`,
`exprIsPtr`, the decay rules, the `ptr<T>` stride machinery — answers for a
typed fn-pointer exactly as it did for a bare `ptr`, and the feature is
additive by construction.

## 3. The parser learns one type spelling, captured at three sites

`parseType`'s new `case TK::Fn:` branch reads the signature and parks it:

```cpp
case TK::Fn: {
    ++p; need(TK::LParen,"expected '(' after fn");
    FuncSig sig;
    if(cur().k!=TK::RParen){
        do { Ty pt=needType("<function parameter type>"); sig.params.push_back(pt); } while(eat(TK::Comma));
    }
    need(TK::RParen,"expected ')' after function parameter types");
    need(TK::Arrow,"expected '->' in a function type");
    sig.ret=needType("<function return type>");
    out=Ty::Ptr; pendingFuncType=true; pendingFuncSig=std::move(sig);
    return true;
}
```

`needType` clears the pending pair at entry, so a value parked by one type can
never leak into an unrelated one, and each of the three declaration sites
captures and resets it:

- **local `let`** — `if(pendingFuncType){s.funcSig=pendingFuncSig;s.isFunc=true;pendingFuncType=false;…}`
- **parameter** — `f.paramFuncSig.push_back(pendingFuncSig);f.paramIsFunc.push_back(true);` (the `else` arm pushes an empty pair, so the two vectors stay index-aligned with `paramDims`)
- **global** — the scalar branch carries `g.funcSig`/`g.isFunc`, and the
  initializer-less form is explicitly allowed (`else if(isFuncType&&cur().k!=TK::Eq){ need(TK::Semi,…); }`)
  so `let gop: fn(i32) -> i32;` zero-fills into `.bss` — the one spelling the
  branch added, and the one a global `ptr` always had.

Two positions are **refused**, each with a positioned diagnostic: a struct
field (`a struct field cannot have a function type (use a pointer instead)` — a
`ptr` field read with `load_ptr` is the dlsym spelling) and a function's return
(`a function cannot return a function type`).

## 4. Sema: a typed call is the direct call it stands for

`Sema` gained a `globalFuncSig` map member (file-scope signatures, built once in
`compileProgram` from `if(g.isFunc) globalFuncSigMap[g.name]=g.funcSig;`) and a
resolver that reads a local binding's signature first and the global map
second:

```cpp
const FuncSig* funcSigOf(const std::string& n) const {
    if(const Binding* b=find(n)){ if(b->isFunc) return &b->funcSig; }
    auto it=globalFuncSig.find(n);
    if(it!=globalFuncSig.end()) return &it->second;
    return nullptr;
}
```

`checkCall`'s indirect branch consults it and, when a signature exists, runs
the same checks a direct call runs — the argument **count**, then each argument
through the shared `checkArgument` (so an `i32` argument to an `i64` parameter
is the same legal widening it always was, measured by `ft_wide_shift`'s
companion cases) — and answers the signature's return type. A bare `ptr`
callee's branch is unchanged: the struct refusal and the `i32` answer stand.

## 5. Codegen: stage by the signature, read the result by it

`emitCallSeq` takes `const FuncSig* sig` and two rules follow:

```cpp
auto at=[&](size_t i)->Ty{
    if(sig&&i<sig->params.size())return sig->params[i];   // the AAPCS64 rule, now available indirectly
    return indirect?Ty::I64:(i<argT.size()?argT[i]:Ty::I32); // the bare-ptr fallback, unchanged
};
const Ty rt=indirect?(sig?sig->ret:Ty::I32):returnTypeOf(e.name);
```

`gen`'s indirect branch hands the resolver's answer over —
`int d=emitCallSeq(e,fs,0,0,true);` — and `callType` answers `fs->ret` so a
typed result type-checks at 64-bit width. The `at()` priority is what retires
the 64-bit staging rule: an `i32` argument rides in a `W` register (exactly
what a callee declaring `i32` reads), an `i64` one in a full `X` register, and
a struct argument reaches `layoutArgs` as a **composite** — a 12-byte `Tri`
splits across two registers, where a bare `ptr` was refused. For **scalars**
the two rules coincide (the 64-bit stage already served both widths — the
v0.23.24-dev design), which is why the round's load-bearing witness is the
struct case, not a scalar one; the mutant layer pins it accordingly.

The result width has one subtlety the suite earned the hard way:
`emitCallSeq` MOVs its result only when the destination temporary register
`d != 0`, so an `i64` return collapsed to `i32` is invisible unless the call is
nested inside something that forces a non-zero destination — `ft_i64_ret`
therefore reads the value back through an addition (`let r: i64 = seed + fp(big);`)
before shifting, and `ft_global_wide` does the same for the global form. Both
witnesses diverge (255 vs the C oracle's 0) under mutants m3/m4/m6, which is
what makes the `rt` rule provably load-bearing.

## 6. Two resolvers, one contract

Sema's `funcSigOf` reads `Binding`/`globalFuncSig` through `find`; Codegen's
reads `slotFuncSig`/`globalFuncSig` through `lookup`. They are independent —
the same split every other type property has — so the two passes cannot
disagree about a signature any more than they can about a stride. The suite's
source-guard layer pins that the name appears **exactly twice**, one per pass.

## 7. Coverage: `tests/function-type-checks.sh` [8/8]

1. a strict `-Werror` rebuild;
2. **source guards** pinning each piece: the `FuncSig` record, the parser's
   `fn` branch and its capture at all three declaration sites, the
   uninitialized-global branch, the two refusals, `Binding`'s two fields, both
   `funcSigOf` resolvers (and that there are exactly two), `checkCall`'s
   signature check, the `gen` hand-off (`emitCallSeq(e,fs,0,0,true)`),
   `emitCallSeq`'s signature-first `at()` and signature `rt`, `callType`'s
   typed answer, and the `globalFuncSigMap` wiring;
3. **15 gcc-differential cases** — `ft_local`, `ft_reassign` (one variable to
   two functions), `ft_wide_shift` (the `i64`-argument centrepiece),
   `ft_i64_ret`, `ft_neg64`, `ft_bool_ret`, `ft_global`, `ft_global_wide`,
   `ft_param` (the signature crossing a call as a parameter),
   `ft_zero_args`, `ft_multi` (mixed classes), `ft_stack_args` (ten arguments,
   the ninth/tenth on the stack), `ft_struct_arg` (a 12-byte struct by value,
   two registers), `ft_loop`, `ft_nested` — every one written twice, in Aster
   and in C, with the oracle `aarch64-linux-gnu-gcc -O2 -fwrapv` under qemu;
4. the shipped example against its C twin (`examples/fn_type.ast` exits 115,
   equal to `tests/function-type-twin.c`);
5. **9 rejections** — wrong count (local and global), a `ptr` argument to an
   `i32` parameter, a `bool` to an `i32`, a non-`bool` to a `bool`, the two
   type misspellings (no arrow, no parentheses), and the two position
   refusals;
6. a 7-row coverage map naming the cases each contract depends on;
7. **8 mutants**, each required to turn the battery red: m1 sema's resolver
   (a struct argument must stop compiling — the only witness that can see the
   signature check vanish), m2 the staging width (a struct must stop
   compiling), m3 the result width (the `i64` return must diverge), m4 the
   `gen` hand-off (diverge), m5 the parser's `fn` branch (a typed declaration
   must stop compiling), m6 the global wiring (diverge), m7/m8 the two
   position refusals (each must lose its diagnostic).

## 8. The v0.23.24 suite proves the old contract from the other side

`tests/indirect-call-checks.sh` is not replaced — it is re-pointed. Its source
guards followed `emitCallSeq`'s new signature, and its `at()`/`rt` guards now
pin **both** arms: the signature-first width *and* the bare-`ptr` fallback
(`return indirect?Ty::I64:…`), because the fallback *is* the contract. Its
whole battery — 19 differential cases, the `.so` structural check, 10
rejections, the coverage map and all 8 mutants — passes unchanged. That is the
round's central claim proved negatively: the new feature did not disturb the
old one.

## 9. Nothing that exists moves

```
$ HOSTCC=aarch64-linux-gnu-gcc RUNNER="qemu-aarch64 -L /usr/aarch64-linux-gnu" sh tests/ci.sh
========================================
CI SUMMARY: 94 passed, 0 skipped, 0 failed (of 94 checks)
========================================
```

One suite is new (`function-type-checks.sh`, registered in `ci.sh` beside
`indirect-call-checks.sh`), so the count moves 93 → 94. The byte baseline is
re-recorded by `tests/rebuild-baseline-v0.23.37.sh`: it filters this round's
`fn_type` rows, asserts the **309** pre-existing rows reproduce byte for byte
before it writes anything, and lands the total at **312** — the 3 new rows
belonging to `examples/fn_type.ast`. `struct-checks.sh`'s byte-identity walk
(which diffs the whole file) holds at 312/312, and `version-checks` (which
requires this report to exist, named with the version's own prefix) is green.

## 10. Deliberately not included

* **A function type in a struct field.** Refused, with a message pointing at
  the working spelling (a `ptr` field read with `load_ptr`, the dlsym shape
  v0.23.24-dev documented). A field of `fn(..)` would need the signature to
  live in the layout table, which is a struct-layout round, not this one.
* **A function returning a function type.** Refused. It composes with nothing
  yet — there is no way to *call* a returned fn-pointer without binding it to
  a variable first, and the return-type slot is a `Ty`, not a `Ty` plus a
  signature.
* **Calling through a computed pointer** (`tbl[0](x)`). Still the pre-existing
  pointer-indexing limitation; `load_ptr` into a typed variable is the
  documented route, unchanged.
* **Any change to the bare-`ptr` path.** The legacy 64-bit staging, the `i32`
  answer and the struct refusal stand exactly as v0.23.24-dev left them — the
  `indirect-call-checks.sh` guards pin the fallback arm so it cannot be
  collapsed later.
* **A `Ty` change.** The whole design avoids one; adding a `Ty::Func` would
  have moved every `tyIsPtr` test in the compiler, which is precisely the kind
  of wide blast radius this round's parallel-carriage pattern exists to avoid.

## 11. What this closes, and what it opens

The round closes the v0.23.24-dev *"no function type"* design decision — the
one its own validation report named as deliberately not included: the 64-bit
staging rule is retired for typed callees and stands, untouched, for bare
`ptr`. What it opens is the natural follow-up the struct-field refusal names:
a callback table whose entries are typed (`struct Handlers { onClick: fn(i32) -> i32 }`)
would need the signature in the layout table, and a function *returning* a
fn-pointer would need the return slot to carry one — both small, both
struct-shaped, neither needed by any program in the corpus today.
