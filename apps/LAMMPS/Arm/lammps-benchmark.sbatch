#!/bin/bash
# Run a LAMMPS standard benchmark (LJ melt, Rhodopsin, or EAM Cu) on
# aarch64 nodes (Graviton3E / Graviton4) using OpenMPI + EFA.
#
# Optional: a commented-out block at the end of this script can record
# each run to a DynamoDB table for cross-run aggregation. It is disabled
# by default so customers don't need to provision DynamoDB. To enable,
# follow the instructions in apps/LAMMPS/dynamodb/README.md and uncomment
# the marked block at the bottom of this file.
#
# A single launcher targets both Graviton3E (hpc7g.16xlarge, 64 cores) and
# Graviton4 (m8g.48xlarge / r8g.48xlarge, 192 cores). Select the right
# build by pointing LAMMPS_ENV at the appropriate env script.
#
# Override via --export=ALL,...:
#   LAMMPS_ENV         path to env script (choose Graviton3 / 4 build)
#   MODEL              lj (default) | rhodo | eam
#   SCALE              lattice replication factor (default: 1)
#                      atom count scales as SCALE^3
#   TIMESTEPS          override the deck's default number of timesteps
#   THREADS_PER_RANK   OpenMP threads per MPI rank (default: 1 = pure MPI)
#   BASE_DIR           run output root (default: /fsx/lammps)
#
# Usage:
#   # Graviton3E (hpc7g)
#   sbatch -p hpc7g -N 1 --ntasks-per-node=64 \
#     --export=ALL,LAMMPS_ENV=/fsx/lammps/aarch64-graviton3/lammps-stable_2Aug2023_update3-env.sh \
#     lammps-benchmark.sbatch
#
#   # Graviton4 (m8g)
#   sbatch -p m8g -N 1 --ntasks-per-node=192 \
#     --export=ALL,LAMMPS_ENV=/fsx/lammps/aarch64-graviton4-ompi5/lammps-stable_2Aug2023_update3-ompi5-env.sh \
#     lammps-benchmark.sbatch

#SBATCH --job-name=lammps
#SBATCH -p hpc7g
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=64
#SBATCH --time=02:00:00
#SBATCH --exclusive
#SBATCH --output=/fsx/lammps/logs/slurm-%x-%j.out

set -euo pipefail

LAMMPS_ENV="${LAMMPS_ENV:-/fsx/lammps/aarch64-graviton3/lammps-stable_2Aug2023_update3-env.sh}"
MODEL="${MODEL:-lj}"
SCALE="${SCALE:-1}"
THREADS_PER_RANK="${THREADS_PER_RANK:-1}"
BASE_DIR="${BASE_DIR:-/fsx/lammps}"

case "${MODEL}" in
    lj)
        DECK_FILE="in.lj"
        DEFAULT_TIMESTEPS=100
        EXTRA_FILES=()
        ;;
    rhodo)
        DECK_FILE="in.rhodo"
        DEFAULT_TIMESTEPS=100
        EXTRA_FILES=("data.rhodo")
        ;;
    eam)
        DECK_FILE="in.eam"
        DEFAULT_TIMESTEPS=100
        EXTRA_FILES=("Cu_u3.eam")
        ;;
    *)
        echo "ERROR: Unknown MODEL: ${MODEL} (expected: lj | rhodo | eam)" >&2
        exit 1
        ;;
esac

TIMESTEPS="${TIMESTEPS:-${DEFAULT_TIMESTEPS}}"

NPROC_TOTAL=$(( SLURM_JOB_NUM_NODES * SLURM_NTASKS_PER_NODE ))
if (( THREADS_PER_RANK > 1 )); then
    NRANK_TOTAL=$(( NPROC_TOTAL / THREADS_PER_RANK ))
else
    NRANK_TOTAL=${NPROC_TOTAL}
fi
NRANK_PER_NODE=$(( SLURM_NTASKS_PER_NODE / THREADS_PER_RANK ))

TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_TYPE=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type)
# REGION is referenced by the optional DynamoDB recorder block at the
# bottom of this file (commented out by default).
# shellcheck disable=SC2034
REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)
WORKDIR="${BASE_DIR}/Run/${SLURM_JOB_NAME}/${MODEL}/${SLURM_CLUSTER_NAME:-cluster}/${SLURM_JOB_ID}-${SLURM_JOB_NUM_NODES}x${INSTANCE_TYPE}-${NRANK_TOTAL}x${THREADS_PER_RANK}-s${SCALE}-$(date '+%d-%m-%Y-%H-%M')"

mkdir -p "${WORKDIR}"
cd "${WORKDIR}"
cp "$0" .

echo "=== LAMMPS benchmark (Arm) ==="
echo "Date:          $(date)"
echo "SLURM Job ID:  ${SLURM_JOB_ID}"
echo "Model:         ${MODEL} (${DECK_FILE})"
echo "Nodes:         ${SLURM_JOB_NUM_NODES} x ${INSTANCE_TYPE}"
echo "MPI ranks:     ${NRANK_TOTAL} total (${NRANK_PER_NODE}/node)"
echo "OMP threads:   ${THREADS_PER_RANK}/rank -> ${NPROC_TOTAL} cores total"
echo "Scale factor:  ${SCALE} (atom count scales as SCALE^3)"
echo "Timesteps:     ${TIMESTEPS}"
echo "Workdir:       ${WORKDIR}"

if [ ! -f "${LAMMPS_ENV}" ]; then
    echo "ERROR: LAMMPS env script not found: ${LAMMPS_ENV}" >&2
    exit 1
fi
set +u
# shellcheck source=/dev/null
source "${LAMMPS_ENV}"
set -u
LMP_BIN="$(command -v lmp || true)"
if [ -z "${LMP_BIN}" ]; then
    echo "ERROR: lmp binary not in PATH; check ${LAMMPS_ENV}" >&2
    exit 1
fi
echo "lmp binary:    ${LMP_BIN}"
echo "LAMMPS tag:    ${LAMMPS_TAG:-unknown}"

# ---------------------------------------------------------------------------
# MPI / EFA sanity
# ---------------------------------------------------------------------------
echo "=== MPI / EFA sanity ==="
echo "mpirun:          $(command -v mpirun)"
mpirun --version 2>&1 | head -2 | sed 's/^/  /'
echo "libfabric (fi_info -l):"
fi_info -l 2>&1 | sed 's/^/  /' | head -6
echo "libfabric EFA provider (fi_info -p efa -t FI_EP_RDM):"
fi_info -p efa -t FI_EP_RDM 2>&1 | grep -E "provider|fabric|domain|nic|version" | sed 's/^/  /' | head -10 || true
echo "lmp libfabric/openmpi linkage:"
ldd "${LMP_BIN}" 2>/dev/null | grep -E "libmpi|libfabric|libopen-" | sed 's/^/  /' || true
echo

# ---------------------------------------------------------------------------
# Stage benchmark input files
# ---------------------------------------------------------------------------
BENCH_CACHE="${BASE_DIR}/benchmarks/${MODEL}"
mkdir -p "${BENCH_CACHE}"
RAW_BASE="https://raw.githubusercontent.com/lammps/lammps/${LAMMPS_TAG:-stable_2Aug2023_update3}/bench"

fetch_if_missing() {
    local name="$1"
    local dest="${BENCH_CACHE}/${name}"
    if [ ! -s "${dest}" ]; then
        echo "Downloading ${name} from ${RAW_BASE}/${name}"
        if ! curl -fsSL "${RAW_BASE}/${name}" -o "${dest}"; then
            echo "ERROR: failed to download ${name} from ${RAW_BASE}/${name}" >&2
            rm -f "${dest}"
            return 1
        fi
    fi
    cp "${dest}" .
}

fetch_if_missing "${DECK_FILE}"
for extra in "${EXTRA_FILES[@]}"; do
    fetch_if_missing "${extra}"
done

# ---------------------------------------------------------------------------
# Hostfile + system tuning
# ---------------------------------------------------------------------------
echo "=== Building hostfile and tuning nodes ==="
scontrol show nodes "${SLURM_NODELIST}" \
    | grep NodeHostName= | awk '{print $2}' | sed 's/NodeHostName=//' > hostfile

srun --ntasks="${SLURM_JOB_NUM_NODES}" --ntasks-per-node=1 /bin/bash -c \
    "sync && echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null && \
     echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled >/dev/null" \
    || true

export OMP_NUM_THREADS="${THREADS_PER_RANK}"
export OMP_PLACES=cores
export OMP_PROC_BIND=close

export FI_PROVIDER=efa
export FI_EFA_USE_DEVICE_RDMA=1
export RDMAV_FORK_SAFE=1

MCA_FLAGS="--mca plm_rsh_agent ssh --mca pml cm --mca mtl ofi --mca btl ^tcp,openib"
if [ "${EFA_VERBOSE:-0}" = "1" ]; then
    MCA_FLAGS="${MCA_FLAGS} --mca mtl_base_verbose 5 --mca pml_base_verbose 5"
fi
if (( THREADS_PER_RANK > 1 )); then
    BIND_FLAGS="--bind-to core --map-by ppr:${NRANK_PER_NODE}:node:PE=${THREADS_PER_RANK}"
else
    BIND_FLAGS="--bind-to core --map-by slot"
fi
X_ENV="-x OMP_NUM_THREADS -x OMP_PLACES -x OMP_PROC_BIND -x FI_PROVIDER -x FI_EFA_USE_DEVICE_RDMA -x RDMAV_FORK_SAFE -x PATH -x LD_LIBRARY_PATH"

LMP_ARGS=(-in "${DECK_FILE}" -var x "${SCALE}" -var y "${SCALE}" -var z "${SCALE}" -var t "${TIMESTEPS}")

echo ""
echo "=== Running LAMMPS (${NRANK_TOTAL} ranks x ${THREADS_PER_RANK} threads) ==="
T_START=$(date +%s.%N)
# We capture stdout to log.run because LAMMPS itself writes log.lammps in
# the cwd (the file used to extract Loop time / atoms etc.).
# shellcheck disable=SC2086
mpirun -np "${NRANK_TOTAL}" --hostfile hostfile \
    ${BIND_FLAGS} ${MCA_FLAGS} ${X_ENV} \
    "${LMP_BIN}" "${LMP_ARGS[@]}" \
    2>&1 | tee log.run
T_END=$(date +%s.%N)
WALL_TIME=$(awk "BEGIN{printf \"%.2f\", ${T_END} - ${T_START}}")

LOOP_LINE="$(grep -E '^Loop time of' log.lammps | tail -1 || true)"
if [ -n "${LOOP_LINE}" ]; then
    LOOP_TIME=$(echo "${LOOP_LINE}" | awk '{print $4}')
    LOOP_STEPS=$(echo "${LOOP_LINE}" | awk '{print $9}')
    ATOMS=$(echo "${LOOP_LINE}" | awk '{print $12}')
else
    echo "WARNING: 'Loop time of ...' line not found in log.lammps" >&2
    LOOP_TIME=0
    LOOP_STEPS=0
    ATOMS=0
fi

if awk "BEGIN { exit !(${LOOP_TIME} > 0) }"; then
    TIMESTEPS_PER_SEC=$(awk "BEGIN{printf \"%.4f\", ${LOOP_STEPS} / ${LOOP_TIME}}")
    ATOM_STEPS_PER_SEC=$(awk "BEGIN{printf \"%.0f\", ${ATOMS} * ${LOOP_STEPS} / ${LOOP_TIME}}")
else
    TIMESTEPS_PER_SEC=0
    ATOM_STEPS_PER_SEC=0
fi

cat <<REPORT

================================================================================
LAMMPS benchmark results
================================================================================
Date:             $(date)
SLURM Job ID:     ${SLURM_JOB_ID}
Model:            ${MODEL}
Nodes:            ${SLURM_JOB_NUM_NODES} x ${INSTANCE_TYPE}
MPI ranks:        ${NRANK_TOTAL} (${NRANK_PER_NODE}/node)
OMP threads:      ${THREADS_PER_RANK}/rank  (total cores: ${NPROC_TOTAL})
Scale factor:     ${SCALE}
Atoms:            ${ATOMS}
Timesteps run:    ${LOOP_STEPS}
Workdir:          ${WORKDIR}

Loop time:        ${LOOP_TIME}s
Timesteps/sec:    ${TIMESTEPS_PER_SEC}
Atom-steps/sec:   ${ATOM_STEPS_PER_SEC}
Wall time:        ${WALL_TIME}s
================================================================================
REPORT

# ---------------------------------------------------------------------------
# Optional: record the result to DynamoDB.
#
# Disabled by default so customers who only want to run LAMMPS aren't
# forced to provision a DynamoDB table or grant dynamodb:PutItem to their
# compute role. To enable cross-run aggregation, deploy
# apps/LAMMPS/dynamodb/record_to_dynamodb.sh on shared storage (default
# path /fsx/lammps/scripts/dynamodb/record_to_dynamodb.sh), grant the IAM
# permission described in apps/LAMMPS/dynamodb/README.md, and uncomment
# the block below by removing the leading '# ' from each line.
# ---------------------------------------------------------------------------
# if [[ "${LD_LIBRARY_PATH:-}" == *"openmpi5"* ]]; then
#     MPI_STACK="openmpi-5"
# else
#     MPI_STACK="openmpi-4"
# fi
# DYNAMODB_RECORDER="${DYNAMODB_RECORDER:-/fsx/lammps/scripts/dynamodb/record_to_dynamodb.sh}"
# if [ -x "${DYNAMODB_RECORDER}" ]; then
#     export SLURM_JOB_ID SLURM_JOB_NUM_NODES SLURM_CLUSTER_NAME
#     export MODEL SCALE
#     export NRANK_TOTAL NRANK_PER_NODE THREADS_PER_RANK
#     export INSTANCE_TYPE REGION LAMMPS_TAG MPI_STACK
#     export ATOMS LOOP_STEPS LOOP_TIME
#     export TIMESTEPS_PER_SEC ATOM_STEPS_PER_SEC WALL_TIME
#     export WORKDIR
#     "${DYNAMODB_RECORDER}" || true
# else
#     echo "DynamoDB recorder not found at ${DYNAMODB_RECORDER} — skipping result persistence"
# fi
