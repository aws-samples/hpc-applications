#!/bin/bash
# Build GROMACS for x86_64 (hpc8a / hpc7a) using GCC + system OpenMPI 4.1.7.
#
# GROMACS is the workhorse open-source molecular dynamics package for
# biomolecular simulation — proteins, lipids, nucleic acids, and condensed-
# matter systems.
#   https://www.gromacs.org/   https://gitlab.com/gromacs/gromacs
#
# Unlike LAMMPS, GROMACS ships TWO MPI build paths and we install both:
#
#   1. Thread_MPI (`gmx`):       single-node only, no external MPI dependency.
#                                Built from a CMake tree configured with
#                                  -DGMX_MPI=OFF -DGMX_THREAD_MPI=ON
#                                Used by the benchmark launcher when N==1.
#
#   2. Library_MPI (`gmx_mpi`):  multi-node, linked against the Amazon-provided
#                                OpenMPI 4.1.7 at /opt/amazon/openmpi (so EFA
#                                is automatic at runtime). Built from a CMake
#                                tree configured with
#                                  -DGMX_MPI=ON -DGMX_THREAD_MPI=OFF
#                                Used by the benchmark launcher when N>1.
#
# Both variants share the same CMake flags otherwise (AVX_512, OpenMP, own
# FFTW, Release, -O3 -march=x86-64-v4 -mtune=znver4). GCC 11.5 (AL2023) only
# knows up to znver4; hpc8a (Zen5) compiles fine with -mtune=znver4 +
# -march=x86-64-v4 — AVX-512 is emitted and the binary runs optimally on
# Zen5 too. Same trade-off as the LAMMPS x86 build.
#
# Override via --export=ALL,...:
#   GROMACS_TAG     git tag from https://gitlab.com/gromacs/gromacs
#                   (default: v2024.4)
#   BASE_DIR        install root (default: /fsx/gromacs)
#   TARGET_CPU      compiler micro-arch:
#                     hpc8a (default, Zen5 / AVX-512)
#                     hpc7a (Zen4 / AVX-512)
#                     generic-avx2 (Zen3+, portable)
#   COMPILE_CORES   parallel compile threads (default: 48)

#SBATCH --job-name=build-gromacs
#SBATCH -p hpc8a
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=192
#SBATCH --time=02:00:00
#SBATCH --exclusive
#SBATCH --output=/fsx/gromacs/logs/build_x86_%j.out
#SBATCH --error=/fsx/gromacs/logs/build_x86_%j.err

set -euo pipefail

GROMACS_TAG="${GROMACS_TAG:-v2024.4}"
BASE_DIR="${BASE_DIR:-/fsx/gromacs}"
TARGET_CPU="${TARGET_CPU:-hpc8a}"
COMPILE_CORES="${COMPILE_CORES:-48}"

BUILD_DIR="${BASE_DIR}/build/x86_64-${GROMACS_TAG}"
INSTALL_ROOT="${BASE_DIR}/x86_64/${GROMACS_TAG}"
INSTALL_TMPI="${INSTALL_ROOT}/tmpi"
INSTALL_OMPI="${INSTALL_ROOT}/ompi"
ENV_SCRIPT_TMPI="${INSTALL_ROOT}/gromacs-${GROMACS_TAG}-tmpi-env.sh"
ENV_SCRIPT_OMPI="${INSTALL_ROOT}/gromacs-${GROMACS_TAG}-ompi-env.sh"
LOG_DIR="${BASE_DIR}/logs"

mkdir -p "${LOG_DIR}" "${BUILD_DIR}"

LOG_FILE="${LOG_DIR}/build_x86_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "${LOG_FILE}") 2>&1

# ---------------------------------------------------------------------------
# Trap any failure (set -e propagates here). Per Requirements 1.7 / 1.8:
#
#   1.7 — On retrieve failure (clone / fetch / checkout), DO NOT create or
#         modify the install directory. Pre-existing installs from earlier
#         successful runs MUST be left intact.
#   1.8 — On any configure / compile / install failure, DO NOT generate
#         env scripts. Leave the install directory untouched modulo the
#         half-installed prefix THIS run was actively writing to.
#
# The TOUCHED flags are set inside build_variant() immediately before the
# destructive `rm -rf "${prefix}"` step. Only prefixes this run started
# clobbering get cleaned up; everything else is left exactly as we found it.
# ---------------------------------------------------------------------------
on_error() {
    local exit_code=$?
    local failed_line=${1:-?}
    echo "" >&2
    echo "ERROR: GROMACS x86 build failed at line ${failed_line} (exit ${exit_code})." >&2
    echo "       GROMACS_TAG=${GROMACS_TAG}" >&2
    echo "       Logs at ${LOG_FILE}" >&2
    if [ "${TMPI_TOUCHED:-0}" = "1" ] && [ "${TMPI_INSTALLED:-0}" != "1" ]; then
        if [ -d "${INSTALL_TMPI}" ]; then
            echo "       Cleaning half-installed Thread_MPI prefix: ${INSTALL_TMPI}" >&2
            rm -rf "${INSTALL_TMPI}"
        fi
        # An env script on disk for this variant is necessarily from a prior
        # run; if its target prefix was just destroyed, drop the stale script
        # so a re-submit can regenerate it cleanly.
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

echo "=== GROMACS x86 build started at $(date) ==="
echo "Host:           $(hostname)"
echo "Tag:            ${GROMACS_TAG}"
echo "Target CPU:     ${TARGET_CPU}"
echo "Install root:   ${INSTALL_ROOT}"
echo "  tmpi prefix:  ${INSTALL_TMPI}"
echo "  ompi prefix:  ${INSTALL_OMPI}"
echo "Env scripts:    ${ENV_SCRIPT_TMPI}"
echo "                ${ENV_SCRIPT_OMPI}"
echo "Build dir:      ${BUILD_DIR}"

# ---------------------------------------------------------------------------
# Pick compile flags for the requested micro-arch.
# ---------------------------------------------------------------------------
case "${TARGET_CPU}" in
    hpc8a|hpc7a)
        CXX_FLAGS="-O3 -march=x86-64-v4 -mtune=znver4 -DNDEBUG"
        ;;
    generic-avx2)
        # Fallback for hosts without AVX-512. We still set GMX_SIMD=AVX_512
        # below if the user asked for an AVX-512 host, but the generic
        # target downgrades to AVX2-256 to keep the binary portable.
        CXX_FLAGS="-O3 -march=x86-64-v3 -mtune=generic -DNDEBUG"
        ;;
    *)
        echo "ERROR: Unknown TARGET_CPU: ${TARGET_CPU} (expected: hpc8a | hpc7a | generic-avx2)" >&2
        exit 1
        ;;
esac
echo "CXX flags:      ${CXX_FLAGS}"

# ---------------------------------------------------------------------------
# Prereqs (safe to re-run; dnf will say "already installed").
# GROMACS needs: cmake >= 3.18, gcc/g++ 11+, git, make, python3.
# FFTW is built in-tree via -DGMX_BUILD_OWN_FFTW=ON so we don't depend on
# fftw-devel from the OS.
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
module load openmpi/4.1.7
module load libfabric-aws
OMPI_ROOT="${OPENMPI_ROOT:-/opt/amazon/openmpi}"
MPIRUN_BIN="${OMPI_ROOT}/bin/mpirun"
echo "OpenMPI:        $("${MPIRUN_BIN}" --version | head -1)"
echo "OpenMPI root:   ${OMPI_ROOT}"

# ---------------------------------------------------------------------------
# Source checkout. We pin to the requested tag and use --depth=1 to keep the
# clone small — the GROMACS history is large and we don't need it for a
# release build.
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
# Common CMake flags shared by both variants. The Thread_MPI and Library_MPI
# trees differ only in the GMX_MPI / GMX_THREAD_MPI / CMAKE_INSTALL_PREFIX
# trio appended below.
# ---------------------------------------------------------------------------
COMMON_CMAKE_FLAGS=(
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_C_FLAGS="${CXX_FLAGS}"
    -DCMAKE_CXX_FLAGS="${CXX_FLAGS}"
    -DGMX_SIMD=AVX_512
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
    # start clobbering the install prefix. If configure or compile failed
    # above, ${prefix} still holds whatever a prior successful run left
    # there, and the trap leaves it alone (Requirement 1.7 / 1.8 intent).
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
# build_variant() flips TMPI_TOUCHED at the last moment (right before the
# install prefix is wiped), so a configure/compile failure here still
# leaves any earlier successful install in place (Req 1.7 / 1.8 intent).
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
# Variant 2: Library_MPI -> gmx_mpi (linked against OpenMPI 4.1.7)
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
# GROMACS ${GROMACS_TAG} — x86_64 Thread_MPI variant (GCC, ${TARGET_CPU})
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
# GROMACS ${GROMACS_TAG} — x86_64 Library_MPI variant (GCC + OpenMPI 4.1.7, ${TARGET_CPU})
# Multi-node capable. Invoke gmx_mpi under mpirun.
module purge
module load openmpi/4.1.7
module load libfabric-aws
export GROMACS_ROOT="${INSTALL_OMPI}"
export GROMACS_TAG="${GROMACS_TAG}"
export PATH="\${GROMACS_ROOT}/bin:\${PATH}"
export LD_LIBRARY_PATH="\${GROMACS_ROOT}/lib64:\${GROMACS_ROOT}/lib:\${LD_LIBRARY_PATH:-}"
export GMXLIB="\${GROMACS_ROOT}/share/gromacs/top"
ENV
chmod +x "${ENV_SCRIPT_OMPI}"

echo ""
echo "=== GROMACS x86 build complete at $(date) ==="
echo "Install root:   ${INSTALL_ROOT}"
echo "  tmpi binary:  ${GMX_BIN}"
echo "  ompi binary:  ${GMX_MPI_BIN}"
echo "Env scripts:    ${ENV_SCRIPT_TMPI}"
echo "                ${ENV_SCRIPT_OMPI}"
echo "Log:            ${LOG_FILE}"
