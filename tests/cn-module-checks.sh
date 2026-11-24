#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ASTER_BIN=${ASTER_BIN:-$ROOT/build/cn-s1-s2/aster}
RUNNER=${RUNNER:-$ROOT/tests/run-aarch64.sh}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

mkdir -p "$TMP/app" "$TMP/packages"
cat > "$TMP/app/start-zh.ast" <<'SRC'
方法 启动方法(): 整数
返回 7
结束 方法
SRC
cat > "$TMP/app/start-en.ast" <<'SRC'
// aster:language=en
fn main(): i32 {
return 7;
}
SRC
echo '[entry] Chinese 启动方法 and English main produce the same entry object'
"$ASTER_BIN" build-cn-obj "$TMP/app/start-zh.ast" -o "$TMP/start-zh.o"
"$ASTER_BIN" build-cn-obj "$TMP/app/start-en.ast" -o "$TMP/start-en.o"
cmp "$TMP/start-zh.o" "$TMP/start-en.o"
"$ASTER_BIN" link-obj "$TMP/start-zh.o" -o "$TMP/start"
if "$RUNNER" "$TMP/start"; then status=0; else status=$?; fi
[ "$status" -eq 7 ] || { echo "FAIL: Chinese startup returned $status, expected 7" >&2; exit 1; }

mkdir -p "$TMP/project/src"
cat > "$TMP/project/aster.proj" <<'SRC'
name bilingual
[language]
default = "zh"
allowed = ["zh", "en"]
src/main.ast
src/helper.ast
SRC
cat > "$TMP/project/src/main.ast" <<'SRC'
方法 启动方法(): 整数
返回 加一(41) - 42
结束 方法
SRC
cat > "$TMP/project/src/helper.ast" <<'SRC'
// aster:language=en
fn 加一(value: i32): i32 {
return value + 1;
}
SRC
echo '[project build] existing build command compiles mixed-language sources'
(cd "$TMP/project" && "$ASTER_BIN" build)
if "$RUNNER" "$TMP/project/build/bilingual"; then status=0; else status=$?; fi
[ "$status" -eq 0 ] || { echo "FAIL: bilingual project build returned $status, expected 0" >&2; exit 1; }
(cd "$TMP/project" && "$ASTER_BIN" build > build-cache.log)
grep -q '0 compiled, 2 reused' "$TMP/project/build-cache.log" || {
    echo 'FAIL: bilingual project build did not reuse its cached object' >&2; cat "$TMP/project/build-cache.log" >&2; exit 1;
}
printf '\n' >> "$TMP/project/src/helper.ast"
(cd "$TMP/project" && "$ASTER_BIN" build > build-source-change.log)
grep -q '2 compiled, 0 reused' "$TMP/project/build-source-change.log" || {
    echo 'FAIL: bilingual source edit did not invalidate the project cache' >&2; cat "$TMP/project/build-source-change.log" >&2; exit 1;
}
(cd "$TMP/project" && "$ASTER_BIN" build --no-cache > build-no-cache.log)
grep -q '2 compiled, 0 reused' "$TMP/project/build-no-cache.log" || {
    echo 'FAIL: bilingual --no-cache did not rebuild the project' >&2; cat "$TMP/project/build-no-cache.log" >&2; exit 1;
}
if command -v readelf >/dev/null 2>&1; then
    (cd "$TMP/project" && "$ASTER_BIN" build -g >/dev/null)
    readelf -S "$TMP/project/build/bilingual" | grep -q '\.debug_line' || {
        echo 'FAIL: bilingual project build -g omitted .debug_line' >&2; exit 1; }
    readelf -S "$TMP/project/build/bilingual" | grep -q '\.debug_info' || {
        echo 'FAIL: bilingual project build -g omitted .debug_info' >&2; exit 1; }
fi

mkdir -p "$TMP/project-external/src" "$TMP/project-external-packages"
cat > "$TMP/project-external/aster.proj" <<'SRC'
name external
[language]
default = "zh"
allowed = ["zh", "en"]
src/main.ast
SRC
cat > "$TMP/project-external-packages/math.ast" <<'SRC'
// aster:language=en
package external.math;
fn add(value: i32): i32 {
return value + 1;
}
SRC
cat > "$TMP/project-external/src/main.ast" <<'SRC'
@导入("external.math").别名("math")
方法 启动方法(): 整数
返回 math.add(41) - 42
结束 方法
SRC
(cd "$TMP/project-external" && "$ASTER_BIN" build --module-dir "$TMP/project-external-packages" > external-build.log)
if "$RUNNER" "$TMP/project-external/build/external"; then status=0; else status=$?; fi
[ "$status" -eq 0 ] || { echo "FAIL: external package project returned $status, expected 0" >&2; exit 1; }
(cd "$TMP/project-external" && "$ASTER_BIN" build --module-dir "$TMP/project-external-packages" > external-cache.log)
grep -q '0 compiled, 1 reused' "$TMP/project-external/external-cache.log" || {
    echo 'FAIL: external package project did not reuse its cache' >&2; cat "$TMP/project-external/external-cache.log" >&2; exit 1;
}
(cd "$TMP/project-external" && "$ASTER_BIN" run --module-dir "$TMP/project-external-packages" > external-run.log)
if [ "$?" -ne 0 ]; then
    echo 'FAIL: bilingual project run with an external package failed' >&2
    cat "$TMP/project-external/external-run.log" >&2
    exit 1
fi
printf '\n' >> "$TMP/project-external-packages/math.ast"
(cd "$TMP/project-external" && "$ASTER_BIN" build --module-dir "$TMP/project-external-packages" > external-change.log)
grep -q '1 compiled, 0 reused' "$TMP/project-external/external-change.log" || {
    echo 'FAIL: external package edit did not invalidate project cache' >&2; cat "$TMP/project-external/external-change.log" >&2; exit 1;
}

mkdir -p "$TMP/external-abi/packages"
cat > "$TMP/external-abi/packages/text.ast" <<'SRC'
// aster:language=zh
包名 demo.文本
外部("puts") 方法 输出(值: 指针): 整数
SRC
cat > "$TMP/external-abi/main.ast" <<'SRC'
// aster:language=zh
@导入("demo.文本").别名("文")
方法 启动方法(): 整数
返回 文.输出(0)
结束 方法
SRC
"$ASTER_BIN" build-cn-obj --module-dir "$TMP/external-abi/packages" \
    "$TMP/external-abi/main.ast" -o "$TMP/external-abi/main.o"
if command -v readelf >/dev/null 2>&1; then
    readelf -Ws "$TMP/external-abi/main.o" | grep -E 'UND[[:space:]]+puts$' >/dev/null || {
        echo 'FAIL: imported Chinese external mapping did not preserve the ASCII ABI symbol' >&2; exit 1;
    }
fi

mkdir -p "$TMP/external-global-abi/packages"
cat > "$TMP/external-global-abi/packages/counter.ast" <<'SRC'
// aster:language=en
package external.counter;
extern let native_counter: i32;
extern let native_values: i32[2];
extern let native_callback: fn(i32): i32;
SRC
cat > "$TMP/external-global-abi/main.ast" <<'SRC'
// aster:language=zh
@导入("external.counter").别名("计数")
方法 启动方法(): 整数
计数.native_values[1] = 计数.native_values[0] + 1
返回 计数.native_callback(计数.native_counter) + 计数.native_values[1]
结束 方法
SRC
"$ASTER_BIN" build-cn-obj --module-dir "$TMP/external-global-abi/packages" \
    "$TMP/external-global-abi/main.ast" -o "$TMP/external-global-abi/main.o"
if command -v readelf >/dev/null 2>&1; then
    readelf -Ws "$TMP/external-global-abi/main.o" | grep -E 'UND[[:space:]]+native_counter$' >/dev/null || {
        echo 'FAIL: imported external global did not preserve the ASCII ABI symbol' >&2; exit 1;
    }
    readelf -Ws "$TMP/external-global-abi/main.o" | grep -E 'UND[[:space:]]+native_values$' >/dev/null || {
        echo 'FAIL: imported external global array did not preserve the ASCII ABI symbol' >&2; exit 1;
    }
    readelf -Ws "$TMP/external-global-abi/main.o" | grep -E 'UND[[:space:]]+native_callback$' >/dev/null || {
        echo 'FAIL: imported external function-pointer global did not preserve the ASCII ABI symbol' >&2; exit 1;
    }
fi

mkdir -p "$TMP/test-project/src" "$TMP/test-project/tests"
cat > "$TMP/test-project/aster.proj" <<'SRC'
name bilingual_tests
[language]
default = "zh"
allowed = ["zh", "en"]
src/lib.ast
test tests/basic.ast
SRC
cat > "$TMP/test-project/src/lib.ast" <<'SRC'
方法 加一(value: 整数): 整数
返回 value + 1
结束 方法
SRC
cat > "$TMP/test-project/tests/basic.ast" <<'SRC'
// aster:language=en
fn main(): i32 {
return 加一(41) - 42;
}
SRC
(cd "$TMP/test-project" && "$ASTER_BIN" test > test-first.log)
grep -q '2 compiled, 0 reused' "$TMP/test-project/test-first.log" || {
    echo 'FAIL: bilingual aster test did not compile its test object' >&2; cat "$TMP/test-project/test-first.log" >&2; exit 1;
}
(cd "$TMP/test-project" && "$ASTER_BIN" test > test-second.log)
grep -q '0 compiled, 2 reused' "$TMP/test-project/test-second.log" || {
    echo 'FAIL: bilingual aster test did not reuse its test object' >&2; cat "$TMP/test-project/test-second.log" >&2; exit 1;
}
printf '\n' >> "$TMP/test-project/tests/basic.ast"
(cd "$TMP/test-project" && "$ASTER_BIN" test > test-change.log)
grep -q '1 compiled, 1 reused' "$TMP/test-project/test-change.log" || {
    echo 'FAIL: bilingual aster test did not invalidate its cache after a test-source edit' >&2; cat "$TMP/test-project/test-change.log" >&2; exit 1;
}
mkdir -p "$TMP/test-project/modules-a" "$TMP/test-project/modules-b"
(cd "$TMP/test-project" && "$ASTER_BIN" test --module-dir modules-a --module-dir modules-b > test-order.log)
grep -q '2 compiled, 0 reused' "$TMP/test-project/test-order.log" || {
    echo 'FAIL: bilingual aster test did not include module-root order in its cache key' >&2; cat "$TMP/test-project/test-order.log" >&2; exit 1;
}
(cd "$TMP/test-project" && "$ASTER_BIN" test --module-dir modules-b --module-dir modules-a > test-order-reversed.log)
grep -q '2 compiled, 0 reused' "$TMP/test-project/test-order-reversed.log" || {
    echo 'FAIL: changing module-root order incorrectly reused bilingual test cache' >&2; cat "$TMP/test-project/test-order-reversed.log" >&2; exit 1;
}
mkdir -p "$TMP/test-project/test-packages"
cat > "$TMP/test-project/test-packages/helper.ast" <<'SRC'
// aster:language=en
package demo.test_helper;
fn add_one(value: i32): i32 {
return value + 1;
}
SRC
cat > "$TMP/test-project/tests/basic.ast" <<'SRC'
// aster:language=en
@import("demo.test_helper").alias("helper")
fn main(): i32 {
return helper.add_one(41) - 42;
}
SRC
(cd "$TMP/test-project" && "$ASTER_BIN" test --module-dir test-packages > test-package-first.log)
grep -q '2 compiled, 0 reused' "$TMP/test-project/test-package-first.log" || {
    echo 'FAIL: bilingual aster test did not compile an external package test' >&2; cat "$TMP/test-project/test-package-first.log" >&2; exit 1;
}
(cd "$TMP/test-project" && "$ASTER_BIN" test --module-dir test-packages > test-package-second.log)
grep -q '0 compiled, 2 reused' "$TMP/test-project/test-package-second.log" || {
    echo 'FAIL: bilingual aster test did not reuse an external package test' >&2; cat "$TMP/test-project/test-package-second.log" >&2; exit 1;
}
printf '\n' >> "$TMP/test-project/test-packages/helper.ast"
(cd "$TMP/test-project" && "$ASTER_BIN" test --module-dir test-packages > test-package-change.log)
grep -q '1 compiled, 1 reused' "$TMP/test-project/test-package-change.log" || {
    echo 'FAIL: external package edit did not invalidate bilingual test cache' >&2; cat "$TMP/test-project/test-package-change.log" >&2; exit 1;
}

mkdir -p "$TMP/test-collision/tests/one" "$TMP/test-collision/tests/two"
cat > "$TMP/test-collision/aster.proj" <<'SRC'
name bilingual_test_collision
[language]
default = "en"
allowed = ["zh", "en"]
test tests/one/same.ast
test tests/two/same.ast
SRC
cat > "$TMP/test-collision/tests/one/same.ast" <<'SRC'
// aster:language=en
fn main(): i32 {
return 0;
}
SRC
cat > "$TMP/test-collision/tests/two/same.ast" <<'SRC'
// aster:language=en
fn main(): i32 {
return 0;
}
SRC
(cd "$TMP/test-collision" && "$ASTER_BIN" test > collision-first.log)
grep -q '2 tests, 0 failed (2 compiled, 0 reused)' "$TMP/test-collision/collision-first.log" || {
    echo 'FAIL: bilingual tests with the same basename did not both run' >&2; cat "$TMP/test-collision/collision-first.log" >&2; exit 1;
}
[ "$(find "$TMP/test-collision/build/tests" -maxdepth 1 -type f | wc -l | tr -d ' ')" -eq 2 ] || {
    echo 'FAIL: bilingual same-basename tests did not get distinct executables' >&2; find "$TMP/test-collision/build/tests" -maxdepth 1 -type f >&2; exit 1;
}
(cd "$TMP/test-collision" && "$ASTER_BIN" test > collision-second.log)
grep -q '2 tests, 0 failed (0 compiled, 2 reused)' "$TMP/test-collision/collision-second.log" || {
    echo 'FAIL: bilingual same-basename tests did not reuse both objects' >&2; cat "$TMP/test-collision/collision-second.log" >&2; exit 1;
}

cat > "$TMP/packages/calc-zh.ast" <<'SRC'
// aster:language=zh
// comments before the package declaration are ignored
包名 demo.calc
方法 乘二(数: 整数): 整数
返回 数 * 2
结束 方法
SRC
cat > "$TMP/packages/calc-en.ast" <<'SRC'
// aster:language=en
package demo.calc;
fn 加一(value: i32): i32 {
return 乘二(value) + 1;
}
SRC
cat > "$TMP/app/main.ast" <<'SRC'
@导入("demo.calc").别名("计算")
@导入("demo.calc").别名("calc")
方法 启动方法(): 整数
返回 计算.加一(20) + calc.乘二(1)
结束 方法
SRC

echo '[1/4] package name indexes mixed-language source files; aliases share one module load'
"$ASTER_BIN" build-cn-obj --language zh --module-dir "$TMP/packages" "$TMP/app/main.ast" -o "$TMP/main.o"
"$ASTER_BIN" link-obj "$TMP/main.o" -o "$TMP/main"
if "$RUNNER" "$TMP/main"; then status=0; else status=$?; fi
[ "$status" -eq 43 ] || { echo "FAIL: imported result was $status, expected 43" >&2; exit 1; }

cat > "$TMP/packages/math-zh.ast" <<'SRC'
包名 标准库.数学 = standard.math
方法 平方(value: 整数): 整数
返回 value * value
结束 方法
SRC
cat > "$TMP/packages/math-en.ast" <<'SRC'
// aster:language=en
package 标准库.数学 = standard.math;
fn cube(value: i32): i32 {
return value * value * value;
}
SRC
cat > "$TMP/app/math-zh.ast" <<'SRC'
@导入("标准库.数学").别名("数学")
方法 启动方法(): 整数
返回 数学.cube(3) + 数学.平方(4)
结束 方法
SRC
cat > "$TMP/app/math-en.ast" <<'SRC'
// aster:language=en
@import("standard.math").alias("math")
fn main(): i32 {
return math.cube(2) + math.平方(3);
}
SRC
echo '[aliases] localized package names resolve to one bilingual package identity'
"$ASTER_BIN" build-cn-obj --language zh --module-dir "$TMP/packages" "$TMP/app/math-zh.ast" -o "$TMP/math-zh.o"
"$ASTER_BIN" link-obj "$TMP/math-zh.o" -o "$TMP/math-zh"
if "$RUNNER" "$TMP/math-zh"; then status=0; else status=$?; fi
[ "$status" -eq 43 ] || { echo "FAIL: Chinese package alias result was $status, expected 43" >&2; exit 1; }
"$ASTER_BIN" build-cn-obj --module-dir "$TMP/packages" "$TMP/app/math-en.ast" -o "$TMP/math-en.o"
"$ASTER_BIN" link-obj "$TMP/math-en.o" -o "$TMP/math-en"
if "$RUNNER" "$TMP/math-en"; then status=0; else status=$?; fi
[ "$status" -eq 17 ] || { echo "FAIL: English package alias result was $status, expected 17" >&2; exit 1; }

cat > "$TMP/packages/oop-core.ast" <<'SRC'
包名 demo.oop
枚举 Color
Red = 4
Blue = Red + 3
结束 枚举
接口类 HasValue
方法 value(): 整数
结束 接口类
方法 加二(值: 整数): 整数
返回 值 + 2
结束 方法
类 Item : HasValue
变量 回调: 方法(整数): 整数 = 加二
@静态
变量 count: 整数 = 3
@静态
变量 values: 整数[2] = [2, 3]
@静态
方法 increment(): 整数
Item.count = Item.count + 1
返回 Item.count
结束 方法
@静态
方法 incrementFirst(): 整数
Item.values[0] = Item.values[0] + 1
返回 Item.values[0]
结束 方法
方法 value(): 整数
返回 Blue
结束 方法
@静态
方法 double(value: Color): 整数
返回 value * 2
结束 方法
结束 类
类 ChildItem : Item
@静态
方法 readCount(): 整数
返回 ChildItem.count
结束 方法
@静态
方法 readSecond(): 整数
返回 ChildItem.values[1]
结束 方法
结束 类
类 Base
变量 baseValue: 整数
@受限
方法 inherited(): 整数
返回 本对象.baseValue
结束 方法
结束 类
类 Derived : Base
方法 from_base(): 整数
本对象.baseValue = 3
返回 父对象.inherited() + 1
结束 方法
结束 类
类 Ledger
@受限
变量 internalValue: 整数
@受限
@静态
变量 internalStaticValue: 整数 = 9
结束 类
SRC
cat > "$TMP/packages/interface-base.ast" <<'SRC'
// aster:language=en
package demo.interface_base;
interface class RootContract {
fn root(): i32;
}
interface class ReadableContract: RootContract {
fn read(): i32;
}
SRC
cat > "$TMP/packages/interface-child.ast" <<'SRC'
// aster:language=en
package demo.interface_child;
@import("demo.interface_base").alias("base")
interface class AdvancedContract: base.ReadableContract {
fn extra(): i32;
fn childView(): AdvancedContract;
}
class ContractImplementation: AdvancedContract {
fn root(): i32 { return 38; }
fn read(): i32 { return 40; }
fn extra(): i32 { return 2; }
fn childView(): AdvancedContract { return this; }
}
SRC
cat > "$TMP/packages/restricted-interface.ast" <<'SRC'
// aster:language=en
package demo.restricted_interface;
interface class PublicContract {
fn apply(): i32;
}
class RestrictedImplementation: PublicContract {
@protected
fn apply(): i32 { return 1; }
}
SRC
cat > "$TMP/packages/function-signature-interface.ast" <<'SRC'
// aster:language=en
package demo.function_signature_interface;
interface class CallbackContract {
fn invoke(callback: fn(i32): i32): i32;
}
class MismatchedImplementation: CallbackContract {
fn invoke(callback: fn(i64): i64): i32 { return 0; }
}
SRC
cat > "$TMP/packages/oop-callback-en.ast" <<'SRC'
// aster:language=en
package demo.oop;
interface class RootValue {
fn root(): i32;
}
interface class ReadableValue: RootValue {
fn read(): i32;
}
interface class AdvancedValue: ReadableValue {
fn extra(): i32;
fn asAdvanced(): AdvancedValue;
fn childView(): AdvancedValue;
}
class AdvancedObject: AdvancedValue {
fn root(): i32 { return 38; }
fn read(): i32 { return 40; }
fn asAdvanced(): AdvancedValue { return this; }
fn childView(): AdvancedValue { return this; }
fn extra(): i32 { return 2; }
}
fn addTwo(value: i32): i32 {
return value + 2;
}
@private
fn hiddenAdd(value: i32): i32 {
return value + 99;
}
struct CallbackStruct {
callbacks: fn(i32): i32[2]
}
class CallbackBox {
let instanceCallback: fn(i32): i32 = addTwo;
let instanceCallbacks: fn(i32): i32[2] = [addTwo, addTwo];
@static
let callback: fn(i32): i32 = addTwo;
@static
let callbacks: fn(i32): i32[2] = [addTwo, addTwo];
@private
@static
let hiddenCallback: fn(i32): i32 = addTwo;
@protected
@static
let restrictedCallback: fn(i32): i32 = addTwo;
@static
fn run(value: i32): i32 {
return CallbackBox.callback(value);
}
@static
fn runArray(value: i32): i32 {
return CallbackBox.callbacks[1](value);
}
}
class CallbackChild: CallbackBox {
@static
fn readRestricted(value: i32): i32 {
return CallbackChild.restrictedCallback(value);
}
}
class InterfaceCallback: HasValue {
let interfaceCallbacks: fn(i32): i32[1] = [addTwo];
fn value(): i32 {
return this.interfaceCallbacks[0](40);
}
}
class CallbackBase {
@protected
let inheritedCallbacks: fn(i32): i32[1] = [addTwo];
fn readInherited(value: i32): i32 {
return this.inheritedCallbacks[0](value);
}
}
class CallbackDerived: CallbackBase {
fn readInheritedFromChild(value: i32): i32 {
return this.inheritedCallbacks[0](value);
}
}
SRC
cat > "$TMP/packages/oop-struct-en.ast" <<'SRC'
// aster:language=en
package demo.oop;
struct Point { x: i32, y: i32 }
class StaticPoint {
@static
let origin: Point = Point { 2, 3 };
@static
let zero: Point;
@static
let points: Point[2] = [Point { 1, 2 }, Point { 3, 4 }];
@static
let zeroPoints: Point[2];
@static
fn adjust(): i32 {
StaticPoint.origin.x = StaticPoint.origin.x + 1;
return StaticPoint.origin.x + StaticPoint.origin.y;
}
}
SRC
cat > "$TMP/app/oop-import.ast" <<'SRC'
@导入("demo.oop").别名("oop")
方法 启动方法(): 整数
oop.StaticPoint.points[1].x = 9
返回 oop.Item.double(oop.Color.Blue) + oop.Item().value() + oop.Derived().from_base() + oop.Item.increment() + oop.Item.count + oop.ChildItem.readCount() + oop.Item.incrementFirst() + oop.ChildItem.readSecond() + oop.Item.values[0] + oop.CallbackBox.run(40) + oop.CallbackBox.runArray(40) + oop.CallbackChild.run(40) + oop.CallbackChild.readRestricted(40) + oop.CallbackBox().instanceCallback(40) + oop.Item().回调(40) + oop.StaticPoint.adjust() + oop.StaticPoint.origin.x + oop.StaticPoint.origin.y + oop.StaticPoint.zero.x + oop.StaticPoint.zero.y + oop.StaticPoint.points[1].x + oop.StaticPoint.points[1].y + oop.StaticPoint.zeroPoints[0].x + oop.StaticPoint.zeroPoints[0].y + oop.CallbackBase().readInherited(40) + oop.CallbackDerived().readInheritedFromChild(40) - 219
结束 方法
SRC
echo '[oop] imported classes, inheritance, static function-pointer arrays, and enum members compose'
"$ASTER_BIN" build-cn-obj --module-dir "$TMP/packages" "$TMP/app/oop-import.ast" -o "$TMP/oop-import.o"
"$ASTER_BIN" build-obj "$ROOT/stdlib/aster_std.ast" -o "$TMP/aster_std.o"
"$ASTER_BIN" link-obj "$TMP/oop-import.o" "$TMP/aster_std.o" -o "$TMP/oop-import"
if "$RUNNER" "$TMP/oop-import"; then status=0; else status=$?; fi
[ "$status" -eq 188 ] || { echo "FAIL: imported OOP result was $status, expected 188" >&2; exit 1; }

cat > "$TMP/app/callback-array-import-zh.ast" <<'SRC'
@导入("demo.oop").别名("oop")
方法 启动方法(): 整数
变量 盒: oop.CallbackStruct
盒.callbacks[1] = oop.addTwo
变量 对象: oop.CallbackBox = oop.CallbackBox()
返回 盒.callbacks[1](40) + 对象.instanceCallbacks[0](40) - 84
结束 方法
SRC
cat > "$TMP/app/callback-array-import-en.ast" <<'SRC'
// aster:language=en
@import("demo.oop").alias("oop")
fn main(): i32 {
let box: oop.CallbackStruct;
box.callbacks[1] = oop.addTwo;
let object: oop.CallbackBox = oop.CallbackBox();
return box.callbacks[1](40) + object.instanceCallbacks[0](40) - 84;
}
SRC
echo '[fn arrays] imported structure and instance fields preserve signatures and method values'
for language in zh en; do
    "$ASTER_BIN" build-cn-obj --language "$language" --module-dir "$TMP/packages" \
        "$TMP/app/callback-array-import-$language.ast" -o "$TMP/callback-array-import-$language.o"
    "$ASTER_BIN" link-obj "$TMP/callback-array-import-$language.o" "$TMP/aster_std.o" \
        -o "$TMP/callback-array-import-$language"
    if "$RUNNER" "$TMP/callback-array-import-$language"; then status=0; else status=$?; fi
    [ "$status" -eq 0 ] || {
        echo "FAIL: $language imported callback array result was $status, expected 0" >&2
        exit 1
    }
done

cat > "$TMP/app/hidden-method-value.ast" <<'SRC'
@导入("demo.oop").别名("oop")
方法 启动方法(): 整数
变量 回调们: 方法(整数): 整数[1] = [oop.hiddenAdd]
返回 回调们[0](1)
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj --module-dir "$TMP/packages" \
    "$TMP/app/hidden-method-value.ast" -o "$TMP/hidden-method-value.o" \
    2> "$TMP/hidden-method-value.err"; then
    echo 'FAIL: a private imported method was usable as a function value' >&2
    exit 1
fi
grep -q "method 'hiddenAdd' is not public in package 'demo.oop'" \
    "$TMP/hidden-method-value.err"

cat > "$TMP/app/inherited-callback-import-en.ast" <<'SRC'
// aster:language=en
@import("demo.oop").alias("oop")
class LocalCallback: oop.CallbackBase {
fn read(value: i32): i32 {
return this.inheritedCallbacks[0](value);
}
}
fn main(): i32 { return LocalCallback().read(40) - 42; }
SRC
cat > "$TMP/app/inherited-callback-import-zh.ast" <<'SRC'
@导入("demo.oop").别名("oop")
类 本地回调 : oop.CallbackBase
方法 读取(值: 整数): 整数
返回 本对象.inheritedCallbacks[0](值)
结束 方法
结束 类
方法 启动方法(): 整数
返回 本地回调().读取(40) - 42
结束 方法
SRC
cat > "$TMP/app/interface-callback-import-en.ast" <<'SRC'
// aster:language=en
@import("demo.oop").alias("oop")
fn use(value: oop.HasValue): i32 { return value.value(); }
fn main(): i32 { return use(oop.InterfaceCallback()) - 42; }
SRC
cat > "$TMP/app/interface-callback-import-zh.ast" <<'SRC'
@导入("demo.oop").别名("oop")
方法 使用(值: oop.HasValue): 整数
返回 值.value()
结束 方法
方法 启动方法(): 整数
返回 使用(oop.InterfaceCallback()) - 42
结束 方法
SRC
echo '[inheritance] imported subclasses retain protected function-array access'
for language in en zh; do
    "$ASTER_BIN" build-cn-obj --language "$language" --module-dir "$TMP/packages" \
        "$TMP/app/inherited-callback-import-$language.ast" \
        -o "$TMP/inherited-callback-import-$language.o"
    "$ASTER_BIN" link-obj "$TMP/inherited-callback-import-$language.o" "$TMP/aster_std.o" \
        -o "$TMP/inherited-callback-import-$language"
    if "$RUNNER" "$TMP/inherited-callback-import-$language"; then status=0; else status=$?; fi
    [ "$status" -eq 0 ] || {
        echo "FAIL: $language imported subclass protected callback result was $status, expected 0" >&2
        exit 1
    }
done
echo '[interfaces] imported interface dispatch preserves callback field signatures'
for language in en zh; do
    "$ASTER_BIN" build-cn-obj --language "$language" --module-dir "$TMP/packages" \
        "$TMP/app/interface-callback-import-$language.ast" \
        -o "$TMP/interface-callback-import-$language.o"
    "$ASTER_BIN" link-obj "$TMP/interface-callback-import-$language.o" "$TMP/aster_std.o" \
        -o "$TMP/interface-callback-import-$language"
    if "$RUNNER" "$TMP/interface-callback-import-$language"; then status=0; else status=$?; fi
    [ "$status" -eq 0 ] || {
        echo "FAIL: $language imported interface callback result was $status, expected 0" >&2
        exit 1
    }
done
cat > "$TMP/app/interface-inheritance-import-en.ast" <<'SRC'
// aster:language=en
@import("demo.oop").alias("oop")
let passCount: i32 = 0;
fn useRoot(value: oop.RootValue): i32 { return value.root(); }
fn useBase(value: oop.ReadableValue): i32 { return value.read(); }
fn passChild(value: oop.AdvancedValue): oop.AdvancedValue { passCount = passCount + 1; return value; }
fn useChild(value: oop.AdvancedValue): i32 { return useBase(passChild(value)) + useRoot(passChild(value)) + value.extra(); }
fn useReturnedChild(value: oop.AdvancedValue): i32 { return useBase(value.asAdvanced()); }
fn useClassReturnedRoot(value: oop.AdvancedObject): i32 { return useRoot(value.childView()); }
fn useInterfaceReturnedRoot(value: oop.AdvancedValue): i32 { return useRoot(value.childView()); }
fn main(): i32 { return useRoot(oop.AdvancedObject()) + useBase(oop.AdvancedObject()) + useChild(oop.AdvancedObject()) + useReturnedChild(oop.AdvancedObject()) + useClassReturnedRoot(oop.AdvancedObject()) + useInterfaceReturnedRoot(oop.AdvancedObject()) + passCount - 276; }
SRC
cat > "$TMP/app/interface-inheritance-import-zh.ast" <<'SRC'
@导入("demo.oop").别名("oop")
变量 传递次数: 整数 = 0
方法 使用根接口(值: oop.RootValue): 整数
返回 值.root()
结束 方法
方法 使用基接口(值: oop.ReadableValue): 整数
返回 值.read()
结束 方法
方法 传递子接口(值: oop.AdvancedValue): oop.AdvancedValue
传递次数 = 传递次数 + 1
返回 值
结束 方法
方法 使用子接口(值: oop.AdvancedValue): 整数
返回 使用基接口(传递子接口(值)) + 使用根接口(传递子接口(值)) + 值.extra()
结束 方法
方法 使用返回子接口(值: oop.AdvancedValue): 整数
返回 使用基接口(值.asAdvanced())
结束 方法
方法 使用类方法返回根接口(值: oop.AdvancedObject): 整数
返回 使用根接口(值.childView())
结束 方法
方法 使用接口方法返回根接口(值: oop.AdvancedValue): 整数
返回 使用根接口(值.childView())
结束 方法
方法 启动方法(): 整数
返回 使用根接口(oop.AdvancedObject()) + 使用基接口(oop.AdvancedObject()) + 使用子接口(oop.AdvancedObject()) + 使用返回子接口(oop.AdvancedObject()) + 使用类方法返回根接口(oop.AdvancedObject()) + 使用接口方法返回根接口(oop.AdvancedObject()) + 传递次数 - 276
结束 方法
SRC
echo '[interface inheritance] imported classes implementing a derived interface convert to its base interface'
for language in en zh; do
    "$ASTER_BIN" build-cn-obj --language "$language" --module-dir "$TMP/packages" \
        "$TMP/app/interface-inheritance-import-$language.ast" \
        -o "$TMP/interface-inheritance-import-$language.o"
    "$ASTER_BIN" link-obj "$TMP/interface-inheritance-import-$language.o" "$TMP/aster_std.o" \
        -o "$TMP/interface-inheritance-import-$language"
    if "$RUNNER" "$TMP/interface-inheritance-import-$language"; then status=0; else status=$?; fi
    [ "$status" -eq 0 ] || {
        echo "FAIL: $language imported interface inheritance result was $status, expected 0" >&2
        exit 1
    }
done
cat > "$TMP/app/cross-package-interface-inheritance-en.ast" <<'SRC'
// aster:language=en
@import("demo.interface_base").alias("base")
@import("demo.interface_child").alias("child")
let passCount: i32 = 0;
fn useRoot(value: base.RootContract): i32 { return value.root(); }
fn useBase(value: base.ReadableContract): i32 { return value.read(); }
fn passChild(value: child.AdvancedContract): child.AdvancedContract { passCount = passCount + 1; return value; }
fn useChild(value: child.AdvancedContract): i32 { return useBase(passChild(value)) + value.extra(); }
fn useReturnedRoot(value: child.AdvancedContract): i32 { return useRoot(value.childView()); }
fn main(): i32 {
let value: child.ContractImplementation = child.ContractImplementation();
return useBase(value) + useRoot(passChild(value)) + useRoot(value.childView()) + useChild(value) + useReturnedRoot(value) + passCount - 198;
}
SRC
cat > "$TMP/app/cross-package-interface-inheritance-zh.ast" <<'SRC'
@导入("demo.interface_base").别名("基接口")
@导入("demo.interface_child").别名("子接口")
变量 传递次数: 整数 = 0
方法 使用基接口(值: 基接口.ReadableContract): 整数
返回 值.read()
结束 方法
方法 使用根接口(值: 基接口.RootContract): 整数
返回 值.root()
结束 方法
方法 传递子接口(值: 子接口.AdvancedContract): 子接口.AdvancedContract
传递次数 = 传递次数 + 1
返回 值
结束 方法
方法 使用子接口(值: 子接口.AdvancedContract): 整数
返回 使用基接口(传递子接口(值)) + 值.extra()
结束 方法
方法 使用返回根接口(值: 子接口.AdvancedContract): 整数
返回 使用根接口(值.childView())
结束 方法
方法 启动方法(): 整数
变量 值: 子接口.ContractImplementation = 子接口.ContractImplementation()
返回 使用基接口(值) + 使用根接口(传递子接口(值)) + 使用根接口(值.childView()) + 使用子接口(值) + 使用返回根接口(值) + 传递次数 - 198
结束 方法
SRC
echo '[cross-package interfaces] a derived package interface inherits an imported contract'
for language in en zh; do
    "$ASTER_BIN" build-cn-obj --language "$language" --module-dir "$TMP/packages" \
        "$TMP/app/cross-package-interface-inheritance-$language.ast" \
        -o "$TMP/cross-package-interface-inheritance-$language.o"
    "$ASTER_BIN" link-obj "$TMP/cross-package-interface-inheritance-$language.o" "$TMP/aster_std.o" \
        -o "$TMP/cross-package-interface-inheritance-$language"
    if "$RUNNER" "$TMP/cross-package-interface-inheritance-$language"; then status=0; else status=$?; fi
    [ "$status" -eq 0 ] || {
        echo "FAIL: $language cross-package interface inheritance returned $status, expected 0" >&2
        exit 1
    }
done

cat > "$TMP/packages/array-api.ast" <<'SRC'
// aster:language=en
package demo.arrays;
fn bump(values: i32[2]): i32 {
values[0] = values[0] + 3;
return values[0] + values[1];
}
class ArrayOps {
fn bump(values: i32[2]): i32 {
values[1] = values[1] + 4;
return values[0] + values[1];
}
}
SRC
cat > "$TMP/app/array-import.ast" <<'SRC'
// aster:language=zh
@导入("demo.arrays").别名("数组")
方法 启动方法(): 整数
变量 values: 整数[2] = [4, 6]
变量 first: 整数 = 数组.bump(values)
如果 first != 13
返回 1
结束 如果
如果 values[0] != 7
返回 2
结束 如果
变量 second: 整数 = 数组.ArrayOps().bump(values)
如果 second != 17
返回 3
结束 如果
如果 values[1] != 10
返回 4
结束 如果
返回 0
结束 方法
SRC
echo '[array parameters] imported top-level and class methods preserve fixed array ABI'
"$ASTER_BIN" build-cn-obj --module-dir "$TMP/packages" \
    "$TMP/app/array-import.ast" -o "$TMP/array-import.o"
"$ASTER_BIN" link-obj "$TMP/array-import.o" "$TMP/aster_std.o" \
    -o "$TMP/array-import"
if "$RUNNER" "$TMP/array-import"; then status=0; else status=$?; fi
[ "$status" -eq 0 ] || { echo "FAIL: imported array parameter result was $status, expected 0" >&2; exit 1; }

cat > "$TMP/app/hidden-static-callback.ast" <<'SRC'
@导入("demo.oop").别名("oop")
方法 启动方法(): 整数
返回 oop.CallbackBox.hiddenCallback(1)
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj --module-dir "$TMP/packages" \
    "$TMP/app/hidden-static-callback.ast" -o "$TMP/hidden-static-callback.o" \
    2> "$TMP/hidden-static-callback.err"; then
    echo 'FAIL: a @private static function pointer field was visible outside its class' >&2
    exit 1
fi
grep -q "field 'hiddenCallback' is hidden outside class '.*CallbackBox" \
    "$TMP/hidden-static-callback.err"

cat > "$TMP/app/restricted-static-callback.ast" <<'SRC'
@导入("demo.oop").别名("oop")
方法 启动方法(): 整数
返回 oop.CallbackBox.restrictedCallback(1)
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj --module-dir "$TMP/packages" \
    "$TMP/app/restricted-static-callback.ast" -o "$TMP/restricted-static-callback.o" \
    2> "$TMP/restricted-static-callback.err"; then
    echo 'FAIL: a @protected static function pointer field was visible outside its class' >&2
    exit 1
fi
grep -q "field 'restrictedCallback' is restricted to class '.*CallbackBox.*and its subclasses" \
    "$TMP/restricted-static-callback.err"

cat > "$TMP/app/restricted-instance-callback-array.ast" <<'SRC'
@导入("demo.oop").别名("oop")
方法 启动方法(): 整数
变量 基类对象: oop.CallbackBase
返回 基类对象.inheritedCallbacks[0](1)
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj --module-dir "$TMP/packages" \
    "$TMP/app/restricted-instance-callback-array.ast" -o "$TMP/restricted-instance-callback-array.o" \
    2> "$TMP/restricted-instance-callback-array.err"; then
    echo 'FAIL: a @protected inherited function pointer array field was visible outside its class hierarchy' >&2
    exit 1
fi
grep -q "field 'inheritedCallbacks' is restricted to class '.*CallbackBase.*and its subclasses" \
    "$TMP/restricted-instance-callback-array.err"

cat > "$TMP/app/restricted-field.ast" <<'SRC'
@导入("demo.oop").别名("oop")
方法 启动方法(): 整数
变量 ledger: oop.Ledger
返回 ledger.internalValue
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj --module-dir "$TMP/packages" \
    "$TMP/app/restricted-field.ast" -o "$TMP/restricted-field.o" \
    2> "$TMP/restricted-field.err"; then
    echo 'FAIL: a @受限 field was visible outside its class hierarchy' >&2
    exit 1
fi
grep -q "is restricted to class '.*Ledger.*and its subclasses" "$TMP/restricted-field.err"

cat > "$TMP/app/restricted-static-field.ast" <<'SRC'
@导入("demo.oop").别名("oop")
方法 启动方法(): 整数
返回 oop.Ledger.internalStaticValue
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj --module-dir "$TMP/packages" \
    "$TMP/app/restricted-static-field.ast" -o "$TMP/restricted-static-field.o" \
    2> "$TMP/restricted-static-field.err"; then
    echo 'FAIL: a @受限 static field was visible outside its class hierarchy' >&2
    exit 1
fi
grep -q "is restricted to class '.*Ledger.*and its subclasses" \
    "$TMP/restricted-static-field.err"

cat > "$TMP/app/missing-interface-method.ast" <<'SRC'
@导入("demo.oop").别名("oop")
类 Broken : oop.HasValue
结束 类
方法 启动方法(): 整数
返回 0
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj --module-dir "$TMP/packages" \
    "$TMP/app/missing-interface-method.ast" -o "$TMP/missing-interface-method.o" \
    2> "$TMP/missing-interface-method.err"; then
    echo 'FAIL: a class without an imported interface method was accepted' >&2
    exit 1
fi
grep -q "does not implement interface" "$TMP/missing-interface-method.err" || {
    cat "$TMP/missing-interface-method.err" >&2
    exit 1
}

cat > "$TMP/app/restricted-interface-implementation.ast" <<'SRC'
// aster:language=en
@import("demo.restricted_interface").alias("contract")
fn main(): i32 { return 0; }
SRC
if "$ASTER_BIN" build-cn-obj --module-dir "$TMP/packages" \
    "$TMP/app/restricted-interface-implementation.ast" \
    -o "$TMP/restricted-interface-implementation.o" \
    2> "$TMP/restricted-interface-implementation.err"; then
    echo 'FAIL: a protected method was accepted as a public interface implementation' >&2
    exit 1
fi
grep -q "class method signature does not match interface '.*PublicContract'.*apply" \
    "$TMP/restricted-interface-implementation.err"

cat > "$TMP/app/function-signature-interface.ast" <<'SRC'
// aster:language=en
@import("demo.function_signature_interface").alias("contract")
fn main(): i32 { return 0; }
SRC
if "$ASTER_BIN" build-cn-obj --module-dir "$TMP/packages" \
    "$TMP/app/function-signature-interface.ast" \
    -o "$TMP/function-signature-interface.o" \
    2> "$TMP/function-signature-interface.err"; then
    echo 'FAIL: a mismatched function-pointer parameter signature implemented an interface' >&2
    exit 1
fi
grep -q "class method signature does not match interface '.*CallbackContract'.*invoke" \
    "$TMP/function-signature-interface.err"

cat > "$TMP/packages/state.ast" <<'SRC'
包名 demo.state
变量 count: 整数 = 5
常量 step: 整数 = 2
方法 增加(): 整数
count = count + step
返回 count
结束 方法
SRC
cat > "$TMP/app/state.ast" <<'SRC'
@导入("demo.state").别名("state")
方法 启动方法(): 整数
返回 state.增加() + state.count
结束 方法
SRC
"$ASTER_BIN" build-cn-obj --module-dir "$TMP/packages" "$TMP/app/state.ast" -o "$TMP/state.o"
"$ASTER_BIN" link-obj "$TMP/state.o" -o "$TMP/state"
if "$RUNNER" "$TMP/state"; then status=0; else status=$?; fi
[ "$status" -eq 14 ] || { echo "FAIL: imported global result was $status, expected 14" >&2; exit 1; }

cat > "$TMP/packages/hidden-global.ast" <<'SRC'
包名 demo.hidden_global
@隐藏
变量 secret: 整数 = 8
SRC
cat > "$TMP/app/hidden-global.ast" <<'SRC'
@导入("demo.hidden_global").别名("hidden")
方法 启动方法(): 整数
返回 hidden.secret
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj --module-dir "$TMP/packages" \
    "$TMP/app/hidden-global.ast" -o "$TMP/hidden-global.o" 2> "$TMP/hidden-global.err"; then
    echo 'FAIL: hidden package global was imported' >&2
    exit 1
fi
grep -q "is not public in package" "$TMP/hidden-global.err"

cat > "$TMP/packages/hidden-type.ast" <<'SRC'
包名 demo.hidden_type
@隐藏
类 Hidden
结束 类
SRC
cat > "$TMP/app/hidden-type.ast" <<'SRC'
@导入("demo.hidden_type").别名("secret")
方法 启动方法(): 整数
变量 item: secret.Hidden
返回 0
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj --module-dir "$TMP/packages" \
    "$TMP/app/hidden-type.ast" -o "$TMP/hidden-type.o" 2> "$TMP/hidden-type.err"; then
    echo 'FAIL: hidden package type was imported' >&2
    exit 1
fi
grep -q "type 'Hidden' is not public in package" "$TMP/hidden-type.err"

cat > "$TMP/packages/restricted-global-a.ast" <<'SRC'
包名 demo.restricted_global
@受限
变量 localState: 整数 = 1
SRC
cat > "$TMP/packages/restricted-global-b.ast" <<'SRC'
包名 demo.restricted_global
方法 read(): 整数
返回 localState
结束 方法
SRC
cat > "$TMP/app/restricted-global.ast" <<'SRC'
@导入("demo.restricted_global").别名("restricted")
方法 启动方法(): 整数
返回 restricted.read()
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj --module-dir "$TMP/packages" \
    "$TMP/app/restricted-global.ast" -o "$TMP/restricted-global.o" \
    2> "$TMP/restricted-global.err"; then
    echo 'FAIL: a package source read a restricted global from another file' >&2
    exit 1
fi
grep -q "restricted to its declaring file" "$TMP/restricted-global.err"

cat > "$TMP/packages/point.ast" <<'SRC'
包名 model.types
类 Point
变量 x: 整数
结束 类
SRC
cat > "$TMP/packages/point-api.ast" <<'SRC'
包名 demo.point_api
@导入("model.types").别名("model")
方法 get_x(point: model.Point): 整数
返回 point.x
结束 方法
SRC
cat > "$TMP/app/types.ast" <<'SRC'
@导入("demo.point_api").别名("api")
方法 启动方法(): 整数
返回 0
结束 方法
SRC
echo '[types] imported package types resolve through transitive package imports'
"$ASTER_BIN" build-cn-obj --module-dir "$TMP/packages" "$TMP/app/types.ast" -o "$TMP/types.o"
test -s "$TMP/types.o"

cat > "$TMP/packages/secret.ast" <<'SRC'
包名 demo.secret
@隐藏
方法 私有值(): 整数
返回 4
结束 方法
SRC
cat > "$TMP/app/hidden.ast" <<'SRC'
@导入("demo.secret").别名("secret")
方法 启动方法(): 整数
返回 secret.私有值()
结束 方法
SRC
echo '[2/4] hidden package methods are not exported'
if "$ASTER_BIN" build-cn-obj --模块目录 "$TMP/packages" "$TMP/app/hidden.ast" -o "$TMP/hidden.o" 2> "$TMP/hidden.err"; then
    echo 'FAIL: hidden package method was imported' >&2
    exit 1
fi
grep -q 'is not public in package' "$TMP/hidden.err"

cat > "$TMP/packages/restricted-a.ast" <<'SRC'
包名 demo.restricted
@受限
方法 仅本文件(): 整数
返回 9
结束 方法
SRC
cat > "$TMP/packages/restricted-b.ast" <<'SRC'
包名 demo.restricted
方法 跨文件调用(): 整数
返回 仅本文件()
结束 方法
SRC
cat > "$TMP/app/restricted.ast" <<'SRC'
@导入("demo.restricted").别名("restricted")
方法 启动方法(): 整数
返回 restricted.跨文件调用()
结束 方法
SRC
echo '[3/4] restricted methods remain private to their declaring source file'
if "$ASTER_BIN" build-cn-obj --module-dir "$TMP/packages" "$TMP/app/restricted.ast" -o "$TMP/restricted.o" 2> "$TMP/restricted.err"; then
    echo 'FAIL: a restricted method was referenced from another package file' >&2
    exit 1
fi
grep -q 'restricted to its declaring file' "$TMP/restricted.err"

cat > "$TMP/packages/cycle-a.ast" <<'SRC'
包名 cycle.a
@导入("cycle.b").别名("b")
方法 来自A(): 整数
返回 b.来自B()
结束 方法
SRC
cat > "$TMP/packages/cycle-b.ast" <<'SRC'
包名 cycle.b
@导入("cycle.a").别名("a")
方法 来自B(): 整数
返回 a.来自A()
结束 方法
SRC
cat > "$TMP/app/cycle.ast" <<'SRC'
@导入("cycle.a").别名("a")
方法 启动方法(): 整数
返回 a.来自A()
结束 方法
SRC
echo '[4/4] cyclic package imports fail during dependency discovery'
if "$ASTER_BIN" build-cn-obj --module-dir "$TMP/packages" "$TMP/app/cycle.ast" -o "$TMP/cycle.o" 2> "$TMP/cycle.err"; then
    echo 'FAIL: cyclic package imports were accepted' >&2
    exit 1
fi
grep -q 'cyclic package import involving' "$TMP/cycle.err"

mkdir -p "$TMP/packages-conflict" "$TMP/packages-mismatch"
cat > "$TMP/packages-conflict/alias-a.ast" <<'SRC'
包名 demo.alias_a = shared.alias
方法 value(): 整数
返回 1
结束 方法
SRC
cat > "$TMP/packages-conflict/alias-b.ast" <<'SRC'
包名 demo.alias_b = shared.alias
方法 value(): 整数
返回 2
结束 方法
SRC
cat > "$TMP/app/alias-conflict.ast" <<'SRC'
@导入("demo.alias_a").别名("a")
方法 启动方法(): 整数
返回 a.value()
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj --module-dir "$TMP/packages-conflict" \
    "$TMP/app/alias-conflict.ast" -o "$TMP/alias-conflict.o" \
    2> "$TMP/alias-conflict.err"; then
    echo 'FAIL: one package alias resolving to two canonical names was accepted' >&2
    exit 1
fi
grep -q 'package alias resolves to multiple canonical names' "$TMP/alias-conflict.err"

mkdir -p "$TMP/packages-alias-root-a" "$TMP/packages-alias-root-b"
cat > "$TMP/packages-alias-root-a/alias-a.ast" <<'SRC'
包名 demo.root_a = shared.root
方法 value(): 整数
返回 1
结束 方法
SRC
cat > "$TMP/packages-alias-root-b/alias-b.ast" <<'SRC'
包名 demo.root_b = shared.root
方法 value(): 整数
返回 2
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj --module-dir "$TMP/packages-alias-root-a" \
    --module-dir "$TMP/packages-alias-root-b" "$TMP/app/alias-conflict.ast" \
    -o "$TMP/alias-cross-root.o" 2> "$TMP/alias-cross-root.err"; then
    echo 'FAIL: cross-root package alias collision was accepted' >&2
    exit 1
fi
grep -q 'package alias resolves to multiple canonical names' "$TMP/alias-cross-root.err"

cat > "$TMP/packages-mismatch/alias-mismatch-a.ast" <<'SRC'
包名 demo.alias_mismatch = first.alias
方法 one(): 整数
返回 1
结束 方法
SRC
cat > "$TMP/packages-mismatch/alias-mismatch-b.ast" <<'SRC'
包名 demo.alias_mismatch = second.alias
方法 two(): 整数
返回 2
结束 方法
SRC
cat > "$TMP/app/alias-mismatch.ast" <<'SRC'
@导入("demo.alias_mismatch").别名("mismatch")
方法 启动方法(): 整数
返回 mismatch.one()
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj --module-dir "$TMP/packages-mismatch" \
    "$TMP/app/alias-mismatch.ast" -o "$TMP/alias-mismatch.o" \
    2> "$TMP/alias-mismatch.err"; then
    echo 'FAIL: package source files with inconsistent aliases were accepted' >&2
    exit 1
fi
grep -q 'package aliases do not match' "$TMP/alias-mismatch.err" || {
    cat "$TMP/alias-mismatch.err" >&2
    exit 1
}

# B-P1: an include/导入 inherits the importer's language when the imported
# file has neither its own directive nor a per-file [language] entry
# (selectLanguage: directive > per-file entry > importer > project default
# > zh). The lib below is English with no directive — under the old
# behaviour it was parsed as zh and failed at `fn` / `ptr<u8>`, exactly
# like aster_std.ast:52 in the Phase 1 report.
mkdir -p "$TMP/bp1"
cat > "$TMP/bp1/base.ast" <<'SRC'
fn base_value(): i32 {
return 0;
}
SRC
cat > "$TMP/bp1/lib.ast" <<'SRC'
include "base.ast";
fn add_one(x: i32): i32 {
return x + 1 + base_value();
}
fn count_bytes(p: ptr<u8>, n: i32): i32 {
return n;
}
SRC
cat > "$TMP/bp1/main_en.ast" <<'SRC'
// aster:language=en
include "lib.ast";
fn main(): i32 {
return add_one(41);
}
SRC
echo '[B-P1] English importer inherits into directive-less (nested) imports'
"$ASTER_BIN" build-cn-obj "$TMP/bp1/main_en.ast" -o "$TMP/bp1/main_en.o"
"$ASTER_BIN" link-obj "$TMP/bp1/main_en.o" -o "$TMP/bp1/main_en"
if "$RUNNER" "$TMP/bp1/main_en"; then status=0; else status=$?; fi
[ "$status" -eq 42 ] || { echo "FAIL: B-P1 English import result was $status, expected 42" >&2; exit 1; }

# B-P1: the importer wins over the project default — a Chinese importer
# under an en-default project still brings its helper in as Chinese.
mkdir -p "$TMP/bp1-zh/src"
cat > "$TMP/bp1-zh/aster.proj" <<'SRC'
name bp1-zh
[language]
default = "en"
src/main.ast
SRC
cat > "$TMP/bp1-zh/src/main.ast" <<'SRC'
// aster:language=zh
导入 "helper.ast"
方法 启动方法(): 整数
返回 加一(41)
结束 方法
SRC
cat > "$TMP/bp1-zh/src/helper.ast" <<'SRC'
方法 加一(值: 整数): 整数
返回 值 + 1
结束 方法
SRC
echo '[B-P1] Chinese importer beats an en project default'
(cd "$TMP/bp1-zh" && "$ASTER_BIN" build-cn-obj src/main.ast -o "$TMP/bp1-zh.o")
"$ASTER_BIN" link-obj "$TMP/bp1-zh.o" -o "$TMP/bp1-zh-exe"
if "$RUNNER" "$TMP/bp1-zh-exe"; then status=0; else status=$?; fi
[ "$status" -eq 42 ] || { echo "FAIL: B-P1 Chinese import result was $status, expected 42" >&2; exit 1; }

# B-P1: per-file [language] entries let listed sources mix languages in
# one project — the English framework file keeps en while the Chinese app
# sources stay zh, with no directive added to the framework file. The
# Chinese app source imports a directive-less Chinese helper (nested
# import): it must inherit zh from its own TU even though the first
# listed TU is English.
mkdir -p "$TMP/bp1-mixed/src"
cat > "$TMP/bp1-mixed/aster.proj" <<'SRC'
name bp1-mixed
[language]
default = "zh"
"src/fw_en.ast" = "en"
src/fw_en.ast
src/app_zh.ast
SRC
cat > "$TMP/bp1-mixed/src/fw_en.ast" <<'SRC'
fn fw_value(): i32 {
return 40;
}
SRC
cat > "$TMP/bp1-mixed/src/app_zh.ast" <<'SRC'
导入 "helper_zh.ast"
方法 启动方法(): 整数
返回 fw_value() + 加一(0)
结束 方法
SRC
cat > "$TMP/bp1-mixed/src/helper_zh.ast" <<'SRC'
导入 "base_zh.ast"
方法 加一(值: 整数): 整数
返回 值 + 基础值()
结束 方法
SRC
cat > "$TMP/bp1-mixed/src/base_zh.ast" <<'SRC'
方法 基础值(): 整数
返回 1
结束 方法
SRC
echo '[B-P1] per-file [language] entries mix English and Chinese sources'
(cd "$TMP/bp1-mixed" && "$ASTER_BIN" build > build.log 2>&1) || {
    echo 'FAIL: B-P1 mixed-language project build failed' >&2
    cat "$TMP/bp1-mixed/build.log" >&2; exit 1;
}
if "$RUNNER" "$TMP/bp1-mixed/build/bp1-mixed"; then status=0; else status=$?; fi
[ "$status" -eq 41 ] || { echo "FAIL: B-P1 mixed-language result was $status, expected 41" >&2; exit 1; }
(cd "$TMP/bp1-mixed" && "$ASTER_BIN" build > build-cache.log 2>&1)
grep -q '0 compiled, 2 reused' "$TMP/bp1-mixed/build-cache.log" || {
    echo 'FAIL: B-P1 mixed-language rebuild did not reuse its cache' >&2
    cat "$TMP/bp1-mixed/build-cache.log" >&2; exit 1;
}
# Per-file entries are part of the cache key: flipping one must not reuse
# an object compiled under the other language.
sed -i 's#"src/fw_en.ast" = "en"#"src/fw_en.ast" = "zh"#' "$TMP/bp1-mixed/aster.proj"
if (cd "$TMP/bp1-mixed" && "$ASTER_BIN" build > build-flip.log 2>&1); then
    echo 'FAIL: B-P1 per-file flip to zh reused the English object' >&2; exit 1;
fi
sed -i 's#"src/fw_en.ast" = "zh"#"src/fw_en.ast" = "en"#' "$TMP/bp1-mixed/aster.proj"

# B-P1 precedence negatives: a file directive beats a per-file entry, and
# an unknown [language] key is still rejected (a typo must not silently
# become a per-file entry).
mkdir -p "$TMP/bp1-neg"
cat > "$TMP/bp1-neg/aster.proj" <<'SRC'
name bp1-neg
[language]
default = "zh"
"bad.ast" = "en"
main.ast
SRC
cat > "$TMP/bp1-neg/bad.ast" <<'SRC'
// aster:language=zh
fn bad(): i32 {
return 1;
}
SRC
cat > "$TMP/bp1-neg/main.ast" <<'SRC'
方法 启动方法(): 整数
返回 0
结束 方法
SRC
echo '[B-P1] a file directive beats a per-file entry'
if (cd "$TMP/bp1-neg" && "$ASTER_BIN" build-cn-obj bad.ast -o bad.o 2> bad.err); then
    echo 'FAIL: B-P1 directive losing to a per-file entry was accepted' >&2; exit 1;
fi
cat > "$TMP/bp1-neg/aster.proj" <<'SRC'
name bp1-neg
[language]
default = "zh"
bogus = "en"
main.ast
SRC
if (cd "$TMP/bp1-neg" && "$ASTER_BIN" build > build.err 2>&1); then
    echo 'FAIL: B-P1 unknown language setting was accepted' >&2; exit 1;
fi
grep -q "unknown language setting 'bogus'" "$TMP/bp1-neg/build.err" || {
    cat "$TMP/bp1-neg/build.err" >&2; exit 1;
}

echo 'PASS: Chinese module import checks'
