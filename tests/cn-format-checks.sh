#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ASTER_BIN=${ASTER_BIN:-$ROOT/aster}
if [ ! -x "$ASTER_BIN" ]; then
    echo "set ASTER_BIN to a built Aster executable" >&2
    exit 2
fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

cat > "$TMP/zh.ast" <<'SRC'
// aster:language=zh
方法 启动方法(): 整数
变量 总计: 整数 = 0
计次循环 (i = 1, 2)
如果 (i == 1)
总计 = 总计 + i
否则
总计 = 总计 + 2
结束 如果
结束 计次循环
假如 总计
是 4
返回 0
否则
返回 1
结束 假如
结束 方法
SRC
cat > "$TMP/zh.expected" <<'SRC'
// aster:language=zh
方法 启动方法(): 整数
    变量 总计: 整数 = 0
    计次循环 (i = 1, 2)
        如果 (i == 1)
            总计 = 总计 + i
        否则
            总计 = 总计 + 2
        结束 如果
    结束 计次循环
    假如 总计
        是 4
            返回 0
        否则
            返回 1
    结束 假如
结束 方法
SRC

printf '%s\n' '[1/4] Chinese block indentation and match-arm indentation'
if "$ASTER_BIN" fmt --check "$TMP/zh.ast" > /dev/null 2>&1; then
    echo 'FAIL: unformatted Chinese source passed --check' >&2
    exit 1
fi
"$ASTER_BIN" build-cn-obj "$TMP/zh.ast" -o "$TMP/zh.before.o" > /dev/null
"$ASTER_BIN" fmt "$TMP/zh.ast" > "$TMP/zh.formatted"
cmp "$TMP/zh.expected" "$TMP/zh.formatted"
"$ASTER_BIN" 格式化源码 "$TMP/zh.ast" > "$TMP/zh.alias"
cmp "$TMP/zh.expected" "$TMP/zh.alias"
"$ASTER_BIN" 格式化源码 --write "$TMP/zh.ast" > /dev/null
cmp "$TMP/zh.expected" "$TMP/zh.ast"
"$ASTER_BIN" build-cn-obj "$TMP/zh.ast" -o "$TMP/zh.after.o" > /dev/null
cmp "$TMP/zh.before.o" "$TMP/zh.after.o"
"$ASTER_BIN" fmt --check "$TMP/zh.ast" > /dev/null

cat > "$TMP/en.ast" <<'SRC'
// aster:language=en
fn main(): i32 {
let text: string = "{ } // literal";
if (true) {
return 0;
} else {
return 1;
}
}
SRC
cat > "$TMP/en.expected" <<'SRC'
// aster:language=en
fn main(): i32 {
    let text: string = "{ } // literal";
    if (true) {
        return 0;
    } else {
        return 1;
    }
}
SRC
printf '%s\n' '[2/4] English braces inside strings do not change block depth'
"$ASTER_BIN" fmt --language en "$TMP/en.ast" > "$TMP/en.formatted"
cmp "$TMP/en.expected" "$TMP/en.formatted"
"$ASTER_BIN" fmt --write "$TMP/en.ast" > /dev/null
cmp "$TMP/en.expected" "$TMP/en.ast"

printf '%s\n' '[3/4] formatter command options reject conflicting write modes'
if "$ASTER_BIN" fmt --write --check "$TMP/en.ast" > /dev/null 2>&1; then
    echo 'FAIL: conflicting formatter modes were accepted' >&2
    exit 1
fi

printf '%s\n' '[4/4] checked-in Chinese examples compile'
"$ASTER_BIN" build-cn-obj "$ROOT/examples/cn/hello.ast" -o "$TMP/hello.o" > /dev/null
"$ASTER_BIN" build-cn-obj "$ROOT/examples/cn/oop.ast" -o "$TMP/oop.o" > /dev/null

echo 'PASS: bilingual source formatter checks'
