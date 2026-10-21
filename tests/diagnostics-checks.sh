#!/bin/sh
# Source-level diagnostic checks (P4.1).
#
# Verifies that a compile error carrying a " at L:C" location now ALSO prints
# the offending source line and a "^" caret aligned under the reported column,
# while the original message text (the part the rest of the suite greps for)
# is preserved verbatim.
#
# This began with parse/lexer errors and was completed (v0.23.10-dev) by
# threading source positions through the AST, so the semantic pass (Sema) and
# the global-declaration checks report the same source line + caret. A
# genuinely location-less diagnostic (the function-level fall-through check)
# still prints a single compact line with no spurious source echo.
set -eu
CXX=${CXX:-g++}
$CXX -std=c++17 -O2 -Wall -Wextra -pedantic src/aster.cpp -o aster

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# A parse error with a deterministic location. The oversized literal lands at
# column 27 of line 1 (verified by aster's own "file:1:27:" prefix below).
cat > "$WORK/huge.ast" <<'AST'
fn main() -> i32 { return 999999999999999999999999999; }
AST

out=$(./aster build-elf "$WORK/huge.ast" -o "$WORK/x" 2>&1 || true)

echo "$out"

# 1) The original message text is still present (backward compatibility).
printf '%s\n' "$out" | grep -qF 'integer literal is too large at 1:27' \
    || { echo "FAIL: original diagnostic message missing"; exit 1; }

# 2) The source line is echoed.
printf '%s\n' "$out" | grep -qF 'fn main() -> i32 { return 999999999999999999999999999; }' \
    || { echo "FAIL: offending source line not echoed"; exit 1; }

# 3) Parse the column aster reports, then verify the caret is aligned there.
col=$(printf '%s\n' "$out" | sed -n 's/.*:1:\([0-9][0-9]*\): error:.*/\1/p' | head -1)
[ -n "$col" ] || { echo "FAIL: could not read column from diagnostic"; exit 1; }

# The caret line is the line immediately after the echoed source line.
src_line='fn main() -> i32 { return 999999999999999999999999999; }'
caret_line=$(printf '%s\n' "$out" | awk -v src="$src_line" '
    found && !seen { print; seen=1; next }
    index($0, src) > 0 { found=1 }
')
[ -n "$caret_line" ] || { echo "FAIL: caret line not found"; exit 1; }

# Expected: 4-space indent + (col-1) spaces + a single "^".
expected_spaces=$((4 + col - 1))
case "$caret_line" in
    $(printf '%*s' "$expected_spaces" '')^)
        ;;
    *)
        echo "FAIL: caret not aligned to column $col (got: [$caret_line])"
        exit 1
        ;;
esac

# 4) A located error on a non-first line also works: the caret lands on the
#    right physical line, and realigns to whatever column aster reports there.
cat > "$WORK/ml.ast" <<'AST'
fn f() -> i32 { return 1; }
fn g() -> i32 { return 999999999999999999999999999; }
fn main() -> i32 { return 0; }
AST
out2=$(./aster build-elf "$WORK/ml.ast" -o "$WORK/x" 2>&1 || true)
line2=$(printf '%s\n' "$out2" | sed -n 's/.*:\([0-9][0-9]*\):\([0-9][0-9]*\): error:.*/\1/p' | head -1)
col2=$(printf '%s\n' "$out2" | sed -n 's/.*:\([0-9][0-9]*\):\([0-9][0-9]*\): error:.*/\2/p' | head -1)
[ "$line2" = "2" ] || { echo "FAIL: multi-line error should report line 2 (got $line2)"; exit 1; }
printf '%s\n' "$out2" | grep -qF 'fn g() -> i32 { return 999999999999999999999999999; }' \
    || { echo "FAIL: multi-line offending source line not echoed"; exit 1; }
src_line2='fn g() -> i32 { return 999999999999999999999999999; }'
caret_line2=$(printf '%s\n' "$out2" | awk -v src="$src_line2" '
    found && !seen { print; seen=1; next }
    index($0, src) > 0 { found=1 }
')
exp2=$((4 + col2 - 1))
case "$caret_line2" in
    $(printf '%*s' "$exp2" '')^) ;;
    *) echo "FAIL: multi-line caret not aligned to column $col2 (got: [$caret_line2])"; exit 1 ;;
esac

# 5) A SEMANTIC error now carries a location too (v0.23.10-dev, P4.1补全):
#    the Sema pass reports the offending token, so the source line is echoed
#    and the caret lands under the variable. The message text is preserved, so
#    the substring `grep -F` assertions in sema-checks/bool-checks/struct-checks
#    keep matching unchanged.
cat > "$WORK/sem.ast" <<'AST'
fn main() -> i32 {
    let ok: bool = 5;
    return 0;
}
AST
out3=$(./aster build-elf "$WORK/sem.ast" -o "$WORK/x" 2>&1 || true)
echo "$out3"
printf '%s\n' "$out3" | grep -qF "type mismatch initializing 'ok': expected bool" \
    || { echo "FAIL: semantic error message missing"; exit 1; }
line3=$(printf '%s\n' "$out3" | sed -n 's/.*:\([0-9][0-9]*\):\([0-9][0-9]*\): error:.*/\1/p' | head -1)
col3=$(printf '%s\n' "$out3" | sed -n 's/.*:\([0-9][0-9]*\):\([0-9][0-9]*\): error:.*/\2/p' | head -1)
[ "$line3" = "2" ] || { echo "FAIL: semantic error should report line 2 (got $line3)"; exit 1; }
src_line3='    let ok: bool = 5;'
printf '%s\n' "$out3" | grep -qF "$src_line3" \
    || { echo "FAIL: semantic error offending source line not echoed"; exit 1; }
caret_line3=$(printf '%s\n' "$out3" | awk -v src="$src_line3" '
    found && !seen { print; seen=1; next }
    index($0, src) > 0 { found=1 }
')
[ -n "$caret_line3" ] || { echo "FAIL: semantic caret line not found"; exit 1; }
exp3=$((4 + col3 - 1))
case "$caret_line3" in
    $(printf '%*s' "$exp3" '')^) ;;
    *) echo "FAIL: semantic caret not aligned to column $col3 (got: [$caret_line3])"; exit 1 ;;
esac

# 6) A genuinely location-less diagnostic still prints compactly: the
#    function-level fall-through check names no single source token, so it must
#    NOT echo a source line or a caret.
cat > "$WORK/ft.ast" <<'AST'
fn main() -> i32 {
    let x: i32 = 1;
}
AST
out4=$(./aster build-elf "$WORK/ft.ast" -o "$WORK/x" 2>&1 || true)
printf '%s\n' "$out4" | grep -qF "may fall through without returning" \
    || { echo "FAIL: fall-through diagnostic missing"; exit 1; }
lines4=$(printf '%s\n' "$out4" | wc -l)
[ "$lines4" -eq 1 ] || { echo "FAIL: location-less error should print exactly one line (got $lines4)"; exit 1; }

echo "PASS: parse + semantic errors show source line and aligned caret; location-less errors stay compact"
