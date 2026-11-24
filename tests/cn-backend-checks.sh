#!/bin/sh
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

cat > "$TMP/core-zh.ast" <<'SRC'
// aster:language=zh
方法 add(a: 整数, b: 整数): 整数
返回 a + b
结束 方法
方法 启动方法(): 整数
变量 sum: 整数 = 0
变量 selected: 整数 = 0
计次循环 (i = 1, 3)
sum = sum + i
结束 计次循环
假如 sum
是 6
selected = 2
是 7, 8
selected = 3
否则
selected = 4
结束 假如
返回 add(20, 22) + sum + selected
结束 方法
SRC
cat > "$TMP/core-en.ast" <<'SRC'
fn add(a: i32, b: i32): i32 {
return a + b;
}
fn main(): i32 {
let sum: i32 = 0;
let selected: i32 = 0;
for (i = 1, 3) {
sum = sum + i;
}
switch (sum) {
case 6
selected = 2;
case 7, 8
selected = 3;
else
selected = 4;
}
return add(20, 22) + sum + selected;
}
SRC

printf '%s\n' '[1/19] bilingual frontends produce identical backend objects'
"$ASTER_BIN" build-cn-obj "$TMP/core-zh.ast" -o "$TMP/zh.o"
"$ASTER_BIN" build-cn-obj --language en "$TMP/core-en.ast" -o "$TMP/en.o"
cat > "$TMP/aster.proj" <<'PROJ'
[language]
default = "en"
allowed = ["zh", "en"]
PROJ
"$ASTER_BIN" build-cn-obj --project "$TMP/aster.proj" "$TMP/core-en.ast" -o "$TMP/project-en.o"
cmp "$TMP/zh.o" "$TMP/en.o"
cmp "$TMP/zh.o" "$TMP/project-en.o"

cat > "$TMP/omitted-void-zh.ast" <<'SRC'
// aster:language=zh
方法 touch()
变量 marker: 整数 = 1
marker = marker + 1
结束 方法
方法 touchExplicit(): 空
变量 marker: 整数 = 1
marker = marker + 1
结束 方法
方法 启动方法(): 整数
touch()
touchExplicit()
返回 0
结束 方法
SRC
cat > "$TMP/omitted-void-en.ast" <<'SRC'
// aster:language=en
fn touch() {
let marker: i32 = 1;
marker = marker + 1;
}
fn touchExplicit(): void {
let marker: i32 = 1;
marker = marker + 1;
}
fn main(): i32 {
touch();
touchExplicit();
return 0;
}
SRC
"$ASTER_BIN" build-cn-obj "$TMP/omitted-void-zh.ast" -o "$TMP/omitted-void-zh.o"
"$ASTER_BIN" build-cn-obj --language en "$TMP/omitted-void-en.ast" -o "$TMP/omitted-void-en.o"
cmp "$TMP/omitted-void-zh.o" "$TMP/omitted-void-en.o"
"$ASTER_BIN" link-obj "$TMP/omitted-void-zh.o" -o "$TMP/omitted-void"
if [ "$CAN_RUN" -eq 1 ]; then
    "$RUNNER" "$TMP/omitted-void"
fi

cat > "$TMP/extern-zh.ast" <<'SRC'
// aster:language=zh
外部("puts") 方法 输出(文本: 指针): 整数
方法 启动方法(): 整数
返回 输出(0)
结束 方法
SRC
cat > "$TMP/extern-en.ast" <<'SRC'
// aster:language=en
extern fn puts(text: ptr): i32;
fn main(): i32 {
return puts(0);
}
SRC
"$ASTER_BIN" build-cn-obj "$TMP/extern-zh.ast" -o "$TMP/extern-zh.o"
"$ASTER_BIN" build-cn-obj --language en "$TMP/extern-en.ast" -o "$TMP/extern-en.o"
cmp "$TMP/extern-zh.o" "$TMP/extern-en.o"
readelf -Ws "$TMP/extern-zh.o" | grep -E 'UND[[:space:]]+puts$' >/dev/null || {
    echo 'FAIL: Chinese external method did not produce an undefined puts symbol' >&2; exit 1;
}
cat > "$TMP/extern-global-zh.ast" <<'SRC'
// aster:language=zh
外部("native_counter") 变量 计数: 整数
方法 启动方法(): 整数
计数 = 计数 + 2
返回 计数
结束 方法
SRC
cat > "$TMP/extern-global-en.ast" <<'SRC'
// aster:language=en
extern let native_counter: i32;
fn main(): i32 {
native_counter = native_counter + 2;
return native_counter;
}
SRC
"$ASTER_BIN" build-cn-obj "$TMP/extern-global-zh.ast" -o "$TMP/extern-global-zh.o"
"$ASTER_BIN" build-cn-obj --language en "$TMP/extern-global-en.ast" -o "$TMP/extern-global-en.o"
cmp "$TMP/extern-global-zh.o" "$TMP/extern-global-en.o"
readelf -Ws "$TMP/extern-global-zh.o" | grep -E 'UND[[:space:]]+native_counter$' >/dev/null || {
    echo 'FAIL: Chinese external global did not produce an undefined OBJECT symbol' >&2; exit 1;
}
cat > "$TMP/extern-global-array-zh.ast" <<'SRC'
// aster:language=zh
外部("native_values") 变量 数值: 整数[2]
方法 启动方法(): 整数
数值[1] = 数值[0] + 1
返回 数值[1]
结束 方法
SRC
cat > "$TMP/extern-global-array-en.ast" <<'SRC'
// aster:language=en
extern let native_values: i32[2];
fn main(): i32 {
native_values[1] = native_values[0] + 1;
return native_values[1];
}
SRC
"$ASTER_BIN" build-cn-obj "$TMP/extern-global-array-zh.ast" -o "$TMP/extern-global-array-zh.o"
"$ASTER_BIN" build-cn-obj --language en "$TMP/extern-global-array-en.ast" -o "$TMP/extern-global-array-en.o"
cmp "$TMP/extern-global-array-zh.o" "$TMP/extern-global-array-en.o"
readelf -Ws "$TMP/extern-global-array-zh.o" | grep -E 'UND[[:space:]]+native_values$' >/dev/null || {
    echo 'FAIL: external global array did not preserve the ASCII ABI symbol' >&2; exit 1;
}
cat > "$TMP/extern-global-fn-zh.ast" <<'SRC'
// aster:language=zh
外部("native_callback") 变量 回调: 方法(整数): 整数
方法 启动方法(): 整数
返回 回调(41)
结束 方法
SRC
cat > "$TMP/extern-global-fn-en.ast" <<'SRC'
// aster:language=en
extern let native_callback: fn(i32): i32;
fn main(): i32 {
return native_callback(41);
}
SRC
"$ASTER_BIN" build-cn-obj "$TMP/extern-global-fn-zh.ast" -o "$TMP/extern-global-fn-zh.o"
"$ASTER_BIN" build-cn-obj --language en "$TMP/extern-global-fn-en.ast" -o "$TMP/extern-global-fn-en.o"
cmp "$TMP/extern-global-fn-zh.o" "$TMP/extern-global-fn-en.o"
readelf -Ws "$TMP/extern-global-fn-zh.o" | grep -E 'UND[[:space:]]+native_callback$' >/dev/null || {
    echo 'FAIL: external function-pointer global did not preserve the ASCII ABI symbol' >&2; exit 1;
}
cat > "$TMP/extern-global-string-zh.ast" <<'SRC'
// aster:language=zh
外部("native_text") 变量 文本: 字符串
方法 启动方法(): 整数
如果 文本 == 空
返回 1
否则
返回 0
结束 如果
结束 方法
SRC
cat > "$TMP/extern-global-string-en.ast" <<'SRC'
// aster:language=en
extern let native_text: string;
fn main(): i32 {
if (native_text == null) {
return 1;
} else {
return 0;
}
}
SRC
"$ASTER_BIN" build-cn-obj "$TMP/extern-global-string-zh.ast" -o "$TMP/extern-global-string-zh.o"
"$ASTER_BIN" build-cn-obj --language en "$TMP/extern-global-string-en.ast" -o "$TMP/extern-global-string-en.o"
cmp "$TMP/extern-global-string-zh.o" "$TMP/extern-global-string-en.o"
readelf -Ws "$TMP/extern-global-string-zh.o" | grep -E 'UND[[:space:]]+native_text$' >/dev/null || {
    echo 'FAIL: external string global did not preserve the ASCII ABI symbol' >&2; exit 1;
}
cat > "$TMP/extern-global-missing-map.ast" <<'SRC'
// aster:language=zh
外部 变量 计数: 整数
方法 启动方法(): 整数
返回 0
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/extern-global-missing-map.ast" \
    -o "$TMP/extern-global-missing-map.o" 2> "$TMP/extern-global-missing-map.err"; then
    echo 'FAIL: external global without an ASCII mapping was accepted' >&2; exit 1
fi
grep -q "expected '(' after '外部'" "$TMP/extern-global-missing-map.err" || {
    echo 'FAIL: missing external global symbol diagnostic was not specific' >&2
    cat "$TMP/extern-global-missing-map.err" >&2
    exit 1
}
cat > "$TMP/extern-global-init.ast" <<'SRC'
// aster:language=en
extern let native_counter: i32 = 1;
fn main(): i32 { return 0; }
SRC
if "$ASTER_BIN" build-cn-obj --language en "$TMP/extern-global-init.ast" \
    -o "$TMP/extern-global-init.o" 2> "$TMP/extern-global-init.err"; then
    echo 'FAIL: external global with an initializer was accepted' >&2; exit 1
fi
grep -q 'external global declarations cannot have an initializer' \
    "$TMP/extern-global-init.err" || {
    echo 'FAIL: external global initializer diagnostic was not specific' >&2
    cat "$TMP/extern-global-init.err" >&2
    exit 1
}
cat > "$TMP/extern-missing-map.ast" <<'SRC'
// aster:language=zh
外部 方法 输出(值: 指针): 整数
方法 启动方法(): 整数
返回 0
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/extern-missing-map.ast" -o "$TMP/extern-missing-map.o" \
    2> "$TMP/extern-missing-map.err"; then
    echo 'FAIL: external method without an ASCII mapping was accepted' >&2; exit 1
fi
grep -q "expected '(' after '外部'" "$TMP/extern-missing-map.err" || {
    echo 'FAIL: missing external symbol mapping diagnostic was not specific' >&2
    cat "$TMP/extern-missing-map.err" >&2
    exit 1
}
cat > "$TMP/extern-empty-map.ast" <<'SRC'
// aster:language=zh
外部("") 方法 输出(值: 指针): 整数
方法 启动方法(): 整数
返回 0
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/extern-empty-map.ast" -o "$TMP/extern-empty-map.o" \
    2> "$TMP/extern-empty-map.err"; then
    echo 'FAIL: empty external symbol mapping was accepted' >&2; exit 1
fi
grep -q 'external symbol name must not be empty' "$TMP/extern-empty-map.err" || {
    echo 'FAIL: empty external symbol diagnostic was not specific' >&2
    cat "$TMP/extern-empty-map.err" >&2
    exit 1
}
cat > "$TMP/extern-nonascii-map.ast" <<'SRC'
// aster:language=zh
外部("输出") 方法 输出(值: 指针): 整数
方法 启动方法(): 整数
返回 0
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/extern-nonascii-map.ast" -o "$TMP/extern-nonascii-map.o" \
    2> "$TMP/extern-nonascii-map.err"; then
    echo 'FAIL: non-ASCII external symbol mapping was accepted' >&2; exit 1
fi
grep -q 'external symbol names must use ASCII' "$TMP/extern-nonascii-map.err" || {
    echo 'FAIL: non-ASCII external symbol diagnostic was not specific' >&2
    cat "$TMP/extern-nonascii-map.err" >&2
    exit 1
}

cat > "$TMP/wide-match-zh.ast" <<'SRC'
// aster:language=zh
方法 启动方法(): 整数
变量 selected: 整数 = 0
变量 unsigned32: u整数 = 4294967295u
变量 signed64: 长整数 = 4294967296L
变量 unsigned64: u长整数 = 18446744073709551615uL
变量 byteValue: u字节 = u字节(255)
变量 wordValue: u短整数 = u短整数(65535)
变量 letter: 字符 = 字符(65)
假如 unsigned32
是 4294967295u
selected = selected + 1
否则
返回 0
结束 假如
假如 signed64
是 4294967296L
selected = selected + 1
否则
返回 0
结束 假如
假如 unsigned64
是 18446744073709551615uL
selected = selected + 1
否则
返回 0
结束 假如
假如 byteValue
是 255
selected = selected + 1
否则
返回 0
结束 假如
假如 wordValue
是 65535
selected = selected + 1
否则
返回 0
结束 假如
假如 letter
是 65
selected = selected + 1
否则
返回 0
结束 假如
返回 selected
结束 方法
SRC
cat > "$TMP/wide-match-en.ast" <<'SRC'
fn main(): i32 {
let selected: i32 = 0;
let unsigned32: u32 = 4294967295u;
let signed64: i64 = 4294967296L;
let unsigned64: u64 = 18446744073709551615uL;
let byteValue: u8 = u8(255);
let wordValue: u16 = u16(65535);
let letter: char = char(65);
switch (unsigned32) {
case 4294967295u
selected = selected + 1;
else
return 0;
}
switch (signed64) {
case 4294967296L
selected = selected + 1;
else
return 0;
}
switch (unsigned64) {
case 18446744073709551615uL
selected = selected + 1;
else
return 0;
}
switch (byteValue) {
case 255
selected = selected + 1;
else
return 0;
}
switch (wordValue) {
case 65535
selected = selected + 1;
else
return 0;
}
switch (letter) {
case 65
selected = selected + 1;
else
return 0;
}
return selected;
}
SRC
"$ASTER_BIN" build-cn-obj "$TMP/wide-match-zh.ast" -o "$TMP/wide-match-zh.o"
"$ASTER_BIN" build-cn-obj --language en "$TMP/wide-match-en.ast" -o "$TMP/wide-match-en.o"
cmp "$TMP/wide-match-zh.o" "$TMP/wide-match-en.o"
"$ASTER_BIN" link-obj "$TMP/wide-match-zh.o" -o "$TMP/wide-match"
if [ "$CAN_RUN" -eq 1 ]; then
    if "$RUNNER" "$TMP/wide-match"; then status=0; else status=$?; fi
    [ "$status" -eq 6 ] || { echo "FAIL: expected exit 6, got $status" >&2; exit 1; }
else
    echo 'SKIP: execution requires qemu-aarch64 or AArch64 Linux'
fi

cat > "$TMP/enum-match-zh.ast" <<'SRC'
// aster:language=zh
枚举 Color
Green = 4
Blue = Green + 3
Red = -2
结束 枚举
结构 Box
color: Color
colors: Color[2]
结束 结构
方法 启动方法(): 整数
变量 total: 整数 = 0
变量 color: Color
变量 box: Box
变量 selected: Color = Blue
变量 colors: Color[2]
假如 color
是 Green
total = total + 1
结束 假如
假如 colors[1]
是 Green
total = total + 1
结束 假如
假如 box.color
是 Green
total = total + 1
结束 假如
假如 box.colors[1]
是 Green
total = total + 1
结束 假如
假如 selected
是 Blue
total = total + 1
结束 假如
返回 total
结束 方法
SRC
cat > "$TMP/enum-match-en.ast" <<'SRC'
// aster:language=en
enum Color { Green = 4, Blue = Green + 3, Red = -2 }
struct Box { color: Color, colors: Color[2] }
fn main(): i32 {
let total: i32 = 0;
let color: Color;
let box: Box;
let selected: Color = Blue;
let colors: Color[2];
switch (color) {
case Green
total = total + 1;
}
switch (colors[1]) {
case Green
total = total + 1;
}
switch (box.color) {
case Green
total = total + 1;
}
switch (box.colors[1]) {
case Green
total = total + 1;
}
switch (selected) {
case Blue
total = total + 1;
}
return total;
}
SRC
"$ASTER_BIN" build-cn-obj "$TMP/enum-match-zh.ast" -o "$TMP/enum-match-zh.o"
"$ASTER_BIN" build-cn-obj --language en "$TMP/enum-match-en.ast" -o "$TMP/enum-match-en.o"
cmp "$TMP/enum-match-zh.o" "$TMP/enum-match-en.o"
"$ASTER_BIN" link-obj "$TMP/enum-match-zh.o" -o "$TMP/enum-match"
if [ "$CAN_RUN" -eq 1 ]; then
    if "$RUNNER" "$TMP/enum-match"; then status=0; else status=$?; fi
    [ "$status" -eq 5 ] || { echo "FAIL: expected exit 5, got $status" >&2; exit 1; }
else
    echo 'SKIP: execution requires qemu-aarch64 or AArch64 Linux'
fi

cat > "$TMP/truthiness-zh.ast" <<'SRC'
// aster:language=zh
枚举 Flag
Off = 0
On = 1
结束 枚举
方法 启动方法(): 整数
变量 total: 整数 = 0
变量 state: Flag = On
如果 (state)
total = total + 1
结束 如果
state = Off
如果 (state)
返回 99
结束 如果
变量 loopState: Flag = On
循环 (loopState)
total = total + 1
loopState = Off
结束 循环
变量 count: 长整数 = 1
循环 (count)
total = total + 1
count = count - 1
结束 循环
如果 (0)
返回 90
结束 如果
变量 target: 整数 = 0
变量 pointer: 指针 = 空
如果 (pointer)
返回 91
结束 如果
pointer = &target
如果 (pointer)
total = total + 1
结束 如果
pointer = 空
如果 (pointer)
返回 92
结束 如果
变量 precise: f64 = 0.0
如果 (precise)
返回 93
结束 如果
precise = 1.5
如果 (precise)
total = total + 1
结束 如果
变量 single: 单精度 = 单精度(0.0)
如果 (single)
返回 94
结束 如果
single = 单精度(2.0)
如果 (single)
total = total + 1
结束 如果
如果 (空)
返回 95
结束 如果
如果 ("text")
total = total + 1
结束 如果
返回 total
结束 方法
SRC
cat > "$TMP/truthiness-en.ast" <<'SRC'
// aster:language=en
enum Flag { Off = 0, On = 1 }
fn main(): i32 {
let total: i32 = 0;
let state: Flag = On;
if (state) {
total = total + 1;
}
state = Off;
if (state) {
return 99;
}
let loopState: Flag = On;
while (loopState) {
total = total + 1;
loopState = Off;
}
let count: i64 = 1;
while (count) {
total = total + 1;
count = count - 1;
}
if (0) {
return 90;
}
let target: i32 = 0;
let pointer: ptr = null;
if (pointer) {
return 91;
}
pointer = &target;
if (pointer) {
total = total + 1;
}
pointer = null;
if (pointer) {
return 92;
}
let precise: f64 = 0.0;
if (precise) {
return 93;
}
precise = 1.5;
if (precise) {
total = total + 1;
}
let single: f32 = f32(0.0);
if (single) {
return 94;
}
single = f32(2.0);
if (single) {
total = total + 1;
}
if (null) {
return 95;
}
if ("text") {
total = total + 1;
}
return total;
}
SRC
"$ASTER_BIN" build-cn-obj "$TMP/truthiness-zh.ast" -o "$TMP/truthiness-zh.o"
"$ASTER_BIN" build-cn-obj --language en "$TMP/truthiness-en.ast" -o "$TMP/truthiness-en.o"
cmp "$TMP/truthiness-zh.o" "$TMP/truthiness-en.o"
"$ASTER_BIN" link-obj "$TMP/truthiness-zh.o" -o "$TMP/truthiness"
if [ "$CAN_RUN" -eq 1 ]; then
    if "$RUNNER" "$TMP/truthiness"; then status=0; else status=$?; fi
    [ "$status" -eq 7 ] || { echo "FAIL: expected exit 7, got $status" >&2; exit 1; }
else
    echo 'SKIP: execution requires qemu-aarch64 or AArch64 Linux'
fi

printf '%s\n' '[2/19] signed count loops link and run on AArch64 Linux'
cat > "$TMP/flow.ast" <<'SRC'
// aster:language=zh
方法 启动方法(): 整数
变量 total: 整数 = 0
计次循环 (up = 1, 5, 2)
total = total + up
结束 计次循环
计次循环 (down = 5, 1, -2)
total = total + down
结束 计次循环
计次循环 (0, 1)
total = total + 100
结束 计次循环
计次循环 (upper = 2147483647, 2147483647)
total = total + 1
结束 计次循环
计次循环 (lower = -2147483648, -2147483648, -1)
total = total + 1
结束 计次循环
假如 total
是 220, 221
返回 total
否则
返回 99
结束 假如
结束 方法
SRC
"$ASTER_BIN" build-cn-obj "$TMP/flow.ast" -o "$TMP/flow.o"
"$ASTER_BIN" link-obj "$TMP/flow.o" -o "$TMP/flow"
if [ "$CAN_RUN" -eq 1 ]; then
    if "$RUNNER" "$TMP/flow"; then status=0; else status=$?; fi
    [ "$status" -eq 220 ] || { echo "FAIL: expected exit 220, got $status" >&2; exit 1; }
else
    echo 'SKIP: execution requires qemu-aarch64 or AArch64 Linux'
fi

printf '%s\n' '[3/19] dynamic count-loop steps run once and zero traps by default'
cat > "$TMP/zero-step.ast" <<'SRC'
// aster:language=zh
方法 启动方法(): 整数
计次循环 (i = 1, 2, 0)
返回 i
结束 计次循环
返回 0
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/zero-step.ast" -o "$TMP/zero-step.o" 2> "$TMP/zero-step.err"; then
    echo 'FAIL: zero count-loop step accepted' >&2
    exit 1
fi
grep -q 'counting-loop step cannot be zero' "$TMP/zero-step.err"

cat > "$TMP/dynamic-step.ast" <<'SRC'
// aster:language=zh
方法 启动方法(): 整数
变量 total: 整数 = 0
变量 step: 整数 = 1
计次循环 (i = 1, 3, step)
total = total + i
step = 2
结束 计次循环
step = -2
计次循环 (i = 5, 1, step)
total = total + i
结束 计次循环
返回 total
结束 方法
SRC
"$ASTER_BIN" build-cn-obj "$TMP/dynamic-step.ast" -o "$TMP/dynamic-step.o"
"$ASTER_BIN" link-obj "$TMP/dynamic-step.o" -o "$TMP/dynamic-step"
if [ "$CAN_RUN" -eq 1 ]; then
    if "$RUNNER" "$TMP/dynamic-step"; then status=0; else status=$?; fi
    [ "$status" -eq 15 ] || { echo "FAIL: expected exit 15, got $status" >&2; exit 1; }
else
    echo 'SKIP: execution requires qemu-aarch64 or AArch64 Linux'
fi

cat > "$TMP/dynamic-zero-step.ast" <<'SRC'
// aster:language=zh
方法 启动方法(): 整数
变量 step: 整数 = 0
计次循环 (i = 1, 2, step)
返回 99
结束 计次循环
返回 17
结束 方法
SRC
"$ASTER_BIN" build-cn-obj "$TMP/dynamic-zero-step.ast" -o "$TMP/dynamic-zero-step.o"
"$ASTER_BIN" link-obj "$TMP/dynamic-zero-step.o" -o "$TMP/dynamic-zero-step"
"$ASTER_BIN" build-cn-obj --no-count-check "$TMP/dynamic-zero-step.ast" -o "$TMP/no-count-check.o"
"$ASTER_BIN" link-obj "$TMP/no-count-check.o" -o "$TMP/no-count-check"
if [ "$CAN_RUN" -eq 1 ]; then
    if "$RUNNER" "$TMP/dynamic-zero-step" >/dev/null 2>&1; then status=0; else status=$?; fi
    [ "$status" -eq 133 ] || { echo "FAIL: expected exit 133, got $status" >&2; exit 1; }
    if "$RUNNER" "$TMP/no-count-check" >/dev/null 2>&1; then status=0; else status=$?; fi
    [ "$status" -eq 17 ] || { echo "FAIL: expected exit 17, got $status" >&2; exit 1; }
else
    echo 'SKIP: execution requires qemu-aarch64 or AArch64 Linux'
fi

cat > "$TMP/large-step.ast" <<'SRC'
// aster:language=zh
方法 启动方法(): 整数
计次循环 (i = 1, 2, 2147483648)
返回 i
结束 计次循环
返回 0
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/large-step.ast" -o "$TMP/large-step.o" 2> "$TMP/large-step.err"; then
    echo 'FAIL: out-of-range count-loop step accepted' >&2
    exit 1
fi
grep -q 'counting-loop step must fit i32' "$TMP/large-step.err"

cat > "$TMP/duplicate-match.ast" <<'SRC'
// aster:language=zh
方法 启动方法(): 整数
假如 2
是 1, 2
返回 10
是 2
返回 20
结束 假如
返回 0
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/duplicate-match.ast" -o "$TMP/duplicate-match.o" 2> "$TMP/duplicate-match.err"; then
    echo 'FAIL: duplicate match value accepted' >&2
    exit 1
fi
grep -q 'duplicate match value 2' "$TMP/duplicate-match.err"

cat > "$TMP/nonconstant-match.ast" <<'SRC'
// aster:language=zh
方法 启动方法(): 整数
变量 label: 整数 = 2
假如 2
是 label
返回 10
结束 假如
返回 0
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/nonconstant-match.ast" -o "$TMP/nonconstant-match.o" 2> "$TMP/nonconstant-match.err"; then
    echo 'FAIL: nonconstant match value accepted' >&2
    exit 1
fi
grep -q 'match values must be compile-time integer constants' "$TMP/nonconstant-match.err"

cat > "$TMP/out-of-range-match.ast" <<'SRC'
// aster:language=zh
方法 启动方法(): 整数
假如 1
是 2147483648
返回 10
结束 假如
返回 0
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/out-of-range-match.ast" -o "$TMP/out-of-range-match.o" 2> "$TMP/out-of-range-match.err"; then
    echo 'FAIL: out-of-range match value accepted' >&2
    exit 1
fi
grep -q 'match value does not fit i32' "$TMP/out-of-range-match.err"

cat > "$TMP/bool-match.ast" <<'SRC'
// aster:language=zh
方法 启动方法(): 整数
变量 value: 逻辑型 = 真
假如 value
是 3
返回 10
结束 假如
返回 0
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/bool-match.ast" -o "$TMP/bool-match.o" 2> "$TMP/bool-match.err"; then
    echo 'FAIL: non-integer match subject accepted' >&2
    exit 1
fi
grep -q 'match subject must be an integer type' "$TMP/bool-match.err"

cat > "$TMP/u8-out-of-range-match.ast" <<'SRC'
// aster:language=zh
方法 启动方法(): 整数
变量 value: u8 = u8(1)
假如 value
是 256
返回 10
结束 假如
返回 0
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/u8-out-of-range-match.ast" -o "$TMP/u8-out-of-range-match.o" 2> "$TMP/u8-out-of-range-match.err"; then
    echo 'FAIL: out-of-range u8 match value accepted' >&2
    exit 1
fi
grep -q 'match value does not fit u8' "$TMP/u8-out-of-range-match.err"

cat > "$TMP/unknown-match-subject.ast" <<'SRC'
// aster:language=zh
方法 启动方法(): 整数
假如 missing
是 1
返回 10
结束 假如
返回 0
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/unknown-match-subject.ast" -o "$TMP/unknown-match-subject.o" 2> "$TMP/unknown-match-subject.err"; then
    echo 'FAIL: unknown match subject accepted' >&2
    exit 1
fi
grep -q "$TMP/unknown-match-subject.ast:3:" "$TMP/unknown-match-subject.err"

printf '%s\n' '[4/19] lowered count variables remain read-only'
cat > "$TMP/write-counter.ast" <<'SRC'
// aster:language=zh
方法 启动方法(): 整数
计次循环 (i = 1, 2)
i = 5
结束 计次循环
返回 0
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/write-counter.ast" -o "$TMP/write-counter.o" 2> "$TMP/write-counter.err"; then
    echo 'FAIL: count-loop variable assignment accepted' >&2
    exit 1
fi
grep -q 'cannot assign to a const: i' "$TMP/write-counter.err"

cat > "$TMP/address-counter.ast" <<'SRC'
// aster:language=zh
方法 启动方法(): 整数
计次循环 (i = 1, 2)
变量 p: 指针 = &i
返回 0
结束 计次循环
返回 0
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/address-counter.ast" -o "$TMP/address-counter.o" 2> "$TMP/address-counter.err"; then
    echo 'FAIL: count-loop variable address accepted' >&2
    exit 1
fi
grep -q 'cannot take the address of a const: i' "$TMP/address-counter.err"

printf '%s\n' '[5/19] semantic failures retain source locations and condition types'
cat > "$TMP/invalid.ast" <<'SRC'
// aster:language=zh
方法 启动方法(): 整数
返回 missingName
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/invalid.ast" -o "$TMP/invalid.o" 2> "$TMP/error"; then
    echo 'FAIL: unknown variable accepted' >&2
    exit 1
fi
grep -q "$TMP/invalid.ast:3:" "$TMP/error"

cat > "$TMP/struct-if.ast" <<'SRC'
// aster:language=zh
结构 Box
value: 整数
结束 结构
方法 启动方法(): 整数
变量 item: Box
如果 (item)
返回 0
结束 如果
返回 0
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/struct-if.ast" -o "$TMP/struct-if.o" 2> "$TMP/struct-if.err"; then
    echo 'FAIL: struct if condition accepted' >&2
    exit 1
fi
grep -q 'condition must be bool, numeric, or pointer' "$TMP/struct-if.err"

cat > "$TMP/struct-while.ast" <<'SRC'
// aster:language=en
struct Box { value: i32 }
fn main(): i32 {
let item: Box;
while (item) {
return 0;
}
return 0;
}
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/struct-while.ast" -o "$TMP/struct-while.o" 2> "$TMP/struct-while.err"; then
    echo 'FAIL: struct while condition accepted' >&2
    exit 1
fi
grep -q 'condition must be bool, numeric, or pointer' "$TMP/struct-while.err"

cat > "$TMP/range-match-zh.ast" <<'SRC'
// aster:language=zh
方法 启动方法(): 整数
假如 5
是 0 到 17
返回 1
结束 假如
返回 0
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/range-match-zh.ast" -o "$TMP/range-match-zh.o" 2> "$TMP/range-match-zh.err"; then
    echo 'FAIL: deferred Chinese range match accepted' >&2
    exit 1
fi
grep -q '范围匹配尚未实现' "$TMP/range-match-zh.err"

cat > "$TMP/range-match-en.ast" <<'SRC'
// aster:language=en
fn main(): i32 {
switch (5) {
case 0 to 17
return 1;
}
return 0;
}
SRC
if "$ASTER_BIN" build-cn-obj --language en "$TMP/range-match-en.ast" -o "$TMP/range-match-en.o" 2> "$TMP/range-match-en.err"; then
    echo 'FAIL: deferred English range match accepted' >&2
    exit 1
fi
grep -q 'range matching is not implemented' "$TMP/range-match-en.err"

printf '%s\n' '[6/19] debug output includes DWARF sections when readelf exists'
"$ASTER_BIN" build-cn-obj -g "$TMP/core-zh.ast" -o "$TMP/debug.o"
if command -v readelf >/dev/null 2>&1; then
    readelf -S "$TMP/debug.o" | grep -q '\.debug_line'
    readelf -S "$TMP/debug.o" | grep -q '\.debug_info'
    readelf -S "$TMP/debug.o" | grep -q '\.eh_frame'
else
    echo 'SKIP: readelf is unavailable'
fi

printf '%s\n' '[7/19] local arrays initialize, index, store, and preserve const'
cat > "$TMP/arrays.ast" <<'SRC'
// aster:language=zh
方法 启动方法(): 整数
变量 items: 整数[3] = [4, 5, 6]
items[1] = items[0] + 2
常量 fixed: 整数[2] = [7, 8]
变量 zeros: 整数[2]
返回 items[1] + fixed[0] + zeros[1]
结束 方法
SRC
"$ASTER_BIN" build-cn-obj "$TMP/arrays.ast" -o "$TMP/arrays.o"
"$ASTER_BIN" link-obj "$TMP/arrays.o" -o "$TMP/arrays"
if [ "$CAN_RUN" -eq 1 ]; then
    if "$RUNNER" "$TMP/arrays"; then status=0; else status=$?; fi
    [ "$status" -eq 13 ] || { echo "FAIL: expected exit 13, got $status" >&2; exit 1; }
else
    echo 'SKIP: array execution requires qemu-aarch64 or AArch64 Linux'
fi

cat > "$TMP/array-length-mismatch.ast" <<'SRC'
// aster:language=zh
方法 启动方法(): 整数
变量 items: 整数[2] = [1, 2, 3]
返回 items[0]
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/array-length-mismatch.ast" -o "$TMP/array-length-mismatch.o" 2> "$TMP/array-length-mismatch.err"; then
    echo 'FAIL: mismatched array literal length accepted' >&2
    exit 1
fi
grep -q 'array literal length does not match declared array length' "$TMP/array-length-mismatch.err"

printf '%s\n' '[8/19] array foreach lowers with read-only element and index bindings'
cat > "$TMP/foreach-zh.ast" <<'SRC'
// aster:language=zh
方法 启动方法(): 整数
变量 items: 整数[3] = [4, 5, 6]
变量 total: 整数 = 0
遍历循环 (item -> items)
total = total + item
结束 遍历循环
遍历循环 (index, item2 -> items)
total = total + index
total = total + item2
结束 遍历循环
返回 total
结束 方法
SRC
cat > "$TMP/foreach-en.ast" <<'SRC'
// aster:language=en
fn main(): i32 {
let items: i32[3] = [4, 5, 6];
let total: i32 = 0;
foreach item in items {
total = total + item;
}
foreach index, item2 in items {
total = total + index;
total = total + item2;
}
return total;
}
SRC
"$ASTER_BIN" build-cn-obj "$TMP/foreach-zh.ast" -o "$TMP/foreach-zh.o"
"$ASTER_BIN" build-cn-obj "$TMP/foreach-en.ast" -o "$TMP/foreach-en.o"
cmp "$TMP/foreach-zh.o" "$TMP/foreach-en.o"
"$ASTER_BIN" link-obj "$TMP/foreach-zh.o" -o "$TMP/foreach"
if [ "$CAN_RUN" -eq 1 ]; then
    if "$RUNNER" "$TMP/foreach"; then status=0; else status=$?; fi
    [ "$status" -eq 33 ] || { echo "FAIL: expected exit 33, got $status" >&2; exit 1; }
else
    echo 'SKIP: foreach execution requires qemu-aarch64 or AArch64 Linux'
fi

cat > "$TMP/foreach-read-only.ast" <<'SRC'
// aster:language=zh
方法 启动方法(): 整数
变量 items: 整数[1] = [4]
遍历循环 (item -> items)
item = 5
结束 遍历循环
返回 0
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/foreach-read-only.ast" -o "$TMP/foreach-read-only.o" 2> "$TMP/foreach-read-only.err"; then
    echo 'FAIL: foreach element binding was writable' >&2
    exit 1
fi
grep -q 'cannot assign to a const: item' "$TMP/foreach-read-only.err"

cat > "$TMP/foreach-index-read-only.ast" <<'SRC'
// aster:language=zh
方法 启动方法(): 整数
变量 items: 整数[1] = [4]
遍历循环 (index, item -> items)
index = 5
结束 遍历循环
返回 0
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/foreach-index-read-only.ast" -o "$TMP/foreach-index-read-only.o" 2> "$TMP/foreach-index-read-only.err"; then
    echo 'FAIL: foreach index binding was writable' >&2
    exit 1
fi
grep -q 'cannot assign to a const: index' "$TMP/foreach-index-read-only.err"

printf '%s\n' '[9/19] UTF-8 strings lower and private symbols link across frontends'
cat > "$TMP/string-zh.ast" <<'SRC'
// aster:language=zh
方法 take(text: 字符串): 整数
返回 40
结束 方法
方法 启动方法(): 整数
变量 greeting: 字符串 = "你好"
返回 take(greeting) + take("世界")
结束 方法
SRC
cat > "$TMP/string-en.ast" <<'SRC'
// aster:language=en
fn take(text: string): i32 {
return 40;
}
fn main(): i32 {
let greeting: string = "你好";
return take(greeting) + take("世界");
}
SRC
"$ASTER_BIN" build-cn-obj "$TMP/string-zh.ast" -o "$TMP/string-zh.o"
"$ASTER_BIN" build-cn-obj "$TMP/string-en.ast" -o "$TMP/string-en.o"
cmp "$TMP/string-zh.o" "$TMP/string-en.o"
cat > "$TMP/string-native.ast" <<'SRC'
fn native_literal() -> i32 {
    write(1, "native\n", 7);
    return 0;
}
SRC
"$ASTER_BIN" build-obj "$TMP/string-native.ast" -o "$TMP/string-native.o"
"$ASTER_BIN" link-obj "$TMP/string-zh.o" "$TMP/string-native.o" -o "$TMP/string"
if [ "$CAN_RUN" -eq 1 ]; then
    if "$RUNNER" "$TMP/string"; then status=0; else status=$?; fi
    [ "$status" -eq 80 ] || { echo "FAIL: expected exit 80, got $status" >&2; exit 1; }
else
    echo 'SKIP: string execution requires qemu-aarch64 or AArch64 Linux'
fi

cat > "$TMP/string-default.ast" <<'SRC'
// aster:language=zh
方法 启动方法(): 整数
变量 text: 字符串
如果 text == 空
返回 1
结束 如果
返回 0
结束 方法
SRC
"$ASTER_BIN" build-cn-obj "$TMP/string-default.ast" -o "$TMP/string-default.o"
"$ASTER_BIN" link-obj "$TMP/string-default.o" -o "$TMP/string-default"
if [ "$CAN_RUN" -eq 1 ]; then
    if "$RUNNER" "$TMP/string-default"; then status=0; else status=$?; fi
    [ "$status" -eq 0 ] || { echo "FAIL: expected exit 0, got $status" >&2; exit 1; }
else
    echo 'SKIP: string-default execution requires qemu-aarch64 or AArch64 Linux'
fi

cat > "$TMP/string-return.ast" <<'SRC'
// aster:language=zh
方法 produce(): 字符串
返回 "返回值"
结束 方法
方法 consume(text: 字符串): 整数
返回 29
结束 方法
方法 启动方法(): 整数
返回 consume(produce())
结束 方法
SRC
"$ASTER_BIN" build-cn-obj "$TMP/string-return.ast" -o "$TMP/string-return.o"
"$ASTER_BIN" link-obj "$TMP/string-return.o" -o "$TMP/string-return"
if [ "$CAN_RUN" -eq 1 ]; then
    if "$RUNNER" "$TMP/string-return"; then status=0; else status=$?; fi
    [ "$status" -eq 29 ] || { echo "FAIL: expected exit 29, got $status" >&2; exit 1; }
else
    echo 'SKIP: string-return execution requires qemu-aarch64 or AArch64 Linux'
fi

cat > "$TMP/string-nul.ast" <<'SRC'
// aster:language=zh
方法 启动方法(): 整数
返回 0 + "坏\0"
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/string-nul.ast" -o "$TMP/string-nul.o" 2> "$TMP/string-nul.err"; then
    echo 'FAIL: string literal containing NUL accepted' >&2
    exit 1
fi
grep -q 'string literals cannot contain NUL' "$TMP/string-nul.err"

cat > "$TMP/string-view.ast" <<'SRC'
// aster:language=zh
方法 启动方法(): 整数
变量 text: 字符串视图 = 字符串视图(空)
返回 0
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/string-view.ast" -o "$TMP/string-view.o" 2> "$TMP/string-view.err"; then
    echo 'FAIL: non-string string_view conversion was accepted' >&2
    exit 1
fi
grep -q 'string_view conversion requires a string operand' "$TMP/string-view.err"

printf '%s\n' '[10/19] scalar and array variables receive typed default values'
cat > "$TMP/default-scalars.ast" <<'SRC'
// aster:language=zh
方法 acceptSingle(value: f32): 整数
返回 0
结束 方法
方法 启动方法(): 整数
变量 count: 整数
变量 ready: 逻辑型
变量 letter: 字符
变量 pointer: 指针
变量 precise: f64
变量 single: f32
变量 samples: f64[2]
变量 texts: 字符串[2]
如果 count != 0
返回 1
结束 如果
如果 ready
返回 2
结束 如果
如果 letter != 0
返回 3
结束 如果
如果 pointer != 空
返回 4
结束 如果
如果 precise != 0.0
返回 5
结束 如果
如果 samples[0] != 0.0
返回 6
结束 如果
如果 texts[0] != texts[1]
返回 7
结束 如果
返回 acceptSingle(single)
结束 方法
SRC
"$ASTER_BIN" build-cn-obj "$TMP/default-scalars.ast" -o "$TMP/default-scalars.o"
"$ASTER_BIN" link-obj "$TMP/default-scalars.o" -o "$TMP/default-scalars"
if [ "$CAN_RUN" -eq 1 ]; then
    if "$RUNNER" "$TMP/default-scalars"; then status=0; else status=$?; fi
    [ "$status" -eq 0 ] || { echo "FAIL: expected exit 0, got $status" >&2; exit 1; }
else
    echo 'SKIP: scalar-default execution requires qemu-aarch64 or AArch64 Linux'
fi
cat > "$TMP/default-void.ast" <<'SRC'
// aster:language=zh
方法 启动方法(): 整数
变量 impossible: 空
返回 0
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/default-void.ast" -o "$TMP/default-void.o" 2> "$TMP/default-void.err"; then
    echo 'FAIL: void local was accepted' >&2
    exit 1
fi
grep -q 'void cannot be used as a local variable type' "$TMP/default-void.err"

printf '%s\n' '[11/19] scalar casts lower through the native float ABI'
cat > "$TMP/scalar-casts.ast" <<'SRC'
// aster:language=zh
方法 启动方法(): 整数
变量 single: 单精度 = 单精度(1.0)
变量 precise: 小数 = 小数(1)
变量 truncated: 整数 = 整数(1.75)
如果 single != 单精度(1.0)
返回 1
结束 如果
如果 precise != 1.0
返回 2
结束 如果
如果 truncated != 1
返回 3
结束 如果
返回 0
结束 方法
SRC
"$ASTER_BIN" build-cn-obj "$TMP/scalar-casts.ast" -o "$TMP/scalar-casts.o"
cat > "$TMP/scalar-casts-en.ast" <<'SRC'
// aster:language=en
fn main(): i32 {
let single: f32 = f32(1.0);
let precise: f64 = f64(1);
let truncated: i32 = i32(1.75);
if (single != f32(1.0)) { return 1; }
if (precise != 1.0) { return 2; }
if (truncated != 1) { return 3; }
return 0;
}
SRC
"$ASTER_BIN" build-cn-obj --language en "$TMP/scalar-casts-en.ast" -o "$TMP/scalar-casts-en.o"
cmp "$TMP/scalar-casts.o" "$TMP/scalar-casts-en.o"
"$ASTER_BIN" link-obj "$TMP/scalar-casts.o" -o "$TMP/scalar-casts"
if [ "$CAN_RUN" -eq 1 ]; then
    if "$RUNNER" "$TMP/scalar-casts"; then status=0; else status=$?; fi
    [ "$status" -eq 0 ] || { echo "FAIL: expected exit 0, got $status" >&2; exit 1; }
else
    echo 'SKIP: scalar-cast execution requires qemu-aarch64 or AArch64 Linux'
fi
cat > "$TMP/bad-cast-arity.ast" <<'SRC'
// aster:language=zh
方法 启动方法(): 整数
返回 小数(1, 2)
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/bad-cast-arity.ast" -o "$TMP/bad-cast-arity.o" 2> "$TMP/bad-cast-arity.err"; then
    echo 'FAIL: type cast with two arguments was accepted' >&2
    exit 1
fi
grep -q 'a type cast requires exactly one argument' "$TMP/bad-cast-arity.err"


printf '%s\n' '[12/19] nested structures zero-fill and initialize string fields'
cat > "$TMP/struct-defaults-zh.ast" <<'SRC'
// aster:language=zh
结构 Inner
value: 整数
label: 字符串
结束 结构
结构 Record
nested: Inner
ready: 逻辑型
single: 单精度
precise: 小数
tail: 字符串
pointer: 指针
结束 结构
方法 启动方法(): 整数
变量 item: Record
如果 item.nested.label == 空
返回 1
结束 如果
如果 item.tail == 空
返回 2
结束 如果
如果 item.nested.value != 0
返回 3
结束 如果
如果 item.ready
返回 4
结束 如果
如果 item.single != 单精度(0.0)
返回 5
结束 如果
如果 item.precise != 0.0
返回 6
结束 如果
如果 item.pointer != 空
返回 7
结束 如果
item.nested.value = 27
item.tail = "ready"
返回 item.nested.value
结束 方法
SRC
cat > "$TMP/struct-defaults-en.ast" <<'SRC'
// aster:language=en
struct Inner { value: i32, label: string }
struct Record { nested: Inner, ready: bool, single: f32, precise: f64, tail: string, pointer: ptr }
fn main(): i32 {
let item: Record;
if (item.nested.label == null) { return 1; }
if (item.tail == null) { return 2; }
if (item.nested.value != 0) { return 3; }
if (item.ready) { return 4; }
if (item.single != f32(0.0)) { return 5; }
if (item.precise != 0.0) { return 6; }
if (item.pointer != null) { return 7; }
item.nested.value = 27;
item.tail = "ready";
return item.nested.value;
}
SRC
"$ASTER_BIN" build-cn-obj "$TMP/struct-defaults-zh.ast" -o "$TMP/struct-defaults-zh.o"
"$ASTER_BIN" build-cn-obj --language en "$TMP/struct-defaults-en.ast" -o "$TMP/struct-defaults-en.o"
cmp "$TMP/struct-defaults-zh.o" "$TMP/struct-defaults-en.o"
"$ASTER_BIN" link-obj "$TMP/struct-defaults-zh.o" -o "$TMP/struct-defaults"
if [ "$CAN_RUN" -eq 1 ]; then
    if "$RUNNER" "$TMP/struct-defaults"; then status=0; else status=$?; fi
    [ "$status" -eq 27 ] || { echo "FAIL: expected exit 27, got $status" >&2; exit 1; }
else
    echo 'SKIP: structure-default execution requires qemu-aarch64 or AArch64 Linux'
fi

cat > "$TMP/struct-void-field.ast" <<'SRC'
// aster:language=zh
结构 Invalid
field: 空
结束 结构
方法 启动方法(): 整数
返回 0
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/struct-void-field.ast" -o "$TMP/struct-void-field.o" 2> "$TMP/struct-void-field.err"; then
    echo 'FAIL: void structure field accepted' >&2; exit 1
fi
grep -q 'void cannot be used as a structure field type' "$TMP/struct-void-field.err"

printf '%s\n' '[13/19] nested struct literals initialize locals bilingually'
cat > "$TMP/struct-literal-zh.ast" <<'SRC'
// aster:language=zh
结构 Pair
left: 整数
right: 整数
结束 结构
结构 Box
pair: Pair
label: 字符串
结束 结构
方法 启动方法(): 整数
变量 item: Box = Box { Pair { 19, 23 }, "done" }
如果 item.label == 空
返回 1
结束 如果
返回 item.pair.left + item.pair.right
结束 方法
SRC
cat > "$TMP/struct-literal-en.ast" <<'SRC'
// aster:language=en
struct Pair { left: i32, right: i32 }
struct Box { pair: Pair, label: string }
fn main(): i32 {
let item: Box = Box { Pair { 19, 23 }, "done" };
if (item.label == null) { return 1; }
return item.pair.left + item.pair.right;
}
SRC
"$ASTER_BIN" build-cn-obj "$TMP/struct-literal-zh.ast" -o "$TMP/struct-literal-zh.o"
"$ASTER_BIN" build-cn-obj --language en "$TMP/struct-literal-en.ast" -o "$TMP/struct-literal-en.o"
cmp "$TMP/struct-literal-zh.o" "$TMP/struct-literal-en.o"
"$ASTER_BIN" link-obj "$TMP/struct-literal-zh.o" -o "$TMP/struct-literal"
if [ "$CAN_RUN" -eq 1 ]; then
    if "$RUNNER" "$TMP/struct-literal"; then status=0; else status=$?; fi
    [ "$status" -eq 42 ] || { echo "FAIL: expected exit 42, got $status" >&2; exit 1; }
else
    echo 'SKIP: structure-literal execution requires qemu-aarch64 or AArch64 Linux'
fi

cat > "$TMP/struct-literal-arity.ast" <<'SRC'
// aster:language=zh
结构 Pair
left: 整数
right: 整数
结束 结构
方法 启动方法(): 整数
变量 pair: Pair = Pair { 1 }
返回 0
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/struct-literal-arity.ast" -o "$TMP/struct-literal-arity.o" 2> "$TMP/struct-literal-arity.err"; then
    echo 'FAIL: structure literal with missing field accepted' >&2; exit 1
fi
grep -q "struct literal for 'Pair' has 1 values but the struct has 2 fields" "$TMP/struct-literal-arity.err"

printf '%s\n' '[14/19] structure array fields read, write, and default-initialize bilingually'
cat > "$TMP/struct-array-zh.ast" <<'SRC'
// aster:language=zh
结构 Table
items: 整数[2]
labels: 字符串[2]
结束 结构
方法 启动方法(): 整数
变量 table: Table
如果 table.labels[0] == 空
返回 1
结束 如果
如果 table.labels[1] == 空
返回 2
结束 如果
table.items[0] = 19
table.items[1] = 23
返回 table.items[0] + table.items[1]
结束 方法
SRC
cat > "$TMP/struct-array-en.ast" <<'SRC'
// aster:language=en
struct Table { items: i32[2], labels: string[2] }
fn main(): i32 {
let table: Table;
if (table.labels[0] == null) { return 1; }
if (table.labels[1] == null) { return 2; }
table.items[0] = 19;
table.items[1] = 23;
return table.items[0] + table.items[1];
}
SRC
"$ASTER_BIN" build-cn-obj "$TMP/struct-array-zh.ast" -o "$TMP/struct-array-zh.o"
"$ASTER_BIN" build-cn-obj --language en "$TMP/struct-array-en.ast" -o "$TMP/struct-array-en.o"
cmp "$TMP/struct-array-zh.o" "$TMP/struct-array-en.o"
"$ASTER_BIN" link-obj "$TMP/struct-array-zh.o" -o "$TMP/struct-array"
if [ "$CAN_RUN" -eq 1 ]; then
    if "$RUNNER" "$TMP/struct-array"; then status=0; else status=$?; fi
    [ "$status" -eq 42 ] || { echo "FAIL: expected exit 42, got $status" >&2; exit 1; }
else
    echo 'SKIP: structure-array execution requires qemu-aarch64 or AArch64 Linux'
fi

printf '%s\n' '[15/19] automatic defaults remain readable without a second assignment'
cat > "$TMP/default-read-zh.ast" <<'SRC'
// aster:language=zh
结构 Defaults
count: 整数
label: 字符串
items: 整数[2]
结束 结构
方法 启动方法(): 整数
变量 scalar: 整数
变量 value: Defaults
如果 scalar != 0
返回 1
结束 如果
如果 value.count != 0
返回 2
结束 如果
如果 value.label == 空
返回 3
结束 如果
如果 value.items[0] != 0
返回 4
结束 如果
返回 0
结束 方法
SRC
cat > "$TMP/default-read-en.ast" <<'SRC'
// aster:language=en
struct Defaults { count: i32, label: string, items: i32[2] }
fn main(): i32 {
let scalar: i32;
let value: Defaults;
if (scalar != 0) { return 1; }
if (value.count != 0) { return 2; }
if (value.label == null) { return 3; }
if (value.items[0] != 0) { return 4; }
return 0;
}
SRC
"$ASTER_BIN" build-cn-obj "$TMP/default-read-zh.ast" -o "$TMP/default-read-zh.o"
"$ASTER_BIN" build-cn-obj --language en "$TMP/default-read-en.ast" -o "$TMP/default-read-en.o"
cmp "$TMP/default-read-zh.o" "$TMP/default-read-en.o"

printf '%s\n' '[16/19] structure array element members initialize and read bilingually'
cat > "$TMP/struct-array-element-zh.ast" <<'SRC'
// aster:language=zh
结构 Point
x: 整数
y: 整数
label: 字符串
结束 结构
方法 启动方法(): 整数
变量 points: Point[2] = [Point { 1, 2, "first" }, Point { 3, 4, "second" }]
变量 defaults: Point[1]
如果 defaults[0].label == 空
返回 1
结束 如果
如果 defaults[0].x != 0
返回 2
结束 如果
points[1].y = 44
返回 points[1].y
结束 方法
SRC
cat > "$TMP/struct-array-element-en.ast" <<'SRC'
// aster:language=en
struct Point { x: i32, y: i32, label: string }
fn main(): i32 {
let points: Point[2] = [Point { 1, 2, "first" }, Point { 3, 4, "second" }];
let defaults: Point[1];
if (defaults[0].label == null) { return 1; }
if (defaults[0].x != 0) { return 2; }
points[1].y = 44;
return points[1].y;
}
SRC
"$ASTER_BIN" build-cn-obj "$TMP/struct-array-element-zh.ast" -o "$TMP/struct-array-element-zh.o"
"$ASTER_BIN" build-cn-obj --language en "$TMP/struct-array-element-en.ast" -o "$TMP/struct-array-element-en.o"
cmp "$TMP/struct-array-element-zh.o" "$TMP/struct-array-element-en.o"
"$ASTER_BIN" link-obj "$TMP/struct-array-element-zh.o" -o "$TMP/struct-array-element"
if [ "$CAN_RUN" -eq 1 ]; then
    if "$RUNNER" "$TMP/struct-array-element"; then status=0; else status=$?; fi
    [ "$status" -eq 44 ] || { echo "FAIL: expected exit 44, got $status" >&2; exit 1; }
else
    echo 'SKIP: structure-array-element execution requires qemu-aarch64 or AArch64 Linux'
fi

printf '%s\n' '[17/19] enumloop exposes bilingual structure field metadata'
cat > "$TMP/enumloop-zh.ast" <<'SRC'
// aster:language=zh
结构 Record
id: 整数
score: 长整数
label: 字符串
items: 整数[2]
结束 结构
结构 Holder
item: Record
结束 结构
方法 启动方法(): 整数
变量 record: Record
record.id = 11
record.score = 29
record.label = "value"
变量 seen: 整数 = 0
枚举循环 (field -> record)
如果 field.名称 == 空
返回 1
结束 如果
如果 field.值 == 空
返回 2
结束 如果
如果 field.类型 == 1
如果 field.值 == &record.id
seen = seen + 1
结束 如果
如果 field.值 == &record.items[0]
seen = seen + 10
结束 如果
跳过循环
结束 如果
如果 field.类型 == 2
如果 field.值 == &record.score
seen = seen + 100
结束 如果
结束 如果
如果 field.类型 == 3
如果 field.值 == &record.label
seen = seen + 1000
结束 如果
结束 如果
结束 枚举循环
如果 seen != 1111
返回 3
结束 如果
变量 holder: Holder
holder.item.id = 23
变量 memberSeen: 整数 = 0
枚举循环 (entry -> holder.item)
如果 entry.值 == &holder.item.id
memberSeen = memberSeen + 1
结束 如果
结束 枚举循环
如果 memberSeen != 1
返回 4
结束 如果
变量 records: Record[2]
records[0].id = 31
records[1].id = 47
变量 selected: 整数 = 0
变量 arraySeen: 整数 = 0
枚举循环 (entry -> records[selected])
selected = 1
如果 entry.值 == &records[0].id
arraySeen = arraySeen + 1
结束 如果
如果 entry.值 == &records[1].id
arraySeen = arraySeen + 100
结束 如果
结束 枚举循环
如果 arraySeen != 1
返回 5
结束 如果
变量 visits: 整数 = 0
枚举循环 (item -> record)
visits = visits + 1
退出循环
结束 枚举循环
返回 visits - 1
结束 方法
SRC
cat > "$TMP/enumloop-en.ast" <<'SRC'
// aster:language=en
struct Record { id: i32, score: i64, label: string, items: i32[2] }
struct Holder { item: Record }
fn main(): i32 {
let record: Record;
record.id = 11;
record.score = 29;
record.label = "value";
let seen: i32 = 0;
enumloop field in record {
if (field.name == null) { return 1; }
if (field.value == null) { return 2; }
if (field.type == 1) {
if (field.value == &record.id) { seen = seen + 1; }
if (field.value == &record.items[0]) { seen = seen + 10; }
continue;
}
if (field.type == 2) { if (field.value == &record.score) { seen = seen + 100; } }
if (field.type == 3) { if (field.value == &record.label) { seen = seen + 1000; } }
}
if (seen != 1111) { return 3; }
let holder: Holder;
holder.item.id = 23;
let memberSeen: i32 = 0;
enumloop entry in holder.item { if (entry.value == &holder.item.id) { memberSeen = memberSeen + 1; } }
if (memberSeen != 1) { return 4; }
let records: Record[2];
records[0].id = 31;
records[1].id = 47;
let selected: i32 = 0;
let arraySeen: i32 = 0;
enumloop entry in records[selected] {
selected = 1;
if (entry.value == &records[0].id) { arraySeen = arraySeen + 1; }
if (entry.value == &records[1].id) { arraySeen = arraySeen + 100; }
}
if (arraySeen != 1) { return 5; }
let visits: i32 = 0;
enumloop item in record { visits = visits + 1; break; }
return visits - 1;
}
SRC
"$ASTER_BIN" build-cn-obj "$TMP/enumloop-zh.ast" -o "$TMP/enumloop-zh.o"
"$ASTER_BIN" build-cn-obj --language en "$TMP/enumloop-en.ast" -o "$TMP/enumloop-en.o"
cmp "$TMP/enumloop-zh.o" "$TMP/enumloop-en.o"
"$ASTER_BIN" link-obj "$TMP/enumloop-zh.o" -o "$TMP/enumloop"
if [ "$CAN_RUN" -eq 1 ]; then
    if "$RUNNER" "$TMP/enumloop"; then status=0; else status=$?; fi
    [ "$status" -eq 0 ] || { echo "FAIL: expected exit 0, got $status" >&2; exit 1; }
else
    echo 'SKIP: enumloop execution requires qemu-aarch64 or AArch64 Linux'
fi

cat > "$TMP/enumloop-scalar.ast" <<'SRC'
// aster:language=zh
方法 启动方法(): 整数
变量 value: 整数 = 7
枚举循环 (field -> value)
返回 1
结束 枚举循环
返回 0
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/enumloop-scalar.ast" -o "$TMP/enumloop-scalar.o" 2> "$TMP/enumloop-scalar.err"; then
    echo 'FAIL: enumloop accepted a scalar object' >&2; exit 1
fi
grep -q 'enumloop object must be a structure variable' "$TMP/enumloop-scalar.err"

printf '%s\n' '[18/19] auto-initialized unchanged values produce conservative warnings'
cat > "$TMP/stable-zh.ast" <<'SRC'
// aster:language=zh
结构 Data
fixed: 整数
changed: 整数
escaped: 整数
结束 结构
方法 inspect(value: 指针): 空
返回
结束 方法
方法 启动方法(): 整数
变量 stable: 整数
变量 changed: 整数
changed = 2
变量 escaped: 整数
变量 escapedPointer: 指针 = 指针(&escaped)
变量 data: Data
data.changed = 5
变量 fieldPointer: 指针 = 指针(&data.escaped)
变量 values: 整数[2]
values[0] = 1
变量 passed: 整数[2]
inspect(passed)
变量 conditional: 整数
如果 (真)
conditional = 9
结束 如果
变量 explicit: 整数 = 7
常量 constant: 整数 = 3
返回 stable + data.fixed + values[1] + conditional + explicit + constant + changed + escaped + data.changed
结束 方法
SRC
cat > "$TMP/stable-en.ast" <<'SRC'
// aster:language=en
struct Data { fixed: i32, changed: i32, escaped: i32 }
fn inspect(value: ptr): void { return; }
fn main(): i32 {
let stable: i32;
let changed: i32;
changed = 2;
let escaped: i32;
let escapedPointer: ptr = ptr(&escaped);
let data: Data;
data.changed = 5;
let fieldPointer: ptr = ptr(&data.escaped);
let values: i32[2];
values[0] = 1;
let passed: i32[2];
inspect(passed);
let conditional: i32;
if (true) { conditional = 9; }
let explicit: i32 = 7;
const constant: i32 = 3;
return stable + data.fixed + values[1] + conditional + explicit + constant + changed + escaped + data.changed;
}
SRC
"$ASTER_BIN" build-cn-obj "$TMP/stable-zh.ast" -o "$TMP/stable-zh.o" 2> "$TMP/stable-zh.err"
"$ASTER_BIN" build-cn-obj --language en "$TMP/stable-en.ast" -o "$TMP/stable-en.o" 2> "$TMP/stable-en.err"
cmp "$TMP/stable-zh.o" "$TMP/stable-en.o" || { echo "FAIL: \$TMP/stable-zh.o and \$TMP/stable-en.o differ" >&2; exit 1; }
for language in zh en; do
    if [ "$language" = zh ]; then
        stable_warning="warning: 局部变量 'stable' 仅获得初始值"
        field_warning="warning: 字段 'data.fixed' 仅获得初始值"
        unexpected="warning: (局部变量 'changed'|局部变量 'escaped'|字段 'data.changed'|字段 'data.escaped'|局部数组 'values'|局部数组 'passed'|局部变量 'conditional'|局部变量 'explicit')"
    else
        stable_warning="warning: local variable 'stable' receives only its initial value"
        field_warning="warning: field 'data.fixed' receives only its initial value"
        unexpected="warning: (local variable 'changed'|local variable 'escaped'|field 'data.changed'|field 'data.escaped'|local array 'values'|local array 'passed'|local variable 'conditional'|local variable 'explicit')"
    fi
    grep -q "$stable_warning" "$TMP/stable-$language.err"
    grep -q "$field_warning" "$TMP/stable-$language.err"
    if grep -Eq "$unexpected" "$TMP/stable-$language.err"; then
        echo "FAIL: stable-value analysis warned about a modified, escaped, explicitly initialized, or constant binding ($language)" >&2
        exit 1
    fi
done

printf '%s\n' '[19/19] signed i8 and i16 values preserve their ranges and ABI'
cat > "$TMP/signed-narrow-zh.ast" <<'SRC'
// aster:language=zh
结构 Values
byte: 字节
short: 短整数
bytes: 字节[2]
shorts: 短整数[2]
结束 结构
结构 Metadata
byte: 字节
short: 短整数
结束 结构
方法 identity8(value: 字节): 字节
返回 value
结束 方法
方法 identity16(value: 短整数): 短整数
返回 value
结束 方法
方法 widen8(value: 字节): 长整数
返回 value
结束 方法
方法 widen16(value: 短整数): 长整数
返回 value
结束 方法
方法 reinterpret8(value: u字节): 字节
返回 字节(value)
结束 方法
方法 reinterpret16(value: u短整数): 短整数
返回 短整数(value)
结束 方法
方法 stackCheck(a: 整数, b: 整数, c: 整数, d: 整数, e: 整数, f: 整数, g: 整数, h: 整数, value8: 字节, value16: 短整数): 整数
返回 widen8(value8) + widen16(value16) + 312
结束 方法
方法 启动方法(): 整数
变量 zero8: 字节
变量 zero16: 短整数
如果 zero8 != 0
返回 1
结束 如果
如果 zero16 != 0
返回 2
结束 如果
变量 byteValue: 字节 = 字节(255)
变量 shortValue: 短整数 = 短整数(65534)
如果 byteValue != -1
返回 3
结束 如果
如果 shortValue != -2
返回 4
结束 如果
如果 reinterpret8(u字节(255)) != -1
返回 4
结束 如果
如果 reinterpret16(u短整数(65534)) != -2
返回 4
结束 如果
如果 byteValue >= 0
返回 3
结束 如果
变量 matched: 整数 = 0
假如 byteValue
是 -1
matched = matched + 1
否则
返回 4
结束 假如
如果 matched != 1
返回 4
结束 如果
如果 widen8(identity8(byteValue)) != -1
返回 5
结束 如果
如果 widen16(identity16(shortValue)) != -2
返回 6
结束 如果
变量 bytes: 字节[2] = [字节(128), 字节(127)]
变量 shorts: 短整数[2] = [短整数(32768), 短整数(32767)]
如果 bytes[0] != -128
返回 7
结束 如果
如果 shorts[0] != -32768
返回 8
结束 如果
变量 values: Values
如果 values.byte != 0 || values.short != 0 || values.bytes[1] != 0 || values.shorts[0] != 0
返回 9
结束 如果
values.byte = -120
values.short = -1234
values.bytes[1] = -128
values.shorts[0] = -32768
如果 values.byte != -120 || values.short != -1234 || values.bytes[1] != -128 || values.shorts[0] != -32768
返回 10
结束 如果
变量 metadata: Metadata
变量 kinds: 整数 = 0
枚举循环 (field -> metadata)
如果 field.类型 == 15
如果 field.值 == &metadata.byte
kinds = kinds + 1
结束 如果
结束 如果
如果 field.类型 == 16
如果 field.值 == &metadata.short
kinds = kinds + 2
结束 如果
结束 如果
结束 枚举循环
如果 kinds != 3
返回 11
结束 如果
如果 stackCheck(0, 0, 0, 0, 0, 0, 0, 0, -12, -300) != 0
返回 12
结束 如果
返回 0
结束 方法
SRC
cat > "$TMP/signed-narrow-en.ast" <<'SRC'
// aster:language=en
struct Values { byte: i8, short: i16, bytes: i8[2], shorts: i16[2] }
struct Metadata { byte: i8, short: i16 }
fn identity8(value: i8): i8 { return value; }
fn identity16(value: i16): i16 { return value; }
fn widen8(value: i8): i64 { return value; }
fn widen16(value: i16): i64 { return value; }
fn reinterpret8(value: u8): i8 { return i8(value); }
fn reinterpret16(value: u16): i16 { return i16(value); }
fn stackCheck(a: i32, b: i32, c: i32, d: i32, e: i32, f: i32, g: i32, h: i32, value8: i8, value16: i16): i32 {
return widen8(value8) + widen16(value16) + 312;
}
fn main(): i32 {
let zero8: i8;
let zero16: i16;
if (zero8 != 0) { return 1; }
if (zero16 != 0) { return 2; }
let byteValue: i8 = i8(255);
let shortValue: i16 = i16(65534);
if (byteValue != -1) { return 3; }
if (shortValue != -2) { return 4; }
if (reinterpret8(u8(255)) != -1) { return 4; }
if (reinterpret16(u16(65534)) != -2) { return 4; }
if (byteValue >= 0) { return 3; }
let matched: i32 = 0;
switch (byteValue) {
case -1
matched = matched + 1;
else
return 4;
}
if (matched != 1) { return 4; }
if (widen8(identity8(byteValue)) != -1) { return 5; }
if (widen16(identity16(shortValue)) != -2) { return 6; }
let bytes: i8[2] = [i8(128), i8(127)];
let shorts: i16[2] = [i16(32768), i16(32767)];
if (bytes[0] != -128) { return 7; }
if (shorts[0] != -32768) { return 8; }
let values: Values;
if (values.byte != 0 || values.short != 0 || values.bytes[1] != 0 || values.shorts[0] != 0) { return 9; }
values.byte = -120;
values.short = -1234;
values.bytes[1] = -128;
values.shorts[0] = -32768;
if (values.byte != -120 || values.short != -1234 || values.bytes[1] != -128 || values.shorts[0] != -32768) { return 10; }
let metadata: Metadata;
let kinds: i32 = 0;
enumloop field in metadata {
if (field.type == 15) { if (field.value == &metadata.byte) { kinds = kinds + 1; } }
if (field.type == 16) { if (field.value == &metadata.short) { kinds = kinds + 2; } }
}
if (kinds != 3) { return 11; }
if (stackCheck(0, 0, 0, 0, 0, 0, 0, 0, -12, -300) != 0) { return 12; }
return 0;
}
SRC
"$ASTER_BIN" build-cn-obj "$TMP/signed-narrow-zh.ast" -o "$TMP/signed-narrow-zh.o"
"$ASTER_BIN" build-cn-obj --language en "$TMP/signed-narrow-en.ast" -o "$TMP/signed-narrow-en.o"
cmp "$TMP/signed-narrow-zh.o" "$TMP/signed-narrow-en.o"
"$ASTER_BIN" build-cn-obj -g "$TMP/signed-narrow-zh.ast" -o "$TMP/signed-narrow-debug.o"
if command -v strings >/dev/null 2>&1; then
    strings -n 2 "$TMP/signed-narrow-debug.o" | grep -qx 'i8'
    strings -n 2 "$TMP/signed-narrow-debug.o" | grep -qx 'i16'
fi
"$ASTER_BIN" link-obj "$TMP/signed-narrow-zh.o" -o "$TMP/signed-narrow"
if [ "$CAN_RUN" -eq 1 ]; then
    if "$RUNNER" "$TMP/signed-narrow"; then status=0; else status=$?; fi
    [ "$status" -eq 0 ] || { echo "FAIL: expected exit 0, got $status" >&2; exit 1; }
else
    echo 'SKIP: signed-narrow execution requires qemu-aarch64 or AArch64 Linux'
fi
cat > "$TMP/native-signed-narrow.ast" <<'SRC'
fn narrow8(value: i8) -> i8 { return value; }
fn widen16(value: i16) -> i64 { return value; }
fn main() -> i32 {
    let byte: i8 = i8(255);
    let short: i16 = i16(65534);
    if (narrow8(byte) != -1) { return 1; }
    if (widen16(short) != -2) { return 2; }
    return 0;
}
SRC
"$ASTER_BIN" build-elf "$TMP/native-signed-narrow.ast" -o "$TMP/native-signed-narrow"
if [ "$CAN_RUN" -eq 1 ]; then
    if "$RUNNER" "$TMP/native-signed-narrow"; then status=0; else status=$?; fi
    [ "$status" -eq 0 ] || { echo "FAIL: expected exit 0, got $status" >&2; exit 1; }
else
    echo 'SKIP: native signed-narrow execution requires qemu-aarch64 or AArch64 Linux'
fi
for narrow_case in 'byte i8 128' 'short i16 32768'; do
    set -- $narrow_case
    name=$1
    type=$2
    value=$3
    cat > "$TMP/signed-narrow-overflow.ast" <<SRC
// aster:language=en
fn main(): i32 { let invalid: $type = $value; return 0; }
SRC
    if "$ASTER_BIN" build-cn-obj "$TMP/signed-narrow-overflow.ast" -o "$TMP/signed-narrow-overflow.o" 2> "$TMP/signed-narrow-overflow.err"; then
        echo "FAIL: out-of-range $name initializer accepted" >&2
        exit 1
    fi
    grep -q "initializer does not fit in $type" "$TMP/signed-narrow-overflow.err"
done

cat > "$TMP/closure-unknown-capture.ast" <<'SRC'
// aster:language=en
fn main(): i32 {
let value: i32 = 2;
let callback = fn [missing] (): i32 {
return 0;
};
return 0;
}
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/closure-unknown-capture.ast" \
    -o "$TMP/closure-unknown-capture.o" 2> "$TMP/closure-unknown-capture.err"; then
    echo 'FAIL: unknown closure capture was accepted' >&2
    exit 1
fi
grep -q 'unknown closure capture: missing' "$TMP/closure-unknown-capture.err"

cat > "$TMP/closure-uncaptured-body.ast" <<'SRC'
// aster:language=zh
方法 启动方法(): 整数
    变量 步长: 整数 = 2
    变量 局部值: 整数 = 9
    变量 回调 = 方法 [步长] (): 整数
        返回 局部值
    结束 方法
    返回 0
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/closure-uncaptured-body.ast" \
    -o "$TMP/closure-uncaptured-body.o" 2> "$TMP/closure-uncaptured-body.err"; then
    echo 'FAIL: closure body referenced an uncaptured local' >&2
    exit 1
fi
grep -q 'unknown variable: 局部值' "$TMP/closure-uncaptured-body.err"

cat > "$TMP/closure-global-capture.ast" <<'SRC'
// aster:language=en
let shared: i32 = 3;
fn main(): i32 {
let callback = fn [shared] (): i32 {
return 0;
};
return 0;
}
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/closure-global-capture.ast" \
    -o "$TMP/closure-global-capture.o" 2> "$TMP/closure-global-capture.err"; then
    echo 'FAIL: global closure capture was accepted' >&2
    exit 1
fi
grep -q 'global variable cannot be captured; access it directly: shared' \
    "$TMP/closure-global-capture.err"

cat > "$TMP/closure-large-env.ast" <<'SRC'
// aster:language=en
struct Large {
bytes: i64[33]
}
fn main(): i32 {
let large: Large;
let callback = fn [large] (): i32 {
return 0;
};
return 0;
}
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/closure-large-env.ast" \
    -o "$TMP/closure-large-env.o" 2> "$TMP/closure-large-env.err"; then
    echo 'FAIL: oversized closure environment was accepted' >&2
    exit 1
fi
grep -q "closure environment exceeds 256 bytes at capture 'large'" \
    "$TMP/closure-large-env.err"

cat > "$TMP/closure-this-outside.ast" <<'SRC'
// aster:language=en
fn main(): i32 {
let callback = fn [this] (): i32 {
return 0;
};
return 0;
}
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/closure-this-outside.ast" \
    -o "$TMP/closure-this-outside.o" 2> "$TMP/closure-this-outside.err"; then
    echo 'FAIL: this capture outside an instance method was accepted' >&2
    exit 1
fi
grep -q 'this can only be captured inside an instance method' \
    "$TMP/closure-this-outside.err"

cat > "$TMP/closure-valid-capture.ast" <<'SRC'
// aster:language=en
fn main(): i32 {
let step: i32 = 2;
let callback = fn [step] (value: i32): i32 {
return value + step;
};
step = 3;
return callback(40);
}
SRC
"$ASTER_BIN" build-cn-obj "$TMP/closure-valid-capture.ast" \
    -o "$TMP/closure-valid-capture.o"

cat > "$TMP/closure-zero-en.ast" <<'SRC'
// aster:language=en
fn main(): i32 {
let callback = fn [] (value: i32): i32 {
return value + 1;
};
return callback(41);
}
SRC
"$ASTER_BIN" build-cn-obj --language en "$TMP/closure-zero-en.ast" \
    -o "$TMP/closure-zero-en.o"

cat > "$TMP/closure-zero-zh.ast" <<'SRC'
// aster:language=zh
方法 启动方法(): 整数
    变量 回调: 闭包(整数): 整数 = 方法 [] (数值: 整数): 整数
        返回 数值 + 1
    结束 方法
    返回 回调(41)
结束 方法
SRC
"$ASTER_BIN" build-cn-obj "$TMP/closure-zero-zh.ast" \
    -o "$TMP/closure-zero-zh.o"

cat > "$TMP/closure-field-en.ast" <<'SRC'
// aster:language=en
struct Holder { callback: closure(i32): i32 }
fn main(): i32 {
let holder: Holder;
holder.callback = fn [] (value: i32): i32 {
return value + 1;
};
return holder.callback(41);
}
SRC
"$ASTER_BIN" build-cn-obj --language en "$TMP/closure-field-en.ast" \
    -o "$TMP/closure-field-en.o"

cat > "$TMP/closure-field-zh.ast" <<'SRC'
// aster:language=zh
结构 持有者
    回调: 闭包(整数): 整数
结束 结构
方法 启动方法(): 整数
    变量 持有者值: 持有者
    持有者值.回调 = 方法 [] (数值: 整数): 整数
        返回 数值 + 1
    结束 方法
    返回 持有者值.回调(41)
结束 方法
SRC
"$ASTER_BIN" build-cn-obj "$TMP/closure-field-zh.ast" \
    -o "$TMP/closure-field-zh.o"

cat > "$TMP/closure-array-en.ast" <<'SRC'
// aster:language=en
fn main(): i32 {
let callbacks: closure(i32): i32[1];
callbacks[0] = fn [] (value: i32): i32 {
return value + 1;
};
return callbacks[0](41);
}
SRC
"$ASTER_BIN" build-cn-obj --language en "$TMP/closure-array-en.ast" \
    -o "$TMP/closure-array-en.o"

cat > "$TMP/closure-array-zh.ast" <<'SRC'
// aster:language=zh
方法 启动方法(): 整数
    变量 回调们: 闭包(整数): 整数[1]
    回调们[0] = 方法 [] (数值: 整数): 整数
        返回 数值 + 1
    结束 方法
    返回 回调们[0](41)
结束 方法
SRC
"$ASTER_BIN" build-cn-obj "$TMP/closure-array-zh.ast" \
    -o "$TMP/closure-array-zh.o"

cat > "$TMP/closure-array-capture-en.ast" <<'SRC'
// aster:language=en
fn main(): i32 {
    let values: i32[2] = [20, 22];
    let callback = fn [values] (index: i32): i32 {
        return values[index];
    };
    return callback(1);
}
SRC
"$ASTER_BIN" build-cn-obj --language en "$TMP/closure-array-capture-en.ast" \
    -o "$TMP/closure-array-capture-en.o"

cat > "$TMP/closure-array-capture-zh.ast" <<'SRC'
// aster:language=zh
方法 启动方法(): 整数
    变量 数组: 整数[2] = [20, 22]
    变量 回调 = 方法 [数组] (索引: 整数): 整数
        返回 数组[索引]
    结束 方法
    返回 回调(1)
结束 方法
SRC
"$ASTER_BIN" build-cn-obj "$TMP/closure-array-capture-zh.ast" \
    -o "$TMP/closure-array-capture-zh.o"

cat > "$TMP/closure-callback-adapter-en.ast" <<'SRC'
// aster:language=en
let observed: i32 = 0;
fn register(callback: fn(ptr): i32, user: ptr): i32 {
    return callback(user);
}
fn main(): i32 {
    let offset: i32 = 41;
    let callback = fn [offset] (user: ptr): i32 {
        observed = offset + 1;
        return 0;
    };
    register(callback, null);
    let value: i32 = register(callback, null);
    value = register(callback, null);
    return observed + value;
}
SRC
"$ASTER_BIN" build-cn-obj --language en "$TMP/closure-callback-adapter-en.ast" \
    -o "$TMP/closure-callback-adapter-en.o"

cat > "$TMP/closure-callback-adapter-zh.ast" <<'SRC'
// aster:language=zh
变量 观察值: 整数 = 0
方法 注册(回调: 方法(指针): 整数, 用户: 指针): 整数
    返回 回调(用户)
结束 方法
方法 启动方法(): 整数
    变量 偏移: 整数 = 41
    变量 回调 = 方法 [偏移] (用户: 指针): 整数
        观察值 = 偏移 + 1
        返回 偏移 + 1
    结束 方法
    返回 注册(回调, 空)
结束 方法
SRC
"$ASTER_BIN" build-cn-obj "$TMP/closure-callback-adapter-zh.ast" \
    -o "$TMP/closure-callback-adapter-zh.o"

cat > "$TMP/closure-callback-member-en.ast" <<'SRC'
// aster:language=en
class Scheduler {
    @static
    fn register(callback: fn(ptr): i32, user: ptr): i32 {
        return callback(user);
    }
}
fn main(): i32 {
    let offset: i32 = 41;
    let callback = fn [offset] (user: ptr): i32 {
        return offset + 1;
    };
    return Scheduler.register(callback, null);
}
SRC
"$ASTER_BIN" build-cn-obj --language en "$TMP/closure-callback-member-en.ast" \
    -o "$TMP/closure-callback-member-en.o"

cat > "$TMP/closure-callback-member-zh.ast" <<'SRC'
// aster:language=zh
类 调度器
    方法 注册(回调: 方法(指针): 整数, 用户: 指针): 整数
        返回 回调(用户)
    结束 方法
结束 类
方法 启动方法(): 整数
    变量 调度: 调度器 = 调度器()
    变量 偏移: 整数 = 41
    变量 回调 = 方法 [偏移] (用户: 指针): 整数
        返回 偏移 + 1
    结束 方法
    返回 调度.注册(回调, 空)
结束 方法
SRC
"$ASTER_BIN" build-cn-obj "$TMP/closure-callback-member-zh.ast" \
    -o "$TMP/closure-callback-member-zh.o"

cat > "$TMP/closure-callback-field-en.ast" <<'SRC'
// aster:language=en
struct Holder { callback: closure(ptr): i32 }
fn register(callback: fn(ptr): i32, user: ptr): i32 {
    return callback(user);
}
fn main(): i32 {
    let holder: Holder;
    holder.callback = fn [] (user: ptr): i32 {
        return 42;
    };
    return register(holder.callback, null);
}
SRC
"$ASTER_BIN" build-cn-obj --language en "$TMP/closure-callback-field-en.ast" \
    -o "$TMP/closure-callback-field-en.o"

cat > "$TMP/closure-callback-array-zh.ast" <<'SRC'
// aster:language=zh
方法 注册(回调: 方法(指针): 整数, 用户: 指针): 整数
    返回 回调(用户)
结束 方法
方法 启动方法(): 整数
    变量 回调们: 闭包(指针): 整数[1]
    回调们[0] = 方法 [] (用户: 指针): 整数
        返回 43
    结束 方法
    返回 注册(回调们[0], 空)
结束 方法
SRC
"$ASTER_BIN" build-cn-obj "$TMP/closure-callback-array-zh.ast" \
    -o "$TMP/closure-callback-array-zh.o"

cat > "$TMP/closure-callback-delayed-en.ast" <<'SRC'
// aster:language=en
let saved0: fn(ptr): i32 = null;
let saved1: fn(ptr): i32 = null;
let user0: ptr = null;
let user1: ptr = null;
fn register(callback: fn(ptr): i32, user: ptr, slot: i32): i32 {
    if (slot == 0) {
        saved0 = callback;
        user0 = user;
    } else {
        saved1 = callback;
        user1 = user;
    }
    return 0;
}
fn install(offset: i32, slot: i32, user: ptr): i32 {
    let callback = fn [offset] (user: ptr): i32 {
        if (user == null) { return offset; }
        return offset + 1;
    };
    register(callback, user, slot);
    return 0;
}
fn invoke0(): i32 { return saved0(user0); }
fn invoke1(): i32 { return saved1(user1); }
fn main(): i32 {
    let marker0: i32 = 0;
    let marker1: i32 = 0;
    install(41, 0, &marker0);
    install(42, 1, &marker1);
    return invoke0() + invoke1();
}
SRC
"$ASTER_BIN" build-cn-obj --language en "$TMP/closure-callback-delayed-en.ast" \
    -o "$TMP/closure-callback-delayed-en.o"

cat > "$TMP/closure-callback-delayed-zh.ast" <<'SRC'
// aster:language=zh
变量 保存一: 方法(指针): 整数 = 空
变量 保存二: 方法(指针): 整数 = 空
变量 用户一: 指针 = 空
变量 用户二: 指针 = 空
方法 注册(回调: 方法(指针): 整数, 用户: 指针, 槽: 整数): 整数
    如果 槽
        保存二 = 回调
        用户二 = 用户
    否则
        保存一 = 回调
        用户一 = 用户
    结束 如果
    返回 0
结束 方法
方法 安装(偏移: 整数, 槽: 整数, 用户指针: 指针): 整数
    变量 回调 = 方法 [偏移] (用户: 指针): 整数
        如果 用户 == 空
            返回 偏移
        结束 如果
        返回 偏移 + 1
    结束 方法
    注册(回调, 用户指针, 槽)
    返回 0
结束 方法
方法 调用一(): 整数
    返回 保存一(用户一)
结束 方法
方法 调用二(): 整数
    返回 保存二(用户二)
结束 方法
方法 启动方法(): 整数
    变量 标记一: 整数 = 0
    变量 标记二: 整数 = 0
    安装(41, 0, &标记一)
    安装(42, 1, &标记二)
    返回 调用一() + 调用二()
结束 方法
SRC
"$ASTER_BIN" build-cn-obj "$TMP/closure-callback-delayed-zh.ast" \
    -o "$TMP/closure-callback-delayed-zh.o"

cat > "$TMP/closure-callback-nested-en.ast" <<'SRC'
// aster:language=en
fn register(callback: fn(ptr): i32, user: ptr): i32 {
    return callback(user);
}
fn bump(value: i32): i32 { return value + 1; }
fn main(): i32 {
    let offset: i32 = 41;
    let callback = fn [offset] (user: ptr): i32 {
        return offset;
    };
    return bump(register(callback, null));
}
SRC
"$ASTER_BIN" build-cn-obj --language en "$TMP/closure-callback-nested-en.ast" \
    -o "$TMP/closure-callback-nested-en.o"

cat > "$TMP/closure-callback-nested-zh.ast" <<'SRC'
// aster:language=zh
方法 注册(回调: 方法(指针): 整数, 用户: 指针): 整数
    返回 回调(用户)
结束 方法
方法 加一(数值: 整数): 整数
    返回 数值 + 1
结束 方法
方法 启动方法(): 整数
    变量 偏移: 整数 = 41
    变量 回调 = 方法 [偏移] (用户: 指针): 整数
        返回 偏移
    结束 方法
    返回 加一(注册(回调, 空))
结束 方法
SRC
"$ASTER_BIN" build-cn-obj "$TMP/closure-callback-nested-zh.ast" \
    -o "$TMP/closure-callback-nested-zh.o"

cat > "$TMP/closure-callback-condition-en.ast" <<'SRC'
// aster:language=en
fn register(callback: fn(ptr): i32, user: ptr): i32 {
    return callback(user);
}
fn main(): i32 {
    let callback = fn [] (user: ptr): i32 {
        return 42;
    };
    if (register(callback, null)) {
        return 42;
    } else {
        return 7;
    }
}
SRC
"$ASTER_BIN" build-cn-obj --language en "$TMP/closure-callback-condition-en.ast" \
    -o "$TMP/closure-callback-condition-en.o"

cat > "$TMP/closure-callback-condition-zh.ast" <<'SRC'
// aster:language=zh
方法 注册(回调: 方法(指针): 整数, 用户: 指针): 整数
    返回 回调(用户)
结束 方法
方法 启动方法(): 整数
    变量 回调 = 方法 [] (用户: 指针): 整数
        返回 42
    结束 方法
    如果 注册(回调, 空)
        返回 42
    否则
        返回 7
    结束 如果
结束 方法
SRC
"$ASTER_BIN" build-cn-obj "$TMP/closure-callback-condition-zh.ast" \
    -o "$TMP/closure-callback-condition-zh.o"

cat > "$TMP/closure-callback-while-en.ast" <<'SRC'
// aster:language=en
let visits: i32 = 0;
fn register(callback: fn(ptr): i32, user: ptr): i32 {
    visits = visits + 1;
    return visits;
}
fn main(): i32 {
    let callback = fn [] (user: ptr): i32 {
        return 0;
    };
    let body_visits: i32 = 0;
    while (register(callback, null) < 3) {
        body_visits = body_visits + 1;
        continue;
    }
    return visits + body_visits;
}
SRC
"$ASTER_BIN" build-cn-obj --language en "$TMP/closure-callback-while-en.ast" \
    -o "$TMP/closure-callback-while-en.o"

cat > "$TMP/closure-callback-while-zh.ast" <<'SRC'
// aster:language=zh
变量 次数: 整数 = 0
方法 注册(回调: 方法(指针): 整数, 用户: 指针): 整数
    次数 = 次数 + 1
    返回 次数
结束 方法
方法 启动方法(): 整数
    变量 回调 = 方法 [] (用户: 指针): 整数
        返回 0
    结束 方法
    变量 循环体次数: 整数 = 0
    循环 (注册(回调, 空) < 3)
        循环体次数 = 循环体次数 + 1
        跳过循环
    结束 循环
    返回 次数 + 循环体次数
结束 方法
SRC
"$ASTER_BIN" build-cn-obj "$TMP/closure-callback-while-zh.ast" \
    -o "$TMP/closure-callback-while-zh.o"

cat > "$TMP/closure-callback-count-en.ast" <<'SRC'
// aster:language=en
let calls: i32 = 0;
fn register(callback: fn(ptr): i32, user: ptr): i32 {
    calls = calls + 1;
    return calls;
}
fn main(): i32 {
    let callback = fn [] (user: ptr): i32 {
        return 0;
    };
    let body: i32 = 0;
    for (i = register(callback, null), register(callback, null), register(callback, null)) {
        body = body + 1;
    }
    return calls + body;
}
SRC
"$ASTER_BIN" build-cn-obj --language en "$TMP/closure-callback-count-en.ast" \
    -o "$TMP/closure-callback-count-en.o"

cat > "$TMP/closure-callback-count-zh.ast" <<'SRC'
// aster:language=zh
变量 次数: 整数 = 0
方法 注册(回调: 方法(指针): 整数, 用户: 指针): 整数
    次数 = 次数 + 1
    返回 次数
结束 方法
方法 启动方法(): 整数
    变量 回调 = 方法 [] (用户: 指针): 整数
        返回 0
    结束 方法
    变量 循环体: 整数 = 0
    计次循环 (索引 = 注册(回调, 空), 注册(回调, 空), 注册(回调, 空))
        循环体 = 循环体 + 1
    结束 计次循环
    返回 次数 + 循环体
结束 方法
SRC
"$ASTER_BIN" build-cn-obj "$TMP/closure-callback-count-zh.ast" \
    -o "$TMP/closure-callback-count-zh.o"

cat > "$TMP/closure-callback-match-en.ast" <<'SRC'
// aster:language=en
fn register(callback: fn(ptr): i32, user: ptr): i32 {
    return callback(user);
}
fn main(): i32 {
    let callback = fn [] (user: ptr): i32 {
        return 1;
    };
    switch (register(callback, null)) {
    case 1
        return 42;
    else
        return 7;
    }
}
SRC
"$ASTER_BIN" build-cn-obj --language en "$TMP/closure-callback-match-en.ast" \
    -o "$TMP/closure-callback-match-en.o"

cat > "$TMP/closure-callback-match-zh.ast" <<'SRC'
// aster:language=zh
方法 注册(回调: 方法(指针): 整数, 用户: 指针): 整数
    返回 回调(用户)
结束 方法
方法 启动方法(): 整数
    变量 回调 = 方法 [] (用户: 指针): 整数
        返回 1
    结束 方法
    假如 注册(回调, 空)
    是 1
        返回 42
    否则
        返回 7
    结束 假如
结束 方法
SRC
"$ASTER_BIN" build-cn-obj "$TMP/closure-callback-match-zh.ast" \
    -o "$TMP/closure-callback-match-zh.o"

cat > "$TMP/closure-callback-struct-return-en.ast" <<'SRC'
// aster:language=en
struct Result { value: i32 }
fn register(callback: fn(ptr): Result, user: ptr): Result {
    return callback(user);
}
fn main(): i32 {
    let callback = fn [] (user: ptr): Result {
        let result: Result;
        return result;
    };
    register(callback, null);
    return 0;
}
SRC
if "$ASTER_BIN" build-cn-obj --language en "$TMP/closure-callback-struct-return-en.ast" \
    -o "$TMP/closure-callback-struct-return-en.o" 2> "$TMP/closure-callback-struct-return-en.err"; then
    echo 'FAIL: struct-return callback adapter was accepted (en)' >&2
    exit 1
fi
grep -q 'closure callback adapter does not support struct return values' \
    "$TMP/closure-callback-struct-return-en.err"

cat > "$TMP/closure-callback-struct-return-zh.ast" <<'SRC'
// aster:language=zh
结构 结果
    值: 整数
结束 结构
方法 注册(回调: 方法(指针): 结果, 用户: 指针): 结果
    返回 回调(用户)
结束 方法
方法 启动方法(): 整数
    变量 回调 = 方法 [] (用户: 指针): 结果
        变量 结果值: 结果
        返回 结果值
    结束 方法
    注册(回调, 空)
    返回 0
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/closure-callback-struct-return-zh.ast" \
    -o "$TMP/closure-callback-struct-return-zh.o" 2> "$TMP/closure-callback-struct-return-zh.err"; then
    echo 'FAIL: struct-return callback adapter was accepted (zh)' >&2
    exit 1
fi
grep -q 'closure callback adapter does not support struct return values' \
    "$TMP/closure-callback-struct-return-zh.err"

cat > "$TMP/closure-callback-void-nested-en.ast" <<'SRC'
// aster:language=en
fn register(callback: fn(ptr): void, user: ptr): void {
    callback(user);
}
fn consume(value: i32): i32 { return value; }
fn main(): i32 {
    let callback = fn [] (user: ptr): void {
        return;
    };
    return consume(register(callback, null));
}
SRC
if "$ASTER_BIN" build-cn-obj --language en "$TMP/closure-callback-void-nested-en.ast" \
    -o "$TMP/closure-callback-void-nested-en.o" 2> "$TMP/closure-callback-void-nested-en.err"; then
    echo 'FAIL: void nested callback adapter was accepted (en)' >&2
    exit 1
fi
grep -q 'a callback adapter call returning void cannot be used inside an expression' \
    "$TMP/closure-callback-void-nested-en.err"

cat > "$TMP/closure-callback-void-nested-zh.ast" <<'SRC'
// aster:language=zh
方法 注册(回调: 方法(指针): 空, 用户: 指针): 空
    回调(用户)
结束 方法
方法 消费(数值: 整数): 整数
    返回 数值
结束 方法
方法 启动方法(): 整数
    变量 回调 = 方法 [] (用户: 指针): 空
        返回
    结束 方法
    返回 消费(注册(回调, 空))
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/closure-callback-void-nested-zh.ast" \
    -o "$TMP/closure-callback-void-nested-zh.o" 2> "$TMP/closure-callback-void-nested-zh.err"; then
    echo 'FAIL: void nested callback adapter was accepted (zh)' >&2
    exit 1
fi
grep -q 'a callback adapter call returning void cannot be used inside an expression' \
    "$TMP/closure-callback-void-nested-zh.err"

cat > "$TMP/closure-callback-wrong-user-en.ast" <<'SRC'
// aster:language=en
fn register(callback: fn(ptr): i32, user: i32): i32 {
    return 0;
}
fn main(): i32 {
    let callback = fn [] (user: ptr): i32 { return 42; };
    return register(callback, 0);
}
SRC
if "$ASTER_BIN" build-cn-obj --language en "$TMP/closure-callback-wrong-user-en.ast" \
    -o "$TMP/closure-callback-wrong-user-en.o" 2> "$TMP/closure-callback-wrong-user-en.err"; then
    echo 'FAIL: callback adapter accepted a non-pointer user parameter (en)' >&2
    exit 1
fi
grep -q 'argument type mismatch calling register at argument 1: expected ptr' \
    "$TMP/closure-callback-wrong-user-en.err"

cat > "$TMP/closure-callback-wrong-user-zh.ast" <<'SRC'
// aster:language=zh
方法 注册(回调: 方法(指针): 整数, 用户: 整数): 整数
    返回 0
结束 方法
方法 启动方法(): 整数
    变量 回调 = 方法 [] (用户: 指针): 整数
        返回 42
    结束 方法
    返回 注册(回调, 0)
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/closure-callback-wrong-user-zh.ast" \
    -o "$TMP/closure-callback-wrong-user-zh.o" 2> "$TMP/closure-callback-wrong-user-zh.err"; then
    echo 'FAIL: callback adapter accepted a non-pointer user parameter (zh)' >&2
    exit 1
fi
grep -q 'argument type mismatch calling 注册 at argument 1: expected ptr' \
    "$TMP/closure-callback-wrong-user-zh.err"

cat > "$TMP/closure-callback-plain-function-en.ast" <<'SRC'
// aster:language=en
fn plain(user: ptr): i32 { return 42; }
fn register(callback: fn(ptr): i32, user: ptr): i32 {
    return callback(user);
}
fn main(): i32 {
    return register(plain, null);
}
SRC
"$ASTER_BIN" build-cn-obj --language en "$TMP/closure-callback-plain-function-en.ast" \
    -o "$TMP/closure-callback-plain-function-en.o"

cat > "$TMP/closure-callback-plain-function-zh.ast" <<'SRC'
// aster:language=zh
方法 普通(用户: 指针): 整数
    返回 42
结束 方法
方法 注册(回调: 方法(指针): 整数, 用户: 指针): 整数
    返回 回调(用户)
结束 方法
方法 启动方法(): 整数
    返回 注册(普通, 空)
结束 方法
SRC
"$ASTER_BIN" build-cn-obj "$TMP/closure-callback-plain-function-zh.ast" \
    -o "$TMP/closure-callback-plain-function-zh.o"

if command -v readelf >/dev/null 2>&1; then
    readelf -Ws "$TMP/closure-zero-en.o" | grep -q '__aster_cn_closure_'
    readelf -Ws "$TMP/closure-zero-zh.o" | grep -q '__aster_cn_closure_'
    readelf -Ws "$TMP/closure-callback-adapter-en.o" | grep -q '__aster_cn_adapter_thunk_'
    readelf -Ws "$TMP/closure-callback-adapter-zh.o" | grep -q '__aster_cn_adapter_thunk_'
    readelf -Ws "$TMP/closure-callback-member-en.o" | grep -q '__aster_cn_adapter_thunk_'
    readelf -Ws "$TMP/closure-callback-member-zh.o" | grep -q '__aster_cn_adapter_thunk_'
    readelf -Ws "$TMP/closure-callback-field-en.o" | grep -q '__aster_cn_adapter_thunk_'
    readelf -Ws "$TMP/closure-callback-array-zh.o" | grep -q '__aster_cn_adapter_thunk_'
    readelf -Ws "$TMP/closure-callback-delayed-en.o" | grep -q '__aster_cn_adapter_thunk_'
    readelf -Ws "$TMP/closure-callback-delayed-zh.o" | grep -q '__aster_cn_adapter_thunk_'
    readelf -Ws "$TMP/closure-callback-nested-en.o" | grep -q '__aster_cn_adapter_thunk_'
    readelf -Ws "$TMP/closure-callback-nested-zh.o" | grep -q '__aster_cn_adapter_thunk_'
    readelf -Ws "$TMP/closure-callback-condition-en.o" | grep -q '__aster_cn_adapter_thunk_'
    readelf -Ws "$TMP/closure-callback-condition-zh.o" | grep -q '__aster_cn_adapter_thunk_'
    readelf -Ws "$TMP/closure-callback-while-en.o" | grep -q '__aster_cn_adapter_thunk_'
    readelf -Ws "$TMP/closure-callback-while-zh.o" | grep -q '__aster_cn_adapter_thunk_'
    readelf -Ws "$TMP/closure-callback-count-en.o" | grep -q '__aster_cn_adapter_thunk_'
    readelf -Ws "$TMP/closure-callback-count-zh.o" | grep -q '__aster_cn_adapter_thunk_'
    readelf -Ws "$TMP/closure-callback-match-en.o" | grep -q '__aster_cn_adapter_thunk_'
    readelf -Ws "$TMP/closure-callback-match-zh.o" | grep -q '__aster_cn_adapter_thunk_'
    if readelf -Ws "$TMP/closure-callback-plain-function-en.o" | grep -q '__aster_cn_adapter_thunk_'; then
        echo 'FAIL: ordinary function pointer received an adapter thunk (en)' >&2
        exit 1
    fi
    if readelf -Ws "$TMP/closure-callback-plain-function-zh.o" | grep -q '__aster_cn_adapter_thunk_'; then
        echo 'FAIL: ordinary function pointer received an adapter thunk (zh)' >&2
        exit 1
    fi
fi
if [ "$CAN_RUN" -eq 1 ]; then
    "$ASTER_BIN" build-obj "$ROOT/stdlib/aster_std.ast" -o "$TMP/aster_std.o"
    "$ASTER_BIN" link-obj "$TMP/closure-valid-capture.o" "$TMP/aster_std.o" -o "$TMP/closure-valid-capture"
    if "$RUNNER" "$TMP/closure-valid-capture"; then status=0; else status=$?; fi
    [ "$status" -eq 42 ]
    cat > "$TMP/closure-valid-capture-zh.ast" <<'SRC'
// aster:language=zh
方法 启动方法(): 整数
变量 步长: 整数 = 2
变量 回调 = 方法 [步长] (数值: 整数): 整数
返回 数值 + 步长
结束 方法
步长 = 3
返回 回调(40)
结束 方法
SRC
    "$ASTER_BIN" build-cn-obj "$TMP/closure-valid-capture-zh.ast" \
        -o "$TMP/closure-valid-capture-zh.o"
    "$ASTER_BIN" link-obj "$TMP/closure-valid-capture-zh.o" "$TMP/aster_std.o" \
        -o "$TMP/closure-valid-capture-zh"
    if "$RUNNER" "$TMP/closure-valid-capture-zh"; then status=0; else status=$?; fi
    [ "$status" -eq 42 ]
    "$ASTER_BIN" link-obj "$TMP/closure-zero-en.o" -o "$TMP/closure-zero-en"
    if "$RUNNER" "$TMP/closure-zero-en"; then status=0; else status=$?; fi
    [ "$status" -eq 42 ]
    "$ASTER_BIN" link-obj "$TMP/closure-zero-zh.o" -o "$TMP/closure-zero-zh"
    if "$RUNNER" "$TMP/closure-zero-zh"; then status=0; else status=$?; fi
    [ "$status" -eq 42 ]
    for adapter_target in en zh; do
        "$ASTER_BIN" link-obj "$TMP/closure-callback-adapter-$adapter_target.o" \
            "$TMP/aster_std.o" -o "$TMP/closure-callback-adapter-$adapter_target"
        if "$RUNNER" "$TMP/closure-callback-adapter-$adapter_target"; then status=0; else status=$?; fi
        [ "$status" -eq 42 ]
    done
    for member_target in en zh; do
        "$ASTER_BIN" link-obj "$TMP/closure-callback-member-$member_target.o" \
            "$TMP/aster_std.o" -o "$TMP/closure-callback-member-$member_target"
        if "$RUNNER" "$TMP/closure-callback-member-$member_target"; then status=0; else status=$?; fi
        [ "$status" -eq 42 ]
    done
    "$ASTER_BIN" link-obj "$TMP/closure-callback-field-en.o" \
        "$TMP/aster_std.o" -o "$TMP/closure-callback-field-en"
    if "$RUNNER" "$TMP/closure-callback-field-en"; then status=0; else status=$?; fi
    [ "$status" -eq 42 ]
    "$ASTER_BIN" link-obj "$TMP/closure-callback-array-zh.o" \
        "$TMP/aster_std.o" -o "$TMP/closure-callback-array-zh"
    if "$RUNNER" "$TMP/closure-callback-array-zh"; then status=0; else status=$?; fi
    [ "$status" -eq 43 ]
    for delayed_target in en zh; do
        "$ASTER_BIN" link-obj "$TMP/closure-callback-delayed-$delayed_target.o" \
            "$TMP/aster_std.o" -o "$TMP/closure-callback-delayed-$delayed_target"
        if "$RUNNER" "$TMP/closure-callback-delayed-$delayed_target"; then status=0; else status=$?; fi
        [ "$status" -eq 85 ]
    done
    for nested_target in en zh; do
        "$ASTER_BIN" link-obj "$TMP/closure-callback-nested-$nested_target.o" \
            "$TMP/aster_std.o" -o "$TMP/closure-callback-nested-$nested_target"
        if "$RUNNER" "$TMP/closure-callback-nested-$nested_target"; then status=0; else status=$?; fi
        [ "$status" -eq 42 ]
    done
    for condition_target in en zh; do
        "$ASTER_BIN" link-obj "$TMP/closure-callback-condition-$condition_target.o" \
            "$TMP/aster_std.o" -o "$TMP/closure-callback-condition-$condition_target"
        if "$RUNNER" "$TMP/closure-callback-condition-$condition_target"; then status=0; else status=$?; fi
        [ "$status" -eq 42 ]
    done
    for while_target in en zh; do
        "$ASTER_BIN" link-obj "$TMP/closure-callback-while-$while_target.o" \
            "$TMP/aster_std.o" -o "$TMP/closure-callback-while-$while_target"
        if "$RUNNER" "$TMP/closure-callback-while-$while_target"; then status=0; else status=$?; fi
        [ "$status" -eq 5 ]
    done
    for count_target in en zh; do
        "$ASTER_BIN" link-obj "$TMP/closure-callback-count-$count_target.o" \
            "$TMP/aster_std.o" -o "$TMP/closure-callback-count-$count_target"
        if "$RUNNER" "$TMP/closure-callback-count-$count_target"; then status=0; else status=$?; fi
        [ "$status" -eq 4 ]
    done
    for match_target in en zh; do
        "$ASTER_BIN" link-obj "$TMP/closure-callback-match-$match_target.o" \
            "$TMP/aster_std.o" -o "$TMP/closure-callback-match-$match_target"
        if "$RUNNER" "$TMP/closure-callback-match-$match_target"; then status=0; else status=$?; fi
        [ "$status" -eq 42 ]
    done
    for plain_target in en zh; do
        "$ASTER_BIN" link-obj "$TMP/closure-callback-plain-function-$plain_target.o" \
            "$TMP/aster_std.o" -o "$TMP/closure-callback-plain-function-$plain_target"
        if "$RUNNER" "$TMP/closure-callback-plain-function-$plain_target"; then status=0; else status=$?; fi
        [ "$status" -eq 42 ]
    done
    for closure_target in field-en field-zh array-en array-zh; do
        "$ASTER_BIN" link-obj "$TMP/closure-$closure_target.o" \
            -o "$TMP/closure-$closure_target"
        if "$RUNNER" "$TMP/closure-$closure_target"; then status=0; else status=$?; fi
        [ "$status" -eq 42 ]
    done
    for capture_target in en zh; do
        "$ASTER_BIN" link-obj "$TMP/closure-array-capture-$capture_target.o" \
            "$TMP/aster_std.o" -o "$TMP/closure-array-capture-$capture_target"
        if "$RUNNER" "$TMP/closure-array-capture-$capture_target"; then status=0; else status=$?; fi
        [ "$status" -eq 22 ]
    done

    cat > "$TMP/class-enum-public-en.ast" <<'SRC'
// aster:language=en
class PublicFields {
let visible: i32;
@private
let hidden: i32;
}
fn main(): i32 {
let object: PublicFields = PublicFields();
let seen: i32 = 0;
enumloop field in object {
if (field.name == "visible") { seen = seen + 1; }
if (field.name == "hidden") { return 2; }
}
return seen;
}
SRC
    cat > "$TMP/class-enum-public-zh.ast" <<'SRC'
// aster:language=zh
类 公开字段
变量 可见: 整数
@隐藏
变量 隐藏: 整数
结束 类
方法 启动方法(): 整数
变量 对象: 公开字段 = 公开字段()
变量 已见: 整数 = 0
枚举循环 (字段 -> 对象)
如果 字段.名称 == "可见"
已见 = 已见 + 1
结束 如果
如果 字段.名称 == "隐藏"
返回 2
结束 如果
结束 枚举循环
返回 已见
结束 方法
SRC
    "$ASTER_BIN" build-cn-obj --language en "$TMP/class-enum-public-en.ast" \
        -o "$TMP/class-enum-public-en.o"
    "$ASTER_BIN" build-cn-obj "$TMP/class-enum-public-zh.ast" \
        -o "$TMP/class-enum-public-zh.o"
    for class_enum_target in en zh; do
        "$ASTER_BIN" link-obj "$TMP/class-enum-public-$class_enum_target.o" \
            "$TMP/aster_std.o" \
            -o "$TMP/class-enum-public-$class_enum_target"
        if "$RUNNER" "$TMP/class-enum-public-$class_enum_target"; then status=0; else status=$?; fi
        [ "$status" -eq 1 ]
    done

    cat > "$TMP/class-enum-null-en.ast" <<'SRC'
// aster:language=en
class PublicFields { let visible: i32; }
fn main(): i32 {
let object: PublicFields;
enumloop field in object { return 1; }
return 0;
}
SRC
    cat > "$TMP/class-enum-null-zh.ast" <<'SRC'
// aster:language=zh
类 公开字段
变量 可见: 整数
结束 类
方法 启动方法(): 整数
变量 对象: 公开字段
枚举循环 (字段 -> 对象)
返回 1
结束 枚举循环
返回 0
结束 方法
SRC
    for class_enum_target in en zh; do
        "$ASTER_BIN" build-cn-obj --language "$class_enum_target" \
            "$TMP/class-enum-null-$class_enum_target.ast" \
            -o "$TMP/class-enum-null-$class_enum_target.o"
        "$ASTER_BIN" link-obj "$TMP/class-enum-null-$class_enum_target.o" \
            -o "$TMP/class-enum-null-$class_enum_target"
        if "$RUNNER" "$TMP/class-enum-null-$class_enum_target"; then status=0; else status=$?; fi
        [ "$status" -eq 133 ] || {
            echo "FAIL: $class_enum_target null class enumloop exited $status, expected 133" >&2
            exit 1
        }
    done
else
    echo 'SKIP: closure execution requires qemu-aarch64 or AArch64 Linux'
fi

cat > "$TMP/global-string-array-en.ast" <<'SRC'
// aster:language=en
let labels: string[2] = ["first", "second"];
let empty: string[2];
fn main(): i32 {
labels[1] = "changed";
if (labels[0] == "first" && labels[1] == "changed" && empty[0] == "") {
return 7;
}
return 0;
}
SRC
cat > "$TMP/global-string-array-zh.ast" <<'SRC'
// aster:language=zh
变量 标签: 字符串[2] = ["第一个", "第二个"]
变量 空标签: 字符串[2]
方法 启动方法(): 整数
标签[1] = "改过"
如果 标签[0] == "第一个"
如果 标签[1] == "改过"
如果 空标签[0] == ""
返回 7
结束 如果
结束 如果
结束 如果
返回 0
结束 方法
SRC
for global_string_target in en zh; do
    "$ASTER_BIN" build-cn-obj --language "$global_string_target" \
        "$TMP/global-string-array-$global_string_target.ast" \
        -o "$TMP/global-string-array-$global_string_target.o"
    "$ASTER_BIN" link-obj "$TMP/global-string-array-$global_string_target.o" \
        -o "$TMP/global-string-array-$global_string_target"
    if [ "$CAN_RUN" -eq 1 ]; then
        if "$RUNNER" "$TMP/global-string-array-$global_string_target"; then status=0; else status=$?; fi
        [ "$status" -eq 7 ] || {
            echo "FAIL: $global_string_target global string array exited $status, expected 7" >&2
            exit 1
        }
    fi
done

cat > "$TMP/global-string-array-bad.ast" <<'SRC'
// aster:language=en
let labels: string[2] = ["ok", 1];
fn main(): i32 { return 0; }
SRC
if "$ASTER_BIN" build-cn-obj --language en "$TMP/global-string-array-bad.ast" \
    -o "$TMP/global-string-array-bad.o" >"$TMP/global-string-array-bad.log" 2>&1; then
    echo 'FAIL: a global string array accepted a non-string element' >&2
    exit 1
fi
rg -q 'global string array element initializer type mismatch' \
    "$TMP/global-string-array-bad.log"

cat > "$TMP/global-struct-array-en.ast" <<'SRC'
// aster:language=en
struct Point { x: i32, y: i32 }
let points: Point[2] = [Point { 1, 2 }, Point { 3, 4 }];
let emptyPoints: Point[2];
fn main(): i32 {
points[1].x = 9;
return points[0].x + points[0].y + points[1].x + points[1].y + emptyPoints[0].x + emptyPoints[0].y;
}
SRC
cat > "$TMP/global-struct-array-zh.ast" <<'SRC'
// aster:language=zh
结构 Point
x: 整数
y: 整数
结束 结构
变量 points: Point[2] = [Point { 1, 2 }, Point { 3, 4 }]
变量 emptyPoints: Point[2]
方法 启动方法(): 整数
points[1].x = 9
返回 points[0].x + points[0].y + points[1].x + points[1].y + emptyPoints[0].x + emptyPoints[0].y
结束 方法
SRC
for global_struct_target in en zh; do
    "$ASTER_BIN" build-cn-obj --language "$global_struct_target" \
        "$TMP/global-struct-array-$global_struct_target.ast" \
        -o "$TMP/global-struct-array-$global_struct_target.o"
done
cmp "$TMP/global-struct-array-en.o" "$TMP/global-struct-array-zh.o"
"$ASTER_BIN" link-obj "$TMP/global-struct-array-en.o" \
    -o "$TMP/global-struct-array"
if [ "$CAN_RUN" -eq 1 ]; then
    if "$RUNNER" "$TMP/global-struct-array"; then status=0; else status=$?; fi
    [ "$status" -eq 16 ] || {
        echo "FAIL: global struct array exited $status, expected 16" >&2
        exit 1
    }
fi

cat > "$TMP/global-struct-array-string-field.ast" <<'SRC'
// aster:language=en
struct Labeled { label: string, value: i32 }
let values: Labeled[1] = [Labeled { "bad", 1 }];
fn main(): i32 { return 0; }
SRC
if "$ASTER_BIN" build-cn-obj --language en \
    "$TMP/global-struct-array-string-field.ast" \
    -o "$TMP/global-struct-array-string-field.o" \
    >"$TMP/global-struct-array-string-field.log" 2>&1; then
    echo 'FAIL: global struct array accepted a string-field constant initializer' >&2
    exit 1
fi
rg -q 'global struct field .* cannot be initialized by a constant' \
    "$TMP/global-struct-array-string-field.log"

cat > "$TMP/array-parameter-en.ast" <<'SRC'
// aster:language=en
let shared: i32[3] = [1, 2, 3];
fn update(values: i32[3]): i32 {
values[1] = values[1] + 5;
return values[0] + values[1] + values[2];
}
fn main(): i32 {
let values: i32[3] = [10, 20, 30];
let total: i32 = update(values);
if (total != 65) { return 1; }
if (values[1] != 25) { return 2; }
if (update(shared) != 11) { return 3; }
if (shared[1] != 7) { return 4; }
return 0;
}
SRC
cat > "$TMP/array-parameter-zh.ast" <<'SRC'
// aster:language=zh
变量 shared: 整数[3] = [1, 2, 3]
方法 update(values: 整数[3]): 整数
values[1] = values[1] + 5
返回 values[0] + values[1] + values[2]
结束 方法
方法 启动方法(): 整数
变量 values: 整数[3] = [10, 20, 30]
变量 total: 整数 = update(values)
如果 total != 65
返回 1
结束 如果
如果 values[1] != 25
返回 2
结束 如果
如果 update(shared) != 11
返回 3
结束 如果
如果 shared[1] != 7
返回 4
结束 如果
返回 0
结束 方法
SRC
for array_parameter_target in en zh; do
    "$ASTER_BIN" build-cn-obj --language "$array_parameter_target" \
        "$TMP/array-parameter-$array_parameter_target.ast" \
        -o "$TMP/array-parameter-$array_parameter_target.o"
done
cmp "$TMP/array-parameter-en.o" "$TMP/array-parameter-zh.o"
"$ASTER_BIN" link-obj "$TMP/array-parameter-en.o" -o "$TMP/array-parameter"
if [ "$CAN_RUN" -eq 1 ]; then
    if "$RUNNER" "$TMP/array-parameter"; then status=0; else status=$?; fi
    [ "$status" -eq 0 ] || {
        echo "FAIL: array parameter test exited $status, expected 0" >&2
        exit 1
    }
fi

cat > "$TMP/array-parameter-type-mismatch.ast" <<'SRC'
// aster:language=en
fn readValues(values: i32[2]): i32 { return values[0]; }
fn main(): i32 {
let values: u8[2] = [1, 2];
return readValues(values);
}
SRC
if "$ASTER_BIN" build-cn-obj --language en \
    "$TMP/array-parameter-type-mismatch.ast" \
    -o "$TMP/array-parameter-type-mismatch.o" \
    >"$TMP/array-parameter-type-mismatch.log" 2>&1; then
    echo 'FAIL: array parameter accepted an array with a different element type' >&2
    exit 1
fi
rg -q 'array argument element type mismatch' "$TMP/array-parameter-type-mismatch.log"

cat > "$TMP/array-parameter-length-mismatch.ast" <<'SRC'
// aster:language=en
fn readValues(values: i32[3]): i32 { return values[0]; }
fn main(): i32 {
let values: i32[2] = [1, 2];
return readValues(values);
}
SRC
if "$ASTER_BIN" build-cn-obj --language en \
    "$TMP/array-parameter-length-mismatch.ast" \
    -o "$TMP/array-parameter-length-mismatch.o" \
    >"$TMP/array-parameter-length-mismatch.log" 2>&1; then
    echo 'FAIL: array parameter accepted an array with a different length' >&2
    exit 1
fi
rg -q 'array argument length mismatch: expected 3, got 2' \
    "$TMP/array-parameter-length-mismatch.log"

cat > "$TMP/class-array-parameter-length-mismatch.ast" <<'SRC'
// aster:language=en
class ArrayOps {
fn readValues(values: i32[3]): i32 { return values[0]; }
}
fn main(): i32 {
let values: i32[2] = [1, 2];
return ArrayOps().readValues(values);
}
SRC
if "$ASTER_BIN" build-cn-obj --language en \
    "$TMP/class-array-parameter-length-mismatch.ast" \
    -o "$TMP/class-array-parameter-length-mismatch.o" \
    >"$TMP/class-array-parameter-length-mismatch.log" 2>&1; then
    echo 'FAIL: class method array parameter accepted an array with a different length' >&2
    exit 1
fi
rg -q 'array argument length mismatch: expected 3, got 2' \
    "$TMP/class-array-parameter-length-mismatch.log"

cat > "$TMP/interface-array-parameter-length-mismatch.ast" <<'SRC'
// aster:language=en
interface class ArrayReader {
fn readValues(values: i32[3]): i32;
}
class ArrayOps: ArrayReader {
fn readValues(values: i32[3]): i32 { return values[0]; }
}
fn main(): i32 {
let reader: ArrayReader = ArrayOps();
let values: i32[2] = [1, 2];
return reader.readValues(values);
}
SRC
if "$ASTER_BIN" build-cn-obj --language en \
    "$TMP/interface-array-parameter-length-mismatch.ast" \
    -o "$TMP/interface-array-parameter-length-mismatch.o" \
    >"$TMP/interface-array-parameter-length-mismatch.log" 2>&1; then
    echo 'FAIL: interface array parameter accepted an array with a different length' >&2
    exit 1
fi
rg -q 'array argument length mismatch: expected 3, got 2' \
    "$TMP/interface-array-parameter-length-mismatch.log"

cat > "$TMP/parent-constructor-array-length-mismatch.ast" <<'SRC'
// aster:language=en
class Base {
@constructor
fn init(values: i32[3]): void {}
}
class Derived: Base {
@constructor
fn init(values: i32[2]): void { super(values); }
}
fn main(): i32 {
let values: i32[2] = [1, 2];
let object: Derived = Derived(values);
return 0;
}
SRC
if "$ASTER_BIN" build-cn-obj --language en \
    "$TMP/parent-constructor-array-length-mismatch.ast" \
    -o "$TMP/parent-constructor-array-length-mismatch.o" \
    >"$TMP/parent-constructor-array-length-mismatch.log" 2>&1; then
    echo 'FAIL: parent constructor accepted an array with a different length' >&2
    exit 1
fi
rg -q 'array argument length mismatch: expected 3, got 2' \
    "$TMP/parent-constructor-array-length-mismatch.log"

cat > "$TMP/array-parameter-multidimensional.ast" <<'SRC'
// aster:language=en
fn readValues(values: i32[2][3]): i32 { return values[0][0]; }
fn main(): i32 { return 0; }
SRC
if "$ASTER_BIN" build-cn-obj --language en \
    "$TMP/array-parameter-multidimensional.ast" \
    -o "$TMP/array-parameter-multidimensional.o" \
    >"$TMP/array-parameter-multidimensional.log" 2>&1; then
    echo 'FAIL: multidimensional array parameter unexpectedly compiled' >&2
    exit 1
fi
rg -q 'supports one-dimensional array parameters' \
    "$TMP/array-parameter-multidimensional.log"

cat > "$TMP/class-array-parameter-en.ast" <<'SRC'
// aster:language=en
class ArrayOps {
@static
fn update(values: i32[2]): i32 {
values[1] = values[1] + 10;
return values[0] + values[1];
}
}
fn main(): i32 {
let values: i32[2] = [4, 6];
if (ArrayOps.update(values) != 20) { return 1; }
if (values[1] != 16) { return 2; }
return 0;
}
SRC
cat > "$TMP/class-array-parameter-zh.ast" <<'SRC'
// aster:language=zh
类 ArrayOps
@静态
方法 update(values: 整数[2]): 整数
values[1] = values[1] + 10
返回 values[0] + values[1]
结束 方法
结束 类
方法 启动方法(): 整数
变量 values: 整数[2] = [4, 6]
如果 ArrayOps.update(values) != 20
返回 1
结束 如果
如果 values[1] != 16
返回 2
结束 如果
返回 0
结束 方法
SRC
for class_array_parameter_target in en zh; do
    "$ASTER_BIN" build-cn-obj --language "$class_array_parameter_target" \
        "$TMP/class-array-parameter-$class_array_parameter_target.ast" \
        -o "$TMP/class-array-parameter-$class_array_parameter_target.o"
done
cmp "$TMP/class-array-parameter-en.o" "$TMP/class-array-parameter-zh.o"
"$ASTER_BIN" link-obj "$TMP/class-array-parameter-en.o" \
    -o "$TMP/class-array-parameter"
if [ "$CAN_RUN" -eq 1 ]; then
    if "$RUNNER" "$TMP/class-array-parameter"; then status=0; else status=$?; fi
    [ "$status" -eq 0 ] || {
        echo "FAIL: class array parameter test exited $status, expected 0" >&2
        exit 1
    }
fi

echo 'PASS: Chinese backend integration checks'
