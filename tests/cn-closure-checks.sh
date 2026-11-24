#!/bin/sh
# Closure checks (design §2.14 and §5.1 S4): zero-capture and capturing
# closures run in both languages, and unknown captures are rejected.
# This is the suite named `cn-closure-checks.sh` by the design; the wider
# closure runtime coverage lives in tests/cn-backend-checks.sh.
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

echo '[1/4] a capturing closure runs and sees the captured value'
cat > "$TMP/closure-capture-zh.ast" <<'SRC'
// aster:language=zh
方法 启动方法(): 整数
    变量 步长: 整数 = 2
    变量 回调: 闭包(整数): 整数 = 方法 [步长] (数值: 整数): 整数
        返回 数值 + 步长
    结束 方法
    返回 回调(40)
结束 方法
SRC
"$ASTER_BIN" build-cn-obj "$TMP/closure-capture-zh.ast" -o "$TMP/closure-capture-zh.o"
if [ "$CAN_RUN" -eq 1 ]; then
    "$ASTER_BIN" build-obj "$ROOT/stdlib/aster_std.ast" -o "$TMP/aster_std.o"
    "$ASTER_BIN" link-obj "$TMP/closure-capture-zh.o" "$TMP/aster_std.o" -o "$TMP/closure-capture-zh"
    if "$RUNNER" "$TMP/closure-capture-zh"; then status=0; else status=$?; fi
    [ "$status" -eq 42 ] || { echo "FAIL: capturing closure returned $status, expected 42" >&2; exit 1; }
else
    echo 'SKIP: execution requires qemu-aarch64 or AArch64 Linux'
fi

echo '[2/4] a zero-capture closure runs in English'
cat > "$TMP/closure-zero-en.ast" <<'SRC'
// aster:language=en
fn main(): i32 {
let callback = fn [] (value: i32): i32 {
return value + 1;
};
return callback(41);
}
SRC
"$ASTER_BIN" build-cn-obj --language en "$TMP/closure-zero-en.ast" -o "$TMP/closure-zero-en.o"
if [ "$CAN_RUN" -eq 1 ]; then
    "$ASTER_BIN" link-obj "$TMP/closure-zero-en.o" "$TMP/aster_std.o" -o "$TMP/closure-zero-en"
    if "$RUNNER" "$TMP/closure-zero-en"; then status=0; else status=$?; fi
    [ "$status" -eq 42 ] || { echo "FAIL: zero-capture closure returned $status, expected 42" >&2; exit 1; }
else
    echo 'SKIP: execution requires qemu-aarch64 or AArch64 Linux'
fi

echo '[3/4] an unknown capture name is rejected'
cat > "$TMP/closure-unknown-capture.ast" <<'SRC'
// aster:language=en
fn main(): i32 {
let f = fn [missing] (x: i32): i32 {
return x;
};
return f(0);
}
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/closure-unknown-capture.ast" \
    -o "$TMP/closure-unknown-capture.o" 2>"$TMP/closure-unknown-capture.err"; then
    echo 'FAIL: unknown closure capture was accepted' >&2
    exit 1
fi
grep -q 'unknown closure capture: missing' "$TMP/closure-unknown-capture.err" || {
    echo 'FAIL: expected unknown-capture rejection' >&2
    exit 1
}

echo '[4/4] closure types accept `->` (design §2.14) in both languages, same lowering as `:`'
# The helper salt is a hash of the canonical input path (LIB8), so the
# two spellings must be built from the SAME path for a byte-identical
# comparison; a different path mints different `__aster_cn_closure_*`
# helper names even for identical sources.
cat > "$TMP/closure-spelling-zh.ast" <<'SRC'
// aster:language=zh
方法 启动方法(): 整数
    变量 步长: 整数 = 2
    变量 回调: 闭包(整数) -> 整数 = 方法 [步长] (数值: 整数): 整数
        返回 数值 + 步长
    结束 方法
    返回 回调(40)
结束 方法
SRC
"$ASTER_BIN" build-cn-obj "$TMP/closure-spelling-zh.ast" -o "$TMP/closure-arrow-zh.o"
cat > "$TMP/closure-spelling-zh.ast" <<'SRC'
// aster:language=zh
方法 启动方法(): 整数
    变量 步长: 整数 = 2
    变量 回调: 闭包(整数): 整数 = 方法 [步长] (数值: 整数): 整数
        返回 数值 + 步长
    结束 方法
    返回 回调(40)
结束 方法
SRC
"$ASTER_BIN" build-cn-obj "$TMP/closure-spelling-zh.ast" -o "$TMP/closure-colon-zh.o"
cmp "$TMP/closure-arrow-zh.o" "$TMP/closure-colon-zh.o" || {
    echo 'FAIL: `闭包(整数) -> 整数` did not lower to the same object as `闭包(整数): 整数`' >&2
    exit 1
}
cat > "$TMP/closure-spelling-en.ast" <<'SRC'
// aster:language=en
fn main(): i32 {
let callback: closure(i32) -> i32 = fn [] (value: i32): i32 {
return value + 1;
};
return callback(41);
}
SRC
"$ASTER_BIN" build-cn-obj --language en "$TMP/closure-spelling-en.ast" -o "$TMP/closure-arrow-en.o"
cat > "$TMP/closure-spelling-en.ast" <<'SRC'
// aster:language=en
fn main(): i32 {
let callback: closure(i32): i32 = fn [] (value: i32): i32 {
return value + 1;
};
return callback(41);
}
SRC
"$ASTER_BIN" build-cn-obj --language en "$TMP/closure-spelling-en.ast" -o "$TMP/closure-colon-en.o"
cmp "$TMP/closure-arrow-en.o" "$TMP/closure-colon-en.o" || {
    echo 'FAIL: `closure(i32) -> i32` did not lower to the same object as `closure(i32): i32`' >&2
    exit 1
}

echo 'PASS: bilingual closure checks'
