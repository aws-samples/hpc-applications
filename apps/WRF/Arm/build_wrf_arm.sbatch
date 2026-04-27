#!/bin/bash
# Build WRF using Spack (GCC + OpenMPI) on AWS Graviton
# Single script for Graviton3E (hpc7g / Neoverse V1) and Graviton4 (m8g, r8g / Neoverse V2).
# Target is auto-detected from /proc/cpuinfo at runtime.
#
# Knobs:
#   TARGET=graviton3|graviton4   # auto-detected from /proc/cpuinfo if not set
#   OMPI_VERSION=4|5             # default 4; 5 uses the ParallelCluster openmpi5 module
#
# Examples:
#   # Graviton3E (hpc7g.16xlarge, 64 cores) with OpenMPI 4
#   sbatch -p hpc7g --ntasks-per-node=64 build_wrf_arm.sbatch
#
#   # Graviton4 (m8g.48xlarge, 192 cores) with OpenMPI 5
#   sbatch -p m8g --ntasks-per-node=192 --export=ALL,OMPI_VERSION=5 build_wrf_arm.sbatch

#SBATCH --job-name=build-wrf-arm
#SBATCH --nodes=1
#SBATCH --time=04:00:00
#SBATCH --output=/fsx/wrf/logs/build_wrf_arm_%j.out
#SBATCH --error=/fsx/wrf/logs/build_wrf_arm_%j.err
#SBATCH --exclusive

set -euo pipefail

WRF_VERSION="${WRF_VERSION:-4.6.1}"
OMPI_VERSION="${OMPI_VERSION:-4}"   # 4 → /opt/amazon/openmpi (4.1.7), 5 → /opt/amazon/openmpi5 (5.0.9)

case "$OMPI_VERSION" in
    4) OMPI_SPEC="openmpi@4.1.7"; OMPI_PREFIX="/opt/amazon/openmpi";  OMPI_TAG=""     ;;
    5) OMPI_SPEC="openmpi@5.0.9"; OMPI_PREFIX="/opt/amazon/openmpi5"; OMPI_TAG="-ompi5" ;;
    *) echo "ERROR: OMPI_VERSION must be 4 or 5 (got: $OMPI_VERSION)"; exit 1 ;;
esac

mkdir -p /fsx/wrf/logs

# ---------------------------------------------------------------------------
# Auto-detect Graviton generation
#   Graviton3/3E → Neoverse V1 (CPU part 0xd40) → target=neoverse_v1
#   Graviton4    → Neoverse V2 (CPU part 0xd4f) → target=neoverse_v2
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
        SPACK_TARGET="neoverse_v1"
        DESC="Graviton3E / Neoverse V1 (hpc7g)"
        ;;
    graviton4)
        ARCH_TAG="graviton4"
        SPACK_TARGET="neoverse_v2"
        DESC="Graviton4 / Neoverse V2 (m8g / r8g)"
        ;;
    *)
        echo "ERROR: TARGET must be graviton3 or graviton4 (got: $TARGET)"; exit 1 ;;
esac

# Per-arch Spack root to avoid lock contention between G3 and G4 concurrent builds
SPACK_ROOT="${SPACK_ROOT:-/fsx/spack-${ARCH_TAG}}"
# Node-local per-user Spack cache (avoids EFS lock thrash)
export SPACK_USER_CACHE_PATH="/tmp/spack-cache-${USER}-${SLURM_JOB_ID}"
mkdir -p "$SPACK_USER_CACHE_PATH"

echo "=== WRF ${WRF_VERSION} build for ${DESC} at $(date) ==="
echo "Host:          $(hostname)"
echo "Target:        ${TARGET} (spack target=${SPACK_TARGET})"
echo "OpenMPI:       ${OMPI_SPEC} from ${OMPI_PREFIX}"
echo "Spack root:    ${SPACK_ROOT}"

# ---------------------------------------------------------------------------
# Setup Spack (dedicated aarch64 instance; avoids x86 compiler contamination)
# ---------------------------------------------------------------------------
if [ ! -d "$SPACK_ROOT" ]; then
    echo "=== Installing Spack at $SPACK_ROOT ==="
    git clone -c feature.manyFiles=true --depth=1 https://github.com/spack/spack.git "$SPACK_ROOT"
fi

# Start with a clean per-user cache so Spack re-detects compilers for this arch
rm -rf ~/.spack/linux ~/.spack/cache

set +euo pipefail
source "$SPACK_ROOT/share/spack/setup-env.sh"
set -euo pipefail

# System dependencies used by Spack packages
sudo dnf install -y libtirpc-devel 2>/dev/null || true

# Detect compilers
spack compiler find

# ---------------------------------------------------------------------------
# Per-arch packages.yaml — pins the right OpenMPI as external and keeps
# krb5 / libtirpc as system externals so Spack doesn't rebuild them.
#
# Written to the per-arch Spack root (not $HOME/.spack) because the shared
# NFS $HOME is a source of stale-file-handle races when two builds (G3 + G4)
# run concurrently, and $HOME-scoped config also leaks OMPI4 externals into
# OMPI5 builds. The per-arch path isolates them cleanly.
#
# `spack config --scope site` writes to $SPACK_ROOT/etc/spack/packages.yaml,
# which is picked up ahead of $HOME/.spack/packages.yaml for this Spack tree.
# ---------------------------------------------------------------------------
SITE_PACKAGES="${SPACK_ROOT}/etc/spack/packages.yaml"
mkdir -p "$(dirname "$SITE_PACKAGES")"
# Remove any stale $HOME scope to avoid mixing OMPI4/OMPI5 externals across builds.
rm -f "$HOME/.spack/packages.yaml"
cat > "$SITE_PACKAGES" << SPACKEOF
packages:
  openmpi:
    externals:
    - spec: ${OMPI_SPEC}+atomics~cuda~cxx~cxx_exceptions~java~memchecker+pmi~rocm~static~wrapper-rpath fabrics=ofi schedulers=slurm
      prefix: ${OMPI_PREFIX}
    buildable: false
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
echo "=== Site packages.yaml (external OpenMPI ${OMPI_VERSION}) ==="
cat "$SITE_PACKAGES"

# ---------------------------------------------------------------------------
# Install WRF (GCC + external OpenMPI, tuned for the detected Graviton)
# ---------------------------------------------------------------------------
NCORES=$(nproc)
echo "=== Installing WRF ${WRF_VERSION} with GCC + ${OMPI_SPEC} (${DESC}) ==="
# Use the system OpenMPI from /opt/amazon as the MPI layer (EFA-enabled).
# Spack would otherwise build a vanilla OpenMPI without the OFI fabric
# support, which cannot use EFA at runtime.
spack install -j ${NCORES} wrf@${WRF_VERSION} build_type=dm+sm %gcc ^${OMPI_SPEC}

echo ""
echo "=== WRF installation complete ==="
spack find -p wrf
# Resolve the install path by filtering to the WRF that depends on the MPI we
# just used. Multiple WRF installs can coexist in the same Spack root if we
# have already built against OMPI4 and are now adding OMPI5.
WRF_DIR=$(spack location -i "wrf@${WRF_VERSION}%gcc ^${OMPI_SPEC}")
echo "WRF dir: $WRF_DIR"

# ---------------------------------------------------------------------------
# Download CONUS 12km benchmark data (shared across Arm / x86, OMPI4/OMPI5)
# ---------------------------------------------------------------------------
CONUS_DIR="/fsx/wrf/conus_12km"
if [ ! -f "$CONUS_DIR/wrfinput_d01" ]; then
    echo "=== Downloading CONUS 12km benchmark data ==="
    mkdir -p "$CONUS_DIR" && cd "$CONUS_DIR"
    curl -OL https://aws-hpc-weather.s3.us-east-2.amazonaws.com/wrf_simulation_CONUS12km.tar.gz
    tar -xzf wrf_simulation_CONUS12km.tar.gz
    if [ -d "$CONUS_DIR/conus_12km" ]; then
        mv "$CONUS_DIR/conus_12km"/* "$CONUS_DIR"/ 2>/dev/null || true
        rmdir "$CONUS_DIR/conus_12km" 2>/dev/null || true
    fi
    rm -f wrf_simulation_CONUS12km.tar.gz
    ln -sf "$WRF_DIR"/test/em_real/* . 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Create environment script
#   OMPI4 → /fsx/wrf/aarch64-${ARCH_TAG}/wrf-${WRF_VERSION}-env.sh
#   OMPI5 → /fsx/wrf/aarch64-${ARCH_TAG}-ompi5/wrf-${WRF_VERSION}-ompi5-env.sh
# ---------------------------------------------------------------------------
ENV_DIR="/fsx/wrf/aarch64-${ARCH_TAG}${OMPI_TAG}"
if [ "$OMPI_VERSION" = "5" ]; then
    ENV_SCRIPT="${ENV_DIR}/wrf-${WRF_VERSION}-ompi5-env.sh"
else
    ENV_SCRIPT="${ENV_DIR}/wrf-${WRF_VERSION}-env.sh"
fi
mkdir -p "$ENV_DIR"
cat > "$ENV_SCRIPT" << ENVEOF
#!/bin/bash
# Source this to set up WRF ${WRF_VERSION} environment
# Built with GCC + ${OMPI_SPEC} via Spack (${DESC})
source ${SPACK_ROOT}/share/spack/setup-env.sh
spack load "wrf@${WRF_VERSION}%gcc ^${OMPI_SPEC}"
export WRF_DIR=\$(spack location -i "wrf@${WRF_VERSION}%gcc ^${OMPI_SPEC}")
# Force external OpenMPI (${OMPI_PREFIX}) to the front of PATH / LD_LIBRARY_PATH
# so it shadows anything that Spack's `spack load` added.
if [ -d ${OMPI_PREFIX}/bin ]; then
    export PATH="${OMPI_PREFIX}/bin:\$PATH"
    export LD_LIBRARY_PATH="${OMPI_PREFIX}/lib64:\${LD_LIBRARY_PATH:-}"
fi
ENVEOF
chmod +x "$ENV_SCRIPT"

echo ""
echo "=== ${TARGET} / OMPI${OMPI_VERSION} build complete at $(date) ==="
echo "WRF dir:    $WRF_DIR"
echo "Env script: $ENV_SCRIPT"
