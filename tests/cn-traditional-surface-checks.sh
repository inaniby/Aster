#!/bin/sh
# tests/cn-traditional-surface-checks.sh — D-3 (i): the bilingual frontend
# accepts the framework sources' traditional surface, so a bilingual
# project can build the framework + the app without the traditional
# build-obj detour. The framework files themselves are compiled here
# (aui.ast / aster_std.ast / aui_impl.ast); each newly accepted surface
# also has a small program with a qemu-checked exit code.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ASTER_BIN=${ASTER_BIN:-$ROOT/build/cn-s1-s2/aster}
if [ ! -x "$ASTER_BIN" ]; then
    echo "set ASTER_BIN to a built Aster executable" >&2
    exit 2
fi
RUNNER=${RUNNER:-$ROOT/tests/run-aarch64.sh}
# AArch64 guests run natively on an AArch64 host and under qemu-aarch64
# elsewhere. Without either, execution checks SKIP cleanly (cf.
# bootstrap-loop-checks.sh) instead of failing with Exec format error.
if [ "$(uname -m)" = aarch64 ] || [ "$(uname -m)" = arm64 ] \
    || command -v qemu-aarch64 >/dev/null 2>&1; then
    CAN_RUN=1
else
    CAN_RUN=0
fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

# Build one English source to an executable and check its exit code.
run_expect() {
    name=$1
    expected=$2
    "$ASTER_BIN" build-cn-obj --language en "$TMP/$name.ast" -o "$TMP/$name.o"
    "$ASTER_BIN" link-obj "$TMP/$name.o" -o "$TMP/$name"
    if [ "$CAN_RUN" -eq 1 ]; then
        if "$RUNNER" "$TMP/$name"; then status=0; else status=$?; fi
        [ "$status" -eq "$expected" ] || { echo "FAIL: $name expected exit $expected, got $status" >&2; exit 1; }
    else
        echo 'SKIP: execution requires qemu-aarch64 or AArch64 Linux'
    fi
}

printf '%s\n' '[1/8] aui.ast: the declaration-only framework header reports an empty object, like the traditional build'
if "$ASTER_BIN" build-cn-obj --language en "$ROOT/stdlib/asterui/src/aui.ast" \
    -o "$TMP/aui.o" 2> "$TMP/aui.err"; then
    echo 'FAIL: aui.ast produced an object' >&2; exit 1
fi
grep -q 'cannot write an empty object' "$TMP/aui.err"
if "$ASTER_BIN" build-obj --pic "$ROOT/stdlib/asterui/src/aui.ast" \
    -o "$TMP/aui-trad.o" 2> "$TMP/aui-trad.err"; then
    echo 'FAIL: traditional build of aui.ast produced an object' >&2; exit 1
fi
grep -q 'cannot write an empty object' "$TMP/aui-trad.err"

printf '%s\n' '[2/8] aster_std.ast builds in the bilingual frontend'
"$ASTER_BIN" build-cn-obj --language en "$ROOT/stdlib/aster_std.ast" -o "$TMP/aster_std.o"

printf '%s\n' '[3/8] aui_impl.ast builds in the bilingual frontend'
"$ASTER_BIN" build-cn-obj --language en "$ROOT/stdlib/asterui/src/aui_impl.ast" -o "$TMP/aui_impl.o"

printf '%s\n' '[4/8] generic pointers, pointer casts, memory intrinsics, deref stores, pointer indexing'
cat > "$TMP/pointers.ast" <<'SRC'
// aster:language=en
fn bump(p: ptr<i32>) -> i32 { p[0] = p[0] + 1; return p[0]; }
fn main(): i32 {
let a: i32[2] = [40, 0];
let p: ptr<i32> = a;
let v: i32 = bump(p);
let q: ptr<u8> = ptr<u8>(p);
*(p + 4) = load_u8(q) + 1;
store_u8(q, load_u8(q) + 1);
return v + a[1] + load_u8(q) - 42;
}
SRC
run_expect pointers 83

printf '%s\n' '[5/8] shifts, bitwise operators, else-if chains, cross-line expressions, multi-line parameter lists'
cat > "$TMP/operators.ast" <<'EOF'
// aster:language=en
fn pick(x: i32,
        y: i32) -> i32 {
let r: i32 = 0;
if (x == 1) { r = 1; }
else if (x == 2) { r = 2; }
else { r = 3; }
return r + (1 + 2 << 1) + (8 >> 1 + 1) +
       (6 & 3 | 8) + (5 ^ 3) + ((6 & 3)
       | 8);
}
fn main(): i32 { return pick(2, 0); }
EOF
# pick(2,0): r=2, shifts 6+2, bitwise 10+6, leading-operator continuation 10 -> 36
run_expect operators 36

printf '%s\n' '[6/8] sizeof(Type) folds to the type size'
cat > "$TMP/sizeof.ast" <<'SRC'
// aster:language=en
struct Pair { x: i32, y: i32, }
fn main(): i32 { return sizeof(i32) + sizeof(Pair) + sizeof(u8); }
SRC
run_expect sizeof 13

printf '%s\n' '[7/8] calls through fn-typed locals and bare pointers, string literals decay to pointers'
cat > "$TMP/indirect.ast" <<'SRC'
// aster:language=en
fn twice(x: i32) -> i32 { return x * 2; }
fn first(p: ptr) -> i32 { return load_u8(p); }
fn first8(p: ptr<u8>) -> i32 { return load_u8(p); }
fn cmp2(a: ptr, b: ptr) -> i32 { return 5; }
fn main(): i32 {
let f: fn(i32) -> i32 = twice;
let cmp: ptr = cmp2;
return f(20) + cmp(0, 0) - 5 + first("A") - 65 + first8("B") - 66;
}
SRC
# 40 + 5 - 5 + 65 - 65 + 66 - 66 = 40
run_expect indirect 40

printf '%s\n' '[8/8] __aster_cn_ is the runtime namespace (allowed); other __aster_ prefixes stay reserved'
cat > "$TMP/cn-prefix.ast" <<'SRC'
// aster:language=en
fn __aster_cn_str_order(a: ptr<u8>, b: ptr<u8>) -> i32 { return 0; }
fn main(): i32 { return __aster_cn_str_order(0, 0); }
SRC
"$ASTER_BIN" build-cn-obj --language en "$TMP/cn-prefix.ast" -o "$TMP/cn-prefix.o"
cat > "$TMP/reserved-prefix.ast" <<'SRC'
// aster:language=en
fn __aster_user() -> i32 { return 0; }
fn main(): i32 { return 0; }
SRC
if "$ASTER_BIN" build-cn-obj --language en "$TMP/reserved-prefix.ast" \
    -o "$TMP/reserved-prefix.o" 2> "$TMP/reserved-prefix.err"; then
    echo 'FAIL: __aster_user was accepted' >&2; exit 1
fi
grep -q "identifier prefix '__aster_' is reserved" "$TMP/reserved-prefix.err"

echo 'PASS: traditional-surface checks'
