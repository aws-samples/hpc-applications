#!/bin/bash
#SBATCH --nodes=2
#SBATCH --partition=hpc7g
#SBATCH --output=%x_%j.out
#SBATCH --exclusive

# =============================================================================
# STAR-CCM+ 21.02 — Arm (Graviton) Batch Submit Script (OpenMPI + EFA)
# =============================================================================
#
# Usage:
#   sbatch submit_batch.sbatch -s /fsx/simulations/model.sim
#   sbatch submit_batch.sbatch -v 21.02.007 -s model.sim -m macro.java
#   sbatch submit_batch.sbatch -v 21.02.007 -s model.sim -m "macro.java,mesh,run"
#
# Flags:
#   -v VERSION    STAR-CCM+ version (default: 21.02.007)
#   -s SIM_FILE   Simulation file path (default: /fsx/simulations/model.sim)
#   -m BATCH_CMD  -batch command(s): a .java macro, run, mesh, step, or a
#                 comma-separated combination (default: run — solves the sim)
#   -l PODKEY     PoD license key (default: $PODLIC env var)
#
# MPI: OpenMPI is the only option for Arm (Intel MPI is x86-only).
#   Uses -mpi openmpi (version-agnostic — picks up openmpi4 on 20.x, openmpi5 on 21.x).
#
# IMPORTANT: Requires glibc >= 2.28. Use RHEL8, Ubuntu 20+, or AL2023.
#
# Tested on: hpc7g.16xlarge (Graviton3, 64 cores, EFA)
# =============================================================================

APP_VERSION="21.02.007"
SIM_FILE="/fsx/simulations/model.sim"
BATCH_CMD="run"
PODKEY="${PODLIC}"

while getopts "v:s:m:l:" opt; do
    case ${opt} in
        v) APP_VERSION="${OPTARG}" ;;
        s) SIM_FILE="${OPTARG}" ;;
        m) BATCH_CMD="${OPTARG}" ;;
        l) PODKEY="${OPTARG}" ;;
        *) echo "Usage: sbatch $0 -v VERSION -s SIM_FILE [-m BATCH_CMD] [-l PODKEY]"; exit 1 ;;
    esac
done

# EFA configuration
export FI_EFA_FORK_SAFE=1

# Ensure Slurm tools are in PATH (STAR-CCM+ -bs slurm calls scontrol)
export PATH=/opt/slurm/bin:$PATH

SIM_BASENAME=$(basename ${SIM_FILE})
LICENSEOPTS="-power -podkey ${PODKEY} -licpath 1999@flex.cd-adapco.com"

echo "STAR-CCM+ ${APP_VERSION} — Arm (Graviton) batch"
echo "Nodes: ${SLURM_JOB_NUM_NODES}, Sim: ${SIM_BASENAME}, Batch: ${BATCH_CMD}"
echo "Start: $(date)"
_rec_t0="$(date +%s)"

/fsx/Siemens/${APP_VERSION}/STAR-CCM+${APP_VERSION}/star/bin/starccm+ \
    -pio \
    -bs slurm \
    ${LICENSEOPTS} \
    -mpi openmpi \
    -xsystemlibfabric -ldlibpath /opt/amazon/efa/lib64 \
    -fabric OFI \
    -batch ${BATCH_CMD} \
    ${SIM_BASENAME} > "${SIM_BASENAME%.*}.log" 2>&1
_rec_rc=$?

echo "Finish: $(date)"

# ---------------------------------------------------------------------------
# Record this benchmark to the AI-Powered HPC dataset (best-effort, non-fatal).
# The recorder self-collects host details from the environment; this launch
# script times the solve (wall clock) and passes it, so no arguments are
# needed. Only a SUCCESSFUL solve is recorded, and the job's exit status is
# preserved (a recorder problem never changes it). Point DYNAMODB_RECORDER at
# the script if it isn't found automatically; set SOURCE=<YourOrg> to tag your
# contributions. See apps/StarCCM/dynamodb/README.md and apps/BENCHMARK-RECORDERS.md.
# ---------------------------------------------------------------------------
_rec_secs=$(( $(date +%s) - ${_rec_t0:-$(date +%s)} ))
[ "${_rec_secs}" -gt 0 ] 2>/dev/null || _rec_secs=""
_recorder="${DYNAMODB_RECORDER:-}"
for _c in "${_recorder}" \
          "${SLURM_SUBMIT_DIR:-.}/../../../dynamodb/record-benchmark.sh" \
          "${SLURM_SUBMIT_DIR:-.}/dynamodb/record-benchmark.sh" \
          "${SLURM_SUBMIT_DIR:-.}/apps/StarCCM/dynamodb/record-benchmark.sh"; do
    if [ -n "${_c}" ] && [ -x "${_c}" ]; then _recorder="${_c}"; break; fi
done
if [ "${_rec_rc:-1}" -eq 0 ] && [ -n "${_recorder}" ] && [ -x "${_recorder}" ]; then
    STARCCM_VERSION="${APP_VERSION}" BENCHMARK_CASE="${SIM_BASENAME%.*}" \
    TIME_TO_SOLUTION="${_rec_secs}" RUN_DIR="${PWD}" "${_recorder}" \
        || echo "NOTE: benchmark recorder failed (non-fatal); the solve was unaffected." >&2
elif [ "${_rec_rc:-1}" -ne 0 ]; then
    echo "NOTE: solver exited ${_rec_rc:-?}; skipping benchmark recording." >&2
else
    echo "NOTE: benchmark recorder not found; set DYNAMODB_RECORDER=/path/to/record-benchmark.sh to record." >&2
fi
exit ${_rec_rc:-0}
