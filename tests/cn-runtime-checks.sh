#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ASTER_BIN=${ASTER_BIN:-$ROOT/build/cn-s1-s2/aster}
RUNNER=${RUNNER:-$ROOT/tests/run-aarch64.sh}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

mkdir -p "$TMP/app"
cat > "$TMP/app/string-zh.ast" <<'SRC'
// aster:language=zh
@导入("标准库.文本").别名("文本")
方法 启动方法(): 整数
    变量 合计: 整数 = 整数(文本.长度(文本.拼接("A", "ster")))
    如果 文本.相等("Aster", "Aster")
        合计 = 合计 + 10
    结束 如果
    如果 文本.更小("a", "b")
        合计 = 合计 + 27
    结束 如果
    返回 合计
结束 方法
SRC

cat > "$TMP/app/string-en.ast" <<'SRC'
// aster:language=en
@import("standard.text").alias("text")
fn main(): i32 {
    let total: i32 = i32(text.length(text.concat("A", "ster")));
    if (text.equals("Aster", "Aster")) {
        total = total + 10;
    }
    if (text.less("a", "b")) {
        total = total + 27;
    }
    return total;
}
SRC

"$ASTER_BIN" build-obj "$ROOT/stdlib/aster_std.ast" -o "$TMP/aster_std.o"
for language in zh en; do
    "$ASTER_BIN" build-cn-obj --module-dir "$ROOT/stdlib/cn" \
        "$TMP/app/string-$language.ast" -o "$TMP/string-$language.o"
    "$ASTER_BIN" link-obj "$TMP/string-$language.o" "$TMP/aster_std.o" \
        -o "$TMP/string-$language"
    if "$RUNNER" "$TMP/string-$language"; then status=0; else status=$?; fi
    [ "$status" -eq 42 ] || {
        echo "FAIL: $language bilingual standard string API returned $status, expected 42" >&2
        exit 1
    }
done

echo 'PASS: bilingual standard library string package'
