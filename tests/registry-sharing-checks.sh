#!/bin/sh
# tests/registry-sharing-checks.sh
#
# Cross-TU registry sharing: the §4 probe matrix from
# ~/workspace/cold-compile/phase4-segB/registry-sharing-DECISION.md,
# as a repeatable suite. Sharing is default-off; every comparison below
# runs the build three ways and requires byte-identical products:
#
#   (a) $ASTER_BIN build --jobs 1 --registry-sharing   (serial sharing)
#   (b) $ASTER_BIN build --registry-sharing             (parallel sharing)
#   (c) cold control: $COLD_BIN build --jobs 1          (+ --no-registry-sharing
#       when $COLD_BIN is the same binary as $ASTER_BIN)
#
#   [1/7] strict rebuild + source guards + --help lists both switches
#   [2/7] R1 key-mutation matrix (14 minimal mutations on an APK fixture;
#         .o set + APK byte-compared across (a)/(b)/(c))
#   [3/7] R2 closures (closure in one TU / in several TUs / same signature
#         different captures; .o set + exe across (a)/(b)/(c))
#   [4/7] R3 D2a layout/event project (.o set + APK) and build-cn-obj
#         single-shot paths (zh + en; emitted layout code bytes)
#   [5/7] R4 class-heavy project (30 classes, 3 interfaces, 3 inheritance
#         chains; .o set + APK + .so dynamic symbols across (a)/(b)/(c))
#   [6/7] R5 aster test, two test programs with same-named methods of
#         different signatures (pass variant + error variant; outputs
#         byte-compared sharing binary vs cold binary)
#   [7/7] R6 error parity: the existing errproj/errproj2/errproj3/
#         err-strlit/err-d2a fixtures (copied, never edited in place),
#         --jobs 1 and parallel, plus duplicate-declaration errors
#         (dup-global/dup-struct/dup-alias) in both modes; stdout+stderr+rc
#         compared ms-normalised
#
# Fixtures are (re)written under $TMPD on every run (rm -rf first), so a
# second run passes exactly like the first. The R6 fixtures live outside
# the repo (~/workspace/parallel-build, ~/workspace/ms-compile/scratch)
# and are copied in; a missing one fails loudly with its path.
#
# .o comparison is by content hash, not file name: .o names embed a hash
# of the absolute project path. APKs are compared by sha256; the signing
# key is shared because ASTER_KEY_DIR is fixed below.
#
# Override points (env vars):
#   ASTER_BIN       binary under test (default $TMPD/aster-rs; rebuilt
#                   strictly from src/aster.cpp unless RS_NO_REBUILD=1)
#   ASTER_BIN_COLD  cold-control binary (default: same as ASTER_BIN, in
#                   which case the control adds --no-registry-sharing;
#                   point it at a baseline binary for a true cross-binary
#                   control — that binary must NOT get --no-registry-sharing,
#                   it predates the flag)
#   RS_NO_REBUILD=1 skip the strict rebuild, use $ASTER_BIN as-is
#   ASTER_KEY_DIR   fixed to $HOME/workspace/projects/Aster (keys live in
#                   its .aster/ directory); same key for every twin build
set -eu
. tests/lib/tmpdir.sh

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

export ASTER_KEY_DIR="$HOME/workspace/projects/Aster"
ASTER_BIN="${ASTER_BIN:-$TMPD/aster-rs}"
COLD_BIN="${ASTER_BIN_COLD:-$ASTER_BIN}"
if [ "$COLD_BIN" = "$ASTER_BIN" ]; then COLD_FLAGS="--no-registry-sharing"; else COLD_FLAGS=""; fi
W="$TMPD/rs-checks"
rm -rf "$W"; mkdir -p "$W"
PASS_N=0

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { PASS_N=$((PASS_N + 1)); printf '  %-44s %s\n' "$1" 'ok'; }
# norm <file>: timings vary run to run; everything else must match exactly.
norm() { sed -E 's/in [0-9]+ ms/in N ms/g; s/[0-9]+ ms/N ms/g' "$1"; }
# norm_eq <f1> <f2>: ms-normalised byte equality (no process substitution:
# this suite is POSIX sh).
norm_eq() { norm "$1" > "$W/n-a"; norm "$2" > "$W/n-b"; cmp -s "$W/n-a" "$W/n-b"; }
# run_logged <rcfile> <outfile> <errfile> <workdir> <cmd...>: run <cmd> in
# <workdir>, capturing rc/out/err. Failing commands are EXPECTED here
# (error fixtures), so the failure must not trip set -e: the subshell's
# failure is caught by the || list, never by -e. (dash -e kills a subshell
# at a failing simple command before any trailing 'echo $?' runs, which
# is why the rc must be captured outside the subshell.)
run_logged() {
    rl_rcfile=$1; rl_outfile=$2; rl_errfile=$3; rl_dir=$4; shift 4
    rl_rc=0
    (cd "$rl_dir" && "$@" > "$rl_outfile" 2> "$rl_errfile") || rl_rc=$?
    echo "$rl_rc" > "$rl_rcfile"
}
# osum <dir>: content-only hash of the .o set (names stripped).
osum() { (cd "$1" && { find build/.cache -name 'cn-*.o' -type f 2>/dev/null | sort | while read -r f; do sha256sum "$f"; done; } | awk '{print $1}' | sort | sha256sum | cut -d' ' -f1); }
sha_file() { sha256sum "$1" | cut -d' ' -f1; }

# triple <label> <dir> <product-relpath> [extra build flags...]:
# (a) sharing --jobs 1, (b) sharing parallel, (c) cold --jobs 1. All three
# must agree on rc; rc 0 requires identical .o contents + identical
# product; rc != 0 requires identical ms-normalised stdout+stderr.
# The builds wipe build/ in turn, so hashes are captured right after
# each build.
triple() {
    label=$1; dir=$2; product=$3; shift 3
    rm -rf "$dir/build"
    run_logged "$W/t-a.rc" "$W/t-a.out" "$W/t-a.err" "$dir" env ASTER_KEY_DIR="$ASTER_KEY_DIR" "$ASTER_BIN" build --jobs 1 --registry-sharing "$@"
    [ -f "$dir/$product" ] && [ "$(cat "$W/t-a.rc")" = 0 ] && sha_file "$dir/$product" > "$W/t-a.prod" || : > "$W/t-a.prod"
    osum "$dir" > "$W/t-a.osum"
    rm -rf "$dir/build"
    run_logged "$W/t-b.rc" "$W/t-b.out" "$W/t-b.err" "$dir" env ASTER_KEY_DIR="$ASTER_KEY_DIR" "$ASTER_BIN" build --registry-sharing "$@"
    [ -f "$dir/$product" ] && [ "$(cat "$W/t-b.rc")" = 0 ] && sha_file "$dir/$product" > "$W/t-b.prod" || : > "$W/t-b.prod"
    osum "$dir" > "$W/t-b.osum"
    rm -rf "$dir/build"
    # shellcheck disable=SC2086
    run_logged "$W/t-c.rc" "$W/t-c.out" "$W/t-c.err" "$dir" env ASTER_KEY_DIR="$ASTER_KEY_DIR" "$COLD_BIN" build --jobs 1 $COLD_FLAGS "$@"
    [ -f "$dir/$product" ] && [ "$(cat "$W/t-c.rc")" = 0 ] && sha_file "$dir/$product" > "$W/t-c.prod" || : > "$W/t-c.prod"
    osum "$dir" > "$W/t-c.osum"
    ra=$(cat "$W/t-a.rc"); rb=$(cat "$W/t-b.rc"); rc=$(cat "$W/t-c.rc")
    [ "$ra" = "$rb" ] && [ "$rb" = "$rc" ] || fail "$label: rc differs sharing-j1=$ra sharing-par=$rb cold=$rc (see $W/t-*.out|err)"
    if [ "$ra" = 0 ]; then
        cmp -s "$W/t-a.osum" "$W/t-b.osum" && cmp -s "$W/t-b.osum" "$W/t-c.osum" || fail "$label: .o contents differ (see $W/t-*.osum)"
        cmp -s "$W/t-a.prod" "$W/t-b.prod" && cmp -s "$W/t-b.prod" "$W/t-c.prod" || fail "$label: product $product differs (see $W/t-*.prod)"
        ok "$label"
    else
        norm_eq "$W/t-a.out" "$W/t-b.out" && norm_eq "$W/t-b.out" "$W/t-c.out" || fail "$label: stdout differs on error (see $W/t-*.out)"
        norm_eq "$W/t-a.err" "$W/t-b.err" && norm_eq "$W/t-b.err" "$W/t-c.err" || fail "$label: stderr differs on error (see $W/t-*.err)"
        ok "$label (error rc=$ra, identical)"
    fi
}

# cnobj_compare <label> <dir> <out-stem> [argv...]: build-cn-obj with the
# test binary vs the cold binary (single-shot callers take no sharing
# flag); compare rc, ms-normalised output, and the produced .o bytes.
cnobj_compare() {
    label=$1; dir=$2; stem=$3; shift 3
    # Both runs write to the SAME -o path (the path is echoed in stdout),
    # so the .o sha is captured immediately after each run.
    run_logged "$W/$stem.shr.rc" "$W/$stem.shr.out" "$W/$stem.shr.err" "$dir" "$ASTER_BIN" build-cn-obj "$@" -o "$W/$stem.o"
    [ "$(cat "$W/$stem.shr.rc")" = 0 ] && sha_file "$W/$stem.o" > "$W/$stem.shr.sha" || : > "$W/$stem.shr.sha"
    run_logged "$W/$stem.cold.rc" "$W/$stem.cold.out" "$W/$stem.cold.err" "$dir" "$COLD_BIN" build-cn-obj "$@" -o "$W/$stem.o"
    [ "$(cat "$W/$stem.cold.rc")" = 0 ] && sha_file "$W/$stem.o" > "$W/$stem.cold.sha" || : > "$W/$stem.cold.sha"
    ra=$(cat "$W/$stem.shr.rc"); rc=$(cat "$W/$stem.cold.rc")
    [ "$ra" = "$rc" ] || fail "$label: rc differs test=$ra cold=$rc (see $W/$stem.*.out|err)"
    norm_eq "$W/$stem.shr.out" "$W/$stem.cold.out" || fail "$label: stdout differs (see $W/$stem.*.out)"
    norm_eq "$W/$stem.shr.err" "$W/$stem.cold.err" || fail "$label: stderr differs (see $W/$stem.*.err)"
    if [ "$ra" = 0 ]; then
        cmp -s "$W/$stem.shr.sha" "$W/$stem.cold.sha" || fail "$label: .o bytes differ"
    fi
    ok "$label"
}

# err_compare <label> <dir> <mode> [argv...]: cold vs sharing build of an
# error fixture; mode j1 adds --jobs 1 to both, par adds nothing.
# Compares rc + ms-normalised stdout+stderr.
err_compare() {
    label=$1; dir=$2; mode=$3; shift 3
    if [ "$mode" = j1 ]; then jflag="--jobs 1"; else jflag=""; fi
    rm -rf "$dir/build"
    # shellcheck disable=SC2086
    run_logged "$W/e-cold.rc" "$W/e-cold.out" "$W/e-cold.err" "$dir" env ASTER_KEY_DIR="$ASTER_KEY_DIR" "$COLD_BIN" build $jflag $COLD_FLAGS "$@"
    rm -rf "$dir/build"
    # shellcheck disable=SC2086
    run_logged "$W/e-shr.rc" "$W/e-shr.out" "$W/e-shr.err" "$dir" env ASTER_KEY_DIR="$ASTER_KEY_DIR" "$ASTER_BIN" build $jflag --registry-sharing "$@"
    ra=$(cat "$W/e-cold.rc"); rb=$(cat "$W/e-shr.rc")
    [ "$ra" = "$rb" ] || fail "$label: rc differs cold=$ra sharing=$rb (see $W/e-*.out|err)"
    norm_eq "$W/e-cold.out" "$W/e-shr.out" || fail "$label: stdout differs (see $W/e-*.out)"
    norm_eq "$W/e-cold.err" "$W/e-shr.err" || fail "$label: stderr differs (see $W/e-*.err)"
    ok "$label (rc=$ra)"
}

# test_compare <label> <dir> <needle>: aster test with the test binary vs
# the cold binary (the test driver takes no sharing flag); compare rc +
# ms-normalised output, and require <needle> in the sharing output.
test_compare() {
    label=$1; dir=$2; needle=$3
    rm -rf "$dir/build"
    run_logged "$W/tt-shr.rc" "$W/tt-shr.out" "$W/tt-shr.err" "$dir" env ASTER_KEY_DIR="$ASTER_KEY_DIR" "$ASTER_BIN" test
    rm -rf "$dir/build"
    run_logged "$W/tt-cold.rc" "$W/tt-cold.out" "$W/tt-cold.err" "$dir" env ASTER_KEY_DIR="$ASTER_KEY_DIR" "$COLD_BIN" test
    ra=$(cat "$W/tt-shr.rc"); rb=$(cat "$W/tt-cold.rc")
    [ "$ra" = "$rb" ] || fail "$label: rc differs test-bin=$ra cold-bin=$rb (see $W/tt-*.out|err)"
    norm_eq "$W/tt-shr.out" "$W/tt-cold.out" || fail "$label: stdout differs (see $W/tt-*.out)"
    norm_eq "$W/tt-shr.err" "$W/tt-cold.err" || fail "$label: stderr differs (see $W/tt-*.err)"
    grep -qF -- "$needle" "$W/tt-shr.out" || grep -qF -- "$needle" "$W/tt-shr.err" || fail "$label: expected '$needle' in test output (see $W/tt-shr.out|err)"
    ok "$label (rc=$ra)"
}

# ---------------------------------------------------------------------------
echo "[1/7] strict rebuild + source guards"
if [ "${RS_NO_REBUILD:-0}" = 1 ]; then
    [ -x "$ASTER_BIN" ] || fail "RS_NO_REBUILD=1 but ASTER_BIN is not executable: $ASTER_BIN"
    printf '  %-44s %s\n' 'using prebuilt ASTER_BIN (RS_NO_REBUILD=1)' "$ASTER_BIN"
else
    ${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror -o "$ASTER_BIN" src/aster.cpp
    printf '  %-44s %s\n' 'strict rebuild' 'ok'
fi
for needle in '--registry-sharing' '--no-registry-sharing' 'registrySharing' 'cnComputeRegistryKey' 'cnBuildRegistryFront'; do
    grep -qF -- "$needle" src/aster.cpp || fail "source guard missing: $needle"
done
ok 'source guards'
"$ASTER_BIN" --help | grep -qF -- '--registry-sharing' || fail "--help lacks --registry-sharing"
"$ASTER_BIN" --help | grep -qF -- '--no-registry-sharing' || fail "--help lacks --no-registry-sharing"
ok '--help lists both switches'

# ---------------------------------------------------------------------------
# Fixture writers (embedded; the R1 base is the step-2 key-probe project,
# plus an APK header so .o + APK are both compared).
write_r1_fixture() { # $1 = dir
    d=$1; rm -rf "$d"; mkdir -p "$d/src"
    cat > "$d/aster.proj" <<'PROJ'
kind apk
package com.example.rsprobe
name rsprobe
label 探针
[language]
default = "zh"
src/main.ast
src/second.ast
src/alloc.ast
PROJ
    cat > "$d/src/main.ast" <<'SRC'
外部("my_output") 方法 输出(值: 指针): 整数
类型 数量 = 整数
结构 点
横: 整数
纵: 整数
结束 结构
接口类 可取值
方法 取值(): 整数
结束 接口类
类 基
变量 基值: 整数
方法 取值(): 整数
返回 本对象.基值
结束 方法
结束 类
类 基二
变量 基值: 整数
方法 取值(): 整数
返回 本对象.基值 + 100
结束 方法
结束 类
类 一号 : 可取值
方法 取值(): 整数
返回 11
结束 方法
结束 类
类 派生 : 基
方法 问候(): 整数
返回 7
结束 方法
结束 类
变量 计数: 整数 = 0
变量 原点: 点 = 点 { 1, 2 }
方法 加一(值: 整数): 整数
返回 值 + 1
结束 方法
方法 备用(): 整数
返回 5
结束 方法
方法 用编号(): 整数
变量 x: 数量 = 7
返回 x
结束 方法
方法 启动方法(): 整数
变量 实例: 派生 = 派生()
计数 = 加一(41) + 实例.问候() + 备用() + 用编号()
返回 计数
结束 方法
SRC
    cat > "$d/src/second.ast" <<'SRC'
方法 备用二(): 整数
返回 6
结束 方法
变量 备用计数: 整数 = 0
SRC
    cat > "$d/src/alloc.ast" <<'SRC'
方法 alloc(数量: 整数): 指针
返回 0
结束 方法
SRC
}

write_pkg_fixture() { # $1 = dir (package-file mutation case)
    d=$1; rm -rf "$d"; mkdir -p "$d/src" "$d/packages"
    cat > "$d/aster.proj" <<'PROJ'
name keypkg
[language]
default = "zh"
allowed = ["zh", "en"]
src/main.ast
PROJ
    cat > "$d/src/main.ast" <<'SRC'
@导入("external.math").别名("math")
方法 启动方法(): 整数
返回 math.add(41) - 42
结束 方法
SRC
    cat > "$d/packages/math.ast" <<'SRC'
// aster:language=en
package external.math;
fn add(value: i32): i32 {
return value + 1;
}
SRC
}

# R1 mutators (one minimal change each, ported from the step-2 key probes).
mut_sig() { python3 - "$1" <<'PY'
import os, sys
p = os.path.join(sys.argv[1], 'src/main.ast')
s = open(p).read()
s = s.replace('方法 加一(值: 整数): 整数', '方法 加一(值: 整数, 步: 整数): 整数')
s = s.replace('返回 值 + 1', '返回 值 + 步')
s = s.replace('加一(41)', '加一(41, 1)')
open(p, 'w').write(s)
PY
}
mut_add_method() { python3 - "$1" <<'PY'
import os, sys
p = os.path.join(sys.argv[1], 'src/main.ast')
s = open(p).read()
s += '方法 加二(值: 整数): 整数\n返回 值 + 2\n结束 方法\n'
open(p, 'w').write(s)
PY
}
mut_del_method() { python3 - "$1" <<'PY'
import os, sys
p = os.path.join(sys.argv[1], 'src/second.ast')
s = open(p).read()
s = s.replace('方法 备用二(): 整数\n返回 6\n结束 方法\n', '')
open(p, 'w').write(s)
PY
}
mut_dup_global() { python3 - "$1" <<'PY'
import os, sys
p = os.path.join(sys.argv[1], 'src/main.ast')
s = open(p).read()
s += '变量 计数: 整数 = 1\n'
open(p, 'w').write(s)
PY
}
mut_struct_field() { python3 - "$1" <<'PY'
import os, sys
p = os.path.join(sys.argv[1], 'src/main.ast')
s = open(p).read()
s = s.replace('纵: 整数', '纵: 整数\n高: 整数')
s = s.replace('点 { 1, 2 }', '点 { 1, 2, 3 }')
open(p, 'w').write(s)
PY
}
mut_class_inherit() { python3 - "$1" <<'PY'
import os, sys
p = os.path.join(sys.argv[1], 'src/main.ast')
s = open(p).read()
s = s.replace('类 派生 : 基', '类 派生 : 基二')
open(p, 'w').write(s)
PY
}
mut_iface_add() { python3 - "$1" <<'PY'
import os, sys
p = os.path.join(sys.argv[1], 'src/main.ast')
s = open(p).read()
s += '类 三号 : 可取值\n方法 取值(): 整数\n返回 33\n结束 方法\n结束 类\n'
open(p, 'w').write(s)
PY
}
mut_iface_del() { python3 - "$1" <<'PY'
import os, sys
p = os.path.join(sys.argv[1], 'src/main.ast')
s = open(p).read()
s = s.replace('类 一号 : 可取值\n方法 取值(): 整数\n返回 11\n结束 方法\n结束 类\n', '')
open(p, 'w').write(s)
PY
}
mut_extern_name() { python3 - "$1" <<'PY'
import os, sys
p = os.path.join(sys.argv[1], 'src/main.ast')
s = open(p).read()
s = s.replace('外部("my_output")', '外部("my_output2")')
open(p, 'w').write(s)
PY
}
mut_alias_type() { python3 - "$1" <<'PY'
import os, sys
p = os.path.join(sys.argv[1], 'src/main.ast')
s = open(p).read()
s = s.replace('类型 数量 = 整数', '类型 数量 = 长整数')
s = s.replace('方法 用编号(): 整数', '方法 用编号(): 长整数')
s = s.replace(' + 用编号()', '')
open(p, 'w').write(s)
PY
}
mut_constructed() { python3 - "$1" <<'PY'
import os, sys
p = os.path.join(sys.argv[1], 'src/main.ast')
s = open(p).read()
s = s.replace('变量 实例: 派生 = 派生()', '变量 实例: 基二 = 基二()')
s = s.replace('实例.问候()', '实例.取值()')
open(p, 'w').write(s)
PY
}
mut_lang_config() { python3 - "$1" <<'PY'
import os, sys
d = sys.argv[1]
p = os.path.join(d, 'aster.proj')
s = open(p).read()
s = s.replace('default = "zh"', 'default = "zh"\n"src/second.ast" = "en"')
open(p, 'w').write(s)
q = os.path.join(d, 'src/second.ast')
open(q, 'w').write('fn spare2(): i32 { return 6; }\nlet spare_count: i32 = 0;\n')
PY
}
mut_comment() { python3 - "$1" <<'PY'
import os, sys
p = os.path.join(sys.argv[1], 'src/main.ast')
s = open(p).read()
s += '// 探针注释：只改注释，不改声明\n'
open(p, 'w').write(s)
PY
}
mut_package_file() { python3 - "$1" <<'PY'
import os, sys
p = os.path.join(sys.argv[1], 'packages/math.ast')
s = open(p).read()
s = s.replace('return value + 1;', 'return value + 2;')
open(p, 'w').write(s)
PY
}

echo "[2/7] R1 key-mutation matrix (.o + APK, sharing-j1 vs sharing-par vs cold)"
r1_case() { # $1 = tag, $2 = mutator function name
    d="$W/r1-$1"; write_r1_fixture "$d"; "$2" "$d"
    triple "R1 $1" "$d" "build/rsprobe.apk"
}
r1_case sig mut_sig
r1_case add-method mut_add_method
r1_case del-method mut_del_method
r1_case dup-global mut_dup_global
r1_case struct-field mut_struct_field
r1_case class-inherit mut_class_inherit
r1_case iface-add mut_iface_add
r1_case iface-del mut_iface_del
r1_case extern-name mut_extern_name
r1_case alias-type mut_alias_type
r1_case constructed mut_constructed
r1_case lang-config mut_lang_config
r1_case comment-only mut_comment
d="$W/r1-package-file"; write_pkg_fixture "$d"; mut_package_file "$d"
triple "R1 package-file" "$d" "build/keypkg" --module-dir packages

# ---------------------------------------------------------------------------
echo "[3/7] R2 closures (.o + exe, sharing-j1 vs sharing-par vs cold)"
write_closure_fixture() { # $1 = dir
    d=$1; rm -rf "$d"; mkdir -p "$d/src"
    cat > "$d/aster.proj" <<'PROJ'
name closureprobe
[language]
default = "zh"
src/main.ast
src/a.ast
src/b.ast
src/alloc.ast
PROJ
    cat > "$d/src/main.ast" <<'SRC'
方法 启动方法(): 整数
变量 步长: 整数 = 2
变量 回调: 闭包(整数): 整数 = 方法 [步长] (数值: 整数): 整数
返回 数值 + 步长
结束 方法
返回 回调(40) + 用甲() + 用乙()
结束 方法
SRC
    cat > "$d/src/a.ast" <<'SRC'
方法 用甲(): 整数
变量 步长: 整数 = 10
变量 回调: 闭包(整数): 整数 = 方法 [步长] (数值: 整数): 整数
返回 数值 + 步长
结束 方法
返回 回调(30)
结束 方法
SRC
    cat > "$d/src/b.ast" <<'SRC'
方法 用乙(): 整数
变量 步长: 整数 = 100
变量 回调: 闭包(整数): 整数 = 方法 [步长] (数值: 整数): 整数
返回 数值 + 步长
结束 方法
变量 直调: 闭包(整数): 整数 = 方法 [] (数值: 整数): 整数
返回 数值 + 1
结束 方法
返回 回调(0) + 直调(41)
结束 方法
SRC
    cat > "$d/src/alloc.ast" <<'SRC'
方法 alloc(数量: 整数): 指针
返回 0
结束 方法
SRC
}
d="$W/r2-closure"; write_closure_fixture "$d"
triple "R2 closures" "$d" "build/closureprobe"

# ---------------------------------------------------------------------------
echo "[4/7] R3 D2a layout/event (.o + APK, then build-cn-obj single-shot)"
# NOTE (pre-existing, baseline-verified, not a sharing regression): in a
# project build a synthesised layout method cannot be called by source
# name ("unknown variable: 页一", reproduced with the c5a953c baseline
# binary, sharing on and off) and a layout/event-only TU emits an empty
# .o. The project part below therefore guards registry divergence
# (a double synthesis would fail loudly; a stale front would change the
# registered signatures) while the single-shot part compares the actual
# emitted layout code bytes.
write_d2a_fixture() { # $1 = dir
    d=$1; rm -rf "$d"; mkdir -p "$d/src"
    cat > "$d/aster.proj" <<'PROJ'
kind apk
package com.example.d2aprobe
name d2aprobe
label 布局探针
[language]
default = "zh"
src/app.ast
src/page.ast
PROJ
    cat > "$d/src/app.ast" <<'SRC'
结构 应用
计数: 整数
结束 结构
变量 g_app: 应用 = 应用 { 0 }
外部("aui_column") 方法 列(键: 整数): 整数
外部("aui_row") 方法 行(键: 整数): 整数
外部("aui_label") 方法 标签(键: 整数, 文本: 指针): 整数
外部("aui_button") 方法 按钮(键: 整数, 文本: 指针, 回调: 方法(指针): 整数, 用户: 指针): 整数
外部("aui_text_i32") 方法 数字(键: 整数, 值: 整数): 整数
外部("aui_pad") 方法 边距(尺寸: 整数): 整数
外部("aui_gap") 方法 间距(尺寸: 整数): 整数
外部("aui_end") 方法 结束节点(): 整数
方法 启动方法(): 整数
返回 g_app.计数 + 42
结束 方法
SRC
    cat > "$d/src/page.ast" <<'SRC'
事件 加:被单击() {
g_app.计数 = g_app.计数 + 1
}
事件 减:被单击() {
g_app.计数 = g_app.计数 - 1
}
布局 页一(s: 指针<应用>, 用户: 指针): 视图 {
列 主列, 内边距(20), 间隙(16) {
标签 标题, 指针("计数器")
行 按钮行, 间隙(12) {
按钮 减, 指针("-")
数字 计数, s.计数
按钮 加, 指针("+")
}
}
}
SRC
}
d="$W/r3-d2a"; write_d2a_fixture "$d"
triple "R3 d2a project" "$d" "build/d2aprobe.apk"
# Single-shot: the concatenated file (stub + layout + events) emits the
# layout method and the event callbacks; compare the .o bytes.
cat "$d/src/app.ast" "$d/src/page.ast" > "$W/r3-one-zh.ast"
cnobj_compare "R3 build-cn-obj zh" "$W" "r3-zh" "$W/r3-one-zh.ast"
cat > "$W/r3-one-en.ast" <<'SRC'
struct App {
    count: i32
}
let g_app: App = App { 0 };
extern fn aui_column(key: i32) : i32;
extern fn aui_row(key: i32) : i32;
extern fn aui_label(key: i32, text: ptr) : i32;
extern fn aui_button(key: i32, text: ptr, cb: fn(ptr): i32, user: ptr) : i32;
extern fn aui_text_i32(key: i32, value: i32) : i32;
extern fn aui_pad(dp: i32) : i32;
extern fn aui_gap(dp: i32) : i32;
extern fn aui_end() : i32;
fn main(): i32 {
return g_app.count + 42;
}
event Inc:tap() {
    g_app.count = g_app.count + 1;
}
event Dec:tap() {
    g_app.count = g_app.count - 1;
}
layout page_one(s: ptr<App>, user: ptr) : View {
    Column MainCol, Padding(20), Gap(16) {
        Label Title, ptr("Counter")
        Row ButtonRow, Gap(12) {
            Button Dec, ptr("-")
            Number Count, s.count
            Button Inc, ptr("+")
        }
    }
}
SRC
cnobj_compare "R3 build-cn-obj en" "$W" "r3-en" --language en "$W/r3-one-en.ast"

# ---------------------------------------------------------------------------
echo "[5/7] R4 class-heavy project (.o + APK + .so exports)"
# Generated equivalent of the step-2 probes/classheavy project: 30 classes
# in 3 inheritance chains (10 each), 3 interfaces, 9 interface tables,
# 30 class vtables; roots implement one interface, derived classes
# @重写 the three interface methods; fields only on roots.
gen_classheavy() { # $1 = dir
    python3 - "$1" <<'PY'
import os, sys
d = sys.argv[1]
os.makedirs(d + '/src', exist_ok=True)
ifaces = ['接口甲', '接口乙', '接口丙']
imethods = [['取值甲', '取乙甲', '取丙甲'], ['取值乙', '取乙乙', '取丙乙'], ['取值丙', '取乙丙', '取丙丙']]
with open(d + '/src/ifaces.ast', 'w') as f:
    for g in range(3):
        f.write('接口类 %s\n' % ifaces[g])
        for m in imethods[g]:
            f.write('方法 %s(): 整数\n' % m)
        f.write('结束 接口类\n')
for cf in range(10):
    lines = []
    for k in range(3):
        i = cf * 3 + k
        g = i // 10
        r = i % 10
        if r < 3:
            lines.append('类 类%d : %s' % (i, ifaces[g]))
            lines.append('变量 值: 整数')
            override = False
        else:
            base = g * 10 + ((r - 3) % 3)
            lines.append('类 类%d : 类%d' % (i, base))
            override = True
        for j, m in enumerate(imethods[g]):
            if override:
                lines.append('@重写')
            lines.append('方法 %s(): 整数' % m)
            lines.append('返回 本对象.值 + %d' % (i * 10 + j))
            lines.append('结束 方法')
        for k2 in range(5):
            lines.append('方法 本法%d_%d(): 整数' % (i, k2))
            lines.append('返回 本对象.值 + %d' % (i * 100 + k2))
            lines.append('结束 方法')
        lines.append('结束 类')
    with open(d + '/src/c%d.ast' % cf, 'w') as f:
        f.write('\n'.join(lines) + '\n')
with open(d + '/src/main.ast', 'w') as f:
    f.write('方法 启动方法(): 整数\n变量 a: 类0 = 类0()\n变量 b: 类10 = 类10()\n变量 c: 类20 = 类20()\n返回 a.取值甲() + b.取值乙() + c.取值丙()\n结束 方法\n')
with open(d + '/src/alloc.ast', 'w') as f:
    f.write('方法 alloc(数量: 整数): 指针\n返回 0\n结束 方法\n')
srcs = '\n'.join(['src/alloc.ast', 'src/ifaces.ast'] + ['src/c%d.ast' % cf for cf in range(10)] + ['src/main.ast'])
with open(d + '/aster.proj', 'w') as f:
    f.write('kind apk\npackage com.example.classheavy\nname classheavy\nlabel 类重\n[language]\ndefault = "zh"\n' + srcs + '\n')
PY
}
# so_exports <dir>: sorted dynamic symbols of the built .so.
so_exports() { readelf --dyn-syms -W "$1/build/.cache/classheavy.so" | awk '$4 == "FUNC" || $4 == "OBJECT" {print $8}' | sort; }
d="$W/r4-classheavy"; rm -rf "$d"; gen_classheavy "$d"
triple "R4 class-heavy" "$d" "build/classheavy.apk"
# The triple() above already compared .o + APK across the three builds;
# the .so export table needs its own pass because triple() wipes build/
# between runs. Rebuild each way once more and compare exports.
(cd "$d" && rm -rf build && ASTER_KEY_DIR="$ASTER_KEY_DIR" "$ASTER_BIN" build --jobs 1 --registry-sharing > "$W/r4-a.log" 2>&1) || fail "R4 rebuild sharing-j1 failed (see $W/r4-a.log)"
so_exports "$d" > "$W/r4-a.exp"
(cd "$d" && rm -rf build && ASTER_KEY_DIR="$ASTER_KEY_DIR" "$ASTER_BIN" build --registry-sharing > "$W/r4-b.log" 2>&1) || fail "R4 rebuild sharing-par failed (see $W/r4-b.log)"
so_exports "$d" > "$W/r4-b.exp"
# shellcheck disable=SC2086
(cd "$d" && rm -rf build && ASTER_KEY_DIR="$ASTER_KEY_DIR" "$COLD_BIN" build --jobs 1 $COLD_FLAGS > "$W/r4-c.log" 2>&1) || fail "R4 rebuild cold failed (see $W/r4-c.log)"
so_exports "$d" > "$W/r4-c.exp"
cmp -s "$W/r4-a.exp" "$W/r4-b.exp" && cmp -s "$W/r4-b.exp" "$W/r4-c.exp" || fail "R4 .so exports differ (see $W/r4-*.exp)"
ok "R4 .so exports ($(wc -l < "$W/r4-a.exp" | tr -d ' ') symbols)"

# ---------------------------------------------------------------------------
echo "[6/7] R5 aster test (same-named method, different signatures)"
write_r5_fixture() { # $1 = dir, $2 = variant (pass|err)
    d=$1; variant=$2; rm -rf "$d"; mkdir -p "$d/src" "$d/tests"
    cat > "$d/aster.proj" <<'PROJ'
kind exe
[language]
default = "zh"
src/main.ast
test tests/t1.ast
test tests/t2.ast
PROJ
    cat > "$d/src/main.ast" <<'SRC'
方法 启动方法(): 整数
返回 0
结束 方法
SRC
    cat > "$d/tests/t1.ast" <<'SRC'
方法 加一(值: 整数): 整数
返回 值 + 1
结束 方法
方法 启动方法(): 整数
返回 加一(41) - 42
结束 方法
SRC
    if [ "$variant" = err ]; then
        cat > "$d/tests/t2.ast" <<'SRC'
方法 加一(值: 整数, 步: 整数): 整数
返回 值 + 步
结束 方法
方法 启动方法(): 整数
返回 加一(41) - 42
结束 方法
SRC
    else
        cat > "$d/tests/t2.ast" <<'SRC'
方法 加一(值: 整数, 步: 整数): 整数
返回 值 + 步
结束 方法
方法 启动方法(): 整数
返回 加一(41, 1) - 42
结束 方法
SRC
    fi
}
d="$W/r5-pass"; write_r5_fixture "$d" pass
test_compare "R5 test pass" "$d" "2 tests, 0 failed"
d="$W/r5-err"; write_r5_fixture "$d" err
test_compare "R5 test err" "$d" "function pointer expects 2 argument(s), got 1"

# ---------------------------------------------------------------------------
echo "[7/7] R6 error parity (existing fixtures, --jobs 1 and parallel)"
ERR_ROOT="$HOME/workspace/parallel-build"
MS_ROOT="$HOME/workspace/ms-compile/scratch"
for fx in "$ERR_ROOT/errproj" "$ERR_ROOT/errproj2" "$ERR_ROOT/errproj3" "$MS_ROOT/err-strlit" "$MS_ROOT/err-d2a"; do
    [ -d "$fx" ] || fail "R6 fixture missing: $fx"
done
copy_fixture() { # $1 = src, $2 = dst: copy and drop any stale build/
    rm -rf "$2"; cp -r "$1" "$2"; rm -rf "$2/build"
}
d="$W/r6-errproj"; copy_fixture "$ERR_ROOT/errproj" "$d"
err_compare "R6 errproj j1" "$d" j1 --verbose
err_compare "R6 errproj par" "$d" par --verbose
d="$W/r6-errproj2"; copy_fixture "$ERR_ROOT/errproj2" "$d"
err_compare "R6 errproj2 j1" "$d" j1 --verbose
d="$W/r6-errproj3"; copy_fixture "$ERR_ROOT/errproj3" "$d"
err_compare "R6 errproj3 j1" "$d" j1 --verbose
err_compare "R6 errproj3 par" "$d" par --verbose
d="$W/r6-err-strlit"; copy_fixture "$MS_ROOT/err-strlit" "$d"
err_compare "R6 err-strlit j1" "$d" j1 --verbose
err_compare "R6 err-strlit par" "$d" par --verbose
d="$W/r6-err-d2a"; copy_fixture "$MS_ROOT/err-d2a" "$d"
cnobj_compare "R6 err-d2a single-shot" "$d" "r6-d2a" src/main.ast
cnobj_compare "R6 err-d2a single-shot proj" "$d" "r6-d2a-proj" --project aster.proj src/main.ast
# Duplicate-declaration errors must surface from the first dirty TU, with
# today's timing and attribution, in both modes (R6 fallback path).
mut_dup_struct() { python3 - "$1" <<'PY'
import os, sys
p = os.path.join(sys.argv[1], 'src/main.ast')
s = open(p).read()
s += '结构 点\n横: 整数\n纵: 整数\n结束 结构\n'
open(p, 'w').write(s)
PY
}
mut_dup_alias() { python3 - "$1" <<'PY'
import os, sys
p = os.path.join(sys.argv[1], 'src/main.ast')
s = open(p).read()
s += '类型 数量 = 整数\n'
open(p, 'w').write(s)
PY
}
for spec in "dup-global mut_dup_global" "dup-struct mut_dup_struct" "dup-alias mut_dup_alias"; do
    set -- $spec; tag=$1; mut=$2
    d="$W/r6-$tag"; write_r1_fixture "$d"; "$mut" "$d"
    err_compare "R6 $tag j1" "$d" j1 --verbose
    err_compare "R6 $tag par" "$d" par --verbose
done

echo "PASS: registry-sharing-checks: $PASS_N cases"
