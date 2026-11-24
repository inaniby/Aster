#!/bin/sh
# Type checks (design §5.1 S4): the unified type checker rejects
# string/pointer confusion, out-of-range narrow initializers, void locals
# and non-string string_view conversions.
# This is the suite named `cn-types-checks.sh` by the design.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ASTER_BIN=${ASTER_BIN:-$ROOT/build/cn-s1-s2/aster}
if [ ! -x "$ASTER_BIN" ]; then
    echo "set ASTER_BIN to a built Aster executable" >&2
    exit 2
fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

echo '[1/4] a string variable cannot initialize a pointer'
cat > "$TMP/str-to-ptr.ast" <<'SRC'
// aster:language=zh
方法 启动方法(): 整数
变量 s: 字符串 = "张三"
变量 p: 指针 = s
返回 0
结束 方法
SRC
# NOTE (P1, D-3 (i)): a string *literal* decays to a bare ptr / 1-byte ptr
# (mainline-compatible; the framework needs `let suf: ptr = "/aui.log"`),
# so this probe must use a string *variable* to test the S4 rule that
# `字符串` and `指针` are not interchangeable.
if "$ASTER_BIN" build-cn-obj "$TMP/str-to-ptr.ast" -o "$TMP/str-to-ptr.o" 2>"$TMP/str-to-ptr.err"; then
    echo 'FAIL: string-to-pointer initialization was accepted' >&2
    exit 1
fi
grep -q "type mismatch initializing 'p': expected ptr" "$TMP/str-to-ptr.err" || {
    echo 'FAIL: expected string-to-pointer type rejection' >&2
    exit 1
}

echo '[2/4] a narrow initializer must fit its type'
cat > "$TMP/narrow-overflow.ast" <<'SRC'
// aster:language=en
fn main(): i32 {
let x: u8 = 300;
return x;
}
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/narrow-overflow.ast" -o "$TMP/narrow-overflow.o" 2>"$TMP/narrow-overflow.err"; then
    echo 'FAIL: out-of-range u8 initializer was accepted' >&2
    exit 1
fi
grep -q 'does not fit in u8' "$TMP/narrow-overflow.err" || {
    echo 'FAIL: expected narrowing rejection' >&2
    exit 1
}

echo '[3/4] void cannot be a local variable type'
cat > "$TMP/void-local.ast" <<'SRC'
// aster:language=en
fn main(): i32 {
let x: void = 0;
return 0;
}
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/void-local.ast" -o "$TMP/void-local.o" 2>"$TMP/void-local.err"; then
    echo 'FAIL: void local variable was accepted' >&2
    exit 1
fi
grep -q 'void cannot be used as a local variable type' "$TMP/void-local.err" || {
    echo 'FAIL: expected void-local rejection' >&2
    exit 1
}

echo '[4/4] string_view conversion requires a string operand'
cat > "$TMP/string-view.ast" <<'SRC'
// aster:language=zh
方法 启动方法(): 整数
变量 text: 字符串视图 = 字符串视图(空)
返回 0
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/string-view.ast" -o "$TMP/string-view.o" 2>"$TMP/string-view.err"; then
    echo 'FAIL: non-string string_view conversion was accepted' >&2
    exit 1
fi
grep -q 'string_view conversion requires a string operand' "$TMP/string-view.err" || {
    echo 'FAIL: expected string_view conversion rejection' >&2
    exit 1
}

echo 'PASS: bilingual type checks'
