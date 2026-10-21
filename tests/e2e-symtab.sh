#!/bin/sh
# v0.17.0 end-to-end check for the source-level symbol table: the images that carry a .symtab are
# actually executed (natively or through a runner such as `qemu-aarch64`), and real binutils is asked
# to read the table back with `readelf -s`, so the evidence does not depend on this project's parser.
#
#   HOSTCC=aarch64-linux-gnu-gcc RUNNER="qemu-aarch64 -L /usr/aarch64-linux-gnu" sh tests/e2e-symtab.sh
#
# On an AArch64 host use RUNNER= (the default). HOSTCC compiles the target-architecture test hosts.
set -eu
. tests/host-toolchain-probe.sh
HOSTCC=${HOSTCC:-cc}
READELF=${READELF:-aarch64-linux-gnu-readelf}
RUNNER=${RUNNER:-tests/run-aarch64.sh}
run() { $RUNNER "$@"; }
[ -x ./aster ] || { echo "build ./aster first" >&2; exit 2; }

./aster build-elf examples/symbols_demo.ast -o tmp-sym-e2e-exec
./aster build-pie examples/symbols_demo.ast -o tmp-sym-e2e-pie
./aster build-pie examples/symbols_init.ast -o tmp-sym-e2e-init
./aster build-so  examples/symbols_demo.ast -o tmp-sym-e2e.so
chmod +x tmp-sym-e2e-exec tmp-sym-e2e-pie tmp-sym-e2e-init

$HOSTCC -O1 -o tmp-sym-loader tests/pie-loader.c
$HOSTCC -O1 -o tmp-sym-host tests/sym-host.c -ldl

check() { # label expected command...
  label=$1
  want=$2
  shift 2
  set +e
  run "$@"
  got=$?
  set -e
  if [ "$got" != "$want" ]; then echo "FAIL: $label expected exit $want, got $got" >&2; exit 1; fi
  echo "PASS: $label exit=$got"
}

# symbols_demo: counter=5 -> 6, so main returns bump(6)+zeroed+spare[1] = 42+0+3 = 45.
check "ET_EXEC with .symtab" 45 ./tmp-sym-e2e-exec
check "static PIE with .symtab, kernel-chosen base" 45 ./tmp-sym-e2e-pie
check "static PIE with run-time initializer" 42 ./tmp-sym-e2e-init

# The same PIE loaded by an unrelated user-space loader at several random bases: appending the
# section table and the symbol table must not have introduced any address dependence.
i=1
while [ "$i" -le 3 ]; do
  check "static PIE at a random base (run $i)" 45 ./tmp-sym-loader ./tmp-sym-e2e-pie
  i=$((i + 1))
done
check "static-PIE run-time initializer at a random base" 42 ./tmp-sym-loader ./tmp-sym-e2e-init

check "shared object with .symtab through dlopen/dlsym" 0 ./tmp-sym-host ./tmp-sym-e2e.so

# ---------------------------------------------------------------- readelf -s evidence
if [ "$READELF" = none ]; then
  echo "# note: READELF=none, so the five binutils evidence lines below are skipped"
  READELF=
else
  READELF=$(command -v "$READELF" 2>/dev/null || command -v readelf 2>/dev/null || true)
  if [ -z "$READELF" ]; then
    echo "FAIL: no readelf found; install binutils or point READELF at an AArch64-capable readelf" >&2
    echo "      (use READELF=none to run only the execution checks)" >&2
    exit 2
  fi
fi
if [ -n "$READELF" ]; then
  for spec in "tmp-sym-e2e-exec:main bump counter zeroed table spare _start" \
              "tmp-sym-e2e-pie:main bump counter zeroed table spare _start" \
              "tmp-sym-e2e-init:main seed started arr" \
              "tmp-sym-e2e.so:main bump counter zeroed table spare"; do
    image=${spec%%:*}
    names=${spec#*:}
    table=$($READELF -sW "$image")
    for n in $names; do
      echo "$table" | grep -qE "^ *[0-9]+: +[0-9a-f]+ +[0-9]+ +(FUNC|OBJECT) +GLOBAL +DEFAULT +[0-9]+ +$n$" \
        || { echo "FAIL: $READELF -s $image does not show $n as a defined GLOBAL FUNC/OBJECT" >&2; exit 1; }
    done
    echo "PASS: $($READELF --version | head -1 | cut -d' ' -f1) -s lists $(echo $names | wc -w) source-level name(s) in $image"
  done
  $READELF -SW tmp-sym-e2e-exec | grep -qE '\.bss +NOBITS' || { echo "FAIL: .bss must be NOBITS" >&2; exit 1; }
  $READELF -SW tmp-sym-e2e.so | grep -q '\.dynsym' || { echo "FAIL: .dynsym disappeared" >&2; exit 1; }
  $READELF -SW tmp-sym-e2e.so | grep -q '\.rela.dyn' || { echo "FAIL: .rela.dyn disappeared" >&2; exit 1; }
  echo "PASS: readelf confirms .bss is NOBITS and the shared object keeps .dynsym/.rela.dyn"
fi

rm -f tmp-sym-e2e-exec tmp-sym-e2e-pie tmp-sym-e2e-init tmp-sym-e2e.so tmp-sym-loader tmp-sym-host
echo "PASS: all v0.17.0 source-level symbol table execution checks"
