#!/bin/sh
# .eh_frame checks (v0.23.33-dev).
#
# `-g` makes aster emit call-frame information beside the line table and the
# .debug_info it already wrote, so a debugger can walk a stack instead of only
# printing the frame it stopped in. Aster's frames are uniform — every
# function's prologue is exactly `SUB SP, SP, #8192` and SP never moves again —
# so a whole function's unwind table is six bytes of CFI:
#
#     CFA        r31 (sp) + 8192, from one instruction past the prologue
#     r30 (x30)  at CFA-8, for a body that returns; absent for the entry
#
# This suite proves nine things:
#
#   1. IT IS OFF BY DEFAULT: without -g there is no .eh_frame, no
#      .eh_frame_hdr and no PT_GNU_EH_FRAME in an executable, a PIE, an object,
#      a shared object — nor in any of the shipped examples.
#   2. IT IS ADDITIVE: -g adds the sections without moving a byte of .text, and
#      a relocatable object says how to fix its addresses up instead.
#   3. THE CIE IS THE ONE GCC WRITES: the same bytes, compared byte for byte
#      against aarch64-linux-gnu-gcc's own object for the same program.
#   4. EVERY FUNCTION HAS AN FDE, AND IT AGREES WITH .symtab: each FDE's
#      [begin, end) is exactly the address and size its own FUNC symbol has.
#   5. THE CFI IS TIED TO THE CODE: the CFA rule starts one instruction in,
#      which objdump says is where `SUB SP, SP, #8192` ends, and the return
#      address is saved at CFA-8 by every body that returns — not by the entry,
#      which exits rather than returns.
#   6. THE LOOKUP HEADER IS SELF-CONSISTENT AND REACHABLE: .eh_frame_hdr names
#      .eh_frame, carries one sorted row per FDE pointing at it, and both
#      sections sit inside a PT_LOAD with a PT_GNU_EH_FRAME on the header.
#   7. TWO INDEPENDENT READERS AGREE: binutils and LLVM read the same bytes and
#      must describe the same functions and the same rules.
#   8. IT SURVIVES LINKING AND RUNNING: two objects produce one raised table,
#      a shared object keeps every function's, and qemu says the images behave
#      exactly as they did without -g.
#   9. THE SUITE CAN STILL FAIL.
set -eu
cd "$(dirname "$0")/.."
CXX=${CXX:-g++}
OUT=${OUT:-tmp-ehframe-checks}
rm -rf "$OUT"; mkdir -p "$OUT"
trap 'rm -rf "$OUT"' EXIT

$CXX -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp -o "$OUT/aster"
ASTER="$OUT/aster"

if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: python3 is required to decode .eh_frame"
    exit 0
fi
DECODE="python3 tests/ehframe-decode.py"

# Three functions: two that return, and main, which becomes the entry and
# exits instead. Every line below is either a declaration this suite checks or
# fill, and the exit status is asserted in layer 8.
SRC="$OUT/unwind.ast"
cat > "$SRC" <<'AST'
fn add(a: i32, b: i32) -> i32 {
    let t: i32 = a + b;
    return t;
}

fn sub(a: i32, b: i32) -> i32 {
    let t: i32 = a - b;
    return t;
}

fn main() -> i32 {
    return add(3, 4) - sub(3, 4);
}
AST

fail() { echo "FAIL: $1"; exit 1; }
eqaddr() { [ $(( $1 )) -eq $(( $2 )) ] || fail "$3 ($1 vs $2)"; }
# Address and size of a section by name. readelf -S -W shuffles the field
# columns depending on the section number's width ("  [ 5]" vs "[17]"), so we
# locate the name token and count forward instead of betting on a fixed column:
# Name, Type, Address, Offset, Size  ->  address is +2 fields, size is +4.
section_addr() { readelf -S -W "$1" | awk -v n="$2" '{for(i=1;i<=NF;++i)if($i==n){print "0x"$(i+2);exit}}'; }
section_size() { readelf -S -W "$1" | awk -v n="$2" '{for(i=1;i<=NF;++i)if($i==n){print "0x"$(i+4);exit}}'; }
# Every FUNC symbol as "<value> <size> <name>", one per line.
funcsyms() { readelf -sW "$1" | awk '$4=="FUNC"{print $2, $3, $8}'; }
# Is this address inside some PT_LOAD? An unwinder reads the table out of the
# loaded image, so a table no segment maps is a table nothing can find.
in_load() {
    readelf -lW "$1" | awk '$1=="LOAD"{print $3, $5}' \
    | while read -r v sz; do
        [ $(( $2 )) -ge $(( $v )) ] && [ $(( $2 )) -lt $(( $v + $sz )) ] \
            && echo yes
    done | grep -q yes
}
# Our decoder's pc ranges, normalised to stripped hex so either reader's
# zero-padded form can be compared with it.
our_ranges() {
    while read -r s e _cfa _ra; do printf '0x%x 0x%x\n' "$(( s ))" "$(( e ))"; done
}

# --- 1. off by default: no unwind table anywhere --------------------------------
printf '%s\n' '[1/9] off by default'
$ASTER build-elf "$SRC" -o "$OUT/plain.elf" >/dev/null
$ASTER build-pie "$SRC" -o "$OUT/plain.pie" >/dev/null
$ASTER build-obj "$SRC" -o "$OUT/plain.o"   >/dev/null
$ASTER build-so  "$SRC" -o "$OUT/plain.so"  >/dev/null
for f in plain.elf plain.pie plain.o plain.so; do
    readelf -S "$OUT/$f" | grep -q '\.eh_frame' \
        && fail "default build of $f must not carry .eh_frame"
    readelf -S "$OUT/$f" | grep -q '\.eh_frame_hdr' \
        && fail "default build of $f must not carry .eh_frame_hdr"
    readelf -l "$OUT/$f" | grep -q 'GNU_EH_FRAME' \
        && fail "default build of $f must not carry a PT_GNU_EH_FRAME"
done
# The whole example corpus, not just this source: -g is the only thing that
# turns the table on, so nothing else may grow one.
for f in examples/*.ast; do
    $ASTER build-elf "$f" -o "$OUT/ex.elf" >/dev/null 2>&1 || continue
    readelf -S "$OUT/ex.elf" | grep -q '\.eh_frame' \
        && fail "default build of $f grew an .eh_frame"
done
printf '  %-34s %s\n' 'products without .eh_frame' '4'
printf '  %-34s %s\n' 'examples without .eh_frame' "$(ls examples/*.ast | wc -l)"

# --- 2. -g adds it, and .text does not move -------------------------------------
printf '%s\n' '[2/9] additive, and relocated in an object'
$ASTER build-elf "$SRC" -g -o "$OUT/dbg.elf" >/dev/null
$ASTER build-pie "$SRC" -g -o "$OUT/dbg.pie" >/dev/null
$ASTER build-obj "$SRC" -g -o "$OUT/dbg.o"   >/dev/null
$ASTER build-so  "$SRC" -g -o "$OUT/dbg.so"  >/dev/null
for f in elf pie o so; do
    readelf -S "$OUT/dbg.$f" | grep -q '\.eh_frame' || fail "-g build of .$f has no .eh_frame"
    readelf -x .text "$OUT/plain.$f" > "$OUT/text.plain.$f"
    readelf -x .text "$OUT/dbg.$f"   > "$OUT/text.dbg.$f"
    cmp -s "$OUT/text.plain.$f" "$OUT/text.dbg.$f" \
        || fail "-g changed the .text bytes of .$f"
done
# A relocatable object cannot know its addresses, so it leaves them as zero and
# says how to fix them: one R_AARCH64_PREL32 per FDE, each naming a function.
readelf -S "$OUT/dbg.o" | grep -q '\.rela\.eh_frame' || fail "object has no .rela.eh_frame"
readelf -r "$OUT/dbg.o" | awk '/\.rela\.eh_frame/,/^$/' | grep -q 'R_AARCH64_PREL32' \
    || fail ".rela.eh_frame has no R_AARCH64_PREL32 relocation"
nrel=$(readelf -r "$OUT/dbg.o" | awk '/\.rela\.eh_frame/,/^$/' | grep -c 'R_AARCH64_PREL32')
funcsyms "$OUT/dbg.o" > "$OUT/osyms"
nfunc=$(wc -l < "$OUT/osyms")
[ "$nrel" -eq "$nfunc" ] \
    || fail "object has $nrel FDE relocations for $nfunc functions"
while read -r _val _size name; do
    readelf -r "$OUT/dbg.o" | awk '/\.rela\.eh_frame/,/^$/' | grep -qw "$name" \
        || fail ".rela.eh_frame does not describe $name"
done < "$OUT/osyms"
# Reading it back needs those relocations applied, which the decoder does.
$DECODE --fdes "$OUT/dbg.o" | sort > "$OUT/ofdes"
[ "$(wc -l < "$OUT/ofdes")" -eq "$nfunc" ] \
    || fail "object describes $(wc -l < "$OUT/ofdes") functions, not $nfunc"

# --- 3. the CIE is the one gcc writes -------------------------------------------
printf '%s\n' '[3/9] the CIE, against gcc'
GCC=${GCC:-aarch64-linux-gnu-gcc}
if command -v "$GCC" >/dev/null 2>&1; then
    cat > "$OUT/twin.c" <<'C'
int add(int a, int b) { return a + b; }
int sub(int a, int b) { return a - b; }
int main(void) { return add(3, 4) - sub(3, 4); }
C
    "$GCC" -O2 -c "$OUT/twin.c" -o "$OUT/twin.o" 2>/dev/null
    ours=$($DECODE --ciehex "$OUT/dbg.o")
    theirs=$($DECODE --ciehex "$OUT/twin.o")
    [ -n "$theirs" ] || fail "$GCC emitted an .eh_frame this decoder cannot read"
    [ "$ours" = "$theirs" ] \
        || fail "Aster's CIE is $ours but gcc's is $theirs"
    printf '  %-34s %s\n' 'CIE bytes identical to gcc' "${#ours} hex digits"
else
    printf '  %-34s %s\n' 'CIE bytes identical to gcc' "skipped (no $GCC)"
fi
# Whatever gcc is available, the fields themselves are fixed by the ABI.
$DECODE --cie "$OUT/dbg.o" > "$OUT/cie"
grep -q '^version=1 ' "$OUT/cie"                 || fail "CIE version is not 1"
grep -q 'augmentation=zR ' "$OUT/cie"            || fail "CIE augmentation is not zR"
grep -q 'code_alignment=4 ' "$OUT/cie"           || fail "CIE code alignment is not 4"
grep -q 'data_alignment=-8 ' "$OUT/cie"          || fail "CIE data alignment is not -8"
grep -q 'ra_column=30 ' "$OUT/cie"               || fail "CIE return-address column is not 30"
grep -q 'augmentation_data=1b' "$OUT/cie"        || fail "CIE pointer encoding is not pcrel sdata4"

# --- 4. one FDE per function, agreeing with the symbol table --------------------
printf '%s\n' '[4/9] one FDE per function'
check_fdes() { # <file> — every FDE must be a function, and every function an FDE
    # A function may carry more than one name (e.g. the entry is both `_start`
    # and `main`), so dedupe FUNC symbols by address before counting: one FDE
    # per distinct function, aliases sharing their FDE.
    funcsyms "$1" | sort -u -k1,2 > "$OUT/syms.$2"
    n=$(sort -u -k1,1 "$OUT/syms.$2" | wc -l)
    $DECODE --fdes "$1" | sort > "$OUT/fdes.$2"
    [ "$(wc -l < "$OUT/fdes.$2")" -eq "$n" ] \
        || fail "$2: $(wc -l < "$OUT/fdes.$2") FDEs for $n functions"
    while read -r s e cfa ra; do
        hit=
        while read -r val size name; do
            if [ $(( s )) -eq $(( 0x$val )) ] && [ $(( e - s )) -eq "$size" ]; then
                hit=$name; break
            fi
        done < "$OUT/syms.$2"
        [ -n "$hit" ] \
            || fail "$2: no FUNC symbol covers the FDE at $s..$e (size $(( e - s )))"
        printf '%s\n' "$hit" >> "$OUT/covered.$2"
    done < "$OUT/fdes.$2"
    [ "$(sort -u "$OUT/covered.$2" | wc -l)" -eq "$n" ] \
        || fail "$2: an FDE covers a function twice or a function is uncovered"
}
for pair in "dbg.elf exec" "dbg.pie pie" "dbg.so so"; do
    set -- $pair
    : > "$OUT/covered.$2"
    check_fdes "$OUT/$1" "$2"
    printf '  %-34s %s\n' "$2: FDEs match .symtab" "$(wc -l < "$OUT/covered.$2")"
done

# --- 5. what the CFI says, tied to the code it describes -------------------------
printf '%s\n' '[5/9] the CFA rule and the return address'
# The CFA rule must start one instruction into the function, and objdump says
# that instruction is the frame's `SUB SP, SP, #8192` — the whole reason a
# single rule can describe every Aster frame.
OBJDUMP=${OBJDUMP:-aarch64-linux-gnu-objdump}
if command -v "$OBJDUMP" >/dev/null 2>&1; then
    first=$("$OBJDUMP" -d "$OUT/dbg.elf" | awk '/^0000/{getline; print; exit}')
    case "$first" in
        *"sub	sp, sp, #0x2, lsl #12"*) : ;;
        *) fail "a function no longer opens with SUB SP, SP, #8192: $first" ;;
    esac
    printf '  %-34s %s\n' 'prologue is one instruction' 'sub sp, sp, #8192'
else
    printf '  %-34s %s\n' 'prologue is one instruction' "skipped (no $OBJDUMP)"
fi
# Every FDE, in every product: CFA is SP + 8192.
for pair in "dbg.elf exec" "dbg.pie pie" "dbg.so so"; do
    set -- $pair
    while read -r s e cfa ra; do
        [ "$cfa" = "r31+8192" ] || fail "$2: the FDE at $s says CFA is $cfa"
    done < "$OUT/fdes.$2"
done
# The return address: every body that returns saves X30 at CFA-8. The entry is
# the exception — it exits, so its prologue never stores X30 and its FDE must
# not claim one. A shared object has no entry: there, main returns like anyone.
entry_addr=$(section_addr "$OUT/dbg.elf" .text)
while read -r s e cfa ra; do
    if [ $(( s )) -eq $(( entry_addr )) ]; then
        [ "$ra" = "-" ] || fail "the entry's FDE claims a return address at $ra"
    else
        [ "$ra" = "cfa-8" ] || fail "the FDE at $s does not say where X30 is ($ra)"
    fi
done < "$OUT/fdes.exec"
while read -r s e cfa ra; do
    [ "$ra" = "cfa-8" ] || fail "a shared object's FDE at $s does not say where X30 is ($ra)"
done < "$OUT/fdes.so"
# And the rules take effect where the suite just said they do: one instruction
# in for the CFA, two for the return address.
$DECODE "$OUT/dbg.elf" > "$OUT/dump"
awk '/^FDE /{n++} n==1 && /^    /{print}' "$OUT/dump" | sed -n '1,2p' | sed 's/^[[:space:]]*//' > "$OUT/cfi.head"
[ "$(cat "$OUT/cfi.head")" = "DW_CFA_advance_loc 4
DW_CFA_def_cfa_offset 8192" ] \
    || fail "the CFA rule does not start one instruction in: $(cat "$OUT/cfi.head")"
awk '/^FDE /{n++} n==2 && /^    /{print}' "$OUT/dump" | sed 's/^[[:space:]]*//' > "$OUT/cfi.callee"
[ "$(cat "$OUT/cfi.callee")" = "DW_CFA_advance_loc 4
DW_CFA_def_cfa_offset 8192
DW_CFA_advance_loc 4
DW_CFA_offset r30 at cfa-8" ] \
    || fail "a returning body's rules are not (CFA at +4, X30 at +8): $(cat "$OUT/cfi.callee")"
printf '  %-34s %s\n' 'CFA' 'r31+8192 from +4'
printf '  %-34s %s\n' 'return address' 'cfa-8 from +8, none at the entry'

# --- 6. the lookup header, and the segments that expose it ----------------------
printf '%s\n' '[6/9] .eh_frame_hdr and its segments'
check_hdr() { # <file> <label>
    readelf -S "$1" | grep -q '\.eh_frame_hdr' || fail "$2 has no .eh_frame_hdr"
    $DECODE --hdr "$1" > "$OUT/hdr.$2"
    [ -s "$OUT/hdr.$2" ] || fail "$2: the header did not decode"
    head -1 "$OUT/hdr.$2" | grep -q '^version=1 '             || fail "$2: header version is not 1"
    head -1 "$OUT/hdr.$2" | grep -q 'eh_frame_ptr_enc=0x1b '  || fail "$2: eh_frame_ptr is not pcrel sdata4"
    head -1 "$OUT/hdr.$2" | grep -q 'table_enc=0x3b'          || fail "$2: the table is not datarel sdata4"
    ptr=$(head -1 "$OUT/hdr.$2" | sed 's/.*eh_frame_ptr=0x\([0-9a-f]*\).*/\1/')
    eqaddr "0x$ptr" "$(section_addr "$1" .eh_frame)" "$2: the header does not point at .eh_frame"
    # One row per FDE, in ascending function order, each landing on its FDE.
    tail -n +2 "$OUT/hdr.$2" > "$OUT/hdr.rows.$2"
    $DECODE --fdes "$1" | sort > "$OUT/hdr.fdes.$2"
    [ "$(wc -l < "$OUT/hdr.rows.$2")" -eq "$(wc -l < "$OUT/hdr.fdes.$2")" ] \
        || fail "$2: the header has $(wc -l < "$OUT/hdr.rows.$2") rows for $(wc -l < "$OUT/hdr.fdes.$2") FDEs"
    : > "$OUT/hdr.norm.$2"
    while read -r fn fa; do
        printf '%s %s\n' "$(( fn ))" "$(( fa ))" >> "$OUT/hdr.norm.$2"
    done < "$OUT/hdr.rows.$2"
    sort -n "$OUT/hdr.norm.$2" > "$OUT/hdr.sorted.$2"
    cmp -s "$OUT/hdr.norm.$2" "$OUT/hdr.sorted.$2" \
        || fail "$2: the lookup table is not sorted by function address"
    # Every row's FDE address must sit inside .eh_frame, and the function it
    # names must be one an FDE actually covers.
    ef_addr=$(section_addr "$1" .eh_frame)
    ef_size=$(section_size "$1" .eh_frame)
    while read -r fn fa; do
        [ $(( fa )) -ge $(( ef_addr )) ] && [ $(( fa )) -lt $(( ef_addr + ef_size )) ] \
            || fail "$2: a header row points outside .eh_frame at $fa"
        grep -q "^0x$(printf '%x' "$(( fn ))") " "$OUT/hdr.fdes.$2" \
            || fail "$2: a header row names 0x$(printf '%x' "$(( fn ))"), which no FDE covers"
    done < "$OUT/hdr.rows.$2"
    # PT_GNU_EH_FRAME on the header, and both sections inside a PT_LOAD.
    readelf -lW "$1" | awk '$1=="GNU_EH_FRAME"{sub(/^0x/,"",$3); print $3}' > "$OUT/ehseg.$2"
    [ -s "$OUT/ehseg.$2" ] || fail "$2 has no PT_GNU_EH_FRAME"
    eqaddr "0x$(cat "$OUT/ehseg.$2")" "$(section_addr "$1" .eh_frame_hdr)" \
        "$2: PT_GNU_EH_FRAME does not point at .eh_frame_hdr"
    in_load "$1" "$(section_addr "$1" .eh_frame)"     || fail "$2: .eh_frame is in no PT_LOAD"
    in_load "$1" "$(section_addr "$1" .eh_frame_hdr)" || fail "$2: .eh_frame_hdr is in no PT_LOAD"
}
: > "$OUT/hdr.norm.elf"; : > "$OUT/hdr.norm.pie"; : > "$OUT/hdr.norm.so"
check_hdr "$OUT/dbg.elf" elf
check_hdr "$OUT/dbg.pie" pie
check_hdr "$OUT/dbg.so"  so
printf '  %-34s %s\n' 'header rows sorted and in range' '3 products'
printf '  %-34s %s\n' 'PT_GNU_EH_FRAME + PT_LOAD' '3 products'

# --- 7. two independent readers agree --------------------------------------------
printf '%s\n' '[7/9] independent readers'
for pair in "dbg.elf exec" "dbg.pie pie" "dbg.so so"; do
    set -- $pair
    readelf --debug-dump=frames "$OUT/$1" \
        | sed -n 's/.*pc=0*\([0-9a-f]*\)\.\.0*\([0-9a-f]*\).*/\1 \2/p' \
        | while read -r a b; do printf '0x%x 0x%x\n' "$(( 0x$a ))" "$(( 0x$b ))"; done \
        | sort > "$OUT/readelf.$2"
    our_ranges < "$OUT/fdes.$2" | sort > "$OUT/ours.$2"
    cmp -s "$OUT/readelf.$2" "$OUT/ours.$2" \
        || fail "$2: readelf describes different functions than this decoder"
done
printf '  %-34s %s\n' 'readelf agrees on pc ranges' '3 products'
if command -v llvm-dwarfdump >/dev/null 2>&1; then
    llvm-dwarfdump --eh-frame "$OUT/dbg.elf" > "$OUT/llvm.txt" 2>&1
    grep -q 'Return address column: 30' "$OUT/llvm.txt" \
        || fail "llvm-dwarfdump does not read the return-address column as 30"
    grep -q 'DW_CFA_def_cfa_offset: +8192' "$OUT/llvm.txt" \
        || fail "llvm-dwarfdump does not read the CFA offset as 8192"
    grep -q 'W30=\[CFA-8\]' "$OUT/llvm.txt" \
        || fail "llvm-dwarfdump does not read X30 as saved at CFA-8"
    printf '  %-34s %s\n' 'llvm-dwarfdump agrees' 'CFA +8192, W30 at CFA-8'
else
    printf '  %-34s %s\n' 'llvm-dwarfdump agrees' 'skipped (not installed)'
fi

# --- 8. it survives linking, and it runs -----------------------------------------
printf '%s\n' '[8/9] linking and running'
cat > "$OUT/defs.ast" <<'AST'
fn add2(n: i32) -> i32 {
    return n + 2;
}
AST
cat > "$OUT/entry.ast" <<'AST'
extern fn add2(n: i32) -> i32;

fn main() -> i32 {
    return add2(40);
}
AST
$ASTER build-obj "$OUT/entry.ast" -g -o "$OUT/la.o" >/dev/null
$ASTER build-obj "$OUT/defs.ast"  -g -o "$OUT/lb.o" >/dev/null
$ASTER link-obj "$OUT/la.o" "$OUT/lb.o" -o "$OUT/linked" >/dev/null
: > "$OUT/covered.linked"
check_fdes "$OUT/linked" linked
[ "$(wc -l < "$OUT/covered.linked")" -eq 2 ] \
    || fail "the linked image describes $(wc -l < "$OUT/covered.linked") functions, not 2"
# The two objects' functions land one after the other, so the table has to be
# raised: no FDE may still sit at the address its object gave it.
$DECODE --fdes "$OUT/la.o" | sort > "$OUT/pre.a"
$DECODE --fdes "$OUT/linked" | sort > "$OUT/post.a"
eqaddr "$(head -1 "$OUT/post.a" | cut -d' ' -f1)" "$(section_addr "$OUT/linked" .text)" \
    "the linked table does not start at .text"
while read -r s e cfa ra; do
    [ "$cfa" = "r31+8192" ] || fail "a linked FDE at $s says CFA is $cfa"
    [ $(( s )) -ge $(( $(section_addr "$OUT/linked" .text) )) ] \
        || fail "a linked FDE at $s was not raised into the image"
done < "$OUT/post.a"
printf '  %-34s %s\n' 'link-obj: FDEs raised' '2'
# A shared object built out of PIC objects keeps one FDE per function too.
$ASTER build-obj "$OUT/entry.ast" --pic -g -o "$OUT/pa.o" >/dev/null
$ASTER build-obj "$OUT/defs.ast"  --pic -g -o "$OUT/pb.o" >/dev/null
$ASTER link-so "$OUT/pa.o" "$OUT/pb.o" --soname libu.so -o "$OUT/libu.so" >/dev/null
: > "$OUT/covered.libu"
check_fdes "$OUT/libu.so" libu
[ "$(wc -l < "$OUT/covered.libu")" -eq 2 ] \
    || fail "the linked shared object describes $(wc -l < "$OUT/covered.libu") functions, not 2"
while read -r s e cfa ra; do
    [ "$ra" = "cfa-8" ] || fail "a linked .so FDE at $s does not say where X30 is ($ra)"
done < "$OUT/fdes.libu"
check_hdr "$OUT/libu.so" libu
printf '  %-34s %s\n' 'link-so: FDEs raised, header' '2'
# And a gnu-hash shared object built straight from source.
$ASTER build-so "$SRC" --soname libu2.so -g -o "$OUT/libu2.so" >/dev/null
: > "$OUT/covered.libu2"
check_fdes "$OUT/libu2.so" libu2
: > "$OUT/hdr.norm.libu2"
check_hdr "$OUT/libu2.so" libu2

# Runtime: -g is metadata. The images must do exactly what they did without it.
RUNNER=${RUNNER:-tests/run-aarch64.sh}
can_run=no
if [ "$(uname -m)" = aarch64 ] || command -v qemu-aarch64 >/dev/null 2>&1; then
    can_run=yes
fi
if [ "$can_run" = yes ]; then
    set +e
    $RUNNER "$OUT/plain.elf" > "$OUT/out.plain" 2>&1; rp=$?
    $RUNNER "$OUT/dbg.elf"   > "$OUT/out.dbg"   2>&1; rd=$?
    set -e
    [ "$rp" = 8 ] || fail "the plain image exited $rp, not 8 (add(3,4)-sub(3,4) = 7-(-1))"
    [ "$rd" = "$rp" ] || fail "-g changed the exit status ($rp vs $rd)"
    cmp -s "$OUT/out.plain" "$OUT/out.dbg" || fail "-g changed the program's output"
    printf '  %-34s %s\n' 'qemu: same exit and output' "exit=$rp"
else
    printf '  %-34s %s\n' 'qemu: same exit and output' 'skipped (no runner)'
fi

# --- 9. the suite can still fail --------------------------------------------------
printf '%s\n' '[9/9] the suite can still fail'
# A test that cannot fail is decoration. Halve the CFA offset and require the
# checks above to notice; if the mutation ever stops applying, this step fails
# so the guard gets fixed instead of quietly passing.
sed 's|body.push_back(0x0e);ehUleb(body,8192);|body.push_back(0x0e);ehUleb(body,4096);|' \
    src/aster.cpp > "$OUT/mutant.cpp"
grep -q 'ehUleb(body,4096)' "$OUT/mutant.cpp" \
    || fail "the halved-CFA mutation no longer applies to src/aster.cpp"
$CXX -std=c++17 -O2 -w "$OUT/mutant.cpp" -o "$OUT/aster-mutant"
"$OUT/aster-mutant" build-elf "$SRC" -g -o "$OUT/mutant.elf" >/dev/null
$DECODE --fdes "$OUT/mutant.elf" | grep -q 'r31+8192' \
    && fail "a halved CFA offset went unnoticed"
# And drop the return-address rule: every callee must lose it.
sed 's|body.push_back(0x9e);ehUleb(body,1);|body.push_back(0x00);|' \
    src/aster.cpp > "$OUT/mutant2.cpp"
grep -q 'body.push_back(0x00);     // DW_CFA_offset' "$OUT/mutant2.cpp" \
    || fail "the dropped-return-address mutation no longer applies"
$CXX -std=c++17 -O2 -w "$OUT/mutant2.cpp" -o "$OUT/aster-mutant2"
"$OUT/aster-mutant2" build-elf "$SRC" -g -o "$OUT/mutant2.elf" >/dev/null
$DECODE --fdes "$OUT/mutant2.elf" | grep -q 'cfa-8' \
    && fail "losing the return-address rule went unnoticed"
printf '%s\n' 'PASS: -g emits .eh_frame — the CIE gcc writes, one FDE per function agreeing with .symtab, CFA = SP+8192 one instruction in, X30 at CFA-8 in every body that returns, a sorted .eh_frame_hdr under PT_GNU_EH_FRAME in its own PT_LOAD, raised through link-obj and link-so, and no change to how the program runs'
