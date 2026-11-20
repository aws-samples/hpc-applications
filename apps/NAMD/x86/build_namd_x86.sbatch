#!/bin/bash
#SBATCH --job-name=build-namd-x86
#SBATCH --constraint=hpc8a.96xlarge
#SBATCH --partition=hpc8a
#SBATCH --nodes=1
#SBATCH --exclusive
#SBATCH --time=02:00:00
#SBATCH --output=build-namd-x86-%j.out
#
# Build NAMD 3.0.2 from source for one x86 instance family (TARGET_CPU).
#
# NAMD runs on the Charm++ parallel runtime. This script builds Charm++ once,
# using the MPI/SMP backend over the system OpenMPI (which uses EFA underneath
# via its libfabric provider):
#   * mpi-linux-x86_64 ... smp   — one process per node + worker threads
# then configures and compiles NAMD against that Charm++, producing the `namd3`
# binary, and NAMD's psfgen, which the launcher's 20STMV benchmark is built
# with. Charm++ and NAMD's own code are compiled with the target's -march and
# -mtune. NAMD also takes the options of its Linux-AVX512-g++ arch file (AVX-512,
# and NAMD's mixed-precision AVX-512 tile-list kernels, NAMD_AVXTILES), or, for
# hpc6a, whose CPU has no AVX-512, those of its Linux-x86_64-g++ arch file.
#
#   TARGET_CPU            -march / -mtune                    NAMD arch
#   hpc8a, hpc7a, m8a     x86-64-v4 / znver4                 Linux-AVX512-g++
#   c8i, r8i              x86-64-v4 / sapphirerapids         Linux-AVX512-g++
#   hpc6id                x86-64-v4 / icelake-server         Linux-AVX512-g++
#   hpc6a                 x86-64-v3 / znver3                 Linux-x86_64-g++
#
# Each target installs under ${BASE_DIR}/x86_64/<version>-<target>/, where the
# benchmark launcher finds the build of the node's instance family.
#
# The MPI layer needs nothing beyond the system OpenMPI, which already carries
# the traffic between nodes over EFA.
#
# NOTE: the NAMD source tarball is distributed behind a license click-through
# (https://www.ks.uiuc.edu/Research/namd/) and CANNOT be fetched
# non-interactively. Download NAMD_<version>_Source.tar.gz once, accepting the
# license, and stage it at ${BASE_DIR}/src/ before submitting this job. Set
# NAMD_SRC to override the path, or NAMD_SRC_URL to fetch from a private mirror.
#
# Override via --export=ALL,...:
#   NAMD_VERSION   NAMD release (default 3.0.2)
#   BASE_DIR       install root (default /fsx/namd)
#   TARGET_CPU     hpc8a | hpc7a | m8a | c8i | r8i | hpc6id | hpc6a (default hpc8a)
#   COMPILE_CORES  parallel build threads (default 48)
#   NAMD_SRC       staged source tarball (default ${BASE_DIR}/src/NAMD_${NAMD_VERSION}_Source.tar.gz)
#   NAMD_SRC_URL   optional URL to fetch the source tarball from a mirror
#   FFTW_VERSION   FFTW release (default 3.3.10)
#   FFTW_SHA256    the FFTW tarball's SHA-256 (default: FFTW's published one for
#                  3.3.10; none for another version, which then only prints it)

set -euo pipefail

NAMD_VERSION="${NAMD_VERSION:-3.0.2}"
BASE_DIR="${BASE_DIR:-/fsx/namd}"
TARGET_CPU="${TARGET_CPU:-hpc8a}"
COMPILE_CORES="${COMPILE_CORES:-48}"
NAMD_SRC="${NAMD_SRC:-${BASE_DIR}/src/NAMD_${NAMD_VERSION}_Source.tar.gz}"
NAMD_SRC_URL="${NAMD_SRC_URL:-}"

CHARM_NET="mpi-linux-x86_64"          # Charm++ MPI backend (rides EFA via OpenMPI)
CHARM_ARCH="${CHARM_NET}-smp"         # SMP: one process/node + worker threads
OPENMPI_MODULE="${OPENMPI_MODULE:-openmpi/4.1.7}"
INSTALL_DIR="${BASE_DIR}/x86_64/${NAMD_VERSION}-${TARGET_CPU}"
FFTW_PREFIX="${INSTALL_DIR}/fftw"   # static single-precision FFTW (self-contained on FSx)
FFTW_VERSION="${FFTW_VERSION:-3.3.10}"
# The SHA-256 that FFTW publishes for its 3.3.10 tarball. The tarball, downloaded
# or staged, must match it before it is extracted; set FFTW_SHA256 for another
# version.
if [ -z "${FFTW_SHA256:-}" ] && [ "${FFTW_VERSION}" = "3.3.10" ]; then
    FFTW_SHA256="56c932549852cddcfafdab3820b0200c7742675be92179e59e6215b340e26467"
fi
FFTW_SHA256="${FFTW_SHA256:-}"
BUILD_DIR="${BASE_DIR}/build/x86_64-${NAMD_VERSION}-${TARGET_CPU}-$$"
ENV_SCRIPT="${INSTALL_DIR}/namd-${NAMD_VERSION}-x86-env.sh"

log()  { echo "[$(date +%H:%M:%S)] $*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }
trap 'fail "build failed at line ${LINENO} (stage: ${STAGE:-unknown})"' ERR
STAGE="init"

# --- The target's flags ----------------------------------------------------
# The -march/-mtune go to Charm++'s build and to NAMD's compile options. NAMD's
# ./config --cxx-opts and --cc-opts replace its arch file's options, so
# NAMD_OPTS repeats them.
case "${TARGET_CPU}" in
    hpc8a|hpc7a|m8a) TARGET_FLAGS=(-march=x86-64-v4 -mtune=znver4) ;;
    c8i|r8i)         TARGET_FLAGS=(-march=x86-64-v4 -mtune=sapphirerapids) ;;
    hpc6id)          TARGET_FLAGS=(-march=x86-64-v4 -mtune=icelake-server) ;;
    hpc6a)           TARGET_FLAGS=(-march=x86-64-v3 -mtune=znver3) ;;
    *) fail "unsupported TARGET_CPU '${TARGET_CPU}' (expected hpc8a, hpc7a, m8a, c8i, r8i, hpc6id or hpc6a)" ;;
esac
if [ "${TARGET_CPU}" = hpc6a ]; then
    NAMD_ARCH="Linux-x86_64-g++"      # no AVX-512 on this CPU
    NAMD_ISA="avx2"
    NAMD_ARCH_OPTS=(-O3 -fexpensive-optimizations -ffast-math)
else
    NAMD_ARCH="Linux-AVX512-g++"      # AVX-512 and the tile-list kernels
    NAMD_ISA="avx512"
    NAMD_ARCH_OPTS=(-O3 -fexpensive-optimizations -ffast-math -mavx512f -mavx512dq -DNAMD_AVXTILES)
fi
HOST_OPT=(-O3 "${TARGET_FLAGS[@]}")
NAMD_OPTS="${NAMD_ARCH_OPTS[*]} ${TARGET_FLAGS[*]}"

log "NAMD ${NAMD_VERSION} x86 build — target=${TARGET_CPU} (${TARGET_FLAGS[*]}, NAMD arch ${NAMD_ARCH}) cores=${COMPILE_CORES}"
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

# --- Toolchain / dependencies --------------------------------------------
# TCL (runtime libtcl8.6.so) ships in the base AMI on every node, so we link
# it dynamically and only need its dev headers at build time. FFTW is built
# from source as a STATIC single-precision library into the shared install
# prefix so the namd3 binary carries no external FFTW .so dependency and runs
# unchanged on every (ephemeral) compute node.
STAGE="deps"
log "installing build dependencies (gcc-c++, gfortran, tcl-devel)"
sudo dnf install -y gcc gcc-c++ gcc-gfortran make tar gzip \
    tcl-devel >/dev/null 2>&1 \
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

# --- Build static single-precision FFTW (self-contained on shared FSx) ----
STAGE="fftw"
if [ ! -f "${FFTW_PREFIX}/lib/libfftw3f.a" ]; then
    FFTW_SRC="${BASE_DIR}/src/fftw-${FFTW_VERSION}.tar.gz"
    if [ ! -f "${FFTW_SRC}" ]; then
        log "fetching FFTW ${FFTW_VERSION}"
        curl -fsSL --max-time 600 --retry 3 -o "${FFTW_SRC}" \
            "https://www.fftw.org/fftw-${FFTW_VERSION}.tar.gz" \
            || fail "failed to download FFTW ${FFTW_VERSION}"
    fi
    FFTW_GOT="$(sha256sum "${FFTW_SRC}" | awk '{print $1}')"
    if [ -n "${FFTW_SHA256}" ]; then
        [ "${FFTW_GOT}" = "${FFTW_SHA256}" ] \
            || fail "${FFTW_SRC} has SHA-256 ${FFTW_GOT}, not the expected ${FFTW_SHA256} (FFTW_SHA256); remove it to download it again"
        log "FFTW ${FFTW_VERSION} tarball: SHA-256 ${FFTW_GOT}, as expected"
    else
        echo "NOTE: no SHA-256 to check for FFTW ${FFTW_VERSION} (set FFTW_SHA256); ${FFTW_SRC} has SHA-256 ${FFTW_GOT}" >&2
    fi
    FFTW_BUILD="${BUILD_DIR}-fftw"
    mkdir -p "${FFTW_BUILD}"
    tar xzf "${FFTW_SRC}" -C "${FFTW_BUILD}" --strip-components=1 \
        || fail "failed to extract FFTW source"
    ( cd "${FFTW_BUILD}" \
      && ./configure --prefix="${FFTW_PREFIX}" \
            --enable-float --enable-static --disable-shared \
            --enable-sse2 --enable-avx --enable-avx2 --enable-avx512 \
            CFLAGS="-O3 -fPIC" >/dev/null \
      && make -j"${COMPILE_CORES}" >/dev/null \
      && make install >/dev/null ) \
        || fail "FFTW build/install failed"
    rm -rf "${FFTW_BUILD}"
fi
[ -f "${FFTW_PREFIX}/lib/libfftw3f.a" ] || fail "static libfftw3f.a missing under ${FFTW_PREFIX}"
log "static FFTW ready: ${FFTW_PREFIX}/lib/libfftw3f.a"

# --- Build Charm++ (MPI/SMP over system OpenMPI; rides EFA) ---------------
STAGE="charm++"
cd "${BUILD_DIR}/${CHARM_DIR}"
# The MPI backend needs mpicxx/mpicc in PATH. The system OpenMPI uses EFA via
# its libfabric provider, so inter-node Charm++ traffic still rides EFA.
module load "${OPENMPI_MODULE}" libfabric-aws 2>/dev/null || true
command -v mpicxx >/dev/null 2>&1 || fail "mpicxx not in PATH (load ${OPENMPI_MODULE})"
log "building Charm++ ${CHARM_NET} smp (MPI backend over $(mpicxx --showme:version 2>/dev/null | head -1 || echo OpenMPI))"
./build charm++ "${CHARM_NET}" smp --with-production \
    -j"${COMPILE_CORES}" "${HOST_OPT[@]}" \
    || fail "Charm++ MPI/SMP build failed"

# --- Configure + compile NAMD --------------------------------------------
STAGE="namd-config"
cd "${BUILD_DIR}"
log "configuring NAMD (${NAMD_ARCH}, MPI/SMP Charm++, static FFTW, ${NAMD_OPTS})"
./config "${NAMD_ARCH}" \
    --charm-arch "${CHARM_ARCH}" \
    --with-tcl --tcl-prefix /usr \
    --with-fftw3 --fftw-prefix "${FFTW_PREFIX}" \
    --cc "gcc" --cxx "g++" \
    --cc-opts "${NAMD_OPTS}" --cxx-opts "${NAMD_OPTS}" \
    || fail "NAMD configure failed"

STAGE="namd-compile"
cd "${BUILD_DIR}/${NAMD_ARCH}"
log "compiling NAMD"
make -j"${COMPILE_CORES}" || fail "NAMD compile failed"
[ -x namd3 ] || fail "NAMD compile finished but namd3 binary is missing"

# --- psfgen, for the 20STMV benchmark ------------------------------------
# NAMD's source ships psfgen with the molfile plugins it needs (the js and
# namdbin formats). The benchmark launcher builds the 20STMV system from STMV
# with it, as NAMD's construction scripts do. If psfgen does not build, namd3
# is installed all the same, with a NOTE: only MODEL=20STMV needs psfgen.
STAGE="psfgen"
PSFGEN_BUILT=""
log "compiling psfgen"
if make -j"${COMPILE_CORES}" psfgen && [ -x psfgen ]; then
    PSFGEN_BUILT=1
else
    echo "NOTE: psfgen did not build; namd3 is installed without it, and only the 20STMV benchmark (MODEL=20STMV) needs it" >&2
fi

# --- Install -------------------------------------------------------------
STAGE="install"
mkdir -p "${INSTALL_DIR}/bin"
cp -a namd3 "${INSTALL_DIR}/bin/namd3"
log "installed namd3 -> ${INSTALL_DIR}/bin/namd3"
if [ -n "${PSFGEN_BUILT}" ]; then
    cp -a psfgen "${INSTALL_DIR}/bin/psfgen"
    log "installed psfgen -> ${INSTALL_DIR}/bin/psfgen"
fi

# --- Generate the env script ---------------------------------------------
STAGE="env-script"
cat > "${ENV_SCRIPT}" <<EOF
#!/bin/bash
# NAMD ${NAMD_VERSION} — x86_64, target ${TARGET_CPU} (Charm++ ${CHARM_ARCH} over OpenMPI/EFA, NAMD arch ${NAMD_ARCH})
module load ${OPENMPI_MODULE} libfabric-aws 2>/dev/null || true
export NAMD_ROOT="${INSTALL_DIR}"
export PATH="\${NAMD_ROOT}/bin:\${PATH}"
export LD_LIBRARY_PATH="\${NAMD_ROOT}/lib:\${LD_LIBRARY_PATH:-}"
export NAMD_VERSION="${NAMD_VERSION}"
export CHARM_ARCH="${CHARM_ARCH}"
export NAMD_TARGET_CPU="${TARGET_CPU}"
export NAMD_ISA="${NAMD_ISA}"
EOF
chmod 0644 "${ENV_SCRIPT}"

log "DONE. namd3: ${INSTALL_DIR}/bin/namd3"
if [ -n "${PSFGEN_BUILT}" ]; then log "      psfgen: ${INSTALL_DIR}/bin/psfgen"; fi
log "      env:   ${ENV_SCRIPT}"
"${INSTALL_DIR}/bin/namd3" --version 2>&1 | head -3 || true
