#!/bin/sh
# Package format checks (stdlib §11): `aster pack` builds the standard
# library package (manifest + canonical sources + prebuilt std.o),
# `aster pack --check` fails when the sources and the manifest disagree,
# `aster complete` reads the manifest (not the sources) filtered by the
# file's language, and aster.proj `[package]` declarations are version
# checked by build/test before any import resolves.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ASTER_BIN=${ASTER_BIN:-$ROOT/aster}
RUNNER=${RUNNER:-$ROOT/tests/run-aarch64.sh}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

fail() { echo "FAIL: $1" >&2; exit 1; }

echo '[1/7] pack generates a complete manifest'
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
    "aster_std.ast", "aster_core.ast", "cn/string-zh.ast", "cn/string-en.ast"], m["files"]
kinds = {}
for e in m["exports"]:
    kinds[e["kind"]] = kinds.get(e["kind"], 0) + 1
    assert set(e) == {"name", "name_zh", "kind", "signature", "package", "doc"}, e
    assert e["doc"] == "", e
assert kinds == {"function": 113, "struct": 5, "const": 13, "global": 10}, kinds
text = [e for e in m["exports"] if e["package"] == "standard.text"]
assert [(e["name"], e["name_zh"]) for e in text] == [
    ("length", "长度"), ("concat", "拼接"), ("equals", "相等"), ("less", "更小")], text
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
for pair in "长度 length" "拼接 concat" "相等 equals" "更小 less"; do
    set -- $pair
    grep -q "\"name_zh\": \"$1\"" "$TMP/pkg/manifest.json" || fail "manifest is missing $1"
    grep -q "\"name\": \"$2\"" "$TMP/pkg/manifest.json" || fail "manifest is missing $2"
done
for f in aster_std.ast aster_core.ast cn/string-zh.ast cn/string-en.ast; do
    h=$(sha256sum "$ROOT/stdlib/$f" | awk '{print $1}')
    grep -q "\"path\": \"$f\", \"sha256\": \"$h\"" "$TMP/pkg/manifest.json" \
        || fail "manifest hash is wrong for $f"
done
# std.o is the object `build-obj` produces from the same source, byte for byte.
"$ASTER_BIN" build-obj "$ROOT/stdlib/aster_std.ast" -o "$TMP/std-ref.o" > /dev/null 2>&1
cmp "$TMP/pkg/std.o" "$TMP/std-ref.o" || fail 'std.o differs from build-obj output'
# Packing twice is deterministic.
"$ASTER_BIN" pack --src-dir "$ROOT/stdlib" --out "$TMP/pkg2" > /dev/null 2>&1
cmp "$TMP/pkg/manifest.json" "$TMP/pkg2/manifest.json" || fail 'pack is not deterministic'

echo '[2/7] pack --check passes on a fresh package and fails on tampering'
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
# A package missing one of its files is incomplete and must fail --check.
"$ASTER_BIN" pack --src-dir "$ROOT/stdlib" --out "$TMP/pkg-missing" > /dev/null 2>&1
rm "$TMP/pkg-missing/cn/string-en.ast"
if "$ASTER_BIN" pack --src-dir "$ROOT/stdlib" --check "$TMP/pkg-missing" > "$TMP/check-missing.log" 2>&1; then
    fail 'pack --check passed on a package missing a file'
fi
grep -q 'package is incomplete: missing file "cn/string-en.ast"' "$TMP/check-missing.log" \
    || fail 'missing-file diagnostic is wrong'

echo '[3/7] complete filters by the file language'
printf '// aster:language=zh\n' > "$TMP/file-zh.ast"
printf '// aster:language=en\n' > "$TMP/file-en.ast"
"$ASTER_BIN" complete "$TMP/pkg2" "$TMP/file-zh.ast" > "$TMP/complete-zh.txt" 2>&1
grep -q '^长度' "$TMP/complete-zh.txt" || fail 'zh completion is missing 长度'
grep -q '^拼接' "$TMP/complete-zh.txt" || fail 'zh completion is missing 拼接'
if grep -q '^length' "$TMP/complete-zh.txt"; then fail 'zh completion leaked length'; fi
if grep -q '^memcpy' "$TMP/complete-zh.txt"; then fail 'zh completion leaked an English-only routine'; fi
"$ASTER_BIN" complete "$TMP/pkg2" "$TMP/file-en.ast" > "$TMP/complete-en.txt" 2>&1
grep -q '^length' "$TMP/complete-en.txt" || fail 'en completion is missing length'
grep -q '^memcpy' "$TMP/complete-en.txt" || fail 'en completion is missing memcpy'
if grep -q '^长度' "$TMP/complete-en.txt"; then fail 'en completion leaked 长度'; fi
# --language is the default only when no file is given; a file's own
# directive wins over it (an en file stays en under --language zh).
"$ASTER_BIN" complete --language zh "$TMP/pkg2" > "$TMP/complete-defzh.txt" 2>&1
grep -q '^长度' "$TMP/complete-defzh.txt" || fail '--language zh did not default to zh'
if grep -q '^length' "$TMP/complete-defzh.txt"; then fail '--language zh leaked length'; fi
"$ASTER_BIN" complete --language zh "$TMP/pkg2" "$TMP/file-en.ast" > "$TMP/complete-filewins.txt" 2>&1
grep -q '^length' "$TMP/complete-filewins.txt" || fail 'file language did not win over --language'
# JSON output carries the manifest export shape; a manifest.json path works too.
"$ASTER_BIN" complete --language zh --format json "$TMP/pkg2/manifest.json" > "$TMP/complete-zh.json" 2>&1
python3 - "$TMP/complete-zh.json" <<'PY' || fail 'complete --format json is wrong'
import json, sys
entries = json.load(open(sys.argv[1]))
assert [(e["name"], e["name_zh"]) for e in entries] == [
    ("length", "长度"), ("concat", "拼接"), ("equals", "相等"), ("less", "更小")], entries
PY
"$ASTER_BIN" complete --language en --format json "$TMP/pkg2" > "$TMP/complete-en.json" 2>&1
python3 -c "import json,sys; assert len(json.load(open(sys.argv[1]))) == 141" "$TMP/complete-en.json" \
    || fail 'complete --format json (en) does not list all 141 exports'

echo '[4/7] [package] version check passes, and [package] does not disturb [language]'
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

echo '[5/7] version check reports a missing package and a version mismatch'
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

echo '[6/7] version check runs for test as well, and undeclared projects are unaffected'
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

echo '[7/7] pack/complete reject bad usage'
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

echo 'package checks passed'
