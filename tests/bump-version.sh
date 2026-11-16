#!/bin/sh
# bump-version.sh — the mechanical half of a release bump.
#
# Scripted from the real bump commit a53ca33 (0.23.79-dev -> 0.23.82-dev,
# 26 files). It moves only the mechanical version positions:
#
#   src/aster.cpp                  #define ASTER_VERSION_STRING "X"
#   CMakeLists.txt                 project(aster_bootstrap VERSION X.Y.Z ...)
#   README.md                      # Aster Bootstrap Compiler vX
#   docs/language-reference.md     **Applies to: vX** ...
#   21 resident suites             grep -qF '#define ASTER_VERSION_STRING "X"' ...
#   tests/baseline/vX/             new frozen baseline, copied from the latest
#
# The exact spellings above are the ones a53ca33 actually changed — the
# guard pin is one grep line per suite (the error message on the next line
# still names an older version and is NOT touched), the README body keeps
# naming the previous release in its history paragraphs (only the title
# moves), and the baseline copy is byte-identical (393 lines at a53ca33).
# Every replacement is counted before it is made: a file that contains the
# old spelling zero times or more than once aborts the run.
#
# The script deliberately does NOT write narrative: VERSION_HISTORY.md and
# VALIDATION-v<new>.md are the human's job. It prints where they go at the
# end. The one-sentence summary argument is only echoed back as the
# suggested commit message — it is never written into any file.
#
# Usage:
#   sh tests/bump-version.sh [--dry-run] <new-version> [one-sentence summary]
#   sh tests/bump-version.sh selftest [fake-version]   # default 0.23.99-dev
#
# <new-version> looks like 0.23.83-dev. --dry-run prints every planned
# change and writes nothing. selftest copies the worktree to /tmp, bumps
# the copy to a fake version, and verifies the pins and the baseline there;
# the real worktree is never bumped by a selftest.
set -eu
cd "$(dirname "$0")/.."
ROOT=$PWD

# The 21 suites whose version guard pin a53ca33 re-pointed. Listed
# explicitly, not globbed: a renamed suite must fail loudly here instead
# of silently dropping out of the bump.
GUARD_SUITES='alias-const-checks.sh cast-conversions-checks.sh char-checks.sh
const-fold-u64-checks.sh elf-metadata-checks.sh embed-align-checks.sh
enum-checks.sh eval-order-checks.sh frame-slot-contract-checks.sh
front-sema-checks.sh integer-cast-checks.sh layout-boundary-checks.sh
link-project-contract-checks.sh literals-checks.sh
section-align-contract-checks.sh signedness-checks.sh stack-arg-abi-checks.sh
stride-scale-checks.sh type-strictness-checks.sh union-checks.sh void-checks.sh'

die() { echo "FAIL: $*" >&2; exit 1; }

# Escape a needle for the pattern half of a sed s||| command (BRE: '.',
# '*', '[', ']', '^', '$' and '\' are active; '(' and ')' are literal in
# BRE and must NOT be escaped — '\(' would open a group). The replacement
# half needs different escaping ('&' and '\' only), so it has its own.
esc_pat() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/\./\\./g' -e 's/\*/\\*/g' -e 's/\[/\\[/g' -e 's/\]/\\]/g' -e 's/\^/\\^/g' -e 's/\$/\\$/g'; }
esc_rep() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/&/\\&/g'; }

# check_once FILE NEEDLE — the preflight half of replace_once: count only,
# write nothing. do_bump runs this over every needle before any file is
# touched, so a bad count aborts with the tree untouched instead of
# half-bumped.
check_once() {
    file=$1; needle=$2
    count=$(grep -cF -- "$needle" "$file" || true)
    [ "$count" = "1" ] || die "$file: expected exactly 1 occurrence of '$needle', found $count"
}

# replace_once FILE OLD-NEEDLE NEW-NEEDLE
# Count first: exactly one occurrence, or abort. In dry-run mode only
# report; otherwise rewrite that one occurrence in place.
replace_once() {
    file=$1; old=$2; new=$3
    count=$(grep -cF -- "$old" "$file" || true)
    [ "$count" = "1" ] || die "$file: expected exactly 1 occurrence of '$old', found $count"
    if [ "$DRY_RUN" = "1" ]; then
        printf 'would change %s:\n  - %s\n  + %s\n' "$file" "$old" "$new"
    else
        sed -i "s|$(esc_pat "$old")|$(esc_rep "$new")|" "$file"
        printf 'changed %s\n' "$file"
    fi
}

# current_version — read the old version out of the source, never hardcoded,
# so the same script bumps 0.23.82-dev -> 0.23.83-dev and the next one after.
current_version() {
    ver=$(sed -n 's/^#define ASTER_VERSION_STRING "\(.*\)"$/\1/p' src/aster.cpp | head -1)
    [ -n "$ver" ] || die "could not read ASTER_VERSION_STRING from src/aster.cpp"
    printf '%s' "$ver"
}

# latest_baseline — the newest frozen baseline directory, e.g. v0.23.82-dev.
latest_baseline() {
    ls -d tests/baseline/v*-dev 2>/dev/null | sort -V | tail -n 1 \
        | sed 's|tests/baseline/||'
}

do_bump() {
    NEW=$1
    SUMMARY=${2:-}
    printf '%s' "$NEW" | grep -qEq '^[0-9]+\.[0-9]+\.[0-9]+-dev$' \
        || die "bad version '$NEW': expected e.g. 0.23.83-dev"
    OLD=$(current_version)
    [ "$NEW" != "$OLD" ] || die "new version $NEW is the current version"
    OLD_BASE=${OLD%-dev}
    NEW_BASE=${NEW%-dev}
    OLD_BASELINE=$(latest_baseline)
    [ -n "$OLD_BASELINE" ] || die "no tests/baseline/v*-dev directory found"
    [ "$OLD_BASELINE" = "v$OLD" ] || die "latest baseline is $OLD_BASELINE, but the source version is $OLD — resolve the drift before bumping"
    NEW_BASELINE="v$NEW"
    [ ! -e "tests/baseline/$NEW_BASELINE" ] || die "tests/baseline/$NEW_BASELINE already exists"

    printf 'bump %s -> %s%s\n' "$OLD" "$NEW" "$([ "$DRY_RUN" = "1" ] && printf ' (dry run — nothing will be written)')"

    # Preflight: every needle must occur exactly once, checked before any
    # write, so a drift aborts with the tree untouched.
    check_once src/aster.cpp "#define ASTER_VERSION_STRING \"$OLD\""
    check_once CMakeLists.txt "project(aster_bootstrap VERSION $OLD_BASE LANGUAGES CXX)"
    check_once README.md "# Aster Bootstrap Compiler v$OLD"
    check_once docs/language-reference.md "**Applies to: v$OLD**"
    for suite in $GUARD_SUITES; do
        check_once "tests/$suite" \
            "grep -qF '#define ASTER_VERSION_STRING \"$OLD\"' src/aster.cpp"
    done

    replace_once src/aster.cpp \
        "#define ASTER_VERSION_STRING \"$OLD\"" \
        "#define ASTER_VERSION_STRING \"$NEW\""
    replace_once CMakeLists.txt \
        "project(aster_bootstrap VERSION $OLD_BASE LANGUAGES CXX)" \
        "project(aster_bootstrap VERSION $NEW_BASE LANGUAGES CXX)"
    replace_once README.md \
        "# Aster Bootstrap Compiler v$OLD" \
        "# Aster Bootstrap Compiler v$NEW"
    replace_once docs/language-reference.md \
        "**Applies to: v$OLD**" \
        "**Applies to: v$NEW**"
    for suite in $GUARD_SUITES; do
        replace_once "tests/$suite" \
            "grep -qF '#define ASTER_VERSION_STRING \"$OLD\"' src/aster.cpp" \
            "grep -qF '#define ASTER_VERSION_STRING \"$NEW\"' src/aster.cpp"
    done

    # New frozen baseline: a verbatim copy of the latest one. The version
    # string is not embedded in plain build outputs (only the DWARF -g
    # producer and stdout banners), so at a53ca33 all 393 rows reproduced
    # byte-identically; the copy below is checked, not assumed.
    SRC_HASHES="tests/baseline/$OLD_BASELINE/example-hashes.txt"
    DST_DIR="tests/baseline/$NEW_BASELINE"
    DST_HASHES="$DST_DIR/example-hashes.txt"
    [ -f "$SRC_HASHES" ] || die "$SRC_HASHES does not exist"
    src_lines=$(wc -l < "$SRC_HASHES" | tr -d ' ')
    if [ "$DRY_RUN" = "1" ]; then
        printf 'would create %s (copy of %s, %s lines)\n' "$DST_HASHES" "$SRC_HASHES" "$src_lines"
    else
        mkdir "$DST_DIR"
        cp "$SRC_HASHES" "$DST_HASHES"
        dst_lines=$(wc -l < "$DST_HASHES" | tr -d ' ')
        [ "$dst_lines" = "$src_lines" ] || die "$DST_HASHES has $dst_lines lines, source has $src_lines"
        cmp -s "$SRC_HASHES" "$DST_HASHES" || die "$DST_HASHES differs from $SRC_HASHES"
        printf 'created %s (%s lines, byte-identical to %s)\n' "$DST_HASHES" "$dst_lines" "$SRC_HASHES"
    fi

    if [ "$DRY_RUN" = "1" ]; then
        printf 'dry run done: no file was written.\n'
        return 0
    fi
    printf 'bump %s -> %s done: 4 version positions, 21 guard pins, 1 baseline.\n' "$OLD" "$NEW"
    printf 'Narrative is yours, not this script'"'"'s — write it in:\n'
    printf '  - VERSION_HISTORY.md (new top entry for v%s)\n' "$NEW"
    printf '  - VALIDATION-v%s.md (the validation report for this release)\n' "$NEW"
    printf 'Then review the diff, run: sh tests/bump-version.sh selftest\n'
    if [ -n "$SUMMARY" ]; then
        printf 'Suggested commit message:\n  Bump version to v%s\n\n  %s\n' "$NEW" "$SUMMARY"
    else
        printf 'Suggested commit message: Bump version to v%s\n' "$NEW"
    fi
}

# selftest [FAKE-VERSION] — bump a throwaway copy and verify it.
# The fake version defaults to 0.23.99-dev and never touches this worktree.
do_selftest() {
    FAKE=${1:-0.23.99-dev}
    printf '%s' "$FAKE" | grep -qEq '^[0-9]+\.[0-9]+\.[0-9]+-dev$' \
        || die "bad fake version '$FAKE': expected e.g. 0.23.99-dev"
    OLD=$(current_version)
    [ "$FAKE" != "$OLD" ] || die "fake version $FAKE is the current version"
    TMP=$(mktemp -d /tmp/aster-bump-selftest.XXXXXX)
    trap 'rm -rf "$TMP"' EXIT INT TERM
    printf 'selftest: copying worktree to %s\n' "$TMP"
    cp -a "$ROOT/." "$TMP/"
    rm -rf "$TMP/.git"
    cd "$TMP"

    # 1) --dry-run must not write anything.
    before=$(find . -type f ! -path './.git/*' -exec md5sum {} + | sort -k2)
    DRY_RUN=1 sh tests/bump-version.sh --dry-run "$FAKE" "selftest fake bump" > "$TMP/dryrun.log"
    after=$(find . -type f ! -path './.git/*' -exec md5sum {} + | sort -k2)
    # dryrun.log itself is new, so compare excluding it.
    after_wo_log=$(printf '%s\n' "$after" | grep -v 'dryrun.log' || true)
    [ "$before" = "$after_wo_log" ] || die "dry-run changed files in the copy"
    grep -q "would change src/aster.cpp" "$TMP/dryrun.log" || die "dry-run output did not list src/aster.cpp"
    grep -q "would create tests/baseline/v$FAKE/example-hashes.txt" "$TMP/dryrun.log" \
        || die "dry-run output did not list the new baseline"
    echo "OK: --dry-run lists the bump and writes nothing"

    # 2) The real bump inside the copy.
    DRY_RUN=0 sh tests/bump-version.sh "$FAKE" "selftest fake bump" > "$TMP/bump.log"
    echo "OK: bump to $FAKE ran in the copy"

    # 3) The four version positions name the fake version, and only it.
    grep -qF "#define ASTER_VERSION_STRING \"$FAKE\"" src/aster.cpp \
        || die "ASTER_VERSION_STRING is not $FAKE in the copy"
    grep -qF "project(aster_bootstrap VERSION ${FAKE%-dev} LANGUAGES CXX)" CMakeLists.txt \
        || die "CMakeLists.txt project version is not ${FAKE%-dev} in the copy"
    head -1 README.md | grep -qF "# Aster Bootstrap Compiler v$FAKE" \
        || die "README.md title is not v$FAKE in the copy"
    grep -qF "**Applies to: v$FAKE**" docs/language-reference.md \
        || die "language-reference.md 'Applies to' is not v$FAKE in the copy"
    echo "OK: ASTER_VERSION_STRING, CMake, README title, 'Applies to' all name $FAKE"

    # 4) All 21 guard pins point at the fake version; none still names old.
    pins=0
    for suite in $GUARD_SUITES; do
        n=$(grep -cF "grep -qF '#define ASTER_VERSION_STRING \"$FAKE\"' src/aster.cpp" "tests/$suite" || true)
        [ "$n" = "1" ] || die "tests/$suite: expected 1 pin for $FAKE, found $n"
        old_n=$(grep -cF "grep -qF '#define ASTER_VERSION_STRING \"$OLD\"' src/aster.cpp" "tests/$suite" || true)
        [ "$old_n" = "0" ] || die "tests/$suite: still pins $OLD"
        pins=$((pins + 1))
    done
    echo "OK: $pins/21 guard pins name $FAKE, 0 still name $OLD"

    # 5) The new baseline exists with the same row count as the source.
    [ -f "tests/baseline/v$FAKE/example-hashes.txt" ] \
        || die "tests/baseline/v$FAKE/example-hashes.txt missing in the copy"
    new_lines=$(wc -l < "tests/baseline/v$FAKE/example-hashes.txt" | tr -d ' ')
    old_lines=$(wc -l < "tests/baseline/v$OLD/example-hashes.txt" | tr -d ' ')
    [ "$new_lines" = "$old_lines" ] \
        || die "new baseline has $new_lines lines, source has $old_lines"
    cmp -s "tests/baseline/v$FAKE/example-hashes.txt" "tests/baseline/v$OLD/example-hashes.txt" \
        || die "new baseline differs from the source baseline"
    echo "OK: tests/baseline/v$FAKE/example-hashes.txt exists, $new_lines lines, byte-identical to v$OLD"

    # NOTE: tests/version-checks.sh is deliberately NOT the selftest gate.
    # It also demands a freshly built ./aster, a VALIDATION-v<new>.md and a
    # VERSION_HISTORY.md top entry naming the new version — none of which
    # a53ca33 produced, and none of which a mechanical bump can produce.
    # Those are the human's narrative steps in CONTRIBUTING.md; the pins
    # and the baseline above are this script's whole scope.
    echo "=== bump-version selftest: ALL PASSED (fake $FAKE, copy removed) ==="
}

DRY_RUN=0
case "${1:-}" in
    selftest)
        shift
        do_selftest "${1:-0.23.99-dev}"
        ;;
    --dry-run)
        DRY_RUN=1
        shift
        [ $# -ge 1 ] || die "usage: sh tests/bump-version.sh [--dry-run] <new-version> [summary]"
        do_bump "$1" "${2:-}"
        ;;
    --help|-h)
        sed -n '1,30p' "$0" | sed 's/^# \?//'
        ;;
    '')
        die "usage: sh tests/bump-version.sh [--dry-run] <new-version> [summary] | selftest [fake-version]"
        ;;
    -*)
        die "unknown option '$1'"
        ;;
    *)
        [ $# -ge 1 ] || die "usage: sh tests/bump-version.sh [--dry-run] <new-version> [summary]"
        do_bump "$1" "${2:-}"
        ;;
esac
