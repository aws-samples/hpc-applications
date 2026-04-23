#!/bin/bash
#SBATCH --nodes=2
#SBATCH --partition=hpc7g
#SBATCH --output=%x_%j.out
#SBATCH --exclusive

# =============================================================================
# STAR-CCM+ 18.06 — Arm (Graviton) Server Submit Script (OpenMPI + EFA)
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
# Tested on: hpc7g.16xlarge (Graviton3, 64 cores, EFA)
# OS: RHEL8 or Ubuntu 20+
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

export FI_EFA_FORK_SAFE=1
export FI_PROVIDER=efa
export FI_EFA_USE_DEVICE_RDMA=1
export OMPI_MCA_btl="^openib"

SIM_BASENAME=$(basename ${SIM_FILE})
LICENSEOPTS="-power -podkey ${PODKEY} -licpath 1999@flex.cd-adapco.com"

echo "STAR-CCM+ ${APP_VERSION} — Arm (Graviton) server mode"
echo "Nodes: ${SLURM_JOB_NUM_NODES}, Sim: ${SIM_BASENAME}"
echo "Connect to the server host:port shown in the log file."
echo "Start: $(date)"

/fsx/Siemens/${APP_VERSION}/STAR-CCM+${APP_VERSION}/star/bin/starccm+ \
    -pio \
    -bs slurm \
    ${LICENSEOPTS} \
    -mpi openmpi4 \
    -server \
    ${SIM_BASENAME} > "${SIM_BASENAME%.*}.log" 2>&1

echo "Finish: $(date)"
