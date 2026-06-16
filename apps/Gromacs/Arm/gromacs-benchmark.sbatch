#!/bin/bash
# Run a GROMACS standard MPINAT benchmark (benchMEM, benchPEP-h, STMV, or
# RNAse) on aarch64 nodes (hpc7g / Graviton3E or m8g / Graviton4) using
# OpenMPI + EFA.
#
# Like the x86 launcher, GROMACS ships TWO MPI build paths and we install
# both at build time. The launcher picks the right one based on node count:
#
#   1 node   -> source *-tmpi-env.sh, run `gmx mdrun` directly (Thread_MPI,
#               no mpirun, intra-node parallelism handled by the binary)
#   N nodes  -> source *-ompi[5]-env.sh, run `mpirun ... gmx_mpi mdrun`
#               (Library_MPI linked against OpenMPI 4.1.7 or 5.0.9, EFA
#               via libfabric)
#
# On aarch64 we support three Library_MPI builds:
#
#   * Graviton3E + OpenMPI 4 (legacy 64 ranks/node baseline)
#   * Graviton3E + OpenMPI 5 (default — recommended for full-density EFA)
#   * Graviton4  + OpenMPI 5 (required — OpenMPI 4 cannot scale to 192
#     ranks/node EFA endpoints on Neoverse V2)
#
# The combination Graviton4 + OpenMPI 4 is **rejected at submit time**
#
#
# The four benchmarks come from the upstream Max Planck Institute test set
# (https://www.mpinat.mpg.de/grubmueller/bench) and are fixed-size — there
# is no equivalent of LAMMPS lattice replication. Atom counts are roughly:
#   benchMEM    ~80,000      PME, membrane protein, the standard reference
#   benchPEP-h  ~12,000,000  Strong-scaling reference at high rank counts
#   STMV        ~1,000,000   Mid-size virus capsid in water
#   RNAse       ~24,000      Low-rank baseline / quick smoke test
#
# GROMACS prints performance to md.log on the lines:
#                  (ns/day)    (hour/ns)
#   Performance:   144.741     0.166
#   Wall t (s):     59.668
# `-resethway` discards the first half of the run from the timing so warm-up
# cost is excluded; `-noconfout` suppresses the multi-GiB per-rank confout
# write that otherwise dominates I/O at high rank counts.
#
# Optional: a commented-out block at the end of this script can record
# each run to a DynamoDB table for cross-run aggregation. It is disabled
# by default so customers don't need to provision DynamoDB. To enable,
# follow the instructions in apps/Gromacs/dynamodb/README.md and uncomment
# the marked block at the bottom of this file.
#
# Override via --export=ALL,...:
#   GROMACS_ENV         path to env script. Default: auto-selected per node
#                       count from /fsx/gromacs/aarch64-graviton4-ompi5/...
#                       (preferred) or aarch64-graviton3-ompi5/... or
#                       aarch64-graviton3/... — most recently modified wins.
#                       Set explicitly to force a particular variant
#                       (e.g. ompi5-env on a single node, or to pin to
#                       Graviton3E + OpenMPI 4 for legacy comparisons).
#   MODEL               benchMEM (default) | benchPEP-h | STMV | RNAse
#   TIMESTEPS           override the model's default -nsteps
#                       (range 1..10,000,000)
#   NSTLIST             neighbour-list rebuild interval (default 100,
#                       range 1..1,000)
#   THREADS_PER_RANK    OpenMP threads per MPI rank
#                       (default 1 = pure MPI, range 1..192)
#   BASE_DIR            run output root (default: /fsx/gromacs)
#   DYNAMODB_RECORDER   path to record_to_dynamodb.sh
#                       (default: /fsx/gromacs/scripts/dynamodb/record_to_dynamodb.sh)
#
# Usage:
#   sbatch --nodes=1 gromacs-benchmark.sbatch                                # benchMEM, 1N (Thread_MPI)
#   sbatch --nodes=4 --export=ALL,MODEL=benchPEP-h gromacs-benchmark.sbatch  # benchPEP-h, 4N (Library_MPI)
#   sbatch --nodes=2 -p m8g --ntasks-per-node=192 \
#       --export=ALL,MODEL=STMV,THREADS_PER_RANK=4 gromacs-benchmark.sbatch  # m8g, hybrid

#SBATCH --job-name=gromacs-arm
#SBATCH -p hpc7g
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=64
#SBATCH --time=02:00:00
#SBATCH --exclusive
#SBATCH --output=/fsx/gromacs/logs/gromacs_bench_arm_%j.out
#SBATCH --error=/fsx/gromacs/logs/gromacs_bench_arm_%j.err

set -euo pipefail

on_err() {
    local exit_code=$?
    local failed_line=${1:-?}
    echo "" >&2
    echo "ERROR: GROMACS benchmark failed at line ${failed_line} (exit ${exit_code})." >&2
    if [ -n "${WORKDIR:-}" ] && [ -d "${WORKDIR:-/dev/null}" ]; then
        echo "       Workdir preserved at: ${WORKDIR}" >&2
    fi
    exit "${exit_code}"
}
trap 'on_err ${LINENO}' ERR

# ---------------------------------------------------------------------------
# Override variables
# ---------------------------------------------------------------------------
MODEL="${MODEL:-benchMEM}"
NSTLIST="${NSTLIST:-100}"
THREADS_PER_RANK="${THREADS_PER_RANK:-1}"
BASE_DIR="${BASE_DIR:-/fsx/gromacs}"
DYNAMODB_RECORDER="${DYNAMODB_RECORDER:-/fsx/gromacs/scripts/dynamodb/record_to_dynamodb.sh}"

# ---------------------------------------------------------------------------
# Per-model config (design.md section 4 model table).
#   .tpr filename, default nsteps, MPINAT URL.
# Pages serve .tpr.gz archives — fetched, gunzipped, validated non-empty,
# then cached at /fsx/gromacs/benchmarks/<MODEL>/<MODEL>.tpr.
# ---------------------------------------------------------------------------
case "${MODEL}" in
    benchMEM)
        TPR_FILE="benchMEM.tpr"
        DEFAULT_TIMESTEPS=50000
        MODEL_URL="https://www.mpinat.mpg.de/benchMEM"
        ;;
    benchPEP-h)
        TPR_FILE="benchPEP-h.tpr"
        DEFAULT_TIMESTEPS=5000
        MODEL_URL="https://www.mpinat.mpg.de/benchPEP-h"
        ;;
    STMV)
        TPR_FILE="STMV.tpr"
        DEFAULT_TIMESTEPS=10000
        MODEL_URL="https://www.mpinat.mpg.de/STMV"
        ;;
    RNAse)
        TPR_FILE="RNAse.tpr"
        DEFAULT_TIMESTEPS=100000
        MODEL_URL="https://www.mpinat.mpg.de/RNAse"
        ;;
    *)
        echo "ERROR: Unknown MODEL: '${MODEL}'" >&2
        echo "       Expected one of: benchMEM | benchPEP-h | STMV | RNAse" >&2
        exit 1
        ;;
esac

TIMESTEPS="${TIMESTEPS:-${DEFAULT_TIMESTEPS}}"

# ---------------------------------------------------------------------------
# Override validation (Requirements 4.6, 7.2). Each check identifies the
# offending variable and its received value before exiting non-zero. Same
# ranges as the x86 launcher so customers can reuse parameter tables.
# ---------------------------------------------------------------------------
is_positive_int() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( $1 > 0 ))
}

if ! is_positive_int "${TIMESTEPS}" || (( TIMESTEPS < 1 || TIMESTEPS > 10000000 )); then
    echo "ERROR: TIMESTEPS='${TIMESTEPS}' invalid (expected integer in 1..10000000)" >&2
    exit 1
fi
if ! is_positive_int "${NSTLIST}" || (( NSTLIST < 1 || NSTLIST > 1000 )); then
    echo "ERROR: NSTLIST='${NSTLIST}' invalid (expected integer in 1..1000)" >&2
    exit 1
fi
if ! is_positive_int "${THREADS_PER_RANK}" || (( THREADS_PER_RANK < 1 || THREADS_PER_RANK > 192 )); then
    echo "ERROR: THREADS_PER_RANK='${THREADS_PER_RANK}' invalid (expected integer in 1..192)" >&2
    exit 1
fi
if [[ "${BASE_DIR}" != /* ]]; then
    echo "ERROR: BASE_DIR='${BASE_DIR}' is not an absolute path" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Rank / thread arithmetic (Requirements 4.6, 10.4, 10.5).
# ---------------------------------------------------------------------------
NPROC_TOTAL=$(( SLURM_JOB_NUM_NODES * SLURM_NTASKS_PER_NODE ))
if (( THREADS_PER_RANK > 1 )); then
    NRANK_TOTAL=$(( NPROC_TOTAL / THREADS_PER_RANK ))
    NRANK_PER_NODE=$(( SLURM_NTASKS_PER_NODE / THREADS_PER_RANK ))
else
    NRANK_TOTAL=${NPROC_TOTAL}
    NRANK_PER_NODE=${SLURM_NTASKS_PER_NODE}
fi

# ---------------------------------------------------------------------------
# Auto-pick GROMACS_ENV if the user didn't supply one.
#   Single node -> tmpi (no MPI dep)
#   Multi-node  -> ompi5 (default for aarch64) or ompi (Graviton3E + OMPI4)
# Search the three valid install roots in priority order, picking the most
# recently modified matching env script across all of them so a fresh build
# is auto-selected without a code change:
#   1. aarch64-graviton4-ompi5   (preferred when m8g is available)
#   2. aarch64-graviton3-ompi5   (default for hpc7g)
#   3. aarch64-graviton3         (legacy hpc7g + OpenMPI 4 fallback)
# ---------------------------------------------------------------------------
if [ -z "${GROMACS_ENV:-}" ]; then
    if (( SLURM_JOB_NUM_NODES == 1 )); then
        ENV_PATTERNS=("gromacs-*-tmpi-env.sh")
    else
        # Multi-node: prefer OpenMPI 5 env scripts, fall back to OMPI 4.
        ENV_PATTERNS=("gromacs-*-ompi5-env.sh" "gromacs-*-ompi-env.sh")
    fi
    for AARCH_DIR in \
            "${BASE_DIR}/aarch64-graviton4-ompi5" \
            "${BASE_DIR}/aarch64-graviton3-ompi5" \
            "${BASE_DIR}/aarch64-graviton3"; do
        [ -d "${AARCH_DIR}" ] || continue
        for ENV_PATTERN in "${ENV_PATTERNS[@]}"; do
            CANDIDATE="$(find "${AARCH_DIR}" -maxdepth 2 -type f \
                -name "${ENV_PATTERN}" -printf '%T@ %p\n' 2>/dev/null \
                | sort -nr | head -1 | awk '{print $2}')"
            if [ -n "${CANDIDATE}" ]; then
                GROMACS_ENV="${CANDIDATE}"
                break 2
            fi
        done
    done
    if [ -z "${GROMACS_ENV:-}" ]; then
        echo "ERROR: GROMACS_ENV unset and no auto-discovered env script found" >&2
        echo "       Searched (in priority order):" >&2
        echo "         ${BASE_DIR}/aarch64-graviton4-ompi5/*/gromacs-*-{tmpi,ompi5}-env.sh" >&2
        echo "         ${BASE_DIR}/aarch64-graviton3-ompi5/*/gromacs-*-{tmpi,ompi5}-env.sh" >&2
        echo "         ${BASE_DIR}/aarch64-graviton3/*/gromacs-*-{tmpi,ompi}-env.sh" >&2
        echo "       Set GROMACS_ENV=/path/to/gromacs-<tag>-{tmpi,ompi,ompi5}-env.sh" >&2
        exit 1
    fi
fi
if [ ! -f "${GROMACS_ENV}" ] || [ ! -r "${GROMACS_ENV}" ]; then
    echo "ERROR: GROMACS_ENV='${GROMACS_ENV}' is not a readable regular file" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# GROMACS_ENV suffix validation + Graviton4-OMPI4 reject (# 4.5). The build script never produces an aarch64-graviton4 + ompi-env
# pair, but a customer could hand-craft a path; we explicitly reject it
# here so the failure mode is visible at submit time rather than as a
# 192-rank EFA endpoint exhaustion at runtime.
# ---------------------------------------------------------------------------
case "${GROMACS_ENV}" in
    *-tmpi-env.sh|*-ompi-env.sh|*-ompi5-env.sh)
        : # supported suffix
        ;;
    *)
        echo "ERROR: GROMACS_ENV='${GROMACS_ENV}' has an unrecognised suffix" >&2
        echo "       Expected: *-tmpi-env.sh, *-ompi-env.sh, or *-ompi5-env.sh" >&2
        exit 1
        ;;
esac

if [[ "${GROMACS_ENV}" == *"aarch64-graviton4"* ]] \
        && [[ "${GROMACS_ENV}" == *"-ompi-env.sh" ]]; then
    echo "ERROR: GROMACS_ENV='${GROMACS_ENV}' pairs Graviton4 with OpenMPI 4" >&2
    echo "       This combination is rejected at submit time:" >&2
    echo "       OpenMPI 4.1.7 cannot scale to 192 ranks/node EFA endpoints on" >&2
    echo "       Neoverse V2. Use a *-ompi5-env.sh script for Graviton4." >&2
    exit 1
fi

# Decide which binary we'll invoke based on the env script flavour and node
# count. The user can force the Library_MPI variant on a single node by
# passing GROMACS_ENV=...-ompi[5]-env.sh explicitly.
case "${GROMACS_ENV}" in
    *-tmpi-env.sh)
        ENV_VARIANT="tmpi"
        ;;
    *-ompi-env.sh|*-ompi5-env.sh)
        ENV_VARIANT="ompi"
        ;;
    *)
        # Defensive — the suffix check above should have caught everything.
        if (( SLURM_JOB_NUM_NODES == 1 )); then
            ENV_VARIANT="tmpi"
        else
            ENV_VARIANT="ompi"
        fi
        ;;
esac

# Multi-node Thread_MPI is impossible — bail out with a useful message
# rather than silently producing nonsense scaling numbers.
if (( SLURM_JOB_NUM_NODES > 1 )) && [ "${ENV_VARIANT}" = "tmpi" ]; then
    echo "ERROR: GROMACS_ENV='${GROMACS_ENV}' is the Thread_MPI variant" >&2
    echo "       but the job spans ${SLURM_JOB_NUM_NODES} nodes." >&2
    echo "       Pass GROMACS_ENV=...-ompi5-env.sh (or -ompi-env.sh on" >&2
    echo "       Graviton3E) for multi-node runs." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Workdir under BASE_DIR/Run/... (Requirements 4.6, 7.x — same convention as
# the x86 launcher so cross-arch sweeps share a directory layout).
# ---------------------------------------------------------------------------
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_TYPE=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/instance-type)
# REGION is referenced by the optional DynamoDB recorder block at the
# bottom of this file (commented out by default).
# shellcheck disable=SC2034
REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/placement/region)

WORKDIR="${BASE_DIR}/Run/${SLURM_JOB_NAME}/${MODEL}/${SLURM_CLUSTER_NAME:-cluster}/${SLURM_JOB_ID}-${SLURM_JOB_NUM_NODES}x${INSTANCE_TYPE}-${NRANK_TOTAL}x${THREADS_PER_RANK}-$(date '+%d-%m-%Y-%H-%M')"

if [ -e "${WORKDIR}" ]; then
    echo "ERROR: workdir already exists: ${WORKDIR}" >&2
    echo "       Refusing to overwrite. Re-submit (new SLURM_JOB_ID) or remove it." >&2
    exit 1
fi
mkdir -p "${WORKDIR}"
cd "${WORKDIR}"
cp "$0" .

echo "=== GROMACS benchmark (aarch64) ==="
echo "Date:          $(date)"
echo "SLURM Job ID:  ${SLURM_JOB_ID}"
echo "Model:         ${MODEL} (${TPR_FILE})"
echo "Nodes:         ${SLURM_JOB_NUM_NODES} x ${INSTANCE_TYPE}"
echo "MPI ranks:     ${NRANK_TOTAL} total (${NRANK_PER_NODE}/node)"
echo "OMP threads:   ${THREADS_PER_RANK}/rank -> ${NPROC_TOTAL} cores total"
echo "Timesteps:     ${TIMESTEPS}"
echo "NSTLIST:       ${NSTLIST}"
echo "ENV_VARIANT:   ${ENV_VARIANT}"
echo "GROMACS_ENV:   ${GROMACS_ENV}"
echo "Workdir:       ${WORKDIR}"

# ---------------------------------------------------------------------------
# Source the chosen env script (loads modules, sets PATH/LD_LIBRARY_PATH/
# GMXLIB/GROMACS_TAG).
# ---------------------------------------------------------------------------
set +u
# shellcheck source=/dev/null
source "${GROMACS_ENV}"
set -u

if [ "${ENV_VARIANT}" = "tmpi" ]; then
    GMX_BIN_NAME="gmx"
else
    GMX_BIN_NAME="gmx_mpi"
fi
GMX_BIN="$(command -v "${GMX_BIN_NAME}" || true)"
if [ -z "${GMX_BIN}" ]; then
    echo "ERROR: ${GMX_BIN_NAME} not found in PATH; check ${GROMACS_ENV}" >&2
    exit 1
fi
echo "${GMX_BIN_NAME} binary:  ${GMX_BIN}"
echo "GROMACS tag:    ${GROMACS_TAG:-unknown}"

# ---------------------------------------------------------------------------
# MPI / EFA sanity check (Requirements 4.3, 10.6).
# Multi-node runs require EFA; single-node Thread_MPI bypasses MPI entirely
# and therefore doesn't depend on EFA — we still log mpirun/ldd output when
# available because that information is useful in run logs.
# ---------------------------------------------------------------------------
echo "=== MPI / EFA sanity ==="
if command -v mpirun >/dev/null 2>&1; then
    echo "mpirun:        $(command -v mpirun)"
    mpirun --version 2>&1 | head -2 | sed 's/^/  /'
else
    echo "mpirun:        (not in PATH — Thread_MPI variant)"
fi
echo "libfabric EFA provider (fi_info -p efa -t FI_EP_RDM):"
EFA_OUT="$(fi_info -p efa -t FI_EP_RDM 2>&1 || true)"
echo "${EFA_OUT}" | grep -E "provider|fabric|domain|nic|version" \
    | sed 's/^/  /' | head -10 || true
if (( SLURM_JOB_NUM_NODES > 1 )); then
    if ! echo "${EFA_OUT}" | grep -q "^provider:"; then
        echo "ERROR: fi_info -p efa reports zero EFA providers" >&2
        echo "       Multi-node GROMACS over Library_MPI requires EFA." >&2
        exit 1
    fi
fi
echo "${GMX_BIN_NAME} linkage:"
ldd "${GMX_BIN}" 2>/dev/null | grep -E "libmpi|libfabric|libopen-" \
    | sed 's/^/  /' || true
echo

# ---------------------------------------------------------------------------
# Stage benchmark input deck. The MPINAT pages currently serve <MODEL>.zip
# (one .tpr at the archive root). Older script revisions used .tpr.gz; if a
# future MPINAT layout reverts to gzip we'll fall back to gunzip. Reuse a
# non-zero cached .tpr without issuing a network request
# (Requirements 7.3, 7.4, 7.5, 7.7).
# .tpr files are architecture-agnostic so the cache is shared with x86.
# ---------------------------------------------------------------------------
BENCH_CACHE="${BASE_DIR}/benchmarks/${MODEL}"
mkdir -p "${BENCH_CACHE}"
chmod 0755 "${BENCH_CACHE}"
CACHED_TPR="${BENCH_CACHE}/${TPR_FILE}"

if [ ! -s "${CACHED_TPR}" ]; then
    echo "Downloading ${MODEL} from ${MODEL_URL}"
    TMP_DL="${BENCH_CACHE}/.${TPR_FILE}.dl.partial.$$"
    TMP_TPR="${BENCH_CACHE}/.${TPR_FILE}.partial.$$"
    if ! curl --max-time 600 --retry 3 --retry-delay 5 -fsSL \
            "${MODEL_URL}" -o "${TMP_DL}"; then
        rm -f "${TMP_DL}" "${TMP_TPR}"
        echo "ERROR: download exhausted retries and no cached ${TPR_FILE} exists" >&2
        echo "       MODEL=${MODEL}" >&2
        echo "       URL=${MODEL_URL}" >&2
        echo "       Cache=${CACHED_TPR}" >&2
        echo "       To bypass the network entirely, pre-stage the .tpr at" >&2
        echo "       ${CACHED_TPR} and re-run." >&2
        exit 1
    fi
    # Detect archive type by inspecting the first bytes — MPINAT today serves
    # zip (PK\x03\x04), older versions served gzip (1f 8b). Anything else is
    # likely already a raw .tpr (some mirrors serve uncompressed) or HTML.
    MAGIC="$(head -c 4 "${TMP_DL}" | od -An -tx1 | tr -d ' \n' || true)"
    case "${MAGIC}" in
        504b0304*)
            # ZIP. The MPINAT decks have a single .tpr at the root.
            if ! command -v unzip >/dev/null 2>&1; then
                rm -f "${TMP_DL}" "${TMP_TPR}"
                echo "ERROR: 'unzip' not in PATH; cannot extract ${MODEL_URL}" >&2
                exit 1
            fi
            INNER="$(unzip -Z1 "${TMP_DL}" 2>/dev/null \
                | grep -E "/?${TPR_FILE}\$" | head -1 || true)"
            if [ -z "${INNER}" ]; then
                rm -f "${TMP_DL}" "${TMP_TPR}"
                echo "ERROR: ${TPR_FILE} not found inside zip from ${MODEL_URL}" >&2
                echo "       Archive contents:" >&2
                unzip -Z1 "${TMP_DL}" >&2 | head -20 || true
                exit 1
            fi
            if ! unzip -p "${TMP_DL}" "${INNER}" > "${TMP_TPR}"; then
                rm -f "${TMP_DL}" "${TMP_TPR}"
                echo "ERROR: unzip of ${MODEL_URL} failed" >&2
                exit 1
            fi
            ;;
        1f8b08*)
            # gzip
            if ! gunzip -c "${TMP_DL}" > "${TMP_TPR}"; then
                rm -f "${TMP_DL}" "${TMP_TPR}"
                echo "ERROR: gunzip of ${MODEL_URL} failed" >&2
                exit 1
            fi
            ;;
        *)
            # Treat as raw .tpr (some mirrors serve uncompressed). gmx dump
            # in the next step will catch any malformed payload (e.g. HTML).
            cp "${TMP_DL}" "${TMP_TPR}"
            ;;
    esac
    rm -f "${TMP_DL}"
    if [ ! -s "${TMP_TPR}" ]; then
        rm -f "${TMP_TPR}"
        echo "ERROR: extracted ${TPR_FILE} is empty" >&2
        exit 1
    fi
    mv "${TMP_TPR}" "${CACHED_TPR}"
    chmod 0644 "${CACHED_TPR}"
else
    echo "Reusing cached ${TPR_FILE} (size $(stat -c %s "${CACHED_TPR}") bytes)"
fi
cp "${CACHED_TPR}" "${TPR_FILE}"

# ---------------------------------------------------------------------------
# Derive atom count from the cached .tpr (used in the results block and
# in the optional DynamoDB record). gmx dump prints the topology header on
# stdout; we just want the natoms line. Failure here is non-fatal.
# ---------------------------------------------------------------------------
ATOMS="$(${GMX_BIN} dump -s "${TPR_FILE}" 2>/dev/null \
    | awk '/natoms/ {print $3; exit}' || true)"
ATOMS="${ATOMS:-0}"

# ---------------------------------------------------------------------------
# Hostfile + system tuning (page-cache drop + THP enable on every node).
# Failure on any node is fatal — the run would not be
# reproducible if some nodes were tuned and others weren't.
# ---------------------------------------------------------------------------
echo "=== Building hostfile and tuning nodes ==="
scontrol show nodes "${SLURM_NODELIST}" \
    | grep NodeHostName= | awk '{print $2}' | sed 's/NodeHostName=//' > hostfile
cat hostfile | sed 's/^/  /'

if ! srun --ntasks="${SLURM_JOB_NUM_NODES}" --ntasks-per-node=1 /bin/bash -c \
        "sync && echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null && \
         echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled >/dev/null"; then
    echo "ERROR: page-cache drop / THP enable failed on at least one allocated node" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# OpenMP + EFA tuning. These vars are forwarded to every rank via -x.
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
# Rank placement (Requirements 10.4, 10.5; design Property 6).
#   THREADS_PER_RANK > 1 -> hybrid MPI+OpenMP, ppr-style binding
#   THREADS_PER_RANK == 1 -> pure MPI, map-by slot
# Graviton is single-socket (one NUMA node per package on hpc7g and m8g),
# so the LAMMPS-style flex-cores cpu-list pattern is intentionally NOT
# carried over here — there's no spread-across-CCDs problem to solve.
# ---------------------------------------------------------------------------
if (( THREADS_PER_RANK > 1 )); then
    BIND_FLAGS="--bind-to core --map-by ppr:${NRANK_PER_NODE}:node:PE=${THREADS_PER_RANK}"
else
    BIND_FLAGS="--bind-to core --map-by slot"
fi
echo "BIND_FLAGS:    ${BIND_FLAGS}"

X_ENV="-x OMP_NUM_THREADS -x OMP_PLACES -x OMP_PROC_BIND"
X_ENV="${X_ENV} -x FI_PROVIDER -x FI_EFA_USE_DEVICE_RDMA -x RDMAV_FORK_SAFE"
X_ENV="${X_ENV} -x PATH -x LD_LIBRARY_PATH -x GMXLIB"

# Three-line MCA selection block printed on its own
# lines so log-scrapers can match each token literally.
echo "pml=cm"
echo "mtl=ofi"
echo "provider=efa"

# ---------------------------------------------------------------------------
# Build mdrun args. -resethway discards the warm-up half of the run from
# the timing; -noconfout suppresses the multi-GiB confout.gro write that
# otherwise dominates I/O at high rank counts.
# ---------------------------------------------------------------------------
MDRUN_ARGS=(mdrun -s "${TPR_FILE}" -nsteps "${TIMESTEPS}" -resethway -noconfout
    -nstlist "${NSTLIST}" -deffnm md)

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
echo ""
if (( SLURM_JOB_NUM_NODES == 1 )) && [ "${ENV_VARIANT}" = "tmpi" ]; then
    echo "=== Running gmx mdrun (Thread_MPI, ${NPROC_TOTAL} cores total) ==="
    T_START=$(date +%s.%N)
    # Thread_MPI bypasses mpirun: gmx auto-detects ranks from $(nproc).
    # Pass -ntmpi / -ntomp explicitly so we use the operator-requested
    # shape rather than gmx's auto-tuner. Pinning is left to gmx's own
    # pinner. Graviton is single-socket / no SMT so the pinstride is 1.
    "${GMX_BIN}" "${MDRUN_ARGS[@]}" \
        -ntmpi "${NRANK_PER_NODE}" -ntomp "${THREADS_PER_RANK}" \
        -pin on -pinoffset 0 -pinstride 1 \
        2>&1 | tee log.run
    T_END=$(date +%s.%N)
else
    echo "=== Running gmx_mpi mdrun (${NRANK_TOTAL} ranks x ${THREADS_PER_RANK} threads) ==="
    T_START=$(date +%s.%N)
    # shellcheck disable=SC2086
    mpirun -np "${NRANK_TOTAL}" --hostfile hostfile \
        ${BIND_FLAGS} ${MCA_FLAGS} ${X_ENV} \
        "${GMX_BIN}" "${MDRUN_ARGS[@]}" \
        2>&1 | tee log.run
    T_END=$(date +%s.%N)
fi
WALL_TIME_TOTAL=$(awk "BEGIN{printf \"%.2f\", ${T_END} - ${T_START}}")

# ---------------------------------------------------------------------------
# Extract performance metrics (Requirements 4.4; design Property 3).
# GROMACS prints near the end of md.log:
#                  (ns/day)    (hour/ns)
#   Performance:   144.741     0.166
#   Wall t (s):     59.668
# Missing values -> 0 / "n/a" (non-fatal: gmx_mpi exit code is the
# authoritative success signal per design.md error-handling table).
# ---------------------------------------------------------------------------
LOG_FILE_MD="md.log"
NS_PER_DAY=0
HOUR_PER_NS=0
WALL_TIME=0

if [ -f "${LOG_FILE_MD}" ]; then
    PERF_LINE="$(grep -E '^Performance:' "${LOG_FILE_MD}" | tail -1 || true)"
    if [ -n "${PERF_LINE}" ]; then
        NS_PER_DAY=$(echo "${PERF_LINE}" | awk '{print $2}')
        HOUR_PER_NS=$(echo "${PERF_LINE}" | awk '{print $3}')
    fi
    WALL_TIME="$(awk '/^[[:space:]]*Time:/ {wall=$3} END {print (wall == "" ? 0 : wall)}' "${LOG_FILE_MD}")"
fi

if [ -z "${NS_PER_DAY}" ] || [ "${NS_PER_DAY}" = "0" ]; then
    NS_PER_DAY="0"; NS_DISPLAY="n/a"
else
    NS_DISPLAY="${NS_PER_DAY}"
fi
if [ -z "${HOUR_PER_NS}" ] || [ "${HOUR_PER_NS}" = "0" ]; then
    HOUR_PER_NS="0"; HOUR_DISPLAY="n/a"
else
    HOUR_DISPLAY="${HOUR_PER_NS}"
fi
if [ -z "${WALL_TIME}" ] || [ "${WALL_TIME}" = "0" ]; then
    WALL_TIME="0"; WALL_DISPLAY="n/a"
else
    WALL_DISPLAY="${WALL_TIME}s"
fi

# How many timesteps GROMACS actually ran (post-resethway). Best-effort
# parse — if md.log doesn't have a recognisable "Statistics over ... steps"
# line, fall back to the requested TIMESTEPS.
LOOP_STEPS="$(awk '/Statistics over [0-9]+ steps/ {for (i=1;i<=NF;i++) if ($i=="over") {print $(i+1); exit}}' "${LOG_FILE_MD}" 2>/dev/null || true)"
LOOP_STEPS="${LOOP_STEPS:-${TIMESTEPS}}"

# ---------------------------------------------------------------------------
# Run metadata (captured here so the optional DynamoDB
# block at the bottom can reference them without re-shelling out).
#
# The four metadata vars below (KERNEL_VERSION, OS_PRETTY, PC_VERSION,
# MPI_STACK) are only consumed by the commented-out DynamoDB recorder
# block at the bottom of this file. Shellcheck flags them as unused
# until the block is uncommented; same conscious pattern as REGION
# above and as the LAMMPS launcher.
# ---------------------------------------------------------------------------
MPI_VERSION="$(mpirun --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true)"
MPI_VERSION="${MPI_VERSION:-unknown}"
LIBFABRIC_VERSION="$(fi_info --version 2>/dev/null | awk '/libfabric:/ {print $2; exit}' || true)"
LIBFABRIC_VERSION="${LIBFABRIC_VERSION:-unknown}"
EFA_VERSION="$(fi_info -p efa 2>/dev/null | awk '/version:/ {print $2; exit}' || true)"
EFA_VERSION="${EFA_VERSION:-unknown}"
# shellcheck disable=SC2034
KERNEL_VERSION="$(uname -r)"
# shellcheck disable=SC2034
OS_PRETTY="unknown"
if [ -f /etc/os-release ]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    # shellcheck disable=SC2034
    OS_PRETTY="${PRETTY_NAME:-unknown}"
fi
if [ -f /opt/parallelcluster/.bootstrapped ]; then
    # shellcheck disable=SC2034
    PC_VERSION="$(sed 's/aws-parallelcluster-cookbook-//g' /opt/parallelcluster/.bootstrapped)"
else
    # shellcheck disable=SC2034
    PC_VERSION="unknown"
fi
# Derive MPI_STACK from the env-script suffix so the DynamoDB record
# disambiguates Graviton3E + OpenMPI 4 from Graviton3E + OpenMPI 5 — both
# show up as ENV_VARIANT=ompi but record different mpi_stack values per
## shellcheck disable=SC2034
MPI_STACK="tmpi"
if [ "${ENV_VARIANT}" = "ompi" ]; then
    case "${GROMACS_ENV}" in
        *-ompi5-env.sh)
            # shellcheck disable=SC2034
            MPI_STACK="openmpi-5"
            ;;
        *-ompi-env.sh)
            # shellcheck disable=SC2034
            MPI_STACK="openmpi-4"
            ;;
        *)
            # Defensive — covered by the suffix check earlier.
            if [[ "${LD_LIBRARY_PATH:-}" == *"openmpi5"* ]]; then
                # shellcheck disable=SC2034
                MPI_STACK="openmpi-5"
            else
                # shellcheck disable=SC2034
                MPI_STACK="openmpi-4"
            fi
            ;;
    esac
fi

# ---------------------------------------------------------------------------
# Results block (matches the design.md "Performance Output Format" shape).
# ---------------------------------------------------------------------------
cat <<REPORT

================================================================================
GROMACS benchmark results (aarch64)
================================================================================
Date:             $(date)
SLURM Job ID:     ${SLURM_JOB_ID}
Model:            ${MODEL}
Nodes:            ${SLURM_JOB_NUM_NODES} x ${INSTANCE_TYPE}
MPI ranks:        ${NRANK_TOTAL} (${NRANK_PER_NODE}/node)
OMP threads:      ${THREADS_PER_RANK}/rank  (total cores: ${NPROC_TOTAL})
Atoms:            ${ATOMS}
Timesteps run:    ${LOOP_STEPS}
Workdir:          ${WORKDIR}

ns/day:           ${NS_DISPLAY}
hour/ns:          ${HOUR_DISPLAY}
Wall time:        ${WALL_DISPLAY}
Wall time (job):  ${WALL_TIME_TOTAL}s
================================================================================
REPORT

# ---------------------------------------------------------------------------
# Optional: record the result to DynamoDB.
#
# Disabled by default in the public repository so customers who only want
# to run GROMACS aren't forced to provision a DynamoDB table or grant
# dynamodb:PutItem to their compute role. To enable cross-run aggregation:
#
#   1. Deploy apps/Gromacs/dynamodb/record_to_dynamodb.sh on shared
#      storage (default path /fsx/gromacs/scripts/dynamodb/record_to_dynamodb.sh
#      — override with DYNAMODB_RECORDER on the sbatch command line).
#   2. Grant the dynamodb:PutItem permission to the compute role as
#      described in apps/Gromacs/dynamodb/README.md.
#   3. Uncomment the block below by removing the leading `# ` from each
#      line. Every line of the export statements and the recorder
#      invocation must be uncommented for the call site to be active.
#
# Note: this public-repo committed file ships with the call site
# DISABLED. The cluster copy under /fsx/gromacs/scripts/Arm/ ships with
# the call site ENABLED so internal benchmark sweeps record to
# Gromacs_Benchmarks in us-east-1.
# ---------------------------------------------------------------------------
# export SLURM_JOB_ID SLURM_JOB_NUM_NODES SLURM_CLUSTER_NAME
# export MODEL
# export NRANK_TOTAL NRANK_PER_NODE THREADS_PER_RANK
# export INSTANCE_TYPE REGION
# export GROMACS_TAG MPI_STACK
# export MPI_VERSION LIBFABRIC_VERSION EFA_VERSION
# export KERNEL_VERSION OS_PRETTY PC_VERSION
# export ATOMS LOOP_STEPS
# export NS_PER_DAY HOUR_PER_NS WALL_TIME
# export WORKDIR
# if [ -x "${DYNAMODB_RECORDER}" ]; then
#     "${DYNAMODB_RECORDER}" || true
# else
#     echo "DynamoDB recorder not found at ${DYNAMODB_RECORDER} — skipping result persistence"
# fi
