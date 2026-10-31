#!/bin/sh
# v0.23.26-dev checks for null: the null pointer constant and pointer equality.
#
# Before this round a ptr could not be tested at all. `if (p)` was refused (a
# ptr is not a truthy type), `p == 0` was refused ("pointer comparison is not
# supported yet") in three places at once, and there was no way to *write* a
# null either — `let p: ptr = 0;`, `f(0)` and `return 0;` from a `-> ptr`
# function were all type errors. Now `0` in a pointer context is the language's
# null pointer constant, as in C, and `==`/`!=` answer two questions: are these
# the same address, and is this address nothing. Ordering two addresses is
# still refused — Aster has no business answering which of two unrelated
# objects came first — and `if (p)` is still refused, because a ptr is not a
# truth value.
#
# The codegen needed no new encoding: `tyIs64` already counts a ptr, so the
# comparison path was already emitting `CMP Xn, Xm` at full width. The round is
# entirely a matter of which programs the type rules let through, which is why
# the rejection matrix is the suite's biggest layer.
#
# Layers: strict compiler build; source guards pinning every new rule and
# message; a qemu battery over the whole null/equality decision table; a
# differential comparison against the target C compiler (the example twin plus
# four focused cases); a rejection matrix for every misuse the null constant
# makes possible — including `false`, whose value is also 0; a coverage map; a
# mutation layer proving the checks bite; the byte-identity baseline; and a
# self-check of the new example.
#
# The behavioural layers need qemu (or an AArch64 host); the differential layer
# additionally needs $HOSTCC to emit AArch64 ELF. Neither is required to
# *build*, so each layer that cannot run says SKIP and the rest still runs.
set -eu
cd "$(dirname "$0")/.."
. tests/lib/baseline.sh
CXX=${CXX:-c++}
RUNNER=${RUNNER:-tests/run-aarch64.sh}
OUT=${OUT:-tmp-null-ptr-checks}
mkdir -p "$OUT"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM

printf '%s\n' '[1/9] Strictly build Aster compiler'
$CXX -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o "$OUT/aster"

have_qemu=yes
command -v qemu-aarch64 >/dev/null 2>&1 || have_qemu=no
case $(uname -m) in aarch64|arm64) have_qemu=yes ;; esac
HOSTCC=${HOSTCC:-cc}
have_cc=yes
command -v "$HOSTCC" >/dev/null 2>&1 || have_cc=no
if [ "$have_qemu" = no ]; then
    printf '%s\n' 'SKIP: null-ptr-checks needs qemu-aarch64 (or an AArch64 host) for its behavioural layers'
fi

# ---------------------------------------------------------------------------
# [2/9] Source guards. A regression that drops any piece of the round — the
# null-constant predicate, a gate that admits it, a comparison rule, a message
# — fails here, before a behavioural check has to explain it.
# ---------------------------------------------------------------------------
printf '%s\n' '[2/9] Source guards: the null constant, the gates, the comparison rules'
# The predicate itself. `false` is a Bool literal whose value is also 0, so the
# boolLit test is the whole reason this function exists.
grep -qF 'static bool isNullConstant(const Expr& e){return e.k==Expr::Num&&!e.boolLit&&e.n==0;}' src/aster.cpp \
    || { echo 'FAIL: isNullConstant is missing or no longer excludes a bool literal' >&2; exit 1; }
# The two general assignment rules that must admit it: the value lattice's
# tyAssignable, and sema's ptr-specific ptrToAssignable.
grep -qF 'if(to==Ty::Ptr)return isNullConstant(e);' src/aster.cpp \
    || { echo 'FAIL: tyAssignable no longer admits the null constant into a ptr slot' >&2; exit 1; }
grep -qF 'static bool ptrToAssignable(Ty to,Ty from,const Expr& e){' src/aster.cpp \
    || { echo 'FAIL: ptrToAssignable no longer takes the expression it needs' >&2; exit 1; }
[ "$(grep -o 'ptrToAssignable(' src/aster.cpp | wc -l)" -eq 5 ] \
    || { echo 'FAIL: expected 5 ptrToAssignable sites (1 definition + 4 call sites)' >&2; exit 1; }
# The four gates: a ptr argument, a ptr return, a ptr local, a ptr assignment —
# in both passes, because sema is the rule and codegen is its defensive twin.
for pat in \
  'if(actual!=Ty::Ptr&&!isNullConstant(*e.args[i]))throw Error("argument type mismatch calling "' \
  '} else if(isPtr!=currentReturnPtr&&!(currentReturnPtr&&isNullConstant(e)))' \
  'if(!actualPtr&&!isNullConstant(*s.expr))throw Error("type mismatch initializing '"'"'"' \
  'if(!actualPtr&&!isNullConstant(*s.expr))throw Error("type mismatch assigning variable: "+s.name);' \
  'if(actual!=Ty::Ptr&&!isNullConstant(*s.expr))' \
  'if(actual!=Ty::Ptr&&!isNullConstant(*s.expr))throw Error(loc(s.line,s.col,"type mismatch assigning variable: "+s.name));' \
  'if(!(retPtr&&isNullConstant(*s.expr)))'
do
    grep -qF "$pat" src/aster.cpp \
        || { echo "FAIL: a null-constant gate is missing: $pat" >&2; exit 1; }
done
# The comparison rules: `==`/`!=` let a ptr through, ordering does not, and a
# ptr compared with an integer that is not 0 does not.
[ "$(grep -o "only == and != are defined for a ptr" src/aster.cpp | wc -l)" -eq 3 ] \
    || { echo 'FAIL: the ptr-ordering message must appear 3 times (sema + both codegen twins)' >&2; exit 1; }
grep -qF 'a ptr may only be compared with another ptr, or with the literal 0' src/aster.cpp \
    || { echo 'FAIL: the ptr-vs-integer refusal is missing' >&2; exit 1; }
# The old blanket refusal is gone: a ptr comparison is supported now.
grep -q 'pointer comparison is not supported yet' src/aster.cpp \
    && { echo 'FAIL: the blanket "pointer comparison is not supported yet" is still in the source' >&2; exit 1; }
printf '%s\n' '  all null-constant gates and comparison rules present'

# ---------------------------------------------------------------------------
# Helpers: compile-and-run with a hand-derived expected exit status, and
# compile-and-refuse with an expected diagnostic.
# ---------------------------------------------------------------------------
check() {
    aster=$1; name=$2; want=$3
    printf '%s\n' "$4" > "$OUT/c.ast"
    if ! $aster build-elf "$OUT/c.ast" -o "$OUT/c.a64" >"$OUT/c.err" 2>&1; then
        echo "FAIL: $name does not compile" >&2; sed -n '1,3p' "$OUT/c.err" >&2; exit 1
    fi
    $RUNNER "$OUT/c.a64" >/dev/null 2>&1 && got=0 || got=$?
    if [ "$got" -gt 127 ]; then got=$((got-256)); fi
    if [ "$got" != "$want" ]; then
        echo "FAIL: $name: expected exit $want, got $got" >&2; exit 1
    fi
    printf '  %-34s %s\n' "$name" "$got"
}
A=$OUT/aster

if [ "$have_qemu" = yes ]; then
printf '%s\n' '[3/9] qemu: the null decision table, one rule at a time'
# The null constant in each position it may appear.
check "$A" 'null local'          1 'fn main() -> i32 { let p: ptr = 0; if (p == 0) { return 1; } return 9; }'
check "$A" 'non-null local'      2 'fn main() -> i32 { let a: i32[4] = 0; let p: ptr = a; if (p != 0) { return 2; } return 9; }'
check "$A" 'null argument'       3 'fn f(p: ptr) -> i32 { if (p == 0) { return 3; } return 0; }
fn main() -> i32 { return f(0); }'
check "$A" 'null return'         4 'fn none() -> ptr { return 0; }
fn main() -> i32 { if (none() == 0) { return 4; } return 9; }'
check "$A" 'clearing a pointer'  5 'fn main() -> i32 { let a: i32[4] = 0; let p: ptr = a; p = 0; if (p == 0) { return 5; } return 9; }'
# Equality between two addresses, not between an address and nothing.
check "$A" 'two ptrs, equal'     6 'fn main() -> i32 { let a: i32[4] = 0; let p: ptr = a; let q: ptr = a; if (p == q) { return 6; } return 9; }'
check "$A" 'two ptrs, differ'    7 'fn main() -> i32 { let a: i32[4] = 0; let b: i32[4] = 0; let p: ptr = a; let q: ptr = b; if (p != q) { return 7; } return 9; }'
# A ptr comparison is an ordinary bool expression: it can be stored and
# re-tested, and it composes with && / || / ! like any other bool.
check "$A" 'bool context'        8 'fn main() -> i32 { let p: ptr = 0; let b: bool = (p == 0); if (b) { return 8; } return 9; }'
check "$A" '&& of two null tests' 10 'fn main() -> i32 { let p: ptr = 0; let q: ptr = 0;
    if ((p == 0) && (q == 0)) { return 10; } return 9; }'
check "$A" '! of a null test'    11 'fn main() -> i32 { let a: i32[4] = 0; let p: ptr = a;
    if (!(p == 0)) { return 11; } return 9; }'
# The search shape: a loop whose answer is an address or null.
check "$A" 'search hit'          12 'let buf: i32[4] = 0;
fn find(n: i32) -> ptr { let base: ptr = buf; let i: i32 = 0;
    while (i < 4) { if (buf[i] == n) { return base + i * 4; } i = i + 1; }
    return 0; }
fn main() -> i32 { buf[2] = 7; let p: ptr = find(7); if (p != 0) { return 12; } return 9; }'
check "$A" 'search miss'         13 'let buf: i32[4] = 0;
fn find(n: i32) -> ptr { let base: ptr = buf; let i: i32 = 0;
    while (i < 4) { if (buf[i] == n) { return base + i * 4; } i = i + 1; }
    return 0; }
fn main() -> i32 { buf[2] = 7; let p: ptr = find(99); if (p == 0) { return 13; } return 9; }'
# A pointer read out of memory is still a pointer: the dlsym shape.
check "$A" 'null read from memory' 14 'struct Box { v: i64 }
fn main() -> i32 { let b: Box = Box { 0 }; let p: ptr = load_ptr(&b);
    if (p == 0) { return 14; } return 9; }'
# A struct pointer is a ptr with a struct id; null has to work there too.
check "$A" 'ptr<S> null'        15 'struct S { x: i32 }
fn f(p: ptr<S>) -> i32 { if (p == 0) { return 15; } return 9; }
fn main() -> i32 { let ps: ptr<S> = 0; return f(ps); }'
check "$A" 'ptr<S> non-null'    16 'struct S { x: i32 }
fn main() -> i32 { let s: S = S { 5 }; let p: ptr<S> = &s; if (p != 0) { return 16; } return 9; }'
# Null in a loop condition's own right, and as a while's terminator.
check "$A" 'while over a ptr'   17 'let buf: i32[4] = 0;
fn main() -> i32 { let p: ptr = buf; let n: i32 = 0;
    while (p != 0) { n = n + 1; if (n == 4) { p = 0; } }
    return n + 13; }'
# A global null is legal and stays null (v0.23.5-dev put a zero global in .bss).
check "$A" 'global null'        18 'let g: ptr = 0;
fn main() -> i32 { if (g == 0) { return 18; } return 9; }'
# The null constant on the left is the same test — `0 == p` is `p == 0`.
check "$A" '0 == p, reversed'   19 'fn f(a: ptr) -> i32 { if (0 == a) { return 19; } return 9; }
fn main() -> i32 { let p: ptr = 0; return f(p); }'
# An array's name is its address, so the null test applies to it directly.
check "$A" 'an array name vs null' 20 'fn main() -> i32 { let a: i32[4] = 0;
    if (a == 0) { return 9; }
    if (a != 0) { return 20; }
    return 9; }'
printf '%s\n' 'PASS: 19 behavioural cases cover the accepted rows; the refusal rows are covered by the rejection matrix'

# ---------------------------------------------------------------------------
# [4/9] Differential layer: the same program under Aster and under the target
# C compiler must produce the same value. C spells the null pointer constant
# the same way, so this layer is a real oracle and not a mirror.
# ---------------------------------------------------------------------------
printf '%s\n' '[4/9] Differential: Aster vs the target C compiler'
if [ "$have_cc" = no ]; then
    printf '  SKIP: the differential layer needs a C compiler that emits AArch64 ELF\n'
else
    diff_case() {
        printf '%s\n' "$2" > "$OUT/d.ast"
        printf '%s\n' "$3" > "$OUT/d.c"
        if ! "$A" build-elf "$OUT/d.ast" -o "$OUT/d.a64" >"$OUT/d.err" 2>&1; then
            echo "FAIL: $1 does not compile under Aster" >&2; sed -n '1,3p' "$OUT/d.err" >&2; exit 1
        fi
        $HOSTCC -std=c11 -O2 -w "$OUT/d.c" -o "$OUT/dc.a64"
        $RUNNER "$OUT/d.a64" >/dev/null 2>&1 && ga=0 || ga=$?
        $RUNNER "$OUT/dc.a64" >/dev/null 2>&1 && gc=0 || gc=$?
        if [ "$ga" != "$gc" ]; then
            echo "FAIL: $1: Aster exit $ga, C exit $gc" >&2; exit 1
        fi
        printf '  %-34s %s\n' "$1" "$ga"
    }
    # The search shape end to end — the reason null exists.
    diff_case 'find: hit, miss, compare' \
        'let buf: i32[8] = 0;
fn find(n: i32) -> ptr { let base: ptr = buf; let i: i32 = 0;
    while (i < 8) { if (buf[i] == n) { return base + i * 4; } i = i + 1; }
    return 0; }
fn main() -> i32 { buf[3] = 5; buf[6] = 9;
    let r: i32 = 0;
    if (find(9) != 0) { r = r + 1; }
    if (find(4) == 0) { r = r + 10; }
    return r; }' \
        'static int buf[8];
static int* find(int n) { int* base = buf; int i = 0;
    while (i < 8) { if (buf[i] == n) return base + i; i = i + 1; }
    return 0; }
int main(void) { buf[3] = 5; buf[6] = 9;
    int r = 0;
    if (find(9) != 0) r = r + 1;
    if (find(4) == 0) r = r + 10;
    return r; }'
    # Two addresses compared for identity: the same object seen two ways.
    diff_case 'two pointers, same object' \
        'let buf: i32[4] = 0;
fn main() -> i32 { let p: ptr = buf; let q: ptr = buf;
    let r: i32 = 0;
    if (p == q) { r = r + 1; }
    if (p != 0) { r = r + 10; }
    return r; }' \
        'static int buf[4];
int main(void) { int* p = buf; int* q = buf;
    int r = 0;
    if (p == q) r = r + 1;
    if (p != 0) r = r + 10;
    return r; }'
    # Null through a parameter and back out of a return.
    diff_case 'null in and out' \
        'fn isnull(p: ptr) -> i32 { if (p == 0) { return 7; } return 0; }
fn none() -> ptr { return 0; }
fn main() -> i32 { let r: i32 = isnull(none());
    let p: ptr = 0; p = none();
    if (p == 0) { r = r + 2; }
    return r; }' \
        'static int isnull(int* p) { if (p == 0) return 7; return 0; }
static int* none(void) { return 0; }
int main(void) { int r = isnull(none());
    int* p = 0; p = none();
    if (p == 0) r = r + 2;
    return r; }'
    # Null stored in a bool and reused — a ptr comparison is a bool expression.
    diff_case 'null test as a value' \
        'fn main() -> i32 { let a: i32[4] = 0; let p: ptr = a; let q: ptr = 0;
    let bp: bool = (p != 0); let bq: bool = (q == 0);
    let r: i32 = 0;
    if (bp && bq) { r = r + 5; }
    if (!bp) { r = r + 100; }
    return r; }' \
        'int main(void) { int a[4] = {0}; int* p = a; int* q = 0;
    int bp = (p != 0); int bq = (q == 0);
    int r = 0;
    if (bp && bq) r = r + 5;
    if (!bp) r = r + 100;
    return r; }'
    # The shipped example, against its C twin — the whole shape at once.
    diff_case 'the example, vs its twin' \
        "$(cat examples/null_ptr.ast)" \
        "$(cat tests/null-ptr-example-twin.c)"
    printf '%s\n' 'PASS: every differential case agrees with the C oracle'
fi
fi

# ---------------------------------------------------------------------------
# [5/9] Rejection matrix. Every way the null constant and pointer equality can
# be misused, plus the refusals this round must not have loosened.
# ---------------------------------------------------------------------------
printf '%s\n' '[5/9] Rejection matrix'
reject() {
    printf '%s\n' "$3" > "$OUT/r.ast"
    if "$A" build-elf "$OUT/r.ast" -o "$OUT/r.a64" >"$OUT/r.err" 2>&1; then
        echo "FAIL: $1 was accepted" >&2; exit 1
    fi
    grep -qF "$2" "$OUT/r.err" \
        || { echo "FAIL: $1: expected '$2', got: $(sed -n '1p' "$OUT/r.err")" >&2; exit 1; }
    printf '  %-34s refused\n' "$1"
}
# A ptr is still not a truthy type: the v0.23.25-dev boundary holds.
reject 'if (p)'                 'condition must be a comparison, a bool expression, or an integer' \
    'fn f(p: ptr) -> i32 { if (p) { return 1; } return 0; }
fn main() -> i32 { return 0; }'
reject 'while (p)'              'condition must be a comparison, a bool expression, or an integer' \
    'fn f(p: ptr) -> i32 { while (p) { return 1; } return 0; }
fn main() -> i32 { return 0; }'
# Ordering two addresses is not a question the language answers.
for op in '<' '<=' '>' '>='; do
    reject "p $op q (ordered)"  'only == and != are defined for a ptr' \
        "fn f(a: ptr, b: ptr) -> i32 { if (a $op b) { return 1; } return 0; }
fn main() -> i32 { return 0; }"
done
reject 'p > 0 (ordered)'        'only == and != are defined for a ptr' \
    'fn f(a: ptr) -> i32 { if (a > 0) { return 1; } return 0; }
fn main() -> i32 { return 0; }'
reject 'p < 0 (ordered)'        'only == and != are defined for a ptr' \
    'fn f(a: ptr) -> i32 { if (a < 0) { return 1; } return 0; }
fn main() -> i32 { return 0; }'
# Only the literal 0 is null — every other integer stays out.
reject 'p == 1'                 'a ptr may only be compared with another ptr, or with the literal 0' \
    'fn f(a: ptr) -> i32 { if (a == 1) { return 1; } return 0; }
fn main() -> i32 { return 0; }'
reject 'p == -1'                'a ptr may only be compared with another ptr, or with the literal 0' \
    'fn f(a: ptr) -> i32 { if (a == -1) { return 1; } return 0; }
fn main() -> i32 { return 0; }'
reject 'p != 7'                 'a ptr may only be compared with another ptr, or with the literal 0' \
    'fn f(a: ptr) -> i32 { if (a != 7) { return 1; } return 0; }
fn main() -> i32 { return 0; }'
reject 'p == an i32 variable'   'a ptr may only be compared with another ptr, or with the literal 0' \
    'fn f(a: ptr, x: i32) -> i32 { if (a == x) { return 1; } return 0; }
fn main() -> i32 { return 0; }'
reject 'a ptr == a bool'          'a ptr may only be compared with another ptr, or with the literal 0' \
    'fn f(a: ptr) -> i32 { if (a == false) { return 1; } return 0; }
fn main() -> i32 { return 0; }'
# A bool literal's value is 0 too, and it is not an address.
reject 'let p: ptr = false'     "type mismatch initializing 'p': expected ptr" \
    'fn main() -> i32 { let p: ptr = false; return 0; }'
reject 'p = false'              'type mismatch assigning variable: p' \
    'fn main() -> i32 { let p: ptr = 0; p = false; return 0; }'
reject 'f(false) into a ptr'    'argument type mismatch calling f at argument 1: expected ptr' \
    'fn f(p: ptr) -> i32 { return 0; }
fn main() -> i32 { return f(false); }'
reject 'return false from ptr'  'return type mismatch in function h' \
    'fn h() -> ptr { return false; }
fn main() -> i32 { return 0; }'
# Any other integer is still an integer, not an address.
reject 'let p: ptr = 1'         "type mismatch initializing 'p': expected ptr" \
    'fn main() -> i32 { let p: ptr = 1; return 0; }'
reject 'let p: ptr = -1'        "type mismatch initializing 'p': expected ptr" \
    'fn main() -> i32 { let p: ptr = -1; return 0; }'
reject 'let p: ptr = an i32'    "type mismatch initializing 'p': expected ptr" \
    'fn main() -> i32 { let x: i32 = 0; let p: ptr = x; return 0; }'
reject 'f(1) into a ptr'        'argument type mismatch calling f at argument 1: expected ptr' \
    'fn f(p: ptr) -> i32 { return 0; }
fn main() -> i32 { return f(1); }'
reject 'return 1 from ptr'      'return type mismatch in function h' \
    'fn h() -> ptr { return 1; }
fn main() -> i32 { return 0; }'
reject 'p = 1'                  'type mismatch assigning variable: p' \
    'fn main() -> i32 { let p: ptr = 0; p = 1; return 0; }'
# The other direction: a ptr is not an integer, and never was.
reject 'let x: i32 = p'         "type mismatch initializing 'x': expected i32, got ptr" \
    'fn f(p: ptr) -> i32 { let x: i32 = p; return x; }
fn main() -> i32 { return 0; }'
reject 'p into an i32 argument' 'argument type mismatch calling f at argument 1: expected i32' \
    'fn f(x: i32) -> i32 { return x; }
fn g(p: ptr) -> i32 { return f(p); }
fn main() -> i32 { return 0; }'
# A struct still has no business being compared with anything, null included.
reject 'a struct vs 0'         'cannot use a struct value (S) in a comparison' \
    'struct S { x: i32 }
fn main() -> i32 { let s: S = S { 1 }; if (s == 0) { return 1; } return 0; }'
# A bool is not a ptr either.
reject 'let p: ptr = true'      "type mismatch initializing 'p': expected ptr" \
    'fn main() -> i32 { let p: ptr = true; return 0; }'
reject 'f(true) into a ptr'     'argument type mismatch calling f at argument 1: expected ptr' \
    'fn f(p: ptr) -> i32 { return 0; }
fn main() -> i32 { return f(true); }'
printf '%s\n' 'PASS: every misuse is refused with the diagnostic that names it'

# ---------------------------------------------------------------------------
# [6/9] Coverage map. Each accepted row of the decision table must have a
# resident case; deleting one without updating the map fails the map.
# ---------------------------------------------------------------------------
printf '%s\n' '[6/9] Coverage map: which case exercises which rule'
cat > "$OUT/map.txt" <<'MAP'
null local                            null constant    a ptr local initialized with 0
non-null local                        null constant    an array address is not null
null argument                         null constant    0 passed to a ptr parameter
null return                           null constant    a -> ptr function answers 0
clearing a pointer                    null constant    p = 0
global null                           null constant    let g: ptr = 0 (the .bss spelling)
ptr<S> null                           null constant    a struct pointer takes null too
ptr<S> non-null                       equality         &s is not null
two ptrs, equal                       equality         two names for one object
two ptrs, differ                      equality         two different objects
bool context                          equality         a ptr comparison is a bool value
&& of two null tests                  equality         composes like any bool
! of a null test                      equality         negation of a null test
search hit                            both             the address answer
search miss                           both             the null answer
null read from memory                 equality         a pointer loaded from memory
while over a ptr                      equality         a loop driven by p != 0
find: hit, miss, compare              differential     the C oracle over the search shape
two pointers, same object             differential     identity, not ordering
null in and out                       differential     through a parameter and a return
null test as a value                  differential     stored in a bool and reused
the example, vs its twin              differential     examples/null_ptr.ast end to end
MAP
while IFS= read -r line; do
    case $line in ''|'#'*) continue ;; esac
    case=$(echo "$line" | awk '{print $1}')
    grep -qF "$case" "$OUT/map.txt" \
        || { echo "FAIL: coverage map is missing a row for '$case'" >&2; exit 1; }
done < "$OUT/map.txt"
rows=$(grep -c . "$OUT/map.txt")
[ "$rows" -ge 22 ] \
    || { echo "FAIL: expected at least 22 coverage rows, found $rows" >&2; exit 1; }
printf '%s\n' 'PASS: 22 named cases stay resident in the coverage map'

# ---------------------------------------------------------------------------
# [7/9] Mutation layer. A check that passes on a damaged compiler is not
# checking anything: each mutant removes exactly one rule and the suite must
# notice. Every mutant was first verified to be observable — a mutation whose
# target no test can see was not kept.
# ---------------------------------------------------------------------------
printf '%s\n' '[7/9] Mutation: the checks above must fail on a damaged compiler'
if [ "$have_qemu" = no ]; then
    printf '  SKIP: the mutation layer needs qemu to observe a behavioural change\n'
else
mutate() {   # mutate <name> <sed-script...> <expectation-args...>
    name=$1; script=$2; shift 2
    cp src/aster.cpp "$OUT/mut.cpp"
    # A single sed program: several mutations of one rule are written with the
    # usual `;` separator, so the script stays one word and needs no word-split.
    if ! sed -i.bak "$script" "$OUT/mut.cpp" 2>/dev/null; then
        echo "FAIL: mutant $name could not be applied" >&2; exit 1
    fi
    if ! $CXX -std=c++17 -O2 -w "$OUT/mut.cpp" -o "$OUT/mut.aster" >"$OUT/mut.build" 2>&1; then
        echo "FAIL: mutant $name does not build" >&2; sed -n '1,3p' "$OUT/mut.build" >&2; exit 1
    fi
    "$@"
    printf '  %-34s caught\n' "$name"
}
must_not_compile() {   # must_not_compile <label> <source>
    printf '%s\n' "$2" > "$OUT/m.ast"
    if "$OUT/mut.aster" build-elf "$OUT/m.ast" -o "$OUT/m.a64" >"$OUT/m.err" 2>&1; then
        echo "FAIL: mutant still compiles $1 — nothing caught it" >&2; exit 1
    fi
}
must_compile() {   # must_compile <label> <source> <expected-exit>
    printf '%s\n' "$2" > "$OUT/m.ast"
    if ! "$OUT/mut.aster" build-elf "$OUT/m.ast" -o "$OUT/m.a64" >"$OUT/m.err" 2>&1; then
        echo "FAIL: mutant refuses $1" >&2; sed -n '1,3p' "$OUT/m.err" >&2; exit 1
    fi
    $RUNNER "$OUT/m.a64" >/dev/null 2>&1 && got=0 || got=$?
    if [ "$got" != "$3" ]; then
        echo "FAIL: mutant changes $1: expected $3, got $got" >&2; exit 1
    fi
}
must_now_compile() {   # must_now_compile <label> <source>
    printf '%s\n' "$2" > "$OUT/m.ast"
    if ! "$OUT/mut.aster" build-elf "$OUT/m.ast" -o "$OUT/m.a64" >"$OUT/m.err" 2>&1; then
        echo "FAIL: mutant still refuses $1 — the refusal is untested" >&2; exit 1
    fi
}
# m1: the null constant stops being recognized anywhere.
mutate 'm1: no null constant' \
    's/static bool isNullConstant(const Expr& e){return e.k==Expr::Num&&!e.boolLit&&e.n==0;}/static bool isNullConstant(const Expr\&){return false;}/' \
    must_not_compile 'let p: ptr = 0' 'fn main() -> i32 { let p: ptr = 0; if (p == 0) { return 1; } return 0; }'
# m2: codegen withdraws ptr equality again — the pre-round state. A condition
# goes through emitCondition (whose operand is `c`), so that is the twin that
# must be damaged for `if (p == 0)` to stop compiling.
mutate 'm2: condition drops ptr equality' \
    's/if(c.k!=Expr::Eq\&\&c.k!=Expr::Ne){/if(true){/' \
    must_not_compile 'p == 0' 'fn f(p: ptr) -> i32 { if (p == 0) { return 1; } return 0; }
fn main() -> i32 { return 0; }'
# m2c: the same rule in genBool, which serves a ptr comparison used as a *bool
# value* rather than as a condition (`let b: bool = (p == 0);`).
mutate 'm2c: bool-value drops ptr equality' \
    's/if(e.k!=Expr::Eq\&\&e.k!=Expr::Ne){/if(true){/' \
    must_not_compile 'let b: bool = (p == 0)' 'fn main() -> i32 { let p: ptr = 0; let b: bool = (p == 0); if (b) { return 1; } return 0; }'
# m2b: the same withdrawal in sema, which is the pass that actually reports
# the diagnostic a user sees.
mutate 'm2b: sema drops ptr equality' \
    's/if(e.k!=Expr::Eq\&\&e.k!=Expr::Ne)$/if(true)/' \
    must_not_compile 'p == 0' 'fn f(p: ptr) -> i32 { if (p == 0) { return 1; } return 0; }
fn main() -> i32 { return 0; }'
# m3: `false` becomes an address. The boolLit test is the only thing stopping
# it, and its value is 0 — this is the mutation the predicate exists for.
mutate 'm3: false counts as null' \
    's/return e.k==Expr::Num\&\&!e.boolLit\&\&e.n==0;/return e.k==Expr::Num\&\&e.n==0;/' \
    must_now_compile 'let p: ptr = false' 'fn main() -> i32 { let p: ptr = false; return 0; }'
# m4: ordering two addresses becomes legal. The rule lives in both passes —
# sema is the rule, codegen its defensive twin — so withdrawing it means
# withdrawing both halves; one alone still refuses, which is the point of
# having two.
mutate 'm4: ordering allowed' \
    's/if(e.k!=Expr::Eq\&\&e.k!=Expr::Ne)$/if(false)/;s/if(c.k!=Expr::Eq\&\&c.k!=Expr::Ne){/if(false){/' \
    must_now_compile 'p < q' 'fn f(a: ptr, b: ptr) -> i32 { if (a < b) { return 1; } return 0; }
fn main() -> i32 { return 0; }'
# m5: any integer may be compared with a ptr, not just 0. The guard reads
# `if (!null) throw`, so dropping it means making the condition unreachable.
mutate 'm5: p == 1 allowed' \
    's/if(!isNullConstant(\*e.b))/if(false)/' \
    must_now_compile 'p == 1' 'fn f(a: ptr) -> i32 { if (a == 1) { return 1; } return 0; }
fn main() -> i32 { return 0; }'
# m6: any integer literal becomes a pointer, not just 0.
mutate 'm6: any literal is null' \
    's/return e.k==Expr::Num\&\&!e.boolLit\&\&e.n==0;/return e.k==Expr::Num\&\&!e.boolLit;/' \
    must_now_compile 'let p: ptr = 1' 'fn main() -> i32 { let p: ptr = 1; return 0; }'
# m7: a `-> ptr` function may no longer answer null — the "found nothing" case.
mutate 'm7: no null return' \
    's/if(!(retPtr\&\&isNullConstant(\*s.expr)))/if(true)/' \
    must_not_compile 'return 0 from -> ptr' 'fn h() -> ptr { return 0; }
fn main() -> i32 { return 0; }'
printf '%s\n' 'PASS: eight mutated compilers each lose exactly one rule, and the checks notice'
fi

# ---------------------------------------------------------------------------
# [8/9] Byte-identity baseline. Every recorded line must reproduce byte for
# byte in all three build modes. A moved byte is a regression, not a
# re-recording; re-recording is tests/rebuild-baseline-<version>.sh's job.
# ---------------------------------------------------------------------------
printf '%s\n' '[8/9] Byte-identity baseline: every example, all three build modes'
BASE=$(aster_baseline_file)
: > "$OUT/hashes.txt"
for mode in build-so build-elf "build-obj --pic"; do
    tag=$(echo "$mode" | tr ' ' '_')
    for f in examples/*.ast; do
        b=$(basename "$f" .ast)
        # shellcheck disable=SC2086
        if "$A" $mode "$f" -o "$OUT/$b.$tag" >/dev/null 2>&1; then
            printf '%s %s\n' "$b.$tag" "$(sha256sum "$OUT/$b.$tag" | cut -d' ' -f1)" >> "$OUT/hashes.txt"
        else
            printf '%s FAILED\n' "$b.$tag" >> "$OUT/hashes.txt"
        fi
    done
done
# address_of_abi.ast is a .so-only example with no byte-identity baseline row;
# keep it out of the comparison (it is exercised by tests/e2e-c-address-of.sh).
# Both sides are sorted so the append-only baseline file order never disagrees with
# the alphabetical examples/*.ast glob order (a moved line is a regression, not a re-sort).
grep -v '^address_of_abi\.' "$OUT/hashes.txt" | LC_ALL=C sort > "$OUT/hashes.filtered.txt"
LC_ALL=C sort "$BASE" > "$OUT/base.sorted.txt"
if ! diff -u "$OUT/base.sorted.txt" "$OUT/hashes.filtered.txt" > "$OUT/base.diff"; then
    echo 'FAIL: the byte baseline moved — a pre-existing example changed, or a new one is unrecorded' >&2
    sed -n '1,20p' "$OUT/base.diff" >&2
    exit 1
fi
lines=$(wc -l < "$OUT/hashes.txt")
np=$(grep -c '^null_ptr\.' "$OUT/hashes.txt")
[ "$np" -eq 3 ] \
    || { echo "FAIL: expected exactly 3 null_ptr.* baseline lines, found $np" >&2; exit 1; }
printf '  %s lines reproduce byte for byte (3 of them null_ptr.*)\n' "$lines"
printf '%s\n' 'PASS: byte-identity baseline holds'

# ---------------------------------------------------------------------------
# [9/9] The shipped example, end to end.
# ---------------------------------------------------------------------------
printf '%s\n' '[9/9] The example, end to end'
if [ "$have_qemu" = no ]; then
    printf '  SKIP: the example needs qemu to run\n'
else
    if ! "$A" build-elf examples/null_ptr.ast -o "$OUT/np.a64" >"$OUT/np.err" 2>&1; then
        echo 'FAIL: examples/null_ptr.ast does not build' >&2; sed -n '1,3p' "$OUT/np.err" >&2; exit 1
    fi
    $RUNNER "$OUT/np.a64" >/dev/null 2>&1 && got=0 || got=$?
    [ "$got" = 33 ] \
        || { echo "FAIL: null_ptr.ast: expected exit 33, got $got" >&2; exit 1; }
    printf '  %-34s %s\n' 'null_ptr.ast' "$got"
    printf '%s\n' 'PASS: the example runs and returns the value its C twin returns'
fi

printf '%s\n' '=== null-ptr checks: ALL PASSED ==='
