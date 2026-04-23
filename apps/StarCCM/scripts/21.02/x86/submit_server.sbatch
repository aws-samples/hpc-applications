#!/bin/bash
#SBATCH --nodes=2
#SBATCH --partition=hpc7a
#SBATCH --output=%x_%j.out
#SBATCH --exclusive

# =============================================================================
# STAR-CCM+ 21.02 — x86 Server Submit Script (OpenMPI + EFA)
# =============================================================================
#
# Usage:
#   sbatch submit_server.sbatch -v 21.02.007 -s /fsx/simulations/model.sim
#
# Flags:
#   -v VERSION    STAR-CCM+ version (default: 21.02.007)
#   -s SIM_FILE   Simulation file path (default: /fsx/simulations/model.sim)
#   -l PODKEY     PoD license key (default: $PODLIC env var)
#
# MPI: OpenMPI (recommended for Linux per Siemens user guide).
#   Intel MPI is unsupported on AMD and crashes on 21.02+.
#
# IMPORTANT: Requires glibc >= 2.28 (AL2023, Ubuntu 20+, RHEL8+).
# =============================================================================

APP_VERSION="21.02.007"
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

# EFA configuration for OpenMPI
export FI_EFA_FORK_SAFE=1

# Ensure Slurm tools are in PATH
export PATH=/opt/slurm/bin:$PATH

SIM_BASENAME=$(basename ${SIM_FILE})
LICENSEOPTS="-power -podkey ${PODKEY} -licpath 1999@flex.cd-adapco.com"

echo "STAR-CCM+ ${APP_VERSION} — x86 server mode (OpenMPI)"
echo "Nodes: ${SLURM_JOB_NUM_NODES}, Sim: ${SIM_BASENAME}"
echo "Connect to the server host:port shown in the log file."
echo "Start: $(date)"

/fsx/Siemens/${APP_VERSION}/STAR-CCM+${APP_VERSION}/star/bin/starccm+ \
    -pio \
    -bs slurm \
    ${LICENSEOPTS} \
    -mpi openmpi \
    -xsystemlibfabric -ldlibpath /opt/amazon/efa/lib64 \
    -fabric OFI \
    -server \
    ${SIM_BASENAME} > "${SIM_BASENAME%.*}.log" 2>&1

echo "Finish: $(date)"
