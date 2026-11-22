#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
${CXX:-c++} -std=c++17 -Wall -Wextra -Wpedantic -Werror \
    "$ROOT/src/cn_lex_main.cpp" "$ROOT/src/cn_lexer.cpp" -o "$TMP/aster-cn-lex"

printf '%s\n' '[1/6] Chinese identifiers, longest keywords, and code-point columns'
cat > "$TMP/zh.ast" <<'SRC'
方法 启动方法(): 整数
变量 中文名2： 整数 = 1
返回 中文名2
结束 方法
SRC
"$TMP/aster-cn-lex" "$TMP/zh.ast" > "$TMP/zh.tokens"
grep -q '^1:4 .* StartMethod "启动方法"$' "$TMP/zh.tokens"
grep -q '^2:1 .* VarDecl "变量"$' "$TMP/zh.tokens"
grep -q '^2:4 .* Identifier "中文名2"$' "$TMP/zh.tokens"
grep -q '^4:1 .* EndKw "结束"$' "$TMP/zh.tokens"
printf '%s\n' '布尔' | "$TMP/aster-cn-lex" - > "$TMP/bool-spelling.tokens"
grep -q 'Identifier "布尔"' "$TMP/bool-spelling.tokens"
if grep -q 'Bool "布尔"' "$TMP/bool-spelling.tokens"; then
    echo 'FAIL: obsolete Chinese bool alias remained a keyword' >&2; exit 1
fi

printf '%s\n' '[2/6] language isolation, directives, project defaults, and phrase matching'
printf '%s\n' '启动方法' | "$TMP/aster-cn-lex" - > "$TMP/start-method.tokens"
grep -q 'StartMethod "启动方法"' "$TMP/start-method.tokens"
printf '%s\n' 'if 枚举循环 否则如果' | "$TMP/aster-cn-lex" > "$TMP/zh-mode.tokens"
printf '%s\n' '如果' | "$TMP/aster-cn-lex" --language=en - > "$TMP/en-mode.tokens"
printf '%s\n' 'else if interface class' | "$TMP/aster-cn-lex" --language=en - > "$TMP/en-phrases.tokens"
grep -q 'EnumLoop "枚举循环"' "$TMP/zh-mode.tokens"
grep -q 'ElseIf "否则如果"' "$TMP/zh-mode.tokens"
grep -q 'Identifier "如果"' "$TMP/en-mode.tokens"
grep -q 'ElseIf "else if"' "$TMP/en-phrases.tokens"
grep -q 'InterfaceClass "interface class"' "$TMP/en-phrases.tokens"
printf '%s\n' '变量 于: 整数 = 1 -> 于' | "$TMP/aster-cn-lex" - > "$TMP/arrow-zh.tokens"
[ "$(grep -c 'Identifier "于"' "$TMP/arrow-zh.tokens")" -eq 2 ]
grep -q 'Arrow "->"' "$TMP/arrow-zh.tokens"
printf '%s\n' 'foreach item in items {}' | "$TMP/aster-cn-lex" --language=en - > "$TMP/foreach-en.tokens"
grep -q 'InKw "in"' "$TMP/foreach-en.tokens"
printf '%s\n' '// aster:language=en' 'fn main() -> i32 { return 0; }' | "$TMP/aster-cn-lex" - > "$TMP/directive.tokens"
grep -q 'Method "fn"' "$TMP/directive.tokens"
cat > "$TMP/aster.proj" <<'PROJ'
[language]
default = "en"
allowed = ["zh", "en"]
PROJ
printf '%s\n' 'fn main() -> i32 { return 0; }' | "$TMP/aster-cn-lex" --project "$TMP/aster.proj" - > "$TMP/project.tokens"
grep -q 'Method "fn"' "$TMP/project.tokens"
printf '%s\n' '// aster:language=zh' '变量 a: 整数 = 1' | "$TMP/aster-cn-lex" --project "$TMP/aster.proj" - > "$TMP/project-directive.tokens"
grep -q 'VarDecl "变量"' "$TMP/project-directive.tokens"
printf '%s\n' '变量 a: 整数 = 1' | "$TMP/aster-cn-lex" --language=zh --project "$TMP/aster.proj" - > "$TMP/override.tokens"
grep -q 'VarDecl "变量"' "$TMP/override.tokens"
cat > "$TMP/aster.proj" <<'PROJ'
[language]
default = "en"
allowed = ["en"]
PROJ
if printf '%s\n' '// aster:language=zh' '变量 a: 整数 = 1' | "$TMP/aster-cn-lex" --project "$TMP/aster.proj" - > /dev/null 2> "$TMP/project-disallowed"; then
    echo 'FAIL: project allowed language accepted' >&2; exit 1
fi
grep -q 'not allowed by project configuration' "$TMP/project-disallowed"
if printf '%s\n' '// aster:language=en' 'fn main() -> i32 { return 0; }' | "$TMP/aster-cn-lex" --language=zh - > /dev/null 2> "$TMP/conflict"; then
    echo 'FAIL: conflicting language directive accepted' >&2; exit 1
fi
grep -q 'conflicts with file directive' "$TMP/conflict"

printf '%s\n' '[3/6] full-width punctuation normalizes outside literals only'
printf '%s\n' '变量 a：整数 = 1，2、3' '变量 s: 字符串 = "甲，乙：丙、丁"' | \
    "$TMP/aster-cn-lex" - > "$TMP/punct.tokens"
grep -q 'Comma ","' "$TMP/punct.tokens"
grep -q 'String "\\"甲，乙：丙、丁\\""' "$TMP/punct.tokens"

printf '%s\n' '[4/6] newline suppression within delimiters and byte offsets'
printf '变量 a: 整数 = (1 +\n2)\n' | "$TMP/aster-cn-lex" - > "$TMP/nl.tokens"
[ "$(grep -c 'Newline' "$TMP/nl.tokens")" -eq 1 ]
grep -q 'byte=0+6 VarDecl' "$TMP/nl.tokens"

printf '%s\n' '[5/6] malformed UTF-8 and unsupported Unicode are rejected'
if printf '\300\257' | "$TMP/aster-cn-lex" - > /dev/null 2> "$TMP/bad-utf8"; then
    echo 'FAIL: overlong UTF-8 accepted' >&2; exit 1
fi
grep -q 'invalid UTF-8' "$TMP/bad-utf8"
if printf '变量 😀: 整数\n' | "$TMP/aster-cn-lex" - > /dev/null 2> "$TMP/bad-cp"; then
    echo 'FAIL: unsupported identifier code point accepted' >&2; exit 1
fi
grep -q 'unsupported source code point' "$TMP/bad-cp"

printf '%s\n' '[6/6] numeric separators and character escapes are validated'
printf '%s\n' '1_000 0x1_a 0b1_0 1.2_3' | "$TMP/aster-cn-lex" - > "$TMP/numbers.tokens"
[ "$(grep -c 'Number ' "$TMP/numbers.tokens")" -eq 4 ]
printf '%s\n' '1.25e1 0xDE' | "$TMP/aster-cn-lex" - > "$TMP/float-numbers.tokens"
grep -q 'Number "1.25e1"' "$TMP/float-numbers.tokens"
grep -q 'Number "0xDE"' "$TMP/float-numbers.tokens"
for bad in '1__0' '1_' '0x_' '0x1_' '0b1_0_'; do
    if printf '%s\n' "$bad" | "$TMP/aster-cn-lex" - > /dev/null 2> "$TMP/bad-number"; then
        echo "FAIL: malformed number accepted: $bad" >&2; exit 1
    fi
done
if printf '%s\n' '1.25u' | "$TMP/aster-cn-lex" - > /dev/null 2> "$TMP/float-suffix.err"; then
    echo 'FAIL: integer suffix accepted on a float literal' >&2; exit 1
fi
grep -q 'floating-point literal cannot have an integer suffix' "$TMP/float-suffix.err"
printf '%s\n' "'\\n'" "'\\x41'" | "$TMP/aster-cn-lex" - > "$TMP/chars.tokens"
[ "$(grep -c 'Character ' "$TMP/chars.tokens")" -eq 2 ]
if printf '%s\n' "'\\q'" | "$TMP/aster-cn-lex" - > /dev/null 2> "$TMP/bad-char"; then
    echo 'FAIL: unsupported character escape accepted' >&2; exit 1
fi
grep -q 'unsupported character escape' "$TMP/bad-char"

echo 'PASS: Chinese/English UTF-8 lexer checks'
