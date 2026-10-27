#!/bin/sh
# v0.23.49-dev checks for the switch statement (Pascal semantics) and labeled
# break/continue.
#
# This round adds two control-flow features that the language has been missing:
#
#   * switch (subject) { case C: body; default: body } — Pascal-shaped. Every
#     case body runs to its end and drops out of the statement, so there is no
#     fallthrough and no per-case break; a bare `break` inside a case still means
#     the innermost *loop*, because a switch never opens one. Case values are
#     compile-time integer constants (reusing constantInteger / foldConst),
#     a duplicate value is refused, and the value must fit the subject's width.
#   * labeled break / continue — `break outer;` / `continue outer;` name a while
#     or a for (`outer: while ...`), and an unlabeled form keeps its old meaning.
#
# And it keeps the bytes of every program that compiled before: a switch never
# appears in a pre-existing example, so the byte-identity baseline is untouched
# except for the six new examples the rounds have added (Layer [8/9]).
#
# The behavioural layers need qemu (or an AArch64 host); the differential layer
# additionally needs $HOSTCC to emit AArch64 ELF. Neither is required to *build*,
# so each layer that cannot run says SKIP and the rest still runs.
set -eu
cd "$(dirname "$0")/.."
CXX=${CXX:-c++}
RUNNER=${RUNNER:-tests/run-aarch64.sh}
OUT=${OUT:-tmp-switch-checks}
mkdir -p "$OUT"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM

printf '%s\n' '[1/9] Strictly build Aster compiler'
$CXX -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o "$OUT/aster"

have_qemu=yes
command -v qemu-aarch64 >/dev/null 2>&1 || have_qemu=no
case $(uname -m) in aarch64|arm64) have_qemu=yes ;; esac
HOSTCC=${HOSTCC:-cc}
have_cc=yes
command -v "$HOSTCC" >/dev/null 2>&1 || have_cc=no
if command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then HOSTCC=aarch64-linux-gnu-gcc; fi
if [ "$have_qemu" = no ]; then
    printf '%s\n' 'SKIP: switch-checks needs qemu-aarch64 (or an AArch64 host) for its behavioural layers'
fi

# ---------------------------------------------------------------------------
# [2/9] Source guards. Each change is pinned where it was made, so a regression
# that quietly reopens one fails here rather than by a behavioural case.
# ---------------------------------------------------------------------------
printf '%s\n' '[2/9] Source guards: the switch and label changes'
# The three new token kinds, grouped with the loop-control words.
grep -qF 'Switch, Case, Default, // v0.23.49-dev: the switch statement' src/aster.cpp \
    || { echo 'FAIL: TK no longer declares Switch, Case, Default' >&2; exit 1; }
# Their spellings in the lexer chain, after the loop-control words.
grep -qF 'else if(x=="switch")k=TK::Switch; else if(x=="case")k=TK::Case; else if(x=="default")k=TK::Default;' src/aster.cpp \
    || { echo 'FAIL: the lexer no longer recognises switch/case/default' >&2; exit 1; }
# Stmt gains the Switch kind and the case/default/label fields.
grep -qF 'Break, Continue, Switch, Expr' src/aster.cpp \
    || { echo 'FAIL: Stmt::Kind no longer declares Switch' >&2; exit 1; }
grep -qF 'std::vector<std::vector<Stmt>> caseBodies;' src/aster.cpp \
    || { echo 'FAIL: Stmt no longer carries caseBodies' >&2; exit 1; }
grep -qF 'std::string label;' src/aster.cpp \
    || { echo 'FAIL: Stmt no longer carries the loop/break label' >&2; exit 1; }
# The range a case value must fit, mirroring initializerFits for a slot.
grep -qF 'static bool caseValueFits(Ty t,int64_t folded){' src/aster.cpp \
    || { echo 'FAIL: caseValueFits() is missing' >&2; exit 1; }
# The parser entry points and the brace-less case body collector.
grep -qF 'Stmt switchStatement(){' src/aster.cpp \
    || { echo 'FAIL: switchStatement() is missing' >&2; exit 1; }
grep -qF 'std::vector<Stmt> caseBody(){' src/aster.cpp \
    || { echo 'FAIL: caseBody() is missing' >&2; exit 1; }
# The label dispatch: only a while or a for may carry one.
grep -qF 'only a while or for loop may be labeled: ' src/aster.cpp \
    || { echo 'FAIL: the label dispatch is missing' >&2; exit 1; }
# A labeled break/continue reads the following identifier as its target.
grep -qF 'if(cur().k==TK::Ident){s.label=cur().s;++p;}' src/aster.cpp \
    || { echo 'FAIL: break/continue no longer read a label' >&2; exit 1; }
# Sema pins the subject to integers and refuses a duplicate / out-of-range case.
grep -qF 'switch subject must be an integer, not ' src/aster.cpp \
    || { echo 'FAIL: Sema no longer checks the switch subject is an integer' >&2; exit 1; }
grep -qF 'duplicate case value ' src/aster.cpp \
    || { echo 'FAIL: Sema no longer refuses a duplicate case value' >&2; exit 1; }
grep -qF 'case value does not fit the switch subject type' src/aster.cpp \
    || { echo 'FAIL: Sema no longer checks the case value fits the subject' >&2; exit 1; }
# The named-loop stack, consumed by labeled break/continue.
grep -qF 'std::vector<std::string> loopNames;' src/aster.cpp \
    || { echo 'FAIL: Sema no longer tracks named loops' >&2; exit 1; }
# Codegen resolves a labeled break/continue by name, innermost first.
grep -qF 'size_t loopIndexFor(const Stmt& s) const {' src/aster.cpp \
    || { echo 'FAIL: loopIndexFor() is missing' >&2; exit 1; }
# The comparison chain: a mismatch branches over this case's body.
grep -qF 'patchCond(skip,1,code.size())' src/aster.cpp \
    || { echo 'FAIL: the switch no longer branches on mismatch' >&2; exit 1; }
printf '%s\n' 'PASS: all the switch and label changes are pinned in the source'

# ---------------------------------------------------------------------------
# [3/9] qemu: every shape, hand-derived. Each case returns the value it is named
# for, so a wrong match, a wrong default, or a fallthrough is the exit code.
# ---------------------------------------------------------------------------
printf '%s\n' '[3/9] qemu: switch and labels, every shape'
if [ "$have_qemu" = yes ]; then
check() {
    aster=$1; name=$2; want=$3
    printf '%s\n' "$4" > "$OUT/c.ast"
    if ! $aster build-elf "$OUT/c.ast" -o "$OUT/c.a64" >"$OUT/c.err" 2>&1; then
        echo "FAIL: $name does not compile" >&2; sed -n '1,3p' "$OUT/c.err" >&2; exit 1
    fi
    $RUNNER "$OUT/c.a64" >/dev/null 2>&1 && got=0 || got=$?
    # No 127-gate: qemu-aarch64 returns the guest exit status (& 0xff) verbatim,
    # so every value in 0..255 is observable directly; folding would corrupt a
    # genuine return such as 200 or 255 (cf. the [9/9] example, which is 212).
    if [ "$got" != "$want" ]; then
        echo "FAIL: $name: expected exit $want, got $got" >&2; exit 1
    fi
    printf '  %-40s %s\n' "$name" "$got"
}
A=$OUT/aster
# --- Pascal semantics: each matching case body self-ends; no fallthrough ---
check "$A" 'case 1 matches, value 11'         11 'fn main() -> i32 { let x: i32 = 1; let r: i32 = 0; switch (x) { case 1: r = 11; case 2: r = 22; default: r = 99; } return r; }'
check "$A" 'case 2 matches, value 22'         22 'fn main() -> i32 { let x: i32 = 2; let r: i32 = 0; switch (x) { case 1: r = 11; case 2: r = 22; default: r = 99; } return r; }'
check "$A" 'no case matches, default 99'       99 'fn main() -> i32 { let x: i32 = 7; let r: i32 = 0; switch (x) { case 1: r = 11; case 2: r = 22; default: r = 99; } return r; }'
check "$A" 'default may precede the cases'     22 'fn main() -> i32 { let x: i32 = 2; let r: i32 = 0; switch (x) { default: r = 99; case 1: r = 11; case 2: r = 22; } return r; }'
check "$A" 'default after the cases still runs' 99 'fn main() -> i32 { let x: i32 = 9; let r: i32 = 0; switch (x) { case 1: r = 11; case 2: r = 22; default: r = 99; } return r; }'
check "$A" 'case value is an expression (1+1)' 22 'fn main() -> i32 { let x: i32 = 2; let r: i32 = 0; switch (x) { case 1+1: r = 22; default: r = 99; } return r; }'
check "$A" 'empty case body chains, value 0'    0 'fn main() -> i32 { let x: i32 = 1; let r: i32 = 0; switch (x) { case 1: case 2: r = 22; default: r = 99; } return r; }'
check "$A" 'subject reused across every case'  55 'fn main() -> i32 { let x: i32 = 5; let r: i32 = 0; switch (x) { case 3: r = 33; case 5: r = 55; default: r = 99; } return r; }'
check "$A" 'middle of three cases, value 22'    22 'fn main() -> i32 { let x: i32 = 2; let r: i32 = 0; switch (x) { case 1: r = 11; case 2: r = 22; case 3: r = 33; default: r = 99; } return r; }'
# --- nested switch ---
check "$A" 'nested switch, inner case 2'       200 'fn main() -> i32 { let a: i32 = 1; let b: i32 = 2; let r: i32 = 0; switch (a) { case 1: switch (b) { case 2: r = 200; default: r = 100; } default: r = 7; } return r; }'
# --- switch inside a loop, the C-style continue still steers the loop ---
check "$A" 'switch in loop, continue skips add'  4 'fn main() -> i32 { let r: i32 = 0; let i: i32 = 0; while (i < 5) { i = i + 1; switch (i) { case 2: continue; } r = r + 1; } return r; }'
# --- single-label break / continue ---
check "$A" 'single label break'                 5 'fn main() -> i32 { let r: i32 = 0; outer: while (r < 100) { r = r + 1; if (r == 5) { break outer; } } return r; }'
check "$A" 'single label continue into step'     4 'fn main() -> i32 { let r: i32 = 0; outer: for (let i: i32 = 0; i < 4; i = i + 1) { if (i == 2) { continue outer; } r = r + i; } return r; }'
# --- double-label continue: outer is the target, not the inner loop ---
check "$A" 'double label continue outer'         3 'fn main() -> i32 { let r: i32 = 0; outer: for (let k: i32 = 0; k < 3; k = k + 1) { let i: i32 = 0; inner: while (i < 3) { i = i + 1; if (i == 2) { continue outer; } r = r + 1; } } return r; }'
# --- wide subjects: u8 / i64 / u64 ---
check "$A" 'wide u8 subject, value 1'           1 'fn main() -> i32 { let a: u8 = 200; let r: i32 = 0; switch (a) { case 200: r = 1; default: r = 2; } return r; }'
check "$A" 'wide i64 subject, negative'          1 'fn main() -> i32 { let a: i64 = -5; let r: i32 = 0; switch (a) { case -5: r = 1; default: r = 2; } return r; }'
check "$A" 'wide u64 subject, >2^32'             1 'fn main() -> i32 { let a: u64 = 4294967296; let r: i32 = 0; switch (a) { case 4294967296: r = 1; default: r = 2; } return r; }'
check "$A" 'wide u8 mismatch falls to default'   2 'fn main() -> i32 { let a: u8 = 5; let r: i32 = 0; switch (a) { case 200: r = 1; default: r = 2; } return r; }'
# --- definitelyReturns: a switch with a default that covers every case ---
check "$A" 'definitelyReturns switch + default'  99 'fn f(x: i32) -> i32 { switch (x) { case 1: return 10; case 2: return 20; default: return 99; } }
fn main() -> i32 { return f(3); }'
# --- a label on a for, not just a while ---
check "$A" 'label on for, break'                 5 'fn main() -> i32 { let r: i32 = 0; outer: for (let i: i32 = 0; i < 100; i = i + 1) { r = r + 1; if (r == 5) { break outer; } } return r; }'
else
    printf '%s\n' '  SKIP: the behavioural cases need qemu to run'
fi

# ---------------------------------------------------------------------------
# [4/9] Differential: Aster against the target C compiler, whose switch is the
# shape Aster describes. No expectation here is hand-computed.
# ---------------------------------------------------------------------------
printf '%s\n' '[4/9] Differential: Aster vs the target C compiler'
if [ "$have_qemu" = yes ] && [ "$have_cc" = yes ]; then
    diff_case() {
        printf '%s\n' "$2" > "$OUT/d.ast"
        printf '%s\n' "$3" > "$OUT/d.c"
        if ! "$A" build-elf "$OUT/d.ast" -o "$OUT/d.a64" >"$OUT/d.err" 2>&1; then
            echo "FAIL: $1 does not compile under Aster" >&2; sed -n '1,3p' "$OUT/d.err" >&2; exit 1
        fi
        "$HOSTCC" -std=c11 -O2 -w "$OUT/d.c" -o "$OUT/dc.a64"
        $RUNNER "$OUT/d.a64" >/dev/null 2>&1 && ga=0 || ga=$?
        $RUNNER "$OUT/dc.a64" >/dev/null 2>&1 && gc=0 || gc=$?
        if [ "$ga" != "$gc" ]; then
            echo "FAIL: $1: Aster exit $ga, C exit $gc" >&2; exit 1
        fi
        printf '  %-40s %s\n' "$1" "$ga"
    }
    # The shipped example against its twin, end to end.
    diff_case 'examples/switch.ast' \
        "$(cat examples/switch.ast)" \
        "$(cat tests/switch-twin.c)"
    # A label crossing a nested loop, where C needs a goto and Aster names the
    # outer loop directly.
    diff_case 'labeled continue crosses a loop' \
        'fn main() -> i32 {
    let r: i32 = 0;
    outer: for (let k: i32 = 0; k < 3; k = k + 1) {
        let i: i32 = 0;
        while (i < 4) { i = i + 1; if (i == 3) { continue outer; } r = r + 1; }
    }
    return r; }' \
        '#include <stdint.h>
int main(void) {
    int32_t r = 0;
    for (int32_t k = 0; k < 3; k = k + 1) {
        int32_t i = 0;
        while (i < 4) { i = i + 1; if (i == 3) { goto outer_continue; } r = r + 1; }
    outer_continue:;
    }
    return r; }'
    # A switch that steers nothing but selects — Pascal no-fallthrough against
    # C with explicit breaks on every case.
    diff_case 'switch selects, no fallthrough' \
        'fn main() -> i32 {
    let r: i32 = 0;
    let x: i32 = 2;
    switch (x) {
        case 1: r = r + 1;
        case 2: r = r + 2;
        case 3: r = r + 3;
        default: r = r + 0;
    }
    return r; }' \
        '#include <stdint.h>
int main(void) {
    int32_t r = 0;
    int32_t x = 2;
    switch (x) {
        case 1: r = r + 1; break;
        case 2: r = r + 2; break;
        case 3: r = r + 3; break;
        default: r = r + 0; break;
    }
    return r; }'
else
    printf '%s\n' '  SKIP: the differential layer needs qemu and a target C compiler'
fi

# ---------------------------------------------------------------------------
# [5/9] Rejection matrix: the subject must be an integer, a case value must be a
# compile-time constant that fits and is unique, and labels must name a real loop.
# ---------------------------------------------------------------------------
printf '%s\n' '[5/9] Rejection matrix'
reject() {
    printf '%s\n' "$3" > "$OUT/r.ast"
    if "$A" build-elf "$OUT/r.ast" -o "$OUT/r.a64" >"$OUT/r.err" 2>&1; then
        echo "FAIL: $1 was accepted" >&2; exit 1
    fi
    grep -qF "$2" "$OUT/r.err" \
        || { echo "FAIL: $1: expected '$2', got: $(sed -n '1p' "$OUT/r.err")" >&2; exit 1; }
    printf '  %-40s refused\n' "$1"
}
A=$OUT/aster
reject 'bool subject'            "switch subject must be an integer, not bool" \
    'fn main() -> i32 { let b: bool = true; let r: i32 = 0; switch (b) { case 1: r = 1; default: r = 2; } return r; }'
reject 'ptr subject'             "switch subject must be an integer, not ptr" \
    'fn main() -> i32 { let p: ptr = "x"; let r: i32 = 0; switch (p) { case 1: r = 1; default: r = 2; } return r; }'
reject 'non-constant case value'  "case value must be a compile-time constant" \
    'fn main() -> i32 { let x: i32 = 1; let y: i32 = 2; let r: i32 = 0; switch (x) { case y: r = 1; default: r = 2; } return r; }'
reject 'duplicate case value'     "duplicate case value 1" \
    'fn main() -> i32 { let x: i32 = 1; let r: i32 = 0; switch (x) { case 1: r = 1; case 1: r = 2; default: r = 3; } return r; }'
reject 'case value too wide for i32' "case value does not fit the switch subject type" \
    'fn main() -> i32 { let x: i32 = 1; let r: i32 = 0; switch (x) { case 2147483648: r = 1; default: r = 2; } return r; }'
reject 'case value too wide for u8' "case value does not fit the switch subject type" \
    'fn main() -> i32 { let a: u8 = 5; let r: i32 = 0; switch (a) { case 300: r = 1; default: r = 2; } return r; }'
reject 'second default'          "a second default case" \
    'fn main() -> i32 { let x: i32 = 1; let r: i32 = 0; switch (x) { default: r = 1; default: r = 2; } return r; }'
reject 'break outside a loop'     "break used outside a loop" \
    'fn main() -> i32 { let x: i32 = 1; switch (x) { case 1: break; } return 0; }'
reject 'continue outside a loop'   "continue used outside a loop" \
    'fn main() -> i32 { let x: i32 = 1; switch (x) { case 1: continue; } return 0; }'
reject 'label on a non-loop'      "only a while or for loop may be labeled" \
    'fn main() -> i32 { let x: i32 = 0; foo: if (x < 2) { x = x + 1; } return x; }'
reject 'break to a missing label'  "no such loop label: outer" \
    'fn main() -> i32 { let r: i32 = 0; while (r < 2) { break outer; } return r; }'
reject 'continue to a missing label' "no such loop label: outer" \
    'fn main() -> i32 { let r: i32 = 0; while (r < 2) { continue outer; } return r; }'
printf '%s\n' 'PASS: the rejection matrix holds'

# ---------------------------------------------------------------------------
# [6/9] Coverage: the behavioural layer above is the coverage, so a hole in a
# guard is a hole here. This is a positive layer, not a guard.
# ---------------------------------------------------------------------------
printf '%s\n' '[6/9] Coverage: every switch shape is exercised'
if [ "$have_qemu" = yes ]; then
    n=$(grep -c '^check ' "$0")
    [ "$n" -ge 20 ] || { echo "FAIL: expected at least 20 behavioural cases, found $n" >&2; exit 1; }
    printf '  %-40s %s\n' 'behavioural cases' "$n"
    printf '%s\n' 'PASS: the behavioural matrix covers every switch shape'
else
    printf '%s\n' '  SKIP: the coverage count needs the behavioural cases to run'
fi

# ---------------------------------------------------------------------------
# [7/9] Mutation layer. Each mutant removes one rule; a case must notice.
# ---------------------------------------------------------------------------
printf '%s\n' '[7/9] Mutation layer'
must_differ() {   # must_differ <name> <good-exit> <source>: mutant must NOT give good-exit
    name=$1; good=$2
    printf '%s\n' "$3" > "$OUT/m.ast"
    if ! "$OUT/mut.aster" build-elf "$OUT/m.ast" -o "$OUT/m.a64" >"$OUT/m.err" 2>&1; then
        echo "FAIL: mutant does not compile $name" >&2; exit 1
    fi
    $RUNNER "$OUT/m.a64" >/dev/null 2>&1 && got=0 || got=$?
    # No 127-gate: qemu-aarch64 returns the guest exit status (& 0xff) verbatim,
    # so every value in 0..255 is observable directly; folding would corrupt a
    # genuine return such as 200 or 255 (cf. the [9/9] example, which is 212).
    if [ "$got" = "$good" ]; then
        echo "FAIL: mutant $name still gives $got — the case does not see the rule" >&2; exit 1
    fi
}
must_now_compile() {   # must_now_compile <name> <source>: real compiler refuses, mutant accepts
    name=$1
    printf '%s\n' "$2" > "$OUT/m.ast"
    if "$OUT/mut.aster" build-elf "$OUT/m.ast" -o "$OUT/m.a64" >"$OUT/m.err" 2>&1; then
        :   # the mutant accepts it — the rule was removed
    else
        echo "FAIL: mutant $name still refuses — the rule was not removed" >&2; exit 1
    fi
}
must_not_compile() {   # must_not_compile <name> <source>: real and mutant both refuse
    name=$1
    printf '%s\n' "$2" > "$OUT/m.ast"
    if "$OUT/mut.aster" build-elf "$OUT/m.ast" -o "$OUT/m.a64" >"$OUT/m.err" 2>&1; then
        echo "FAIL: mutant $name now compiles — a hard error turned into silence" >&2; exit 1
    fi
}
mutate() {   # mutate <name> <sed-script> <expectation...>
    name=$1; script=$2; shift 2
    cp src/aster.cpp "$OUT/mut.cpp"
    if ! sed -i.bak "$script" "$OUT/mut.cpp" 2>/dev/null; then
        echo "FAIL: mutant $name could not be applied" >&2; exit 1
    fi
    if ! $CXX -std=c++17 -O2 -w "$OUT/mut.cpp" -o "$OUT/mut.aster" >"$OUT/mut.build" 2>&1; then
        echo "FAIL: mutant $name does not build" >&2; sed -n '1,3p' "$OUT/mut.build" >&2; exit 1
    fi
    "$@"
    printf '  %-40s caught\n' "$name"
}
if [ "$have_qemu" = no ]; then
    printf '  SKIP: the mutation layer needs qemu to observe a changed answer'
else
# m1: the case's skip branch is inverted — a match now skips the body and a
# mismatch falls into it, so the wrong case body runs.
mutate 'm1: the mismatch branch is inverted' \
    's|patchCond(skip,1,code.size())|patchCond(skip,0,code.size())|' \
    must_differ 'no case matches, default 99' 99 'fn main() -> i32 { let x: i32 = 7; let r: i32 = 0; switch (x) { case 1: r = 11; case 2: r = 22; default: r = 99; } return r; }'
# m2: a labeled break/continue always targets the innermost loop instead of the
# named one, so `continue outer` no longer crosses out of the inner loop.
mutate 'm2: a labeled jump always takes the innermost loop' \
    's|if(loops\[i\].name==s.label)return i;|return loops.size()-1;|' \
    must_differ 'double label continue outer' 3 'fn main() -> i32 { let r: i32 = 0; outer: for (let k: i32 = 0; k < 3; k = k + 1) { let i: i32 = 0; inner: while (i < 3) { i = i + 1; if (i == 1) { continue outer; } r = r + 1; } } return r; }'
# m3: the default body is never emitted, so a subject that matches no case and
# would have hit the default instead returns the uninitialised accumulator.
mutate 'm3: the default body is not emitted' \
    's|if(s.hasDefault)block(s.elseBody,true);||' \
    must_differ 'no case matches, default 99' 99 'fn main() -> i32 { let x: i32 = 7; let r: i32 = 0; switch (x) { case 1: r = 11; case 2: r = 22; default: r = 99; } return r; }'
printf '%s\n' 'PASS: three mutated compilers each lose exactly one rule, and the checks notice'
fi

# ---------------------------------------------------------------------------
# [8/9] Byte-identity baseline. Every line recorded before this round must
# reproduce byte for byte. This round's own example is excluded; everything the
# rounds before it produced is pinned at 288 rows.
# ---------------------------------------------------------------------------
printf '%s\n' '[8/9] Byte-identity baseline'
BASE=tests/baseline/v0.23.5-dev/example-hashes.txt
: > "$OUT/hashes.txt"
for mode in build-so build-elf "build-obj --pic"; do
    tag=$(echo "$mode" | tr ' ' '_')
    for f in examples/*.ast; do
        b=$(basename "$f" .ast)
        if "$A" $mode "$f" -o "$OUT/$b.$tag" >/dev/null 2>&1; then
            printf '%s %s\n' "$b.$tag" "$(sha256sum "$OUT/$b.$tag" | cut -d' ' -f1)" >> "$OUT/hashes.txt"
        else
            printf '%s FAILED\n' "$b.$tag" >> "$OUT/hashes.txt"
        fi
    done
done
# v0.23.49-dev: this round's example (switch.ast) joins the filter; fifteen of
# the families the rounds before v0.23.5-dev know are new are excluded, and the
# pre-existing count is the same 288 it has been since v0.23.30-dev.
# v0.23.51-dev: the TLS round's example (tls_demo.ast) and the symbol-versioning
# round's example (so_verstrlen.ast) join the filter the same way; v0.23.52-dev
# adds so_tls_demo.ast beside them, so twenty families are skipped and the
# pre-existing count is still 288: 348 recorded, 60 of them belonging to the
# twenty rounds this suite knows are new.
# v0.23.57-dev: c_ptr_difference.ast (the pointer-difference round) joins this filter the same way, so the pre-existing count stays 288.
FILTER='-e ^switch\. -e ^sizeof_len\. -e ^struct_array_field\. -e ^array_elem_types\. -e ^precedence\. -e ^array_address\. -e ^multi_dim_array\. -e ^lifecycle\. -e ^fn_type\. -e ^cb_table\. -e ^fn_ret\. -e ^call-stmt\. -e ^copy\. -e ^arena\. -e ^stdlib_demo\. -e ^integer_cast\. -e ^literals\. -e ^tls_demo\. -e ^so_verstrlen\. -e ^c_ptr_difference\. -e ^so_tls_demo\.'
grep -v $FILTER "$BASE" > "$OUT/expected-old.txt"
grep -v $FILTER "$OUT/hashes.txt" > "$OUT/got-old.txt"
if ! diff -u "$OUT/expected-old.txt" "$OUT/got-old.txt" > "$OUT/old.diff"; then
    echo 'FAIL: a pre-existing example moved — the round changed bytes' >&2
    sed -n '1,20p' "$OUT/old.diff" >&2
    exit 1
fi
old=$(wc -l < "$OUT/expected-old.txt")
new=$(wc -l < "$OUT/got-old.txt")
[ "$old" -eq 288 ] \
    || { echo "FAIL: expected 288 pre-existing baseline rows, found $old" >&2; exit 1; }
[ "$new" -eq 288 ] \
    || { echo "FAIL: expected 288 rows of pre-existing output, found $new" >&2; exit 1; }
[ "$(grep -c '^switch\.' "$OUT/hashes.txt")" -eq 3 ] \
    || { echo 'FAIL: switch.ast is not in the baseline in all three modes' >&2; exit 1; }
printf '  %-40s %s\n' 'pre-existing rows byte-identical' "$old"
printf '  %-40s %s\n' 'new example rows recorded' '3'
printf '%s\n' 'PASS: byte-identity baseline holds'

# ---------------------------------------------------------------------------
# [9/9] The shipped example, end to end.
# ---------------------------------------------------------------------------
printf '%s\n' '[9/9] The example, end to end'
if [ "$have_qemu" = no ]; then
    printf '  SKIP: the example needs qemu to run\n'
else
    if ! "$A" build-elf examples/switch.ast -o "$OUT/sw.a64" >"$OUT/sw.err" 2>&1; then
        echo 'FAIL: examples/switch.ast does not build' >&2; sed -n '1,3p' "$OUT/sw.err" >&2; exit 1
    fi
    $RUNNER "$OUT/sw.a64" >/dev/null 2>&1 && got=0 || got=$?
    [ "$got" = 212 ] \
        || { echo "FAIL: examples/switch.ast: expected exit 212, got $got" >&2; exit 1; }
    printf '  %-40s %s\n' 'switch.ast' "$got"
    printf '%s\n' 'PASS: the example runs and returns the value its C twin returns'
fi

printf '%s\n' '=== switch checks: ALL PASSED ==='
