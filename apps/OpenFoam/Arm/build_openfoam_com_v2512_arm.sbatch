#!/bin/bash
# Build OpenFOAM v2512 (openfoam.com) from source on AWS ParallelCluster — Arm
# Single script for Graviton3E (hpc7g / Neoverse V1) and Graviton4 (m8g, r8g / Neoverse V2).
# Compiler: GCC 14
#
# Target is auto-detected from /proc/cpuinfo at runtime. The correct flags and
# install path are selected based on the CPU the build runs on. Simply submit
# to the partition you want to build for:
#
#   # Graviton3E (hpc7g.16xlarge, 64 cores)
#   sbatch -p hpc7g --ntasks-per-node=64 build_openfoam_com_v2512_arm.sbatch
#
#   # Graviton4 (m8g.48xlarge, 192 cores)
#   sbatch -p m8g --ntasks-per-node=192 build_openfoam_com_v2512_arm.sbatch
#
# You can also force a target with: TARGET=graviton3|graviton4

#SBATCH --job-name=build-of-v2512-arm
#SBATCH --nodes=1
#SBATCH --time=05:00:00
#SBATCH --output=/fsx/openfoam/logs/build_v2512_arm_%j.out
#SBATCH --error=/fsx/openfoam/logs/build_v2512_arm_%j.err
#SBATCH --exclusive

set -euo pipefail

VERSION="v2512"
COMPILE_CORES=48

# ---------------------------------------------------------------------------
# Auto-detect Graviton generation from CPU part number
#   Graviton3/3E → Neoverse V1 (CPU part 0xd40) → -mcpu=neoverse-v1
#   Graviton4    → Neoverse V2 (CPU part 0xd4f) → -mcpu=neoverse-v2
# ---------------------------------------------------------------------------
TARGET="${TARGET:-auto}"
if [ "$TARGET" = "auto" ]; then
    CPU_PART=$(awk '/^CPU part/ {print $NF; exit}' /proc/cpuinfo)
    case "$CPU_PART" in
        0xd40) TARGET="graviton3" ;;
        0xd4f) TARGET="graviton4" ;;
        *)     echo "ERROR: Unknown CPU part $CPU_PART. Set TARGET=graviton3|graviton4 to override."; exit 1 ;;
    esac
fi

case "$TARGET" in
    graviton3)
        ARCH_TAG="graviton3"
        MCPU="neoverse-v1"
        DESC="Graviton3E / Neoverse V1 / SVE 256-bit (hpc7g)"
        ;;
    graviton4)
        ARCH_TAG="graviton4"
        MCPU="neoverse-v2"
        DESC="Graviton4 / Neoverse V2 / SVE2 128-bit (m8g / r8g)"
        ;;
    *)
        echo "ERROR: TARGET must be graviton3 or graviton4 (got: $TARGET)"
        exit 1
        ;;
esac

BUILD_DIR="/fsx/tmp/openfoam-build-${ARCH_TAG}"
INSTALL_DIR="/fsx/openfoam/aarch64-${ARCH_TAG}/${VERSION}"

LOG_FILE="/fsx/openfoam/logs/build_v2512_${ARCH_TAG}_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

cleanup_on_failure() {
    echo "ERROR: Build failed. Logs at: $LOG_FILE"
    echo "Build dir preserved at: $BUILD_DIR/"
    exit 1
}
trap cleanup_on_failure ERR

echo "=== OpenFOAM ${VERSION} ${DESC} build started at $(date) ==="
echo "Host:    $(hostname)"
echo "Job ID:  ${SLURM_JOB_ID:-N/A}"
echo "Target:  ${TARGET} (-mcpu=${MCPU})"

# ---------------------------------------------------------------------------
# Create directories
# ---------------------------------------------------------------------------
mkdir -p /fsx/openfoam/logs
mkdir -p "$BUILD_DIR"
mkdir -p "$(dirname "$INSTALL_DIR")"

# ---------------------------------------------------------------------------
# Install GCC 14 and build dependencies
# ---------------------------------------------------------------------------
echo "=== Installing GCC 14 and build dependencies ==="
sudo dnf install -y \
    gcc14 gcc14-c++ gcc14-gfortran \
    gcc gcc-c++ gcc-gfortran \
    make cmake git ca-certificates flex \
    zlib-devel boost-devel fftw-devel \
    readline-devel ncurses-devel libcurl-devel

# Symlink GCC 14 so wmake's Gcc rules find them
GCC14_BIN="/fsx/tmp/gcc14-bin-aarch64"
mkdir -p "$GCC14_BIN"
ln -sf /usr/bin/gcc14-gcc "$GCC14_BIN/gcc"
ln -sf /usr/bin/gcc14-g++ "$GCC14_BIN/g++"
ln -sf /usr/bin/gcc14-gfortran "$GCC14_BIN/gfortran"
export PATH="$GCC14_BIN:$PATH"

echo "Compiler: $(gcc --version | head -1)"

# MPI — use ParallelCluster OpenMPI
if [ -d /opt/amazon/openmpi/bin ]; then
    export PATH="/opt/amazon/openmpi/bin:$PATH"
    export LD_LIBRARY_PATH="/opt/amazon/openmpi/lib:${LD_LIBRARY_PATH:-}"
    export MPI_HOME="/opt/amazon/openmpi"
    echo "MPI: $(mpirun --version 2>&1 | head -1)"
fi

# ---------------------------------------------------------------------------
# Download and extract sources
# ---------------------------------------------------------------------------
cd "$BUILD_DIR"

echo "=== Downloading OpenFOAM ${VERSION} ==="
if [ ! -d "$BUILD_DIR/OpenFOAM-${VERSION}" ]; then
    curl -L -o "$BUILD_DIR/OpenFOAM-${VERSION}.tgz" \
        "https://sourceforge.net/projects/openfoam/files/${VERSION}/OpenFOAM-${VERSION}.tgz"
    tar xzf "$BUILD_DIR/OpenFOAM-${VERSION}.tgz" -C "$BUILD_DIR"
    rm -f "$BUILD_DIR/OpenFOAM-${VERSION}.tgz"
fi

echo "=== Downloading ThirdParty ${VERSION} ==="
if [ ! -d "$BUILD_DIR/ThirdParty-${VERSION}" ]; then
    curl -L -o "$BUILD_DIR/ThirdParty-${VERSION}.tar.gz" \
        "https://sourceforge.net/projects/openfoam/files/${VERSION}/ThirdParty-${VERSION}.tar.gz"
    tar xzf "$BUILD_DIR/ThirdParty-${VERSION}.tar.gz" -C "$BUILD_DIR"
    rm -f "$BUILD_DIR/ThirdParty-${VERSION}.tar.gz"
fi

# ---------------------------------------------------------------------------
# Source OpenFOAM environment
# ---------------------------------------------------------------------------
echo "=== Sourcing OpenFOAM environment ==="
set +euo pipefail
source "$BUILD_DIR/OpenFOAM-${VERSION}/etc/bashrc" || true
set -euo pipefail

# ---------------------------------------------------------------------------
# Compiler flags — tuned for the detected CPU
# ---------------------------------------------------------------------------
echo "=== Setting compiler flags for ${DESC} ==="
OPT_FLAGS="-O2 -mcpu=${MCPU} -mtune=${MCPU}"
export WM_CFLAGS="$OPT_FLAGS"
export WM_CXXFLAGS="$OPT_FLAGS"
export WM_LDFLAGS="$OPT_FLAGS"
export CFLAGS="$OPT_FLAGS"
export CXXFLAGS="$OPT_FLAGS"
export FFLAGS="$OPT_FLAGS"
echo "  Flags: $OPT_FLAGS"

# ---------------------------------------------------------------------------
# Compile ThirdParty
# ---------------------------------------------------------------------------
echo "=== Compiling ThirdParty (${COMPILE_CORES} cores) ==="
cd "$BUILD_DIR/ThirdParty-${VERSION}"
./Allwmake -j ${COMPILE_CORES}

# ---------------------------------------------------------------------------
# Compile OpenFOAM
# ---------------------------------------------------------------------------
echo "=== Compiling OpenFOAM (${COMPILE_CORES} cores) ==="
cd "$BUILD_DIR/OpenFOAM-${VERSION}"
./Allwmake -j ${COMPILE_CORES}

# ---------------------------------------------------------------------------
# Move to final install location
# ---------------------------------------------------------------------------
echo "=== Installing to ${INSTALL_DIR} ==="
rm -rf "$INSTALL_DIR"
mv "$BUILD_DIR/OpenFOAM-${VERSION}" "$INSTALL_DIR"
mv "$BUILD_DIR/ThirdParty-${VERSION}" "$(dirname "$INSTALL_DIR")/ThirdParty-${VERSION}"

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
echo "=== Verifying installation ==="
SIMPLEFOAM="$INSTALL_DIR/platforms/linuxARM64GccDPInt32Opt/bin/simpleFoam"
if [ -x "$SIMPLEFOAM" ]; then
    echo "SUCCESS: simpleFoam found at $SIMPLEFOAM"
    file "$SIMPLEFOAM"
else
    echo "ERROR: simpleFoam not found"
    find "$INSTALL_DIR/platforms" -name "simpleFoam" -type f 2>/dev/null
    exit 1
fi

# ---------------------------------------------------------------------------
# Create environment script
# ---------------------------------------------------------------------------
echo "=== Creating environment script ==="
ENV_SCRIPT="/fsx/openfoam/aarch64-${ARCH_TAG}/openfoam-${VERSION}-env.sh"
cat > "$ENV_SCRIPT" << ENVSCRIPT
#!/bin/bash
# Source this to set up OpenFOAM ${VERSION} environment
# Built with GCC 14, optimized for ${DESC}
if [ -d /opt/amazon/openmpi/bin ]; then
    export PATH="/opt/amazon/openmpi/bin:\$PATH"
    export LD_LIBRARY_PATH="/opt/amazon/openmpi/lib:\${LD_LIBRARY_PATH:-}"
    export MPI_HOME="/opt/amazon/openmpi"
fi
source "${INSTALL_DIR}/etc/bashrc" || true
ENVSCRIPT
chmod +x "$ENV_SCRIPT"

# ---------------------------------------------------------------------------
# Cleanup build artifacts
# ---------------------------------------------------------------------------
echo "=== Cleaning up .o files and lnInclude ==="
find "$INSTALL_DIR" -name '*.o' -type f -delete
find "$INSTALL_DIR" -name 'lnInclude' -type d -exec rm -rf {} + 2>/dev/null || true
find "$(dirname "$INSTALL_DIR")/ThirdParty-${VERSION}" -name '*.o' -type f -delete 2>/dev/null || true

echo ""
echo "=== ${TARGET} build complete at $(date) ==="
echo "Install dir:  $INSTALL_DIR"
echo "Env script:   $ENV_SCRIPT"
