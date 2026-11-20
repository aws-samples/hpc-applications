#!/bin/bash
# =============================================================================
# The iteration count of the benchmark scripts (END_TIME, ../README.md,
# "Iterations"), each script run end to end with the stubs of stubs.sh. What it
# pins:
#   * by default the run's controlDict sets endTime 200, and simpleFoam runs to
#     it; the case's own controlDict is left as it ships (endTime 4000);
#   * END_TIME=4000 runs the case as it ships, END_TIME=37 runs 37 iterations,
#     and an empty END_TIME is the default;
#   * an END_TIME that is not a whole number of iterations, 1 or more, is
#     refused before the run directory is made, and nothing runs;
#   * a controlDict with no endTime line is refused before the decomposition.
#
#   apps/OpenFoam/tests/test-iterations.sh
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=stubs.sh
source "${HERE}/stubs.sh"

end_time() { awk '/^[[:space:]]*endTime[[:space:]]/ {gsub(";", "", $2); print $2; exit}' "$1" 2>/dev/null; }
last_time() { awk '/^Time = / {t = $3} END {print t}' "${RUN}/log.solver" 2>/dev/null; }
NOEND="${STUBS}/no-endtime/occDrivAerStaticMesh"
make_case "${NOEND}"
sed -i '/endTime/d' "${NOEND}/system/controlDict"

job=300
for s in "${SCRIPTS[@]}"; do
    echo "== ${s} =="
    if skip_arm_here "${s}"; then
        skipt "${s}" "this host has a module system, which the Arm launcher loads, and which could put a real MPI first in PATH"
        continue
    fi

    job=$((job + 1)); run_script "${s}" "${job}"
    completes "by default" "${job}"
    check "by default: endTime 200 in the run's controlDict" 200 "$(end_time "${RUN}/system/controlDict")"
    check "by default: simpleFoam runs to iteration 200" 200 "$(last_time)"
    check "by default: the case's own controlDict is left as it ships" 4000 "$(end_time "${CASE}/system/controlDict")"

    for n in 4000 37 ""; do
        want="${n:-200}"
        job=$((job + 1)); run_script "${s}" "${job}" END_TIME="${n}"
        completes "END_TIME='${n}'" "${job}"
        check "END_TIME='${n}': endTime ${want} in the run's controlDict" "${want}" "$(end_time "${RUN}/system/controlDict")"
        check "END_TIME='${n}': simpleFoam runs to iteration ${want}" "${want}" "$(last_time)"
    done

    for v in abc 0 -5 2.5 0200 "20 0"; do
        job=$((job + 1)); run_script "${s}" "${job}" END_TIME="${v}"
        check "END_TIME='${v}': refused (exit 1)" 1 "${RC}"
        has "END_TIME='${v}': ERROR" "ERROR: END_TIME must be a whole number of iterations, 1 or more (got: ${v})"
        check "END_TIME='${v}': no run directory" "" "${RUN}"
        check "END_TIME='${v}': nothing runs" "0 0" "$(decompositions "${job}") $(launches "${job}" simpleFoam)"
    done

    job=$((job + 1)); run_script "${s}" "${job}" CASE_SRC="${NOEND}"
    check "a controlDict with no endTime: refused (exit 1)" 1 "${RC}"
    has "a controlDict with no endTime: ERROR" "ERROR: could not set endTime 200 in system/controlDict"
    check "a controlDict with no endTime: no decomposePar" 0 "$(decompositions "${job}")"
done

finish "iterations"
