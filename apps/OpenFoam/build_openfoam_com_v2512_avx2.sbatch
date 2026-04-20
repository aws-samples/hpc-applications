#!/bin/bash
# Build OpenFOAM v2512 (openfoam.com) — AVX2 build (no AVX-512)
# For comparison benchmarking against the AVX-512 build

#SBATCH --job-name=build-of-avx2
#SBATCH -p hpc8a
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=192
#SBATCH --time=05:00:00
#SBATCH --output=/fsx/openfoam/logs/build_v2512_avx2_%j.out
#SBATCH --error=/fsx/openfoam/logs/build_v2512_avx2_%j.err
#SBATCH --exclusive

set -euo pipefail

VERSION="v2512"
BUILD_DIR="/fsx/tmp/openfoam-build-avx2"
INSTALL_DIR="/fsx/openfoam/x86_64-avx2/${VERSION}"
COMPILE_CORES=48

LOG_FILE="/fsx/openfoam/logs/build_v2512_avx2_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

trap 'echo "ERROR: Build failed. Logs at: $LOG_FILE"; exit 1' ERR

echo "=== OpenFOAM ${VERSION} AVX2 build started at $(date) ==="
echo "Host: $(hostname)"
echo "Job ID: ${SLURM_JOB_ID:-N/A}"

mkdir -p /fsx/openfoam/logs "$BUILD_DIR" "$(dirname "$INSTALL_DIR")"

# Install build dependencies
echo "=== Installing build dependencies ==="
sudo dnf install -y gcc gcc-c++ gcc-gfortran \
    make cmake git ca-certificates flex zlib-devel boost-devel fftw-devel \
    readline-devel ncurses-devel libcurl-devel

echo "Compiler: $(gcc --version | head -1)"

if [ -d /opt/amazon/openmpi/bin ]; then
    export PATH="/opt/amazon/openmpi/bin:$PATH"
    export LD_LIBRARY_PATH="/opt/amazon/openmpi/lib:${LD_LIBRARY_PATH:-}"
    export MPI_HOME="/opt/amazon/openmpi"
fi

# Download sources
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

# Source environment
echo "=== Sourcing OpenFOAM environment ==="
set +euo pipefail
source "$BUILD_DIR/OpenFOAM-${VERSION}/etc/bashrc" || true
set -euo pipefail

# AVX2 flags (x86-64-v3 = AVX2 + FMA + BMI, no AVX-512)
echo "=== Setting compiler flags: AVX2 (x86-64-v3, no AVX-512) ==="
OPT_FLAGS="-O2 -march=x86-64-v3 -mtune=generic"
export WM_CFLAGS="$OPT_FLAGS"
export WM_CXXFLAGS="$OPT_FLAGS"
export WM_LDFLAGS="$OPT_FLAGS"
export CFLAGS="$OPT_FLAGS"
export CXXFLAGS="$OPT_FLAGS"
export FFLAGS="$OPT_FLAGS"
echo "  Flags: $OPT_FLAGS"

# Compile
echo "=== Compiling ThirdParty (${COMPILE_CORES} cores) ==="
cd "$BUILD_DIR/ThirdParty-${VERSION}"
./Allwmake -j ${COMPILE_CORES}

echo "=== Compiling OpenFOAM (${COMPILE_CORES} cores) ==="
cd "$BUILD_DIR/OpenFOAM-${VERSION}"
./Allwmake -j ${COMPILE_CORES}

# Install
echo "=== Installing to ${INSTALL_DIR} ==="
rm -rf "$INSTALL_DIR"
mv "$BUILD_DIR/OpenFOAM-${VERSION}" "$INSTALL_DIR"
mv "$BUILD_DIR/ThirdParty-${VERSION}" "$(dirname "$INSTALL_DIR")/ThirdParty-${VERSION}"

# Verify
SIMPLEFOAM="$INSTALL_DIR/platforms/linux64GccDPInt32Opt/bin/simpleFoam"
if [ -x "$SIMPLEFOAM" ]; then
    echo "SUCCESS: simpleFoam found"
    file "$SIMPLEFOAM"
else
    echo "ERROR: simpleFoam not found"
    exit 1
fi

# Env script
cat > /fsx/openfoam/x86_64-avx2/openfoam-${VERSION}-env.sh << 'ENVSCRIPT'
#!/bin/bash
# OpenFOAM v2512 — AVX2 build (no AVX-512)
if [ -d /opt/amazon/openmpi/bin ]; then
    export PATH="/opt/amazon/openmpi/bin:$PATH"
    export LD_LIBRARY_PATH="/opt/amazon/openmpi/lib:${LD_LIBRARY_PATH:-}"
    export MPI_HOME="/opt/amazon/openmpi"
fi
source "/fsx/openfoam/x86_64-avx2/v2512/etc/bashrc" || true
ENVSCRIPT
chmod +x /fsx/openfoam/x86_64-avx2/openfoam-${VERSION}-env.sh

# Cleanup
find "$INSTALL_DIR" -name '*.o' -type f -delete
find "$INSTALL_DIR" -name 'lnInclude' -type d -exec rm -rf {} + 2>/dev/null || true
find "$(dirname "$INSTALL_DIR")/ThirdParty-${VERSION}" -name '*.o' -type f -delete 2>/dev/null || true

echo ""
echo "=== AVX2 build complete at $(date) ==="
echo "Install dir:  $INSTALL_DIR"
echo "Env script:   /fsx/openfoam/x86_64-avx2/openfoam-${VERSION}-env.sh"
