#!/bin/sh
# Semantic checks (design §5.1 S4): the unified semantic analysis rejects
# const writes, unknown names, count-loop variable writes and zero steps.
# This is the suite named `cn-sema-checks.sh` by the design.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ASTER_BIN=${ASTER_BIN:-$ROOT/build/cn-s1-s2/aster}
if [ ! -x "$ASTER_BIN" ]; then
    echo "set ASTER_BIN to a built Aster executable" >&2
    exit 2
fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

echo '[1/4] assignment to a const is rejected'
cat > "$TMP/const-write.ast" <<'SRC'
// aster:language=zh
方法 启动方法(): 整数
常量 i: 整数 = 1
i = 2
返回 0
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/const-write.ast" -o "$TMP/const-write.o" 2>"$TMP/const-write.err"; then
    echo 'FAIL: assignment to a const was accepted' >&2
    exit 1
fi
grep -q 'cannot assign to a const: i' "$TMP/const-write.err" || {
    echo 'FAIL: expected const-assignment rejection' >&2
    exit 1
}

echo '[2/4] an unknown variable is rejected'
cat > "$TMP/unknown-var.ast" <<'SRC'
// aster:language=en
fn main(): i32 {
return missing;
}
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/unknown-var.ast" -o "$TMP/unknown-var.o" 2>"$TMP/unknown-var.err"; then
    echo 'FAIL: unknown variable was accepted' >&2
    exit 1
fi
grep -q 'unknown variable: missing' "$TMP/unknown-var.err" || {
    echo 'FAIL: expected unknown-variable rejection' >&2
    exit 1
}

echo '[3/4] the count-loop variable cannot be assigned in the loop body'
cat > "$TMP/count-modify.ast" <<'SRC'
// aster:language=zh
方法 启动方法(): 整数
变量 total: 整数 = 0
计次循环 (i = 1, 3)
i = 5
结束 计次循环
返回 total
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/count-modify.ast" -o "$TMP/count-modify.o" 2>"$TMP/count-modify.err"; then
    echo 'FAIL: count-loop variable assignment was accepted' >&2
    exit 1
fi
grep -q 'cannot assign to a const: i' "$TMP/count-modify.err" || {
    echo 'FAIL: expected count-loop variable rejection' >&2
    exit 1
}

echo '[4/4] a constant zero count-loop step is rejected'
cat > "$TMP/zero-step.ast" <<'SRC'
// aster:language=zh
方法 启动方法(): 整数
计次循环 (i = 1, 2, 0)
返回 i
结束 计次循环
返回 0
结束 方法
SRC
if "$ASTER_BIN" build-cn-obj "$TMP/zero-step.ast" -o "$TMP/zero-step.o" 2>"$TMP/zero-step.err"; then
    echo 'FAIL: zero count-loop step was accepted' >&2
    exit 1
fi
grep -q 'counting-loop step cannot be zero' "$TMP/zero-step.err" || {
    echo 'FAIL: expected zero-step rejection' >&2
    exit 1
}

echo 'PASS: bilingual semantic checks'
