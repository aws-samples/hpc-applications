#!/bin/bash
# Build OpenRadioss for x86_64 (hpc8a / hpc7a) using GCC + OpenMPI.
#
# OpenRadioss is the open source version of Altair Radioss, an explicit
# finite element solver for highly non-linear dynamic events (crash,
# impact, blast, ...).  https://openradioss.org
#
# This build uses the upstream "linux64_gf" architecture target (GCC +
# gfortran) with OpenMPI support.  Upstream recommends OpenMPI 4.1.2+
# but any OpenMPI 4.1 works; we use the system module (4.1.7) so EFA is
# automatically available at runtime.
#
# Override via --export=ALL,...:
#   OPENRADIOSS_TAG       release tag to build (default: latest-20260319)
#   BASE_DIR              install root (default: /fsx/openradioss)
#   TARGET_CPU            compiler micro-arch:
#                           hpc8a (default, Zen5 / AVX-512)
#                           hpc7a (Zen4 / AVX-512)
#                           generic-avx2 (Zen3+, portable)
#   COMPILE_CORES         parallel compile threads (default: 48)

#SBATCH --job-name=build-openradioss
#SBATCH -p hpc8a
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=192
#SBATCH --time=03:00:00
#SBATCH --exclusive
#SBATCH --output=/fsx/openradioss/logs/build_x86_%j.out
#SBATCH --error=/fsx/openradioss/logs/build_x86_%j.err

set -euo pipefail

OPENRADIOSS_TAG="${OPENRADIOSS_TAG:-latest-20260319}"
BASE_DIR="${BASE_DIR:-/fsx/openradioss}"
TARGET_CPU="${TARGET_CPU:-hpc8a}"
COMPILE_CORES="${COMPILE_CORES:-48}"

BUILD_DIR="${BASE_DIR}/build/x86_64-${OPENRADIOSS_TAG}"
INSTALL_DIR="${BASE_DIR}/x86_64/${OPENRADIOSS_TAG}"
ENV_SCRIPT="${BASE_DIR}/x86_64/openradioss-${OPENRADIOSS_TAG}-env.sh"
LOG_DIR="${BASE_DIR}/logs"

mkdir -p "${LOG_DIR}" "${BUILD_DIR}" "$(dirname "${INSTALL_DIR}")"

LOG_FILE="${LOG_DIR}/build_x86_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "${LOG_FILE}") 2>&1

trap 'echo "ERROR: Build failed. Logs at ${LOG_FILE}"; exit 1' ERR

echo "=== OpenRadioss x86 build started at $(date) ==="
echo "Host:        $(hostname)"
echo "Tag:         ${OPENRADIOSS_TAG}"
echo "Target CPU:  ${TARGET_CPU}"
echo "Install dir: ${INSTALL_DIR}"
echo "Env script:  ${ENV_SCRIPT}"
echo "Build dir:   ${BUILD_DIR}"

# ---------------------------------------------------------------------------
# Pick the compile flags for the requested micro-arch.
# These are ADDITIONAL flags; the upstream build_script.sh already sets -O3
# for the "release" build.  We add -march / -mtune to enable AVX-512 on
# Zen4/Zen5 and keep a portable AVX2 variant for cross-instance comparison.
#
# Note: GCC 11.5 (AL2023) only knows up to znver4.  hpc8a (Zen5) compiles
# fine with "-mtune=znver4 -march=x86-64-v4" — AVX-512 is emitted and the
# binary runs optimally on Zen5 too; we miss only a handful of Zen5-only
# scheduling tweaks.  Use TARGET_CPU=hpc8a-gcc14 once GCC 14 is available.
# ---------------------------------------------------------------------------
case "${TARGET_CPU}" in
    hpc8a|hpc7a)
        ADDFLAG="-march=x86-64-v4 -mtune=znver4"
        ;;
    generic-avx2)
        ADDFLAG="-march=x86-64-v3 -mtune=generic"
        ;;
    *)
        echo "Unknown TARGET_CPU: ${TARGET_CPU}" >&2
        exit 1
        ;;
esac
echo "Compile flags addflag: ${ADDFLAG}"

# ---------------------------------------------------------------------------
# System prerequisites (safe to re-run; dnf will just say "already installed").
# OpenRadioss needs git, git-lfs (for bundled binary assets), cmake, gcc 11+,
# gfortran, make, perl, python3.  Everything except git-lfs is already on
# AL2023 HPC images.
# ---------------------------------------------------------------------------
echo "=== Installing build prerequisites ==="
sudo dnf install -y git git-lfs cmake make perl python3 which 2>&1 | tail -5
git lfs install --skip-smudge || true
echo "GCC: $(gcc --version | head -1)"
echo "gfortran: $(gfortran --version | head -1)"
echo "CMake: $(cmake --version | head -1)"

# ---------------------------------------------------------------------------
# Make OpenMPI visible at build time (OpenRadioss build_script.sh defaults
# OMPI to /opt/openmpi; we override via -mpi-root).
# ---------------------------------------------------------------------------
module load openmpi/4.1.7
module load libfabric-aws
OMPI_ROOT="${OPENMPI_ROOT:-/opt/amazon/openmpi}"
# On AL2023 the Amazon-built OpenMPI places libs under lib64 (not lib), so
# OpenRadioss's default -mpi-root expansion of "-L${root}/lib" fails to
# find libmpi. Pass the lib and include directories explicitly instead.
OMPI_INC="${OMPI_ROOT}/include"
OMPI_LIB="${OMPI_ROOT}/lib64"
echo "OpenMPI: $(${OMPI_ROOT}/bin/mpirun --version | head -1)"
echo "OpenMPI include: ${OMPI_INC}"
echo "OpenMPI libdir:  ${OMPI_LIB}"

# ---------------------------------------------------------------------------
# Checkout the release tag (shallow) and enable LFS for the stored extlib
# artefacts.  On a redo we just reset --hard so partial builds don't poison
# the next run.
# ---------------------------------------------------------------------------
cd "${BUILD_DIR}"
if [ ! -d OpenRadioss/.git ]; then
    echo "=== Cloning OpenRadioss @ ${OPENRADIOSS_TAG} ==="
    git clone --depth=1 --branch "${OPENRADIOSS_TAG}" \
        https://github.com/OpenRadioss/OpenRadioss.git OpenRadioss
else
    echo "=== Re-using existing checkout in $(pwd)/OpenRadioss ==="
    (cd OpenRadioss && git reset --hard HEAD && git clean -fdx) || true
fi
cd OpenRadioss
git lfs pull || true

# ---------------------------------------------------------------------------
# Build STARTER (pre-processor, no MPI, OpenMP only).
# ---------------------------------------------------------------------------
echo ""
echo "=== Building Starter (${COMPILE_CORES} cores) ==="
pushd starter >/dev/null
./build_script.sh -arch=linux64_gf -release \
    -nt="${COMPILE_CORES}" \
    -addflag="${ADDFLAG}"
popd >/dev/null

# ---------------------------------------------------------------------------
# Build ENGINE with OpenMPI (MPI+OpenMP hybrid).  -mpi-root points the
# build at the system OpenMPI so the result links against /opt/amazon/openmpi
# and can use EFA at runtime.
# ---------------------------------------------------------------------------
echo ""
echo "=== Building Engine (${COMPILE_CORES} cores, OpenMPI) ==="
pushd engine >/dev/null
./build_script.sh -arch=linux64_gf -mpi=ompi -release \
    -mpi-include="${OMPI_INC}" \
    -mpi-libdir="${OMPI_LIB}" \
    -nt="${COMPILE_CORES}" \
    -addflag="${ADDFLAG}"
popd >/dev/null

# ---------------------------------------------------------------------------
# Verify the expected binaries landed in OpenRadioss/exec/ and then copy the
# whole OpenRadioss tree into the install prefix (the hm_cfg_files/, extlib/
# and exec/ directories are all needed at runtime).
# ---------------------------------------------------------------------------
STARTER_BIN="exec/starter_linux64_gf"
ENGINE_BIN="exec/engine_linux64_gf_ompi"
for bin in "${STARTER_BIN}" "${ENGINE_BIN}"; do
    if [ ! -x "${bin}" ]; then
        echo "ERROR: expected binary not found: ${bin}" >&2
        exit 1
    fi
    file "${bin}"
done

echo ""
echo "=== Installing to ${INSTALL_DIR} ==="
rm -rf "${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}"
# Copy the subset needed at runtime.
cp -a exec "${INSTALL_DIR}/"
cp -a hm_cfg_files "${INSTALL_DIR}/"
cp -a extlib "${INSTALL_DIR}/" 2>/dev/null || true

# OpenRadioss ships a pre-built libapr-1.so.0 under extlib/hm_reader which
# is linked against libcrypt.so.1 (the older libxcrypt SONAME). AL2023
# compute nodes ship only libcrypt.so.2 via libxcrypt, so the bundled apr
# fails to load with "libcrypt.so.1: cannot open shared object file" when
# we put extlib/hm_reader on LD_LIBRARY_PATH. Rename the bundled apr so
# the system /lib64/libapr-1.so.0 (which links against libcrypt.so.2) is
# picked up instead. Starter and engine need no apr functions beyond what
# the system version provides.
if [ -f "${INSTALL_DIR}/extlib/hm_reader/linux64/libapr-1.so.0" ]; then
    mv "${INSTALL_DIR}/extlib/hm_reader/linux64/libapr-1.so.0" \
       "${INSTALL_DIR}/extlib/hm_reader/linux64/libapr-1.so.0.bundled"
    echo "Renamed bundled libapr-1.so.0 so the system libapr is used at runtime"
fi

# ---------------------------------------------------------------------------
# Env script — pulls in the right modules and exports OpenRadioss paths.
# Benchmark scripts source this file.
# ---------------------------------------------------------------------------
cat > "${ENV_SCRIPT}" <<ENV
#!/bin/bash
# OpenRadioss ${OPENRADIOSS_TAG} — x86_64 build (GCC + OpenMPI, ${TARGET_CPU})
module purge
module load openmpi/4.1.7
module load libfabric-aws
export OPENRADIOSS_ROOT="${INSTALL_DIR}"
export PATH="\${OPENRADIOSS_ROOT}/exec:\${PATH}"
export RAD_CFG_PATH="\${OPENRADIOSS_ROOT}/hm_cfg_files"
# hm_reader and h3d ship as shared libraries under extlib; starter / engine
# link against them at runtime.
for d in "\${OPENRADIOSS_ROOT}/extlib/hm_reader/linux64" \\
         "\${OPENRADIOSS_ROOT}/extlib/h3d/lib/linux64"; do
    [ -d "\${d}" ] && export LD_LIBRARY_PATH="\${d}:\${LD_LIBRARY_PATH:-}"
done
ENV
chmod +x "${ENV_SCRIPT}"

echo ""
echo "=== OpenRadioss x86 build complete at $(date) ==="
echo "Install dir: ${INSTALL_DIR}"
echo "Env script:  ${ENV_SCRIPT}"
echo "Log:         ${LOG_FILE}"
