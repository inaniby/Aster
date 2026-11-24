#!/bin/sh
# Class checks (design §5.1 S4): a class with a field and an instance
# method runs in both languages, and a class that misses an interface
# method is rejected.
# This is the suite named `cn-class-checks.sh` by the design; the wider
# class, override and interface coverage lives in tests/cn-constructor-checks.sh,
# tests/cn-override-checks.sh and tests/cn-interface-checks.sh.
# [4/5]-[5/5] are the B26 regression: a class and a standard-library
# `alloc` in one project. The factory TU must reuse the declared alloc
# (same signature) instead of failing on the injected stub, a TU that
# needs no alloc must get neither a throw nor a stub, a mismatched
# alloc still throws where alloc is truly needed, and a project with no
# alloc at all still fails at link time (the stub is only a declaration).
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

echo '[1/5] a counter class runs in Chinese'
cat > "$TMP/counter-zh.ast" <<'SRC'
// aster:language=zh
类 计数器
变量 值: 整数 = 0
方法 增加(甲: 整数): 整数
本对象.值 = 本对象.值 + 甲
返回 本对象.值
结束 方法
结束 类
方法 启动方法(): 整数
变量 c: 计数器 = 计数器()
返回 c.增加(41)
结束 方法
SRC
"$ASTER_BIN" build-cn-obj "$TMP/counter-zh.ast" -o "$TMP/counter-zh.o"
if [ "$CAN_RUN" -eq 1 ]; then
    "$ASTER_BIN" build-obj "$ROOT/stdlib/aster_std.ast" -o "$TMP/aster_std.o"
    "$ASTER_BIN" link-obj "$TMP/counter-zh.o" "$TMP/aster_std.o" -o "$TMP/counter-zh"
    if "$RUNNER" "$TMP/counter-zh"; then status=0; else status=$?; fi
    [ "$status" -eq 41 ] || { echo "FAIL: Chinese counter returned $status, expected 41" >&2; exit 1; }
else
    echo 'SKIP: execution requires qemu-aarch64 or AArch64 Linux'
fi

echo '[2/5] a counter class runs in English'
cat > "$TMP/counter-en.ast" <<'SRC'
// aster:language=en
class Counter {
let value: i32 = 0;
fn increase(x: i32): i32 {
this.value = this.value + x;
return this.value;
}
}
fn main(): i32 {
let first: Counter = Counter();
return first.increase(41);
}
SRC
"$ASTER_BIN" build-cn-obj --language en "$TMP/counter-en.ast" -o "$TMP/counter-en.o"
if [ "$CAN_RUN" -eq 1 ]; then
    "$ASTER_BIN" link-obj "$TMP/counter-en.o" "$TMP/aster_std.o" -o "$TMP/counter-en"
    if "$RUNNER" "$TMP/counter-en"; then status=0; else status=$?; fi
    [ "$status" -eq 41 ] || { echo "FAIL: English counter returned $status, expected 41" >&2; exit 1; }
else
    echo 'SKIP: execution requires qemu-aarch64 or AArch64 Linux'
fi

echo '[3/5] a class that misses an interface method is rejected'
cat > "$TMP/iface-missing.ast" <<'SRC'
// aster:language=zh
接口类 可读
方法 读(): 整数
结束 接口类
类 书本 : 可读
变量 标题: 字符串 = "x"
结束 类
方法 启动方法(): 整数
返回 0
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/iface-missing.ast" -o "$TMP/iface-missing.o" 2>"$TMP/iface-missing.err"; then
    echo 'FAIL: class missing an interface method was accepted' >&2
    exit 1
fi
