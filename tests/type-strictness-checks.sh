#!/bin/sh
# tests/type-strictness-checks.sh — the audit's P1 batch, held down.
#
# AUDIT-v0.23.61-dev.md found five defects of the second kind: not "computes
# the wrong answer" but "answers the wrong thing about a program" — a legal
# program refused, an illegal one accepted. That is a quieter failure and a
# harder one to notice, which is exactly why it needs a suite of its own:
#
#   1. a wide integer reaching a shift or a bitwise-not aborted the compiler
#      (the TypedIR exemption list had never been told about Shl/Shr/BitNot);
#   2. two different enums compared equal — the type is nominal everywhere
#      except in a comparison;
#   3. an enum slot accepted a constant no i32 could hold;
#   4. an auto-incremented enumerator walked out of i32 unnamed;
#   5. a `return` accepted an implicit narrowing, so
#      `fn f() -> u8 { return x; }` with an i64 x handed back `300 & 0xFF`.
#
# Fix 5 covers the four positions where a value is *bound* to a declared type
# — a `let`, a local assignment, a global assignment and a `return`. A store
# through a subscript or a field is left as it was, on purpose:
# `bootstrap/aster.ast` stores an i64 instruction word into an i32[262144]
# stream and the bootstrap subset has no cast expression, so tightening those
# two sites would break self-hosting with no way to fix the source. Mutants n7
# and n8 withdraw that exemption and must be caught, which is what keeps a
# deliberate carve-out from quietly becoming an accident.
#
# The suite is therefore two-sided, and both sides are load-bearing: the
# accepting side proves the strictness did not break a program that has always
# compiled (`return a + b;` on two u8 operands is the one that nearly did),
# and the refusing side proves each rule fires.
#
# Layers (the project 9-layer shape): strict build, source guards, qemu
# witnesses, a C differential twin, the rejection matrix, coverage counting,
# eight mutations, the byte baseline, and the shapes through all three build
# modes.
set -eu
cd "$(dirname "$0")/.."
. tests/lib/baseline.sh
CXX=${CXX:-c++}
RUNNER=${RUNNER:-tests/run-aarch64.sh}
OUT=${OUT:-tmp-type-strictness-checks}
mkdir -p "$OUT"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM

printf '%s\n' '[1/9] Strictly build Aster compiler'
$CXX -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp -o "$OUT/aster"

have_qemu=yes
command -v qemu-aarch64 >/dev/null 2>&1 || have_qemu=no
case $(uname -m) in aarch64|arm64) have_qemu=yes ;; esac
HOSTCC=${HOSTCC:-cc}
have_cc=yes
command -v "$HOSTCC" >/dev/null 2>&1 || have_cc=no
if command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then HOSTCC=aarch64-linux-gnu-gcc; fi
if [ "$have_qemu" = no ]; then
    printf '%s\n' 'SKIP: type-strictness-checks needs qemu-aarch64 (or an AArch64 host) for its behavioural layers'
fi
A=$OUT/aster

# ---------------------------------------------------------------------------
# [2/9] Source guards. Each fix is pinned where it was made.
# ---------------------------------------------------------------------------
printf '%s\n' '[2/9] Source guards: the five rules'
grep -qF '#define ASTER_VERSION_STRING "0.23.76-dev"' src/aster.cpp \
    || { echo "FAIL: the version constant is not 0.23.76-dev" >&2; exit 1; }
grep -qF 'case Expr::Shl: case Expr::Shr: case Expr::BitNot:' src/aster.cpp \
    || { echo "FAIL: the shift family is no longer in the TypedIR exemption" >&2; exit 1; }
grep -qF 'if(t.k==Ty::Enum)return enumValueFits((int64_t)e.n);' src/aster.cpp \
    || { echo "FAIL: a bare literal is no longer range-checked for an enum slot" >&2; exit 1; }
grep -qF 'case Ty::Enum: return enumValueFits(folded);' src/aster.cpp \
    || { echo "FAIL: a folded constant is no longer range-checked for an enum slot" >&2; exit 1; }
grep -qF 'else if(!enumValueFits(val))throw Error(loc(cn.line,cn.col,"enumerator value out of i32 range: "+cn.s));' src/aster.cpp \
    || { echo "FAIL: the auto-increment is no longer range-checked" >&2; exit 1; }
grep -qF 'cannot compare two different enum types: ' src/aster.cpp \
    || { echo "FAIL: a comparison no longer isolates two enums" >&2; exit 1; }
grep -qF 'if(!refuseNarrow||semaTypeIsPlaceholder(e))return;' src/aster.cpp \
    || { echo "FAIL: an arithmetic result is no longer exempt from the narrowing check" >&2; exit 1; }
# The positions the round leaves alone are pinned too, so the carve-out cannot
# quietly become universal or quietly disappear: `refuseNarrow` is the
# parameter that names it. v0.23.74-dev (F-11) adds a third call site — the
# store through a typed pointer — so three call sites now pass false.
grep -qF 'const std::string& what,bool refuseNarrow=true)' src/aster.cpp \
    || { echo "FAIL: the narrowing rule no longer has a named exemption" >&2; exit 1; }
[ "$(grep -c 'checkValue(.*,\*s\.expr,actual,.*,false);' src/aster.cpp)" = 3 ] \
    || { echo "FAIL: the element/field/DerefAssign store exemption is not exactly three call sites" >&2; exit 1; }
grep -qF 'checkValue(retType,*s.expr,actual,"return type mismatch in function "+fn);' src/aster.cpp \
    || { echo "FAIL: a return no longer goes through the same rule an argument does" >&2; exit 1; }
printf '%s\n' 'PASS: all five rules are pinned in the source'

# ---------------------------------------------------------------------------
# [3/9] The accepting side: programs that must still compile, and still give
# the answer they gave before any of this. This is the layer that caught the
# first draft of fix 5, which broke `return a + b;` on two u8 operands.
# ---------------------------------------------------------------------------
printf '%s\n' '[3/9] qemu: what must still be accepted'
check() {
    aster=$1; name=$2; want=$3
    printf '%s\n' "$4" > "$OUT/c.ast"
    if ! $aster build-elf "$OUT/c.ast" -o "$OUT/c.a64" >"$OUT/c.err" 2>&1; then
        echo "FAIL: $name does not compile" >&2; sed -n '1,3p' "$OUT/c.err" >&2; exit 1
    fi
    # An Aster program's `return r` is the process exit status, so it is
    # already r & 0xff: 255 and -1 are the same answer here, and comparing
    # the raw statuses is the only comparison that means anything.
    $RUNNER "$OUT/c.a64" >/dev/null 2>&1 && got=0 || got=$?
    if [ "$got" != "$want" ]; then
        echo "FAIL: $name: expected exit $want, got $got" >&2; exit 1
    fi
    printf '  %-44s %s\n' "$name" "$got"
}
if [ "$have_qemu" = yes ]; then
# --- 1. a wide integer reaches a shift / a bitwise-not (P1-1) ---
check "$A" 'i64 << through a sum'            12 'fn main() -> i32 { let a: i64 = 1; let b: i64 = 2; let c: i64 = (a + b) << 2; return i32(c); }'
check "$A" 'u8 >> through a sum'             40 'fn main() -> i32 { let a: u8 = 40; let b: u8 = 40; let v: i32 = (a + b) >> 1; return v; }'
check "$A" '~(i64 + i64)'                   252 'fn main() -> i32 { let a: i64 = 1; let b: i64 = 2; let v: i64 = ~(a + b); return i32(v & 255); }'
check "$A" 'i64 << in a condition'            1 'fn main() -> i32 { let a: i64 = 3; if ((a << 1) == 6) { return 1; } return 0; }'
# --- 2. an enum: what a comparison still permits (P1-2) ---
check "$A" 'same enum =='                     1 'enum Color { R, G }
fn main() -> i32 { let c: Color = R; if (c == R) { return 1; } return 0; }'
check "$A" 'enum == i32 constant'             1 'enum Color { R, G }
fn main() -> i32 { let c: Color = G; if (c == 1) { return 1; } return 0; }'
check "$A" 'enum != other enumerator'         1 'enum Color { R, G }
fn main() -> i32 { let c: Color = R; if (c != G) { return 1; } return 0; }'
check "$A" 'enum in i32 arithmetic'           3 'enum Color { R, G, B }
fn main() -> i32 { let c: Color = B; return c + 1; }'
check "$A" 'enum == i32 variable'             1 'enum Color { R, G }
fn main() -> i32 { let c: Color = G; let x: i32 = 1; if (c == x) { return 1; } return 0; }'
# --- 3. an enum inside its own range (P1-3, P1-4) ---
check "$A" 'enum from a fitting constant'     1 'enum Color { R, G }
fn main() -> i32 { let c: Color = 1; if (c == G) { return 1; } return 0; }'
check "$A" 'enum auto-increment at the edge'  2 'enum E { A = 2147483645, B, C }
fn main() -> i32 { return i32(C) - 2147483645; }'
# --- 4. a narrowing asked for out loud (P1-5) ---
check "$A" 'return u8(x) — the cast'         44 'fn f() -> u8 { let x: i64 = 300; return u8(x); }
fn main() -> i32 { return i32(f()); }'
check "$A" 'return a + b on two u8'         255 'fn add_u8(a: u8, b: u8) -> u8 { return a + b; }
fn main() -> i32 { return i32(add_u8(200, 55)); }'
check "$A" 'u8 element from arithmetic'      10 'fn main() -> i32 { let a: u8[4] = 0; let i: i32 = 1; a[i] = i * 7 + 3; return i32(a[1]); }'
check "$A" 'u8 field from arithmetic'       255 'struct S { b: u8 }
fn main() -> i32 { let s: S; s.b = 200 + 55; return i32(s.b); }'
check "$A" 'u8 from a fitting constant'     200 'fn main() -> i32 { let b: u8 = 200; return i32(b); }'
# --- 5. the two positions the round leaves alone. Both are *accepted*, and
#      that is the assertion: an i64 landing in an i32 element or field keeps
#      the container's width. `bootstrap/aster.ast` depends on the first one
#      (it stores an i64 instruction word into an i32[262144] stream) and the
#      bootstrap subset has no cast to spell it with. Mutants n7/n8 withdraw
#      the exemption and must be caught; these two rows are what they catch.
check "$A" 'i64 into an i32 element'          7 'fn main() -> i32 { let a: i32[4] = 0; let w: i64 = 7; a[0] = w; return a[0]; }'
check "$A" 'i64 into an i32 field'            9 'struct S { v: i32 }
fn main() -> i32 { let s: S = S { 0 }; let w: i64 = 9; s.v = w; return s.v; }'
# --- 6. the width rule this round left alone ---
check "$A" 'ptr<i64> store keeps -5'          1 'let q: i64 = 0;
fn main() -> i32 { let p: ptr<i64> = &q; *p = -5; if (q == -5) { return 1; } return 0; }'
printf '%s\n' 'PASS: 17 witnesses, every legal program still legal'
fi

# ---------------------------------------------------------------------------
# [4/9] Differential: the C twin says what these programs mean. The refusals
# have no twin — C accepts an implicit narrowing with a warning — so this
# layer pins the accepting half against an outside authority.
# ---------------------------------------------------------------------------
printf '%s\n' '[4/9] Differential: Aster vs the C twin'
if [ "$have_qemu" = yes ] && [ "$have_cc" = yes ] && [ -f tests/type-strictness-twin.c ]; then
    if $HOSTCC -O2 -o "$OUT/twin" tests/type-strictness-twin.c 2>"$OUT/twin.build"; then
        diffcase() {   # diffcase <case> <aster source>
            dname=$1; printf '%s\n' "$2" > "$OUT/d.ast"
            if ! "$A" build-elf "$OUT/d.ast" -o "$OUT/d.a64" >"$OUT/d.err" 2>&1; then
                echo "FAIL: $dname does not compile" >&2; sed -n '1,3p' "$OUT/d.err" >&2; exit 1
            fi
            $RUNNER "$OUT/d.a64" >/dev/null 2>&1 && got=0 || got=$?
            $RUNNER "$OUT/twin" "$dname" >/dev/null 2>&1 && want=0 || want=$?
            if [ "$got" != "$want" ]; then
                echo "FAIL: $dname: Aster gave $got, C gave $want" >&2; exit 1
            fi
            printf '  %-44s %s\n' "$dname" "$got"
        }
        diffcase S1 'fn main() -> i32 { let a: i64 = 1; let b: i64 = 2; let c: i64 = (a + b) << 2; return i32(c); }'
        diffcase S2 'fn main() -> i32 { let a: u8 = 40; let b: u8 = 40; let v: i32 = (a + b) >> 1; return v; }'
        diffcase S3 'fn main() -> i32 { let a: i64 = 1; let b: i64 = 2; let v: i64 = ~(a + b); return i32(v & 255); }'
        diffcase S4 'enum Color { R, G }
fn main() -> i32 { let c: Color = R; if (c == R) { return 1; } return 0; }'
        diffcase S5 'enum Color { R, G }
fn main() -> i32 { let c: Color = G; if (c == 1) { return 1; } return 0; }'
        diffcase S6 'fn f() -> u8 { let x: i64 = 300; return u8(x); }
fn main() -> i32 { return i32(f()); }'
        diffcase S7 'fn add_u8(a: u8, b: u8) -> u8 { return a + b; }
fn main() -> i32 { return i32(add_u8(200, 55)); }'
        diffcase S8 'fn main() -> i32 { let a: u8[4] = 0; let i: i32 = 1; a[i] = i * 7 + 3; return i32(a[1]); }'
        diffcase S9 'let q: i64 = 0;
fn main() -> i32 { let p: ptr<i64> = &q; *p = -5; if (q == -5) { return 1; } return 0; }'
        printf '%s\n' 'PASS: 9 differential cases agree with C'
    else
        printf '  SKIP: the C twin does not build with %s\n' "$HOSTCC"
    fi
else
    printf '  SKIP: the differential layer needs qemu, a C compiler, and the twin\n'
fi

# ---------------------------------------------------------------------------
# [5/9] The refusing side. Each rule fires on the program that names it, and
# each rejects with its own diagnostic — a refusal that lands somewhere else
# is a different rule, not this one.
# ---------------------------------------------------------------------------
printf '%s\n' '[5/9] Rejection matrix'
must_refuse() {   # must_refuse <name> <needle> <source>
    rname=$1; needle=$2
    printf '%s\n' "$3" > "$OUT/r.ast"
    if "$A" build-elf "$OUT/r.ast" -o "$OUT/r.a64" >"$OUT/r.err" 2>&1; then
        echo "FAIL: $rname is accepted" >&2; exit 1
    fi
    grep -qF "$needle" "$OUT/r.err" \
        || { echo "FAIL: $rname is refused, but not as '$needle'" >&2; sed -n '1,2p' "$OUT/r.err" >&2; exit 1; }
    printf '  %-44s refused\n' "$rname"
}
must_refuse 'cross-enum ==' 'cannot compare two different enum types' 'enum Color { R, G }
enum Fruit { A, B }
fn main() -> i32 { let c: Color = R; let f: Fruit = A; if (c == f) { return 1; } return 0; }'
must_refuse 'cross-enum !=' 'cannot compare two different enum types' 'enum Color { R, G }
enum Fruit { A, B }
fn main() -> i32 { let c: Color = R; let f: Fruit = A; if (c != f) { return 1; } return 0; }'
must_refuse 'enum <- constant past i32' 'type mismatch initializing' 'enum Color { R, G }
fn main() -> i32 { let c: Color = 4294967296; return 0; }'
must_refuse 'enum <- folded sum past i32' 'type mismatch initializing' 'enum Color { R, G }
fn main() -> i32 { let c: Color = 4294967295 + 1; return 0; }'
must_refuse 'enum auto-increment past i32' 'enumerator value out of i32 range' 'enum E { A = 2147483647, B }
fn main() -> i32 { return i32(B); }'
must_refuse 'return narrowing i64 -> u8' 'return type mismatch' 'fn f() -> u8 { let x: i64 = 300; return x; }
fn main() -> i32 { return i32(f()); }'
must_refuse 'return narrowing i64 -> u16' 'return type mismatch' 'fn f() -> u16 { let x: i64 = 70000; return x; }
fn main() -> i32 { return i32(f()); }'
# v0.23.63-dev leaves a store through a subscript or a field alone — see the
# header. The two rows that used to refuse it are therefore gone, and the
# carve-out is instead (a) accepted on purpose by witnesses 18/19 below and
# (b) withdrawn by mutants n7/n8, which must be caught. Two value positions
# take their place in the matrix so the count still says what it said.
must_refuse 'let narrowing i64 -> i32' 'type mismatch initializing' 'fn main() -> i32 { let x: i64 = 300; let b: i32 = x; return b; }'
must_refuse 'return narrowing i64 -> i32' 'return type mismatch' 'fn f() -> i32 { let x: i64 = 300; return x; }
fn main() -> i32 { return f(); }'
must_refuse 'let narrowing i64 -> u8' 'type mismatch initializing' 'fn main() -> i32 { let x: i64 = 300; let b: u8 = x; return i32(b); }'
must_refuse 'enum <- i64' 'type mismatch initializing' 'enum Color { R, G }
fn main() -> i32 { let x: i64 = 1; let c: Color = x; return 0; }'
must_refuse 'assign narrowing i64 -> u8' 'assigning variable' 'fn main() -> i32 { let b: u8 = 0; let x: i64 = 300; b = x; return i32(b); }'
must_refuse 'global assign narrowing i64 -> u8' 'assigning variable' 'let g: u8 = 0;
fn main() -> i32 { let x: i64 = 300; g = x; return i32(g); }'
printf '%s\n' 'PASS: 13 refusals, each by its own rule'

# ---------------------------------------------------------------------------
# [6/9] Coverage: both sides are counted, because a suite that only refuses
# would pass by refusing everything and a suite that only accepts would not
# be testing a rule at all.
# ---------------------------------------------------------------------------
printf '%s\n' '[6/9] Coverage: both sides are exercised'
witnesses=$(grep -c "^check \"\$A\" " tests/type-strictness-checks.sh || echo 0)
[ "$witnesses" -ge 17 ] \
    || { echo "FAIL: expected at least 17 accepting witnesses, found $witnesses" >&2; exit 1; }
refusals=$(grep -c "^must_refuse " tests/type-strictness-checks.sh || echo 0)
[ "$refusals" -ge 13 ] \
    || { echo "FAIL: expected at least 13 refusals, found $refusals" >&2; exit 1; }
printf '  %-44s %s\n' 'accepting witnesses' "$witnesses"
printf '  %-44s %s\n' 'refusals' "$refusals"
printf '%s\n' 'PASS: the matrix is complete'

# ---------------------------------------------------------------------------
# [7/9] Mutation layer. One mutant per fix. Two of the five rules refuse, so
# their mutants must *accept*; three admit, so theirs must *refuse*. Both
# directions are asserted — a mutant that agrees with the real compiler has
# not been tested, whichever way it agrees.
# ---------------------------------------------------------------------------
printf '%s\n' '[7/9] Mutation layer'
# The real compiler refuses this program; the mutant must accept it.
mutant_accepts() {   # mutant_accepts <name> <source>
    mname=$1
    printf '%s\n' "$2" > "$OUT/m.ast"
    if "$A" build-elf "$OUT/m.ast" -o "$OUT/m.a64" >"$OUT/m.err" 2>&1; then
        echo "FAIL: the real compiler accepts $mname" >&2; exit 1
    fi
    if ! "$OUT/mut.aster" build-elf "$OUT/m.ast" -o "$OUT/mm.a64" >"$OUT/mm.err" 2>&1; then
        echo "FAIL: mutant $mname still refuses — the rule is untested" >&2
        sed -n '1,2p' "$OUT/mm.err" >&2; exit 1
    fi
}
# The real compiler accepts this program and it exits `want`; the mutant must
# not produce the same answer (here: it must not compile at all).
mutant_refuses() {   # mutant_refuses <name> <source> <want>
    mname=$1
    printf '%s\n' "$2" > "$OUT/m.ast"
    if ! "$A" build-elf "$OUT/m.ast" -o "$OUT/m.a64" >"$OUT/m.err" 2>&1; then
        echo "FAIL: the real compiler refuses $mname" >&2; sed -n '1,3p' "$OUT/m.err" >&2; exit 1
    fi
    $RUNNER "$OUT/m.a64" >/dev/null 2>&1 && got=0 || got=$?
    if [ "$got" != "$3" ]; then
        echo "FAIL: $mname: expected exit $3, got $got" >&2; exit 1
    fi
    # The mutant is expected to abort the compile (that is the defect), and a
    # shell reports an aborting child on its own stderr — quieten that, it is
    # the mutant's death notice and not a finding.
    if ( "$OUT/mut.aster" build-elf "$OUT/m.ast" -o "$OUT/mm.a64" >"$OUT/mm.err" 2>&1 ) 2>/dev/null; then
        echo "FAIL: mutant $mname still accepts — the rule is untested" >&2; exit 1
    fi
}
mutate() {   # mutate <name> <perl -0pi script> <expectation...>
    name=$1; script=$2; shift 2
    cp src/aster.cpp "$OUT/mut.cpp"
    if ! perl -0pi -e "$script" "$OUT/mut.cpp" 2>"$OUT/mut.perl"; then
        echo "FAIL: mutant $name could not be applied" >&2; sed -n '1,3p' "$OUT/mut.perl" >&2; exit 1
    fi
    if cmp -s src/aster.cpp "$OUT/mut.cpp"; then
        echo "FAIL: mutant $name did not change the source" >&2; exit 1
    fi
    if ! $CXX -std=c++17 -O2 -w "$OUT/mut.cpp" -o "$OUT/mut.aster" >"$OUT/mut.build" 2>&1; then
        echo "FAIL: mutant $name does not build" >&2; sed -n '1,3p' "$OUT/mut.build" >&2; exit 1
    fi
    "$@"
    printf '  %-44s caught\n' "$name"
}
if [ "$have_qemu" = no ]; then
    printf '  SKIP: the mutation layer needs qemu to observe a changed answer\n'
else
# n1: the shift family leaves the TypedIR exemption — a legal wide shift
# aborts the compiler again.
mutate 'n1: Shl/Shr/BitNot leave the exemption' \
    's/\n[ ]*case Expr::Shl: case Expr::Shr: case Expr::BitNot:\n/\n/' \
    mutant_refuses 'i64 << through a sum' \
    'fn main() -> i32 { let a: i64 = 1; let b: i64 = 2; let c: i64 = (a + b) << 2; return i32(c); }' 12
# n2: two enums compare by their bits again.
mutate 'n2: cross-enum comparison allowed' \
    's/if\(a\.sid!=b\.sid\)[\s\S]*?throw Error\(loc\(e\.line,e\.col,"cannot compare two different enum types: "\+tyNameFull\(a\)\+" and "\+tyNameFull\(b\)\)\);/if(false)return Ty::Bool;/' \
    mutant_accepts 'cross-enum ==' 'enum Color { R, G }
enum Fruit { A, B }
fn main() -> i32 { let c: Color = R; let f: Fruit = A; if (c == f) { return 1; } return 0; }'
# n3: an enum slot takes any literal again.
mutate 'n3: enum literal not range-checked' \
    's/if\(t\.k==Ty::Enum\)return enumValueFits\(\(int64_t\)e\.n\);//' \
    mutant_accepts 'enum <- constant past i32' 'enum Color { R, G }
fn main() -> i32 { let c: Color = 4294967296; return 0; }'
# n4: the auto-increment walks out of i32 unnamed again.
mutate 'n4: enum auto-increment not checked' \
    's/else if\(!enumValueFits\(val\)\)throw Error/else if(false)throw Error/' \
    mutant_accepts 'enum auto-increment past i32' 'enum E { A = 2147483647, B }
fn main() -> i32 { return i32(B); }'
# n5: a value may narrow implicitly again.
mutate 'n5: no assignability check on a value' \
    's/if\(!tyAssignable\(want,actual,e\)\)[\s\S]*?" \(write an explicit cast to truncate\)"\)\);/if(false)throw Error(loc(e.line,e.col,what));/' \
    mutant_accepts 'return narrowing i64 -> u8' 'fn f() -> u8 { let x: i64 = 300; return x; }
fn main() -> i32 { return i32(f()); }'
# n6: a let may narrow implicitly again — the branch that made the rule
# positional rather than universal.
mutate 'n6: let no longer checks assignability' \
    's/if\(!semaTypeIsPlaceholder\(\*s\.expr\)&&!tyAssignable\(s\.ty,actual,\*s\.expr\)\)[\s\S]*?" \(write an explicit cast to truncate\)"\)\);/if(false)throw Error(loc(s.line,s.col,"mutant"));\n/' \
    mutant_accepts 'let narrowing i64 -> u8' 'fn main() -> i32 { let x: i64 = 300; let b: u8 = x; return i32(b); }'
# n7/n8: the two positions the round leaves alone are left alone on purpose, so
# each gets a mutant that withdraws the exemption — and both must be caught by
# a program the real compiler *accepts*. n7 is the load-bearing one:
# `bootstrap/aster.ast` stores an i64 instruction word into an i32 stream and
# the bootstrap subset has no cast, so tightening it breaks self-hosting.
mutate 'n7: element store tightened' \
    's/elem,\*s\.expr,actual,([\s\S]*?),false\);/elem,*s.expr,actual,$1);/' \
    mutant_refuses 'i64 into an i32 element' \
    'fn main() -> i32 { let a: i32[4] = 0; let w: i64 = 7; a[0] = w; return a[0]; }' 7
mutate 'n8: field store tightened' \
    's/field,\*s\.expr,actual,([\s\S]*?),false\);/field,*s.expr,actual,$1);/' \
    mutant_refuses 'i64 into an i32 field' \
    'struct S { v: i32 }
fn main() -> i32 { let s: S = S { 0 }; let w: i64 = 9; s.v = w; return s.v; }' 9
printf '%s\n' 'PASS: eight mutated compilers each lose exactly one rule, and the matrix notices'
fi

# ---------------------------------------------------------------------------
# [8/9] Byte-identity baseline. The round answers questions about programs,
# not about bytes: nothing it did should move a single emitted byte, and this
# layer is what would say so if it had.
# ---------------------------------------------------------------------------
printf '%s\n' '[8/9] Byte-identity baseline'
BASE=$(aster_baseline_file)
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
FILTER='-e ^cast-conversions\. -e ^sizeof_len\. -e ^struct_array_field\. -e ^array_elem_types\. -e ^precedence\. -e ^array_address\. -e ^multi_dim_array\. -e ^lifecycle\. -e ^fn_type\. -e ^cb_table\. -e ^fn_ret\. -e ^call-stmt\. -e ^copy\. -e ^arena\. -e ^stdlib_demo\. -e ^integer_cast\. -e ^switch\. -e ^literals\. -e ^tls_demo\. -e ^so_verstrlen\. -e ^c_ptr_difference\. -e ^address_of\. -e ^address_of_abi\. -e ^so_tls_demo\. -e ^enum_demo\. -e ^type_alias\. -e ^const_binding\. -e ^void_return\.'
grep -v $FILTER "$BASE" | LC_ALL=C sort > "$OUT/expected-old.txt"
grep -v $FILTER "$OUT/hashes.txt" | LC_ALL=C sort > "$OUT/got-old.txt"
if ! diff -u "$OUT/expected-old.txt" "$OUT/got-old.txt" > "$OUT/old.diff"; then
    echo 'FAIL: a pre-existing example moved — the round changed bytes' >&2
    sed -n '1,20p' "$OUT/old.diff" >&2
    exit 1
fi
old=$(wc -l < "$OUT/expected-old.txt")
new=$(wc -l < "$OUT/got-old.txt")
[ "$old" -eq 312 ] \
    || { echo "FAIL: expected 312 pre-existing baseline rows, found $old" >&2; exit 1; }
[ "$new" -eq 312 ] \
    || { echo "FAIL: expected 312 rows of pre-existing output, found $new" >&2; exit 1; }
printf '  %-44s %s\n' 'pre-existing rows byte-identical' "$old"
printf '%s\n' 'PASS: byte-identity baseline holds'

# ---------------------------------------------------------------------------
# [9/9] The shapes through every build mode.
# ---------------------------------------------------------------------------
printf '%s\n' '[9/9] The shapes, all three build modes'
shape() {   # shape <name> <source>
    printf '%s\n' "$2" > "$OUT/s.ast"
    for mode in build-elf build-so "build-obj --pic"; do
        if ! "$A" $mode "$OUT/s.ast" -o "$OUT/s.out" >"$OUT/s.err" 2>&1; then
            echo "FAIL: $1 does not $mode" >&2; sed -n '1,3p' "$OUT/s.err" >&2; exit 1
        fi
    done
    printf '  %-44s elf+so+pic\n' "$1"
}
shape 'i64 << through a sum' 'fn main() -> i32 { let a: i64 = 1; let b: i64 = 2; let c: i64 = (a + b) << 2; return i32(c); }'
shape 'same-enum comparison' 'enum Color { R, G }
fn main() -> i32 { let c: Color = R; if (c == R) { return 1; } return 0; }'
shape 'return u8(x) — the cast' 'fn f() -> u8 { let x: i64 = 300; return u8(x); }
fn main() -> i32 { return i32(f()); }'
shape 'return a + b on two u8' 'fn add_u8(a: u8, b: u8) -> u8 { return a + b; }
fn main() -> i32 { return i32(add_u8(200, 55)); }'
printf '%s\n' 'PASS: all v0.23.64-dev type-strictness checks'
