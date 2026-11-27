#!/bin/sh
# Context-aware completion checks: `aster complete --cursor LINE:COL
# [--stdin]` parses the current file (unsaved stdin text when --stdin is
# given) plus the aster.proj sources and returns scoped candidates filtered
# by the cursor context; without --cursor it keeps the package-export
# listing (zh lists every export, displayed under its Chinese name when it
# has one, else its English name — the D-ZH rule, see package-checks [3/10]).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ASTER_BIN=${ASTER_BIN:-$ROOT/aster}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

fail() { echo "FAIL: $1" >&2; exit 1; }

# cursor_for <src> <search> <replace-with-|> <out-stdin> — echoes LINE:COL
# for the `|` marker in the replaced text and writes the marker-free text
# (the editor's unsaved buffer) to <out-stdin>.
cursor_for() {
    python3 - "$1" "$2" "$3" "$4" <<'PY'
import sys
src, old, new, out = sys.argv[1:5]
text = open(src).read()
assert old in text, "pattern not in %s: %r" % (src, old)
text = text.replace(old, new, 1)
lines = text.split("\n")
for i, ln in enumerate(lines):
    if "|" in ln:
        print("%d:%d" % (i + 1, ln.index("|") + 1))
        lines[i] = ln.replace("|", "", 1)
        break
else:
    raise SystemExit("no cursor marker in replacement")
open(out, "w").write("\n".join(lines))
PY
}
# names <json-file> — one candidate name per line, in output order.
names() {
    python3 -c "import json,sys; print('\n'.join(e['name'] for e in json.load(open(sys.argv[1]))))" "$1"
}
# names_zh <json-file> — "name<TAB>name_zh" per line.
names_zh() {
    python3 -c "import json,sys; print('\n'.join(e['name']+'\t'+e.get('name_zh','') for e in json.load(open(sys.argv[1]))))" "$1"
}
complete_at() { # <stdin-file> <cursor> <file> <out-json>
    "$ASTER_BIN" complete --format json --cursor "$2" --stdin "$PKG" "$3" < "$1" > "$4" 2>"$TMP/stderr.txt" \
        || fail "complete --cursor failed (rc=$?) for $3 @ $2"
    [ ! -s "$TMP/stderr.txt" ] || fail "complete --cursor wrote to stderr: $(cat "$TMP/stderr.txt")"
}

echo '[1/6] fixtures: a Chinese project with two files, plus a packed stdlib'
"$ASTER_BIN" pack --src-dir "$ROOT/stdlib" --out "$TMP/pkg" > /dev/null 2>&1 \
    || fail 'aster pack failed'
PKG="$TMP/pkg"
mkdir -p "$TMP/proj/src"
cat > "$TMP/proj/aster.proj" <<'EOF'
name probe
src/main.ast
src/util.ast
EOF
cat > "$TMP/proj/src/util.ast" <<'EOF'
// aster:language=zh
结构 尺寸
宽: 整数
高: 整数
结束 结构
变量 工具名: 字符串 = "尺"
方法 面积(尺寸: 尺寸): 整数
返回 尺寸.宽
结束 方法
EOF
cat > "$TMP/proj/src/main.ast" <<'EOF'
// aster:language=zh
结构 点
x: 整数
y: 整数
结束 结构
枚举 颜色
红
绿
结束 枚举
变量 全局计数: 整数 = 0
类 问候页
变量 标题: 字符串
变量 位置: 点
方法 问候(名字: 字符串): 字符串
变量 本地问候: 字符串 = 名字
返回 本地问候
结束 方法
方法 面积(): 整数
变量 宽: 整数 = 3
返回 宽
结束 方法
结束 类
方法 造点(): 点
变量 p: 点
返回 p
结束 方法
方法 启动方法(): 整数
变量 页: 问候页
变量 n: 整数 = 1
返回 0
结束 方法
EOF
MAIN="$TMP/proj/src/main.ast"

echo '[2/6] same-project symbols complete at the cursor'
CUR=$(cursor_for "$MAIN" '返回 0' '返回 |' "$TMP/s1.ast")
complete_at "$TMP/s1.ast" "$CUR" "$MAIN" "$TMP/c1.json"
for want in n 全局计数 造点 面积 工具名; do
    names "$TMP/c1.json" | grep -qx "$want" || fail "expression completion is missing $want"
done
for want in 问候页 点; do
    if names "$TMP/c1.json" | grep -qx "$want"; then fail "expression completion leaked type $want"; fi
done
CUR=$(cursor_for "$MAIN" '变量 本地问候: 字符串 = 名字' '变量 本地问候: 字符串 = 名|' "$TMP/s2.ast")
complete_at "$TMP/s2.ast" "$CUR" "$MAIN" "$TMP/c2.json"
names "$TMP/c2.json" | grep -qx '名字' || fail 'parameter 名字 did not complete'
if names "$TMP/c2.json" | grep -qx '本地问候'; then fail 'a local declared after the cursor completed'; fi
CUR=$(cursor_for "$MAIN" '返回 本地问候' '返回 本|地问候' "$TMP/s3.ast")
complete_at "$TMP/s3.ast" "$CUR" "$MAIN" "$TMP/c3.json"
names "$TMP/c3.json" | grep -qx '本地问候' || fail 'local 本地问候 did not complete with prefix 本'
if names "$TMP/c3.json" | grep -qx '名字'; then fail 'prefix 本 did not filter out 名字'; fi
CUR=$(cursor_for "$MAIN" '返回 本地问候' '返回 标|
返回 本地问候' "$TMP/s4.ast")
complete_at "$TMP/s4.ast" "$CUR" "$MAIN" "$TMP/c4.json"
names "$TMP/c4.json" | grep -qx '标题' || fail 'class field 标题 did not complete inside its method'

echo '[3/6] member completion follows the receiver type'
CUR=$(cursor_for "$MAIN" '返回 p' '返回 p.|' "$TMP/m1.ast")
complete_at "$TMP/m1.ast" "$CUR" "$MAIN" "$TMP/m1.json"
[ "$(names "$TMP/m1.json" | tr '\n' ' ')" = 'x y ' ] || fail "struct members are wrong: $(names "$TMP/m1.json" | tr '\n' ' ')"
CUR=$(cursor_for "$MAIN" '返回 0' '返回 页.|' "$TMP/m2.ast")
complete_at "$TMP/m2.ast" "$CUR" "$MAIN" "$TMP/m2.json"
[ "$(names "$TMP/m2.json" | tr '\n' ' ')" = '标题 位置 问候 面积 ' ] || fail "class members are wrong: $(names "$TMP/m2.json" | tr '\n' ' ')"
CUR=$(cursor_for "$MAIN" '返回 0' '返回 文本.|' "$TMP/m3.ast")
complete_at "$TMP/m3.ast" "$CUR" "$MAIN" "$TMP/m3.json"
[ "$(names "$TMP/m3.json" | tr '\n' ' ')" = 'length concat equals less print eprint ' ] || fail "module 文本 members are wrong: $(names "$TMP/m3.json" | tr '\n' ' ')"
names_zh "$TMP/m3.json" | grep -qx 'length	长度' || fail 'module member length lost its Chinese name'
CUR=$(cursor_for "$MAIN" '返回 0' '返回 n.|' "$TMP/m4.ast")
complete_at "$TMP/m4.ast" "$CUR" "$MAIN" "$TMP/m4.json"
[ -z "$(names "$TMP/m4.json")" ] || fail "an i32 variable must have no members: $(names "$TMP/m4.json" | tr '\n' ' ')"
CUR=$(cursor_for "$MAIN" '返回 0' '返回 造点().|' "$TMP/m5.ast")
complete_at "$TMP/m5.ast" "$CUR" "$MAIN" "$TMP/m5.json"
[ "$(names "$TMP/m5.json" | tr '\n' ' ')" = 'x y ' ] || fail "call-result members are wrong: $(names "$TMP/m5.json" | tr '\n' ' ')"
CUR=$(cursor_for "$MAIN" '返回 0' '返回 颜色.|' "$TMP/m6.ast")
complete_at "$TMP/m6.ast" "$CUR" "$MAIN" "$TMP/m6.json"
[ "$(names "$TMP/m6.json" | tr '\n' ' ')" = '红 绿 ' ] || fail "enum members are wrong: $(names "$TMP/m6.json" | tr '\n' ' ')"

echo '[4/6] context filtering: type position, expression position, return type'
CUR=$(cursor_for "$MAIN" '变量 n: 整数 = 1' '变量 n: |' "$TMP/t1.ast")
complete_at "$TMP/t1.ast" "$CUR" "$MAIN" "$TMP/t1.json"
for want in 点 颜色 问候页 尺寸; do
    names "$TMP/t1.json" | grep -qx "$want" || fail "type position is missing $want"
done
names_zh "$TMP/t1.json" | grep -qx 'i32	整数' || fail 'type position is missing builtin 整数'
for want in 造点 length n; do
    if names "$TMP/t1.json" | grep -qx "$want"; then fail "type position leaked $want"; fi
done
CUR=$(cursor_for "$MAIN" '方法 造点(): 点' '方法 造点(): |' "$TMP/t2.ast")
complete_at "$TMP/t2.ast" "$CUR" "$MAIN" "$TMP/t2.json"
names "$TMP/t2.json" | grep -qx '点' || fail 'return-type position is missing 点'
if names "$TMP/t2.json" | grep -qx '造点'; then fail 'return-type position leaked 造点'; fi

echo '[5/6] Chinese mode keeps both names; unsaved text never touches disk'
"$ASTER_BIN" complete --language zh --format json "$PKG" > "$TMP/zh.json" 2>&1
python3 - "$TMP/zh.json" <<'PY' || fail 'zh completion lost a name'
import json, sys
entries = json.load(open(sys.argv[1]))
assert len(entries) == 143, len(entries)
assert sorted(e["name_zh"] for e in entries if e["name_zh"]) == \
    sorted(["长度", "拼接", "相等", "更小", "输出", "输出错误"]), entries
assert "memcpy" in [e["name"] for e in entries], entries
assert set(entries[0]) == {"name", "name_zh", "kind", "signature", "package", "doc", "doc_en"}, entries[0]
PY
"$ASTER_BIN" complete --language zh "$PKG" > "$TMP/zh.txt" 2>&1
grep -q '^长度' "$TMP/zh.txt" || fail 'zh text completion is missing 长度'
grep -q '^memcpy' "$TMP/zh.txt" || fail 'zh text completion lost English-only memcpy'
cp "$MAIN" "$TMP/main-before.ast"
sed 's/变量 n: 整数 = 1/变量 独角兽: 整数 = 1/' "$MAIN" > "$TMP/u0.ast"
CUR=$(cursor_for "$TMP/u0.ast" '返回 0' '返回 独|' "$TMP/u1.ast")
complete_at "$TMP/u1.ast" "$CUR" "$MAIN" "$TMP/u1.json"
names "$TMP/u1.json" | grep -qx '独角兽' || fail 'an unsaved symbol did not complete'
if names "$TMP/u1.json" | grep -qx 'n'; then fail 'the stale disk symbol n completed'; fi
cmp -s "$MAIN" "$TMP/main-before.ast" || fail 'completion wrote back to the disk file'

echo '[6/6] regression: no-cursor output is stable, usage errors stay rc=2'
"$ASTER_BIN" complete --language en --format json "$PKG" > "$TMP/en1.json" 2>&1
"$ASTER_BIN" complete --language en --format json "$PKG" > "$TMP/en2.json" 2>&1
cmp -s "$TMP/en1.json" "$TMP/en2.json" || fail 'no-cursor en JSON is not deterministic'
python3 - "$TMP/en1.json" <<'PY' || fail 'no-cursor en JSON is wrong'
import json, sys
entries = json.load(open(sys.argv[1]))
assert len(entries) == 143, len(entries)
assert set(entries[0]) == {"name", "name_zh", "kind", "signature", "package", "doc", "doc_en"}, entries[0]
PY
"$ASTER_BIN" complete --language en "$PKG" > "$TMP/en.txt" 2>&1
[ "$(grep -c . "$TMP/en.txt")" = '143' ] || fail "no-cursor en text has $(grep -c . "$TMP/en.txt") lines, expected 143"
if "$ASTER_BIN" complete --cursor 1:2 "$PKG" > /dev/null 2>&1; then fail '--cursor without a file must fail'; fi
if "$ASTER_BIN" complete --stdin "$PKG" "$MAIN" < /dev/null > /dev/null 2>&1; then fail '--stdin without --cursor must fail'; fi
if "$ASTER_BIN" complete --cursor xx "$PKG" "$MAIN" > /dev/null 2>&1; then fail 'a malformed --cursor must fail'; fi
echo 'PASS: complete-checks'
