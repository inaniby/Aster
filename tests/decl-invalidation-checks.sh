#!/bin/sh
# tests/decl-invalidation-checks.sh
#
# Phase 2: declaration-level invalidation (incremental-design §4.2).
#
#   [1] compile aster with the same strict flags used for release (-Werror)
#   [2] source guards for the declaration index (--decl-invalidation, the
#       decl table / dirty computation / index read-write, the decl-aware
#       .meta reuse, the per-TU refs round-trip through the parallel workers)
#   [3] deterministic cases on a small bilingual APK fixture, twin projects
#       (decl build vs cold build): comment 0 / body 2 / signature 2 /
#       global 2 / type 2 / alias 2 / enum 1 / add-method 1 / delete-method
#       error parity — every green case asserts the APK and the .o contents
#       are byte-identical to the cold twin
#   [4] random-mutation contrast loop (seeded, reproducible): 8 rounds, each
#       a fresh twin pair with one mutation drawn from the pool; the decl
#       build's .o set and APK must be byte-identical to cold
#   [5] default-on: without any flag a comment change recompiles 0 (the
#       decl path is the default); --no-decl-invalidation restores the
#       Phase 1 file-hash behaviour (comment recompiles the cold set,
#       byte-identical output)
#   [6] daemon: --daemon --decl-invalidation, comment 0 / body 2, APK == cold
#
# .o comparison is by content hash, not file name: the .o file names embed a
# hash of the absolute project path, so two different project directories get
# different names for identical bytes (a pre-existing cache-key property).
# Keys are pre-generated with `aster keygen` into a scratch directory, so the
# signing key is identical across the decl/cold comparison — which is what
# makes the APK byte comparison meaningful.
#
# Override points (env vars): ASTER_BIN, KEY_DIR
set -eu
. tests/lib/tmpdir.sh

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ASTER_BIN="${ASTER_BIN:-$TMPD/aster-decl}"
KEY_DIR="${KEY_DIR:-$TMPD/aster-decl-keys}"
FIXTURE="$TMPD/decl-fixture"
PROJ="$TMPD/decl-proj"
TWIN="$TMPD/decl-proj-twin"
APK="build/decl.apk"

fail() { echo "FAIL: $*" >&2; exit 1; }
apk_sha() { sha256sum "$1" | cut -d' ' -f1; }
# osum <dir>: content-only hash of the .o set (names stripped, see header).
osum() { (cd "$1" && sha256sum build/.cache/cn-*.o | awk '{print $1}' | sort | sha256sum | cut -d' ' -f1); }
# norm <log>: timings vary run to run; everything else must match exactly.
norm() { sed -E 's/in [0-9]+ ms/in N ms/g' "$1"; }
# build <dir> [extra flags...]: --jobs 1 --verbose; leaves the log in
# $TMPD/last-build.log; prints the compiled TU lines + the summary line.
build() {
    dir="$1"; shift
    (cd "$dir" && ASTER_KEY_DIR="$KEY_DIR" "$ASTER_BIN" build --jobs 1 --verbose "$@" \
        > "$TMPD/last-build.log" 2>&1) ||
        fail "build failed in $dir (see $TMPD/last-build.log)"
    grep -E 'compiled [a-z]|\(.*compiled,' "$TMPD/last-build.log" | sed 's/aster: verbose: //;s/ in [0-9]* ms//'
}
count_of() { grep -o '([0-9]* compiled, [0-9]* reused)' "$TMPD/last-build.log" | tail -1 | sed -E 's/\(([0-9]+) compiled.*/\1/'; }
expect_count() { # expect_count <label> <want> — reads $TMPD/last-build.log
    got="$(count_of)"
    [ "$got" = "$2" ] || fail "$1: expected $2 compiled, got $got (see $TMPD/last-build.log)"
    printf '  %-40s %s\n' "$1" "ok ($got compiled)"
}
expect_same_product() { # expect_same_product <label>: APK + .o contents vs twin
    a="$(apk_sha "$PROJ/$APK")"; b="$(apk_sha "$TWIN/$APK")"
    [ "$a" = "$b" ] || fail "$1: APK differs decl=$a cold=$b"
    a="$(osum "$PROJ")"; b="$(osum "$TWIN")"
    [ "$a" = "$b" ] || fail "$1: .o contents differ decl=$a cold=$b"
    printf '  %-40s %s\n' "$1" "ok (APK + .o identical)"
}

echo "[1/6] compiling aster (strict: -Wall -Wextra -Werror)"
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror -o "$ASTER_BIN" src/aster.cpp

echo "[2/6] source guards: declaration-level invalidation"
for needle in \
    '--decl-invalidation' \
    'decl-invalidation' \
    'decl-index.json' \
    'declComputeDirty' \
    'declBuildTable' \
    'declIndexLoad' \
    'declIndexSave' \
    'declSerializeRefs' \
    'declParseRefs' \
    'g_cnEmittedFieldAccesses' \
    'declSkipDepFiles' \
    'declDirtyTus' ; do
    grep -qF -- "$needle" src/aster.cpp || fail "source guard missing: $needle"
done
printf '  %-40s %s\n' 'decl-invalidation layer present' 'ok'

echo "[3/6] fixture project (5 sources, Chinese)"
rm -rf "$KEY_DIR" && mkdir -p "$KEY_DIR"
"$ASTER_BIN" keygen --dir "$KEY_DIR" > /dev/null
rm -rf "$FIXTURE" && mkdir -p "$FIXTURE/src"
cat > "$FIXTURE/aster.proj" <<'PROJ'
kind apk
package com.example.decl
name decl
label 声明
src/main.ast
src/counter.ast
src/extra1.ast
src/extra2.ast
src/types.ast
PROJ
cat > "$FIXTURE/src/counter.ast" <<'SRC'
变量 计数: 整数 = 41
方法 增加(步长: 整数): 整数
    计数 = 计数 + 步长
    返回 计数
结束 方法
SRC
cat > "$FIXTURE/src/extra1.ast" <<'SRC'
变量 备用一: 整数 = 1
方法 取一(): 整数
    返回 备用一 + 计数
结束 方法
SRC
cat > "$FIXTURE/src/extra2.ast" <<'SRC'
变量 备用二: 整数 = 2
方法 取二(): 整数
    返回 备用二
结束 方法
SRC
cat > "$FIXTURE/src/types.ast" <<'SRC'
结构 点
横: 整数
纵: 整数
结束 结构
类型 数量 = 整数
枚举 方向
上 = 1
下 = 2
结束 枚举
方法 用坐标(某点: 点): 整数
    返回 某点.横 + 某点.纵
结束 方法
方法 用点(): 整数
    变量 p: 点
    p.横 = 3
    p.纵 = 4
    返回 用坐标(p)
结束 方法
方法 用编号(): 整数
    变量 x: 数量 = 7
    返回 x
结束 方法
方法 用方向(): 整数
    变量 d: 方向 = 下
    变量 结果: 整数 = 2
    假如 d
    是 上
    结果 = 1
    结束 假如
    返回 结果
结束 方法
SRC
cat > "$FIXTURE/src/main.ast" <<'SRC'
方法 ANativeActivity_onCreate(活动: 指针, 保存状态: 指针, 保存大小: 整数): 整数
    变量 p: 点
    p.横 = 1
    p.纵 = 2
    变量 n: 数量 = 3
    返回 增加(1) + 取一() + 取二() + 用点() + 用编号() + 用方向() + p.横 + p.纵 + n
结束 方法
SRC

# fresh_twins: pristine copies for one case; clean-build both (decl / cold).
fresh_twins() {
    rm -rf "$PROJ" "$TWIN"
    cp -r "$FIXTURE" "$PROJ"
    cp -r "$FIXTURE" "$TWIN"
    build "$PROJ" --decl-invalidation > /dev/null
    expect_count "clean build (decl)" 5
    build "$TWIN" --no-decl-invalidation > /dev/null
    expect_count "clean build (cold)" 5
    [ "$(apk_sha "$PROJ/$APK")" = "$(apk_sha "$TWIN/$APK")" ] ||
        fail "clean builds disagree on the APK"
}
# run_case <name> <mut-fn> <want-decl> <want-cold>: mutate both, rebuild, compare.
run_case() {
    "$2" "$PROJ"
    "$2" "$TWIN"
    build "$PROJ" --decl-invalidation > /dev/null
    expect_count "$1 (decl)" "$3"
    build "$TWIN" --no-decl-invalidation > /dev/null
    expect_count "$1 (cold)" "$4"
    expect_same_product "$1"
}

mut_comment() { printf '\n// decl suite probe\n' >> "$1/src/counter.ast"; }
mut_body() { perl -pi -e 's/计数 = 计数 \+ 步长/计数 = 计数 + 步长 + 1/' "$1/src/counter.ast"; }
mut_sig() { perl -pi -e 's/步长/步/g' "$1/src/counter.ast"; }
mut_global() { perl -pi -e 's/变量 计数: 整数 = 41/变量 计数: 整数 = 42/' "$1/src/counter.ast"; }
mut_type() { perl -0777 -pi -e 's/横: 整数\n纵: 整数/纵: 整数\n横: 整数/' "$1/src/types.ast"; }
mut_alias() { perl -pi -e 's/数量/数目/g' "$1/src/types.ast" "$1/src/main.ast"; }
mut_enum() { perl -pi -e 's/^上 = 1$/上 = 10/' "$1/src/types.ast"; }
mut_add() { printf '\n方法 未用方法(x: 整数): 整数\n    返回 x + 1\n结束 方法\n' >> "$1/src/counter.ast"; }

echo "[3/6] deterministic cases (twin contrast)"
fresh_twins; run_case "comment" mut_comment 0 3
fresh_twins; run_case "method body" mut_body 2 3
fresh_twins; run_case "method signature" mut_sig 2 3
fresh_twins; run_case "global init" mut_global 2 3
fresh_twins; run_case "struct field order" mut_type 2 2
fresh_twins; run_case "type alias rename" mut_alias 2 2
fresh_twins; run_case "enum member value" mut_enum 1 2
fresh_twins; run_case "add method" mut_add 1 3

echo "[3/6] delete-method: error parity (both builds must fail identically)"
fresh_twins
sed -i '2,4d' "$PROJ/src/extra2.ast"
sed -i '2,4d' "$TWIN/src/extra2.ast"
set +e
(cd "$PROJ" && ASTER_KEY_DIR="$KEY_DIR" "$ASTER_BIN" build --jobs 1 --decl-invalidation > "$TMPD/del-decl.log" 2>&1); rc_decl=$?
(cd "$TWIN" && ASTER_KEY_DIR="$KEY_DIR" "$ASTER_BIN" build --jobs 1 > "$TMPD/del-cold.log" 2>&1); rc_cold=$?
set -e
[ "$rc_decl" = "$rc_cold" ] || fail "delete-method: rc differs decl=$rc_decl cold=$rc_cold"
[ "$rc_decl" != 0 ] || fail "delete-method: expected both builds to fail"
norm "$TMPD/del-decl.log" > "$TMPD/del-decl.norm"
norm "$TMPD/del-cold.log" > "$TMPD/del-cold.norm"
diff -q "$TMPD/del-decl.norm" "$TMPD/del-cold.norm" > /dev/null ||
    { echo "FAIL: delete-method error output differs:" >&2; diff "$TMPD/del-decl.norm" "$TMPD/del-cold.norm" >&2; exit 1; }
printf '  %-40s %s\n' 'delete-method error parity' "ok (rc=$rc_decl, identical output)"

echo "[4/6] random-mutation contrast loop (seeded)"
seed=20261127
round=1
while [ "$round" -le 8 ]; do
    seed=$(( (seed * 1103515245 + 12345) & 0x7fffffff ))
    kind=$(( seed % 8 ))
    case "$kind" in
        0) mut=mut_comment; name=comment ;;
        1) mut=mut_body; name="method body" ;;
        2) mut=mut_sig; name="method signature" ;;
        3) mut=mut_global; name="global init" ;;
        4) mut=mut_type; name="struct field order" ;;
        5) mut=mut_alias; name="type alias rename" ;;
        6) mut=mut_enum; name="enum member value" ;;
        *) mut=mut_add; name="add method" ;;
    esac
    fresh_twins > /dev/null
    "$mut" "$PROJ"; "$mut" "$TWIN"
    build "$PROJ" --decl-invalidation > /dev/null
    dcount="$(count_of)"
    build "$TWIN" > /dev/null
    ccount="$(count_of)"
    expect_same_product "round $round ($name, decl=$dcount cold=$ccount)"
    round=$(( round + 1 ))
done

echo "[5/6] default-on: no flag uses the decl path; --no-decl-invalidation restores Phase 1"
fresh_twins > /dev/null
mut_comment "$PROJ"; mut_comment "$TWIN"
build "$PROJ" > /dev/null
expect_count "comment without flag" 0
build "$TWIN" --no-decl-invalidation > /dev/null
expect_count "comment --no-decl-invalidation" 3
expect_same_product "default-on"

echo "[6/6] daemon: --daemon --decl-invalidation"
stop_daemon() { "$ASTER_BIN" serve stop --project "$PROJ" > /dev/null 2>&1 || true; }
trap stop_daemon EXIT
fresh_twins > /dev/null
setsid "$ASTER_BIN" serve --project "$PROJ" --detached > "$TMPD/decl-daemon.log" 2>&1 < /dev/null &
sleep 2
"$ASTER_BIN" serve status --project "$PROJ" > "$TMPD/decl-status.log" 2>&1 ||
    { echo "FAIL: daemon did not come up:" >&2; cat "$TMPD/decl-daemon.log" >&2; exit 1; }
grep -q 'running (pid ' "$TMPD/decl-status.log" || fail "status did not report running"
(cd "$PROJ" && ASTER_KEY_DIR="$KEY_DIR" "$ASTER_BIN" build --jobs 1 --verbose --daemon --decl-invalidation > "$TMPD/d1.log" 2>&1) || fail "daemon warm build failed (see $TMPD/d1.log)"
grep -q 'decl-invalidation: 0 decls changed' "$TMPD/d1.log" || fail "daemon warm build did not run the decl path"
mut_comment "$PROJ"; mut_comment "$TWIN"
(cd "$PROJ" && ASTER_KEY_DIR="$KEY_DIR" "$ASTER_BIN" build --jobs 1 --verbose --daemon --decl-invalidation > "$TMPD/d2.log" 2>&1) || fail "daemon comment build failed (see $TMPD/d2.log)"
grep -q '(0 compiled, 5 reused)' "$TMPD/d2.log" || fail "daemon comment build did not recompile 0"
(cd "$TWIN" && ASTER_KEY_DIR="$KEY_DIR" "$ASTER_BIN" build --jobs 1 > /dev/null 2>&1)
mut_body "$PROJ"; mut_body "$TWIN"
(cd "$PROJ" && ASTER_KEY_DIR="$KEY_DIR" "$ASTER_BIN" build --jobs 1 --verbose --daemon --decl-invalidation > "$TMPD/d3.log" 2>&1) || fail "daemon body build failed (see $TMPD/d3.log)"
grep -q '(2 compiled, 3 reused)' "$TMPD/d3.log" || fail "daemon body build did not recompile 2"
(cd "$TWIN" && ASTER_KEY_DIR="$KEY_DIR" "$ASTER_BIN" build --jobs 1 > /dev/null 2>&1)
expect_same_product "daemon body"
"$ASTER_BIN" serve status --project "$PROJ" > "$TMPD/decl-status2.log" 2>&1
grep -qE 'requests: [3-9]' "$TMPD/decl-status2.log" || fail "daemon did not serve the requests"
printf '  %-40s %s\n' 'daemon served 3+ requests' 'ok'
stop_daemon
trap - EXIT

echo "decl-invalidation-checks: PASS"
