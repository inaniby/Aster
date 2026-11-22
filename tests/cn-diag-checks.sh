#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ASTER_BIN=${ASTER_BIN:-$ROOT/build/cn-s1-s2/aster}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

cxx=${CXX:-c++}
"$cxx" -std=c++17 -Wall -Wextra -Wpedantic -Werror \
    "$ROOT/src/cn_parse_main.cpp" "$ROOT/src/cn_parser.cpp" "$ROOT/src/cn_lexer.cpp" \
    -o "$TMP/aster-cn-parse"
"$cxx" -std=c++17 -Wall -Wextra -Wpedantic -Werror \
    "$ROOT/src/cn_lex_main.cpp" "$ROOT/src/cn_lexer.cpp" \
    -o "$TMP/aster-cn-lex"

cat > "$TMP/block-zh.ast" <<'SRC'
// aster:language=zh
方法 启动方法(): 整数
    返回 1
结束 如果
SRC
cat > "$TMP/block-en.ast" <<'SRC'
// aster:language=en
fn main(): i32 {
    return 1;
SRC

if "$TMP/aster-cn-parse" "$TMP/block-zh.ast" >"$TMP/zh.out" 2>"$TMP/zh.err"; then
    echo 'FAIL: malformed Chinese block was accepted' >&2
    exit 1
fi
if "$TMP/aster-cn-parse" "$TMP/block-en.ast" >"$TMP/en.out" 2>"$TMP/en.err"; then
    echo 'FAIL: malformed English block was accepted' >&2
    exit 1
fi
grep -q '\[A-010\]' "$TMP/zh.err"
grep -q '\[A-010\]' "$TMP/en.err"
grep -q '代码块结构不匹配' "$TMP/zh.err"
grep -q 'block structure does not match' "$TMP/en.err"
grep -q 'mismatched block close' "$TMP/zh.err"
grep -q 'unexpected end of file inside a block' "$TMP/en.err"

printf '\377' > "$TMP/bad-utf8.ast"
if "$TMP/aster-cn-lex" --language zh "$TMP/bad-utf8.ast" >"$TMP/utf8.out" 2>"$TMP/utf8.err"; then
    echo 'FAIL: invalid UTF-8 was accepted' >&2
    exit 1
fi
grep -q '\[A-001\]' "$TMP/utf8.err"
grep -q 'UTF-8 编码无效' "$TMP/utf8.err"

cat > "$TMP/type-zh.ast" <<'SRC'
// aster:language=zh
方法 启动方法(): 整数
    变量 文字: 整数 = "错误"
    返回 文字
结束 方法
SRC
cat > "$TMP/type-en.ast" <<'SRC'
// aster:language=en
fn main(): i32 {
    let text: i32 = "error";
    return text;
}
SRC
for language in zh en; do
    if "$ASTER_BIN" build-cn-obj --language "$language" "$TMP/type-$language.ast" \
        -o "$TMP/type-$language.o" >"$TMP/type-$language.out" 2>"$TMP/type-$language.err"; then
        echo "FAIL: $language type error was accepted" >&2
        exit 1
    fi
    grep -q '\[A-050\]' "$TMP/type-$language.err"
done
grep -q '类型检查失败' "$TMP/type-zh.err"
grep -q 'type checking failed' "$TMP/type-en.err"

echo 'PASS: bilingual diagnostics and stable error codes'
