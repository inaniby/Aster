#!/bin/sh
# v0.23.54-dev (ELF segments) / v0.23.55-dev (build-apk ZIP offset): page-size
# regression guard for Android 16 KB-page support.
#
# Android 15+ devices that use a 16 KB page reject any app (targetSdk >= 35)
# whose ELF load segments are not page-aligned to 0x4000: every PT_LOAD must
# carry p_align >= 0x4000 and its p_vaddr/p_offset must be congruent mod that
# align. And because Android mmaps the .so straight out of the APK, the .so's
# data offset *inside the ZIP* must also be congruent to the page size. Aster
# historically hard-coded 0x1000 (4 KB) for every loadable segment in all
# three ELF writers and for the .so's ZIP entry. This suite locks the contract
# introduced by the --page-size flag:
#
#   * default (no flag): every PT_LOAD keeps Align 0x1000, the embedded .so's
#     ZIP entry stays 4096-aligned, and the emitted image is byte-for-byte what
#     it always was. This is the regression fence — a silent 4 KB shift, or a
#     16 KB value leaking into the default path, must not happen. The default
#     path is also required to be *unchanged* from the pre-16 KB binary, so we
#     assert the 4 KB and 16 KB images differ.
#
#   * --page-size 16384: every PT_LOAD gets Align 0x4000, vaddr/offset are
#     0x4000-aligned, the .so's ZIP entry shifts to a 16384-aligned offset, AND
#     a built executable still runs to its expected exit code (the bytes are not
#     just laid out differently — they must still load and execute, which is
#     the property Android actually checks).
#
# Source-level guards confirm the writers no longer hard-code 0x1000 for
# segment layout (the dead kSharedTextVaddr constant is gone and no bare 0x1000
# literal remains), so the change cannot quietly rot back to a single fixed
# page size.
set -eu
cd "$(dirname "$0")/.."
OUT=${OUT:-tmp-page-size-checks}
W="$OUT/work"
mkdir -p "$W"; trap 'rm -rf "$OUT"' EXIT HUP INT TERM

# ---------------------------------------------------------------------------
# [1/6] Strictly build Aster — the exact flags CI enforces under -Werror.
printf '%s\n' '[1/6] Strictly build Aster compiler'
${CXX:-g++} -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp -o "$OUT/aster"
AS="$OUT/aster"

# ---------------------------------------------------------------------------
# [2/6] Source-level guards: the three ELF writers must derive every loadable
# segment's align/offset from `pageSize`, not from a hard-coded 0x1000. The
# dead kSharedTextVaddr constant (the old shared-object .text base) is gone,
# and no bare 0x1000 literal remains in the file.
printf '%s\n' '[2/6] Source guards: no hard-coded 0x1000 segment layout'
if grep -q 'kSharedTextVaddr' src/aster.cpp; then
    echo "FAIL: kSharedTextVaddr still present in src/aster.cpp" >&2
    exit 1
fi
echo "OK: kSharedTextVaddr removed from src/aster.cpp"
if grep -q '0x1000' src/aster.cpp; then
    echo "FAIL: bare 0x1000 literal remains in src/aster.cpp (segment layout must derive from pageSize)" >&2
    exit 1
fi
echo "OK: no bare 0x1000 literal in src/aster.cpp"

# ---------------------------------------------------------------------------
# [3/6] The test corpus. A global (data segment) plus a string literal
# (rodata segment) plus the text segment exercises more than one PT_LOAD in
# both writers, so the alignment parameter is checked on every segment kind.
printf '%s\n' '[3/6] Prepare test corpus'
cat > "$W/source.ast" <<'AST'
let g_factor: i32 = 6;
fn main() -> i32 {
  let x: i32 = 7;
  let label: ptr = "pg-size-rodata";
  let _u: i32 = label[0];
  return x * g_factor;
}
AST

# ---------------------------------------------------------------------------
# [4/6] Behavioral guard. A Python ELF reader inspects every PT_LOAD of every
# produced image and asserts the alignment contract. It also refuses to let the
# 16 KB flag be a silent no-op: the 4 KB and 16 KB build-elf images must differ.
printf '%s\n' '[4/6] Build and verify load-segment alignment (default 0x1000, 16384 -> 0x4000)'
"$AS" build-obj "$W/source.ast" -o "$W/source.o"
python3 - "$AS" "$W" <<'PY'
import struct, subprocess, sys, os

AS, W = sys.argv[1], sys.argv[2]

def build(args, input_path, out_path, page):
    # args is the command verb(s) plus any prebuilt inputs (the link-* verbs);
    # input_path is the source (.ast) for the build-* verbs or None for the
    # link-* verbs. The page size is inserted right after the command verb
    # (argv[1]), because each verb parses its own arguments.
    argv = [AS] + args
    if page:
        argv = [AS] + args[:1] + ["--page-size", str(page)] + args[1:]
    if input_path is not None:
        argv += [input_path]
    argv += ["-o", out_path]
    subprocess.run(argv, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)

def load_segments(path):
    b = open(path, "rb").read()
    assert b[:6] == b"\x7fELF\x02\x01", (path, "not ELF64-LE")
    phoff = struct.unpack_from("<Q", b, 32)[0]
    phentsize, phnum = struct.unpack_from("<HH", b, 54)
    loads = []
    for i in range(phnum):
        p = struct.unpack_from("<IIQQQQQQ", b, phoff + i * phentsize)
        if p[0] == 1:  # PT_LOAD
            loads.append(p)  # (type, flags, offset, vaddr, paddr, filesz, memsz, align)
    return loads

def check_alignment(path, page, label):
    loads = load_segments(path)
    assert loads, (path, "no PT_LOAD segment")
    for p in loads:
        align, off, vaddr = p[7], p[2], p[3]
        assert align == page, (label, path, "PT_LOAD align", hex(align), "expected", hex(page))
        assert off % page == 0 and vaddr % page == 0, (
            label, path, "PT_LOAD not aligned", hex(off), hex(vaddr), "to", hex(page))
    print("PASS: %s %s — %d PT_LOAD segment(s) all Align %s, vaddr/offset aligned"
          % (label, os.path.basename(path), len(loads), hex(page)))

CMDS = [
    ("build-elf", ["build-elf"], "source.ast"),
    ("build-pie", ["build-pie"], "source.ast"),
    ("build-so", ["build-so"], "source.ast"),
    ("link-obj", ["link-obj", os.path.join(W, "source.o")], None),
    ("link-pie", ["link-pie", os.path.join(W, "source.o")], None),
]

# Default must keep 0x1000 on every segment.
for name, args, inp in CMDS:
    out = os.path.join(W, name + "-4k")
    build(args, os.path.join(W, inp) if inp else None, out, None)
    check_alignment(out, 0x1000, "default")

# 16384 must switch every segment to 0x4000.
for name, args, inp in CMDS:
    out = os.path.join(W, name + "-16k")
    build(args, os.path.join(W, inp) if inp else None, out, 16384)
    check_alignment(out, 0x4000, "page-size=16384")

# The 16 KB flag must actually change the default build-elf image (it must not
# be a silent no-op — that is exactly the bug this suite guards against).
d = open(os.path.join(W, "build-elf-4k"), "rb").read()
p = open(os.path.join(W, "build-elf-16k"), "rb").read()
assert d != p, "build-elf with --page-size 16384 is byte-identical to the 4 KB default"
print("PASS: --page-size 16384 changes the emitted build-elf image (not a silent no-op)")
PY

# ---------------------------------------------------------------------------
# [5/6] Executability. A 16 KB image is only useful if it still loads and runs.
# Drive build-elf and build-pie (16384) under qemu-aarch64 and require the
# expected exit code (7 * 6 = 42). The default-path images must also still run.
printf '%s\n' '[5/6] Run 16 KB (and default) executables under qemu-aarch64'
run(){ sh tests/run-aarch64.sh "$@"; }
"$AS" build-elf "$W/source.ast" -o "$W/run-4k.elf"
"$AS" build-elf --page-size 16384 "$W/source.ast" -o "$W/run-16k.elf"
"$AS" build-pie --page-size 16384 "$W/source.ast" -o "$W/run-16k-pie"
EXPECTED=42
for img in run-4k.elf run-16k.elf run-16k-pie; do
    set +e
    run "$W/$img" >/dev/null 2>&1; rc=$?
    set -e
    if [ "$rc" != "$EXPECTED" ]; then
        echo "FAIL: $img exited $rc, expected $EXPECTED under qemu-aarch64" >&2
        exit 1
    fi
    echo "PASS: $img runs under qemu-aarch64 and exits $EXPECTED"
done

# ---------------------------------------------------------------------------
# [6/6] build-apk end-to-end. Android mmaps the packaged .so straight out of the
# APK, so the .so's data offset inside the ZIP must be congruent to the page
# size as well — not just the ELF segment alignment. This block builds an APK
# both ways (.ast -> build-apk, which compiles the .so internally with the
# chosen page size) and asserts, for each: the embedded .so's PT_LOAD segments
# carry the right Align, AND the .so's ZIP entry is aligned to that page size.
# The project's own APK validator is run as an independent cross-check.
printf '%s\n' '[6/6] build-apk: .so ELF alignment AND ZIP entry alignment'
python3 - "$AS" "$W" <<'PY'
import struct, subprocess, sys, os, zipfile

AS, W = sys.argv[1], sys.argv[2]
KEYS = os.path.join(W, "apk-keys")
os.makedirs(KEYS, exist_ok=True)
subprocess.run([AS, "keygen", "--dir", KEYS], check=True,
               stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)

def build_apk(ast, apk, so_out, page):
    argv = [AS, "build-apk"]
    if page:
        argv += ["--page-size", str(page)]
    argv += [ast, "-o", apk, "--emit-so", so_out,
             "--package", "com.pagesize.test", "--libname", "pstest",
             "--abi", "arm64-v8a", "--keystore-dir", KEYS]
    subprocess.run(argv, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)

def zip_so_offset(apk):
    raw = open(apk, "rb").read()
    idx = raw.find(b"PK\x03\x04")
    while idx != -1:
        nl = struct.unpack_from('<H', raw, idx + 26)[0]
        el = struct.unpack_from('<H', raw, idx + 28)[0]
        fn = raw[idx + 30: idx + 30 + nl].decode('utf-8', 'replace')
        if fn.endswith('.so'):
            return idx + 30 + nl + el
        idx = raw.find(b"PK\x03\x04", idx + 4)
    raise SystemExit("no lib/*.so entry found in %s" % apk)

def so_load_aligns(so):
    b = open(so, "rb").read()
    assert b[:6] == b"\x7fELF\x02\x01", (so, "not ELF64-LE")
    phoff = struct.unpack_from('<Q', b, 32)[0]
    phentsize, phnum = struct.unpack_from('<HH', b, 54)
    aligns = []
    for i in range(phnum):
        p = struct.unpack_from('<IIQQQQQQ', b, phoff + i * phentsize)
        if p[0] == 1:  # PT_LOAD
            aligns.append(p[7])
    return aligns

AST = "examples/native_activity.ast"
build_apk(AST, os.path.join(W, "app-4k.apk"),  os.path.join(W, "so-4k.so"),  None)
build_apk(AST, os.path.join(W, "app-16k.apk"), os.path.join(W, "so-16k.so"), 16384)

# Default path: ELF Align 0x1000 and a 4096-aligned ZIP entry.
off4 = zip_so_offset(os.path.join(W, "app-4k.apk"))
assert off4 % 4096 == 0, ("default build-apk .so ZIP offset not 4096-aligned", off4)
for a in so_load_aligns(os.path.join(W, "so-4k.so")):
    assert a == 0x1000, ("default build-apk embedded .so Align", hex(a))
print("PASS: default build-apk — embedded .so Align 0x1000, ZIP entry offset %d 4096-aligned" % off4)

# 16384 path: ELF Align 0x4000 and a 16384-aligned ZIP entry.
off16 = zip_so_offset(os.path.join(W, "app-16k.apk"))
assert off16 % 16384 == 0, ("--page-size 16384 build-apk .so ZIP offset not 16384-aligned", off16)
for a in so_load_aligns(os.path.join(W, "so-16k.so")):
    assert a == 0x4000, ("--page-size 16384 build-apk embedded .so Align", hex(a))
print("PASS: --page-size 16384 build-apk — embedded .so Align 0x4000, ZIP entry offset %d 16384-aligned" % off16)

# The 16 KB flag must actually change the APK (not a silent no-op).
a4 = open(os.path.join(W, "app-4k.apk"), "rb").read()
a16 = open(os.path.join(W, "app-16k.apk"), "rb").read()
assert a4 != a16, "--page-size 16384 build-apk is byte-identical to the 4 KB default"
print("PASS: --page-size 16384 changes the build-apk image (not a silent no-op)")

# Independent cross-check with the project's own APK validator.
for apk, page in (("app-4k.apk", 4096), ("app-16k.apk", 16384)):
    r = subprocess.run([sys.executable, "tests/validate_apk.py",
                        os.path.join(W, apk), "--package", "com.pagesize.test",
                        "--libname", "pstest", "--abi", "arm64-v8a",
                        "--page-size", str(page)],
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if r.returncode != 0:
        sys.exit("FAIL: validate_apk.py rejected %s:\n%s" % (apk, r.stdout.decode()))
print("PASS: validate_apk.py accepts both APKs at their respective page size")
PY

echo "=== page-size checks: ALL PASSED ==="
