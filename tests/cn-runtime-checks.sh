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
    合计 = 合计 + 文本.输出("你好\n")
    合计 = 合计 + 文本.输出错误("错\n")
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
    total = total + text.print("hi\n");
    total = total + text.eprint("er\n");
    return total;
}
SRC

"$ASTER_BIN" build-obj "$ROOT/stdlib/aster_std.ast" -o "$TMP/aster_std.o"
for language in zh en; do
    "$ASTER_BIN" build-cn-obj --module-dir "$ROOT/stdlib/cn" \
        "$TMP/app/string-$language.ast" -o "$TMP/string-$language.o"
    "$ASTER_BIN" link-obj "$TMP/string-$language.o" "$TMP/aster_std.o" \
        -o "$TMP/string-$language"
    if "$RUNNER" "$TMP/string-$language" > "$TMP/string-$language.out" 2> "$TMP/string-$language.err"; then status=0; else status=$?; fi
    # 42 from the four string methods, plus the two output calls' byte
    # counts: zh prints "你好\n" (7) to stdout and "错\n" (4) to stderr,
    # en prints "hi\n" (3) and "er\n" (3).
    case "$language" in
        zh) want=53; printf '你好\n' > "$TMP/want.out"; printf '错\n' > "$TMP/want.err" ;;
        en) want=48; printf 'hi\n' > "$TMP/want.out"; printf 'er\n' > "$TMP/want.err" ;;
    esac
    [ "$status" -eq "$want" ] || {
        echo "FAIL: $language bilingual standard string API returned $status, expected $want" >&2
        exit 1
    }
    cmp -s "$TMP/string-$language.out" "$TMP/want.out" || {
        echo "FAIL: $language bilingual standard string API wrote the wrong stdout" >&2
        exit 1
    }
    cmp -s "$TMP/string-$language.err" "$TMP/want.err" || {
        echo "FAIL: $language bilingual standard string API wrote the wrong stderr" >&2
        exit 1
    }
done

echo 'PASS: bilingual standard library string package'
