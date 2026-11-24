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

# A-002: the lexer rejects a character outside the supported set.
printf '// aster:language=en\nfn main(): i32 { return $; }\n' > "$TMP/char-en.ast"
if "$TMP/aster-cn-lex" --language en "$TMP/char-en.ast" >"$TMP/char.out" 2>"$TMP/char.err"; then
    echo 'FAIL: unsupported character was accepted' >&2
    exit 1
fi
grep -q '\[A-002\]' "$TMP/char.err" || {
    echo 'FAIL: expected [A-002] for an unsupported character' >&2
    exit 1
}

# A-003: an unknown language directive value is rejected.
cat > "$TMP/bad-language.ast" <<'SRC'
// aster:language=xx
fn main(): i32 { return 0; }
SRC
if "$TMP/aster-cn-parse" "$TMP/bad-language.ast" >"$TMP/bad-language.out" 2>"$TMP/bad-language.err"; then
    echo 'FAIL: unknown language directive was accepted' >&2
    exit 1
fi
grep -q '\[A-003\]' "$TMP/bad-language.err" || {
    echo 'FAIL: expected [A-003] for an unknown language directive' >&2
    exit 1
}

# A-011: a top-level token that starts no declaration is a syntax error.
cat > "$TMP/garbage-en.ast" <<'SRC'
// aster:language=en
hello
SRC
if "$TMP/aster-cn-parse" "$TMP/garbage-en.ast" >"$TMP/garbage.out" 2>"$TMP/garbage.err"; then
    echo 'FAIL: garbage top-level token was accepted' >&2
    exit 1
fi
grep -q '\[A-011\]' "$TMP/garbage.err" || {
    echo 'FAIL: expected [A-011] for a misplaced top-level token' >&2
    exit 1
}

# A-020: a package header that repeats a name or alias is rejected.
cat > "$TMP/dup-package-zh.ast" <<'SRC'
// aster:language=zh
包名 我的包 = 我的包
方法 启动方法(): 整数
返回 0
结束 方法
SRC
if "$TMP/aster-cn-parse" "$TMP/dup-package-zh.ast" >"$TMP/dup-package.out" 2>"$TMP/dup-package.err"; then
    echo 'FAIL: duplicate package name or alias was accepted' >&2
    exit 1
fi
grep -q '\[A-020\]' "$TMP/dup-package.err" || {
    echo 'FAIL: expected [A-020] for a duplicate package name or alias' >&2
    exit 1
}

# A-021: an unknown top-level annotation is rejected (top level takes
# 隐藏/hidden/受限/private only; @protected is a class-member annotation).
cat > "$TMP/bad-annotation-en.ast" <<'SRC'
// aster:language=en
@protected
fn main(): i32 { return 0; }
SRC
if "$TMP/aster-cn-parse" "$TMP/bad-annotation-en.ast" >"$TMP/bad-annotation.out" 2>"$TMP/bad-annotation.err"; then
    echo 'FAIL: unknown top-level annotation was accepted' >&2
    exit 1
fi
grep -q '\[A-021\]' "$TMP/bad-annotation.err" || {
    echo 'FAIL: expected [A-021] for an unknown top-level annotation' >&2
    exit 1
}

# A-030: a repeated structure declaration is rejected.
cat > "$TMP/dup-struct-zh.ast" <<'SRC'
// aster:language=zh
结构 点
横: 整数
结束 结构
结构 点
纵: 整数
结束 结构
方法 启动方法(): 整数
返回 0
结束 方法
SRC
if "$TMP/aster-cn-parse" "$TMP/dup-struct-zh.ast" >"$TMP/dup-struct.out" 2>"$TMP/dup-struct.err"; then
    echo 'FAIL: duplicate structure declaration was accepted' >&2
    exit 1
fi
grep -q '\[A-030\]' "$TMP/dup-struct.err" || {
    echo 'FAIL: expected [A-030] for a duplicate structure declaration' >&2
    exit 1
}

# A-040: reading a hidden field from outside its class is rejected.
cat > "$TMP/hidden-zh.ast" <<'SRC'
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
cat > "$TMP/hidden-en.ast" <<'SRC'
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
    if "$ASTER_BIN" build-cn-obj --language "$language" "$TMP/hidden-$language.ast" \
        -o "$TMP/hidden-$language.o" >"$TMP/hidden-$language.out" 2>"$TMP/hidden-$language.err"; then
        echo "FAIL: $language hidden-field access was accepted" >&2
        exit 1
    fi
    grep -q '\[A-040\]' "$TMP/hidden-$language.err" || {
        echo "FAIL: expected [A-040] for a $language hidden-field access" >&2
        exit 1
    }
done

# A-060: range matching is a deferred construct, not a silent acceptance.
cat > "$TMP/range-zh.ast" <<'SRC'
// aster:language=zh
方法 启动方法(): 整数
假如 5
是 0 到 17
返回 1
结束 假如
返回 0
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/range-zh.ast" -o "$TMP/range-zh.o" 2>"$TMP/range.err"; then
    echo 'FAIL: range match was accepted' >&2
    exit 1
fi
grep -q '\[A-060\]' "$TMP/range.err" || {
    echo 'FAIL: expected [A-060] for range matching' >&2
    exit 1
}

# A-099: the fallback code covers errors with no narrower category
# (here an unterminated string literal).
cat > "$TMP/unterminated-zh.ast" <<'SRC'
// aster:language=zh
方法 启动方法(): 整数
变量 s: 字符串 = "abc
返回 0
结束 方法
SRC
if "$TMP/aster-cn-parse" "$TMP/unterminated-zh.ast" >"$TMP/unterminated.out" 2>"$TMP/unterminated.err"; then
    echo 'FAIL: unterminated string literal was accepted' >&2
    exit 1
fi
grep -q '\[A-099\]' "$TMP/unterminated.err" || {
    echo 'FAIL: expected [A-099] for an unterminated string literal' >&2
    exit 1
}

echo 'PASS: bilingual diagnostics and stable error codes'
