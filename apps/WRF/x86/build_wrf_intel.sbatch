#!/bin/bash
# Build WRF from source with GCC + Intel MPI on AWS HPC instances
# Requires dependencies built by build_wrf_dependencies_intel.sh

#SBATCH --job-name=build-wrf-intel
#SBATCH -p hpc8a
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=48
#SBATCH --time=03:00:00
#SBATCH --exclusive

set -euo pipefail

WRF_VERSION="${WRF_VERSION:-4.6.1}"
PREFIX="${PREFIX:-/fsx/wrf/deps}"
INSTALL_DIR="/fsx/wrf/intel/${WRF_VERSION}"
BUILD_DIR="/fsx/tmp/wrf-build-intel"
COMPILE_CORES=48

echo "=== WRF ${WRF_VERSION} GCC+IntelMPI build started at $(date) ==="
echo "Host: $(hostname)"

# ---------------------------------------------------------------------------
# Build dependencies if not already present
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEP_SCRIPT="${SCRIPT_DIR}/build_wrf_dependencies_intel.sh"
# Fallback to /fsx/wrf if running from Slurm spool
[ -f "$DEP_SCRIPT" ] || DEP_SCRIPT="/fsx/wrf/build_wrf_dependencies_intel.sh"

if [ ! -d "${PREFIX}/hdf5" ] || [ ! -d "${PREFIX}/netcdf-c" ]; then
    echo "=== Building WRF dependencies ==="
    if [ -f "$DEP_SCRIPT" ]; then
        bash "$DEP_SCRIPT" "$PREFIX"
    else
        echo "ERROR: Dependency script not found at $DEP_SCRIPT"
        echo "Please run build_wrf_dependencies_intel.sh first"
        exit 1
    fi
else
    echo "=== Dependencies already present at ${PREFIX} ==="
fi

# ---------------------------------------------------------------------------
# Load Intel MPI and dependencies
# ---------------------------------------------------------------------------
echo "=== Loading environment ==="
source /opt/intel/mpi/latest/env/vars.sh 2>/dev/null || true

module use ${PREFIX}/modulefiles
module load cmake
module load zlib-ng
module load libaec
module load hdf5
module load pnetcdf
module load netcdf-c
module load netcdf-fortran

# GCC + Intel MPI wrappers
export CC=mpigcc
export FC=mpifc
export CXX=mpigxx
export I_MPI_CC=gcc
export I_MPI_FC=gfortran
export I_MPI_CXX=g++

echo "CC=$CC, FC=$FC, CXX=$CXX"
echo "HDF5_DIR=$HDF5_DIR"
echo "NETCDF_C_DIR=$NETCDF_C_DIR"
echo "NETCDF_FORTRAN_DIR=$NETCDF_FORTRAN_DIR"

# WRF expects NETCDF as a single path — create a combined directory
NETCDF_COMBINED="${BUILD_DIR}/netcdf-combined"
mkdir -p "$NETCDF_COMBINED"/{include,lib,bin}
ln -sf "$NETCDF_C_DIR"/include/* "$NETCDF_COMBINED"/include/ 2>/dev/null || true
ln -sf "$NETCDF_C_DIR"/lib/* "$NETCDF_COMBINED"/lib/ 2>/dev/null || true
ln -sf "$NETCDF_C_DIR"/bin/* "$NETCDF_COMBINED"/bin/ 2>/dev/null || true
ln -sf "$NETCDF_FORTRAN_DIR"/include/* "$NETCDF_COMBINED"/include/ 2>/dev/null || true
ln -sf "$NETCDF_FORTRAN_DIR"/lib/* "$NETCDF_COMBINED"/lib/ 2>/dev/null || true
ln -sf "$NETCDF_FORTRAN_DIR"/bin/* "$NETCDF_COMBINED"/bin/ 2>/dev/null || true

export NETCDF="$NETCDF_COMBINED"
export PNETCDF="$PNETCDF_DIR"
export HDF5="$HDF5_DIR"
export PHDF5="$HDF5_DIR"
export WRFIO_NCD_LARGE_FILE_SUPPORT=1

# ---------------------------------------------------------------------------
# Download WRF source
# ---------------------------------------------------------------------------
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

if [ ! -d "$BUILD_DIR/WRFV${WRF_VERSION}" ]; then
    echo "=== Downloading WRF ${WRF_VERSION} ==="
    curl -L -o WRF-${WRF_VERSION}.tar.gz \
        "https://github.com/wrf-model/WRF/releases/download/v${WRF_VERSION}/v${WRF_VERSION}.tar.gz"
    tar xzf WRF-${WRF_VERSION}.tar.gz
    rm -f WRF-${WRF_VERSION}.tar.gz
fi

cd "$BUILD_DIR/WRFV${WRF_VERSION}"

# ---------------------------------------------------------------------------
# Configure WRF
# ---------------------------------------------------------------------------
echo "=== Configuring WRF ==="
# Option 34 = GNU (gfortran/gcc) dmpar (distributed memory parallel)
# Intel MPI provides the MPI layer via mpigcc/mpifc wrappers
export WRF_EM_CORE=1
export WRF_NMM_CORE=0
export WRF_DA_CORE=0

# Clean any previous configure
./clean -a 2>/dev/null || true

# Auto-select GNU dmpar option (34) with basic nesting (1)
printf '34\n1\n' | ./configure 2>&1 | tee log.configure

# Patch configure.wrf to use Intel MPI wrappers instead of generic mpicc/mpif90
sed -i 's/^DM_FC.*=.*/DM_FC           =       mpifc/' configure.wrf
sed -i 's/^DM_CC.*=.*/DM_CC           =       mpigcc/' configure.wrf

# ---------------------------------------------------------------------------
# Compile WRF
# ---------------------------------------------------------------------------
echo "=== Compiling WRF (${COMPILE_CORES} cores) ==="
./compile -j ${COMPILE_CORES} em_real 2>&1 | tee log.compile

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
echo "=== Verifying installation ==="
WRF_EXE="$BUILD_DIR/WRFV${WRF_VERSION}/main/wrf.exe"
if [ -x "$WRF_EXE" ]; then
    echo "SUCCESS: wrf.exe found at $WRF_EXE"
    file "$WRF_EXE"
else
    echo "ERROR: wrf.exe not found"
    ls main/*.exe 2>/dev/null || echo "No executables in main/"
    exit 1
fi

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
echo "=== Installing to ${INSTALL_DIR} ==="
mkdir -p "$INSTALL_DIR"
cp -r "$BUILD_DIR/WRFV${WRF_VERSION}" "$INSTALL_DIR/WRF"

# ---------------------------------------------------------------------------
# Download CONUS 12km benchmark data
# ---------------------------------------------------------------------------
CONUS_DIR="/fsx/wrf/conus_12km"
if [ ! -f "$CONUS_DIR/wrfinput_d01" ]; then
    echo "=== Downloading CONUS 12km benchmark data ==="
    mkdir -p "$CONUS_DIR"
    cd "$CONUS_DIR"
    curl -OL https://aws-hpc-weather.s3.us-east-2.amazonaws.com/wrf_simulation_CONUS12km.tar.gz
    tar -xzf wrf_simulation_CONUS12km.tar.gz
    # Tarball extracts into a conus_12km subdirectory — flatten it
    if [ -d "$CONUS_DIR/conus_12km" ]; then
        mv "$CONUS_DIR/conus_12km"/* "$CONUS_DIR"/ 2>/dev/null || true
        rmdir "$CONUS_DIR/conus_12km" 2>/dev/null || true
    fi
    rm -f wrf_simulation_CONUS12km.tar.gz
    # Link WRF run files (don't overwrite namelist.input)
    ln -sf "$INSTALL_DIR/WRF/test/em_real"/* . 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Create environment script
# ---------------------------------------------------------------------------
echo "=== Creating environment script ==="
cat > /fsx/wrf/wrf-${WRF_VERSION}-intel-env.sh << 'ENVEOF'
#!/bin/bash
# Source this to set up WRF WRFVER (GCC + Intel MPI) environment
source /opt/intel/mpi/latest/env/vars.sh 2>/dev/null || true
module use DEPPREFIX/modulefiles
module load cmake zlib-ng libaec hdf5 pnetcdf netcdf-c netcdf-fortran
export CC=mpigcc FC=mpifc CXX=mpigxx
export I_MPI_CC=gcc I_MPI_FC=gfortran I_MPI_CXX=g++
export NETCDF="INSTALLPATH/WRF/external/io_netcdf"
export WRF_DIR="INSTALLPATH/WRF"
export PATH="$WRF_DIR/main:$PATH"
ENVEOF
# Substitute placeholders
sed -i "s|WRFVER|${WRF_VERSION}|g" /fsx/wrf/wrf-${WRF_VERSION}-intel-env.sh
sed -i "s|DEPPREFIX|${PREFIX}|g" /fsx/wrf/wrf-${WRF_VERSION}-intel-env.sh
sed -i "s|INSTALLPATH|${INSTALL_DIR}|g" /fsx/wrf/wrf-${WRF_VERSION}-intel-env.sh
chmod +x /fsx/wrf/wrf-${WRF_VERSION}-intel-env.sh

echo ""
echo "=== Build complete at $(date) ==="
echo "WRF dir:    $INSTALL_DIR/WRF"
echo "Env script: /fsx/wrf/wrf-${WRF_VERSION}-intel-env.sh"
