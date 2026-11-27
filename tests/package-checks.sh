#!/bin/sh
# Package format checks (stdlib §11): `aster pack` builds the standard
# library package (manifest + canonical sources + prebuilt std.o),
# `aster pack --check` fails when the sources and the manifest disagree,
# `aster complete` reads the manifest (not the sources) filtered by the
# file's language, and aster.proj `[package]` declarations are version
# checked by build/test/build-cn-obj before any import resolves.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ASTER_BIN=${ASTER_BIN:-$ROOT/aster}
RUNNER=${RUNNER:-$ROOT/tests/run-aarch64.sh}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

fail() { echo "FAIL: $1" >&2; exit 1; }

echo '[1/10] pack generates a complete manifest'
"$ASTER_BIN" pack --src-dir "$ROOT/stdlib" --out "$TMP/pkg" > "$TMP/pack.log" 2>&1 \
    || { cat "$TMP/pack.log" >&2; fail 'aster pack failed'; }
grep -q 'packed standard' "$TMP/pack.log" || fail 'pack did not report the package'
[ -f "$TMP/pkg/manifest.json" ] || fail 'manifest.json missing'
[ -f "$TMP/pkg/std.o" ] || fail 'std.o missing'
[ -f "$TMP/pkg/aster_std.ast" ] || fail 'pack did not copy aster_std.ast'
[ -f "$TMP/pkg/aster_core.ast" ] || fail 'pack did not copy aster_core.ast'
[ -f "$TMP/pkg/cn/string-zh.ast" ] || fail 'pack did not copy cn/string-zh.ast'
[ -f "$TMP/pkg/cn/string-en.ast" ] || fail 'pack did not copy cn/string-en.ast'
python3 - "$TMP/pkg/manifest.json" <<'PY' || fail 'manifest contents are wrong'
import json, sys
m = json.load(open(sys.argv[1]))
assert m["name"] == "standard", m["name"]
assert m["name_zh"] == "标准库", m["name_zh"]
assert m["version"] == "0.23.82-dev", m["version"]
assert [f["path"] for f in m["files"]] == [
    "aster_std.ast", "aster_core.ast", "cn/string-zh.ast", "cn/string-en.ast", "std.o"], m["files"]
kinds = {}
for e in m["exports"]:
    kinds[e["kind"]] = kinds.get(e["kind"], 0) + 1
    assert set(e) == {"name", "name_zh", "kind", "signature", "package", "doc", "doc_en"}, e
    assert e["doc"] != "", e
    assert e["doc_en"] != "", e
assert kinds == {"function": 115, "struct": 5, "const": 13, "global": 10}, kinds
# Every export carries a bilingual doc comment (stdlib sources document
# every public declaration in Chinese and in English); spot-check one
# of each kind in both languages.
assert [e["doc"] for e in m["exports"] if e["name"] == "memcpy"] == \
    ["前向复制 n 字节，重叠是调用方的问题，返回 n。"]
assert [e["doc_en"] for e in m["exports"] if e["name"] == "memcpy"] == \
    ["Copy n bytes forward; overlapping regions are the caller's problem; return n."]
assert [e["doc"] for e in m["exports"] if e["name"] == "Buf"] == \
    ["字节缓冲，指针、长度与容量的三元组。"]
assert [e["doc_en"] for e in m["exports"] if e["name"] == "Buf"] == \
    ["A byte buffer, a triple of pointer, length and capacity."]
assert [e["doc"] for e in m["exports"] if e["name"] == "O_RDONLY"] == \
    ["Linux 的 O_RDONLY（0）。"]
assert [e["doc_en"] for e in m["exports"] if e["name"] == "O_RDONLY"] == \
    ["Linux O_RDONLY (0)."]
assert [e["doc"] for e in m["exports"] if e["name"] == "hkeys"] == \
    ["固定哈希表的键串，0 表示空槽。"]
assert [e["doc_en"] for e in m["exports"] if e["name"] == "hkeys"] == \
    ["The key strings of the fixed hash table; 0 marks an empty slot."]
assert [e["doc"] for e in m["exports"] if e["name"] == "length"] == \
    ["返回字符串的长度。"]
assert [e["doc_en"] for e in m["exports"] if e["name"] == "length"] == \
    ["Return the length of the string."]
text = [e for e in m["exports"] if e["package"] == "standard.text"]
assert [(e["name"], e["name_zh"]) for e in text] == [
    ("length", "长度"), ("concat", "拼接"), ("equals", "相等"), ("less", "更小"),
    ("print", "输出"), ("eprint", "输出错误")], text
assert sorted(e["name"] for e in m["exports"] if e["kind"] == "struct") == [
    "AsterStringView", "Buf", "Map", "Vec32", "VecPtr"]
PY
# Every routine the sources declare must appear in the manifest, and every
# file hash must be the file's real sha256.
for f in aster_std aster_core; do
    awk '/^fn /{name=$2; sub(/\(.*/,"",name); print name}' "$ROOT/stdlib/$f.ast" > "$TMP/$f.names"
    while read -r name; do
        grep -q "\"name\": \"$name\"" "$TMP/pkg/manifest.json" \
            || fail "manifest is missing $f routine $name"
    done < "$TMP/$f.names"
done
for pair in "长度 length" "拼接 concat" "相等 equals" "更小 less" "输出 print" "输出错误 eprint"; do
    set -- $pair
    grep -q "\"name_zh\": \"$1\"" "$TMP/pkg/manifest.json" || fail "manifest is missing $1"
    grep -q "\"name\": \"$2\"" "$TMP/pkg/manifest.json" || fail "manifest is missing $2"
done
for f in aster_std.ast aster_core.ast cn/string-zh.ast cn/string-en.ast; do
    h=$(sha256sum "$ROOT/stdlib/$f" | awk '{print $1}')
    grep -q "\"path\": \"$f\", \"sha256\": \"$h\"" "$TMP/pkg/manifest.json" \
        || fail "manifest hash is wrong for $f"
done
# The manifest's std.o hash must be the packaged std.o file's real sha256.
h=$(sha256sum "$TMP/pkg/std.o" | awk '{print $1}')
grep -q "\"path\": \"std.o\", \"sha256\": \"$h\"" "$TMP/pkg/manifest.json" \
    || fail 'manifest hash is wrong for std.o'
# std.o is the object `build-obj` produces from the same source, byte for byte.
"$ASTER_BIN" build-obj "$ROOT/stdlib/aster_std.ast" -o "$TMP/std-ref.o" > /dev/null 2>&1
cmp "$TMP/pkg/std.o" "$TMP/std-ref.o" || fail 'std.o differs from build-obj output'
# Packing twice is deterministic.
"$ASTER_BIN" pack --src-dir "$ROOT/stdlib" --out "$TMP/pkg2" > /dev/null 2>&1
cmp "$TMP/pkg/manifest.json" "$TMP/pkg2/manifest.json" || fail 'pack is not deterministic'

echo '[2/10] pack --check passes on a fresh package and fails on tampering'
"$ASTER_BIN" pack --src-dir "$ROOT/stdlib" --check "$TMP/pkg" > "$TMP/check-ok.log" 2>&1 \
    || { cat "$TMP/check-ok.log" >&2; fail 'pack --check failed on a fresh package'; }
# The default source dir is the repository stdlib/ when run from the root.
(cd "$ROOT" && "$ASTER_BIN" pack --check "$TMP/pkg2" > /dev/null 2>&1) \
    || fail 'pack --check failed with the default source dir';
mkdir -p "$TMP/src"
cp -r "$ROOT/stdlib/." "$TMP/src/"
"$ASTER_BIN" pack --src-dir "$TMP/src" --out "$TMP/pkg-tamper" > /dev/null 2>&1
"$ASTER_BIN" pack --src-dir "$TMP/src" --check "$TMP/pkg-tamper" > /dev/null 2>&1
printf '\n// tampered\n' >> "$TMP/src/aster_std.ast"
if "$ASTER_BIN" pack --src-dir "$TMP/src" --check "$TMP/pkg-tamper" > "$TMP/check-tamper.log" 2>&1; then
    fail 'pack --check passed after a source was tampered with'
fi
grep -q 'sha256 differs' "$TMP/check-tamper.log" || fail 'tamper diagnostic does not name the hash'
# Pack leaves the directory read-only (§11.1), so restore writability
# before tampering with it in place (a no-op when run as root, required
# otherwise: sed/mv need the directory writable, >> needs the file).
chmod u+w "$TMP/pkg"
sed 's/"name": "memcpy"/"name": "memcpy_renamed"/' "$TMP/pkg/manifest.json" > "$TMP/pkg/manifest-tampered.json"
mv "$TMP/pkg/manifest-tampered.json" "$TMP/pkg/manifest.json"
if "$ASTER_BIN" pack --src-dir "$ROOT/stdlib" --check "$TMP/pkg" > "$TMP/check-manifest.log" 2>&1; then
    fail 'pack --check passed after the manifest was tampered with'
fi
grep -q 'exports\[0\] differs' "$TMP/check-manifest.log" || fail 'manifest-tamper diagnostic is wrong'
# A tampered copy *inside* the package directory must fail too (§11.1):
# the manifest still matches the canonical sources, but the package's own
# file no longer matches the hash its manifest records.
"$ASTER_BIN" pack --src-dir "$ROOT/stdlib" --out "$TMP/pkg-copy" > /dev/null 2>&1
"$ASTER_BIN" pack --src-dir "$ROOT/stdlib" --check "$TMP/pkg-copy" > /dev/null 2>&1 \
    || fail 'pack --check failed on a fresh package copy'
chmod -R u+w "$TMP/pkg-copy"
printf '\n// tampered\n' >> "$TMP/pkg-copy/aster_std.ast"
if "$ASTER_BIN" pack --src-dir "$ROOT/stdlib" --check "$TMP/pkg-copy" > "$TMP/check-copy.log" 2>&1; then
    fail 'pack --check passed after a packaged file was tampered with'
fi
grep -q 'sha256 differs for "aster_std.ast"' "$TMP/check-copy.log" \
    || fail 'packaged-file tamper diagnostic does not name the file hash'
grep -q 'package has been modified' "$TMP/check-copy.log" \
    || fail 'packaged-file tamper diagnostic does not say the package was modified'
# The manifest.json path form of --check checks the same package files.
if "$ASTER_BIN" pack --src-dir "$ROOT/stdlib" --check "$TMP/pkg-copy/manifest.json" > /dev/null 2>&1; then
    fail 'pack --check <manifest.json> passed after a packaged file was tampered with'
fi
# The same tampered package must fail a build that declares a matching
# [package] version.
mkdir -p "$TMP/proj-tamper/src" "$TMP/proj-tamper/packages"
cp -r "$TMP/pkg-copy" "$TMP/proj-tamper/packages/standard"
cat > "$TMP/proj-tamper/src/main.ast" <<'SRC'
方法 启动方法(): 整数
返回 0
结束 方法
SRC
cat > "$TMP/proj-tamper/aster.proj" <<'EOF'
name tamper
[package]
standard = "0.23.82-dev"
[language]
default = "zh"
src/main.ast
EOF
if (cd "$TMP/proj-tamper" && "$ASTER_BIN" build > build.log 2>&1); then
    fail 'build passed with a tampered package installed'
fi
grep -q "package 'standard': files sha256 differs for \"aster_std.ast\"" \
    "$TMP/proj-tamper/build.log" || { cat "$TMP/proj-tamper/build.log" >&2; fail 'tampered-package build diagnostic is wrong'; }
# The same must hold for std.o: it is package content, so a tampered
# std.o inside the package must fail --check and a matching-version build.
"$ASTER_BIN" pack --src-dir "$ROOT/stdlib" --out "$TMP/pkg-copy2" > /dev/null 2>&1
"$ASTER_BIN" pack --src-dir "$ROOT/stdlib" --check "$TMP/pkg-copy2" > /dev/null 2>&1 \
    || fail 'pack --check failed on a fresh package copy (std.o case)'
chmod -R u+w "$TMP/pkg-copy2"
printf 'X' >> "$TMP/pkg-copy2/std.o"
if "$ASTER_BIN" pack --src-dir "$ROOT/stdlib" --check "$TMP/pkg-copy2" > "$TMP/check-copy2.log" 2>&1; then
    fail 'pack --check passed after the packaged std.o was tampered with'
fi
grep -q 'sha256 differs for "std.o"' "$TMP/check-copy2.log" \
    || fail 'packaged std.o tamper diagnostic does not name the file hash'
grep -q 'package has been modified' "$TMP/check-copy2.log" \
    || fail 'packaged std.o tamper diagnostic does not say the package was modified'
mkdir -p "$TMP/proj-tamper2/src" "$TMP/proj-tamper2/packages"
cp -r "$TMP/pkg-copy2" "$TMP/proj-tamper2/packages/standard"
cp "$TMP/proj-tamper/src/main.ast" "$TMP/proj-tamper2/src/main.ast"
cp "$TMP/proj-tamper/aster.proj" "$TMP/proj-tamper2/aster.proj"
sed 's/name tamper/name tamper2/' "$TMP/proj-tamper2/aster.proj" > "$TMP/proj-tamper2/aster.proj.new"
mv "$TMP/proj-tamper2/aster.proj.new" "$TMP/proj-tamper2/aster.proj"
if (cd "$TMP/proj-tamper2" && "$ASTER_BIN" build > build.log 2>&1); then
    fail 'build passed with a tampered std.o installed'
fi
grep -q "package 'standard': files sha256 differs for \"std.o\"" \
    "$TMP/proj-tamper2/build.log" || { cat "$TMP/proj-tamper2/build.log" >&2; fail 'tampered-std.o build diagnostic is wrong'; }
# A package missing one of its files is incomplete and must fail --check.
"$ASTER_BIN" pack --src-dir "$ROOT/stdlib" --out "$TMP/pkg-missing" > /dev/null 2>&1
chmod u+w "$TMP/pkg-missing/cn"
rm "$TMP/pkg-missing/cn/string-en.ast"
if "$ASTER_BIN" pack --src-dir "$ROOT/stdlib" --check "$TMP/pkg-missing" > "$TMP/check-missing.log" 2>&1; then
    fail 'pack --check passed on a package missing a file'
fi
grep -q 'package is incomplete: missing file "cn/string-en.ast"' "$TMP/check-missing.log" \
    || fail 'missing-file diagnostic is wrong'
# A file the manifest does not list is a modification too, even when
# every listed file still matches: the hash check cannot see it.
# Top level first, for --check and for a matching-version build.
"$ASTER_BIN" pack --src-dir "$ROOT/stdlib" --out "$TMP/pkg-extra" > /dev/null 2>&1
chmod u+w "$TMP/pkg-extra"
echo 'not part of the package' > "$TMP/pkg-extra/extra.txt"
if "$ASTER_BIN" pack --src-dir "$ROOT/stdlib" --check "$TMP/pkg-extra" > "$TMP/check-extra.log" 2>&1; then
    fail 'pack --check passed on a package with an extra file'
fi
grep -q 'package contains unexpected file "extra.txt"' "$TMP/check-extra.log" \
    || fail 'extra-file diagnostic does not name the file'
grep -q 'package has been modified' "$TMP/check-extra.log" \
    || fail 'extra-file diagnostic does not say the package was modified'
mkdir -p "$TMP/proj-extra/src" "$TMP/proj-extra/packages"
cp -r "$TMP/pkg-extra" "$TMP/proj-extra/packages/standard"
cp "$TMP/proj-tamper/src/main.ast" "$TMP/proj-extra/src/main.ast"
cat > "$TMP/proj-extra/aster.proj" <<'EOF'
name extra
[package]
standard = "0.23.82-dev"
[language]
default = "zh"
src/main.ast
EOF
if (cd "$TMP/proj-extra" && "$ASTER_BIN" build > build.log 2>&1); then
    fail 'build passed with an extra file in the package'
fi
grep -q "package 'standard': package contains unexpected file \"extra.txt\"" \
    "$TMP/proj-extra/build.log" || { cat "$TMP/proj-extra/build.log" >&2; fail 'extra-file build diagnostic is wrong'; }
# The same, one level down: the enumeration is recursive, so an extra
# file inside cn/ is caught too, by --check and by a build.
"$ASTER_BIN" pack --src-dir "$ROOT/stdlib" --out "$TMP/pkg-extra2" > /dev/null 2>&1
chmod u+w "$TMP/pkg-extra2/cn"
echo 'not part of the package' > "$TMP/pkg-extra2/cn/extra.ast"
if "$ASTER_BIN" pack --src-dir "$ROOT/stdlib" --check "$TMP/pkg-extra2" > "$TMP/check-extra2.log" 2>&1; then
    fail 'pack --check passed on a package with an extra file under cn/'
fi
grep -q 'package contains unexpected file "cn/extra.ast"' "$TMP/check-extra2.log" \
    || fail 'extra-file diagnostic does not name the file under cn/'
mkdir -p "$TMP/proj-extra2/src" "$TMP/proj-extra2/packages"
cp -r "$TMP/pkg-extra2" "$TMP/proj-extra2/packages/standard"
cp "$TMP/proj-tamper/src/main.ast" "$TMP/proj-extra2/src/main.ast"
cp "$TMP/proj-extra/aster.proj" "$TMP/proj-extra2/aster.proj"
sed 's/name extra/name extra2/' "$TMP/proj-extra2/aster.proj" > "$TMP/proj-extra2/aster.proj.new"
mv "$TMP/proj-extra2/aster.proj.new" "$TMP/proj-extra2/aster.proj"
if (cd "$TMP/proj-extra2" && "$ASTER_BIN" build > build.log 2>&1); then
    fail 'build passed with an extra file under cn/ in the package'
fi
grep -q "package 'standard': package contains unexpected file \"cn/extra.ast\"" \
    "$TMP/proj-extra2/build.log" || { cat "$TMP/proj-extra2/build.log" >&2; fail 'extra-file-under-cn build diagnostic is wrong'; }

echo '[3/10] complete filters by the file language'
printf '// aster:language=zh\n' > "$TMP/file-zh.ast"
printf '// aster:language=en\n' > "$TMP/file-en.ast"
"$ASTER_BIN" complete "$TMP/pkg2" "$TMP/file-zh.ast" > "$TMP/complete-zh.txt" 2>&1
grep -q '^长度' "$TMP/complete-zh.txt" || fail 'zh completion is missing 长度'
grep -q '^拼接' "$TMP/complete-zh.txt" || fail 'zh completion is missing 拼接'
grep -q '^输出' "$TMP/complete-zh.txt" || fail 'zh completion is missing 输出'
grep -q '^输出错误' "$TMP/complete-zh.txt" || fail 'zh completion is missing 输出错误'
if grep -q '^length' "$TMP/complete-zh.txt"; then fail 'zh completion leaked length'; fi
if grep -q '^memcpy' "$TMP/complete-zh.txt"; then fail 'zh completion leaked an English-only routine'; fi
"$ASTER_BIN" complete "$TMP/pkg2" "$TMP/file-en.ast" > "$TMP/complete-en.txt" 2>&1
grep -q '^length' "$TMP/complete-en.txt" || fail 'en completion is missing length'
grep -q '^memcpy' "$TMP/complete-en.txt" || fail 'en completion is missing memcpy'
if grep -q '^长度' "$TMP/complete-en.txt"; then fail 'en completion leaked 长度'; fi
# --language wins outright over a file directive (an en file goes zh
# under --language zh); with no file it is the default. The old
# file-wins reading was revoked by the complete-takes-aster.proj decision.
"$ASTER_BIN" complete --language zh "$TMP/pkg2" > "$TMP/complete-defzh.txt" 2>&1
grep -q '^长度' "$TMP/complete-defzh.txt" || fail '--language zh did not default to zh'
if grep -q '^length' "$TMP/complete-defzh.txt"; then fail '--language zh leaked length'; fi
"$ASTER_BIN" complete --language zh "$TMP/pkg2" "$TMP/file-en.ast" > "$TMP/complete-flagwins.txt" 2>&1
grep -q '^长度' "$TMP/complete-flagwins.txt" || fail '--language zh did not win over an en file directive'
if grep -q '^length' "$TMP/complete-flagwins.txt"; then fail '--language zh leaked length over an en file'; fi
# JSON output carries the manifest export shape; a manifest.json path works too.
"$ASTER_BIN" complete --language zh --format json "$TMP/pkg2/manifest.json" > "$TMP/complete-zh.json" 2>&1
python3 - "$TMP/complete-zh.json" <<'PY' || fail 'complete --format json is wrong'
import json, sys
entries = json.load(open(sys.argv[1]))
assert [(e["name"], e["name_zh"]) for e in entries] == [
    ("length", "长度"), ("concat", "拼接"), ("equals", "相等"), ("less", "更小"),
    ("print", "输出"), ("eprint", "输出错误")], entries
PY
"$ASTER_BIN" complete --language en --format json "$TMP/pkg2" > "$TMP/complete-en.json" 2>&1
python3 -c "import json,sys; assert len(json.load(open(sys.argv[1]))) == 143" "$TMP/complete-en.json" \
    || fail 'complete --format json (en) does not list all 143 exports'

echo '[4/10] [package] version check passes, and [package] does not disturb [language]'
mkdir -p "$TMP/proj-ok/src" "$TMP/proj-ok/packages"
"$ASTER_BIN" pack --src-dir "$ROOT/stdlib" --out "$TMP/proj-ok/packages/standard" > /dev/null 2>&1
cat > "$TMP/proj-ok/src/main.ast" <<'SRC'
方法 启动方法(): 整数
返回 0
结束 方法
SRC
cat > "$TMP/proj-ok/aster.proj" <<'EOF'
name ok
[package]
standard = "0.23.82-dev"
[language]
default = "zh"
src/main.ast
EOF
(cd "$TMP/proj-ok" && "$ASTER_BIN" build > build.log 2>&1) \
    || { cat "$TMP/proj-ok/build.log" >&2; fail 'build with a matching [package] version failed'; }
if "$RUNNER" "$TMP/proj-ok/build/ok"; then status=0; else status=$?; fi
[ "$status" -eq 0 ] || fail "matching-version project returned $status, expected 0"

echo '[5/10] version check reports a missing package and a version mismatch'
mkdir -p "$TMP/proj-missing/src" "$TMP/proj-mismatch/src"
cp "$TMP/proj-ok/src/main.ast" "$TMP/proj-missing/src/main.ast"
cp "$TMP/proj-ok/src/main.ast" "$TMP/proj-mismatch/src/main.ast"
cat > "$TMP/proj-missing/aster.proj" <<'EOF'
name missing
[package]
standard = "0.23.82-dev"
src/main.ast
EOF
if (cd "$TMP/proj-missing" && "$ASTER_BIN" build > build.log 2>&1); then
    fail 'build passed with no package installed'
fi
grep -q "package 'standard' version \"0.23.82-dev\" required by aster.proj was not found" \
    "$TMP/proj-missing/build.log" || { cat "$TMP/proj-missing/build.log" >&2; fail 'missing-package diagnostic is wrong'; }
cp -r "$TMP/proj-ok/packages" "$TMP/proj-mismatch/"
cat > "$TMP/proj-mismatch/aster.proj" <<'EOF'
name mismatch
[package]
standard = "0.0.0"
[language]
default = "zh"
src/main.ast
EOF
if (cd "$TMP/proj-mismatch" && "$ASTER_BIN" build > build.log 2>&1); then
    fail 'build passed with a mismatched package version'
fi
grep -q "package 'standard' version mismatch: aster.proj requires \"0.0.0\" but .* has \"0.23.82-dev\"" \
    "$TMP/proj-mismatch/build.log" || { cat "$TMP/proj-mismatch/build.log" >&2; fail 'version-mismatch diagnostic is wrong'; }
# A [package] section after the sources, and the Chinese package name, parse too.
cat > "$TMP/proj-mismatch/aster.proj" <<'EOF'
name mismatch2
src/main.ast
[package]
标准库 = "0.23.82-dev"
EOF
(cd "$TMP/proj-mismatch" && "$ASTER_BIN" build > build.log 2>&1) \
    || { cat "$TMP/proj-mismatch/build.log" >&2; fail 'build with [package] after sources / Chinese name failed'; }

echo '[6/10] version check runs for test as well, and undeclared projects are unaffected'
mkdir -p "$TMP/proj-test/src" "$TMP/proj-test/tests"
cp -r "$TMP/proj-ok/packages" "$TMP/proj-test/"
cat > "$TMP/proj-test/src/main.ast" <<'SRC'
方法 启动方法(): 整数
返回 0
结束 方法
SRC
cat > "$TMP/proj-test/tests/t.ast" <<'SRC'
// aster:language=en
fn main(): i32 {
return 0;
}
SRC
cat > "$TMP/proj-test/aster.proj" <<'EOF'
name testok
[package]
standard = "0.23.82-dev"
src/main.ast
test tests/t.ast
EOF
(cd "$TMP/proj-test" && "$ASTER_BIN" test > test.log 2>&1) \
    || { cat "$TMP/proj-test/test.log" >&2; fail 'test with a matching [package] version failed'; }
sed 's/"0.23.82-dev"/"9.9.9"/' "$TMP/proj-test/aster.proj" > "$TMP/proj-test/aster.proj.bad"
mv "$TMP/proj-test/aster.proj.bad" "$TMP/proj-test/aster.proj"
if (cd "$TMP/proj-test" && "$ASTER_BIN" test > test.log 2>&1); then
    fail 'test passed with a mismatched package version'
fi
grep -q 'version mismatch' "$TMP/proj-test/test.log" || fail 'test version-mismatch diagnostic is wrong'
mkdir -p "$TMP/proj-plain/src"
cp "$TMP/proj-ok/src/main.ast" "$TMP/proj-plain/src/main.ast"
printf 'name plain\nsrc/main.ast\n' > "$TMP/proj-plain/aster.proj"
(cd "$TMP/proj-plain" && "$ASTER_BIN" build > build.log 2>&1) \
    || { cat "$TMP/proj-plain/build.log" >&2; fail 'build without [package] broke'; }

echo '[7/10] pack/complete reject bad usage'
if "$ASTER_BIN" pack --nope > /dev/null 2>&1; then fail 'pack accepted an unknown option'; fi
if "$ASTER_BIN" pack --src-dir "$TMP/does-not-exist" --out "$TMP/pkg-nope" > /dev/null 2>&1; then
    fail 'pack accepted a missing source dir'
fi
if "$ASTER_BIN" pack --check "$TMP/does-not-exist" > /dev/null 2>&1; then
    fail 'pack --check accepted a missing package dir'
fi
if "$ASTER_BIN" complete "$TMP/does-not-exist" > /dev/null 2>&1; then
    fail 'complete accepted a missing package dir'
fi
if "$ASTER_BIN" complete --language fr "$TMP/pkg2" > /dev/null 2>&1; then
    fail 'complete accepted an unknown language'
fi
if "$ASTER_BIN" complete --format yaml "$TMP/pkg2" > /dev/null 2>&1; then
    fail 'complete accepted an unknown format'
fi

echo '[8/10] pack leaves the package read-only, and re-pack over it works'
"$ASTER_BIN" pack --src-dir "$ROOT/stdlib" --out "$TMP/pkg-ro" > /dev/null 2>&1
# No file or directory under the package carries a write bit. Checked by
# mode bits, not by attempting a write: the suite may run as root, and
# root can write through a read-only mode.
[ -z "$(find "$TMP/pkg-ro" -perm /0222 -print -quit)" ] \
    || fail 'pack left a writable file or directory in the package'
# Re-packing into the same directory restores writability, rewrites, and
# locks the package again; the result still passes --check and a build.
"$ASTER_BIN" pack --src-dir "$ROOT/stdlib" --out "$TMP/pkg-ro" > "$TMP/repack.log" 2>&1 \
    || { cat "$TMP/repack.log" >&2; fail 're-pack into the same directory failed'; }
[ -z "$(find "$TMP/pkg-ro" -perm /0222 -print -quit)" ] \
    || fail 're-pack left a writable file or directory in the package'
"$ASTER_BIN" pack --src-dir "$ROOT/stdlib" --check "$TMP/pkg-ro" > /dev/null 2>&1 \
    || fail 'pack --check failed after re-pack'
mkdir -p "$TMP/proj-ro/src" "$TMP/proj-ro/packages"
cp -r "$TMP/pkg-ro" "$TMP/proj-ro/packages/standard"
cp "$TMP/proj-ok/src/main.ast" "$TMP/proj-ro/src/main.ast"
cp "$TMP/proj-ok/aster.proj" "$TMP/proj-ro/aster.proj"
sed 's/name ok/name ro/' "$TMP/proj-ro/aster.proj" > "$TMP/proj-ro/aster.proj.new"
mv "$TMP/proj-ro/aster.proj.new" "$TMP/proj-ro/aster.proj"
(cd "$TMP/proj-ro" && "$ASTER_BIN" build > build.log 2>&1) \
    || { cat "$TMP/proj-ro/build.log" >&2; fail 'build with a re-packed package failed'; }
if "$RUNNER" "$TMP/proj-ro/build/ro"; then status=0; else status=$?; fi
[ "$status" -eq 0 ] || fail "re-packed project returned $status, expected 0"

echo '[9/10] build-cn-obj --project runs the same package version check'
# The same fixtures as the build cases above, through build-cn-obj
# --project invoked from outside the project directory: the package root
# is the project directory, not the cwd. The mismatch fixture is built
# fresh here because [5/10] overwrote proj-mismatch/aster.proj with a
# matching-version declaration at the end of its section.
mkdir -p "$TMP/proj-cnobj-mismatch/src"
cp -r "$TMP/proj-ok/packages" "$TMP/proj-cnobj-mismatch/"
cp "$TMP/proj-ok/src/main.ast" "$TMP/proj-cnobj-mismatch/src/main.ast"
cat > "$TMP/proj-cnobj-mismatch/aster.proj" <<'EOF'
name cnobj-mismatch
[package]
standard = "0.0.0"
[language]
default = "zh"
src/main.ast
EOF
"$ASTER_BIN" build-cn-obj --project "$TMP/proj-ok/aster.proj" \
    "$TMP/proj-ok/src/main.ast" -o "$TMP/proj-ok/main.o" > "$TMP/cnobj-ok.log" 2>&1 \
    || { cat "$TMP/cnobj-ok.log" >&2; fail 'build-cn-obj --project failed with a matching [package] version'; }
[ -f "$TMP/proj-ok/main.o" ] || fail 'build-cn-obj --project produced no object'
if "$ASTER_BIN" build-cn-obj --project "$TMP/proj-cnobj-mismatch/aster.proj" \
    "$TMP/proj-cnobj-mismatch/src/main.ast" -o "$TMP/cnobj-mismatch.o" > "$TMP/cnobj-mismatch.log" 2>&1; then
    fail 'build-cn-obj --project passed with a mismatched package version'
fi
grep -q "aster build-cn-obj: package 'standard' version mismatch: aster.proj requires \"0.0.0\" but .* has \"0.23.82-dev\"" \
    "$TMP/cnobj-mismatch.log" || { cat "$TMP/cnobj-mismatch.log" >&2; fail 'build-cn-obj version-mismatch diagnostic is wrong'; }
if "$ASTER_BIN" build-cn-obj --project "$TMP/proj-missing/aster.proj" \
    "$TMP/proj-missing/src/main.ast" -o "$TMP/cnobj-missing.o" > "$TMP/cnobj-missing.log" 2>&1; then
    fail 'build-cn-obj --project passed with no package installed'
fi
grep -q "package 'standard' version \"0.23.82-dev\" required by aster.proj was not found" \
    "$TMP/cnobj-missing.log" || { cat "$TMP/cnobj-missing.log" >&2; fail 'build-cn-obj missing-package diagnostic is wrong'; }
if "$ASTER_BIN" build-cn-obj --project "$TMP/proj-tamper2/aster.proj" \
    "$TMP/proj-tamper2/src/main.ast" -o "$TMP/cnobj-tamper2.o" > "$TMP/cnobj-tamper2.log" 2>&1; then
    fail 'build-cn-obj --project passed with a tampered std.o installed'
fi
grep -q "aster build-cn-obj: package 'standard': files sha256 differs for \"std.o\"" \
    "$TMP/cnobj-tamper2.log" || { cat "$TMP/cnobj-tamper2.log" >&2; fail 'build-cn-obj tampered-std.o diagnostic is wrong'; }
if "$ASTER_BIN" build-cn-obj --project "$TMP/proj-extra/aster.proj" \
    "$TMP/proj-extra/src/main.ast" -o "$TMP/cnobj-extra.o" > "$TMP/cnobj-extra.log" 2>&1; then
    fail 'build-cn-obj --project passed with an extra file in the package'
fi
grep -q "aster build-cn-obj: package 'standard': package contains unexpected file \"extra.txt\"" \
    "$TMP/cnobj-extra.log" || { cat "$TMP/cnobj-extra.log" >&2; fail 'build-cn-obj extra-file diagnostic is wrong'; }
# A project that declares no package is unaffected by the hook.
"$ASTER_BIN" build-cn-obj --project "$TMP/proj-plain/aster.proj" \
    "$TMP/proj-plain/src/main.ast" -o "$TMP/proj-plain/main.o" > "$TMP/cnobj-plain.log" 2>&1 \
    || { cat "$TMP/cnobj-plain.log" >&2; fail 'build-cn-obj --project failed without [package]'; }
[ -f "$TMP/proj-plain/main.o" ] || fail 'build-cn-obj --project produced no object without [package]'

echo '[10/10] doc comments are extracted into the manifest and complete'
# A synthetic source tree exercises the extraction rules: a bilingual
# doc (Chinese first, English after an `@en` marker line), the same
# split written on one line (`/** zh @en en */`), a Chinese-only doc,
# an English-only doc, no doc, an ordinary /* */ comment, a doc
# separated from its declaration by a blank line, a /** hidden inside
# a // line comment, a /** inside a string literal, and doc comments on
# a struct, a const and a global. The bilingual pair carries the same
# pair in both files.
mkdir -p "$TMP/docsrc/cn"
cat > "$TMP/docsrc/aster_std.ast" <<'SRC'
/** 中文一句。
 * @en One English sentence.
 * Continued in English.
 */
fn one(a: i32, b: i32) : i32 { return a + b; }

/** 中文单行。 @en English single line. */
fn two(a: i32, b: i32) : i32 { return a * b; }

fn three(a: i32) : i32 { return a; }

/* An ordinary comment, not a doc comment. */
fn four(a: i32) : i32 { return a; }

/** A doc comment separated from its declaration by a blank line. */

fn five(a: i32) : i32 { return a; }

// /** A doc comment hidden inside a line comment. */
fn six(a: i32) : i32 { return a; }

/** 中文结构。
 * @en An English struct.
 */
struct Point { x: i32, y: i32 }

/** 只有中文的常量。 */
const kAnswer: i32 = 42;

/** 中文全局。
 * @en An English global.
 */
let gCounter: i32 = 0;

/** Doc above a string that mentions a doc comment. */
fn seven(a: i32) : i32 {
    let s: ptr<u8> = "/** not a doc comment */";
    return a;
}

/** 只有中文。 */
fn eight(a: i32) : i32 { return a; }

/** @en English only. */
fn nine(a: i32) : i32 { return a; }
SRC
: > "$TMP/docsrc/aster_core.ast"
cat > "$TMP/docsrc/cn/string-zh.ast" <<'SRC'
// aster:language=zh
包名 标准库.文本 = standard.text

/** 返回字符串的长度。
 * @en Return the length of the string.
 */
方法 长度(值: 字符串): 长整数
    返回 0
结束 方法
SRC
cat > "$TMP/docsrc/cn/string-en.ast" <<'SRC'
// aster:language=en
package 标准库.文本 = standard.text;

/** 返回字符串的长度。
 * @en Return the length of the string.
 */
fn length(value: string): i64 {
    return 0;
}
SRC
"$ASTER_BIN" pack --src-dir "$TMP/docsrc" --out "$TMP/docpkg" > /dev/null 2>&1 \
    || fail 'aster pack failed on the doc fixture'
python3 - "$TMP/docpkg/manifest.json" <<'PY' || fail 'doc extraction is wrong'
import json, sys
m = json.load(open(sys.argv[1]))
docs = {e["name"]: (e["doc"], e["doc_en"]) for e in m["exports"]}
assert docs["one"] == ("中文一句。", "One English sentence.\nContinued in English."), docs["one"]
assert docs["two"] == ("中文单行。", "English single line."), docs["two"]
assert docs["three"] == ("", ""), docs["three"]
assert docs["four"] == ("", ""), docs["four"]
assert docs["five"] == ("", ""), docs["five"]
assert docs["six"] == ("", ""), docs["six"]
assert docs["Point"] == ("中文结构。", "An English struct."), docs["Point"]
assert docs["kAnswer"] == ("只有中文的常量。", ""), docs["kAnswer"]
assert docs["gCounter"] == ("中文全局。", "An English global."), docs["gCounter"]
assert docs["seven"] == ("Doc above a string that mentions a doc comment.", ""), docs["seven"]
assert docs["eight"] == ("只有中文。", ""), docs["eight"]
assert docs["nine"] == ("", "English only."), docs["nine"]
assert docs["length"] == ("返回字符串的长度。", "Return the length of the string."), docs["length"]
PY
# complete shows the doc in the file's language in both formats; a
# doc-less export still shows an empty doc column, and a Chinese-only
# doc falls back to Chinese for an English file.
"$ASTER_BIN" complete --language en "$TMP/docpkg" > "$TMP/doc-complete.txt" 2>&1
python3 - "$TMP/doc-complete.txt" <<'PY' || fail 'complete (text) doc is wrong'
import sys
rows = {}
for line in open(sys.argv[1], encoding="utf-8"):
    parts = line.rstrip("\n").split("\t")
    assert len(parts) == 4, parts
    rows[parts[0]] = parts[3]
assert rows["one"] == "One English sentence. Continued in English.", rows["one"]
assert rows["two"] == "English single line.", rows["two"]
assert rows["three"] == "", rows["three"]
assert rows["eight"] == "只有中文。", rows["eight"]
assert rows["nine"] == "English only.", rows["nine"]
PY
"$ASTER_BIN" complete --language en --format json "$TMP/docpkg" > "$TMP/doc-complete.json" 2>&1
python3 - "$TMP/doc-complete.json" <<'PY' || fail 'complete (json) doc is wrong'
import json, sys
docs = {e["name"]: (e["doc"], e["doc_en"]) for e in json.load(open(sys.argv[1]))}
assert docs["one"] == ("中文一句。", "One English sentence.\nContinued in English."), docs["one"]
assert docs["two"] == ("中文单行。", "English single line."), docs["two"]
assert docs["eight"] == ("只有中文。", ""), docs["eight"]
assert docs["nine"] == ("", "English only."), docs["nine"]
assert docs["three"] == ("", ""), docs["three"]
PY
"$ASTER_BIN" complete --language zh "$TMP/docpkg" > "$TMP/doc-complete-zh.txt" 2>&1
python3 - "$TMP/doc-complete-zh.txt" <<'PY' || fail 'complete (zh) is missing the doc for 长度'
import sys
rows = {}
for line in open(sys.argv[1], encoding="utf-8"):
    parts = line.rstrip("\n").split("\t")
    assert len(parts) == 4, parts
    rows[parts[0]] = parts[3]
assert rows["长度"] == "返回字符串的长度。", rows["长度"]
PY

# complete reads the [language] default from aster.proj: --project DIR
# (and --project=DIR), the nearest aster.proj above the completed file,
# then aster.proj in the working directory, then the built-in zh.
# The chain is --language > file directive > per-file entry > project
# default > zh; --language wins over a file directive outright (unlike
# build, which errors on that conflict).
mkdir -p "$TMP/proj-en/src" "$TMP/noproj" "$TMP/emptycwd" "$TMP/emptyproj"
printf 'kind = "app"\n[language]\ndefault = "en"\n' > "$TMP/proj-en/aster.proj"
printf '// no language directive\n' > "$TMP/proj-en/src/plain.ast"
printf '// aster:language=zh\n' > "$TMP/proj-en/src/decl-zh.ast"
printf '// aster:language=zh\n' > "$TMP/noproj/decl-zh.ast"
printf '// aster:language=en\n' > "$TMP/noproj/decl-en.ast"
printf '// no language directive\n' > "$TMP/noproj/plain.ast"
# (1) A project default of en applies to a file with no directive, via
# --project, via --project=, and via the ancestor lookup with no flag.
for projflag in "--project $TMP/proj-en" "--project=$TMP/proj-en" ""; do
    # shellcheck disable=SC2086
    "$ASTER_BIN" complete $projflag "$TMP/docpkg" "$TMP/proj-en/src/plain.ast" > "$TMP/doc-complete-proj.txt" 2>&1 \
        || fail "complete with proj $projflag failed"
    python3 - "$TMP/doc-complete-proj.txt" <<'PYEOF' || fail 'complete did not follow the project language default'
import sys
rows = {}
for line in open(sys.argv[1], encoding="utf-8"):
    parts = line.rstrip("\n").split("\t")
    assert len(parts) == 4, parts
    rows[parts[0]] = parts[3]
assert rows["length"] == "Return the length of the string.", rows["length"]
assert rows["one"] == "One English sentence. Continued in English.", rows["one"]
PYEOF
done
# (2) --language beats a file directive, in both directions (run from an
# empty directory so no working-directory aster.proj can interfere).
(cd "$TMP/emptycwd" && "$ASTER_BIN" complete --language en "$TMP/docpkg" "$TMP/noproj/decl-zh.ast") > "$TMP/doc-complete-flag-en.txt" 2>&1 \
    || fail 'complete --language en over a zh directive failed'
grep -q "one.*One English sentence" "$TMP/doc-complete-flag-en.txt" \
    || fail '--language en did not win over a zh file directive'
(cd "$TMP/emptycwd" && "$ASTER_BIN" complete --language zh "$TMP/docpkg" "$TMP/noproj/decl-en.ast") > "$TMP/doc-complete-flag-zh.txt" 2>&1 \
    || fail 'complete --language zh over an en directive failed'
python3 - "$TMP/doc-complete-flag-zh.txt" <<'PYEOF' || fail '--language zh did not win over an en file directive'
import sys
rows = {}
for line in open(sys.argv[1], encoding="utf-8"):
    parts = line.rstrip("\n").split("\t")
    assert len(parts) == 4, parts
    rows[parts[0]] = parts[3]
assert rows["长度"] == "返回字符串的长度。", rows["长度"]
PYEOF
# (3) A file directive beats the project default (zh directive, en project).
"$ASTER_BIN" complete "$TMP/docpkg" "$TMP/proj-en/src/decl-zh.ast" > "$TMP/doc-complete-directive.txt" 2>&1 \
    || fail 'complete with a directive over a project default failed'
python3 - "$TMP/doc-complete-directive.txt" <<'PYEOF' || fail 'a file directive did not win over the project default'
import sys
rows = {}
for line in open(sys.argv[1], encoding="utf-8"):
    parts = line.rstrip("\n").split("\t")
    assert len(parts) == 4, parts
    rows[parts[0]] = parts[3]
assert rows["长度"] == "返回字符串的长度。", rows["长度"]
PYEOF
# (4) With no project anywhere, no directive and no --language, the
# built-in default zh applies (with and without a file argument).
(cd "$TMP/emptycwd" && "$ASTER_BIN" complete "$TMP/docpkg" "$TMP/noproj/plain.ast") > "$TMP/doc-complete-noproj.txt" 2>&1 \
    || fail 'complete with no project failed'
(cd "$TMP/emptycwd" && "$ASTER_BIN" complete "$TMP/docpkg") > "$TMP/doc-complete-noproj-nofile.txt" 2>&1 \
    || fail 'complete with no project and no file failed'
for f in "$TMP/doc-complete-noproj.txt" "$TMP/doc-complete-noproj-nofile.txt"; do
    python3 - "$f" <<'PYEOF' || fail 'complete did not default to zh with no project'
import sys
rows = {}
for line in open(sys.argv[1], encoding="utf-8"):
    parts = line.rstrip("\n").split("\t")
    assert len(parts) == 4, parts
    rows[parts[0]] = parts[3]
assert rows["长度"] == "返回字符串的长度。", rows["长度"]
PYEOF
done
# (5) --project pointing at a missing directory, or at a directory with
# no aster.proj inside, is a clear rc=1 diagnostic, not a crash.
if "$ASTER_BIN" complete --project "$TMP/does-not-exist" "$TMP/docpkg" > "$TMP/doc-complete-badproj.log" 2>&1; then
    fail 'complete --project passed with a missing project directory'
fi
grep -q "项目目录不存在" "$TMP/doc-complete-badproj.log" \
    || { cat "$TMP/doc-complete-badproj.log" >&2; fail 'complete --project missing-directory diagnostic is wrong'; }
if "$ASTER_BIN" complete --project "$TMP/emptyproj" "$TMP/docpkg" > "$TMP/doc-complete-noprojfile.log" 2>&1; then
    fail 'complete --project passed with a directory containing no aster.proj'
fi
grep -q "no aster.proj in project directory" "$TMP/doc-complete-noprojfile.log" \
    || { cat "$TMP/doc-complete-noprojfile.log" >&2; fail 'complete --project no-aster.proj diagnostic is wrong'; }

echo 'package checks passed'
