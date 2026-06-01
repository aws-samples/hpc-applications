#!/bin/bash
# Run a GROMACS standard MPINAT benchmark (benchMEM, benchPEP-h, STMV, or
# RNAse) on x86_64 + CUDA nodes across three GPU families — g6e / L40S,
# g7e / Blackwell RTX PRO 6000, p5 / H100 — with single-GPU Thread_MPI or
# multi-GPU Thread_MPI/Library_MPI.
#
# Phase 3 (GPU) launcher. Pairs with build_gromacs_gpu.sbatch (GROMACS
# v2026.1 on CUDA 13). The offload split (-bonded / -update) is left
# overridable because -update gpu aborts benchMEM under GPU LINCS; it
# defaults to GROMACS auto so each system runs the split GROMACS deems
# valid. Capture the measured optimum per (model, GPU family) in
# apps/Gromacs/README.md rather than freezing it here.
#
# Like the CPU launchers, GROMACS ships TWO MPI build paths and we install
# both at build time. The launcher picks the right one based on GPU_COUNT
# and the number of GPUs visible on a single node:
#
#   GPU_COUNT == 1                 -> source *-tmpi-env.sh, run `gmx mdrun`
#                                     directly (Thread_MPI, single GPU).
#                                     `-gpu_id 0`.
#   1 < GPU_COUNT <= GPUs/node     -> source *-tmpi-env.sh, run `gmx mdrun`
#                                     with `-ntmpi GPU_COUNT` and
#                                     `-gpu_id 0,1,...,(GPU_COUNT-1)`.
#                                     Thread_MPI handles intra-node parallel.
#   GPU_COUNT > GPUs/node          -> source *-ompi[5]-env.sh, run
#                                     `mpirun -np GPU_COUNT ... gmx_mpi
#                                     mdrun` with one rank per GPU.
#                                     EFA via libfabric for inter-node.
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
# GPU offload split:
#   We pass `-nb gpu -pme gpu -bonded "${GPU_BONDED:-auto}" -update
#   "${GPU_UPDATE:-auto}"`. -nb / -pme always run on the GPU; -bonded and
#   -update default to GROMACS `auto` because forcing `-update gpu` aborts
#   benchMEM (GPU LINCS cannot handle its coupled constraints). Override
#   GPU_BONDED / GPU_UPDATE (gpu|cpu|auto) to force a split during tuning.
#   Capture the measured optimum in apps/Gromacs/README.md.
#
# Optional: a commented-out block at the end of this script can record
# each run to a DynamoDB table for cross-run aggregation. It is disabled
# by default so customers don't need to provision DynamoDB. To enable,
# follow the instructions in apps/Gromacs/dynamodb/README.md and uncomment
# the marked block at the bottom of this file. The GPU launcher additionally
# exports GPU_COUNT and CUDA_VERSION so the recorder appends those fields to
# the DynamoDB record (Requirement 11.5, 11.6 — Phase 3 extension).
#
# Override via --export=ALL,...:
#   GROMACS_ENV         path to env script. Default: auto-selected per
#                       GPU_COUNT vs. detected GPUs/node from
#                       /fsx/gromacs/x86_64-cuda*-{l40s,blackwell,h100}/<tag>/.
#                       Most recently modified matching env script wins.
#                       Set explicitly to force a particular variant
#                       (e.g. ompi-env on a single node, or to pin to a
#                       specific CUDA / GPU build).
#   MODEL               benchMEM (default) | benchPEP-h | STMV | RNAse
#   TIMESTEPS           override the model's default -nsteps
#                       (range 1..10,000,000)
#   NSTLIST             neighbour-list rebuild interval (default 100,
#                       range 1..1,000)
#   GPU_COUNT           number of GPUs to use (default 1, range
#                       1..min(8, nvidia-smi -L count))
#   BASE_DIR            run output root (default: /fsx/gromacs)
#   DYNAMODB_RECORDER   path to record_to_dynamodb.sh
#                       (default: /fsx/gromacs/scripts/dynamodb/record_to_dynamodb.sh)
#
# Usage:
#   sbatch --gres=gpu:1 gromacs-benchmark.sbatch                              # benchMEM, 1 GPU
#   sbatch --gres=gpu:4 --export=ALL,GPU_COUNT=4 gromacs-benchmark.sbatch     # benchMEM, 4 GPUs (Thread_MPI)
#   sbatch --gres=gpu:8 --export=ALL,GPU_COUNT=8,MODEL=STMV gromacs-benchmark.sbatch
#   sbatch -p p5 --nodes=2 --gres=gpu:8 \
#       --export=ALL,GPU_COUNT=16,MODEL=benchPEP-h gromacs-benchmark.sbatch   # Library_MPI, 2 nodes

#SBATCH --job-name=gromacs-gpu
#SBATCH -p g6e
#SBATCH --nodes=1
#SBATCH --gres=gpu:1
#SBATCH --time=03:00:00
#SBATCH --exclusive
#SBATCH --output=/fsx/gromacs/logs/gromacs_bench_gpu_%j.out
#SBATCH --error=/fsx/gromacs/logs/gromacs_bench_gpu_%j.err

set -euo pipefail

on_err() {
    local exit_code=$?
    local failed_line=${1:-?}
    echo "" >&2
    echo "ERROR: GROMACS GPU benchmark failed at line ${failed_line} (exit ${exit_code})." >&2
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
GPU_COUNT="${GPU_COUNT:-1}"
BASE_DIR="${BASE_DIR:-/fsx/gromacs}"
DYNAMODB_RECORDER="${DYNAMODB_RECORDER:-/fsx/gromacs/scripts/dynamodb/record_to_dynamodb.sh}"

# ---------------------------------------------------------------------------
# Per-model config (Requirement 7.1, design.md section 4 model table).
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
# Override validation (Requirements 6.1, 6.2, 7.2). Each check identifies
# the offending variable and its received value before exiting non-zero.
# Same TIMESTEPS / NSTLIST ranges as the CPU launchers so customers can
# reuse parameter tables.
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
if [[ "${BASE_DIR}" != /* ]]; then
    echo "ERROR: BASE_DIR='${BASE_DIR}' is not an absolute path" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# GPU detection + GPU_COUNT validation (Requirement 6.2).
# Requires nvidia-smi on the compute node — present on g6e and p5 by
# default. The supported range is 1..min(8, detected GPUs/node).
# ---------------------------------------------------------------------------
if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "ERROR: nvidia-smi not found on PATH; this script requires an NVIDIA GPU node" >&2
    exit 1
fi

GPUS_PER_NODE="$(nvidia-smi -L 2>/dev/null | wc -l | tr -d '[:space:]')"
if [ -z "${GPUS_PER_NODE}" ] || [ "${GPUS_PER_NODE}" = "0" ]; then
    echo "ERROR: nvidia-smi -L reports zero GPUs on the compute node" >&2
    exit 1
fi

# Effective max is min(8, GPUs/node). The hard ceiling at 8 mirrors
# Requirement 6.2 — single-node L40S / H100 SKUs ship up to 8 GPUs and we
# do not validate >8 multi-node configurations as part of Phase 3.
GPU_MAX=8
if (( GPUS_PER_NODE < GPU_MAX )); then
    GPU_MAX=${GPUS_PER_NODE}
fi

if ! is_positive_int "${GPU_COUNT}" \
        || (( GPU_COUNT < 1 || GPU_COUNT > 8 )) \
        || (( GPU_COUNT > GPU_MAX )); then
    echo "ERROR: GPU_COUNT='${GPU_COUNT}' invalid" >&2
    echo "       Expected integer in 1..min(8, detected GPUs/node)" >&2
    echo "       Detected GPUs/node: ${GPUS_PER_NODE}" >&2
    echo "       Effective max:      ${GPU_MAX}" >&2
    exit 1
fi

# Multi-node hint: GPU_COUNT > GPUs/node implies the user must launch the
# job across multiple nodes via --nodes=N --gres=gpu:G. We *cannot* expand
# a single-node allocation to multiple nodes from inside the script, so we
# fail fast with a descriptive message rather than running 8 ranks on one
# node.
if (( GPU_COUNT > GPUS_PER_NODE )); then
    if (( SLURM_JOB_NUM_NODES <= 1 )); then
        echo "ERROR: GPU_COUNT=${GPU_COUNT} exceeds GPUs/node (${GPUS_PER_NODE})" >&2
        echo "       but the job spans only ${SLURM_JOB_NUM_NODES} node." >&2
        echo "       Re-submit with --nodes=N --gres=gpu:${GPUS_PER_NODE}" >&2
        echo "       such that N * GPUs/node >= GPU_COUNT." >&2
        exit 1
    fi
    if (( GPU_COUNT > SLURM_JOB_NUM_NODES * GPUS_PER_NODE )); then
        echo "ERROR: GPU_COUNT=${GPU_COUNT} exceeds total GPUs in allocation" >&2
        echo "       (${SLURM_JOB_NUM_NODES} nodes x ${GPUS_PER_NODE} GPUs/node = $((SLURM_JOB_NUM_NODES * GPUS_PER_NODE)))" >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Auto-pick GROMACS_ENV if the user didn't supply one (Requirement 6.3,
# 6.4, 6.5). Strategy:
#   GPU_COUNT <= GPUs/node  -> tmpi env (single-node multi-GPU Thread_MPI)
#   GPU_COUNT > GPUs/node   -> ompi env (multi-node Library_MPI)
# Search both x86_64-cuda*-l40s and x86_64-cuda*-h100 install roots and
# pick the most recently modified matching env script so a fresh build is
# auto-selected without a code change.
# ---------------------------------------------------------------------------
if [ -z "${GROMACS_ENV:-}" ]; then
    if (( GPU_COUNT <= GPUS_PER_NODE )); then
        ENV_PATTERNS=("gromacs-*-tmpi-env.sh")
    else
        # Multi-node: prefer OpenMPI 5 env scripts (Library_MPI), fall back
        # to OMPI 4. Either is supported by the GPU build script.
        ENV_PATTERNS=("gromacs-*-ompi5-env.sh" "gromacs-*-ompi-env.sh")
    fi
    BEST_CANDIDATE=""
    BEST_MTIME=0
    for CUDA_DIR in "${BASE_DIR}"/x86_64-cuda*-l40s "${BASE_DIR}"/x86_64-cuda*-blackwell "${BASE_DIR}"/x86_64-cuda*-h100; do
        [ -d "${CUDA_DIR}" ] || continue
        for ENV_PATTERN in "${ENV_PATTERNS[@]}"; do
            CANDIDATE_LINE="$(find "${CUDA_DIR}" -maxdepth 2 -type f \
                -name "${ENV_PATTERN}" -printf '%T@ %p\n' 2>/dev/null \
                | sort -nr | head -1)"
            [ -n "${CANDIDATE_LINE}" ] || continue
            CAND_MTIME="${CANDIDATE_LINE%% *}"
            CAND_PATH="${CANDIDATE_LINE#* }"
            # Compare mtimes as integers (drop fractional part).
            CAND_MTIME_INT="${CAND_MTIME%%.*}"
            if (( CAND_MTIME_INT > BEST_MTIME )); then
                BEST_MTIME=${CAND_MTIME_INT}
                BEST_CANDIDATE="${CAND_PATH}"
            fi
        done
    done
    GROMACS_ENV="${BEST_CANDIDATE}"
    if [ -z "${GROMACS_ENV}" ]; then
        echo "ERROR: GROMACS_ENV unset and no auto-discovered env script found" >&2
        echo "       Searched:" >&2
        echo "         ${BASE_DIR}/x86_64-cuda*-l40s/*/gromacs-*-{tmpi,ompi,ompi5}-env.sh" >&2
        echo "         ${BASE_DIR}/x86_64-cuda*-blackwell/*/gromacs-*-{tmpi,ompi,ompi5}-env.sh" >&2
        echo "         ${BASE_DIR}/x86_64-cuda*-h100/*/gromacs-*-{tmpi,ompi,ompi5}-env.sh" >&2
        echo "       Set GROMACS_ENV=/path/to/gromacs-<tag>-{tmpi,ompi,ompi5}-env.sh" >&2
        exit 1
    fi
fi
if [ ! -f "${GROMACS_ENV}" ] || [ ! -r "${GROMACS_ENV}" ]; then
    echo "ERROR: GROMACS_ENV='${GROMACS_ENV}' is not a readable regular file" >&2
    exit 1
fi

# Decide which binary we'll invoke based on the env script flavour and the
# GPU_COUNT vs. GPUs/node relationship. The user can force the Library_MPI
# variant on a single node by passing GROMACS_ENV=...-ompi[5]-env.sh.
case "${GROMACS_ENV}" in
    *-tmpi-env.sh)
        ENV_VARIANT="tmpi"
        ;;
    *-ompi-env.sh|*-ompi5-env.sh)
        ENV_VARIANT="ompi"
        ;;
    *)
        # Defensive — fall back to GPU_COUNT vs. GPUs/node rule.
        if (( GPU_COUNT <= GPUS_PER_NODE )); then
            ENV_VARIANT="tmpi"
        else
            ENV_VARIANT="ompi"
        fi
        ;;
esac

# Multi-node Thread_MPI is impossible — bail out with a useful message
# rather than silently producing nonsense scaling numbers.
if (( GPU_COUNT > GPUS_PER_NODE )) && [ "${ENV_VARIANT}" = "tmpi" ]; then
    echo "ERROR: GROMACS_ENV='${GROMACS_ENV}' is the Thread_MPI variant" >&2
    echo "       but GPU_COUNT=${GPU_COUNT} exceeds GPUs/node (${GPUS_PER_NODE})." >&2
    echo "       Pass GROMACS_ENV=...-ompi[5]-env.sh for multi-node GPU runs." >&2
    exit 1
fi

# Determine the GPU instance family (l40s | h100) from the env script path
# so the run directory and the DynamoDB record disambiguate g6e vs. p5
# results without re-shelling out to nvidia-smi after sourcing the env.
case "${GROMACS_ENV}" in
    *-l40s/*) GPU_TARGET_TAG="l40s" ;;
    *-blackwell/*) GPU_TARGET_TAG="blackwell" ;;
    *-h100/*) GPU_TARGET_TAG="h100" ;;
    *)
        # Fall back to nvidia-smi if the path doesn't encode the target.
        gpu_name_probe="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || true)"
        case "${gpu_name_probe}" in
            *H100*) GPU_TARGET_TAG="h100" ;;
            *L40S*|*L40s*) GPU_TARGET_TAG="l40s" ;;
            *"RTX PRO 6000"*|*Blackwell*) GPU_TARGET_TAG="blackwell" ;;
            *) GPU_TARGET_TAG="unknown" ;;
        esac
        ;;
esac

# ---------------------------------------------------------------------------
# Workdir under BASE_DIR/Run/... — same convention as the CPU launchers
# but the path encodes <gpu_count>g<gpu_target> in place of the
# <ranks>x<threads> token so a 4-GPU sweep is distinguishable from an
# 8-GPU sweep at a glance.
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

WORKDIR="${BASE_DIR}/Run/${SLURM_JOB_NAME}/${MODEL}/${SLURM_CLUSTER_NAME:-cluster}/${SLURM_JOB_ID}-${SLURM_JOB_NUM_NODES}x${INSTANCE_TYPE}-${GPU_COUNT}g${GPU_TARGET_TAG}-$(date '+%d-%m-%Y-%H-%M')"

if [ -e "${WORKDIR}" ]; then
    echo "ERROR: workdir already exists: ${WORKDIR}" >&2
    echo "       Refusing to overwrite. Re-submit (new SLURM_JOB_ID) or remove it." >&2
    exit 1
fi
mkdir -p "${WORKDIR}"
cd "${WORKDIR}"
cp "$0" .

echo "=== GROMACS GPU benchmark ==="
echo "Date:          $(date)"
echo "SLURM Job ID:  ${SLURM_JOB_ID}"
echo "Model:         ${MODEL} (${TPR_FILE})"
echo "Nodes:         ${SLURM_JOB_NUM_NODES} x ${INSTANCE_TYPE}"
echo "GPUs/node:     ${GPUS_PER_NODE}"
echo "GPU_COUNT:     ${GPU_COUNT}"
echo "GPU target:    ${GPU_TARGET_TAG}"
echo "Timesteps:     ${TIMESTEPS}"
echo "NSTLIST:       ${NSTLIST}"
echo "ENV_VARIANT:   ${ENV_VARIANT}"
echo "GROMACS_ENV:   ${GROMACS_ENV}"
echo "Workdir:       ${WORKDIR}"

# ---------------------------------------------------------------------------
# nvidia-smi topo -m at job start (Requirement 6.8). Captured here so the
# topology is in the slurm log even if the benchmark fails downstream.
# Also write a one-line summary into the run log so log scrapers can match
# `GPU topology:` literally without parsing the full nvidia-smi table.
# ---------------------------------------------------------------------------
echo ""
echo "=== nvidia-smi topo -m ==="
TOPO_FILE="${WORKDIR}/nvidia-smi-topo.txt"
nvidia-smi topo -m 2>&1 | tee "${TOPO_FILE}"

# Classify the inter-GPU fabric (Requirement 6.5) by scanning the upper
# triangle of the nvidia-smi topo matrix. The matrix uses tokens like NV#
# (NVLink generation #), NVS (NVSwitch), PXB / PIX / NODE / SYS (PCIe of
# decreasing locality). We classify in priority order:
#   * any NVS occurrence  -> "NVSwitch"  (p5 H100, all-to-all NVSwitch)
#   * any NV# occurrence  -> "NVLink"    (NVLink point-to-point)
#   * any PIX/PXB/NODE    -> "PCIe"      (no high-speed inter-GPU fabric)
#   * else                -> "unknown"
GPU_TOPO_CLASS="unknown"
if grep -qE '\bNVS\b' "${TOPO_FILE}"; then
    GPU_TOPO_CLASS="NVSwitch"
elif grep -qE '\bNV[0-9]+\b' "${TOPO_FILE}"; then
    GPU_TOPO_CLASS="NVLink"
elif grep -qE '\b(PIX|PXB|NODE|SYS)\b' "${TOPO_FILE}"; then
    GPU_TOPO_CLASS="PCIe"
fi
echo "GPU topology: ${GPU_TOPO_CLASS} (${GPU_COUNT} GPU(s) requested, ${GPUS_PER_NODE} GPU(s)/node)"
echo ""

# ---------------------------------------------------------------------------
# Source the chosen env script (loads CUDA module, modules, sets PATH /
# LD_LIBRARY_PATH / GMXLIB / GROMACS_TAG / CUDA_VISIBLE_DEVICES default).
# ---------------------------------------------------------------------------
set +u
# shellcheck source=/dev/null
source "${GROMACS_ENV}"
set -u

# Constrain CUDA_VISIBLE_DEVICES to the first GPU_COUNT GPUs so a job that
# requested --gres=gpu:4 doesn't accidentally touch GPUs 4..7. The env
# script already sets a default covering 0..N-1 of the build host; we
# tighten that to 0..GPU_COUNT-1 here per Requirement 6.3 / 6.4.
if (( GPU_COUNT == 1 )); then
    CUDA_VISIBLE_DEVICES="0"
else
    CUDA_VISIBLE_DEVICES="$(seq -s, 0 $((GPU_COUNT - 1)))"
fi
export CUDA_VISIBLE_DEVICES
echo "CUDA_VISIBLE_DEVICES: ${CUDA_VISIBLE_DEVICES}"

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

# Capture the CUDA toolkit version on the running node for the DynamoDB
# record (Requirement 6.7's GPU extension to the schema). nvcc may not be
# on PATH at run time even when the build had it; fall back to the
# nvidia-smi driver-side CUDA version line.
# shellcheck disable=SC2034
CUDA_VERSION="unknown"
# NOTE: avoid 'cmd | awk ...exit...' pipelines here — awk closing the pipe
# early sends SIGPIPE upstream, which under 'set -o pipefail' aborts the whole
# script (exit 141). Capture into a variable first, then parse, with || true.
if command -v nvcc >/dev/null 2>&1; then
    _nvcc_out="$(nvcc --version 2>/dev/null || true)"
    CUDA_VERSION="$(printf '%s\n' "${_nvcc_out}" | awk '/release/ {print $(NF-1)}' | tr -d ',' || true)"
fi
if [ -z "${CUDA_VERSION}" ] || [ "${CUDA_VERSION}" = "unknown" ]; then
    _smi_out="$(nvidia-smi 2>/dev/null || true)"
    CUDA_VERSION="$(printf '%s\n' "${_smi_out}" | awk '/CUDA Version:/ {for (i=1;i<=NF;i++) if ($i=="Version:") {print $(i+1)}}' | head -1 | tr -d ',' || true)"
    CUDA_VERSION="${CUDA_VERSION:-unknown}"
fi
echo "CUDA version:   ${CUDA_VERSION}"

# ---------------------------------------------------------------------------
# MPI / EFA sanity check (Requirements 2.3, 2.4, 2.5, 10.6 — apply only on
# multi-node Library_MPI runs). Single-node Thread_MPI bypasses MPI and
# EFA entirely, so we just log mpirun / ldd output without enforcing EFA
# providers.
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
if (( GPU_COUNT > GPUS_PER_NODE )); then
    if ! echo "${EFA_OUT}" | grep -q "^provider:"; then
        echo "ERROR: fi_info -p efa reports zero EFA providers" >&2
        echo "       Multi-node GPU runs over Library_MPI require EFA." >&2
        exit 1
    fi
fi
echo "${GMX_BIN_NAME} linkage:"
ldd "${GMX_BIN}" 2>/dev/null | grep -E "libmpi|libfabric|libopen-|libcuda|libcudart|libnvToolsExt" \
    | sed 's/^/  /' || true
echo

# ---------------------------------------------------------------------------
# Stage benchmark input deck. The MPINAT pages serve <MODEL>.tpr.gz —
# fetch, gunzip, validate non-empty, cache. Reuse a non-zero cached .tpr
# without issuing a network request (Requirements 7.3, 7.4, 7.5, 7.7).
# .tpr files are architecture-agnostic so the cache is shared with the
# CPU launchers.
# ---------------------------------------------------------------------------
BENCH_CACHE="${BASE_DIR}/benchmarks/${MODEL}"
mkdir -p "${BENCH_CACHE}"
chmod 0755 "${BENCH_CACHE}"
CACHED_TPR="${BENCH_CACHE}/${TPR_FILE}"

if [ ! -s "${CACHED_TPR}" ]; then
    echo "Downloading ${MODEL} from ${MODEL_URL}"
    TMP_GZ="${BENCH_CACHE}/.${TPR_FILE}.gz.partial.$$"
    TMP_TPR="${BENCH_CACHE}/.${TPR_FILE}.partial.$$"
    if ! curl --max-time 600 --retry 3 --retry-delay 5 -fsSL \
            "${MODEL_URL}" -o "${TMP_GZ}"; then
        rm -f "${TMP_GZ}" "${TMP_TPR}"
        echo "ERROR: download exhausted retries and no cached ${TPR_FILE} exists" >&2
        echo "       MODEL=${MODEL}" >&2
        echo "       URL=${MODEL_URL}" >&2
        echo "       Cache=${CACHED_TPR}" >&2
        exit 1
    fi
    if ! gunzip -c "${TMP_GZ}" > "${TMP_TPR}"; then
        rm -f "${TMP_GZ}" "${TMP_TPR}"
        echo "ERROR: gunzip of ${MODEL_URL} failed" >&2
        exit 1
    fi
    rm -f "${TMP_GZ}"
    if [ ! -s "${TMP_TPR}" ]; then
        rm -f "${TMP_TPR}"
        echo "ERROR: downloaded ${TPR_FILE} is empty" >&2
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
# Failure on any node is fatal — the run would not be reproducible if some
# nodes were tuned and others weren't.
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
# OpenMP + EFA tuning. With GPU_COUNT == 1 we let GROMACS auto-pick the
# OMP thread count (one process owns the whole node's CPU side); with
# GPU_COUNT > 1 we give each rank an even share of the visible cores.
# These vars are forwarded to every rank via -x for multi-node runs.
# ---------------------------------------------------------------------------
NPROC_PER_NODE="$(nproc 2>/dev/null || echo 1)"
if (( GPU_COUNT == 1 )); then
    OMP_NUM_THREADS="${NPROC_PER_NODE}"
elif (( GPU_COUNT <= GPUS_PER_NODE )); then
    # Single-node multi-GPU Thread_MPI: GPU_COUNT ranks share the node's
    # cores. Round down to keep the product <= NPROC_PER_NODE.
    OMP_NUM_THREADS="$(( NPROC_PER_NODE / GPU_COUNT ))"
    if (( OMP_NUM_THREADS < 1 )); then
        OMP_NUM_THREADS=1
    fi
else
    # Multi-node Library_MPI: GPUs/node ranks per node, share the node's
    # cores between them.
    OMP_NUM_THREADS="$(( NPROC_PER_NODE / GPUS_PER_NODE ))"
    if (( OMP_NUM_THREADS < 1 )); then
        OMP_NUM_THREADS=1
    fi
fi
export OMP_NUM_THREADS
export OMP_PLACES=cores
export OMP_PROC_BIND=close
echo "OMP_NUM_THREADS: ${OMP_NUM_THREADS} (NPROC_PER_NODE=${NPROC_PER_NODE})"

export FI_PROVIDER=efa
export FI_EFA_USE_DEVICE_RDMA=1
export RDMAV_FORK_SAFE=1

MCA_FLAGS="--mca plm_rsh_agent ssh --mca pml cm --mca mtl ofi --mca btl ^tcp,openib"
if [ "${EFA_VERBOSE:-0}" = "1" ]; then
    MCA_FLAGS="${MCA_FLAGS} --mca mtl_base_verbose 5 --mca pml_base_verbose 5"
fi

# Multi-node bind/map: one rank per GPU per node. ppr keeps each rank
# pinned to its own subset of cores.
BIND_FLAGS="--bind-to core --map-by ppr:${GPUS_PER_NODE}:node:PE=${OMP_NUM_THREADS}"
echo "BIND_FLAGS:    ${BIND_FLAGS}"

X_ENV="-x OMP_NUM_THREADS -x OMP_PLACES -x OMP_PROC_BIND"
X_ENV="${X_ENV} -x FI_PROVIDER -x FI_EFA_USE_DEVICE_RDMA -x RDMAV_FORK_SAFE"
X_ENV="${X_ENV} -x PATH -x LD_LIBRARY_PATH -x GMXLIB"
X_ENV="${X_ENV} -x CUDA_VISIBLE_DEVICES"

# Three-line MCA selection block (Requirement 10.6) printed on its own
# lines so log-scrapers can match each token literally. Always emitted —
# the tokens are constants and cheap to log even on single-GPU runs.
echo "pml=cm"
echo "mtl=ofi"
echo "provider=efa"

# ---------------------------------------------------------------------------
# Build mdrun args (Requirement 6.6).
#
# `-nb gpu -pme gpu` always offload non-bonded and PME to the GPU. `-bonded`
# and `-update` are overridable knobs (GPU_BONDED / GPU_UPDATE, gpu|cpu|auto)
# defaulting to GROMACS `auto`: forcing `-update gpu` aborts systems with 3+
# coupled constraints (e.g. benchMEM) via the GPU LINCS path, so we let
# GROMACS pick a valid split per system. Capture the measured optimum per
# (model, GPU family) in apps/Gromacs/README.md rather than freezing it here.
#
# `-resethway` discards the warm-up half of the run from the timing.
# `-noconfout` suppresses the per-rank confout.gro write.
#
# PME tuning vs -resethway: on large systems (benchPEP-h, ~12M atoms) PME
# auto-tuning is still active at the -resethway midpoint, which makes the
# counter reset fail fatally ("PME tuning was still active when attempting to
# reset mdrun counters"). We disable PME tuning with -notunepme for that model
# so the reset (and thus the warm-up exclusion) is deterministic. Smaller
# systems converge PME tuning well before the midpoint and keep tuning on.
# Override TUNEPME=on to force tuning back on for experimentation.
# ---------------------------------------------------------------------------
GPU_BONDED="${GPU_BONDED:-auto}"
GPU_UPDATE="${GPU_UPDATE:-auto}"
MDRUN_ARGS=(mdrun -s "${TPR_FILE}" -nsteps "${TIMESTEPS}" -resethway -noconfout
    -nstlist "${NSTLIST}"
    -nb gpu -pme gpu -bonded "${GPU_BONDED}" -update "${GPU_UPDATE}"
    -deffnm md)

# Disable PME tuning for the large benchPEP-h system (see note above), unless
# the user explicitly re-enables it with TUNEPME=on.
if [ "${MODEL}" = "benchPEP-h" ] && [ "${TUNEPME:-off}" != "on" ]; then
    MDRUN_ARGS+=(-notunepme)
fi

# Multi-rank PME-on-GPU requires a dedicated PME rank. With `-pme gpu` and
# more than one rank, GROMACS refuses to auto-split PME across ranks and
# demands an explicit `-npme` ("PME tasks were required to run on GPUs with
# multiple ranks but the -npme option was not specified"). One PME rank is
# the correct choice for single-node multi-GPU GROMACS, so we pass `-npme 1`
# whenever GPU_COUNT > 1. Single-GPU runs leave PME on the one rank's GPU.
NPME_ARGS=()
if (( GPU_COUNT > 1 )); then
    NPME_ARGS=(-npme 1)
fi

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
echo ""
if [ "${ENV_VARIANT}" = "tmpi" ]; then
    if (( GPU_COUNT == 1 )); then
        echo "=== Running gmx mdrun (Thread_MPI, 1 GPU) ==="
        T_START=$(date +%s.%N)
        "${GMX_BIN}" "${MDRUN_ARGS[@]}" \
            -gpu_id 0 \
            2>&1 | tee log.run
        T_END=$(date +%s.%N)
    else
        # Single-node multi-GPU Thread_MPI: -ntmpi == GPU_COUNT, one rank
        # per GPU. -gpu_id 0,1,...,(GPU_COUNT-1). -npme 1 dedicates one rank
        # to PME (required for PME-on-GPU with >1 rank).
        GPU_ID_LIST="$(seq -s, 0 $((GPU_COUNT - 1)))"
        echo "=== Running gmx mdrun (Thread_MPI, ${GPU_COUNT} GPUs, gpu_id=${GPU_ID_LIST}, npme=1) ==="
        T_START=$(date +%s.%N)
        "${GMX_BIN}" "${MDRUN_ARGS[@]}" \
            -ntmpi "${GPU_COUNT}" \
            "${NPME_ARGS[@]}" \
            -gpu_id "${GPU_ID_LIST}" \
            2>&1 | tee log.run
        T_END=$(date +%s.%N)
    fi
else
    # Library_MPI: one rank per GPU across the allocation. CUDA_VISIBLE_DEVICES
    # is forwarded via -x; libcuda picks the local GPU per rank. -npme 1
    # dedicates one rank to PME (required for PME-on-GPU with >1 rank).
    echo "=== Running gmx_mpi mdrun (Library_MPI, ${GPU_COUNT} GPUs across ${SLURM_JOB_NUM_NODES} nodes) ==="
    T_START=$(date +%s.%N)
    # shellcheck disable=SC2086
    mpirun -np "${GPU_COUNT}" --hostfile hostfile \
        ${BIND_FLAGS} ${MCA_FLAGS} ${X_ENV} \
        "${GMX_BIN}" "${MDRUN_ARGS[@]}" "${NPME_ARGS[@]}" \
        2>&1 | tee log.run
    T_END=$(date +%s.%N)
fi
WALL_TIME_TOTAL=$(awk "BEGIN{printf \"%.2f\", ${T_END} - ${T_START}}")

# ---------------------------------------------------------------------------
# Extract performance metrics (Requirement 6.7; design Property 3).
# Same extraction logic as the CPU phases — GROMACS prints near the end of
# md.log:
#                  (ns/day)    (hour/ns)
#   Performance:   144.741     0.166
#   Wall t (s):     59.668
# Missing values -> 0 / "n/a" (non-fatal: gmx exit code is the
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
# Run metadata (captured here so the optional DynamoDB block at the
# bottom can reference them without re-shelling out).
#
# The metadata vars below (KERNEL_VERSION, OS_PRETTY, PC_VERSION,
# MPI_STACK, NRANK_TOTAL, NRANK_PER_NODE, THREADS_PER_RANK) are only
# consumed by the commented-out DynamoDB recorder block at the bottom of
# this file. Shellcheck flags them as unused until the block is
# uncommented; same conscious pattern as REGION above and as the CPU
# launchers.
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
# disambiguates Thread_MPI from the two OpenMPI generations.
# shellcheck disable=SC2034
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

# Rank / thread accounting for the DynamoDB record.
#   NRANK_TOTAL    = total ranks across the allocation
#   NRANK_PER_NODE = ranks per node (= GPUs/node for multi-node, GPU_COUNT
#                    for single-node)
#   THREADS_PER_RANK = OMP_NUM_THREADS (already computed above)
if (( GPU_COUNT > GPUS_PER_NODE )); then
    # shellcheck disable=SC2034
    NRANK_TOTAL="${GPU_COUNT}"
    # shellcheck disable=SC2034
    NRANK_PER_NODE="${GPUS_PER_NODE}"
else
    # shellcheck disable=SC2034
    NRANK_TOTAL="${GPU_COUNT}"
    # shellcheck disable=SC2034
    NRANK_PER_NODE="${GPU_COUNT}"
fi
# shellcheck disable=SC2034
THREADS_PER_RANK="${OMP_NUM_THREADS}"

# ---------------------------------------------------------------------------
# Results block (matches the design.md "Performance Output Format" shape,
# extended with GPU-specific lines).
# ---------------------------------------------------------------------------
cat <<REPORT

================================================================================
GROMACS GPU benchmark results
================================================================================
Date:             $(date)
SLURM Job ID:     ${SLURM_JOB_ID}
Model:            ${MODEL}
Nodes:            ${SLURM_JOB_NUM_NODES} x ${INSTANCE_TYPE}
GPUs:             ${GPU_COUNT} (${GPU_TARGET_TAG})
GPU topology:     ${GPU_TOPO_CLASS}
MPI ranks:        ${NRANK_TOTAL} (${NRANK_PER_NODE}/node)
OMP threads:      ${THREADS_PER_RANK}/rank
Atoms:            ${ATOMS}
Timesteps run:    ${LOOP_STEPS}
CUDA version:     ${CUDA_VERSION}
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
# Phase 3 GPU runs additionally export GPU_COUNT and CUDA_VERSION; the
# recorder appends `gpu_count` and `cuda_version` attributes to the
# DynamoDB record only when both are set (Requirement 11.5, 11.6).
#
# Note: this public-repo committed file ships with the call site
# DISABLED. The cluster copy under /fsx/gromacs/scripts/GPU/ ships with
# the call site ENABLED so internal benchmark sweeps record to
# Gromacs_Benchmarks in us-east-1 (Requirement 11.9).
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
# export GPU_COUNT CUDA_VERSION
# if [ -x "${DYNAMODB_RECORDER}" ]; then
#     "${DYNAMODB_RECORDER}" || true
# else
#     echo "DynamoDB recorder not found at ${DYNAMODB_RECORDER} — skipping result persistence"
# fi
