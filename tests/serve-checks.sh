#!/bin/sh
# tests/serve-checks.sh
#
# Phase 1: the resident `aster serve` daemon (incremental-design §7.2).
#
#   [1] compile aster with the same strict flags used for release (-Werror)
#   [2] source guards for the service layer (serve subcommand, NDJSON
#       protocol, daemon state, --daemon/--no-daemon, ASTER_DAEMON)
#   [3] `aster serve` starts detached, `serve status` reports it, and a
#       second `serve` refuses while it is running
#   [4] `aster build` through the daemon: the first request runs the worker,
#       the second takes the daemon fast path, and its output is identical
#       to a cold fast-path build modulo timings (same APK bytes)
#   [5] a one-file change through the daemon matches a cold build in a twin
#       copy (same APK sha, same normalized output)
#   [6] fallback: killing the daemon mid-build makes the client print the
#       daemon-unavailable warning and finish via a cold build; the next
#       request relaunches the service. `--no-daemon` bypasses it entirely
#   [7] `aster serve stop` stops the service; status then reports rc=1
#
# No external Android toolchain is involved. Keys are pre-generated with
# `aster keygen` into a scratch directory (ASTER_KEY_DIR), so no build
# prints a key-generation notice and the signing key is identical across
# the daemon/cold comparison — which is what makes the APK byte comparison
# meaningful.
#
# The daemon is started detached (setsid + --detached) with stdio to a log
# file: a foreground `aster serve` whose parent shell exits self-exits via
# the parent-death check, so the suite must not start it in the foreground.
# A trap stops the service on exit, so a failed run leaves no daemon behind.
#
# Override points (env vars): ASTER_BIN, KEY_DIR
set -eu
. tests/lib/tmpdir.sh

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ASTER_BIN="${ASTER_BIN:-$TMPD/aster-serve}"
KEY_DIR="${KEY_DIR:-$TMPD/aster-serve-keys}"
PROJ="$TMPD/serve-proj"
TWIN="$TMPD/serve-proj-twin"
APK="$PROJ/build/serve.apk"
SOCKDIR="$PROJ/build/.cache"

fail() { echo "FAIL: $*" >&2; exit 1; }
apk_sha() { sha256sum "$1" | cut -d' ' -f1; }
# norm <log>: timings vary run to run; everything else must match exactly.
norm() { sed -E 's/in [0-9]+ ms/in N ms/g' "$1"; }
daemon_pid() {
    # the lock file's first line is "pid <n>"
    sed -n 's/^pid //p' "$SOCKDIR"/asterd-*.lock 2>/dev/null | head -1
}
start_daemon() {
    setsid "$ASTER_BIN" serve --project "$PROJ" --socket-dir "$SOCKDIR" --detached \
        > "$TMPD/serve-daemon.log" 2>&1 < /dev/null &
    sleep 2
    "$ASTER_BIN" serve status --project "$PROJ" > "$TMPD/serve-status.log" 2>&1 ||
        { echo "FAIL: daemon did not come up:" >&2; cat "$TMPD/serve-daemon.log" >&2; exit 1; }
}
stop_daemon() { "$ASTER_BIN" serve stop --project "$PROJ" > /dev/null 2>&1 || true; }
trap stop_daemon EXIT

echo "[1/7] compiling aster (strict: -Wall -Wextra -Werror)"
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror -o "$ASTER_BIN" src/aster.cpp

echo "[1/7] generating the test project's debug keys"
rm -rf "$KEY_DIR" && mkdir -p "$KEY_DIR"
"$ASTER_BIN" keygen --dir "$KEY_DIR" > /dev/null

echo "[2/7] source guards: service layer"
for needle in \
    'aster serve' \
    'serve stop' \
    'serve status' \
    'daemonHandleBuild' \
    'daemonServeMain' \
    'daemonEnsure' \
    'ASTER_DAEMON' \
    '--no-daemon' \
    'asterd-' \
    'jsonrpc' \
    'daemon went away mid-build' ; do
    grep -qF -- "$needle" src/aster.cpp || fail "source guard missing: $needle"
done
printf '  %-40s %s\n' 'service layer present' 'ok'

echo "[3/7] small bilingual APK project (4 sources)"
rm -rf "$PROJ" "$TWIN" && mkdir -p "$PROJ/src"
cat > "$PROJ/aster.proj" <<'PROJ'
kind apk
package com.example.serve
name serve
label 计数器
src/main.ast
src/counter.ast
src/extra1.ast
src/extra2.ast
PROJ
cat > "$PROJ/src/counter.ast" <<'SRC'
变量 计数: 整数 = 41
方法 增加(步长: 整数): 整数
    计数 = 计数 + 步长
    返回 计数
结束 方法
SRC
cat > "$PROJ/src/extra1.ast" <<'SRC'
变量 备用一: 整数 = 1
方法 取一(): 整数
    返回 备用一
结束 方法
SRC
cat > "$PROJ/src/extra2.ast" <<'SRC'
变量 备用二: 整数 = 2
方法 取二(): 整数
    返回 备用二
结束 方法
SRC
cat > "$PROJ/src/main.ast" <<'SRC'
方法 ANativeActivity_onCreate(活动: 指针, 保存状态: 指针, 保存大小: 整数): 整数
    返回 增加(1) + 取一() + 取二()
结束 方法
SRC

echo "[3/7] serve starts, status reports it, second serve refuses"
start_daemon
grep -q 'running (pid ' "$TMPD/serve-status.log" || fail "status did not report running"
grep -q 'requests: 0, cached files: 0' "$TMPD/serve-status.log" ||
    fail "status did not report an empty fresh daemon"
if "$ASTER_BIN" serve --project "$PROJ" --socket-dir "$SOCKDIR" --detached \
        > "$TMPD/serve-second.log" 2>&1; then
    fail "second serve should have refused while the daemon runs"
fi
grep -q 'already running' "$TMPD/serve-second.log" ||
    fail "second serve refusal text wrong"

echo "[4/7] build through the daemon: worker, then fast path, output == cold"
(cd "$PROJ" && ASTER_KEY_DIR="$KEY_DIR" ASTER_DAEMON=1 "$ASTER_BIN" build --verbose \
    > "$TMPD/daemon-cold.log" 2>&1) ||
    { echo "FAIL: first daemon build failed:" >&2; cat "$TMPD/daemon-cold.log" >&2; exit 1; }
grep -q '(4 compiled, 0 reused)' "$TMPD/daemon-cold.log" ||
    fail "first daemon build did not compile all 4 sources"
[ -f "$APK" ] || fail "first daemon build wrote no APK"
SHA_DAEMON=$(apk_sha "$APK")
(cd "$PROJ" && ASTER_KEY_DIR="$KEY_DIR" ASTER_DAEMON=1 "$ASTER_BIN" build --verbose \
    > "$TMPD/daemon-warm.log" 2>&1) ||
    { echo "FAIL: second daemon build failed:" >&2; cat "$TMPD/daemon-warm.log" >&2; exit 1; }
grep -q 'aster: verbose: fast-path: reused ' "$TMPD/daemon-warm.log" ||
    fail "second daemon build did not take the daemon fast path"
grep -q '(0 compiled, 4 reused)' "$TMPD/daemon-warm.log" ||
    fail "daemon fast path did not report 0 compiled, 4 reused"
[ "$(apk_sha "$APK")" = "$SHA_DAEMON" ] || fail "daemon warm APK differs"
# The same warm build cold must print exactly the same lines (modulo ms).
(cd "$PROJ" && ASTER_KEY_DIR="$KEY_DIR" "$ASTER_BIN" build --verbose --no-daemon \
    > "$TMPD/cold-warm.log" 2>&1) ||
    { echo "FAIL: cold warm build failed:" >&2; cat "$TMPD/cold-warm.log" >&2; exit 1; }
norm "$TMPD/daemon-warm.log" > "$TMPD/daemon-warm.norm"
norm "$TMPD/cold-warm.log" > "$TMPD/cold-warm.norm"
cmp -s "$TMPD/daemon-warm.norm" "$TMPD/cold-warm.norm" ||
    { echo "FAIL: daemon fast-path output differs from cold:" >&2;
      diff "$TMPD/daemon-warm.norm" "$TMPD/cold-warm.norm" >&2; exit 1; }
printf '  %-40s %s\n' 'daemon fast-path output == cold' 'ok'

echo "[5/7] one-file change: daemon build == cold build in a twin copy"
# The twin warms its OWN cache first: cache keys embed the absolute project
# path, so a copied build/ directory would never hit.
rm -rf "$TWIN"; cp -r "$PROJ" "$TWIN"; rm -rf "$TWIN/build"
(cd "$TWIN" && ASTER_KEY_DIR="$KEY_DIR" "$ASTER_BIN" build --verbose --no-daemon \
    > "$TMPD/twin-warm.log" 2>&1) ||
    { echo "FAIL: twin warm build failed:" >&2; cat "$TMPD/twin-warm.log" >&2; exit 1; }
printf '\n// serve-checks probe comment\n' >> "$PROJ/src/main.ast"
printf '\n// serve-checks probe comment\n' >> "$TWIN/src/main.ast"
(cd "$PROJ" && ASTER_KEY_DIR="$KEY_DIR" ASTER_DAEMON=1 "$ASTER_BIN" build --verbose \
    > "$TMPD/daemon-change.log" 2>&1) ||
    { echo "FAIL: daemon change build failed:" >&2; cat "$TMPD/daemon-change.log" >&2; exit 1; }
(cd "$TWIN" && ASTER_KEY_DIR="$KEY_DIR" "$ASTER_BIN" build --verbose --no-daemon \
    > "$TMPD/twin-change.log" 2>&1) ||
    { echo "FAIL: twin change build failed:" >&2; cat "$TMPD/twin-change.log" >&2; exit 1; }
[ "$(apk_sha "$APK")" = "$(apk_sha "$TWIN/build/serve.apk")" ] ||
    fail "APK sha differs after one-file change (daemon vs cold)"
norm "$TMPD/daemon-change.log" > "$TMPD/daemon-change.norm"
norm "$TMPD/twin-change.log" > "$TMPD/twin-change.norm"
cmp -s "$TMPD/daemon-change.norm" "$TMPD/twin-change.norm" ||
    { echo "FAIL: one-file-change output differs (daemon vs cold):" >&2;
      diff "$TMPD/daemon-change.norm" "$TMPD/twin-change.norm" >&2; exit 1; }
# restore the comment in the probe project
python3 - "$PROJ" <<'PY'
import sys
p = sys.argv[1] + "/src/main.ast"
t = open(p).read()
open(p, "w").write(t.replace("\n// serve-checks probe comment\n", "", 1))
PY
printf '  %-40s %s\n' 'one-file change: daemon == cold' 'ok'

echo "[6/7] fallback: daemon killed mid-build -> cold build + relaunch"
# Stop first: removing build/ while a daemon runs would orphan it (its
# socket file would be unlinked under it). Then a clean build through a
# fresh daemon takes a couple of seconds; kill the daemon while it is in
# flight and the client must fall back to cold.
stop_daemon
rm -rf "$PROJ/build"
start_daemon
(cd "$PROJ" && ASTER_KEY_DIR="$KEY_DIR" ASTER_DAEMON=1 "$ASTER_BIN" build --verbose \
    > "$TMPD/crash.log" 2>&1) &
CRASH_BUILD=$!
sleep 0.5
kill -9 "$(daemon_pid)" 2>/dev/null || fail "could not kill the daemon mid-build"
wait $CRASH_BUILD || fail "mid-flight build failed instead of falling back to cold"
grep -q 'daemon unavailable (daemon went away mid-build)' "$TMPD/crash.log" ||
    fail "mid-flight build printed no daemon-unavailable warning"
grep -q 'built bilingual project' "$TMPD/crash.log" ||
    fail "mid-flight build produced no APK"
[ "$(apk_sha "$APK")" = "$SHA_DAEMON" ] || fail "APK after crash fallback differs"
# The next request relaunches the service.
(cd "$PROJ" && ASTER_KEY_DIR="$KEY_DIR" ASTER_DAEMON=1 "$ASTER_BIN" build --verbose \
    > "$TMPD/relaunch.log" 2>&1) ||
    { echo "FAIL: relaunch build failed:" >&2; cat "$TMPD/relaunch.log" >&2; exit 1; }
"$ASTER_BIN" serve status --project "$PROJ" > "$TMPD/serve-status2.log" 2>&1 ||
    fail "no daemon running after the relaunch build"
grep -q 'running (pid ' "$TMPD/serve-status2.log" || fail "relaunch status wrong"
# --no-daemon bypasses the service entirely (and stays silent about it).
stop_daemon
(cd "$PROJ" && ASTER_KEY_DIR="$KEY_DIR" "$ASTER_BIN" build --verbose --no-daemon \
    > "$TMPD/nodaemon.log" 2>&1) ||
    { echo "FAIL: --no-daemon build failed:" >&2; cat "$TMPD/nodaemon.log" >&2; exit 1; }
if grep -q 'daemon' "$TMPD/nodaemon.log"; then
    fail "--no-daemon build mentioned the daemon"
fi
printf '  %-40s %s\n' 'fallback to cold + relaunch + --no-daemon' 'ok'

echo "[7/7] serve stop"
start_daemon
"$ASTER_BIN" serve stop --project "$PROJ" > "$TMPD/serve-stop.log" 2>&1 ||
    fail "serve stop failed"
grep -q 'stopped the service' "$TMPD/serve-stop.log" || fail "serve stop text wrong"
if "$ASTER_BIN" serve status --project "$PROJ" > "$TMPD/serve-status3.log" 2>&1; then
    fail "status should report rc=1 after serve stop"
fi
grep -q 'no service running' "$TMPD/serve-status3.log" ||
    fail "status after stop text wrong"

echo "PASS: serve-checks"
