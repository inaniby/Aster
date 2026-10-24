#!/bin/sh
# .debug_info checks (P4.3).
#
# `-g` makes aster emit DWARF v4 .debug_abbrev and .debug_info beside the line
# table it already wrote, so a debugger can print a variable by name and not
# only say which .ast line an instruction came from. This suite proves nine
# things:
#
#   1. IT IS OFF BY DEFAULT: without -g there is no .debug_info in an
#      executable, a PIE, an object or a shared object.
#   2. IT IS ADDITIVE: -g adds the sections without moving a single byte of
#      .text, and a relocatable object says how to fix the addresses up.
#   3. THE UNIT IS ANCHORED: one compile unit whose low_pc and high_pc are the
#      .text section's own address and length, read back from readelf rather
#      than trusted, and whose producer names the version that wrote it.
#   4. EVERY FUNCTION IS A SUBPROGRAM: one DIE per function whose low_pc and
#      size are the values its own symbol has in the symbol table, whose frame
#      base is SP, and whose decl_line is the line `fn` is written on.
#   5. EVERY VARIABLE IS REACHABLE: a parameter or local is described from the
#      frame base, in ascending 8-byte slots starting at the frame base, with
#      the type it was declared with and the line it was declared on; a global
#      is described by an absolute address that is the one its symbol has.
#   6. THE TYPES ARE REAL: base types carry a size and an encoding, a struct
#      carries its byte size and each member's offset, an array carries the
#      element count, and a pointer names what it points at.
#   7. AN INDEPENDENT READER AGREES: when llvm-dwarfdump is installed it reads
#      the same bytes and must describe the same functions and variables.
#   8. IT SURVIVES LINKING: two objects produce two units, each raised to its
#      own text address, and both a gnu-hash and a plain shared object keep
#      theirs.
#   9. THE SUITE CAN STILL FAIL.
set -eu
cd "$(dirname "$0")/.."
CXX=${CXX:-g++}
OUT=${OUT:-tmp-debuginfo-checks}
rm -rf "$OUT"; mkdir -p "$OUT"
trap 'rm -rf "$OUT"' EXIT

$CXX -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp -o "$OUT/aster"
ASTER="$OUT/aster"
# The version the producer string must name, read from the source rather than
# from a hard-coded literal, so bumping it cannot quietly break this check.
VER=$(sed -n 's/^#define ASTER_VERSION_STRING "\(.*\)"$/\1/p' src/aster.cpp | head -1)
[ -n "$VER" ] || { echo "FAIL: could not read ASTER_VERSION_STRING"; exit 1; }

if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: python3 is required to decode .debug_info"
    exit 0
fi
DECODE="python3 tests/debuginfo-decode.py"

# A source whose declarations are known exactly: two functions (one with a
# parameter, one with five locals), three globals in two different segments,
# a struct, two arrays — one of them two-dimensional — and two pointers, one
# untyped. Every line below is either a declaration this suite checks or fill.
SRC="$OUT/dbg.ast"
cat > "$SRC" <<'AST'
struct Point { x: i32, y: i32 }

let gcounter: i32 = 7;
let gscores: i32[2] = 0;
let ggrid: i32[2][3] = 0;

fn scale(p: Point, k: i32) -> i32 {
    let t: i32 = p.x * k;
    return t;
}

fn main() -> i32 {
    let a: i32 = 10;
    let arr: i32[3] = 0;
    let pt: Point = Point { 1, 2 };
    let q: ptr = &pt;
    let r: ptr<Point> = &pt;
    arr[0] = 3;
    return scale(pt, a) + gcounter + arr[0] + ggrid[0][0];
}
AST
SRCDIR=$(dirname "$SRC")
NFUNCS=2

fail() { echo "FAIL: $1"; exit 1; }
# A hex string in one notation or the other, compared as a number.
eqaddr() { [ $(( $1 )) -eq $(( $2 )) ] || fail "$3 ($1 vs $2)"; }
section_addr() { readelf -S -W "$1" | awk -v n="$2" '$3==n{print "0x"$5; exit}'; }
section_size() { readelf -S -W "$1" | awk -v n="$2" '$3==n{print "0x"$7; exit}'; }
symbol() { readelf -sW "$1" | awk -v t="$2" -v n="$3" '$4==t && $8==n {print $2 " " $3; exit}'; }

# --- 1. off by default: no .debug_info anywhere -----------------------------------
$ASTER build-elf "$SRC" -o "$OUT/plain.elf" >/dev/null
$ASTER build-pie "$SRC" -o "$OUT/plain.pie" >/dev/null
$ASTER build-obj "$SRC" -o "$OUT/plain.o"   >/dev/null
$ASTER build-so  "$SRC" --soname libplain.so -o "$OUT/plain.so" >/dev/null
for f in plain.elf plain.pie plain.o plain.so; do
    readelf -S "$OUT/$f" | grep -q '\.debug_info' \
        && fail "default build of $f must not carry .debug_info"
    readelf -S "$OUT/$f" | grep -q '\.debug_abbrev' \
        && fail "default build of $f must not carry .debug_abbrev"
done

# --- 2. -g adds it, and .text does not move ---------------------------------------
$ASTER build-elf "$SRC" -g -o "$OUT/dbg.elf" >/dev/null
readelf -S "$OUT/dbg.elf" | grep -q '\.debug_info'   || fail "-g build has no .debug_info"
readelf -S "$OUT/dbg.elf" | grep -q '\.debug_abbrev' || fail "-g build has no .debug_abbrev"

# Debug output is strictly additive: the code is the same bytes either way.
readelf -x .text "$OUT/plain.elf" > "$OUT/text.plain"
readelf -x .text "$OUT/dbg.elf"   > "$OUT/text.dbg"
cmp -s "$OUT/text.plain" "$OUT/text.dbg" \
    || fail "-g changed the .text bytes (diff follows)"$'\n'"$(diff "$OUT/text.plain" "$OUT/text.dbg" | head -5)"

# A relocatable object carries the unit and says how to fix its addresses up.
$ASTER build-obj "$SRC" -g -o "$OUT/dbg.o" >/dev/null
readelf -S "$OUT/dbg.o" | grep -q '\.debug_info'      || fail "object has no .debug_info"
readelf -S "$OUT/dbg.o" | grep -q '\.rela\.debug_info' || fail "object has no .rela.debug_info"
readelf -r "$OUT/dbg.o" | awk '/\.rela\.debug_info/,/^$/' | grep -q 'R_AARCH64_ABS64' \
    || fail ".rela.debug_info has no R_AARCH64_ABS64 relocation"
readelf -r "$OUT/dbg.o" | awk '/\.rela\.debug_info/,/^$/' | grep -q '\.text' \
    || fail ".rela.debug_info does not reference the .text section symbol"
readelf -r "$OUT/dbg.o" | awk '/\.rela\.debug_info/,/^$/' | grep -q 'scale' \
    || fail ".rela.debug_info does not reference the function symbol it describes"

# --- 3. the compile unit is anchored to .text ---------------------------------------
$DECODE "$OUT/dbg.elf" > "$OUT/tree.txt"
$DECODE --units "$OUT/dbg.elf" > "$OUT/units.txt"
[ "$(wc -l < "$OUT/units.txt")" -eq 1 ] || fail "expected exactly one unit, got $(wc -l < "$OUT/units.txt")"
set -- $(cat "$OUT/units.txt")
[ "$1" = "dbg.ast" ] || fail "the unit is named $1, not dbg.ast"
eqaddr "$2" "$(section_addr "$OUT/dbg.elf" .text)" "the unit's low_pc is not the address of .text"
eqaddr "$3" "$(section_size "$OUT/dbg.elf" .text)" "the unit's high_pc is not the length of .text"

culine=$(grep '^COMPILE_UNIT ' "$OUT/tree.txt" || true)
[ -n "$culine" ] || fail "no compile unit DIE"
case "$culine" in *"producer=Aster v$VER "*) : ;; *) fail "the producer does not name $VER: $culine" ;; esac
case "$culine" in *"language=DW_LANG_C89 "*) : ;; *) fail "the language is not DW_LANG_C89: $culine" ;; esac
case "$culine" in *"name=dbg.ast "*)         : ;; *) fail "the unit does not name the source: $culine" ;; esac
case "$culine" in *"comp_dir=$SRCDIR "*)     : ;; *) fail "comp_dir is not $SRCDIR: $culine" ;; esac
case "$culine" in *"stmt_list=0")            : ;; *) fail "the unit does not point at the line table: $culine" ;; esac

# --- 4. one subprogram per function, agreeing with the symbol table -----------------
$DECODE --functions "$OUT/dbg.elf" | sort > "$OUT/funcs.txt"
[ "$(wc -l < "$OUT/funcs.txt")" -eq "$NFUNCS" ] \
    || fail "expected one subprogram per function, got $(wc -l < "$OUT/funcs.txt")"
while read -r name low size dline; do
    sym=$(symbol "$OUT/dbg.elf" FUNC "$name")
    [ -n "$sym" ] || fail "no FUNC symbol for $name"
    set -- $sym
    eqaddr "$low"  "0x$1" "subprogram $name starts at $low but its symbol is at 0x$1"
    [ $((size)) -eq "$2" ] || fail "subprogram $name is $size bytes, its symbol says $2"
    want=$(grep -n "^fn $name" "$SRC" | head -1 | cut -d: -f1)
    [ "$dline" = "$want" ] || fail "subprogram $name says line $dline, the source says $want"
done < "$OUT/funcs.txt"
# The frame base is SP: Aster's frame is a fixed 8192 bytes and SP does not move
# again inside a body, so no CFA rules are needed to read a slot.
nfb=$(grep -c 'frame_base=breg31+0' "$OUT/tree.txt" || true)
[ "$nfb" -eq "$NFUNCS" ] || fail "expected $NFUNCS frame bases of breg31+0, got $nfb"

# --- 5. every variable is reachable -------------------------------------------------
$DECODE --vars "$OUT/dbg.elf" > "$OUT/vars.txt"
: > "$OUT/offs.txt"; : > "$OUT/globals.txt"
while read -r scope name kind type loc line; do
    case "$kind" in
    global)
        # A global's address must be the address its own symbol has.
        a=${loc#addr(0x}; a=${a%)}
        sym=$(symbol "$OUT/dbg.elf" OBJECT "$name")
        [ -n "$sym" ] || fail "no OBJECT symbol for global $name"
        set -- $sym
        eqaddr "0x$a" "0x$1" "global $name is at 0x$a but its symbol is at 0x$1"
        echo "$name $type" >> "$OUT/globals.txt"
        ;;
    local|param)
        case "$loc" in fbreg+*|fbreg-*) : ;; *) fail "$scope.$name is not described from the frame base ($loc)" ;; esac
        if [ "$kind" = param ]; then
            want=$(grep -n "^fn $scope" "$SRC" | head -1 | cut -d: -f1)
        else
            want=$(grep -n "let $name:" "$SRC" | head -1 | cut -d: -f1)
        fi
        [ -n "$want" ] || fail "no declaration line for $scope.$name"
        [ "$line" = "$want" ] || fail "$scope.$name says line $line, the source says $want"
        echo "$scope ${loc#fbreg}" >> "$OUT/offs.txt"
        ;;
    *) fail "unexpected variable kind '$kind'" ;;
    esac
done < "$OUT/vars.txt"

# The frame is one 8-byte slot per value: the offsets must ascend in eighths,
# and the first variable of each function must sit at the frame base itself.
if ! awk '{ if ($2 % 8 != 0) { print "not a slot multiple: " $0; exit 1 }
            if ($1 == pk && $2 < pv + 8) { print "not ascending: " $0; exit 1 }
            if ($1 != pk && $2 != 0) { print "does not start at the frame base: " $0; exit 1 }
            pk = $1; pv = $2 }' "$OUT/offs.txt" > "$OUT/order.err" 2>&1
then fail "frame offsets are wrong: $(cat "$OUT/order.err")"; fi

# Names, kinds, types and declaration lines, exactly as written in the source.
grep -v ' global ' "$OUT/vars.txt" | awk '{print $1,$2,$3,$4,$6}' | sort > "$OUT/vars.got"
cat > "$OUT/vars.want" <<'WANT'
main a local i32 13
main arr local i32[3] 14
main pt local Point 15
main q local ptr<void> 16
main r local ptr<Point> 17
scale k param i32 7
scale p param Point 7
scale t local i32 8
WANT
sort -o "$OUT/vars.want" "$OUT/vars.want"
cmp -s "$OUT/vars.got" "$OUT/vars.want" \
    || fail "locals and parameters do not match the source:"$'\n'"$(diff "$OUT/vars.want" "$OUT/vars.got" | head -10)"
sort -o "$OUT/globals.txt" "$OUT/globals.txt"
cat > "$OUT/globals.want" <<'WANT'
gcounter i32
ggrid i32[2][3]
gscores i32[2]
WANT
cmp -s "$OUT/globals.txt" "$OUT/globals.want" \
    || fail "globals do not match the source:"$'\n'"$(diff "$OUT/globals.want" "$OUT/globals.txt" | head -10)"

# --- 6. the type DIEs describe what was declared -------------------------------------
grep -q '^  BASE_TYPE name=i32 byte_size=4 encoding=5' "$OUT/tree.txt" \
    || fail "no four-byte signed base type named i32"
grep -q '^  STRUCTURE_TYPE name=Point byte_size=8' "$OUT/tree.txt" \
    || fail "struct Point is not eight bytes"
grep -q '^    MEMBER name=x type=i32 data_member_location=0' "$OUT/tree.txt" \
    || fail "member x is not at offset 0"
grep -q '^    MEMBER name=y type=i32 data_member_location=4' "$OUT/tree.txt" \
    || fail "member y is not at offset 4"
grep -q '^  POINTER_TYPE byte_size=8 type=void' "$OUT/tree.txt" \
    || fail "an untyped ptr is not an eight-byte pointer to an unspecified type"
grep -q '^  POINTER_TYPE byte_size=8 type=Point' "$OUT/tree.txt" \
    || fail "ptr<Point> is not an eight-byte pointer to Point"
grep -q '^  UNSPECIFIED_TYPE' "$OUT/tree.txt" \
    || fail "the target of an untyped ptr is missing"
# i32[3] is a subrange of 0..2; i32[2][3] is two of those, spelled as an array
# whose element type is itself an array — the C reading, and the one a debugger
# prints as i32[2][3].
grep -q '^  ARRAY_TYPE type=i32$' "$OUT/tree.txt" || fail "no array of i32"
grep -q '^    SUBRANGE_TYPE upper_bound=2' "$OUT/tree.txt" || fail "i32[3] has no subrange of 3"
grep -q '^  ARRAY_TYPE type=i32\[3\]$' "$OUT/tree.txt" || fail "i32[2][3] is not an array of i32[3]"
grep -q 'bad-ref' "$OUT/tree.txt" && fail "a DW_AT_type points outside the unit"

# --- 7. an independent reader agrees (external witness) ------------------------------
if command -v llvm-dwarfdump >/dev/null 2>&1; then
    llvm-dwarfdump --debug-info "$OUT/dbg.elf" > "$OUT/llvm.txt" 2>&1 \
        || fail "llvm-dwarfdump could not decode the unit"
    if ! python3 - "$OUT/llvm.txt" "$OUT/funcs.txt" "$OUT/vars.txt" <<'PY'
import re, sys

TAG = re.compile(r'^\s*(?:0x[0-9a-fA-F]+:\s*)?DW_TAG_([a-z_]+)')
ATTR = re.compile(r'^\s*DW_AT_([a-z_]+)\s*\((.*)\)\s*$')


def value(raw):
    m = re.search(r'"([^"]*)"', raw)
    if m:
        return m.group(1)
    m = re.search(r'(0x[0-9a-fA-F]+|\d+)', raw)
    return m.group(1) if m else raw.strip()


def location(raw):
    """llvm spells an operator name out; the suite decoder spells it compactly."""
    raw = raw.strip()
    m = re.match(r'DW_OP_fbreg\s*([+-]?\d+)', raw)
    if m:
        return 'fbreg%+d' % int(m.group(1))
    m = re.match(r'DW_OP_addr\s*(0x[0-9a-fA-F]+)', raw)
    if m:
        return 'addr(0x%x)' % int(m.group(1), 16)
    return raw


def llvm_type(s):
    s = s.strip()
    if s.endswith('*'):                       # "Point *" / " *" for an untyped one
        inner = s[:-1].strip()
        return 'ptr<%s>' % (inner if inner else 'void')
    return s


def short(t):
    """llvm names only the outermost subrange; ours spells every dimension."""
    i = t.find(']')
    return t[:i + 1] if i >= 0 else t


funcs, variables = set(), set()
die = None
skip_depth = None
for line in open(sys.argv[1]):
    m = TAG.match(line)
    if m:
        # v0.23.51-dev: each subroutine's DW_TAG_subroutine_type carries its
        # formal_parameter children — the function's *signature*, which carries
        # no location. The suite decoder skips that subtree (see
        # debuginfo-decode.py), so this cross-reader must skip it too or it
        # would collect phantom parameters. Depth is the indentation after the
        # "0x<offset>:" prefix; a subtree ends at the first DIE at a shallower
        # or equal depth.
        depth = len(re.match(r'^(?:0x[0-9a-fA-F]+:)?(\s*)', line).group(1))
        if skip_depth is not None and depth > skip_depth:
            die = None
            continue
        skip_depth = depth if m.group(1) == 'subroutine_type' else None
        die = {'tag': m.group(1)}
        continue
    if die is None:
        continue
    m = ATTR.match(line)
    if m:
        die[m.group(1)] = m.group(2)
        continue
    if line.strip():
        continue
    tag = die.get('tag')
    if tag == 'subprogram':
        lo = int(value(die['low_pc']), 16)
        hi = int(value(die['high_pc']), 16)
        funcs.add((value(die.get('name', '""')), lo, hi - lo, int(value(die.get('decl_line', '(0)')))))
    elif tag in ('variable', 'formal_parameter'):
        variables.add((value(die.get('name', '""')), llvm_type(value(die.get('type', '""'))),
                       location(die.get('location', '')), int(value(die.get('decl_line', '(0)')))))
    die = None

ours_funcs = set()
for line in open(sys.argv[2]):
    p = line.split()
    if p:
        ours_funcs.add((p[0], int(p[1], 16), int(p[2], 16), int(p[3])))
ours_vars = set()
for line in open(sys.argv[3]):
    p = line.split()
    if p:
        ours_vars.add((p[1], short(p[3]), p[4], int(p[5])))

bad = False
for what, theirs, ours in (("functions", funcs, ours_funcs), ("variables", variables, ours_vars)):
    if theirs != ours:
        bad = True
        print("llvm-dwarfdump only:", sorted(theirs - ours))
        print("suite decoder only:", sorted(ours - theirs))
        print("for:", what)
sys.exit(1 if bad else 0)
PY
    then
        fail "llvm-dwarfdump disagrees with the suite decoder"
    fi
    # Every function must have the same frame base the suite asks for.
    nb=$(grep -c 'DW_OP_breg31' "$OUT/llvm.txt" || true)
    [ "$nb" -eq "$NFUNCS" ] || fail "expected $NFUNCS SP-relative frame bases, llvm-dwarfdump reports $nb"
else
    echo "note: llvm-dwarfdump not installed — skipping the cross-reader check"
fi

# --- 8. it survives linking, and a shared object keeps it ----------------------------
cat > "$OUT/defs.ast" <<'AST'
let gtotal: i32 = 7;

fn add2(n: i32) -> i32 {
    return n + 2;
}
AST
cat > "$OUT/main.ast" <<'AST'
extern let gtotal: i32;
extern fn add2(n: i32) -> i32;

fn main() -> i32 {
    let s: i32 = add2(gtotal);
    return s;
}
AST
$ASTER build-obj "$OUT/main.ast" -g -o "$OUT/a.o" >/dev/null
$ASTER build-obj "$OUT/defs.ast" -g -o "$OUT/b.o" >/dev/null
$ASTER link-obj "$OUT/a.o" "$OUT/b.o" -o "$OUT/linked.elf" >/dev/null
$DECODE --units "$OUT/linked.elf" > "$OUT/lunits.txt"
[ "$(wc -l < "$OUT/lunits.txt")" -eq 2 ] || fail "expected one unit per object, got $(wc -l < "$OUT/lunits.txt")"
mstart=$(awk '/^main\.ast/{print $2}' "$OUT/lunits.txt")
msize=$(awk '/^main\.ast/{print $3}' "$OUT/lunits.txt")
dstart=$(awk '/^defs\.ast/{print $2}' "$OUT/lunits.txt")
[ -n "$mstart" ] && [ -n "$dstart" ] || fail "a unit is missing from the linked output"
eqaddr "$mstart" "$(section_addr "$OUT/linked.elf" .text)" "the first unit does not start at .text"
[ $((dstart)) -ge $((mstart + msize)) ] \
    || fail "the second unit starts at $dstart, inside the first ($mstart + $msize)"
$DECODE --functions "$OUT/linked.elf" | sort > "$OUT/lfuncs.txt"
grep -q '^add2 ' "$OUT/lfuncs.txt" || fail "the linked output has no subprogram for add2"
grep -q '^main ' "$OUT/lfuncs.txt" || fail "the linked output has no subprogram for main"

# A shared object linked out of PIC objects keeps one unit per object too, each
# raised to where that object's text landed in the merged image.
cat > "$OUT/pa.ast" <<'AST'
let gv: i32 = 5;

fn twice(n: i32) -> i32 {
    let r: i32 = n * 2;
    return r;
}
AST
cat > "$OUT/pb.ast" <<'AST'
extern let gv: i32;
extern fn twice(n: i32) -> i32;

fn entry() -> i32 {
    let t: i32 = twice(gv);
    return t;
}
AST
$ASTER build-obj "$OUT/pa.ast" --pic -g -o "$OUT/pa.o" >/dev/null
$ASTER build-obj "$OUT/pb.ast" --pic -g -o "$OUT/pb.o" >/dev/null
$ASTER link-so "$OUT/pa.o" "$OUT/pb.o" --soname libp.so -o "$OUT/libp.so" >/dev/null
$DECODE --units "$OUT/libp.so" > "$OUT/sunits.txt"
[ "$(wc -l < "$OUT/sunits.txt")" -eq 2 ] || fail "expected one unit per PIC object, got $(wc -l < "$OUT/sunits.txt")"
p1=$(awk '/^pa\.ast/{print $2}' "$OUT/sunits.txt")
s1=$(awk '/^pa\.ast/{print $3}' "$OUT/sunits.txt")
p2=$(awk '/^pb\.ast/{print $2}' "$OUT/sunits.txt")
[ -n "$p1" ] && [ -n "$p2" ] || fail "a unit is missing from the linked shared object"
eqaddr "$p1" "$(section_addr "$OUT/libp.so" .text)" "the first PIC unit does not start at .text"
[ $((p2)) -ge $((p1 + s1)) ] || fail "the second PIC unit starts at $p2, inside the first ($p1 + $s1)"

# Both shared-object paths — with a soname (gnu-hash) and without — keep the
# unit, and a PIE keeps it too.
$ASTER build-so  "$SRC" --soname libdbg.so -g -o "$OUT/dbg.so"  >/dev/null
$ASTER build-so  "$SRC" -g -o "$OUT/plain-dbg.so" >/dev/null
$ASTER build-pie "$SRC" -g -o "$OUT/dbg.pie" >/dev/null
for f in dbg.so plain-dbg.so dbg.pie; do
    readelf -S "$OUT/$f" | grep -q '\.debug_info' || fail "$f lost .debug_info"
    $DECODE --vars "$OUT/$f" | grep ' global ' > "$OUT/gvars.$f" \
        || fail "$f describes no globals"
    while read -r _scope name kind type loc _line; do
        a=${loc#addr(0x}; a=${a%)}
        sym=$(symbol "$OUT/$f" OBJECT "$name")
        [ -n "$sym" ] || fail "no OBJECT symbol for $name in $f"
        set -- $sym
        eqaddr "0x$a" "0x$1" "$f: global $name is at 0x$a but its symbol is at 0x$1"
    done < "$OUT/gvars.$f"
done
# A PIE has no fixed load address, so its unit starts at the base of its own image.
$DECODE --units "$OUT/dbg.pie" > "$OUT/units.pie"
eqaddr "$(awk '{print $2}' "$OUT/units.pie")" "$(section_addr "$OUT/dbg.pie" .text)" \
    "the PIE unit does not start at .text"

# --- 9. the suite can still fail -----------------------------------------------------
# A test that cannot fail is decoration. Shift every frame slot by one and
# require the checks above to notice; if the injected change ever stops
# applying, this step fails so the guard gets fixed instead of quietly passing.
sed 's|slot\*8);return e;|slot*8+8);return e;|' src/aster.cpp > "$OUT/mutant.cpp"
grep -q 'slot\*8+8);return e;' "$OUT/mutant.cpp" \
    || fail "the shifted-slot mutation no longer applies to src/aster.cpp"
$CXX -std=c++17 -O2 -w "$OUT/mutant.cpp" -o "$OUT/aster-mutant"
"$OUT/aster-mutant" build-elf "$SRC" -g -o "$OUT/mutant.elf" >/dev/null
$DECODE --vars "$OUT/mutant.elf" > "$OUT/vars.mutant"
[ "$(grep '^scale p param' "$OUT/vars.mutant")" = "scale p param Point fbreg+0 7" ] \
    && fail "a shift in every frame slot went unnoticed (a parameter is no longer at the frame base)"

echo "PASS: -g emits DWARF v4 .debug_info — a unit anchored to .text, one subprogram per function matching the symbol table, every variable reachable from the frame base or its own address, real type DIEs, carried through link and .so, off by default"
