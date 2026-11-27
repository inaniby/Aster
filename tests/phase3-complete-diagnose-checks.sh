#!/bin/sh
# Phase 3: completion and diagnostics through the daemon
# (incremental-design §6.2/§6.3, §7.4).
#
#   [1] compile aster with the same strict flags used for release (-Werror)
#   [2] `complete` via daemon == cold CLI, byte-identical (zh + en:
#       expression position, member access on a local / cross-file type /
#       enum / call result, type position, unsaved stdin text, text format);
#       the daemon log must show the requests were really served, not
#       silently cold-run
#   [3] daemon-side completion timings over the socket (parseUs / lookupUs /
#       totalUs / refreshUs, microsecond units); reported, not asserted
#       against a threshold beyond sanity (< 10 ms)
#   [4] `diagnose` (cold) == `aster build`'s first diagnostic (parse error,
#       type error, missing main) and the APK-missing-package message
#   [5] `diagnose` via daemon == cold CLI, byte-identical (clean, parse
#       error via cold fallback, type error, missing main, text format,
#       --decl-invalidation); the daemon log must show the served cases;
#       diagnose writes no decl-index.json
#   [6] no link/sign: `diagnose` (cold and via daemon) writes no executable
#       artifact and does not touch the built APK
#   [7] fallback: killing the daemon leaves `complete` and `diagnose`
#       correct (byte-identical to the daemon's earlier output)
#
# Override points (env vars): ASTER_BIN, CXX.
set -eu
. tests/lib/tmpdir.sh

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ASTER_BIN="${ASTER_BIN:-$TMPD/aster-phase3}"
PKG="$TMPD/pkg"
PROJ="$TMPD/cproj"
ENPROJ="$TMPD/enproj"
DIAG="$TMPD/dproj"
SOCKDIR="$PROJ/build/.cache"

fail() { echo "FAIL: $*" >&2; exit 1; }
run_in() { # <dir> <rcfile> <outfile> <errfile> <cmd...>
    _dir=$1; _rcf=$2; _out=$3; _err=$4; shift 4
    set +e
    (cd "$_dir" && "$@" > "$_out" 2> "$_err")
    echo "$?" > "$_rcf"
    set -e
}
stop_all() {
    "$ASTER_BIN" serve stop --project "$PROJ" > /dev/null 2>&1 || true
    "$ASTER_BIN" serve stop --project "$ENPROJ" > /dev/null 2>&1 || true
    "$ASTER_BIN" serve stop --project "$DIAG" > /dev/null 2>&1 || true
}
trap stop_all EXIT

cursor_for() { # <src> <old> <new-with-|> <out> — echoes LINE:COL
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
    raise SystemExit("no cursor marker")
open(out, "w").write("\n".join(lines))
PY
}
# complete_case <label> <proj> <file> <cursor> <stdin> [format] — cold
# (--socket-dir at an empty dir, so no daemon can answer) vs daemon.
complete_case() {
    _label=$1; _proj=$2; _file=$3; _cursor=$4; _stdin=$5; _fmt=${6:-json}
    "$ASTER_BIN" complete --format "$_fmt" --cursor "$_cursor" --stdin \
        --socket-dir "$TMPD/nodaemon" "$PKG" "$_file" < "$_stdin" \
        > "$TMPD/cold-$_label.out" 2> "$TMPD/cold-$_label.err" \
        || fail "cold complete failed: $_label"
    [ ! -s "$TMPD/cold-$_label.err" ] || fail "cold complete wrote stderr: $_label"
    "$ASTER_BIN" complete --format "$_fmt" --cursor "$_cursor" --stdin \
        "$PKG" "$_file" < "$_stdin" \
        > "$TMPD/daemon-$_label.out" 2> "$TMPD/daemon-$_label.err" \
        || fail "daemon complete failed: $_label"
    [ ! -s "$TMPD/daemon-$_label.err" ] || fail "daemon complete wrote stderr: $_label"
    cmp -s "$TMPD/cold-$_label.out" "$TMPD/daemon-$_label.out" \
        || fail "complete differs cold vs daemon: $_label"
    echo "  byte-identical: $_label ($(wc -c < "$TMPD/daemon-$_label.out") bytes)"
}
# diag_case <label> <proj> [args...] — cold vs daemon, bytes + rc.
diag_case() {
    _label=$1; _proj=$2; shift 2
    run_in "$_proj" "$TMPD/dc-$_label.rc" "$TMPD/dc-$_label.out" "$TMPD/dc-$_label.err" \
        "$ASTER_BIN" diagnose --socket-dir "$TMPD/nodaemon" "$@"
    run_in "$_proj" "$TMPD/dd-$_label.rc" "$TMPD/dd-$_label.out" "$TMPD/dd-$_label.err" \
        "$ASTER_BIN" diagnose "$@"
    [ "$(cat "$TMPD/dc-$_label.rc")" = "$(cat "$TMPD/dd-$_label.rc")" ] \
        || fail "diagnose rc differs cold vs daemon: $_label"
    [ ! -s "$TMPD/dc-$_label.err" ] || fail "cold diagnose wrote stderr: $_label"
    [ ! -s "$TMPD/dd-$_label.err" ] || fail "daemon diagnose wrote stderr: $_label"
    cmp -s "$TMPD/dc-$_label.out" "$TMPD/dd-$_label.out" \
        || fail "diagnose differs cold vs daemon: $_label"
    echo "  byte-identical: $_label (rc=$(cat "$TMPD/dd-$_label.rc"))"
}

echo "[1/7] compiling aster (strict: -Wall -Wextra -Werror)"
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror -o "$ASTER_BIN" src/aster.cpp

echo "[1/7] fixtures: packed stdlib, zh + en complete projects, diag project"
"$ASTER_BIN" pack --src-dir "$ROOT/stdlib" --out "$PKG" > /dev/null 2>&1 || fail 'aster pack failed'
# Fixture dirs live directly under $TMPD (see tests/lib/tmpdir.sh), so a
# previous run leaves build/ + daemon sockets behind; without this rm the
# second run fails [6/7] on the stale $DIAG/build/probe-diag exe.
rm -rf "$PROJ" "$ENPROJ" "$DIAG"
mkdir -p "$PROJ/src" "$ENPROJ/src" "$DIAG/src"
cat > "$PROJ/aster.proj" <<'EOF'
name probe
src/main.ast
src/util.ast
EOF
cat > "$PROJ/src/util.ast" <<'EOF'
// aster:language=zh
结构 尺寸
宽: 整数
高: 整数
结束 结构
变量 工具名: 字符串 = "尺"
方法 面积(尺寸: 尺寸): 整数
返回 尺寸.宽
结束 方法
方法 造点(x: 整数, y: 整数): 点
变量 p: 点
返回 p
结束 方法
EOF
cat > "$PROJ/src/main.ast" <<'EOF'
// aster:language=zh
结构 点
x: 整数
y: 整数
结束 结构
枚举 颜色
红
绿
结束 枚举
方法 主(): 整数
变量 p: 点
变量 s: 尺寸
变量 n: 整数 = 3
返回 0
结束 方法
EOF
cat > "$ENPROJ/aster.proj" <<'EOF'
name probe-en
src/main.ast
src/util.ast
EOF
cat > "$ENPROJ/src/util.ast" <<'EOF'
// aster:language=en
struct Size { w: i32, h: i32 }
fn area(s: Size): i32 { return s.w; }
fn makePoint(x: i32, y: i32): Point { let p: Point; return p; }
EOF
cat > "$ENPROJ/src/main.ast" <<'EOF'
// aster:language=en
struct Point { x: i32, y: i32 }
fn main(): i32 {
  let p: Point;
  let s: Size;
  let n: i32 = 3;
  return 0;
}
EOF
cat > "$DIAG/aster.proj" <<'EOF'
name probe-diag
src/main.ast
src/util.ast
EOF
cp "$ENPROJ/src/util.ast" "$DIAG/src/util.ast"
cp "$ENPROJ/src/main.ast" "$DIAG/src/main.ast"

echo "[2/7] complete via daemon == cold CLI"
setsid "$ASTER_BIN" serve --project "$PROJ" --socket-dir "$SOCKDIR" --detached \
    > "$TMPD/serve-zh.log" 2>&1 < /dev/null &
sleep 2
"$ASTER_BIN" serve status --project "$PROJ" > /dev/null || fail 'zh daemon did not come up'
CUR=$(cursor_for "$PROJ/src/main.ast" "变量 n: 整数 = 3" "变量 n: 整数 = 3
    变量 候|" "$TMPD/c1.txt")
complete_case "zh-expr" "$PROJ" "$PROJ/src/main.ast" "$CUR" "$TMPD/c1.txt"
CUR=$(cursor_for "$PROJ/src/main.ast" "返回 0" "返回 p.|" "$TMPD/c2.txt")
complete_case "zh-member-local" "$PROJ" "$PROJ/src/main.ast" "$CUR" "$TMPD/c2.txt"
CUR=$(cursor_for "$PROJ/src/main.ast" "返回 0" "返回 s.|" "$TMPD/c3.txt")
complete_case "zh-member-xfile" "$PROJ" "$PROJ/src/main.ast" "$CUR" "$TMPD/c3.txt"
CUR=$(cursor_for "$PROJ/src/main.ast" "返回 0" "变量 q: |" "$TMPD/c4.txt")
complete_case "zh-typepos" "$PROJ" "$PROJ/src/main.ast" "$CUR" "$TMPD/c4.txt"
CUR=$(cursor_for "$PROJ/src/main.ast" "返回 0" "返回 颜色.|" "$TMPD/c5.txt")
complete_case "zh-enum-member" "$PROJ" "$PROJ/src/main.ast" "$CUR" "$TMPD/c5.txt"
CUR=$(cursor_for "$PROJ/src/main.ast" "返回 0" "返回 造点(1, 2).|" "$TMPD/c6.txt")
complete_case "zh-call-receiver" "$PROJ" "$PROJ/src/main.ast" "$CUR" "$TMPD/c6.txt"
CUR=$(cursor_for "$PROJ/src/main.ast" "返回 0" "返回 p.|" "$TMPD/c7.txt")
complete_case "zh-member-text" "$PROJ" "$PROJ/src/main.ast" "$CUR" "$TMPD/c7.txt" "text"
CUR=$(cursor_for "$PROJ/src/main.ast" "返回 0" "变量 新符号: 整数 = 1
    返回 新|" "$TMPD/c8.txt")
complete_case "zh-unsaved-new-sym" "$PROJ" "$PROJ/src/main.ast" "$CUR" "$TMPD/c8.txt"
[ "$(grep -c 'complete:' "$TMPD/serve-zh.log")" = '8' ] \
    || fail "zh daemon served $(grep -c 'complete:' "$TMPD/serve-zh.log") complete requests, expected 8"
"$ASTER_BIN" serve stop --project "$PROJ" > /dev/null 2>&1 || true
sleep 1
setsid "$ASTER_BIN" serve --project "$ENPROJ" --detached \
    > "$TMPD/serve-en.log" 2>&1 < /dev/null &
sleep 2
"$ASTER_BIN" serve status --project "$ENPROJ" > /dev/null || fail 'en daemon did not come up'
CUR=$(cursor_for "$ENPROJ/src/main.ast" "return 0;" "return p.|" "$TMPD/e2.txt")
CUR_E2="$CUR"
complete_case "en-member-local" "$ENPROJ" "$ENPROJ/src/main.ast" "$CUR" "$TMPD/e2.txt"
CUR=$(cursor_for "$ENPROJ/src/main.ast" "return 0;" "return s.|" "$TMPD/e3.txt")
complete_case "en-member-xfile" "$ENPROJ" "$ENPROJ/src/main.ast" "$CUR" "$TMPD/e3.txt"
CUR=$(cursor_for "$ENPROJ/src/main.ast" "return 0;" "var q: |" "$TMPD/e4.txt")
complete_case "en-typepos" "$ENPROJ" "$ENPROJ/src/main.ast" "$CUR" "$TMPD/e4.txt"
[ "$(grep -c 'complete:' "$TMPD/serve-en.log")" = '3' ] \
    || fail "en daemon served $(grep -c 'complete:' "$TMPD/serve-en.log") complete requests, expected 3"

echo "[3/7] daemon-side completion timings (direct socket probe, warm)"
python3 - "$ENPROJ" "$PKG" "$ENPROJ/src/main.ast" "$TMPD/e2.txt" "$ASTER_BIN" <<'PY'
import socket, json, sys, glob, os
proj, pkg, f, stdin_file, aster_bin = sys.argv[1:6]
text = open(stdin_file).read()
socks = glob.glob(proj + "/build/.cache/asterd-*.sock")
assert len(socks) == 1, socks
st = os.stat(aster_bin)
binid = "%d:%d:%d:%d.%d" % (st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns // 10**9, st.st_mtime_ns % 10**9)
lines = text.split("\n")
for i, ln in enumerate(lines):
    idx = ln.find("return p.")
    if idx >= 0:
        line, col = i + 1, idx + len("return p.") + 1
        break
else:
    raise SystemExit("cursor text not found")
tot = []
for i in range(3):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(5)
    s.connect(socks[0])
    fobj = s.makefile("rw", encoding="utf-8", newline="\n")
    fobj.write(json.dumps({"jsonrpc": "2.0", "id": 0, "method": "hello", "params": {"protocol": 1, "bin": binid, "project": proj}}) + "\n"); fobj.flush()
    json.loads(fobj.readline())
    fobj.write(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "complete", "params": {
        "project": proj, "file": f, "cursorLine": line, "cursorCol": col,
        "text": text, "zh": False, "format": "json", "manifest": pkg + "/manifest.json"}}) + "\n"); fobj.flush()
    r = json.loads(fobj.readline())["result"]
    tot.append((r["parseUs"], r["lookupUs"], r["totalUs"], r["refreshUs"]))
    s.close()
for i, (p, l, t, r) in enumerate(tot):
    print("  run %d: parseUs=%d lookupUs=%d totalUs=%d refreshUs=%d" % (i, p, l, t, r))
    assert p < 10000 and l < 10000 and t < 10000 and r < 10000, "completion timing over 10 ms"
PY

echo "[4/7] diagnose (cold) == aster build's first diagnostic"
diag_field() {
    python3 -c "import json,sys; d=json.load(open(sys.argv[1]))['diagnostics']; print(d[0][sys.argv[2]] if d else '')" "$1" "$2"
}
# parse error
python3 - "$DIAG/src/util.ast" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read().replace("struct Size { w: i32, h: i32 }", "struct Size { w: i32, h: i32")
open(p, "w").write(t)
PY
run_in "$DIAG" "$TMPD/dg.rc" "$TMPD/dg.out" "$TMPD/dg.err" "$ASTER_BIN" diagnose
[ "$(cat "$TMPD/dg.rc")" = '1' ] || fail "parse-error diagnose rc != 1"
[ "$(diag_field "$TMPD/dg.out" file)" = 'src/util.ast' ] || fail "parse-error file wrong: $(cat "$TMPD/dg.out")"
run_in "$DIAG" "$TMPD/bg.rc" "$TMPD/bg.out" "$TMPD/bg.err" "$ASTER_BIN" build --jobs 1
grep -qF "$(diag_field "$TMPD/dg.out" message)" "$TMPD/bg.err" || fail "parse-error message not in build output"
echo "  parse error matches build: $(cat "$TMPD/dg.out")"
python3 - "$DIAG/src/util.ast" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read().replace("struct Size { w: i32, h: i32", "struct Size { w: i32, h: i32 }")
open(p, "w").write(t)
PY
# type error
python3 - "$DIAG/src/main.ast" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read().replace("return 0;", "return nosuchvar;")
open(p, "w").write(t)
PY
run_in "$DIAG" "$TMPD/dg2.rc" "$TMPD/dg2.out" "$TMPD/dg2.err" "$ASTER_BIN" diagnose
[ "$(cat "$TMPD/dg2.rc")" = '1' ] || fail "type-error diagnose rc != 1"
[ "$(diag_field "$TMPD/dg2.out" message)" = 'unknown variable: nosuchvar' ] || fail "type-error message wrong: $(cat "$TMPD/dg2.out")"
[ "$(diag_field "$TMPD/dg2.out" file)" = 'src/main.ast' ] || fail "type-error file wrong"
run_in "$DIAG" "$TMPD/bg2.rc" "$TMPD/bg2.out" "$TMPD/bg2.err" "$ASTER_BIN" build --jobs 1
grep -qF 'unknown variable: nosuchvar' "$TMPD/bg2.err" || fail "type-error message not in build output"
echo "  type error matches build: $(cat "$TMPD/dg2.out")"
python3 - "$DIAG/src/main.ast" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read().replace("return nosuchvar;", "return 0;")
open(p, "w").write(t)
PY
# missing main: location-less
python3 - "$DIAG/src/main.ast" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read().replace("fn main(): i32 {", "fn notmain(): i32 {")
open(p, "w").write(t)
PY
run_in "$DIAG" "$TMPD/dg3.rc" "$TMPD/dg3.out" "$TMPD/dg3.err" "$ASTER_BIN" diagnose
[ "$(cat "$TMPD/dg3.rc")" = '1' ] || fail "missing-main diagnose rc != 1"
[ "$(diag_field "$TMPD/dg3.out" file)" = '' ] || fail "missing-main diagnostic must have empty file"
[ "$(diag_field "$TMPD/dg3.out" message)" = 'program must define main' ] || fail "missing-main message wrong"
echo "  missing main is location-less: $(cat "$TMPD/dg3.out")"
python3 - "$DIAG/src/main.ast" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read().replace("fn notmain(): i32 {", "fn main(): i32 {")
open(p, "w").write(t)
PY

echo "[5/7] diagnose via daemon == cold CLI"
setsid "$ASTER_BIN" serve --project "$DIAG" --detached \
    > "$TMPD/serve-diag.log" 2>&1 < /dev/null &
sleep 2
"$ASTER_BIN" serve status --project "$DIAG" > /dev/null || fail 'diag daemon did not come up'
diag_case "clean" "$DIAG"
python3 - "$DIAG/src/main.ast" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read().replace("return 0;", "return nosuchvar;")
open(p, "w").write(t)
PY
diag_case "type" "$DIAG"
diag_case "type-text" "$DIAG" --format text
python3 - "$DIAG/src/main.ast" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read().replace("return nosuchvar;", "return 0;")
open(p, "w").write(t)
PY
python3 - "$DIAG/src/main.ast" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read().replace("fn main(): i32 {", "fn notmain(): i32 {")
open(p, "w").write(t)
PY
diag_case "nomain" "$DIAG"
python3 - "$DIAG/src/main.ast" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read().replace("fn notmain(): i32 {", "fn main(): i32 {")
open(p, "w").write(t)
PY
diag_case "decl-clean" "$DIAG" --decl-invalidation
[ ! -f "$DIAG/build/.cache/decl-index.json" ] || fail "daemon diagnose wrote decl-index.json"
[ "$(grep -c 'diagnose: exit' "$TMPD/serve-diag.log")" = '5' ] \
    || fail "diag daemon served $(grep -c 'diagnose: exit' "$TMPD/serve-diag.log") diagnose requests, expected 5"

echo "[6/7] no link/sign: diagnose writes no executable artifact"
[ ! -f "$DIAG/build/probe-diag" ] || fail "diagnose wrote the exe (cold path)"
run_in "$DIAG" "$TMPD/b6.rc" "$TMPD/b6.out" "$TMPD/b6.err" "$ASTER_BIN" build --jobs 1
[ "$(cat "$TMPD/b6.rc")" = '0' ] || fail "diag project build failed"
EXE_MTIME_BEFORE=$(stat -c %Y "$DIAG/build/probe-diag")
"$ASTER_BIN" diagnose --project "$DIAG" > /dev/null 2>&1 || fail "daemon diagnose for mtime check failed"
[ "$EXE_MTIME_BEFORE" = "$(stat -c %Y "$DIAG/build/probe-diag")" ] \
    || fail "diagnose touched the built exe"
echo "  exe untouched by diagnose (cold and via daemon)"

echo "[7/7] fallback: daemon stopped, complete and diagnose still correct"
"$ASTER_BIN" serve stop --project "$ENPROJ" > /dev/null 2>&1 || true
"$ASTER_BIN" serve stop --project "$DIAG" > /dev/null 2>&1 || true
sleep 1
"$ASTER_BIN" complete --format json --cursor "$CUR_E2" --stdin \
    "$PKG" "$ENPROJ/src/main.ast" < "$TMPD/e2.txt" > "$TMPD/fb-complete.out" 2> "$TMPD/fb-complete.err" \
    || fail "complete after daemon stop failed"
[ ! -s "$TMPD/fb-complete.err" ] || fail "fallback complete wrote stderr"
cmp -s "$TMPD/fb-complete.out" "$TMPD/daemon-en-member-local.out" \
    || fail "fallback complete differs from daemon output"
run_in "$DIAG" "$TMPD/fb-diag.rc" "$TMPD/fb-diag.out" "$TMPD/fb-diag.err" "$ASTER_BIN" diagnose
[ "$(cat "$TMPD/fb-diag.rc")" = '0' ] || fail "diagnose after daemon stop rc != 0"
cmp -s "$TMPD/fb-diag.out" "$TMPD/dd-clean.out" \
    || fail "fallback diagnose differs from daemon output"
echo "  fallback complete + diagnose byte-identical"

echo 'PASS: phase3-complete-diagnose-checks'
