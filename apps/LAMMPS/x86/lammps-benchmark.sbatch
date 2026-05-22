#!/bin/bash
# Run a LAMMPS standard benchmark (LJ melt, Rhodopsin, or EAM Cu) on
# x86_64 nodes (hpc8a / hpc7a) using OpenMPI + EFA.
#
# Optional: a commented-out block at the end of this script can record
# each run to a DynamoDB table for cross-run aggregation. It is disabled
# by default so customers don't need to provision DynamoDB. To enable,
# follow the instructions in apps/LAMMPS/dynamodb/README.md and uncomment
# the marked block at the bottom of this file.
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
    rhodo_scaled)
        # in.rhodo.scaled is the same Rhodopsin protein in water as
        # in.rhodo, but the input deck replicates the box via -var x/y/z
        # so the atom count grows as 32000 * x*y*z instead of 32000 * x^3
        # (LJ-style). Used by Murata-Manufacturing's published
        # benchmark with -var x 16 -var y 16 -var z 16 -> ~131M atoms.
        DECK_FILE="in.rhodo.scaled"
        DEFAULT_TIMESTEPS=100
        EXTRA_FILES=("data.rhodo")
        ;;
    eam)
        DECK_FILE="in.eam"
        DEFAULT_TIMESTEPS=100
        EXTRA_FILES=("Cu_u3.eam")
        ;;
    *)
        echo "ERROR: Unknown MODEL: ${MODEL} (expected: lj | rhodo | rhodo_scaled | eam)" >&2
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
# REGION is referenced by the optional DynamoDB recorder block at the
# bottom of this file (commented out by default).
# shellcheck disable=SC2034
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

# ---------------------------------------------------------------------------
# Rank placement.
#
# Three regimes:
#   1. Hybrid MPI + OpenMP                  -> map-by ppr:rpn:node:PE=t
#   2. Pure MPI, fewer ranks/node than cores
#      ("flex-cores" subset benchmarking)   -> --bind-to cpu-list:ordered
#                                              with a hand-tuned list that
#                                              spreads ranks symmetrically
#                                              across all 24 CCDs and both
#                                              sockets, exposing the full L3
#                                              cache to a smaller rank set.
#                                              See Utils/flexible-cores/.
#   3. Pure MPI at full density (all 192 c) -> map-by slot
#
# Supported flex-cores rank-per-node values (mirroring
# Utils/flexible-cores/hello-cpu.openmpi.explicit.sbatch):
#     24, 48, 72, 96, 120, 144, 168, 192
# Any other rank count falls back to map-by slot.
# ---------------------------------------------------------------------------
TOTAL_CORES_PER_NODE="${SLURM_CPUS_ON_NODE:-${SLURM_NTASKS_PER_NODE}}"
FLEX_CPU_LIST=""
if (( THREADS_PER_RANK == 1 )) && (( NRANK_PER_NODE < TOTAL_CORES_PER_NODE )); then
    case ${NRANK_PER_NODE} in
        24)
            FLEX_CPU_LIST="0,8,16,24,32,40,48,56,64,72,80,88,96,104,112,120,128,136,144,152,160,168,176,184" ;;
        48)
            FLEX_CPU_LIST="0,4,8,12,16,20,24,28,32,36,40,44,48,52,56,60,64,68,72,76,80,84,88,92,96,100,104,108,112,116,120,124,128,132,136,140,144,148,152,156,160,164,168,172,176,180,184,188" ;;
        72)
            FLEX_CPU_LIST="0,1,2,8,9,10,16,17,18,24,25,26,32,33,34,40,41,42,48,49,50,56,57,58,64,65,66,72,73,74,80,81,82,88,89,90,96,97,98,104,105,106,112,113,114,120,121,122,128,129,130,136,137,138,144,145,146,152,153,154,160,161,162,168,169,170,176,177,178,184,185,186" ;;
        96)
            FLEX_CPU_LIST="0,2,4,6,8,10,12,14,16,18,20,22,24,26,28,30,32,34,36,38,40,42,44,46,48,50,52,54,56,58,60,62,64,66,68,70,72,74,76,78,80,82,84,86,88,90,92,94,96,98,100,102,104,106,108,110,112,114,116,118,120,122,124,126,128,130,132,134,136,138,140,142,144,146,148,150,152,154,156,158,160,162,164,166,168,170,172,174,176,178,180,182,184,186,188,190" ;;
        120)
            FLEX_CPU_LIST="0,1,2,3,4,8,9,10,11,12,16,17,18,19,20,24,25,26,27,28,32,33,34,35,36,40,41,42,43,44,48,49,50,51,52,56,57,58,59,60,64,65,66,67,68,72,73,74,75,76,80,81,82,83,84,88,89,90,91,92,96,97,98,99,100,104,105,106,107,108,112,113,114,115,116,120,121,122,123,124,128,129,130,131,132,136,137,138,139,140,144,145,146,147,148,152,153,154,155,156,160,161,162,163,164,168,169,170,171,172,176,177,178,179,180,184,185,186,187,188" ;;
        144)
            FLEX_CPU_LIST="0,1,2,3,4,5,8,9,10,11,12,13,16,17,18,19,20,21,24,25,26,27,28,29,32,33,34,35,36,37,40,41,42,43,44,45,48,49,50,51,52,53,56,57,58,59,60,61,64,65,66,67,68,69,72,73,74,75,76,77,80,81,82,83,84,85,88,89,90,91,92,93,96,97,98,99,100,101,104,105,106,107,108,109,112,113,114,115,116,117,120,121,122,123,124,125,128,129,130,131,132,133,136,137,138,139,140,141,144,145,146,147,148,149,152,153,154,155,156,157,160,161,162,163,164,165,168,169,170,171,172,173,176,177,178,179,180,181,184,185,186,187,188,189" ;;
        168)
            FLEX_CPU_LIST="0,1,2,3,4,5,6,8,9,10,11,12,13,14,16,17,18,19,20,21,22,24,25,26,27,28,29,30,32,33,34,35,36,37,38,40,41,42,43,44,45,46,48,49,50,51,52,53,54,56,57,58,59,60,61,62,64,65,66,67,68,69,70,72,73,74,75,76,77,78,80,81,82,83,84,85,86,88,89,90,91,92,93,94,96,97,98,99,100,101,102,104,105,106,107,108,109,110,112,113,114,115,116,117,118,120,121,122,123,124,125,126,128,129,130,131,132,133,134,136,137,138,139,140,141,142,144,145,146,147,148,149,150,152,153,154,155,156,157,158,160,161,162,163,164,165,166,168,169,170,171,172,173,174,176,177,178,179,180,181,182,184,185,186,187,188,189,190" ;;
        *)
            : ;;  # fall through to map-by slot
    esac
fi

if (( THREADS_PER_RANK > 1 )); then
    BIND_FLAGS="--bind-to core --map-by ppr:${NRANK_PER_NODE}:node:PE=${THREADS_PER_RANK}"
elif [ -n "${FLEX_CPU_LIST}" ]; then
    BIND_FLAGS="--bind-to cpu-list:ordered --cpu-list ${FLEX_CPU_LIST}"
    echo "Flex-cores: pinning ${NRANK_PER_NODE} ranks/node via cpu-list (see Utils/flexible-cores/)"
else
    BIND_FLAGS="--bind-to core --map-by slot"
fi
echo "BIND_FLAGS:    ${BIND_FLAGS}"
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
