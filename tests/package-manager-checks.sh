#!/bin/sh
# Package manager checks (`aster pkg`): install / upgrade / list / remove
# from a local directory source or a git source, with the lock file
# <project>/packages/.aster-pkg-sources recording where each package
# came from. A package whose files do not match its manifest is never
# installed, and a failed install leaves no half-installed directory.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ASTER_BIN=${ASTER_BIN:-$ROOT/aster}
RUNNER=${RUNNER:-$ROOT/tests/run-aarch64.sh}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

fail() { echo "FAIL: $1" >&2; exit 1; }

# make_demo_pkg DIR VERSION [CONTENT]: a minimal hand-built package
# (one source file, empty exports) with a correct manifest.
make_demo_pkg() {
    _dir=$1; _ver=$2; _content=${3:-"// demo package\n"}
    mkdir -p "$_dir"
    printf '%s' "$_content" > "$_dir/demo.ast"
    python3 - "$_dir" "$_ver" <<'PY'
import hashlib, json, sys
d, ver = sys.argv[1], sys.argv[2]
data = open(d + "/demo.ast", "rb").read()
m = {"name": "demo", "name_zh": "演示包", "version": ver,
     "files": [{"path": "demo.ast", "sha256": hashlib.sha256(data).hexdigest()}],
     "exports": []}
open(d + "/manifest.json", "w", encoding="utf-8").write(json.dumps(m, ensure_ascii=False, indent=2) + "\n")
PY
}

# fresh project dir (no aster.proj needed except where a build is run)
new_proj() { mkdir -p "$1"; }

echo '[1/7] local install: pack the standard library, install it, build with it'
"$ASTER_BIN" pack --src-dir "$ROOT/stdlib" --out "$TMP/pkg-src" > /dev/null 2>&1 \
    || fail 'aster pack failed'
mkdir -p "$TMP/proj/src"
cat > "$TMP/proj/src/main.ast" <<'SRC'
方法 启动方法(): 整数
返回 0
结束 方法
SRC
cat > "$TMP/proj/aster.proj" <<'EOF'
name pkgtest
[package]
standard = "0.23.82-dev"
[language]
default = "zh"
src/main.ast
EOF
"$ASTER_BIN" pkg install "$TMP/pkg-src" --project "$TMP/proj" > "$TMP/install.log" 2>&1 \
    || { cat "$TMP/install.log" >&2; fail 'pkg install of the standard library failed'; }
grep -q 'installed standard (标准库) 0.23.82-dev' "$TMP/install.log" \
    || fail 'install output does not name the package and version'
[ -f "$TMP/proj/packages/standard/manifest.json" ] || fail 'installed manifest.json missing'
[ -f "$TMP/proj/packages/standard/std.o" ] || fail 'installed std.o missing'
[ -f "$TMP/proj/packages/standard/cn/string-zh.ast" ] || fail 'installed cn/string-zh.ast missing'
# The installed package is read-only on disk, like a packed one.
[ -z "$(find "$TMP/proj/packages/standard" -perm /0222 -print -quit)" ] \
    || fail 'installed package left a writable file or directory'
# The lock file records the source, and lives beside the packages.
grep -q "\"name\": \"standard\"" "$TMP/proj/packages/.aster-pkg-sources" \
    || fail 'lock file does not record the package name'
grep -q "\"source\": \"$TMP/pkg-src\"" "$TMP/proj/packages/.aster-pkg-sources" \
    || fail 'lock file does not record the source'
grep -q "\"version\": \"0.23.82-dev\"" "$TMP/proj/packages/.aster-pkg-sources" \
    || fail 'lock file does not record the version'
(cd "$TMP/proj" && "$ASTER_BIN" build > build.log 2>&1) \
    || { cat "$TMP/proj/build.log" >&2; fail 'build with the installed package failed'; }
if "$RUNNER" "$TMP/proj/build/pkgtest"; then status=0; else status=$?; fi
[ "$status" -eq 0 ] || fail "installed-package project returned $status, expected 0"

echo '[2/7] git install: file:// URL and plain local path, both from a local repo'
make_demo_pkg "$TMP/demo-repo" "0.1.0"
(cd "$TMP/demo-repo" && git init -q . && git -c user.name=t -c user.email=t@t add -A \
    && git -c user.name=t -c user.email=t@t commit -qm 'demo 0.1.0')
new_proj "$TMP/proj-git-url"
"$ASTER_BIN" pkg install "file://$TMP/demo-repo" --project "$TMP/proj-git-url" > "$TMP/git-url.log" 2>&1 \
    || { cat "$TMP/git-url.log" >&2; fail 'pkg install from a file:// git URL failed'; }
grep -q 'installed demo (演示包) 0.1.0' "$TMP/git-url.log" || fail 'git URL install output is wrong'
[ -f "$TMP/proj-git-url/packages/demo/demo.ast" ] || fail 'git URL install left no demo.ast'
[ -d "$TMP/proj-git-url/packages/demo/.git" ] && fail 'installed package still contains .git'
grep -q "\"source\": \"file://$TMP/demo-repo\"" "$TMP/proj-git-url/packages/.aster-pkg-sources" \
    || fail 'lock file does not record the git URL source'
new_proj "$TMP/proj-git-path"
"$ASTER_BIN" pkg install "$TMP/demo-repo" --project "$TMP/proj-git-path" > "$TMP/git-path.log" 2>&1 \
    || { cat "$TMP/git-path.log" >&2; fail 'pkg install from a local git path failed'; }
grep -q 'installed demo (演示包) 0.1.0' "$TMP/git-path.log" || fail 'local git path install output is wrong'
[ -f "$TMP/proj-git-path/packages/demo/demo.ast" ] || fail 'local git path install left no demo.ast'
[ -d "$TMP/proj-git-path/packages/demo/.git" ] && fail 'local-path install left .git in the package'
# No clone scratch directory is left behind in /tmp.
[ -z "$(ls -d /tmp/aster-pkg-clone.* 2>/dev/null)" ] || fail 'git install left a clone scratch directory'

echo '[3/7] upgrade: a newer source version replaces the package; a second upgrade is a no-op'
new_proj "$TMP/proj-up"
make_demo_pkg "$TMP/demo-up" "0.1.0" "// v1\n"
"$ASTER_BIN" pkg install "$TMP/demo-up" --project "$TMP/proj-up" > /dev/null 2>&1 \
    || fail 'upgrade fixture install failed'
grep -q 'v1' "$TMP/proj-up/packages/demo/demo.ast" || fail 'upgrade fixture content is wrong'
make_demo_pkg "$TMP/demo-up" "0.2.0" "// v2\n"
"$ASTER_BIN" pkg upgrade demo --project "$TMP/proj-up" > "$TMP/upgrade.log" 2>&1 \
    || { cat "$TMP/upgrade.log" >&2; fail 'pkg upgrade failed'; }
grep -q 'upgraded demo (演示包) 0.1.0 -> 0.2.0' "$TMP/upgrade.log" \
    || fail 'upgrade output does not show the version change'
grep -q 'v2' "$TMP/proj-up/packages/demo/demo.ast" || fail 'upgrade did not replace the package files'
grep -q '"version": "0.2.0"' "$TMP/proj-up/packages/.aster-pkg-sources" \
    || fail 'upgrade did not update the lock file version'
before=$(sha256sum "$TMP/proj-up/packages/demo/demo.ast" | awk '{print $1}')
"$ASTER_BIN" pkg upgrade demo --project "$TMP/proj-up" > "$TMP/upgrade2.log" 2>&1 \
    || { cat "$TMP/upgrade2.log" >&2; fail 'second pkg upgrade failed'; }
grep -q '已是最新 0.2.0' "$TMP/upgrade2.log" || fail 'second upgrade did not report already up to date'
after=$(sha256sum "$TMP/proj-up/packages/demo/demo.ast" | awk '{print $1}')
[ "$before" = "$after" ] || fail 'no-op upgrade changed the installed package'
# The same, through a git source: the upgrade re-clones and picks up the new commit.
new_proj "$TMP/proj-git-up"
"$ASTER_BIN" pkg install "$TMP/demo-repo" --project "$TMP/proj-git-up" > /dev/null 2>&1 \
    || fail 'git upgrade fixture install failed'
make_demo_pkg "$TMP/demo-repo" "0.3.0" "// v3\n"
(cd "$TMP/demo-repo" && git -c user.name=t -c user.email=t@t add -A \
    && git -c user.name=t -c user.email=t@t commit -qm 'demo 0.3.0')
"$ASTER_BIN" pkg upgrade demo --project "$TMP/proj-git-up" > "$TMP/git-upgrade.log" 2>&1 \
    || { cat "$TMP/git-upgrade.log" >&2; fail 'pkg upgrade from a git source failed'; }
grep -q 'upgraded demo (演示包) 0.1.0 -> 0.3.0' "$TMP/git-upgrade.log" \
    || fail 'git upgrade output does not show the version change'
grep -q 'v3' "$TMP/proj-git-up/packages/demo/demo.ast" || fail 'git upgrade did not replace the package files'

echo '[4/7] list shows installed packages; remove drops them from the list and the lock file'
"$ASTER_BIN" pkg list --project "$TMP/proj-up" > "$TMP/list.log" 2>&1 \
    || fail 'pkg list failed'
grep -q '^demo (演示包) 0.2.0$' "$TMP/list.log" || fail 'list does not show the upgraded package'
"$ASTER_BIN" pkg remove demo --project "$TMP/proj-up" > "$TMP/remove.log" 2>&1 \
    || { cat "$TMP/remove.log" >&2; fail 'pkg remove failed'; }
grep -q 'removed demo' "$TMP/remove.log" || fail 'remove output does not name the package'
[ ! -e "$TMP/proj-up/packages/demo" ] || fail 'remove left the package directory behind'
if grep -q '"name": "demo"' "$TMP/proj-up/packages/.aster-pkg-sources"; then
    fail 'remove left the lock file entry behind'
fi
"$ASTER_BIN" pkg list --project "$TMP/proj-up" > "$TMP/list2.log" 2>&1
grep -q '未安装包' "$TMP/list2.log" || fail 'list after remove does not report no packages'
if grep -q '^demo ' "$TMP/list2.log"; then fail 'list after remove still shows the package'; fi

echo '[5/7] verification failure installs nothing: bad manifest, tampered std.o, extra file'
# A manifest that is not JSON at all.
new_proj "$TMP/proj-badjson"
cp -r "$TMP/pkg-src" "$TMP/pkg-badjson"
chmod -R u+w "$TMP/pkg-badjson"
printf 'not json' > "$TMP/pkg-badjson/manifest.json"
if "$ASTER_BIN" pkg install "$TMP/pkg-badjson" --project "$TMP/proj-badjson" > "$TMP/badjson.log" 2>&1; then
    fail 'pkg install accepted a manifest that is not JSON'
fi
grep -q 'invalid JSON' "$TMP/badjson.log" || fail 'bad-manifest diagnostic does not name the JSON error'
[ ! -e "$TMP/proj-badjson/packages/standard" ] || fail 'bad-manifest install left a half-installed package'
# A tampered std.o inside the source.
new_proj "$TMP/proj-tamper"
cp -r "$TMP/pkg-src" "$TMP/pkg-tamper"
chmod -R u+w "$TMP/pkg-tamper"
printf 'X' >> "$TMP/pkg-tamper/std.o"
if "$ASTER_BIN" pkg install "$TMP/pkg-tamper" --project "$TMP/proj-tamper" > "$TMP/tamper.log" 2>&1; then
    fail 'pkg install accepted a tampered std.o'
fi
grep -q 'sha256 differs for "std.o"' "$TMP/tamper.log" || fail 'tampered-std.o diagnostic does not name the file hash'
[ ! -e "$TMP/proj-tamper/packages/standard" ] || fail 'tampered-std.o install left a half-installed package'
# An extra file in the source.
new_proj "$TMP/proj-extra"
cp -r "$TMP/pkg-src" "$TMP/pkg-extra"
chmod -R u+w "$TMP/pkg-extra"
echo 'not part of the package' > "$TMP/pkg-extra/extra.txt"
if "$ASTER_BIN" pkg install "$TMP/pkg-extra" --project "$TMP/proj-extra" > "$TMP/extra.log" 2>&1; then
    fail 'pkg install accepted a source with an extra file'
fi
grep -q 'package contains unexpected file "extra.txt"' "$TMP/extra.log" \
    || fail 'extra-file diagnostic does not name the file'
[ ! -e "$TMP/proj-extra/packages/standard" ] || fail 'extra-file install left a half-installed package'

echo '[6/7] error cases fail with a diagnostic and a non-zero exit code'
new_proj "$TMP/proj-err"
if "$ASTER_BIN" pkg install "$TMP/does-not-exist" --project "$TMP/proj-err" > "$TMP/err-missing.log" 2>&1; then
    fail 'pkg install accepted a missing source'
fi
grep -q '源不存在' "$TMP/err-missing.log" || fail 'missing-source diagnostic is wrong'
if "$ASTER_BIN" pkg install "file://$TMP/does-not-exist-repo" --project "$TMP/proj-err" > "$TMP/err-clone.log" 2>&1; then
    fail 'pkg install accepted a git URL that cannot be cloned'
fi
grep -q 'git clone failed' "$TMP/err-clone.log" || fail 'clone-failure diagnostic does not name git clone'
[ ! -e "$TMP/proj-err/packages/demo" ] || fail 'failed clone install left a package behind'
if "$ASTER_BIN" pkg upgrade standard --project "$TMP/proj-err" > "$TMP/err-nolock.log" 2>&1; then
    fail 'pkg upgrade passed with no lock record'
fi
grep -q '未记录来源' "$TMP/err-nolock.log" || fail 'upgrade-without-lock diagnostic is wrong'
if "$ASTER_BIN" pkg remove nope --project "$TMP/proj-err" > "$TMP/err-remove.log" 2>&1; then
    fail 'pkg remove passed for a package that is not installed'
fi
grep -q '包未安装' "$TMP/err-remove.log" || fail 'remove-missing diagnostic is wrong'
# A directory that is neither a package nor a git repository.
mkdir -p "$TMP/not-a-package"
if "$ASTER_BIN" pkg install "$TMP/not-a-package" --project "$TMP/proj-err" > "$TMP/err-notpkg.log" 2>&1; then
    fail 'pkg install accepted a directory with no manifest and no .git'
fi
grep -q '源不是合法的包目录也不是 git 仓库' "$TMP/err-notpkg.log" \
    || fail 'not-a-package diagnostic is wrong'
if "$ASTER_BIN" pkg > /dev/null 2>&1; then fail 'pkg with no subcommand passed'; fi
if "$ASTER_BIN" pkg frobnicate --project "$TMP/proj-err" > /dev/null 2>&1; then
    fail 'pkg accepted an unknown subcommand'
fi
if "$ASTER_BIN" pkg install --project "$TMP/does-not-exist-proj" "$TMP/pkg-src" > /dev/null 2>&1; then
    fail 'pkg install passed with a missing project directory'
fi

echo '[7/7] Chinese aliases: 包 安装 / 列表 / 删除'
new_proj "$TMP/proj-zh"
"$ASTER_BIN" 包 安装 "$TMP/demo-up" --project "$TMP/proj-zh" > "$TMP/zh-install.log" 2>&1 \
    || { cat "$TMP/zh-install.log" >&2; fail '包 安装 failed'; }
grep -q 'installed demo (演示包) 0.2.0' "$TMP/zh-install.log" || fail '包 安装 output is wrong'
"$ASTER_BIN" 包 列表 --project "$TMP/proj-zh" > "$TMP/zh-list.log" 2>&1 \
    || fail '包 列表 failed'
grep -q '^demo (演示包) 0.2.0$' "$TMP/zh-list.log" || fail '包 列表 does not show the package'
"$ASTER_BIN" 包 升级 demo --project "$TMP/proj-zh" > "$TMP/zh-upgrade.log" 2>&1 \
    || fail '包 升级 failed'
grep -q '已是最新 0.2.0' "$TMP/zh-upgrade.log" || fail '包 升级 did not report already up to date'
"$ASTER_BIN" 包 删除 demo --project "$TMP/proj-zh" > /dev/null 2>&1 \
    || fail '包 删除 failed'
[ ! -e "$TMP/proj-zh/packages/demo" ] || fail '包 删除 left the package directory behind'
"$ASTER_BIN" pkg list --project "$TMP/proj-zh" > "$TMP/zh-list2.log" 2>&1
grep -q '未安装包' "$TMP/zh-list2.log" || fail 'list after 包 删除 does not report no packages'

echo 'package manager checks passed'
