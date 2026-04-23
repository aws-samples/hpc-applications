#!/bin/bash
#SBATCH --job-name=STAR_GPGPU_SRV
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=8
#SBATCH --partition=p4d24
#SBATCH --output=%x_%j.out
#SBATCH --exclusive
#SBATCH --no-requeue

# =============================================================================
# STAR-CCM+ 18.06 — GPU Server Submit Script (Intel MPI + EFA)
# =============================================================================
#
# Usage:
#   sbatch submit_server.sbatch -v 18.06.007 -s /fsx/simulations/model.sim
#
# Flags:
#   -v VERSION    STAR-CCM+ version (default: 18.06.007)
#   -s SIM_FILE   Simulation file path (default: /fsx/simulations/model.sim)
#   -l PODKEY     PoD license key (default: $PODLIC env var)
#
# Tested on: p4d.24xlarge (8x A100), p5.48xlarge (8x H100)
# =============================================================================

APP_VERSION="18.06.007"
SIM_FILE="/fsx/simulations/model.sim"
PODKEY="${PODLIC}"

while getopts "v:s:l:" opt; do
    case ${opt} in
        v) APP_VERSION="${OPTARG}" ;;
        s) SIM_FILE="${OPTARG}" ;;
        l) PODKEY="${OPTARG}" ;;
        *) echo "Usage: sbatch $0 -v VERSION -s SIM_FILE [-l PODKEY]"; exit 1 ;;
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

HOSTFILE="${SLURM_JOB_ID}_hosts.txt"
GPUFILE="${SLURM_JOB_ID}_gpus.txt"
GPUS_PER_NODE=${SLURM_NTASKS_PER_NODE:-8}
TOTAL_GPUS=$(( SLURM_JOB_NUM_NODES * GPUS_PER_NODE ))

rm -f ${HOSTFILE} ${GPUFILE}
for host in $(scontrol show hostname ${SLURM_NODELIST}); do
    echo "${host}:${GPUS_PER_NODE}" >> ${HOSTFILE}
    echo "${host} auto:${GPUS_PER_NODE}" >> ${GPUFILE}
done

echo "STAR-CCM+ ${APP_VERSION} — GPU server mode"
echo "Nodes: ${SLURM_JOB_NUM_NODES}, GPUs: ${TOTAL_GPUS}"
echo "Connect to the server host:port shown in the log file."
echo "Start: $(date)"

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
    -server \
    ${SIM_BASENAME} > "${SIM_BASENAME%.*}.log" 2>&1

echo "Finish: $(date)"
