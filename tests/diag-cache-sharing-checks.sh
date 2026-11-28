#!/bin/sh
# tests/diag-cache-sharing-checks.sh
#
# diag 行缓存共享（~/workspace/cold-compile/diag-cache-sharing/ §4）：
# g_diagLines 按值向量改为指向缓存条目的指针 + 自有后备 owned 向量，
# 同一构建内每个源文件的诊断行只读一次，命中不再整向量拷贝、不再析构
# 旧行。本套件只验证可观测行为：探针计数、报错逐字节对照、daemon
# 产物对照、多程序同进程、读失败路径。净值（ms/文件）在交付目录的
# PROGRESS.md §3/§4 里，不进套件。
#
#   [1/6] 命中复用（v4 探针口径）：干净构建未命中数 = 文件数（问候 21、
#         合成 81），distinctMissPaths = 文件数，命中数与 §1/§3 逐项相等
#         （问候 2329、合成 18649），命中段计时 copyUs <= 1 ms/构建——
#         v4 的 copyUs 计的是指针赋值本身（`g_diagLinesPtr = ...`），
#         实测 0–60 µs 只是计时调用的粒度噪声；§1 基线同口径约
#         129 ms（问候）/ 501 ms（合成），三数量级之差才是断言。
#         逐项 == 0 的写法是错的（合成 81 文件实测 copyUs = 8 µs）。
#         二次构建（0 compiled）未命中仍 = 文件数——每文件每构建只读一次。
#         注意：冷进程的缓存不跨构建常驻，二次构建仍把每文件重读一次
#         是按设计（§2 daemon 边界）；“不重复读”指同一构建内不按 TU
#         重复读，不是跨构建零读盘。
#   [2/6] 文件改动后失效：errproj 的 fnX 行改大（改大小）后重建，报错
#         回显用新内容；改回后回显恢复；两阶段 stderr 与冷基线逐字节相同。
#   [3/6] 报错逐字节对照：(a) errproj 跨文件解析错 j1+并行；(b) 单文件
#         类型错（带行回显与 caret）；(c) 主文件解析错；(d) 双错工程：
#         先报第一个文件的错且回显属该文件，修好第一个后报第二个文件
#         的错且回显属第二个文件。
#   [4/6] daemon 开/关对照：同一 daemon 内首请求与 --no-cache 重复请求
#         的产物（APK sha、全树清单、stderr）逐字节相同；停 daemon 后
#         冷构建（--no-daemon）与首请求产物逐字节相同，stdout 只差 ms。
#         本项无开关：diag 共享没有 on/off 旗标（--no-registry-sharing
#         与本项无关）；daemon 的开/关是 ASTER_DAEMON=1 / --no-daemon。
#         首请求与重复请求的 stdout 按设计就不相同（重复请求走指纹
#         快径复用 APK），故只比产物，不比 stdout（见 §3 口径更正）。
#   [5/6] 多程序同进程指针复用：aster test 两测程各出一例错；先报 t1
#         的错且回显属 t1，修好 t1 后报 t2 的错且回显属 t2，两阶段新旧
#         二进制 stdout+stderr 逐字节相同。
#   [6/6] 空/读失败路径（指针 null 分支）：(a) 不存在的 include；
#         (b) include 文件本身解析错（走 owned 后备，带回显）；
#         (c) 构建成功后删掉一源文件再构建（missing source）；
#         (d) aster test 里测程解析错报 <source>，只印消息无 caret。
#         全部与冷基线逐字节相同。
#
# Fixtures: bench-greet / bench-big / errproj live outside the repo
# (~/workspace/parallel-build, copied, never edited in place); the rest
# are embedded writers. A missing external fixture fails loudly.
#
# Binaries (all strict -Wall -Wextra -Wpedantic -Werror, 0 warnings):
#   ASTER_BIN   binary under test (default $TMPD/aster-dcs, rebuilt from
#               src/aster.cpp unless DC_NO_REBUILD=1)
#   COLD_BIN    cold-control binary (default $TMPD/aster-dcs-base, rebuilt
#               from `git show HEAD:src/aster.cpp`; point DC_COLD_BIN at a
#               prebuilt baseline to skip the rebuild). The suite refuses
#               to run if it hashes identically to ASTER_BIN: with no
#               worktree change every comparison below would pass vacuously.
#   PROBE_BIN   v4 DIAG probe, regenerated from the CURRENT worktree source
#               with $DC_PROBE_SCRIPT (default .../diag-cache-sharing/
#               probes/make_probe_v4.py) so it can never go stale; missing
#               script fails loudly.
#
# Override points (env vars): ASTER_BIN, DC_COLD_BIN, DC_NO_REBUILD=1,
# DC_PROBE_SCRIPT, ASTER_KEY_DIR (fixed to $HOME/workspace/projects/Aster
# below; the signing key must be identical across every twin build).
set -eu
. tests/lib/tmpdir.sh

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

export ASTER_KEY_DIR="$HOME/workspace/projects/Aster"
ASTER_BIN="${ASTER_BIN:-$TMPD/aster-dcs}"
COLD_BIN="${DC_COLD_BIN:-$TMPD/aster-dcs-base}"
PROBE_SCRIPT="${DC_PROBE_SCRIPT:-$HOME/workspace/cold-compile/diag-cache-sharing/probes/make_probe_v4.py}"
W="$TMPD/dcs-checks"
rm -rf "$W"; mkdir -p "$W"
PASS_N=0

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { PASS_N=$((PASS_N + 1)); printf '  %-44s %s\n' "$1" 'ok'; }
norm() { sed -E 's/[0-9]+ ms/N ms/g; s/[0-9]+\.[0-9]*s/N.Ns/g' "$1"; }
norm_eq() { norm "$1" > "$W/n-a"; norm "$2" > "$W/n-b"; cmp -s "$W/n-a" "$W/n-b"; }
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
sha_file() { sha256sum "$1" | cut -d' ' -f1; }
# manifest <dir>: relpath + sha256 of the build/ tree, sorted. Daemon lock
# files (asterd-*.lock, *.sock) embed the daemon pid and are removed on
# stop; they are not build products, so they are excluded.
manifest() {
    (cd "$1" && find build -type f | sort | while read -r f; do
        case "$f" in *asterd-*.lock|*.sock) continue;; esac
        sha256sum "$f"
    done | sed -E 's#^([0-9a-f]{64})  #\1 #' | sort)
}
# err_compare <label> <dir> <mode> [argv...]: new binary vs cold binary
# build of an error fixture; mode j1 adds --jobs 1 to both, par adds
# nothing. Compares rc + ms-normalised stdout + raw stderr bytes.
err_compare() {
    label=$1; dir=$2; mode=$3; shift 3
    if [ "$mode" = j1 ]; then jflag="--jobs 1"; else jflag=""; fi
    rm -rf "$dir/build"
    # shellcheck disable=SC2086
    run_logged "$W/e-new.rc" "$W/e-new.out" "$W/e-new.err" "$dir" env ASTER_KEY_DIR="$ASTER_KEY_DIR" "$ASTER_BIN" build $jflag "$@"
    rm -rf "$dir/build"
    # shellcheck disable=SC2086
    run_logged "$W/e-cold.rc" "$W/e-cold.out" "$W/e-cold.err" "$dir" env ASTER_KEY_DIR="$ASTER_KEY_DIR" "$COLD_BIN" build $jflag "$@"
    ra=$(cat "$W/e-new.rc"); rb=$(cat "$W/e-cold.rc")
    [ "$ra" = "$rb" ] || fail "$label: rc differs new=$ra cold=$rb (see $W/e-*.out|err)"
    norm_eq "$W/e-new.out" "$W/e-cold.out" || fail "$label: stdout differs (see $W/e-*.out)"
    cmp -s "$W/e-new.err" "$W/e-cold.err" || fail "$label: stderr differs (see $W/e-*.err)"
    ok "$label (rc=$ra, stderr $(wc -c < "$W/e-new.err" | tr -d ' ') B)"
}
# test_compare <label> <dir>: aster test with the test binary vs the cold
# binary; compare rc + ms-normalised stdout + raw stderr bytes.
test_compare() {
    label=$1; dir=$2
    rm -rf "$dir/build"
    run_logged "$W/tt-new.rc" "$W/tt-new.out" "$W/tt-new.err" "$dir" env ASTER_KEY_DIR="$ASTER_KEY_DIR" "$ASTER_BIN" test
    rm -rf "$dir/build"
    run_logged "$W/tt-cold.rc" "$W/tt-cold.out" "$W/tt-cold.err" "$dir" env ASTER_KEY_DIR="$ASTER_KEY_DIR" "$COLD_BIN" test
    ra=$(cat "$W/tt-new.rc"); rb=$(cat "$W/tt-cold.rc")
    [ "$ra" = "$rb" ] || fail "$label: rc differs new=$ra cold=$rb (see $W/tt-*.out|err)"
    norm_eq "$W/tt-new.out" "$W/tt-cold.out" || fail "$label: stdout differs (see $W/tt-*.out)"
    cmp -s "$W/tt-new.err" "$W/tt-cold.err" || fail "$label: stderr differs (see $W/tt-*.err)"
    ok "$label (rc=$ra)"
}
# probe_field <diagprobe-file> <field>: value of one DIAGPROBE field.
probe_field() { sed -n "s/.* $2=\\([0-9]*\\).*/\\1/p" "$1" | head -1; }
# probe_build <label> <dir> <probe-out-prefix>: clean serial probe build;
# asserts rc=0 and (N compiled, 0 reused) in stdout, leaves the DIAGPROBE
# file at $W/<prefix>.diagprobe.
probe_build() {
    label=$1; dir=$2; prefix=$3
    rm -rf "$dir/build"; rm -f "$W/$prefix.diagprobe"
    (cd "$dir" && ASTER_KEY_DIR="$ASTER_KEY_DIR" DIAGPROBE_FILE="$W/$prefix.diagprobe" "$PROBE_BIN" build --jobs 1 --verbose > "$W/$prefix.out" 2> "$W/$prefix.err") || fail "$label: probe build failed (see $W/$prefix.err)"
    grep -q 'compiled, 0 reused' "$W/$prefix.out" || fail "$label: no (N compiled, 0 reused) line"
    [ -s "$W/$prefix.diagprobe" ] || fail "$label: no DIAGPROBE output"
}

echo "setup: strict rebuilds + guards + probe regeneration"
if [ "${DC_NO_REBUILD:-0}" = 1 ]; then
    [ -x "$ASTER_BIN" ] || fail "DC_NO_REBUILD=1 but ASTER_BIN is not executable: $ASTER_BIN"
    printf '  %-44s %s\n' 'using prebuilt ASTER_BIN (DC_NO_REBUILD=1)' "$ASTER_BIN"
else
    ${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror -o "$ASTER_BIN" src/aster.cpp
    printf '  %-44s %s\n' 'strict rebuild (test binary)' 'ok'
fi
if [ -n "${DC_COLD_BIN:-}" ]; then
    [ -x "$COLD_BIN" ] || fail "DC_COLD_BIN is not executable: $COLD_BIN"
else
    # The HEAD source must be compiled from a file NAMED aster.cpp: the
    # anonymous-namespace mangling seed follows the input file name, so
    # building the identical source as base.cpp hashes differently
    # (fe91530a… vs the §3 baseline 0c045c00…; verified 2026-11-28).
    git show HEAD:src/aster.cpp > "$W/aster.cpp" || fail "could not read HEAD:src/aster.cpp for the cold binary"
    # NOTE: aster.cpp lives in $W, not src/, so the sibling cn_*.hpp
    # headers only resolve with -I src (same trap as the §1 probe build).
    ${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror -I src -o "$COLD_BIN" "$W/aster.cpp"
    printf '  %-44s %s\n' 'strict rebuild (cold binary, HEAD)' 'ok'
fi
[ "$(sha_file "$ASTER_BIN")" != "$(sha_file "$COLD_BIN")" ] || fail "ASTER_BIN hashes identically to COLD_BIN: no worktree change, suite would pass vacuously"
printf '  %-44s %s\n' 'test binary md5' "$(md5sum "$ASTER_BIN" | cut -d' ' -f1)"
printf '  %-44s %s\n' 'cold binary md5' "$(md5sum "$COLD_BIN" | cut -d' ' -f1)"
for needle in 'g_diagLinesPtr' 'g_diagLinesOwned' 'cnClearDiagLines' 'kEmptyDiagLines'; do
    grep -qF -- "$needle" src/aster.cpp || fail "source guard missing: $needle"
done
grep -qF -- 'diagCache' src/aster.cpp || fail "source guard missing: diagCache"
ok 'source guards (pointer + owned fallback)'
[ -f "$PROBE_SCRIPT" ] || fail "probe script missing: $PROBE_SCRIPT"
python3 "$PROBE_SCRIPT" src/aster.cpp "$W/probe.cpp" > "$W/probe-gen.log" 2>&1 || fail "probe generation failed (see $W/probe-gen.log)"
PROBE_BIN="$W/aster-dcs-probe"
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror -I src -o "$PROBE_BIN" "$W/probe.cpp"
ok 'probe v4 regenerated + strict build'

# ---------------------------------------------------------------------------
echo "[1/6] hit reuse (probe counts: misses == files, copyUs <= 1 ms)"
GREET="$HOME/workspace/parallel-build/bench-greet"
BIG="$HOME/workspace/parallel-build/bench-big"
[ -d "$GREET" ] || fail "fixture missing: $GREET"
[ -d "$BIG" ] || fail "fixture missing: $BIG"
d="$W/probe-greet"; rm -rf "$d"; cp -r "$GREET" "$d"; rm -rf "$d/build" "$d/gmon.out"
probe_build "probe greet clean j1" "$d" "probe-greet"
[ "$(probe_field "$W/probe-greet.diagprobe" misses)" = 21 ] || fail "greet misses != 21: $(cat "$W/probe-greet.diagprobe")"
[ "$(probe_field "$W/probe-greet.diagprobe" distinctMissPaths)" = 21 ] || fail "greet distinctMissPaths != 21"
[ "$(probe_field "$W/probe-greet.diagprobe" hits)" = 2329 ] || fail "greet hits != 2329: $(cat "$W/probe-greet.diagprobe")"
# copyUs times the pointer assignment itself, not a copy: the bound is
# 1 ms/build (§1 baseline was ~129 ms here). == 0 is wrong: the big
# fixture measures 8-60 us of timer granularity noise.
[ "$(probe_field "$W/probe-greet.diagprobe" copyUs)" -le 1000 ] || fail "greet copyUs > 1000 us: $(cat "$W/probe-greet.diagprobe")"
ok "probe greet clean: misses=21 distinct=21 hits=2329 copyUs=$(probe_field "$W/probe-greet.diagprobe" copyUs) us"
d="$W/probe-big"; rm -rf "$d"; cp -r "$BIG" "$d"; rm -rf "$d/build"
probe_build "probe big clean j1" "$d" "probe-big"
[ "$(probe_field "$W/probe-big.diagprobe" misses)" = 81 ] || fail "big misses != 81: $(cat "$W/probe-big.diagprobe")"
[ "$(probe_field "$W/probe-big.diagprobe" distinctMissPaths)" = 81 ] || fail "big distinctMissPaths != 81"
[ "$(probe_field "$W/probe-big.diagprobe" hits)" = 18649 ] || fail "big hits != 18649: $(cat "$W/probe-big.diagprobe")"
[ "$(probe_field "$W/probe-big.diagprobe" copyUs)" -le 1000 ] || fail "big copyUs > 1000 us: $(cat "$W/probe-big.diagprobe")"
ok "probe big clean: misses=81 distinct=81 hits=18649 copyUs=$(probe_field "$W/probe-big.diagprobe" copyUs) us"
# Second build on the greet copy (build/ intact): 0 compiled, and each
# file is still read exactly once — misses == 21, not per-TU.
d="$W/probe-greet"
(cd "$d" && ASTER_KEY_DIR="$ASTER_KEY_DIR" DIAGPROBE_FILE="$W/probe-greet-2nd.diagprobe" "$PROBE_BIN" build --jobs 1 --verbose > "$W/probe-greet-2nd.out" 2> "$W/probe-greet-2nd.err") || fail "probe greet second build failed (see $W/probe-greet-2nd.err)"
grep -q '(0 compiled, 21 reused)' "$W/probe-greet-2nd.out" || fail "second build did not report (0 compiled, 21 reused)"
[ "$(probe_field "$W/probe-greet-2nd.diagprobe" misses)" = 21 ] || fail "second-build misses != 21: $(cat "$W/probe-greet-2nd.diagprobe")"
[ "$(probe_field "$W/probe-greet-2nd.diagprobe" distinctMissPaths)" = 21 ] || fail "second-build distinctMissPaths != 21"
ok 'probe greet second build: misses=21 (once per file, not per TU)'

# ---------------------------------------------------------------------------
echo "[2/6] file change invalidates the echo"
ERR_ROOT="$HOME/workspace/parallel-build"
[ -d "$ERR_ROOT/errproj" ] || fail "fixture missing: $ERR_ROOT/errproj"
d="$W/mod-errproj"; rm -rf "$d"; cp -r "$ERR_ROOT/errproj" "$d"; rm -rf "$d/build"
err_compare "errproj orig j1" "$d" j1 --verbose
cp "$W/e-new.err" "$W/mod-orig.err"
grep -qF 'extern fnX paint_scale_x(p: i32) : i32;' "$W/mod-orig.err" || fail "orig echo lacks the fnX line"
python3 - "$d" <<'PY'
import os, sys
p = os.path.join(sys.argv[1], 'framework/src/aui_drawprim.ast')
s = open(p).read()
assert 'extern fnX paint_scale_x(p: i32) : i32;' in s
open(p, 'w').write(s.replace('extern fnX paint_scale_x(p: i32) : i32;',
                             'extern fnY paint_scale_xyzw(p: i32) : i32;'))
PY
err_compare "errproj modified (size changed) j1" "$d" j1 --verbose
grep -qF 'extern fnY paint_scale_xyzw(p: i32) : i32;' "$W/e-new.err" || fail "modified echo lacks the new fnY line"
grep -qF 'fnX paint_scale_x' "$W/e-new.err" && fail "modified echo still shows the old fnX line"
ok 'modified echo uses new content (size changed)'
python3 - "$d" <<'PY'
import os, sys
p = os.path.join(sys.argv[1], 'framework/src/aui_drawprim.ast')
s = open(p).read()
open(p, 'w').write(s.replace('extern fnY paint_scale_xyzw(p: i32) : i32;',
                             'extern fnX paint_scale_x(p: i32) : i32;'))
PY
err_compare "errproj reverted j1" "$d" j1 --verbose
cmp -s "$W/e-new.err" "$W/mod-orig.err" || fail "reverted stderr differs from original stderr"
ok 'reverted echo restores original bytes'

# ---------------------------------------------------------------------------
echo "[3/6] error parity: byte-identical stderr (3 cases + dual-error switch)"
err_compare "errproj cross-file parse j1" "$d" j1 --verbose
err_compare "errproj cross-file parse par" "$d" par --verbose
# (b) single-file type error, with line echo + caret.
write_type_fixture() { # $1 = dir
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
d="$W/err-type"; write_type_fixture "$d"
err_compare "single-file type error j1" "$d" j1 --verbose
grep -qF 'src/main.ast:2:1: error: return type mismatch in function main' "$W/e-new.err" || fail "type error location wrong (see $W/e-new.err)"
grep -qF '返回 "独一文字"' "$W/e-new.err" || fail "type error echo lacks the source line"
grep -q '    ^' "$W/e-new.err" || fail "type error echo lacks the caret"
ok 'type error echo + caret belong to src/main.ast'
# (c) main-file parse error (bench-greet copy, 方法 -> 方法X in main).
d="$W/err-parse"; rm -rf "$d"; cp -r "$GREET" "$d"; rm -rf "$d/build" "$d/gmon.out"
python3 - "$d" <<'PY'
import os, sys
p = os.path.join(sys.argv[1], 'src/main.ast')
s = open(p).read()
assert s.count('方法 ANativeActivity_onCreate') == 1
open(p, 'w').write(s.replace('方法 ANativeActivity_onCreate', '方法X ANativeActivity_onCreate', 1))
PY
err_compare "main-file parse error j1" "$d" j1 --verbose
grep -qF 'src/main.ast:74:1: error: [A-011]' "$W/e-new.err" || fail "main parse error location wrong (see $W/e-new.err)"
grep -qF '方法X ANativeActivity_onCreate' "$W/e-new.err" || fail "main parse echo lacks the 方法X line"
ok 'main-file parse echo + caret'
# (d) dual-error switch: two parse errors in different files; first the
# a.ast error is reported with a's echo, then after fixing a.ast the
# b.ast error is reported with b's echo. Only the first error is ever
# printed (diagnose reports the first error), so the switch is proven
# across the two stages, not within one stderr.
write_dual_fixture() { # $1 = dir
    dd=$1; rm -rf "$dd"; mkdir -p "$dd/src"
    cat > "$dd/aster.proj" <<'PROJ'
kind exe
[language]
default = "zh"
src/a.ast
src/b.ast
src/alloc.ast
PROJ
    cat > "$dd/src/a.ast" <<'SRC'
方法 甲(): 整数
返回 1
方法X 坏甲(): 整数
返回 2
结束 方法
SRC
    cat > "$dd/src/b.ast" <<'SRC'
方法 乙(): 整数
返回 1
方法X 坏乙(): 整数
返回 2
结束 方法
SRC
    cat > "$dd/src/alloc.ast" <<'SRC'
方法 alloc(数量: 整数): 指针
返回 0
结束 方法
SRC
}
d="$W/err-dual"; write_dual_fixture "$d"
err_compare "dual-error stage 1 (a.ast) j1" "$d" j1 --verbose
grep -qF 'src/a.ast:3:1: error' "$W/e-new.err" || fail "stage 1 location is not a.ast:3:1 (see $W/e-new.err)"
grep -qF '方法X 坏甲(): 整数' "$W/e-new.err" || fail "stage 1 echo is not a.ast's line"
grep -qF '坏乙' "$W/e-new.err" && fail "stage 1 echo leaks the b.ast error"
ok 'dual-error stage 1: first error, echo belongs to a.ast'
cat > "$d/src/a.ast" <<'SRC'
方法 甲(): 整数
返回 1
结束 方法
方法 坏甲(): 整数
返回 2
结束 方法
SRC
err_compare "dual-error stage 2 (b.ast) j1" "$d" j1 --verbose
grep -qF 'src/b.ast:3:1: error' "$W/e-new.err" || fail "stage 2 location is not b.ast:3:1 (see $W/e-new.err)"
grep -qF '方法X 坏乙(): 整数' "$W/e-new.err" || fail "stage 2 echo is not b.ast's line"
grep -qF '坏甲' "$W/e-new.err" && fail "stage 2 echo leaks the a.ast error"
ok 'dual-error stage 2: second error, echo belongs to b.ast'

# ---------------------------------------------------------------------------
echo "[4/6] daemon on/off: products byte-identical (APK, manifest, stderr)"
write_daemon_fixture() { # $1 = dir
    dd=$1; rm -rf "$dd"; mkdir -p "$dd/src" "$dd/build/.cache"
    cat > "$dd/aster.proj" <<'PROJ'
kind apk
package com.example.dcs
name dcs
label 计数器
src/main.ast
src/counter.ast
src/extra1.ast
src/extra2.ast
PROJ
    cat > "$dd/src/counter.ast" <<'SRC'
变量 计数: 整数 = 41
方法 增加(步长: 整数): 整数
    计数 = 计数 + 步长
    返回 计数
结束 方法
SRC
    cat > "$dd/src/extra1.ast" <<'SRC'
变量 备用一: 整数 = 1
方法 取一(): 整数
    返回 备用一
结束 方法
SRC
    cat > "$dd/src/extra2.ast" <<'SRC'
变量 备用二: 整数 = 2
方法 取二(): 整数
    返回 备用二
结束 方法
SRC
    cat > "$dd/src/main.ast" <<'SRC'
方法 ANativeActivity_onCreate(活动: 指针, 保存状态: 指针, 保存大小: 整数): 整数
    返回 增加(1) + 取一() + 取二()
结束 方法
SRC
}
d="$W/daemon-proj"; write_daemon_fixture "$d"
SOCKDIR="$d/build/.cache"
stop_daemon() { "$ASTER_BIN" serve stop --project "$d" > /dev/null 2>&1 || true; }
trap stop_daemon EXIT
setsid "$ASTER_BIN" serve --project "$d" --socket-dir "$SOCKDIR" --detached > "$W/daemon-serve.log" 2>&1 < /dev/null &
sleep 2
"$ASTER_BIN" serve status --project "$d" > "$W/daemon-status.log" 2>&1 || { echo "FAIL: daemon did not come up:" >&2; cat "$W/daemon-serve.log" >&2; exit 1; }
grep -q 'running (pid ' "$W/daemon-status.log" || fail "daemon status did not report running"
ok 'daemon up (serve status)'
run_logged "$W/dm-req1.rc" "$W/dm-req1.out" "$W/dm-req1.err" "$d" env ASTER_KEY_DIR="$ASTER_KEY_DIR" ASTER_DAEMON=1 "$ASTER_BIN" build --verbose
[ "$(cat "$W/dm-req1.rc")" = 0 ] || fail "daemon req1 failed (see $W/dm-req1.err)"
grep -q '(4 compiled, 0 reused)' "$W/dm-req1.out" || fail "daemon req1 did not compile all 4 sources"
manifest "$d" > "$W/dm-req1.manifest"
sha_file "$d/build/dcs.apk" > "$W/dm-req1.apk"
run_logged "$W/dm-req2.rc" "$W/dm-req2.out" "$W/dm-req2.err" "$d" env ASTER_KEY_DIR="$ASTER_KEY_DIR" ASTER_DAEMON=1 "$ASTER_BIN" build --verbose --no-cache
[ "$(cat "$W/dm-req2.rc")" = 0 ] || fail "daemon req2 (--no-cache) failed (see $W/dm-req2.err)"
manifest "$d" > "$W/dm-req2.manifest"
sha_file "$d/build/dcs.apk" > "$W/dm-req2.apk"
cmp -s "$W/dm-req1.apk" "$W/dm-req2.apk" || fail "daemon req1 vs req2 APK differs"
cmp -s "$W/dm-req1.manifest" "$W/dm-req2.manifest" || fail "daemon req1 vs req2 build/ manifest differs"
cmp -s "$W/dm-req1.err" "$W/dm-req2.err" || fail "daemon req1 vs req2 stderr differs"
ok 'daemon req1 vs req2 --no-cache: APK + manifest + stderr identical'
stop_daemon
trap - EXIT
rm -rf "$d/build"
run_logged "$W/dm-cold.rc" "$W/dm-cold.out" "$W/dm-cold.err" "$d" env ASTER_KEY_DIR="$ASTER_KEY_DIR" "$ASTER_BIN" build --verbose --no-daemon
[ "$(cat "$W/dm-cold.rc")" = 0 ] || fail "cold build (--no-daemon) failed (see $W/dm-cold.err)"
manifest "$d" > "$W/dm-cold.manifest"
sha_file "$d/build/dcs.apk" > "$W/dm-cold.apk"
cmp -s "$W/dm-req1.apk" "$W/dm-cold.apk" || fail "daemon req1 vs cold APK differs"
cmp -s "$W/dm-req1.manifest" "$W/dm-cold.manifest" || fail "daemon req1 vs cold build/ manifest differs"
cmp -s "$W/dm-req1.err" "$W/dm-cold.err" || fail "daemon req1 vs cold stderr differs"
norm_eq "$W/dm-req1.out" "$W/dm-cold.out" || fail "daemon req1 vs cold stdout differs beyond ms (see $W/dm-req1.out $W/dm-cold.out)"
ok 'daemon req1 vs cold --no-daemon: APK + manifest + stderr + stdout identical'

# ---------------------------------------------------------------------------
echo "[5/6] two test programs in one process, each error echoes its own file"
write_test_fixture() { # $1 = dir
    dd=$1; rm -rf "$dd"; mkdir -p "$dd/src" "$dd/tests"
    cat > "$dd/aster.proj" <<'PROJ'
kind exe
[language]
default = "zh"
src/main.ast
test tests/t1.ast
test tests/t2.ast
PROJ
    cat > "$dd/src/main.ast" <<'SRC'
方法 启动方法(): 整数
返回 0
结束 方法
SRC
    cat > "$dd/tests/t1.ast" <<'SRC'
方法 加一(值: 整数, 步: 整数): 整数
返回 值 + 步
结束 方法
方法 启动方法(): 整数
返回 加一(41) - 42
结束 方法
SRC
    cat > "$dd/tests/t2.ast" <<'SRC'
方法 加二(值: 整数, 步: 整数): 整数
返回 值 + 步
结束 方法
方法 启动方法(): 整数
返回 加二(41) - 42
结束 方法
SRC
}
d="$W/test-two"; write_test_fixture "$d"
test_compare "aster test stage 1 (t1 error)" "$d"
grep -qF 'tests/t1.ast:5:4: error: function pointer expects 2 argument(s), got 1' "$W/tt-new.err" || fail "stage 1 error is not t1.ast:5:4 (see $W/tt-new.err)"
grep -qF '返回 加一(41) - 42' "$W/tt-new.err" || fail "stage 1 echo is not t1's line"
grep -qF '加二' "$W/tt-new.err" && fail "stage 1 echo leaks the t2 error"
ok 'aster test stage 1: t1 error echoes t1 only'
python3 - "$d" <<'PY'
import os, sys
p = os.path.join(sys.argv[1], 'tests/t1.ast')
s = open(p).read()
open(p, 'w').write(s.replace('加一(41) - 42', '加一(41, 1) - 42'))
PY
test_compare "aster test stage 2 (t2 error)" "$d"
grep -qF 'PASS tests/t1.ast' "$W/tt-new.out" || fail "stage 2 did not PASS t1 (see $W/tt-new.out)"
grep -qF 'tests/t2.ast:5:4: error: function pointer expects 2 argument(s), got 1' "$W/tt-new.err" || fail "stage 2 error is not t2.ast:5:4 (see $W/tt-new.err)"
grep -qF '返回 加二(41) - 42' "$W/tt-new.err" || fail "stage 2 echo is not t2's line"
grep -qF '加一(41) - 42' "$W/tt-new.err" && fail "stage 2 echo leaks the t1 error"
ok 'aster test stage 2: t2 error echoes t2 only'

# ---------------------------------------------------------------------------
echo "[6/6] unreadable / missing diagnostic file: message only, no caret"
# (a) include of a nonexistent file.
write_inc_fixture() { # $1 = dir
    dd=$1; rm -rf "$dd"; mkdir -p "$dd/src"
    cat > "$dd/aster.proj" <<'PROJ'
kind exe
[language]
default = "en"
src/main.ast
PROJ
    cat > "$dd/src/main.ast" <<'SRC'
include "gone.ast";
fn main(): i32 {
return 0;
}
SRC
}
d="$W/err-inc-missing"; write_inc_fixture "$d"
err_compare "missing include j1" "$d" j1
grep -qF "cannot find imported file 'src/gone.ast'" "$W/e-new.err" || fail "missing-include message wrong (see $W/e-new.err)"
grep -q '^ *\^$' "$W/e-new.err" && fail "missing-include stderr has a caret"
ok 'missing include: message only, no caret'
# (b) included file itself has a parse error: the include catch point fills
# the owned fallback from the text already read, so the echo + caret come
# from the included file.
cat > "$d/src/gone.ast" <<'SRC'
fn broken( : i32 {
return 1;
}
SRC
err_compare "bad include file j1" "$d" j1
grep -qF 'src/gone.ast:1:12: error: [A-011]' "$W/e-new.err" || fail "bad-include location wrong (see $W/e-new.err)"
grep -qF 'fn broken( : i32 {' "$W/e-new.err" || fail "bad-include echo lacks the included file's line"
grep -q '    ^' "$W/e-new.err" || fail "bad-include echo lacks the caret"
ok 'bad include: echo + caret belong to the included file (owned fallback)'
# (c) build OK, delete a source file, rebuild at once: missing source.
write_del_fixture() { # $1 = dir
    dd=$1; rm -rf "$dd"; mkdir -p "$dd/src"
    cat > "$dd/aster.proj" <<'PROJ'
kind exe
[language]
default = "zh"
src/main.ast
src/extra.ast
PROJ
    cat > "$dd/src/main.ast" <<'SRC'
方法 启动方法(): 整数
返回 取一()
结束 方法
SRC
    cat > "$dd/src/extra.ast" <<'SRC'
方法 取一(): 整数
返回 1
结束 方法
SRC
}
d="$W/err-deleted"; write_del_fixture "$d"
run_logged "$W/del-ok.rc" "$W/del-ok.out" "$W/del-ok.err" "$d" env ASTER_KEY_DIR="$ASTER_KEY_DIR" "$ASTER_BIN" build --jobs 1
[ "$(cat "$W/del-ok.rc")" = 0 ] || fail "setup build before delete failed (see $W/del-ok.err)"
rm "$d/src/extra.ast"
err_compare "deleted source j1" "$d" j1
grep -qF 'aster build: missing source src/extra.ast' "$W/e-new.err" || fail "deleted-source message wrong (see $W/e-new.err)"
grep -q '^ *\^$' "$W/e-new.err" && fail "deleted-source stderr has a caret"
ok 'deleted source: message only, no caret'
# (d) test-program parse error is reported as <source>: no file can be
# loaded, so the pointer stays null and only the message is printed.
d="$W/test-source"; write_test_fixture "$d"
python3 - "$d" <<'PY'
import os, sys
p = os.path.join(sys.argv[1], 'tests/t1.ast')
s = open(p).read()
open(p, 'w').write(s.replace('方法 加一(值: 整数, 步: 整数): 整数',
                             '方法X 加一(值: 整数, 步: 整数): 整数', 1))
PY
test_compare "aster test <source> parse error" "$d"
grep -qF 'aster: <source>:1:1: error: [A-011]' "$W/tt-new.err" || fail "<source> error location wrong (see $W/tt-new.err)"
grep -q '^ *\^$' "$W/tt-new.err" && fail "<source> stderr has a caret"
grep -qF '加一' "$W/tt-new.err" && fail "<source> stderr leaks a source line"
ok '<source> parse error: message only, no caret (null pointer branch)'

echo "PASS: diag-cache-sharing-checks: $PASS_N cases"
