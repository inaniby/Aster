#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ASTER_BIN=${ASTER_BIN:-$ROOT/.tmp-ci/adapter/aster-virtual-strict}
if [ ! -x "$ASTER_BIN" ]; then
    echo "set ASTER_BIN to a built Aster executable" >&2
    exit 2
fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

cat > "$TMP/override-zh.ast" <<'SRC'
// aster:language=zh
类 基类
变量 已观察: 整数
@构造
方法 初始化(): 空
本对象.已观察 = 本对象.取值()
结束 方法
方法 取值(): 整数
返回 10
结束 方法
结束 类
类 子类 : 基类
@重写
方法 取值(): 整数
返回 20
结束 方法
方法 父值(): 整数
返回 父对象.取值()
结束 方法
结束 类
类 空类
结束 类
接口类 可取值
方法 获取(): 整数
结束 接口类
类 接口基 : 可取值
方法 获取(): 整数
返回 30
结束 方法
结束 类
类 接口派生 : 接口基
@重写
方法 获取(): 整数
返回 40
结束 方法
结束 类
方法 读取(对象: 基类): 整数
返回 对象.取值()
结束 方法
方法 读取接口(对象: 可取值): 整数
返回 对象.获取()
结束 方法
方法 读取基类接口(对象: 接口基): 整数
返回 读取接口(对象)
结束 方法
变量 制造次数: 整数 = 0
方法 制造(): 子类
制造次数 = 制造次数 + 1
返回 子类()
结束 方法
方法 启动方法(): 整数
变量 对象: 子类 = 子类()
变量 空对象: 空类 = 空类()
返回 读取(对象) + 对象.父值() + 对象.取值() + 对象.已观察 + 制造().取值() + 制造次数 + 读取接口(接口派生()) + 读取基类接口(接口派生())
结束 方法
SRC

cat > "$TMP/override-en.ast" <<'SRC'
// aster:language=en
class Base {
let observed: i32;
@constructor
fn initialize(): void { this.observed = this.value(); }
fn value(): i32 { return 10; }
}
class Child: Base {
@override
fn value(): i32 { return 20; }
fn parentValue(): i32 { return super.value(); }
}
class Empty {}
interface class Value {
fn get(): i32;
}
class InterfaceBase: Value {
fn get(): i32 { return 30; }
}
class InterfaceChild: InterfaceBase {
@override
fn get(): i32 { return 40; }
}
fn read(object: Base): i32 { return object.value(); }
fn readInterface(object: Value): i32 { return object.get(); }
fn readBaseInterface(object: InterfaceBase): i32 { return readInterface(object); }
let makeCount: i32 = 0;
fn make(): Child { makeCount = makeCount + 1; return Child(); }
fn main(): i32 {
let object: Child = Child();
let emptyObject: Empty = Empty();
return read(object) + object.parentValue() + object.value() + object.observed + make().value() + makeCount + readInterface(InterfaceChild()) + readBaseInterface(InterfaceChild());
}
SRC

"$ASTER_BIN" build-cn-obj "$TMP/override-zh.ast" -o "$TMP/override-zh.o"
"$ASTER_BIN" build-cn-obj --language en "$TMP/override-en.ast" -o "$TMP/override-en.o"
"$ASTER_BIN" build-obj "$ROOT/stdlib/aster_std.ast" -o "$TMP/aster_std.o"

if [ "$(uname -s)" = Linux ] && [ "$(uname -m)" = aarch64 ]; then
    for language in zh en; do
        "$ASTER_BIN" link-obj "$TMP/override-$language.o" "$TMP/aster_std.o" \
            -o "$TMP/override-$language"
        if "$TMP/override-$language"; then status=0; else status=$?; fi
        [ "$status" -eq 161 ]
    done
else
    echo 'SKIP: override execution requires AArch64 Linux'
fi

cat > "$TMP/static-fields-zh.ast" <<'SRC'
// aster:language=zh
类 计数器
@静态
变量 值: 整数 = 4
@静态
变量 初始值: 整数
@静态
变量 值列表: 整数[2] = [7, 8]
@静态
方法 增加(): 整数
计数器.值 = 计数器.值 + 1
返回 计数器.值
结束 方法
@静态
方法 增加数组首项(): 整数
计数器.值列表[0] = 计数器.值列表[0] + 1
返回 计数器.值列表[0]
结束 方法
方法 读取(): 整数
返回 计数器.值
结束 方法
结束 类
类 派生计数器 : 计数器
结束 类
方法 启动方法(): 整数
变量 第一个: 计数器 = 计数器()
变量 第二个: 计数器 = 计数器()
返回 计数器.增加() + 派生计数器.值 + 第一个.读取() + 第二个.读取() + 计数器.初始值 + 计数器.增加数组首项() + 派生计数器.值列表[0] + 计数器.值列表[1] - 24
结束 方法
SRC

cat > "$TMP/static-fields-en.ast" <<'SRC'
// aster:language=en
class Counter {
@static
let value: i32 = 4;
@static
let baseline: i32;
@static
let values: i32[2] = [7, 8];
@static
fn increment(): i32 {
Counter.value = Counter.value + 1;
return Counter.value;
}
@static
fn incrementFirst(): i32 {
Counter.values[0] = Counter.values[0] + 1;
return Counter.values[0];
}
fn read(): i32 { return Counter.value; }
}
class DerivedCounter: Counter {}
fn main(): i32 {
let first: Counter = Counter();
let second: Counter = Counter();
return Counter.increment() + DerivedCounter.value + first.read() + second.read() + Counter.baseline + Counter.incrementFirst() + DerivedCounter.values[0] + Counter.values[1] - 24;
}
SRC

for language in zh en; do
    if [ "$language" = zh ]; then
        "$ASTER_BIN" build-cn-obj "$TMP/static-fields-zh.ast" -o "$TMP/static-fields-$language.o"
    else
        "$ASTER_BIN" build-cn-obj --language en "$TMP/static-fields-en.ast" \
            -o "$TMP/static-fields-$language.o"
    fi
    if [ "$(uname -s)" = Linux ] && [ "$(uname -m)" = aarch64 ]; then
        "$ASTER_BIN" link-obj "$TMP/static-fields-$language.o" "$TMP/aster_std.o" \
            -o "$TMP/static-fields-$language"
        if "$TMP/static-fields-$language"; then status=0; else status=$?; fi
        [ "$status" -eq 20 ] || {
            echo "FAIL: $language static field result was $status, expected 20" >&2
            exit 1
        }
    fi
done

cat > "$TMP/static-struct-field-zh.ast" <<'SRC'
// aster:language=zh
结构 点
    横: 整数
    纵: 整数
结束 结构
结构 带标签点
    标签: 字符串
    数值: 整数
结束 结构
类 静态点
@静态
变量 初始点: 点 = 点 { 7, 8 }
@静态
变量 默认点: 点
@静态
变量 带标签: 带标签点 = 带标签点 { "ok", 5 }
@静态
变量 点列表: 点[2] = [点 { 1, 2 }, 点 { 3, 4 }]
@静态
变量 默认列表: 点[2]
结束 类
方法 启动方法(): 整数
静态点.初始点.横 = 20
静态点.点列表[1].横 = 9
返回 静态点.初始点.横 + 静态点.初始点.纵 + 静态点.默认点.横 + 静态点.默认点.纵 + 静态点.带标签.数值 + 静态点.点列表[1].横 + 静态点.点列表[1].纵 + 静态点.默认列表[0].横 + 静态点.默认列表[0].纵
结束 方法
SRC

cat > "$TMP/static-struct-field-en.ast" <<'SRC'
// aster:language=en
struct Point { x: i32, y: i32 }
struct LabeledPoint { label: string, value: i32 }
class StaticPoint {
@static
let initialized: Point = Point { 7, 8 };
@static
let defaultPoint: Point;
@static
let labeled: LabeledPoint = LabeledPoint { "ok", 5 };
@static
let points: Point[2] = [Point { 1, 2 }, Point { 3, 4 }];
@static
let defaultPoints: Point[2];
}
fn main(): i32 {
StaticPoint.initialized.x = 20;
StaticPoint.points[1].x = 9;
return StaticPoint.initialized.x + StaticPoint.initialized.y + StaticPoint.defaultPoint.x + StaticPoint.defaultPoint.y + StaticPoint.labeled.value + StaticPoint.points[1].x + StaticPoint.points[1].y + StaticPoint.defaultPoints[0].x + StaticPoint.defaultPoints[0].y;
}
SRC

for language in zh en; do
    if [ "$language" = zh ]; then
        "$ASTER_BIN" build-cn-obj "$TMP/static-struct-field-zh.ast" \
            -o "$TMP/static-struct-field-$language.o"
    else
        "$ASTER_BIN" build-cn-obj --language en "$TMP/static-struct-field-en.ast" \
            -o "$TMP/static-struct-field-$language.o"
    fi
    "$ASTER_BIN" link-obj "$TMP/static-struct-field-$language.o" \
        -o "$TMP/static-struct-field-$language"
    if "$TMP/static-struct-field-$language"; then status=0; else status=$?; fi
    [ "$status" -eq 46 ] || {
        echo "FAIL: $language static struct field result was $status, expected 46" >&2
        exit 1
    }
done

cat > "$TMP/static-function-field-zh.ast" <<'SRC'
// aster:language=zh
方法 加二(值: 整数): 整数
返回 值 + 2
结束 方法
类 静态回调
@静态
变量 回调: 方法(整数): 整数 = 加二
@静态
方法 运行(值: 整数): 整数
返回 静态回调.回调(值)
结束 方法
结束 类
类 派生静态回调 : 静态回调
结束 类
方法 启动方法(): 整数
返回 派生静态回调.运行(40)
结束 方法
SRC

cat > "$TMP/static-function-field-en.ast" <<'SRC'
// aster:language=en
fn addTwo(value: i32): i32 { return value + 2; }
class StaticCallback {
@static
let callback: fn(i32): i32 = addTwo;
@static
fn run(value: i32): i32 { return StaticCallback.callback(value); }
}
class DerivedStaticCallback: StaticCallback {}
fn main(): i32 { return DerivedStaticCallback.run(40); }
SRC

for language in zh en; do
    if [ "$language" = zh ]; then
        "$ASTER_BIN" build-cn-obj "$TMP/static-function-field-zh.ast" \
            -o "$TMP/static-function-field-$language.o"
    else
        "$ASTER_BIN" build-cn-obj --language en "$TMP/static-function-field-en.ast" \
            -o "$TMP/static-function-field-$language.o"
    fi
    "$ASTER_BIN" link-obj "$TMP/static-function-field-$language.o" \
        -o "$TMP/static-function-field-$language"
    if "$TMP/static-function-field-$language"; then status=0; else status=$?; fi
    [ "$status" -eq 42 ] || {
        echo "FAIL: $language static function field result was $status, expected 42" >&2
        exit 1
    }
done

cat > "$TMP/null-class-zh.ast" <<'SRC'
// aster:language=zh
类 盒子
方法 运行(): 整数
返回 1
结束 方法
结束 类
方法 启动方法(): 整数
变量 值: 盒子
返回 值.运行()
结束 方法
SRC

cat > "$TMP/null-class-en.ast" <<'SRC'
// aster:language=en
class Box {
fn run(): i32 { return 1; }
}
fn main(): i32 {
let value: Box;
return value.run();
}
SRC

if [ "$(uname -s)" = Linux ] && [ "$(uname -m)" = aarch64 ]; then
    for language in zh en; do
        "$ASTER_BIN" build-cn-obj --language "$language" \
            "$TMP/null-class-$language.ast" -o "$TMP/null-class-$language.o"
        "$ASTER_BIN" link-obj "$TMP/null-class-$language.o" \
            -o "$TMP/null-class-$language"
        if "$TMP/null-class-$language"; then status=0; else status=$?; fi
        [ "$status" -eq 133 ] || {
            echo "FAIL: $language null class method call exited $status, expected 133" >&2
            exit 1
        }
    done
else
    echo 'SKIP: null class execution requires AArch64 Linux'
fi

cat > "$TMP/null-returned-class-zh.ast" <<'SRC'
// aster:language=zh
类 盒子
方法 运行(): 整数
返回 1
结束 方法
结束 类
方法 空盒子(): 盒子
返回 空
结束 方法
方法 启动方法(): 整数
返回 空盒子().运行()
结束 方法
SRC

cat > "$TMP/null-returned-class-en.ast" <<'SRC'
// aster:language=en
class Box {
fn run(): i32 { return 1; }
}
fn empty(): Box { return null; }
fn main(): i32 { return empty().run(); }
SRC

if [ "$(uname -s)" = Linux ] && [ "$(uname -m)" = aarch64 ]; then
    for language in zh en; do
        "$ASTER_BIN" build-cn-obj --language "$language" \
            "$TMP/null-returned-class-$language.ast" \
            -o "$TMP/null-returned-class-$language.o"
        "$ASTER_BIN" link-obj "$TMP/null-returned-class-$language.o" \
            -o "$TMP/null-returned-class-$language"
        if "$TMP/null-returned-class-$language"; then status=0; else status=$?; fi
        [ "$status" -eq 133 ] || {
            echo "FAIL: $language returned-null class method call exited $status, expected 133" >&2
            exit 1
        }
    done
else
    echo 'SKIP: returned-null class execution requires AArch64 Linux'
fi

cat > "$TMP/null-class-field-zh.ast" <<'SRC'
// aster:language=zh
类 盒子
变量 值: 整数
结束 类
方法 启动方法(): 整数
变量 盒子对象: 盒子
返回 盒子对象.值
结束 方法
SRC

cat > "$TMP/null-class-field-en.ast" <<'SRC'
// aster:language=en
class Box { let value: i32; }
fn main(): i32 {
let box: Box;
return box.value;
}
SRC

cat > "$TMP/null-class-field-write-zh.ast" <<'SRC'
// aster:language=zh
类 盒子
变量 值: 整数
结束 类
方法 启动方法(): 整数
变量 盒子对象: 盒子
盒子对象.值 = 1
返回 0
结束 方法
SRC

cat > "$TMP/null-class-field-write-en.ast" <<'SRC'
// aster:language=en
class Box { let value: i32; }
fn main(): i32 {
let box: Box;
box.value = 1;
return 0;
}
SRC

cat > "$TMP/null-class-field-call-zh.ast" <<'SRC'
// aster:language=zh
类 盒子
变量 回调: 方法(整数): 整数
结束 类
方法 启动方法(): 整数
变量 盒子对象: 盒子
返回 盒子对象.回调(1)
结束 方法
SRC

cat > "$TMP/null-class-field-call-en.ast" <<'SRC'
// aster:language=en
class Box { let callback: fn(i32): i32; }
fn main(): i32 {
let box: Box;
return box.callback(1);
}
SRC

cat > "$TMP/null-class-returned-field-zh.ast" <<'SRC'
// aster:language=zh
类 盒子
变量 值: 整数
结束 类
方法 空盒子(): 盒子
返回 空
结束 方法
方法 启动方法(): 整数
返回 空盒子().值
结束 方法
SRC

cat > "$TMP/null-class-returned-field-en.ast" <<'SRC'
// aster:language=en
class Box { let value: i32; }
fn empty(): Box { return null; }
fn main(): i32 { return empty().value; }
SRC

cat > "$TMP/null-class-field-array-zh.ast" <<'SRC'
// aster:language=zh
类 盒子
变量 数值: 整数[1]
结束 类
方法 启动方法(): 整数
变量 盒子对象: 盒子
返回 盒子对象.数值[0]
结束 方法
SRC

cat > "$TMP/null-class-field-array-en.ast" <<'SRC'
// aster:language=en
class Box { let values: i32[1]; }
fn main(): i32 {
let box: Box;
return box.values[0];
}
SRC

cat > "$TMP/null-class-field-array-write-zh.ast" <<'SRC'
// aster:language=zh
类 盒子
变量 数值: 整数[1]
结束 类
方法 启动方法(): 整数
变量 盒子对象: 盒子
盒子对象.数值[0] = 1
返回 0
结束 方法
SRC

cat > "$TMP/null-class-field-array-write-en.ast" <<'SRC'
// aster:language=en
class Box { let values: i32[1]; }
fn main(): i32 {
let box: Box;
box.values[0] = 1;
return 0;
}
SRC

if [ "$(uname -s)" = Linux ] && [ "$(uname -m)" = aarch64 ]; then
    for operation in field field-write field-call returned-field field-array field-array-write; do
        for language in zh en; do
            "$ASTER_BIN" build-cn-obj --language "$language" \
                "$TMP/null-class-$operation-$language.ast" \
                -o "$TMP/null-class-$operation-$language.o"
            "$ASTER_BIN" link-obj "$TMP/null-class-$operation-$language.o" \
                -o "$TMP/null-class-$operation-$language"
            if "$TMP/null-class-$operation-$language"; then status=0; else status=$?; fi
            [ "$status" -eq 133 ] || {
                echo "FAIL: $language null class $operation exited $status, expected 133" >&2
                exit 1
            }
        done
    done
else
    echo 'SKIP: null class field execution requires AArch64 Linux'
fi

cat > "$TMP/static-function-array-en.ast" <<'SRC'
// aster:language=en
fn addTwo(value: i32): i32 { return value + 2; }
fn addThree(value: i32): i32 { return value + 3; }
class StaticCallback {
@static
let callbacks: fn(i32): i32[2] = [addTwo, addThree];
}
fn main(): i32 {
StaticCallback.callbacks[0] = addThree;
return StaticCallback.callbacks[0](40) + StaticCallback.callbacks[1](40);
}
SRC
"$ASTER_BIN" build-cn-obj --language en "$TMP/static-function-array-en.ast" \
    -o "$TMP/static-function-array-en.o"
"$ASTER_BIN" link-obj "$TMP/static-function-array-en.o" \
    -o "$TMP/static-function-array-en"
if "$TMP/static-function-array-en"; then status=0; else status=$?; fi
[ "$status" -eq 86 ] || {
    echo "FAIL: English static function pointer array exited $status, expected 86" >&2
    exit 1
}

cat > "$TMP/static-function-array-zh.ast" <<'SRC'
// aster:language=zh
方法 加二(值: 整数): 整数
返回 值 + 2
结束 方法
方法 加三(值: 整数): 整数
返回 值 + 3
结束 方法
类 静态回调
@静态
变量 回调们: 方法(整数): 整数[2] = [加二, 加三]
结束 类
方法 启动方法(): 整数
静态回调.回调们[0] = 加三
返回 静态回调.回调们[0](40) + 静态回调.回调们[1](40)
结束 方法
SRC
"$ASTER_BIN" build-cn-obj --language zh "$TMP/static-function-array-zh.ast" \
    -o "$TMP/static-function-array-zh.o"
"$ASTER_BIN" link-obj "$TMP/static-function-array-zh.o" \
    -o "$TMP/static-function-array-zh"
if "$TMP/static-function-array-zh"; then status=0; else status=$?; fi
[ "$status" -eq 86 ] || {
    echo "FAIL: Chinese static function pointer array exited $status, expected 86" >&2
    exit 1
}

cat > "$TMP/static-function-array-bad.ast" <<'SRC'
// aster:language=en
fn addTwo(value: i32): i32 { return value + 2; }
fn wrong(): i32 { return 0; }
class StaticCallback {
@static
let callbacks: fn(i32): i32[2] = [addTwo, wrong];
}
fn main(): i32 { return 0; }
SRC
if "$ASTER_BIN" build-cn-obj --language en "$TMP/static-function-array-bad.ast" \
    -o "$TMP/static-function-array-bad.o" >"$TMP/static-function-array-bad.log" 2>&1; then
    echo 'FAIL: mismatched static function pointer array element was accepted' >&2
    exit 1
fi
rg -q 'static function pointer array element signature mismatch|function signature mismatch initializing class field' \
    "$TMP/static-function-array-bad.log"

cat > "$TMP/static-function-array-bad-store.ast" <<'SRC'
// aster:language=en
fn addTwo(value: i32): i32 { return value + 2; }
fn wrong(): i32 { return 0; }
class StaticCallback {
@static
let callbacks: fn(i32): i32[2] = [addTwo, addTwo];
}
fn main(): i32 {
StaticCallback.callbacks[0] = wrong;
return 0;
}
SRC
if "$ASTER_BIN" build-cn-obj --language en "$TMP/static-function-array-bad-store.ast" \
    -o "$TMP/static-function-array-bad-store.o" >"$TMP/static-function-array-bad-store.log" 2>&1; then
    echo 'FAIL: mismatched static function pointer array store was accepted' >&2
    exit 1
fi
rg -q "type mismatch assigning function pointer array element" \
    "$TMP/static-function-array-bad-store.log"

cat > "$TMP/instance-function-array-en.ast" <<'SRC'
// aster:language=en
struct CallbackBox {
    callbacks: fn(i32): i32[2]
}
fn addTwo(value: i32): i32 { return value + 2; }
fn addThree(value: i32): i32 { return value + 3; }
class InstanceCallback {
let callbacks: fn(i32): i32[2] = [addTwo, addThree];
}
fn main(): i32 {
let object: InstanceCallback = InstanceCallback();
let box: CallbackBox;
box.callbacks[1] = addTwo;
return object.callbacks[0](40) + box.callbacks[1](40);
}
SRC
cat > "$TMP/instance-function-array-zh.ast" <<'SRC'
// aster:language=zh
结构 回调盒
    回调们: 方法(整数): 整数[2]
结束 结构
方法 加二(值: 整数): 整数
    返回 值 + 2
结束 方法
方法 加三(值: 整数): 整数
    返回 值 + 3
结束 方法
类 实例回调
变量 回调们: 方法(整数): 整数[2] = [加二, 加三]
结束 类
方法 启动方法(): 整数
    变量 对象: 实例回调 = 实例回调()
    变量 盒: 回调盒
    盒.回调们[1] = 加二
    返回 对象.回调们[0](40) + 盒.回调们[1](40)
结束 方法
SRC
for language in zh en; do
    "$ASTER_BIN" build-cn-obj --language "$language" \
        "$TMP/instance-function-array-$language.ast" \
        -o "$TMP/instance-function-array-$language.o"
    if [ "$(uname -s)" = Linux ] && [ "$(uname -m)" = aarch64 ]; then
        "$ASTER_BIN" link-obj "$TMP/instance-function-array-$language.o" "$TMP/aster_std.o" \
            -o "$TMP/instance-function-array-$language"
        if "$TMP/instance-function-array-$language"; then status=0; else status=$?; fi
        [ "$status" -eq 84 ] || {
            echo "FAIL: $language instance/structure function pointer array result was $status, expected 84" >&2
            exit 1
        }
    fi
done

cat > "$TMP/static-string-array-en.ast" <<'SRC'
// aster:language=en
class StaticText {
@static
let labels: string[2] = ["first", "second"];
@static
let empty: string[2];
}
fn main(): i32 {
StaticText.labels[1] = "changed";
if (StaticText.labels[0] == "first") {
if (StaticText.labels[1] == "changed" && StaticText.empty[0] == "") { return 3; }
}
return 0;
}
SRC
"$ASTER_BIN" build-cn-obj --language en "$TMP/static-string-array-en.ast" \
    -o "$TMP/static-string-array-en.o"
"$ASTER_BIN" link-obj "$TMP/static-string-array-en.o" \
    -o "$TMP/static-string-array-en"
if "$TMP/static-string-array-en"; then status=0; else status=$?; fi
[ "$status" -eq 3 ] || {
    echo "FAIL: English static string array exited $status, expected 3" >&2
    exit 1
}

cat > "$TMP/static-string-array-zh.ast" <<'SRC'
// aster:language=zh
类 静态文本
@静态
变量 标签: 字符串[2] = ["第一个", "第二个"]
@静态
变量 空标签: 字符串[2]
结束 类
方法 启动方法(): 整数
静态文本.标签[1] = "改过"
如果 静态文本.标签[0] == "第一个"
如果 静态文本.空标签[0] == ""
如果 静态文本.标签[1] == "改过"
返回 3
结束 如果
结束 如果
结束 如果
返回 0
结束 方法
SRC
"$ASTER_BIN" build-cn-obj --language zh "$TMP/static-string-array-zh.ast" \
    -o "$TMP/static-string-array-zh.o"
"$ASTER_BIN" link-obj "$TMP/static-string-array-zh.o" \
    -o "$TMP/static-string-array-zh"
if "$TMP/static-string-array-zh"; then status=0; else status=$?; fi
[ "$status" -eq 3 ] || {
    echo "FAIL: Chinese static string array exited $status, expected 3" >&2
    exit 1
}

cat > "$TMP/object-static-field.ast" <<'SRC'
// aster:language=en
class Counter {
@static
let value: i32 = 4;
fn read(object: Counter): i32 { return object.value; }
}
fn main(): i32 { return 0; }
SRC
if "$ASTER_BIN" build-cn-obj --language en "$TMP/object-static-field.ast" \
    -o "$TMP/object-static-field.o" >"$TMP/object-static-field.log" 2>&1; then
    echo 'FAIL: a static field was accepted through an object' >&2
    exit 1
fi
rg -q 'static field must be accessed through a class name' "$TMP/object-static-field.log"

cat > "$TMP/class-instance-field.ast" <<'SRC'
// aster:language=en
class Box { let value: i32; }
fn main(): i32 { return Box.value; }
SRC
if "$ASTER_BIN" build-cn-obj --language en "$TMP/class-instance-field.ast" \
    -o "$TMP/class-instance-field.o" >"$TMP/class-instance-field.log" 2>&1; then
    echo 'FAIL: an instance field was accepted through a class name' >&2
    exit 1
fi
rg -q 'instance field must be accessed through an object' "$TMP/class-instance-field.log"

cat > "$TMP/object-static-array.ast" <<'SRC'
// aster:language=en
class Counter {
@static
let values: i32[2] = [1, 2];
fn read(object: Counter): i32 { return object.values[0]; }
}
fn main(): i32 { return 0; }
SRC
if "$ASTER_BIN" build-cn-obj --language en "$TMP/object-static-array.ast" \
    -o "$TMP/object-static-array.o" >"$TMP/object-static-array.log" 2>&1; then
    echo 'FAIL: a static array field was accepted through an object' >&2
    exit 1
fi
rg -q 'static array field must be accessed through a class name' \
    "$TMP/object-static-array.log"

cat > "$TMP/bad-signature.ast" <<'SRC'
// aster:language=en
class Base { fn value(): i32 { return 1; } }
class Child: Base {
@override
fn value(x: i32): i32 { return x; }
}
fn main(): i32 { return 0; }
SRC
if "$ASTER_BIN" build-cn-obj --language en "$TMP/bad-signature.ast" \
    -o "$TMP/bad-signature.o" >"$TMP/bad-signature.log" 2>&1; then
    echo 'FAIL: an override with a different signature was accepted' >&2
    exit 1
fi
rg -q 'override signature does not match inherited method' "$TMP/bad-signature.log"

cat > "$TMP/missing-annotation.ast" <<'SRC'
// aster:language=en
class Base { fn value(): i32 { return 1; } }
class Child: Base { fn value(): i32 { return 2; } }
fn main(): i32 { return 0; }
SRC
if "$ASTER_BIN" build-cn-obj --language en "$TMP/missing-annotation.ast" \
    -o "$TMP/missing-annotation.o" >"$TMP/missing-annotation.log" 2>&1; then
    echo 'FAIL: an override without an annotation was accepted' >&2
    exit 1
fi
rg -q 'requires @override' "$TMP/missing-annotation.log"

cat > "$TMP/no-parent-method.ast" <<'SRC'
// aster:language=zh
类 独立
@重写
方法 取值(): 整数
返回 1
结束 方法
结束 类
方法 启动方法(): 整数
返回 0
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/no-parent-method.ast" \
    -o "$TMP/no-parent-method.o" >"$TMP/no-parent-method.log" 2>&1; then
    echo 'FAIL: @重写 without a parent method was accepted' >&2
    exit 1
fi
rg -q 'no inherited method exists' "$TMP/no-parent-method.log"

cat > "$TMP/static-override.ast" <<'SRC'
// aster:language=en
class Base {
@static
fn value(): i32 { return 1; }
}
class Child: Base {
@override
@static
fn value(): i32 { return 2; }
}
fn main(): i32 { return 0; }
SRC
if "$ASTER_BIN" build-cn-obj --language en "$TMP/static-override.ast" \
    -o "$TMP/static-override.o" >"$TMP/static-override.log" 2>&1; then
    echo 'FAIL: a static method was accepted as an override' >&2
    exit 1
fi
rg -q 'static methods and constructors cannot be overridden' "$TMP/static-override.log"
echo 'PASS: bilingual class override, dynamic dispatch, and static field checks'
