#!/bin/bash
# Build LAMMPS for aarch64 (Graviton3E / Graviton4) using GCC + OpenMPI.
#
# LAMMPS is the Large-scale Atomic/Molecular Massively Parallel Simulator from
# Sandia National Laboratories. It is the de-facto standard open-source
# molecular dynamics code in materials science, chemistry, and physics.
#   https://www.lammps.org/   https://github.com/lammps/lammps
#
# We use GCC + system OpenMPI on AL2023. The Graviton generation is
# auto-detected from /proc/cpuinfo so a single script targets both
# hpc7g (Neoverse V1 / Graviton3E) and m8g (Neoverse V2 / Graviton4).
#
# Override via --export=ALL,...:
#   LAMMPS_TAG       release tag (default: stable_2Aug2023_update3)
#   OMPI_VERSION     4 (default, /opt/amazon/openmpi)
#                     or 5 (/opt/amazon/openmpi5) — recommended for
#                     Graviton4 running 192 ranks/node over EFA
#   BASE_DIR         install root (default: /fsx/lammps)
#   TARGET           graviton3 | graviton4 | auto (default)
#   COMPILE_CORES    parallel compile threads (default: 48)

#SBATCH --job-name=build-lammps-arm
#SBATCH -p hpc7g
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=64
#SBATCH --time=02:00:00
#SBATCH --exclusive
#SBATCH --output=/fsx/lammps/logs/build_arm_%j.out
#SBATCH --error=/fsx/lammps/logs/build_arm_%j.err

set -euo pipefail

LAMMPS_TAG="${LAMMPS_TAG:-stable_2Aug2023_update3}"
OMPI_VERSION="${OMPI_VERSION:-4}"
BASE_DIR="${BASE_DIR:-/fsx/lammps}"
TARGET="${TARGET:-auto}"
COMPILE_CORES="${COMPILE_CORES:-48}"

# ---------------------------------------------------------------------------
# Detect Graviton generation from /proc/cpuinfo CPU-part field.
#   0xd40 = Neoverse V1 -> Graviton3 / Graviton3E
#   0xd4f = Neoverse V2 -> Graviton4
# ---------------------------------------------------------------------------
if [ "${TARGET}" = "auto" ]; then
    cpu_part=$(awk '/CPU part/ {print $NF; exit}' /proc/cpuinfo)
    case "${cpu_part}" in
        0xd40) TARGET="graviton3" ;;
        0xd4f) TARGET="graviton4" ;;
        *)
            echo "Unknown CPU part ${cpu_part}; set TARGET=graviton3 or graviton4 explicitly" >&2
            exit 1
            ;;
    esac
fi

case "${TARGET}" in
    graviton3)
        MCPU_FLAG="neoverse-v1"
        TARGET_TAG="aarch64-graviton3"
        ;;
    graviton4)
        MCPU_FLAG="neoverse-v2"
        TARGET_TAG="aarch64-graviton4"
        ;;
    *)
        echo "Unknown TARGET: ${TARGET} (expected: graviton3 | graviton4)" >&2
        exit 1
        ;;
esac

case "${OMPI_VERSION}" in
    4)
        OMPI_MODULE="openmpi/4.1.7"
        OMPI_ROOT="/opt/amazon/openmpi"
        OMPI_TAG=""
        ;;
    5)
        OMPI_MODULE="openmpi5/5.0.9amzn1"
        OMPI_ROOT="/opt/amazon/openmpi5"
        OMPI_TAG="-ompi5"
        ;;
    *)
        echo "Unknown OMPI_VERSION: ${OMPI_VERSION} (expected: 4 | 5)" >&2
        exit 1
        ;;
esac

BUILD_DIR="${BASE_DIR}/build/${TARGET_TAG}${OMPI_TAG}-${LAMMPS_TAG}"
INSTALL_DIR="${BASE_DIR}/${TARGET_TAG}${OMPI_TAG}/${LAMMPS_TAG}"
ENV_SCRIPT="${BASE_DIR}/${TARGET_TAG}${OMPI_TAG}/lammps-${LAMMPS_TAG}${OMPI_TAG}-env.sh"
LOG_DIR="${BASE_DIR}/logs"

mkdir -p "${LOG_DIR}" "${BUILD_DIR}" "$(dirname "${INSTALL_DIR}")"

LOG_FILE="${LOG_DIR}/build_${TARGET_TAG}${OMPI_TAG}_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "${LOG_FILE}") 2>&1

trap 'echo "ERROR: Build failed. Logs at ${LOG_FILE}"; exit 1' ERR

echo "=== LAMMPS Arm build started at $(date) ==="
echo "Host:        $(hostname)"
echo "Tag:         ${LAMMPS_TAG}"
echo "Target:      ${TARGET} (mcpu=${MCPU_FLAG})"
echo "OpenMPI:     ${OMPI_VERSION} (${OMPI_MODULE})"
echo "Install dir: ${INSTALL_DIR}"
echo "Env script:  ${ENV_SCRIPT}"

CXX_FLAGS="-O3 -mcpu=${MCPU_FLAG} -mtune=${MCPU_FLAG} -DNDEBUG"
echo "CXX flags: ${CXX_FLAGS}"

# ---------------------------------------------------------------------------
# Prereqs
# ---------------------------------------------------------------------------
echo "=== Installing build prerequisites ==="
sudo dnf install -y git cmake make gcc-c++ gcc-gfortran fftw-devel python3 which 2>&1 | tail -5
echo "GCC:    $(gcc --version | head -1)"
echo "G++:    $(g++ --version | head -1)"
echo "CMake:  $(cmake --version | head -1)"

module load "${OMPI_MODULE}"
module load libfabric-aws
echo "OpenMPI: $("${OMPI_ROOT}"/bin/mpirun --version | head -1)"
echo "OpenMPI root: ${OMPI_ROOT}"

# ---------------------------------------------------------------------------
# Source checkout
# ---------------------------------------------------------------------------
cd "${BUILD_DIR}"
if [ ! -d lammps/.git ]; then
    echo "=== Cloning LAMMPS @ ${LAMMPS_TAG} ==="
    git clone --depth=1 --branch "${LAMMPS_TAG}" \
        https://github.com/lammps/lammps.git lammps
else
    echo "=== Re-using existing checkout in $(pwd)/lammps ==="
    (cd lammps && git reset --hard HEAD && git clean -fdx) || true
fi

# ---------------------------------------------------------------------------
# Configure with CMake (same package set as the x86 build)
# ---------------------------------------------------------------------------
mkdir -p lammps/build
cd lammps/build
echo "=== Running CMake ==="
cmake ../cmake \
    -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_FLAGS="${CXX_FLAGS}" \
    -DCMAKE_C_FLAGS="${CXX_FLAGS}" \
    -DBUILD_SHARED_LIBS=on \
    -DBUILD_MPI=yes \
    -DBUILD_OMP=yes \
    -DFFT=FFTW3 \
    -DPKG_KSPACE=on \
    -DPKG_MANYBODY=on \
    -DPKG_MOLECULE=on \
    -DPKG_RIGID=on \
    -DPKG_REPLICA=on \
    -DPKG_MISC=on \
    -DPKG_EXTRA-DUMP=on \
    -DPKG_EXTRA-FIX=on

# ---------------------------------------------------------------------------
# Compile + install
# ---------------------------------------------------------------------------
echo ""
echo "=== Building (${COMPILE_CORES} cores) ==="
cmake --build . --parallel "${COMPILE_CORES}"

echo ""
echo "=== Installing to ${INSTALL_DIR} ==="
rm -rf "${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}"
cmake --install .

# ---------------------------------------------------------------------------
# Verify the binary exists and runs
# ---------------------------------------------------------------------------
LMP_BIN="${INSTALL_DIR}/bin/lmp"
if [ ! -x "${LMP_BIN}" ]; then
    echo "ERROR: expected binary not found: ${LMP_BIN}" >&2
    exit 1
fi
echo ""
echo "=== Smoke test: lmp -h ==="
file "${LMP_BIN}"
"${LMP_BIN}" -h 2>&1 | head -20 || true

# ---------------------------------------------------------------------------
# Env script
# ---------------------------------------------------------------------------
cat > "${ENV_SCRIPT}" <<ENV
#!/bin/bash
# LAMMPS ${LAMMPS_TAG} — ${TARGET_TAG} (GCC + OpenMPI ${OMPI_VERSION}, ${MCPU_FLAG})
module purge
module load ${OMPI_MODULE}
module load libfabric-aws
export LAMMPS_ROOT="${INSTALL_DIR}"
export LAMMPS_TAG="${LAMMPS_TAG}"
export PATH="\${LAMMPS_ROOT}/bin:\${PATH}"
export LD_LIBRARY_PATH="\${LAMMPS_ROOT}/lib64:\${LAMMPS_ROOT}/lib:\${LD_LIBRARY_PATH:-}"
ENV
chmod +x "${ENV_SCRIPT}"

echo ""
echo "=== LAMMPS Arm build complete at $(date) ==="
echo "Install dir: ${INSTALL_DIR}"
echo "Env script:  ${ENV_SCRIPT}"
echo "Log:         ${LOG_FILE}"
