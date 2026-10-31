#!/bin/sh
# tests/mutation-score-checks.sh — aggregate mutation census and score.
#
# The gate already fails when any mutant survives: every mutation-bearing
# suite asserts that its damaged compiler must change an observable answer.
# What was missing was an aggregate view. This suite counts the mutant builds
# that the standardized helpers declare (`mutate`, `build_mutant`,
# `mutate_and_check`), requires every declaring suite to contain at least one
# survivor assertion, and floors both the number of suites and the number of
# mutants. In a green run every declared mutant was therefore caught, so the
# census is also the denominator of a 100% mutation score; a suite that loses
# its kill assertion or its probes fails here before the gate can go green.
#
# The floor is a ratchet over the standardized corpus, not a count of every
# bespoke mutation layer in the tree (some suites build mutants by hand). It is
# deliberately just below the measured value: a reviewed change may raise it,
# a silent shrink fails.
set -eu
cd "$(dirname "$0")/.."
. tests/lib/verdict.sh

FLOOR_SUITES=24
FLOOR_MUTANTS=150
MIN_PER_SUITE=2

# A mutation suite is only evidence if it can fail when the mutant survives.
# These are the texts its failure path uses; the list is broad because the
# helpers grew independently, but every counted suite must match one.
KILL='went unnoticed|does not bite|does not see the rule|the case does not test|battery does not test|still (compiles|refuses|gives|accepts|matches|carries|produces|produced|trapped|refused)|not (the|a) (rule|check|fix)|probe is blind|did NOT diverge|did not diverge|mutation did not (remove|change|damage)|guard is stale|the fix is untested|refusal is untested'

printf '%s\n' '[1/2] Census of declared mutant builds'
total=0
suites=0
thin=""
blind=""
for f in tests/*-checks.sh; do
    # Calls use either an identifier or a quoted label as the first argument.
    n=$(grep -cE '^[[:space:]]*(mutate|build_mutant|mutate_and_check)[[:space:]]+["'"'"'$A-Za-z0-9_]' "$f" || true)
    [ "$n" -gt 0 ] || continue
    suites=$((suites + 1))
    total=$((total + n))
    printf '  %-44s %3d\n' "$(basename "$f")" "$n"
    [ "$n" -ge "$MIN_PER_SUITE" ] || thin="$thin $(basename "$f"):$n"
    if ! grep -qiE "$KILL" "$f"; then
        blind="$blind $(basename "$f")"
    fi
done

printf '%s\n' '[2/2] Aggregate score'
if [ -n "$blind" ]; then
    aster_fail "mutation suite(s) declare mutants but have no survivor assertion:$blind"
fi
if [ -n "$thin" ]; then
    aster_fail "mutation suite(s) below the $MIN_PER_SUITE-mutant floor:$thin"
fi
if [ "$suites" -lt "$FLOOR_SUITES" ] || [ "$total" -lt "$FLOOR_MUTANTS" ]; then
    aster_fail "mutation census too small: $suites suites (floor $FLOOR_SUITES), $total mutants (floor $FLOOR_MUTANTS)"
fi

printf 'PASS: mutation score: %s suites declare %s mutant builds (floors %s suites, %s mutants, %s per suite); a green gate means %s/%s caught (100%%)\n' \
    "$suites" "$total" "$FLOOR_SUITES" "$FLOOR_MUTANTS" "$MIN_PER_SUITE" "$total" "$total"
