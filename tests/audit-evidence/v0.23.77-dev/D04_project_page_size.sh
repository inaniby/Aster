#!/bin/sh
# D-04 — reproduce the dead `page-size` setting in aster.proj.
# Usage: sh D04_project_page_size.sh <aster-binary>
# Everything is created under /tmp; the working tree is never touched.
A=${1:-/tmp/aster_audit}
W=/tmp/auditv77_pagesize
rm -rf "$W"; mkdir -p "$W/keys"
export ASTER_KEY_DIR="$W/keys"
cd "$W" || exit 2
"$A" new --apk p16 >/dev/null 2>&1 || exit 2
printf 'page-size 16384\n' >> p16/aster.proj
printf '=== aster.proj (note page-size) ===\n'; tail -2 p16/aster.proj
printf '\n=== build with NO CLI page-size ===\n'
(cd p16 && "$A" build >/dev/null 2>&1); echo "rc=$?"
printf 'meta flags : '; grep -rh '^flags' p16/build/.cache/*.meta
SO=$(find p16 -name '*.so' | head -1)
printf 'p_align    : '; aarch64-linux-gnu-readelf -lW "$SO" | awk '/LOAD/{print $NF; exit}'
printf '\n=== control: CLI --page-size 16384 ===\n'
(cd p16 && "$A" build --no-cache --page-size 16384 >/dev/null 2>&1); echo "rc=$?"
printf 'p_align    : '; aarch64-linux-gnu-readelf -lW "$SO" | awk '/LOAD/{print $NF; exit}'
printf '\nExpect 0x4000 in both; v0.23.77-dev gives 0x1000 for the first.\n'
