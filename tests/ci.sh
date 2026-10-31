#!/bin/sh
# tests/ci.sh — Aster one-command CI regression gate.
#
# The gate is deliberately strict about *signals*:
#
#   exit 0   PASS   the suite ran; optional layers may have printed SKIP
#   exit 77  SKIP   the whole suite could not run; a reason is mandatory
#   other    FAIL   an assertion failed, or the suite died
#
# A missing dependency is reported once, by the environment probe, instead of
# surfacing as a misleading assertion failure inside a suite.  A SKIP in a
# critical suite is a red run: the clean-machine CI is supposed to have qemu,
# readelf, objdump, python3, sha256sum and a C++17 compiler.
#
# The compiler is built once, strictly, and tests/lib/cxx-cache.sh hands that
# binary to every suite that would otherwise recompile src/aster.cpp.  Mutated
# sources, -c, -g, sanitizer and alternate-target builds bypass the cache.
#
# Usage:
#   sh tests/ci.sh
#   sh tests/ci.sh                         # full gate, green machine
#   CI_SUITES="tls-checks.sh linker-checks.sh" sh tests/ci.sh
#   CI_SKIP_APK_GATE=1 CI_ALLOW_MISSING=1 sh tests/ci.sh
#   CI_REBUILD=1 sh tests/ci.sh            # ignore the build stamp
#
# Environment:
#   CXX, HOSTCC, RUNNER     as before; HOSTCC is probed for AArch64 output
#   CI_OUT                  artifact/log directory (default ci-artifacts)
#   CI_SUITES               space-separated subset for a focused run
#   CI_SUITE_DIR            directory the suite names are relative to (tests)
#   CI_CRITICAL             suites whose SKIP is fatal (default list below)
#   CI_ALLOW_MISSING=1      do not exit 2 when a required tool is absent; the
#                           suites then SKIP and critical skips still fail
#   CI_SKIP_APK_GATE=1      skip the three independent APK gates
#   CI_KEEP_ARTIFACTS=1     keep logs even on a green run
#   CI_REBUILD=1            rebuild the cached compiler unconditionally
#   CI_JOBS=N               run N suites in isolated, parallel worktrees
#                           (default 1; suites with fixed /tmp paths run alone)

set -u
cd "$(dirname "$0")/.."

REAL_CXX=${CXX:-g++}
if [ -n "${HOSTCC:-}" ]; then
    :
elif command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
    HOSTCC=aarch64-linux-gnu-gcc
else
    HOSTCC=cc
fi
RUNNER=${RUNNER:-tests/run-aarch64.sh}

OUT=${CI_OUT:-ci-artifacts}
case "$OUT" in
    /*) : ;;
    *) OUT="$PWD/$OUT" ;;
esac
mkdir -p "$OUT"

SUITE_DIR=${CI_SUITE_DIR:-tests}
case "$SUITE_DIR" in
    /*) : ;;
    *) SUITE_DIR="$PWD/$SUITE_DIR" ;;
esac

CRITICAL=${CI_CRITICAL-apk-checks.sh signing-checks.sh tls-checks.sh linker-checks.sh codegen-checks.sh struct-checks.sh enum-checks.sh resource-table-checks.sh page-size-checks.sh version-checks.sh}
ALLOW_MISSING=${CI_ALLOW_MISSING:-0}
SKIP_APK_GATE=${CI_SKIP_APK_GATE:-0}
KEEP_ARTIFACTS=${CI_KEEP_ARTIFACTS:-0}
JOBS=${CI_JOBS:-1}

case "$JOBS" in
    ''|*[!0-9]*)
        printf 'FAIL: CI_JOBS must be a positive integer (got %s)\n' "$JOBS" >&2
        exit 2
        ;;
esac
[ "$JOBS" -ge 1 ] || {
    printf 'FAIL: CI_JOBS must be at least 1 (got %s)\n' "$JOBS" >&2
    exit 2
}
if [ "$JOBS" -gt 1 ]; then
    if [ "$SUITE_DIR" != "$PWD/tests" ]; then
        printf 'WARNING: CI_JOBS>1 needs the default tests/ suite directory; using one job\n' >&2
        JOBS=1
    elif ! command -v tar >/dev/null 2>&1; then
        printf 'WARNING: CI_JOBS>1 needs tar to isolate suites; using one job\n' >&2
        JOBS=1
    else
        case "$OUT" in
            "$PWD"/*)
                out_rel=${OUT#"$PWD"/}
                if [ "$out_rel" != "ci-artifacts" ]; then
                    printf 'WARNING: CI_JOBS>1 needs CI_OUT=ci-artifacts or a directory outside the tree; using one job\n' >&2
                    JOBS=1
                fi
                ;;
        esac
    fi
fi

PASS=0; SKIP=0; FAIL=0; PARTIAL=0; CRITICAL_SKIP=0
GATE_PASS=0; GATE_FAIL=0; GATE_SKIP=0
FAILURES=""
SKIP_REPORT=""

is_critical() {
    case " $CRITICAL " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# 1. Environment probe
# ---------------------------------------------------------------------------
printf '%s\n' '=== Aster CI — environment ==='
printf 'CXX       : %s\n' "$REAL_CXX"
printf 'HOSTCC    : %s\n' "$HOSTCC"
printf 'RUNNER    : %s\n' "$RUNNER"
printf 'OUT       : %s\n' "$OUT"
printf 'JOBS      : %s\n' "$JOBS"

missing_required=""

probe_required() {
    name=$1
    if command -v "$name" >/dev/null 2>&1; then
        printf '%-12s %s\n' "$name" "$(command -v "$name")"
    else
        printf '%-12s MISSING (required)\n' "$name"
        missing_required="$missing_required $name"
    fi
}

probe_optional() {
    name=$1
    if command -v "$name" >/dev/null 2>&1; then
        printf '%-12s %s\n' "$name" "$(command -v "$name")"
    else
        printf '%-12s MISSING (optional)\n' "$name"
    fi
}

probe_required "$REAL_CXX"
probe_required python3
probe_required readelf
probe_required objdump
probe_required sha256sum
probe_optional openssl
probe_optional llvm-objdump
probe_optional llvm-dwarfdump
probe_optional zip
probe_optional unzip

QEMU_OK=0
if [ "$RUNNER" != "tests/run-aarch64.sh" ] && [ -n "$RUNNER" ]; then
    QEMU_OK=1
elif command -v qemu-aarch64 >/dev/null 2>&1; then
    QEMU_OK=1
elif [ "$(uname -m 2>/dev/null)" = "aarch64" ]; then
    QEMU_OK=1
fi
if [ "$QEMU_OK" -eq 1 ]; then
    printf '%-12s %s\n' qemu "available (or native AArch64)"
else
    printf '%-12s MISSING (required)\n' qemu
    missing_required="$missing_required qemu-aarch64"
fi

HOSTCC_OK=0
probe_dir=$(mktemp -d 2>/dev/null || true)
if [ -n "$probe_dir" ]; then
    printf 'int main(void){return 0;}\n' > "$probe_dir/probe.c"
    if "$HOSTCC" -c "$probe_dir/probe.c" -o "$probe_dir/probe.o" >/dev/null 2>&1; then
        if readelf -h "$probe_dir/probe.o" 2>/dev/null | grep -q 'AArch64'; then
            HOSTCC_OK=1
        fi
    fi
    rm -rf "$probe_dir"
fi
if [ "$HOSTCC_OK" -eq 1 ]; then
    printf '%-12s %s\n' HOSTCC "can emit AArch64 ELF"
else
    printf '%-12s %s\n' HOSTCC "cannot emit AArch64 ELF (e2e suites will SKIP)"
fi

if python3 -c "import androguard" >/dev/null 2>&1; then
    printf '%-12s %s\n' androguard present
else
    printf '%-12s %s\n' androguard "MISSING (optional)"
fi
if python3 -c "import PIL" >/dev/null 2>&1; then
    printf '%-12s %s\n' PIL present
else
    printf '%-12s %s\n' PIL "MISSING (optional)"
fi

if [ -n "$missing_required" ]; then
    if [ "$ALLOW_MISSING" -eq 1 ]; then
        printf 'WARNING: missing required tools:%s (CI_ALLOW_MISSING=1)\n' "$missing_required"
    else
        printf 'FATAL: missing required tools:%s\n' "$missing_required" >&2
        printf 'Install them, or set CI_ALLOW_MISSING=1 to let the affected suites SKIP (critical skips will still fail).\n' >&2
        exit 2
    fi
fi

export HOSTCC RUNNER
export ASTER_HAVE_QEMU=$QEMU_OK
export ASTER_HAVE_LLVM_OBJDUMP=0
command -v llvm-objdump >/dev/null 2>&1 && export ASTER_HAVE_LLVM_OBJDUMP=1
export ASTER_HAVE_LLVM_DWARFDUMP=0
command -v llvm-dwarfdump >/dev/null 2>&1 && export ASTER_HAVE_LLVM_DWARFDUMP=1

# ---------------------------------------------------------------------------
# 2. Strict build — once
# ---------------------------------------------------------------------------
printf '\n=== Building aster (strict: -Wall -Wextra -pedantic -Werror) ===\n'
SOURCE_HASH=$(sha256sum src/aster.cpp | awk '{print $1}')
STAMP="$OUT/aster.sha256"
ASTER_BIN=${ASTER_BIN:-$OUT/aster}
case "$ASTER_BIN" in
    /*) : ;;
    *) ASTER_BIN="$PWD/$ASTER_BIN" ;;
esac
mkdir -p "$(dirname "$ASTER_BIN")"

if [ "${CI_REBUILD:-0}" != "1" ] && [ -x "$ASTER_BIN" ] && [ -f "$STAMP" ] \
        && [ "$(cat "$STAMP" 2>/dev/null)" = "$SOURCE_HASH" ]; then
    printf 'BUILD CACHED: %s (%s)\n' "$ASTER_BIN" "$SOURCE_HASH"
else
    build_tmp="$ASTER_BIN.tmp.$$"
    if ! "$REAL_CXX" -std=c++17 -O2 -Wall -Wextra -pedantic -Werror \
            src/aster.cpp -o "$build_tmp" 2>"$OUT/build.log"; then
        cat "$OUT/build.log" >&2
        printf 'BUILD FAILED (any warning is a hard error under -Werror)\n' >&2
        exit 1
    fi
    mv "$build_tmp" "$ASTER_BIN"
    printf '%s\n' "$SOURCE_HASH" > "$STAMP"
    printf 'BUILD OK: %s (%s)\n' "$ASTER_BIN" "$SOURCE_HASH"
fi
"$ASTER_BIN" --version 2>&1 | head -1

# Some older suites still invoke ./aster directly. Keep a copy of the same
# strict binary at the repository root so they test the compiler under test,
# not a stale local build. The path is gitignored and generated.
if [ "$ASTER_BIN" != "$PWD/aster" ]; then
    if cp "$ASTER_BIN" "$PWD/aster.tmp.$$" 2>/dev/null; then
        mv "$PWD/aster.tmp.$$" "$PWD/aster"
    else
        rm -f "$PWD/aster.tmp.$$"
    fi
fi

ASTER_SOURCE_HASH=$SOURCE_HASH
export ASTER_BIN ASTER_SOURCE_HASH
export REAL_CXX
CXX="$PWD/tests/lib/cxx-cache.sh"
export CXX
printf 'CACHE     : compiler builds through %s\n' "$CXX"

# ---------------------------------------------------------------------------
# 3. Suites
# ---------------------------------------------------------------------------
DEFAULT_SUITES="
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
array-address-checks.sh multi-dim-array-checks.sh sizeof-len-checks.sh integer-cast-checks.sh cast-conversions-checks.sh switch-checks.sh enum-checks.sh resource-table-checks.sh runtime-bounds-checks.sh sema-checks.sh signing-checks.sh typedir-mutation.sh
so-argument-checks.sh so-dependency-chain-checks.sh so-dyn-checks.sh so-negative-checks.sh
so-scope-checks.sh symbol-versioning-checks.sh struct-checks.sh symtab-checks.sh wide-int-checks.sh wide-int-literal-checks.sh literals-checks.sh narrow-int-abi-checks.sh narrow-value-coverage.sh write-output-checks.sh syscall-io-checks.sh heap-checks.sh stdlib-checks.sh codegen-checks.sh syntax-relief-checks.sh narrow-memory-checks.sh compiler-other-faces-audit.sh diagnostics-checks.sh
fuzz-checks.sh debugline-checks.sh debug-info-checks.sh eh-frame-checks.sh include-checks.sh version-checks.sh ci-protocol-checks.sh coverage-checks.sh mutation-score-checks.sh
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
SUITES=${CI_SUITES:-$DEFAULT_SUITES}
set -- $SUITES
SUITE_TOTAL=$#

printf '\n=== Running %s test suites ===\n' "$SUITE_TOTAL"

# classify_suite <name> — print the verdict for one finished suite and update
# the counters. The runner leaves the exit status in $OUT/<suite>.rc.
classify_suite() {
    s=$1
    path="$SUITE_DIR/$s"
    log="$OUT/$s.log"
    printf '%-44s ' "$s"

    if [ ! -f "$path" ]; then
        printf 'FAIL (missing suite)\n'
        FAIL=$((FAIL+1)); FAILURES="$FAILURES $s"
        return 0
    fi

    rc=$(cat "$OUT/$s.rc" 2>/dev/null || printf '1')
    case "$rc" in
        ''|*[!0-9]*) rc=1 ;;
    esac
    skip_reason=$(sed -n 's/^[[:space:]]*SKIP:[[:space:]]*//p' "$log" | head -1)
    skip_marks=$(grep -cE '^[[:space:]]*SKIP:' "$log" 2>/dev/null || true)
    pass_marks=$(grep -Eic '^[[:space:]]*(PASS|OK):|ALL .*PASSED|=== .*PASSED' "$log" 2>/dev/null || true)
    skip_marks=${skip_marks:-0}
    pass_marks=${pass_marks:-0}

    if [ "$rc" -eq 77 ]; then
        if [ -z "$skip_reason" ]; then
            printf 'FAIL (rc=77 without a SKIP reason)\n'
            FAIL=$((FAIL+1)); FAILURES="$FAILURES $s"
            return 0
        fi
        if is_critical "$s"; then
            printf 'FAIL (critical suite SKIP: %s)\n' "$skip_reason"
            FAIL=$((FAIL+1)); CRITICAL_SKIP=$((CRITICAL_SKIP+1))
            FAILURES="$FAILURES $s"
        else
            printf 'SKIP (%s)\n' "$skip_reason"
            SKIP=$((SKIP+1))
            SKIP_REPORT="$SKIP_REPORT
  $s — $skip_reason"
        fi
    elif [ "$rc" -ne 0 ]; then
        printf 'FAIL (rc=%s)\n' "$rc"
        FAIL=$((FAIL+1)); FAILURES="$FAILURES $s"
        printf '%s\n' "----- tail of $path -----" >&2
        tail -n 10 "$log" >&2 || true
    elif [ "$pass_marks" -eq 0 ] && [ "$skip_marks" -gt 0 ]; then
        # Legacy suite: exit 0 with only SKIP lines.  Keep it visible and let
        # critical-suite policy reject it, but do not call a suite that never
        # ran a PASS.
        if is_critical "$s"; then
            printf 'FAIL (critical suite skipped without exit 77: %s)\n' "${skip_reason:-no reason}"
            FAIL=$((FAIL+1)); CRITICAL_SKIP=$((CRITICAL_SKIP+1))
            FAILURES="$FAILURES $s"
        else
            printf 'SKIP (legacy exit 0: %s)\n' "${skip_reason:-no reason}"
            SKIP=$((SKIP+1))
            SKIP_REPORT="$SKIP_REPORT
  $s — legacy exit 0 — ${skip_reason:-no reason}"
        fi
    else
        if [ "$skip_marks" -gt 0 ]; then
            printf 'PASS (partial skips: %s)\n' "$skip_marks"
            PARTIAL=$((PARTIAL+1))
        else
            printf 'PASS\n'
        fi
        PASS=$((PASS+1))
    fi
    return 0
}

# run_suite_serial <name> — run in the repository, as every suite always has.
run_suite_serial() {
    s=$1
    path="$SUITE_DIR/$s"
    log="$OUT/$s.log"
    if [ ! -f "$path" ]; then
        : >"$log"
        printf '127\n' >"$OUT/$s.rc"
        return 0
    fi
    HOSTCC="$HOSTCC" RUNNER="$RUNNER" CXX="$CXX" ASTER_BIN="$ASTER_BIN" \
        ASTER_SOURCE_HASH="$ASTER_SOURCE_HASH" sh "$path" >"$log" 2>&1
    printf '%s\n' "$?" >"$OUT/$s.rc"
    return 0
}

# run_suite_isolated <name> — copy the tree to a private worktree, run the
# suite there, then discard the copy. Suites write fixed names such as
# tmp-g-rw.o and tmp-dyn-a.o into their current directory; without a private
# tree those names collide as soon as two suites run at once. The cached
# compiler and the runner wrapper stay absolute and shared.
run_suite_isolated() {
    s=$1
    path="$SUITE_DIR/$s"
    log="$OUT/$s.log"
    if [ ! -f "$path" ]; then
        : >"$log"
        printf '127\n' >"$OUT/$s.rc"
        return 0
    fi

    work="$OUT/work/$s"
    tarfile="$OUT/$s.tar"
    rm -rf "$work"
    mkdir -p "$work/tmp"
    if ! tar -C "$PWD" -cf "$tarfile" \
            --exclude=./.git --exclude=./.aster --exclude=./build \
            --exclude=./ci-artifacts --exclude='./tmp-*' \
            --exclude='./*.core' --exclude='__pycache__' . 2>"$OUT/$s.copy.log" \
            || ! tar -C "$work" -xf "$tarfile" 2>>"$OUT/$s.copy.log"; then
        printf 'FAIL: could not isolate the tree\n' >"$log"
        printf '125\n' >"$OUT/$s.rc"
        rm -rf "$work" "$tarfile"
        return 0
    fi
    rm -f "$tarfile" "$OUT/$s.copy.log"

    ( cd "$work" && HOSTCC="$HOSTCC" RUNNER="$RUNNER" CXX="$CXX" \
        ASTER_BIN="$ASTER_BIN" ASTER_SOURCE_HASH="$ASTER_SOURCE_HASH" \
        TMPDIR="$work/tmp" sh "$work/tests/$s" ) >"$log" 2>&1
    printf '%s\n' "$?" >"$OUT/$s.rc"
    rm -rf "$work"
    return 0
}

# run_parallel_batches <jobs> <suite...> — start at most <jobs> isolated suites
# at a time and classify each batch as it finishes.
run_parallel_batches() {
    jobs=$1
    shift
    batch_names=""
    batch_pids=""
    n=0
    for s in "$@"; do
        run_suite_isolated "$s" &
        batch_pids="$batch_pids $!"
        batch_names="$batch_names $s"
        n=$((n+1))
        if [ "$n" -ge "$jobs" ]; then
            for p in $batch_pids; do wait "$p" || true; done
            for s in $batch_names; do classify_suite "$s"; done
            batch_names=""; batch_pids=""; n=0
        fi
    done
    if [ -n "$batch_pids" ]; then
        for p in $batch_pids; do wait "$p" || true; done
        for s in $batch_names; do classify_suite "$s"; done
    fi
}

if [ "$JOBS" -gt 1 ]; then
    parallel_suites=""
    serial_suites=""
    serial_count=0
    for s in $SUITES; do
        if grep -q '/tmp/' "$SUITE_DIR/$s" 2>/dev/null; then
            serial_suites="$serial_suites $s"
            serial_count=$((serial_count+1))
        else
            parallel_suites="$parallel_suites $s"
        fi
    done
    printf '  %s isolated jobs; %s suite(s) with fixed /tmp paths run alone\n' \
        "$JOBS" "$serial_count"

    # shellcheck disable=SC2086 # the list is intentionally word-split
    run_parallel_batches "$JOBS" $parallel_suites
    for s in $serial_suites; do
        run_suite_isolated "$s"
        classify_suite "$s"
    done
else
    for s in $SUITES; do
        run_suite_serial "$s"
        classify_suite "$s"
    done
fi

# ---------------------------------------------------------------------------
# 4. APK verification gate (independent of the suites)
# ---------------------------------------------------------------------------
printf '\n=== APK verification gate ===\n'
gate_apk() {
    dname=$1; src=$2; pkg=$3; lib=$4; lab=$5; shift 5
    printf '%-44s ' "$dname"
    KEY_DIR="$OUT/keys"; mkdir -p "$KEY_DIR"
    APK="$OUT/$(basename "$src" .ast).apk"
    if "$ASTER_BIN" build-apk "$src" -o "$APK" \
            --package "$pkg" --libname "$lib" --abi arm64-v8a \
            --label "$lab" "$@" \
            --min-sdk 24 --target-sdk 34 --version-code 1 --version-name "1.0" \
            --keystore-dir "$KEY_DIR" >"$OUT/apk-build-$lib.log" 2>&1; then
        if python3 tests/validate_apk.py "$APK" --package "$pkg" \
                --libname "$lib" --label "$lab" --label-literal \
                >"$OUT/apk-validate-$lib.log" 2>&1; then
            if "$ASTER_BIN" verify-apk "$APK" >"$OUT/apk-verify-$lib.log" 2>&1; then
                echo "PASS"; GATE_PASS=$((GATE_PASS+1))
            else
                echo "FAIL (aster verify-apk)"; GATE_FAIL=$((GATE_FAIL+1))
                FAILURES="$FAILURES apk-verify-$lib"
                tail -n 10 "$OUT/apk-verify-$lib.log" >&2 || true
            fi
        else
            echo "FAIL (validate_apk.py)"; GATE_FAIL=$((GATE_FAIL+1))
            FAILURES="$FAILURES apk-validate-$lib"
            tail -n 15 "$OUT/apk-validate-$lib.log" >&2 || true
        fi
    else
        echo "FAIL (build-apk)"; GATE_FAIL=$((GATE_FAIL+1))
        FAILURES="$FAILURES apk-build-$lib"
        tail -n 15 "$OUT/apk-build-$lib.log" >&2 || true
    fi
}

if [ "$SKIP_APK_GATE" -eq 1 ]; then
    echo "SKIP (CI_SKIP_APK_GATE=1)"; GATE_SKIP=$((GATE_SKIP+1))
else
    gate_apk "apk: native_render"  examples/native_render.ast  com.aster.nativerender nativerender 'Aster NativeRender'
    gate_apk "apk: icon_text_demo" examples/icon_text_demo.ast com.aster.icontext    icontext    'Aster 图标文字' \
        --string app_subtitle="ICON + TEXT" --string greeting="Hello from resources.arsc"
    gate_apk "apk: native_touch"    examples/native_touch.ast    com.aster.nativeapp  nativeapp   'Aster Touch'
fi

# ---------------------------------------------------------------------------
# 5. Summary
# ---------------------------------------------------------------------------
printf '\n========================================\n'
printf 'CI SUMMARY: %d passed, %d skipped, %d failed (of %d suites)\n' \
    "$PASS" "$SKIP" "$FAIL" "$SUITE_TOTAL"
printf 'APK GATES : %d passed, %d skipped, %d failed\n' \
    "$GATE_PASS" "$GATE_SKIP" "$GATE_FAIL"
if [ "$PARTIAL" -gt 0 ]; then
    printf 'PARTIAL   : %d suite(s) passed with optional SKIP layers\n' "$PARTIAL"
fi
if [ -n "$SKIP_REPORT" ]; then
    printf 'SKIPPED:%s\n' "$SKIP_REPORT"
fi
if [ -n "$FAILURES" ]; then
    printf 'FAILED:%s\n' "$FAILURES"
fi
printf '========================================\n'

if [ "$FAIL" -gt 0 ] || [ "$GATE_FAIL" -gt 0 ]; then
    printf 'Failing run: per-suite logs kept under %s/\n' "$OUT"
    exit 1
fi

if [ "$KEEP_ARTIFACTS" != "1" ]; then
    rm -rf "$OUT" 2>/dev/null || true
    rm -f tmp-* 2>/dev/null || true
fi
exit 0
