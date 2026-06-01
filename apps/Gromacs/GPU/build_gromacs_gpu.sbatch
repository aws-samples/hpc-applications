#!/bin/bash
# Build GROMACS for x86_64 + CUDA across three GPU families using GCC + nvcc:
#   g6e / L40S                  (Ada Lovelace, sm_89)
#   g7e / Blackwell RTX PRO 6000 (Blackwell,   sm_120)
#   p5  / H100                  (Hopper,       sm_90)
#
# Phase 3 (GPU). Pins GROMACS v2026.1 on CUDA 13: the GPU nodes ship CUDA 13.0
# and GROMACS 2024.4 cannot build against CUDA 13 (upstream added CUDA 13
# support in 2025.3). v2026.1 also matches the team's reference MPS document.
#   https://www.gromacs.org/   https://gitlab.com/gromacs/gromacs
#
# Like the x86 / Arm builds, this script produces TWO CMake variants and
# installs both:
#
#   1. Thread_MPI + CUDA (`gmx`):       single-node multi-GPU. Built with
#                                       -DGMX_MPI=OFF -DGMX_THREAD_MPI=ON.
#                                       Used by the benchmark launcher when
#                                       GPU_COUNT <= GPUs-per-node.
#
#   2. Library_MPI + CUDA (`gmx_mpi`):  multi-node GPU runs under mpirun.
#                                       Built with -DGMX_MPI=ON
#                                       -DGMX_THREAD_MPI=OFF and linked
#                                       against the system OpenMPI.
#
# Both variants share the same CUDA flags (-DGMX_GPU=CUDA,
# -DGMX_CUDA_TARGET_SM=<per-target>, --use_fast_math). The host SIMD level is
# auto-detected from /proc/cpuinfo (the g6e / p5 host CPUs do not all advertise
# AVX-512), and -march=native is passed to the host compiler. For a GPU build
# the host SIMD barely matters because force / PME / bonded / update run on the
# GPU.
#
# Toolchain: GROMACS 2026 needs C++20 (GCC >= 12) and CMake >= 3.28, and the
# Blackwell sm_120 target needs a recent nvcc. We use the AL2023 GCC 14
# packages (installed as /usr/bin/gcc14-gcc, gcc14-g++) and a CMake 3.28.3
# staged on shared FSx.
#
# Override via --export=ALL,...:
#   GROMACS_TAG     git tag from https://gitlab.com/gromacs/gromacs
#                   (default: v2026.1)
#   BASE_DIR        install root (default: /fsx/gromacs)
#   GPU_TARGET      l40s | h100 | blackwell | auto (default — auto-detects
#                   from nvidia-smi --query-gpu=name)
#   CUDA_TOOLKIT    CUDA major version on PATH (default: 13 — must be >= 13)
#   OMPI_VERSION    4 (default) or 5
#   COMPILE_CORES   parallel compile threads (default: 48)

#SBATCH --job-name=build-gromacs-gpu
#SBATCH -p g6e
#SBATCH --nodes=1
#SBATCH --gres=gpu:1
#SBATCH --time=03:00:00
#SBATCH --exclusive
#SBATCH --output=/fsx/gromacs/logs/build_gpu_%j.out
#SBATCH --error=/fsx/gromacs/logs/build_gpu_%j.err

set -euo pipefail

GROMACS_TAG="${GROMACS_TAG:-v2026.1}"
BASE_DIR="${BASE_DIR:-/fsx/gromacs}"
GPU_TARGET="${GPU_TARGET:-auto}"
CUDA_TOOLKIT="${CUDA_TOOLKIT:-13}"
OMPI_VERSION="${OMPI_VERSION:-4}"
COMPILE_CORES="${COMPILE_CORES:-48}"

LOG_DIR="${BASE_DIR}/logs"
mkdir -p "${LOG_DIR}"

LOG_FILE="${LOG_DIR}/build_gpu_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "${LOG_FILE}") 2>&1

echo "=== GROMACS GPU build started at $(date) ==="
echo "Host:           $(hostname)"
echo "Tag:            ${GROMACS_TAG}"
echo "Requested:      GPU_TARGET=${GPU_TARGET} CUDA_TOOLKIT=${CUDA_TOOLKIT} OMPI_VERSION=${OMPI_VERSION}"

# ---------------------------------------------------------------------------
# Pre-flight: nvidia-smi + CUDA toolkit + CUDA major version (Req 5.7).
# Each individual probe is hard-bounded with `timeout 10` so the full
# pre-flight cannot exceed 30 seconds even if the driver hangs.
# ---------------------------------------------------------------------------
echo "=== Pre-flight: GPU + CUDA toolkit ==="
PREFLIGHT_START=$SECONDS

if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "ERROR: nvidia-smi not found on PATH" >&2
    echo "       The NVIDIA driver must be installed on the build host." >&2
    exit 1
fi
if ! timeout 10 nvidia-smi >/dev/null 2>&1; then
    echo "ERROR: nvidia-smi present but did not return successfully within 10s" >&2
    exit 1
fi
echo "nvidia-smi:     OK"

# CUDA toolkit detection. We trust nvcc on PATH first; fall back to the
# canonical /usr/local/cuda symlink and CUDA_HOME if the user pre-set it.
NVCC_BIN=""
if command -v nvcc >/dev/null 2>&1; then
    NVCC_BIN="$(command -v nvcc)"
elif [ -n "${CUDA_HOME:-}" ] && [ -x "${CUDA_HOME}/bin/nvcc" ]; then
    NVCC_BIN="${CUDA_HOME}/bin/nvcc"
elif [ -x "/usr/local/cuda/bin/nvcc" ]; then
    NVCC_BIN="/usr/local/cuda/bin/nvcc"
fi

if [ -z "${NVCC_BIN}" ]; then
    echo "ERROR: CUDA toolkit (nvcc) not detected on PATH or under /usr/local/cuda" >&2
    echo "       Install the CUDA toolkit (>= 13) before submitting this build." >&2
    exit 1
fi

if ! timeout 10 "${NVCC_BIN}" --version >/dev/null 2>&1; then
    echo "ERROR: ${NVCC_BIN} did not respond within 10s" >&2
    exit 1
fi

CUDA_VERSION_STR="$("${NVCC_BIN}" --version | awk '/release/ {print $(NF-1)}' | tr -d ',')"
CUDA_MAJOR="${CUDA_VERSION_STR%%.*}"
echo "nvcc:           ${NVCC_BIN}"
echo "CUDA version:   ${CUDA_VERSION_STR} (major=${CUDA_MAJOR})"

if ! [[ "${CUDA_MAJOR}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: could not parse CUDA major version from '${CUDA_VERSION_STR}'" >&2
    exit 1
fi
if [ "${CUDA_MAJOR}" -lt 13 ]; then
    echo "ERROR: CUDA toolkit major version ${CUDA_MAJOR} is below the required minimum of 13" >&2
    echo "       GROMACS ${GROMACS_TAG} on this phase targets CUDA 13 (Blackwell sm_120)." >&2
    exit 1
fi

# CUDA_HOME is consumed by the CMake configure below.
CUDA_HOME="${CUDA_HOME:-$(dirname "$(dirname "${NVCC_BIN}")")}"
export CUDA_HOME
echo "CUDA_HOME:      ${CUDA_HOME}"

PREFLIGHT_ELAPSED=$((SECONDS - PREFLIGHT_START))
echo "Pre-flight took ${PREFLIGHT_ELAPSED}s (Req 5.7 budget: 30s)"
if [ "${PREFLIGHT_ELAPSED}" -gt 30 ]; then
    echo "ERROR: pre-flight exceeded 30s budget (took ${PREFLIGHT_ELAPSED}s)" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Host SIMD auto-detection (Req 5.8). For a GPU build the host SIMD barely
# matters (force / PME / bonded / update run on the GPU), and the g6e / p5
# host CPUs do not all advertise AVX-512, so rather than hardcode AVX_512 we
# pick the widest SIMD the build host actually supports.
# ---------------------------------------------------------------------------
if grep -q '\bavx512f\b' /proc/cpuinfo; then
    HOST_SIMD="AVX_512"
elif grep -q '\bavx2\b' /proc/cpuinfo; then
    HOST_SIMD="AVX2_256"
else
    HOST_SIMD="SSE4.1"
fi
echo "Host SIMD:      ${HOST_SIMD} (auto-detected from /proc/cpuinfo)"

# ---------------------------------------------------------------------------
# GPU auto-detection from nvidia-smi (Req 5.4 / 5.10 — install path encodes
# target). Pattern lifted directly from design.md Section 3.
# ---------------------------------------------------------------------------
if [ "${GPU_TARGET}" = "auto" ]; then
    gpu_name="$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1 || true)"
    echo "Detected GPU:   ${gpu_name}"
    case "${gpu_name}" in
        *H100*) GPU_TARGET="h100" ;;
        *L40S*|*L40s*) GPU_TARGET="l40s" ;;
        *"RTX PRO 6000"*|*Blackwell*|*GB200*|*B200*) GPU_TARGET="blackwell" ;;
        *)
            echo "ERROR: unsupported GPU: ${gpu_name}" >&2
            echo "       Set GPU_TARGET=l40s|h100|blackwell explicitly to override" >&2
            exit 1
            ;;
    esac
fi

case "${GPU_TARGET}" in
    l40s|h100|blackwell) ;;
    *)
        echo "ERROR: Unknown GPU_TARGET: ${GPU_TARGET} (expected: l40s | h100 | blackwell | auto)" >&2
        exit 1
        ;;
esac
echo "GPU target:     ${GPU_TARGET}"

# Map the GPU target to its CUDA compute capability (SM) for nvcc codegen.
#   L40S               = Ada Lovelace  sm_89
#   H100               = Hopper        sm_90
#   RTX PRO 6000 (g7e) = Blackwell     sm_120 (needs CUDA >= 12.8; native on
#                                       CUDA 13 + GROMACS 2026)
case "${GPU_TARGET}" in
    l40s)      CUDA_SM="89" ;;
    h100)      CUDA_SM="90" ;;
    blackwell) CUDA_SM="120" ;;
esac
echo "CUDA SM target: ${CUDA_SM}"

# ---------------------------------------------------------------------------
# OpenMPI selection. Both 4 and 5 are accepted on x86 GPU instances.
# Default 4 mirrors the x86 CPU build for consistency at customer sites
# that already have the openmpi/4.1.7 module on PATH.
# ---------------------------------------------------------------------------
case "${OMPI_VERSION}" in
    4)
        OMPI_MODULE="openmpi/4.1.7"
        OMPI_ROOT="/opt/amazon/openmpi"
        OMPI_ENV_SUFFIX="ompi"
        ;;
    5)
        OMPI_MODULE="openmpi5/5.0.9amzn1"
        OMPI_ROOT="/opt/amazon/openmpi5"
        OMPI_ENV_SUFFIX="ompi5"
        ;;
    *)
        echo "ERROR: Unknown OMPI_VERSION: ${OMPI_VERSION} (expected: 4 | 5)" >&2
        exit 1
        ;;
esac

TARGET_TAG="x86_64-cuda${CUDA_MAJOR}-${GPU_TARGET}"

BUILD_DIR="${BASE_DIR}/build/${TARGET_TAG}-${GROMACS_TAG}"
INSTALL_ROOT="${BASE_DIR}/${TARGET_TAG}/${GROMACS_TAG}"
INSTALL_TMPI="${INSTALL_ROOT}/tmpi"
INSTALL_OMPI="${INSTALL_ROOT}/ompi"
ENV_SCRIPT_TMPI="${INSTALL_ROOT}/gromacs-${GROMACS_TAG}-tmpi-env.sh"
ENV_SCRIPT_OMPI="${INSTALL_ROOT}/gromacs-${GROMACS_TAG}-${OMPI_ENV_SUFFIX}-env.sh"

mkdir -p "${BUILD_DIR}"

# ---------------------------------------------------------------------------
# Pre-flight: install root must not already exist (Req 5.11 intent — never
# silently overwrite a prior install). The user must `rm -rf` the existing
# directory or bump GROMACS_TAG.
# ---------------------------------------------------------------------------
if [ -d "${INSTALL_ROOT}" ]; then
    echo "ERROR: install root already exists: ${INSTALL_ROOT}" >&2
    echo "       Refusing to overwrite. Remove it manually or bump GROMACS_TAG." >&2
    exit 1
fi

echo "Install root:   ${INSTALL_ROOT}"
echo "  tmpi prefix:  ${INSTALL_TMPI}"
echo "  ompi prefix:  ${INSTALL_OMPI}"
echo "Env scripts:    ${ENV_SCRIPT_TMPI}"
echo "                ${ENV_SCRIPT_OMPI}"
echo "Build dir:      ${BUILD_DIR}"

# ---------------------------------------------------------------------------
# Trap any failure (set -e propagates here). Same shape as the x86 / Arm
# builds: the TOUCHED flags are flipped inside build_variant() right
# before we clobber the install prefix, so a configure/compile failure
# leaves untouched any earlier successful install (Req 5.11).
# ---------------------------------------------------------------------------
on_error() {
    local exit_code=$?
    local failed_line=${1:-?}
    echo "" >&2
    echo "ERROR: GROMACS GPU build failed at line ${failed_line} (exit ${exit_code})." >&2
    echo "       GROMACS_TAG=${GROMACS_TAG} GPU_TARGET=${GPU_TARGET}" >&2
    echo "       CUDA=${CUDA_VERSION_STR} OMPI_VERSION=${OMPI_VERSION}" >&2
    echo "       Logs at ${LOG_FILE}" >&2
    if [ "${TMPI_TOUCHED:-0}" = "1" ] && [ "${TMPI_INSTALLED:-0}" != "1" ]; then
        if [ -d "${INSTALL_TMPI}" ]; then
            echo "       Cleaning half-installed Thread_MPI prefix: ${INSTALL_TMPI}" >&2
            rm -rf "${INSTALL_TMPI}"
        fi
        rm -f "${ENV_SCRIPT_TMPI}"
    fi
    if [ "${OMPI_TOUCHED:-0}" = "1" ] && [ "${OMPI_INSTALLED:-0}" != "1" ]; then
        if [ -d "${INSTALL_OMPI}" ]; then
            echo "       Cleaning half-installed Library_MPI prefix: ${INSTALL_OMPI}" >&2
            rm -rf "${INSTALL_OMPI}"
        fi
        rm -f "${ENV_SCRIPT_OMPI}"
    fi
    exit "${exit_code}"
}
trap 'on_error ${LINENO}' ERR

TMPI_TOUCHED=0
TMPI_INSTALLED=0
OMPI_TOUCHED=0
OMPI_INSTALLED=0

# ---------------------------------------------------------------------------
# Prereqs (safe to re-run; dnf will say "already installed").
# GROMACS 2026 needs C++20, so we install GCC 14 (AL2023 packages). FFTW is
# built in-tree via -DGMX_BUILD_OWN_FFTW=ON so we don't depend on fftw-devel
# from the OS.
# ---------------------------------------------------------------------------
echo "=== Installing build prerequisites ==="
sudo dnf install -y git make python3 which \
    gcc14 gcc14-c++ gcc14-gfortran 2>&1 | tail -5

# ---------------------------------------------------------------------------
# Toolchain for GROMACS 2026 (C++20 needs GCC >= 12; CMake >= 3.28 required;
# Blackwell sm_120 needs a recent nvcc). GCC 14.2 comes from the AL2023 repo
# under versioned names (/usr/bin/gcc14-gcc, gcc14-g++); CMake 3.28.3 is
# staged on shared FSx at /fsx/tools.
# ---------------------------------------------------------------------------
GMX_CC="$(command -v gcc14-gcc || command -v gcc-14 || echo /usr/bin/gcc14-gcc)"
GMX_CXX="$(command -v gcc14-g++ || command -v g++-14 || echo /usr/bin/gcc14-g++)"
GMX_FC="$(command -v gcc14-gfortran || command -v gfortran-14 || true)"
export CC="${GMX_CC}"
export CXX="${GMX_CXX}"
[ -n "${GMX_FC}" ] && export FC="${GMX_FC}"

CMAKE_328="/fsx/tools/cmake-3.28.3-linux-x86_64/bin"
if [ -x "${CMAKE_328}/cmake" ]; then
    export PATH="${CMAKE_328}:${PATH}"
fi
echo "CC:     ${CC} ($(${CC} --version | head -1))"
echo "CXX:    ${CXX} ($(${CXX} --version | head -1))"
echo "CMake:  $(cmake --version | head -1)"

# ---------------------------------------------------------------------------
# Make OpenMPI visible at build time. CMake's FindMPI picks it up via the
# loaded module's PATH/MPI_HOME. Only the Library_MPI variant uses it; the
# Thread_MPI variant configures with GMX_MPI=OFF and ignores any MPI on
# PATH.
# ---------------------------------------------------------------------------
module load "${OMPI_MODULE}"
module load libfabric-aws
MPIRUN_BIN="${OMPI_ROOT}/bin/mpirun"
echo "OpenMPI:        $("${MPIRUN_BIN}" --version | head -1)"
echo "OpenMPI root:   ${OMPI_ROOT}"

# ---------------------------------------------------------------------------
# Probe whether the linked OpenMPI advertises CUDA support. The result is
# embedded as a comment in the generated ompi Env_Script (Req 5.6) so the
# benchmark launcher and any human reading the env file knows whether
# inter-GPU collectives go through CUDA-aware MPI or fall back to NCCL.
# ---------------------------------------------------------------------------
MPI_CUDA_AWARE_COMMENT="# MPI is not CUDA-aware; NCCL is used for inter-GPU collectives"
if command -v ompi_info >/dev/null 2>&1; then
    if ompi_info 2>/dev/null | grep -qi 'mca:mpi:base:param:mpi_built_with_cuda_support:value:true' \
        || ompi_info --parsable --all 2>/dev/null | grep -qi 'mpi_built_with_cuda_support:value:true' \
        || ompi_info 2>/dev/null | grep -Eqi 'cuda.*(yes|true)'; then
        MPI_CUDA_AWARE_COMMENT="# MPI is CUDA-aware"
    fi
fi
echo "MPI CUDA-aware: ${MPI_CUDA_AWARE_COMMENT#\# }"

# ---------------------------------------------------------------------------
# Source checkout. Pin to the requested tag and use --depth=1 to keep the
# clone small.
# ---------------------------------------------------------------------------
SRC_DIR="${BUILD_DIR}/gromacs"
cd "${BUILD_DIR}"
if [ ! -d "${SRC_DIR}/.git" ]; then
    echo "=== Cloning GROMACS @ ${GROMACS_TAG} ==="
    git clone --depth=1 --branch "${GROMACS_TAG}" \
        https://gitlab.com/gromacs/gromacs.git gromacs
else
    echo "=== Re-using existing checkout in ${SRC_DIR} ==="
    (cd "${SRC_DIR}" && git reset --hard HEAD && git clean -fdx) || true
fi

# ---------------------------------------------------------------------------
# Common CMake flags shared by both variants. Host SIMD is auto-detected
# (HOST_SIMD) with -march=native. The CUDA SM target is per-GPU-family
# (sm_89 L40S / sm_90 H100 / sm_120 Blackwell). --use_fast_math and
# -DGMX_RELAXED_DOUBLE_PRECISION=OFF match Req 5.8 wording.
# ---------------------------------------------------------------------------
CXX_FLAGS="-O3 -march=native -DNDEBUG"
echo "CXX flags:      ${CXX_FLAGS}"

COMMON_CMAKE_FLAGS=(
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_C_FLAGS="${CXX_FLAGS}"
    -DCMAKE_CXX_FLAGS="${CXX_FLAGS}"
    "-DGMX_SIMD=${HOST_SIMD}"
    -DGMX_FFT_LIBRARY=fftw3
    -DGMX_BUILD_OWN_FFTW=ON
    -DGMX_OPENMP=ON
    -DGMX_GPU=CUDA
    "-DGMX_CUDA_TARGET_SM=${CUDA_SM}"
    -DGMX_RELAXED_DOUBLE_PRECISION=OFF
    -DCMAKE_CUDA_FLAGS=--use_fast_math
    "-DCUDA_TOOLKIT_ROOT_DIR=${CUDA_HOME}"
    -DBUILD_SHARED_LIBS=ON
    -DGMX_DEFAULT_SUFFIX=ON
)

# ---------------------------------------------------------------------------
# Build helper: configure, build, install one CMake variant.
#   $1 = variant name ("tmpi" | "ompi")
#   $2 = install prefix
#   $@ remaining = extra CMake flags (GMX_MPI / GMX_THREAD_MPI etc.)
# ---------------------------------------------------------------------------
build_variant() {
    local variant="$1"; shift
    local prefix="$1"; shift
    local variant_build_dir="${BUILD_DIR}/build-${variant}"

    echo ""
    echo "=================================================================="
    echo "=== Building variant: ${variant}"
    echo "=== Install prefix:   ${prefix}"
    echo "=================================================================="

    rm -rf "${variant_build_dir}"
    mkdir -p "${variant_build_dir}"
    cd "${variant_build_dir}"

    echo "=== Running CMake (${variant}) ==="
    cmake "${SRC_DIR}" \
        -DCMAKE_INSTALL_PREFIX="${prefix}" \
        -DCMAKE_C_COMPILER="${CC}" \
        -DCMAKE_CXX_COMPILER="${CXX}" \
        -DCMAKE_CUDA_HOST_COMPILER="${CXX}" \
        "${COMMON_CMAKE_FLAGS[@]}" \
        "$@"

    echo ""
    echo "=== Compiling (${variant}, ${COMPILE_CORES} cores) ==="
    cmake --build . --parallel "${COMPILE_CORES}"

    echo ""
    echo "=== Installing (${variant}) to ${prefix} ==="
    # Flip the TOUCHED flag at the last moment — only here does this run
    # start clobbering the install prefix.
    case "${variant}" in
        tmpi) TMPI_TOUCHED=1 ;;
        ompi) OMPI_TOUCHED=1 ;;
    esac
    rm -rf "${prefix}"
    mkdir -p "${prefix}"
    cmake --install .
}

# ---------------------------------------------------------------------------
# Variant 1: Thread_MPI + CUDA -> gmx (single-node multi-GPU)
# ---------------------------------------------------------------------------
build_variant "tmpi" "${INSTALL_TMPI}" \
    -DGMX_MPI=OFF \
    -DGMX_THREAD_MPI=ON

GMX_BIN="${INSTALL_TMPI}/bin/gmx"
if [ ! -x "${GMX_BIN}" ]; then
    echo "ERROR: expected Thread_MPI binary not found: ${GMX_BIN}" >&2
    exit 1
fi
echo ""
echo "=== Smoke test: gmx --version (Thread_MPI + CUDA) ==="
"${GMX_BIN}" --version 2>&1 | head -30 || true
TMPI_INSTALLED=1

# ---------------------------------------------------------------------------
# Variant 2: Library_MPI + CUDA -> gmx_mpi (multi-node)
# ---------------------------------------------------------------------------
build_variant "ompi" "${INSTALL_OMPI}" \
    -DGMX_MPI=ON \
    -DGMX_THREAD_MPI=OFF \
    -DMPIEXEC_EXECUTABLE="${MPIRUN_BIN}"

GMX_MPI_BIN="${INSTALL_OMPI}/bin/gmx_mpi"
if [ ! -x "${GMX_MPI_BIN}" ]; then
    echo "ERROR: expected Library_MPI binary not found: ${GMX_MPI_BIN}" >&2
    exit 1
fi
echo ""
echo "=== Smoke test: gmx_mpi --version (Library_MPI + CUDA) ==="
"${GMX_MPI_BIN}" --version 2>&1 | head -30 || true
echo ""
echo "=== gmx_mpi MPI / libfabric / CUDA linkage ==="
ldd "${GMX_MPI_BIN}" 2>/dev/null | grep -E "libmpi|libfabric|libopen-|libcuda|libcudart|libnvToolsExt" | sed 's/^/  /' || true
OMPI_INSTALLED=1

# ---------------------------------------------------------------------------
# Default CUDA_VISIBLE_DEVICES (Req 5.5) — covers all GPUs detected on the
# build host. The benchmark launcher can still narrow this at run time.
# ---------------------------------------------------------------------------
GPU_COUNT_DETECTED="$(nvidia-smi -L 2>/dev/null | wc -l | tr -d '[:space:]')"
if [ -z "${GPU_COUNT_DETECTED}" ] || [ "${GPU_COUNT_DETECTED}" = "0" ]; then
    GPU_COUNT_DETECTED=1
fi
CUDA_VISIBLE_DEVICES_DEFAULT="$(seq -s, 0 $((GPU_COUNT_DETECTED - 1)))"
echo "CUDA_VISIBLE_DEVICES default: ${CUDA_VISIBLE_DEVICES_DEFAULT} (detected ${GPU_COUNT_DETECTED} GPU(s))"

# ---------------------------------------------------------------------------
# Env scripts — sourced by the benchmark launcher. Both variants load the
# CUDA toolkit module so PATH and LD_LIBRARY_PATH pick up libcudart and
# friends. The ompi variant additionally loads the chosen OpenMPI module.
# Customer sites that ship CUDA via a different module name (e.g.
# `cuda/13.0`) can adjust the `module load` line locally — we use
# `module load cuda` as the canonical default and tolerate failure with
# `|| true` so the script still works on hosts that ship CUDA via PATH
# rather than environment-modules.
# ---------------------------------------------------------------------------
cat > "${ENV_SCRIPT_TMPI}" <<ENV
#!/bin/bash
# GROMACS ${GROMACS_TAG} — ${TARGET_TAG} Thread_MPI + CUDA variant
# (GCC 14 + nvcc ${CUDA_VERSION_STR}, ${GPU_TARGET} sm_${CUDA_SM}, ${HOST_SIMD} host SIMD)
# Single-node multi-GPU. Use the ompi variant for multi-node GPU runs.
# CUDA toolkit is loaded via environment-modules if available; falls back
# to whatever PATH already advertises if the module command is missing.
module load cuda 2>/dev/null || true
export GROMACS_ROOT="${INSTALL_TMPI}"
export GROMACS_TAG="${GROMACS_TAG}"
export PATH="\${GROMACS_ROOT}/bin:\${PATH}"
export LD_LIBRARY_PATH="\${GROMACS_ROOT}/lib64:\${GROMACS_ROOT}/lib:\${LD_LIBRARY_PATH:-}"
export GMXLIB="\${GROMACS_ROOT}/share/gromacs/top"
export CUDA_VISIBLE_DEVICES="\${CUDA_VISIBLE_DEVICES:-${CUDA_VISIBLE_DEVICES_DEFAULT}}"
ENV
chmod +x "${ENV_SCRIPT_TMPI}"

cat > "${ENV_SCRIPT_OMPI}" <<ENV
#!/bin/bash
# GROMACS ${GROMACS_TAG} — ${TARGET_TAG} Library_MPI + CUDA variant
# (GCC 14 + nvcc ${CUDA_VERSION_STR} + OpenMPI ${OMPI_VERSION}, ${GPU_TARGET} sm_${CUDA_SM}, ${HOST_SIMD} host SIMD)
# Multi-node GPU runs. Invoke gmx_mpi under mpirun.
${MPI_CUDA_AWARE_COMMENT}
module purge
module load cuda 2>/dev/null || true
module load ${OMPI_MODULE}
module load libfabric-aws
export GROMACS_ROOT="${INSTALL_OMPI}"
export GROMACS_TAG="${GROMACS_TAG}"
export PATH="\${GROMACS_ROOT}/bin:\${PATH}"
export LD_LIBRARY_PATH="\${GROMACS_ROOT}/lib64:\${GROMACS_ROOT}/lib:\${LD_LIBRARY_PATH:-}"
export GMXLIB="\${GROMACS_ROOT}/share/gromacs/top"
export CUDA_VISIBLE_DEVICES="\${CUDA_VISIBLE_DEVICES:-${CUDA_VISIBLE_DEVICES_DEFAULT}}"
ENV
chmod +x "${ENV_SCRIPT_OMPI}"

echo ""
echo "=== GROMACS GPU build complete at $(date) ==="
echo "Install root:   ${INSTALL_ROOT}"
echo "  tmpi binary:  ${GMX_BIN}"
echo "  ompi binary:  ${GMX_MPI_BIN}"
echo "Env scripts:    ${ENV_SCRIPT_TMPI}"
echo "                ${ENV_SCRIPT_OMPI}"
echo "Log:            ${LOG_FILE}"
