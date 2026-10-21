#!/bin/sh
# .debug_line checks (P4.2).
#
# `-g` / `--debug-line` makes aster emit a DWARF v4 line-number table, so a
# debugger can answer "which .ast line is this instruction?" and "where does a
# breakpoint for line N go?". This suite proves four things:
#
#   1. THE TABLE IS CORRECT, not merely present: a decoder written for this
#      suite (tests/debugline-decode.py) reads the section straight out of the
#      ELF and the rows it produces are checked against the source — every
#      statement line must appear, and no line that holds no statement may.
#   2. THE ENCODING IS REAL DWARF: when llvm-dwarfdump is installed it decodes
#      the same file and the two must agree row for row. Two independent
#      readers agreeing is the whole point of a standard format.
#   3. CODEGEN DOES NOT MOVE: the .text bytes of a -g build are byte-identical
#      to those of the same build without -g. Debug output is additive.
#   4. IT IS OFF BY DEFAULT: without -g there is no .debug_line anywhere, in
#      an executable, a PIE, an object, or a shared object.
#   5. THE LINKER CARRIES IT: one unit per input object, each raised to that
#      object's final text address, and a shared object keeps the table too.
set -eu
cd "$(dirname "$0")/.."
CXX=${CXX:-g++}
OUT=${OUT:-tmp-debugline-checks}
rm -rf "$OUT"; mkdir -p "$OUT"
trap 'rm -rf "$OUT"' EXIT

$CXX -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp -o "$OUT/aster"
ASTER="$OUT/aster"

if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: python3 is required to decode .debug_line"
    exit 0
fi
DECODE="python3 tests/debugline-decode.py"

# A source whose statement lines are known exactly. Every line below either
# carries a statement (and must appear in the table) or does not (and must
# not): blank lines, the closing braces, and the declarations that are not
# themselves statements.
cat > "$OUT/lines.ast" <<'AST'
fn helper(n: i32) -> i32 {
    let t: i32 = n * 2;
    return t + 1;
}

fn main() -> i32 {
    let a: i32 = 10;
    let b: i32 = helper(a);
    if (b > 20) {
        return 1;
    } else {
        return 0;
    }
}
AST
# Lines with a statement (or a function prologue): 1,2,3,6,7,8,9,10,12.
WANT_LINES="1 2 3 6 7 8 9 10 12"
TOTAL_LINES=14

fail() { echo "FAIL: $1"; exit 1; }

# --- 1. off by default: no .debug_line anywhere -----------------------------------
$ASTER build-elf "$OUT/lines.ast" -o "$OUT/plain.elf" >/dev/null
$ASTER build-pie "$OUT/lines.ast" -o "$OUT/plain.pie" >/dev/null
$ASTER build-obj "$OUT/lines.ast" -o "$OUT/plain.o" >/dev/null
$ASTER build-so  "$OUT/lines.ast" --soname libplain.so -o "$OUT/plain.so" >/dev/null
for f in plain.elf plain.pie plain.o plain.so; do
    readelf -S "$OUT/$f" | grep -q '\.debug_line' \
        && fail "default build of $f must not carry .debug_line"
done

# --- 2. -g adds it, and .text does not move ---------------------------------------
$ASTER build-elf "$OUT/lines.ast" -g -o "$OUT/dbg.elf" >/dev/null
readelf -S "$OUT/dbg.elf" | grep -q '\.debug_line' \
    || fail "-g build has no .debug_line section"

# The code is the same bytes either way: debug output is strictly additive.
readelf -x .text "$OUT/plain.elf" > "$OUT/text.plain"
readelf -x .text "$OUT/dbg.elf"   > "$OUT/text.dbg"
cmp -s "$OUT/text.plain" "$OUT/text.dbg" \
    || fail "-g changed the .text bytes (diff follows)"$'\n'"$(diff "$OUT/text.plain" "$OUT/text.dbg" | head -5)"

# --- 3. the rows are correct --------------------------------------------------------
$DECODE "$OUT/dbg.elf" > "$OUT/rows.txt"
[ -s "$OUT/rows.txt" ] || fail "decoder produced no rows"

# 3a. Every line in the table is a real line of the source, and the file is ours.
while read -r addr line path; do
    case "$path" in
        */lines.ast) ;;
        *) fail "row $addr names an unexpected file: $path" ;;
    esac
    if [ "$line" -lt 1 ] || [ "$line" -gt "$TOTAL_LINES" ]; then
        fail "row $addr names line $line, outside 1..$TOTAL_LINES"
    fi
done < "$OUT/rows.txt"

# 3b. Exactly the statement lines appear — no more, no fewer.
got=$(awk '{print $2}' "$OUT/rows.txt" | sort -n -u | tr '\n' ' ' | sed 's/ *$//')
want=$(echo "$WANT_LINES" | tr ' ' '\n' | sort -n -u | tr '\n' ' ' | sed 's/ *$//')
[ "$got" = "$want" ] || fail "line set mismatch: table has [$got], source has [$want]"

# 3c. Addresses ascend, and every one of them lands inside .text.
text_addr=$(readelf -S -W "$OUT/dbg.elf" | awk '$3==".text"{print "0x"$5; exit}')
text_size=$(readelf -S -W "$OUT/dbg.elf" | awk '$3==".text"{print "0x"$7; exit}')
text_end=$(printf '0x%x\n' $(( text_addr + text_size )))
prev=0
while read -r addr line path; do
    a=$((addr))
    [ "$a" -ge "$((prev))" ] || fail "addresses are not ascending at $addr"
    [ "$a" -ge "$((text_addr))" ] || fail "row $addr is below .text ($text_addr)"
    [ "$a" -lt "$((text_end))" ] || fail "row $addr is past the end of .text ($text_end)"
    prev=$a
done < "$OUT/rows.txt"

# --- 4. an independent reader agrees (external witness) ----------------------------
if command -v llvm-dwarfdump >/dev/null 2>&1; then
    llvm-dwarfdump --debug-line "$OUT/dbg.elf" > "$OUT/llvm.txt" 2>&1 \
        || fail "llvm-dwarfdump could not decode the table"
    # Two independent readers of the same bytes must agree row for row.
    # llvm prints the end_sequence row as well; the suite decoder drops it
    # (it marks where a sequence ends, not a statement), so drop it here too.
    if ! python3 - "$OUT/llvm.txt" "$OUT/rows.txt" <<'PY'
import re, sys

PAT = r'^(0x[0-9a-fA-F]+)\s+(\d+)\s'


def rows(path, skip_end_sequence):
    out = set()
    with open(path) as fh:
        for line in fh:
            if skip_end_sequence and "end_sequence" in line:
                continue
            m = re.match(PAT, line)
            if m:
                out.add((int(m.group(1), 16), int(m.group(2))))
    return out


llvm = rows(sys.argv[1], True)
ours = rows(sys.argv[2], False)
if llvm != ours:
    print("llvm-dwarfdump only:", sorted(llvm - ours))
    print("suite decoder only:", sorted(ours - llvm))
    sys.exit(1)
PY
    then
        fail "llvm-dwarfdump disagrees with the suite decoder"
    fi

    # The sequence must end exactly where .text ends.
    ends=$(python3 - "$OUT/llvm.txt" <<'PY'
import re, sys
out = []
for line in open(sys.argv[1]):
    if "end_sequence" in line:
        m = re.match(r'^(0x[0-9a-fA-F]+)', line)
        if m:
            out.append(int(m.group(1), 16))
print(" ".join("0x%x" % a for a in out))
PY
    )
    [ "$ends" = "$text_end" ] \
        || fail "the line sequence ends at $ends, but .text ends at $text_end"
else
    echo "note: llvm-dwarfdump not installed — skipping the cross-reader check"
fi

# --- 5. PIE: same lines, addresses relative to the image ---------------------------
$ASTER build-pie "$OUT/lines.ast" -g -o "$OUT/dbg.pie" >/dev/null
$DECODE "$OUT/dbg.pie" > "$OUT/rows.pie"
got=$(awk '{print $2}' "$OUT/rows.pie" | sort -n -u | tr '\n' ' ' | sed 's/ *$//')
[ "$got" = "$want" ] || fail "PIE line set mismatch: [$got]"
pie_addr=$(awk 'NR==1{print $1}' "$OUT/rows.pie")
pie_num=$((pie_addr))
[ "$pie_num" -lt $((0x100000)) ] || fail "PIE rows look like fixed addresses ($pie_addr)"

# --- 6. a relocatable object carries the table and says how to fix it --------------
$ASTER build-obj "$OUT/lines.ast" -g -o "$OUT/dbg.o" >/dev/null
readelf -S "$OUT/dbg.o" | grep -q '\.debug_line'      || fail "object has no .debug_line"
readelf -S "$OUT/dbg.o" | grep -q '\.rela\.debug_line' || fail "object has no .rela.debug_line"
readelf -r "$OUT/dbg.o" | awk '/\.rela\.debug_line/,/^$/' | grep -q 'R_AARCH64_ABS64' \
    || fail ".rela.debug_line has no R_AARCH64_ABS64 relocation"
readelf -r "$OUT/dbg.o" | awk '/\.rela\.debug_line/,/^$/' | grep -q '\.text' \
    || fail ".rela.debug_line does not reference the .text section symbol"

# --- 7. linking two objects keeps one unit per object, each at its own address -----
cat > "$OUT/defs.ast" <<'AST'
let total: i32 = 7;

fn add2(n: i32) -> i32 {
    return n + 2;
}
AST
cat > "$OUT/main.ast" <<'AST'
extern let total: i32;
extern fn add2(n: i32) -> i32;

fn main() -> i32 {
    return add2(total);
}
AST
$ASTER build-obj "$OUT/main.ast" -g -o "$OUT/a.o" >/dev/null
$ASTER build-obj "$OUT/defs.ast" -g -o "$OUT/b.o" >/dev/null
$ASTER link-obj "$OUT/a.o" "$OUT/b.o" -o "$OUT/linked.elf" >/dev/null
$DECODE --units "$OUT/linked.elf" > "$OUT/units.txt"
[ "$(wc -l < "$OUT/units.txt")" -eq 2 ] || fail "expected one unit per object, got $(wc -l < "$OUT/units.txt")"
grep -q 'main\.ast' "$OUT/units.txt" || fail "unit for the main object is missing"
grep -q 'defs\.ast' "$OUT/units.txt" || fail "unit for the defs object is missing"

# The second object's rows must start at or after where the first one's end, and
# each unit's line numbers must match its own source.
main_end=$(awk '/main\.ast/{print $3}' "$OUT/units.txt")
defs_start=$(awk '/defs\.ast/{print $2}' "$OUT/units.txt")
[ $((defs_start)) -ge $((main_end)) ] \
    || fail "second unit starts at $defs_start, before the first ends at $main_end"
$DECODE "$OUT/linked.elf" > "$OUT/rows.link"
# main.ast: the prologue at line 4, the return at line 5.  defs.ast: 3 and 4.
grep -q 'main\.ast' "$OUT/rows.link" || fail "no rows for the main object"
for pair in "4 main.ast" "5 main.ast" "3 defs.ast" "4 defs.ast"; do
    set -- $pair
    grep -qE "^0x[0-9a-f]+ $1 .*$2\$" "$OUT/rows.link" \
        || fail "linked table is missing line $1 of $2"
done

# --- 8. a shared object keeps the table too ---------------------------------------
$ASTER build-so "$OUT/lines.ast" --soname liblines.so -g -o "$OUT/dbg.so" >/dev/null
readelf -S "$OUT/dbg.so" | grep -q '\.debug_line' || fail "shared object has no .debug_line"
$DECODE "$OUT/dbg.so" > "$OUT/rows.so"
got=$(awk '{print $2}' "$OUT/rows.so" | sort -n -u | tr '\n' ' ' | sed 's/ *$//')
[ "$got" = "$want" ] || fail "shared-object line set mismatch: [$got]"

# --- 9. the suite can still fail ---------------------------------------------------
# A test that cannot fail is decoration. Shift every recorded line by one and
# require the assertion above to notice; if the injected change ever stops
# applying, this step fails so the guard gets fixed instead of quietly passing.
sed 's|if(emitLineInfo&&s.line!=0)lineRows.push_back({(uint32_t)code.size(),s.line});|if(emitLineInfo\&\&s.line!=0)lineRows.push_back({(uint32_t)code.size(),s.line+1});|' \
    src/aster.cpp > "$OUT/mutant.cpp"
grep -q 's.line+1' "$OUT/mutant.cpp" \
    || fail "the off-by-one mutation no longer applies to src/aster.cpp"
$CXX -std=c++17 -O2 -w "$OUT/mutant.cpp" -o "$OUT/aster-mutant"
"$OUT/aster-mutant" build-elf "$OUT/lines.ast" -g -o "$OUT/mutant.elf" >/dev/null
$DECODE "$OUT/mutant.elf" > "$OUT/rows.mutant"
mut=$(awk '{print $2}' "$OUT/rows.mutant" | sort -n -u | tr '\n' ' ' | sed 's/ *$//')
[ "$mut" != "$want" ] \
    || fail "an off-by-one in the recorded source line went unnoticed"

echo "PASS: -g emits a correct DWARF v4 .debug_line (statement lines match the source, codegen unchanged, off by default, carried through link and .so)"
