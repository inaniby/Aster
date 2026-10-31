#!/bin/sh
# tests/lib/cxx-cache.sh — build the compiler once per CI run.
#
# tests/ci.sh exports CXX to this wrapper, ASTER_BIN to the one strict binary it
# built, and ASTER_SOURCE_HASH to the SHA-256 of src/aster.cpp.  A suite that
# asks for exactly that source with ordinary build flags gets the cached binary
# copied to its own -o path instead of recompiling 12,000 lines.  Every other
# invocation — a mutated copy of the source, -c, -g, sanitizers, alternate
# targets, or an unknown flag — is forwarded to the real compiler unchanged.
#
# This is deliberately conservative: a false cache hit would silently test the
# wrong compiler, so flags are allowlisted.  Only the documented strict build
# (-std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror) is served from cache;
# -O0/-O3, -static, -flto, sanitizers, extra defines and linker flags all opt
# out and pay the real build.

REAL_CXX=${REAL_CXX:-g++}

if [ -z "${ASTER_BIN:-}" ] || [ ! -x "$ASTER_BIN" ] || [ -z "${ASTER_SOURCE_HASH:-}" ]; then
    exec "$REAL_CXX" "$@"
fi

src=""
out=""
src_count=0
compile_only=0
unsafe=0
expect_out=0

for arg in "$@"; do
    if [ "$expect_out" -eq 1 ]; then
        out=$arg
        expect_out=0
        continue
    fi
    case "$arg" in
        -o) expect_out=1 ;;
        -o*) out=${arg#-o} ;;
        -c) compile_only=1 ;;
        # The only flags that cannot change which binary the suite expects.
        -std=c++17|-O2|-Wall|-Wextra|-Wpedantic|-pedantic|-Werror|-pipe)
            : ;;
        -*) unsafe=1 ;;
        *) src_count=$((src_count + 1)); src=$arg ;;
    esac
done

[ "$expect_out" -eq 0 ] || exec "$REAL_CXX" "$@"
[ "$compile_only" -eq 0 ] || exec "$REAL_CXX" "$@"
[ "$unsafe" -eq 0 ] || exec "$REAL_CXX" "$@"
[ "$src_count" -eq 1 ] || exec "$REAL_CXX" "$@"
[ -n "$out" ] || exec "$REAL_CXX" "$@"

case "$src" in
    src/aster.cpp|./src/aster.cpp|"$PWD/src/aster.cpp") : ;;
    *) exec "$REAL_CXX" "$@" ;;
esac

current_hash=$(sha256sum src/aster.cpp 2>/dev/null | awk '{print $1}')
[ "$current_hash" = "$ASTER_SOURCE_HASH" ] || exec "$REAL_CXX" "$@"

if [ "$out" = "/dev/null" ] || [ "$out" = "$ASTER_BIN" ]; then
    exit 0
fi

if cp "$ASTER_BIN" "$out" 2>/dev/null; then
    chmod +x "$out" 2>/dev/null || true
    exit 0
fi

exec "$REAL_CXX" "$@"
