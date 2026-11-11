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
#   [9] mutation: a cache entry whose meta has lost its `src` line is not reused
set -eu
cd "$(dirname "$0")/.."
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

printf '%s\n' '[1/16] Strictly build Aster compiler'
$CXX -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror -o "$ASTER" src/aster.cpp
printf '  %-40s %s\n' 'compiler built' 'ok'

printf '%s\n' '[2/16] aster new scaffolds a project that builds and runs'
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

printf '%s\n' '[3/16] a second build reuses every object'
"$ASTER" build > build2.log 2>&1
grep -q '(0 compiled, 2 reused)' build2.log || {
    echo 'FAIL: the second build did not reuse both objects:' >&2; cat build2.log >&2; exit 1; }
cp build/app first-app
"$ASTER" build > build3.log 2>&1
cmp -s build/app first-app || { echo 'FAIL: rebuilding changed the executable' >&2; exit 1; }
printf '  %-40s %s\n' '0 compiled, 2 reused; output byte-identical' 'ok'

printf '%s\n' '[4/16] editing a source or an included file recompiles what depends on it'
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

printf '%s\n' '[5/16] editing an @embed asset recompiles the embedding object'
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

printf '%s\n' '[6/16] aster deps names the include and the asset'
"$ASTER" deps src/main.ast -o main.o > deps.txt
grep -q 'main.o: src/main.ast' deps.txt || { echo 'FAIL: the deps rule has no target' >&2; cat deps.txt >&2; exit 1; }
grep -q 'util.ast' deps.txt || { echo 'FAIL: the deps rule lost the include' >&2; cat deps.txt >&2; exit 1; }
grep -q 'asset.txt' deps.txt || { echo 'FAIL: the deps rule lost the @embed asset' >&2; cat deps.txt >&2; exit 1; }
printf '  %-40s %s\n' 'rule lists source, include and asset' 'ok'

printf '%s\n' '[7/16] --no-cache compiles again, byte-identically'
"$ASTER" build > c1.log 2>&1
cp build/app cached-app
"$ASTER" build --no-cache > c2.log 2>&1
grep -q '(2 compiled, 0 reused)' c2.log || {
    echo 'FAIL: --no-cache did not recompile everything:' >&2; cat c2.log >&2; exit 1; }
cmp -s build/app cached-app || { echo 'FAIL: --no-cache changed the executable' >&2; exit 1; }
printf '  %-40s %s\n' '--no-cache recompiles and reproduces the bytes' 'ok'

printf '%s\n' '[8/16] error paths'
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
printf '  %-40s %s\n' 'no project / missing source / unknown option refused' 'ok'

printf '%s\n' '[9/16] mutation: a cache entry without its src line is not reused'
meta=$(ls build/.cache/*.meta | head -1)
grep -v '^src ' "$meta" > "$meta.tmp"
mv "$meta.tmp" "$meta"
"$ASTER" build > mut.log 2>&1
grep -q '(1 compiled, 1 reused)' mut.log || {
    echo 'FAIL: a cache entry with no src line was trusted:' >&2; cat mut.log >&2; exit 1; }
printf '  %-40s %s\n' 'meta validation is load-bearing' 'ok'

printf '%s\n' '[10/16] aster run forwards the exit code and the arguments'
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

printf '%s\n' '[11/16] aster add appends once and dedupes'
printf 'fn twice(x: i32) -> i32 { return x + x; }\n' > src/extra.ast
"$ASTER" add src/extra.ast > add.log 2>&1
grep -q 'added src/extra.ast' add.log || { echo 'FAIL: aster add did not append:' >&2; cat add.log >&2; exit 1; }
"$ASTER" add src/extra.ast > add2.log 2>&1
grep -q 'already in' add2.log || { echo 'FAIL: aster add appended a duplicate:' >&2; cat add2.log >&2; exit 1; }
[ "$(grep -c 'extra.ast' aster.proj)" = 1 ] || { echo 'FAIL: extra.ast appears more than once in aster.proj' >&2; exit 1; }
printf '  %-40s %s\n' 'appended once, second add is a no-op' 'ok'

printf '%s\n' '[12/16] aster deps in a project names every object'
"$ASTER" deps > deps-all.txt
grep -q 'build/main.o: src/main.ast' deps-all.txt || { echo 'FAIL: the project deps rule for main.o is wrong:' >&2; cat deps-all.txt >&2; exit 1; }
grep -q 'build/util.o: src/util.ast' deps-all.txt || { echo 'FAIL: the project deps rule for util.o is missing:' >&2; cat deps-all.txt >&2; exit 1; }
printf '  %-40s %s\n' 'one rule per project source' 'ok'

printf '%s\n' '[13/16] an apk project builds a signed, verifiable APK'
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
printf '  %-40s %s\n' 'signed APK verifies; run and package errors' 'ok'

printf '%s\n' '[14/16] signing is configured in aster.proj'
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

printf '%s\n' '[15/16] aster test runs the project tests'
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
grep -v '^test ' aster.proj > aster.proj.tmp; mv aster.proj.tmp aster.proj
set +e
"$ASTER" test > test4.log 2>&1
none_rc=$?
set -e
[ "$none_rc" != 0 ] || { echo 'FAIL: a project without tests ran aster test successfully' >&2; exit 1; }
grep -q 'lists no `test` sources' test4.log || {
    echo 'FAIL: the no-tests error is wrong:' >&2; cat test4.log >&2; exit 1; }
printf '  %-40s %s\n' 'pass, fail with exit code, filter miss, no tests' 'ok'

printf '%s\n' '[16/16] aster doctor checks the host and the project'
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
printf '  %-40s %s\n' 'doctor: pass, missing source fails, --strict fails on warns' 'ok'

echo 'PASS: project workflow (new, build cache, deps, error paths, mutation)'
