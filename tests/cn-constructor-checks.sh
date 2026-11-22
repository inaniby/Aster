#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ASTER_BIN=${ASTER_BIN:-$ROOT/.tmp-ci/adapter/aster-constructor}
if [ ! -x "$ASTER_BIN" ]; then
    echo "set ASTER_BIN to a built Aster executable" >&2
    exit 2
fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

cat > "$TMP/constructor-zh.ast" <<'SRC'
// aster:language=zh
类 基本
变量 基值: 整数
@构造
方法 构造(值: 整数)
本对象.基值 = 值
结束 方法
结束 类
类 派生 : 基本
变量 当前值: 整数
@构造
方法 初始化(值: 整数): 空
父对象(值 + 38)
本对象.当前值 = 值
结束 方法
方法 总计(): 整数
返回 本对象.基值 + 本对象.当前值
结束 方法
结束 类
类 字段基类
变量 分数: 整数 = 10
@构造
方法 构造()
本对象.分数 = 本对象.分数 + 1
结束 方法
结束 类
类 字段子类 : 字段基类
变量 复制值: 整数 = 本对象.分数 + 2
变量 数组值: 整数[2] = [3, 4]
@构造
方法 构造()
本对象.复制值 = 本对象.复制值 + 1
结束 方法
方法 总计(): 整数
返回 本对象.分数 + 本对象.复制值 + 本对象.数组值[0] + 本对象.数组值[1]
结束 方法
结束 类
类 参数来源
变量 值: 整数
@构造
方法 构造(输入: 整数)
本对象.值 = 输入
结束 方法
方法 获取(): 整数
返回 本对象.值
结束 方法
结束 类
类 包装 : 基本
@构造
方法 构造()
父对象(参数来源(5).获取())
结束 方法
方法 获取(): 整数
返回 本对象.基值
结束 方法
结束 类
类 中间 : 基本
变量 中间值: 整数
@构造
方法 构造(值: 整数): 空
父对象(值 + 1)
本对象.中间值 = 值
结束 方法
结束 类
类 叶子 : 中间
变量 叶子值: 整数
@构造
方法 构造(值: 整数): 空
父对象(值 * 2)
本对象.叶子值 = 值
结束 方法
方法 总计(): 整数
返回 本对象.基值 + 本对象.中间值 + 本对象.叶子值
结束 方法
结束 类
类 旧式
变量 数值: 整数
方法 设置(值: 整数)
本对象.数值 = 值
结束 方法
方法 获取(): 整数
返回 本对象.数值
结束 方法
结束 类
变量 调用次数: 整数 = 0
方法 下一个值(): 整数
调用次数 = 调用次数 + 1
返回 2
结束 方法
方法 无返回值()
调用次数 = 调用次数 + 0
结束 方法
方法 启动方法(): 整数
变量 对象: 派生 = 派生(下一个值())
变量 包装对象: 包装 = 包装()
变量 多层: 叶子 = 叶子(3)
变量 字段对象: 字段子类 = 字段子类()
变量 旧对象: 旧式 = 旧式()
旧对象.设置(0)
无返回值()
返回 对象.总计() - 42 + 包装对象.获取() - 5 + 多层.总计() - 16 + 字段对象.总计() - 32 + 调用次数 - 1 + 旧对象.获取()
结束 方法
SRC

cat > "$TMP/constructor-en.ast" <<'SRC'
// aster:language=en
class Base {
let value: i32;
@constructor
fn constructor(value: i32) {
this.value = value;
}
}
class Derived: Base {
let extra: i32;
@constructor
fn initialize(value: i32): void {
super(value + 38);
this.extra = value;
}
fn total(): i32 { return this.value + this.extra; }
}
class FieldBase {
let score: i32 = 10;
@constructor
fn constructor() { this.score = this.score + 1; }
}
class FieldChild: FieldBase {
let copied: i32 = this.score + 2;
let values: i32[2] = [3, 4];
@constructor
fn constructor() { this.copied = this.copied + 1; }
fn total(): i32 { return this.score + this.copied + this.values[0] + this.values[1]; }
}
class ConstructorSource {
let value: i32;
@constructor
fn constructor(input: i32) {
this.value = input;
}
fn get(): i32 { return this.value; }
}
class Wrapped: Base {
@constructor
fn constructor() {
super(ConstructorSource(5).get());
}
fn get(): i32 { return this.value; }
}
class Middle: Base {
let middle: i32;
@constructor
fn constructor(value: i32): void {
super(value + 1);
this.middle = value;
}
}
class Leaf: Middle {
let leaf: i32;
@constructor
fn constructor(value: i32): void {
super(value * 2);
this.leaf = value;
}
fn total(): i32 { return this.value + this.middle + this.leaf; }
}
class Legacy {
let value: i32;
fn set(value: i32) {
this.value = value;
}
fn get(): i32 { return this.value; }
}
let calls: i32 = 0;
fn next(): i32 { calls = calls + 1; return 2; }
fn noValue() { calls = calls + 0; }
fn main(): i32 {
let object: Derived = Derived(next());
let wrapped: Wrapped = Wrapped();
let deep: Leaf = Leaf(3);
let fields: FieldChild = FieldChild();
let legacy: Legacy = Legacy();
legacy.set(0);
noValue();
return object.total() - 42 + wrapped.get() - 5 + deep.total() - 16 + fields.total() - 32 + calls - 1 + legacy.get();
}
SRC

"$ASTER_BIN" build-cn-obj "$TMP/constructor-zh.ast" -o "$TMP/constructor-zh.o"
"$ASTER_BIN" build-cn-obj --language en "$TMP/constructor-en.ast" \
    -o "$TMP/constructor-en.o"
"$ASTER_BIN" build-obj "$ROOT/stdlib/aster_std.ast" -o "$TMP/aster_std.o"

if [ "$(uname -s)" = Linux ] && [ "$(uname -m)" = aarch64 ]; then
    for language in zh en; do
        "$ASTER_BIN" link-obj "$TMP/constructor-$language.o" \
            "$TMP/aster_std.o" -o "$TMP/constructor-$language"
        if "$TMP/constructor-$language"; then status=0; else status=$?; fi
        [ "$status" -eq 0 ]
    done

    mkdir -p "$TMP/packages" "$TMP/app"
    cat > "$TMP/packages/model.ast" <<'SRC'
// aster:language=en
package fixture.model;
let initialValue: i32 = 41;
class Token {
let value: i32;
@constructor
fn constructor(value: i32): void { this.value = value; }
fn read(): i32 { return this.value; }
}
class Ready {
let value: i32 = initialValue;
fn read(): i32 { return this.value; }
}
class HiddenToken {
let value: i32;
@private
@constructor
fn constructor(value: i32): void { this.value = value; }
}
SRC
    cat > "$TMP/app/import.ast" <<'SRC'
// aster:language=zh
@导入("fixture.model").别名("model")
方法 启动方法(): 整数
返回 model.Token(41).read() - 41 + model.Ready().read() - 41
结束 方法
SRC
    "$ASTER_BIN" build-cn-obj --module-dir "$TMP/packages" \
        "$TMP/app/import.ast" -o "$TMP/import.o"
    "$ASTER_BIN" link-obj "$TMP/import.o" "$TMP/aster_std.o" -o "$TMP/import"
    if "$TMP/import"; then status=0; else status=$?; fi
    [ "$status" -eq 0 ]
    cat > "$TMP/app/hidden-import.ast" <<'SRC'
// aster:language=zh
@导入("fixture.model").别名("model")
方法 启动方法(): 整数
变量 值: model.HiddenToken = model.HiddenToken(1)
返回 0
结束 方法
SRC
    if "$ASTER_BIN" build-cn-obj --module-dir "$TMP/packages" \
        "$TMP/app/hidden-import.ast" -o "$TMP/hidden-import.o" \
        >"$TMP/hidden-import.log" 2>&1; then
        echo 'FAIL: an imported private constructor was accessible' >&2
        exit 1
    fi
    rg -q "constructor '.*HiddenToken' is hidden outside class" \
        "$TMP/hidden-import.log"
else
    echo 'SKIP: constructor execution requires AArch64 Linux'
fi

cat > "$TMP/multiple-constructors.ast" <<'SRC'
// aster:language=zh
类 多个构造器
@构造
方法 初始化(): 空
结束 方法
@构造
方法 创建(): 空
结束 方法
结束 类
方法 启动方法(): 整数
返回 0
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/multiple-constructors.ast" \
    -o "$TMP/multiple-constructors.o" >"$TMP/multiple-constructors.log" 2>&1; then
    echo 'FAIL: a class with multiple constructors was accepted' >&2
    exit 1
fi
rg -q 'a class can declare only one constructor' "$TMP/multiple-constructors.log"

cat > "$TMP/nonvoid-constructor.ast" <<'SRC'
// aster:language=zh
类 错误构造器
@构造
方法 构造(): 整数
返回 1
结束 方法
结束 类
方法 启动方法(): 整数
返回 0
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/nonvoid-constructor.ast" \
    -o "$TMP/nonvoid-constructor.o" >"$TMP/nonvoid-constructor.log" 2>&1; then
    echo 'FAIL: a constructor with a non-void result was accepted' >&2
    exit 1
fi
rg -q 'a constructor must be an instance method returning void' \
    "$TMP/nonvoid-constructor.log"

cat > "$TMP/wrong-arity.ast" <<'SRC'
// aster:language=zh
类 有参
@构造
方法 构造(值: 整数): 空
结束 方法
结束 类
方法 启动方法(): 整数
变量 值: 有参 = 有参()
返回 0
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/wrong-arity.ast" \
    -o "$TMP/wrong-arity.o" >"$TMP/wrong-arity.log" 2>&1; then
    echo 'FAIL: construction without required arguments was accepted' >&2
    exit 1
fi
if ! rg -Fq "class constructor for '有参' expects 1 argument(s), got 0" \
    "$TMP/wrong-arity.log"; then
    cat "$TMP/wrong-arity.log" >&2
    exit 1
fi

cat > "$TMP/manual-call.ast" <<'SRC'
// aster:language=zh
类 有参
@构造
方法 构造(值: 整数): 空
结束 方法
结束 类
方法 启动方法(): 整数
变量 值: 有参 = 有参(1)
返回 值.构造(1)
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/manual-call.ast" \
    -o "$TMP/manual-call.o" >"$TMP/manual-call.log" 2>&1; then
    echo 'FAIL: a constructor was callable as a regular instance method' >&2
    exit 1
fi
rg -q 'a constructor can only be invoked through its class name' \
    "$TMP/manual-call.log"

cat > "$TMP/base-arity.ast" <<'SRC'
// aster:language=zh
类 基类
@构造
方法 构造(值: 整数): 空
结束 方法
结束 类
类 子类 : 基类
结束 类
方法 启动方法(): 整数
返回 0
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/base-arity.ast" \
    -o "$TMP/base-arity.o" >"$TMP/base-arity.log" 2>&1; then
    echo 'FAIL: a derived class with an implicit argument-requiring base constructor was accepted' >&2
    exit 1
fi
rg -q 'a derived class must declare a constructor to pass arguments to its base class' \
    "$TMP/base-arity.log"

cat > "$TMP/base-arity-mismatch.ast" <<'SRC'
// aster:language=zh
类 基类
@构造
方法 构造(值: 整数): 空
结束 方法
结束 类
类 子类 : 基类
@构造
方法 构造(): 空
父对象()
结束 方法
结束 类
方法 启动方法(): 整数
返回 0
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/base-arity-mismatch.ast" \
    -o "$TMP/base-arity-mismatch.o" >"$TMP/base-arity-mismatch.log" 2>&1; then
    echo 'FAIL: an explicit base constructor call with the wrong arity was accepted' >&2
    exit 1
fi
rg -q "base constructor for '基类' expects 1 argument\\(s\\), got 0" \
    "$TMP/base-arity-mismatch.log"

cat > "$TMP/misplaced-super.ast" <<'SRC'
// aster:language=zh
类 基类
结束 类
类 子类 : 基类
方法 错误(): 空
父对象()
结束 方法
结束 类
方法 启动方法(): 整数
返回 0
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/misplaced-super.ast" \
    -o "$TMP/misplaced-super.o" >"$TMP/misplaced-super.log" 2>&1; then
    echo 'FAIL: a parent constructor call outside a constructor was accepted' >&2
    exit 1
fi
rg -q 'a parent constructor call must be the first statement of a constructor' \
    "$TMP/misplaced-super.log"

cat > "$TMP/unbuilt-parent-argument.ast" <<'SRC'
// aster:language=zh
类 基类
@构造
方法 构造(值: 整数)
结束 方法
结束 类
类 子类 : 基类
@构造
方法 构造(): 空
父对象(未声明变量)
结束 方法
结束 类
方法 启动方法(): 整数
返回 0
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/unbuilt-parent-argument.ast" \
    -o "$TMP/unbuilt-parent-argument.o" >"$TMP/unbuilt-parent-argument.log" 2>&1; then
    echo 'FAIL: an unresolved base constructor argument in an unbuilt class was accepted' >&2
    exit 1
fi
rg -q 'unknown variable: 未声明变量' "$TMP/unbuilt-parent-argument.log"

cat > "$TMP/wrong-field-array-length.ast" <<'SRC'
// aster:language=zh
类 数组初值错误
变量 数值: 整数[2] = [1]
结束 类
方法 启动方法(): 整数
返回 0
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/wrong-field-array-length.ast" \
    -o "$TMP/wrong-field-array-length.o" >"$TMP/wrong-field-array-length.log" 2>&1; then
    echo 'FAIL: a class array initializer with the wrong length was accepted' >&2
    exit 1
fi
rg -q 'array field initializer length does not match declared array length' \
    "$TMP/wrong-field-array-length.log"

cat > "$TMP/unbuilt-field-initializer.ast" <<'SRC'
// aster:language=zh
类 未使用字段错误
变量 数值: 整数 = 未声明变量
结束 类
方法 启动方法(): 整数
返回 0
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/unbuilt-field-initializer.ast" \
    -o "$TMP/unbuilt-field-initializer.o" >"$TMP/unbuilt-field-initializer.log" 2>&1; then
    echo 'FAIL: an unresolved initializer on an unused class was accepted' >&2
    exit 1
fi
rg -q 'unknown variable: 未声明变量' "$TMP/unbuilt-field-initializer.log"

cat > "$TMP/field-type-mismatch-zh.ast" <<'SRC'
// aster:language=zh
类 字段类型错误
变量 value: 整数 = "wrong"
结束 类
方法 启动方法(): 整数
返回 0
结束 方法
SRC
cat > "$TMP/field-type-mismatch-en.ast" <<'SRC'
// aster:language=en
class FieldTypeError {
let value: i32 = "wrong";
}
fn main(): i32 { return 0; }
SRC
for language in zh en; do
    if "$ASTER_BIN" build-cn-obj --language "$language" \
        "$TMP/field-type-mismatch-$language.ast" \
        -o "$TMP/field-type-mismatch-$language.o" \
        >"$TMP/field-type-mismatch-$language.log" 2>&1; then
        echo "FAIL: an incompatible $language class field initializer was accepted" >&2
        exit 1
    fi
    if [ "$language" = zh ]; then
        rg -Fq "类字段 'value' 的初值类型不匹配：需要 i32，实际为 string" \
            "$TMP/field-type-mismatch-$language.log"
    else
        rg -Fq "type mismatch initializing class field 'value': expected i32, got string" \
            "$TMP/field-type-mismatch-$language.log"
    fi
done

cat > "$TMP/field-narrowing.ast" <<'SRC'
// aster:language=zh
类 字段窄化错误
变量 value: 字节 = 128
结束 类
方法 启动方法(): 整数
返回 0
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/field-narrowing.ast" \
    -o "$TMP/field-narrowing.o" >"$TMP/field-narrowing.log" 2>&1; then
    echo 'FAIL: an out-of-range class field initializer was accepted' >&2
    exit 1
fi
rg -Fq "类字段 'value' 的初值类型不匹配：需要 i8，实际为 i32" \
    "$TMP/field-narrowing.log"

cat > "$TMP/field-class-mismatch.ast" <<'SRC'
// aster:language=zh
类 目标类型
结束 类
类 不相关类型
结束 类
类 字段类引用错误
变量 value: 目标类型 = 不相关类型()
结束 类
方法 启动方法(): 整数
返回 0
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/field-class-mismatch.ast" \
    -o "$TMP/field-class-mismatch.o" >"$TMP/field-class-mismatch.log" 2>&1; then
    echo 'FAIL: an unrelated class reference initialized a class field' >&2
    exit 1
fi
if ! rg -Fq "类字段 'value' 的初值类型不匹配：需要 ptr<目标类型>，实际为 ptr<不相关类型>" \
    "$TMP/field-class-mismatch.log"; then
    cat "$TMP/field-class-mismatch.log" >&2
    exit 1
fi

cat > "$TMP/field-function-mismatch.ast" <<'SRC'
// aster:language=zh
类 字段函数类型错误
变量 source: 方法(整数):整数
变量 callback: 方法(字符串):整数 = 本对象.source
结束 类
方法 启动方法(): 整数
返回 0
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/field-function-mismatch.ast" \
    -o "$TMP/field-function-mismatch.o" >"$TMP/field-function-mismatch.log" 2>&1; then
    echo 'FAIL: an incompatible function pointer initialized a class field' >&2
    exit 1
fi
rg -Fq "类字段 'callback' 的函数签名不匹配" \
    "$TMP/field-function-mismatch.log"

cat > "$TMP/field-array-type-mismatch.ast" <<'SRC'
// aster:language=zh
类 字段数组类型错误
变量 values: 整数[2] = [1, 真]
结束 类
方法 启动方法(): 整数
返回 0
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/field-array-type-mismatch.ast" \
    -o "$TMP/field-array-type-mismatch.o" >"$TMP/field-array-type-mismatch.log" 2>&1; then
    echo 'FAIL: a class array field accepted an incompatible element' >&2
    exit 1
fi
if ! rg -Fq "类字段 'values' 的初值类型不匹配：需要 i32，实际为 bool" \
    "$TMP/field-array-type-mismatch.log"; then
    cat "$TMP/field-array-type-mismatch.log" >&2
    exit 1
fi

cat > "$TMP/field-access-zh.ast" <<'SRC'
// aster:language=zh
类 隐藏状态
@隐藏
变量 secret: 整数
结束 类
类 隐藏访问错误
变量 value: 整数 = 隐藏状态().secret
结束 类
方法 启动方法(): 整数
返回 0
结束 方法
SRC
cat > "$TMP/field-access-en.ast" <<'SRC'
// aster:language=en
class HiddenState {
@private
let secret: i32;
}
class HiddenAccessError {
let value: i32 = HiddenState().secret;
}
fn main(): i32 { return 0; }
SRC
for language in zh en; do
    if "$ASTER_BIN" build-cn-obj --language "$language" \
        "$TMP/field-access-$language.ast" -o "$TMP/field-access-$language.o" \
        >"$TMP/field-access-$language.log" 2>&1; then
        echo "FAIL: a $language field initializer accessed a private field" >&2
        exit 1
    fi
    if [ "$language" = zh ]; then
        rg -Fq "field 'secret' is hidden outside class '隐藏状态'" \
            "$TMP/field-access-$language.log"
    else
        rg -Fq "field 'secret' is hidden outside class 'HiddenState'" \
            "$TMP/field-access-$language.log"
    fi
done

echo 'PASS: bilingual class constructor checks'
