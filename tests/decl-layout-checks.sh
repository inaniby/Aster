#!/bin/sh
# tests/decl-layout-checks.sh
#
# D-2a declarative layout lowering (W-1..W-10): layout/event desugar,
# name->key (FNV-1a), key() folding, event-block checks, modifier checks.
#
#   [1/7] the four D-2a drafts (counter/tab-input, zh/en) compile and run:
#         line counts 58/58 and 102/102, the FNV-1a rule, and the qemu
#         probes that record every aui_* call (keys, aui_end discipline,
#         user passthrough, event callbacks callable and mutating g_app).
#         The drafts themselves are NOT edited: each probe concatenates a
#         stub (struct 应用/App + g_app + recording aui_* definitions +
#         driver main) in front of the draft in a scratch directory.
#   [2/7] P1-3: illegal attribute name / type / string dimension, rejected
#         naming the attribute.
#   [3/7] P2-1: inserting a node does not shift existing keys.
#         P2-2: a duplicate node name in one declaration is rejected.
#         P2-3: renaming a node breaks its event and key() references.
#   [4/7] P3-2: a layout declaration in the wrong place is rejected;
#         two independent layouts in one file both build and run.
#   [5/7] P4-2: a duplicate modifier is rejected.
#         P4-3: the same modifier set in two source orders desugars to
#         byte-identical objects (work order §1 W-3 / §6: modifiers are
#         emitted in design §4 table order, not source order).
#   [6/7] P5-2: body-tail statements run after the tree (source order);
#         a construction-phase let/if supplies a Select's open value.
#   [7/7] P6-2/P6-3 and the W-1..W-10 rejection probes, plus the W-8
#         explicit-key and W-3 wrap-content positive probes.
#         W-11 (bootstrap rejection) and W-12 (docs) belong to the
#         bootstrap/docs worker and are not probed here.
#   [8/7] D-2a diagnostics follow the program language: the English
#         mirrors of the [2/7]-[7/7] rejection probes assert the English
#         wording (same error, same structure, only the language
#         differs); the Chinese probes above keep asserting Chinese.
#
# NOTE on the FNV-1a keys: keys are emitted as SIGNED i32 literals
# (e.g. -13268203 for 4281699093). The backend compares a > INT32_MAX
# unsigned literal in 64-bit, so an i32 variable holding a key's bit
# pattern would never compare equal to the unsigned spelling, and the
# sentinel pattern `s.选择打开 == 键(语言)` would break on the
# round trip (store the key, compare it later). The probes assert the
# signed spellings.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ASTER_BIN=${ASTER_BIN:-$ROOT/build/cn-s1-s2/aster}
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
PROTO=${D2A_PROTOTYPES:-$HOME/workspace/asterui-cn-s1s2/prototypes/d2a}
if [ ! -f "$PROTO/counter-zh.ast" ] || [ ! -f "$PROTO/counter-en.ast" ] \
    || [ ! -f "$PROTO/tab-input-zh.ast" ] || [ ! -f "$PROTO/tab-input-en.ast" ]; then
    echo "D-2a drafts not found in $PROTO (set D2A_PROTOTYPES)" >&2
    exit 2
fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

run_status() { # $1 = program, $2 = expected exit code
    if [ "$CAN_RUN" -eq 0 ]; then
        printf '  SKIP: %s needs qemu-aarch64 or AArch64 Linux\n' "$1"
        return 0
    fi
    rc=0; "$RUNNER" "$1" || rc=$?
    [ "$rc" = "$2" ] || { echo "FAIL: $1 exited $rc, expected $2" >&2; exit 1; }
}

expect_fail() { # $1 = label, $2 = needle, $3... = command
    label=$1; needle=$2; shift 2
    if "$@" > "$TMP/fail.out" 2> "$TMP/fail.err"; then
        echo "FAIL: $label was accepted" >&2; exit 1
    fi
    grep -q "$needle" "$TMP/fail.err" || {
        echo "FAIL: $label was refused for the wrong reason (want '$needle'):" >&2
        cat "$TMP/fail.err" >&2; exit 1; }
    printf '  %-40s %s\n' "$label" 'refused'
}

build_ok() { # $1 = label, $2... = build-cn-obj arguments (file last, then -o out)
    label=$1; shift
    "$ASTER_BIN" build-cn-obj "$@" > "$TMP/build.out" 2> "$TMP/build.err" || {
        echo "FAIL: $label did not build:" >&2
        cat "$TMP/build.err" >&2; exit 1; }
    printf '  %-40s %s\n' "$label" 'builds'
}

# Shared fixture for the small probes: struct 应用 + g_app, the externs
# the probes use, and a trivial main. Each probe appends its own
# layout/event declarations to a copy.
cat > "$TMP/app-zh.ast" <<'SRC'
结构 应用
计数: 整数
页: 整数
语言: 整数
提醒: 整数
推广: 整数
滑杆: 整数
选择打开: 整数
结束 结构
变量 g_app: 应用 = 应用 { 0, 0, 0, 1, 0, 500, 0 }
外部("aui_column") 方法 列(键: 整数): 整数
外部("aui_row") 方法 行(键: 整数): 整数
外部("aui_label") 方法 标签(键: 整数, 文本: 指针): 整数
外部("aui_button") 方法 按钮(键: 整数, 文本: 指针, 回调: 方法(指针): 整数, 用户: 指针): 整数
外部("aui_text_i32") 方法 数字(键: 整数, 值: 整数): 整数
外部("aui_pad") 方法 边距(尺寸: 整数): 整数
外部("aui_gap") 方法 间距(尺寸: 整数): 整数
外部("aui_weight") 方法 权重(宽: 整数): 整数
外部("aui_size") 方法 尺寸(宽: 整数, 高: 整数): 整数
外部("aui_end") 方法 结束节点(): 整数
外部("aui_invalidate") 方法 刷新(): 整数
方法 启动方法(): 整数
    返回 0
结束 方法
SRC

probe_file() { # reads the probe body on stdin after the shared fixture
    cat "$TMP/app-zh.ast" > "$TMP/probe.ast"
    cat >> "$TMP/probe.ast"
}

# ---------------------------------------------------------------------------
printf '%s\n' '[1/7] drafts: line counts, FNV-1a rule, compile, qemu run'
[ "$(wc -l < "$PROTO/counter-zh.ast")" = 58 ] || {
    echo 'FAIL: counter-zh.ast is not 58 lines' >&2; exit 1; }
[ "$(wc -l < "$PROTO/counter-en.ast")" = 58 ] || {
    echo 'FAIL: counter-en.ast is not 58 lines' >&2; exit 1; }
[ "$(wc -l < "$PROTO/tab-input-zh.ast")" = 102 ] || {
    echo 'FAIL: tab-input-zh.ast is not 102 lines' >&2; exit 1; }
[ "$(wc -l < "$PROTO/tab-input-en.ast")" = 102 ] || {
    echo 'FAIL: tab-input-en.ast is not 102 lines' >&2; exit 1; }
printf '  %-40s %s\n' 'counter 58/58, tab-input 102/102' 'ok'
if command -v python3 >/dev/null 2>&1; then
    python3 - "$PROTO" <<'PY' || { echo 'FAIL: FNV-1a rule check' >&2; exit 1; }
import sys
def fnv(s):
    h = 2166136261
    for b in s.encode('utf-8'):
        h ^= b
        h = (h * 16777619) & 0xffffffff
    return h
assert fnv('page_counter.主列') == 3117286848, fnv('page_counter.主列')
assert fnv('page_input.语言') == 4281699093, fnv('page_input.语言')
assert fnv('page_counter.MainCol') == 324013166, fnv('page_counter.MainCol')
assert fnv('page_input.Language') == 3190575563, fnv('page_input.Language')
PY
    printf '  %-40s %s\n' 'FNV-1a(decl.name) rule' 'ok'
else
    printf '  SKIP: python3 not found, FNV-1a rule check skipped\n'
fi

# Minimal stubs: only struct 应用/App + g_app, so the draft compiles as
# one build-cn-obj file with its aui_* externs left unresolved.
cat > "$TMP/app-only-zh.ast" <<'SRC'
结构 应用
计数: 整数
页: 整数
语言: 整数
提醒: 整数
推广: 整数
滑杆: 整数
选择打开: 整数
结束 结构
变量 g_app: 应用 = 应用 { 0, 0, 0, 1, 0, 500, 0 }
SRC
cat > "$TMP/app-only-en.ast" <<'SRC'
struct App {
    count: i32,
    tab: i32,
    lang: i32,
    notify: i32,
    promo: i32,
    slider: i32,
    sel_open: i32
}
let g_app: App = App { 0, 0, 0, 1, 0, 500, 0 };
SRC
cat "$TMP/app-only-zh.ast" "$PROTO/counter-zh.ast" > "$TMP/min-counter-zh.ast"
cat "$TMP/app-only-zh.ast" "$PROTO/tab-input-zh.ast" > "$TMP/min-tab-zh.ast"
cat "$TMP/app-only-en.ast" "$PROTO/counter-en.ast" > "$TMP/min-counter-en.ast"
cat "$TMP/app-only-en.ast" "$PROTO/tab-input-en.ast" > "$TMP/min-tab-en.ast"
build_ok 'counter-zh compiles' "$TMP/min-counter-zh.ast" -o "$TMP/min-counter-zh.o"
build_ok 'tab-input-zh compiles' "$TMP/min-tab-zh.ast" -o "$TMP/min-tab-zh.o"
build_ok 'counter-en compiles' --language en "$TMP/min-counter-en.ast" -o "$TMP/min-counter-en.o"
build_ok 'tab-input-en compiles' --language en "$TMP/min-tab-en.ast" -o "$TMP/min-tab-en.o"

# Full qemu probes: stub (struct + g_app + recording aui_* definitions +
# driver main) + draft, built as one file, linked, run under qemu.
# The driver asserts: layout return 0, every constructor key equals the
# FNV-1a value (signed i32 spelling), aui_end/pad/gap counts, the user
# argument passthrough, and each event callback callable with the
# expected effect on g_app.
cat > "$TMP/stub-counter-zh.ast" <<'SRC'
结构 应用
计数: 整数
页: 整数
语言: 整数
提醒: 整数
推广: 整数
滑杆: 整数
选择打开: 整数
结束 结构
变量 g_app: 应用 = 应用 { 0, 0, 0, 1, 0, 500, 0 }
变量 键日志: 整数[32]
变量 日志数: 整数 = 0
变量 结束数: 整数 = 0
变量 边距数: 整数 = 0
变量 间距数: 整数 = 0
变量 状态值: 整数 = 0
变量 保存减: 方法(指针): 整数 = 空
变量 保存加: 方法(指针): 整数 = 空
变量 保存重置: 方法(指针): 整数 = 空
变量 保存用户: 指针 = 空
方法 记键(键: 整数): 整数
    键日志[日志数] = 键
    日志数 = 日志数 + 1
    返回 0
结束 方法
方法 aui_column(键: 整数): 整数
    记键(键)
    返回 0
结束 方法
方法 aui_row(键: 整数): 整数
    记键(键)
    返回 0
结束 方法
方法 aui_label(键: 整数, 文本: 指针): 整数
    记键(键)
    返回 0
结束 方法
方法 aui_text_i32(键: 整数, 值: 整数): 整数
    记键(键)
    返回 0
结束 方法
方法 aui_button(键: 整数, 文本: 指针, 回调: 方法(指针): 整数, 用户: 指针): 整数
    记键(键)
    如果 键 == 967344210
        保存减 = 回调
    否则如果 键 == -1094478546
        保存加 = 回调
    否则如果 键 == 1801790954
        保存重置 = 回调
    结束 如果
    保存用户 = 用户
    返回 0
结束 方法
方法 aui_pad(尺寸: 整数): 整数
    边距数 = 边距数 + 1
    返回 0
结束 方法
方法 aui_gap(尺寸: 整数): 整数
    间距数 = 间距数 + 1
    返回 0
结束 方法
方法 aui_state_set(键: 整数, 值: 整数): 整数
    如果 键 == 1
        状态值 = 值
    结束 如果
    返回 0
结束 方法
方法 aui_invalidate(): 整数
    返回 0
结束 方法
方法 aui_end(): 整数
    结束数 = 结束数 + 1
    返回 0
结束 方法
方法 启动方法(): 整数
    变量 p: 指针<应用> = &g_app
    变量 r: 整数 = page_counter(p, p)
    如果 r != 0
        返回 11
    结束 如果
    如果 日志数 != 9
        返回 12
    结束 如果
    如果 键日志[0] != -1177680448
        返回 13
    结束 如果
    如果 键日志[1] != -1717266343
        返回 13
    结束 如果
    如果 键日志[2] != -1338672106
        返回 13
    结束 如果
    如果 键日志[3] != 967344210
        返回 13
    结束 如果
    如果 键日志[4] != -608616239
        返回 13
    结束 如果
    如果 键日志[5] != -1094478546
        返回 13
    结束 如果
    如果 键日志[6] != 1801790954
        返回 13
    结束 如果
    如果 键日志[7] != 944530720
        返回 13
    结束 如果
    如果 键日志[8] != -2016649531
        返回 13
    结束 如果
    如果 结束数 != 2
        返回 14
    结束 如果
    如果 边距数 != 1
        返回 15
    结束 如果
    如果 间距数 != 2
        返回 16
    结束 如果
    变量 up: 指针 = p
    如果 保存用户 != up
        返回 17
    结束 如果
    变量 c0: 整数 = 保存减(保存用户)
    如果 g_app.计数 != -1
        返回 21
    结束 如果
    如果 状态值 != -1
        返回 22
    结束 如果
    变量 c1: 整数 = 保存加(保存用户)
    如果 g_app.计数 != 0
        返回 23
    结束 如果
    g_app.计数 = 5
    变量 c2: 整数 = 保存重置(保存用户)
    如果 g_app.计数 != 0
        返回 24
    结束 如果
    如果 状态值 != 0
        返回 25
    结束 如果
    返回 0
结束 方法
SRC
cat "$TMP/stub-counter-zh.ast" "$PROTO/counter-zh.ast" > "$TMP/full-counter-zh.ast"
"$ASTER_BIN" build-cn-obj "$TMP/full-counter-zh.ast" -o "$TMP/full-counter-zh.o"
"$ASTER_BIN" link-obj "$TMP/full-counter-zh.o" -o "$TMP/full-counter-zh"
run_status "$TMP/full-counter-zh" 0
printf '  %-40s %s\n' 'counter-zh qemu probe' 'ok'

cat > "$TMP/stub-counter-en.ast" <<'SRC'
struct App {
    count: i32,
    tab: i32,
    lang: i32,
    notify: i32,
    promo: i32,
    slider: i32,
    sel_open: i32
}
let g_app: App = App { 0, 0, 0, 1, 0, 500, 0 };
let keylog: i32[32];
let logn: i32 = 0;
let endn: i32 = 0;
let padn: i32 = 0;
let gapn: i32 = 0;
let statev: i32 = 0;
let savedDec: fn(ptr) : i32 = null;
let savedInc: fn(ptr) : i32 = null;
let savedReset: fn(ptr) : i32 = null;
let savedUser: ptr = null;
fn logKey(key: i32) : i32 {
    keylog[logn] = key;
    logn = logn + 1;
    return 0;
}
fn aui_column(key: i32) : i32 {
    logKey(key);
    return 0;
}
fn aui_row(key: i32) : i32 {
    logKey(key);
    return 0;
}
fn aui_label(key: i32, text: ptr) : i32 {
    logKey(key);
    return 0;
}
fn aui_text_i32(key: i32, value: i32) : i32 {
    logKey(key);
    return 0;
}
fn aui_button(key: i32, text: ptr, cb: fn(ptr) : i32, user: ptr) : i32 {
    logKey(key);
    if (key == 1786076415) {
        savedDec = cb;
    } else if (key == 183326715) {
        savedInc = cb;
    } else if (key == -1039401196) {
        savedReset = cb;
    }
    savedUser = user;
    return 0;
}
fn aui_pad(dp: i32) : i32 {
    padn = padn + 1;
    return 0;
}
fn aui_gap(dp: i32) : i32 {
    gapn = gapn + 1;
    return 0;
}
fn aui_state_set(key: i32, value: i32) : i32 {
    if (key == 1) {
        statev = value;
    }
    return 0;
}
fn aui_invalidate() : i32 {
    return 0;
}
fn aui_end() : i32 {
    endn = endn + 1;
    return 0;
}
fn main() : i32 {
    let p: ptr<App> = &g_app;
    let r: i32 = page_counter(p, p);
    if (r != 0) {
        return 11;
    }
    if (logn != 9) {
        return 12;
    }
    if (keylog[0] != 324013166) {
        return 13;
    }
    if (keylog[1] != 1056240053) {
        return 13;
    }
    if (keylog[2] != 1599418147) {
        return 13;
    }
    if (keylog[3] != 1786076415) {
        return 13;
    }
    if (keylog[4] != 1227156576) {
        return 13;
    }
    if (keylog[5] != 183326715) {
        return 13;
    }
    if (keylog[6] != -1039401196) {
        return 13;
    }
    if (keylog[7] != 840075724) {
        return 13;
    }
    if (keylog[8] != -1552151513) {
        return 13;
    }
    if (endn != 2) {
        return 14;
    }
    if (padn != 1) {
        return 15;
    }
    if (gapn != 2) {
        return 16;
    }
    let up: ptr = p;
    if (savedUser != up) {
        return 17;
    }
    let c0: i32 = savedDec(savedUser);
    if (g_app.count != -1) {
        return 21;
    }
    if (statev != -1) {
        return 22;
    }
    let c1: i32 = savedInc(savedUser);
    if (g_app.count != 0) {
        return 23;
    }
    g_app.count = 5;
    let c2: i32 = savedReset(savedUser);
    if (g_app.count != 0) {
        return 24;
    }
    if (statev != 0) {
        return 25;
    }
    return 0;
}
SRC
cat "$TMP/stub-counter-en.ast" "$PROTO/counter-en.ast" > "$TMP/full-counter-en.ast"
"$ASTER_BIN" build-cn-obj --language en "$TMP/full-counter-en.ast" -o "$TMP/full-counter-en.o"
"$ASTER_BIN" link-obj "$TMP/full-counter-en.o" -o "$TMP/full-counter-en"
run_status "$TMP/full-counter-en" 0
printf '  %-40s %s\n' 'counter-en qemu probe' 'ok'

cat > "$TMP/stub-tab-zh.ast" <<'SRC'
结构 应用
计数: 整数
页: 整数
语言: 整数
提醒: 整数
推广: 整数
滑杆: 整数
选择打开: 整数
结束 结构
变量 g_app: 应用 = 应用 { 0, 0, 0, 1, 0, 500, 0 }
变量 键日志: 整数[64]
变量 日志数: 整数 = 0
变量 结束数: 整数 = 0
变量 边距数: 整数 = 0
变量 间距数: 整数 = 0
变量 权重数: 整数 = 0
变量 键盘数: 整数 = 0
变量 清空数: 整数 = 0
变量 聚焦数: 整数 = 0
变量 打开值: 整数 = 0
变量 原因次: 整数 = 0
变量 保存清除: 方法(指针): 整数 = 空
变量 保存聚焦: 方法(指针): 整数 = 空
变量 保存提醒: 方法(指针): 整数 = 空
变量 保存推广: 方法(指针): 整数 = 空
变量 保存音量: 方法(指针): 整数 = 空
变量 保存语言: 方法(指针): 整数 = 空
变量 保存用户: 指针 = 空
方法 记键(键: 整数): 整数
    键日志[日志数] = 键
    日志数 = 日志数 + 1
    返回 0
结束 方法
方法 aui_scroll(键: 整数): 整数
    记键(键)
    返回 0
结束 方法
方法 aui_weight(宽: 整数): 整数
    权重数 = 权重数 + 1
    返回 0
结束 方法
方法 aui_column(键: 整数): 整数
    记键(键)
    返回 0
结束 方法
方法 aui_row(键: 整数): 整数
    记键(键)
    返回 0
结束 方法
方法 aui_pad(尺寸: 整数): 整数
    边距数 = 边距数 + 1
    返回 0
结束 方法
方法 aui_gap(尺寸: 整数): 整数
    间距数 = 间距数 + 1
    返回 0
结束 方法
方法 aui_label(键: 整数, 文本: 指针): 整数
    记键(键)
    返回 0
结束 方法
方法 aui_text_field(键: 整数, 提示: 指针): 整数
    记键(键)
    返回 0
结束 方法
方法 aui_text_value(键: 整数): 指针
    返回 空
结束 方法
方法 aui_focus_get(): 整数
    返回 0
结束 方法
方法 aui_button(键: 整数, 文本: 指针, 回调: 方法(指针): 整数, 用户: 指针): 整数
    记键(键)
    如果 键 == 2056707812
        保存清除 = 回调
    否则如果 键 == -1581218569
        保存聚焦 = 回调
    结束 如果
    保存用户 = 用户
    返回 0
结束 方法
方法 aui_select(键: 整数, 当前: 整数, 打开: 整数, 占位: 指针, 回调: 方法(指针): 整数, 用户: 指针): 整数
    记键(键)
    打开值 = 打开
    保存语言 = 回调
    保存用户 = 用户
    返回 0
结束 方法
方法 aui_option(键: 整数, 文本: 指针): 整数
    记键(键)
    返回 0
结束 方法
方法 aui_select_value(键: 整数): 整数
    返回 2
结束 方法
方法 aui_select_reason(): 整数
    原因次 = 原因次 + 1
    如果 原因次 == 1
        返回 0
    结束 如果
    返回 1
结束 方法
方法 aui_switch(键: 整数, 开: 整数, 回调: 方法(指针): 整数, 用户: 指针): 整数
    记键(键)
    保存提醒 = 回调
    保存用户 = 用户
    返回 0
结束 方法
方法 aui_checkbox(键: 整数, 文本: 指针, 选中: 整数, 回调: 方法(指针): 整数, 用户: 指针): 整数
    记键(键)
    保存推广 = 回调
    保存用户 = 用户
    返回 0
结束 方法
方法 aui_slider(键: 整数, 值: 整数, 步长: 整数, 回调: 方法(指针): 整数, 用户: 指针): 整数
    记键(键)
    保存音量 = 回调
    保存用户 = 用户
    返回 0
结束 方法
方法 aui_slider_value(键: 整数): 整数
    返回 42
结束 方法
方法 aui_progress(键: 整数, 值: 整数): 整数
    记键(键)
    返回 0
结束 方法
方法 aui_keyboard(目标键: 整数): 整数
    键盘数 = 键盘数 + 1
    返回 0
结束 方法
方法 aui_text_clear(键: 整数): 整数
    清空数 = 清空数 + 1
    返回 0
结束 方法
方法 aui_focus(键: 整数): 整数
    聚焦数 = 聚焦数 + 1
    返回 0
结束 方法
方法 aui_invalidate(): 整数
    返回 0
结束 方法
方法 aui_end(): 整数
    结束数 = 结束数 + 1
    返回 0
结束 方法
方法 启动方法(): 整数
    变量 p: 指针<应用> = &g_app
    g_app.选择打开 = -13268203
    变量 r: 整数 = page_input(p, p)
    如果 r != 0
        返回 11
    结束 如果
    如果 日志数 != 22
        返回 12
    结束 如果
    如果 键日志[0] != -585354663
        返回 13
    结束 如果
    如果 键日志[1] != -1352274108
        返回 13
    结束 如果
    如果 键日志[2] != -2049447115
        返回 13
    结束 如果
    如果 键日志[3] != -1590598266
        返回 13
    结束 如果
    如果 键日志[4] != -577031649
        返回 13
    结束 如果
    如果 键日志[5] != 437478704
        返回 13
    结束 如果
    如果 键日志[6] != 1954322306
        返回 13
    结束 如果
    如果 键日志[7] != 2013458970
        返回 13
    结束 如果
    如果 键日志[8] != 2056707812
        返回 13
    结束 如果
    如果 键日志[9] != -1581218569
        返回 13
    结束 如果
    如果 键日志[10] != -179923339
        返回 13
    结束 如果
    如果 键日志[11] != -13268203
        返回 13
    结束 如果
    如果 键日志[12] != -346624983
        返回 13
    结束 如果
    如果 键日志[13] != 2027987585
        返回 13
    结束 如果
    如果 键日志[14] != -303572459
        返回 13
    结束 如果
    如果 键日志[15] != 801531054
        返回 13
    结束 如果
    如果 键日志[16] != 193638921
        返回 13
    结束 如果
    如果 键日志[17] != -354040849
        返回 13
    结束 如果
    如果 键日志[18] != -220585786
        返回 13
    结束 如果
    如果 键日志[19] != 2105057127
        返回 13
    结束 如果
    如果 键日志[20] != 457176243
        返回 13
    结束 如果
    如果 键日志[21] != -1475122508
        返回 13
    结束 如果
    如果 结束数 != 6
        返回 14
    结束 如果
    如果 边距数 != 2
        返回 15
    结束 如果
    如果 间距数 != 3
        返回 16
    结束 如果
    如果 权重数 != 3
        返回 17
    结束 如果
    如果 键盘数 != 0
        返回 18
    结束 如果
    如果 打开值 != 1
        返回 19
    结束 如果
    变量 up: 指针 = p
    如果 保存用户 != up
        返回 20
    结束 如果
    变量 c0: 整数 = 保存清除(保存用户)
    如果 清空数 != 1
        返回 31
    结束 如果
    变量 c1: 整数 = 保存聚焦(保存用户)
    如果 聚焦数 != 1
        返回 32
    结束 如果
    变量 c2: 整数 = 保存提醒(保存用户)
    如果 g_app.提醒 != 0
        返回 33
    结束 如果
    变量 c3: 整数 = 保存推广(保存用户)
    如果 g_app.推广 != 1
        返回 34
    结束 如果
    变量 c4: 整数 = 保存音量(保存用户)
    如果 g_app.滑杆 != 42
        返回 35
    结束 如果
    变量 c5: 整数 = 保存语言(保存用户)
    如果 g_app.选择打开 != -13268203
        返回 36
    结束 如果
    变量 c6: 整数 = 保存语言(保存用户)
    如果 g_app.语言 != 2
        返回 37
    结束 如果
    如果 g_app.选择打开 != 0
        返回 38
    结束 如果
    返回 0
结束 方法
SRC
cat "$TMP/stub-tab-zh.ast" "$PROTO/tab-input-zh.ast" > "$TMP/full-tab-zh.ast"
"$ASTER_BIN" build-cn-obj "$TMP/full-tab-zh.ast" -o "$TMP/full-tab-zh.o"
"$ASTER_BIN" link-obj "$TMP/full-tab-zh.o" -o "$TMP/full-tab-zh"
run_status "$TMP/full-tab-zh" 0
printf '  %-40s %s\n' 'tab-input-zh qemu probe' 'ok'

cat > "$TMP/stub-tab-en.ast" <<'SRC'
struct App {
    count: i32,
    tab: i32,
    lang: i32,
    notify: i32,
    promo: i32,
    slider: i32,
    sel_open: i32
}
let g_app: App = App { 0, 0, 0, 1, 0, 500, 0 };
let keylog: i32[64];
let logn: i32 = 0;
let endn: i32 = 0;
let padn: i32 = 0;
let gapn: i32 = 0;
let weightn: i32 = 0;
let kbn: i32 = 0;
let clearn: i32 = 0;
let focusn: i32 = 0;
let openv: i32 = 0;
let reasonn: i32 = 0;
let savedClear: fn(ptr) : i32 = null;
let savedFocus: fn(ptr) : i32 = null;
let savedNotify: fn(ptr) : i32 = null;
let savedPromo: fn(ptr) : i32 = null;
let savedVolume: fn(ptr) : i32 = null;
let savedLanguage: fn(ptr) : i32 = null;
let savedUser: ptr = null;
fn logKey(key: i32) : i32 {
    keylog[logn] = key;
    logn = logn + 1;
    return 0;
}
fn aui_scroll(key: i32) : i32 {
    logKey(key);
    return 0;
}
fn aui_weight(w: i32) : i32 {
    weightn = weightn + 1;
    return 0;
}
fn aui_column(key: i32) : i32 {
    logKey(key);
    return 0;
}
fn aui_row(key: i32) : i32 {
    logKey(key);
    return 0;
}
fn aui_pad(dp: i32) : i32 {
    padn = padn + 1;
    return 0;
}
fn aui_gap(dp: i32) : i32 {
    gapn = gapn + 1;
    return 0;
}
fn aui_label(key: i32, text: ptr) : i32 {
    logKey(key);
    return 0;
}
fn aui_text_field(key: i32, hint: ptr) : i32 {
    logKey(key);
    return 0;
}
fn aui_text_value(key: i32) : ptr {
    return null;
}
fn aui_focus_get() : i32 {
    return 0;
}
fn aui_button(key: i32, text: ptr, cb: fn(ptr) : i32, user: ptr) : i32 {
    logKey(key);
    if (key == -1171597166) {
        savedClear = cb;
    } else if (key == -2143741853) {
        savedFocus = cb;
    }
    savedUser = user;
    return 0;
}
fn aui_select(key: i32, selected: i32, open: i32, placeholder: ptr, cb: fn(ptr) : i32, user: ptr) : i32 {
    logKey(key);
    openv = open;
    savedLanguage = cb;
    savedUser = user;
    return 0;
}
fn aui_option(key: i32, text: ptr) : i32 {
    logKey(key);
    return 0;
}
fn aui_select_value(key: i32) : i32 {
    return 2;
}
fn aui_select_reason() : i32 {
    reasonn = reasonn + 1;
    if (reasonn == 1) {
        return 0;
    }
    return 1;
}
fn aui_switch(key: i32, on: i32, cb: fn(ptr) : i32, user: ptr) : i32 {
    logKey(key);
    savedNotify = cb;
    savedUser = user;
    return 0;
}
fn aui_checkbox(key: i32, text: ptr, checked: i32, cb: fn(ptr) : i32, user: ptr) : i32 {
    logKey(key);
    savedPromo = cb;
    savedUser = user;
    return 0;
}
fn aui_slider(key: i32, value: i32, step: i32, cb: fn(ptr) : i32, user: ptr) : i32 {
    logKey(key);
    savedVolume = cb;
    savedUser = user;
    return 0;
}
fn aui_slider_value(key: i32) : i32 {
    return 42;
}
fn aui_progress(key: i32, value: i32) : i32 {
    logKey(key);
    return 0;
}
fn aui_keyboard(target_key: i32) : i32 {
    kbn = kbn + 1;
    return 0;
}
fn aui_text_clear(key: i32) : i32 {
    clearn = clearn + 1;
    return 0;
}
fn aui_focus(key: i32) : i32 {
    focusn = focusn + 1;
    return 0;
}
fn aui_invalidate() : i32 {
    return 0;
}
fn aui_end() : i32 {
    endn = endn + 1;
    return 0;
}
fn main() : i32 {
    let p: ptr<App> = &g_app;
    g_app.sel_open = -1104391733;
    let r: i32 = page_input(p, p);
    if (r != 0) {
        return 11;
    }
    if (logn != 22) {
        return 12;
    }
    if (keylog[0] != 464528793) {
        return 13;
    }
    if (keylog[1] != -137450478) {
        return 13;
    }
    if (keylog[2] != -15933671) {
        return 13;
    }
    if (keylog[3] != -236665557) {
        return 13;
    }
    if (keylog[4] != 298383220) {
        return 13;
    }
    if (keylog[5] != 1168151760) {
        return 13;
    }
    if (keylog[6] != -1153224307) {
        return 13;
    }
    if (keylog[7] != 1464126559) {
        return 13;
    }
    if (keylog[8] != -1171597166) {
        return 13;
    }
    if (keylog[9] != -2143741853) {
        return 13;
    }
    if (keylog[10] != -134503575) {
        return 13;
    }
    if (keylog[11] != -1104391733) {
        return 13;
    }
    if (keylog[12] != 1956836555) {
        return 13;
    }
    if (keylog[13] != 1943312675) {
        return 13;
    }
    if (keylog[14] != 666349752) {
        return 13;
    }
    if (keylog[15] != 2080632968) {
        return 13;
    }
    if (keylog[16] != -2094042644) {
        return 13;
    }
    if (keylog[17] != -1270126600) {
        return 13;
    }
    if (keylog[18] != 1366121808) {
        return 13;
    }
    if (keylog[19] != 707760919) {
        return 13;
    }
    if (keylog[20] != -1989447041) {
        return 13;
    }
    if (keylog[21] != 2006538838) {
        return 13;
    }
    if (endn != 6) {
        return 14;
    }
    if (padn != 2) {
        return 15;
    }
    if (gapn != 3) {
        return 16;
    }
    if (weightn != 3) {
        return 17;
    }
    if (kbn != 0) {
        return 18;
    }
    if (openv != 1) {
        return 19;
    }
    let up: ptr = p;
    if (savedUser != up) {
        return 20;
    }
    let c0: i32 = savedClear(savedUser);
    if (clearn != 1) {
        return 31;
    }
    let c1: i32 = savedFocus(savedUser);
    if (focusn != 1) {
        return 32;
    }
    let c2: i32 = savedNotify(savedUser);
    if (g_app.notify != 0) {
        return 33;
    }
    let c3: i32 = savedPromo(savedUser);
    if (g_app.promo != 1) {
        return 34;
    }
    let c4: i32 = savedVolume(savedUser);
    if (g_app.slider != 42) {
        return 35;
    }
    let c5: i32 = savedLanguage(savedUser);
    if (g_app.sel_open != -1104391733) {
        return 36;
    }
    let c6: i32 = savedLanguage(savedUser);
    if (g_app.lang != 2) {
        return 37;
    }
    if (g_app.sel_open != 0) {
        return 38;
    }
    return 0;
}
SRC
cat "$TMP/stub-tab-en.ast" "$PROTO/tab-input-en.ast" > "$TMP/full-tab-en.ast"
"$ASTER_BIN" build-cn-obj --language en "$TMP/full-tab-en.ast" -o "$TMP/full-tab-en.o"
"$ASTER_BIN" link-obj "$TMP/full-tab-en.o" -o "$TMP/full-tab-en"
run_status "$TMP/full-tab-en" 0
printf '  %-40s %s\n' 'tab-input-en qemu probe' 'ok'

# ---------------------------------------------------------------------------
printf '%s\n' '[2/7] P1-3: illegal attribute name / type / string dimension'
probe_file <<'SRC' > /dev/null
布局 页一(s: 指针<应用>, 用户: 指针): 视图 {
    列 主列, 内边距("16dp") {
        标签 标题, 指针("x")
    }
}
SRC
expect_fail 'string dimension 内边距("16dp")' "修饰符 '内边距' 的参数须是整数，不接受字符串维度" \
    "$ASTER_BIN" build-cn-obj "$TMP/probe.ast" -o "$TMP/probe.o"
probe_file <<'SRC' > /dev/null
布局 页一(s: 指针<应用>, 用户: 指针): 视图 {
    列 主列, 内边距(1.5) {
        标签 标题, 指针("x")
    }
}
SRC
expect_fail 'float dimension 内边距(1.5)' "修饰符 '内边距' 的参数须是整数，不接受浮点数" \
    "$ASTER_BIN" build-cn-obj "$TMP/probe.ast" -o "$TMP/probe.o"
probe_file <<'SRC' > /dev/null
布局 页一(s: 指针<应用>, 用户: 指针): 视图 {
    列 主列 {
        按钮 加, 指针("加"), 乱七八糟(1)
    }
}
SRC
expect_fail 'off-table name as extra position arg' "'乱七八糟' 不是已知修饰符" \
    "$ASTER_BIN" build-cn-obj "$TMP/probe.ast" -o "$TMP/probe.o"

# ---------------------------------------------------------------------------
printf '%s\n' '[3/7] P2-1/2/3: key stability, duplicate name, rename breaks refs'
cat > "$TMP/p21stub.ast" <<'SRC'
结构 应用
计数: 整数
页: 整数
语言: 整数
提醒: 整数
推广: 整数
滑杆: 整数
选择打开: 整数
结束 结构
变量 g_app: 应用 = 应用 { 0, 0, 0, 1, 0, 500, 0 }
变量 键日志: 整数[8]
变量 日志数: 整数 = 0
方法 记键(键: 整数): 整数
    键日志[日志数] = 键
    日志数 = 日志数 + 1
    返回 0
结束 方法
方法 aui_column(键: 整数): 整数
    记键(键)
    返回 0
结束 方法
方法 aui_label(键: 整数, 文本: 指针): 整数
    记键(键)
    返回 0
结束 方法
方法 aui_button(键: 整数, 文本: 指针, 回调: 方法(指针): 整数, 用户: 指针): 整数
    记键(键)
    返回 0
结束 方法
方法 aui_end(): 整数
    返回 0
结束 方法
外部("aui_column") 方法 列(键: 整数): 整数
外部("aui_label") 方法 标签(键: 整数, 文本: 指针): 整数
外部("aui_button") 方法 按钮(键: 整数, 文本: 指针, 回调: 方法(指针): 整数, 用户: 指针): 整数
外部("aui_end") 方法 结束节点(): 整数
SRC
cat "$TMP/p21stub.ast" > "$TMP/p21a.ast"
cat >> "$TMP/p21a.ast" <<'SRC'
布局 页甲(s: 指针<应用>, 用户: 指针): 视图 {
    列 甲 {
        标签 乙, 指针("乙")
    }
}
方法 启动方法(): 整数
    变量 p: 指针<应用> = &g_app
    变量 r: 整数 = 页甲(p, p)
    如果 日志数 != 2
        返回 1
    结束 如果
    如果 键日志[0] != 20233752
        返回 2
    结束 如果
    如果 键日志[1] != -290084439
        返回 2
    结束 如果
    返回 r
结束 方法
SRC
cat "$TMP/p21stub.ast" > "$TMP/p21b.ast"
cat >> "$TMP/p21b.ast" <<'SRC'
布局 页甲(s: 指针<应用>, 用户: 指针): 视图 {
    列 甲 {
        标签 丙, 指针("丙")
        标签 乙, 指针("乙")
    }
}
方法 启动方法(): 整数
    变量 p: 指针<应用> = &g_app
    变量 r: 整数 = 页甲(p, p)
    如果 日志数 != 3
        返回 1
    结束 如果
    如果 键日志[0] != 20233752
        返回 2
    结束 如果
    如果 键日志[1] != -222723700
        返回 2
    结束 如果
    如果 键日志[2] != -290084439
        返回 2
    结束 如果
    返回 r
结束 方法
SRC
"$ASTER_BIN" build-cn-obj "$TMP/p21a.ast" -o "$TMP/p21a.o"
"$ASTER_BIN" link-obj "$TMP/p21a.o" -o "$TMP/p21a"
run_status "$TMP/p21a" 0
"$ASTER_BIN" build-cn-obj "$TMP/p21b.ast" -o "$TMP/p21b.o"
"$ASTER_BIN" link-obj "$TMP/p21b.o" -o "$TMP/p21b"
run_status "$TMP/p21b" 0
printf '  %-40s %s\n' 'P2-1 insert node keeps existing keys' 'ok'
probe_file <<'SRC' > /dev/null
布局 页一(s: 指针<应用>, 用户: 指针): 视图 {
    列 主列 {
        标签 标题, 指针("x")
        标签 标题, 指针("y")
    }
}
SRC
expect_fail 'P2-2 duplicate node name' "节点名 '标题' 重复" \
    "$ASTER_BIN" build-cn-obj "$TMP/probe.ast" -o "$TMP/probe.o"
probe_file <<'SRC' > /dev/null
事件 加:被单击() {
    刷新()
}
布局 页一(s: 指针<应用>, 用户: 指针): 视图 {
    列 主列 {
        按钮 增加, 指针("加")
    }
}
SRC
expect_fail "P2-3 rename breaks the event ref" "事件块引用的节点 '加' 不存在" \
    "$ASTER_BIN" build-cn-obj "$TMP/probe.ast" -o "$TMP/probe.o"
probe_file <<'SRC' > /dev/null
布局 页一(s: 指针<应用>, 用户: 指针): 视图 {
    列 主列 {
        按钮 增加, 指针("加")
        数字 计数, 键(加)
    }
}
SRC
expect_fail "P2-3 rename breaks the key() ref" "键('加') 引用的节点不存在" \
    "$ASTER_BIN" build-cn-obj "$TMP/probe.ast" -o "$TMP/probe.o"

# ---------------------------------------------------------------------------
printf '%s\n' '[4/7] P3-2: layout in the wrong place; two layouts, one file'
probe_file <<'SRC' > /dev/null
方法 外壳(): 整数
    布局 页一(s: 指针<应用>, 用户: 指针): 视图 {
        列 主列 {
            标签 标题, 指针("x")
        }
    }
    返回 0
结束 方法
SRC
expect_fail 'P3-2 layout inside a method body' "expected an expression" \
    "$ASTER_BIN" build-cn-obj "$TMP/probe.ast" -o "$TMP/probe.o"
cat "$TMP/p21stub.ast" > "$TMP/p32b.ast"
cat >> "$TMP/p32b.ast" <<'SRC'
布局 页甲(s: 指针<应用>, 用户: 指针): 视图 {
    列 甲 {
        标签 乙, 指针("乙")
    }
}
布局 页乙(s: 指针<应用>, 用户: 指针): 视图 {
    列 甲 {
        标签 乙, 指针("乙")
    }
}
方法 启动方法(): 整数
    变量 p: 指针<应用> = &g_app
    变量 a: 整数 = 页甲(p, p)
    变量 b: 整数 = 页乙(p, p)
    如果 a != 0
        返回 1
    结束 如果
    如果 b != 0
        返回 2
    结束 如果
    如果 日志数 != 4
        返回 3
    结束 如果
    如果 键日志[0] != 20233752
        返回 4
    结束 如果
    如果 键日志[2] != -1648215139
        返回 4
    结束 如果
    返回 0
结束 方法
SRC
"$ASTER_BIN" build-cn-obj "$TMP/p32b.ast" -o "$TMP/p32b.o"
"$ASTER_BIN" link-obj "$TMP/p32b.o" -o "$TMP/p32b"
run_status "$TMP/p32b" 0
printf '  %-40s %s\n' 'P3-2 two layouts, one file' 'ok'

# ---------------------------------------------------------------------------
printf '%s\n' '[5/7] P4-2/3: duplicate modifier; scrambled-order equivalence'
probe_file <<'SRC' > /dev/null
布局 页一(s: 指针<应用>, 用户: 指针): 视图 {
    列 主列, 内边距(24), 内边距(16) {
        标签 标题, 指针("x")
    }
}
SRC
expect_fail "P4-2 duplicate modifier" "修饰符 '内边距' 重复" \
    "$ASTER_BIN" build-cn-obj "$TMP/probe.ast" -o "$TMP/probe.o"
cat > "$TMP/p43stub.ast" <<'SRC'
结构 应用
计数: 整数
页: 整数
语言: 整数
提醒: 整数
推广: 整数
滑杆: 整数
选择打开: 整数
结束 结构
变量 g_app: 应用 = 应用 { 0, 0, 0, 1, 0, 500, 0 }
变量 边距数: 整数 = 0
变量 间距数: 整数 = 0
变量 权重数: 整数 = 0
方法 aui_column(键: 整数): 整数
    返回 0
结束 方法
方法 aui_label(键: 整数, 文本: 指针): 整数
    返回 0
结束 方法
方法 aui_pad(尺寸: 整数): 整数
    边距数 = 边距数 + 1
    返回 0
结束 方法
方法 aui_gap(尺寸: 整数): 整数
    间距数 = 间距数 + 1
    返回 0
结束 方法
方法 aui_weight(宽: 整数): 整数
    权重数 = 权重数 + 1
    返回 0
结束 方法
方法 aui_end(): 整数
    返回 0
结束 方法
外部("aui_column") 方法 列(键: 整数): 整数
外部("aui_label") 方法 标签(键: 整数, 文本: 指针): 整数
外部("aui_pad") 方法 边距(尺寸: 整数): 整数
外部("aui_gap") 方法 间距(尺寸: 整数): 整数
外部("aui_weight") 方法 权重(宽: 整数): 整数
外部("aui_end") 方法 结束节点(): 整数
SRC
cat "$TMP/p43stub.ast" > "$TMP/p43a.ast"
cat >> "$TMP/p43a.ast" <<'SRC'
布局 页甲(s: 指针<应用>, 用户: 指针): 视图 {
    列 甲, 内边距(20), 间隙(8), 权重(1) {
        标签 乙, 指针("乙")
    }
}
方法 启动方法(): 整数
    变量 p: 指针<应用> = &g_app
    变量 r: 整数 = 页甲(p, p)
    如果 边距数 != 1
        返回 1
    结束 如果
    如果 间距数 != 1
        返回 2
    结束 如果
    如果 权重数 != 1
        返回 3
    结束 如果
    返回 r
结束 方法
SRC
cat "$TMP/p43stub.ast" > "$TMP/p43b.ast"
cat >> "$TMP/p43b.ast" <<'SRC'
布局 页甲(s: 指针<应用>, 用户: 指针): 视图 {
    列 甲, 权重(1), 内边距(20), 间隙(8) {
        标签 乙, 指针("乙")
    }
}
方法 启动方法(): 整数
    变量 p: 指针<应用> = &g_app
    变量 r: 整数 = 页甲(p, p)
    如果 边距数 != 1
        返回 1
    结束 如果
    如果 间距数 != 1
        返回 2
    结束 如果
    如果 权重数 != 1
        返回 3
    结束 如果
    返回 r
结束 方法
SRC
"$ASTER_BIN" build-cn-obj "$TMP/p43a.ast" -o "$TMP/p43a.o"
"$ASTER_BIN" link-obj "$TMP/p43a.o" -o "$TMP/p43a"
run_status "$TMP/p43a" 0
"$ASTER_BIN" build-cn-obj "$TMP/p43b.ast" -o "$TMP/p43b.o"
cmp "$TMP/p43a.o" "$TMP/p43b.o" || { echo "FAIL: P4-3 scrambled modifier order changed the object" >&2; exit 1; }
"$ASTER_BIN" link-obj "$TMP/p43b.o" -o "$TMP/p43b"
run_status "$TMP/p43b" 0
printf '  %-40s %s\n' 'P4-3 scrambled modifier order, byte-identical' 'ok'

# ---------------------------------------------------------------------------
printf '%s\n' '[6/7] P5-2: tail statements after the tree; let/if feeds Select'
cat > "$TMP/p52.ast" <<'SRC'
结构 应用
计数: 整数
页: 整数
语言: 整数
提醒: 整数
推广: 整数
滑杆: 整数
选择打开: 整数
结束 结构
变量 g_app: 应用 = 应用 { 0, 0, 0, 1, 0, 500, 0 }
变量 尾标: 整数 = 0
变量 列时尾标: 整数 = 0
变量 打开值: 整数 = 0
方法 aui_column(键: 整数): 整数
    列时尾标 = 尾标
    返回 0
结束 方法
方法 aui_label(键: 整数, 文本: 指针): 整数
    返回 0
结束 方法
方法 aui_select(键: 整数, 当前: 整数, 打开: 整数, 占位: 指针, 回调: 方法(指针): 整数, 用户: 指针): 整数
    打开值 = 打开
    返回 0
结束 方法
方法 aui_option(键: 整数, 文本: 指针): 整数
    返回 0
结束 方法
方法 aui_end(): 整数
    返回 0
结束 方法
外部("aui_column") 方法 列(键: 整数): 整数
外部("aui_label") 方法 标签(键: 整数, 文本: 指针): 整数
外部("aui_select") 方法 下拉选择(键: 整数, 当前: 整数, 打开: 整数, 占位: 指针, 回调: 方法(指针): 整数, 用户: 指针): 整数
外部("aui_option") 方法 选项(键: 整数, 文本: 指针): 整数
外部("aui_end") 方法 结束节点(): 整数
布局 页甲(s: 指针<应用>, 用户: 指针): 视图 {
    列 甲 {
        变量 打开: 整数 = 0
        如果 s.选择打开 == 键(语言)
            打开 = 1
        结束 如果
        下拉选择 语言, s.语言, 打开, 指针("选") {
            选项 英语, 指针("英语")
        }
        标签 乙, 指针("乙")
    }
    尾标 = 1
}
方法 启动方法(): 整数
    变量 p: 指针<应用> = &g_app
    g_app.选择打开 = -1594825719
    变量 r: 整数 = 页甲(p, p)
    如果 列时尾标 != 0
        返回 1
    结束 如果
    如果 尾标 != 1
        返回 2
    结束 如果
    如果 打开值 != 1
        返回 3
    结束 如果
    返回 r
结束 方法
SRC
"$ASTER_BIN" build-cn-obj "$TMP/p52.ast" -o "$TMP/p52.o"
"$ASTER_BIN" link-obj "$TMP/p52.o" -o "$TMP/p52"
run_status "$TMP/p52" 0
printf '  %-40s %s\n' 'P5-2 tail order + let/if feeds Select' 'ok'

# ---------------------------------------------------------------------------
printf '%s\n' '[7/7] P6-2/3 and the W-1..W-10 rejection probes'
probe_file <<'SRC' > /dev/null
事件 不存在:被单击() {
    刷新()
}
布局 页一(s: 指针<应用>, 用户: 指针): 视图 {
    列 主列 {
        标签 标题, 指针("x")
    }
}
SRC
expect_fail "P6-2 event on a nonexistent node" "事件块引用的节点 '不存在' 不存在" \
    "$ASTER_BIN" build-cn-obj "$TMP/probe.ast" -o "$TMP/probe.o"
probe_file <<'SRC' > /dev/null
事件 加:变化() {
    刷新()
}
布局 页一(s: 指针<应用>, 用户: 指针): 视图 {
    列 主列 {
        按钮 加, 指针("加")
    }
}
SRC
expect_fail "P6-3 button with change" "事件种 '变化' 不能用于节点 '加'" \
    "$ASTER_BIN" build-cn-obj "$TMP/probe.ast" -o "$TMP/probe.o"
probe_file <<'SRC' > /dev/null
事件 标题:被单击() {
    刷新()
}
布局 页一(s: 指针<应用>, 用户: 指针): 视图 {
    列 主列 {
        标签 标题, 指针("x")
    }
}
SRC
expect_fail "P6-3 label with tap (no events)" "该种不接受任何事件" \
    "$ASTER_BIN" build-cn-obj "$TMP/probe.ast" -o "$TMP/probe.o"
probe_file <<'SRC' > /dev/null
布局 页一(s: 指针<应用>, 用户: 指针): 视图 {
    列 主列 {
        数字 计数, 键(没有这个节点)
    }
}
SRC
expect_fail "W-7 key() to a nonexistent node" "键('没有这个节点') 引用的节点不存在" \
    "$ASTER_BIN" build-cn-obj "$TMP/probe.ast" -o "$TMP/probe.o"
probe_file <<'SRC' > /dev/null
布局 页一(s: 指针<应用>, 用户: 指针): 视图 {
    列 主列 {
        数字 计数, 键(1 + 2)
    }
}
SRC
expect_fail "W-7 key() with a non-identifier" "键" \
    "$ASTER_BIN" build-cn-obj "$TMP/probe.ast" -o "$TMP/probe.o"
probe_file <<'SRC' > /dev/null
事件 加:被单击() {
    变量 x: 整数 = s.计数
    刷新()
}
布局 页一(s: 指针<应用>, 用户: 指针): 视图 {
    列 主列 {
        按钮 加, 指针("加")
    }
}
SRC
expect_fail "W-4 event refs a layout param" "引用了布局局部量 's'" \
    "$ASTER_BIN" build-cn-obj "$TMP/probe.ast" -o "$TMP/probe.o"
probe_file <<'SRC' > /dev/null
事件 加:被单击() {
    变量 x: 整数 = 打开
    刷新()
}
布局 页一(s: 指针<应用>, 用户: 指针): 视图 {
    列 主列 {
        变量 打开: 整数 = 0
        按钮 加, 指针("加")
    }
}
SRC
expect_fail "W-4 event refs a layout-local var" "引用了布局局部量 '打开'" \
    "$ASTER_BIN" build-cn-obj "$TMP/probe.ast" -o "$TMP/probe.o"
probe_file <<'SRC' > /dev/null
事件 加:被单击() {
    刷新()
}
事件 加:被单击() {
    刷新()
}
布局 页一(s: 指针<应用>, 用户: 指针): 视图 {
    列 主列 {
        按钮 加, 指针("加")
    }
}
SRC
expect_fail "W-4 duplicate (key, event)" "事件块重复" \
    "$ASTER_BIN" build-cn-obj "$TMP/probe.ast" -o "$TMP/probe.o"
probe_file <<'SRC' > /dev/null
布局 页一(s: 指针<应用>, 用户: 指针): 视图 {
    列 主列, 生长(1) {
        标签 标题, 指针("x")
    }
}
SRC
expect_fail "W-3 grow has no framework call" "框架未提供 aui_grow" \
    "$ASTER_BIN" build-cn-obj "$TMP/probe.ast" -o "$TMP/probe.o"
probe_file <<'SRC' > /dev/null
布局 页一(s: 指针<应用>, 用户: 指针): 视图 {
    列 主列, 尺寸(填满, 100) {
        标签 标题, 指针("x")
    }
}
SRC
expect_fail "W-3 size fill has no encoding" "填满走 权重(1)" \
    "$ASTER_BIN" build-cn-obj "$TMP/probe.ast" -o "$TMP/probe.o"
probe_file <<'SRC' > /dev/null
布局 页一(s: 指针<应用>, 用户: 指针): 视图 {
}
SRC
expect_fail 'W-1 empty layout body' "布局 '页一' 没有节点行" \
    "$ASTER_BIN" build-cn-obj "$TMP/probe.ast" -o "$TMP/probe.o"
probe_file <<'SRC' > /dev/null
布局 启动方法(s: 指针<应用>, 用户: 指针): 视图 {
    列 主列 {
        标签 标题, 指针("x")
    }
}
SRC
expect_fail "W-1 layout named main" "布局不能命名为 'main'" \
    "$ASTER_BIN" build-cn-obj "$TMP/probe.ast" -o "$TMP/probe.o"
probe_file <<'SRC' > /dev/null
事件 加:长按() {
    刷新()
}
布局 页一(s: 指针<应用>, 用户: 指针): 视图 {
    列 主列 {
        按钮 加, 指针("加")
    }
}
SRC
expect_fail 'W-10 long press is a global gesture' "事件种 '长按' 不进事件模型" \
    "$ASTER_BIN" build-cn-obj "$TMP/probe.ast" -o "$TMP/probe.o"
probe_file <<'SRC' > /dev/null
事件 加:捏合() {
    刷新()
}
布局 页一(s: 指针<应用>, 用户: 指针): 视图 {
    列 主列 {
        按钮 加, 指针("加")
    }
}
SRC
expect_fail 'W-10 pinch is a global gesture' "事件种 '捏合' 不进事件模型" \
    "$ASTER_BIN" build-cn-obj "$TMP/probe.ast" -o "$TMP/probe.o"
probe_file <<'SRC' > /dev/null
布局 页一(s: 指针<应用>, 用户: 指针): 视图 {
    列 主列, 键 = 5 {
        标签 标题, 键 = 5, 指针("x")
    }
}
SRC
expect_fail 'W-6 explicit key collision' '节点 key 碰撞' \
    "$ASTER_BIN" build-cn-obj "$TMP/probe.ast" -o "$TMP/probe.o"
probe_file <<'SRC' > /dev/null
方法 取数(): 整数
    返回 1
结束 方法
布局 页一(s: 指针<应用>, 用户: 指针): 视图 {
    列 主列 {
        标签 标题, 取数(列 子列 {
            标签 子标, 指针("x")
        })
    }
}
SRC
expect_fail 'W-2 node row in argument position' "expected ')' after call arguments" \
    "$ASTER_BIN" build-cn-obj "$TMP/probe.ast" -o "$TMP/probe.o"

# Positive probes: W-8 explicit key override, W-3 wrap content.
cat > "$TMP/w8.ast" <<'SRC'
结构 应用
计数: 整数
页: 整数
语言: 整数
提醒: 整数
推广: 整数
滑杆: 整数
选择打开: 整数
结束 结构
变量 g_app: 应用 = 应用 { 0, 0, 0, 1, 0, 500, 0 }
变量 见键: 整数 = 0
方法 aui_column(键: 整数): 整数
    见键 = 键
    返回 0
结束 方法
方法 aui_label(键: 整数, 文本: 指针): 整数
    返回 0
结束 方法
方法 aui_end(): 整数
    返回 0
结束 方法
外部("aui_column") 方法 列(键: 整数): 整数
外部("aui_label") 方法 标签(键: 整数, 文本: 指针): 整数
外部("aui_end") 方法 结束节点(): 整数
布局 页一(s: 指针<应用>, 用户: 指针): 视图 {
    列 主列, 键 = 100 {
        标签 标题, 指针("x")
    }
}
方法 启动方法(): 整数
    变量 p: 指针<应用> = &g_app
    变量 r: 整数 = 页一(p, p)
    如果 见键 != 100
        返回 1
    结束 如果
    返回 r
结束 方法
SRC
"$ASTER_BIN" build-cn-obj "$TMP/w8.ast" -o "$TMP/w8.o"
"$ASTER_BIN" link-obj "$TMP/w8.o" -o "$TMP/w8"
run_status "$TMP/w8" 0
printf '  %-40s %s\n' 'W-8 explicit key = 100' 'ok'
cat > "$TMP/w3wrap.ast" <<'SRC'
结构 应用
计数: 整数
页: 整数
语言: 整数
提醒: 整数
推广: 整数
滑杆: 整数
选择打开: 整数
结束 结构
变量 g_app: 应用 = 应用 { 0, 0, 0, 1, 0, 500, 0 }
变量 见宽: 整数 = 0
变量 见高: 整数 = 0
方法 aui_column(键: 整数): 整数
    返回 0
结束 方法
方法 aui_size(宽: 整数, 高: 整数): 整数
    见宽 = 宽
    见高 = 高
    返回 0
结束 方法
方法 aui_end(): 整数
    返回 0
结束 方法
外部("aui_column") 方法 列(键: 整数): 整数
外部("aui_size") 方法 尺寸(宽: 整数, 高: 整数): 整数
外部("aui_end") 方法 结束节点(): 整数
布局 页一(s: 指针<应用>, 用户: 指针): 视图 {
    列 主列, 尺寸(包内容, 100) {
    }
}
方法 启动方法(): 整数
    变量 p: 指针<应用> = &g_app
    变量 r: 整数 = 页一(p, p)
    如果 见宽 != -1
        返回 1
    结束 如果
    如果 见高 != 100
        返回 2
    结束 如果
    返回 r
结束 方法
SRC
"$ASTER_BIN" build-cn-obj "$TMP/w3wrap.ast" -o "$TMP/w3wrap.o"
"$ASTER_BIN" link-obj "$TMP/w3wrap.o" -o "$TMP/w3wrap"
run_status "$TMP/w3wrap" 0
printf '  %-40s %s\n' 'W-3 size wrap content maps to -1' 'ok'

# ---------------------------------------------------------------------------
printf '%s\n' '[8/7] D-2a diagnostics follow the program language (English mirrors)'
cat > "$TMP/app-en.ast" <<'SRC'
struct App {
    count: i32,
    tab: i32,
    lang: i32,
    notify: i32,
    promo: i32,
    slider: i32,
    sel_open: i32
}
let g_app: App = App { 0, 0, 0, 1, 0, 500, 0 };
extern fn aui_column(key: i32) : i32;
extern fn aui_row(key: i32) : i32;
extern fn aui_label(key: i32, text: ptr) : i32;
extern fn aui_button(key: i32, text: ptr, cb: fn(ptr) : i32, user: ptr) : i32;
extern fn aui_text_i32(key: i32, value: i32) : i32;
extern fn aui_pad(dp: i32) : i32;
extern fn aui_gap(dp: i32) : i32;
extern fn aui_weight(w: i32) : i32;
extern fn aui_size(w: i32, h: i32) : i32;
extern fn aui_end() : i32;
extern fn aui_invalidate() : i32;
fn main() : i32 {
    return 0;
}
SRC

probe_file_en() { # reads the probe body on stdin after the shared en fixture
    cat "$TMP/app-en.ast" > "$TMP/probe-en.ast"
    cat >> "$TMP/probe-en.ast"
}

probe_file_en <<'SRC' > /dev/null
layout PageOne(s: ptr<App>, user: ptr) : View {
    Column MainCol {
        NoSuchKind Title, ptr("x")
    }
}
SRC
expect_fail 'en unknown node kind' "layout 'PageOne' node 'Title': unknown node kind 'NoSuchKind'" \
    "$ASTER_BIN" build-cn-obj --language en "$TMP/probe-en.ast" -o "$TMP/probe-en.o"
probe_file_en <<'SRC' > /dev/null
layout PageOne(s: ptr<App>, user: ptr) : View {
    Column MainCol {
        Label Title, ptr("x")
        Label Title, ptr("y")
    }
}
SRC
expect_fail 'en duplicate node name' "duplicate node name 'Title' in layout 'PageOne'" \
    "$ASTER_BIN" build-cn-obj --language en "$TMP/probe-en.ast" -o "$TMP/probe-en.o"
probe_file_en <<'SRC' > /dev/null
layout PageOne(s: ptr<App>, user: ptr) : View {
    Column MainCol, key = 5 {
        Label Title, key = 5, ptr("x")
    }
}
SRC
expect_fail 'en explicit key collision' "node key collision: node 'MainCol' of layout 'PageOne'" \
    "$ASTER_BIN" build-cn-obj --language en "$TMP/probe-en.ast" -o "$TMP/probe-en.o"
probe_file_en <<'SRC' > /dev/null
layout PageOne(s: ptr<App>, user: ptr) : View {
    Column MainCol {
        Number Count, key(Add)
    }
}
SRC
expect_fail 'en key() to a nonexistent node' "node referenced by key('Add') does not exist" \
    "$ASTER_BIN" build-cn-obj --language en "$TMP/probe-en.ast" -o "$TMP/probe-en.o"
probe_file_en <<'SRC' > /dev/null
layout PageA(s: ptr<App>, user: ptr) : View {
    Column A {
        Label Same, ptr("x")
    }
}
layout PageB(s: ptr<App>, user: ptr) : View {
    Column A {
        Label Same, ptr("x")
    }
}
fn getKey() : i32 {
    return key(Same);
}
SRC
expect_fail 'en key() is ambiguous' "key('Same') is ambiguous: multiple layouts (PageA, PageB)" \
    "$ASTER_BIN" build-cn-obj --language en "$TMP/probe-en.ast" -o "$TMP/probe-en.o"
probe_file_en <<'SRC' > /dev/null
event Inc:tap() {
    let x: i32 = s.count;
    aui_invalidate();
}
layout PageOne(s: ptr<App>, user: ptr) : View {
    Column MainCol {
        Button Inc, ptr("Inc")
    }
}
SRC
expect_fail 'en event refs a layout param' "event block 'Inc:tap' references layout-local 's'" \
    "$ASTER_BIN" build-cn-obj --language en "$TMP/probe-en.ast" -o "$TMP/probe-en.o"
probe_file_en <<'SRC' > /dev/null
event Inc:tap() {
    let cb = fn [open] (value: i32): i32 {
        return value + open;
    };
    aui_invalidate();
}
layout PageOne(s: ptr<App>, user: ptr) : View {
    Column MainCol {
        let open: i32 = 0;
        Button Inc, ptr("Inc")
    }
}
SRC
expect_fail 'en event captures a layout-local' "event block 'Inc:tap' captures layout-local 'open'" \
    "$ASTER_BIN" build-cn-obj --language en "$TMP/probe-en.ast" -o "$TMP/probe-en.o"
probe_file_en <<'SRC' > /dev/null
layout PageOne(s: ptr<App>, user: ptr) : View {
    Column MainCol, Grow(1) {
        Label Title, ptr("x")
    }
}
SRC
expect_fail 'en grow has no framework call' "modifier 'Grow' has no framework target" \
    "$ASTER_BIN" build-cn-obj --language en "$TMP/probe-en.ast" -o "$TMP/probe-en.o"
probe_file_en <<'SRC' > /dev/null
layout PageOne(s: ptr<App>, user: ptr) : View {
    Column MainCol, Padding(24), Padding(16) {
        Label Title, ptr("x")
    }
}
SRC
expect_fail 'en duplicate modifier' "duplicate modifier 'Padding' of node 'MainCol'" \
    "$ASTER_BIN" build-cn-obj --language en "$TMP/probe-en.ast" -o "$TMP/probe-en.o"
probe_file_en <<'SRC' > /dev/null
layout PageOne(s: ptr<App>, user: ptr) : View {
    Column MainCol, Padding("16dp") {
        Label Title, ptr("x")
    }
}
SRC
expect_fail 'en string dimension' "modifier 'Padding' arguments take integers only; string dimensions are not accepted" \
    "$ASTER_BIN" build-cn-obj --language en "$TMP/probe-en.ast" -o "$TMP/probe-en.o"
probe_file_en <<'SRC' > /dev/null
layout PageOne(s: ptr<App>, user: ptr) : View {
    Column MainCol, Size(Fill, 100) {
        Label Title, ptr("x")
    }
}
SRC
expect_fail 'en size fill has no encoding' "Size 'Fill' has no framework encoding: use Weight(1) instead" \
    "$ASTER_BIN" build-cn-obj --language en "$TMP/probe-en.ast" -o "$TMP/probe-en.o"
probe_file_en <<'SRC' > /dev/null
layout main(s: ptr<App>, user: ptr) : View {
    Column MainCol {
        Label Title, ptr("x")
    }
}
SRC
expect_fail 'en layout named main' "a layout cannot be named 'main' (entry method)" \
    "$ASTER_BIN" build-cn-obj --language en "$TMP/probe-en.ast" -o "$TMP/probe-en.o"
probe_file_en <<'SRC' > /dev/null
layout PageOne(s: ptr<App>, user: ptr) : View {
    Column MainCol {
        Label Title, ptr("x")
    }
}
layout PageOne(s: ptr<App>, user: ptr) : View {
    Column MainCol {
        Label Title, ptr("x")
    }
}
SRC
expect_fail 'en duplicate layout declaration' "duplicate layout declaration 'PageOne'" \
    "$ASTER_BIN" build-cn-obj --language en "$TMP/probe-en.ast" -o "$TMP/probe-en.o"
probe_file_en <<'SRC' > /dev/null
layout PageOne(s: ptr<App>, user: ptr) : View {
}
SRC
expect_fail 'en empty layout body' "layout 'PageOne' has no node rows" \
    "$ASTER_BIN" build-cn-obj --language en "$TMP/probe-en.ast" -o "$TMP/probe-en.o"
probe_file_en <<'SRC' > /dev/null
event NoSuch:tap() {
    aui_invalidate();
}
layout PageOne(s: ptr<App>, user: ptr) : View {
    Column MainCol {
        Label Title, ptr("x")
    }
}
SRC
expect_fail 'en event on a nonexistent node' "node 'NoSuch' referenced by an event block does not exist" \
    "$ASTER_BIN" build-cn-obj --language en "$TMP/probe-en.ast" -o "$TMP/probe-en.o"
probe_file_en <<'SRC' > /dev/null
event Inc:longpress() {
    aui_invalidate();
}
layout PageOne(s: ptr<App>, user: ptr) : View {
    Column MainCol {
        Button Inc, ptr("Inc")
    }
}
SRC
expect_fail 'en long press is a global gesture' "event kind 'longpress' is not part of the event model: long press / pinch are global gesture registrations" \
    "$ASTER_BIN" build-cn-obj --language en "$TMP/probe-en.ast" -o "$TMP/probe-en.o"
probe_file_en <<'SRC' > /dev/null
event Inc:NoSuchEvent() {
    aui_invalidate();
}
layout PageOne(s: ptr<App>, user: ptr) : View {
    Column MainCol {
        Button Inc, ptr("Inc")
    }
}
SRC
expect_fail 'en unknown event kind' "unknown event kind 'NoSuchEvent' (node 'Inc')" \
    "$ASTER_BIN" build-cn-obj --language en "$TMP/probe-en.ast" -o "$TMP/probe-en.o"
probe_file_en <<'SRC' > /dev/null
event Inc:change() {
    aui_invalidate();
}
layout PageOne(s: ptr<App>, user: ptr) : View {
    Column MainCol {
        Button Inc, ptr("Inc")
    }
}
SRC
expect_fail 'en button with change' "event kind 'change' cannot be used on node 'Inc' (kind 'Button', this kind only accepts tap)" \
    "$ASTER_BIN" build-cn-obj --language en "$TMP/probe-en.ast" -o "$TMP/probe-en.o"
probe_file_en <<'SRC' > /dev/null
event Title:tap() {
    aui_invalidate();
}
layout PageOne(s: ptr<App>, user: ptr) : View {
    Column MainCol {
        Label Title, ptr("x")
    }
}
SRC
expect_fail 'en label with tap (no events)' "this kind accepts no events" \
    "$ASTER_BIN" build-cn-obj --language en "$TMP/probe-en.ast" -o "$TMP/probe-en.o"
probe_file_en <<'SRC' > /dev/null
event Inc:tap() {
    aui_invalidate();
}
event Inc:tap() {
    aui_invalidate();
}
layout PageOne(s: ptr<App>, user: ptr) : View {
    Column MainCol {
        Button Inc, ptr("Inc")
    }
}
SRC
expect_fail 'en duplicate (key, event)' "duplicate event block: event 'tap' of node 'Inc' is already declared" \
    "$ASTER_BIN" build-cn-obj --language en "$TMP/probe-en.ast" -o "$TMP/probe-en.o"

echo 'PASS: bilingual declarative layout checks'
