#!/bin/bash
#SBATCH --job-name=STAR_GPU_SRV
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=8
#SBATCH --cpus-per-task=12
#SBATCH --gres=gpu:8
#SBATCH --partition=gpu
#SBATCH --output=%x_%j.out
#SBATCH --exclusive
#SBATCH --no-requeue

# =============================================================================
# STAR-CCM+ 21.02 — GPU Server Submit Script (OpenMPI + EFA)
# =============================================================================
#
# Starts STAR-CCM+ in server mode for interactive GUI connection.
# Connect from your desktop client to the head node IP on the printed port.
#
# Usage:
#   sbatch submit_server.sbatch -v 21.02.007 -s /fsx/simulations/model.sim
#   sbatch --nodes=2 submit_server.sbatch -v 21.02.007 -s model.sim
#
# Flags:
#   -v VERSION    STAR-CCM+ version (default: 21.02.007)
#   -s SIM_FILE   Simulation file path (required)
#   -l PODKEY     PoD license key (default: $PODLIC env var)
#
# See submit_batch.sbatch for full documentation on GPU flags and settings.
#
# Tested on: g6e.48xlarge (8x L40S), ParallelCluster 3.15, AL2023
# =============================================================================

APP_VERSION="21.02.007"
SIM_FILE=""
PODKEY="${PODLIC}"

while getopts "v:s:l:" opt; do
    case ${opt} in
        v) APP_VERSION="${OPTARG}" ;;
        s) SIM_FILE="${OPTARG}" ;;
        l) PODKEY="${OPTARG}" ;;
        *) echo "Usage: sbatch $0 -v VERSION -s SIM_FILE [-l PODKEY]"; exit 1 ;;
    esac
done

if [ -z "${SIM_FILE}" ]; then
    echo "ERROR: Simulation file required. Use -s /path/to/model.sim"
    exit 1
fi

export FI_EFA_FORK_SAFE=1
export PATH=/opt/slurm/bin:/usr/local/bin:$PATH
[ -f /etc/profile.d/pcluster.sh ] && source /etc/profile.d/pcluster.sh
ulimit -s unlimited

GPUS_PER_NODE=${SLURM_NTASKS_PER_NODE:-8}
TOTAL_GPUS=$(( SLURM_JOB_NUM_NODES * GPUS_PER_NODE ))

HOSTFILE="${SLURM_JOB_ID}_hosts.txt"
GPUFILE="${SLURM_JOB_ID}_gpus.txt"

rm -f ${HOSTFILE} ${GPUFILE}
for host in $(scontrol show hostname ${SLURM_NODELIST}); do
    echo "${host}:${GPUS_PER_NODE}" >> ${HOSTFILE}
    echo "${host} auto:${GPUS_PER_NODE}" >> ${GPUFILE}
done

LICENSEOPTS="-power -podkey ${PODKEY} -licpath 1999@flex.cd-adapco.com"

echo "=== STAR-CCM+ ${APP_VERSION} — GPU server mode ==="
echo "Nodes: ${SLURM_JOB_NUM_NODES} | GPUs: ${TOTAL_GPUS}"
echo "Connect your STAR-CCM+ client to this node once the server starts."
echo "Start: $(date)"

/fsx/Siemens/${APP_VERSION}/STAR-CCM+${APP_VERSION}/star/bin/starccm+ \
    -gpgpu file:${GPUFILE} \
    -np ${TOTAL_GPUS} \
    -machinefile ${HOSTFILE} \
    -pio \
    ${LICENSEOPTS} \
    -mpi openmpi \
    -xsystemlibfabric -ldlibpath /opt/amazon/efa/lib64 \
    -fabric OFI \
    -server \
    ${SIM_FILE}

echo "Finish: $(date)"
