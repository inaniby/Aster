#!/bin/sh
# build.sh — Gallery 模板：双语构建 + 无窗口 qemu 检查。
#
# 全部走双语前端（`aster build` / `build-cn-obj`），不走传统 build-obj
# 回退。某阶段失败时，把阻塞项记进 phase1-impl-b.md，不要绕路——
# 详见该日志的当前状态。
# `aster run` 按设计拒绝 apk 工程；验收口径是 `aster build` +
# 无窗口 qemu + `verify-apk`，不是 `aster run`。
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
FW=$(CDPATH= cd -- "$ROOT/../../.." && pwd)
ASTER=${ASTER:-$HOME/workspace/projects/Aster-cn-s1s2-fix/aster}
RUNNER=${RUNNER:-$HOME/workspace/projects/Aster-cn-s1s2-fix/tests/run-aarch64.sh}
QEMU=${QEMU:-qemu-aarch64}
APP_LANG=zh # 模板源码是中文；框架源码是英文 legacy
if [ ! -x "$ASTER" ]; then
    echo "build.sh: no aster at $ASTER (set ASTER=...)" >&2
    exit 2
fi
echo "== [1/3] aster build (bilingual, apk) =="
(cd "$ROOT" && "$ASTER" build)
APK="$ROOT/build/gallery-zh.apk"
echo "== [2/3] verify-apk $APK =="
"$ASTER" verify-apk "$APK"
echo "== [3/3] headless qemu check =="
OBJ="$ROOT/build/headless-obj"
mkdir -p "$OBJ"
# 框架 + 应用对象，全部双语（build-cn-obj）。
for spec in "src/aui_impl.ast:aui_impl" "src/font_runtime.ast:font_runtime" \
            "src/render/truetype.ast:truetype" "src/render/text.ast:text" \
            "assets/embeds.ast:embeds" "src/aster_std.ast:std" \
            "tests/fake_ndk.ast:fake_ndk"; do
    src=${spec%%:*}; base=${spec#*:}
    "$ASTER" build-cn-obj --project "$ROOT/aster.proj" --language en "$FW/$src" -o "$OBJ/$base.o"
done
for f in app page_counter page_input page_nav; do
    "$ASTER" build-cn-obj --project "$ROOT/aster.proj" --language "$APP_LANG" "$ROOT/src/$f.ast" -o "$OBJ/$f.o"
done
"$ASTER" build-cn-obj --project "$ROOT/aster.proj" --language "$APP_LANG" "$ROOT/tests/headless.ast" -o "$OBJ/headless.o"
# shellcheck disable=SC2086
"$ASTER" link-obj "$OBJ/headless.o" "$OBJ/app.o" "$OBJ/page_counter.o" \
    "$OBJ/page_input.o" "$OBJ/page_nav.o" "$OBJ/aui_impl.o" \
    "$OBJ/font_runtime.o" "$OBJ/truetype.o" "$OBJ/text.o" "$OBJ/embeds.o" \
    "$OBJ/std.o" "$OBJ/fake_ndk.o" -o "$OBJ/headless"
if [ "$(uname -m)" = aarch64 ] || [ "$(uname -m)" = arm64 ]; then
    "$OBJ/headless"
else
    "$QEMU" "$OBJ/headless"
fi
echo "build.sh: gallery template OK (build + verify-apk + headless exit 0)"
