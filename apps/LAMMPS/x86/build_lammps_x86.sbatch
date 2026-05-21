#!/bin/bash
# Build LAMMPS for x86_64 (hpc8a / hpc7a) using GCC + system OpenMPI 4.1.7.
#
# LAMMPS is the Large-scale Atomic/Molecular Massively Parallel Simulator from
# Sandia National Laboratories. It is the de-facto standard open-source
# molecular dynamics code in materials science, chemistry, and physics.
#   https://www.lammps.org/   https://github.com/lammps/lammps
#
# Build is CMake-based, links against the Amazon-provided OpenMPI at
# /opt/amazon/openmpi (so EFA is automatic at runtime), and enables the
# packages we need for the LJ-melt, Rhodopsin, and EAM benchmarks.
#
# Override via --export=ALL,...:
#   LAMMPS_TAG       release tag from github.com/lammps/lammps
#                    (default: stable_2Aug2023_update3)
#   BASE_DIR         install root (default: /fsx/lammps)
#   TARGET_CPU       compiler micro-arch:
#                      hpc8a (default, Zen5 / AVX-512)
#                      hpc7a (Zen4 / AVX-512)
#                      generic-avx2 (Zen3+, portable)
#   COMPILE_CORES    parallel compile threads (default: 48)

#SBATCH --job-name=build-lammps
#SBATCH -p hpc8a
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=192
#SBATCH --time=02:00:00
#SBATCH --exclusive
#SBATCH --output=/fsx/lammps/logs/build_x86_%j.out
#SBATCH --error=/fsx/lammps/logs/build_x86_%j.err

set -euo pipefail

LAMMPS_TAG="${LAMMPS_TAG:-stable_2Aug2023_update3}"
BASE_DIR="${BASE_DIR:-/fsx/lammps}"
TARGET_CPU="${TARGET_CPU:-hpc8a}"
COMPILE_CORES="${COMPILE_CORES:-48}"

BUILD_DIR="${BASE_DIR}/build/x86_64-${LAMMPS_TAG}"
INSTALL_DIR="${BASE_DIR}/x86_64/${LAMMPS_TAG}"
ENV_SCRIPT="${BASE_DIR}/x86_64/lammps-${LAMMPS_TAG}-env.sh"
LOG_DIR="${BASE_DIR}/logs"

mkdir -p "${LOG_DIR}" "${BUILD_DIR}" "$(dirname "${INSTALL_DIR}")"

LOG_FILE="${LOG_DIR}/build_x86_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "${LOG_FILE}") 2>&1

trap 'echo "ERROR: Build failed. Logs at ${LOG_FILE}"; exit 1' ERR

echo "=== LAMMPS x86 build started at $(date) ==="
echo "Host:        $(hostname)"
echo "Tag:         ${LAMMPS_TAG}"
echo "Target CPU:  ${TARGET_CPU}"
echo "Install dir: ${INSTALL_DIR}"
echo "Env script:  ${ENV_SCRIPT}"
echo "Build dir:   ${BUILD_DIR}"

# ---------------------------------------------------------------------------
# Pick the compile flags for the requested micro-arch. GCC 11.5 (AL2023) only
# knows up to znver4. hpc8a (Zen5) compiles fine with -mtune=znver4 +
# -march=x86-64-v4 — AVX-512 is emitted and the binary runs optimally on
# Zen5 too; we only miss a few Zen5-only scheduling tweaks.
# ---------------------------------------------------------------------------
case "${TARGET_CPU}" in
    hpc8a|hpc7a)
        CXX_FLAGS="-O3 -march=x86-64-v4 -mtune=znver4 -DNDEBUG"
        ;;
    generic-avx2)
        CXX_FLAGS="-O3 -march=x86-64-v3 -mtune=generic -DNDEBUG"
        ;;
    *)
        echo "Unknown TARGET_CPU: ${TARGET_CPU} (expected: hpc8a | hpc7a | generic-avx2)" >&2
        exit 1
        ;;
esac
echo "CXX flags: ${CXX_FLAGS}"

# ---------------------------------------------------------------------------
# Prereqs (safe to re-run; dnf will say "already installed").
# LAMMPS needs: cmake >= 3.16, gcc/g++ 11+, gfortran (for some packages),
# git, make, fftw3-devel (for KSPACE+FFT).
# ---------------------------------------------------------------------------
echo "=== Installing build prerequisites ==="
sudo dnf install -y git cmake make gcc-c++ gcc-gfortran fftw-devel python3 which 2>&1 | tail -5
echo "GCC:    $(gcc --version | head -1)"
echo "G++:    $(g++ --version | head -1)"
echo "CMake:  $(cmake --version | head -1)"

# ---------------------------------------------------------------------------
# Make OpenMPI visible at build time. CMake's FindMPI will pick it up via
# the loaded module's PATH/MPI_HOME.
# ---------------------------------------------------------------------------
module load openmpi/4.1.7
module load libfabric-aws
OMPI_ROOT="${OPENMPI_ROOT:-/opt/amazon/openmpi}"
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
# Configure with CMake. The packages we enable cover all three benchmarks:
#   KSPACE    -> long-range electrostatics (PPPM) for in.rhodo
#   MANYBODY  -> EAM and Tersoff potentials for in.eam
#   MOLECULE  -> bonds/angles/dihedrals for in.rhodo
#   RIGID     -> rigid bodies for in.rhodo (water SHAKE)
#   REPLICA   -> replica exchange (cheap, useful)
#   MISC      -> assorted commonly-used utilities
# We also add EXTRA-DUMP and EXTRA-FIX which cost nothing and unlock common
# output formats users expect.
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
# Env script — pulls in the right modules and exports paths so benchmark
# scripts can `source` it.
# ---------------------------------------------------------------------------
cat > "${ENV_SCRIPT}" <<ENV
#!/bin/bash
# LAMMPS ${LAMMPS_TAG} — x86_64 (GCC + OpenMPI 4.1.7, ${TARGET_CPU})
module purge
module load openmpi/4.1.7
module load libfabric-aws
export LAMMPS_ROOT="${INSTALL_DIR}"
export LAMMPS_TAG="${LAMMPS_TAG}"
export PATH="\${LAMMPS_ROOT}/bin:\${PATH}"
export LD_LIBRARY_PATH="\${LAMMPS_ROOT}/lib64:\${LAMMPS_ROOT}/lib:\${LD_LIBRARY_PATH:-}"
ENV
chmod +x "${ENV_SCRIPT}"

echo ""
echo "=== LAMMPS x86 build complete at $(date) ==="
echo "Install dir: ${INSTALL_DIR}"
echo "Env script:  ${ENV_SCRIPT}"
echo "Log:         ${LOG_FILE}"
