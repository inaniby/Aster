#!/bin/sh
# tests/project-checks.sh — v0.23.77-dev project workflow: `aster new`, `aster
# build` (with its content-keyed object cache) and `aster deps`.
#
# Layers:
#   [1] strict build of the compiler
#   [2] `aster new` scaffolds a project that builds and runs
#   [3] a second build reuses every object (content cache, no recompilation)
#   [4] editing a source recompiles it; editing an included file recompiles the
#       file that includes it
#   [5] editing an `@embed` asset recompiles the object that embeds it
#   [6] `aster deps` names the include and the asset
#   [7] `--no-cache` compiles again, and the output is byte-identical
#   [8] error paths: no aster.proj, a missing source, an unknown option
#   [9] mutation: a cache entry whose meta has lost its `src` line is not reused;
#       a planted object whose bytes no longer match the meta's `obj` hash is
#       not reused either, and a meta from before the `obj` line existed
#       (no hash at all) fails closed to a recompile
set -eu
cd "$(dirname "$0")/.."
ROOT=$(pwd)
# v0.23.77-dev (host adaptation): run AArch64 products through the shared
# runner. It executes them natively on an AArch64/Termux host and under qemu
# elsewhere, so the very same suite is valid on both kinds of machine.
RUNNER=${RUNNER:-tests/run-aarch64.sh}
case "$RUNNER" in
    /*) ;;
    *) if [ -f "$RUNNER" ]; then RUNNER="$(cd "$(dirname "$RUNNER")" && pwd)/$(basename "$RUNNER")"; fi ;;
esac
. tests/lib/tmpdir.sh

CXX=${CXX:-c++}
ASTER="$TMPD/project-aster"
WORK="$TMPD/project-work"
rm -rf "$WORK"; mkdir -p "$WORK"

printf '%s\n' '[1/19] Strictly build Aster compiler'
$CXX -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror -o "$ASTER" src/aster.cpp
printf '  %-40s %s\n' 'compiler built' 'ok'

printf '%s\n' '[2/19] aster new scaffolds a project that builds and runs'
cd "$WORK"
"$ASTER" new app >/dev/null
[ -f app/aster.proj ] && [ -f app/src/main.ast ] && [ -f app/src/util.ast ] || {
    echo 'FAIL: aster new did not scaffold the project files' >&2; exit 1; }
cd app
"$ASTER" build > build.log 2>&1
[ -x build/app ] || { echo 'FAIL: aster build produced no executable' >&2; cat build.log >&2; exit 1; }
set +e
"$RUNNER" ./build/app
rc=$?
set -e
[ "$rc" = 0 ] || { echo "FAIL: the scaffolded program exited $rc, expected 0" >&2; exit 1; }
printf '  %-40s %s\n' 'scaffold builds and runs (exit 0)' 'ok'

printf '%s\n' '[3/19] a second build reuses every object'
"$ASTER" build > build2.log 2>&1
grep -q '(0 compiled, 2 reused)' build2.log || {
    echo 'FAIL: the second build did not reuse both objects:' >&2; cat build2.log >&2; exit 1; }
cp build/app first-app
"$ASTER" build > build3.log 2>&1
cmp -s build/app first-app || { echo 'FAIL: rebuilding changed the executable' >&2; exit 1; }
printf '  %-40s %s\n' '0 compiled, 2 reused; output byte-identical' 'ok'

printf '%s\n' '[4/19] editing a source or an included file recompiles what depends on it'
# util.ast changes first: it recompiles, and so does the file that includes it
printf 'fn add(a: i32, b: i32) -> i32 {\n    return a + b + 0;\n}\n' > src/util.ast
"$ASTER" build > b1.log 2>&1
grep -q '(2 compiled, 0 reused)' b1.log || {
    echo 'FAIL: editing util.ast did not recompile util.ast and the file that includes it:' >&2
    cat b1.log >&2; exit 1; }
# then only main.ast: exactly one object recompiles
printf 'include "util.ast";\nfn main() -> i32 { return add(40, 3) - 43; }\n' > src/main.ast
"$ASTER" build > b2.log 2>&1
grep -q '(1 compiled, 1 reused)' b2.log || {
    echo 'FAIL: editing main.ast did not recompile exactly it:' >&2; cat b2.log >&2; exit 1; }
printf 'fn add(a: i32, b: i32) -> i32 {\n    return a + b - 0;\n}\n' > src/util.ast
"$ASTER" build > b3.log 2>&1
grep -q '(2 compiled, 0 reused)' b3.log || {
    echo 'FAIL: the second util.ast edit did not recompile both:' >&2; cat b3.log >&2; exit 1; }
printf '  %-40s %s\n' 'source and include edits recompile the right objects' 'ok'

printf '%s\n' '[5/19] editing an @embed asset recompiles the embedding object'
printf 'first asset\n' > src/asset.txt
printf 'include "util.ast";\nlet blob: ptr = @embed("asset.txt");\nfn main() -> i32 { if (blob == 0) { return 1; } return add(40, 2) - 42; }\n' > src/main.ast
"$ASTER" build > a1.log 2>&1
grep -q '(1 compiled, 1 reused)' a1.log || {
    echo 'FAIL: adding an @embed did not recompile main:' >&2; cat a1.log >&2; exit 1; }
printf 'second asset, longer\n' > src/asset.txt
"$ASTER" build > a2.log 2>&1
grep -q '(1 compiled, 1 reused)' a2.log || {
    echo 'FAIL: editing an @embed asset did not recompile the object that embeds it:' >&2
    cat a2.log >&2; exit 1; }
printf '  %-40s %s\n' 'asset edit recompiles the embedder' 'ok'

printf '%s\n' '[6/19] aster deps names the include and the asset'
"$ASTER" deps src/main.ast -o main.o > deps.txt
grep -q 'main.o: src/main.ast' deps.txt || { echo 'FAIL: the deps rule has no target' >&2; cat deps.txt >&2; exit 1; }
grep -q 'util.ast' deps.txt || { echo 'FAIL: the deps rule lost the include' >&2; cat deps.txt >&2; exit 1; }
grep -q 'asset.txt' deps.txt || { echo 'FAIL: the deps rule lost the @embed asset' >&2; cat deps.txt >&2; exit 1; }
printf '  %-40s %s\n' 'rule lists source, include and asset' 'ok'

printf '%s\n' '[7/19] --no-cache compiles again, byte-identically'
"$ASTER" build > c1.log 2>&1
cp build/app cached-app
"$ASTER" build --no-cache > c2.log 2>&1
grep -q '(2 compiled, 0 reused)' c2.log || {
    echo 'FAIL: --no-cache did not recompile everything:' >&2; cat c2.log >&2; exit 1; }
cmp -s build/app cached-app || { echo 'FAIL: --no-cache changed the executable' >&2; exit 1; }
printf '  %-40s %s\n' '--no-cache recompiles and reproduces the bytes' 'ok'

printf '%s\n' '[8/19] error paths'
cd "$WORK"
if "$ASTER" build > noexcept.log 2>&1; then
    echo 'FAIL: aster build worked outside a project' >&2; exit 1
fi
grep -q 'no aster.proj' noexcept.log || { echo 'FAIL: the missing-project error is wrong:' >&2; cat noexcept.log >&2; exit 1; }
cd app
printf 'src/main.ast\nsrc/missing.ast\n' > aster.proj
if "$ASTER" build > missing.log 2>&1; then
    echo 'FAIL: aster build accepted a missing source' >&2; exit 1
fi
grep -q 'missing source src/missing.ast' missing.log || {
    echo 'FAIL: the missing-source error is wrong:' >&2; cat missing.log >&2; exit 1; }
printf 'src/main.ast\nsrc/util.ast\n' > aster.proj
if "$ASTER" build --nope > badopt.log 2>&1; then
    echo 'FAIL: aster build accepted an unknown option' >&2; exit 1
fi
grep -q 'unknown option --nope' badopt.log || {
    echo 'FAIL: the unknown-option error is wrong:' >&2; cat badopt.log >&2; exit 1; }
# v0.23.81-dev (CLI-P2-13): `aster new` used to take the directory basename
# as the project/package name unchecked, so `foo bar`, `foo-bar` and `123abc`
# scaffolded projects whose package `com.example.<name>` only failed later
# at `aster build`. The project name and the package name are different
# things: the project name is the directory name and may be Chinese, so `new`
# only requires a usable directory name; the Android package is derived from
# it (ASCII, each segment starting with a letter) and the human-readable
# label keeps the original name. A `name` line is written only when the
# directory name is not already a plain file name. Only "." and ".." are
# refused, and nothing is created on a refusal.
cd "$WORK"
for bad in '.' '..'; do
    if "$ASTER" new "$bad" > badname.log 2>&1; then
        echo "FAIL: aster new accepted the unusable project name $bad" >&2; exit 1
    fi
    grep -q 'is not a usable project name' badname.log || {
        echo "FAIL: the unusable-name error for $bad is wrong:" >&2; cat badname.log >&2; exit 1; }
done
# Plain projects: every usable directory name is accepted, Chinese included.
for ok in 'foo bar' 'foo-bar' '123abc' '我的项目'; do
    "$ASTER" new "$ok" > okname.log 2>&1 || {
        echo "FAIL: aster new refused the legal project name $ok:" >&2; cat okname.log >&2; exit 1; }
    [ -f "$ok/aster.proj" ] || { echo "FAIL: aster new $ok scaffolded nothing" >&2; exit 1; }
done
(cd foo-bar && "$ASTER" build > build.log 2>&1) || {
    echo 'FAIL: a plain project named foo-bar did not build:' >&2; cat foo-bar/build.log >&2; exit 1; }
(cd '我的项目' && "$ASTER" build > build.log 2>&1) || {
    echo 'FAIL: a plain project named 我的项目 did not build:' >&2; cat '我的项目/build.log' >&2; exit 1; }
[ -f '我的项目/build/app' ] || { echo 'FAIL: the Chinese project did not build to build/app' >&2; exit 1; }
# APK projects: the package is derived from the project name, never the raw
# directory name; the label keeps the original name. The apk/ prefix keeps
# these apart from the plain projects of the same basename above.
apk_case() {
    dir=$1; pkg=$2; namekey=$3
    base=${dir##*/}
    "$ASTER" new --apk "$dir" > apkname.log 2>&1 || {
        echo "FAIL: aster new --apk refused the project name $dir:" >&2; cat apkname.log >&2; exit 1; }
    grep -qF "package $pkg" "$dir/aster.proj" || {
        echo "FAIL: --apk $dir did not derive package $pkg:" >&2; cat "$dir/aster.proj" >&2; exit 1; }
    grep -qF "label $base" "$dir/aster.proj" || {
        echo "FAIL: --apk $dir did not keep its label:" >&2; cat "$dir/aster.proj" >&2; exit 1; }
    if [ -n "$namekey" ]; then
        grep -qF "name $namekey" "$dir/aster.proj" || {
            echo "FAIL: --apk $dir did not write name $namekey:" >&2; cat "$dir/aster.proj" >&2; exit 1; }
    fi
}
apk_case 'apk/foo-bar' 'com.example.foo_bar' ''
apk_case 'apk/123abc' 'com.example.a123abc' ''
apk_case 'apk/foo bar' 'com.example.foo_bar' 'foo_bar'
apk_case 'apk/我的应用' 'com.example.app' 'app'
(cd 'apk/我的应用' && "$ASTER" build > build.log 2>&1) || {
    echo 'FAIL: an APK project named 我的应用 did not build:' >&2; cat 'apk/我的应用/build.log' >&2; exit 1; }
[ -f 'apk/我的应用/build/app.apk' ] || { echo 'FAIL: the Chinese APK project did not build to build/app.apk' >&2; exit 1; }
"$ASTER" verify-apk 'apk/我的应用/build/app.apk' > verify.log 2>&1 || {
    echo 'FAIL: the Chinese APK project did not verify:' >&2; cat verify.log >&2; exit 1; }
"$ASTER" new good_name > goodname.log 2>&1 || {
    echo 'FAIL: aster new refused the legal project name good_name:' >&2; cat goodname.log >&2; exit 1; }
[ -f good_name/aster.proj ] || { echo 'FAIL: aster new good_name scaffolded nothing' >&2; exit 1; }
cd app
# v0.23.81-dev (fuzz batch): the `name` line in a hand-edited aster.proj is
# still validated by the parser (validProjectName), even though `aster new`
# now accepts any usable directory name -- the name is the output file
# name, so `../x`, an empty name, a name with a space or a slash, or `.`
# must be refused at build time, with the plain-file-name diagnostic.
for nm in '../x' '' 'foo bar' 'a/b' '.'; do
    printf 'name %s\nkind exe\nsrc/main.ast\nsrc/util.ast\n' "$nm" > aster.proj
    if "$ASTER" build > badprojname.log 2>&1; then
        echo "FAIL: aster build accepted the hand-edited project name [$nm]" >&2; exit 1
    fi
    grep -q 'name must be a plain file name' badprojname.log || {
        echo "FAIL: the hand-edited name [$nm] was refused for the wrong reason:" >&2; cat badprojname.log >&2; exit 1; }
done
printf 'kind exe\nsrc/main.ast\nsrc/util.ast\n' > aster.proj
printf '  %-40s %s\n' 'no project / missing source / unknown option / new name rules / bad name line refused' 'ok'

printf '%s\n' '[9/19] mutation: tampered meta / poisoned object / old-format meta are not reused'
meta=$(ls build/.cache/*.meta | head -1)
grep -v '^src ' "$meta" > "$meta.tmp"
mv "$meta.tmp" "$meta"
"$ASTER" build > mut.log 2>&1
grep -q '(1 compiled, 1 reused)' mut.log || {
    echo 'FAIL: a cache entry with no src line was trusted:' >&2; cat mut.log >&2; exit 1; }
# v0.23.81-dev (CLI-P2-1): the meta records sha256(object); a cached .o whose
# bytes were replaced after the build must be caught on reuse and recompiled,
# never silently linked. The poisoned object returns 99, the real program 0.
"$ASTER" build > mutclean.log 2>&1
grep -q '(0 compiled, 2 reused)' mutclean.log || {
    echo 'FAIL: the cache did not settle after the src-line mutation:' >&2; cat mutclean.log >&2; exit 1; }
grep -q '^obj [0-9a-f]\{64\}$' build/.cache/*.meta || {
    echo 'FAIL: no cache meta records an obj sha256:' >&2; exit 1; }
for m in build/.cache/*.meta; do
    if grep -q '^src src/main.ast ' "$m"; then main_meta=$m; main_obj=${m%.meta}.o; fi
done
printf 'include "util.ast";\nfn main() -> i32 { return 99; }\n' > src/poison_main.ast
"$ASTER" build-obj src/poison_main.ast -o poison.o >/dev/null
cp poison.o "$main_obj"
rm src/poison_main.ast poison.o
"$ASTER" build > mutpoison.log 2>&1
grep -q '(1 compiled, 1 reused)' mutpoison.log || {
    echo 'FAIL: a poisoned cached object was reused:' >&2; cat mutpoison.log >&2; exit 1; }
set +e
"$RUNNER" ./build/app
poison_rc=$?
set -e
[ "$poison_rc" = 0 ] || {
    echo "FAIL: the rebuilt program exited $poison_rc, expected 0 (poison leaked in)" >&2; exit 1; }
# v0.23.81-dev (CLI-P2-1): a meta written before the `obj` line existed has
# no object hash to check; it must fail closed to a recompile, not be trusted.
grep -v '^obj ' "$main_meta" > "$main_meta.tmp"
mv "$main_meta.tmp" "$main_meta"
"$ASTER" build > mutold.log 2>&1
grep -q '(1 compiled, 1 reused)' mutold.log || {
    echo 'FAIL: a cache entry with no obj hash was trusted:' >&2; cat mutold.log >&2; exit 1; }
# v0.23.81-dev (fuzz batch): a planted symlink in the cache must never be
# written through (P1-12: the object writer used to use a predictable
# tmp-<key>.o name through ofstream; it now mkstemps an unpredictable name
# and publishes by rename, and the meta writer goes through
# writeFileAtomic the same way). A symlinked .o is caught by the obj-hash
# check and recompiled, a symlinked .meta fails closed the same way, and in
# both cases the link is replaced by a regular file while the victim is
# untouched. A symlink at the old predictable tmp-<key>.o name is never
# touched at all.
"$ASTER" build > mutsettle.log 2>&1
grep -q '(0 compiled, 2 reused)' mutsettle.log || {
    echo 'FAIL: the cache did not settle after the old-format meta test:' >&2; cat mutsettle.log >&2; exit 1; }
main_meta=$(grep -l '^src src/main.ast ' build/.cache/*.meta)
main_obj=${main_meta%.meta}.o
printf 'VICTIM-OBJ' > victim-obj.txt
rm "$main_obj"; ln -s victim-obj.txt "$main_obj"
"$ASTER" build > mutlinko.log 2>&1
grep -q '(1 compiled, 1 reused)' mutlinko.log || {
    echo 'FAIL: a symlinked cached object was trusted:' >&2; cat mutlinko.log >&2; exit 1; }
[ "$(cat victim-obj.txt)" = 'VICTIM-OBJ' ] || {
    echo 'FAIL: the build wrote through the symlinked cached object' >&2; exit 1; }
[ -L "$main_obj" ] && { echo 'FAIL: the symlinked cached object was not replaced by a real file' >&2; exit 1; }
main_meta=$(grep -l '^src src/main.ast ' build/.cache/*.meta)
printf 'VICTIM-META' > victim-meta.txt
rm "$main_meta"; ln -s victim-meta.txt "$main_meta"
"$ASTER" build > mutlinkm.log 2>&1
grep -q '(1 compiled, 1 reused)' mutlinkm.log || {
    echo 'FAIL: a symlinked cache meta was trusted:' >&2; cat mutlinkm.log >&2; exit 1; }
[ "$(cat victim-meta.txt)" = 'VICTIM-META' ] || {
    echo 'FAIL: the build wrote through the symlinked cache meta' >&2; exit 1; }
[ -L "$main_meta" ] && { echo 'FAIL: the symlinked cache meta was not replaced by a real file' >&2; exit 1; }
main_meta=$(grep -l '^src src/main.ast ' build/.cache/*.meta)
key=$(basename "$main_meta" .meta)
printf 'VICTIM-TMP' > victim-tmp.txt
ln -s victim-tmp.txt "build/.cache/tmp-$key.o"
"$ASTER" build > mutlinkt.log 2>&1
grep -q '(0 compiled, 2 reused)' mutlinkt.log || {
    echo 'FAIL: the build did not reuse the cache with a legacy tmp symlink present:' >&2; cat mutlinkt.log >&2; exit 1; }
[ "$(cat victim-tmp.txt)" = 'VICTIM-TMP' ] || {
    echo 'FAIL: the build wrote through the legacy tmp-<key>.o symlink' >&2; exit 1; }
[ -L "build/.cache/tmp-$key.o" ] || {
    echo 'FAIL: the legacy tmp-<key>.o symlink was unexpectedly replaced' >&2; exit 1; }
rm "build/.cache/tmp-$key.o" victim-obj.txt victim-meta.txt victim-tmp.txt
# Two builds of the same project at once, each in its own copy with its own
# cache directory: both must exit 0, both must compile from a cold cache,
# and the outputs must be byte-identical. Sharing one cache directory made
# the cold-cache assertion unachievable: whoever publishes an object first
# lets the other reuse it, so one build always reported a reuse instead of
# (2 compiled, 0 reused). The copies keep the basename "app" so the output
# path stays build/app in both.
rm -rf "$WORK/par1" "$WORK/par2"
mkdir -p "$WORK/par1/app" "$WORK/par2/app"
# cp -r, not -a: preserving ownership fails on the overlay fs (this host's
# root has no CAP_CHOWN), cp exits 1 and the suite dies under set -e.
# The copies only need the files, not their ownership.
cp -r "$WORK/app/aster.proj" "$WORK/app/src" "$WORK/par1/app/"
cp -r "$WORK/app/aster.proj" "$WORK/app/src" "$WORK/par2/app/"
(cd "$WORK/par1/app" && "$ASTER" build > "$WORK/par1.log" 2>&1) & par1_pid=$!
(cd "$WORK/par2/app" && "$ASTER" build > "$WORK/par2.log" 2>&1) & par2_pid=$!
par1_rc=0; wait "$par1_pid" || par1_rc=$?
par2_rc=0; wait "$par2_pid" || par2_rc=$?
[ "$par1_rc" = 0 ] || { echo "FAIL: the first parallel build exited $par1_rc:" >&2; cat "$WORK/par1.log" >&2; exit 1; }
[ "$par2_rc" = 0 ] || { echo "FAIL: the second parallel build exited $par2_rc:" >&2; cat "$WORK/par2.log" >&2; exit 1; }
grep -q '(2 compiled, 0 reused)' "$WORK/par1.log" || {
    echo 'FAIL: the first parallel build did not compile from a cold cache:' >&2; cat "$WORK/par1.log" >&2; exit 1; }
grep -q '(2 compiled, 0 reused)' "$WORK/par2.log" || {
    echo 'FAIL: the second parallel build did not compile from a cold cache:' >&2; cat "$WORK/par2.log" >&2; exit 1; }
cmp -s "$WORK/par1/app/build/app" "$WORK/par2/app/build/app" || { echo 'FAIL: the parallel builds produced different executables' >&2; exit 1; }
(cd "$WORK/par1/app" && "$ASTER" build > "$WORK/par1b.log" 2>&1)
grep -q '(0 compiled, 2 reused)' "$WORK/par1b.log" || {
    echo 'FAIL: the cache did not settle after the parallel builds:' >&2; cat "$WORK/par1b.log" >&2; exit 1; }
rm -rf "$WORK/par1" "$WORK/par2" "$WORK/par1.log" "$WORK/par2.log" "$WORK/par1b.log"
printf '  %-40s %s\n' 'meta validation is load-bearing; cache symlinks safe; parallel builds agree' 'ok'

printf '%s\n' '[10/19] aster run forwards the exit code and the arguments'
cd "$WORK/app"
printf 'include "util.ast";\nfn main() -> i32 { return add(40, 2); }\n' > src/main.ast
set +e
"$ASTER" run > run.log 2>&1
run_rc=$?
"$ASTER" run -- -x -y > run2.log 2>&1
run2_rc=$?
set -e
[ "$run_rc" = 42 ] || { echo "FAIL: aster run returned $run_rc, expected the program's 42" >&2; cat run.log >&2; exit 1; }
[ "$run2_rc" = 42 ] || { echo "FAIL: aster run -- args returned $run2_rc, expected 42" >&2; cat run2.log >&2; exit 1; }
printf '  %-40s %s\n' 'run returns 42, with and without -- args' 'ok'

printf '%s\n' '[11/19] aster add appends once and dedupes'
printf 'fn twice(x: i32) -> i32 { return x + x; }\n' > src/extra.ast
"$ASTER" add src/extra.ast > add.log 2>&1
grep -q 'added src/extra.ast' add.log || { echo 'FAIL: aster add did not append:' >&2; cat add.log >&2; exit 1; }
"$ASTER" add src/extra.ast > add2.log 2>&1
grep -q 'already in' add2.log || { echo 'FAIL: aster add appended a duplicate:' >&2; cat add2.log >&2; exit 1; }
[ "$(grep -c 'extra.ast' aster.proj)" = 1 ] || { echo 'FAIL: extra.ast appears more than once in aster.proj' >&2; exit 1; }
# v0.23.81-dev (CLI-P2-3 / D-06): the same source under a different spelling
# (`./src/extra.ast`, `src/../src/extra.ast`) is the same source, not a new
# one — `aster add` must refuse it, and a hand-edited aster.proj listing it
# twice must still compile and link it only once.
"$ASTER" add ./src/extra.ast > add3.log 2>&1
grep -q 'already in' add3.log || { echo 'FAIL: aster add accepted ./src/extra.ast as a new source:' >&2; cat add3.log >&2; exit 1; }
"$ASTER" add src/../src/extra.ast > add4.log 2>&1
grep -q 'already in' add4.log || { echo 'FAIL: aster add accepted src/../src/extra.ast as a new source:' >&2; cat add4.log >&2; exit 1; }
[ "$(grep -c 'extra.ast' aster.proj)" = 1 ] || { echo 'FAIL: extra.ast appears more than once in aster.proj' >&2; exit 1; }
printf 'src/main.ast\n./src/util.ast\nsrc/../src/util.ast\nsrc/extra.ast\n' > aster.proj
"$ASTER" deps > deps-dup.txt
[ "$(grep -c 'build/util.o:' deps-dup.txt)" = 1 ] || { echo 'FAIL: a hand-edited duplicate source produced two util.o rules:' >&2; cat deps-dup.txt >&2; exit 1; }
[ "$(grep -c 'build/main.o:' deps-dup.txt)" = 1 ] || { echo 'FAIL: a hand-edited duplicate source produced two main.o rules:' >&2; cat deps-dup.txt >&2; exit 1; }
"$ASTER" build --no-cache > dupbuild.log 2>&1
grep -q '(3 compiled, 0 reused)' dupbuild.log || {
    echo 'FAIL: a hand-edited duplicate source was compiled more than once:' >&2; cat dupbuild.log >&2; exit 1; }
printf 'src/main.ast\nsrc/util.ast\nsrc/extra.ast\n' > aster.proj
printf '  %-40s %s\n' 'appended once, second add is a no-op' 'ok'

printf '%s\n' '[12/19] aster deps in a project names every object'
"$ASTER" deps > deps-all.txt
grep -q 'build/main.o: src/main.ast' deps-all.txt || { echo 'FAIL: the project deps rule for main.o is wrong:' >&2; cat deps-all.txt >&2; exit 1; }
grep -q 'build/util.o: src/util.ast' deps-all.txt || { echo 'FAIL: the project deps rule for util.o is missing:' >&2; cat deps-all.txt >&2; exit 1; }
printf '  %-40s %s\n' 'one rule per project source' 'ok'

printf '%s\n' '[13/19] an apk project builds a signed, verifiable APK'
cd "$WORK"
"$ASTER" new --apk apkapp >/dev/null
cd apkapp
"$ASTER" build > apk.log 2>&1
[ -f build/apkapp.apk ] || { echo 'FAIL: the apk project produced no APK' >&2; cat apk.log >&2; exit 1; }
"$ASTER" verify-apk build/apkapp.apk > apkverify.log 2>&1 || {
    echo 'FAIL: the project APK did not verify:' >&2; cat apkverify.log >&2; exit 1; }
"$ASTER" build > apk2.log 2>&1
grep -q '(0 compiled, 1 reused)' apk2.log || {
    echo 'FAIL: rebuilding the apk project did not reuse its object:' >&2; cat apk2.log >&2; exit 1; }
set +e
"$ASTER" run > apkrun.log 2>&1
apk_run_rc=$?
set -e
[ "$apk_run_rc" != 0 ] || { echo 'FAIL: aster run accepted an apk project' >&2; exit 1; }
grep -q 'this is an apk project' apkrun.log || {
    echo 'FAIL: aster run refused the apk project for the wrong reason:' >&2; cat apkrun.log >&2; exit 1; }
printf 'kind apk\nsrc/main.ast\n' > aster.proj
set +e
"$ASTER" build > apkpkg.log 2>&1
apk_pkg_rc=$?
set -e
[ "$apk_pkg_rc" != 0 ] || { echo 'FAIL: an apk project without a package built' >&2; exit 1; }
grep -q 'needs `package' apkpkg.log || {
    echo 'FAIL: the missing-package error is wrong:' >&2; cat apkpkg.log >&2; exit 1; }
# v0.23.81-dev (fuzz batch): /dev/full under the project path (P1-13 fixed
# the standalone `build-apk -o /dev/full` case; the project build reaches
# the same buildApk, and the exe project reaches the ELF writer -- both
# must fail instead of exiting 0 with a truncated output).
printf 'kind apk\npackage com.example.apkapp\nsrc/main.ast\n' > aster.proj
set +e
"$ASTER" build -o /dev/full > fullapk.log 2>&1
full_apk_rc=$?
set -e
[ "$full_apk_rc" != 0 ] || { echo 'FAIL: an apk project build to /dev/full exited 0' >&2; exit 1; }
grep -q 'failed writing /dev/full' fullapk.log || {
    echo 'FAIL: the apk project /dev/full failure was reported for the wrong reason:' >&2; cat fullapk.log >&2; exit 1; }
# v0.23.82-dev: an apk project carries its own version. Without the fields
# the build stamps versionCode 1 / versionName "1.0"; with them the manifest
# carries the project's version, so rebuilding an existing app never looks
# like a downgrade to the installer.
cd "$WORK/apkapp"
printf 'kind apk\npackage com.example.apkapp\nversion-code 19\nversion-name 2.7.1\nsrc/main.ast\n' > aster.proj
"$ASTER" build > apkver.log 2>&1
python3 "$ROOT/tests/validate_apk.py" build/apkapp.apk --package com.example.apkapp --libname apkapp --abi arm64-v8a > apkvercheck.log 2>&1 || {
    echo 'FAIL: the versioned project APK did not validate:' >&2; cat apkvercheck.log >&2; exit 1; }
grep -q 'verCode=19' apkvercheck.log || {
    echo 'FAIL: version-code 19 did not reach the manifest:' >&2; cat apkvercheck.log >&2; exit 1; }
grep -q "verName='2.7.1'" apkvercheck.log || {
    echo 'FAIL: version-name 2.7.1 did not reach the manifest:' >&2; cat apkvercheck.log >&2; exit 1; }
"$ASTER" doctor > apkverdoc.log 2>&1
grep -q 'version 19 (2.7.1)' apkverdoc.log || {
    echo 'FAIL: doctor did not report the project version:' >&2; cat apkverdoc.log >&2; exit 1; }
# invalid versions fail closed, with the range in the message
for bad in 'version-code 0' 'version-code 2100000001' 'version-code abc' 'version-code 12x'; do
    printf 'kind apk\npackage com.example.apkapp\n%s\nsrc/main.ast\n' "$bad" > aster.proj
    set +e; "$ASTER" build > apkbadv.log 2>&1; bad_rc=$?; set -e
    [ "$bad_rc" != 0 ] || { echo "FAIL: aster build accepted '$bad':" >&2; cat apkbadv.log >&2; exit 1; }
    grep -q 'version-code must be a decimal integer between 1 and 2100000000' apkbadv.log || {
        echo "FAIL: '$bad' was refused for the wrong reason:" >&2; cat apkbadv.log >&2; exit 1; }
done
printf 'kind apk\npackage com.example.apkapp\nversion-name\nsrc/main.ast\n' > aster.proj
set +e; "$ASTER" build > apkbadv2.log 2>&1; bad2_rc=$?; set -e
[ "$bad2_rc" != 0 ] || { echo 'FAIL: aster build accepted an empty version-name' >&2; exit 1; }
grep -q 'version-name must not be empty' apkbadv2.log || {
    echo 'FAIL: the empty version-name refusal is wrong:' >&2; cat apkbadv2.log >&2; exit 1; }
cd "$WORK/app"
set +e
"$ASTER" build -o /dev/full > full-exe.log 2>&1
full_exe_rc=$?
set -e
[ "$full_exe_rc" != 0 ] || { echo 'FAIL: an exe project build to /dev/full exited 0' >&2; exit 1; }
grep -q 'failed closing ELF executable: /dev/full' full-exe.log || {
    echo 'FAIL: the exe project /dev/full failure was reported for the wrong reason:' >&2; cat full-exe.log >&2; exit 1; }
cd "$WORK/apkapp"
printf '  %-40s %s\n' 'signed APK verifies; run and package errors; /dev/full fails' 'ok'

printf '%s\n' '[14/19] signing is configured in aster.proj'
cd "$WORK/apkapp"
mkdir -p keys
"$ASTER" keygen --dir keys >/dev/null
cat > aster.proj <<'PROJ'
kind apk
package com.example.apkapp
sign-mode release
keystore keys/.aster/debug.key.pem
cert keys/.aster/debug.crt.pem
src/main.ast
PROJ
"$ASTER" build > rel.log 2>&1
"$ASTER" verify-apk build/apkapp.apk > relverify.log 2>&1 || {
    echo 'FAIL: the release-signed project APK did not verify:' >&2; cat relverify.log >&2; exit 1; }
grep -v '^cert ' aster.proj > aster.proj.tmp; mv aster.proj.tmp aster.proj
set +e
"$ASTER" build > relnocert.log 2>&1
rel_rc=$?
set -e
[ "$rel_rc" != 0 ] || { echo 'FAIL: release signing without a cert built' >&2; exit 1; }
grep -q 'needs `keystore <path>` and `cert <path>`' relnocert.log || {
    echo 'FAIL: the missing-cert error is wrong:' >&2; cat relnocert.log >&2; exit 1; }
printf 'kind apk\npackage com.example.apkapp\nkeystore keys/.aster/debug.key.pem\nsrc/main.ast\n' > aster.proj
set +e
"$ASTER" build > dbgkey.log 2>&1
dbg_rc=$?
set -e
[ "$dbg_rc" != 0 ] || { echo 'FAIL: a debug build accepted a keystore' >&2; exit 1; }
grep -q 'keystore/cert are release settings' dbgkey.log || {
    echo 'FAIL: the debug-with-keystore error is wrong:' >&2; cat dbgkey.log >&2; exit 1; }
printf '  %-40s %s\n' 'release builds; both signing misconfigurations refused' 'ok'

printf '%s\n' '[15/19] aster test runs the project tests'
# the scaffold carries a test line and a test file
cd "$WORK"
"$ASTER" new testsample >/dev/null
grep -q '^test ' testsample/aster.proj || {
    echo 'FAIL: the scaffolded aster.proj lists no test source' >&2; exit 1; }
[ -f testsample/tests/util_test.ast ] || {
    echo 'FAIL: the scaffold wrote no tests/util_test.ast' >&2; exit 1; }
cd testsample
"$ASTER" test > scaffoldtest.log 2>&1 || {
    echo 'FAIL: the scaffolded test did not pass:' >&2; cat scaffoldtest.log >&2; exit 1; }
# the app project was rewritten by earlier layers, so give it a test again
cd "$WORK/app"
mkdir -p tests
printf 'include "../src/util.ast";\nfn main() -> i32 { if (add(2, 3) != 5) { return 1; } return 0; }\n' > tests/util_test.ast
grep -q '^test ' aster.proj || printf 'test tests/util_test.ast\n' >> aster.proj
"$ASTER" test > test1.log 2>&1
grep -q 'PASS tests/util_test.ast' test1.log || {
    echo 'FAIL: aster test did not pass the scaffolded test:' >&2; cat test1.log >&2; exit 1; }
grep -q '1 test, 0 failed' test1.log || {
    echo 'FAIL: aster test did not summarise one passing test:' >&2; cat test1.log >&2; exit 1; }
printf 'include "../src/util.ast";\nfn main() -> i32 { if (add(2, 3) != 6) { return 3; } return 0; }\n' > tests/util_test.ast
set +e
"$ASTER" test > test2.log 2>&1
fail_rc=$?
set -e
[ "$fail_rc" = 1 ] || { echo "FAIL: a failing test made aster test exit $fail_rc, expected 1" >&2; cat test2.log >&2; exit 1; }
grep -q 'FAIL tests/util_test.ast (exit 3)' test2.log || {
    echo 'FAIL: the failing test was not reported with its exit code:' >&2; cat test2.log >&2; exit 1; }
set +e
"$ASTER" test nosuch > test3.log 2>&1
miss_rc=$?
set -e
[ "$miss_rc" != 0 ] || { echo 'FAIL: a filter that matches nothing exited 0' >&2; exit 1; }
grep -q 'no test matched' test3.log || { echo 'FAIL: the empty-filter error is wrong:' >&2; cat test3.log >&2; exit 1; }
# v0.23.81-dev (P2-3 / D-06): duplicate `test` lines are deduped, like
# sources lines (same normalizeProjPath normalisation): the same test under
# an identical spelling and under a different spelling
# (`./tests/util_test.ast`) runs once, not once per line.
printf 'include "../src/util.ast";\nfn main() -> i32 { if (add(2, 3) != 5) { return 1; } return 0; }\n' > tests/util_test.ast
printf 'test tests/util_test.ast\ntest ./tests/util_test.ast\n' >> aster.proj
"$ASTER" test > testdup.log 2>&1 || {
    echo 'FAIL: the duplicated test did not pass:' >&2; cat testdup.log >&2; exit 1; }
grep -q '1 test, 0 failed' testdup.log || {
    echo 'FAIL: a duplicated test line ran the test more than once:' >&2; cat testdup.log >&2; exit 1; }
[ "$(grep -c 'PASS tests/util_test.ast' testdup.log)" = 1 ] || {
    echo 'FAIL: the duplicated test was not reported as PASS exactly once:' >&2; cat testdup.log >&2; exit 1; }
grep -v '^test ' aster.proj > aster.proj.tmp; mv aster.proj.tmp aster.proj
set +e
"$ASTER" test > test4.log 2>&1
none_rc=$?
set -e
[ "$none_rc" != 0 ] || { echo 'FAIL: a project without tests ran aster test successfully' >&2; exit 1; }
grep -q 'lists no `test` sources' test4.log || {
    echo 'FAIL: the no-tests error is wrong:' >&2; cat test4.log >&2; exit 1; }
printf '  %-40s %s\n' 'pass, fail with exit code, filter miss, no tests' 'ok'

printf '%s\n' '[16/19] aster doctor checks the host and the project'
# v0.23.77-dev (host adaptation): `aster doctor` walks up from cwd looking for
# a .git/.aster to decide where a project's debug key lives. In an isolated CI
# worktree that search can land on the *parent* checkout, whose
# .aster/debug.key.pem may or may not exist depending on what was built there
# earlier — so the "no project debug key yet" warning would depend on host
# residue rather than on this project. Pin the key directory to a private,
# empty one: the assertion stays exactly as strict on both kinds of machine.
export ASTER_KEY_DIR="$WORK/doctor-key-dir"
mkdir -p "$ASTER_KEY_DIR"
cd "$WORK"
"$ASTER" doctor > doctor1.log 2>&1 || {
    echo 'FAIL: aster doctor failed outside a project:' >&2; cat doctor1.log >&2; exit 1; }
grep -q 'Aster doctor:' doctor1.log || { echo 'FAIL: aster doctor printed no summary' >&2; exit 1; }
grep -q ' compiler:' doctor1.log || { echo 'FAIL: aster doctor skipped the compiler check' >&2; exit 1; }
cd testsample
"$ASTER" doctor > doctor2.log 2>&1 || {
    echo 'FAIL: aster doctor failed on the scaffolded project:' >&2; cat doctor2.log >&2; exit 1; }
grep -q 'exactly one source defines `main`' doctor2.log || {
    echo 'FAIL: aster doctor did not recognise the project entry source:' >&2; cat doctor2.log >&2; exit 1; }
printf 'kind exe\nsrc/main.ast\nsrc/nope.ast\n' > aster.proj
set +e
"$ASTER" doctor > doctor3.log 2>&1
doc_rc=$?
set -e
[ "$doc_rc" != 0 ] || { echo 'FAIL: aster doctor passed a project with a missing source' >&2; exit 1; }
grep -q 'missing source: src/nope.ast' doctor3.log || {
    echo 'FAIL: the missing-source finding is wrong:' >&2; cat doctor3.log >&2; exit 1; }
printf 'kind apk\npackage com.example.testsample\n' > aster.proj
set +e
"$ASTER" doctor > doctor4.log 2>&1
doc2_rc=$?
"$ASTER" doctor --strict > doctor5.log 2>&1
strict_rc=$?
set -e
[ "$doc2_rc" = 0 ] || { echo 'FAIL: a warning-only project failed plain aster doctor' >&2; cat doctor4.log >&2; exit 1; }
grep -q 'no project debug key yet' doctor4.log || {
    echo 'FAIL: the missing-debug-key warning is wrong:' >&2; cat doctor4.log >&2; exit 1; }
[ "$strict_rc" != 0 ] || { echo 'FAIL: --strict ignored a warning' >&2; exit 1; }
# v0.23.81-dev (fuzz batch): TMPDIR as a symlink, and a planted probe
# symlink (P1-11: doctor used to open the fixed name .aster-doctor-probe
# through ofstream, truncating whatever it pointed at; it now mkstemps an
# unpredictable name that never follows a link).
mkdir -p "$WORK/real-tmp"
ln -s "$WORK/real-tmp" "$WORK/link-tmp"
TMPDIR="$WORK/link-tmp" "$ASTER" doctor > doctor-tmpdir.log 2>&1 || {
    echo 'FAIL: aster doctor failed with TMPDIR a symlink to a directory:' >&2; cat doctor-tmpdir.log >&2; exit 1; }
grep -qF "writable scratch: $WORK/link-tmp" doctor-tmpdir.log || {
    echo 'FAIL: doctor did not report the symlinked TMPDIR as writable scratch:' >&2; cat doctor-tmpdir.log >&2; exit 1; }
printf 'VICTIM-CONTENT' > "$WORK/doctor-victim.txt"
ln -s "$WORK/doctor-victim.txt" "$WORK/real-tmp/.aster-doctor-probe"
TMPDIR="$WORK/link-tmp" "$ASTER" doctor > doctor-probe.log 2>&1 || {
    echo 'FAIL: aster doctor failed with a planted probe symlink:' >&2; cat doctor-probe.log >&2; exit 1; }
[ "$(cat "$WORK/doctor-victim.txt")" = 'VICTIM-CONTENT' ] || {
    echo 'FAIL: doctor wrote through the planted .aster-doctor-probe symlink' >&2; exit 1; }
[ -L "$WORK/real-tmp/.aster-doctor-probe" ] || {
    echo 'FAIL: doctor replaced the planted probe symlink' >&2; exit 1; }
printf '  %-40s %s\n' 'doctor: pass, missing source fails, --strict fails on warns, TMPDIR symlink safe' 'ok'

printf '%s\n' '[17/19] two TUs: each keeps its own type namespace (P1-4)'
# v0.23.80-dev (P1-4): the type tables are process globals, so a struct
# declared by one TU used to leak into the next one compiled in the same
# process — the next TU could use a type it never declared, and
# re-declaring the same tag was a spurious duplicate. Both directions are
# pinned here: the same tag in two TUs builds, and an undeclared use fails.
mkdir -p "$WORK/twotu/src"
cat > "$WORK/twotu/aster.proj" <<'PROJ'
name twotu
kind exe
src/a.ast
src/b.ast
PROJ
cat > "$WORK/twotu/src/a.ast" <<'AST'
struct Shared { v: i32 }
extern fn extra() -> i32;
fn get() -> i32 { let s: Shared = Shared { 41 }; return s.v; }
fn main() -> i32 { return get() + extra(); }
AST
cat > "$WORK/twotu/src/b.ast" <<'AST'
struct Shared { v: i32 }
fn extra() -> i32 { let s: Shared = Shared { 1 }; return s.v; }
AST
(cd "$WORK/twotu" && "$ASTER" build >"$WORK/twotu.log" 2>&1) \
    || { echo 'FAIL: two TUs re-declaring the same struct tag must build:' >&2; cat "$WORK/twotu.log" >&2; exit 1; }
set +e; "$RUNNER" "$WORK/twotu/build/twotu" >/dev/null 2>&1; two_rc=$?; set -e
[ "$two_rc" = 42 ] || { echo "FAIL: two-TU program returned $two_rc, expected 42" >&2; exit 1; }
printf 'fn extra() -> i32 { let s: Shared = Shared { 1 }; return s.v; }\n' > "$WORK/twotu/src/b.ast"
rm -rf "$WORK/twotu/build"
(cd "$WORK/twotu" && "$ASTER" build >"$WORK/twotu-leak.log" 2>&1) \
    && { echo 'FAIL: a TU using a struct it never declared must not build' >&2; exit 1; }
grep -q 'struct name' "$WORK/twotu-leak.log" \
    || { echo 'FAIL: the undeclared-struct refusal names no struct:' >&2; cat "$WORK/twotu-leak.log" >&2; exit 1; }
printf '  %-40s %s\n' 'same tag in two TUs builds (42); undeclared use refused' 'ok'

printf '%s\n' '[18/19] a source path with a space still hits the cache (CLI-P2-4/D-07)'
# v0.23.81-dev (CLI-P2-4/D-07): the .meta `src` line used to split at the
# first space, so a path with a space never matched its cache entry and
# always recompiled. Both readers (project build and `aster test`) split
# at the last space now, and a short or wrong hash still fails closed.
mkdir -p "$WORK/spacey/my src"
cat > "$WORK/spacey/aster.proj" <<'PROJ'
name spacey
kind exe
my src/main.ast
my src/helper.ast
PROJ
printf 'fn main() -> i32 { return 42; }\n' > "$WORK/spacey/my src/main.ast"
printf 'fn bump(x: i32) -> i32 { return x + 1; }\n' > "$WORK/spacey/my src/helper.ast"
(cd "$WORK/spacey" && "$ASTER" build >"$WORK/spacey1.log" 2>&1) \
    || { echo 'FAIL: the spaced-path project did not build:' >&2; cat "$WORK/spacey1.log" >&2; exit 1; }
grep -q '(2 compiled, 0 reused)' "$WORK/spacey1.log" || {
    echo 'FAIL: the first spaced-path build did not compile both objects:' >&2
    cat "$WORK/spacey1.log" >&2; exit 1; }
(cd "$WORK/spacey" && "$ASTER" build >"$WORK/spacey2.log" 2>&1) \
    || { echo 'FAIL: the spaced-path rebuild failed:' >&2; cat "$WORK/spacey2.log" >&2; exit 1; }
grep -q '(0 compiled, 2 reused)' "$WORK/spacey2.log" || {
    echo 'FAIL: the second build did not reuse the objects for source paths with a space:' >&2
    cat "$WORK/spacey2.log" >&2; exit 1; }
printf 'fn main() -> i32 { return 43; }\n' > "$WORK/spacey/my src/main.ast"
(cd "$WORK/spacey" && "$ASTER" build >"$WORK/spacey3.log" 2>&1) \
    || { echo 'FAIL: rebuilding after editing the spaced source failed:' >&2; cat "$WORK/spacey3.log" >&2; exit 1; }
grep -q '(1 compiled, 1 reused)' "$WORK/spacey3.log" || {
    echo 'FAIL: editing the spaced source did not recompile exactly it:' >&2; cat "$WORK/spacey3.log" >&2; exit 1; }
# the `aster test` reader is a second copy of the same .meta parsing: the
# entry source (it defines main) is left out of the test link, so the
# helper lib and the spaced test path are the two objects that must reuse.
printf 'fn main() -> i32 { return 0; }\n' > "$WORK/spacey/my src/util_test.ast"
printf 'test my src/util_test.ast\n' >> "$WORK/spacey/aster.proj"
(cd "$WORK/spacey" && "$ASTER" test >"$WORK/spacey-test1.log" 2>&1) \
    || { echo 'FAIL: aster test did not pass for the spaced test path:' >&2; cat "$WORK/spacey-test1.log" >&2; exit 1; }
(cd "$WORK/spacey" && "$ASTER" test >"$WORK/spacey-test2.log" 2>&1) \
    || { echo 'FAIL: the second aster test run did not pass:' >&2; cat "$WORK/spacey-test2.log" >&2; exit 1; }
grep -q '(0 compiled, 2 reused)' "$WORK/spacey-test2.log" || {
    echo 'FAIL: the second aster test run did not reuse both spaced-path objects:' >&2
    cat "$WORK/spacey-test2.log" >&2; exit 1; }
printf '  %-40s %s\n' 'spaced path reuses (build and test); edit recompiles' 'ok'

printf '%s\n' '[19/19] aster run/test time out a hanging child instead of hanging (CLI-P2-12)'
# v0.23.81-dev (CLI-P2-12): waitpid used to block forever with no EINTR
# retry and no timeout, so a hanging test hung `aster test`. The wait is now
# bounded (default 60s, --timeout N, $ASTER_RUN_TIMEOUT): SIGTERM, then
# SIGKILL after a 5s grace period, and the child is always reaped.
cd "$WORK/app"
grep -q '^test ' aster.proj || printf 'test tests/util_test.ast\n' >> aster.proj
printf 'include "../src/util.ast";\nfn main() -> i32 { while (1) { } return 0; }\n' > tests/util_test.ast
set +e
"$ASTER" test --timeout 1 > timeout1.log 2>&1
to_rc=$?
set -e
[ "$to_rc" = 1 ] || { echo "FAIL: a hanging test made aster test exit $to_rc, expected 1" >&2; cat timeout1.log >&2; exit 1; }
grep -q 'aster test: timed out after 1s' timeout1.log || {
    echo 'FAIL: the hanging test was not reported as a timeout:' >&2; cat timeout1.log >&2; exit 1; }
grep -q 'FAIL tests/util_test.ast (timed out after 1s)' timeout1.log || {
    echo 'FAIL: the timed-out test was not reported as FAIL:' >&2; cat timeout1.log >&2; exit 1; }
# a second hanging test still runs: the timed-out child was reaped, aster is alive
set +e
"$ASTER" test --timeout 1 > timeout1b.log 2>&1
to2_rc=$?
set -e
[ "$to2_rc" = 1 ] || { echo "FAIL: the second hanging test exited $to2_rc, expected 1" >&2; cat timeout1b.log >&2; exit 1; }
grep -q 'FAIL tests/util_test.ast (timed out after 1s)' timeout1b.log || {
    echo 'FAIL: the second hanging test was not reported as a timeout FAIL:' >&2; cat timeout1b.log >&2; exit 1; }
printf 'include "util.ast";\nfn main() -> i32 { while (1) { } return add(40, 2); }\n' > src/main.ast
set +e
"$ASTER" run --timeout 1 > timeout2.log 2>&1
run_to_rc=$?
set -e
[ "$run_to_rc" = 124 ] || { echo "FAIL: a hanging run exited $run_to_rc, expected 124" >&2; cat timeout2.log >&2; exit 1; }
grep -q 'aster run: timed out after 1s' timeout2.log || {
    echo 'FAIL: the hanging run was not reported as a timeout:' >&2; cat timeout2.log >&2; exit 1; }
set +e
ASTER_RUN_TIMEOUT=1 "$ASTER" run > timeout3.log 2>&1
env_to_rc=$?
set -e
[ "$env_to_rc" = 124 ] || { echo "FAIL: ASTER_RUN_TIMEOUT=1 made a hanging run exit $env_to_rc, expected 124" >&2; cat timeout3.log >&2; exit 1; }
grep -q 'aster run: timed out after 1s' timeout3.log || {
    echo 'FAIL: the env-var timeout was not reported:' >&2; cat timeout3.log >&2; exit 1; }
set +e
"$ASTER" test --timeout abc > timeout4.log 2>&1
bad_rc=$?
set -e
[ "$bad_rc" = 2 ] || { echo "FAIL: --timeout abc exited $bad_rc, expected 2" >&2; cat timeout4.log >&2; exit 1; }
grep -q 'must be a decimal integer between 0 and 86400' timeout4.log || {
    echo 'FAIL: the bad --timeout error is wrong:' >&2; cat timeout4.log >&2; exit 1; }
printf 'include "../src/util.ast";\nfn main() -> i32 { if (add(2, 3) != 5) { return 1; } return 0; }\n' > tests/util_test.ast
printf 'include "util.ast";\nfn main() -> i32 { return add(40, 2); }\n' > src/main.ast
"$ASTER" test > timeout5.log 2>&1 || {
    echo 'FAIL: the passing test stopped passing after the timeout change:' >&2; cat timeout5.log >&2; exit 1; }
grep -q 'PASS tests/util_test.ast' timeout5.log || {
    echo 'FAIL: the passing test was not reported as PASS:' >&2; cat timeout5.log >&2; exit 1; }
printf '  %-40s %s\n' 'hanging run/test killed at 1s; env + errors; normal still passes' 'ok'

echo 'PASS: project workflow (new, build cache, deps, error paths, mutation)'
