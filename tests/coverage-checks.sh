#!/bin/sh
# tests/coverage-checks.sh — line-coverage ratchet for src/aster.cpp.
#
# The byte baselines and the codegen twin pin output; they do not say how much
# of the compiler any test actually executes. This suite builds the compiler
# with --coverage at -O0, drives one deterministic corpus through the public
# CLI, and requires gcov's line coverage of src/aster.cpp to stay above a
# floor. The corpus is intentionally broad and cheap: every example through
# build-elf/build-pie/build-obj/build-obj --pic/build-so, the three link verbs,
# keygen plus build-apk/verify-apk, the -g / --bounds-check / --page-size
# paths, the top-level error paths, and the v0.23.77-dev project CLI
# (new/add/deps/build/run/test/doctor) plus the wider DWARF and APK paths.
# It takes well under a minute because the instrumented compiler is built once
# and each CLI call is milliseconds.
#
# The floor is a ratchet, not a target: when the corpus grows, raise it. A
# lower floor is a reviewed source change. Coverage is compiler-version
# sensitive at the margin (templates and inlined helpers change the executable
# line count), which is why the floor sits a few points below the measured
# value rather than at it.
#
# gcov is optional. If it is absent the suite skips (77); a gcov that exists
# but cannot read the profile is a failure, because that is a broken tool, not
# a missing one.
set -eu
cd "$(dirname "$0")/.."
. tests/lib/verdict.sh

OUT=${OUT:-tmp-coverage-checks}
mkdir -p "$OUT/work" "$OUT/keys"
trap 'rm -rf "$OUT"' EXIT HUP INT TERM

CXX=${CXX:-c++}
major=$($CXX -dumpversion 2>/dev/null | cut -d. -f1) || major=""
if [ -n "${GCOV:-}" ]; then
    :
elif [ -n "$major" ] && command -v "gcov-$major" >/dev/null 2>&1; then
    GCOV=gcov-$major
elif command -v gcov >/dev/null 2>&1; then
    GCOV=gcov
else
    aster_skip "coverage needs gcov (none found)"
fi

printf '%s\n' '[1/3] Build src/aster.cpp with --coverage'
$CXX -std=c++17 -O0 --coverage -o "$OUT/aster" src/aster.cpp

printf '%s\n' '[2/3] Drive the corpus'
A=$OUT/aster
W=$OUT/work
for f in examples/*.ast; do
    b=$(basename "$f" .ast)
    "$A" build-elf "$f" -o "$W/$b.elf" >/dev/null 2>&1 || :
    "$A" build-pie "$f" -o "$W/$b.pie" >/dev/null 2>&1 || :
    "$A" build-obj "$f" -o "$W/$b.o" >/dev/null 2>&1 || :
    "$A" build-obj --pic "$f" -o "$W/$b.pic.o" >/dev/null 2>&1 || :
    "$A" build-so "$f" -o "$W/$b.so" >/dev/null 2>&1 || :
done
"$A" build-elf -g examples/condition.ast -o "$W/debug.elf" >/dev/null 2>&1 || :
"$A" build-elf --bounds-check examples/array_rw.ast -o "$W/bounds.elf" >/dev/null 2>&1 || :
"$A" build-elf --page-size 16384 examples/condition.ast -o "$W/page.elf" >/dev/null 2>&1 || :
"$A" build-obj --pic tests/codegen-fixtures/return_42.ast -o "$W/r42.o" >/dev/null 2>&1 || :
"$A" link-obj "$W/r42.o" -o "$W/link42" >/dev/null 2>&1 || :
"$A" link-pie "$W/r42.o" -o "$W/link42.pie" >/dev/null 2>&1 || :
"$A" link-so --soname libx.so "$W/r42.o" -o "$W/libx.so" >/dev/null 2>&1 || :
"$A" keygen --dir "$OUT/keys" --force >/dev/null 2>&1 || :
"$A" build-apk examples/native_render.ast -o "$W/app.apk" --package com.example.aster \
    --keystore-dir "$OUT/keys" >/dev/null 2>&1 || :
"$A" verify-apk "$W/app.apk" >/dev/null 2>&1 || :
"$A" >/dev/null 2>&1 || :
"$A" nope >/dev/null 2>&1 || :

# v0.23.77-dev: the audit round added a project CLI, DWARF validation and a
# wider set of link/page-size/bounds paths. Drive them as well, so the ratchet
# measures the compiler as it is now instead of the subset that existed when
# this corpus was first written. ABS_A survives the subshell cd's below.
ABS_A=$(cd "$(dirname "$A")" && pwd)/$(basename "$A")
mkdir -p "$W/proj"
"$ABS_A" new "$W/proj/app" >/dev/null 2>&1 || :
"$ABS_A" new --apk "$W/proj/apk" >/dev/null 2>&1 || :
if [ -d "$W/proj/app" ]; then
    (cd "$W/proj/app" && "$ABS_A" deps src/main.ast >/dev/null 2>&1) || :
    (cd "$W/proj/app" && "$ABS_A" add src/util.ast >/dev/null 2>&1) || :
    (cd "$W/proj/app" && "$ABS_A" build >/dev/null 2>&1) || :
    (cd "$W/proj/app" && "$ABS_A" run >/dev/null 2>&1) || :
    (cd "$W/proj/app" && "$ABS_A" test >/dev/null 2>&1) || :
    (cd "$W/proj/app" && "$ABS_A" doctor >/dev/null 2>&1) || :
    (cd "$W/proj/app" && "$ABS_A" doctor --strict >/dev/null 2>&1) || :
    (cd "$W/proj/app" && "$ABS_A" build --no-cache -g >/dev/null 2>&1) || :
fi
"$A" build-elf -g examples/structs.ast -o "$W/debug2.elf" >/dev/null 2>&1 || :
"$A" build-so -g examples/runtime_init.ast -o "$W/debugso.so" >/dev/null 2>&1 || :
"$A" build-elf --page-size 16384 --bounds-check examples/array_rw.ast \
    -o "$W/page16.elf" >/dev/null 2>&1 || :
"$A" build-obj -g --pic examples/tls_demo.ast -o "$W/tlsg.o" >/dev/null 2>&1 || :
"$A" link-so --soname libmix.so --needed libc.so.6 "$W/r42.o" \
    -o "$W/libmix.so" >/dev/null 2>&1 || :
"$A" build-apk examples/native_touch.ast -o "$W/touch.apk" \
    --package com.example.touch --keystore-dir "$OUT/keys" >/dev/null 2>&1 || :
"$A" verify-apk "$W/touch.apk" >/dev/null 2>&1 || :

printf '%s\n' '[2b/3] Drive the bilingual corpus (tests/coverage-fixtures-cn)'
if [ ! -d tests/coverage-fixtures-cn ]; then
    echo 'FAIL: [2b/3] bilingual corpus missing: tests/coverage-fixtures-cn/ not found; regenerate it with tests/coverage-fixtures-cn/extract-fixtures.py (do not skip this section)' >&2
    exit 1
fi
# The legacy corpus above never runs the bilingual frontend: src/aster.cpp
# line coverage sat at 46.91% with the cn lowering paths almost entirely
# unexecuted (see audit-cn-s1s2/coverage/uncovered-analysis.md). The
# fixtures below are byte-identical extracts of the cn suite heredocs
# (MANIFEST.md), the D-2a drafts plus their decl-layout stubs, and the
# Gallery/framework sources copied from the UI tree — all self-contained
# in this tree, so this section runs anywhere the tree runs. Every
# fixture is driven through build-cn-obj in both languages: a
# wrong-language run fails fast at lex/parse, the right-language run
# goes through lowering. Rejection probes only reach the diagnostic
# paths; that is intended, not a gap. Project fixtures are copied under
# $W first so `aster build` outputs never dirty the tree.
CNFIX=tests/coverage-fixtures-cn
CNW=$W/cn
mkdir -p "$CNW"
n=0
for f in $(find "$CNFIX" -name '*.ast' | sort); do
    rel=${f#$CNFIX/}
    suite=${rel%%/*}
    n=$((n+1))
    if [ -d "$CNFIX/$suite/packages" ]; then
        "$A" build-cn-obj --language zh --module-dir "$CNFIX/$suite/packages" "$f" -o "$CNW/$n.o" >/dev/null 2>&1 || :
        "$A" build-cn-obj --language en --module-dir "$CNFIX/$suite/packages" "$f" -o "$CNW/$n.o" >/dev/null 2>&1 || :
    else
        "$A" build-cn-obj --language zh "$f" -o "$CNW/$n.o" >/dev/null 2>&1 || :
        "$A" build-cn-obj --language en "$f" -o "$CNW/$n.o" >/dev/null 2>&1 || :
    fi
done
# Bilingual programs that already live in the tree (not suite extracts).
"$A" build-cn-obj examples/cn/hello.ast -o "$CNW/hello.o" >/dev/null 2>&1 || :
"$A" build-cn-obj examples/cn/oop.ast -o "$CNW/oop.o" >/dev/null 2>&1 || :
"$A" build-cn-obj stdlib/cn/string-zh.ast -o "$CNW/string-zh.o" >/dev/null 2>&1 || :
"$A" build-cn-obj --language en stdlib/cn/string-en.ast -o "$CNW/string-en.o" >/dev/null 2>&1 || :
"$A" build-cn-obj --language en stdlib/aster_std.ast -o "$CNW/stdlib.o" >/dev/null 2>&1 || :
"$A" build-cn-obj --project "$CNFIX/cn-backend/aster.proj" "$CNFIX/cn-backend/core-en.ast" -o "$CNW/core-proj.o" >/dev/null 2>&1 || :
# Bilingual `aster build` / `aster test` projects, copied under $W.
CNP=$W/cn-proj
mkdir -p "$CNP"
for p in cn-class/b26 cn-class/b26rt cn-apk/p9exe cn-apk/zhcounter cn-apk/encounter \
         cn-module/project cn-module/bp1-mixed; do
    d=${p#*/}
    rm -rf "$CNP/$d"; cp -r "$CNFIX/$p" "$CNP/$d"
    (cd "$CNP/$d" && "$ABS_A" build >/dev/null 2>&1) || :
done
# Rebuilds: cache reuse, --no-cache and -g paths on the small bilingual project.
(cd "$CNP/project" && "$ABS_A" build >/dev/null 2>&1) || :
(cd "$CNP/project" && "$ABS_A" build --no-cache >/dev/null 2>&1) || :
(cd "$CNP/project" && "$ABS_A" build -g >/dev/null 2>&1) || :
# Expected-failure project (negative probe): mismatched alloc still throws.
rm -rf "$CNP/b26-mismatch"; cp -r "$CNFIX/cn-class/b26-mismatch" "$CNP/b26-mismatch"
(cd "$CNP/b26-mismatch" && "$ABS_A" build >/dev/null 2>&1) || :
(cd "$CNP/b26-mismatch" && "$ABS_A" build-cn-obj --project aster.proj src/widget.ast -o "$CNW/b26mm-widget.o" >/dev/null 2>&1) || :
(cd "$CNP/b26-mismatch" && "$ABS_A" build-cn-obj --project aster.proj src/main.ast -o "$CNW/b26mm-main.o" >/dev/null 2>&1) || :
# External-package project: build/run with an out-of-tree module dir.
rm -rf "$CNP/project-external" "$CNP/project-external-packages"
cp -r "$CNFIX/cn-module/project-external" "$CNP/project-external"
cp -r "$CNFIX/cn-module/project-external-packages" "$CNP/project-external-packages"
(cd "$CNP/project-external" && "$ABS_A" build --module-dir "$CNP/project-external-packages" >/dev/null 2>&1) || :
(cd "$CNP/project-external" && "$ABS_A" run --module-dir "$CNP/project-external-packages" >/dev/null 2>&1) || :
# bp1-zh is built with build-cn-obj from inside its project dir (the suite way).
rm -rf "$CNP/bp1-zh"; cp -r "$CNFIX/cn-module/bp1-zh" "$CNP/bp1-zh"
(cd "$CNP/bp1-zh" && "$ABS_A" build-cn-obj src/main.ast -o "$CNW/bp1-zh.o" >/dev/null 2>&1) || :
(cd "$CNP/bp1-zh" && "$ABS_A" build-cn-obj --project aster.proj src/main.ast -o "$CNW/bp1-zh-proj.o" >/dev/null 2>&1) || :
# Expected-failure project (negative probe): bad per-file language entry.
rm -rf "$CNP/bp1-neg"; cp -r "$CNFIX/cn-module/bp1-neg" "$CNP/bp1-neg"
(cd "$CNP/bp1-neg" && "$ABS_A" build >/dev/null 2>&1) || :
# Bilingual `aster test`: one passing project, one duplicate-test-name probe.
rm -rf "$CNP/test-project"; cp -r "$CNFIX/cn-module/test-project" "$CNP/test-project"
(cd "$CNP/test-project" && "$ABS_A" test >/dev/null 2>&1) || :
rm -rf "$CNP/test-collision"; cp -r "$CNFIX/cn-module/test-collision" "$CNP/test-collision"
(cd "$CNP/test-collision" && "$ABS_A" test >/dev/null 2>&1) || :
"$A" verify-apk "$CNP/zhcounter/build/zhcounter.apk" >/dev/null 2>&1 || :
"$A" verify-apk "$CNP/encounter/build/encounter.apk" >/dev/null 2>&1 || :

printf '%s\n' '[3/3] gcov line coverage of src/aster.cpp'
if ! (cd "$OUT" && "$GCOV" -b -c aster.gcno) >"$OUT/gcov.log" 2>&1; then
    echo "FAIL: $GCOV could not read the profile (is it from the same GCC as $CXX?)" >&2
    tail -5 "$OUT/gcov.log" >&2
    exit 1
fi
line=$(awk "/^File '.*src\/aster\.cpp'/{f=1} f&&/Lines executed:/{print;exit}" "$OUT/gcov.log")
pct=$(printf '%s\n' "$line" | sed -n 's/.*Lines executed:\([0-9][0-9.]*\)%.*/\1/p')
total=$(printf '%s\n' "$line" | sed -n 's/.*of \([0-9][0-9]*\).*/\1/p')
if [ -z "$pct" ] || [ -z "$total" ]; then
    echo 'FAIL: no coverage summary for src/aster.cpp in gcov output' >&2
    tail -10 "$OUT/gcov.log" >&2
    exit 1
fi
FLOOR=80
if awk -v p="$pct" -v f="$FLOOR" 'BEGIN{exit !(p+0>=f+0)}'; then
    printf 'PASS: src/aster.cpp line coverage %s%% of %s executable lines (floor %s%%)\n' \
        "$pct" "$total" "$FLOOR"
else
    echo "FAIL: src/aster.cpp line coverage ${pct}% of $total executable lines, below the ${FLOOR}% floor" >&2
    exit 1
fi
