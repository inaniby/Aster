#!/bin/sh
# AST equivalence checks (design §5.1 S3, §5.5 item 5): the same program
# written in Chinese and in English must lower to one shared AST. This is
# the suite named `cn-ast-equiv-checks.sh` by the design; the same coverage
# also exists inline in tests/cn-parser-checks.sh.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

cxx=${CXX:-c++}
"$cxx" -std=c++17 -Wall -Wextra -Wpedantic -Werror \
    "$ROOT/src/cn_parse_main.cpp" "$ROOT/src/cn_parser.cpp" "$ROOT/src/cn_lexer.cpp" \
    -o "$TMP/aster-cn-parse"

echo '[1/2] Chinese and English counter programs produce one shared AST'
cat > "$TMP/counter-zh.ast" <<'SRC'
// aster:language=zh
方法 启动方法(): 整数
变量 total: 整数 = 0
计次循环 (i = 1, 3)
total = total + i
结束 计次循环
返回 total
结束 方法
SRC
cat > "$TMP/counter-en.ast" <<'SRC'
// aster:language=en
fn main(): i32 {
let total: i32 = 0;
for (i = 1, 3) {
total = total + i;
}
return total;
}
SRC
"$TMP/aster-cn-parse" "$TMP/counter-zh.ast" >"$TMP/counter-zh.dump" 2>"$TMP/counter-zh.err" || {
    echo 'FAIL: Chinese counter did not parse' >&2
    cat "$TMP/counter-zh.err" >&2
    exit 1
}
"$TMP/aster-cn-parse" "$TMP/counter-en.ast" >"$TMP/counter-en.dump" 2>"$TMP/counter-en.err" || {
    echo 'FAIL: English counter did not parse' >&2
    cat "$TMP/counter-en.err" >&2
    exit 1
}
cmp "$TMP/counter-zh.dump" "$TMP/counter-en.dump" || {
    echo 'FAIL: Chinese and English counters produced different AST dumps' >&2
    diff "$TMP/counter-zh.dump" "$TMP/counter-en.dump" >&2
    exit 1
}

echo '[2/2] an omitted return type normalizes to void in both languages'
cat > "$TMP/omit-zh.ast" <<'SRC'
// aster:language=zh
方法 log()
返回
结束 方法
方法 启动方法(): 整数
返回 0
结束 方法
SRC
cat > "$TMP/omit-en.ast" <<'SRC'
// aster:language=en
fn log() {
return;
}
fn main(): i32 { return 0; }
SRC
"$TMP/aster-cn-parse" "$TMP/omit-zh.ast" >"$TMP/omit-zh.dump" 2>"$TMP/omit-zh.err" || {
    echo 'FAIL: Chinese omitted-return program did not parse' >&2
    cat "$TMP/omit-zh.err" >&2
    exit 1
}
"$TMP/aster-cn-parse" "$TMP/omit-en.ast" >"$TMP/omit-en.dump" 2>"$TMP/omit-en.err" || {
    echo 'FAIL: English omitted-return program did not parse' >&2
    cat "$TMP/omit-en.err" >&2
    exit 1
}
cmp "$TMP/omit-zh.dump" "$TMP/omit-en.dump" || {
    echo 'FAIL: omitted return types did not normalize to the same AST' >&2
    diff "$TMP/omit-zh.dump" "$TMP/omit-en.dump" >&2
    exit 1
}
grep -q '"void"' "$TMP/omit-zh.dump" || {
    echo 'FAIL: omitted return type did not normalize to void' >&2
    exit 1
}

echo 'PASS: Chinese and English sources produce one shared AST'
