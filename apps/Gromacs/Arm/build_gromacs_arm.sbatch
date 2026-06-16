#!/bin/bash
# Build GROMACS for aarch64 (Graviton3E / Graviton4) using GCC + system OpenMPI.
#
# GROMACS is the workhorse open-source molecular dynamics package for
# biomolecular simulation — proteins, lipids, nucleic acids, and condensed-
# matter systems.
#   https://www.gromacs.org/   https://gitlab.com/gromacs/gromacs
#
# Like the x86 build, this script produces TWO CMake variants and installs
# both:
#
#   1. Thread_MPI (`gmx`):       single-node only, no external MPI dependency.
#                                Built with -DGMX_MPI=OFF -DGMX_THREAD_MPI=ON.
#                                Used by the benchmark launcher when N==1.
#
#   2. Library_MPI (`gmx_mpi`):  multi-node, linked against the Amazon-provided
#                                OpenMPI (4.1.7 or 5.0.9 depending on the
#                                target). Built with -DGMX_MPI=ON
#                                -DGMX_THREAD_MPI=OFF. Used when N>1.
#
# Both variants share the same CMake flags otherwise:
# `-mcpu=neoverse-v1` on Graviton3E / `-mcpu=neoverse-v2` on Graviton4,
# OpenMP, own FFTW (so the build is self-contained on Arm), Release build,
# and `-DGMX_SIMD=ARM_SVE` (with a runtime fallback to ARM_NEON_ASIMD if
# the SVE feature probe fails on the build host).
#
# OpenMPI selection follows the LAMMPS Arm pattern:
#   * Graviton3E (hpc7g, Neoverse V1, CPU part 0xd40)
#       OMPI_VERSION=4 (legacy) or 5 (default — recommended for full
#       density at 64 ranks/node over EFA)
#   * Graviton4 (m8g, Neoverse V2, CPU part 0xd4f)
#       OMPI_VERSION=5 always — required for 192 ranks/node EFA endpoint
#       scaling. OMPI_VERSION=4 is rejected at submit time.
#
# Override via --export=ALL,...:
#   GROMACS_TAG     git tag from https://gitlab.com/gromacs/gromacs
#                   (default: v2024.4)
#   OMPI_VERSION    4 (Graviton3E only) or 5 (default)
#   BASE_DIR        install root (default: /fsx/gromacs)
#   TARGET          graviton3 | graviton4 | auto (default — auto-detects
#                   from /proc/cpuinfo CPU part)
#   COMPILE_CORES   parallel compile threads (default: 48)

#SBATCH --job-name=build-gromacs-arm
#SBATCH -p hpc7g
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=64
#SBATCH --time=02:00:00
#SBATCH --exclusive
#SBATCH --output=/fsx/gromacs/logs/build_arm_%j.out
#SBATCH --error=/fsx/gromacs/logs/build_arm_%j.err

set -euo pipefail

GROMACS_TAG="${GROMACS_TAG:-v2024.4}"
OMPI_VERSION="${OMPI_VERSION:-5}"
BASE_DIR="${BASE_DIR:-/fsx/gromacs}"
TARGET="${TARGET:-auto}"
COMPILE_CORES="${COMPILE_CORES:-48}"

# ---------------------------------------------------------------------------
# Detect Graviton generation from /proc/cpuinfo CPU-part field (Req 3.3 / 3.4).
#   0xd40 = Neoverse V1 -> Graviton3 / Graviton3E
#   0xd4f = Neoverse V2 -> Graviton4
# An unknown CPU part aborts before invoking CMake with a descriptive error.
# ---------------------------------------------------------------------------
if [ "${TARGET}" = "auto" ]; then
    cpu_part=$(awk '/CPU part/ {print $NF; exit}' /proc/cpuinfo)
    case "${cpu_part}" in
        0xd40) TARGET="graviton3" ;;
        0xd4f) TARGET="graviton4" ;;
        *)
            echo "ERROR: unsupported CPU part ${cpu_part} in /proc/cpuinfo" >&2
            echo "       Set TARGET=graviton3 or TARGET=graviton4 explicitly to override" >&2
            exit 1
            ;;
    esac
fi

case "${TARGET}" in
    graviton3)
        MCPU_FLAG="neoverse-v1"
        TARGET_TAG_BASE="aarch64-graviton3"
        ;;
    graviton4)
        MCPU_FLAG="neoverse-v2"
        TARGET_TAG_BASE="aarch64-graviton4"
        ;;
    *)
        echo "ERROR: Unknown TARGET: ${TARGET} (expected: graviton3 | graviton4 | auto)" >&2
        exit 1
        ;;
esac

# ---------------------------------------------------------------------------
# OpenMPI selection (Req 3.6 / 3.7).
# Graviton4 forces OMPI_VERSION=5 — reject =4 with a descriptive error.
# Graviton3E accepts 4 or 5 (default 5).
# ---------------------------------------------------------------------------
if [ "${TARGET}" = "graviton4" ] && [ "${OMPI_VERSION}" != "5" ]; then
    echo "ERROR: Graviton4 requires OMPI_VERSION=5 (got: ${OMPI_VERSION})" >&2
    echo "       OpenMPI 4.1.7 cannot scale to 192 ranks/node over EFA on Neoverse V2." >&2
    exit 1
fi

case "${OMPI_VERSION}" in
    4)
        OMPI_MODULE="openmpi/4.1.7"
        OMPI_ROOT="/opt/amazon/openmpi"
        OMPI_TAG=""
        OMPI_ENV_SUFFIX="ompi"
        ;;
    5)
        OMPI_MODULE="openmpi5/5.0.9amzn1"
        OMPI_ROOT="/opt/amazon/openmpi5"
        OMPI_TAG="-ompi5"
        OMPI_ENV_SUFFIX="ompi5"
        ;;
    *)
        echo "ERROR: Unknown OMPI_VERSION: ${OMPI_VERSION} (expected: 4 | 5)" >&2
        exit 1
        ;;
esac

TARGET_TAG="${TARGET_TAG_BASE}${OMPI_TAG}"

BUILD_DIR="${BASE_DIR}/build/${TARGET_TAG}-${GROMACS_TAG}"
INSTALL_ROOT="${BASE_DIR}/${TARGET_TAG}/${GROMACS_TAG}"
INSTALL_TMPI="${INSTALL_ROOT}/tmpi"
INSTALL_OMPI="${INSTALL_ROOT}/ompi"
ENV_SCRIPT_TMPI="${INSTALL_ROOT}/gromacs-${GROMACS_TAG}-tmpi-env.sh"
ENV_SCRIPT_OMPI="${INSTALL_ROOT}/gromacs-${GROMACS_TAG}-${OMPI_ENV_SUFFIX}-env.sh"
LOG_DIR="${BASE_DIR}/logs"

mkdir -p "${LOG_DIR}" "${BUILD_DIR}"

LOG_FILE="${LOG_DIR}/build_${TARGET_TAG}_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "${LOG_FILE}") 2>&1

# ---------------------------------------------------------------------------
# Pre-flight: install root must not already exist (Req 3.10). We refuse to
# silently overwrite a prior install. The user must `rm -rf` the existing
# directory or bump GROMACS_TAG.
# ---------------------------------------------------------------------------
if [ -d "${INSTALL_ROOT}" ]; then
    echo "ERROR: install root already exists: ${INSTALL_ROOT}" >&2
    echo "       Refusing to overwrite. Remove it manually or bump GROMACS_TAG." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Trap any failure (set -e propagates here). Same shape as the x86 build:
# the TOUCHED flags are flipped inside build_variant() right before we
# clobber the install prefix, so a configure/compile failure leaves
# untouched any earlier successful install.
# ---------------------------------------------------------------------------
on_error() {
    local exit_code=$?
    local failed_line=${1:-?}
    echo "" >&2
    echo "ERROR: GROMACS Arm build failed at line ${failed_line} (exit ${exit_code})." >&2
    echo "       GROMACS_TAG=${GROMACS_TAG} TARGET=${TARGET} OMPI_VERSION=${OMPI_VERSION}" >&2
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

echo "=== GROMACS Arm build started at $(date) ==="
echo "Host:           $(hostname)"
echo "Tag:            ${GROMACS_TAG}"
echo "Target:         ${TARGET} (mcpu=${MCPU_FLAG})"
echo "OpenMPI:        ${OMPI_VERSION} (${OMPI_MODULE})"
echo "Install root:   ${INSTALL_ROOT}"
echo "  tmpi prefix:  ${INSTALL_TMPI}"
echo "  ompi prefix:  ${INSTALL_OMPI}"
echo "Env scripts:    ${ENV_SCRIPT_TMPI}"
echo "                ${ENV_SCRIPT_OMPI}"
echo "Build dir:      ${BUILD_DIR}"

# ---------------------------------------------------------------------------
# Prereqs (safe to re-run; dnf will say "already installed").
# GROMACS needs: cmake >= 3.18, gcc/g++ 11+, git, make, python3.
# FFTW is built in-tree via -DGMX_BUILD_OWN_FFTW=ON (Req 3.12) so we don't
# depend on fftw-devel from the OS.
# ---------------------------------------------------------------------------
echo "=== Installing build prerequisites ==="
sudo dnf install -y git cmake make gcc-c++ gcc-gfortran python3 which 2>&1 | tail -5
echo "GCC:    $(gcc --version | head -1)"
echo "G++:    $(g++ --version | head -1)"
echo "CMake:  $(cmake --version | head -1)"

# ---------------------------------------------------------------------------
# Make OpenMPI visible at build time. CMake's FindMPI picks it up via the
# loaded module's PATH/MPI_HOME. Only the Library_MPI variant uses it; the
# Thread_MPI variant configures with GMX_MPI=OFF and ignores any MPI on PATH.
# ---------------------------------------------------------------------------
module load "${OMPI_MODULE}"
module load libfabric-aws
MPIRUN_BIN="${OMPI_ROOT}/bin/mpirun"
echo "OpenMPI:        $("${MPIRUN_BIN}" --version | head -1)"
echo "OpenMPI root:   ${OMPI_ROOT}"

# ---------------------------------------------------------------------------
# Probe SVE support at configure time (Req 3.5). Compile a tiny C snippet
# that includes <arm_sve.h>. On success we keep -DGMX_SIMD=ARM_SVE; on
# failure we fall back to -DGMX_SIMD=ARM_NEON_ASIMD and emit a warning.
# ---------------------------------------------------------------------------
GMX_SIMD="ARM_SVE"
SVE_PROBE_DIR="$(mktemp -d)"
trap 'rm -rf "${SVE_PROBE_DIR}"' EXIT
SVE_PROBE_C="${SVE_PROBE_DIR}/sve_probe.c"
SVE_PROBE_BIN="${SVE_PROBE_DIR}/sve_probe"
cat > "${SVE_PROBE_C}" <<'PROBE'
#include <arm_sve.h>
int main(void) {
    /* Reference one SVE intrinsic so the linker actually pulls SVE in. */
    svbool_t p = svptrue_b32();
    return svcntb() > 0 && svptest_any(p, p) ? 0 : 0;
}
PROBE
echo "=== Probing SVE support (compile + link of arm_sve.h snippet) ==="
CC="${CC:-gcc}"
if "${CC}" -march=native -O2 "${SVE_PROBE_C}" -o "${SVE_PROBE_BIN}" 2>"${SVE_PROBE_DIR}/probe.err"; then
    echo "SVE probe:      OK ($("${CC}" --version | head -1))"
    GMX_SIMD="ARM_SVE"
else
    echo "WARNING: SVE feature probe failed on $(hostname)" >&2
    echo "         Compiler: $("${CC}" --version | head -1)" >&2
    echo "         Probe stderr (last 5 lines):" >&2
    tail -5 "${SVE_PROBE_DIR}/probe.err" >&2 || true
    echo "         Falling back to -DGMX_SIMD=ARM_NEON_ASIMD" >&2
    GMX_SIMD="ARM_NEON_ASIMD"
fi
echo "GMX_SIMD:       ${GMX_SIMD}"

CXX_FLAGS="-O3 -mcpu=${MCPU_FLAG} -mtune=${MCPU_FLAG} -DNDEBUG"
echo "CXX flags:      ${CXX_FLAGS}"

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
# Common CMake flags shared by both variants. Req 3.12 requires
# -DGMX_BUILD_OWN_FFTW=ON so the build is self-contained on Arm.
# ---------------------------------------------------------------------------
COMMON_CMAKE_FLAGS=(
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_C_FLAGS="${CXX_FLAGS}"
    -DCMAKE_CXX_FLAGS="${CXX_FLAGS}"
    "-DGMX_SIMD=${GMX_SIMD}"
    -DGMX_FFT_LIBRARY=fftw3
    -DGMX_BUILD_OWN_FFTW=ON
    -DGMX_OPENMP=ON
    -DGMX_GPU=OFF
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
# Variant 1: Thread_MPI -> gmx
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
echo "=== Smoke test: gmx --version (Thread_MPI) ==="
"${GMX_BIN}" --version 2>&1 | head -25 || true
TMPI_INSTALLED=1

# ---------------------------------------------------------------------------
# Variant 2: Library_MPI -> gmx_mpi (linked against the chosen OpenMPI)
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
echo "=== Smoke test: gmx_mpi --version (Library_MPI) ==="
"${GMX_MPI_BIN}" --version 2>&1 | head -25 || true
echo ""
echo "=== gmx_mpi MPI / libfabric linkage ==="
ldd "${GMX_MPI_BIN}" 2>/dev/null | grep -E "libmpi|libfabric|libopen-" | sed 's/^/  /' || true
OMPI_INSTALLED=1

# ---------------------------------------------------------------------------
# Env scripts — sourced by the benchmark launcher. Only the ompi variant
# loads the openmpi/libfabric-aws modules; the tmpi variant has no MPI
# dependency and runs anywhere with just PATH/LD_LIBRARY_PATH/GMXLIB set.
# ---------------------------------------------------------------------------
cat > "${ENV_SCRIPT_TMPI}" <<ENV
#!/bin/bash
# GROMACS ${GROMACS_TAG} — ${TARGET_TAG_BASE} Thread_MPI variant (GCC, ${MCPU_FLAG}, ${GMX_SIMD})
# Single-node only. Use the ompi variant for multi-node runs.
export GROMACS_ROOT="${INSTALL_TMPI}"
export GROMACS_TAG="${GROMACS_TAG}"
export PATH="\${GROMACS_ROOT}/bin:\${PATH}"
export LD_LIBRARY_PATH="\${GROMACS_ROOT}/lib64:\${GROMACS_ROOT}/lib:\${LD_LIBRARY_PATH:-}"
export GMXLIB="\${GROMACS_ROOT}/share/gromacs/top"
ENV
chmod +x "${ENV_SCRIPT_TMPI}"

cat > "${ENV_SCRIPT_OMPI}" <<ENV
#!/bin/bash
# GROMACS ${GROMACS_TAG} — ${TARGET_TAG} Library_MPI variant (GCC + OpenMPI ${OMPI_VERSION}, ${MCPU_FLAG}, ${GMX_SIMD})
# Multi-node capable. Invoke gmx_mpi under mpirun.
module purge
module load ${OMPI_MODULE}
module load libfabric-aws
export GROMACS_ROOT="${INSTALL_OMPI}"
export GROMACS_TAG="${GROMACS_TAG}"
export PATH="\${GROMACS_ROOT}/bin:\${PATH}"
export LD_LIBRARY_PATH="\${GROMACS_ROOT}/lib64:\${GROMACS_ROOT}/lib:\${LD_LIBRARY_PATH:-}"
export GMXLIB="\${GROMACS_ROOT}/share/gromacs/top"
ENV
chmod +x "${ENV_SCRIPT_OMPI}"

echo ""
echo "=== GROMACS Arm build complete at $(date) ==="
echo "Install root:   ${INSTALL_ROOT}"
echo "  tmpi binary:  ${GMX_BIN}"
echo "  ompi binary:  ${GMX_MPI_BIN}"
echo "Env scripts:    ${ENV_SCRIPT_TMPI}"
echo "                ${ENV_SCRIPT_OMPI}"
echo "Log:            ${LOG_FILE}"
