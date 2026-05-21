#!/bin/bash
# Run a LAMMPS standard benchmark (LJ melt, Rhodopsin, or EAM Cu) on
# x86_64 nodes (hpc8a / hpc7a) using OpenMPI + EFA, and record the result
# to DynamoDB.
#
# LAMMPS is a single-binary MD code. Each benchmark consists of an input
# script (in.<model>) and, for some models, a data file. The bench/
# directory of the LAMMPS source repository defines three standard
# benchmarks that have been used for years to compare MD performance:
#   - lj    : 32k Lennard-Jones particles, pair potential only
#   - rhodo : 32k atom rhodopsin protein in water (PPPM long-range, SHAKE)
#   - eam   : 32k Cu atoms with EAM many-body potential
# All three accept lattice replication via -var x N -var y N -var z N,
# which scales the atom count by N^3 — useful for weak scaling.
#
# Override via --export=ALL,...:
#   LAMMPS_ENV         path to env script (default: latest x86_64 build)
#   MODEL              lj (default) | rhodo | eam
#   SCALE              lattice replication factor (default: 1)
#                      atom count scales as SCALE^3
#   TIMESTEPS          override the deck's default number of timesteps
#   THREADS_PER_RANK   OpenMP threads per MPI rank (default: 1 = pure MPI)
#   BASE_DIR           run output root (default: /fsx/lammps)
#
# Usage:
#   sbatch --nodes=1 lammps-benchmark.sbatch                    # LJ, 1N
#   sbatch --nodes=4 --export=ALL,MODEL=rhodo lammps-benchmark.sbatch
#   sbatch --nodes=8 --export=ALL,MODEL=eam,SCALE=2 lammps-benchmark.sbatch

#SBATCH --job-name=lammps
#SBATCH -p hpc8a
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=192
#SBATCH --time=02:00:00
#SBATCH --exclusive
#SBATCH --output=/fsx/lammps/logs/slurm-%x-%j.out

set -euo pipefail

LAMMPS_ENV="${LAMMPS_ENV:-/fsx/lammps/x86_64/lammps-stable_2Aug2023_update3-env.sh}"
MODEL="${MODEL:-lj}"
SCALE="${SCALE:-1}"
THREADS_PER_RANK="${THREADS_PER_RANK:-1}"
BASE_DIR="${BASE_DIR:-/fsx/lammps}"
DYNAMODB_TABLE="${DYNAMODB_TABLE:-LAMMPS_Benchmarks}"
DYNAMODB_REGION="${DYNAMODB_REGION:-us-east-1}"

# ---------------------------------------------------------------------------
# Per-model config: input file, default timesteps, extra files needed.
# All three input scripts come from the LAMMPS bench/ directory and are
# tiny (~1 KB) — we cache them on FSx so a single download covers every
# job submitted on either cluster.
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Workdir under BASE_DIR/Run/...
# ---------------------------------------------------------------------------
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_TYPE=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type)
REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)
WORKDIR="${BASE_DIR}/Run/${SLURM_JOB_NAME}/${MODEL}/${SLURM_CLUSTER_NAME:-cluster}/${SLURM_JOB_ID}-${SLURM_JOB_NUM_NODES}x${INSTANCE_TYPE}-${NRANK_TOTAL}x${THREADS_PER_RANK}-s${SCALE}-$(date '+%d-%m-%Y-%H-%M')"

mkdir -p "${WORKDIR}"
cd "${WORKDIR}"
cp "$0" .

echo "=== LAMMPS benchmark ==="
echo "Date:          $(date)"
echo "SLURM Job ID:  ${SLURM_JOB_ID}"
echo "Model:         ${MODEL} (${DECK_FILE})"
echo "Nodes:         ${SLURM_JOB_NUM_NODES} x ${INSTANCE_TYPE}"
echo "MPI ranks:     ${NRANK_TOTAL} total (${NRANK_PER_NODE}/node)"
echo "OMP threads:   ${THREADS_PER_RANK}/rank -> ${NPROC_TOTAL} cores total"
echo "Scale factor:  ${SCALE} (atom count scales as SCALE^3)"
echo "Timesteps:     ${TIMESTEPS}"
echo "Workdir:       ${WORKDIR}"

# ---------------------------------------------------------------------------
# Source LAMMPS env (loads modules, sets PATH/LD_LIBRARY_PATH).
# ---------------------------------------------------------------------------
if [ ! -f "${LAMMPS_ENV}" ]; then
    echo "ERROR: LAMMPS env script not found: ${LAMMPS_ENV}" >&2
    echo "Set LAMMPS_ENV=/path/to/lammps-<tag>-env.sh" >&2
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
# MPI / EFA sanity check (printed once at job start so the run log has
# evidence of the EFA path).
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
# Stage benchmark input files. The bench/ scripts and data files come from
# the upstream LAMMPS repo and are tiny — we cache them once on FSx and
# reuse forever.
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

# ---------------------------------------------------------------------------
# OpenMP + EFA tuning
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Build LAMMPS command line. The bench/ scripts use -var x/y/z to control
# lattice replication, and the LJ deck supports -var t for an alternative
# timestep override; here we set the run length via the universal
# `-var t N` followed by `run $t`. Since not all decks have that pattern,
# we use the safer LAMMPS `-var` and rely on the deck's existing $x/$y/$z
# variables (defined in all three bench scripts).
# ---------------------------------------------------------------------------
LMP_ARGS=(-in "${DECK_FILE}" -var x "${SCALE}" -var y "${SCALE}" -var z "${SCALE}")

# Some decks (in.rhodo) use -var t for timesteps; others (in.lj, in.eam)
# don't. Pass it anyway — LAMMPS silently ignores unknown -var values
# unless they're referenced.
LMP_ARGS+=(-var t "${TIMESTEPS}")

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Extract performance metrics. LAMMPS prints, near the end of the run:
#   Loop time of <float> on <int> procs for <int> steps with <int> atoms
# We pull each value with a single awk pass and tolerate missing data so a
# crashed run still produces a well-formed results block.
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Results block
# ---------------------------------------------------------------------------
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
# Record to DynamoDB. Failure is non-fatal — local logs are the source of
# truth, the table is just a convenience index across runs.
# ---------------------------------------------------------------------------
echo "=== Recording results to DynamoDB (${DYNAMODB_TABLE} in ${DYNAMODB_REGION}) ==="

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

# Pick MPI stack tag based on which OpenMPI was loaded.
if [[ "${LD_LIBRARY_PATH:-}" == *"openmpi5"* ]] || [[ "${MPI_VERSION}" == 5.* ]]; then
    MPI_STACK="openmpi-5"
else
    MPI_STACK="openmpi-4"
fi

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
