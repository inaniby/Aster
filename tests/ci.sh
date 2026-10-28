#!/bin/sh
# tests/ci.sh — Aster one-command CI regression gate (P4.3).
#
# One command to run the whole delivery discipline Aster lives by:
#   1. Probe the environment (compiler, qemu, openssl, androguard, PIL, HOSTCC).
#   2. Build aster STRICTLY: -std=c++17 -O2 -Wall -Wextra -pedantic -Werror.
#      -Werror turns any warning into a hard build failure, so zero-warning
#      compilation is enforced here, not just hoped for.
#   3. Run every test suite (*-checks.sh, *-structural.sh, e2e-*.sh). Each suite
#      is a black box: exit 0 with a "SKIP" line counts as SKIP, exit 0 with no
#      skip counts as PASS, non-zero counts as FAIL (and we keep going so every
#      suite gets a verdict).
#   4. Build the icon+text demo APK and verify it two independent ways:
#        - python3 tests/validate_apk.py ... --label-literal
#        - ./aster verify-apk ...
#   5. Print a per-suite summary and exit 1 if anything FAILED.
#
# Suites that need a target-architecture $HOSTCC (the e2e and C-ABI suites) skip
# themselves cleanly (exit 0 with a SKIP line) when no such compiler exists; pass
# HOSTCC to override the automatic choice. When aarch64-linux-gnu-gcc is on PATH
# it is picked on every host: the e2e hosts are AArch64 binaries and RUNNER
# executes them under qemu-user off AArch64, so cross-compiling them is a
# supported configuration everywhere (it used to be an x86-only mistake).
#
# Usage:
#   sh tests/ci.sh
#   HOSTCC=aarch64-linux-gnu-gcc sh tests/ci.sh
#   CXX=clang++ sh tests/ci.sh

set -u
cd "$(dirname "$0")/.."

CXX=${CXX:-g++}
# HOSTCC selects the C compiler used by the end-to-end (e2e) suites, which build
# a C host program that links Aster's AArch64 output. That host is a *target*
# binary: it is executed through RUNNER (tests/run-aarch64.sh), which runs it
# natively on an AArch64 host and under qemu-user everywhere else. So HOSTCC
# must emit AArch64 ELF, not "binaries runnable on THIS machine". We prefer the
# cross toolchain whenever it is installed; a native aarch64 cc is the fallback
# when it is not; without either, the e2e suites' own probe SKIPs them cleanly.
# An explicit HOSTCC on the command line always wins.
if [ -n "${HOSTCC:-}" ]; then
    : # caller-supplied
elif command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
    HOSTCC=aarch64-linux-gnu-gcc
else
    HOSTCC=cc
fi
RUNNER=${RUNNER:-tests/run-aarch64.sh}
OUT=${CI_OUT:-ci-artifacts}
mkdir -p "$OUT"

PASS=0; SKIP=0; FAIL=0
FAILURES=""

# ---------------------------------------------------------------------------
# 1. Environment probe
# ---------------------------------------------------------------------------
printf '%s\n' "=== Aster CI — environment ==="
printf 'CXX       : %s (%s)\n' "$CXX" "$("$CXX" --version 2>/dev/null | head -1)"
printf 'HOSTCC    : %s\n' "$HOSTCC"
printf 'RUNNER    : %s\n' "$RUNNER"
printf 'qemu      : %s\n' "$(command -v qemu-aarch64 || echo MISSING)"
printf 'readelf   : %s\n' "$(command -v readelf || echo MISSING)"
printf 'openssl   : %s\n' "$(command -v openssl || echo MISSING)"
python3 -c "import androguard, PIL; print('androguard/PIL: present')" 2>/dev/null \
    || printf 'androguard/PIL: %s\n' "$(python3 -c 'import androguard' 2>/dev/null && echo androguard-only || echo MISSING)"

# ---------------------------------------------------------------------------
# 2. Strict build (warnings are errors)
# ---------------------------------------------------------------------------
printf '\n=== Building aster (strict: -Wall -Wextra -pedantic -Werror) ===\n'
if ! build_log=$("$CXX" -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp -o aster 2>&1); then
    echo "$build_log"
    echo "BUILD FAILED (any warning is a hard error under -Werror)"
    exit 1
fi
echo "BUILD OK: ./aster — $("$CXX" -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp -o /dev/null 2>&1; ./aster --help 2>&1 | head -1)"

# ---------------------------------------------------------------------------
# 3. Full suite list (each file is a black-box suite)
# ---------------------------------------------------------------------------
SUITES="
apk-checks.sh array-bounds-checks.sh bool-checks.sh comment-checks.sh
condition-checks.sh
null-ptr-checks.sh
embed-checks.sh error-checks.sh for-loop-checks.sh global-checks.sh
global-deep-checks.sh tls-checks.sh gnu-hash-checks.sh icon-checks.sh icon-text-demo-checks.sh
indirect-call-checks.sh function-type-checks.sh
callback-table-checks.sh function-return-fn-checks.sh discard-call-checks.sh
linker-checks.sh local-array-checks.sh object-checks.sh operator-checks.sh pie-so-checks.sh
pixel-offset-checks.sh pointer-index-checks.sh precedence-checks.sh
array-elem-types-checks.sh array-param-bounds-checks.sh relro-checks.sh struct-array-field-checks.sh
array-address-checks.sh multi-dim-array-checks.sh sizeof-len-checks.sh integer-cast-checks.sh switch-checks.sh resource-table-checks.sh runtime-bounds-checks.sh sema-checks.sh signing-checks.sh typedir-mutation.sh
so-argument-checks.sh so-dependency-chain-checks.sh so-dyn-checks.sh so-negative-checks.sh
so-scope-checks.sh symbol-versioning-checks.sh struct-checks.sh symtab-checks.sh wide-int-checks.sh wide-int-literal-checks.sh literals-checks.sh narrow-int-abi-checks.sh narrow-value-coverage.sh write-output-checks.sh syscall-io-checks.sh heap-checks.sh stdlib-checks.sh codegen-checks.sh syntax-relief-checks.sh narrow-memory-checks.sh compiler-other-faces-audit.sh diagnostics-checks.sh
fuzz-checks.sh debugline-checks.sh debug-info-checks.sh eh-frame-checks.sh include-checks.sh version-checks.sh
touch-checks.sh page-size-checks.sh bootstrap-loop-checks.sh pointer-difference-checks.sh address-of-checks.sh
e2e-c-abi-32-args.sh e2e-c-abi-32-external.sh e2e-c-abi.sh e2e-c-libc-strings.sh
e2e-c-mixed-ptr-stack.sh e2e-c-multi-object-rodata.sh e2e-c-ptr-arithmetic.sh
e2e-c-ptr-index.sh e2e-c-ptr-memory.sh e2e-c-ptr-u8.sh e2e-c-ptr.sh e2e-c-ptr-difference.sh e2e-c-address-of.sh
e2e-c-string-literals.sh e2e-c-struct.sh e2e-global-deep.sh e2e-pie-so.sh
e2e-relro.sh e2e-so-dependency-chain.sh e2e-so-dependency-failure.sh
e2e-so-dependency-lifecycle.sh e2e-so-import.sh e2e-so-negative.sh e2e-symtab.sh
lifecycle-callbacks.sh
c-abi-32-args-structural.sh c-abi-32-external-structural.sh c-abi-structural.sh
c-libc-strings-structural.sh c-mixed-ptr-stack-structural.sh
c-multi-object-rodata-structural.sh c-ptr-arithmetic-structural.sh c-ptr-structural.sh
c-ptr-u8-structural.sh c-string-literals-structural.sh
"

printf '\n=== Running %s test suites ===\n' "$(echo $SUITES | wc -w)"
for s in $SUITES; do
    path="tests/$s"
    if [ ! -f "$path" ]; then
        printf '%-42s MISSING (no such suite)\n' "$s"
        FAIL=$((FAIL+1)); FAILURES="$FAILURES $s"; continue
    fi
    log="$OUT/$s.log"
    mkdir -p "$OUT"
    printf '%-42s ' "$s"
    if HOSTCC="$HOSTCC" RUNNER="$RUNNER" CXX="$CXX" sh "$path" >"$log" 2>&1; then
        if grep -qiE '^[[:space:]]*SKIP|SKIP:' "$log"; then
            echo "SKIP"; SKIP=$((SKIP+1))
        else
            echo "PASS"; PASS=$((PASS+1))
        fi
    else
        rc=$?
        echo "FAIL (rc=$rc)"; FAIL=$((FAIL+1)); FAILURES="$FAILURES $s"
        echo "----- tail of $path -----" >&2
        tail -n 10 "$log" >&2 || true
    fi
done

# ---------------------------------------------------------------------------
# 4. APK verification gate (independent of the suites above)
#    Build each demo APK and verify it two independent ways:
#      - python3 tests/validate_apk.py ... --label-literal
#      - ./aster verify-apk ...
#    Neither step needs HOSTCC, so this gate runs on every runner.
# ---------------------------------------------------------------------------
printf '\n=== APK verification gate ===\n'
gate_apk() {
    # $1 = display name, $2 = source .ast, $3 = package, $4 = libname,
    # $5 = label, rest = extra build-apk args (e.g. --string NAME=VALUE)
    dname=$1; src=$2; pkg=$3; lib=$4; lab=$5; shift 5
    printf '%-42s ' "$dname"
    KEY_DIR="$OUT/keys"; mkdir -p "$KEY_DIR"
    APK="$OUT/$(basename "$src" .ast).apk"
    if ./aster build-apk "$src" -o "$APK" \
            --package "$pkg" --libname "$lib" --abi arm64-v8a \
            --label "$lab" "$@" \
            --min-sdk 24 --target-sdk 34 --version-code 1 --version-name "1.0" \
            --keystore-dir "$KEY_DIR" >"$OUT/apk-build-$lib.log" 2>&1; then
        if python3 tests/validate_apk.py "$APK" --package "$pkg" \
                --libname "$lib" --label "$lab" --label-literal \
                >"$OUT/apk-validate-$lib.log" 2>&1; then
            if ./aster verify-apk "$APK" >"$OUT/apk-verify-$lib.log" 2>&1; then
                echo "PASS"; PASS=$((PASS+1))
            else
                echo "FAIL (aster verify-apk)"; FAIL=$((FAIL+1)); FAILURES="$FAILURES apk-verify-$lib"
                tail -n 10 "$OUT/apk-verify-$lib.log" >&2 || true
            fi
        else
            echo "FAIL (validate_apk.py)"; FAIL=$((FAIL+1)); FAILURES="$FAILURES apk-validate-$lib"
            tail -n 15 "$OUT/apk-validate-$lib.log" >&2 || true
        fi
    else
        echo "FAIL (build-apk)"; FAIL=$((FAIL+1)); FAILURES="$FAILURES apk-build-$lib"
        tail -n 15 "$OUT/apk-build-$lib.log" >&2 || true
    fi
}

gate_apk "apk: native_render"  examples/native_render.ast  com.aster.nativerender nativerender 'Aster NativeRender'
gate_apk "apk: icon_text_demo" examples/icon_text_demo.ast com.aster.icontext    icontext    'Aster 图标文字' \
    --string app_subtitle="ICON + TEXT" --string greeting="Hello from resources.arsc"
gate_apk "apk: native_touch"    examples/native_touch.ast    com.aster.nativeapp  nativeapp   'Aster Touch'

# ---------------------------------------------------------------------------
# 5. Summary
# ---------------------------------------------------------------------------
printf '\n========================================\n'
printf 'CI SUMMARY: %d passed, %d skipped, %d failed (of %d checks)\n' \
    "$PASS" "$SKIP" "$FAIL" "$((PASS+SKIP+FAIL))"
if [ -n "$FAILURES" ]; then
    printf 'FAILED:%s\n' "$FAILURES"
fi
printf '========================================\n'

# Clean up scratch artifacts produced during the run. On a RED run the per-suite
# logs are the only record of what went wrong, so they stay: deleting the
# evidence is how a failure turns into an unreproducible mystery (it did once --
# a suite failed, ci.sh removed its log with the rest, and the next run was
# green with no clue left). A green run leaves nothing behind.
if [ "$FAIL" -gt 0 ]; then
    printf 'Failing run: per-suite logs kept under %s/\n' "$OUT"
    exit 1
fi
rm -rf "$OUT" 2>/dev/null || true
rm -f tmp-* 2>/dev/null || true
exit 0
