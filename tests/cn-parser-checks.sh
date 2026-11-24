#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
c++ -std=c++17 -Wall -Wextra -Wpedantic -Werror \
    "$ROOT/src/cn_parse_main.cpp" "$ROOT/src/cn_parser.cpp" "$ROOT/src/cn_lexer.cpp" \
    -o "$TMP/aster-cn-parse"

cat > "$TMP/counter-zh.ast" <<'SRC'
方法 启动方法(): 整数
变量 count: 整数 = 0
循环 (count < 3)
count = count + 1
结束 循环
返回 count
结束 方法
SRC
cat > "$TMP/counter-en.ast" <<'SRC'
// aster:language=en
fn main(): i32 {
let count: i32 = 0;
while (count < 3) {
count = count + 1;
}
return count;
}
SRC

printf '%s\n' '[1/16] Chinese and English sources produce one shared AST'
"$TMP/aster-cn-parse" "$TMP/counter-zh.ast" > "$TMP/zh.ast.out"
"$TMP/aster-cn-parse" "$TMP/counter-en.ast" > "$TMP/en.ast.out"
cmp "$TMP/zh.ast.out" "$TMP/en.ast.out"
grep -q '(Method "main" "i32"' "$TMP/zh.ast.out"
grep -q '(WhileLoopStatement' "$TMP/zh.ast.out"
grep -q '(VariableDeclaration "count" "i32"' "$TMP/zh.ast.out"

cat > "$TMP/start-zh.ast" <<'SRC'
方法 启动方法(): 整数
返回 7
结束 方法
SRC
cat > "$TMP/start-en.ast" <<'SRC'
// aster:language=en
fn main(): i32 {
return 7;
}
SRC
"$TMP/aster-cn-parse" "$TMP/start-zh.ast" > "$TMP/start-zh.out"
"$TMP/aster-cn-parse" "$TMP/start-en.ast" > "$TMP/start-en.out"
cmp "$TMP/start-zh.out" "$TMP/start-en.out"
grep -q '(Method "main" "i32"' "$TMP/start-zh.out"
printf '%s\n' '[entry] Chinese 启动方法 normalizes to the shared main AST name'

cat > "$TMP/english-entry-in-zh.ast" <<'SRC'
方法 main(): 整数
返回 0
结束 方法
SRC
if "$TMP/aster-cn-parse" "$TMP/english-entry-in-zh.ast" \
    > /dev/null 2> "$TMP/english-entry-in-zh.err"; then
    echo 'FAIL: Chinese main entry spelling was accepted' >&2
    exit 1
fi
grep -q '中文入口方法应命名为' "$TMP/english-entry-in-zh.err"

cat > "$TMP/package-zh.ast" <<'SRC'
// package metadata ignores comments and blank lines

包名 标准库.数学 = standard.math
@导入("标准库.字符串").别名("text")
方法 启动方法(): 整数
返回 0
结束 方法
SRC
cat > "$TMP/package-en.ast" <<'SRC'
// aster:language=en
// package metadata ignores comments and blank lines

package 标准库.数学 = standard.math;
@import("标准库.字符串").alias("text")
fn main(): i32 {
return 0;
}
SRC
"$TMP/aster-cn-parse" "$TMP/package-zh.ast" > "$TMP/package-zh.out"
"$TMP/aster-cn-parse" "$TMP/package-en.ast" > "$TMP/package-en.out"
cmp "$TMP/package-zh.out" "$TMP/package-en.out"
grep -q '(Package "标准库.数学" (Alias "standard.math"))' "$TMP/package-zh.out"
grep -q '(Alias "standard.math")' "$TMP/package-zh.out"
grep -q '(Import "标准库.字符串" "text")' "$TMP/package-zh.out"
printf '%s\n' '[package] package headers and import aliases normalize bilingually'

cat > "$TMP/package-late.ast" <<'SRC'
方法 first(): 整数
返回 1
结束 方法
包名 invalid.late
SRC
if "$TMP/aster-cn-parse" "$TMP/package-late.ast" > /dev/null 2> "$TMP/package-late.err"; then
    echo 'FAIL: package declaration after a declaration was accepted' >&2
    exit 1
fi
grep -q 'package declaration must be the first declaration' "$TMP/package-late.err"

cat > "$TMP/import-empty-alias.ast" <<'SRC'
@导入("standard.math").别名("")
方法 启动方法(): 整数
返回 0
结束 方法
SRC
if "$TMP/aster-cn-parse" "$TMP/import-empty-alias.ast" > /dev/null 2> "$TMP/import-empty-alias.err"; then
    echo 'FAIL: empty import alias was accepted' >&2
    exit 1
fi
grep -q 'import alias must be an identifier' "$TMP/import-empty-alias.err"

cat > "$TMP/if-zh.ast" <<'SRC'
方法 启动方法(): 整数
变量 count: 整数 = 1
如果 (count == 1)
返回 10
否则如果 (count == 2)
返回 20
否则
返回 30
结束 如果
返回 0
结束 方法
SRC
cat > "$TMP/if-en.ast" <<'SRC'
// aster:language=en
fn main(): i32 {
let count: i32 = 1;
if (count == 1) {
return 10;
} else if (count == 2) {
return 20;
} else {
return 30;
}
return 0;
}
SRC
printf '%s\n' '[2/16] else-if branches normalize to the same AST'
"$TMP/aster-cn-parse" "$TMP/if-zh.ast" > "$TMP/if-zh.out"
"$TMP/aster-cn-parse" "$TMP/if-en.ast" > "$TMP/if-en.out"
cmp "$TMP/if-zh.out" "$TMP/if-en.out"
grep -q '(IfStatement' "$TMP/if-zh.out"

cat > "$TMP/count-zh.ast" <<'SRC'
方法 启动方法(): 整数
变量 total: 整数 = 0
计次循环 (i = 1, 3, 1)
total = total + i
结束 计次循环
返回 total
结束 方法
SRC
cat > "$TMP/count-en.ast" <<'SRC'
// aster:language=en
fn main(): i32 {
let total: i32 = 0;
for (i = 1, 3, 1) {
total = total + i;
}
return total;
}
SRC
printf '%s\n' '[3/16] count loops preserve range expressions and normalize bilingually'
"$TMP/aster-cn-parse" "$TMP/count-zh.ast" > "$TMP/count-zh.out"
"$TMP/aster-cn-parse" "$TMP/count-en.ast" > "$TMP/count-en.out"
cmp "$TMP/count-zh.out" "$TMP/count-en.out"
grep -q '(CountLoopStatement "i" (IntegerLiteral "1") (IntegerLiteral "3") (IntegerLiteral "1")' "$TMP/count-zh.out"

cat > "$TMP/count-no-counter.ast" <<'SRC'
方法 启动方法(): 整数
计次循环 (1, 3)
返回 0
结束 计次循环
返回 0
结束 方法
SRC
"$TMP/aster-cn-parse" "$TMP/count-no-counter.ast" > "$TMP/count-no-counter.out"
grep -q '(CountLoopStatement (IntegerLiteral "1") (IntegerLiteral "3")' "$TMP/count-no-counter.out"

cat > "$TMP/match-zh.ast" <<'SRC'
方法 启动方法(): 整数
变量 value: 整数 = 20
变量 result: 整数 = 0
假如 value
是 18
result = 1
是 20, 21
result = 2
否则
result = 3
结束 假如
返回 result
结束 方法
SRC
cat > "$TMP/match-en.ast" <<'SRC'
// aster:language=en
fn main(): i32 {
let value: i32 = 20;
let result: i32 = 0;
switch (value) {
case 18
result = 1;
case 20, 21
result = 2;
else
result = 3;
}
return result;
}
SRC
printf '%s\n' '[4/16] match multi-value arms normalize bilingually'
"$TMP/aster-cn-parse" "$TMP/match-zh.ast" > "$TMP/match-zh.out"
"$TMP/aster-cn-parse" "$TMP/match-en.ast" > "$TMP/match-en.out"
cmp "$TMP/match-zh.out" "$TMP/match-en.out"
grep -q '(MatchStatement (Identifier "value") (Case (IntegerLiteral "18")' "$TMP/match-zh.out"

printf '%s\n' '[5/16] mismatched Chinese block closes are rejected'
cat > "$TMP/mismatch.ast" <<'SRC'
方法 启动方法(): 整数
返回 0
结束 循环
SRC
if "$TMP/aster-cn-parse" "$TMP/mismatch.ast" > /dev/null 2> "$TMP/mismatch.err"; then
    echo 'FAIL: mismatched block close accepted' >&2; exit 1
fi
grep -q 'mismatched block close' "$TMP/mismatch.err"

cat > "$TMP/count-mismatch.ast" <<'SRC'
方法 启动方法(): 整数
计次循环 (1, 2)
返回 0
结束 循环
结束 方法
SRC
if "$TMP/aster-cn-parse" "$TMP/count-mismatch.ast" > /dev/null 2> "$TMP/count-mismatch.err"; then
    echo 'FAIL: mismatched count-loop close accepted' >&2; exit 1
fi
grep -q 'expected .CountLoop.' "$TMP/count-mismatch.err"

printf '%s\n' '[6/16] Chinese and English block syntax cannot be mixed'
cat > "$TMP/mixed.ast" <<'SRC'
方法 启动方法(): 整数 {
返回 0
}
SRC
if "$TMP/aster-cn-parse" "$TMP/mixed.ast" > /dev/null 2> "$TMP/mixed.err"; then
    echo 'FAIL: English brace block accepted in zh mode' >&2; exit 1
fi
grep -q 'expected a newline before the block body' "$TMP/mixed.err"

printf '%s\n' '[7/16] generated-name prefix is reserved'
cat > "$TMP/reserved-name.ast" <<'SRC'
方法 __aster_user(): 整数
返回 0
结束 方法
SRC
if "$TMP/aster-cn-parse" "$TMP/reserved-name.ast" > /dev/null 2> "$TMP/reserved-name.err"; then
    echo 'FAIL: reserved identifier prefix accepted' >&2; exit 1
fi
grep -q "identifier prefix '__aster_' is reserved" "$TMP/reserved-name.err"

cat > "$TMP/array-zh.ast" <<'SRC'
方法 启动方法(): 整数
变量 items: 整数[3] = [4, 5, 6]
items[1] = items[0] + 2
返回 items[1]
结束 方法
SRC
cat > "$TMP/array-en.ast" <<'SRC'
// aster:language=en
fn main(): i32 {
let items: i32[3] = [4, 5, 6];
items[1] = items[0] + 2;
return items[1];
}
SRC
printf '%s\n' '[8/16] fixed arrays and indexed stores normalize bilingually'
"$TMP/aster-cn-parse" "$TMP/array-zh.ast" > "$TMP/array-zh.out"
"$TMP/aster-cn-parse" "$TMP/array-en.ast" > "$TMP/array-en.out"
cmp "$TMP/array-zh.out" "$TMP/array-en.out"
grep -q '(Dimensions "3")' "$TMP/array-zh.out"
grep -q '(Index (Identifier "items") (IntegerLiteral "1"))' "$TMP/array-zh.out"

cat > "$TMP/foreach-zh.ast" <<'SRC'
方法 启动方法(): 整数
变量 items: 整数[3] = [4, 5, 6]
遍历循环 (item -> items)
返回 0
结束 遍历循环
遍历循环 (index, item2 -> items)
返回 0
结束 遍历循环
返回 0
结束 方法
SRC
cat > "$TMP/foreach-en.ast" <<'SRC'
// aster:language=en
fn main(): i32 {
let items: i32[3] = [4, 5, 6];
foreach item in items {
return 0;
}
foreach index, item2 in items {
return 0;
}
return 0;
}
SRC
printf '%s\n' '[9/16] foreach bindings and arrow/in forms normalize bilingually'
"$TMP/aster-cn-parse" "$TMP/foreach-zh.ast" > "$TMP/foreach-zh.out"
"$TMP/aster-cn-parse" "$TMP/foreach-en.ast" > "$TMP/foreach-en.out"
cmp "$TMP/foreach-zh.out" "$TMP/foreach-en.out"
grep -q '(ForEachLoopStatement "item" (Identifier "items")' "$TMP/foreach-zh.out"
grep -q '(ForEachLoopStatement "index" "item2" (Identifier "items")' "$TMP/foreach-zh.out"

cat > "$TMP/enumloop-zh.ast" <<'SRC'
方法 启动方法(): 整数
枚举循环 (条目 -> 用户甲)
返回 0
结束 枚举循环
返回 0
结束 方法
SRC
cat > "$TMP/enumloop-en.ast" <<'SRC'
// aster:language=en
fn main(): i32 {
enumloop 条目 in 用户甲 {
return 0;
}
return 0;
}
SRC
printf '%s\n' '[10/16] enumloop arrow/in forms normalize bilingually'
"$TMP/aster-cn-parse" "$TMP/enumloop-zh.ast" > "$TMP/enumloop-zh.out"
"$TMP/aster-cn-parse" "$TMP/enumloop-en.ast" > "$TMP/enumloop-en.out"
cmp "$TMP/enumloop-zh.out" "$TMP/enumloop-en.out"
grep -q '(EnumLoopStatement "条目" (Identifier "用户甲")' "$TMP/enumloop-zh.out"

cat > "$TMP/float-zh.ast" <<'SRC'
方法 启动方法(): 整数
变量 first: 小数 = 1.25e1
变量 mask: 整数 = 0xDE
返回 0
结束 方法
SRC
cat > "$TMP/float-en.ast" <<'SRC'
// aster:language=en
fn main(): i32 {
let first: f64 = 1.25e1;
let mask: i32 = 0xDE;
return 0;
}
SRC
printf '%s\n' '[11/16] float and hexadecimal literals normalize bilingually'
"$TMP/aster-cn-parse" "$TMP/float-zh.ast" > "$TMP/float-zh.out"
"$TMP/aster-cn-parse" "$TMP/float-en.ast" > "$TMP/float-en.out"
cmp "$TMP/float-zh.out" "$TMP/float-en.out"
grep -q '(FloatLiteral "1.25e1")' "$TMP/float-zh.out"
grep -q '(IntegerLiteral "0xDE")' "$TMP/float-zh.out"

cat > "$TMP/cast-zh.ast" <<'SRC'
方法 启动方法(): 整数
变量 single: 单精度 = 单精度(1.0)
变量 precise: 小数 = 小数(1)
返回 0
结束 方法
SRC
cat > "$TMP/cast-en.ast" <<'SRC'
// aster:language=en
fn main(): i32 {
let single: f32 = f32(1.0);
let precise: f64 = f64(1);
return 0;
}
SRC
printf '%s\n' '[12/16] scalar casts normalize bilingually'
"$TMP/aster-cn-parse" "$TMP/cast-zh.ast" > "$TMP/cast-zh.out"
"$TMP/aster-cn-parse" "$TMP/cast-en.ast" > "$TMP/cast-en.out"
cmp "$TMP/cast-zh.out" "$TMP/cast-en.out"
grep -q '(Call (TypeName "f32") (FloatLiteral "1.0"))' "$TMP/cast-zh.out"
grep -q '(Call (TypeName "f64") (IntegerLiteral "1"))' "$TMP/cast-zh.out"

cat > "$TMP/struct-zh.ast" <<'SRC'
结构 Inner
value: 整数
label: 字符串
结束 结构
结构 Record
nested: Inner
ready: 逻辑型
single: 单精度
precise: 小数
结束 结构
方法 启动方法(): 整数
变量 item: Record
item.nested.value = 27
返回 item.nested.value
结束 方法
SRC
cat > "$TMP/struct-en.ast" <<'SRC'
// aster:language=en
struct Inner { value: i32, label: string }
struct Record { nested: Inner, ready: bool, single: f32, precise: f64 }
fn main(): i32 {
let item: Record;
item.nested.value = 27;
return item.nested.value;
}
SRC
printf '%s\n' '[13/16] structure declarations and nested members normalize bilingually'
"$TMP/aster-cn-parse" "$TMP/struct-zh.ast" > "$TMP/struct-zh.out"
"$TMP/aster-cn-parse" "$TMP/struct-en.ast" > "$TMP/struct-en.out"
cmp "$TMP/struct-zh.out" "$TMP/struct-en.out"
grep -q '(Structure "Inner" (Fields (Field "value" "i32") (Field "label" "string")))' "$TMP/struct-zh.out"
grep -q '(Member (Member (Identifier "item") (Identifier "nested")) (Identifier "value"))' "$TMP/struct-zh.out"

cat > "$TMP/struct-array-field-zh.ast" <<'SRC'
结构 Table
items: 整数[2]
结束 结构
方法 启动方法(): 整数
变量 table: Table
table.items[1] = 8
返回 table.items[1]
结束 方法
SRC
cat > "$TMP/struct-array-field-en.ast" <<'SRC'
// aster:language=en
struct Table { items: i32[2] }
fn main(): i32 {
let table: Table;
table.items[1] = 8;
return table.items[1];
}
SRC
printf '%s\n' '[14/16] structure array fields normalize bilingually'
"$TMP/aster-cn-parse" "$TMP/struct-array-field-zh.ast" > "$TMP/struct-array-field-zh.out"
"$TMP/aster-cn-parse" "$TMP/struct-array-field-en.ast" > "$TMP/struct-array-field-en.out"
cmp "$TMP/struct-array-field-zh.out" "$TMP/struct-array-field-en.out"
grep -q '(Dimensions "2")' "$TMP/struct-array-field-zh.out"
grep -q '(Index (Member (Identifier "table") (Identifier "items")) (IntegerLiteral "1"))' "$TMP/struct-array-field-zh.out"

cat > "$TMP/struct-array-element-zh.ast" <<'SRC'
结构 Point
x: 整数
y: 整数
结束 结构
方法 启动方法(): 整数
变量 points: Point[2] = [Point { 1, 2 }, Point { 3, 4 }]
返回 points[1].y
结束 方法
SRC
cat > "$TMP/struct-array-element-en.ast" <<'SRC'
// aster:language=en
struct Point { x: i32, y: i32 }
fn main(): i32 {
let points: Point[2] = [Point { 1, 2 }, Point { 3, 4 }];
return points[1].y;
}
SRC
printf '%s\n' '[15/16] structure array element members normalize bilingually'
"$TMP/aster-cn-parse" "$TMP/struct-array-element-zh.ast" > "$TMP/struct-array-element-zh.out"
"$TMP/aster-cn-parse" "$TMP/struct-array-element-en.ast" > "$TMP/struct-array-element-en.out"
cmp "$TMP/struct-array-element-zh.out" "$TMP/struct-array-element-en.out"
grep -q '(Member (Index (Identifier "points") (IntegerLiteral "1")) (Identifier "y"))' "$TMP/struct-array-element-zh.out"

cat > "$TMP/struct-literal-zh.ast" <<'SRC'
结构 Pair
left: 整数
right: 整数
结束 结构
方法 启动方法(): 整数
变量 pair: Pair = Pair { 10, 20 }
返回 pair.left + pair.right
结束 方法
SRC
cat > "$TMP/struct-literal-en.ast" <<'SRC'
// aster:language=en
struct Pair { left: i32, right: i32 }
fn main(): i32 {
let pair: Pair = Pair { 10, 20 };
return pair.left + pair.right;
}
SRC
printf '%s\n' '[16/16] structure literals and enum declarations normalize bilingually'
"$TMP/aster-cn-parse" "$TMP/struct-literal-zh.ast" > "$TMP/struct-literal-zh.out"
"$TMP/aster-cn-parse" "$TMP/struct-literal-en.ast" > "$TMP/struct-literal-en.out"
cmp "$TMP/struct-literal-zh.out" "$TMP/struct-literal-en.out"
grep -q '(StructLiteral "Pair" (IntegerLiteral "10") (IntegerLiteral "20"))' "$TMP/struct-literal-zh.out"

cat > "$TMP/enum-zh.ast" <<'SRC'
枚举 Color
Red
Green = 4
Blue = Green + 3
结束 枚举
方法 启动方法(): 整数
变量 selected: Color = Blue
返回 selected
结束 方法
SRC
cat > "$TMP/enum-en.ast" <<'SRC'
// aster:language=en
enum Color {
Red,
Green = 4,
Blue = Green + 3
}
fn main(): i32 {
let selected: Color = Blue;
return selected;
}
SRC
"$TMP/aster-cn-parse" "$TMP/enum-zh.ast" > "$TMP/enum-zh.out"
"$TMP/aster-cn-parse" "$TMP/enum-en.ast" > "$TMP/enum-en.out"
cmp "$TMP/enum-zh.out" "$TMP/enum-en.out"
grep -q '(Enum "Color" (Members (Member "Red") (Member "Green" (IntegerLiteral "4")) (Member "Blue" (Binary "+" (Identifier "Green") (IntegerLiteral "3")))))' "$TMP/enum-zh.out"

cat > "$TMP/enum-braces-zh.ast" <<'SRC'
枚举 Color { Red, Blue }
方法 启动方法(): 整数
返回 0
结束 方法
SRC
if "$TMP/aster-cn-parse" "$TMP/enum-braces-zh.ast" \
    > /dev/null 2> "$TMP/enum-braces-zh.err"; then
    echo 'FAIL: Chinese brace-delimited enum was accepted' >&2
    exit 1
fi

cat > "$TMP/restricted-class-zh.ast" <<'SRC'
类 Base
@受限.类
方法 inherited(): 整数
返回 1
结束 方法
@隐藏
变量 secret: 整数
结束 类
方法 启动方法(): 整数
返回 0
结束 方法
SRC
cat > "$TMP/restricted-class-en.ast" <<'SRC'
// aster:language=en
class Base {
@protected
fn inherited(): i32 {
return 1;
}
@private
let secret: i32;
}
fn main(): i32 {
return 0;
}
SRC
"$TMP/aster-cn-parse" "$TMP/restricted-class-zh.ast" > "$TMP/restricted-class-zh.out"
"$TMP/aster-cn-parse" "$TMP/restricted-class-en.ast" > "$TMP/restricted-class-en.out"
cmp "$TMP/restricted-class-zh.out" "$TMP/restricted-class-en.out"
grep -q '(Visibility "protected")' "$TMP/restricted-class-zh.out"
grep -q '(Visibility "private")' "$TMP/restricted-class-zh.out"

cat > "$TMP/restricted-class-old-en.ast" <<'SRC'
// aster:language=en
class Base {
@restricted
fn inherited(): i32 {
return 1;
}
}
fn main(): i32 {
return 0;
}
SRC
if "$TMP/aster-cn-parse" "$TMP/restricted-class-old-en.ast" \
    > /dev/null 2> "$TMP/restricted-class-old-en.err"; then
    echo 'FAIL: English class member annotation @restricted was accepted' >&2
    exit 1
fi
grep -q "unknown class member annotation '@restricted'" "$TMP/restricted-class-old-en.err"

cat > "$TMP/restricted-top-level-old-en.ast" <<'SRC'
// aster:language=en
@restricted
fn private_value(): i32 {
return 1;
}
fn main(): i32 {
return 0;
}
SRC
if "$TMP/aster-cn-parse" "$TMP/restricted-top-level-old-en.ast" \
    > /dev/null 2> "$TMP/restricted-top-level-old-en.err"; then
    echo 'FAIL: English top-level annotation @restricted was accepted' >&2
    exit 1
fi
grep -q "unknown top-level annotation '@restricted'" "$TMP/restricted-top-level-old-en.err"

cat > "$TMP/closure-zh.ast" <<'SRC'
方法 启动方法(): 整数
变量 step: 整数 = 2
变量 offset: 整数 = 1
变量 increment = 方法 [step, offset] (value: 整数): 整数
返回 value + step + offset
结束 方法
变量 zero = 方法 (): 整数
返回 0
结束 方法
返回 increment(10) + zero()
结束 方法
类 Holder
变量 value: 整数
方法 read(): 整数
变量 get_value = 方法 [本对象] (): 整数
返回 本对象.value
结束 方法
返回 get_value()
结束 方法
结束 类
SRC
cat > "$TMP/closure-en.ast" <<'SRC'
// aster:language=en
fn main(): i32 {
let step: i32 = 2;
let offset: i32 = 1;
let increment = fn [step, offset] (value: i32): i32 {
return value + step + offset;
};
let zero = fn (): i32 {
return 0;
};
return increment(10) + zero();
}
class Holder {
let value: i32;
fn read(): i32 {
let get_value = fn [this] (): i32 {
return this.value;
};
return get_value();
}
}
SRC
"$TMP/aster-cn-parse" "$TMP/closure-zh.ast" > "$TMP/closure-zh.out"
"$TMP/aster-cn-parse" "$TMP/closure-en.ast" > "$TMP/closure-en.out"
cmp "$TMP/closure-zh.out" "$TMP/closure-en.out"
grep -q '(ClosureExpression (Captures "step" "offset") (Parameters (Parameter "value" "i32")) (Returns "i32")' "$TMP/closure-zh.out"
grep -q '(ClosureExpression (Captures "this") (Parameters) (Returns "i32")' "$TMP/closure-zh.out"

cat > "$TMP/closure-reference-capture.ast" <<'SRC'
方法 启动方法(): 整数
变量 step: 整数 = 2
变量 increment = 方法 [&step] (): 整数
返回 step
结束 方法
返回 0
结束 方法
SRC
if "$TMP/aster-cn-parse" "$TMP/closure-reference-capture.ast" \
    > /dev/null 2> "$TMP/closure-reference-capture.err"; then
    echo 'FAIL: reference capture was accepted' >&2
    exit 1
fi
grep -q '闭包只支持按值捕获' "$TMP/closure-reference-capture.err"

cat > "$TMP/closure-type-zh.ast" <<'SRC'
方法 apply(callback: 闭包(整数, 字符串): 整数): 闭包(): 空
返回 空
结束 方法
方法 启动方法(): 整数
变量 callback: 闭包(闭包(整数): 整数, 指针): 空
返回 0
结束 方法
SRC
cat > "$TMP/closure-type-en.ast" <<'SRC'
// aster:language=en
fn apply(callback: closure(i32, string): i32): closure(): void {
return null;
}
fn main(): i32 {
let callback: closure(closure(i32): i32, ptr): void;
return 0;
}
SRC
"$TMP/aster-cn-parse" "$TMP/closure-type-zh.ast" > "$TMP/closure-type-zh.out"
"$TMP/aster-cn-parse" "$TMP/closure-type-en.ast" > "$TMP/closure-type-en.out"
cmp "$TMP/closure-type-zh.out" "$TMP/closure-type-en.out"
grep -q '"closure(i32,string):i32"' "$TMP/closure-type-zh.out"
grep -q '"closure(closure(i32):i32,ptr):void"' "$TMP/closure-type-zh.out"

cat > "$TMP/closure-type-arrow-zh.ast" <<'SRC'
方法 启动方法(): 整数
变量 回调: 闭包(整数)->整数
返回 0
结束 方法
SRC
if "$TMP/aster-cn-parse" "$TMP/closure-type-arrow-zh.ast" \
    > /dev/null 2> "$TMP/closure-type-arrow-zh.err"; then
    echo 'FAIL: arrow return syntax was accepted by the Chinese frontend' >&2
    exit 1
fi
grep -q "expected ':' after closure parameter types" "$TMP/closure-type-arrow-zh.err"

cat > "$TMP/closure-type-arrow-en.ast" <<'SRC'
// aster:language=en
fn main(): i32 {
let callback: closure(i32) -> i32;
return 0;
}
SRC
if "$TMP/aster-cn-parse" "$TMP/closure-type-arrow-en.ast" \
    > /dev/null 2> "$TMP/closure-type-arrow-en.err"; then
    echo 'FAIL: arrow return syntax was accepted by the English frontend' >&2
    exit 1
fi
grep -q "expected ':' after closure parameter types" "$TMP/closure-type-arrow-en.err"

cat > "$TMP/duplicate-capture-zh.ast" <<'SRC'
方法 启动方法(): 整数
变量 value = 方法 [step, step] (): 整数
返回 0
结束 方法
返回 0
结束 方法
SRC
if "$TMP/aster-cn-parse" "$TMP/duplicate-capture-zh.ast" \
    > /dev/null 2> "$TMP/duplicate-capture-zh.err"; then
    echo 'FAIL: duplicate closure capture was accepted' >&2
    exit 1
fi
grep -q '闭包捕获项重复: step' "$TMP/duplicate-capture-zh.err"

cat > "$TMP/duplicate-capture-en.ast" <<'SRC'
// aster:language=en
fn main(): i32 {
let value = fn [step, step] (): i32 {
return 0;
};
return 0;
}
SRC
if "$TMP/aster-cn-parse" "$TMP/duplicate-capture-en.ast" \
    > /dev/null 2> "$TMP/duplicate-capture-en.err"; then
    echo 'FAIL: duplicate English closure capture was accepted' >&2
    exit 1
fi
grep -q 'duplicate closure capture: step' "$TMP/duplicate-capture-en.err"

cat > "$TMP/omitted-void-zh.ast" <<'SRC'
方法 触碰()
结束 方法
方法 另一个(): 空
结束 方法
方法 启动方法(): 整数
触碰()
另一个()
返回 0
结束 方法
SRC
cat > "$TMP/omitted-void-en.ast" <<'SRC'
// aster:language=en
fn 触碰() {}
fn 另一个(): void {}
fn main(): i32 {
触碰();
另一个();
return 0;
}
SRC
"$TMP/aster-cn-parse" "$TMP/omitted-void-zh.ast" > "$TMP/omitted-void-zh.out"
"$TMP/aster-cn-parse" "$TMP/omitted-void-en.ast" > "$TMP/omitted-void-en.out"
cmp "$TMP/omitted-void-zh.out" "$TMP/omitted-void-en.out"
grep -q '(Method "触碰" "void"' "$TMP/omitted-void-zh.out"
grep -q '(Method "另一个" "void"' "$TMP/omitted-void-zh.out"

cat > "$TMP/class-field-initializer-zh.ast" <<'SRC'
类 FieldState
变量 first: 整数 = 4
变量 second: 整数 = 本对象.first + 2
结束 类
SRC
cat > "$TMP/class-field-initializer-en.ast" <<'SRC'
// aster:language=en
class FieldState {
let first: i32 = 4;
let second: i32 = this.first + 2;
}
SRC
printf '%s\n' '[17/17] class field initializers normalize bilingually'
"$TMP/aster-cn-parse" "$TMP/class-field-initializer-zh.ast" > "$TMP/class-field-initializer-zh.out"
"$TMP/aster-cn-parse" "$TMP/class-field-initializer-en.ast" > "$TMP/class-field-initializer-en.out"
cmp "$TMP/class-field-initializer-zh.out" "$TMP/class-field-initializer-en.out"
grep -q '(Field "second" "i32" (Binary "+" (Member' "$TMP/class-field-initializer-zh.out"

cat > "$TMP/private-top-level-en.ast" <<'SRC'
// aster:language=en
@private
fn private_value(): i32 {
return 1;
}
fn main(): i32 {
return 0;
}
SRC
"$TMP/aster-cn-parse" "$TMP/private-top-level-en.ast" > "$TMP/private-top-level-en.out"
grep -q '(Visibility "private")' "$TMP/private-top-level-en.out"

cat > "$TMP/static-field-zh.ast" <<'SRC'
类 Counter
@静态
变量 count: 整数 = 1
结束 类
方法 启动方法(): 整数
返回 Counter.count
结束 方法
SRC
cat > "$TMP/static-field-en.ast" <<'SRC'
// aster:language=en
class Counter {
@static
let count: i32 = 1;
}
fn main(): i32 { return Counter.count; }
SRC
printf '%s\n' '[static fields] annotations and class-qualified access normalize bilingually'
"$TMP/aster-cn-parse" "$TMP/static-field-zh.ast" > "$TMP/static-field-zh.out"
"$TMP/aster-cn-parse" "$TMP/static-field-en.ast" > "$TMP/static-field-en.out"
cmp "$TMP/static-field-zh.out" "$TMP/static-field-en.out"
grep -q '(Field "count" "i32" (Static) (IntegerLiteral "1"))' "$TMP/static-field-zh.out"

cat > "$TMP/interface-inheritance-zh.ast" <<'SRC'
接口类 可读
方法 读取(): 整数
结束 接口类
接口类 可增强 : 可读
方法 增强(): 整数
结束 接口类
方法 启动方法(): 整数
返回 0
结束 方法
SRC
cat > "$TMP/interface-inheritance-en.ast" <<'SRC'
// aster:language=en
interface class 可读 {
fn 读取(): i32;
}
interface class 可增强: 可读 {
fn 增强(): i32;
}
fn main(): i32 { return 0; }
SRC
printf '%s\n' '[interfaces] inherited interface signatures normalize bilingually'
"$TMP/aster-cn-parse" "$TMP/interface-inheritance-zh.ast" > "$TMP/interface-inheritance-zh.out"
"$TMP/aster-cn-parse" "$TMP/interface-inheritance-en.ast" > "$TMP/interface-inheritance-en.out"
cmp "$TMP/interface-inheritance-zh.out" "$TMP/interface-inheritance-en.out"
grep -q '(InterfaceClass "可增强" (Base "可读")' "$TMP/interface-inheritance-zh.out"

# P1-1: a diagnostic is decorated exactly once even though lexing,
# parsing and the main catch all decorate (idempotent [A-NNN] prefix).
printf 'fn main(): i32 { return \377; }\n' > "$TMP/bad-utf8.ast"
if "$TMP/aster-cn-parse" "$TMP/bad-utf8.ast" \
    > /dev/null 2> "$TMP/bad-utf8.err"; then
    echo 'FAIL: invalid UTF-8 was accepted' >&2
    exit 1
fi
if [ "$(grep -o '\[A-001\]' "$TMP/bad-utf8.err" | wc -l)" -ne 1 ]; then
    echo 'FAIL: invalid UTF-8 diagnostic was not decorated exactly once' >&2
    exit 1
fi

# P1-2: .type member name follows the file language.
cat > "$TMP/dot-type-en.ast" <<'SRC'
// aster:language=en
fn f(o: ptr): i32 { return o.type; }
fn main(): i32 { return 0; }
SRC
"$TMP/aster-cn-parse" "$TMP/dot-type-en.ast" > "$TMP/dot-type-en.out"
grep -q '(Member (Identifier "o") (Identifier "type"))' "$TMP/dot-type-en.out"

# P1-3: type aliases and top-level file imports parse (zh and en).
cat > "$TMP/alias-import-zh.ast" <<'SRC'
类型 用户编号 = 整数
导入 "math.ast"
方法 启动方法(): 整数
变量 x: 用户编号 = 0
返回 x
结束 方法
SRC
"$TMP/aster-cn-parse" "$TMP/alias-import-zh.ast" > "$TMP/alias-import-zh.out"
grep -q '(Alias "用户编号" "i32")' "$TMP/alias-import-zh.out"
grep -q '(FileImport "math.ast")' "$TMP/alias-import-zh.out"
cat > "$TMP/alias-import-en.ast" <<'SRC'
// aster:language=en
type UserId = i32;
include "math.ast";
fn main(): i32 { let x: UserId = 0; return x; }
SRC
"$TMP/aster-cn-parse" "$TMP/alias-import-en.ast" > "$TMP/alias-import-en.out"
grep -q '(Alias "UserId" "i32")' "$TMP/alias-import-en.out"
grep -q '(FileImport "math.ast")' "$TMP/alias-import-en.out"

# P1-4: struct literals and class construction do not depend on
# declaration order.
cat > "$TMP/late-literal-zh.ast" <<'SRC'
方法 启动方法(): 整数
变量 p: 点 = 点{1, 2}
返回 p.甲 + p.乙
结束 方法
结构 点
甲: 整数
乙: 整数
结束 结构
SRC
"$TMP/aster-cn-parse" "$TMP/late-literal-zh.ast" > "$TMP/late-literal-zh.out"
grep -q '(StructLiteral "点"' "$TMP/late-literal-zh.out"
cat > "$TMP/late-construct-en.ast" <<'SRC'
// aster:language=en
fn main(): i32 { let p: Point = Point(3, 4); return p.x + p.y; }
class Point {
let x: i32;
let y: i32;
@constructor
fn constructor(x: i32, y: i32) { this.x = x; this.y = y; }
}
SRC
"$TMP/aster-cn-parse" "$TMP/late-construct-en.ast" > "$TMP/late-construct-en.out"
grep -q '(Call (TypeName "Point")' "$TMP/late-construct-en.out"

# P1-5: ternary ?: parses (right-associative) in both languages.
cat > "$TMP/ternary-zh.ast" <<'SRC'
方法 启动方法(): 整数
变量 x: 整数 = 1
返回 x == 1 ? 10 : x == 2 ? 20 : 30
结束 方法
SRC
"$TMP/aster-cn-parse" "$TMP/ternary-zh.ast" > "$TMP/ternary-zh.out"
grep -q '(Conditional (Binary "=="' "$TMP/ternary-zh.out"
cat > "$TMP/ternary-en.ast" <<'SRC'
// aster:language=en
fn main(): i32 { let x: i32 = 1; return x == 1 ? 10 : 20; }
SRC
"$TMP/aster-cn-parse" "$TMP/ternary-en.ast" > "$TMP/ternary-en.out"
grep -q '(Conditional (Binary "=="' "$TMP/ternary-en.out"

# P1-6: English switch accepts case <expr>: and default:.
cat > "$TMP/switch-default-en.ast" <<'SRC'
// aster:language=en
fn main(): i32 { let x: i32 = 2; switch (x) { case 1: return 1; default: return 0; } }
SRC
"$TMP/aster-cn-parse" "$TMP/switch-default-en.ast" > "$TMP/switch-default-en.out"
grep -q '(Case ' "$TMP/switch-default-en.out"
grep -q '(Else ' "$TMP/switch-default-en.out"

# P1-7: multi-dimensional arrays are rejected in variables and parameters.
cat > "$TMP/multidim-var-zh.ast" <<'SRC'
方法 启动方法(): 整数
变量 a: 整数[2][3]
返回 0
结束 方法
SRC
if "$TMP/aster-cn-parse" "$TMP/multidim-var-zh.ast" \
    > /dev/null 2> "$TMP/multidim-var-zh.err"; then
    echo 'FAIL: multi-dimensional variable was accepted' >&2
    exit 1
fi
grep -q 'one-dimensional' "$TMP/multidim-var-zh.err"
cat > "$TMP/multidim-param-en.ast" <<'SRC'
// aster:language=en
fn f(x: i32[2][3]): i32 { return x[0][0]; }
fn main(): i32 { return 0; }
SRC
if "$TMP/aster-cn-parse" "$TMP/multidim-param-en.ast" \
    > /dev/null 2> "$TMP/multidim-param-en.err"; then
    echo 'FAIL: multi-dimensional parameter was accepted' >&2
    exit 1
fi
grep -q 'supports one-dimensional array parameters' "$TMP/multidim-param-en.err"

# P1-8: annotations are enforced per language (cross-language spellings
# are rejected).
cat > "$TMP/annotation-zh-private.ast" <<'SRC'
@private
方法 甲(): 整数
返回 0
结束 方法
方法 启动方法(): 整数
返回 0
结束 方法
SRC
if "$TMP/aster-cn-parse" "$TMP/annotation-zh-private.ast" \
    > /dev/null 2> "$TMP/annotation-zh-private.err"; then
    echo 'FAIL: @private in a Chinese file was accepted' >&2
    exit 1
fi
grep -q "unknown top-level annotation '@private'" "$TMP/annotation-zh-private.err"
cat > "$TMP/annotation-en-hidden.ast" <<'SRC'
// aster:language=en
class C {
@hidden
let x: i32;
}
fn main(): i32 { return 0; }
SRC
if "$TMP/aster-cn-parse" "$TMP/annotation-en-hidden.ast" \
    > /dev/null 2> "$TMP/annotation-en-hidden.err"; then
    echo 'FAIL: @hidden in an English class was accepted' >&2
    exit 1
fi
grep -q "unknown class member annotation '@hidden'" "$TMP/annotation-en-hidden.err"

# P1-9: empty structures, empty matches and empty switches parse.
cat > "$TMP/empty-zh.ast" <<'SRC'
结构 空壳
结束 结构
方法 启动方法(): 整数
变量 x: 整数 = 1
假如 (x)
结束 假如
返回 0
结束 方法
SRC
"$TMP/aster-cn-parse" "$TMP/empty-zh.ast" > "$TMP/empty-zh.out"
grep -q '(Structure "空壳" (Fields))' "$TMP/empty-zh.out"
cat > "$TMP/empty-switch-en.ast" <<'SRC'
// aster:language=en
fn main(): i32 { let x: i32 = 1; switch (x) { } return 0; }
SRC
"$TMP/aster-cn-parse" "$TMP/empty-switch-en.ast" > "$TMP/empty-switch-en.out"
grep -q '(MatchStatement (Identifier "x"))' "$TMP/empty-switch-en.out"

# P1-23: 字段 is a reserved word and cannot be used as a field name.
cat > "$TMP/reserved-field-zh.ast" <<'SRC'
结构 点
字段: 整数
结束 结构
方法 启动方法(): 整数
返回 0
结束 方法
SRC
if "$TMP/aster-cn-parse" "$TMP/reserved-field-zh.ast" \
    > /dev/null 2> "$TMP/reserved-field-zh.err"; then
    echo 'FAIL: 字段 as a structure field name was accepted' >&2
    exit 1
fi
grep -q '保留字' "$TMP/reserved-field-zh.err"

echo 'PASS: bilingual core parser checks'
