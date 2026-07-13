#!/bin/bash
#SBATCH --job-name=STAR_GPU
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=8
#SBATCH --cpus-per-task=12
#SBATCH --gres=gpu:8
#SBATCH --partition=gpu
#SBATCH --output=%x_%j.out
#SBATCH --exclusive
#SBATCH --no-requeue

# =============================================================================
# STAR-CCM+ 21.02 — GPU Batch Submit Script (OpenMPI + EFA)
# =============================================================================
#
# Usage:
#   sbatch submit_batch.sbatch -v 21.02.007 -s /fsx/simulations/model.sim
#   sbatch submit_batch.sbatch -v 21.02.007 -s model.sim -m macro.java
#   sbatch submit_batch.sbatch -v 21.02.007 -s model.sim -m "macro.java,mesh,run"
#   sbatch --nodes=2 submit_batch.sbatch -v 21.02.007 -s model.sim
#
# Flags:
#   -v VERSION    STAR-CCM+ version (default: 21.02.007)
#   -s SIM_FILE   Simulation file path (required)
#   -m BATCH_CMD  -batch command(s): a .java macro, run, mesh, step, or a
#                 comma-separated combination (default: run — solves the sim)
#   -l PODKEY     PoD license key (default: $PODLIC env var)
#
# GPU offload:
#   STAR-CCM+ offloads solver computations (matrix operations) to GPUs while
#   CPUs handle mesh management, I/O, and orchestration. Each MPI rank maps
#   to exactly one GPU. For 8 GPUs per node, use -np 8 per node.
#
#   The -np flag MUST equal the total GPU count across all nodes.
#   CPU cores per GPU are controlled by --cpus-per-task (not -np).
#   Recommended: 4-12 CPUs per GPU depending on instance type.
#
# MPI:
#   OpenMPI (bundled with STAR-CCM+) is recommended for all platforms.
#   The -xsystemlibfabric flag bridges to the system's EFA-aware libfabric.
#   Do NOT use -bs slurm with -machinefile — they conflict. This script
#   uses explicit machine file + GPU file for reliable GPU mapping.
#
# IMPORTANT: Requires glibc >= 2.28 (AL2023, Ubuntu 20+, RHEL8+).
#   ParallelCluster 3.15+ auto-installs NVIDIA drivers on GPU instances.
#
# Tested on: g6e.48xlarge (8x L40S), ParallelCluster 3.15, AL2023
# Expected to work on: p4d.24xlarge (A100), p5.48xlarge (H100),
#   p5en.48xlarge (H200), g7e.48xlarge (RTX PRO 6000)
#
# Adjust these SBATCH directives for your instance type:
#   g6e.48xlarge:  --ntasks-per-node=8  --cpus-per-task=12  --gres=gpu:8
#   p4d.24xlarge:  --ntasks-per-node=8  --cpus-per-task=12  --gres=gpu:8
#   p5.48xlarge:   --ntasks-per-node=8  --cpus-per-task=24  --gres=gpu:8
#   p5en.48xlarge: --ntasks-per-node=8  --cpus-per-task=24  --gres=gpu:8
#   g7e.48xlarge:  --ntasks-per-node=8  --cpus-per-task=24  --gres=gpu:8
# =============================================================================

APP_VERSION="21.02.007"
SIM_FILE=""
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

if [ -z "${SIM_FILE}" ]; then
    echo "ERROR: Simulation file required. Use -s /path/to/model.sim"
    exit 1
fi

# EFA configuration
export FI_EFA_FORK_SAFE=1

# Ensure Slurm tools are in PATH (scontrol used for hostname resolution)
export PATH=/opt/slurm/bin:/usr/local/bin:$PATH
[ -f /etc/profile.d/pcluster.sh ] && source /etc/profile.d/pcluster.sh

ulimit -s unlimited

# --- Derive GPU and node counts from SLURM allocation ---
GPUS_PER_NODE=${SLURM_NTASKS_PER_NODE:-8}
TOTAL_GPUS=$(( SLURM_JOB_NUM_NODES * GPUS_PER_NODE ))

# --- Generate machine file and GPU file ---
# Machine file: tells MPI how many ranks per host (1 rank = 1 GPU)
# GPU file: tells STAR-CCM+ which GPUs to use per host
HOSTFILE="${SLURM_JOB_ID}_hosts.txt"
GPUFILE="${SLURM_JOB_ID}_gpus.txt"

rm -f ${HOSTFILE} ${GPUFILE}
for host in $(scontrol show hostname ${SLURM_NODELIST}); do
    echo "${host}:${GPUS_PER_NODE}" >> ${HOSTFILE}
    echo "${host} auto:${GPUS_PER_NODE}" >> ${GPUFILE}
done

# --- License ---
LICENSEOPTS="-power -podkey ${PODKEY} -licpath 1999@flex.cd-adapco.com"
# Note: when -gpgpu is active, STAR-CCM+ ignores -power (you'll see a
# warning). PoD licensing still works — compute nodes need internet access
# to reach the license server.

# --- Batch command (default: run) ---
SIM_BASENAME=$(basename ${SIM_FILE})

echo "=== STAR-CCM+ ${APP_VERSION} — GPU batch (OpenMPI + EFA) ==="
echo "Nodes: ${SLURM_JOB_NUM_NODES} | GPUs: ${TOTAL_GPUS} (${GPUS_PER_NODE}/node)"
echo "Sim: ${SIM_FILE}"
echo "Start: $(date)"
_rec_t0="$(date +%s)"
echo ""
echo "Host file:"
cat ${HOSTFILE}
echo "GPU file:"
cat ${GPUFILE}
echo ""

# --- Run STAR-CCM+ ---
# Key flags:
#   -gpgpu file:<path>     Enable GPU offload, read GPU assignment from file
#   -np <total_gpus>       Total MPI ranks = total GPUs
#   -machinefile <path>    Explicit host assignment (do NOT combine with -bs slurm)
#   -mpi openmpi           Use STAR-CCM+'s bundled OpenMPI
#   -xsystemlibfabric      Use system's EFA-aware libfabric (not bundled)
#   -ldlibpath <path>      Path to EFA libraries
#   -fabric OFI            Use OFI (libfabric) transport
#   -pio                   Parallel I/O for loading simulation files

/fsx/Siemens/${APP_VERSION}/STAR-CCM+${APP_VERSION}/star/bin/starccm+ \
    -gpgpu file:${GPUFILE} \
    -np ${TOTAL_GPUS} \
    -machinefile ${HOSTFILE} \
    -pio \
    ${LICENSEOPTS} \
    -mpi openmpi \
    -xsystemlibfabric -ldlibpath /opt/amazon/efa/lib64 \
    -fabric OFI \
    -batch ${BATCH_CMD} \
    ${SIM_FILE} > "${SIM_BASENAME%.*}.log" 2>&1
_rec_rc=$?

echo ""
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
