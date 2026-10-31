#!/bin/sh
# v0.23.13-dev: version/doc-sync regression checks.
#
# The version string is one of the few things in this project that is written
# down in more than one place, and it drifted once: the usage banner carried
# its own copy and still read v0.23.12-dev while the binary was v0.23.13-dev.
# Nothing caught it, because nothing looked. These checks are the thing that
# looks. They need no compiler, no qemu and no toolchain, so they run on every
# runner — which is the point, since a version is exactly the kind of detail a
# skipped suite would let rot.
set -eu
cd "$(dirname "$0")/.."

# The single source of truth: the macro both kVersion and the usage banner
# expand. It is read out of the source rather than out of the binary so that a
# banner that disagrees with the source is a finding, not the thing measured.
VER=$(sed -n 's/^#define ASTER_VERSION_STRING "\(.*\)"$/\1/p' src/aster.cpp | head -1)
if [ -z "$VER" ]; then
    echo "FAIL: could not read ASTER_VERSION_STRING from src/aster.cpp" >&2
    exit 1
fi

# 1) The banner the user actually sees must name that version.
banner=$(./aster --help 2>&1 | head -1)
case "$banner" in
    *"$VER"*) : ;;
    *) echo "FAIL: usage banner '$banner' does not name $VER" >&2; exit 1 ;;
esac
echo "OK: usage banner names the version the binary was built with ($VER)"

# 2) kVersion must be *that macro*, not a second literal someone has to remember
#    to edit — which is exactly how the banner came to name a version the binary
#    did not have.
grep -q '^constexpr const char\* kVersion = ASTER_VERSION_STRING;$' src/aster.cpp \
    || { echo "FAIL: kVersion is no longer defined from ASTER_VERSION_STRING" >&2; exit 1; }
echo "OK: kVersion expands the shared version macro"

# CMake carries the same version for its project() metadata. It is the one
# build system file that names a version, and a bump that forgets it would
# ship a CMake project claiming an older release than the binary it builds.
cmake_ver=$(sed -n 's/^project(aster_bootstrap VERSION \([0-9][0-9.]*\) .*/\1/p' \
    CMakeLists.txt | head -1)
expect_ver=${VER%-dev}
if [ -z "$cmake_ver" ]; then
    echo "FAIL: could not read the project version from CMakeLists.txt" >&2
    exit 1
fi
if [ "$cmake_ver" != "$expect_ver" ]; then
    echo "FAIL: CMakeLists.txt project version is $cmake_ver, source is $expect_ver" >&2
    exit 1
fi
echo "OK: CMakeLists.txt project version matches the source ($expect_ver)"

# 3) The version literal must appear exactly once in the source: in the macro
#    itself. A second copy is a second chance to forget to update it.
# Quoted, because the version is also mentioned in comments ("// v0.23.13-dev:
# ...") and those are not copies of the literal -- only a `"..."` occurrence is.
count=$(grep -c "\"$VER\"" src/aster.cpp || true)
if [ "$count" != "1" ]; then
    echo "FAIL: the literal \"$VER\" appears $count times in src/aster.cpp; it must appear once (the shared macro)" >&2
    exit 1
fi
echo "OK: the version literal has exactly one home in the source"

# 3) README's title must carry it — the first thing anyone reads.
if ! head -1 README.md | grep -q "$VER"; then
    echo "FAIL: README.md title does not name $VER: $(head -1 README.md)" >&2
    exit 1
fi
echo "OK: README.md title names $VER"

# The architecture map states the size of the translation unit. It once said
# "~2.5k lines" while the file had grown past 13k; a stale size is how a reader
# concludes the document is about a compiler that no longer exists. Keep the
# claim within 10% of the real file so a major change forces a doc review.
arch_k=$(sed -n 's/^One C++17 translation unit, ~\([0-9][0-9]*\)k lines,.*/\1/p' \
    ARCHITECTURE.md | head -1)
if [ -z "$arch_k" ]; then
    echo "FAIL: could not read the line-count claim from ARCHITECTURE.md" >&2
    exit 1
fi
actual_lines=$(wc -l < src/aster.cpp | tr -d ' ')
arch_lo=$((arch_k * 900))
arch_hi=$((arch_k * 1100))
if [ "$actual_lines" -lt "$arch_lo" ] || [ "$actual_lines" -gt "$arch_hi" ]; then
    echo "FAIL: ARCHITECTURE.md claims ~${arch_k}k lines; src/aster.cpp has $actual_lines (allowed ${arch_lo}-${arch_hi})" >&2
    exit 1
fi
echo "OK: ARCHITECTURE.md line-count claim (~${arch_k}k) matches src/aster.cpp ($actual_lines)"

# 4) VERSION_HISTORY's newest entry must be this version (its first heading).
top=$(grep -m1 '^## ' VERSION_HISTORY.md)
case "$top" in
    *"$VER"*) : ;;
    *) echo "FAIL: newest VERSION_HISTORY.md entry is '$top', not $VER" >&2; exit 1 ;;
esac
echo "OK: VERSION_HISTORY.md's newest entry is $VER"

# 5) Every shipped version ships its own validation report (named with the
#    version's own "v" prefix, as every report in this project is).
if [ ! -f "VALIDATION-v$VER.md" ]; then
    echo "FAIL: VALIDATION-v$VER.md does not exist" >&2
    exit 1
fi
echo "OK: VALIDATION-v$VER.md exists"

echo "=== version checks: ALL PASSED ==="
