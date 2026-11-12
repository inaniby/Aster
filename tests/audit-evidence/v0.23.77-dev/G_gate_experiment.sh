#!/bin/sh
# G-01 / G-02 / G-08 — gate-effectiveness experiment; fake suites live in /tmp only.
# Usage: sh G_gate_experiment.sh [repo-root]
R=${1:-/workspace/aster-v0.22.38-dev}
D=/tmp/auditv77_fake_suites
rm -rf "$D"; mkdir -p "$D"
printf '#!/bin/sh\nexit 0\n' > "$D/zero-assert.sh"
printf '#!/bin/sh\necho "SKIP: no oracle on this host"\nexit 77\n' > "$D/silent-skip.sh"
printf '#!/bin/sh\necho "SKIP: no oracle on this host"\nexit 0\n' > "$D/legacy-skip.sh"
chmod +x "$D"/*.sh
cd "$R" || exit 2
set +e
CI_SUITE_DIR="$D" CI_SUITES="zero-assert.sh silent-skip.sh legacy-skip.sh" \
    CI_SKIP_APK_GATE=1 sh tests/ci.sh
rc=$?
set -e
printf '\nCI_EXIT=%s\n' "$rc"
printf 'A green gate here means: a suite with zero assertions is PASS, two skipped\n'
printf 'suites do not fail the run, and all APK gates were skipped.\n'
