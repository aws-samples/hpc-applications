#!/bin/bash
# Build WRF using Spack on AWS HPC instances
# Based on: https://catalog.workshops.aws/nwp-on-aws/en-US/2-wrf

#SBATCH --job-name=build-wrf
#SBATCH -p hpc8a
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=48
#SBATCH --time=03:00:00
#SBATCH --exclusive

set -euo pipefail

WRF_VERSION="${WRF_VERSION:-4.6.1}"
SPACK_ROOT="${SPACK_ROOT:-/fsx/spack}"

echo "=== WRF ${WRF_VERSION} build started at $(date) ==="
echo "Host: $(hostname)"

# ---------------------------------------------------------------------------
# Setup Spack
# ---------------------------------------------------------------------------
if [ ! -d "$SPACK_ROOT" ]; then
    echo "=== Installing Spack ==="
    git clone -c feature.manyFiles=true --depth=1 https://github.com/spack/spack.git "$SPACK_ROOT"
fi

source "$SPACK_ROOT/share/spack/setup-env.sh"

# Install system dependencies needed by Spack packages
sudo dnf install -y libtirpc-devel 2>/dev/null || true

# Detect compilers and external packages
spack compiler find
spack external find openmpi

# Use system krb5 and libtirpc to avoid build issues with OpenSSL
if ! grep -q "krb5:" "$SPACK_ROOT/etc/spack/packages.yaml" 2>/dev/null; then
    cat >> "$SPACK_ROOT/etc/spack/packages.yaml" << 'SPACKEOF'
  krb5:
    externals:
    - spec: krb5@1.21.3
      prefix: /usr
    buildable: false
  libtirpc:
    externals:
    - spec: libtirpc@1.3.3
      prefix: /usr
    buildable: false
SPACKEOF
fi

# ---------------------------------------------------------------------------
# Install WRF with OpenMPI (GCC)
# ---------------------------------------------------------------------------
echo "=== Installing WRF ${WRF_VERSION} (OpenMPI + GCC) ==="
spack install -j 48 wrf@${WRF_VERSION} build_type=dm+sm %gcc ^openmpi

echo ""
echo "=== WRF installation complete ==="
spack find -p wrf
WRF_DIR=$(spack location -i wrf@${WRF_VERSION}%gcc)

# ---------------------------------------------------------------------------
# Download CONUS 12km benchmark data
# ---------------------------------------------------------------------------
echo "=== Downloading CONUS 12km benchmark data ==="
CONUS_DIR="/fsx/wrf/conus_12km"
if [ ! -f "$CONUS_DIR/wrfinput_d01" ]; then
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
    # Link WRF run files (but don't overwrite namelist.input)
    ln -sf "$WRF_DIR"/test/em_real/* . 2>/dev/null || true
    echo "CONUS 12km data ready at $CONUS_DIR"
else
    echo "CONUS 12km data already present at $CONUS_DIR"
fi

# ---------------------------------------------------------------------------
# Create environment script
# ---------------------------------------------------------------------------
echo "=== Creating environment script ==="
mkdir -p /fsx/wrf
cat > /fsx/wrf/wrf-${WRF_VERSION}-env.sh << ENVEOF
#!/bin/bash
# Source this to set up WRF ${WRF_VERSION} environment
source ${SPACK_ROOT}/share/spack/setup-env.sh
spack load wrf@${WRF_VERSION}%gcc
export WRF_DIR=\$(spack location -i wrf@${WRF_VERSION}%gcc)
if [ -d /opt/amazon/openmpi/bin ]; then
    export PATH="/opt/amazon/openmpi/bin:\$PATH"
    export LD_LIBRARY_PATH="/opt/amazon/openmpi/lib:\${LD_LIBRARY_PATH:-}"
fi
ENVEOF
chmod +x /fsx/wrf/wrf-${WRF_VERSION}-env.sh

echo ""
echo "=== Build complete at $(date) ==="
echo "WRF dir:    $WRF_DIR"
echo "CONUS data: $CONUS_DIR"
echo "Env script: /fsx/wrf/wrf-${WRF_VERSION}-env.sh"
