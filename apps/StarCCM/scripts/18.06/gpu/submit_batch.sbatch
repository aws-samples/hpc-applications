#!/bin/bash
#SBATCH --job-name=STAR_GPGPU
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=8
#SBATCH --partition=p4d24
#SBATCH --output=%x_%j.out
#SBATCH --exclusive
#SBATCH --no-requeue

# =============================================================================
# STAR-CCM+ 18.06 — GPU Batch Submit Script (Intel MPI + EFA)
# =============================================================================
#
# Usage:
#   sbatch submit_batch.sbatch -s /fsx/simulations/model.sim
#   sbatch submit_batch.sbatch -v 18.06.007 -s model.sim -m macro.java
#   sbatch submit_batch.sbatch -v 18.06.007 -s model.sim -m "macro.java,mesh,run"
#
# Flags:
#   -v VERSION    STAR-CCM+ version (default: 18.06.007)
#   -s SIM_FILE   Simulation file path (default: /fsx/simulations/model.sim)
#   -m BATCH_CMD  -batch command(s): a .java macro, run, mesh, step, or a
#                 comma-separated combination (default: run — solves the sim)
#   -l PODKEY     PoD license key (default: $PODLIC env var)
#
# GPU instances use ntasks-per-node=8 (one MPI rank per GPU).
# Host and GPU files are generated automatically from SLURM allocation.
#
# Tested on: p4d.24xlarge (8x A100), p5.48xlarge (8x H100)
# =============================================================================

APP_VERSION="18.06.007"
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

module load intelmpi

export I_MPI_OFI_LIBRARY_INTERNAL=0
export I_MPI_FABRICS=shm:ofi
export I_MPI_OFI_PROVIDER=efa
export I_MPI_MULTIRAIL=1
export I_MPI_HYDRA_BRANCH_COUNT=0
export I_MPI_PIN=1
export FI_EFA_SHM_AV_SIZE=256
export FI_EFA_FORK_SAFE=1
ulimit -s unlimited

SIM_BASENAME=$(basename ${SIM_FILE})
LICENSEOPTS="-power -podkey ${PODKEY} -licpath 1999@flex.cd-adapco.com"

# Generate host file (hostname:gpus_per_node) and GPU file for STAR-CCM+
HOSTFILE="${SLURM_JOB_ID}_hosts.txt"
GPUFILE="${SLURM_JOB_ID}_gpus.txt"
GPUS_PER_NODE=${SLURM_NTASKS_PER_NODE:-8}
TOTAL_GPUS=$(( SLURM_JOB_NUM_NODES * GPUS_PER_NODE ))

rm -f ${HOSTFILE} ${GPUFILE}
for host in $(scontrol show hostname ${SLURM_NODELIST}); do
    echo "${host}:${GPUS_PER_NODE}" >> ${HOSTFILE}
    echo "${host} auto:${GPUS_PER_NODE}" >> ${GPUFILE}
done

echo "STAR-CCM+ ${APP_VERSION} — GPU batch"
echo "Nodes: ${SLURM_JOB_NUM_NODES}, GPUs/node: ${GPUS_PER_NODE}, Total GPUs: ${TOTAL_GPUS}"
echo "Sim: ${SIM_BASENAME}, Batch: ${BATCH_CMD}"
echo "Start: $(date)"
_rec_t0="$(date +%s)"

/fsx/Siemens/${APP_VERSION}/STAR-CCM+${APP_VERSION}/star/bin/starccm+ \
    -gpgpu file:${GPUFILE} \
    -np ${TOTAL_GPUS} \
    -machinefile ${HOSTFILE} \
    -pio \
    -bs slurm \
    ${LICENSEOPTS} \
    -mpi intel \
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
_gpu_count="${TOTAL_GPUS:-}"
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
        --metric "gpu_count=${_gpu_count}" --char "accelerator=gpu" \
        || echo "NOTE: benchmark recorder failed (non-fatal); the solve was unaffected." >&2
elif [ "${_rec_rc:-1}" -ne 0 ]; then
    echo "NOTE: solver exited ${_rec_rc:-?}; skipping benchmark recording." >&2
else
    echo "NOTE: benchmark recorder not found; set DYNAMODB_RECORDER=/path/to/record-benchmark.sh to record." >&2
fi
exit ${_rec_rc:-0}
