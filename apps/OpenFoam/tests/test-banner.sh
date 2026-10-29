#!/bin/bash
# =============================================================================
# What the benchmark scripts print about the case they run, each script run end
# to end with the stubs of stubs.sh. What it pins:
#   * the banner the job prints first and the heading of its report name the
#     case and mesh in CASE_SRC, the ones the script runs, and no mesh size:
#     236M is only the x86 scripts' default mesh, and MESH_SIZE only chooses
#     the Arm launcher's default CASE_SRC and the mesh it downloads into one
#     without a mesh;
#   * with the 65M mesh in CASE_SRC (and MESH_SIZE=236 on the Arm launcher),
#     no line of the job's output names the 236M mesh.
#
#   apps/OpenFoam/tests/test-banner.sh
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=stubs.sh
source "${HERE}/stubs.sh"
# A case with another mesh (the 65M mesh's cell count), under its own directory.
M65="${STUBS}/m65/occDrivAerStaticMesh"; make_case "${M65}" "nPoints:12  nCells:65334765  nFaces:30  nInternalFaces:10"
job=600
for s in "${SCRIPTS[@]}"; do
    echo "== ${s} =="
    if skip_arm_here "${s}"; then
        skipt "${s}" "this host has a module system, which the Arm launcher loads, and which could put a real MPI first in PATH"
        continue
    fi
    case "${s}" in
        x86/openfoam-benchmark-openmpi.sbatch)  mpi="OpenMPI" ;;
        x86/openfoam-benchmark-intelmpi.sbatch) mpi="Intel MPI" ;;
        *)                                      mpi="OpenMPI (Arm)" ;;
    esac
    for c in "${CASE}" "${M65}"; do
        if [ "${c}" = "${CASE}" ]; then label="the 236M mesh"; else label="the 65M mesh"; fi
        job=$((job + 1)); run_script "${s}" "${job}" CASE_SRC="${c}" MESH_SIZE=236
        check "${label}: completes (exit 0)" 0 "${RC}"
        has "${label}: the banner names the case and mesh in CASE_SRC" \
            "=== OCC DrivAer, the case and mesh in ${c} — ${mpi} ==="
        has "${label}: so does the report's heading" "OCC DrivAer, the case and mesh in ${c} — ${mpi} Results"
    done
    check "the 65M mesh: no line of the output names the 236M mesh" 0 "$(grep -c '236M' <<<"${OUT}")"
done
finish "banner"
