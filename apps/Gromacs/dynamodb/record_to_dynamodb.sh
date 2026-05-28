#!/bin/bash
# Record a GROMACS benchmark result to DynamoDB.
#
# Called at the end of apps/Gromacs/{x86,Arm,GPU}/gromacs-benchmark.sbatch with
# the run metrics and metadata exposed as environment variables. This is
# intentionally a separate script because most GROMACS users do not need
# centralised result persistence — if you don't want it, simply delete
# (or never deploy) the apps/Gromacs/dynamodb/ directory and the benchmark
# scripts will silently skip the recording step.
#
# Table:   Gromacs_Benchmarks (us-east-1)
#   - Partition key:  job_id (S)
#   - Sort key:       config (S) — formatted as "<nodes>N-<rpn>rpn-<model>"
#   - Billing:        PAY_PER_REQUEST
#
# Required IAM permission on compute nodes:
#   {
#     "Effect":   "Allow",
#     "Action":   "dynamodb:PutItem",
#     "Resource": "arn:aws:dynamodb:us-east-1:*:table/Gromacs_Benchmarks"
#   }
#
# See apps/Gromacs/dynamodb/README.md for the full table schema and the
# manual steps to enable the call site on the internal cluster copy under
# /fsx/gromacs/scripts/.
#
# Required env vars (set by the benchmark scripts before sourcing this file):
#   SLURM_JOB_ID, SLURM_JOB_NUM_NODES, SLURM_CLUSTER_NAME
#   MODEL
#   NRANK_TOTAL, NRANK_PER_NODE, THREADS_PER_RANK
#   INSTANCE_TYPE, REGION
#   GROMACS_TAG
#   MPI_STACK   (one of: tmpi, openmpi-4, openmpi-5)
#   MPI_VERSION, LIBFABRIC_VERSION, EFA_VERSION
#   KERNEL_VERSION, OS_PRETTY, PC_VERSION
#   ATOMS, LOOP_STEPS
#   NS_PER_DAY, HOUR_PER_NS, WALL_TIME
#   WORKDIR
#
# Optional env vars (Phase 3 — GPU runs only):
#   GPU_COUNT       (Number)  — appended to the record only if BOTH are set
#   CUDA_VERSION    (String)
#
# Optional env vars (with defaults):
#   DYNAMODB_TABLE   (default: Gromacs_Benchmarks)
#   DYNAMODB_REGION  (default: us-east-1)

set -euo pipefail

DYNAMODB_TABLE="${DYNAMODB_TABLE:-Gromacs_Benchmarks}"
DYNAMODB_REGION="${DYNAMODB_REGION:-us-east-1}"

CLUSTER_NAME="${SLURM_CLUSTER_NAME:-unknown}"
CONFIG="${SLURM_JOB_NUM_NODES}N-${NRANK_PER_NODE}rpn-${MODEL}"
DYNAMO_FILE="${WORKDIR}/dynamodb_record.json"

# Phase 3 hook: append gpu_count and cuda_version only when BOTH are set.
# When unset (Phase 1 / Phase 2 CPU runs), GPU_FIELDS stays empty and the
# JSON is emitted without those attributes.
GPU_FIELDS=""
if [ -n "${GPU_COUNT:-}" ] && [ -n "${CUDA_VERSION:-}" ]; then
    GPU_FIELDS=",
    \"gpu_count\":         {\"N\": \"${GPU_COUNT}\"},
    \"cuda_version\":      {\"S\": \"${CUDA_VERSION}\"}"
fi

cat > "${DYNAMO_FILE}" <<DYNEOF
{
    "job_id":             {"S": "${SLURM_JOB_ID}"},
    "config":             {"S": "${CONFIG}"},
    "timestamp":          {"S": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"},
    "model":              {"S": "${MODEL}"},
    "nodes":              {"N": "${SLURM_JOB_NUM_NODES}"},
    "ranks_total":        {"N": "${NRANK_TOTAL}"},
    "ranks_per_node":     {"N": "${NRANK_PER_NODE}"},
    "threads_per_rank":   {"N": "${THREADS_PER_RANK}"},
    "instance_type":      {"S": "${INSTANCE_TYPE}"},
    "cluster_name":       {"S": "${CLUSTER_NAME}"},
    "gromacs_tag":        {"S": "${GROMACS_TAG:-unknown}"},
    "mpi_stack":          {"S": "${MPI_STACK}"},
    "mpi_version":        {"S": "${MPI_VERSION}"},
    "libfabric_version":  {"S": "${LIBFABRIC_VERSION}"},
    "efa_version":        {"S": "${EFA_VERSION}"},
    "kernel":             {"S": "${KERNEL_VERSION}"},
    "os":                 {"S": "${OS_PRETTY}"},
    "pc_version":         {"S": "${PC_VERSION}"},
    "region":             {"S": "${REGION}"},
    "atoms":              {"N": "${ATOMS}"},
    "nsteps":             {"N": "${LOOP_STEPS}"},
    "ns_per_day":         {"N": "${NS_PER_DAY}"},
    "hour_per_ns":        {"N": "${HOUR_PER_NS}"},
    "wall_time_s":        {"N": "${WALL_TIME}"},
    "workdir":            {"S": "${WORKDIR}"}${GPU_FIELDS}
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

exit 0
