#!/bin/bash
# Run an OpenRadioss HPC benchmark model (Chrysler Neon 1M or Ford Taurus 10M)
# on aarch64 nodes (Graviton3E / Graviton4) using OpenMPI + EFA.
#
# OpenRadioss is a two-stage solver:
#   * starter : single-node pre-processor that partitions the mesh into
#               NSPMD domains and writes the partitioned .rst files
#   * engine  : MPI+OpenMP parallel solver
#
# A single launcher targets both Graviton3E (hpc7g.16xlarge, 64 cores) and
# Graviton4 (m8g.48xlarge / r8g.48xlarge, 192 cores). Select the right
# build by pointing OPENRADIOSS_ENV at the appropriate env script.
#
# Override via --export=ALL,...:
#   OPENRADIOSS_ENV       path to env script (choose Graviton3 / 4 build)
#   MODEL                 neon1m (default) | taurus10m
#   THREADS_PER_RANK      OpenMP threads per MPI rank (default: 1 = pure MPI)
#   SIM_TIME              override /RUN final time in seconds
#   BASE_DIR              run output root (default: /fsx/openradioss)
#   MODEL_DIR             input deck source (default: /fsx/openradioss/models/<model>)
#
# Usage:
#   # Graviton3E (hpc7g)
#   sbatch -p hpc7g -N 1 --ntasks-per-node=64 \
#     --export=ALL,OPENRADIOSS_ENV=/fsx/openradioss/aarch64-graviton3/openradioss-latest-20260319-env.sh \
#     openradioss-benchmark.sbatch
#
#   # Graviton4 (m8g)
#   sbatch -p m8g -N 1 --ntasks-per-node=192 \
#     --export=ALL,OPENRADIOSS_ENV=/fsx/openradioss/aarch64-graviton4/openradioss-latest-20260319-env.sh \
#     openradioss-benchmark.sbatch

#SBATCH --job-name=openradioss
#SBATCH -p hpc7g
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=64
#SBATCH --time=04:00:00
#SBATCH --exclusive
#SBATCH --output=/fsx/openradioss/logs/slurm-%x-%j.out

set -euo pipefail

OPENRADIOSS_ENV="${OPENRADIOSS_ENV:-/fsx/openradioss/aarch64-graviton3/openradioss-latest-20260319-env.sh}"
MODEL="${MODEL:-neon1m}"
THREADS_PER_RANK="${THREADS_PER_RANK:-1}"
BASE_DIR="${BASE_DIR:-/fsx/openradioss}"

case "${MODEL}" in
    neon1m)
        DECK_PREFIX="NEON1M11"
        MODEL_ARCHIVE_URL="https://openradioss.atlassian.net/wiki/download/attachments/47546369/Neon1m11_2017.zip?api=v2"
        DEFAULT_MODEL_DIR="${BASE_DIR}/models/neon1m"
        ;;
    taurus10m)
        DECK_PREFIX="TAURUS_A05_FFB50"
        MODEL_ARCHIVE_URL="https://openradioss.atlassian.net/wiki/download/attachments/47546369/Taurus10M.zip?api=v2"
        DEFAULT_MODEL_DIR="${BASE_DIR}/models/taurus10m"
        ;;
    *)
        echo "Unknown MODEL: ${MODEL} (expected: neon1m | taurus10m)" >&2
        exit 1
        ;;
esac
MODEL_DIR="${MODEL_DIR:-${DEFAULT_MODEL_DIR}}"

NPROC_TOTAL=$(( SLURM_JOB_NUM_NODES * SLURM_NTASKS_PER_NODE ))
if (( THREADS_PER_RANK > 1 )); then
    NRANK_TOTAL=$(( NPROC_TOTAL / THREADS_PER_RANK ))
else
    NRANK_TOTAL=${NPROC_TOTAL}
fi
NRANK_PER_NODE=$(( SLURM_NTASKS_PER_NODE / THREADS_PER_RANK ))

TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_TYPE=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type)
WORKDIR="${BASE_DIR}/Run/${SLURM_JOB_NAME}/${MODEL}/${SLURM_CLUSTER_NAME:-cluster}/${SLURM_JOB_ID}-${SLURM_JOB_NUM_NODES}x${INSTANCE_TYPE}-${NRANK_TOTAL}x${THREADS_PER_RANK}-$(date '+%d-%m-%Y-%H-%M')"

mkdir -p "${WORKDIR}"
cd "${WORKDIR}"
cp "$0" .

echo "=== OpenRadioss benchmark (Arm) ==="
echo "Date:         $(date)"
echo "SLURM Job ID: ${SLURM_JOB_ID}"
echo "Model:        ${MODEL} (deck prefix ${DECK_PREFIX})"
echo "Nodes:        ${SLURM_JOB_NUM_NODES} x ${INSTANCE_TYPE}"
echo "MPI ranks:    ${NRANK_TOTAL} total (${NRANK_PER_NODE}/node)"
echo "OMP threads:  ${THREADS_PER_RANK}/rank -> ${NPROC_TOTAL} cores total"
echo "Workdir:      ${WORKDIR}"

if [ ! -f "${OPENRADIOSS_ENV}" ]; then
    echo "ERROR: OpenRadioss env script not found: ${OPENRADIOSS_ENV}" >&2
    exit 1
fi
set +u
source "${OPENRADIOSS_ENV}"
set -u
echo "Starter: $(which starter_linuxa64_gf)"
echo "Engine:  $(which engine_linuxa64_gf_ompi)"

# ---------------------------------------------------------------------------
# MPI / EFA sanity check: confirm we are using the system OpenMPI from
# /opt/amazon/openmpi[5] and that the EFA libfabric provider is available.
# ---------------------------------------------------------------------------
echo "=== MPI / EFA sanity ==="
echo "mpirun:          $(which mpirun)"
mpirun --version 2>&1 | head -2 | sed 's/^/  /'
echo "libfabric (fi_info -l):"
fi_info -l 2>&1 | sed 's/^/  /' | head -6
echo "libfabric EFA provider (fi_info -p efa -t FI_EP_RDM):"
fi_info -p efa -t FI_EP_RDM 2>&1 | grep -E "provider|fabric|domain|nic|version" | sed 's/^/  /' | head -10
echo "engine libfabric linkage:"
ldd "$(which engine_linuxa64_gf_ompi)" 2>/dev/null | grep -E "libmpi|libfabric|libopen-" | sed 's/^/  /'
echo

# ---------------------------------------------------------------------------
# Stage the model (shared across clusters via FSx; downloaded once).
# ---------------------------------------------------------------------------
if [ ! -d "${MODEL_DIR}" ] || [ -z "$(ls -A "${MODEL_DIR}" 2>/dev/null)" ]; then
    echo "=== Downloading ${MODEL} model ==="
    mkdir -p "${MODEL_DIR}"
    archive="${MODEL_DIR}.zip"
    curl -L -o "${archive}" "${MODEL_ARCHIVE_URL}"
    unzip -q -d "${MODEL_DIR}" "${archive}"
    rm -f "${archive}"
fi

STARTER_DECK="$(find "${MODEL_DIR}" -maxdepth 3 -name "${DECK_PREFIX}_0000.rad" | head -1)"
ENGINE_DECK="$(find "${MODEL_DIR}" -maxdepth 3 -name "${DECK_PREFIX}_0001.rad" | head -1)"
if [ -z "${STARTER_DECK}" ] || [ -z "${ENGINE_DECK}" ]; then
    echo "ERROR: could not find ${DECK_PREFIX}_0000.rad / _0001.rad under ${MODEL_DIR}" >&2
    ls -la "${MODEL_DIR}"
    exit 1
fi

# Symlink every sibling of the two decks into the workdir (Taurus
# references a relative includes/ directory); copy the decks themselves
# so any SIM_TIME override below doesn't touch the source tree.
DECK_DIR="$(dirname "${STARTER_DECK}")"
for item in "${DECK_DIR}"/*; do
    name="$(basename "${item}")"
    case "${name}" in
        "${DECK_PREFIX}_0000.rad"|"${DECK_PREFIX}_0001.rad") ;;
        *) ln -sf "${item}" "./${name}" ;;
    esac
done
cp "${STARTER_DECK}" .
cp "${ENGINE_DECK}"  .
STARTER_DECK_LOCAL="$(basename "${STARTER_DECK}")"
ENGINE_DECK_LOCAL="$(basename "${ENGINE_DECK}")"

if [ -n "${SIM_TIME:-}" ]; then
    echo "=== Overriding /RUN final time to ${SIM_TIME}s in ${ENGINE_DECK_LOCAL} ==="
    python3 - "${ENGINE_DECK_LOCAL}" "${SIM_TIME}" <<'PY'
import re, sys, pathlib
deck = pathlib.Path(sys.argv[1])
sim_time = sys.argv[2]
lines = deck.read_text().splitlines()
for i, line in enumerate(lines):
    if line.startswith("/RUN/"):
        for j in range(i + 1, len(lines)):
            raw = lines[j]
            stripped = raw.strip()
            if not stripped or stripped.startswith("#"):
                continue
            m = re.match(r"^(\s*\d+\s+)([\d.eE+-]+)(\s*)$", raw)
            if m:
                lines[j] = f"{m.group(1)}{sim_time}{m.group(3)}"
                break
            m = re.match(r"^(\s*)([\d.eE+-]+)(\s*)$", raw)
            if m:
                lines[j] = f"{m.group(1)}{sim_time}{m.group(3)}"
                break
        break
deck.write_text("\n".join(lines) + "\n")
PY
fi

echo "=== Building hostfile and tuning nodes ==="
scontrol show nodes "${SLURM_NODELIST}" \
    | grep NodeHostName= | awk '{print $2}' | sed 's/NodeHostName=//' > hostfile

srun --ntasks="${SLURM_JOB_NUM_NODES}" --ntasks-per-node=1 /bin/bash -c \
    "sync && echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null && \
     echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled >/dev/null" \
    || true

export OMP_NUM_THREADS="${THREADS_PER_RANK}"
export OMP_STACKSIZE=400M
export OMP_PLACES=cores
export OMP_PROC_BIND=close

export FI_PROVIDER=efa
export FI_EFA_USE_DEVICE_RDMA=1

MCA_FLAGS="--mca pml cm --mca mtl ofi --mca btl ^tcp,openib"
if [ "${EFA_VERBOSE:-0}" = "1" ]; then
    MCA_FLAGS="${MCA_FLAGS} --mca mtl_base_verbose 5 --mca pml_base_verbose 5"
fi
if (( THREADS_PER_RANK > 1 )); then
    BIND_FLAGS="--bind-to core --map-by ppr:${NRANK_PER_NODE}:node:PE=${THREADS_PER_RANK}"
else
    BIND_FLAGS="--bind-to core --map-by slot"
fi
X_ENV="-x OMP_NUM_THREADS -x OMP_STACKSIZE -x OMP_PLACES -x OMP_PROC_BIND -x FI_PROVIDER -x FI_EFA_USE_DEVICE_RDMA -x PATH -x LD_LIBRARY_PATH -x RAD_CFG_PATH"

echo ""
echo "=== Phase 1: Starter (nspmd=${NRANK_TOTAL}, nthread=${THREADS_PER_RANK}) ==="
T_STARTER_START=$(date +%s.%N)
starter_linuxa64_gf -i "${STARTER_DECK_LOCAL}" \
    -nspmd "${NRANK_TOTAL}" \
    -nthread "${THREADS_PER_RANK}" \
    2>&1 | tee starter.log
T_STARTER_END=$(date +%s.%N)
STARTER_TIME=$(awk "BEGIN{printf \"%.2f\", ${T_STARTER_END} - ${T_STARTER_START}}")
echo "Starter time: ${STARTER_TIME}s"

echo ""
echo "=== Phase 2: Engine (${NRANK_TOTAL} ranks x ${THREADS_PER_RANK} threads) ==="
T_ENGINE_START=$(date +%s.%N)
mpirun -np "${NRANK_TOTAL}" --hostfile hostfile \
    ${BIND_FLAGS} ${MCA_FLAGS} ${X_ENV} \
    engine_linuxa64_gf_ompi -i "${ENGINE_DECK_LOCAL}" \
    2>&1 | tee engine.log
T_ENGINE_END=$(date +%s.%N)
ENGINE_TIME=$(awk "BEGIN{printf \"%.2f\", ${T_ENGINE_END} - ${T_ENGINE_START}}")
TOTAL_TIME=$(awk "BEGIN{printf \"%.2f\", ${T_ENGINE_END} - ${T_STARTER_START}}")

ELAPSED=$(grep -E "ELAPSED TIME\s*[:=]" engine.log | tail -1 | awk '{for(i=1;i<=NF;i++) if ($i ~ /^[0-9.]+$/) t=$i; print t}' || true)

cat <<REPORT

================================================================================
OpenRadioss benchmark results
================================================================================
Date:             $(date)
SLURM Job ID:     ${SLURM_JOB_ID}
Model:            ${MODEL}
Nodes:            ${SLURM_JOB_NUM_NODES} x ${INSTANCE_TYPE}
MPI ranks:        ${NRANK_TOTAL} (${NRANK_PER_NODE}/node)
OMP threads:      ${THREADS_PER_RANK}/rank  (total cores: ${NPROC_TOTAL})
Sim. time:        ${SIM_TIME:-default}
Workdir:          ${WORKDIR}

Starter time:     ${STARTER_TIME}s
Engine time:      ${ENGINE_TIME}s
Total wall time:  ${TOTAL_TIME}s
Radioss elapsed:  ${ELAPSED:-n/a}s
================================================================================
REPORT
