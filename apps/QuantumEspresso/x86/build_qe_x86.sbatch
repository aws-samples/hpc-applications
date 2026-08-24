#!/usr/bin/env bash
#SBATCH --job-name=build-qe-x86
#SBATCH --nodes=1
#SBATCH --exclusive
#SBATCH --time=02:00:00
#SBATCH --output=build-qe-x86-%j.out
#SBATCH --error=build-qe-x86-%j.err
#
# build_qe_x86.sbatch: build an architecture-tuned Quantum ESPRESSO (pw.x)
# for x86_64 (AMD + Intel) on an AWS PCS (Slurm) cluster.
#
# Auto-detects the CPU family from /proc/cpuinfo and compiles QE with the
# matching -march target, through the EFA-bundled Open MPI compiler
# wrappers, against system OpenBLAS + FFTW3:
#
#   AMD Zen 4 (Genoa, c7a/m7a/r7a/hpc7a)   -> -O3 -march=znver4
#   AMD Zen 5 (Turin, c8a/hpc8a)           -> -O3 -march=znver5 (gcc >= 14.1;
#                                             falls back to znver4)
#   Intel Sapphire Rapids (c7i/m7i/r7i)    -> -O3 -march=sapphirerapids
#   Intel Granite Rapids (c8i)             -> -O3 -march=graniterapids
#                                             (gcc >= 14; falls back to
#                                             sapphirerapids)
#
# NOTE: -ffast-math is deliberately NOT used. QE is a DFT code; floating-
# point reassociation can break SCF convergence and perturb total energies.
#
# Vendor-toolchain variants (AOCC + AOCL on AMD, oneAPI + MKL on Intel) are
# documented in the README; they need EULA-gated installers staged by an
# operator and cannot be auto-fetched here. This script builds the GCC
# reference, which is reproducible on a stock AL2023 PCS AMI.
#
# Usage (on an x86 partition of your PCS cluster):
#   sbatch -p <x86-partition> x86/build_qe_x86.sbatch
#
# Overrides via --export=ALL,VAR=value:
#   QE_VERSION   QE release tag to build          (default: 7.5)
#   BASE_DIR     shared-filesystem install root   (default: /fsx/qe)
#   TARGET       znver4|znver5|sapphirerapids|graniterapids|auto (default: auto)
#   QE_CC/QE_CXX/QE_FC
#                compilers the MPI wrappers should wrap
#                (defaults: gcc / g++ / gfortran)
#
# znver5 needs gcc >= 14.1 and graniterapids needs gcc >= 14; the Amazon Linux
# 2023 system gcc is 11.x. To target the newest silicon natively, stage a newer
# gcc and point this script at it, e.g.
#
#   sudo dnf install -y gcc14 gcc14-c++ gcc14-gfortran
#   sbatch -p <c8a-partition> --export=ALL,QE_CC=gcc-14,QE_CXX=g++-14,QE_FC=gfortran-14 \
#          x86/build_qe_x86.sbatch
#
# Otherwise the -march probe falls back to the previous target (correct code,
# just not tuned for the newer core). The fallback is recorded in
# build-manifest.json (march_fallback=true) and the resolved flags are part of
# the idempotence key, so a later resubmission with a capable gcc rebuilds
# rather than silently reusing the fallback.
#
# Installs to ${BASE_DIR}/<qe-version>/gcc-<target>/bin/pw.x with a
# build-manifest.json provenance record. Idempotent.

set -euo pipefail

QE_VERSION="${QE_VERSION:-7.5}"
BASE_DIR="${BASE_DIR:-/fsx/qe}"
TARGET="${TARGET:-auto}"
# Compilers the MPI wrappers will wrap. Overridable so a staged newer gcc
# (e.g. gcc-14 for -march=znver5 / -march=graniterapids) can be used without
# editing this script.
QE_CC="${QE_CC:-gcc}"
QE_CXX="${QE_CXX:-g++}"
QE_FC="${QE_FC:-gfortran}"

log() { printf '[build-qe %s] %s\n' "$(date -Iseconds)" "$*"; }
die() { log "ERROR: $*"; exit 1; }

[[ "$(uname -m)" == x86_64 ]] || die "this script targets x86_64; host is $(uname -m). Submit to an x86 partition (see Arm/build_qe_arm.sbatch for Graviton)."

# --------------------------------------------------------------------------- #
# Prerequisites: compilers, math libraries (system OpenBLAS + FFTW3), tools.
#
# This runs FIRST, before anything that depends on it: the -march probe below
# needs a working compiler, and the idempotence check needs jq. Probing before
# installing would make a missing tool indistinguishable from an unsupported
# flag -- which silently downgraded the target and defeated the idempotence
# check on a node where gcc/jq were not preinstalled.
# --------------------------------------------------------------------------- #
sudo dnf install -y -q gcc gcc-gfortran make cmake \
    openblas-devel fftw-devel git wget xz tar jq

for tool in "$QE_CC" "$QE_CXX" "$QE_FC" cmake jq; do
    command -v "$tool" >/dev/null \
        || die "required tool '$tool' not on PATH after installing prerequisites"
done
log "compilers: CC=${QE_CC} ($("$QE_CC" --version | head -1)) FC=${QE_FC}"

# --------------------------------------------------------------------------- #
# Detect the CPU family. AMD: Zen 4 is family 25 (0x19), Zen 5 is family 26
# (0x1a). Intel: Sapphire Rapids is family 6 model 143; Granite Rapids is
# family 6 model 173/174.
# --------------------------------------------------------------------------- #
gcc_knows() { "$QE_CC" "-march=$1" -E -x c /dev/null >/dev/null 2>&1; }

if [[ "$TARGET" == auto ]]; then
    vendor=$(awk -F': ' '/vendor_id/{print $2; exit}' /proc/cpuinfo)
    family=$(awk -F': ' '/cpu family/{print $2; exit}' /proc/cpuinfo)
    model=$(awk -F': ' '/^model[^ ]*[[:space:]]*:/{print $2; exit}' /proc/cpuinfo)
    case "$vendor" in
        AuthenticAMD)
            case "$family" in
                25) TARGET=znver4 ;;
                26) TARGET=znver5 ;;
                *) die "unrecognised AMD family '$family'; set TARGET explicitly" ;;
            esac ;;
        GenuineIntel)
            case "$model" in
                143)     TARGET=sapphirerapids ;;
                173|174) TARGET=graniterapids ;;
                *) die "unrecognised Intel model '$model'; set TARGET explicitly" ;;
            esac ;;
        *) die "unrecognised vendor '$vendor'" ;;
    esac
fi

MARCH_FALLBACK=false
case "$TARGET" in
    znver4)         OPT="-O3 -march=znver4" ;;
    znver5)
        # -march=znver5 needs gcc >= 14.1; a znver4 binary runs correctly on
        # Zen 5 (AVX-512 is already emitted) so fall back rather than fail.
        if gcc_knows znver5; then OPT="-O3 -march=znver5"
        else
            log "WARNING: ${QE_CC} lacks -march=znver5 (needs gcc>=14.1); building the znver4 target, which runs correctly on Zen 5 but is not Zen 5-tuned. Pass QE_CC/QE_CXX/QE_FC pointing at gcc>=14.1 for a native build."
            OPT="-O3 -march=znver4"; TARGET=znver4; MARCH_FALLBACK=true
        fi ;;
    sapphirerapids) OPT="-O3 -march=sapphirerapids" ;;
    graniterapids)
        if gcc_knows graniterapids; then OPT="-O3 -march=graniterapids"
        else
            log "WARNING: ${QE_CC} lacks -march=graniterapids (needs gcc>=14); building the sapphirerapids target, which runs correctly on Granite Rapids but is not GNR-tuned. Pass QE_CC/QE_CXX/QE_FC pointing at gcc>=14 for a native build."
            OPT="-O3 -march=sapphirerapids"; TARGET=sapphirerapids; MARCH_FALLBACK=true
        fi ;;
    *) die "unknown TARGET '$TARGET'" ;;
esac
log "target=${TARGET} flags='${OPT}' qe=${QE_VERSION} march_fallback=${MARCH_FALLBACK}"

PREFIX="${BASE_DIR}/${QE_VERSION}/gcc-${TARGET}"
SRC_DIR="${BASE_DIR}/${QE_VERSION}/source"

# --------------------------------------------------------------------------- #
# Idempotence: skip when the same (version, target, flags) is already
# installed. The resolved flags are part of the key on purpose: a build that
# fell back to an older -march (see above) must not be mistaken for the native
# one, so resubmitting with a capable compiler rebuilds instead of no-opping.
# --------------------------------------------------------------------------- #
if [[ -x "${PREFIX}/bin/pw.x" && -f "${PREFIX}/build-manifest.json" ]] \
   && jq -e --arg v "$QE_VERSION" --arg t "$TARGET" --arg o "$OPT" \
        '.qe_version == $v and .target == $t and .opt_flags == $o' \
        "${PREFIX}/build-manifest.json" >/dev/null 2>&1; then
    log "QE ${QE_VERSION}/gcc-${TARGET} (${OPT}) already installed at ${PREFIX}; nothing to do"
    exit 0
fi

# --------------------------------------------------------------------------- #
# EFA Open MPI + wrapper overrides (see README).
# --------------------------------------------------------------------------- #
OMPI_ROOT=/opt/amazon/openmpi
[[ -x "${OMPI_ROOT}/bin/mpirun" ]] \
    || die "EFA Open MPI not found at ${OMPI_ROOT}; install the EFA package (efa_installer) on the compute AMI"
export PATH="${OMPI_ROOT}/bin:${PATH}"
export LD_LIBRARY_PATH="${OMPI_ROOT}/lib64:${OMPI_ROOT}/lib:${LD_LIBRARY_PATH:-}"
log "MPI: $(mpirun --version 2>&1 | head -1)"

export OMPI_CC="$QE_CC" OMPI_CXX="$QE_CXX" OMPI_FC="$QE_FC"

# --------------------------------------------------------------------------- #
# Fetch source + provenance hash.
# --------------------------------------------------------------------------- #
mkdir -p "${SRC_DIR}"
TARBALL="${SRC_DIR}/q-e-qe-${QE_VERSION}.tar.gz"
if [[ ! -f "$TARBALL" ]]; then
    log "fetching QE ${QE_VERSION} source from GitLab"
    curl -fsSL --retry 5 -o "$TARBALL" \
        "https://gitlab.com/QEF/q-e/-/archive/qe-${QE_VERSION}/q-e-qe-${QE_VERSION}.tar.gz"
fi
SOURCE_SHA256=$(sha256sum "$TARBALL" | awk '{print $1}')

# --------------------------------------------------------------------------- #
# Configure + build (HDF5/libxc/ScaLAPACK pinned OFF; see README).
# --------------------------------------------------------------------------- #
BUILD_DIR=$(mktemp -d -p /tmp build-qe-XXXXXX)
trap 'rm -rf "$BUILD_DIR"' EXIT
cd "$BUILD_DIR"
tar xzf "$TARBALL"
cd q-e-qe-"${QE_VERSION}"

log "cmake configure"
cmake -B build -S . \
    -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
    -DQE_ENABLE_MPI=ON \
    -DQE_ENABLE_OPENMP=OFF \
    -DQE_ENABLE_HDF5=OFF \
    -DQE_ENABLE_LIBXC=OFF \
    -DQE_ENABLE_SCALAPACK=OFF \
    -DQE_FFTW_VENDOR=FFTW3 \
    -DCMAKE_C_COMPILER=mpicc \
    -DCMAKE_Fortran_COMPILER=mpif90 \
    -DCMAKE_C_FLAGS="${OPT}" \
    -DCMAKE_Fortran_FLAGS="${OPT}"
log "cmake build (-j $(nproc))"
cmake --build build -j "$(nproc)"
log "cmake install -> ${PREFIX}"
cmake --install build

# --------------------------------------------------------------------------- #
# Banner check, then provenance manifest.
# --------------------------------------------------------------------------- #
SMOKE_DIR=$(mktemp -d -p /tmp smoke-XXXXXX)
trap 'rm -rf "$BUILD_DIR" "$SMOKE_DIR"' EXIT
# Open MPI refuses to run as root without an explicit override; jobs
# submitted by automation (SSM, cron) often run as root, so allow it for
# this single-rank probe only.
ALLOW_ROOT=(); [[ $EUID -eq 0 ]] && ALLOW_ROOT=(--allow-run-as-root)
( cd "$SMOKE_DIR" && mpirun -np 1 "${ALLOW_ROOT[@]}" "${PREFIX}/bin/pw.x" <<<q ) \
    > "${SMOKE_DIR}/banner.out" 2> "${SMOKE_DIR}/banner.err" || true
BANNER_LINE=$(grep -E '^[[:space:]]*Program PWSCF v\.' "${SMOKE_DIR}/banner.out" | head -1 || true)
[[ -n "$BANNER_LINE" ]] || {
    log "ERROR: pw.x printed no 'Program PWSCF v.' banner; build is broken"
    head -20 "${SMOKE_DIR}/banner.err" >&2 || true
    exit 4
}
log "banner check ok: ${BANNER_LINE}"

jq -n \
    --arg qe_version "$QE_VERSION" \
    --arg target "$TARGET" \
    --arg opt_flags "$OPT" \
    --argjson march_fallback "$MARCH_FALLBACK" \
    --arg compiler "$("$QE_CC" --version | head -1)" \
    --arg mpi "$(mpirun --version 2>&1 | head -1)" \
    --arg pw_x_sha256 "$(sha256sum "${PREFIX}/bin/pw.x" | awk '{print $1}')" \
    --arg source_tarball_sha256 "$SOURCE_SHA256" \
    --arg built_at "$(date -Iseconds)" \
    --arg banner "$BANNER_LINE" \
    '{qe_version:$qe_version, target:$target, opt_flags:$opt_flags,
      march_fallback:$march_fallback,
      compiler:$compiler, mpi:$mpi, pw_x_sha256:$pw_x_sha256,
      source_tarball_sha256:$source_tarball_sha256,
      built_at:$built_at, banner:$banner}' \
    > "${PREFIX}/build-manifest.json"

log "build complete: ${PREFIX}/bin/pw.x (${TARGET})"
