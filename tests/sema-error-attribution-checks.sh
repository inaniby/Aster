#!/bin/sh
# tests/sema-error-attribution-checks.sh
#
# Sema 报错文件归属（~/workspace/cold-compile/sema-error-attribution/ §3/§4）：
# Sema 抛的错只带行列号、不带文件；渲染时文件取自全局指针，而该指针在
# Sema 运行时恒为空，于是回退到“最后一次解析的文件”（aster.proj 末文件）。
# §3 修复：Function 加 sourceFile 字段（lowering 填），compileProgram 的
# order 循环逐函数置诊断文件（抛错时 sticky、不恢复；正常路径恢复旧值），
# runBilingualProjectBuild 入口清一次诊断文件/行表。
#
#   [1/7] e3：错在首文件 main.ast，末文件 alloc.ast 干净——串行/并行/
#         daemon 三形态 stderr 与 §3 金样逐字节相同（src/main.ast:2:1 +
#         回显 main.ast 第 2 行 + caret），stdout 为空，rc=1，无 APK 产物
#         （报错前已编好的 TU 会在 build/.cache 留 .o，属正常）。
#   [2/7] 对照三项：e3b 单文件（逐字节不变的回归锚点）、e3-last-err 错在
#         末文件（本就报对，逐字节不变）、e3-mid-err 错在中间文件 b.ast
#         （串行/并行，src/b.ast:2:1 + 回显 b.ast 行）。
#   [3/7] errproj3（真实大工程夹具，~/workspace/parallel-build/errproj3
#         的副本）：串行/并行均报 framework/src/aui_tables.ast:883:27 +
#         回显该行，基线报 src/main.ast:883:27 且无回显。
#   [4/7] P1 类方法错（src/a.ast:4:1）、P2 包方法错
#         （packages/math.ast:4:1，绝对路径拼写——工作目录前缀归一化后比对）。
#   [5/7] P3 build-cn-obj merged 错（helper.ast:2:1，[A-050] 前缀为该路径
#         既有渲染）、P4 aster test 错（tests/bad.ast:3:1，基线报 <source>）。
#   [6/7] diagnose JSON：e3 与 errproj3 的 file 字段同步改（文本与 JSON
#         同根因、同修复点），stdout 与 §3 金样逐字节相同，rc=1。
#   [7/7] 消息正文不动（F2）：剥离 `aster: <file>:L:C: ` 头后，e3 /
#         errproj3 / e3-mid-err 的首行消息（`error: … at L:C`）新旧二进
#         制逐字节相同。回显行与 caret 不在此项比对——它们理应随归属改
#         变（回显改取真文件的行），已由 [1/7]–[5/7] 的金样逐字节覆盖。
#         且新 stderr 不含旧的错指文件（e3 无 alloc.ast，
#         errproj3 无 src/main.ast:883，e3-mid 无 c.ast，P4 无 <source>）。
#
# Fixtures: e3/e3b/e3-last/e3-mid/P1–P4 为内嵌写出（与 §3 夹具逐字节相同，
# 已用修复二进制在全新目录下与 §3 verify/ 金样核对过）；errproj3 为外部
# 真实夹具的副本（从不就地改）。缺外部夹具时大声失败。
#
# Binaries (all strict -Wall -Wextra -Wpedantic -Werror, 0 warnings):
#   ASTER_BIN   binary under test (default $TMPD/aster-sea, rebuilt from
#               src/aster.cpp unless SEA_NO_REBUILD=1)
#   COLD_BIN    cold-control binary (default $TMPD/aster-sea-base, rebuilt
#               from `git show HEAD:src/aster.cpp`; point SEA_COLD_BIN at a
#               prebuilt baseline to skip the rebuild). The suite refuses
#               to run if it hashes identically to ASTER_BIN: with no
#               worktree change the [7/7] body comparison would pass
#               vacuously.
#
# Override points (env vars): ASTER_BIN, SEA_COLD_BIN, SEA_NO_REBUILD=1,
# ASTER_KEY_DIR (fixed to $HOME/workspace/projects/Aster below; the signing
# key must be identical across every twin build).
set -eu
. tests/lib/tmpdir.sh

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

export ASTER_KEY_DIR="$HOME/workspace/projects/Aster"
ASTER_BIN="${ASTER_BIN:-$TMPD/aster-sea}"
COLD_BIN="${SEA_COLD_BIN:-$TMPD/aster-sea-base}"
W="$TMPD/sea-checks"
rm -rf "$W"; mkdir -p "$W/golden"
PASS_N=0

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { PASS_N=$((PASS_N + 1)); printf '  %-44s %s\n' "$1" 'ok'; }
sha_file() { sha256sum "$1" | cut -d' ' -f1; }
# run_logged <rcfile> <outfile> <errfile> <workdir> <cmd...>: run <cmd> in
# <workdir>, capturing rc/out/err to FILES (never a pipe: in a pipeline $?
# is the last stage's status, not the binary's). Failing commands are
# EXPECTED here (error fixtures), so the failure must not trip set -e.
run_logged() {
    rl_rcfile=$1; rl_outfile=$2; rl_errfile=$3; rl_dir=$4; shift 4
    rl_rc=0
    (cd "$rl_dir" && "$@" > "$rl_outfile" 2> "$rl_errfile") || rl_rc=$?
    echo "$rl_rc" > "$rl_rcfile"
}
# build_golden <label> <dir> <golden> [argv...]: ASTER_BIN build of an
# error fixture; requires rc=1, empty stdout, empty build/, and stderr
# byte-identical to the golden file.
build_golden() {
    label=$1; dir=$2; golden=$3; shift 3
    rm -rf "$dir/build"
    run_logged "$W/g.rc" "$W/g.out" "$W/g.err" "$dir" env ASTER_KEY_DIR="$ASTER_KEY_DIR" "$ASTER_BIN" build --jobs 1 "$@"
    [ "$(cat "$W/g.rc")" = 1 ] || fail "$label: rc=$(cat "$W/g.rc"), expected 1 (see $W/g.err)"
    [ -s "$W/g.out" ] && fail "$label: stdout not empty on error (see $W/g.out)"
    cmp -s "$W/g.err" "$golden" || fail "$label: stderr differs from golden (diff $W/g.err $golden)"
    # A failed build must leave no product: TUs compiled before the error
    # may leave .o files in build/.cache, but never an APK/executable.
    [ -z "$(find "$dir/build" -name '*.apk' -o -name '*.exe' 2>/dev/null | head -1)" ] || fail "$label: build/ contains a product on error"
    ok "$label (rc=1, stderr $(wc -c < "$W/g.err" | tr -d ' ') B)"
}
# build_golden_par <label> <dir> <golden> [argv...]: same, parallel (no
# --jobs 1); stderr must still equal the same golden file.
build_golden_par() {
    label=$1; dir=$2; golden=$3; shift 3
    rm -rf "$dir/build"
    run_logged "$W/g.rc" "$W/g.out" "$W/g.err" "$dir" env ASTER_KEY_DIR="$ASTER_KEY_DIR" "$ASTER_BIN" build "$@"
    [ "$(cat "$W/g.rc")" = 1 ] || fail "$label: rc=$(cat "$W/g.rc"), expected 1 (see $W/g.err)"
    [ -s "$W/g.out" ] && fail "$label: stdout not empty on error (see $W/g.out)"
    cmp -s "$W/g.err" "$golden" || fail "$label: stderr differs from golden (diff $W/g.err $golden)"
    ok "$label (rc=1, par, stderr $(wc -c < "$W/g.err" | tr -d ' ') B)"
}
# strip_header <file>: drop the leading `aster: <file>:L:C: ` from line 1,
# leaving the message line untouched. Only line 1 is compared (F2): the
# echo/caret lines intentionally change with the attribution (the echo is
# now taken from the true file) and are covered byte-exactly by the
# golden compares in [1/7]-[5/7].
strip_header() { sed -E '1s/^aster: .+:[0-9]+:[0-9]+: //' "$1" | head -1; }
# body_compare <label> <dir> [argv...]: new vs cold binary build of an
# error fixture; rc must agree (1), stdout must be empty on both sides,
# and the header-stripped first message line must be byte-identical (F2:
# the message text never changed, only the file attribution did).
body_compare() {
    label=$1; dir=$2; shift 2
    rm -rf "$dir/build"
    run_logged "$W/b-new.rc" "$W/b-new.out" "$W/b-new.err" "$dir" env ASTER_KEY_DIR="$ASTER_KEY_DIR" "$ASTER_BIN" build --jobs 1 "$@"
    rm -rf "$dir/build"
    run_logged "$W/b-cold.rc" "$W/b-cold.out" "$W/b-cold.err" "$dir" env ASTER_KEY_DIR="$ASTER_KEY_DIR" "$COLD_BIN" build --jobs 1 "$@"
    ra=$(cat "$W/b-new.rc"); rb=$(cat "$W/b-cold.rc")
    [ "$ra" = 1 ] && [ "$rb" = 1 ] || fail "$label: rc differs new=$ra cold=$rb (see $W/b-*.err)"
    [ -s "$W/b-new.out" ] || [ -s "$W/b-cold.out" ] && fail "$label: stdout not empty on error"
    strip_header "$W/b-new.err" > "$W/b-new.body"
    strip_header "$W/b-cold.err" > "$W/b-cold.body"
    cmp -s "$W/b-new.body" "$W/b-cold.body" || fail "$label: message line differs new vs cold (diff $W/b-new.body $W/b-cold.body)"
    ok "$label (message line identical, rc=1)"
}

echo "setup: strict rebuilds + source guards"
if [ "${SEA_NO_REBUILD:-0}" = 1 ]; then
    [ -x "$ASTER_BIN" ] || fail "SEA_NO_REBUILD=1 but ASTER_BIN is not executable: $ASTER_BIN"
    printf '  %-44s %s\n' 'using prebuilt ASTER_BIN (SEA_NO_REBUILD=1)' "$ASTER_BIN"
else
    ${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror -o "$ASTER_BIN" src/aster.cpp
    printf '  %-44s %s\n' 'strict rebuild (test binary)' 'ok'
fi
if [ -n "${SEA_COLD_BIN:-}" ]; then
    [ -x "$COLD_BIN" ] || fail "SEA_COLD_BIN is not executable: $COLD_BIN"
else
    # The HEAD source must be compiled from a file NAMED aster.cpp: the
    # anonymous-namespace mangling seed follows the input file name.
    git show HEAD:src/aster.cpp > "$W/aster.cpp" || fail "could not read HEAD:src/aster.cpp for the cold binary"
    # NOTE: aster.cpp lives in $W, not src/, so the sibling cn_*.hpp
    # headers only resolve with -I src (same trap as the §1 probe build).
    ${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror -I src -o "$COLD_BIN" "$W/aster.cpp"
    printf '  %-44s %s\n' 'strict rebuild (cold binary, HEAD)' 'ok'
fi
[ "$(sha_file "$ASTER_BIN")" != "$(sha_file "$COLD_BIN")" ] || fail "ASTER_BIN hashes identically to COLD_BIN: no worktree change, suite would pass vacuously"
printf '  %-44s %s\n' 'test binary md5' "$(md5sum "$ASTER_BIN" | cut -d' ' -f1)"
printf '  %-44s %s\n' 'cold binary md5' "$(md5sum "$COLD_BIN" | cut -d' ' -f1)"
for needle in 'std::string sourceFile;' 'cnSetDiagnosticFile(f->sourceFile)' 'g_diagFile.clear();' 'prevDiagLines'; do
    grep -qF -- "$needle" src/aster.cpp || fail "source guard missing: $needle"
done
ok 'source guards (Function::sourceFile + per-function set + entry clear)'

# ---------------------------------------------------------------------------
# Golden stderr files (§3 verify/ bytes, re-verified path-independent:
# the same bytes reproduce from a fresh directory).
# ---------------------------------------------------------------------------
cat > "$W/golden/e3.err" <<'EOF'
aster: src/main.ast:2:1: error: return type mismatch in function main at 2:1
    返回 "独一文字"
    ^
EOF
cat > "$W/golden/e3b.err" <<'EOF'
aster: src/main.ast:2:1: error: return type mismatch in function main at 2:1
    返回 "独一文字"
    ^
EOF
cat > "$W/golden/e3-last.err" <<'EOF'
aster: src/alloc.ast:2:1: error: return type mismatch in function alloc at 2:1
    返回 真
    ^
EOF
cat > "$W/golden/e3-mid.err" <<'EOF'
aster: src/b.ast:2:1: error: return type mismatch in function __aster_cn_e587bae99499e696b9e6b395 at 2:1
    返回 "错在中间文件"
    ^
EOF
cat > "$W/golden/errproj3.err" <<'EOF'
aster: framework/src/aui_tables.ast:883:27: error: return type mismatch in function bad_tu_early at 883:27
    fn bad_tu_early() : i32 { return "oops-early"; }
                              ^
EOF
cat > "$W/golden/p1.err" <<'EOF'
aster: src/a.ast:4:1: error: return type mismatch in function __aster_cn_method_e8aea1e695b0e599a8_e59d8f at 4:1
    返回 "错在类方法"
    ^
EOF
# P2's header carries the absolute project path (module-dir resolution);
# the golden keeps the placeholder __W__ and the compare normalises it.
cat > "$W/golden/p2.err" <<'EOF'
aster: __W__/packages/math.ast:4:1: error: return type mismatch in function __aster_cn_5f5f61737465725f6d6f645f36353738373436353732366536313663326536643631373436385f616464 at 4:1
    return "oops-pkg";
    ^
EOF
cat > "$W/golden/p3.err" <<'EOF'
aster: helper.ast:2:1: error: [A-050] 类型检查失败 (return type mismatch in function __aster_cn_e59d8fe696b9e6b395) at 2:1
    返回 "错在导入文件"
    ^
EOF
cat > "$W/golden/p4.err" <<'EOF'
aster: tests/bad.ast:3:1: error: return type mismatch in function main at 3:1
    return "oops-test";
    ^
EOF
cat > "$W/golden/e3-diagnose.out" <<'EOF'
{"diagnostics": [{"file": "src/main.ast", "line": 2, "column": 1, "message": "return type mismatch in function main", "level": "error"}]}
EOF
cat > "$W/golden/errproj3-diagnose.out" <<'EOF'
{"diagnostics": [{"file": "framework/src/aui_tables.ast", "line": 883, "column": 27, "message": "return type mismatch in function bad_tu_early", "level": "error"}]}
EOF

# ---------------------------------------------------------------------------
# Fixture writers (byte-identical to the §3 repro fixtures).
# ---------------------------------------------------------------------------
write_e3() { # $1 = dir (error in first file, last file clean)
    dd=$1; rm -rf "$dd"; mkdir -p "$dd/src"
    cat > "$dd/aster.proj" <<'PROJ'
kind exe
[language]
default = "zh"
src/main.ast
src/alloc.ast
PROJ
    cat > "$dd/src/main.ast" <<'SRC'
方法 启动方法(): 整数
返回 "独一文字"
结束 方法
SRC
    cat > "$dd/src/alloc.ast" <<'SRC'
方法 alloc(数量: 整数): 指针
返回 0
结束 方法
SRC
}
write_e3b() { # $1 = dir (single file)
    dd=$1; rm -rf "$dd"; mkdir -p "$dd/src"
    cat > "$dd/aster.proj" <<'PROJ'
kind exe
[language]
default = "zh"
src/main.ast
PROJ
    cat > "$dd/src/main.ast" <<'SRC'
方法 启动方法(): 整数
返回 "独一文字"
结束 方法
SRC
}
write_e3_last() { # $1 = dir (error in the last file: was already right)
    dd=$1; rm -rf "$dd"; mkdir -p "$dd/src"
    cat > "$dd/aster.proj" <<'PROJ'
kind exe
[language]
default = "zh"
src/main.ast
src/alloc.ast
PROJ
    cat > "$dd/src/main.ast" <<'SRC'
方法 启动方法(): 整数
返回 0
结束 方法
SRC
    cat > "$dd/src/alloc.ast" <<'SRC'
方法 alloc(数量: 整数): 指针
返回 真
结束 方法
SRC
}
write_e3_mid() { # $1 = dir (three files, error in the middle one)
    dd=$1; rm -rf "$dd"; mkdir -p "$dd/src"
    cat > "$dd/aster.proj" <<'PROJ'
kind exe
[language]
default = "zh"
src/a.ast
src/b.ast
src/c.ast
PROJ
    cat > "$dd/src/a.ast" <<'SRC'
方法 启动方法(): 整数
返回 0
结束 方法
SRC
    cat > "$dd/src/b.ast" <<'SRC'
方法 出错方法(): 整数
返回 "错在中间文件"
结束 方法
SRC
    cat > "$dd/src/c.ast" <<'SRC'
方法 干净方法(): 整数
返回 0
结束 方法
SRC
}
write_p1() { # $1 = dir (class-method error in src/a.ast)
    dd=$1; rm -rf "$dd"; mkdir -p "$dd/src"
    cat > "$dd/aster.proj" <<'PROJ'
kind exe
[language]
default = "zh"
src/a.ast
src/b.ast
PROJ
    cat > "$dd/src/a.ast" <<'SRC'
类 计数器
变量 值: 整数 = 0
方法 坏(): 整数
返回 "错在类方法"
结束 方法
结束 类
SRC
    cat > "$dd/src/b.ast" <<'SRC'
方法 启动方法(): 整数
返回 0
结束 方法
SRC
}
write_p2() { # $1 = dir (package-method error in packages/math.ast)
    dd=$1; rm -rf "$dd"; mkdir -p "$dd/src" "$dd/packages"
    cat > "$dd/aster.proj" <<'PROJ'
name pkgerr
[language]
default = "zh"
allowed = ["zh", "en"]
src/main.ast
PROJ
    cat > "$dd/src/main.ast" <<'SRC'
@导入("external.math").别名("math")
方法 启动方法(): 整数
返回 math.add(1)
结束 方法
SRC
    cat > "$dd/packages/math.ast" <<'SRC'
// aster:language=en
package external.math;
fn add(value: i32): i32 {
return "oops-pkg";
}
SRC
}
write_p3() { # $1 = dir (merged via file import: error in helper.ast)
    dd=$1; rm -rf "$dd"; mkdir -p "$dd"
    cat > "$dd/helper.ast" <<'SRC'
方法 坏方法(数: 整数): 整数
返回 "错在导入文件"
结束 方法
SRC
    cat > "$dd/main.ast" <<'SRC'
导入 "helper.ast"
方法 启动方法(): 整数
返回 坏方法(1)
结束 方法
SRC
}
write_p4() { # $1 = dir (aster test error in tests/bad.ast)
    dd=$1; rm -rf "$dd"; mkdir -p "$dd/tests"
    cat > "$dd/aster.proj" <<'PROJ'
name testerr
[language]
default = "en"
allowed = ["zh", "en"]
test tests/bad.ast
PROJ
    cat > "$dd/tests/bad.ast" <<'SRC'
// aster:language=en
fn main(): i32 {
return "oops-test";
}
SRC
}

# ---------------------------------------------------------------------------
echo "[1/7] e3: error in first file (serial / parallel / daemon)"
d="$W/e3"; write_e3 "$d"
build_golden "e3 serial j1" "$d" "$W/golden/e3.err"
build_golden_par "e3 parallel" "$d" "$W/golden/e3.err"
# Daemon: same stderr as the serial build (parity, §1 root-cause step 8).
SOCKDIR="$d/build/.cache"
stop_daemon() {
    "$ASTER_BIN" serve stop --project "$d" > /dev/null 2>&1 || true
    # serve stop can miss under load (CI B 批曾漏停一个 daemon，socket
    # 随后被 [6/7] 的 rm -rf 删掉，只能 kill)；setsid 直接 exec daemon，
    # 故 $! 即 daemon pid，停不掉时直接杀，不留孤儿进程。
    sleep 1
    if [ -n "${DAEMON_PID:-}" ] && kill -0 "$DAEMON_PID" 2>/dev/null; then kill "$DAEMON_PID" 2>/dev/null || true; sleep 1; fi
}
trap stop_daemon EXIT
setsid "$ASTER_BIN" serve --project "$d" --socket-dir "$SOCKDIR" --detached > "$W/e3-daemon-serve.log" 2>&1 < /dev/null &
DAEMON_PID=$!
sleep 2
"$ASTER_BIN" serve status --project "$d" > "$W/e3-daemon-status.log" 2>&1 || { echo "FAIL: daemon did not come up:" >&2; cat "$W/e3-daemon-serve.log" >&2; exit 1; }
grep -q 'running (pid ' "$W/e3-daemon-status.log" || fail "daemon status did not report running"
ok 'e3 daemon up (serve status)'
rm -rf "$d/build"
run_logged "$W/g.rc" "$W/g.out" "$W/g.err" "$d" env ASTER_KEY_DIR="$ASTER_KEY_DIR" ASTER_DAEMON=1 "$ASTER_BIN" build --jobs 1
[ "$(cat "$W/g.rc")" = 1 ] || fail "e3 daemon: rc=$(cat "$W/g.rc"), expected 1 (see $W/g.err)"
[ -s "$W/g.out" ] && fail "e3 daemon: stdout not empty on error"
cmp -s "$W/g.err" "$W/golden/e3.err" || fail "e3 daemon: stderr differs from golden (diff $W/g.err $W/golden/e3.err)"
ok "e3 daemon (rc=1, stderr $(wc -c < "$W/g.err" | tr -d ' ') B)"
stop_daemon
trap - EXIT

# ---------------------------------------------------------------------------
echo "[2/7] controls: single file, error in last file, error in middle file"
d="$W/e3b"; write_e3b "$d"
build_golden "e3b single-file" "$d" "$W/golden/e3b.err"
d="$W/e3-last"; write_e3_last "$d"
build_golden "e3-last-err (last file)" "$d" "$W/golden/e3-last.err"
d="$W/e3-mid"; write_e3_mid "$d"
build_golden "e3-mid-err serial j1" "$d" "$W/golden/e3-mid.err"
build_golden_par "e3-mid-err parallel" "$d" "$W/golden/e3-mid.err"

# ---------------------------------------------------------------------------
echo "[3/7] errproj3: real large project (external fixture copy)"
ERR3_SRC="$HOME/workspace/parallel-build/errproj3"
[ -d "$ERR3_SRC" ] || fail "fixture missing: $ERR3_SRC"
d="$W/errproj3"; rm -rf "$d"; cp -r "$ERR3_SRC" "$d"; rm -rf "$d/build"
build_golden "errproj3 serial j1" "$d" "$W/golden/errproj3.err"
build_golden_par "errproj3 parallel" "$d" "$W/golden/errproj3.err"

# ---------------------------------------------------------------------------
echo "[4/7] P1 class method / P2 package method"
d="$W/p1"; write_p1 "$d"
build_golden "P1 class method" "$d" "$W/golden/p1.err"
d="$W/p2"; write_p2 "$d"
rm -rf "$d/build"
run_logged "$W/g.rc" "$W/g.out" "$W/g.err" "$d" env ASTER_KEY_DIR="$ASTER_KEY_DIR" "$ASTER_BIN" build --jobs 1 --module-dir packages
[ "$(cat "$W/g.rc")" = 1 ] || fail "P2 package method: rc=$(cat "$W/g.rc"), expected 1 (see $W/g.err)"
[ -s "$W/g.out" ] && fail "P2 package method: stdout not empty on error"
sed "s|$d|__W__|g" "$W/g.err" > "$W/g.err.norm"
cmp -s "$W/g.err.norm" "$W/golden/p2.err" || fail "P2 package method: stderr differs from golden (diff $W/g.err.norm $W/golden/p2.err)"
ok "P2 package method (rc=1, stderr $(wc -c < "$W/g.err" | tr -d ' ') B)"

# ---------------------------------------------------------------------------
echo "[5/7] P3 build-cn-obj merged / P4 aster test"
d="$W/p3"; write_p3 "$d"
run_logged "$W/g.rc" "$W/g.out" "$W/g.err" "$d" env ASTER_KEY_DIR="$ASTER_KEY_DIR" "$ASTER_BIN" build-cn-obj main.ast -o "$W/p3.o"
[ "$(cat "$W/g.rc")" = 1 ] || fail "P3 build-cn-obj merged: rc=$(cat "$W/g.rc"), expected 1 (see $W/g.err)"
[ -s "$W/g.out" ] && fail "P3 build-cn-obj merged: stdout not empty on error"
cmp -s "$W/g.err" "$W/golden/p3.err" || fail "P3 build-cn-obj merged: stderr differs from golden (diff $W/g.err $W/golden/p3.err)"
ok "P3 build-cn-obj merged (rc=1, stderr $(wc -c < "$W/g.err" | tr -d ' ') B)"
d="$W/p4"; write_p4 "$d"
rm -rf "$d/build"
run_logged "$W/g.rc" "$W/g.out" "$W/g.err" "$d" env ASTER_KEY_DIR="$ASTER_KEY_DIR" "$ASTER_BIN" test
[ "$(cat "$W/g.rc")" = 1 ] || fail "P4 aster test: rc=$(cat "$W/g.rc"), expected 1 (see $W/g.err)"
cmp -s "$W/g.err" "$W/golden/p4.err" || fail "P4 aster test: stderr differs from golden (diff $W/g.err $W/golden/p4.err)"
ok "P4 aster test (rc=1, stderr $(wc -c < "$W/g.err" | tr -d ' ') B)"

# ---------------------------------------------------------------------------
echo "[6/7] diagnose JSON: file field follows the text attribution"
d="$W/e3"; write_e3 "$d"
rm -rf "$d/build"
run_logged "$W/dg.rc" "$W/dg.out" "$W/dg.err" "$d" env ASTER_KEY_DIR="$ASTER_KEY_DIR" "$ASTER_BIN" diagnose
[ "$(cat "$W/dg.rc")" = 1 ] || fail "diagnose e3: rc=$(cat "$W/dg.rc"), expected 1"
[ -s "$W/dg.err" ] && fail "diagnose e3: stderr not empty (see $W/dg.err)"
cmp -s "$W/dg.out" "$W/golden/e3-diagnose.out" || fail "diagnose e3: JSON differs from golden (diff $W/dg.out $W/golden/e3-diagnose.out)"
ok "diagnose e3 JSON file=src/main.ast"
d="$W/errproj3"; rm -rf "$d"; cp -r "$ERR3_SRC" "$d"; rm -rf "$d/build"
run_logged "$W/dg.rc" "$W/dg.out" "$W/dg.err" "$d" env ASTER_KEY_DIR="$ASTER_KEY_DIR" "$ASTER_BIN" diagnose
[ "$(cat "$W/dg.rc")" = 1 ] || fail "diagnose errproj3: rc=$(cat "$W/dg.rc"), expected 1"
[ -s "$W/dg.err" ] && fail "diagnose errproj3: stderr not empty (see $W/dg.err)"
cmp -s "$W/dg.out" "$W/golden/errproj3-diagnose.out" || fail "diagnose errproj3: JSON differs from golden (diff $W/dg.out $W/golden/errproj3-diagnose.out)"
ok "diagnose errproj3 JSON file=framework/src/aui_tables.ast"

# ---------------------------------------------------------------------------
echo "[7/7] message body unchanged (F2): new vs cold, header stripped"
d="$W/e3"; write_e3 "$d"
body_compare "e3 message body" "$d"
grep -qF 'return type mismatch in function main at 2:1' "$W/b-new.body" || fail "e3 body lacks ' at 2:1'"
grep -qF 'alloc.ast' "$W/b-new.err" && fail "e3 stderr still names the wrong file alloc.ast"
d="$W/errproj3"; rm -rf "$d"; cp -r "$ERR3_SRC" "$d"; rm -rf "$d/build"
body_compare "errproj3 message body" "$d"
grep -qF 'return type mismatch in function bad_tu_early at 883:27' "$W/b-new.body" || fail "errproj3 body lacks ' at 883:27'"
grep -qF 'src/main.ast:883' "$W/b-new.err" && fail "errproj3 stderr still names the wrong file src/main.ast:883"
d="$W/e3-mid"; write_e3_mid "$d"
body_compare "e3-mid-err message body" "$d"
grep -qF 'c.ast' "$W/b-new.err" && fail "e3-mid-err stderr still names the wrong file c.ast"
d="$W/p4"; write_p4 "$d"
rm -rf "$d/build"
run_logged "$W/g.rc" "$W/g.out" "$W/g.err" "$d" env ASTER_KEY_DIR="$ASTER_KEY_DIR" "$ASTER_BIN" test
grep -qF '<source>' "$W/g.err" && fail "P4 stderr still reports <source>"
ok 'no stale attribution left (e3/errproj3/e3-mid/P4)'

echo "PASS: sema-error-attribution-checks: $PASS_N cases"
