#!/bin/sh
# tests/ci-protocol-checks.sh -- self-tests for the CI trust layer.
#
# tests/ci.sh is only as trustworthy as the two mechanisms it relies on:
# tests/lib/verdict.sh (the 0/77/1 exit protocol) and tests/lib/cxx-cache.sh
# (build once per run).  A regression in either would let a red run look green,
# so both are exercised here with child shells and a fake compiler.

set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
. "$HERE/lib/verdict.sh"

aster_require_cmd sha256sum "sha256sum is required to test the build cache"
aster_require_cmd cmp "cmp is required to compare cached outputs"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/aster-ci-protocol.XXXXXX") || aster_fail "cannot create a temporary directory"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT HUP INT TERM

PASSED=0
FAILED=0

pass() { PASSED=$((PASSED + 1)); printf 'PASS: %s\n' "$1"; }
fail() { FAILED=$((FAILED + 1)); printf 'FAIL: %s\n' "$1" >&2; }

# check_verdict NAME EXPECTED_RC EXPECTED_TEXT CODE
# Runs CODE in a fresh shell with verdict.sh sourced.
check_verdict() {
    name=$1
    want_rc=$2
    want_text=$3
    code=$4
    out=$(sh -c '. "$1"; eval "$2"' sh "$HERE/lib/verdict.sh" "$code" 2>&1)
    rc=$?
    ok=1
    [ "$rc" -eq "$want_rc" ] || ok=0
    if [ -n "$want_text" ]; then
        case "$out" in
            *"$want_text"*) : ;;
            *) ok=0 ;;
        esac
    fi
    if [ "$ok" -eq 1 ]; then
        pass "$name"
    else
        fail "$name (rc=$rc, wanted $want_rc; output: $out)"
    fi
}

# ---------------------------------------------------------------------------
# verdict.sh
# ---------------------------------------------------------------------------
if [ "$ASTER_EXIT_PASS" -eq 0 ] && [ "$ASTER_EXIT_SKIP" -eq 77 ] \
        && [ "$ASTER_EXIT_FAIL" -eq 1 ]; then
    pass "verdict constants are 0/77/1"
else
    fail "verdict constants are $ASTER_EXIT_PASS/$ASTER_EXIT_SKIP/$ASTER_EXIT_FAIL, wanted 0/77/1"
fi

check_verdict "aster_skip exits 77 and prints its reason" 77 \
    "SKIP: qemu is absent" 'aster_skip "qemu is absent"'

check_verdict "aster_skip without a reason exits 1" 1 \
    "aster_skip needs a reason" 'aster_skip'

check_verdict "aster_fail exits 1 with its reason" 1 \
    "FAIL: assertion did not hold" 'aster_fail "assertion did not hold"'

check_verdict "aster_require_cmd passes for an installed tool" 0 "" \
    'aster_require_cmd sh "sh is missing"'

check_verdict "aster_require_cmd skips 77 for a missing tool" 77 \
    "SKIP: required tool absent" \
    'aster_require_cmd aster-tool-that-does-not-exist-9f3a "required tool absent"'

: > "$TMP/existing-file"
check_verdict "aster_require_file passes for an existing file" 0 "" \
    "aster_require_file '$TMP/existing-file' 'missing file'"

check_verdict "aster_require_file skips 77 for a missing file" 77 \
    "SKIP: required file absent" \
    'aster_require_file /nonexistent/aster-ci-protocol "required file absent"'

# ---------------------------------------------------------------------------
# cxx-cache.sh
# ---------------------------------------------------------------------------
WORK="$TMP/work"
mkdir -p "$WORK/src" || aster_fail "cannot create $WORK"

cat > "$WORK/fake-cxx" <<'FAKE'
#!/bin/sh
printf 'real-cxx' >> "$REAL_CXX_LOG"
for a in "$@"; do printf '|%s' "$a" >> "$REAL_CXX_LOG"; done
printf '\n' >> "$REAL_CXX_LOG"
out=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) out=$2; shift 2 ;;
        *) shift ;;
    esac
done
if [ -n "$out" ]; then printf 'fake-output\n' > "$out"; fi
exit 0
FAKE
chmod +x "$WORK/fake-cxx"

printf 'int main(void){return 0;}\n' > "$WORK/src/aster.cpp"
HASH=$(sha256sum "$WORK/src/aster.cpp" | awk '{print $1}') \
    || aster_fail "sha256sum failed"
printf 'cached-binary\n' > "$WORK/aster-bin"
chmod +x "$WORK/aster-bin"
: > "$WORK/real.log"

# cache ARGS...  Runs the wrapper from $WORK with the cache environment set.
cache() {
    ( cd "$WORK" && REAL_CXX="$WORK/fake-cxx" REAL_CXX_LOG="$WORK/real.log" \
        ASTER_BIN="$WORK/aster-bin" ASTER_SOURCE_HASH="$HASH" \
        sh "$HERE/lib/cxx-cache.sh" "$@" )
}

# expect_forward NAME ARGS...  A cache miss must reach the real compiler.
expect_forward() {
    name=$1
    shift
    : > "$WORK/real.log"
    if cache "$@"; then
        if [ -s "$WORK/real.log" ]; then
            pass "$name"
        else
            fail "$name (real compiler was not invoked)"
        fi
    else
        fail "$name (wrapper exited nonzero)"
    fi
}

rm -f "$WORK/out-hit"
: > "$WORK/real.log"
if cache -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror \
        src/aster.cpp -o out-hit; then
    if [ -s "$WORK/real.log" ]; then
        fail "cache hit builds src/aster.cpp without the compiler"
    elif cmp -s "$WORK/aster-bin" "$WORK/out-hit"; then
        pass "cache hit copies the strict binary and skips the compiler"
    else
        fail "cache hit produced output different from ASTER_BIN"
    fi
else
    fail "cache hit exited nonzero"
fi

: > "$WORK/real.log"
if cache -std=c++17 -O2 -Wall -Wextra -pedantic -Werror \
        src/aster.cpp -o /dev/null; then
    if [ -s "$WORK/real.log" ]; then
        fail "cache hit for /dev/null invoked the compiler"
    else
        pass "cache hit for /dev/null writes nothing"
    fi
else
    fail "cache hit for /dev/null exited nonzero"
fi

: > "$WORK/real.log"
if cache -std=c++17 -O2 src/aster.cpp -o "$WORK/aster-bin"; then
    if [ -s "$WORK/real.log" ]; then
        fail "cache hit targeting ASTER_BIN invoked the compiler"
    else
        pass "cache hit targeting ASTER_BIN is a no-op"
    fi
else
    fail "cache hit targeting ASTER_BIN exited nonzero"
fi

expect_forward "cache miss for a different optimization level" \
    -std=c++17 -O0 -Wall src/aster.cpp -o out-o0
expect_forward "cache miss for a static link" \
    -std=c++17 -O2 -static src/aster.cpp -o out-static
expect_forward "cache miss with debug info" \
    -std=c++17 -O2 -g src/aster.cpp -o out-g
expect_forward "cache miss with -c" \
    -std=c++17 -O2 -c src/aster.cpp -o out-c.o
expect_forward "cache miss with a preprocessor define" \
    -std=c++17 -O2 -DEXTRA=1 src/aster.cpp -o out-define
expect_forward "cache miss with a sanitizer" \
    -std=c++17 -O2 -fsanitize=address src/aster.cpp -o out-asan
expect_forward "cache miss for a different source" \
    -std=c++17 -O2 other.cpp -o out-other
expect_forward "cache miss for two translation units" \
    -std=c++17 -O2 src/aster.cpp other.cpp -o out-two
expect_forward "cache miss without -o" \
    -std=c++17 -O2 -fsyntax-only src/aster.cpp

printf 'int main(void){return 1;}\n' > "$WORK/src/aster.cpp"
expect_forward "cache miss when src/aster.cpp no longer matches the hash" \
    -std=c++17 -O2 src/aster.cpp -o out-mutated
printf 'int main(void){return 0;}\n' > "$WORK/src/aster.cpp"

: > "$WORK/real.log"
if ( cd "$WORK" && REAL_CXX="$WORK/fake-cxx" REAL_CXX_LOG="$WORK/real.log" \
        sh "$HERE/lib/cxx-cache.sh" -std=c++17 -O2 src/aster.cpp -o out-noenv ); then
    if [ -s "$WORK/real.log" ]; then
        pass "cache is disabled without ASTER_BIN or ASTER_SOURCE_HASH"
    else
        fail "cache was used without ASTER_BIN or ASTER_SOURCE_HASH"
    fi
else
    fail "cache-disabled run exited nonzero"
fi

# ---------------------------------------------------------------------------
# baseline.sh
# ---------------------------------------------------------------------------
BASE_TMP="$TMP/baseline"
mkdir -p "$BASE_TMP/src" "$BASE_TMP/tests/baseline/v9.9-dev" "$BASE_TMP/examples"
printf '%s\n' '#define ASTER_VERSION_STRING "9.9-dev"' > "$BASE_TMP/src/aster.cpp"
: > "$BASE_TMP/examples/foo.ast"
GOOD_SHA=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef

write_base() {
    printf '%s\n' "$@" > "$BASE_TMP/tests/baseline/v9.9-dev/example-hashes.txt"
}
write_base "foo.build-so $GOOD_SHA" "foo.build-elf FAILED"

check_baseline() {
    name=$1
    want_rc=$2
    want_text=$3
    out=$(cd "$BASE_TMP" && ASTER_BASELINE_ROOT=tests/baseline \
        sh -c '. "$1"; aster_baseline_file' sh "$HERE/lib/baseline.sh" 2>&1)
    rc=$?
    ok=1
    [ "$rc" -eq "$want_rc" ] || ok=0
    case "$out" in
        *"$want_text"*) : ;;
        *) ok=0 ;;
    esac
    if [ "$ok" -eq 1 ]; then
        pass "$name"
    else
        fail "$name (rc=$rc, wanted $want_rc; output: $out)"
    fi
}

check_baseline "baseline resolves the snapshot named by ASTER_VERSION_STRING" 0 \
    "tests/baseline/v9.9-dev/example-hashes.txt"

write_base "foo.build-so $GOOD_SHA" "foo.build-so $GOOD_SHA"
check_baseline "baseline rejects duplicate keys" 1 "duplicate keys"

write_base "foo.build-so deadbeef"
check_baseline "baseline rejects a malformed digest" 1 \
    "neither FAILED nor a 64-hex digest"

write_base "stale.build-so $GOOD_SHA"
check_baseline "baseline rejects a row whose example is gone" 1 \
    "missing example examples/stale.ast"

write_base "foo.build-so $GOOD_SHA"
mv "$BASE_TMP/tests/baseline/v9.9-dev" "$BASE_TMP/tests/baseline/v9.9-dev.off"
check_baseline "baseline fails when the version has no snapshot" 1 \
    "no frozen baseline for v9.9-dev"
mv "$BASE_TMP/tests/baseline/v9.9-dev.off" "$BASE_TMP/tests/baseline/v9.9-dev"

printf '%s\n' '/* no version here */' > "$BASE_TMP/src/aster.cpp"
check_baseline "baseline fails when ASTER_VERSION_STRING is missing" 1 \
    "cannot read ASTER_VERSION_STRING"
printf '%s\n' '#define ASTER_VERSION_STRING "9.9-dev"' > "$BASE_TMP/src/aster.cpp"

hardcoded=""
for f in "$HERE"/*.sh; do
    [ "$f" = "$HERE/ci-protocol-checks.sh" ] && continue
    if grep -q 'tests/baseline/v[0-9][^/]*/example-hashes.txt' "$f" 2>/dev/null; then
        hardcoded="$hardcoded $f"
    fi
done
if [ -z "$hardcoded" ]; then
    pass "no suite hardcodes a versioned baseline path"
else
    fail "suites hardcode a versioned baseline path:$hardcoded"
fi

# ---------------------------------------------------------------------------
# Coverage ratchet. The gate is only as wide as its suite list, and the
# corpus is only as wide as the examples and the frozen baseline. These are
# floors, not exact counts: they move up with the project, and moving one
# down is a reviewed source change. An unregistered *-checks.sh suite is an
# orphan — it exists and nobody runs it.
# ---------------------------------------------------------------------------
ROOT=$(CDPATH= cd -- "$HERE/.." && pwd) || aster_fail "cannot resolve the repository root"
registered=$(awk '/^DEFAULT_SUITES="/{f=1;next} f&&/^"$/{f=0} f' "$HERE/ci.sh" \
    | tr ' ' '\n' | grep -E '\.sh$' | LC_ALL=C sort -u)
suite_count=$(printf '%s\n' "$registered" | grep -c .)
examples=$(ls "$ROOT"/examples/*.ast 2>/dev/null | wc -l)
mutations=$(grep -l 'mutant' "$ROOT"/tests/*.sh 2>/dev/null | wc -l)
BASE=$(cd "$ROOT" && ASTER_BASELINE_ROOT=tests/baseline \
    sh -c '. "$1"; aster_baseline_file' sh "$ROOT/tests/lib/baseline.sh" 2>/dev/null)
rows=0
if [ -n "$BASE" ] && [ -f "$ROOT/$BASE" ]; then rows=$(wc -l < "$ROOT/$BASE"); fi
orphans=""
for f in "$ROOT"/tests/*-checks.sh; do
    b=$(basename "$f")
    printf '%s\n' "$registered" | grep -qxF "$b" || orphans="$orphans $b"
done
absent=""
for b in $registered; do
    [ -f "$ROOT/tests/$b" ] || absent="$absent $b"
done
if [ "$suite_count" -ge 115 ] && [ "$examples" -ge 120 ] && [ "$rows" -ge 360 ] \
        && [ "$mutations" -ge 30 ] && [ -z "$orphans" ] && [ -z "$absent" ]; then
    pass "coverage ratchet: $suite_count suites, $examples examples, $rows baseline rows, $mutations mutation suites, no orphans"
else
    fail "coverage ratchet: suites=$suite_count (floor 115), examples=$examples (floor 120), baseline_rows=$rows (floor 360), mutation_suites=$mutations (floor 30), unregistered:$orphans, missing:$absent"
fi

# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------
printf '\nci-protocol: %s checks passed, %s failed\n' "$PASSED" "$FAILED"
if [ "$FAILED" -ne 0 ]; then
    aster_fail "$FAILED protocol check(s) failed"
fi
exit "$ASTER_EXIT_PASS"
