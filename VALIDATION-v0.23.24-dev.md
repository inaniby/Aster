# Validation Report — v0.23.24-dev

**Feature: `op(x)` — a call through a `ptr` variable.** Taking a function's
address had worked since the callback-table work, but every call site emitted a
relocated `BL` and no `BLR` existed, so a `ptr` holding an address could be
stored, passed and handed to C yet never *called*. This round adds the missing
half: `fp(args)` with `fp` a `ptr` local, global or parameter compiles to
`BLR X9`, with zero parser change and a byte-identical direct-call path.

```
$ ./aster build-pie examples/indirect_call.ast -o indirect_call && ./indirect_call
$ echo $?
144                                     # matches the gcc twin of the same program — §7
```

## 1. Why this round exists: the callback shape was one instruction away

A function's name in a value position *is* its address, and that address has
been a first-class `ptr` since the callback-table work: it can be stored in a
variable, passed as an argument, and handed to C through the pointer ABI. What
it could not do was be **called** — the emitter knew `BL` (a relocated direct
branch) and nothing else, so the one construct the whole pointer family exists
to enable, `fn apply(op: ptr, x: i32) -> i32 { return op(x); }`, was
unreachable. The roadmap's candidate queue named it as "a language-design
round of its own", and the honest reason is in the previous rounds' record:
nothing was *broken* — the address worked everywhere except the one place it
mattered most.

## 2. The feature: dispatch, a register window, and one staging rule

**No parser change.** `primary()` has always produced `Call{name}` for `Ident(`,
so the entire feature is dispatch in the three call sites that already exist.
Codegen's `Call` case asks `functionArities` first — **a function name in call
position is still a direct call, the function always wins**, the same rule by
which a user function shadows an intrinsic — and only then asks the new
`indirectCallee()`: a `ptr` local (not an array) or a `ptr` global (not an
array). `emitCallSeq` gained one parameter, `bool indirect=false`; the direct
path is the `indirect=false` branch and is byte-for-byte what it was.

**The register window.** `emitCalleeAddr` materializes the callee's address
into **X9 after the arguments are in their registers and before SP moves**:
X0–X7 hold the arguments, X8 is the hidden result pointer when there is one,
and X9–X15 hold nothing live — every live temporary is parked in the frame and
the staging's own temporaries have been released. The stack copies below touch
only X16/X17, so X9 survives to the `BLR X9` (`0xd63f0000|(Rn<<5)`). No
park/restore change is needed, which is what keeps the direct path at zero
risk. The local case loads the slot's contents; the **global case must load
what the global *holds*** — the first cut of this round materialized the
global's own address (`movX(reg,kGlobalBase)`) and branched into `.data`
(segfault, exit 139), caught by a smoke test before the suite existed and now
pinned by mutation m6, which restores exactly that line.

**The one design decision: there is no function type, so there is no
signature.** A `ptr` variable carries an address, not a signature — no arity
check, no parameter types, no return type beyond the fixed answer. The
consequence for arguments: **every scalar argument rides at 64-bit width**
(`at(i)` answers `Ty::I64` for an indirect call, whatever the expression's own
type). One width serves both kinds of callee: an `i32`-declaring one reads the
low half — exactly the bits a 32-bit stage would have put there — and an
`i64`-declaring one reads a properly extended full register, because AAPCS64
leaves a sub-64-bit argument's upper half unspecified and `gen()` already
extends each source type the right way. The call answers **`i32`**, the same
contract a direct call's `i32` return has always had. The first cut staged
only *over-wide literals* at 64 bits; that leaves an ABI hole the round's own
probes found (an `i32` variable or a small negative literal into an `i64`
parameter would ride with an unspecified upper half), so the rule is uniform —
`call_var64` (194) and `call_neg64` (47) pin it against gcc.

**The second half is a reachability precondition: the static linker.**
`let fp: ptr = f;` at global scope failed to link with *"global address
relocation references a function symbol 'f'"* — a restriction written for
`.so` output, whose text cannot carry load-time relocations and whose function
addresses therefore always travel through GOT slots. It had never been visible
because sema refused the *call* before the linker saw the program. Static
images know function addresses at link time and ADRP/ADD is PC-relative, so
`resolveRelocations` gained a `funcAddrDirect` parameter that `linkObjects`
(and therefore `build-elf`/`build-pie`/`link-obj`/`link-pie`) passes `true`;
the `.so` path passes `false` and is untouched.

## 3. Calling a function, before and after

| | v0.23.23-dev | v0.23.24-dev |
|---|---|---|
| `f(args)` — a function name in call position | direct `BL` | unchanged |
| `fp(args)` — `fp` a `ptr` local/global/parameter | **compile error** ("call to undeclared function") | **`BLR X9`** |
| Argument staging for the indirect call | — | every scalar at 64-bit width |
| Call result | — | `i32` (an `i64` return delivers its low half) |
| `let fp: ptr = f;` at global scope | link error ("references a function symbol") | links in static images; `.so` still routes via GOT |
| Struct argument to an indirect call | — | refused by sema (no signature to lay one out) |
| `extern` function's address | "unknown variable" | refused with the boundary named |

## 4. `tests/indirect-call-checks.sh` — seven layers, all run

Registered in `tests/ci.sh` after `icon-text-demo-checks.sh`.

**[1/7] Strict build.** `-Werror` (and `-pedantic`, as `ci.sh` builds), zero
warnings.

**[2/7] Source guards.** Sixteen pins: `indirectCallee`, the
`emitCallSeq(e,0,0,true)` dispatch, `emitCalleeAddr(9,e.name)`, the `BLR`
encoding, the 64-bit staging line, the global load form, both sema callee
messages, the extern diagnostic, the linker flag *including its call site*,
and the direct call's surviving `BL`.

**[3/7] Tool probe.** Locates `aarch64-linux-gnu-gcc` (the independent oracle)
and a runner; SKIPs cleanly without either.

**[4/7] Differential battery — 19 cases, gcc-differential.** Each case has an
Aster source and a C twin compiled by `aarch64-linux-gnu-gcc -O2 -fwrapv`, both
run under qemu, exit statuses compared — no hand-computed expectation anywhere.
Callee forms: a local pointer, one variable reassigned to two functions (the
call follows what it holds *now*), a trampoline parameter, a runtime-initialized
global before and after reassignment, and a pointer read out of a struct field
with `load_ptr` — the dlsym shape. Argument forms: none, one, ten (the ninth
and tenth travel on the stack), a wide literal and an `i32` variable into
`i64` parameters, a small negative literal, a `ptr`, a `bool`, mixed widths,
negative `i32` values. Call forms: in a loop, nested as an argument, from a
helper that calls through the pointer twice. Precedence: a function wins over
a same-named `ptr` variable in call position (the twin spells the direct call
explicitly, because C's own scoping would answer the other way — this case
pins Aster's documented rule, not the platform ABI).

**[4b/7] Shared object.** The `.so` builds, contains a register branch, and
its text carries **no** load-time relocation — the GOT-slot discipline the
`funcAddrDirect` flag deliberately leaves in place for shared objects.

**[4c/7] The shipped example, against its twin.** `examples/indirect_call.ast`
— every callee form in one program — is built and run beside
`tests/indirect-call-example-twin.c`, compiled by the same oracle; the two
exit statuses must agree (both exit 144, normalized to -112 by the suite's
8-bit convention). The byte baseline records the example's three build modes;
this layer records that it still runs to the number its header claims.

**[5/7] Rejection matrix — 10 cases.** An `i32`, `bool` or struct local as
callee; a local or global array as callee; an `i32` global; an undeclared
name; a struct argument; an extern function as the pointer's value; a `bool`
consumed from the result — each demanding the diagnostic that names the
offending thing.

**[6/7] Coverage map.** Ten contract regressions must stay resident: the five
callee forms, the stack-argument shape, the wide-literal and variable `i64`
stagings, the memory-resident pointer, and the precedence rule. Deleting one
without updating the map fails the map.

**[7/7] Mutation layer — 8 mutants.** Dispatch dropped (m1), `BLR` demoted to
`BR` (m2), callee not materialized (m3), sema resolution dropped (m4), 64-bit
staging reverted to 32-bit (m5), the global callee loading its own address
(m6), the static linker's function-address permission withdrawn (m7), and the
sema struct-argument diagnostic removed (m8). A check that passes on a damaged
compiler is not checking anything.

**Two mutation-layer corrections are on the record, because both were the
layer doing its job.** m5 initially pointed at `call_wide_literal` and
**survived**: that probe's observable is the callee's `i64` result read at
`i32` width, and addition is congruence-preserving mod 2^32, so the low half
of a sum cannot see a truncated argument — a blind probe, not a weak mutant.
The battery gained `call_wide_shift` (`a >> 32`; the answer *is* the
argument's upper half — 232 against 0), and m5 now diverges on it. m4's sed
replacement (`if(const Binding* b=…)` → `if(false)`) failed to build because
the block's body uses `b`; it now uses the C++17 if-init form
(`if(const Binding* b=find(e.name);false)`), which keeps the declaration and
skips the block. m8's first form demanded the refused program *compile* with
sema's check removed — it does not, because codegen's own struct-as-value
guard refuses it with a worse message; the honest assertion is that the
specific diagnostic vanishes, which is what the mutation now requires.

## 5. What this deliberately does not do

- **It does not add a function type.** `fn`-typed variables, typed parameters
  and signature checking are a larger language-design round — the thing that
  would retire the 64-bit staging rule, and the reason this round is "one
  sentence of surface" rather than a type system change.
- **It does not support calling through a computed pointer.** `tbl[0] = inc;`
  still meets the pre-existing "pointer indexing/assignment is not supported
  yet" limitation. The memory-resident shape (`load_ptr(&struct)`) works and
  is the documented route — the dlsym shape.
- **It does not deliver an `i64` result.** The call answers `i32`; a callee
  returning `i64` has its low half delivered. Wrap in the callee if the whole
  value matters.
- **It does not touch the trampoline's own convention.** `apply(op: ptr, x: i32)`
  is an ordinary direct call whose body contains the indirect one.

## 6. Byte identity: 282 of 282

`tests/struct-checks.sh` [4/8] re-hashes every example in three modes
(`build-so`, `build-elf`, `build-obj --pic`) against
`tests/baseline/v0.23.5-dev/example-hashes.txt` and **passed with the round's
compiler**: the 279 pre-existing rows byte-identical, plus 3 new rows recording
`examples/indirect_call.ast`. The diff against the previous recording is three
additions and zero changes. This holds *by construction*: the direct-call
path is the `indirect=false` branch and is untouched, the `.so` path is
untouched, the linker change only *permits* previously rejected programs, and
no pre-existing example can contain an indirect call (it used to be a compile
error). The re-recording itself was verified by
`tests/rebuild-baseline-v0.23.24.sh`, which refuses to write the file unless
every old row reproduces.

## 7. Verification log

| Step | Result |
|---|---|
| Strict `-Werror` (+ `-pedantic`) build of the modified compiler | clean |
| `examples/indirect_call.ast` vs its C twin | both exit 144 (r1=41 r2=40 r3=9 r4=7 r5=5 r6=42) |
| `indirect-call-checks.sh` [4/7] battery | **19/19 match the C oracle** |
| `indirect-call-checks.sh` [4b/7] shared object | builds, branches through a register, no text relocations |
| `indirect-call-checks.sh` [4c/7] shipped example vs its C twin | **both exit 144** |
| `indirect-call-checks.sh` [5/7] rejections | **10/10** rejected with the naming diagnostic |
| `indirect-call-checks.sh` [6/7] coverage map | 10 named cases resident |
| `indirect-call-checks.sh` [7/7] mutations | **8/8** correctly turn the battery red |
| First-cut defect: global callee materialized its own address | segfault (139) before the suite existed; fixed (`loadGlobalT`) and pinned by m6 |
| First-cut design hole: only over-wide literals staged at 64 bits | found by the round's own probes (`var64`/`neg64`); rule made uniform |
| Extern-function address diagnostic | was "unknown variable"; now names the boundary — suite expectation and guard updated |
| Mutation m5's first target (`call_wide_literal`) | survived — addition is congruence-preserving mod 2^32; replaced by `call_wide_shift` (232 vs 0) |
| Mutation m4's sed form | failed to build (`b` undeclared); now C++17 if-init |
| Mutation m8's first form | demanded the refused program compile — codegen's own guard refuses it; now demands the diagnostic vanish |
| First full CI run: **80 passed / 0 skipped / 1 failed** | `wide-int-literal-checks.sh` [2/7] "total SXTW sites: expected 8, found 9" — the round's ninth SXTW leaf (an indirect call's i32 result sign-extended for a 64-bit consumer, the Call rule applied to the untyped callee). A guard doing its job, not a regression: the count is now 9 with the reason recorded at the guard, and the suite passes. The mechanical re-evaluation of every other count guard found no second casualty |
| `struct-checks.sh` [4/8] baseline | **282 recorded outputs reproduced byte for byte** (279 old + 3 new) |
| Full CI | see §8 |

## 8. Full CI

```
========================================
CI SUMMARY: 81 passed, 0 skipped, 0 failed (of 81 checks)
========================================
```

| CI | v0.23.23-dev | v0.23.24-dev |
|---|---|---|
| Result | 80 passed / 0 skipped / 0 failed | **81 passed / 0 skipped / 0 failed** |
| Checks | 80 | 81 (+1: `indirect-call-checks.sh`) |
| Baseline rows | 279 (all unchanged) | 282 (279 unchanged + 3 new) |
| New resident suite | `narrow-memory-checks.sh` | `indirect-call-checks.sh` |

## 9. What this unblocks

- **The callback shape is now writable.** `fn apply(op: ptr, x: i32) -> i32
  { return op(x); }` — a table of operations, a dispatcher, a comparator, a
  trampoline — compiles and runs, and a pointer that crossed a call as a
  parameter, a runtime-initialized global, or a struct field read back with
  `load_ptr` can be the callee. That is the construct the whole pointer
  family has existed to enable.
- **Function addresses are now static-linkable.** `let fp: ptr = f;` links in
  `build-elf`/`build-pie`/`link-obj`/`link-pie`, so a global table of
  operations is expressible without a host; `.so` output keeps the GOT-slot
  discipline unchanged.
- **The boundary of the feature is written down, not discovered later.** No
  function type means no signature means 64-bit staging and an `i32` answer —
  all three pinned by the differential battery — and the computed-pointer
  shape (`tbl[0] = inc`) is recorded as the pre-existing pointer-indexing
  limitation with `load_ptr(&struct)` as the documented route.
- **Still open, in the order the difficulty audit argued:** the
  debug-information slice (`.debug_info` on top of the v0.23.12-dev line
  table), then the audit-ranked backlog.
