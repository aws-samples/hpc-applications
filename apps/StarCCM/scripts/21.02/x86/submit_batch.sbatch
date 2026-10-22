#!/bin/bash
#SBATCH --nodes=2
#SBATCH --partition=hpc7a
#SBATCH --output=%x_%j.out
#SBATCH --exclusive

# =============================================================================
# STAR-CCM+ 21.02 — x86 Batch Submit Script (OpenMPI + EFA)
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
#   -l PODKEY     PoD license key (default: $PODLIC env var, else the Parameter
#                 Store parameter named by PODLIC_SSM_PARAMETER)
#
# MPI: OpenMPI (bundled with STAR-CCM+) is the default and recommended MPI for
#   Linux per the Siemens installation guide; use it on AMD instances.
#
# CPU binding: No -cpubind flag needed — STAR-CCM+ defaults to "bandwidth",
#   which maximises memory bandwidth across NUMA nodes; keep that default.
#
# IMPORTANT: STAR-CCM+ 21.02+ requires glibc >= 2.28.
#   AL2023 (glibc 2.34) ✓ | Ubuntu 20+ ✓ | RHEL8+ ✓ | AL2 (2.26) ✗
#
# Tested on: hpc6a.48xlarge, hpc7a.96xlarge, hpc8a.96xlarge (AL2023)
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

# EFA configuration for OpenMPI
export FI_EFA_FORK_SAFE=1             # Required for EFA with fork()

# Ensure Slurm tools are in PATH (STAR-CCM+ -bs slurm calls scontrol)
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

echo "Drop caches on all nodes"
srun --ntasks=$SLURM_JOB_NUM_NODES --ntasks-per-node=1 /bin/bash -c "sync && echo 3 | sudo tee /proc/sys/vm/drop_caches"
echo "Enabling Transparent Huge Pages (THP)"
srun --ntasks=$SLURM_JOB_NUM_NODES --ntasks-per-node=1 /bin/bash -c "echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled"

echo "STAR-CCM+ ${APP_VERSION} — x86 batch (OpenMPI)"
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
