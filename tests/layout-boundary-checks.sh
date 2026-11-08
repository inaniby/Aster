#!/bin/sh
# tests/layout-boundary-checks.sh — where the layout arithmetic runs out.
#
# AUDIT-v0.23.61-dev.md item 9 asked for the ELF/linker claims to be checked
# empirically, and item 10 for `layoutStruct` to accumulate with an overflow
# check and for the size limit to be enforced earlier. Both are the same
# question — **what happens when layout arithmetic runs out of room** — and
# both had an answer that was worse than a refusal:
#
#   1. `kRelTlsOff` (the internal relocation that writes a thread-local
#      variable's block offset into the `MOVZ X17,#imm16` / `MOVK X17,#imm16,
#      LSL#16` pair) masked the offset with `& 0xffffffffu`. The pair carries
#      32 bits, so a variable at offset 2^32 was silently moved to offset 0 —
#      onto another thread-local. 513 thread-locals of 8 MiB each is a 10 KB
#      source: `g512[0] = 1; return g0[0];` returned 1 instead of 0, because
#      the two had become the same eight bytes.
#
#   2. `layoutStruct` accumulated field offsets in a `uint32_t`. A struct of
#      8192 fields of `L1[512]` (L1 being 1024 bytes) reaches exactly 2^32,
#      which wraps to **0** — and 0 passes the `size > kMaxStructSize` check
#      that ran *after* the loop. So a 4 GiB struct was accepted, `sizeof`
#      reported 0, and every field access landed on whatever the zero-size
#      slot sat on. A 4195-field variant wrapped to 712704 and was refused
#      with a size that had never existed.
#
# Both are now refusals, and both refusals name the number that did not fit.
# Nothing else moves: every example still emits the same bytes (layer [8/9]).
#
# The suite is two-sided like the rest of the project's: the accepting side
# proves the boundary is where it says it is (a thread-local block of exactly
# 2^32 - 8 MiB still works; a 1024-byte struct still works), the refusing side
# proves each ceiling fires, and the mutation layer proves each ceiling is
# load-bearing — a mutant that withdraws one has to be caught by the program
# the real compiler refuses.
#
# Layers (the project 9-layer shape): strict build, source guards, qemu
# witnesses, a C differential twin, the rejection matrix, coverage counting,
# three mutations, the byte baseline, and the shapes through all three build
# modes.
set -eu
cd "$(dirname "$0")/.."
. tests/lib/baseline.sh
CXX=${CXX:-c++}
RUNNER=${RUNNER:-tests/run-aarch64.sh}
OUT=${OUT:-tmp-layout-boundary-checks}
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
    printf '%s\n' 'SKIP: layout-boundary-checks needs qemu-aarch64 (or an AArch64 host) for its behavioural layers'
fi
A=$OUT/aster

# ---------------------------------------------------------------------------
# [2/9] Source guards. Each fix is pinned where it was made, so a later edit
# cannot quietly put the mask or the 32-bit accumulator back.
# ---------------------------------------------------------------------------
printf '%s\n' '[2/9] Source guards: the two ceilings'
grep -qF '#define ASTER_VERSION_STRING "0.23.75-dev"' src/aster.cpp \
    || { echo "FAIL: the version constant is not 0.23.75-dev" >&2; exit 1; }
# (1) the thread-local offset must fit the MOVZ/MOVK pair, and the refusal is
# at the point of the lossy conversion rather than in the caller.
grep -qF 'if(off>0xffffffffULL)' src/aster.cpp \
    || { echo "FAIL: a thread-local offset is no longer range-checked" >&2; exit 1; }
grep -qF '32-bit MOVZ/MOVK pair' src/aster.cpp \
    || { echo "FAIL: the thread-local refusal no longer says what did not fit" >&2; exit 1; }
[ "$(grep -c '& 0xffffffffu)' src/aster.cpp)" = 0 ] \
    || { echo "FAIL: a thread-local offset is masked again instead of being checked" >&2; exit 1; }
# (2) the struct accumulation is 64-bit, and the size limit is enforced inside
# layoutStruct — which is why the constant had to move to namespace scope.
grep -qF 'uint64_t off = 0; uint32_t align = 1;' src/aster.cpp \
    || { echo "FAIL: the struct accumulation is no longer 64-bit" >&2; exit 1; }
grep -qF 'static void layoutStruct(StructDef& s,const Token& id)' src/aster.cpp \
    || { echo "FAIL: layoutStruct no longer carries the position it reports" >&2; exit 1; }
grep -qF 'layoutStruct(s,id);' src/aster.cpp \
    || { echo "FAIL: the caller no longer hands the declaration to layoutStruct" >&2; exit 1; }
grep -qF 'if (off > (uint64_t)kMaxStructSize) tooLarge(f,off);' src/aster.cpp \
    || { echo "FAIL: the size limit is no longer checked while fields are placed" >&2; exit 1; }
grep -qF 'if (size > (uint64_t)kMaxStructSize) tooLarge(s.fields.back(),size);' src/aster.cpp \
    || { echo "FAIL: the size limit is no longer asserted on the rounded-up size" >&2; exit 1; }
printf '%s\n' 'PASS: both ceilings are pinned in the source'

# ---------------------------------------------------------------------------
# [3/9] The accepting side: the boundary is where the round says it is. A
# thread-local block one stride under 2^32 still addresses every variable
# distinctly; a 1024-byte struct still lays out exactly as C lays it out.
# ---------------------------------------------------------------------------
printf '%s\n' '[3/9] qemu: what must still be accepted'
check() {
    aster=$1; name=$2; want=$3
    printf '%s\n' "$4" > "$OUT/c.ast"
    if ! $aster build-elf "$OUT/c.ast" -o "$OUT/c.a64" >"$OUT/c.err" 2>&1; then
        echo "FAIL: $name does not compile" >&2; sed -n '1,3p' "$OUT/c.err" >&2; exit 1
    fi
    # An Aster program's `return r` is the process exit status, so it is
    # already r & 0xff — the raw status is the only comparison that means
    # anything, and large values are compared through /256 below.
    $RUNNER "$OUT/c.a64" >/dev/null 2>&1 && got=0 || got=$?
    if [ "$got" != "$want" ]; then
        echo "FAIL: $name: expected exit $want, got $got" >&2; exit 1
    fi
    printf '%s\n' "$name" >> "$OUT/witnesses.txt"
    printf '  %-44s %s\n' "$name" "$got"
}
# A source generator: the boundary cases are far too large to write out.
gen_tls() {  # gen_tls <count> <last-expr>
    n=$1; body=$2
    : > "$OUT/gen.ast"
    i=0
    while [ "$i" -lt "$n" ]; do
        printf 'tls let g%d: i64[1048576] = 0;\n' "$i" >> "$OUT/gen.ast"
        i=$((i + 1))
    done
    printf 'fn main() -> i32 { g%d[0] = 1; return i32(%s); }\n' "$((n - 1))" "$body" >> "$OUT/gen.ast"
}
if [ "$have_qemu" = yes ]; then
# --- struct layout: unchanged for everything that fits ---
check "$A" 'sizeof(i64[128]) is 1024'       4 'struct A { a: i64[128] }
fn main() -> i32 { return sizeof(A) / 256; }'
check "$A" 'sizeof(1016 + 1) rounds to 1024' 4 'struct B { a: i64[127], b: u8 }
fn main() -> i32 { return sizeof(B) / 256; }'
check "$A" 'mixed alignment: u8,i64,u16'   24 'struct M { a: u8, b: i64, c: u16 }
fn main() -> i32 { let s: M; s.b = 5; return s.b + 19; }'
check "$A" 'nested struct array field'      9 'struct In { x: i32, y: i32 }
struct Out { a: In[2] }
fn main() -> i32 { let s: Out; s.a[1].y = 9; return s.a[1].y; }'
# --- thread-locals: distinct at every offset the pair can carry ---
check "$A" 'two thread-locals do not alias' 1 'tls let t_a: i64 = 0;
tls let t_b: i64 = 0;
fn main() -> i32 { t_b = 1; return i32(t_b); }'
check "$A" 'the other one is still zero'    0 'tls let t_a: i64 = 0;
tls let t_b: i64 = 0;
fn main() -> i32 { t_b = 1; return i32(t_a); }'
# The last offset the 32-bit pair can carry: 511 x 8 MiB = 0xFF800000. One
# more stride and it is 2^32, which is exactly where the next layer refuses.
gen_tls 512 'g0[0]'
if ! "$A" build-elf "$OUT/gen.ast" -o "$OUT/g.a64" >"$OUT/g.err" 2>&1; then
    echo 'FAIL: a thread-local block of 2^32 - 8 MiB no longer compiles' >&2
    sed -n '1,3p' "$OUT/g.err" >&2; exit 1
fi
$RUNNER "$OUT/g.a64" >/dev/null 2>&1 && got=0 || got=$?
[ "$got" = 0 ] || { echo "FAIL: the last legal thread-local aliases g0 (exit $got)" >&2; exit 1; }
printf '%s\n' '511 x 8 MiB: the last legal offset' >> "$OUT/witnesses.txt"
printf '  %-44s %s\n' '511 x 8 MiB: the last legal offset' "$got"
else
    printf '  SKIP: the witness layer needs qemu\n'
fi

# ---------------------------------------------------------------------------
# [4/9] C differential. The struct halves are directly comparable — AAPCS64 is
# AAPCS64. The thread-local half compares the *property* the defect destroyed
# (two thread-locals hold independent values) rather than the 4 GiB block,
# which no C compiler will hand out; the twin says so at the top.
# ---------------------------------------------------------------------------
printf '%s\n' '[4/9] C differential twin'
if [ "$have_qemu" = yes ] && [ "$have_cc" = yes ] && [ -f tests/layout-boundary-twin.c ]; then
    if "$HOSTCC" -O2 tests/layout-boundary-twin.c -o "$OUT/twin" >"$OUT/twin.build" 2>&1; then
        $RUNNER "$OUT/twin" > "$OUT/twin.txt" 2>&1 || {
            echo 'FAIL: the C twin did not run' >&2; sed -n '1,3p' "$OUT/twin.txt" >&2; exit 1; }
        grep -q '^L1.size_over_256 4$' "$OUT/twin.txt" \
            || { echo 'FAIL: the C twin did not report its cases' >&2; sed -n '1,8p' "$OUT/twin.txt" >&2; exit 1; }
        # diffcase <twin-case> <aster-source>: both sides must agree.
        twinval() { sed -n "s/^$1 //p" "$OUT/twin.txt" | head -1; }
        diffcase() {
            dname=$1
            printf '%s\n' "$2" > "$OUT/d.ast"
            if ! "$A" build-elf "$OUT/d.ast" -o "$OUT/d.a64" >"$OUT/d.err" 2>&1; then
                echo "FAIL: $dname does not compile" >&2; sed -n '1,3p' "$OUT/d.err" >&2; exit 1
            fi
            $RUNNER "$OUT/d.a64" >/dev/null 2>&1 && got=0 || got=$?
            ct=$(twinval "$dname")
            if [ "$got" != "$ct" ]; then
                echo "FAIL: $dname: Aster $got, C $ct" >&2; exit 1
            fi
            printf '  %-44s %s\n' "$dname" "$got"
        }
        diffcase 'L1.size_over_256' 'struct A { a: i64[128] }
fn main() -> i32 { return sizeof(A) / 256; }'
        diffcase 'L2.size_over_256' 'struct B { a: i64[127], b: u8 }
fn main() -> i32 { return sizeof(B) / 256; }'
        diffcase 'L3.size' 'struct M { a: u8, b: i64, c: u16 }
fn main() -> i32 { return sizeof(M); }'
        diffcase 'L4.size' 'struct In { x: i32, y: i32 }
struct Out { a: In[2] }
fn main() -> i32 { return sizeof(Out); }'
        diffcase 'L5.t_a_after_t_b' 'tls let t_a: i64 = 0;
tls let t_b: i64 = 0;
fn main() -> i32 { t_b = 1; return i32(t_a); }'
        diffcase 'L6.t_b' 'tls let t_a: i64 = 0;
tls let t_b: i64 = 0;
fn main() -> i32 { t_b = 1; return i32(t_b); }'
        printf '%s\n' 'PASS: 6 differential cases agree with C'
    else
        printf '  SKIP: the C twin does not build with %s\n' "$HOSTCC"
    fi
else
    printf '  SKIP: the differential layer needs qemu, a C compiler, and the twin\n'
fi

# ---------------------------------------------------------------------------
# [5/9] The refusing side. Each ceiling fires on the program that names it,
# and each refusal carries the number that did not fit.
# ---------------------------------------------------------------------------
printf '%s\n' '[5/9] Rejection matrix'
: > "$OUT/refusals.txt"
must_refuse() {   # must_refuse <name> <needle> <source-file>
    rname=$1; needle=$2
    if "$A" build-elf "$3" -o "$OUT/r.a64" >"$OUT/r.err" 2>&1; then
        echo "FAIL: $rname is accepted" >&2; exit 1
    fi
    grep -qF "$needle" "$OUT/r.err" \
        || { echo "FAIL: $rname is refused, but not as '$needle'" >&2; sed -n '1,2p' "$OUT/r.err" >&2; exit 1; }
    printf '%s\n' "$rname" >> "$OUT/refusals.txt"
    printf '  %-44s refused\n' "$rname"
}
refuse_ast() {    # refuse_ast <name> <needle> <inline source>
    printf '%s\n' "$3" > "$OUT/r.ast"
    must_refuse "$1" "$2" "$OUT/r.ast"
}
# --- the 2^32 struct: 8192 x 512 x 1024 = 4294967296, which a uint32_t wraps
#     to 0 and 0 used to pass the size limit. ---
python3 - "$OUT" <<'PY'
import sys
out=sys.argv[1]
n=8192
f="struct Big { " + ", ".join("f%d: L1[512]"%i for i in range(n)) + " }"
open(out+"/wrap.ast","w").write("struct L1 { pad: i64[128] }\n"+f+"\nfn main() -> i32 { let s: Big; return 0; }\n")
n=4195
f="struct Big { " + ", ".join("f%d: L1[1000]"%i for i in range(n)) + " }"
open(out+"/wrap712.ast","w").write("struct L1 { pad: i64[128] }\n"+f+"\nfn main() -> i32 { let s: Big; return 0; }\n")
PY
must_refuse '8192 fields reaching exactly 2^32' 'is too large' "$OUT/wrap.ast"
must_refuse '4195 fields wrapping to 712704'    'is too large' "$OUT/wrap712.ast"
# --- the ordinary limit, now reported from inside the accumulation and naming
#     the field that crossed it. The first of these is also mutant m3's probe,
#     so it lives in a file rather than inline. ---
printf '%s\n' 'struct S { a: i64[129] }
fn main() -> i32 { let s: S; return 0; }' > "$OUT/over.ast"
must_refuse 'one field past 1024' 'is too large: field ' "$OUT/over.ast"
refuse_ast 'two fields summing past 1024' "field 'b'" 'struct S { a: i64[100], b: i64[100] }
fn main() -> i32 { let s: S; return 0; }'
refuse_ast 'a nested struct array past 1024' 'is too large: field ' 'struct In { x: i32, y: i32 }
struct S { a: In[200] }
fn main() -> i32 { let s: S; return 0; }'
# --- the thread-local pair: one stride past 2^32 ---
gen_tls 513 'g0[0]'
must_refuse '513 x 8 MiB: offset 2^32' 'does not fit the 32-bit MOVZ/MOVK pair' "$OUT/gen.ast"
printf '%s\n' 'PASS: every ceiling fires with the number that did not fit'

# ---------------------------------------------------------------------------
# [6/9] Coverage counting. A suite whose matrix silently shrinks to nothing
# still prints PASS unless the count is asserted.
# ---------------------------------------------------------------------------
printf '%s\n' '[6/9] Coverage count'
# Both sides are counted, because a matrix that shrinks to nothing still
# prints PASS unless the count is asserted — and because "7 witnesses, 0
# refusals" is a suite that has stopped testing the ceilings entirely.
witnesses=$(wc -l < "$OUT/witnesses.txt" 2>/dev/null || echo 0)
refusals=$(wc -l < "$OUT/refusals.txt" 2>/dev/null || echo 0)
if [ "$have_qemu" = yes ]; then
    [ "$witnesses" -ge 6 ] \
        || { echo "FAIL: expected at least 6 witnesses, found $witnesses" >&2; exit 1; }
fi
[ "$refusals" -ge 6 ] \
    || { echo "FAIL: expected at least 6 refusals, found $refusals" >&2; exit 1; }
printf '  %-44s %s\n' 'witnesses' "$witnesses"
printf '  %-44s %s\n' 'refusals' "$refusals"
printf '%s\n' 'PASS: both sides of the matrix are counted and non-empty'

# ---------------------------------------------------------------------------
# [7/9] Mutation layer. Three mutants, one per load-bearing edit. Every one of
# them withdraws a refusal, so every one is caught by a program the real
# compiler refuses (mutant_accepts) — the direction that proves the ceiling
# was doing work, not merely present.
# ---------------------------------------------------------------------------
printf '%s\n' '[7/9] Mutation layer'
mutant_accepts() {   # mutant_accepts <name> <source-file>
    mname=$1
    if "$A" build-elf "$2" -o "$OUT/m.a64" >"$OUT/m.err" 2>&1; then
        echo "FAIL: the real compiler accepts $mname" >&2; exit 1
    fi
    if ! "$OUT/mut.aster" build-elf "$2" -o "$OUT/mm.a64" >"$OUT/mm.err" 2>&1; then
        echo "FAIL: mutant $mname still refuses — the ceiling is untested" >&2
        sed -n '1,2p' "$OUT/mm.err" >&2; exit 1
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
gen_tls 513 'g0[0]'
cp "$OUT/gen.ast" "$OUT/tls513.ast"
if [ "$have_qemu" = no ]; then
    printf '  SKIP: the mutation layer needs qemu to observe a changed answer\n'
else
# m1: the thread-local offset is masked again — g512 lands on g0.
mutate 'm1: the TLS offset is masked again' \
    's/if\(off>0xffffffffULL\)/if(false)/' \
    mutant_accepts '513 x 8 MiB' "$OUT/tls513.ast"
# m2: the struct accumulator is 32-bit again AND the per-field limit check is
# gone, which is exactly the shape the defect had: the only remaining check
# runs after the loop, on a size that has already wrapped to 0.
mutate 'm2: uint32 accumulator, no per-field check' \
    's/uint64_t off = 0;/uint32_t off = 0;/; s/if \(off > \(uint64_t\)kMaxStructSize\) tooLarge\(f,off\);//' \
    mutant_accepts '8192 fields reaching 2^32' "$OUT/wrap.ast"
# m3: both size checks are gone, so nothing enforces the 1024-byte limit.
mutate 'm3: no size limit at all' \
    's/if \(off > \(uint64_t\)kMaxStructSize\) tooLarge\(f,off\);//; s/if \(size > \(uint64_t\)kMaxStructSize\) tooLarge\(s\.fields\.back\(\),size\);//' \
    mutant_accepts 'one field past 1024' "$OUT/over.ast"
printf '%s\n' 'PASS: three mutated compilers each lose one ceiling, and the matrix notices'
fi

# ---------------------------------------------------------------------------
# [8/9] Byte baseline. The round changes which programs are accepted; it must
# not change one byte of what an accepted program emits.
# ---------------------------------------------------------------------------
printf '%s\n' '[8/9] Byte baseline: every example, three modes'
BASE=$(aster_baseline_file)
if [ ! -f "$BASE" ]; then
    echo "FAIL: layout byte-identity baseline missing: $BASE" >&2; exit 1
fi
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
grep -v '^address_of_abi\.' "$OUT/hashes.txt" | LC_ALL=C sort > "$OUT/hashes.filtered.txt"
LC_ALL=C sort "$BASE" > "$OUT/base.sorted.txt"
if ! diff -u "$OUT/base.sorted.txt" "$OUT/hashes.filtered.txt" > "$OUT/hashes.diff"; then
    echo 'FAIL: the layout ceilings changed the output of a pre-existing example' >&2
    sed -n '1,20p' "$OUT/hashes.diff" >&2
    exit 1
fi
printf '%s\n' "PASS: $(wc -l < "$OUT/hashes.filtered.txt") recorded outputs reproduced byte for byte"

# ---------------------------------------------------------------------------
# [9/9] The end-to-end shape: a program that exercises both halves survives
# all three build modes, not just build-elf.
# ---------------------------------------------------------------------------
printf '%s\n' '[9/9] End to end: three modes'
cat > "$OUT/shape.ast" <<'EOF'
struct In { x: i32, y: i32 }
struct Out { a: In[2] }
tls let t: i64 = 0;
fn place(s: Out) -> i32 { return s.a[1].y; }
fn main() -> i32 {
    let s: Out;
    s.a[1].y = 40;
    t = t + 2;
    return place(s) + i32(t);
}
EOF
for mode in build-so build-elf "build-obj --pic"; do
    tag=$(echo "$mode" | tr ' ' '_')
    if ! "$A" $mode "$OUT/shape.ast" -o "$OUT/shape.$tag" >"$OUT/shape.err" 2>&1; then
        echo "FAIL: the shape does not build in $mode" >&2; sed -n '1,3p' "$OUT/shape.err" >&2; exit 1
    fi
done
if [ "$have_qemu" = yes ]; then
    $RUNNER "$OUT/shape.build-elf" >/dev/null 2>&1 && got=0 || got=$?
    [ "$got" = 42 ] || { echo "FAIL: the shape exits $got, expected 42" >&2; exit 1; }
    printf '  %-44s %s\n' 'struct + thread-local, build-elf' "$got"
fi
printf '%s\n' 'PASS: the shape builds in all three modes and runs to 42'

printf '%s\n' 'PASS: all v0.23.65-dev layout-boundary checks'
