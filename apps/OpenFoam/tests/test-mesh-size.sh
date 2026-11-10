#!/bin/bash
# =============================================================================
# What the benchmark scripts record about the case (../README.md, "Benchmark"),
# each script run end to end with the stubs of stubs.sh. What it pins:
#   * the mesh is the one CASE_SRC holds, from the cell count in the header of
#     constant/polyMesh/owner (or owner.gz), in millions: meshes of 236, 110 and
#     65 million cells are recorded as such by every script, whatever MESH_SIZE
#     says on the Arm launcher;
#   * the record carries the run's number of iterations (endTime);
#   * a mesh whose header gives no cell count, or one under half a million
#     cells, is not recorded, with a NOTE that says which, and the job ends
#     with exit status 0.
#
#   apps/OpenFoam/tests/test-mesh-size.sh
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=stubs.sh
source "${HERE}/stubs.sh"

# Cases with other meshes (synthetic cell counts but the 65M mesh's), each under its own directory.
M65="${STUBS}/m65/occDrivAerStaticMesh";   make_case "${M65}" "nPoints:12  nCells:65334765  nFaces:30  nInternalFaces:10"
M110="${STUBS}/m110/occDrivAerStaticMesh"; make_case "${M110}" "nPoints:12  nCells:110400000  nFaces:30  nInternalFaces:10"
GZ="${STUBS}/gz/occDrivAerStaticMesh";     make_case "${GZ}" "nPoints:12  nCells:65334765  nFaces:30  nInternalFaces:10"
gzip "${GZ}/constant/polyMesh/owner"
NONE="${STUBS}/none/occDrivAerStaticMesh"; make_case "${NONE}" ""
TINY="${STUBS}/tiny/occDrivAerStaticMesh"; make_case "${TINY}" "nPoints:12  nCells:1234  nFaces:30  nInternalFaces:10"
end_of() { awk '/^[[:space:]]*endTime[[:space:]]/ {gsub(";", "", $2); print $2; exit}' "$1/system/controlDict" 2>/dev/null; }
# recorded_mesh <label> <job> <millions>
recorded_mesh() {
    check "$1: recorded as occDrivAer-$3M" "occDrivAer-$3M" "$(recorded "$2" BENCHMARK_CASE)"
    check "$1: with $3 million cells" "$3" "$(recorded "$2" MESH_CELLS_MILLION)"
    check "$1: with its number of iterations" "--metric num_iterations=$(end_of "${RUN}")" "$(recorded "$2" args)"
}

job=500
for s in "${SCRIPTS[@]}"; do
    echo "== ${s} =="
    if skip_arm_here "${s}"; then
        skipt "${s}" "this host has a module system, which the Arm launcher loads, and which could put a real MPI first in PATH"
        continue
    fi

    job=$((job + 1)); run_script "${s}" "${job}"
    completes "the 236M mesh" "${job}"
    recorded_mesh "the 236M mesh" "${job}" 236

    job=$((job + 1)); run_script "${s}" "${job}" CASE_SRC="${M65}"
    completes "the 65M mesh" "${job}"
    recorded_mesh "the 65M mesh" "${job}" 65

    job=$((job + 1)); run_script "${s}" "${job}" CASE_SRC="${M110}" MESH_SIZE=65
    completes "the 110M mesh" "${job}"
    recorded_mesh "the 110M mesh (MESH_SIZE=65 on the Arm launcher)" "${job}" 110

    job=$((job + 1)); run_script "${s}" "${job}" CASE_SRC="${GZ}"
    completes "a compressed owner file" "${job}"
    recorded_mesh "a compressed owner file (owner.gz)" "${job}" 65

    for c in "${NONE}" "${TINY}"; do
        job=$((job + 1)); run_script "${s}" "${job}" CASE_SRC="${c}"
        label="$(basename "$(dirname "${c}")")"
        check "${label}: completes (exit 0)" 0 "${RC}"
        check "${label}: not recorded" 0 "$(recorder_calls "${job}")"
        if [ "${c}" = "${NONE}" ]; then
            has "${label}: NOTE" \
                "NOTE: the run is not recorded: cannot tell its mesh size from the header of ${c}/constant/polyMesh/owner (nCells)."
        else
            has "${label}: NOTE" \
                "NOTE: the run is not recorded: its mesh has 1234 cells, under half a million (the record gives the mesh in millions)."
        fi
    done
done

finish "mesh size"
