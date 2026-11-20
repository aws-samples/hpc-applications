#!/bin/bash
# =============================================================================
# Each OpenFOAM benchmark script from start to end, with the stubs of stubs.sh,
# on 2 nodes x 4 ranks of the tiny case. What it pins:
#   * the run directory holds the case (0 from 0.orig, constant, system) and a
#     copy of the script, and controlDict no longer includes
#     FOwallClockTimeStatistics;
#   * decomposePar runs once, for 8 subdomains with the simple method,
#     n (nodes 1 ranks-per-node);
#   * mpirun launches renumberMesh, potentialFoam and simpleFoam once each on
#     all 8 ranks; the OpenMPI scripts bind rank i to core i;
#   * the report gives the four phases and the total, and the recorder gets the
#     simpleFoam time as the time to solution;
#   * a recorder that cannot be found, or that ends with an error, leaves the
#     job's exit status at 0, with a NOTE.
#
#   apps/OpenFoam/tests/test-benchmark-scripts.sh
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=stubs.sh
source "${HERE}/stubs.sh"

job=200
for s in "${SCRIPTS[@]}"; do
    echo "== ${s} =="
    if skip_arm_here "${s}"; then
        skipt "${s}" "this host has a module system, which the Arm launcher loads, and which could put a real MPI first in PATH"
        continue
    fi

    job=$((job + 1)); run_script "${s}" "${job}"
    completes "a run" "${job}"
    for f in 0/U constant/polyMesh/owner constant/transportProperties system/controlDict "$(basename "${s}")"; do
        [ -f "${RUN}/${f}" ] && ok "a run: the run directory holds ${f}" \
            || bad "a run: the run directory holds ${f}" "${RUN}/${f}" "missing"
    done
    check "a run: controlDict no longer includes FOwallClockTimeStatistics" 0 \
        "$(grep -c FOwallClockTimeStatistics "${RUN}/system/controlDict")"
    check "a run: decomposePar runs once" 1 "$(decompositions "${job}")"
    check "a run: 8 subdomains" "numberOfSubdomains 8;" "$(grep '^numberOfSubdomains' "${RUN}/system/decomposeParDict")"
    check "a run: the simple method, n (2 1 4)" "method simple; simpleCoeffs { n (2 1 4); }" \
        "$(grep -E '^(method|simpleCoeffs)' "${RUN}/system/decomposeParDict" | tr '\n' ' ' | sed 's/ $//')"
    for app in renumberMesh potentialFoam simpleFoam; do
        check "a run: mpirun launches ${app} once" 1 "$(launches "${job}" "${app}")"
        case " $(launch_field "${job}" "${app}" 3) " in
            *" -np 8 "*) ok "a run: ${app} runs on all 8 ranks" ;;
            *) bad "a run: ${app} runs on all 8 ranks" "-np 8" "$(launch_field "${job}" "${app}" 3)" ;;
        esac
    done
    case "${s}" in
        x86/openfoam-benchmark-openmpi.sbatch) wants=("--bind-to core --map-by slot") ;;
        Arm/*) wants=("--map-by slot" "--bind-to core") ;;
        *) wants=("-ppn 4 -f hostfile") ;;
    esac
    for want in "${wants[@]}"; do
        case " $(launch_field "${job}" simpleFoam 3) " in
            *" ${want} "*) ok "a run: simpleFoam is launched with ${want}" ;;
            *) bad "a run: simpleFoam is launched with ${want}" "${want}" "$(launch_field "${job}" simpleFoam 3)" ;;
        esac
    done
    for p in Decomposition Renumber potentialFoam simpleFoam Total; do
        if grep -qE "^${p}: +[0-9]+\.[0-9]+s$" <<<"${OUT}"; then ok "a run: the report gives ${p}"
        else bad "a run: the report gives ${p}" "${p}: <n>s" "$(grep -E "^${p}:" <<<"${OUT}")"; fi
    done

    job=$((job + 1))
    run_script "${s}" "${job}" DYNAMODB_RECORDER="${STUBS}/no-such-recorder" SLURM_SUBMIT_DIR="${STUBS}/empty/submit"
    check "no recorder: completes (exit 0)" 0 "${RC}"
    has "no recorder: NOTE" "NOTE: benchmark recorder not found; set DYNAMODB_RECORDER=/path/to/record-benchmark.sh to record."

    job=$((job + 1)); run_script "${s}" "${job}" STUB_RECORDER_EXIT=1
    check "a recorder error: completes (exit 0)" 0 "${RC}"
    check "a recorder error: the recorder was called" 1 "$(recorder_calls "${job}")"
    has "a recorder error: NOTE" "NOTE: benchmark recorder failed (non-fatal); the solve was unaffected."
done

finish "benchmark scripts"
