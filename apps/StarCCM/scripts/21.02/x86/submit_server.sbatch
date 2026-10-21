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
#   -l PODKEY     PoD license key (default: $PODLIC env var, else the Parameter
#                 Store parameter named by PODLIC_SSM_PARAMETER)
#
# MPI: OpenMPI (the default and recommended MPI for Linux per the Siemens
#   installation guide); use it on AMD instances.
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
# PoD key: -l, else $PODLIC, else the AWS Systems Manager Parameter Store parameter
# that PODLIC_SSM_PARAMETER names (read now, when the job starts). STAR-CCM+ gets it in
# LM_PROJECT, the variable its launcher sets from -podkey, so the key is not on
# STAR-CCM+'s command line, which STAR-CCM+ writes into its log (and -benchmark into
# its XML and HTML reports).
if [ -z "${PODKEY}" ] && [ -n "${PODLIC_SSM_PARAMETER:-}" ]; then
    if [ -z "${AWS_REGION:-${AWS_DEFAULT_REGION:-}}" ]; then
        _imds_token=$(curl -fsS --max-time 2 -X PUT "http://169.254.169.254/latest/api/token" \
            -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
        export AWS_REGION=$(curl -fsS --max-time 2 -H "X-aws-ec2-metadata-token: ${_imds_token}" \
            "http://169.254.169.254/latest/meta-data/placement/region")
    fi
    PODKEY=$(aws ssm get-parameter --name "${PODLIC_SSM_PARAMETER}" --with-decryption \
        --query Parameter.Value --output text)
fi
[ -n "${PODKEY}" ] && export LM_PROJECT="${PODKEY}"
LICENSEOPTS="-power -licpath 1999@flex.cd-adapco.com"

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
