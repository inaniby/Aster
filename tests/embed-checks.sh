#!/bin/sh
# v0.23.7-dev checks for @embed / @embed_len.
#
# resources.arsc exists for one reason: things the *system* reads before the
# process starts, in a process that is not yours. Anything your own code reads
# at run time does not need it and cannot use it — so that half of "where do my
# resources live?" is answered here instead: @embed("path") puts a file's bytes
# in the object and yields their address, @embed_len("path") yields how many
# there are.
#
# The failure modes worth testing are the quiet ones:
#   * a path that resolves to nothing (or to a directory, or to an empty file)
#     must be an error, not a pointer to something adjacent
#   * the same file embedded twice is one copy, not two
#   * the bytes in the object are the bytes in the file, exactly — no trailing
#     NUL of the kind a string literal owns
#   * a global `let g: ptr = @embed(...)` has to be initialized before main,
#     which used to be rejected outright
#
# Layers:
#   1. strict compiler build
#   2. source guards
#   3. negative cases: every diagnostic has to name what is actually wrong
#   4. structural: rodata bytes versus the file, deduplication, --embed-dir,
#      and the same feature through build-so and build-obj --pic
#   5. run under qemu: byte-for-byte checksums, a global embed, a binary file
#      containing 0x00 and 0xff
#   6. compiler mutations, each a way to get the bytes subtly wrong
set -eu
cd "$(dirname "$0")/.."
OUT=${OUT:-tmp-embed-checks}
mkdir -p "$OUT"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM

ASTER=${ASTER:-$OUT/aster}
# The assets live in their own directory so that the default base (the source
# file's own directory) and --embed-dir are genuinely two different places.
ASSETS="$OUT/assets"
mkdir -p "$ASSETS"

printf '%s\n' '[1/6] Strictly build Aster compiler'
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o "$ASTER"

printf '%s\n' '[2/6] Source guards: @embed, @embed_len, dedup, global ptr init'
grep -qF 'case Expr::Embed:{emitGlobalAddress(e.name);' src/aster.cpp \
    || { echo 'FAIL: @embed no longer emits the address of its rodata object' >&2; exit 1; }
grep -qF 'if (kw.s != "embed" && kw.s != "embed_len")' src/aster.cpp \
    || { echo 'FAIL: the @embed / @embed_len keyword check is gone' >&2; exit 1; }
# A single-quoted shell string cannot hold a single quote, and half of these
# messages are full of them, so the guards match the part that carries the
# meaning and leave the punctuation to the compiler.
grep -qF "unknown attribute '@" src/aster.cpp \
    || { echo 'FAIL: an unknown @attribute is no longer diagnosed' >&2; exit 1; }
grep -qF 'cannot open embedded file' src/aster.cpp \
    || { echo 'FAIL: a missing embedded file is no longer diagnosed' >&2; exit 1; }
grep -qF 'embedded file is a directory' src/aster.cpp \
    || { echo 'FAIL: embedding a directory is no longer diagnosed' >&2; exit 1; }
grep -qF 'embedded file is empty' src/aster.cpp \
    || { echo 'FAIL: embedding an empty file is no longer diagnosed' >&2; exit 1; }
# Deduplication: the bytes live in a map, because a vector would move the first
# blob out from under a reference already handed back to the parser.
grep -qF 'embedBlobs.emplace(full, std::move(bytes)).first->second;' src/aster.cpp \
    || { echo 'FAIL: embedded blobs are no longer deduplicated' >&2; exit 1; }
# A ptr global may now be initialized with a pointer.
grep -qF 'if(g.ty!=Ty::Ptr&&g.initExpr&&exprYieldsPtr(' src/aster.cpp \
    || { echo 'FAIL: global ptr initialization is rejected again' >&2; exit 1; }
grep -qF 'case Expr::Embed: return Ty::Ptr;' src/aster.cpp \
    || { echo 'FAIL: @embed no longer types as ptr' >&2; exit 1; }
grep -qF 'else if(a=="--embed-dir"){if(i+1>=argc)return false;embedDir=argv[++i];}' src/aster.cpp \
    || { echo 'FAIL: --embed-dir is gone' >&2; exit 1; }
printf '%s\n' 'PASS: @embed, @embed_len, dedup, diagnostics and global ptr init present'

printf '%s\n' '[3/6] Negative cases'
# -- the assets ------------------------------------------------------------
printf 'AB' > "$ASSETS/two.bin"                 # 0x41 0x42, sum 131 (< 251)
printf '\101\000\377\132' > "$ASSETS/bin.bin"   # 'A', NUL, 0xFF, 'Z'
printf 'hello world' > "$ASSETS/text.txt"       # 11 bytes
: > "$ASSETS/empty.bin"
mkdir -p "$ASSETS/adir"
# A source file that lives next to its assets, so the default base resolves.
cat > "$ASSETS/probe.ast" <<'AST'
fn main() -> i32 {
    let p: ptr = @embed("two.bin");
    return load_u8(p) + load_u8(p + 1);
}
AST

expect_fail() {   # $1 = label, $2 = source, $3 = expected substring
    # In $ASSETS, so the default base directory is the one holding the assets.
    printf '%s\n' "$2" > "$ASSETS/neg.ast"
    if "$ASTER" build-elf "$ASSETS/neg.ast" -o "$OUT/neg" > "$OUT/neg.log" 2>&1; then
        echo "FAIL: $1 compiled, but should not have" >&2
        sed -n 's/^/    /p' "$OUT/neg.log" >&2
        return 1
    fi
    if ! grep -qF "$3" "$OUT/neg.log"; then
        echo "FAIL: $1 was rejected, but not because of '$3':" >&2
        sed -n 's/^/    /p' "$OUT/neg.log" >&2
        return 1
    fi
    printf '%s\n' "PASS: $1 -- $3"
}
expect_fail 'missing file' \
    'fn main() -> i32 { let p: ptr = @embed("does-not-exist.bin"); return load_u8(p); }' \
    'cannot open embedded file'
expect_fail 'a directory' \
    'fn main() -> i32 { let p: ptr = @embed("adir"); return load_u8(p); }' \
    'embedded file is a directory'
expect_fail 'an empty file' \
    'fn main() -> i32 { let p: ptr = @embed("empty.bin"); return load_u8(p); }' \
    'embedded file is empty'
expect_fail 'unknown @attribute' \
    'fn main() -> i32 { let p: ptr = @nope("two.bin"); return load_u8(p); }' \
    "unknown attribute '@nope'"
expect_fail 'embed into an i32' \
    'fn main() -> i32 { let k: i32 = @embed("two.bin"); return k; }' \
    'type mismatch'
expect_fail 'non-string argument' \
    'fn main() -> i32 { let p: ptr = @embed(7); return load_u8(p); }' \
    'expected a file path after'
expect_fail 'missing parenthesis' \
    'fn main() -> i32 { let p: ptr = @embed "two.bin"; return load_u8(p); }' \
    "expected '(' after '@embed'"
expect_fail 'unterminated call' \
    'fn main() -> i32 { let p: ptr = @embed("two.bin"; return load_u8(p); }' \
    "expected ')' after the file path"
expect_fail 'embed_len into a ptr' \
    'fn main() -> i32 { let p: ptr = @embed_len("two.bin"); return load_u8(p); }' \
    'type mismatch'
# An i64 global must not silently take the low 32 bits of an address: the
# relaxation is for ptr globals only.
expect_fail 'embed into an i64 global' \
    'let g: i64 = @embed("two.bin");
fn main() -> i32 { return 0; }' \
    'type mismatch initializing global'

printf '%s\n' '[4/6] Structural: rodata bytes, dedup, --embed-dir, .so and PIC object'
# The bytes in the object are read straight out of the ELF, not through the
# program: a checksum that happens to match would not prove the bytes are there.
python3 - "$OUT" "$ASSETS" <<'PY'
import os, sys, struct, subprocess
out, assets = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
aster = os.path.join(out, 'aster')

def rodata(path):
    b = open(path, 'rb').read()
    assert b[:4] == b'\x7fELF', 'not an ELF: %s' % path
    assert b[4] == 2 and b[5] == 1, 'not little-endian 64-bit'
    e_shoff, = struct.unpack_from('<Q', b, 0x28)
    e_shentsize, e_shnum, e_shstrndx = struct.unpack_from('<HHH', b, 0x3a)
    def sh(i):
        p = e_shoff + i * e_shentsize
        name, typ, flags, addr, off, size = struct.unpack_from('<IIQQQQ', b, p)
        return name, typ, off, size
    _, _, stroff, _ = sh(e_shstrndx)
    blobs = []
    for i in range(e_shnum):
        name, typ, off, size = sh(i)
        end = b.index(b'\0', stroff + name)
        nm = b[stroff + name:end].decode()
        if nm in ('.rodata', '.rodata.str1.1'):
            blobs.append(b[off:off + size])
    return b''.join(blobs)

def build(src, args, name='probe.ast'):
    # Next to the assets, so the default base directory is theirs.
    sp = os.path.join(assets, name)
    open(sp, 'w').write(src)
    cmd = [aster] + args + [sp, '-o', os.path.join(out, 'probe')]
    r = subprocess.run(cmd, capture_output=True, text=True)
    assert r.returncode == 0, 'build failed: %s%s' % (r.stdout, r.stderr)
    return r.stdout + r.stderr

# 1. the file's bytes appear in rodata exactly once, verbatim
src = 'fn main() -> i32 { let p: ptr = @embed("bin.bin"); return load_u8(p); }\n'
build(src, ['build-elf'])
want = open(os.path.join(assets, 'bin.bin'), 'rb').read()
rd = rodata(os.path.join(out, 'probe'))
assert rd.count(want) == 1, 'the file bytes appear %d times in rodata' % rd.count(want)
assert not want.endswith(b'\0'), 'the test asset itself ends in NUL; use another'
# A string literal keeps a NUL the file does not have; embedded bytes must not.
sys.stderr.write('   rodata holds %d bytes, the asset %d, matched verbatim\n' % (len(rd), len(want)))

# 2. deduplication: the same file named three times is still one copy
src = ('fn main() -> i32 {\n'
       '    let a: ptr = @embed("text.txt");\n'
       '    let b: ptr = @embed("text.txt");\n'
       '    let c: ptr = @embed("bin.bin");\n'
       '    return load_u8(a) + load_u8(b) + load_u8(c);\n'
       '}\n')
build(src, ['build-elf'])
rd = rodata(os.path.join(out, 'probe'))
text = open(os.path.join(assets, 'text.txt'), 'rb').read()
assert rd.count(text) == 1, 'text.txt embedded %d times' % rd.count(text)
assert rd.count(want) == 1, 'bin.bin embedded %d times' % rd.count(want)
# 11 bytes of text + 4 of binary and nothing else: a second copy would show up here
assert len(rd) == len(text) + len(want), 'rodata is %d bytes, expected %d' % (len(rd), len(text) + len(want))
sys.stderr.write('   three @embed of two files -> %d rodata bytes, one copy each\n' % len(rd))

# 3. the default base is the source file's own directory, wherever it is run from
sp = os.path.join(assets, 'dirprobe.ast')
open(sp, 'w').write(src)
r = subprocess.run([aster, 'build-elf', sp, '-o', os.path.join(out, 'dir')],
                   capture_output=True, text=True, cwd='/')
assert r.returncode == 0, 'building from another cwd failed: %s' % r.stderr
sys.stderr.write('   built from cwd=/ with the source directory as the base\n')

# 4. --embed-dir points somewhere else entirely
os.makedirs(os.path.join(out, 'elsewhere'), exist_ok=True)
open(os.path.join(out, 'elsewhere', 'probe.ast'), 'w').write(src)
r = subprocess.run([aster, 'build-elf', os.path.join(out, 'elsewhere', 'probe.ast'),
                    '-o', os.path.join(out, 'ed'), '--embed-dir', assets],
                   capture_output=True, text=True)
assert r.returncode == 0, '--embed-dir build failed: %s' % r.stderr
assert rodata(os.path.join(out, 'ed')).count(text) == 1, '--embed-dir did not supply the bytes'
# ...and without it, the same source cannot find them
r = subprocess.run([aster, 'build-elf', os.path.join(out, 'elsewhere', 'probe.ast'),
                    '-o', os.path.join(out, 'ed2')], capture_output=True, text=True)
assert r.returncode != 0, 'without --embed-dir this should not resolve'
assert 'cannot open embedded file' in r.stderr, r.stderr
sys.stderr.write('   --embed-dir overrides the base, and is required when it is needed\n')

# 5. the same feature through build-so and build-obj --pic
build(src, ['build-so', '--soname', 'libembed.so'])
assert open(os.path.join(out, 'probe'), 'rb').read()[:4] == b'\x7fELF'
build(src, ['build-obj', '--pic'])
assert rodata(os.path.join(out, 'probe')).count(text) == 1, 'PIC object lost the bytes'
sys.stderr.write('   build-so and build-obj --pic carry the embedded bytes too\n')
PY
printf '%s\n' 'PASS: rodata matches the file, one copy each, every pipeline'

printf '%s\n' '[5/6] Run under qemu: checksums, a global embed, binary bytes'
if ! command -v qemu-aarch64 > /dev/null 2>&1; then
    printf '%s\n' 'SKIP: qemu-aarch64 is not installed'
else
    # Every one of these programs returns a byte checksum, which is a perfectly
    # ordinary non-zero exit status, so `set -e` has to be stepped around.
    run_qemu() {
        set +e
        qemu-aarch64 "$1" > /dev/null 2>&1
        QEMU_EXIT=$?
        set -e
    }
    # A checksum the program computes and python recomputes. Exit statuses are
    # eight bits wide, so it is reduced into 0..250 by subtraction — Aster has
    # no remainder operator.
    cat > "$ASSETS/sum.ast" <<'AST'
let blob: ptr = @embed("bin.bin");
let n: i32 = @embed_len("bin.bin");
fn main() -> i32 {
    let i: i32 = 0;
    let s: i32 = 0;
    while (i < n) {
        s = s + load_u8(blob + i);
        i = i + 1;
    }
    while (s > 250) {
        s = s - 251;
    }
    return s;
}
AST
    "$ASTER" build-elf "$ASSETS/sum.ast" -o "$OUT/sum" > /dev/null
    run_qemu "$OUT/sum"; got=$QEMU_EXIT
    want=$(python3 -c "
import sys
b = open('$ASSETS/bin.bin','rb').read()
s = sum(b)
while s > 250: s -= 251
print(s)")
    [ "$got" = "$want" ] || { echo "FAIL: global embed checksum $got, expected $want" >&2; exit 1; }
    printf '%s\n' "PASS: global @embed + @embed_len checksum $got (python: $want)"

    # The same bytes through a function-local embed must agree exactly.
    cat > "$ASSETS/sum2.ast" <<'AST'
fn main() -> i32 {
    let blob: ptr = @embed("bin.bin");
    let n: i32 = @embed_len("bin.bin");
    let i: i32 = 0;
    let s: i32 = 0;
    while (i < n) {
        s = s + load_u8(blob + i);
        i = i + 1;
    }
    while (s > 250) {
        s = s - 251;
    }
    return s;
}
AST
    "$ASTER" build-elf "$ASSETS/sum2.ast" -o "$OUT/sum2" > /dev/null
    run_qemu "$OUT/sum2"; got=$QEMU_EXIT
    [ "$got" = "$want" ] || { echo "FAIL: local embed checksum $got, expected $want" >&2; exit 1; }
    printf '%s\n' 'PASS: function-local @embed agrees with the global one'

    # @embed_len is the file's size, not the size of anything else, and it is a
    # compile-time constant: it works as the initializer of an i32 global.
    cat > "$ASSETS/len.ast" <<'AST'
let n: i32 = @embed_len("text.txt");
let m: i32 = @embed_len("bin.bin");
fn main() -> i32 {
    return n * 10 + m;
}
AST
    "$ASTER" build-elf "$ASSETS/len.ast" -o "$OUT/len" > /dev/null
    run_qemu "$OUT/len"; got=$QEMU_EXIT
    [ "$got" = 114 ] || { echo "FAIL: embed_len gave $got, expected 114 (11*10+4)" >&2; exit 1; }
    printf '%s\n' 'PASS: @embed_len is a compile-time constant equal to the file size'

    # A binary asset: the NUL and the 0xFF are the bytes a text-based check
    # would never notice missing.
    cat > "$ASSETS/bytes.ast" <<'AST'
fn main() -> i32 {
    let p: ptr = @embed("bin.bin");
    return load_u8(p + 1) * 1000000 + load_u8(p + 2);
}
AST
    "$ASTER" build-elf "$ASSETS/bytes.ast" -o "$OUT/bytes" > /dev/null
    run_qemu "$OUT/bytes"; got=$QEMU_EXIT
    # 0 * 1000000 + 255, and the exit status keeps the low eight bits
    [ "$got" = 255 ] || { echo "FAIL: embedded 0x00/0xFF read back as $got" >&2; exit 1; }
    printf '%s\n' 'PASS: NUL and 0xFF bytes survive the round trip'

    # The whole point: a resource carried inside the .so, with no resources.arsc
    # involved, still reaches the running program.
    cat > "$ASSETS/so.ast" <<'AST'
fn asset_len() -> i32 {
    return @embed_len("text.txt");
}
fn main() -> i32 {
    let p: ptr = @embed("text.txt");
    return load_u8(p) + asset_len();
}
AST
    "$ASTER" build-so "$ASSETS/so.ast" -o "$OUT/asset.so" --soname libasset.so > /dev/null
    "$ASTER" build-elf "$ASSETS/so.ast" -o "$OUT/asset" > /dev/null
    run_qemu "$OUT/asset"; got=$QEMU_EXIT
    [ "$got" = "$(python3 -c "print(104 + 11 - ((104+11)//251)*251)")" ] \
        || { echo "FAIL: .so-style asset program returned $got" >&2; exit 1; }
    printf '%s\n' 'PASS: an asset travels inside the shared object'
fi

printf '%s\n' '[6/6] Compiler mutations: four ways to get the bytes wrong'
python3 - "$OUT" <<'PY'
import os, sys
root = sys.argv[1]
src = open('src/aster.cpp').read()

def w(name, pairs):
    s = src
    for old, new in pairs:
        assert s.count(old) == 1, 'anchor for %s appears %d times' % (name, s.count(old))
        s = s.replace(old, new)
    d = os.path.join(root, 'mut-' + name)
    os.makedirs(d, exist_ok=True)
    open(os.path.join(d, 'aster.cpp'), 'w').write(s)

# 1. embed_len off by one: every loop stops one byte early and nothing looks wrong
w('len-off-by-one', [
    ('return E(new Expr(Expr::Num, (uint64_t)data.size()));',
     'return E(new Expr(Expr::Num, (uint64_t)data.size() - 1));'),
])
# 2. no deduplication: the file is embedded once per mention
w('no-dedup', [
    ('        auto seen = embedBlobs.find(full);\n        if (seen != embedBlobs.end()) return seen->second;',
     '        auto seen = embedBlobs.find(full + "#");\n        if (seen != embedBlobs.end()) return seen->second;'),
])
# 3. a trailing NUL, as if an embedded file were a string literal
w('adds-nul', [
    ('        const std::vector<uint8_t>& data = embedBlobs.emplace(full, std::move(bytes)).first->second;',
     '        bytes.push_back(0);\n        const std::vector<uint8_t>& data = embedBlobs.emplace(full, std::move(bytes)).first->second;'),
])
# 4. --embed-dir ignored, so a build that needs it silently uses the wrong base
#    (the anchor is resolveEmbedPath's override branch, which moved when @embed
#    and `include` were given one shared build-wide path-options struct)
w('ignores-embed-dir', [
    ('        if (!g_srcPathOpts.embedDir.empty()) return g_srcPathOpts.embedDir + "/" + path;',
     '        if (false) return path;'),
])
print('\n'.join(sorted(n for n in os.listdir(root) if n.startswith('mut-'))))
PY

for m in len-off-by-one no-dedup adds-nul ignores-embed-dir; do
    ( cd "$OUT/mut-$m" && c++ -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror \
        -o aster aster.cpp ) &
done
wait
for m in len-off-by-one no-dedup adds-nul ignores-embed-dir; do
    [ -x "$OUT/mut-$m/aster" ] || { echo "FAIL: mutated compiler '$m' did not build"; exit 1; }
done
printf '%s\n' '    (four mutated compilers built)'

# 1. len-off-by-one: the checksum no longer matches
"$OUT/mut-len-off-by-one/aster" build-elf "$ASSETS/sum.ast" -o "$OUT/m1" > /dev/null
run_qemu "$OUT/m1"; got=$QEMU_EXIT
[ "$got" != "$want" ] \
    || { echo "FAIL: len-off-by-one produced the same checksum ($got)"; exit 1; }
printf '%s\n' 'PASS: mutation len-off-by-one changes the checksum'

# 2. no-dedup: rodata grows
# The two-file probe: without deduplication rodata is 11 + 11 + 4.
cat > "$OUT/dedup.ast" <<'AST'
fn main() -> i32 {
    let a: ptr = @embed("text.txt");
    let b: ptr = @embed("text.txt");
    let c: ptr = @embed("bin.bin");
    return load_u8(a) + load_u8(b) + load_u8(c);
}
AST
"$OUT/mut-no-dedup/aster" build-elf "$OUT/dedup.ast" -o "$OUT/m2b" \
    --embed-dir "$ASSETS" > /dev/null
big=$(python3 -c "
import sys, struct
b = open('$OUT/m2b','rb').read()
e_shoff, = struct.unpack_from('<Q', b, 0x28)
e_shentsize, e_shnum, e_shstrndx = struct.unpack_from('<HHH', b, 0x3a)
def sh(i):
    p = e_shoff + i * e_shentsize
    name, typ, flags, addr, off, size = struct.unpack_from('<IIQQQQ', b, p)
    return name, off, size
_, stroff, _ = sh(e_shstrndx)
tot = 0
for i in range(e_shnum):
    name, off, size = sh(i)
    end = b.index(b'\0', stroff + name)
    if b[stroff+name:end].startswith(b'.rodata'): tot += size
print(tot)")
[ "$big" = 26 ] || { echo "FAIL: no-dedup rodata is $big bytes, expected 26 (11+11+4)"; exit 1; }
printf '%s\n' 'PASS: mutation no-dedup puts the same file in rodata twice'

# 3. adds-nul: rodata is one byte longer than the file
"$OUT/mut-adds-nul/aster" build-elf "$OUT/dedup.ast" -o "$OUT/m3" \
    --embed-dir "$ASSETS" > /dev/null
big=$(python3 -c "
import sys, struct
b = open('$OUT/m3','rb').read()
e_shoff, = struct.unpack_from('<Q', b, 0x28)
e_shentsize, e_shnum, e_shstrndx = struct.unpack_from('<HHH', b, 0x3a)
def sh(i):
    p = e_shoff + i * e_shentsize
    name, typ, flags, addr, off, size = struct.unpack_from('<IIQQQQ', b, p)
    return name, off, size
_, stroff, _ = sh(e_shstrndx)
tot = 0
for i in range(e_shnum):
    name, off, size = sh(i)
    end = b.index(b'\0', stroff + name)
    if b[stroff+name:end].startswith(b'.rodata'): tot += size
print(tot)")
[ "$big" = 17 ] || { echo "FAIL: adds-nul rodata is $big bytes, expected 17 (11+1 + 4+1)"; exit 1; }
printf '%s\n' 'PASS: mutation adds-nul appends a byte the file does not have'

# 4. ignores-embed-dir: a build that depends on it stops resolving
if "$OUT/mut-ignores-embed-dir/aster" build-elf "$OUT/dedup.ast" -o "$OUT/m4" \
        --embed-dir "$ASSETS" > "$OUT/m4.log" 2>&1; then
    echo "FAIL: ignores-embed-dir still built with --embed-dir" >&2; exit 1
fi
grep -qF 'cannot open embedded file' "$OUT/m4.log" \
    || { echo 'FAIL: ignores-embed-dir failed for another reason:' >&2; sed -n 's/^/    /p' "$OUT/m4.log" >&2; exit 1; }
printf '%s\n' 'PASS: mutation ignores-embed-dir loses the assets'

printf '%s\n' 'ALL EMBED CHECKS PASSED'
