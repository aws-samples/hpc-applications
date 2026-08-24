#!/usr/bin/env bash
#SBATCH --job-name=build-qe-arm
#SBATCH --nodes=1
#SBATCH --exclusive
#SBATCH --time=02:00:00
#SBATCH --output=build-qe-arm-%j.out
#SBATCH --error=build-qe-arm-%j.err
#
# build_qe_arm.sbatch: build an architecture-tuned Quantum ESPRESSO (pw.x)
# for AWS Graviton on an AWS PCS (Slurm) cluster.
#
# Auto-detects the Graviton generation from /proc/cpuinfo (Arm "CPU part")
# and compiles QE with the matching -mcpu target, through the EFA-bundled
# Open MPI compiler wrappers, against system OpenBLAS + FFTW3.
#
#   Graviton2 (Neoverse N1, 0xd0c) -> -O3 -mcpu=neoverse-n1
#   Graviton3 (Neoverse V1, 0xd40) -> -O3 -mcpu=neoverse-v1
#   Graviton4 (Neoverse V2, 0xd4f) -> -O3 -mcpu=neoverse-v2
#   Graviton5 (Neoverse V3, 0xd84) -> -O3 -mcpu=neoverse-v3 (needs gcc >= 13;
#                                     falls back to neoverse-v2 on older gcc)
#
# NOTE: -ffast-math is deliberately NOT used. QE is a DFT code; floating-
# point reassociation can break SCF convergence and perturb total energies.
#
# Usage (on a Graviton partition of your PCS cluster):
#   sbatch -p <graviton-partition> Arm/build_qe_arm.sbatch
#
# Overrides via --export=ALL,VAR=value:
#   QE_VERSION   QE release tag to build            (default: 7.5)
#   BASE_DIR     shared-filesystem install root     (default: /fsx/qe)
#   TARGET       graviton2|graviton3|graviton4|graviton5|auto (default: auto)
#   QE_CC/QE_CXX/QE_FC
#                compilers the MPI wrappers should wrap
#                (defaults: gcc / g++ / gfortran)
#
# Graviton5 note: -mcpu=neoverse-v3 needs gcc >= 13, and the Amazon Linux
# 2023 system gcc is 11.x. To get a NATIVE V3 binary, stage a newer gcc and
# point this script at it, e.g.
#
#   sudo dnf install -y gcc14 gcc14-c++ gcc14-gfortran
#   sbatch -p <c9g-partition> --export=ALL,QE_CC=gcc-14,QE_CXX=g++-14,QE_FC=gfortran-14 \
#          Arm/build_qe_arm.sbatch
#
# Without that, the -mcpu probe below fails and the build falls back to the
# neoverse-v2 target (correct code on Graviton5, just not V3-tuned). The
# fallback is recorded in build-manifest.json (mcpu_fallback=true) and the
# resolved flags are part of the idempotence key, so a later resubmission
# with a capable gcc rebuilds rather than silently reusing the fallback.
#
# The binary installs to ${BASE_DIR}/<qe-version>/gcc-<target>/bin/pw.x and
# a build-manifest.json (compiler, flags, MPI, SHA-256 provenance) is written
# next to it. The build is idempotent: re-submitting with an identical
# (version, target) is a fast no-op.

set -euo pipefail

QE_VERSION="${QE_VERSION:-7.5}"
BASE_DIR="${BASE_DIR:-/fsx/qe}"
TARGET="${TARGET:-auto}"
# Compilers the MPI wrappers will wrap. Overridable so a staged newer gcc
# (e.g. gcc-14 for a native Graviton5 -mcpu=neoverse-v3 build) can be used
# without editing this script.
QE_CC="${QE_CC:-gcc}"
QE_CXX="${QE_CXX:-g++}"
QE_FC="${QE_FC:-gfortran}"

log() { printf '[build-qe %s] %s\n' "$(date -Iseconds)" "$*"; }
die() { log "ERROR: $*"; exit 1; }

[[ "$(uname -m)" == aarch64 ]] || die "this script targets Graviton (aarch64); host is $(uname -m). Submit to a Graviton partition."

# --------------------------------------------------------------------------- #
# Prerequisites: compilers, math libraries (system OpenBLAS + FFTW3), tools.
#
# This runs FIRST, before anything that depends on it: the -mcpu probe below
# needs a working compiler, and the idempotence check needs jq. Probing before
# installing would make a missing tool indistinguishable from an unsupported
# flag -- which silently downgraded the Graviton5 target and defeated the
# idempotence check on a node where gcc/jq were not preinstalled.
# --------------------------------------------------------------------------- #
sudo dnf install -y -q gcc gcc-gfortran make cmake \
    openblas-devel fftw-devel git wget xz tar jq

for tool in "$QE_CC" "$QE_CXX" "$QE_FC" cmake jq; do
    command -v "$tool" >/dev/null \
        || die "required tool '$tool' not on PATH after installing prerequisites"
done
log "compilers: CC=${QE_CC} ($("$QE_CC" --version | head -1)) FC=${QE_FC}"

# --------------------------------------------------------------------------- #
# Detect the Graviton generation from the Arm "CPU part" field.
# --------------------------------------------------------------------------- #
if [[ "$TARGET" == auto ]]; then
    cpu_part=$(awk '/CPU part/{print $4; exit}' /proc/cpuinfo)
    case "$cpu_part" in
        0xd0c) TARGET=graviton2 ;;   # Neoverse N1
        0xd40) TARGET=graviton3 ;;   # Neoverse V1 (also Graviton3E)
        0xd4f) TARGET=graviton4 ;;   # Neoverse V2
        0xd84) TARGET=graviton5 ;;   # Neoverse V3
        *) die "unrecognised Arm CPU part '$cpu_part'; set TARGET=graviton2|graviton3|graviton4|graviton5 explicitly" ;;
    esac
fi
# True when $QE_CC accepts the given -mcpu target.
cc_knows_mcpu() { "$QE_CC" "-mcpu=$1" -E -x c /dev/null >/dev/null 2>&1; }

MCPU_FALLBACK=false
case "$TARGET" in
    graviton2) OPT="-O3 -mcpu=neoverse-n1" ;;
    graviton3) OPT="-O3 -mcpu=neoverse-v1" ;;
    graviton4) OPT="-O3 -mcpu=neoverse-v2" ;;
    graviton5)
        # -mcpu=neoverse-v3 needs gcc >= 13; AL2023's system gcc is 11.x.
        # Fall back to the V2 target (correct code on Graviton5, still SVE-
        # vectorised, just not V3-tuned). For a native V3 build, stage a
        # newer gcc and pass QE_CC/QE_CXX/QE_FC (see header).
        if cc_knows_mcpu neoverse-v3; then
            OPT="-O3 -mcpu=neoverse-v3"
        else
            log "WARNING: ${QE_CC} lacks -mcpu=neoverse-v3 (needs gcc>=13); building the neoverse-v2 target, which runs correctly on Graviton5 but is not V3-tuned. Pass QE_CC/QE_CXX/QE_FC pointing at gcc>=13 for a native build."
            OPT="-O3 -mcpu=neoverse-v2"
            MCPU_FALLBACK=true
        fi
        ;;
    *) die "unknown TARGET '$TARGET'" ;;
esac
log "target=${TARGET} flags='${OPT}' qe=${QE_VERSION} mcpu_fallback=${MCPU_FALLBACK}"

PREFIX="${BASE_DIR}/${QE_VERSION}/gcc-${TARGET}"
SRC_DIR="${BASE_DIR}/${QE_VERSION}/source"

# --------------------------------------------------------------------------- #
# Idempotence: skip when the same (version, target, flags) is already
# installed. The resolved flags are part of the key on purpose: a build that
# fell back to an older -mcpu (see above) must not be mistaken for the native
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
# Use the EFA-bundled Open MPI at /opt/amazon/openmpi (libfabric-aware,
# PMIx-backed); NOT the distro openmpi-devel, whose external-PMIx plugin
# cannot initialise on Amazon Linux 2023.
# --------------------------------------------------------------------------- #
OMPI_ROOT=/opt/amazon/openmpi
[[ -x "${OMPI_ROOT}/bin/mpirun" ]] \
    || die "EFA Open MPI not found at ${OMPI_ROOT}; install the EFA package (efa_installer) on the compute AMI"
export PATH="${OMPI_ROOT}/bin:${PATH}"
export LD_LIBRARY_PATH="${OMPI_ROOT}/lib64:${OMPI_ROOT}/lib:${LD_LIBRARY_PATH:-}"
log "MPI: $(mpirun --version 2>&1 | head -1)"

# CRITICAL: point the Open MPI compiler wrappers at the intended compilers.
# Without this the wrappers may silently compile QE's Fortran (the bulk of
# the code) with whatever the wrappers default to. Explicit is safe:
export OMPI_CC="$QE_CC" OMPI_CXX="$QE_CXX" OMPI_FC="$QE_FC"

# --------------------------------------------------------------------------- #
# Fetch the QE source (shared cache first, GitLab fallback) and record the
# tarball SHA-256 for provenance.
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
# Configure + build. HDF5 / libxc / ScaLAPACK are pinned OFF so every build
# of this script is identical and comparable; the SCF benchmark does not
# need them (see README; "Build options held constant").
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
# Banner check: launch pw.x once under mpirun and require the version banner.
# A bare exec can abort inside singleton MPI_Init before printing anything,
# so one rank under mpirun is the reliable probe.
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

# --------------------------------------------------------------------------- #
# Provenance manifest, written only after the banner check passes.
# --------------------------------------------------------------------------- #
jq -n \
    --arg qe_version "$QE_VERSION" \
    --arg target "$TARGET" \
    --arg opt_flags "$OPT" \
    --argjson mcpu_fallback "$MCPU_FALLBACK" \
    --arg compiler "$("$QE_CC" --version | head -1)" \
    --arg mpi "$(mpirun --version 2>&1 | head -1)" \
    --arg pw_x_sha256 "$(sha256sum "${PREFIX}/bin/pw.x" | awk '{print $1}')" \
    --arg source_tarball_sha256 "$SOURCE_SHA256" \
    --arg built_at "$(date -Iseconds)" \
    --arg banner "$BANNER_LINE" \
    '{qe_version:$qe_version, target:$target, opt_flags:$opt_flags,
      mcpu_fallback:$mcpu_fallback,
      compiler:$compiler, mpi:$mpi, pw_x_sha256:$pw_x_sha256,
      source_tarball_sha256:$source_tarball_sha256,
      built_at:$built_at, banner:$banner}' \
    > "${PREFIX}/build-manifest.json"

log "build complete: ${PREFIX}/bin/pw.x (${TARGET})"
