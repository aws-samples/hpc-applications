#!/usr/bin/env bash
#SBATCH --job-name=qe-ausurf112
#SBATCH --nodes=1
#SBATCH --exclusive
#SBATCH --time=01:00:00
#SBATCH --output=qe-ausurf112-%j.out
#SBATCH --error=qe-ausurf112-%j.err
#
# qe-benchmark.sbatch: run the AUSURF112 Quantum ESPRESSO benchmark (pw.x
# SCF, 112-atom gold surface) on x86_64 (AMD + Intel), on an AWS PCS (Slurm)
# cluster. x86 counterpart of Arm/qe-benchmark.sbatch: same methodology.
#
# AUSURF112 is a deliberately small, single-node example. Larger production
# jobs (more memory, and/or multi-node over EFA) may need slightly different
# best practices -- see "Runtime best practices" in the README.
#
# The one x86-specific rule: Intel instances expose 2 vCPUs per physical core
# (SMT). QE wants ONE MPI rank per PHYSICAL core, so the default rank count is
# derived from lscpu topology (cores, not vCPUs) AND the run requests
# --threads-per-core=1 so Slurm hands each rank a whole core instead of
# packing two ranks onto sibling threads. AMD and Graviton EC2 instances
# report ValidThreadsPerCore=[1] (no SMT to disable), so there physical cores
# == nproc and the flag is a no-op.
#
# Usage:
#   sbatch -p <x86-partition> x86/qe-benchmark.sbatch
#
# Overrides via --export=ALL,VAR=value:
#   QE_VERSION   QE release the build installed        (default: 7.5)
#   BASE_DIR     shared-filesystem root                (default: /fsx/qe)
#   QE_PW_PATH   absolute path to pw.x (skips auto-discovery)
#   NPOOL        k-point pools passed to pw.x -npool   (default: 1)
#   NTASKS       MPI ranks (default: all PHYSICAL cores on the node)

set -euo pipefail

QE_VERSION="${QE_VERSION:-7.5}"
BASE_DIR="${BASE_DIR:-/fsx/qe}"
NPOOL="${NPOOL:-1}"
BENCH=AUSURF112
BENCH_DIR="${BASE_DIR}/benchmarks/${BENCH}"

log() { printf '[qe-bench %s] %s\n' "$(date -Iseconds)" "$*"; }
die() { log "ERROR: $*"; exit 1; }

[[ "$(uname -m)" == x86_64 ]] || die "this launcher targets x86_64; host is $(uname -m) (see Arm/qe-benchmark.sbatch for Graviton)"

# --------------------------------------------------------------------------- #
# MPI + EFA runtime environment.
#
# pw.x was linked against the EFA-bundled Open MPI at /opt/amazon/openmpi, and
# `fi_info` lives under /opt/amazon/efa/bin -- neither is on the default PATH.
# For the small single-node AUSURF112 example this block is not strictly
# required (the Open MPI wrappers bake an RPATH into the binary, so the loader
# finds libmpi on its own, and the EFA probe below is only informational).
# It matters for anything larger: a multi-node run needs the libfabric EFA
# path, and a compute node that never ran the build may be missing the FFTW3 /
# OpenBLAS runtime the binary needs. Setting it explicitly also means the EFA
# probe reports the provider rather than whether fi_info happened to be on
# PATH.
# --------------------------------------------------------------------------- #
OMPI_ROOT=/opt/amazon/openmpi
EFA_ROOT=/opt/amazon/efa
for d in "${OMPI_ROOT}/bin" "${EFA_ROOT}/bin"; do
    [[ -d "$d" ]] && PATH="${d}:${PATH}"
done
export PATH
for d in "${OMPI_ROOT}/lib64" "${OMPI_ROOT}/lib" "${EFA_ROOT}/lib64" "${EFA_ROOT}/lib"; do
    [[ -d "$d" ]] && LD_LIBRARY_PATH="${d}:${LD_LIBRARY_PATH:-}"
done
export LD_LIBRARY_PATH

# --------------------------------------------------------------------------- #
# Resolve pw.x: explicit QE_PW_PATH wins; otherwise pick the install that
# matches this node's CPU family (built by x86/build_qe_x86.sbatch),
# accepting the documented fall-back targets for newer silicon.
# --------------------------------------------------------------------------- #
if [[ -z "${QE_PW_PATH:-}" ]]; then
    vendor=$(awk -F': ' '/vendor_id/{print $2; exit}' /proc/cpuinfo)
    family=$(awk -F': ' '/cpu family/{print $2; exit}' /proc/cpuinfo)
    model=$(awk -F': ' '/^model[^ ]*[[:space:]]*:/{print $2; exit}' /proc/cpuinfo)
    case "$vendor" in
        AuthenticAMD)
            case "$family" in
                25) candidates=(znver4) ;;
                26) candidates=(znver5 znver4) ;;          # znver4 runs on Zen 5
                *) die "unrecognised AMD family '$family'; set QE_PW_PATH explicitly" ;;
            esac ;;
        GenuineIntel)
            case "$model" in
                143)     candidates=(sapphirerapids) ;;
                173|174) candidates=(graniterapids sapphirerapids) ;;  # SPR build runs on GNR
                *) die "unrecognised Intel model '$model'; set QE_PW_PATH explicitly" ;;
            esac ;;
        *) die "unrecognised vendor '$vendor'" ;;
    esac
    for t in "${candidates[@]}"; do
        if [[ -x "${BASE_DIR}/${QE_VERSION}/gcc-${t}/bin/pw.x" ]]; then
            QE_PW_PATH="${BASE_DIR}/${QE_VERSION}/gcc-${t}/bin/pw.x"
            break
        fi
    done
fi
[[ -n "${QE_PW_PATH:-}" && -x "$QE_PW_PATH" ]] \
    || die "pw.x not found under ${BASE_DIR}/${QE_VERSION}/ for this CPU; run x86/build_qe_x86.sbatch first"
log "pw.x = ${QE_PW_PATH}"

# An executable bit is not enough: pw.x dynamically links FFTW3/OpenBLAS and
# the EFA Open MPI. The build node had all of them; a fresh compute node may
# not. Resolve them once here rather than failing 96 ranks deep with a bare
# "error while loading shared libraries".
if command -v ldd >/dev/null 2>&1 && ldd "$QE_PW_PATH" 2>/dev/null | grep -q 'not found'; then
    log "pw.x has unresolved shared libraries; installing the FFTW3/OpenBLAS runtime"
    sudo dnf install -y -q fftw-libs openblas 2>/dev/null \
        || sudo dnf install -y -q fftw openblas 2>/dev/null || true
    missing=$(ldd "$QE_PW_PATH" 2>/dev/null | awk '/not found/{print $1}' | paste -sd, -)
    [[ -z "$missing" ]] || die "pw.x still missing shared libraries: ${missing}"
    log "shared libraries resolved"
fi

# --------------------------------------------------------------------------- #
# Fetch + cache the AUSURF112 deck (shared with the Arm launcher).
# --------------------------------------------------------------------------- #
QEF_RAW=https://raw.githubusercontent.com/QEF/benchmarks/master/AUSURF112
mkdir -p "${BENCH_DIR}"
for f in ausurf.in Au.pbe-nd-van.UPF; do
    if [[ ! -s "${BENCH_DIR}/${f}" ]]; then
        log "fetching ${f}"
        curl -fsSL --retry 5 -o "${BENCH_DIR}/${f}" "${QEF_RAW}/${f}" \
            || die "could not fetch ${f} from ${QEF_RAW}"
    fi
done

# --------------------------------------------------------------------------- #
# Stage the run: results on shared storage, QE scratch on node-local /tmp.
# --------------------------------------------------------------------------- #
RUN_DIR="${BASE_DIR}/Run/${BENCH}-${SLURM_JOB_ID:-manual-$$}"
[[ ! -e "${RUN_DIR}" ]] || die "run dir ${RUN_DIR} already exists; refusing to overwrite"
mkdir -p "${RUN_DIR}"
cd "${RUN_DIR}"
SCRATCH=/tmp/qe-scratch-${SLURM_JOB_ID:-$$}
mkdir -p "${SCRATCH}"

sed -e "s|pseudo_dir *=.*|pseudo_dir = '${BENCH_DIR}'|" \
    -e "s|outdir *=.*|outdir = '${SCRATCH}'|" \
    -e "s|disk_io *=.*|disk_io = 'none'|" \
    "${BENCH_DIR}/ausurf.in" > ausurf.in
grep -q "disk_io" ausurf.in || sed -i "/&CONTROL/a\\  disk_io = 'none'" ausurf.in

# --------------------------------------------------------------------------- #
# Node preparation: EFA provider, fork safety, THP, page cache.
# --------------------------------------------------------------------------- #
export FI_EFA_FORK_SAFE=1
if fi_info -p efa >/dev/null 2>&1; then
    export FI_PROVIDER="${FI_PROVIDER:-efa}"
    log "EFA libfabric provider present (FI_PROVIDER=${FI_PROVIDER})"
elif [[ -n "${FI_PROVIDER:-}" ]]; then
    log "WARNING: fi_info reports no EFA provider, but FI_PROVIDER=${FI_PROVIDER} was set explicitly; honouring it"
else
    # Deliberately leave FI_PROVIDER unset: pinning it to 'efa' on a node with
    # no EFA device makes libfabric fail to find a provider instead of falling
    # back. Single-node runs are unaffected either way.
    log "WARNING: EFA provider not found; leaving FI_PROVIDER unset so libfabric can pick a fallback. Single-node runs are unaffected; multi-node runs will use TCP"
fi

echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled >/dev/null 2>&1 || true
sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true

# --------------------------------------------------------------------------- #
# Rank layout: one MPI rank per PHYSICAL core (not per vCPU/hyper-thread).
# --------------------------------------------------------------------------- #
# Unique physical-core IDs from lscpu topology (counts cores once even
# when SMT exposes 2 CPUs per core); fall back to nproc if lscpu fails.
PHYS_CORES=$(lscpu -p=CORE 2>/dev/null | grep -v '^#' | sort -un | wc -l | xargs)
[[ "${PHYS_CORES:-0}" -ge 1 ]] || PHYS_CORES=$(nproc)
THREADS_PER_CORE=$(( $(nproc) / PHYS_CORES )); (( THREADS_PER_CORE >= 1 )) || THREADS_PER_CORE=1
NTASKS="${NTASKS:-$PHYS_CORES}"
export OMP_NUM_THREADS=1
if (( NTASKS % NPOOL != 0 )); then
    log "npool ${NPOOL} does not divide ntasks ${NTASKS}; using npool=1"
    NPOOL=1
fi
# --threads-per-core=1 is what actually delivers one rank per PHYSICAL core.
# A rank count derived from lscpu is not sufficient on its own: with SMT
# enabled, --cpus-per-task=1 asks for one *thread*, so Slurm may pack two
# ranks onto the two siblings of a single core and leave half the cores idle.
# The flag is a no-op where there is no SMT to disable (Graviton, AMD on EC2).
log "layout: ${NTASKS} MPI ranks x 1 thread on ${PHYS_CORES} physical cores ($(nproc) vCPUs, ${THREADS_PER_CORE} thread(s)/core), npool=${NPOOL}, --threads-per-core=1 --cpu-bind=cores"

# --------------------------------------------------------------------------- #
# Run.
# --------------------------------------------------------------------------- #
START=$(date +%s)
srun --mpi=pmix --ntasks="${NTASKS}" --cpus-per-task=1 \
    --threads-per-core=1 --cpu-bind=cores \
    "${QE_PW_PATH}" -npool "${NPOOL}" -inp ausurf.in \
    > ausurf.out 2> ausurf.err
WALL=$(( $(date +%s) - START ))

# --------------------------------------------------------------------------- #
# Results: require the final JOB DONE marker, then report QE's own PWSCF
# wall-clock alongside the job wall time.
#
# The success marker is JOB DONE, NOT "convergence has been achieved": the
# upstream AUSURF112 deck caps SCF at electron_maxstep=2 (a fixed-work
# benchmark), so non-convergence is the expected, correct outcome and that
# string cannot appear by design.
# --------------------------------------------------------------------------- #
grep -q "JOB DONE" ausurf.out \
    || die "pw.x did not reach JOB DONE; see ${RUN_DIR}/ausurf.out"
# `|| true`: a grep miss must not abort the script under `set -o pipefail`,
# otherwise the results block below (and the job wall time already measured)
# would be lost and the ${PWSCF_WALL:-unavailable} fallback could never fire.
PWSCF_WALL=$(grep -E "^ *PWSCF *:" ausurf.out | tail -1 | sed -E 's/.*CPU *//; s/ *WALL.*//' | xargs || true)

echo "==================== QE BENCHMARK RESULT ===================="
echo " benchmark        : ${BENCH} (112-atom Au surface, SCF)"
echo " pw.x             : ${QE_PW_PATH}"
echo " instance         : $(curl -fsSL --max-time 3 -H "X-aws-ec2-metadata-token: $(curl -fsSL --max-time 3 -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' http://169.254.169.254/latest/api/token 2>/dev/null)" http://169.254.169.254/latest/meta-data/instance-type 2>/dev/null || echo unknown)"
echo " ranks x threads  : ${NTASKS} x 1 (npool=${NPOOL})"
echo " job wall (s)     : ${WALL}"
echo " PWSCF wall       : ${PWSCF_WALL:-unavailable}"
echo " output           : ${RUN_DIR}/ausurf.out"
echo "=============================================================="

rm -rf "${SCRATCH}"
