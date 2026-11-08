#!/bin/sh
# tests/union-checks.sh — `union` as a byte-for-byte C ABI aggregate.
#
# AUDIT-v0.23.61-dev.md's third part listed five language gaps; v0.23.67-dev
# through v0.23.70-dev close all five. This round closes the last one, `union`,
# with the audit's own prescription: "reuse the struct layout (ObjectLayout),
# only overlap the offsets". A union therefore stays a Ty::Struct in the
# compiler's type lattice and shares g_structs / g_structIndex (and so shares
# the struct tag namespace, as C does). The only differences are:
#
#   * every member sits at offset 0, the alignment is the widest member's and
#     the size is the widest member's size rounded up to that alignment;
#   * a literal takes exactly one value, initializes the FIRST member and
#     zeroes every other byte — C's `union U u = {5};`;
#   * reading a member other than the last one written is allowed (type
#     punning / byte reinterpretation), with no active-member tracking;
#   * -g emits a real DW_TAG_union_type (0x17) instead of a structure_type.
#
# Everything else — field access, sizeof, constant folding, AAPCS64 aggregate
# classification for parameters and returns — is inherited from struct unchanged.
# The oracle is gcc: an Aster union must be ABI-identical to the C header's, so
# a C main can link an Aster union function with no shim at all.
#
# Layers (the project 9-layer shape): strict build; source guards pinning every
# piece of the machinery plus the generated reserved-word list; a C-ABI
# independent reader; a gcc differential over six cases; a refusal matrix with
# exact messages; the shipped example against its C twin; coverage counting;
# six mutations; and the byte baseline for the union example.

set -eu
cd "$(dirname "$0")/.."
. tests/lib/baseline.sh
. tests/lib/verdict.sh
CXX=${CXX:-c++}
RUNNER=${RUNNER:-tests/run-aarch64.sh}
OUT=${OUT:-tmp-union-checks}
W="$OUT/work"
mkdir -p "$W"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM
run(){ sh "$RUNNER" "$@"; }

# The differential, the independent reader and the behavioural witnesses need a
# cross gcc and a way to run AArch64; without them those layers say SKIP with a
# reason and the rest of the suite still runs.
HOSTCC=${HOSTCC:-}
if [ -z "$HOSTCC" ] && command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
    HOSTCC=aarch64-linux-gnu-gcc
fi
if [ -z "$HOSTCC" ] && command -v cc >/dev/null 2>&1; then HOSTCC=cc; fi
have_qemu=yes
command -v qemu-aarch64 >/dev/null 2>&1 || have_qemu=no
case $(uname -m) in aarch64|arm64) have_qemu=yes ;; esac
if [ "$have_qemu" = yes ] && [ -n "$HOSTCC" ]; then
    printf 'int main(void){return 0;}\n' > "$W/probe.c"
    if ! "$HOSTCC" -O2 -fwrapv -static "$W/probe.c" -o "$W/probe" >/dev/null 2>&1; then
        have_qemu=no
    elif ! run "$W/probe" >/dev/null 2>&1; then
        have_qemu=no
    fi
fi

# ---------------------------------------------------------------------------
# [1/9] Strictly build the Aster compiler
printf '%s\n' '[1/9] Strictly build Aster compiler'
$CXX -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp -o "$OUT/aster"
A=$OUT/aster

# ---------------------------------------------------------------------------
# [2/9] Source guards. Each piece of the feature is pinned by its text, so a
# round that quietly drops one of them fails here rather than in the field.
printf '%s\n' '[2/9] Source guards: the union machinery'
guard_count=0
guard(){ # $1 = literal source text, $2 = what it is
    grep -qF "$1" src/aster.cpp \
        || { printf 'FAIL: %s is gone\n' "$2" >&2; exit 1; }
    guard_count=$((guard_count + 1))
}
grep -qF '#define ASTER_VERSION_STRING "0.23.74-dev"' src/aster.cpp \
    || { echo 'FAIL: the version constant is not 0.23.74-dev' >&2; exit 1; }
guard 'bool isUnion = false;' 'the StructDef union bit'
guard 'static const char* structKindName(const StructDef& s){ return s.isUnion ? "union" : "struct"; }' 'the kind-name helper'
guard 'void structDeclaration(bool isUnion){' 'the shared aggregate parser'
guard 'StructDef s;s.name=id.s;s.isUnion=isUnion;' 'the declaration bit is set'
guard 'void structDeclaration(){ structDeclaration(false); }' 'the struct entry point is unchanged'
guard 'if(eat(TK::Union)){structDeclaration(true);continue;}' 'the union top-level dispatch'
guard 'else if(x=="union")k=TK::Union;' 'the union reserved word'
guard 'Union };' 'Union is the last token kind'
guard 'if (s.isUnion) {' 'the union layout branch'
guard 'f.offset = 0;' 'every union member overlaps at offset 0'
guard 'tooLarge(*widest,size);' 'the size overflow names the widest member'
guard 'return f.len>0||(tyIsStruct(f.ty)&&structHasArrayField(f.ty.sid));' 'the union array-field branch'
guard 'union literal for' 'the one-value literal refusal'
[ "$(grep -c 'const size_t want=isU?1u:sd.fields.size();' src/aster.cpp)" = 2 ] \
    || { echo 'FAIL: both literal passes must fork their value count' >&2; exit 1; }
guard_count=$((guard_count + 1))
guard 'std::vector<uint8_t> raw(sd.size,0);' 'the constant image is zero-filled'
guard 'storeAtT(31,17,b,Ty::I64)' 'the runtime target is zeroed with XZR'
guard 'const size_t n=sd.isUnion?1u:sd.fields.size();' 'the runtime store writes exactly one member'
guard 'kAbbrUnion=15' 'the DW_TAG_union_type abbreviation code'
guard '{kAbbrUnion,0x17,1,{{kName,fStr},{kByteSize,fData2}}},' 'the unconditional abbrev table entry'
guard 'sd.isUnion ? kAbbrUnion : kAbbrStruct' 'typeRef selects the union tag'
# The decoder must know the tag, and the generated tables must carry the word.
grep -qF '0x17: "UNION_TYPE"' tests/debuginfo-decode.py \
    || { echo 'FAIL: debuginfo-decode.py cannot name a union' >&2; exit 1; }
grep -qF '{ "union", TK_Union }' tests/lexer_names.h \
    || { echo 'FAIL: the generated C twin does not carry TK_Union' >&2; exit 1; }
grep -qF 'let K_Union: i32 = 82;' bootstrap/aster.ast \
    || { echo 'FAIL: the bootstrap lexer does not carry K_Union' >&2; exit 1; }
guard_count=$((guard_count + 3))
# The reserved-word list is generated, not hand-written: 32 words now that
# `union` joined it, and `tls` is still a context keyword.
python3 - <<'PY' || exit 1
import re
src = open('bootstrap/gen_lexer_names.py').read()
m = re.search(r'KEYWORDS = \[(.*?)\]', src, re.S)
entries = re.findall(r'\("([^"]+)",', m.group(1))
assert len(entries) == 32, ('reserved-word count moved', len(entries), entries)
assert 'union' in entries, 'union is not a reserved word'
assert 'tls' not in entries, 'tls became a reserved word — it must stay a context keyword'
print('PASS: 32 reserved words, union among them, tls still a context keyword')
PY
guard_count=$((guard_count + 1))
printf '  %-30s %s\n' "guards passed" "$guard_count"

# ---------------------------------------------------------------------------
# [3/9] An independent reader: a C program links Aster's union functions and
# must agree with a pure-C twin. pack returns a union in one 8-byte register
# with its upper four bytes zeroed; widen takes one in the same way. No shim.
printf '%s\n' '[3/9] Independent reader: C links Aster union fn, must match C linking C'
if [ "$have_qemu" != yes ]; then
    echo 'SKIP: no cross gcc or no qemu — the C-ABI link did not run'
else
cat > "$W/aster_unionfn.ast" <<'AST'
union U { w: i32, q: i64, lo: u8, c: char }
fn pack(v: i32) -> U { return U { v }; }
fn widen(u: U) -> i64 { return u.q; }
AST
"$A" build-obj --pic "$W/aster_unionfn.ast" -o "$W/aster_unionfn.o" >"$W/aster_unionfn.log" 2>&1 \
    || { echo 'FAIL: Aster union functions do not build to an object:' >&2; cat "$W/aster_unionfn.log" >&2; exit 1; }
cat > "$W/c_caller.c" <<'C'
#include <stdint.h>
union U { int32_t w; int64_t q; uint8_t lo; unsigned char c; };
extern union U pack(int32_t);
extern int64_t widen(union U);
int main(void){
    union U u = pack(5);
    if (u.q != 5) return 1;
    if (widen(u) != 5) return 2;
    return 0;
}
C
"$HOSTCC" -c "$W/c_caller.c" -o "$W/c_caller.o" >"$W/c_caller.clog" 2>&1 \
    || { echo 'FAIL: C caller does not compile:' >&2; cat "$W/c_caller.clog" >&2; exit 1; }
"$HOSTCC" "$W/aster_unionfn.o" "$W/c_caller.o" -o "$W/hybrid" -static >"$W/hybrid.log" 2>&1 \
    || { echo 'FAIL: C caller cannot link Aster union function (ABI mismatch):' >&2; cat "$W/hybrid.log" >&2; exit 1; }
run "$W/hybrid" >/dev/null 2>&1 && hy=0 || hy=$?
[ "$hy" -gt 127 ] && hy=$((hy - 256))
[ "$hy" = 0 ] || { echo "FAIL: hybrid (C main -> Aster union fn) exited $hy, expected 0" >&2; exit 1; }
printf 'PASS: %-22s C links Aster union fn, exit %s\n' 'c_calls_aster_union' "$hy"
# The mirror: a pure-C program, same behaviour, must also exit 0.
cat > "$W/c_only.c" <<'C'
#include <stdint.h>
union U { int32_t w; int64_t q; uint8_t lo; unsigned char c; };
static union U pack(int32_t v){ union U u = { .w = v }; return u; }
static int64_t widen(union U u){ return u.q; }
int main(void){
    union U u = pack(5);
    if (u.q != 5) return 1;
    if (widen(u) != 5) return 2;
    return 0;
}
C
"$HOSTCC" -O2 -fwrapv -static "$W/c_only.c" -o "$W/c_only" >/dev/null 2>&1 \
    || { echo 'FAIL: C-only oracle does not compile' >&2; exit 1; }
run "$W/c_only" >/dev/null 2>&1 && cy=0 || cy=$?
[ "$cy" -gt 127 ] && cy=$((cy - 256))
[ "$cy" = 0 ] || { echo "FAIL: C-only oracle exited $cy, expected 0" >&2; exit 1; }
printf 'PASS: %-22s C-only twin, exit %s\n' 'c_only_union' "$cy"
fi

# ---------------------------------------------------------------------------
# [4/9] The gcc differential. An Aster union is the model of C's union, so
# every case has both sources and the two must agree on the exit status under
# qemu — never a hand-computed expectation.
printf '%s\n' '[4/9] gcc differential: Aster and C must agree on union behaviour'
diff_n=0
if [ "$have_qemu" != yes ]; then
    echo 'SKIP: no cross gcc or no qemu — the gcc differential did not run'
else
cat > "$W/union_zerofill.ast" <<'AST'
union U { w: i32, q: i64 }
fn main() -> i32 {
    let u: U = U { 5 };
    if (u.q != 5) { return 1; }
    return 0;
}
AST
cat > "$W/union_zerofill.c" <<'C'
#include <stdint.h>
union U { int32_t w; int64_t q; };
int main(void){
    union U u = { 5 };
    if (u.q != 5) return 1;
    return 0;
}
C
cat > "$W/union_overlap.ast" <<'AST'
union U { w: i32, q: i64, lo: u8, c: char }
fn main() -> i32 {
    let u: U = U { 0x11223344 };
    if (i32(u.lo) != 0x44) { return 1; }
    if (i32(u.c) != 0x44) { return 2; }
    return 0;
}
AST
cat > "$W/union_overlap.c" <<'C'
#include <stdint.h>
union U { int32_t w; int64_t q; uint8_t lo; unsigned char c; };
int main(void){
    union U u = { 0x11223344 };
    if ((int32_t)u.lo != 0x44) return 1;
    if ((int32_t)u.c != 0x44) return 2;
    return 0;
}
C
cat > "$W/union_punning.ast" <<'AST'
union U { w: i32, q: i64, lo: u8, c: char }
fn main() -> i32 {
    let u: U = U { 0 };
    u.q = 0x1122334455667788;
    if (u.w != 0x55667788) { return 1; }
    if (i32(u.lo) != 0x88) { return 2; }
    return 0;
}
AST
cat > "$W/union_punning.c" <<'C'
#include <stdint.h>
union U { int32_t w; int64_t q; uint8_t lo; unsigned char c; };
int main(void){
    union U u = { 0 };
    u.q = 0x1122334455667788LL;
    if (u.w != 0x55667788) return 1;
    if ((int32_t)u.lo != 0x88) return 2;
    return 0;
}
C
cat > "$W/union_size_align.ast" <<'AST'
union U { w: i32, q: i64, lo: u8, c: char }
struct Box { tag: i32, u: U }
fn main() -> i32 {
    if (sizeof(U) != 8) { return 1; }
    if (sizeof(Box) != 16) { return 2; }
    return 0;
}
AST
cat > "$W/union_size_align.c" <<'C'
#include <stdint.h>
union U { int32_t w; int64_t q; uint8_t lo; unsigned char c; };
struct Box { int32_t tag; union U u; };
int main(void){
    if (sizeof(union U) != 8) return 1;
    if (sizeof(struct Box) != 16) return 2;
    return 0;
}
C
cat > "$W/union_struct_field.ast" <<'AST'
union U { w: i32, q: i64 }
struct Box { tag: i32, u: U }
fn main() -> i32 {
    let b: Box = Box { 7, U { 9 } };
    if (b.tag != 7) { return 1; }
    if (b.u.w != 9) { return 2; }
    return 0;
}
AST
cat > "$W/union_struct_field.c" <<'C'
#include <stdint.h>
union U { int32_t w; int64_t q; };
struct Box { int32_t tag; union U u; };
int main(void){
    struct Box b = { 7, { 9 } };
    if (b.tag != 7) return 1;
    if (b.u.w != 9) return 2;
    return 0;
}
C
cat > "$W/union_param_ret.ast" <<'AST'
union U { w: i32, q: i64 }
fn make(v: i32) -> U { return U { v }; }
fn id(u: U) -> U { return u; }
fn main() -> i32 {
    let a: U = make(11);
    if (a.w != 11) { return 1; }
    let b: U = id(U { 5 });
    if (b.w != 5) { return 2; }
    return 0;
}
AST
cat > "$W/union_param_ret.c" <<'C'
#include <stdint.h>
union U { int32_t w; int64_t q; };
static union U make(int32_t v){ union U u = { .w = v }; return u; }
static union U id(union U u){ return u; }
int main(void){
    union U a = make(11);
    if (a.w != 11) return 1;
    union U b = id((union U){ 5 });
    if (b.w != 5) return 2;
    return 0;
}
C
DIFF_CASES='union_zerofill union_overlap union_punning union_size_align union_struct_field union_param_ret'
failed=0
for n in $DIFF_CASES; do
    if ! "$A" build-elf "$W/$n.ast" -o "$W/$n.a64" >"$W/$n.ab.log" 2>&1; then
        echo "FAIL: $n — Aster build failed:" >&2; cat "$W/$n.ab.log" >&2; failed=1; continue
    fi
    if ! "$HOSTCC" -O2 -fwrapv -static "$W/$n.c" -o "$W/$n.c64" >"$W/$n.cb.log" 2>&1; then
        echo "FAIL: $n — C oracle build failed:" >&2; cat "$W/$n.cb.log" >&2; failed=1; continue
    fi
    run "$W/$n.a64" >/dev/null 2>&1 && a=0 || a=$?
    run "$W/$n.c64" >/dev/null 2>&1 && c=0 || c=$?
    [ "$a" -gt 127 ] && a=$((a - 256))
    [ "$c" -gt 127 ] && c=$((c - 256))
    if [ "$a" != "$c" ]; then
        echo "FAIL: $n — Aster exit $a, C oracle exit $c" >&2; failed=1; continue
    fi
    diff_n=$((diff_n + 1))
    printf 'PASS: %-22s exit %s (matches C)\n' "$n" "$a"
done
[ "$failed" = 0 ] || exit 1
fi

# ---------------------------------------------------------------------------
# [5/9] The refusal matrix. These are Aster's own rules (C would accept some of
# them), each pinned by the exact diagnostic that explains it.
printf '%s\n' '[5/9] Refusal matrix: a union is a strict aggregate'
reject(){ # $1 = label, $2 = source, $3 = reason
    printf '%s\n' "$2" > "$W/rej.ast"
    if "$A" build-elf "$W/rej.ast" -o "$W/rej" >"$W/rej.log" 2>&1; then
        echo "FAIL: $1 — accepted, expected: $3" >&2; return 1
    fi
    if ! grep -qF "$3" "$W/rej.log"; then
        echo "FAIL: $1 — refused, but not with \"$3\":" >&2; head -2 "$W/rej.log" >&2; return 1
    fi
    printf 'PASS: %-30s %s\n' "$1" "$3"
    return 0
}
failed=0
rej_n=0
r(){ reject "$@" && rej_n=$((rej_n + 1)) || failed=1; }
r 'union: zero values' \
"union U { w: i32, q: i64 }
fn main() -> i32 { let u: U = U { }; return 0; }" \
"union literal for 'U' has 0 values but a union takes exactly 1"
r 'union: four values' \
"union U { w: i32, q: i64, lo: u8, c: char }
fn main() -> i32 { let u: U = U { 1, 2, 3, 4 }; return 0; }" \
"union literal for 'U' has 4 values but a union takes exactly 1"
r 'union: field type mismatch' \
"union U { w: i32, q: i64 }
fn main() -> i32 { let u: U = U { true }; return 0; }" \
"type mismatch in union literal for 'U' field 'w': expected i32, got bool"
r 'union: empty declaration' \
"union U { }
fn main() -> i32 { return 0; }" \
'union U must declare at least one field'
r 'union: duplicate field' \
"union U { w: i32, w: i32 }
fn main() -> i32 { return 0; }" \
'duplicate field in union U: w'
r 'union: self containment' \
"union U { w: i32, u: U }
fn main() -> i32 { return 0; }" \
'union U cannot contain itself'
r 'union: duplicate declaration' \
"union U { w: i32 }
union U { q: i64 }
fn main() -> i32 { return 0; }" \
'duplicate union declaration: U'
r 'union: conflicts with global' \
"let U: i32 = 0;
union U { w: i32 }
fn main() -> i32 { return 0; }" \
'union name conflicts with a global variable: U'
r 'union: conflicts with function' \
"fn U() -> i32 { return 0; }
union U { w: i32 }
fn main() -> i32 { return 0; }" \
'union name conflicts with a function: U'
r 'union: first field is an array' \
"union U { a: i32[4], w: i32 }
fn main() -> i32 { let u: U = U { 1 }; return 0; }" \
"union 'U' contains an array field and cannot be initialized by a literal"
r 'union: too large' \
"union U { a: i32[300], w: i32 }
fn main() -> i32 { return 0; }" \
"union U is too large: field 'a' reaches offset 1200"
r 'union: non-literal global init' \
"union U { w: i32, q: i64 }
let g: U = 5;
fn main() -> i32 { return 0; }" \
'global struct initializer must be a struct literal: g'
r 'union: literal in an i32 slot' \
"union U { w: i32, q: i64 }
fn main() -> i32 { let x: i32 = U { 5 }; return 0; }" \
"type mismatch initializing 'x': expected i32, got U"
[ "$failed" = 0 ] || exit 1
printf '  %-30s %s\n' "refusals held" "$rej_n"
# The positive counterpart: an array in a NON-first member must not block a
# literal, because a union literal only writes the first member.
printf '%s\n' 'union U { w: i32, a: i32[4] }
fn main() -> i32 { let u: U = U { 5 }; return 0; }' > "$W/nonfirst.ast"
"$A" build-elf "$W/nonfirst.ast" -o "$W/nonfirst" >"$W/nonfirst.log" 2>&1 \
    || { echo 'FAIL: a non-first array member wrongly blocks a union literal' >&2; cat "$W/nonfirst.log" >&2; exit 1; }
printf 'PASS: %-30s %s\n' 'non-first array allowed' 'literal accepted'

# ---------------------------------------------------------------------------
# [6/9] The shipped example against its C twin.
printf '%s\n' '[6/9] The shipped example against its C twin'
if [ "$have_qemu" != yes ]; then
    echo 'SKIP: no cross gcc or no qemu — the example witness did not run'
else
ex=union_layout; twin=tests/union-layout-twin.c
if ! "$A" build-elf "examples/$ex.ast" -o "$W/$ex" >"$W/$ex.log" 2>&1; then
    echo "FAIL: examples/$ex.ast no longer builds:" >&2; cat "$W/$ex.log" >&2; exit 1
fi
if ! "$HOSTCC" -O2 -fwrapv -static "$twin" -o "$W/$ex.c64" >"$W/$ex.c.log" 2>&1; then
    echo "FAIL: $twin no longer builds:" >&2; cat "$W/$ex.c.log" >&2; exit 1
fi
run "$W/$ex" >/dev/null 2>&1 && ae=0 || ae=$?
run "$W/$ex.c64" >/dev/null 2>&1 && ce=0 || ce=$?
[ "$ae" -gt 127 ] && ae=$((ae - 256))
[ "$ce" -gt 127 ] && ce=$((ce - 256))
if [ "$ae" != "$ce" ]; then
    echo "FAIL: examples/$ex.ast exit $ae, $twin exit $ce" >&2; exit 1
fi
printf 'PASS: %-22s exit %s (matches C)\n' "$ex" "$ae"
fi

# ---------------------------------------------------------------------------
# [7/9] Coverage counting: the layers have to be carrying their weight.
printf '%s\n' '[7/9] Coverage: the layers are not vacuous'
[ "$guard_count" -ge 15 ] || { echo "FAIL: only $guard_count source guards, expected at least 15" >&2; exit 1; }
[ "$rej_n" -ge 10 ] || { echo "FAIL: only $rej_n refusals held, expected at least 10" >&2; exit 1; }
[ "$diff_n" -ge 6 ] || { echo "FAIL: only $diff_n differential cases, expected at least 6" >&2; exit 1; }
printf '  %-30s %s\n' "source guards" "$guard_count"
printf '  %-30s %s\n' "refusals" "$rej_n"
printf '  %-30s %s\n' "gcc differential cases" "$diff_n"

# ---------------------------------------------------------------------------
# [8/9] Mutations. Each piece has to be load-bearing. None of these touches a
# `return` statement, so every mutant still compiles under -w.
printf '%s\n' '[8/9] The suite can still fail (six mutations)'
mutate(){ # $1 = label, $2 = sed script
    sed "$2" src/aster.cpp > "$OUT/$1.cpp"
    if cmp -s src/aster.cpp "$OUT/$1.cpp"; then
        echo "FAIL: mutation $1 did not apply — blind" >&2; exit 1
    fi
    $CXX -std=c++17 -O2 -w "$OUT/$1.cpp" -o "$OUT/$1" 2>/dev/null \
        || { echo "FAIL: mutation $1 no longer compiles" >&2; exit 1; }
}
# (a) The declaration bit decides whether an aggregate is a union. With it
# forced off, `U { 5 }` is checked as a struct and refused for having one value
# instead of two.
mutate m1 's/s.isUnion=isUnion;/s.isUnion=false;/'
printf '%s\n' 'union U { w: i32, q: i64 } fn main() -> i32 { let u: U = U { 5 }; return 0; }' > "$W/m1.ast"
"$A" build-elf "$W/m1.ast" -o "$W/m1.orig" >/dev/null 2>&1 \
    || { echo 'FAIL: m1 witness does not build with the shipping compiler' >&2; exit 1; }
if "$OUT/m1" build-elf "$W/m1.ast" -o "$W/m1" >/dev/null 2>&1; then
    echo 'FAIL: mutation (a) went unnoticed — the declaration bit is not load-bearing' >&2; exit 1
fi
printf '  %-40s %s\n' 'a) union bit lost -> literal refused' 'noticed'
# (b) The one-value fork in checkStructLit. Without it a four-value union
# literal is accepted (one value per field), which the original refuses.
mutate m2 '/Ty checkStructLit/,/return Ty::ofStruct/ s/const size_t want=isU?1u:sd.fields.size();/const size_t want=sd.fields.size();/'
printf '%s\n' 'union U { w: i32, q: i64 } fn main() -> i32 { let u: U = U { 1, 2 }; return 0; }' > "$W/m2.ast"
if "$A" build-elf "$W/m2.ast" -o "$W/m2.orig" >/dev/null 2>&1; then
    echo 'FAIL: m2 witness is accepted by the shipping compiler' >&2; exit 1
fi
if ! "$OUT/m2" build-elf "$W/m2.ast" -o "$W/m2" >/dev/null 2>&1; then
    echo 'FAIL: mutation (b) went unnoticed — the value-count fork is not load-bearing' >&2; exit 1
fi
printf '  %-40s %s\n' 'b) value-count fork lost' 'noticed'
# (c) XZR (reg 31) is what zeroes the union target. X0 is not zero, so the
# emitted bytes must differ.
mutate m3 's/storeAtT(31,17,b,Ty::I64)/storeAtT(0,17,b,Ty::I64)/'
# (d) The union branch of structHasArrayField only looks at the first member.
# With it disabled, an array in a later member wrongly blocks the literal.
mutate m4 '/static bool structHasArrayField/,/^}/ s/    if(s.isUnion){/    if(false){/'
printf '%s\n' 'union U { w: i32, a: i32[4] } fn main() -> i32 { let u: U = U { 5 }; return 0; }' > "$W/m4.ast"
"$A" build-elf "$W/m4.ast" -o "$W/m4.orig" >/dev/null 2>&1 \
    || { echo 'FAIL: m4 witness does not build with the shipping compiler' >&2; exit 1; }
if "$OUT/m4" build-elf "$W/m4.ast" -o "$W/m4" >/dev/null 2>&1; then
    echo 'FAIL: mutation (d) went unnoticed — the union array branch is not load-bearing' >&2; exit 1
fi
printf '  %-40s %s\n' 'd) first-member-only rule lost' 'noticed'
# (e) The union layout branch. Disabled, a union is laid out as a struct (sum
# of members), so the example compiles to different bytes.
mutate m5 's/    if (s.isUnion) {/    if (false) {/'
# (f) The DWARF tag selection. Forced back to kAbbrStruct, the -g product must
# differ and the decoder must no longer see a UNION_TYPE DIE.
mutate m6 's/sd.isUnion ? kAbbrUnion : kAbbrStruct/kAbbrStruct/'
"$A" build-elf examples/union_layout.ast -o "$W/orig_elf" >/dev/null 2>&1 \
    || { echo 'FAIL: cannot build the union example with the shipping compiler' >&2; exit 1; }
o_h=$(sha256sum "$W/orig_elf" | cut -d' ' -f1)
for n in 3 5; do
    "$OUT/m$n" build-elf examples/union_layout.ast -o "$W/mut_$n" >/dev/null 2>&1 \
        || { echo "FAIL: mutation m$n no longer builds the union example" >&2; exit 1; }
    m_h=$(sha256sum "$W/mut_$n" | cut -d' ' -f1)
    [ "$o_h" != "$m_h" ] \
        || { echo "FAIL: mutation m$n went unnoticed — identical bytes" >&2; exit 1; }
done
printf '  %-40s %s\n' 'c) XZR zero-fill lost' 'noticed'
printf '  %-40s %s\n' 'e) union layout branch lost' 'noticed'
"$A" build-elf -g examples/union_layout.ast -o "$W/orig_g" >/dev/null 2>&1 \
    || { echo 'FAIL: cannot build the union example with -g' >&2; exit 1; }
"$OUT/m6" build-elf -g examples/union_layout.ast -o "$W/mut_6" >/dev/null 2>&1 \
    || { echo 'FAIL: mutation m6 no longer builds the union example with -g' >&2; exit 1; }
g_h=$(sha256sum "$W/orig_g" | cut -d' ' -f1)
m_h=$(sha256sum "$W/mut_6" | cut -d' ' -f1)
[ "$g_h" != "$m_h" ] \
    || { echo 'FAIL: mutation (f) went unnoticed — identical -g bytes' >&2; exit 1; }
if python3 tests/debuginfo-decode.py "$W/orig_g" --tree 2>/dev/null | grep -q 'UNION_TYPE'; then :; else
    echo 'FAIL: the shipping -g product has no UNION_TYPE DIE' >&2; exit 1
fi
if python3 tests/debuginfo-decode.py "$W/mut_6" --tree 2>/dev/null | grep -q 'UNION_TYPE'; then
    echo 'FAIL: mutation (f) still emits a UNION_TYPE DIE' >&2; exit 1
fi
printf '  %-40s %s\n' 'f) DW_TAG_union_type lost' 'noticed'
mut_n=6
printf '  %-30s %s\n' "mutations noticed" "$mut_n"
[ "$mut_n" -ge 6 ] || exit 1

# ---------------------------------------------------------------------------
# [9/9] The byte baseline for the union example. The full example baseline is
# owned by alias-const-checks.sh; here we pin the three rows that this round
# adds and require them to reproduce. The output basename is part of the
# build-so bytes (.dynstr / VERDEF BASE), so it must be exactly <key>.
printf '%s\n' '[9/9] Byte baseline: the union example reproduces'
BASE=$(aster_baseline_file)
union_rows=$(grep '^union_layout\.' "$BASE" | LC_ALL=C sort)
[ -n "$union_rows" ] || { echo 'FAIL: no union_layout rows in the frozen baseline' >&2; exit 1; }
printf '%s\n' "$union_rows" > "$W/union.rows.txt"
while IFS= read -r spec; do
    [ -z "$spec" ] && continue
    key=${spec% *}; val=${spec#* }
    mode=${key#*.}; base=${key%.*}
    case "$mode" in
        build-so) m='build-so' ;;
        build-elf) m='build-elf' ;;
        build-obj_--pic) m='build-obj --pic' ;;
    esac
    if "$A" $m "examples/$base.ast" -o "$W/$key" >/dev/null 2>&1; then
        got=$(sha256sum "$W/$key" | cut -d' ' -f1)
    else
        got=FAILED
    fi
    if [ "$got" != "$val" ]; then
        echo "FAIL: $key baseline moved: expected $val, got $got" >&2; exit 1
    fi
done < "$W/union.rows.txt"
printf '  %-30s %s\n' "union_layout rows reproduced" "$(echo "$union_rows" | wc -l)"
printf '%s\n' 'PASS: all union checks'
