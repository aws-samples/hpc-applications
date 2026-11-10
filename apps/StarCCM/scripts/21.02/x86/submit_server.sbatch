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
    # The lookup's Region, when AWS_REGION and AWS_DEFAULT_REGION are both unset
    # or empty, comes from the instance metadata (IMDSv2). Each request gives up
    # after 5 seconds (2 to connect), and -f turns an HTTP error into no answer.
    # An answer cut off at that limit, or one that is not a Region name (tested in
    # the C locale: in some locales [a-z] leaves out i), a proxy's page for
    # example, counts as none. The script then sets no Region and leaves both
    # variables as the job got them. If both are unset, the AWS CLI looks for a
    # Region itself: in its configuration, then (AWS CLI v2) in the instance
    # metadata. If either is set to an empty string, AWS CLI v2 takes that as the
    # Region. With an empty Region, or with none, the lookup gives no key, and
    # STAR-CCM+ starts without one.
    if [ -z "${AWS_REGION:-${AWS_DEFAULT_REGION:-}}" ]; then
        _imds_token=$(curl -fsS --connect-timeout 2 --max-time 5 -X PUT "http://169.254.169.254/latest/api/token" \
            -H "X-aws-ec2-metadata-token-ttl-seconds: 60") || _imds_token=""
        _imds_region=$(curl -fsS --connect-timeout 2 --max-time 5 -H "X-aws-ec2-metadata-token: ${_imds_token}" \
            "http://169.254.169.254/latest/meta-data/placement/region") || _imds_region=""
        ( LC_ALL=C; [[ "${_imds_region}" =~ ^[a-z]{2}(-[a-z]+)+-[0-9]+$ ]] ) || _imds_region=""
        [ -n "${_imds_region}" ] && export AWS_REGION="${_imds_region}"
    fi
    PODKEY=$(aws ssm get-parameter --name "${PODLIC_SSM_PARAMETER}" --with-decryption \
        --query Parameter.Value --output text)
fi
[ -n "${PODKEY}" ] && export LM_PROJECT="${PODKEY}"
LICENSEOPTS="-power -licpath 1999@flex.cd-adapco.com"

echo "Drop caches on all nodes"
srun --ntasks=$SLURM_JOB_NUM_NODES --ntasks-per-node=1 /bin/bash -c "sync && echo 3 | sudo tee /proc/sys/vm/drop_caches"
echo "Enabling Transparent Huge Pages (THP)"
srun --ntasks=$SLURM_JOB_NUM_NODES --ntasks-per-node=1 /bin/bash -c "echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled"

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
