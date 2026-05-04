#!/bin/bash
# Build OpenRadioss for aarch64 (Graviton3E / Graviton4) using GCC + OpenMPI.
#
# OpenRadioss is the open source version of Altair Radioss, an explicit
# finite element solver for highly non-linear dynamic events (crash,
# impact, blast, ...).  https://openradioss.org
#
# Upstream ships two Arm build targets: linuxa64 (ArmFlang, the default)
# and linuxa64_gf (GCC + gfortran).  We use the GCC target because:
#   * AL2023 does not ship ArmFlang by default
#   * OpenFOAM and WRF on this cluster use the GCC path too
#   * performance parity between GCC and ACfL on Graviton4 was verified
#     on OpenFOAM (within 0.1-0.6%)
#
# Graviton generation is auto-detected from /proc/cpuinfo so a single
# script targets both hpc7g (Neoverse V1) and m8g / r8g (Neoverse V2).
# Override via TARGET=graviton3 or TARGET=graviton4.
#
# Override via --export=ALL,...:
#   OPENRADIOSS_TAG       release tag (default: latest-20260319)
#   OMPI_VERSION          4 (default, /opt/amazon/openmpi)
#                          or 5 (/opt/amazon/openmpi5) — recommended for
#                          Graviton4 running >128 ranks/node
#   BASE_DIR              install root (default: /fsx/openradioss)
#   TARGET                graviton3 | graviton4 | auto (default)
#   COMPILE_CORES         parallel compile threads (default: 48)

#SBATCH --job-name=build-openradioss-arm
#SBATCH -p hpc7g
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=64
#SBATCH --time=03:00:00
#SBATCH --exclusive
#SBATCH --output=/fsx/openradioss/logs/build_arm_%j.out
#SBATCH --error=/fsx/openradioss/logs/build_arm_%j.err

set -euo pipefail

OPENRADIOSS_TAG="${OPENRADIOSS_TAG:-latest-20260319}"
OMPI_VERSION="${OMPI_VERSION:-4}"
BASE_DIR="${BASE_DIR:-/fsx/openradioss}"
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

BUILD_DIR="${BASE_DIR}/build/${TARGET_TAG}${OMPI_TAG}-${OPENRADIOSS_TAG}"
INSTALL_DIR="${BASE_DIR}/${TARGET_TAG}${OMPI_TAG}/${OPENRADIOSS_TAG}"
ENV_SCRIPT="${BASE_DIR}/${TARGET_TAG}${OMPI_TAG}/openradioss-${OPENRADIOSS_TAG}${OMPI_TAG}-env.sh"
LOG_DIR="${BASE_DIR}/logs"

mkdir -p "${LOG_DIR}" "${BUILD_DIR}" "$(dirname "${INSTALL_DIR}")"

LOG_FILE="${LOG_DIR}/build_${TARGET_TAG}${OMPI_TAG}_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "${LOG_FILE}") 2>&1

trap 'echo "ERROR: Build failed. Logs at ${LOG_FILE}"; exit 1' ERR

echo "=== OpenRadioss Arm build started at $(date) ==="
echo "Host:        $(hostname)"
echo "Tag:         ${OPENRADIOSS_TAG}"
echo "Target:      ${TARGET} (mcpu=${MCPU_FLAG})"
echo "OpenMPI:     ${OMPI_VERSION} (${OMPI_MODULE})"
echo "Install dir: ${INSTALL_DIR}"
echo "Env script:  ${ENV_SCRIPT}"

ADDFLAG="-mcpu=${MCPU_FLAG} -mtune=${MCPU_FLAG}"
echo "Compile addflag: ${ADDFLAG}"

# ---------------------------------------------------------------------------
# Prereqs
# ---------------------------------------------------------------------------
echo "=== Installing build prerequisites ==="
sudo dnf install -y git git-lfs cmake make perl python3 which 2>&1 | tail -5
git lfs install --skip-smudge || true
echo "GCC: $(gcc --version | head -1)"
echo "gfortran: $(gfortran --version | head -1)"
echo "CMake: $(cmake --version | head -1)"

module load "${OMPI_MODULE}"
module load libfabric-aws
# On AL2023 the Amazon-built OpenMPI places libs under lib64 (not lib), so
# OpenRadioss's default -mpi-root expansion of "-L${root}/lib" fails to
# find libmpi. Pass the lib and include directories explicitly instead.
OMPI_INC="${OMPI_ROOT}/include"
OMPI_LIB="${OMPI_ROOT}/lib64"
echo "OpenMPI: $(${OMPI_ROOT}/bin/mpirun --version | head -1)"
echo "OpenMPI include: ${OMPI_INC}"
echo "OpenMPI libdir:  ${OMPI_LIB}"

# ---------------------------------------------------------------------------
# Source checkout
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
# Patch an upstream bug in OpenRadioss' Arm GCC CMake config:
# cmake_linuxa64_gf.txt forgets ${md5_inc} in the release-build c_source and
# cpp_source flag lines, so Starter fails with "fatal error: md5.h: No such
# file or directory" on a release build. Debug and asan branches have it.
# Insert md5_inc alongside zlib_inc on the release lines.
# This is purely additive, safe to re-apply, and only affects the Arm GCC
# build variant we use here.
# ---------------------------------------------------------------------------
for f in starter/CMake_Compilers/cmake_linuxa64_gf.txt \
         engine/CMake_Compilers/cmake_linuxa64_gf.txt; do
    if [ -f "${f}" ] && ! grep -q '${zlib_inc} ${md5_inc} -O2 -fopenmp -march=armv8-a' "${f}"; then
        sed -i 's|\${zlib_inc} -O2 -fopenmp -march=armv8-a -DARCH_CPU=ARM|${zlib_inc} ${md5_inc} -O2 -fopenmp -march=armv8-a -DARCH_CPU=ARM|g' "${f}"
        sed -i 's|\${zlib_inc} -O2 -fopenmp -std=c++11|${zlib_inc} ${md5_inc} -O2 -fopenmp -std=c++11|g' "${f}"
        echo "Patched ${f} to include md5_inc in the release C/CXX compile flags"
    fi
done

# ---------------------------------------------------------------------------
# Starter (SMP, no MPI)
# ---------------------------------------------------------------------------
echo ""
echo "=== Building Starter (${COMPILE_CORES} cores) ==="
pushd starter >/dev/null
./build_script.sh -arch=linuxa64_gf -release \
    -nt="${COMPILE_CORES}" \
    -addflag="${ADDFLAG}"
popd >/dev/null

# ---------------------------------------------------------------------------
# Engine (MPI+OpenMP hybrid)
# ---------------------------------------------------------------------------
echo ""
echo "=== Building Engine (${COMPILE_CORES} cores, OpenMPI ${OMPI_VERSION}) ==="
pushd engine >/dev/null
./build_script.sh -arch=linuxa64_gf -mpi=ompi -release \
    -mpi-include="${OMPI_INC}" \
    -mpi-libdir="${OMPI_LIB}" \
    -nt="${COMPILE_CORES}" \
    -addflag="${ADDFLAG}"
popd >/dev/null

# ---------------------------------------------------------------------------
# Verify + install
# ---------------------------------------------------------------------------
STARTER_BIN="exec/starter_linuxa64_gf"
ENGINE_BIN="exec/engine_linuxa64_gf_ompi"
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
cp -a exec "${INSTALL_DIR}/"
cp -a hm_cfg_files "${INSTALL_DIR}/"
cp -a extlib "${INSTALL_DIR}/" 2>/dev/null || true

# Rename the bundled libapr-1.so.0 (linked against libcrypt.so.1 which is
# not on AL2023) so runtime picks up the system libapr from /lib64. See
# build_openradioss_x86.sbatch for the full rationale.
if [ -f "${INSTALL_DIR}/extlib/hm_reader/linuxa64/libapr-1.so.0" ]; then
    mv "${INSTALL_DIR}/extlib/hm_reader/linuxa64/libapr-1.so.0" \
       "${INSTALL_DIR}/extlib/hm_reader/linuxa64/libapr-1.so.0.bundled"
    echo "Renamed bundled libapr-1.so.0 so the system libapr is used at runtime"
fi

cat > "${ENV_SCRIPT}" <<ENV
#!/bin/bash
# OpenRadioss ${OPENRADIOSS_TAG} — ${TARGET_TAG} (GCC + OpenMPI ${OMPI_VERSION}, ${MCPU_FLAG})
module purge
module load ${OMPI_MODULE}
module load libfabric-aws
export OPENRADIOSS_ROOT="${INSTALL_DIR}"
export PATH="\${OPENRADIOSS_ROOT}/exec:\${PATH}"
export RAD_CFG_PATH="\${OPENRADIOSS_ROOT}/hm_cfg_files"
# hm_reader and h3d ship as shared libraries under extlib; starter / engine
# link against them at runtime.
for d in "\${OPENRADIOSS_ROOT}/extlib/hm_reader/linuxa64" \\
         "\${OPENRADIOSS_ROOT}/extlib/h3d/lib/linuxa64"; do
    [ -d "\${d}" ] && export LD_LIBRARY_PATH="\${d}:\${LD_LIBRARY_PATH:-}"
done
ENV
chmod +x "${ENV_SCRIPT}"

echo ""
echo "=== OpenRadioss Arm build complete at $(date) ==="
echo "Install dir: ${INSTALL_DIR}"
echo "Env script:  ${ENV_SCRIPT}"
echo "Log:         ${LOG_FILE}"
