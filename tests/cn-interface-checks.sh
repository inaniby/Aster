#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ASTER_BIN=${ASTER_BIN:-$ROOT/.tmp-ci/adapter/aster-interface}
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

cat > "$TMP/interface-zh.ast" <<'SRC'
// aster:language=zh
接口类 可取值
方法 取值(): 整数
结束 接口类
结构 容器
值: 可取值
结束 结构
类 一号 : 可取值
方法 取值(): 整数
返回 11
结束 方法
结束 类
类 基类 : 可取值
方法 取值(): 整数
返回 30
结束 方法
结束 类
类 子类 : 基类
结束 类
变量 全局容器: 容器 = 容器 { 一号() }
类 二号 : 可取值
方法 取值(): 整数
返回 22
结束 方法
结束 类
方法 读取(对象: 可取值): 整数
返回 对象.取值()
结束 方法
方法 制造(): 可取值
返回 一号()
结束 方法
变量 制造次数: 整数 = 0
方法 只制造一次(): 可取值
制造次数 = 制造次数 + 1
返回 一号()
结束 方法
方法 接收(值: 整数): 整数
返回 值
结束 方法
方法 启动方法(): 整数
变量 一: 可取值 = 一号()
变量 二: 可取值 = 二号()
变量 继承对象: 可取值 = 子类()
变量 多个: 可取值[2] = [一号(), 二号()]
变量 第一次结果: 整数 = 只制造一次().取值()
变量 嵌套结果: 整数 = 接收(只制造一次().取值())
返回 读取(一) + 二.取值() + 继承对象.取值() + 制造().取值() + 第一次结果 + 全局容器.值.取值() + 多个[0].取值() + 嵌套结果 + 制造次数
结束 方法
SRC

cat > "$TMP/interface-en.ast" <<'SRC'
interface class Value {
fn get(): i32;
}
struct Box { value: Value }
class One: Value {
fn get(): i32 { return 11; }
}
class Base: Value {
fn get(): i32 { return 30; }
}
class Child: Base {
}
class Two: Value {
fn get(): i32 { return 22; }
}
fn read(value: Value): i32 { return value.get(); }
fn make(): Value { return One(); }
let madeCount: i32 = 0;
fn makeOnce(): Value { madeCount = madeCount + 1; return One(); }
fn consume(value: i32): i32 { return value; }
let globalBox: Box = Box { One() };
fn main(): i32 {
let one: Value = One();
let two: Value = Two();
let inherited: Value = Child();
let values: Value[2] = [One(), Two()];
let onceValue: i32 = makeOnce().get();
let nestedValue: i32 = consume(makeOnce().get());
return read(one) + two.get() + inherited.get() + make().get() + onceValue + globalBox.value.get() + values[0].get() + nestedValue + madeCount;
}
SRC

"$ASTER_BIN" build-cn-obj "$TMP/interface-zh.ast" -o "$TMP/interface-zh.o"
"$ASTER_BIN" build-cn-obj --language en "$TMP/interface-en.ast" -o "$TMP/interface-en.o"

cat > "$TMP/array-parameter-interface-zh.ast" <<'SRC'
// aster:language=zh
接口类 数组更新器
方法 更新(values: 整数[2]): 整数
结束 接口类
类 加五 : 数组更新器
方法 更新(values: 整数[2]): 整数
values[0] = values[0] + 5
返回 values[0] + values[1]
结束 方法
结束 类
方法 启动方法(): 整数
变量 updater: 数组更新器 = 加五()
变量 values: 整数[2] = [4, 6]
如果 updater.更新(values) != 15
返回 1
结束 如果
如果 values[0] != 9
返回 2
结束 如果
返回 0
结束 方法
SRC
cat > "$TMP/array-parameter-interface-en.ast" <<'SRC'
// aster:language=en
interface class ArrayUpdater {
fn update(values: i32[2]): i32;
}
class AddFive: ArrayUpdater {
fn update(values: i32[2]): i32 {
values[0] = values[0] + 5;
return values[0] + values[1];
}
}
fn main(): i32 {
let updater: ArrayUpdater = AddFive();
let values: i32[2] = [4, 6];
if (updater.update(values) != 15) { return 1; }
if (values[0] != 9) { return 2; }
return 0;
}
SRC
for array_interface_language in zh en; do
    "$ASTER_BIN" build-cn-obj --language "$array_interface_language" \
        "$TMP/array-parameter-interface-$array_interface_language.ast" \
        -o "$TMP/array-parameter-interface-$array_interface_language.o"
done

"$ASTER_BIN" build-obj "$ROOT/stdlib/aster_std.ast" -o "$TMP/aster_std.o"

cat > "$TMP/omitted-void-interface-zh.ast" <<'SRC'
// aster:language=zh
接口类 Ping
方法 ping()
方法 pingExplicit(): 空
结束 接口类
变量 count: 整数 = 0
类 Impl : Ping
方法 ping(): 空
count = count + 1
结束 方法
方法 pingExplicit()
count = count + 1
结束 方法
结束 类
方法 启动方法(): 整数
变量 value: Ping = Impl()
value.ping()
value.pingExplicit()
返回 count
结束 方法
SRC
cat > "$TMP/omitted-void-interface-en.ast" <<'SRC'
// aster:language=en
interface class Ping {
fn ping();
fn pingExplicit(): void;
}
let count: i32 = 0;
class Impl: Ping {
fn ping(): void { count = count + 1; }
fn pingExplicit() { count = count + 1; }
}
fn main(): i32 {
let value: Ping = Impl();
value.ping();
value.pingExplicit();
return count;
}
SRC
"$ASTER_BIN" build-cn-obj "$TMP/omitted-void-interface-zh.ast" \
    -o "$TMP/omitted-void-interface-zh.o"
"$ASTER_BIN" build-cn-obj --language en "$TMP/omitted-void-interface-en.ast" \
    -o "$TMP/omitted-void-interface-en.o"
cmp "$TMP/omitted-void-interface-zh.o" "$TMP/omitted-void-interface-en.o"
if [ "$CAN_RUN" -eq 1 ]; then
    "$ASTER_BIN" link-obj "$TMP/omitted-void-interface-zh.o" "$TMP/aster_std.o" \
        -o "$TMP/omitted-void-interface"
    if "$RUNNER" "$TMP/omitted-void-interface"; then status=0; else status=$?; fi
    [ "$status" -eq 2 ]
fi

if [ "$CAN_RUN" -eq 1 ]; then
    "$ASTER_BIN" link-obj "$TMP/interface-zh.o" "$TMP/aster_std.o" -o "$TMP/interface-zh"
    "$ASTER_BIN" link-obj "$TMP/interface-en.o" "$TMP/aster_std.o" -o "$TMP/interface-en"
    if "$RUNNER" "$TMP/interface-zh"; then status=0; else status=$?; fi
    [ "$status" -eq 120 ]
    if "$RUNNER" "$TMP/interface-en"; then status=0; else status=$?; fi
    [ "$status" -eq 120 ]

    cat > "$TMP/interface-storage-zh.ast" <<'SRC'
// aster:language=zh
接口类 可取值
方法 获取(): 整数
结束 接口类
类 项目 : 可取值
方法 获取(): 整数
返回 21
结束 方法
结束 类
结构 结构容器
值: 可取值
列表: 可取值[2]
结束 结构
类 类容器
变量 值: 可取值
变量 列表: 可取值[2]
结束 类
方法 启动方法(): 整数
变量 结构对象: 结构容器
结构对象.值 = 项目()
结构对象.列表[0] = 项目()
结构对象.列表[1] = 项目()
变量 类对象: 类容器 = 类容器()
类对象.值 = 项目()
类对象.列表[0] = 项目()
类对象.列表[1] = 项目()
返回 结构对象.值.获取() + 结构对象.列表[0].获取() + 结构对象.列表[1].获取() + 类对象.值.获取() + 类对象.列表[0].获取() + 类对象.列表[1].获取() - 126
结束 方法
SRC
    cat > "$TMP/interface-storage-en.ast" <<'SRC'
// aster:language=en
interface class Value {
fn get(): i32;
}
class Item: Value {
fn get(): i32 { return 21; }
}
struct StructHolder {
value: Value
values: Value[2]
}
class ClassHolder {
let value: Value;
let values: Value[2];
}
fn main(): i32 {
let structHolder: StructHolder;
structHolder.value = Item();
structHolder.values[0] = Item();
structHolder.values[1] = Item();
let classHolder: ClassHolder = ClassHolder();
classHolder.value = Item();
classHolder.values[0] = Item();
classHolder.values[1] = Item();
return structHolder.value.get() + structHolder.values[0].get() + structHolder.values[1].get() + classHolder.value.get() + classHolder.values[0].get() + classHolder.values[1].get() - 126;
}
SRC
    for language in zh en; do
        "$ASTER_BIN" build-cn-obj --language "$language" \
            "$TMP/interface-storage-$language.ast" \
            -o "$TMP/interface-storage-$language.o"
        "$ASTER_BIN" link-obj "$TMP/interface-storage-$language.o" \
            "$TMP/aster_std.o" -o "$TMP/interface-storage-$language"
        if "$RUNNER" "$TMP/interface-storage-$language"; then status=0; else status=$?; fi
        [ "$status" -eq 0 ] || {
            echo "FAIL: $language interface field and array storage result was $status, expected 0" >&2
            exit 1
        }
    done

    "$ASTER_BIN" link-obj "$TMP/array-parameter-interface-zh.o" \
        "$TMP/aster_std.o" -o "$TMP/array-parameter-interface-zh"
    "$ASTER_BIN" link-obj "$TMP/array-parameter-interface-en.o" \
        "$TMP/aster_std.o" -o "$TMP/array-parameter-interface-en"
    if "$RUNNER" "$TMP/array-parameter-interface-zh"; then status=0; else status=$?; fi
    [ "$status" -eq 0 ]
    if "$RUNNER" "$TMP/array-parameter-interface-en"; then status=0; else status=$?; fi
    [ "$status" -eq 0 ]

    cat > "$TMP/null-interface-zh.ast" <<'SRC'
// aster:language=zh
接口类 必需
方法 运行(): 整数
结束 接口类
类 可用 : 必需
方法 运行(): 整数
返回 1
结束 方法
结束 类
方法 启动方法(): 整数
变量 值: 必需
返回 值.运行()
结束 方法
SRC
    cat > "$TMP/null-interface-en.ast" <<'SRC'
// aster:language=en
interface class Required {
fn run(): i32;
}
class Available: Required {
fn run(): i32 { return 1; }
}
fn main(): i32 {
let value: Required;
return value.run();
}
SRC
    cat > "$TMP/null-returned-interface-zh.ast" <<'SRC'
// aster:language=zh
接口类 必需
方法 运行(): 整数
结束 接口类
类 可用 : 必需
方法 运行(): 整数
返回 1
结束 方法
结束 类
方法 返回空接口(): 必需
返回 空
结束 方法
方法 启动方法(): 整数
返回 返回空接口().运行()
结束 方法
SRC
    cat > "$TMP/null-returned-interface-en.ast" <<'SRC'
// aster:language=en
interface class Required {
fn run(): i32;
}
class Available: Required {
fn run(): i32 { return 1; }
}
fn empty(): Required { return null; }
fn main(): i32 { return empty().run(); }
SRC
    for language in zh en; do
        "$ASTER_BIN" build-cn-obj --language "$language" \
            "$TMP/null-interface-$language.ast" \
            -o "$TMP/null-interface-$language.o"
        "$ASTER_BIN" link-obj "$TMP/null-interface-$language.o" \
            "$TMP/aster_std.o" -o "$TMP/null-interface-$language"
        if "$RUNNER" "$TMP/null-interface-$language"; then status=0; else status=$?; fi
        [ "$status" -eq 133 ]

        "$ASTER_BIN" build-cn-obj --language "$language" \
            "$TMP/null-returned-interface-$language.ast" \
            -o "$TMP/null-returned-interface-$language.o"
        "$ASTER_BIN" link-obj "$TMP/null-returned-interface-$language.o" \
            "$TMP/aster_std.o" -o "$TMP/null-returned-interface-$language"
        if "$RUNNER" "$TMP/null-returned-interface-$language"; then status=0; else status=$?; fi
        [ "$status" -eq 133 ]
    done

    mkdir -p "$TMP/app" "$TMP/packages"
    cat > "$TMP/packages/chinese.ast" <<'SRC'
// aster:language=zh
包名 test.chinese
接口类 可读
方法 读取(): 整数
结束 接口类
类 项目 : 可读
方法 读取(): 整数
返回 17
结束 方法
结束 类
SRC
    cat > "$TMP/app/call-chinese.ast" <<'SRC'
// aster:language=en
@import("test.chinese").alias("cn")
fn main(): i32 {
let reader: cn.可读 = cn.项目();
return reader.读取();
}
SRC
    "$ASTER_BIN" build-cn-obj --language en --module-dir "$TMP/packages" \
        "$TMP/app/call-chinese.ast" -o "$TMP/call-chinese.o"
    "$ASTER_BIN" link-obj "$TMP/call-chinese.o" "$TMP/aster_std.o" -o "$TMP/call-chinese"
    if "$RUNNER" "$TMP/call-chinese"; then status=0; else status=$?; fi
    [ "$status" -eq 17 ]

    cat > "$TMP/packages/english.ast" <<'SRC'
// aster:language=en
package test.english;
interface class Reader {
fn read(): i32;
}
class Item: Reader {
fn read(): i32 { return 29; }
}
SRC
    cat > "$TMP/app/call-english.ast" <<'SRC'
// aster:language=zh
@导入("test.english").别名("en")
方法 启动方法(): 整数
变量 reader: en.Reader = en.Item()
返回 reader.read()
结束 方法
SRC
    "$ASTER_BIN" build-cn-obj --language zh --module-dir "$TMP/packages" \
        "$TMP/app/call-english.ast" -o "$TMP/call-english.o"
    "$ASTER_BIN" link-obj "$TMP/call-english.o" "$TMP/aster_std.o" -o "$TMP/call-english"
    if "$RUNNER" "$TMP/call-english"; then status=0; else status=$?; fi
    [ "$status" -eq 29 ]
else
    echo 'SKIP: interface execution requires qemu-aarch64 or AArch64 Linux'
fi

cat > "$TMP/non-implementer.ast" <<'SRC'
// aster:language=zh
接口类 Required
方法 run(): 整数
结束 接口类
类 Unrelated
结束 类
方法 启动方法(): 整数
变量 value: Required = Unrelated()
返回 0
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/non-implementer.ast" \
    -o "$TMP/non-implementer.o" >"$TMP/non-implementer.log" 2>&1; then
    echo 'FAIL: a class without the interface contract compiled' >&2
    exit 1
fi
rg -q "does not implement interface Required" "$TMP/non-implementer.log"

cat > "$TMP/unknown-interface-method.ast" <<'SRC'
// aster:language=zh
接口类 Required
方法 run(): 整数
结束 接口类
方法 启动方法(): 整数
变量 value: Required
返回 value.missing()
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/unknown-interface-method.ast" \
    -o "$TMP/unknown-interface-method.o" >"$TMP/unknown-interface-method.log" 2>&1; then
    echo 'FAIL: a call to a missing interface method compiled' >&2
    exit 1
fi
rg -q "unknown interface method: missing" "$TMP/unknown-interface-method.log"

cat > "$TMP/mismatched-interface-implementation.ast" <<'SRC'
// aster:language=zh
接口类 Required
方法 run(): 整数
结束 接口类
类 Broken : Required
方法 run(): 逻辑型
返回 假
结束 方法
结束 类
方法 启动方法(): 整数
返回 0
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/mismatched-interface-implementation.ast" \
    -o "$TMP/mismatched-interface-implementation.o" \
    >"$TMP/mismatched-interface-implementation.log" 2>&1; then
    echo 'FAIL: a method with the wrong interface signature compiled' >&2
    exit 1
fi
rg -q "class method signature does not match interface" \
    "$TMP/mismatched-interface-implementation.log"

cat > "$TMP/interface-compare.ast" <<'SRC'
// aster:language=zh
接口类 Value
方法 get(): 整数
结束 接口类
方法 启动方法(): 整数
变量 value: Value
返回 value == 空
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/interface-compare.ast" \
    -o "$TMP/interface-compare.o" >"$TMP/interface-compare.log" 2>&1; then
    echo 'FAIL: interface values were accepted by scalar comparison' >&2
    exit 1
fi
rg -q "comparison" "$TMP/interface-compare.log"

echo 'PASS: bilingual interface reference and dispatch checks'
