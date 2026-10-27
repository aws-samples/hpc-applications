#!/bin/bash
# =============================================================================
# Tests for model-fixes.sh (the documented input changes for current releases)
# =============================================================================
# The fixtures hold the exact text each fix edits, as the public models ship it:
# the TopCrunch 3cars and neon pfiles, 3cars' revolute joints and the two Camry v5a
# solids. Context lines around them are synthetic.
#
#   ./tests/test-model-fixes.sh
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIX="${HERE}/fixtures"
FIXES="${HERE}/../model-fixes.sh"

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"; fail=$((fail+1)); }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$3" "$2"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

echo "== pfile-region =="
bash "${FIXES}" pfile-region "${FIX}/pfile-3cars-32" "${TMP}/p32" >/dev/null
is "3cars pfile_32+: silist and transformation in a region" "$(sed -n 2p "${TMP}/p32")" \
    "decomp { region { silist 6 sy 48 } sy 48 }"
is "3cars pfile_32+: the other lines unchanged" "$(sed -n '1p;3p' "${TMP}/p32")" "$(sed -n '1p;3p' "${FIX}/pfile-3cars-32")"
bash "${FIXES}" pfile-region "${FIX}/pfile-3cars-2" "${TMP}/p2" >/dev/null
is "3cars pfile_2: no transformation" "$(sed -n 2p "${TMP}/p2")" "decomp { region { silist 6 } }"
bash "${FIXES}" pfile-region "${FIX}/pfile-neon" "${TMP}/pn" >/dev/null
is "neon pfile" "$(sed -n 2p "${TMP}/pn")" "decomp { region { silist 1 sy 200.0 } sy 200.0 }"
bash "${FIXES}" pfile-region "${TMP}/p32" "${TMP}/again" >/dev/null 2>&1
is "a rewritten pfile is refused (no silist outside a region left)" "$?" "1"
bash "${FIXES}" pfile-region "${FIX}/pfile-car2car" "${TMP}/pc" >/dev/null 2>&1
is "a pfile without a decomp section is refused" "$?" "1"

echo "== 3cars-joint27 =="
bash "${FIXES}" 3cars-joint27 "${FIX}/3cars-joints.k" "${TMP}/j.k" >/dev/null
if cmp -s "${TMP}/j.k" "${FIX}/3cars-joints.expected.k"; then
    ok "joint 27 becomes a spherical joint on its first two nodes; the other joint unchanged"
else
    bad "joint27" "$(cat "${FIX}/3cars-joints.expected.k")" "$(cat "${TMP}/j.k")"
fi
bash "${FIXES}" 3cars-joint27 "${TMP}/j.k" "${TMP}/j2.k" >/dev/null 2>&1
is "an edited deck is refused" "$?" "1"

echo "== camry-meshfix =="
bash "${FIXES}" camry-meshfix "${FIX}/camry-solids.key" "${TMP}/c.key" >/dev/null
if cmp -s "${TMP}/c.key" "${FIX}/camry-solids.expected.key"; then
    ok "wedge 2028692 removed, hex 2033993 made a wedge; the other solids unchanged"
else
    bad "camry-meshfix" "$(cat "${FIX}/camry-solids.expected.key")" "$(cat "${TMP}/c.key")"
fi
bash "${FIXES}" camry-meshfix "${FIX}/camry-shells.key" "${TMP}/s.key" >/dev/null 2>&1
is "the same lines outside *ELEMENT_SOLID are refused" "$?" "1"
bash "${FIXES}" camry-meshfix "${TMP}/c.key" "${TMP}/c2.key" >/dev/null 2>&1
is "an edited mesh is refused" "$?" "1"

echo "== never in place, never a partial file =="
cp "${FIX}/camry-solids.key" "${TMP}/in.key"
bash "${FIXES}" camry-meshfix "${TMP}/in.key" "${TMP}/in.key" >/dev/null 2>&1
is "output = input: refused" "$?/$(cmp -s "${TMP}/in.key" "${FIX}/camry-solids.key" && echo unchanged)" "1/unchanged"
ln -s "${TMP}/in.key" "${TMP}/link.key"
bash "${FIXES}" camry-meshfix "${TMP}/in.key" "${TMP}/link.key" >/dev/null 2>&1
is "output = a link to the input: refused" "$?/$(cmp -s "${TMP}/in.key" "${FIX}/camry-solids.key" && echo unchanged)" "1/unchanged"
bash "${FIXES}" camry-meshfix "${FIX}/camry-shells.key" "${TMP}/none.key" >/dev/null 2>&1
is "a refused fix leaves no output file" "$([ -e "${TMP}/none.key" ] && echo present || echo absent)" "absent"
is "no temporary file left" "$(find "${TMP}" -name '*.key.*' | grep -c .)" "0"
bash "${FIXES}" no-such-fix "${FIX}/camry-solids.key" "${TMP}/x" >/dev/null 2>&1
is "an unknown fix: usage, exit 2" "$?" "2"

echo
echo "model-fixes: ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
