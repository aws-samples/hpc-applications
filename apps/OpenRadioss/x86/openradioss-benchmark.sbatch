#!/bin/bash
# Run an OpenRadioss HPC benchmark model (Chrysler Neon 1M or Ford Taurus 10M)
# on x86_64 nodes using OpenMPI + EFA.
#
# OpenRadioss is a two-stage solver:
#   * starter : single-node pre-processor that partitions the mesh into
#               NSPMD domains and writes the partitioned .rst files
#   * engine  : MPI+OpenMP parallel solver
#
# Defaults are set up for a single hpc8a.96xlarge node (192 cores) running
# the Neon 1M model. Use MODEL=taurus10m plus --nodes for scaling tests.
#
# Override via --export=ALL,...:
#   OPENRADIOSS_ENV       path to env script (default: latest x86_64 build)
#   MODEL                 neon1m (default) | taurus10m
#   THREADS_PER_RANK      OpenMP threads per MPI rank (default: 1 = pure MPI).
#                         Try 2 or 4 for larger scales to reduce inter-rank
#                         communication.
#   SIM_TIME              override /RUN final time (seconds). Useful on
#                         Taurus: default 0.12001s runs ~2h on 1N; set
#                         0.01001 for a ~10 min fast scaling test, or
#                         0.00201 for ~2 min smoke.
#   BASE_DIR              run output root (default: /fsx/openradioss)
#   MODEL_DIR             input deck source (default: /fsx/openradioss/models/<model>)
#
# Usage:
#   sbatch --nodes=1 openradioss-benchmark.sbatch             # Neon 1M, 1N
#   sbatch --nodes=4 --export=ALL,MODEL=taurus10m,SIM_TIME=0.01001 openradioss-benchmark.sbatch

#SBATCH --job-name=openradioss
#SBATCH -p hpc8a
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=192
#SBATCH --time=04:00:00
#SBATCH --exclusive
#SBATCH --output=/fsx/openradioss/logs/slurm-%x-%j.out

set -euo pipefail

OPENRADIOSS_ENV="${OPENRADIOSS_ENV:-/fsx/openradioss/x86_64/openradioss-latest-20260319-env.sh}"
MODEL="${MODEL:-neon1m}"
THREADS_PER_RANK="${THREADS_PER_RANK:-1}"
BASE_DIR="${BASE_DIR:-/fsx/openradioss}"

# Model-specific config: deck filename prefix and download URL.
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

# ---------------------------------------------------------------------------
# Prepare workdir under BASE_DIR/Run/... using the same shape as the other
# repo benchmark scripts (job id, node count, instance type, date)
# ---------------------------------------------------------------------------
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_TYPE=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type)
WORKDIR="${BASE_DIR}/Run/${SLURM_JOB_NAME}/${MODEL}/${SLURM_CLUSTER_NAME:-cluster}/${SLURM_JOB_ID}-${SLURM_JOB_NUM_NODES}x${INSTANCE_TYPE}-${NRANK_TOTAL}x${THREADS_PER_RANK}-$(date '+%d-%m-%Y-%H-%M')"

mkdir -p "${WORKDIR}"
cd "${WORKDIR}"
cp "$0" .

echo "=== OpenRadioss benchmark ==="
echo "Date:         $(date)"
echo "SLURM Job ID: ${SLURM_JOB_ID}"
echo "Model:        ${MODEL} (deck prefix ${DECK_PREFIX})"
echo "Nodes:        ${SLURM_JOB_NUM_NODES} x ${INSTANCE_TYPE}"
echo "MPI ranks:    ${NRANK_TOTAL} total (${NRANK_PER_NODE}/node)"
echo "OMP threads:  ${THREADS_PER_RANK}/rank -> ${NPROC_TOTAL} cores total"
echo "Workdir:      ${WORKDIR}"

# ---------------------------------------------------------------------------
# Load the OpenRadioss environment (sets PATH, RAD_CFG_PATH, loads OpenMPI).
# ---------------------------------------------------------------------------
if [ ! -f "${OPENRADIOSS_ENV}" ]; then
    echo "ERROR: OpenRadioss env script not found: ${OPENRADIOSS_ENV}" >&2
    echo "Set OPENRADIOSS_ENV=/path/to/openradioss-<tag>-env.sh" >&2
    exit 1
fi
set +u
source "${OPENRADIOSS_ENV}"
set -u
echo "Starter: $(which starter_linux64_gf)"
echo "Engine:  $(which engine_linux64_gf_ompi)"

# ---------------------------------------------------------------------------
# MPI / EFA sanity check: confirm we are using the system OpenMPI from
# /opt/amazon/openmpi and that the EFA libfabric provider is available.
# Prints once at job start so the run log has evidence of the EFA path.
# ---------------------------------------------------------------------------
echo "=== MPI / EFA sanity ==="
echo "mpirun:          $(which mpirun)"
mpirun --version 2>&1 | head -2 | sed 's/^/  /'
echo "libfabric (fi_info -l):"
fi_info -l 2>&1 | sed 's/^/  /' | head -6
echo "libfabric EFA provider (fi_info -p efa -t FI_EP_RDM):"
fi_info -p efa -t FI_EP_RDM 2>&1 | grep -E "provider|fabric|domain|nic|version" | sed 's/^/  /' | head -10
echo "engine libfabric linkage:"
ldd "$(which engine_linux64_gf_ompi)" 2>/dev/null | grep -E "libmpi|libfabric|libopen-" | sed 's/^/  /'
echo

# ---------------------------------------------------------------------------
# Stage the model (download + unzip once per cluster, then copy locally).
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

# The deck may reference relative includes (Taurus has an `includes/`
# sub-directory with hundreds of *.inc / *.xref files), so symlink every
# sibling of the two decks into the workdir. The decks themselves are
# copied so any SIM_TIME override below doesn't modify the source.
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

# Apply SIM_TIME override if requested (Taurus has 3 recommended times).
if [ -n "${SIM_TIME:-}" ]; then
    echo "=== Overriding /RUN final time to ${SIM_TIME}s in ${ENGINE_DECK_LOCAL} ==="
    python3 - "${ENGINE_DECK_LOCAL}" "${SIM_TIME}" <<'PY'
import re, sys, pathlib
deck = pathlib.Path(sys.argv[1])
sim_time = sys.argv[2]
lines = deck.read_text().splitlines()
for i, line in enumerate(lines):
    if line.startswith("/RUN/"):
        # Walk subsequent lines; skip comments, blanks, and the stop cycle
        # count. Replace the first line that looks like a plain float
        # (Taurus) or "<cycles> <time>" (Neon) pair.
        for j in range(i + 1, len(lines)):
            raw = lines[j]
            stripped = raw.strip()
            if not stripped or stripped.startswith("#"):
                continue
            # Neon-style: "   1   0.08"  -> two tokens (int, float)
            m = re.match(r"^(\s*\d+\s+)([\d.eE+-]+)(\s*)$", raw)
            if m:
                lines[j] = f"{m.group(1)}{sim_time}{m.group(3)}"
                break
            # Taurus-style: "             0.0020" -> single float
            m = re.match(r"^(\s*)([\d.eE+-]+)(\s*)$", raw)
            if m:
                lines[j] = f"{m.group(1)}{sim_time}{m.group(3)}"
                break
        break
deck.write_text("\n".join(lines) + "\n")
PY
fi

# ---------------------------------------------------------------------------
# Build hostfile and prep system tuning knobs.
# ---------------------------------------------------------------------------
echo "=== Building hostfile and tuning nodes ==="
scontrol show nodes "${SLURM_NODELIST}" \
    | grep NodeHostName= | awk '{print $2}' | sed 's/NodeHostName=//' > hostfile

srun --ntasks="${SLURM_JOB_NUM_NODES}" --ntasks-per-node=1 /bin/bash -c \
    "sync && echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null && \
     echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled >/dev/null" \
    || true

# ---------------------------------------------------------------------------
# OpenMP + EFA tuning. Pure MPI (threads=1) uses one rank per core; hybrid
# builds benefit from pinning threads onto physical cores of the same NUMA
# node as the owning rank.
# ---------------------------------------------------------------------------
export OMP_NUM_THREADS="${THREADS_PER_RANK}"
export OMP_STACKSIZE=400M
export OMP_PLACES=cores
export OMP_PROC_BIND=close

export FI_PROVIDER=efa
export FI_EFA_USE_DEVICE_RDMA=1

MCA_FLAGS="--mca pml cm --mca mtl ofi --mca btl ^tcp,openib"
if [ "${EFA_VERBOSE:-0}" = "1" ]; then
    # Print OpenMPI's MCA component selection at startup so the engine.log
    # shows exactly which PML / MTL / BTL was picked (should be pml=cm,
    # mtl=ofi, provider=efa).
    MCA_FLAGS="${MCA_FLAGS} --mca mtl_base_verbose 5 --mca pml_base_verbose 5"
fi
if (( THREADS_PER_RANK > 1 )); then
    BIND_FLAGS="--bind-to core --map-by ppr:${NRANK_PER_NODE}:node:PE=${THREADS_PER_RANK}"
else
    BIND_FLAGS="--bind-to core --map-by slot"
fi
X_ENV="-x OMP_NUM_THREADS -x OMP_STACKSIZE -x OMP_PLACES -x OMP_PROC_BIND -x FI_PROVIDER -x FI_EFA_USE_DEVICE_RDMA -x PATH -x LD_LIBRARY_PATH -x RAD_CFG_PATH"

# ---------------------------------------------------------------------------
# Phase 1: STARTER — writes partitioned .rst files (one per domain).
# Starter needs -nspmd = NRANK_TOTAL, -nthread = THREADS_PER_RANK.
# ---------------------------------------------------------------------------
echo ""
echo "=== Phase 1: Starter (nspmd=${NRANK_TOTAL}, nthread=${THREADS_PER_RANK}) ==="
T_STARTER_START=$(date +%s.%N)
starter_linux64_gf -i "${STARTER_DECK_LOCAL}" \
    -nspmd "${NRANK_TOTAL}" \
    -nthread "${THREADS_PER_RANK}" \
    2>&1 | tee starter.log
T_STARTER_END=$(date +%s.%N)
STARTER_TIME=$(awk "BEGIN{printf \"%.2f\", ${T_STARTER_END} - ${T_STARTER_START}}")
echo "Starter time: ${STARTER_TIME}s"

# ---------------------------------------------------------------------------
# Phase 2: ENGINE — MPI solver. One rank per domain, OMP_NUM_THREADS threads
# per rank.
# ---------------------------------------------------------------------------
echo ""
echo "=== Phase 2: Engine (${NRANK_TOTAL} ranks x ${THREADS_PER_RANK} threads) ==="
T_ENGINE_START=$(date +%s.%N)
mpirun -np "${NRANK_TOTAL}" --hostfile hostfile \
    ${BIND_FLAGS} ${MCA_FLAGS} ${X_ENV} \
    engine_linux64_gf_ompi -i "${ENGINE_DECK_LOCAL}" \
    2>&1 | tee engine.log
T_ENGINE_END=$(date +%s.%N)
ENGINE_TIME=$(awk "BEGIN{printf \"%.2f\", ${T_ENGINE_END} - ${T_ENGINE_START}}")
TOTAL_TIME=$(awk "BEGIN{printf \"%.2f\", ${T_ENGINE_END} - ${T_STARTER_START}}")

# Pull the engine-reported "ELAPSED TIME" number from the engine log (this is
# Radioss' own wall-time measurement inside the solve loop).
ELAPSED=$(grep -E "ELAPSED TIME\s*[:=]" engine.log | tail -1 | awk '{for(i=1;i<=NF;i++) if ($i ~ /^[0-9.]+$/) t=$i; print t}' || true)

# ---------------------------------------------------------------------------
# Results block
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Record this benchmark to the AI-Powered HPC dataset (best-effort, non-fatal).
# The recorder self-collects host details from the environment; this launch
# script passes the engine (solver) wall time as time-to-solution, plus the
# starter/total/Radioss-elapsed times as extra metrics. A recorder problem
# NEVER fails a good solve (`|| echo`, and set -e already aborts a failed solve
# before this point). Point DYNAMODB_RECORDER at the script if it isn't found
# automatically; set SOURCE=<YourOrg> to tag your contributions.
# See apps/OpenRadioss/dynamodb/README.md and apps/BENCHMARK-RECORDERS.md.
# ---------------------------------------------------------------------------
_or_version="$(basename "${OPENRADIOSS_ENV}" 2>/dev/null | sed -E 's/^openradioss-//; s/-env\.sh$//' || true)"
case "${MODEL}" in
    neon1m)    _or_elems="1"  ;;
    taurus10m) _or_elems="10" ;;
    *)         _or_elems=""   ;;
esac
_or_elapsed="${ELAPSED:-}"; case "${_or_elapsed}" in ""|*[!0-9.]*) _or_elapsed="" ;; esac
_recorder="${DYNAMODB_RECORDER:-}"
for _c in "${_recorder}" \
          "${SLURM_SUBMIT_DIR:-.}/../dynamodb/record-benchmark.sh" \
          "${SLURM_SUBMIT_DIR:-.}/dynamodb/record-benchmark.sh" \
          "${SLURM_SUBMIT_DIR:-.}/apps/OpenRadioss/dynamodb/record-benchmark.sh"; do
    if [ -n "${_c}" ] && [ -x "${_c}" ]; then _recorder="${_c}"; break; fi
done
if [ -n "${_recorder}" ] && [ -x "${_recorder}" ]; then
    OPENRADIOSS_VERSION="${_or_version}" BENCHMARK_CASE="${MODEL}" \
    NUM_ELEMENTS_MILLION="${_or_elems}" ANALYSIS_TYPE="explicit" \
    TIME_TO_SOLUTION="${ENGINE_TIME}" RUN_DIR="${WORKDIR}" "${_recorder}" \
        --metric "starter_seconds=${STARTER_TIME}" --metric "total_seconds=${TOTAL_TIME}" \
        --metric "radioss_elapsed_seconds=${_or_elapsed}" \
        || echo "NOTE: benchmark recorder failed (non-fatal); the solve was unaffected." >&2
else
    echo "NOTE: benchmark recorder not found; set DYNAMODB_RECORDER=/path/to/record-benchmark.sh to record." >&2
fi
