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
grep -q "does not implement interface '可读': missing method '读'" "$TMP/iface-missing.err" || {
    echo 'FAIL: expected missing-interface-method rejection' >&2
    exit 1
}

echo '[4/5] B26: a class plus a declared alloc in one project builds'
mkdir -p "$TMP/b26/src"
cat > "$TMP/b26/aster.proj" <<'PROJ'
kind exe
[language]
default = "en"
src/std.ast
src/widget.ast
src/main.ast
PROJ
cat > "$TMP/b26/src/std.ast" <<'SRC'
// aster:language=en
fn alloc(n: i32) : ptr {
return 0;
}
SRC
cat > "$TMP/b26/src/widget.ast" <<'SRC'
// aster:language=en
class Widget {
let value: i32;
fn get(): i32 {
return this.value;
}
}
let g_widget: Widget = Widget();
SRC
cat > "$TMP/b26/src/main.ast" <<'SRC'
// aster:language=en
fn main(): i32 {
let w: Widget = Widget();
return w.get();
}
SRC
(cd "$TMP/b26" && "$ASTER_BIN" build >"$TMP/b26-build.log" 2>&1) || {
    echo 'FAIL: B26 project (class + declared alloc) did not build' >&2
    cat "$TMP/b26-build.log" >&2
    exit 1
}
[ -x "$TMP/b26/build/b26" ] || { echo 'FAIL: B26 project produced no exe' >&2; exit 1; }
for tu in std widget main; do
    (cd "$TMP/b26" && "$ASTER_BIN" build-cn-obj --project "$TMP/b26/aster.proj" "src/$tu.ast" -o "$TMP/b26/$tu.o" >"$TMP/b26-$tu.log" 2>&1) || {
        echo "FAIL: B26 build-cn-obj --project for $tu failed" >&2
        cat "$TMP/b26-$tu.log" >&2
        exit 1
    }
done
# The declared alloc is reused, not duplicated: defined in the TU that
# owns it, an undefined reference in the factory TU, and absent from the
# TU that needs no alloc at all.
readelf -sW "$TMP/b26/std.o" | grep ' alloc$' | grep -qv UND || {
    echo 'FAIL: B26 std.o does not define alloc' >&2; exit 1; }
readelf -sW "$TMP/b26/widget.o" | grep -q 'UND alloc$' || {
    echo 'FAIL: B26 widget.o does not reference alloc' >&2; exit 1; }
readelf -sW "$TMP/b26/main.o" | grep -q ' alloc$' && {
    echo 'FAIL: B26 main.o should not mention alloc' >&2; exit 1; }
# No alloc anywhere: the stub is only a declaration, so the link still
# fails with the undefined symbol (B26 must not break this).
mkdir -p "$TMP/b26-noalloc/src"
cp "$TMP/b26/aster.proj" "$TMP/b26-noalloc/aster.proj"
sed -i '/src\/std.ast/d' "$TMP/b26-noalloc/aster.proj"
cp "$TMP/b26/src/widget.ast" "$TMP/b26/src/main.ast" "$TMP/b26-noalloc/src/"
if (cd "$TMP/b26-noalloc" && "$ASTER_BIN" build 2>"$TMP/b26-noalloc.err"); then
    echo 'FAIL: B26 project without alloc built' >&2
    exit 1
fi
grep -q "undefined function symbol 'alloc'" "$TMP/b26-noalloc.err" || {
    echo 'FAIL: B26 no-alloc project failed without the alloc link error' >&2
    cat "$TMP/b26-noalloc.err" >&2
    exit 1
}
# Mismatched alloc: the throw is kept where alloc is truly needed (the
# factory TU), and still not raised where it is not (the main TU).
mkdir -p "$TMP/b26-mismatch/src"
cp "$TMP/b26/aster.proj" "$TMP/b26-mismatch/aster.proj"
cp "$TMP/b26/src/widget.ast" "$TMP/b26/src/main.ast" "$TMP/b26-mismatch/src/"
cat > "$TMP/b26-mismatch/src/std.ast" <<'SRC'
// aster:language=en
fn alloc(n: i32) : i32 {
return 0;
}
SRC
if (cd "$TMP/b26-mismatch" && "$ASTER_BIN" build 2>"$TMP/b26-mismatch.err"); then
    echo 'FAIL: B26 mismatched-alloc project built' >&2
    exit 1
fi
grep -q 'alloc is already declared' "$TMP/b26-mismatch.err" || {
    echo 'FAIL: B26 mismatched alloc did not report the conflict' >&2
    cat "$TMP/b26-mismatch.err" >&2
    exit 1
}
if (cd "$TMP/b26-mismatch" && "$ASTER_BIN" build-cn-obj --project "$TMP/b26-mismatch/aster.proj" src/widget.ast -o "$TMP/b26-mismatch/widget.o" 2>"$TMP/b26-mismatch-widget.err"); then
    echo 'FAIL: B26 mismatched alloc was accepted by the factory TU' >&2
    exit 1
fi
grep -q 'alloc is already declared' "$TMP/b26-mismatch-widget.err" || {
    echo 'FAIL: B26 factory TU did not report the alloc conflict' >&2
    cat "$TMP/b26-mismatch-widget.err" >&2
    exit 1
}
(cd "$TMP/b26-mismatch" && "$ASTER_BIN" build-cn-obj --project "$TMP/b26-mismatch/aster.proj" src/main.ast -o "$TMP/b26-mismatch/main.o" >"$TMP/b26-mismatch-main.log" 2>&1) || {
    echo 'FAIL: B26 main TU (needs no alloc) was rejected for the mismatched alloc' >&2
    cat "$TMP/b26-mismatch-main.log" >&2
    exit 1
}

echo '[5/5] B26: a class plus the real standard-library alloc runs'
mkdir -p "$TMP/b26rt/src"
cp "$TMP/b26/aster.proj" "$TMP/b26rt/aster.proj"
cp "$ROOT/stdlib/aster_std.ast" "$TMP/b26rt/src/std.ast"
cat > "$TMP/b26rt/src/widget.ast" <<'SRC'
// aster:language=en
class Widget {
let value: i32 = 0;
fn get(): i32 {
return this.value;
}
fn bump(x: i32): i32 {
this.value = this.value + x;
return this.value;
}
}
SRC
cat > "$TMP/b26rt/src/main.ast" <<'SRC'
// aster:language=en
fn main(): i32 {
let w: Widget = Widget();
return w.bump(41);
}
SRC
(cd "$TMP/b26rt" && "$ASTER_BIN" build >"$TMP/b26rt-build.log" 2>&1) || {
    echo 'FAIL: B26 runtime project (class + real stdlib alloc) did not build' >&2
    cat "$TMP/b26rt-build.log" >&2
    exit 1
}
if [ "$CAN_RUN" -eq 1 ]; then
    if "$RUNNER" "$TMP/b26rt/build/b26rt"; then status=0; else status=$?; fi
    [ "$status" -eq 41 ] || { echo "FAIL: B26 runtime returned $status, expected 41" >&2; exit 1; }
else
    echo 'SKIP: execution requires qemu-aarch64 or AArch64 Linux'
fi

echo 'PASS: bilingual class checks'
