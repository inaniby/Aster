#!/bin/sh
# v0.23.36-dev checks for array-parameter bounds checking under --bounds-check.
#
# From v0.23.34-dev an array parameter `fn f(a: i32[4])` carries its dimensions
# through `Function::paramDims` and remembers them in the binding (so `len(a)`/
# `sizeof(a)` can answer). This round closes the hole that was left open both
# then and in v0.23.35-dev: a subscript through such a parameter is now
# range-checked at run time exactly like a local or global array. The same
# `emitBoundsCheck` (CMP / B.LO / BRK #1) and `checkArrayBounds` (compile-time
# constant reject) machinery is reused; only the data side is new — the
# parameter's element count is carried into codegen's `paramArrayLength` map and
# its dimension list into `slotDims`, so the existing read/write/chain emission
# checks it for free.
#
# Layers: strict build; source guards that pin every new field, the init fill and
# the read-side branch; an acceptance self-check (in-range subscripts behave,
# out-of-range trap with SIGTRAP, and the flag stays opt-in); a multi-dimensional
# parameter layer; a compile-time rejection layer for constant out-of-bounds
# parameter subscripts; an Aster-vs-gcc differential; and a mutation layer that
# proves the checks actually test the new machinery.
#
# The probe needs qemu-aarch64 (or an AArch64 host) for its behavioural layers;
# without it they cannot run at all.
set -eu
cd "$(dirname "$0")/.."
CXX=${CXX:-c++}
HOSTCC=${HOSTCC:-cc}
RUNNER=${RUNNER:-tests/run-aarch64.sh}
OUT=${OUT:-tmp-array-param-bounds-checks}
mkdir -p "$OUT"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM

run_status(){ st=0; $RUNNER "$1" >/dev/null 2>&1 || st=$?; echo "$st"; }

printf '%s\n' '[1/9] Strictly build Aster compiler'
$CXX -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o "$OUT/aster"

have_qemu=yes
command -v qemu-aarch64 >/dev/null 2>&1 || have_qemu=no
case $(uname -m) in aarch64|arm64) have_qemu=yes ;; esac
if [ "$have_qemu" = no ]; then
    printf '%s\n' 'SKIP: array-param-bounds-checks needs qemu-aarch64 (or an AArch64 host) for its behavioural layers'
fi

printf '%s\n' '[2/9] Source guards: the parameter length map, its init, and the read-side check'
# A regression that drops the design must fail here, before a behavioural check
# has to explain it.
grep -qF 'std::map<int,uint32_t> paramArrayLength;' src/aster.cpp \
    || { echo 'FAIL: paramArrayLength member missing from Codegen' >&2; exit 1; }
# The init fill inside the `if(tyIsPtrToElem(pt))` block: both the dimension
# list (multi-dimensional chain) and the element count (single-dimensional read
# and write) must be populated from the parameter's recorded dims.
grep -qF 'slotDims[slot]=f.paramDims[i];' src/aster.cpp \
    || { echo 'FAIL: parameter dimensions are not carried into slotDims' >&2; exit 1; }
grep -qF 'paramArrayLength[slot]=(uint32_t)dimsProduct(f.paramDims[i]);' src/aster.cpp \
    || { echo 'FAIL: parameter element count is not carried into paramArrayLength' >&2; exit 1; }
# The read-side check sits in emitElemAddr's pointer branch, gated on
# paramArrayLength so a plain pointer is left unchecked as before.
grep -qF 'if(paramArrayLength.count(slot)){' src/aster.cpp \
    || { echo 'FAIL: array-parameter read is not bounds-checked' >&2; exit 1; }
# The write-side check mirrors it.
grep -qF 'if(!s.name.empty()){int aslot=lookup(s.name);' src/aster.cpp \
    || { echo 'FAIL: array-parameter write is not bounds-checked' >&2; exit 1; }
# arrayLengthOf must still consult localArrayLength first: changing it would
# retype `&a` on a parameter (AddrOf at the arrayLengthOf call site) and move
# default bytes, so the guard proves we did not regress there.
grep -qF 'auto it=localArrayLength.find(slot);return it==localArrayLength.end()?0:it->second;' src/aster.cpp \
    || { echo 'FAIL: arrayLengthOf must still short-circuit on localArrayLength' >&2; exit 1; }
printf '%s\n' 'PASS: paramArrayLength member, its init fill, and both check sites pinned'

if [ "$have_qemu" = yes ]; then
printf '%s\n' '[3/9] Acceptance: in-range parameter subscripts behave identically (qemu)'
# Read through a parameter array; in range, identical to a plain local read.
cat > "$OUT/read.ast" <<'AST'
fn f(a: i32[4]) -> i32 {
    let s: i32 = 0;
    s = s + a[0]; s = s + a[1]; s = s + a[2]; s = s + a[3];
    return s;
}
fn main() -> i32 { let arr: i32[4] = 10; return f(arr); }
AST
"$OUT/aster" build-elf "$OUT/read.ast" -o "$OUT/read-off" >/dev/null
"$OUT/aster" build-elf "$OUT/read.ast" -o "$OUT/read-on" --bounds-check >/dev/null
st=$(run_status "$OUT/read-off"); [ "$st" = 40 ] || { echo "FAIL: read-off exit $st, want 40" >&2; exit 1; }
st=$(run_status "$OUT/read-on");  [ "$st" = 40 ] || { echo "FAIL: read-on exit $st, want 40" >&2; exit 1; }
# Write through a parameter array.
cat > "$OUT/write.ast" <<'AST'
fn f(a: i32[4], v: i32) -> i32 { a[1] = v; return a[1]; }
fn main() -> i32 { let arr: i32[4] = 0; return f(arr, 7); }
AST
"$OUT/aster" build-elf "$OUT/write.ast" -o "$OUT/write-on" --bounds-check >/dev/null
st=$(run_status "$OUT/write-on"); [ "$st" = 7 ] || { echo "FAIL: write-on exit $st, want 7" >&2; exit 1; }
printf '%s\n' 'PASS: in-range read and write through a parameter array return the same value with and without --bounds-check'

printf '%s\n' '[4/9] Acceptance: out-of-range parameter subscripts trap (SIGTRAP 133)'
cat > "$OUT/oob-read.ast" <<'AST'
fn f(a: i32[4], k: i32) -> i32 { return a[k]; }
fn main() -> i32 { let arr: i32[4] = 7; return f(arr, 4); }
AST
cat > "$OUT/oob-write.ast" <<'AST'
fn f(a: i32[4], k: i32) -> i32 { a[k] = 9; return a[0]; }
fn main() -> i32 { let arr: i32[4] = 3; return f(arr, 4); }
AST
cat > "$OUT/oob-neg.ast" <<'AST'
fn f(a: i32[4], k: i32) -> i32 { return a[k]; }
fn main() -> i32 { let arr: i32[4] = 7; return f(arr, 0 - 1); }
AST
for f in oob-read oob-write oob-neg; do
    "$OUT/aster" build-elf "$OUT/$f.ast" -o "$OUT/$f-on" --bounds-check >/dev/null
    st=$(run_status "$OUT/$f-on")
    [ "$st" = 133 ] || { echo "FAIL: $f with --bounds-check exit $st, want 133 (SIGTRAP)" >&2; exit 1; }
    # The default build does NOT trap: the flag is opt-in and must stay so.
    "$OUT/aster" build-elf "$OUT/$f.ast" -o "$OUT/$f-off" >/dev/null
    st=$(run_status "$OUT/$f-off")
    [ "$st" != 133 ] || { echo "FAIL: $f default build traps: --bounds-check is no longer opt-in" >&2; exit 1; }
done
printf '%s\n' 'PASS: out-of-range read/write/negative parameter subscripts raise SIGTRAP (133) under --bounds-check; default build does not'

printf '%s\n' '[5/9] Multi-dimensional parameter: a[i][j] checked per dimension'
cat > "$OUT/md-ok.ast" <<'AST'
fn f(a: i32[2][3], i: i32, j: i32) -> i32 { return a[i][j]; }
fn main() -> i32 { let arr: i32[2][3] = 0; return f(arr, 1, 2); }
AST
"$OUT/aster" build-elf "$OUT/md-ok.ast" -o "$OUT/md-ok-on" --bounds-check >/dev/null
st=$(run_status "$OUT/md-ok-on"); [ "$st" = 0 ] || { echo "FAIL: md-ok exit $st, want 0" >&2; exit 1; }
cat > "$OUT/md-row.ast" <<'AST'
fn f(a: i32[2][3], i: i32, j: i32) -> i32 { return a[i][j]; }
fn main() -> i32 { let arr: i32[2][3] = 1; return f(arr, 2, 0); }
AST
cat > "$OUT/md-col.ast" <<'AST'
fn f(a: i32[2][3], i: i32, j: i32) -> i32 { return a[i][j]; }
fn main() -> i32 { let arr: i32[2][3] = 1; return f(arr, 0, 3); }
AST
for f in md-row md-col; do
    "$OUT/aster" build-elf "$OUT/$f.ast" -o "$OUT/$f-on" --bounds-check >/dev/null
    st=$(run_status "$OUT/$f-on")
    [ "$st" = 133 ] || { echo "FAIL: $f with --bounds-check exit $st, want 133" >&2; exit 1; }
done
printf '%s\n' 'PASS: i32[2][3] parameter checked per dimension (valid index runs; row/col out-of-range trap)'

printf '%s\n' '[6/9] Compile-time rejection: constant out-of-bounds parameter subscripts'
cat > "$OUT/const-1d.ast" <<'AST'
fn f(a: i32[4]) -> i32 { return a[4]; }
fn main() -> i32 { let arr: i32[4] = 7; return f(arr); }
AST
cat > "$OUT/const-2d.ast" <<'AST'
fn f(a: i32[2][3]) -> i32 { return a[1][3]; }
fn main() -> i32 { let arr: i32[2][3] = 1; return f(arr); }
AST
for f in const-1d const-2d; do
    "$OUT/aster" build-elf "$OUT/$f.ast" -o "$OUT/$f-out" --bounds-check 2>&1 | grep -qF 'array index out of bounds' \
        || { echo "FAIL: constant out-of-bounds parameter subscript not rejected ($f)" >&2; exit 1; }
done
printf '%s\n' 'PASS: constant out-of-bounds read through a parameter is rejected at compile time, flag or no flag'

printf '%s\n' '[7/9] Differential: Aster (--bounds-check) vs a cross-compiled C twin'
cat > "$OUT/diff.ast" <<'AST'
fn pick(a: i32[4], k: i32) -> i32 { return a[k]; }
fn main() -> i32 {
    let arr: i32[4] = 0;
    arr[0] = 3; arr[1] = 1; arr[2] = 4; arr[3] = 1;
    let s: i32 = pick(arr, 0) + pick(arr, 1) * pick(arr, 2) - pick(arr, 3);
    return s;
}
AST
cp tests/array-param-bounds-twin.c "$OUT/diff.c"
"$OUT/aster" build-elf "$OUT/diff.ast" -o "$OUT/diff.a64" --bounds-check >/dev/null
if $HOSTCC -std=c11 -O2 -w "$OUT/diff.c" -o "$OUT/diff.host" 2>/dev/null; then
    ga=$(run_status "$OUT/diff.a64")
    gh=$( ($RUNNER "$OUT/diff.host" >/dev/null 2>&1 && echo 0) || echo $? )
    [ "$ga" = "$gh" ] || { echo "FAIL: Aster exit $ga, C twin exit $gh" >&2; exit 1; }
    printf '  aster == c twin                %s\n' "$ga"
else
    printf '  SKIP: host C compiler unavailable for the differential layer\n'
fi
printf '%s\n' 'PASS: in-range parameter reads match the gcc twin exit for exit'

printf '%s\n' '[8/9] Mutation: the checks must fail on a damaged compiler'
mutate() { # mutate <name> <sed-expr> <source>
    sed "$2" src/aster.cpp > "$OUT/m.cpp"
    if cmp -s src/aster.cpp "$OUT/m.cpp"; then
        echo "FAIL: mutation $1 did not change the source (the guard is stale)" >&2; exit 1
    fi
    if ! $CXX -std=c++17 -O0 -w "$OUT/m.cpp" -o "$OUT/m.aster" 2>/dev/null; then
        echo "FAIL: mutant $1 does not build" >&2; exit 1
    fi
    printf '%s\n' "$3" > "$OUT/m.ast"
    if ! "$OUT/m.aster" build-elf "$OUT/m.ast" -o "$OUT/m.a64" --bounds-check >/dev/null 2>&1; then
        echo "FAIL: mutant $1 rejected a valid program" >&2; exit 1
    fi
    st=$(run_status "$OUT/m.a64")
    [ "$st" = 133 ] && { echo "FAIL: $1: the mutant still trapped — the checks do not test it" >&2; exit 1; }
    printf '  %-34s mutant no longer traps (correct: %s)\n' "$1" "$st"
}
# m1: drop the parameter length fill entirely (slotDims + paramArrayLength), so
# no subscript through a parameter is ever range-checked.
mutate 'no param-length init' \
    '/slotDims\[slot\]=f.paramDims\[i\];/d;/paramArrayLength\[slot\]=(uint32_t)dimsProduct(f.paramDims\[i\]);/d' \
    'fn f(a: i32[4], k: i32) -> i32 { return a[k]; }
fn main() -> i32 { let arr: i32[4] = 7; return f(arr, 4); }'
# m2: drop only the two read-side check *calls* in emitElemAddr (the `if` guard
# stays, now empty); the out-of-range read must fall through without trapping.
# The two lines are unique to the read branch (`paramArrayLength.at(slot)`); the
# write branch uses `paramArrayLength[aslot]`, so it is untouched.
mutate 'no read-side check' \
    '/checkArrayBounds(paramArrayLength.at(slot),index);/d;/emitBoundsCheck(paramArrayLength.at(slot),index,r);/d' \
    'fn f(a: i32[4], k: i32) -> i32 { return a[k]; }
fn main() -> i32 { let arr: i32[4] = 7; return f(arr, 4); }'
fi

printf '%s\n' 'PASS: array-parameter-bounds checks ([1/9]..[8/9] as applicable)'
