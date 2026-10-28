#!/bin/sh
# v0.23.5-dev structural + behavioral checks for structs (P3.3).
#
# A struct is a value with no register form: it lives in memory, is read and
# written field by field, and is moved as a whole. Everything about it is
# therefore either a layout question (where does field `b` sit?) or an ABI
# question (how does it cross a call?). Both are settled by AAPCS64, and both
# were checked against aarch64-linux-gnu-gcc rather than from memory — see
# tests/e2e-c-struct.sh for the executable half.
#
# Layers: strict compiler build, source guards, a rejection matrix, the proof
# that every pre-existing example still compiles byte for byte, a byte-level
# layout comparison against the host C compiler, and qemu runs of the three
# AAPCS64 size classes (<=8 bytes: one register; 9..16: a register pair;
# >16: a caller-made copy reached through X8) in both directions.
set -eu
cd "$(dirname "$0")/.."
OUT=${OUT:-tmp-struct-checks}
mkdir -p "$OUT"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM

run_status(){ st=0; "$PWD/tests/run-aarch64.sh" "$1" >/dev/null 2>&1 || st=$?; echo "$st"; }

printf '%s\n' '[1/8] Strictly build Aster compiler'
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o "$OUT/aster"

printf '%s\n' '[2/8] Source guard: the type lattice, the layout pass and the ABI pieces'
# A regression that drops any one of these changes behaviour before a test that
# exercises it gets a chance to fail, so the guards come first.
# Pinned as the head and the tail rather than the whole member list:
# v0.23.48-dev inserted U64 after I64, and a kind added by a future round must
# not move this guard — the lattice itself is what this suite owns (the same
# discipline pins FieldCall in callback-table-checks.sh and SizeOf/Len in
# sizeof-len-checks.sh).
grep -qF 'enum Kind { I32,' src/aster.cpp \
    && grep -qF 'Struct };' src/aster.cpp \
    || { echo 'FAIL: Ty::Kind no longer carries Struct' >&2; exit 1; }
grep -qF 'static void layoutStruct(StructDef& s) {' src/aster.cpp \
    || { echo 'FAIL: layoutStruct missing' >&2; exit 1; }
grep -qF 'static uint32_t aapcs64Slots(Ty t){ return (tyIsStruct(t)&&tySize(t)>8u)?2u:1u; }' src/aster.cpp \
    || { echo 'FAIL: AAPCS64 register classification missing' >&2; exit 1; }
grep -qF 'static bool structInMemory(Ty t){ return tyIsStruct(t)&&tySize(t)>16u; }' src/aster.cpp \
    || { echo 'FAIL: the >16-byte "copy to memory" classification is missing' >&2; exit 1; }
grep -qF 'static ArgLayout layoutArgs(const std::vector<Ty>& ts,size_t n){' src/aster.cpp \
    || { echo 'FAIL: one shared argument layout is missing (caller and callee must agree)' >&2; exit 1; }
# Stack arguments start at SP+0 as the callee sees it; the copies and the sret
# buffer have no fixed home, so they must sit above them.
grep -qF 'const uint32_t stackBase=0,copyBase=stackBytes,sretBase=stackBytes+copyArea;' src/aster.cpp \
    || { echo 'FAIL: outgoing area no longer puts stack arguments at SP+0' >&2; exit 1; }
grep -qF 'void emitStructAddr(const Expr& e){' src/aster.cpp \
    || { echo 'FAIL: emitStructAddr missing' >&2; exit 1; }
grep -qF 'void emitStructCopy(int dst,int src,uint32_t size){' src/aster.cpp \
    || { echo 'FAIL: emitStructCopy missing' >&2; exit 1; }
grep -qF 'void emitStructStore(const Expr& e){' src/aster.cpp \
    || { echo 'FAIL: emitStructStore missing' >&2; exit 1; }
grep -qF 'void structDeclaration(){' src/aster.cpp \
    || { echo 'FAIL: struct declaration parsing missing' >&2; exit 1; }
grep -qF 'std::vector<uint8_t> structConstantImage(Ty ty,const Expr& init,const std::string& name){' src/aster.cpp \
    || { echo 'FAIL: constant aggregate folding for globals missing' >&2; exit 1; }
# The hidden result pointer: saved on entry (X8 is caller-saved scratch) and
# returned in X0 so a nesting sret call cannot lose it.
grep -qF 'if(!isMain&&structInMemory(f.retType))storeStackOff(8,kSretSlot,Ty::I64);' src/aster.cpp \
    || { echo 'FAIL: the sret pointer is not saved in the prologue' >&2; exit 1; }
grep -qF 'loadStackOff(0,kSretSlot,Ty::I64);       // a nested call may have taken X8' src/aster.cpp \
    || { echo 'FAIL: the sret pointer is not reloaded for the return value' >&2; exit 1; }
printf '%s\n' 'PASS: Ty lattice, layout pass, AAPCS64 classification, shared ArgLayout and sret plumbing present'

printf '%s\n' '[3/8] Rejection matrix: a struct is a value, but not an integer'
# Each case is a program that must be refused, with the diagnostic that must
# appear: a rejection is only as good as the message that explains it.
reject(){
    name=$1; want=$2; src=$3
    printf '%s\n' "$src" > "$OUT/$name.ast"
    msg=$("$OUT/aster" build-elf "$OUT/$name.ast" -o "$OUT/$name.elf" 2>&1 || true)
    case "$msg" in
        *"$want"*) ;;
        *) echo "FAIL: $name not rejected as expected: want '$want', got: $msg" >&2; exit 1 ;;
    esac
}
reject unknown-struct  'expected i32, i64, u8, u16, u32, u64, ptr, ptr<S>, bool, or a struct name' 'fn main() -> i32 { let p: Nope = Nope { 1 }; return p.x; }'
reject unknown-field   "struct 'P' has no field named 'y'"                 'struct P { x: i32 }
fn main() -> i32 { let p: P = P { 1 }; return p.y; }'
reject literal-count   "struct literal for 'P' has 2 values but the struct has 1 fields" 'struct P { x: i32 }
fn main() -> i32 { let p: P = P { 1, 2 }; return p.x; }'
reject dup-field       'duplicate field in struct P: x'                    'struct P { x: i32, x: i32 }
fn main() -> i32 { return 0; }'
reject dup-struct      'duplicate struct declaration: P'                   'struct P { x: i32 }
struct P { y: i32 }
fn main() -> i32 { return 0; }'
reject self-contain    'struct P cannot contain itself'                    'struct P { x: i32, p: P }
fn main() -> i32 { return 0; }'
# v0.23.29-dev: a field may be an array, so this row no longer refuses the
# declaration -- it refuses a *literal* initializer for a struct that has one,
# which is the rule that replaced it. (Covered in full by
# tests/struct-array-field-checks.sh [5/9].)
reject array-field-lit "struct 'P' contains an array field and cannot be initialized by a literal" 'struct P { a: i32[4] }
fn main() -> i32 { let s: P = P { 0 }; return 0; }'
reject struct-arith    'cannot use a struct value (P) in +'                'struct P { x: i32 }
fn main() -> i32 { let p: P = P { 1 }; return p + 1; }'
reject struct-compare  'cannot use a struct value (P) in a comparison'     'struct P { x: i32 }
fn main() -> i32 { let p: P = P { 1 }; let q: P = P { 1 }; if (p == q) { return 1; } else { return 0; } }'
reject struct-cond     'condition must be a comparison, a bool expression, or an integer' 'struct P { x: i32 }
fn main() -> i32 { let p: P = P { 1 }; if (p) { return 1; } else { return 0; } }'
reject arg-struct-i32  'argument type mismatch calling f at argument 1: expected i32, got P' 'struct P { x: i32 }
fn f(a: i32) -> i32 { return a; }
fn main() -> i32 { let p: P = P { 1 }; return f(p); }'
reject arg-i32-struct  'argument type mismatch calling f at argument 1: expected P, got i32' 'struct P { x: i32 }
fn f(p: P) -> i32 { return p.x; }
fn main() -> i32 { return f(1); }'
# Structs are nominal: two structs with identical layouts are different types.
reject arg-other-struct 'argument type mismatch calling g at argument 1: expected Q, got P' 'struct P { x: i32 }
struct Q { x: i32 }
fn g(q: Q) -> i32 { return q.x; }
fn main() -> i32 { let p: P = P { 1 }; return g(p); }'
reject ptr-mismatch    'argument type mismatch calling g at argument 1: expected ptr<P>' 'struct P { x: i32 }
struct Q { y: i32 }
fn g(p: ptr<P>) -> i32 { return p.x; }
fn main() -> i32 { let q: Q = Q { 1 }; return g(&q); }'
reject let-struct-i32  "type mismatch initializing 'x': expected i32, got P" 'struct P { x: i32 }
fn main() -> i32 { let x: i32 = P { 1 }; return x; }'
reject let-other-struct "type mismatch initializing 'q': expected Q, got P" 'struct P { x: i32 }
struct Q { y: i32 }
fn mk() -> P { return P { 1 }; }
fn main() -> i32 { let q: Q = mk(); return q.y; }'
reject addr-of-to-i32  "type mismatch initializing 'k': expected i32, got ptr" 'struct P { x: i32 }
fn main() -> i32 { let p: P = P { 1 }; let k: i32 = &p; return 0; }'
reject field-of-i32    "cannot read field 'y' of i32: expected a struct or a ptr<S>" 'fn main() -> i32 { let x: i32 = 5; return x.y; }'
reject main-returns-struct 'main must return i32'                          'struct P { x: i32 }
fn main() -> P { return P { 1 }; }'
reject return-struct-from-i32 'return type mismatch in function main: expected i32, got P' 'struct P { x: i32 }
fn main() -> i32 { return P { 1 }; }'
reject global-ptr-field "global struct field 'P.p' cannot be initialized by a constant: g" 'struct P { x: i32, p: ptr }
let g: P = P { 1, 2 };
fn main() -> i32 { return g.x; }'
printf '%s\n' 'PASS: 20 struct rules rejected with the diagnostic that explains each'

printf '%s\n' '[4/8] Structural: every pre-existing example still compiles byte for byte'
# tests/baseline/v0.23.5-dev/example-hashes.txt records every example of this
# release in three modes (build-so, build-elf, build-obj --pic), mode-major,
# one sha256 per line. Nothing in the struct work may move a byte of any of
# them: 252 of these 261 lines were recorded before v0.23.13-dev; the six
# added in v0.23.13-dev are the `include` demo pair, and the three added in
# v0.23.14-dev are the touch example examples/native_touch.ast -- in the same
# three modes, of which the build-so and build-obj lines were re-recorded in
# v0.23.15-dev when the on-device touch bugs were fixed (the example itself
# changed; nothing else did, and the other 259 lines are byte-identical).
# v0.23.18-dev re-recorded two more: c_struct_abi.build-so and
# c_struct_abi.build-obj_--pic. Round 2 (wide-integer correctness) stopped the
# arithmetic sites from sign-extending a *constant* operand that had already
# been materialized at full width, and aster_mk_b's `v + 1` / `v + 2` each lost
# the SXTW that followed. Those two SXTWs were no-ops on the values 1 and 2, so
# the object is two instructions shorter and behaves identically — e2e-c-struct
# still passes, which is what actually pins the ABI. The other 259 lines are
# byte-identical, and no example's build status changed in any mode.
# The baseline enumerates examples/*.ast, so a new example has to be added to
# it; what must never change is any line that was already there.
if [ ! -f tests/baseline/v0.23.5-dev/example-hashes.txt ]; then
    echo 'FAIL: struct byte-identity baseline missing' >&2; exit 1
fi
: > "$OUT/hashes.txt"
for mode in build-so build-elf "build-obj --pic"; do
    tag=$(echo "$mode" | tr ' ' '_')
    for f in examples/*.ast; do
        b=$(basename "$f" .ast)
        # shellcheck disable=SC2086
        if "$OUT/aster" $mode "$f" -o "$OUT/$b.$tag" >/dev/null 2>&1; then
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
LC_ALL=C sort tests/baseline/v0.23.5-dev/example-hashes.txt > "$OUT/base.sorted.txt"
if ! diff -u "$OUT/base.sorted.txt" "$OUT/hashes.filtered.txt" > "$OUT/hashes.diff"; then
    echo 'FAIL: struct support changed the output of a pre-existing example' >&2
    sed -n '1,20p' "$OUT/hashes.diff" >&2
    exit 1
fi
printf '%s\n' "PASS: $(wc -l < "$OUT/hashes.filtered.txt") recorded outputs reproduced byte for byte"

printf '%s\n' '[5/8] Structural: field layout matches the C compiler, byte for byte'
# The strongest layout statement available without an offsetof operator: give
# Aster and C the same struct and the same constant initializer, then compare
# the images. Any disagreement about a field's offset, a struct's size, or its
# alignment shows up as a different byte.
# These four have the same layout on x86-64 and AArch64 (no pointer-sized
# field), so $HOSTCC may be either; tests/e2e-c-struct.sh runs the AArch64 half.
cat > "$OUT/layout.c" <<'C'
#include <stdio.h>
#include <string.h>
struct A { int x, y; };
struct B { unsigned char a; long long b; unsigned short c; int d; };
struct C2 { struct A p; int q; long long r; };
struct D { unsigned char a, b; };
static void dump(const void* p, size_t n){
    const unsigned char* b = (const unsigned char*)p;
    for (size_t i = 0; i < n; ++i) printf("%02x", b[i]);
    printf("\n");
}
int main(void){
    /* Padding bytes are part of the image Aster writes (it zero-fills them),
       so they are zeroed here too: leaving them to the stack would compare
       Aster's answer against uninitialized memory. */
    struct A a; memset(&a, 0, sizeof a); a.x = 1; a.y = 2;
    struct B b; memset(&b, 0, sizeof b); b.a = 1; b.b = 2; b.c = 3; b.d = 4;
    struct C2 c; memset(&c, 0, sizeof c); c.p.x = 5; c.p.y = 6; c.q = 7; c.r = 8;
    struct D d; memset(&d, 0, sizeof d); d.a = 1; d.b = 2;
    dump(&a, sizeof a); dump(&b, sizeof b); dump(&c, sizeof c); dump(&d, sizeof d);
    return 0;
}
C
${HOSTCC:-cc} -std=c11 -O2 -Wall -Wextra -Werror "$OUT/layout.c" -o "$OUT/layout-host"
"$PWD/tests/run-aarch64.sh" "$OUT/layout-host" > "$OUT/layout-host.txt"
cat > "$OUT/layout-a.ast" <<'AST'
struct A { x: i32, y: i32 }
let g: A = A { 1, 2 };
fn main() -> i32 { return g.x; }
AST
cat > "$OUT/layout-b.ast" <<'AST'
struct B { a: u8, b: i64, c: u16, d: i32 }
let g: B = B { 1, 2, 3, 4 };
fn main() -> i32 { return g.a; }
AST
cat > "$OUT/layout-c.ast" <<'AST'
struct A { x: i32, y: i32 }
struct C2 { p: A, q: i32, r: i64 }
let g: C2 = C2 { A { 5, 6 }, 7, 8 };
fn main() -> i32 { return g.q; }
AST
cat > "$OUT/layout-d.ast" <<'AST'
struct D { a: u8, b: u8 }
let g: D = D { 1, 2 };
fn main() -> i32 { return g.a; }
AST
: > "$OUT/layout-aster.txt"
for n in a b c d; do
    "$OUT/aster" build-obj "$OUT/layout-$n.ast" -o "$OUT/layout-$n.o" >/dev/null
    python3 - "$OUT/layout-$n.o" "$OUT/layout-$n.img.txt" <<'PY'
import struct, sys
b = open(sys.argv[1], 'rb').read()
assert b[:4] == b'\x7fELF'
shoff, = struct.unpack_from('<Q', b, 40)
shentsize, shnum, shstrndx = struct.unpack_from('<HHH', b, 58)
def sh(i):
    o = shoff + i * shentsize
    name, _t, _f, addr, off, size = struct.unpack_from('<IIQQQQ', b, o)
    return name, off, size
strbase = sh(shstrndx)[1]
data = None
for i in range(shnum):
    name, off, size = sh(i)
    if b[strbase + name:b.index(b'\0', strbase + name)].decode() == '.data':
        data = b[off:off + size]
assert data is not None, 'no .data section'
open(sys.argv[2], 'w').write(data.hex() + '\n')
PY
    cat "$OUT/layout-$n.img.txt" >> "$OUT/layout-aster.txt"
done
# Aster pads every object to a 4-byte multiple, so compare the C-sized prefix.
paste -d' ' "$OUT/layout-aster.txt" "$OUT/layout-host.txt" | while read -r aster c; do
    case "$aster" in "$c"*) ;; *)
        echo "FAIL: layout differs: Aster '$aster' vs C '$c'" >&2; exit 1 ;;
    esac
done
printf '%s\n' 'PASS: i32/i64/u8/u16 fields, a nested struct and a 2-byte struct all lay out exactly as C does'

printf '%s\n' '[6/8] Acceptance: the three AAPCS64 size classes, in and out (qemu self-check)'
# Each program returns 0 when the class is handled correctly and a distinctive
# non-zero status otherwise, so a single run tells you which class broke.
selfcheck(){
    f=$1
    "$OUT/aster" build-elf "$OUT/$f.ast" -o "$OUT/$f" >/dev/null
    st=$(run_status "$OUT/$f")
    [ "$st" -eq 0 ] || { echo "FAIL: $f exited with status $st (0 means the case is handled)" >&2; exit 1; }
}
cat > "$OUT/byval8.ast" <<'AST'
struct P { x: i32, y: i32 }
fn sum(p: P) -> i32 { return p.x + p.y; }
fn mk(v: i32) -> P { return P { v, v * 2 }; }
fn main() -> i32 {
    let p: P = P { 3, 4 };
    let q: P = mk(21);
    return sum(p) + sum(q) - 70;
}
AST
cat > "$OUT/byval16.ast" <<'AST'
struct T { a: i32, b: i32, c: i32 }
fn sum(t: T) -> i32 { return t.a + t.b + t.c; }
fn mk(v: i32) -> T { return T { v, v + 1, v + 2 }; }
fn main() -> i32 {
    let t: T = T { 5, 6, 7 };
    let u: T = mk(30);
    return sum(t) + sum(u) - 111;
}
AST
cat > "$OUT/byval24.ast" <<'AST'
struct B { a: i64, b: i64, c: i64 }
fn sum(b: B) -> i64 { return b.a + b.b + b.c; }
fn mk(v: i64) -> B { return B { v, v + 1, v + 2 }; }
fn main() -> i32 {
    let b: B = B { 100, 200, 300 };
    let c: B = mk(1000);
    return sum(b) + sum(c) - 3603;
}
AST
for f in byval8 byval16 byval24; do selfcheck "$f"; done
printf '%s\n' 'PASS: <=8 bytes in one register, 9..16 in a pair, >16 through X8 — both directions'

printf '%s\n' '[7/8] Acceptance: nesting, ptr<S>, &, whole-struct copy, globals (qemu self-check)'
cat > "$OUT/nested.ast" <<'AST'
struct Inner { a: i32, b: i32 }
struct Outer { p: Inner, c: i32 }
fn sum(o: Outer) -> i32 { return o.p.a + o.p.b + o.c; }
fn main() -> i32 {
    let o: Outer = Outer { Inner { 1, 2 }, 3 };
    o.p = Inner { 10, 20 };
    o.p.b = o.p.b + 5;
    return sum(o) - 38;
}
AST
cat > "$OUT/ptrfield.ast" <<'AST'
struct Node { v: i32, next: ptr<Node> }
fn count(n: ptr<Node>) -> i32 { return n.v; }
fn main() -> i32 {
    let buf: i32[4] = 0;
    let a: Node = Node { 1, buf };
    let b: Node = Node { 2, buf };
    a.next = &b;
    return count(&a) + a.next.v - 3;
}
AST
cat > "$OUT/copy.ast" <<'AST'
struct P { x: i32, y: i32 }
fn twice(p: P) -> P { return P { p.x * 2, p.y * 2 }; }
fn main() -> i32 {
    let p: P = P { 3, 4 };
    let q: P = p;
    q.x = q.x + 10;
    p = q;
    let i: i32 = 0;
    while (i < 3) { p = twice(p); i = i + 1; }
    return p.x + p.y - 136;    // {13,4} -> {26,8} -> {52,16} -> {104,32}
}
AST
cat > "$OUT/globals.ast" <<'AST'
struct Point { x: i32, y: i32 }
struct Rect { a: Point, b: Point }
let origin: Point = Point { 3, 4 };
let zero: Point = Point { 0, 0 };
let unit: Rect = Rect { Point { 1, 2 }, Point { 3, 4 } };
fn set(p: ptr<Point>) -> i32 { p.x = 10; return p.x; }
fn main() -> i32 {
    origin.x = origin.x + 1;
    let t: i32 = set(&origin);
    return origin.x + t + origin.y + zero.x + zero.y
         + unit.a.x + unit.a.y + unit.b.x + unit.b.y - 34;
}
AST
cat > "$OUT/stackarg.ast" <<'AST'
struct B { a: i64, b: i64, c: i64 }
fn nine(a: i32, b: i32, c: i32, d: i32, e: i32, f: i32, g: i32, h: i32, big: B) -> i64 {
    return big.a + big.b + big.c + a + b + h;
}
fn main() -> i32 {
    let big: B = B { 100, 200, 300 };
    return nine(1, 2, 3, 4, 5, 6, 7, 8, big) - 611;
}
AST
cat > "$OUT/callarg.ast" <<'AST'
struct B { a: i64, b: i64, c: i64 }
fn mk(v: i64) -> B { return B { v, v + 1, v + 2 }; }
fn use(b: B) -> i64 { return b.a + b.b + b.c; }
fn main() -> i32 {
    let x: B = mk(use(mk(5)));   // {5,6,7} -> 18 -> {18,19,20}
    return use(x) - 57;
}
AST
# AAPCS64 does not pad a composite to an even-numbered register: aarch64-linux-gnu-gcc
# puts s1 in x1/x2 and s2 in x3/x4 for `f4(int a, struct T s1, struct T s2)`.
cat > "$OUT/pairalloc.ast" <<'AST'
struct T { a: i32, b: i32, c: i32 }
fn f4(a: i32, s1: T, s2: T) -> i32 {
    return a + s1.a + s1.b + s1.c + s2.a + s2.b + s2.c;
}
fn main() -> i32 {
    let s1: T = T { 1, 2, 3 };
    let s2: T = T { 4, 5, 6 };
    return f4(10, s1, s2) - 31;
}
AST
for f in nested ptrfield copy globals stackarg callarg pairalloc; do selfcheck "$f"; done
printf '%s\n' 'PASS: nested aggregates, ptr<S> fields, &, whole-struct assignment, struct globals, 9th-argument composites and call-result arguments'

printf '%s\n' '[8/8] Bit-level: >16-byte returns go through X8, and the pair case uses X0/X1'
cat > "$OUT/sret.ast" <<'AST'
struct B { a: i64, b: i64, c: i64 }
fn mk(v: i64) -> B { return B { v, v + 1, v + 2 }; }
fn main() -> i32 { let b: B = mk(1); return b.a + b.b + b.c - 6; }
AST
cat > "$OUT/pair.ast" <<'AST'
struct T { a: i32, b: i32, c: i32 }
fn mk(v: i32) -> T { return T { v, v + 1, v + 2 }; }
fn main() -> i32 { let t: T = mk(1); return t.a + t.b + t.c - 6; }
AST
"$OUT/aster" build-elf "$OUT/sret.ast" -o "$OUT/sret" >/dev/null
"$OUT/aster" build-elf "$OUT/pair.ast" -o "$OUT/pair" >/dev/null
python3 - "$OUT/sret" "$OUT/pair" <<'PY'
import struct, sys

# AAPCS64, bit level: the >16-byte result comes back through the buffer whose
# address the caller puts in X8, and a 9..16-byte result comes back in the X0/X1
# pair. Both claims are checked on the emitted words, not on the program's
# behaviour, so a change that happens to still produce the right answer (say, by
# accident of where the scratch slots sit) cannot pass.
kSretSlot, kRetBuf = 8160, 8168

def text_words(path):
    b = open(path, 'rb').read()
    assert b[:4] == b'\x7fELF'
    shoff, = struct.unpack_from('<Q', b, 40)
    shentsize, shnum, shstrndx = struct.unpack_from('<HHH', b, 58)
    def sh(i):
        o = shoff + i * shentsize
        name, _t, _f, addr, off, size = struct.unpack_from('<IIQQQQ', b, o)
        return name, off, size
    strbase = sh(shstrndx)[1]
    for i in range(shnum):
        name, off, size = sh(i)
        if b[strbase + name:b.index(b'\0', strbase + name)].decode() == '.text':
            return list(struct.unpack_from('<%dI' % (size // 4), b, off))
    raise AssertionError('no .text')

def adds(words):
    """ADD/SUB (immediate), 64-bit: yield (op, rd, rn, imm)."""
    for w in words:
        if (w >> 24) == 0x91 or (w >> 24) == 0xD1:   # ADD / SUB, sf=1
            yield ('ADD' if (w >> 24) == 0x91 else 'SUB', w & 31, (w >> 5) & 31,
                   (w >> 10) & 0xFFF)

def mem(words, opcode):
    """STR/LDR Xt, [Xn, #imm*8]: yield (rt, rn, byte offset)."""
    for w in words:
        if (w & 0xFFC00000) == opcode:
            yield w & 31, (w >> 5) & 31, ((w >> 10) & 0xFFF) * 8

sret_w = text_words(sys.argv[1])
pair_w = text_words(sys.argv[2])

# The caller publishes the result buffer: ADD X8, SP, #imm.
assert any(op == 'ADD' and rd == 8 and rn == 31 for op, rd, rn, _ in adds(sret_w)), \
    'caller does not hand X8 the result buffer'
# The callee parks it immediately: STR X8, [SP, #8160] — X8 is caller-saved
# scratch, and a nested sret call would otherwise overwrite it.
assert any(rt == 8 and rn == 31 and off == kSretSlot
           for rt, rn, off in mem(sret_w, 0xF9000000)), \
    'callee does not save X8 in its prologue'
# ...and hands the same pointer back in X0 for the return.
assert any(rt == 0 and rn == 31 and off == kSretSlot
           for rt, rn, off in mem(sret_w, 0xF9400000)), \
    'callee does not return the buffer address in X0'
# The >16-byte path must not go anywhere near the 16-byte staging buffer.
assert not any(rt in (0, 1) and rn == 31 and off in (kRetBuf, kRetBuf + 8)
               for rt, rn, off in mem(sret_w, 0xF9400000)), \
    'a >16-byte return reloaded X0/X1 from the 16-byte staging buffer'

# A 12-byte return is staged in the 16-byte buffer and reloaded into X0/X1.
for rt, off in ((0, kRetBuf), (1, kRetBuf + 8)):
    assert any(r == rt and rn == 31 and o == off
               for r, rn, o in mem(pair_w, 0xF9400000)), \
        'a 12-byte return does not reload X%d from the staging buffer' % rt
# The pair path must not use X8 at all.
assert not any(op == 'ADD' and rd == 8 and rn == 31 for op, rd, rn, _ in adds(pair_w)), \
    'a 12-byte return used the X8 result pointer'
print('PASS: >16-byte returns use the X8 buffer; a 12-byte return comes back in X0/X1')
PY
printf '%s\n' 'ALL STRUCT CHECKS PASSED'
