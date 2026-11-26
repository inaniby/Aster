# Validation Report — v0.23.38-dev

**Feature: a callback table — a struct field of function type (`h.onClick(x)`)
and a function that returns one.** The v0.23.37-dev round gave a function
pointer a signature — `let fp: fn(i32) -> i32 = inc;` — and closed its own
record by naming what it had deliberately left out: *"Two positions are refused
with positioned diagnostics: a struct field of function type … and a function
returning a function type"*. Those two refusals were a scope line, not a
verdict, and they left the shape a callback table actually has unwritable: a
`struct` of handlers had to be a `struct` of bare `ptr`s, so no call site was
checked and every one of them rode at the legacy 64-bit width. This round opens
both positions and adds the call form that makes the field worth declaring.

```
# tests/callback-table-checks.sh [4/8] — the reason a field call is its own kind

fn cb(x: i32) -> i32 { return 100; }        # a function named like the field
struct H { cb: fn(i32) -> i32 }
fn inc(x: i32) -> i32 { return x + 1; }
fn main() -> i32 {
    let h: H = H { inc };
    return h.cb(41) % 251;                  # 42 — the field, not the function
}
```

```
# tests/function-return-fn-checks.sh [4/8] — the hand-off the return slot is for

fn pick(which: i32) -> fn(i32) -> i32 { … }
fn apply(op: fn(i32) -> i32, v: i32) -> i32 { return op(v); }
fn main() -> i32 {
    return apply(pick(1), 12) % 251;        # the getter's promise meets the
}                                           # callee's parameter, one check
```

## 1. Why this round exists

v0.23.37-dev put a signature beside a `ptr` in three places — a local, a
parameter, a global — and refused it in two more. The refusals were cheap
because the two positions looked like corners: a struct field and a return
type. They are not corners. They are the two positions a *callback table* is
made of:

1. **A table of handlers is a struct of function pointers.** Written as bare
   `ptr` fields, every call through one is unchecked — no argument count, no
   argument type, an `i32` answer — and the pointer has to be read out of the
   field into a variable before it can be called at all, so the call is written
   somewhere other than where the handler is named.
2. **A function that answers *which* handler is a function that returns a
   function pointer.** Refused, the only spellings left are a global the caller
   fills, or a parameter the caller passes — both of which push the choice out
   of the function whose job it is.

Neither costs anything in the layout: both are eight bytes of address, exactly
what the `ptr` they replace always was. What the signature buys is the check
where the value is written and the width where it is used.

## 2. A field carries a signature beside its eight bytes

`StructField` gains `FuncSig funcSig; bool isFunc=false;` — the same parallel
pattern `Binding`, the frame slot and the global already use — and
`structDeclaration()` captures it where it used to throw. The field's storage
type stays `Ty::Ptr` and its length stays 8, so `layoutStruct`, every offset
table and every pre-existing struct's bytes are untouched; **318 of 318**
baseline rows reproduce, of which the 309 that predate v0.23.37-dev are
byte-identical to the day they were recorded.

What the signature buys is two checks and one width:

- **Every store into the field is checked by signature, not by width.** A
  struct literal's field initializer and a field assignment both run the
  comparison, so `Handlers { double_fn, 0 }` where the field wants
  `fn(i32) -> i32` is refused *where the literal is written* —
  `type mismatch in struct literal for 'Handlers' field 'onClick': expected
  fn(i32) -> i32, got fn(i64) -> i64`.
- **A call through the field is staged by the field's signature**: the
  argument count, each argument's type, and the result read at the declared
  return type — an `i64` return at full width, a `bool` one as a bool, a `ptr`
  one as eight bytes.
- **A bare `ptr` source is deliberately *not* checked.** It carries no
  signature, and `funcSigOfExpr` answers false for it — the same rule a bare
  `ptr` has always had, kept so that untyped code keeps compiling.

An **array** of fn-pointer fields is refused (*"an array of function pointers
is not supported: Handlers.onClick"*): `cb[4]` is a second feature with its
own layout questions, and a plain `ptr[4]` field is unaffected.

## 3. `h.onClick(x)` is its own expression kind, and that is why it works

`Expr::FieldCall` is new, not `Expr::Call` with a flag, because every call site
— `gen`, `checkCall`, `callType` — keys on `e.name`, and v0.23.24-dev's "the
function always wins" rule would silently reroute a field whose name matches a
function in scope. With `fn onClick` beside `Handlers.onClick`, a `Call` node
named `onClick` is the *function*; `h.onClick(41)` would answer 100 instead of
42, with no diagnostic anywhere. `ct_clash` pins it, and mutant m6 — which
makes `postfix()` build a `Field` instead of a `FieldCall` — must stop the
program compiling.

The `Field` node is reused as the callee (`e.a`), `e.name` stays empty, and
`postfix()`'s loop admits a `(` after a field. A call's *result* may not
itself be called — `pick(0)(20)` is refused (*"cannot call the result of this
expression: assign it to a fn(...) variable or a fn(...) field first"*), as is
a call on a subscripted field's result — because a call's result is not a value
you can take an address of, and the diagnostic says where to put it instead.

## 4. The callee is read before the arguments take X0–X7

This is the round's one real codegen decision, and it was found by a wrong
answer rather than by reading. `emitStructAddr` — the address of `h.cb`,
whether `h` is a local, a `ptr<H>` parameter or a nested field — needs a
temporary register, and **the temporary pool is X0–X15**. An ordinary indirect
call reads its callee after the argument loads, from a symbol, which costs no
temporary; doing the same for a field handed `h`'s address to a register that
already held argument 1. The first cut of `examples/cb_table.ast` exited 1
instead of 87, and the disassembly showed `MOV X16, X0` overwriting the
argument after it was staged.

The fix is a position, not a new instruction: the field callee is read
immediately after `--callDepth` and **before** the register-loading loop, and
the ordinary path keeps its old one —
`if(indirect&&e.k!=Expr::FieldCall)emitCalleeAddr(9,e.name);` — so a bare-`ptr`
indirect call emits exactly the bytes it always did. Both arms are pinned by
source guards, and mutant m5 (moving the read back) must make the `ptr<H>` case
disagree with the C oracle.

## 5. A function may return a function pointer: the return slot

`fn pick(which: i32) -> fn(i32) -> i32 { … return inc; }` captures the
signature in `Function::returnFuncSig`/`returnIsFunc` where the parser used to
refuse it; the driver collects it into a `returnFuncSigMap` that Sema reads per
function, and `Stmt::Return` checks a returned pointer against it. So
`return wide;` in a function that promised `fn(i32) -> i32` is a compile error
at the `return` — `return type mismatch in function get: expected fn(i32) ->
i32, got fn(i64) -> i64` — rather than a mismatch discovered at the first call.

A call's **result answers that signature** (`funcSigOfExpr` consults
`returnFuncSig`), which is what makes `apply(pick(1), 20)` one contract
spanning two functions: the getter's promise and the callee's parameter,
compared where the argument is written. That needed the parameter side to be
visible at every call site — see §6.

What the return slot does **not** do is change codegen: `let f: fn(i32) -> i32
= pick(0);` gets its staging and result widths from `f`'s own declared type,
which is the same signature. The return slot's signature is a contract, and a
contract's worth is measured in the mistakes it refuses — which is why this
round's second suite puts its weight on the rejection matrix and its mutants
rather than pretending the battery alone proves it.

## 6. The parameter side is keyed by function name

v0.23.37-dev carried parameter signatures *inside* the `Function` being checked
(`f.paramFuncSig`), which is enough for the call sites in that function's own
body and no others — a call in a different function cannot see what `apply`'s
parameter asked for. This round adds `ParamSig { bool isFunc; FuncSig sig; }`
and a driver-built `paramFuncSigMap`, so an argument handed to a `fn(...)`
parameter is checked wherever the call is written. `isFunc` is what
distinguishes `fn() -> i32` — an empty parameter list that is a real signature
— from "no signature was declared", which is the reason the record exists at
all rather than a `std::vector<FuncSig>`.

## 7. Coverage: two resident suites, both [8/8]

**`tests/callback-table-checks.sh`** — (1) a strict `-Werror` rebuild; (2) 22
source guards (the field's member, its capture, its arrival in the layout
table, the array refusal, the `FieldCall` kind and both parser branches,
`funcSigOfExpr`/`sigEqual`/`checkPtrSig`, the field-call type check, the
parameter map, and the three codegen arms including both sides of the
callee-read position); (3) **12 gcc-differential cases** — a local host, a
`ptr<H>` parameter called through and reassigned inside a helper, the
name-clash case, the `i64` return width, zero arguments, ten with the last two
on the stack, a nested host, a read-out into a `fn` variable, reassignment, a
loop, and `bool`/`ptr` returns; (4) `examples/cb_table.ast` against its twin
(both exit 87); (5) 8 rejections; (6) a 7-row coverage map; (7) 6 mutants —
the value resolver, the comparison, the field capture, `gen`'s signature
hand-off, the callee-read position, and the parser's `FieldCall`.

**`tests/function-return-fn-checks.sh`** — (1) a strict `-Werror` rebuild; (2)
16 source guards (the return slot, its capture, sema's seed and check, the
resolver that answers a call's result, `ParamSig` and the parameter map, the
two driver collections, and the on-the-spot refusal); (3) **12
gcc-differential cases** — the getter, the hand-off, the `i64` width, the empty
parameter list, `bool`/`ptr` returns, two getters of different signature,
reassignment, a loop, ten arguments, a global `fn` slot, and a value landing in
a `fn` **field** (both halves of the round in one line); (4)
`examples/fn_ret.ast` against its twin (both exit 108); (5) 6 rejections; (6) a
7-row coverage map; (7) 6 mutants — the return check, sema's seed, the parser's
capture, the driver's collection, the parameter side, and the on-the-spot
refusal.

Every behavioural case has an Aster source *and* a C source, and the oracle is
`aarch64-linux-gnu-gcc -O2 -fwrapv` under qemu. No expectation is hand-written.

## 8. The v0.23.37 suite — and three others — are re-pointed, not replaced

`tests/function-type-checks.sh` pinned the two refusals this round retires — in
its guard layer and in its rejection matrix — so both are now inverted: the
guards assert the retired text **stays retired** (a refusal nobody watches for
is worse than no refusal at all), and the matrix refuses what the opened
positions now allow *inside* them (a returned fn-pointer of the wrong
signature; an array of fn-pointers). Its mutants m7/m8 were re-pointed at the
new lines. Its 15 differential cases, its 7-row coverage map and its other six
mutants are unchanged and still pass — the proof, from the other side, that
opening a refused position did not disturb what the refusal was protecting.

**The first full CI run of the release came back 8 red**, and every one of them
was a pin this round moved rather than a behaviour that regressed. Four
distinct causes, all in test files:

1. **Six suites count baseline rows.** `array-address`, `array-elem-types`,
   `multi-dim-array`, `precedence-checks`, `sizeof-len` and
   `struct-array-field` filter the examples their own and later rounds added,
   then assert the remainder is 288. This round's two examples added six rows,
   so each answered 294. Both examples join each filter.
2. **`indirect-call-checks.sh` pinned the callee line this round changed.**
   Its guard and its mutant m3 both spelled `if(indirect)emitCalleeAddr(9,
   e.name);`, which is now `if(indirect&&e.k!=Expr::FieldCall)`. The mutant is
   the one that matters: dropping the read must still break an indirect call.
3. **`wide-int-literal-checks.sh` counts SXTW sites — 10, now 11.** A call
   through a fn field reads an `i32` result at the field's declared return
   width, which is one more leaf widening itself from its own type. The site
   count is the round's rule (2) made countable, so the eleventh is a feature,
   not a leak.
4. **Three source guards spelled a struct the round widened.**
   `StructField` gained two members (`struct-array-field`),
   `s.fields.push_back` gained two arguments (`multi-dim-array`,
   `struct-array-field`'s m4 mutant), and `Expr::Kind`'s tail moved when
   `FieldCall` was appended after `SizeOf, Len` (`sizeof-len` — the same pin
   that moved in v0.23.35-dev, now pinned *without* the tail so a later round
   adding a kind does not have to move it again). One more mutant —
   `struct-array-field`'s m2, which splits `postfix()`'s `.`/`[` loop — spelled
   the loop condition before this round added a `(` arm to it.

That is the honest shape of the round: the compiler's behaviour for every
pre-existing program is unchanged (**318 of 318** baseline rows, the 309 that
predate v0.23.37-dev byte-identical), and what moved is the text eight suites
were written against.

## 9. Nothing that exists moves

`tests/rebuild-baseline-v0.23.38.sh` filters this round's `cb_table` and
`fn_ret` rows, asserts the 309 pre-existing rows reproduce **before** it writes
anything, and lands the total at **318**:

```
OK: 309 pre-existing lines byte-identical; 318 lines total (9 new)
```

Nothing that does not declare a function type reaches a new branch: a bare
`ptr` still stages every scalar argument at 64-bit width and still answers
`i32`; a bare-`ptr` indirect call walks exactly the instructions it always did;
a struct with no `fn` field lays out as it always has; and a `ptr` field with no
signature is checked exactly as loosely as it was before.

## 10. Deliberately not included

- **An array of fn-pointers** (`cb[4]`) — refused, with a message naming the
  field. It is a second feature with its own layout questions, and a plain
  `ptr[4]` field is unaffected.
- **A nested function type as an argument type** —
  `fn(fn(i32) -> i32) -> i32` is not parsed.
- **A call on a call's result** — `pick(0)(20)` is refused; assign it first.
- **The signature inside `Ty`** — it still rides beside the value, which is why
  every pre-existing row reproduces.
- **Any change to what a bare `ptr` does.** The round widens where a signature
  may be *declared*, not what an undeclared pointer means.

## 11. What this closes, and what it opens

This closes the v0.23.37-dev scope line — both refused positions are open, and
the callback table the function type was always for is now writable and
checked. Full CI: **96 passed / 0 skipped / 0 failed**.

What it opens is the same question one level up: a fn-pointer **inside** a
function type's parameter list, and a struct passed *by value* to a callback
whose signature declares it — both of which now have a signature to be checked
against and neither of which this round parses. Neither is promised.
