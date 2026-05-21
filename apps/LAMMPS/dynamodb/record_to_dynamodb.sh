#!/bin/bash
# Record a LAMMPS benchmark result to DynamoDB.
#
# Called at the end of apps/LAMMPS/{x86,Arm}/lammps-benchmark.sbatch with
# the run metrics and metadata exposed as environment variables. This is
# intentionally a separate script because most LAMMPS users do not need
# centralised result persistence — if you don't want it, simply delete
# (or never deploy) the apps/LAMMPS/dynamodb/ directory and the benchmark
# scripts will silently skip the recording step.
#
# See apps/LAMMPS/dynamodb/README.md for the table schema and the IAM
# permission required on compute nodes.
#
# Required env vars (set by the benchmark scripts):
#   SLURM_JOB_ID, SLURM_JOB_NUM_NODES, SLURM_CLUSTER_NAME
#   MODEL, SCALE
#   NRANK_TOTAL, NRANK_PER_NODE, THREADS_PER_RANK
#   INSTANCE_TYPE, REGION, LAMMPS_TAG, MPI_STACK
#   ATOMS, LOOP_STEPS, LOOP_TIME
#   TIMESTEPS_PER_SEC, ATOM_STEPS_PER_SEC, WALL_TIME
#   WORKDIR
#
# Optional env vars (with defaults):
#   DYNAMODB_TABLE   (default: LAMMPS_Benchmarks)
#   DYNAMODB_REGION  (default: us-east-1)

set -uo pipefail

DYNAMODB_TABLE="${DYNAMODB_TABLE:-LAMMPS_Benchmarks}"
DYNAMODB_REGION="${DYNAMODB_REGION:-us-east-1}"

# Collect runtime metadata that we don't already have from the benchmark.
MPI_VERSION=$(mpirun --version 2>&1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
LIBFABRIC_VERSION=$(fi_info --version 2>/dev/null | awk '/libfabric:/ {print $2; exit}')
EFA_VERSION=$(fi_info -p efa -t FI_EP_RDM 2>/dev/null | awk '/version:/ {print $2; exit}')
KERNEL_VERSION=$(uname -r)

# shellcheck source=/dev/null
. /etc/os-release
OS_PRETTY="${PRETTY_NAME}"

if [ -f /opt/parallelcluster/.bootstrapped ]; then
    PC_VERSION=$(sed 's/aws-parallelcluster-cookbook-//g' /opt/parallelcluster/.bootstrapped)
else
    PC_VERSION="unknown"
fi

CLUSTER_NAME="${SLURM_CLUSTER_NAME:-unknown}"
CONFIG="${SLURM_JOB_NUM_NODES}N-${NRANK_PER_NODE}rpn-${MODEL}-s${SCALE}"
DYNAMO_FILE="${WORKDIR}/dynamodb_record.json"

cat > "${DYNAMO_FILE}" <<DYNEOF
{
    "job_id":             {"S": "${SLURM_JOB_ID}"},
    "config":             {"S": "${CONFIG}"},
    "timestamp":          {"S": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"},
    "model":              {"S": "${MODEL}"},
    "scale":              {"N": "${SCALE}"},
    "nodes":              {"N": "${SLURM_JOB_NUM_NODES}"},
    "ranks_total":        {"N": "${NRANK_TOTAL}"},
    "ranks_per_node":     {"N": "${NRANK_PER_NODE}"},
    "threads_per_rank":   {"N": "${THREADS_PER_RANK}"},
    "instance_type":      {"S": "${INSTANCE_TYPE}"},
    "cluster_name":       {"S": "${CLUSTER_NAME}"},
    "lammps_tag":         {"S": "${LAMMPS_TAG:-unknown}"},
    "mpi_stack":          {"S": "${MPI_STACK}"},
    "mpi_version":        {"S": "${MPI_VERSION}"},
    "libfabric_version":  {"S": "${LIBFABRIC_VERSION}"},
    "efa_version":        {"S": "${EFA_VERSION}"},
    "kernel":             {"S": "${KERNEL_VERSION}"},
    "os":                 {"S": "${OS_PRETTY}"},
    "pc_version":         {"S": "${PC_VERSION}"},
    "region":             {"S": "${REGION}"},
    "atoms":              {"N": "${ATOMS}"},
    "timesteps":          {"N": "${LOOP_STEPS}"},
    "loop_time_s":        {"N": "${LOOP_TIME}"},
    "timesteps_per_sec":  {"N": "${TIMESTEPS_PER_SEC}"},
    "atom_steps_per_sec": {"N": "${ATOM_STEPS_PER_SEC}"},
    "wall_time_s":        {"N": "${WALL_TIME}"},
    "workdir":            {"S": "${WORKDIR}"}
}
DYNEOF

if aws dynamodb put-item \
        --table-name "${DYNAMODB_TABLE}" \
        --region "${DYNAMODB_REGION}" \
        --item file://"${DYNAMO_FILE}"; then
    echo "DynamoDB record stored: job_id=${SLURM_JOB_ID} config=${CONFIG}"
else
    echo "WARNING: DynamoDB put-item failed; record JSON preserved at ${DYNAMO_FILE}" >&2
fi
