#!/bin/bash
#SBATCH --nodes=2
#SBATCH --partition=hpc7a
#SBATCH --output=%x_%j.out
#SBATCH --exclusive

# =============================================================================
# STAR-CCM+ 18.06 — x86 Batch Submit Script (Intel MPI + EFA)
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
# Tested on: hpc6a.48xlarge, hpc7a.96xlarge (Amazon Linux 2, AL2023)
# MPI: Intel MPI (bundled with STAR-CCM+) + system libfabric for EFA
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

# Intel MPI + EFA configuration
export I_MPI_OFI_LIBRARY_INTERNAL=0   # Use system libfabric (EFA-aware)
export I_MPI_FABRICS=shm:ofi          # Shared memory intra-node, OFI inter-node
export I_MPI_OFI_PROVIDER=efa         # Use EFA provider
export I_MPI_MULTIRAIL=1              # Enable multi-NIC (hpc7a has 2 ENIs)
export FI_EFA_FORK_SAFE=1             # Required for EFA with fork()

SIM_BASENAME=$(basename ${SIM_FILE})
LICENSEOPTS="-power -podkey ${PODKEY} -licpath 1999@flex.cd-adapco.com"

echo "STAR-CCM+ ${APP_VERSION} — x86 batch"
echo "Nodes: ${SLURM_JOB_NUM_NODES}, Sim: ${SIM_BASENAME}, Batch: ${BATCH_CMD}"
echo "Start: $(date)"

/fsx/Siemens/${APP_VERSION}/STAR-CCM+${APP_VERSION}/star/bin/starccm+ \
    -pio \
    -bs slurm \
    ${LICENSEOPTS} \
    -mpi intel \
    -xsystemlibfabric -ldlibpath /opt/amazon/efa/lib64 \
    -fabric OFI \
    -batch ${BATCH_CMD} \
    ${SIM_BASENAME} > "${SIM_BASENAME%.*}.log" 2>&1

echo "Finish: $(date)"
