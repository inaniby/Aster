#!/bin/sh
# Reject empty dynamic-loader metadata arguments instead of emitting malformed ELF tags.
set -eu
CXX=${CXX:-g++}
$CXX -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o aster
WORK=tmp-so-argument-checks
rm -rf "$WORK"; mkdir -p "$WORK"
expect_rejected() {
    label=$1; shift
    set +e
    out=$(./aster "$@" 2>&1); rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
        echo "FAIL: $label unexpectedly succeeded"; exit 1
    fi
    printf '%s\n' "$out" | grep -Fq 'requires a non-empty library name' || {
        echo "FAIL: $label did not report an empty library-name diagnostic: $out"; exit 1;
    }
    echo "PASS: $label rejected with a clear diagnostic"
}
expect_rejected 'empty --needed value' build-so examples/so_chain_base.ast -o "$WORK/empty-needed.so" --needed ''
expect_rejected 'empty --needed= value' build-so examples/so_chain_base.ast -o "$WORK/empty-needed-equals.so" --needed=
expect_rejected 'empty --soname value' build-so examples/so_chain_base.ast -o "$WORK/empty-soname.so" --soname ''
expect_rejected 'empty --soname= value' build-so examples/so_chain_base.ast -o "$WORK/empty-soname-equals.so" --soname=
[ ! -e "$WORK/empty-needed.so" ] && [ ! -e "$WORK/empty-needed-equals.so" ] && \
[ ! -e "$WORK/empty-soname.so" ] && [ ! -e "$WORK/empty-soname-equals.so" ] || {
    echo 'FAIL: malformed output file was created'; exit 1;
}
rm -rf "$WORK"
echo 'PASS: empty SONAME/DT_NEEDED arguments cannot produce malformed shared objects'
