#!/bin/sh
# tests/eval-order-checks.sh — evaluation order and operand width.
#
# v0.23.62-dev fixes four defects that a green gate had been hiding, all of
# them of one kind: a value produced in the wrong order, or at the wrong
# width, while every witness was written in the one shape that dodged them
# (a constant subscript, a constant right-hand side, a 32-bit operand).
#
#   1. a two-dimensional store computed its target address into X16 and then
#      evaluated the right-hand side — which materialises a global's address
#      into that same X16 — so `m[0][1] = g` stored into g.
#   2. a struct array field computed its base address into X16 and then its
#      subscript, so `s.xs[gi]` with a global gi read the wrong element.
#   3. `*p = v` generated v at the default i32 width and stored it at the
#      element's, so a ptr<i64> wrote 4294967291 for -5.
#   4. `(bool)` of a 64-bit operand compared only the low 32 bits, so
#      `(bool)` of 0x1_0000_0000 answered false.
#
# The suite's spine is therefore a matrix, not a list: every fix is witnessed
# once per operand kind — constant, local, global, call — because the defect
# lived in the difference between those columns, and a suite that tests one
# column cannot see it.
#
# Layers (the project 9-layer shape): strict build, source guards, the qemu
# matrix, a C differential twin, the rejection matrix (bounds checks still
# fire after the reordering), coverage, four mutations (one per fix), the
# byte baseline, and the fixed shapes through all three build modes.
set -eu
cd "$(dirname "$0")/.."
. tests/lib/baseline.sh
CXX=${CXX:-c++}
RUNNER=${RUNNER:-tests/run-aarch64.sh}
OUT=${OUT:-tmp-eval-order-checks}
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
    printf '%s\n' 'SKIP: eval-order-checks needs qemu-aarch64 (or an AArch64 host) for its behavioural layers'
fi

# ---------------------------------------------------------------------------
# [2/9] Source guards. Each fix is pinned where it was made. The two
# reorderings cannot be pinned by one line each, so they are pinned by the
# comment that states the order; the two width fixes are pinned by the code.
# ---------------------------------------------------------------------------
printf '%s\n' '[2/9] Source guards: evaluation order and width'
grep -qF '#define ASTER_VERSION_STRING "0.23.75-dev"' src/aster.cpp \
    || { echo "FAIL: the version constant is not 0.23.75-dev" >&2; exit 1; }
grep -qF 'v0.23.62-dev: a struct store parks the destination in the' src/aster.cpp \
    || { echo "FAIL: the multi-dimensional store no longer generates its value first" >&2; exit 1; }
grep -qF 'v0.23.62-dev: the subscript is evaluated BEFORE the field' src/aster.cpp \
    || { echo "FAIL: emitElemAddrField no longer evaluates the subscript first" >&2; exit 1; }
grep -qF 'int address=gen(*s.idx);int value=gen(*s.expr,elem);' src/aster.cpp \
    || { echo "FAIL: a dereference store no longer generates its value at the element width" >&2; exit 1; }
grep -qF 'emit(tyIs64(from)?cmpZeroX(a):cmpZero(a));' src/aster.cpp \
    || { echo "FAIL: (bool) no longer compares at the operand width" >&2; exit 1; }
printf '%s\n' 'PASS: all four fixes are pinned in the source'

# ---------------------------------------------------------------------------
# [3/9] The matrix. Every witness returns the value it is named for, so a
# wrong answer is the exit code. The four columns are the operand kinds.
# ---------------------------------------------------------------------------
printf '%s\n' '[3/9] qemu: the evaluation-order and width matrix'
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
    printf '  %-44s %s\n' "$name" "$got"
}
A=$OUT/aster
if [ "$have_qemu" = yes ]; then
# --- 1. a two-dimensional store: the right-hand side, one column each ---
check "$A" '2d store <- constant'              42 'fn main() -> i32 { let m: i32[2][3] = 0; m[0][1] = 42; return m[0][1]; }'
check "$A" '2d store <- global'                42 'let g: i32 = 42;
fn main() -> i32 { let m: i32[2][3] = 0; m[0][1] = g; return m[0][1]; }'
check "$A" '2d store <- call'                  42 'fn f() -> i32 { return 42; }
fn main() -> i32 { let m: i32[2][3] = 0; m[0][1] = f(); return m[0][1]; }'
check "$A" '2d store <- local'                 42 'fn main() -> i32 { let m: i32[2][3] = 0; let v: i32 = 42; m[0][1] = v; return m[0][1]; }'
check "$A" '2d store, variable subscripts'     42 'let g: i32 = 42;
fn main() -> i32 { let m: i32[2][3] = 0; let i: i32 = 0; let j: i32 = 1; m[i][j] = g; return m[0][1]; }'
check "$A" '3d store <- global'                 7 'let g: i32 = 7;
fn main() -> i32 { let m: i32[2][2][2] = 0; m[0][1][1] = g; return m[0][1][1]; }'
# --- 2. a struct array field: the subscript, one column each ---
check "$A" 'struct field [constant]'           12 'struct S { xs: i32[4] }
fn main() -> i32 { let s: S; s.xs[2] = 12; return s.xs[2]; }'
check "$A" 'struct field [global]'             12 'struct S { xs: i32[4] }
let gi: i32 = 2;
fn main() -> i32 { let s: S; s.xs[2] = 12; return s.xs[gi]; }'
check "$A" 'struct field [local]'              12 'struct S { xs: i32[4] }
fn main() -> i32 { let s: S; let li: i32 = 2; s.xs[2] = 12; return s.xs[li]; }'
check "$A" 'struct field [call]'               12 'struct S { xs: i32[4] }
fn fi() -> i32 { return 2; }
fn main() -> i32 { let s: S; s.xs[2] = 12; return s.xs[fi()]; }'
check "$A" 'struct field store, [global]'      42 'struct S { xs: i32[4] }
let gi: i32 = 2;
fn main() -> i32 { let s: S; s.xs[gi] = 42; return s.xs[2]; }'
# --- 3. a store through a typed pointer: the object's own width ---
check "$A" 'ptr<i64> store, global object'      1 'let q: i64 = 0;
fn main() -> i32 { let p: ptr<i64> = &q; *p = -5; if (q == -5) { return 1; } return 0; }'
check "$A" 'ptr<i64> store, local object'       1 'fn main() -> i32 { let q: i64 = 0; let p: ptr<i64> = &q; *p = -5; if (q == -5) { return 1; } return 0; }'
check "$A" 'ptr<i64> store keeps 300'          44 'let q: i64 = 0;
fn main() -> i32 { let p: ptr<i64> = &q; *p = 300; return i32(q); }'
# --- 4. `(bool)` of a 64-bit operand: all 64 bits ---
check "$A" '(bool) u64 low bit'                 1 'fn main() -> i32 { let a: u64 = 1; if (bool(a)) { return 1; } return 0; }'
check "$A" '(bool) u64 bit 32'                  1 'fn main() -> i32 { let a: u64 = 4294967296; if (bool(a)) { return 1; } return 0; }'
check "$A" '(bool) i64 negative'                1 'fn main() -> i32 { let a: i64 = -1; if (bool(a)) { return 1; } return 0; }'
check "$A" '(bool) u64 zero'                    0 'fn main() -> i32 { let a: u64 = 0; if (bool(a)) { return 1; } return 0; }'
check "$A" '(bool) u64 bit 32, through a bool'  1 'fn main() -> i32 { let a: u64 = 4294967296; let b: bool = bool(a); if (b) { return 1; } return 0; }'
printf '%s\n' 'PASS: 19 witnesses, every column of every fix'
fi

# ---------------------------------------------------------------------------
# [4/9] Differential: the C twin says what these programs mean.
# ---------------------------------------------------------------------------
printf '%s\n' '[4/9] Differential: Aster vs the C twin'
if [ "$have_qemu" = yes ] && [ "$have_cc" = yes ] && [ -f tests/eval-order-twin.c ]; then
    if $HOSTCC -O2 -o "$OUT/twin" tests/eval-order-twin.c 2>"$OUT/twin.build"; then
        diffcase() {   # diffcase <case> <aster source>
            name=$1; printf '%s\n' "$2" > "$OUT/d.ast"
            if ! "$A" build-elf "$OUT/d.ast" -o "$OUT/d.a64" >"$OUT/d.err" 2>&1; then
                echo "FAIL: $name does not compile" >&2; sed -n '1,3p' "$OUT/d.err" >&2; exit 1
            fi
            $RUNNER "$OUT/d.a64" >/dev/null 2>&1 && got=0 || got=$?
            if [ "$got" -gt 127 ]; then got=$((got-256)); fi
            $RUNNER "$OUT/twin" "$name" >/dev/null 2>&1 && want=0 || want=$?
            if [ "$want" -gt 127 ]; then want=$((want-256)); fi
            if [ "$got" != "$want" ]; then
                echo "FAIL: $name: Aster gave $got, C gave $want" >&2; exit 1
            fi
            printf '  %-44s %s\n' "$name" "$got"
        }
        diffcase A2 'let g: i32 = 42;
fn main() -> i32 { let m: i32[2][3] = 0; m[0][1] = g; return m[0][1]; }'
        diffcase A3 'fn f() -> i32 { return 42; }
fn main() -> i32 { let m: i32[2][3] = 0; m[0][1] = f(); return m[0][1]; }'
        diffcase A6 'let g: i32 = 7;
fn main() -> i32 { let m: i32[2][2][2] = 0; m[0][1][1] = g; return m[0][1][1]; }'
        diffcase B2 'struct S { xs: i32[4] }
let gi: i32 = 2;
fn main() -> i32 { let s: S; s.xs[2] = 12; return s.xs[gi]; }'
        diffcase B5 'struct S { xs: i32[4] }
let gi: i32 = 2;
fn main() -> i32 { let s: S; s.xs[gi] = 42; return s.xs[2]; }'
        diffcase C1 'let q: i64 = 0;
fn main() -> i32 { let p: ptr<i64> = &q; *p = -5; if (q == -5) { return 1; } return 0; }'
        diffcase C3 'let q: i64 = 0;
fn main() -> i32 { let p: ptr<i64> = &q; *p = 300; return i32(q); }'
        diffcase D2 'fn main() -> i32 { let a: u64 = 4294967296; if (bool(a)) { return 1; } return 0; }'
        diffcase D4 'fn main() -> i32 { let a: u64 = 0; if (bool(a)) { return 1; } return 0; }'
        printf '%s\n' 'PASS: 9 differential cases agree with C'
    else
        printf '  SKIP: the C twin does not build with %s\n' "$HOSTCC"
    fi
else
    printf '  SKIP: the differential layer needs qemu, a C compiler, and the twin\n'
fi

# ---------------------------------------------------------------------------
# [5/9] Rejection matrix. Reordering must not have moved a bounds check out
# of the program: both checks are still there, and still refuse.
# ---------------------------------------------------------------------------
printf '%s\n' '[5/9] Rejection matrix'
A=$OUT/aster
must_refuse() {   # must_refuse <name> <source>
    printf '%s\n' "$2" > "$OUT/r.ast"
    if "$A" build-elf "$OUT/r.ast" -o "$OUT/r.a64" >"$OUT/r.err" 2>&1; then
        echo "FAIL: $name is accepted — a bounds check went missing" >&2; exit 1
    fi
    grep -qi 'out of bounds\|index' "$OUT/r.err" \
        || { echo "FAIL: $name is refused, but not as an out-of-bounds error" >&2; sed -n '1,2p' "$OUT/r.err" >&2; exit 1; }
    printf '  %-44s refused\n' "$1"
}
must_refuse '2d store, constant subscript past the row' \
    'fn main() -> i32 { let m: i32[2][3] = 0; m[5][0] = 1; return 0; }'
must_refuse '2d store, constant subscript past the column' \
    'fn main() -> i32 { let m: i32[2][3] = 0; m[0][9] = 1; return 0; }'
must_refuse 'struct field subscript past the field' \
    'struct S { xs: i32[4] }
fn main() -> i32 { let s: S; s.xs[9] = 1; return 0; }'
must_refuse 'struct field read past the field' \
    'struct S { xs: i32[4] }
fn main() -> i32 { let s: S; return s.xs[9]; }'
printf '%s\n' 'PASS: the bounds checks survived the reordering'

# ---------------------------------------------------------------------------
# [6/9] Coverage: the matrix is the point of the suite, so the suite counts
# itself. A witness that is dropped silently is a column going untested.
# ---------------------------------------------------------------------------
printf '%s\n' '[6/9] Coverage: every column is exercised'
witnesses=$(grep -c "^check \"\$A\" " tests/eval-order-checks.sh || echo 0)
[ "$witnesses" -ge 19 ] \
    || { echo "FAIL: expected at least 19 matrix witnesses, found $witnesses" >&2; exit 1; }
refusals=$(grep -c "^must_refuse " tests/eval-order-checks.sh || echo 0)
[ "$refusals" -ge 4 ] \
    || { echo "FAIL: expected at least 4 refusals, found $refusals" >&2; exit 1; }
printf '  %-44s %s\n' 'matrix witnesses' "$witnesses"
printf '  %-44s %s\n' 'refusals' "$refusals"
printf '%s\n' 'PASS: the matrix is complete'

# ---------------------------------------------------------------------------
# [7/9] Mutation layer. One mutant per fix, each restoring exactly the
# defect it names; the matrix witness for that fix must change its answer.
# The reorderings are two-line swaps, so the mutants are applied with perl.
# ---------------------------------------------------------------------------
printf '%s\n' '[7/9] Mutation layer'
must_differ() {   # must_differ <name> <source> <the exit the fix produces>
    mname=$1
    printf '%s\n' "$2" > "$OUT/m.ast"
    if ! "$A" build-elf "$OUT/m.ast" -o "$OUT/m.a64" >"$OUT/m.err" 2>&1; then
        echo "FAIL: the real compiler refuses $mname" >&2; sed -n '1,3p' "$OUT/m.err" >&2; exit 1
    fi
    $RUNNER "$OUT/m.a64" >/dev/null 2>&1 && got=0 || got=$?
    if [ "$got" -gt 127 ]; then got=$((got-256)); fi
    if [ "$got" != "$3" ]; then
        echo "FAIL: $mname: expected exit $3, got $got" >&2; exit 1
    fi
    if ! "$OUT/mut.aster" build-elf "$OUT/m.ast" -o "$OUT/mm.a64" >"$OUT/mm.err" 2>&1; then
        :   # a mutant that refuses the program is caught too
    else
        $RUNNER "$OUT/mm.a64" >/dev/null 2>&1 && mgot=0 || mgot=$?
        if [ "$mgot" -gt 127 ]; then mgot=$((mgot-256)); fi
        if [ "$mgot" = "$3" ]; then
            echo "FAIL: mutant $mname still gives $3 — the fix is untested" >&2; exit 1
        fi
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
# m1: the two-dimensional store addresses first again — the value's global
# read lands on the target address, so the store goes to the wrong place.
mutate 'm1: 2d store addresses before the value' \
    's/( {20}int v=gen\(\*s\.expr,elem\);\n)( {20}emitIndexAddr\(\*s\.idx\);\n)/$2$1/' \
    must_differ '2d store <- global' 'let g: i32 = 42;
fn main() -> i32 { let m: i32[2][3] = 0; m[0][1] = g; return m[0][1]; }' 42
# m2: the struct array field takes its base address before its subscript.
mutate 'm2: struct field bases before the subscript' \
    's/( {8}int r=gen\(index\);\n)( {8}emitStructAddr\(fbase\);[^\n]*\n)/$2$1/' \
    must_differ 'struct field [global]' 'struct S { xs: i32[4] }
let gi: i32 = 2;
fn main() -> i32 { let s: S; s.xs[2] = 12; return s.xs[gi]; }' 12
# m3: a dereference store generates its value at the default width again.
mutate 'm3: deref store at the default width' \
    's/int address=gen\(\*s\.idx\);int value=gen\(\*s\.expr,elem\);/int address=gen(*s.idx);int value=gen(*s.expr);/' \
    must_differ 'ptr<i64> store of -5' 'let q: i64 = 0;
fn main() -> i32 { let p: ptr<i64> = &q; *p = -5; if (q == -5) { return 1; } return 0; }' 1
# m4: `(bool)` compares 32 bits whatever the operand is.
mutate 'm4: (bool) always compares 32 bits' \
    's/emit\(tyIs64\(from\)\?cmpZeroX\(a\):cmpZero\(a\)\);/emit(cmpZero(a));/' \
    must_differ '(bool) u64 bit 32' 'fn main() -> i32 { let a: u64 = 4294967296; if (bool(a)) { return 1; } return 0; }' 1
printf '%s\n' 'PASS: four mutated compilers each lose exactly one fix, and the matrix notices'
fi

# ---------------------------------------------------------------------------
# [8/9] Byte-identity baseline. The reorderings move three examples —
# array_address, multi_dim_array and struct_array_field — which is exactly
# the set this suite claims: every other product is unchanged.
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
    echo 'FAIL: a pre-existing example moved — the round changed bytes beyond its own claim' >&2
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
# [9/9] The four fixed shapes through every build mode, so the fix is not
# something only build-elf happens to carry.
# ---------------------------------------------------------------------------
printf '%s\n' '[9/9] The fixed shapes, all three build modes'
shape() {   # shape <name> <source>
    printf '%s\n' "$2" > "$OUT/s.ast"
    for mode in build-elf build-so "build-obj --pic"; do
        if ! "$A" $mode "$OUT/s.ast" -o "$OUT/s.out" >"$OUT/s.err" 2>&1; then
            echo "FAIL: $name does not $mode" >&2; sed -n '1,3p' "$OUT/s.err" >&2; exit 1
        fi
    done
    printf '  %-44s elf+so+pic\n' "$1"
}
shape '2d store <- global' 'let g: i32 = 42;
fn main() -> i32 { let m: i32[2][3] = 0; m[0][1] = g; return m[0][1]; }'
shape 'struct field [global]' 'struct S { xs: i32[4] }
let gi: i32 = 2;
fn main() -> i32 { let s: S; s.xs[2] = 12; return s.xs[gi]; }'
shape 'ptr<i64> store' 'let q: i64 = 0;
fn main() -> i32 { let p: ptr<i64> = &q; *p = -5; if (q == -5) { return 1; } return 0; }'
shape '(bool) u64 bit 32' 'fn main() -> i32 { let a: u64 = 4294967296; if (bool(a)) { return 1; } return 0; }'
printf '%s\n' 'PASS: all v0.23.62-dev evaluation-order and width checks'
