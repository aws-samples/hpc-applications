#!/bin/bash
#SBATCH --job-name=build-namd-x86
#SBATCH --constraint=hpc8a.96xlarge
#SBATCH --partition=hpc8a
#SBATCH --nodes=1
#SBATCH --exclusive
#SBATCH --output=build-namd-x86-%j.out
#
# Build NAMD 3.0.1 from source on x86 HPC instances (hpc8a / hpc7a).
#
# NAMD runs on the Charm++ parallel runtime. This script builds Charm++ twice
#   * ofi-linux-x86_64 ... smp   — multi-node, EFA via libfabric (OFI backend)
#   * multicore-linux-x86_64     — single-node, no network layer
# then configures and compiles NAMD against the OFI/SMP Charm++ with AVX-512
# tile-list kernels (--with-avxtiles), producing the `namd3` binary.
#
# NOTE: the NAMD source tarball is distributed behind a license click-through
# (https://www.ks.uiuc.edu/Research/namd/) and CANNOT be fetched
# non-interactively. Download NAMD_<version>_Source.tar.gz once, accepting the
# license, and stage it at ${BASE_DIR}/src/ before submitting this job. Set
# NAMD_SRC to override the path, or NAMD_SRC_URL to fetch from a private mirror.
#
# Override via --export=ALL,...:
#   NAMD_VERSION   NAMD release (default 3.0.1)
#   BASE_DIR       install root (default /fsx/namd)
#   TARGET_CPU     hpc8a | hpc7a (default hpc8a)
#   COMPILE_CORES  parallel build threads (default 48)
#   NAMD_SRC       staged source tarball (default ${BASE_DIR}/src/NAMD_${NAMD_VERSION}_Source.tar.gz)
#   NAMD_SRC_URL   optional URL to fetch the source tarball from a mirror

set -euo pipefail

NAMD_VERSION="${NAMD_VERSION:-3.0.1}"
BASE_DIR="${BASE_DIR:-/fsx/namd}"
TARGET_CPU="${TARGET_CPU:-hpc8a}"
COMPILE_CORES="${COMPILE_CORES:-48}"
NAMD_SRC="${NAMD_SRC:-${BASE_DIR}/src/NAMD_${NAMD_VERSION}_Source.tar.gz}"
NAMD_SRC_URL="${NAMD_SRC_URL:-}"

CHARM_NET="ofi-linux-x86_64"          # OFI (libfabric/EFA) backend, x86_64
NAMD_ARCH="Linux-x86_64-g++"
INSTALL_DIR="${BASE_DIR}/x86_64/${NAMD_VERSION}"
BUILD_DIR="${BASE_DIR}/build/x86_64-${NAMD_VERSION}-$$"
ENV_SCRIPT="${INSTALL_DIR}/namd-${NAMD_VERSION}-x86-env.sh"

log()  { echo "[$(date +%H:%M:%S)] $*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }
trap 'fail "build failed at line ${LINENO} (stage: ${STAGE:-unknown})"' ERR
STAGE="init"

log "NAMD ${NAMD_VERSION} x86 build — target=${TARGET_CPU} cores=${COMPILE_CORES}"
log "install dir: ${INSTALL_DIR}"

if [ -d "${INSTALL_DIR}/bin" ]; then
    fail "install directory already exists: ${INSTALL_DIR} (remove it to rebuild)"
fi

# --- Stage the (license-gated) source ------------------------------------
STAGE="source"
mkdir -p "${BASE_DIR}/src"
if [ ! -f "${NAMD_SRC}" ]; then
    if [ -n "${NAMD_SRC_URL}" ]; then
        log "fetching NAMD source from mirror ${NAMD_SRC_URL}"
        curl -fsSL --max-time 600 --retry 3 -o "${NAMD_SRC}" "${NAMD_SRC_URL}" \
            || fail "failed to download NAMD source from ${NAMD_SRC_URL}"
    else
        cat >&2 <<EOF
ERROR: NAMD source tarball not found at ${NAMD_SRC}

The NAMD source is distributed behind a license agreement and cannot be
downloaded non-interactively. Please:
  1. Visit https://www.ks.uiuc.edu/Research/namd/ and accept the license
  2. Download NAMD_${NAMD_VERSION}_Source.tar.gz
  3. Place it at ${NAMD_SRC}
     (or set NAMD_SRC / NAMD_SRC_URL), then resubmit this job.
EOF
        exit 1
    fi
fi

# --- Toolchain / dependencies (TCL + FFTW from the distro) ---------------
STAGE="deps"
log "installing build dependencies (gcc-c++, gfortran, fftw-devel, tcl-devel)"
sudo dnf install -y gcc gcc-c++ gcc-gfortran make tar gzip \
    fftw-devel tcl-devel >/dev/null 2>&1 \
    || fail "failed to install build dependencies via dnf"

# --- Extract source ------------------------------------------------------
STAGE="extract"
mkdir -p "${BUILD_DIR}"
log "extracting ${NAMD_SRC}"
tar xzf "${NAMD_SRC}" -C "${BUILD_DIR}" --strip-components=1 \
    || fail "failed to extract ${NAMD_SRC}"
cd "${BUILD_DIR}"
# The NAMD source ships the matching Charm++ as a tarball under the top dir.
CHARM_TARBALL=""
for t in charm-*.tar; do [ -f "$t" ] && CHARM_TARBALL="$t" && break; done
[ -n "${CHARM_TARBALL}" ] && tar xf "${CHARM_TARBALL}"
CHARM_DIR=""
for d in charm-v* charm-[0-9]*; do [ -d "$d" ] && CHARM_DIR="$d" && break; done
[ -n "${CHARM_DIR}" ] || fail "could not locate the bundled Charm++ directory"

# --- Host optimisation flags ---------------------------------------------
case "${TARGET_CPU}" in
    hpc8a|hpc7a) HOST_OPT=(-O3 -march=x86-64-v4 -mtune=znver4) ;;
    *) fail "unsupported TARGET_CPU '${TARGET_CPU}' (expected hpc8a or hpc7a)" ;;
esac

# --- Build Charm++ (OFI/SMP for multi-node, multicore for single-node) ---
STAGE="charm++"
cd "${BUILD_DIR}/${CHARM_DIR}"
log "building Charm++ ${CHARM_NET} smp (EFA/OFI)"
./build charm++ "${CHARM_NET}" smp slurmpmi2 --with-production \
    -j"${COMPILE_CORES}" "${HOST_OPT[@]}" \
    || fail "Charm++ OFI/SMP build failed"
log "building Charm++ multicore-linux-x86_64 (single-node)"
./build charm++ multicore-linux-x86_64 --with-production \
    -j"${COMPILE_CORES}" "${HOST_OPT[@]}" \
    || fail "Charm++ multicore build failed"

# --- Configure + compile NAMD --------------------------------------------
STAGE="namd-config"
cd "${BUILD_DIR}"
log "configuring NAMD (${NAMD_ARCH}, AVX-512 tiles, OFI/SMP Charm++)"
./config "${NAMD_ARCH}" \
    --charm-arch "${CHARM_NET}-smp-slurmpmi2" \
    --with-tcl --tcl-prefix /usr \
    --with-fftw3 --fftw-prefix /usr \
    --with-avxtiles \
    --cc "gcc" --cxx "g++" \
    || fail "NAMD configure failed"

STAGE="namd-compile"
cd "${BUILD_DIR}/${NAMD_ARCH}"
log "compiling NAMD (this can take ~20-40 min)"
make -j"${COMPILE_CORES}" || fail "NAMD compile failed"
[ -x namd3 ] || fail "NAMD compile finished but namd3 binary is missing"

# --- Install -------------------------------------------------------------
STAGE="install"
mkdir -p "${INSTALL_DIR}/bin"
cp -a namd3 "${INSTALL_DIR}/bin/namd3"
# Also keep the multicore binary if a separate build dir was produced.
log "installed namd3 -> ${INSTALL_DIR}/bin/namd3"

# --- Generate the env script ---------------------------------------------
STAGE="env-script"
cat > "${ENV_SCRIPT}" <<EOF
#!/bin/bash
# NAMD ${NAMD_VERSION} — x86_64 (Charm++ ${CHARM_NET}-smp over EFA, AVX-512 tiles)
module load libfabric-aws 2>/dev/null || true
export NAMD_ROOT="${INSTALL_DIR}"
export PATH="\${NAMD_ROOT}/bin:\${PATH}"
export LD_LIBRARY_PATH="\${NAMD_ROOT}/lib:\${LD_LIBRARY_PATH:-}"
export NAMD_VERSION="${NAMD_VERSION}"
export CHARM_ARCH="${CHARM_NET}-smp-slurmpmi2"
EOF
chmod 0644 "${ENV_SCRIPT}"

log "DONE. namd3: ${INSTALL_DIR}/bin/namd3"
log "      env:   ${ENV_SCRIPT}"
"${INSTALL_DIR}/bin/namd3" --version 2>&1 | head -3 || true
