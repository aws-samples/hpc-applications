#!/bin/bash
# Build OpenFOAM v2512 (openfoam.com) from source with Intel MPI
# Optimized for hpc8a.96xlarge (AMD EPYC 5th Gen / Zen 5 / Turin) with GCC 14 + AVX-512

#SBATCH --job-name=build-of-v2512-impi
#SBATCH -p hpc8a
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=192
#SBATCH --time=05:00:00
#SBATCH --output=/fsx/openfoam/logs/build_v2512_intelmpi_%j.out
#SBATCH --error=/fsx/openfoam/logs/build_v2512_intelmpi_%j.err
#SBATCH --exclusive

set -euo pipefail

VERSION="v2512"
BUILD_DIR="/fsx/tmp/openfoam-build-intelmpi"
INSTALL_DIR="/fsx/openfoam/x86_64-intelmpi/${VERSION}"
COMPILE_CORES=48

LOG_FILE="/fsx/openfoam/logs/build_v2512_intelmpi_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

cleanup_on_failure() {
    echo "ERROR: Build failed. Logs at: $LOG_FILE"
    echo "Build dir preserved at: $BUILD_DIR/"
    exit 1
}
trap cleanup_on_failure ERR

echo "=== OpenFOAM ${VERSION} Intel MPI build started at $(date) ==="
echo "Host: $(hostname)"
echo "Job ID: ${SLURM_JOB_ID:-N/A}"

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
GCC14_BIN="/fsx/tmp/gcc14-bin"
mkdir -p "$GCC14_BIN"
ln -sf /usr/bin/gcc14-gcc "$GCC14_BIN/gcc"
ln -sf /usr/bin/gcc14-g++ "$GCC14_BIN/g++"
ln -sf /usr/bin/gcc14-gfortran "$GCC14_BIN/gfortran"
export PATH="$GCC14_BIN:$PATH"

echo "Compiler: $(gcc --version | head -1)"

# ---------------------------------------------------------------------------
# MPI — use Intel MPI (must be in PATH before OpenMPI)
# ---------------------------------------------------------------------------
echo "=== Setting up Intel MPI ==="
module load intelmpi 2>/dev/null || true
module load libfabric-aws 2>/dev/null || true
export I_MPI_OFI_LIBRARY_INTERNAL=0
export I_MPI_OFI_PROVIDER=efa
export MPI_ROOT="$I_MPI_ROOT"
export MPI_ARCH_PATH="$I_MPI_ROOT"
# Ensure Intel MPI mpicc is found before OpenMPI
export PATH="$I_MPI_ROOT/bin:$PATH"
echo "MPI: Intel MPI at $I_MPI_ROOT"
echo "mpicc: $(which mpicc)"
echo "mpicc version: $(mpicc --version 2>&1 | head -1)"

# ---------------------------------------------------------------------------
# Download and extract sources (clean slate)
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
# Source OpenFOAM environment with Intel MPI
# ---------------------------------------------------------------------------
echo "=== Sourcing OpenFOAM environment (Intel MPI) ==="

# OpenFOAM's bashrc hardcodes WM_MPLIB=SYSTEMOPENMPI on line 108.
# Patch it to use INTELMPI before sourcing.
sed -i 's/^export WM_MPLIB=SYSTEMOPENMPI/export WM_MPLIB=INTELMPI/' \
    "$BUILD_DIR/OpenFOAM-${VERSION}/etc/bashrc"

set +euo pipefail
export I_MPI_ROOT
source "$BUILD_DIR/OpenFOAM-${VERSION}/etc/bashrc" || true
set -euo pipefail

echo "  WM_MPLIB: ${WM_MPLIB:-NOT SET}"
echo "  FOAM_MPI: ${FOAM_MPI:-NOT SET}"
echo "  MPI_ARCH_PATH: ${MPI_ARCH_PATH:-NOT SET}"
echo "  MPI_ARCH_PATH: ${MPI_ARCH_PATH:-NOT SET}"

# ---------------------------------------------------------------------------
# Compiler flags — optimize for hpc8a (Zen 5 / AVX-512)
# ---------------------------------------------------------------------------
echo "=== Setting compiler flags for hpc8a (Zen 5 / AVX-512) ==="
OPT_FLAGS="-O2 -march=x86-64-v4 -mtune=znver5"
export WM_CFLAGS="$OPT_FLAGS"
export WM_CXXFLAGS="$OPT_FLAGS"
export WM_LDFLAGS="$OPT_FLAGS"
export CFLAGS="$OPT_FLAGS"
export CXXFLAGS="$OPT_FLAGS"
export FFLAGS="$OPT_FLAGS"
echo "  Flags: $OPT_FLAGS"
echo "  WM_MPLIB: $WM_MPLIB"

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
SIMPLEFOAM="$INSTALL_DIR/platforms/linux64GccDPInt32Opt/bin/simpleFoam"
if [ -x "$SIMPLEFOAM" ]; then
    echo "SUCCESS: simpleFoam found at $SIMPLEFOAM"
    file "$SIMPLEFOAM"
    ldd "$SIMPLEFOAM" | grep -i mpi
else
    echo "ERROR: simpleFoam not found"
    find "$INSTALL_DIR/platforms" -name "simpleFoam" -type f 2>/dev/null
    exit 1
fi

# ---------------------------------------------------------------------------
# Create environment script
# ---------------------------------------------------------------------------
echo "=== Creating environment script ==="
cat > /fsx/openfoam/x86_64-intelmpi/openfoam-${VERSION}-env.sh << 'ENVSCRIPT'
#!/bin/bash
# Source this to set up OpenFOAM v2512 environment (Intel MPI build)
# Built with GCC 14, optimized for hpc8a (Zen 5 / AVX-512)
module load intelmpi 2>/dev/null || true
module load libfabric-aws 2>/dev/null || true
export I_MPI_OFI_LIBRARY_INTERNAL=0
export I_MPI_OFI_PROVIDER=efa
export WM_MPLIB=INTELMPI
source "/fsx/openfoam/x86_64-intelmpi/v2512/etc/bashrc" || true
ENVSCRIPT
chmod +x /fsx/openfoam/x86_64-intelmpi/openfoam-${VERSION}-env.sh

# ---------------------------------------------------------------------------
# Cleanup build artifacts
# ---------------------------------------------------------------------------
echo "=== Cleaning up .o files and lnInclude ==="
find "$INSTALL_DIR" -name '*.o' -type f -delete
find "$INSTALL_DIR" -name 'lnInclude' -type d -exec rm -rf {} + 2>/dev/null || true
find "$(dirname "$INSTALL_DIR")/ThirdParty-${VERSION}" -name '*.o' -type f -delete 2>/dev/null || true

echo ""
echo "=== Intel MPI build complete at $(date) ==="
echo "Install dir:  $INSTALL_DIR"
echo "Env script:   /fsx/openfoam/x86_64-intelmpi/openfoam-${VERSION}-env.sh"
