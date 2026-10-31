#!/bin/sh
# tests/lib/baseline.sh — resolve the frozen per-release byte baseline.
#
# Each release owns tests/baseline/v<version>/example-hashes.txt, where
# <version> is ASTER_VERSION_STRING in src/aster.cpp.  Suites compare against
# exactly that file: bumping the version without adding a snapshot is a hard
# failure, never a silent comparison against the previous release.  Old
# snapshots are immutable; a new release starts by copying the newest one and
# re-records only what its own round changes.
#
# Source from a suite that has already cd'd to the repository root:
#   . tests/lib/baseline.sh
#   BASE=$(aster_baseline_file)
#
# The helper never writes.  A missing snapshot is a release-process error:
#   mkdir -p tests/baseline/v<version>
#   cp tests/baseline/v<previous>/example-hashes.txt tests/baseline/v<version>/
#   # add this round's rows, run the affected suites, review the diff
#
# The format is one row per product:
#   <example>.<build-so|build-elf|build-obj_--pic> <sha256|FAILED>

ASTER_BASELINE_ROOT=${ASTER_BASELINE_ROOT:-tests/baseline}

# Print the version named by the compiler's single source of truth.
aster_baseline_version() {
    sed -n 's/^#define ASTER_VERSION_STRING "\([^"]*\)".*$/\1/p' src/aster.cpp | head -1
}

# aster_baseline_check FILE
# Validates shape, mode suffixes, values, duplicate keys, and that each row
# names an example that still exists.  Returns 1 on the first category of
# error (after printing every line that failed).
aster_baseline_check() {
    _file=$1
    if [ ! -s "$_file" ]; then
        printf 'FAIL: baseline %s is missing or empty\n' "$_file" >&2
        return 1
    fi

    _lineno=0
    _bad=0
    while IFS= read -r _line || [ -n "$_line" ]; do
        _lineno=$((_lineno + 1))
        # shellcheck disable=SC2086
        set -- $_line
        if [ "$#" -ne 2 ]; then
            printf 'FAIL: %s:%d: expected "<name>.<mode> <sha256|FAILED>"\n' \
                "$_file" "$_lineno" >&2
            _bad=1
            continue
        fi
        _key=$1
        _value=$2

        case "$_key" in
            *.build-so) _base=${_key%.build-so} ;;
            *.build-elf) _base=${_key%.build-elf} ;;
            *.build-obj_--pic) _base=${_key%.build-obj_--pic} ;;
            *)
                printf 'FAIL: %s:%d: unknown mode in key %s\n' "$_file" "$_lineno" "$_key" >&2
                _bad=1
                continue
                ;;
        esac
        if [ -z "$_base" ]; then
            printf 'FAIL: %s:%d: empty example name\n' "$_file" "$_lineno" >&2
            _bad=1
        elif [ -d examples ] && [ ! -f "examples/$_base.ast" ]; then
            printf 'FAIL: %s:%d: row names missing example examples/%s.ast\n' \
                "$_file" "$_lineno" "$_base" >&2
            _bad=1
        fi

        if [ "$_value" != "FAILED" ]; then
            if [ "${#_value}" -ne 64 ]; then
                printf 'FAIL: %s:%d: value is neither FAILED nor a 64-hex digest\n' \
                    "$_file" "$_lineno" >&2
                _bad=1
            else
                case "$_value" in
                    *[!0-9a-f]*)
                        printf 'FAIL: %s:%d: digest contains non-hex characters\n' \
                            "$_file" "$_lineno" >&2
                        _bad=1
                        ;;
                esac
            fi
        fi
    done < "$_file"

    _dups=$(cut -d' ' -f1 "$_file" | LC_ALL=C sort | uniq -d)
    if [ -n "$_dups" ]; then
        printf 'FAIL: %s: duplicate keys: %s\n' "$_file" "$_dups" >&2
        _bad=1
    fi

    return "$_bad"
}

# aster_baseline_file
# Prints the frozen baseline for the version in src/aster.cpp, or exits 1.
aster_baseline_file() {
    _version=$(aster_baseline_version)
    if [ -z "$_version" ]; then
        printf 'FAIL: cannot read ASTER_VERSION_STRING from src/aster.cpp\n' >&2
        exit 1
    fi
    _file="$ASTER_BASELINE_ROOT/v$_version/example-hashes.txt"
    if [ ! -f "$_file" ]; then
        printf 'FAIL: no frozen baseline for v%s: %s\n' "$_version" "$_file" >&2
        printf 'A version bump needs its own snapshot; copy the newest existing one and re-record deliberately.\n' >&2
        exit 1
    fi
    if ! aster_baseline_check "$_file"; then
        printf 'FAIL: frozen baseline for v%s is malformed\n' "$_version" >&2
        exit 1
    fi
    printf '%s\n' "$_file"
}
