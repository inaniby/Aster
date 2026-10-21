#!/bin/sh
# Structural checks for the Aster-generated client -> middle -> base chain.
set -eu
CXX=${CXX:-g++}
READELF=${READELF:-readelf}
$CXX -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o aster
WORK=tmp-so-dependency-chain-structural
rm -rf "$WORK"; mkdir -p "$WORK"
./aster build-so examples/so_chain_base.ast -o "$WORK/libchain-base.so" --soname libchain-base.so
./aster build-so examples/so_chain_middle.ast -o "$WORK/libchain-middle.so" --soname libchain-middle.so --needed libchain-base.so
./aster build-so examples/so_chain_client.ast -o "$WORK/libchain-client.so" --soname libchain-client.so --needed libchain-middle.so
"$READELF" -d "$WORK/libchain-base.so" | grep -Fq 'Library soname: [libchain-base.so]' || { echo 'FAIL: base SONAME'; exit 1; }
"$READELF" -d "$WORK/libchain-middle.so" | grep -Fq 'Library soname: [libchain-middle.so]' || { echo 'FAIL: middle SONAME'; exit 1; }
"$READELF" -d "$WORK/libchain-middle.so" | grep -Fq 'Shared library: [libchain-base.so]' || { echo 'FAIL: middle DT_NEEDED base'; exit 1; }
"$READELF" -d "$WORK/libchain-client.so" | grep -Fq 'Library soname: [libchain-client.so]' || { echo 'FAIL: client SONAME'; exit 1; }
"$READELF" -d "$WORK/libchain-client.so" | grep -Fq 'Shared library: [libchain-middle.so]' || { echo 'FAIL: client DT_NEEDED middle'; exit 1; }
"$READELF" -r "$WORK/libchain-middle.so" | grep -q 'R_AARCH64_JUMP_SL' || { echo 'FAIL: middle PLT imports'; exit 1; }
"$READELF" -r "$WORK/libchain-middle.so" | grep -q 'R_AARCH64_GLOB_DA' || { echo 'FAIL: middle GOT import'; exit 1; }
"$READELF" -r "$WORK/libchain-client.so" | grep -q 'R_AARCH64_JUMP_SL' || { echo 'FAIL: client PLT imports'; exit 1; }
echo 'PASS: base/middle/client SONAME and DT_NEEDED chain'
echo 'PASS: middle imports base functions through PLT and global through GOT'
echo 'PASS: client imports middle functions through PLT'
rm -rf "$WORK"
