#!/bin/bash
# Builds the OSU Micro-Benchmarks (OMB) with the EFA installer's Open MPI, for osu_benchmarks_openmpi.sbatch.
#
# Settings, in the environment (for example `MAKE_JOBS=8 bash build_osu_benchmarks_openmpi.sh`):
#   OSU_VERSION  the OMB release to build (default 8.0b2)
#   OSU_SHA256   the SHA-256 of its tarball (default: the one this script knows for OSU_VERSION; for a release it
#                does not know, the download is not checked, and a NOTE says so)
#   INSTALL_DIR  an absolute path: OMB is installed in INSTALL_DIR/install and its build logs are kept in
#                INSTALL_DIR/logs (default /fsx/OSU-Benchmark-OpenMPI)
#   MAKE_JOBS    parallel make jobs (default: nproc)
# The build runs in a directory of its own under TMPDIR (or /tmp), removed once OMB is installed. A step that stops
# prints its exit status and the end of its log, keeps that directory, and ends the script with that status.
set -euo pipefail

OSU_VERSION="${OSU_VERSION:-8.0b2}"
OSU_SHA256="${OSU_SHA256:-}"
INSTALL_DIR="${INSTALL_DIR:-/fsx/OSU-Benchmark-OpenMPI}"
MAKE_JOBS="${MAKE_JOBS:-$(nproc)}"

die() { echo "ERROR: $*" >&2; exit 1; }

# The SHA-256 of each OMB release tarball this script knows.
known_sha256() {
    case "$1" in
        8.0b2) echo 2ea96f0d569b012e70eb5cf8d1025890a228e0dfdb3e84d202c3cf53ee34f1b7 ;;
        *) return 1 ;;
    esac
}

# The settings, checked before anything is loaded or downloaded.
case "${OSU_VERSION}" in
    ''|.*|*[!0-9A-Za-z.]*) die "OSU_VERSION=${OSU_VERSION}: use an OMB release number (digits, letters and dots)" ;;
esac
if [ -n "${OSU_SHA256}" ]; then
    OSU_SHA256=$(printf '%s' "${OSU_SHA256}" | tr 'A-F' 'a-f')
    case "${OSU_SHA256}" in
        *[!0-9a-f]*) die "OSU_SHA256=${OSU_SHA256}: use the 64 hexadecimal digits of a SHA-256" ;;
    esac
    [ "${#OSU_SHA256}" = 64 ] || die "OSU_SHA256=${OSU_SHA256}: use the 64 hexadecimal digits of a SHA-256"
fi
case "${INSTALL_DIR}" in
    /*) ;;
    *) die "INSTALL_DIR=${INSTALL_DIR}: use an absolute path" ;;
esac
case "${MAKE_JOBS}" in
    ''|0*|*[!0-9]*) die "MAKE_JOBS=${MAKE_JOBS}: use a whole number from 1 to 9999" ;;
esac
[ "${#MAKE_JOBS}" -le 4 ] || die "MAKE_JOBS=${MAKE_JOBS}: use a whole number from 1 to 9999"
if [ -z "${OSU_SHA256}" ] && ! OSU_SHA256=$(known_sha256 "${OSU_VERSION}"); then
    OSU_SHA256=""
    echo "NOTE: this script knows no SHA-256 for OMB ${OSU_VERSION}, so the download is not checked;" \
         "set OSU_SHA256 to check it" >&2
fi

# The MPI. Environment Modules' `module` is a shell function, which a non-login shell may lack: then its init script
# is sourced. With no module command at all, the mpirun on the PATH is used, after the same check.
if ! declare -F module >/dev/null 2>&1 && [ -r /etc/profile.d/modules.sh ]; then
    set +eu
    # shellcheck disable=SC1091
    . /etc/profile.d/modules.sh
    set -eu
fi
if declare -F module >/dev/null 2>&1; then
    set +u
    module load openmpi || echo "NOTE: module load openmpi did not succeed: using the mpirun on the PATH" >&2
    set -u
else
    echo "NOTE: no module command: using the MPI on the PATH" >&2
fi
MPI_VERSION=$(mpirun --version 2>/dev/null) || true
MPI_VERSION=${MPI_VERSION%%$'\n'*}
case "${MPI_VERSION}" in
    *"(Open MPI) 4."*) ;;
    *) die "mpirun is not Open MPI 4 (mpirun --version: ${MPI_VERSION:-no output}): load the openmpi module, or put" \
           "the EFA installer's Open MPI 4 first on the PATH" ;;
esac

BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/osu-build.XXXXXX")
LOG_DIR="${BUILD_DIR}/logs"
mkdir -p "${LOG_DIR}" "${BUILD_DIR}/src"
START_DIR=$(pwd)
# step <name> <command...>: runs the command with its output in LOG_DIR/<name>.log. If it ends with another status
# than 0, the script says so, shows the end of the log, keeps BUILD_DIR, and ends with that status.
step() {
    local name=$1 rc=0
    shift
    "$@" > "${LOG_DIR}/${name}.log" 2>&1 || rc=$?
    if [ "${rc}" != 0 ]; then
        echo "ERROR: ${name} ended with exit status ${rc}; the last 30 lines of ${LOG_DIR}/${name}.log:" >&2
        tail -n 30 "${LOG_DIR}/${name}.log" >&2
        echo "The build directory is kept: ${BUILD_DIR}" >&2
        exit "${rc}"
    fi
}

OSU_URL="https://mvapich.cse.ohio-state.edu/download/mvapich/osu-micro-benchmarks-${OSU_VERSION}.tar.gz"
TARBALL="${BUILD_DIR}/osu-micro-benchmarks-${OSU_VERSION}.tar.gz"
echo "==> Downloading OSU Micro-Benchmarks ${OSU_VERSION} from ${OSU_URL}..."
step download curl -fsSL --retry 3 --connect-timeout 10 --max-time 300 -o "${TARBALL}" "${OSU_URL}"
TARBALL_SHA256=$(sha256sum "${TARBALL}")
TARBALL_SHA256=${TARBALL_SHA256%% *}
if [ -n "${OSU_SHA256}" ]; then
    if [ "${TARBALL_SHA256}" != "${OSU_SHA256}" ]; then
        echo "ERROR: the download's SHA-256 is ${TARBALL_SHA256}, not ${OSU_SHA256}: nothing is installed" >&2
        echo "The build directory is kept: ${BUILD_DIR}" >&2
        exit 1
    fi
    echo "==> SHA-256 checked: ${TARBALL_SHA256}"
fi

echo "==> Unpacking..."
step unpack tar -xzf "${TARBALL}" -C "${BUILD_DIR}/src" --strip-components=1
# In the unpacked source: OMB 8.0b2's makefiles link its tests against libraries they name in the source tree,
# which a build in another directory makes in that directory instead.
echo "==> Configuring with ${MPI_VERSION} (in ${BUILD_DIR}/src)..."
cd "${BUILD_DIR}/src"
step configure ./configure CC=mpicc CXX=mpicxx --prefix="${INSTALL_DIR}/install"
echo "==> Compiling with ${MAKE_JOBS} jobs..."
step make make -j"${MAKE_JOBS}"
echo "==> Installing to ${INSTALL_DIR}/install..."
step install make install

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "${INSTALL_DIR}/logs/${OSU_VERSION}-${STAMP}"
cp "${LOG_DIR}"/*.log "${INSTALL_DIR}/logs/${OSU_VERSION}-${STAMP}/"
CC_VERSION=$(mpicc --version 2>/dev/null) || true
{
    echo "omb_version=${OSU_VERSION}"
    echo "omb_sha256=${TARBALL_SHA256}"
    echo "omb_sha256_checked=$([ -n "${OSU_SHA256}" ] && echo yes || echo no)"
    echo "mpi=${MPI_VERSION}"
    echo "mpicc=${CC_VERSION%%$'\n'*}"
    echo "built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "host=$(hostname)"
} > "${INSTALL_DIR}/install/osu-build.txt"
cd "${START_DIR}"
rm -rf "${BUILD_DIR}"

echo "==> Done. OMB ${OSU_VERSION} is installed in ${INSTALL_DIR}/install"
echo "    Build record: ${INSTALL_DIR}/install/osu-build.txt"
echo "    Build logs: ${INSTALL_DIR}/logs/${OSU_VERSION}-${STAMP}"
echo "    Run it with osu_benchmarks_openmpi.sbatch (README.md, \"Run\")"
