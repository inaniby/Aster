#!/bin/sh
# tests/cn-apk-checks.sh
#
# C-1: `aster build` supports bilingual APK projects end to end.
#
#   [1] P9 (bilingual project mode): an English file accepts the mainline
#       `->` return type, and an `extern fn` declaration of a function
#       defined in another source is the same symbol, not a duplicate.
#   [2] a Chinese Counter (compiler default zh, no [language] config)
#       builds to a signed APK via `aster build`; the rebuild reuses both
#       per-source objects; a counter-source change recompiles both, a
#       main-source change recompiles one.
#   [3] an English Counter (explicit en, arrow returns, extern fn) builds
#       to a signed APK the same way.
#   [4] both APKs verify: `aster verify-apk` plus tests/validate_apk.py
#       (v1 + v2 + v3 signatures, structure, digests).
#   [5] qemu entry probe (needs qemu-aarch64 + aarch64-linux-gnu-gcc, else
#       SKIP): the APK's .so is extracted and its ANativeActivity_onCreate
#       is called twice from a C harness under qemu-aarch64; it must return
#       42 then 43, so the counter state persists across calls. This is an
#       entry-point probe, not a full Android launch: there is no
#       NativeActivity framework, JVM or device here; install-and-launch
#       on a phone is a separate, manual check.
#   [6] error paths: `aster run` refuses an apk project; an apk project
#       without `package` is refused.
#
# No external Android toolchain (aapt / apksigner / NDK) is involved: the
# APK is built and signed by aster itself, like tests/apk-checks.sh.
# Counter sources are written into a scratch directory by this suite; the
# deliverable copies built from the same sources live outside the tree
# (see the C-1 report, FIX-REPORT §7).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ASTER_BIN=${ASTER_BIN:-$ROOT/aster}
if [ ! -x "$ASTER_BIN" ]; then
    echo "set ASTER_BIN to a built Aster executable" >&2
    exit 2
fi
RUNNER=${RUNNER:-$ROOT/tests/run-aarch64.sh}
# AArch64 guests run natively on an AArch64 host and under qemu-aarch64
# elsewhere. Without either, execution checks SKIP cleanly (cf.
# bootstrap-loop-checks.sh) instead of failing with Exec format error.
if [ "$(uname -m)" = aarch64 ] || [ "$(uname -m)" = arm64 ] \
    || command -v qemu-aarch64 >/dev/null 2>&1; then
    CAN_RUN=1
else
    CAN_RUN=0
fi
# The qemu entry probe also needs the cross C compiler to link the harness
# against the extracted .so.
if [ "$CAN_RUN" -eq 1 ] && command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
    CAN_PROBE=1
else
    CAN_PROBE=0
fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

printf '%s\n' '[1/6] P9: English `->` return type + extern fn of a defined function'
mkdir -p "$TMP/p9exe/src"
printf 'kind exe\n[language]\ndefault = "en"\nsrc/main.ast\nsrc/util.ast\n' > "$TMP/p9exe/aster.proj"
cat > "$TMP/p9exe/src/main.ast" <<'SRC'
extern fn add(a: i32, b: i32) -> i32;
fn main() -> i32 {
    return add(40, 2) - 42;
}
SRC
cat > "$TMP/p9exe/src/util.ast" <<'SRC'
fn add(a: i32, b: i32) -> i32 {
    return a + b;
}
SRC
(cd "$TMP/p9exe" && "$ASTER_BIN" build > build.log 2>&1) || {
    echo 'FAIL: the P9 project did not build:' >&2; cat "$TMP/p9exe/build.log" >&2; exit 1; }
grep -q '(2 compiled, 0 reused)' "$TMP/p9exe/build.log" || {
    echo 'FAIL: the P9 project did not compile both sources:' >&2; cat "$TMP/p9exe/build.log" >&2; exit 1; }
if [ "$CAN_RUN" -eq 1 ]; then
    "$RUNNER" "$TMP/p9exe/build/p9exe" || {
        echo 'FAIL: the P9 executable did not exit 0' >&2; exit 1; }
    printf '  %-40s %s\n' 'arrow returns + extern fn build and run' 'ok'
else
    printf '  SKIP: P9 run needs qemu-aarch64 or AArch64 Linux\n'
fi
# Two definitions of one name are still a duplicate: the P9 allowance is
# only declaration-vs-definition (and declaration-vs-declaration).
cat > "$TMP/p9exe/src/main.ast" <<'SRC'
fn add(a: i32, b: i32) -> i32 {
    return a + b;
}
fn main() -> i32 {
    return add(40, 2) - 42;
}
SRC
if (cd "$TMP/p9exe" && "$ASTER_BIN" build --no-cache > dup.log 2>&1); then
    echo 'FAIL: two definitions of `add` were accepted' >&2; exit 1
fi
grep -q 'duplicate method declaration: add' "$TMP/p9exe/dup.log" || {
    echo 'FAIL: two definitions were refused for the wrong reason:' >&2; cat "$TMP/p9exe/dup.log" >&2; exit 1; }
printf '  %-40s %s\n' 'two definitions still refused' 'ok'

build_counter() {
    # $1 = dir, $2 = zh|en
    dir=$1; lang=$2
    mkdir -p "$dir/src"
    if [ "$lang" = zh ]; then
        printf 'kind apk\npackage com.example.%s\nlabel %s\nsrc/main.ast\nsrc/counter.ast\n' \
            "${dir##*/}" '计数器' > "$dir/aster.proj"
        cat > "$dir/src/counter.ast" <<'SRC'
变量 计数: 整数 = 41
方法 增加(步长: 整数): 整数
    计数 = 计数 + 步长
    返回 计数
结束 方法
SRC
        cat > "$dir/src/main.ast" <<'SRC'
方法 ANativeActivity_onCreate(活动: 指针, 保存状态: 指针, 保存大小: 整数): 整数
    返回 增加(1)
结束 方法
SRC
    else
        printf 'kind apk\npackage com.example.%s\nlabel Counter\n[language]\ndefault = "en"\nsrc/main.ast\nsrc/counter.ast\n' \
            "${dir##*/}" > "$dir/aster.proj"
        cat > "$dir/src/counter.ast" <<'SRC'
let count: i32 = 41;
fn increment(step: i32) -> i32 {
    count = count + step;
    return count;
}
SRC
        cat > "$dir/src/main.ast" <<'SRC'
extern fn increment(step: i32) -> i32;
fn ANativeActivity_onCreate(activity: ptr, savedState: ptr, savedStateSize: i32) -> i32 {
    return increment(1);
}
SRC
    fi
}

printf '%s\n' '[2/6] Chinese Counter APK (default zh, no [language] config)'
build_counter "$TMP/zhcounter" zh
(cd "$TMP/zhcounter" && "$ASTER_BIN" build > build1.log 2>&1) || {
    echo 'FAIL: the Chinese Counter did not build:' >&2; cat "$TMP/zhcounter/build1.log" >&2; exit 1; }
grep -q '(2 compiled, 0 reused)' "$TMP/zhcounter/build1.log" || {
    echo 'FAIL: the first Chinese build did not compile both sources:' >&2; cat "$TMP/zhcounter/build1.log" >&2; exit 1; }
[ -f "$TMP/zhcounter/build/zhcounter.apk" ] || {
    echo 'FAIL: no build/zhcounter.apk was written' >&2; exit 1; }
(cd "$TMP/zhcounter" && "$ASTER_BIN" build > build2.log 2>&1) || {
    echo 'FAIL: the Chinese rebuild failed:' >&2; cat "$TMP/zhcounter/build2.log" >&2; exit 1; }
grep -q '(0 compiled, 2 reused)' "$TMP/zhcounter/build2.log" || {
    echo 'FAIL: the Chinese rebuild did not reuse both objects:' >&2; cat "$TMP/zhcounter/build2.log" >&2; exit 1; }
printf '\n// a comment change\n' >> "$TMP/zhcounter/src/counter.ast"
(cd "$TMP/zhcounter" && "$ASTER_BIN" build > build3.log 2>&1) || {
    echo 'FAIL: the Chinese build after a counter change failed:' >&2; cat "$TMP/zhcounter/build3.log" >&2; exit 1; }
grep -q '(2 compiled, 0 reused)' "$TMP/zhcounter/build3.log" || {
    echo 'FAIL: a counter-source change did not recompile both objects:' >&2; cat "$TMP/zhcounter/build3.log" >&2; exit 1; }
printf '\n// another comment change\n' >> "$TMP/zhcounter/src/main.ast"
(cd "$TMP/zhcounter" && "$ASTER_BIN" build > build4.log 2>&1) || {
    echo 'FAIL: the Chinese build after a main change failed:' >&2; cat "$TMP/zhcounter/build4.log" >&2; exit 1; }
grep -q '(1 compiled, 1 reused)' "$TMP/zhcounter/build4.log" || {
    echo 'FAIL: a main-source change did not recompile exactly one object:' >&2; cat "$TMP/zhcounter/build4.log" >&2; exit 1; }
printf '  %-40s %s\n' 'zh Counter builds; per-source cache counts hold' 'ok'

printf '%s\n' '[3/6] English Counter APK (explicit en, arrow + extern fn)'
build_counter "$TMP/encounter" en
(cd "$TMP/encounter" && "$ASTER_BIN" build > build1.log 2>&1) || {
    echo 'FAIL: the English Counter did not build:' >&2; cat "$TMP/encounter/build1.log" >&2; exit 1; }
grep -q '(2 compiled, 0 reused)' "$TMP/encounter/build1.log" || {
    echo 'FAIL: the first English build did not compile both sources:' >&2; cat "$TMP/encounter/build1.log" >&2; exit 1; }
[ -f "$TMP/encounter/build/encounter.apk" ] || {
    echo 'FAIL: no build/encounter.apk was written' >&2; exit 1; }
(cd "$TMP/encounter" && "$ASTER_BIN" build > build2.log 2>&1) || {
    echo 'FAIL: the English rebuild failed:' >&2; cat "$TMP/encounter/build2.log" >&2; exit 1; }
grep -q '(0 compiled, 2 reused)' "$TMP/encounter/build2.log" || {
    echo 'FAIL: the English rebuild did not reuse both objects:' >&2; cat "$TMP/encounter/build2.log" >&2; exit 1; }
printf '  %-40s %s\n' 'en Counter builds; per-source cache counts hold' 'ok'

printf '%s\n' '[4/6] both APKs verify (v1 + v2 + v3)'
"$ASTER_BIN" verify-apk "$TMP/zhcounter/build/zhcounter.apk" > "$TMP/verify-zh.log" 2>&1 || {
    echo 'FAIL: the Chinese APK did not verify:' >&2; cat "$TMP/verify-zh.log" >&2; exit 1; }
"$ASTER_BIN" verify-apk "$TMP/encounter/build/encounter.apk" > "$TMP/verify-en.log" 2>&1 || {
    echo 'FAIL: the English APK did not verify:' >&2; cat "$TMP/verify-en.log" >&2; exit 1; }
python3 "$ROOT/tests/validate_apk.py" "$TMP/zhcounter/build/zhcounter.apk" \
    --package com.example.zhcounter --libname zhcounter --abi arm64-v8a > "$TMP/validate-zh.log" 2>&1 || {
    echo 'FAIL: validate_apk.py rejected the Chinese APK:' >&2; cat "$TMP/validate-zh.log" >&2; exit 1; }
python3 "$ROOT/tests/validate_apk.py" "$TMP/encounter/build/encounter.apk" \
    --package com.example.encounter --libname encounter --abi arm64-v8a > "$TMP/validate-en.log" 2>&1 || {
    echo 'FAIL: validate_apk.py rejected the English APK:' >&2; cat "$TMP/validate-en.log" >&2; exit 1; }
printf '  %-40s %s\n' 'verify-apk + validate_apk.py pass for both' 'ok'

printf '%s\n' '[5/6] qemu entry probe: ANativeActivity_onCreate returns 42, then 43'
if [ "$CAN_PROBE" -eq 0 ]; then
    printf '  SKIP: entry probe needs qemu-aarch64 + aarch64-linux-gnu-gcc\n'
else
    mkdir -p "$TMP/sodir"
    python3 - "$TMP" <<'PY'
import sys, zipfile
tmp = sys.argv[1]
for name in ("zhcounter", "encounter"):
    apk = zipfile.ZipFile("%s/%s/build/%s.apk" % (tmp, name, name))
    open("%s/sodir/lib%s.so" % (tmp, name), "wb").write(
        apk.read("lib/arm64-v8a/lib%s.so" % name))
PY
    for name in zhcounter encounter; do
        readelf -Ws --dyn-syms "$TMP/sodir/lib$name.so" | grep -q ' ANativeActivity_onCreate' || {
            echo "FAIL: lib$name.so exports no ANativeActivity_onCreate" >&2; exit 1; }
    done
    cat > "$TMP/probe.c" <<'C'
#include <stdio.h>
extern int ANativeActivity_onCreate(void *activity, void *savedState, int savedStateSize);
int main(void) {
    int first = ANativeActivity_onCreate(0, 0, 0);
    int second = ANativeActivity_onCreate(0, 0, 0);
    printf("onCreate: first=%d second=%d\n", first, second);
    return (first == 42 && second == 43) ? 0 : 1;
}
C
    # -print-sysroot reports "/" on this toolchain, which makes qemu look
    # for the loader at /lib; use the sysroot directory itself, the same
    # choice tests/run-aarch64.sh makes.
    if [ -d /usr/aarch64-linux-gnu ]; then
        SYSROOT=/usr/aarch64-linux-gnu
    else
        SYSROOT=$(aarch64-linux-gnu-gcc -print-sysroot 2>/dev/null || echo /usr/aarch64-linux-gnu)
    fi
    for name in zhcounter encounter; do
        aarch64-linux-gnu-gcc "$TMP/probe.c" -L"$TMP/sodir" -l"$name" -o "$TMP/probe-$name" || {
            echo "FAIL: the $name harness did not link" >&2; exit 1; }
        qemu-aarch64 -L "$SYSROOT" -E LD_LIBRARY_PATH="$TMP/sodir" "$TMP/probe-$name" > "$TMP/probe-$name.log" 2>&1 || {
            echo "FAIL: the $name .so entry probe failed under qemu:" >&2; cat "$TMP/probe-$name.log" >&2; exit 1; }
        grep -q 'onCreate: first=42 second=43' "$TMP/probe-$name.log" || {
            echo "FAIL: the $name probe printed the wrong values:" >&2; cat "$TMP/probe-$name.log" >&2; exit 1; }
    done
    printf '  %-40s %s\n' 'both .so entries run under qemu (42, then 43)' 'ok'
fi

printf '%s\n' '[6/6] error paths'
if (cd "$TMP/zhcounter" && "$ASTER_BIN" run > run.log 2>&1); then
    echo 'FAIL: aster run accepted an apk project' >&2; exit 1
fi
grep -q 'aster run: this is an apk project' "$TMP/zhcounter/run.log" || {
    echo 'FAIL: aster run refused the apk project for the wrong reason:' >&2; cat "$TMP/zhcounter/run.log" >&2; exit 1; }
mkdir -p "$TMP/nopkg/src"
printf 'kind apk\nlabel NoPkg\nsrc/main.ast\n' > "$TMP/nopkg/aster.proj"
cp "$TMP/zhcounter/src/main.ast" "$TMP/nopkg/src/main.ast"
cp "$TMP/zhcounter/src/counter.ast" "$TMP/nopkg/src/counter.ast"
if (cd "$TMP/nopkg" && "$ASTER_BIN" build > nopkg.log 2>&1); then
    echo 'FAIL: an apk project without `package` built' >&2; exit 1
fi
grep -q 'needs `package <android.package>`' "$TMP/nopkg/nopkg.log" || {
    echo 'FAIL: the missing-package refusal was worded wrong:' >&2; cat "$TMP/nopkg/nopkg.log" >&2; exit 1; }
printf '  %-40s %s\n' 'run refusal + missing-package refusal' 'ok'

echo 'PASS: bilingual APK checks (Chinese + English Counter, qemu entry probe)'
