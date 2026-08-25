#!/usr/bin/env bash
#SBATCH --job-name=qe-ausurf112
#SBATCH --nodes=1
#SBATCH --exclusive
#SBATCH --time=01:00:00
#SBATCH --output=qe-ausurf112-%j.out
#SBATCH --error=qe-ausurf112-%j.err
#
# qe-benchmark.sbatch: run the AUSURF112 Quantum ESPRESSO benchmark (pw.x
# SCF, 112-atom gold surface) on AWS Graviton, on an AWS PCS (Slurm) cluster.
#
# AUSURF112 is a deliberately small, single-node example: it completes in
# minutes and fits in any instance listed in the README. Larger production
# jobs (more memory, and/or multi-node over EFA) may need slightly different
# best practices -- see "Runtime best practices" in the README.
#
# The launcher:
#   - auto-selects the pw.x built for THIS node's Graviton generation
#     (matching build_qe_arm.sbatch's install layout),
#   - fetches + caches the AUSURF112 input deck on the shared filesystem,
#   - keeps QE scratch (outdir) on node-local storage (never on NFS),
#   - runs pure-MPI, one rank per physical core, pinned with --cpu-bind=cores,
#   - enables Transparent Huge Pages and verifies the EFA libfabric provider,
#   - extracts the PWSCF wall time and prints a results block.
#
# Usage:
#   sbatch -p <graviton-partition> Arm/qe-benchmark.sbatch
#   sbatch -p <graviton-partition> --ntasks-per-node=64 Arm/qe-benchmark.sbatch
#
# Overrides via --export=ALL,VAR=value:
#   QE_VERSION   QE release the build installed        (default: 7.5)
#   BASE_DIR     shared-filesystem root                (default: /fsx/qe)
#   QE_PW_PATH   absolute path to pw.x (skips auto-discovery)
#   NPOOL        k-point pools passed to pw.x -npool   (default: 1)
#   NTASKS       MPI ranks (default: all physical cores on the node)

set -euo pipefail

QE_VERSION="${QE_VERSION:-7.5}"
BASE_DIR="${BASE_DIR:-/fsx/qe}"
NPOOL="${NPOOL:-1}"
BENCH=AUSURF112
BENCH_DIR="${BASE_DIR}/benchmarks/${BENCH}"

log() { printf '[qe-bench %s] %s\n' "$(date -Iseconds)" "$*"; }
die() { log "ERROR: $*"; exit 1; }

[[ "$(uname -m)" == aarch64 ]] || die "this launcher targets Graviton (aarch64); host is $(uname -m)"

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
# matches this node's Graviton generation (built by build_qe_arm.sbatch).
# --------------------------------------------------------------------------- #
if [[ -z "${QE_PW_PATH:-}" ]]; then
    cpu_part=$(awk '/CPU part/{print $4; exit}' /proc/cpuinfo)
    # Candidate lists run newest-first. The Neoverse ISA is backward
    # compatible, so a binary built for an older generation runs correctly on a
    # newer one (just less tuned) and is a valid second choice; the reverse is
    # not true, which is why an older generation lists only itself.
    case "$cpu_part" in
        0xd0c) candidates=(graviton2) ;;
        0xd40) candidates=(graviton3 graviton2) ;;
        0xd4f) candidates=(graviton4 graviton3 graviton2) ;;
        0xd84) candidates=(graviton5 graviton4 graviton3 graviton2) ;;
        *) die "unrecognised Arm CPU part '$cpu_part'; set QE_PW_PATH explicitly" ;;
    esac
    log "cpu: Arm CPU part ${cpu_part} -> ${candidates[0]}"
    for t in "${candidates[@]}"; do
        if [[ -x "${BASE_DIR}/${QE_VERSION}/gcc-${t}/bin/pw.x" ]]; then
            QE_PW_PATH="${BASE_DIR}/${QE_VERSION}/gcc-${t}/bin/pw.x"
            [[ "$t" == "${candidates[0]}" ]] \
                || log "WARNING: no ${candidates[0]} build found; using the ${t} build, which runs correctly here but is not tuned for this generation"
            break
        fi
    done
fi
[[ -n "${QE_PW_PATH:-}" ]] \
    || die "pw.x not found under ${BASE_DIR}/${QE_VERSION}/ for this Graviton generation; run Arm/build_qe_arm.sbatch on this node first"
[[ -x "$QE_PW_PATH" ]] \
    || die "pw.x not found/executable at ${QE_PW_PATH}; run Arm/build_qe_arm.sbatch on this generation first"

# Require the build manifest next to the binary. The build script writes it
# only AFTER pw.x passes its startup-banner check, so its presence is the
# build's own attestation that the binary ran at least once. Without this
# check, an install whose banner check failed -- binary present, manifest
# deliberately absent -- would be benchmarked anyway.
QE_MANIFEST="$(dirname "$(dirname "$QE_PW_PATH")")/build-manifest.json"
if [[ "${QE_SKIP_MANIFEST_CHECK:-0}" == 1 ]]; then
    log "WARNING: QE_SKIP_MANIFEST_CHECK=1 -- not requiring build-manifest.json beside pw.x"
else
    [[ -f "$QE_MANIFEST" ]] \
        || die "no build-manifest.json beside ${QE_PW_PATH}. The build never passed its banner check, or the install is incomplete; rebuild with Arm/build_qe_arm.sbatch. Set QE_SKIP_MANIFEST_CHECK=1 to run anyway."
fi
log "pw.x = ${QE_PW_PATH}"
if [[ -f "$QE_MANIFEST" ]] && command -v jq >/dev/null 2>&1; then
    log "build: $(jq -r '"target=\(.target) flags=\"\(.opt_flags)\" mcpu_fallback=\(.mcpu_fallback // "n/a") qe=\(.qe_version)"' "$QE_MANIFEST" 2>/dev/null || echo 'manifest unreadable')"
fi

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
# Fetch + cache the AUSURF112 deck (input + Au ultrasoft pseudopotential)
# from the upstream QEF benchmark repository. Cached on the shared
# filesystem so only the first job on the cluster hits the network.
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
# Rank layout: pure MPI, one rank per physical core (Graviton has no SMT,
# so nproc == physical cores), pinned to cores. OMP_NUM_THREADS=1 keeps
# OpenBLAS/FFTW from oversubscribing.
# --------------------------------------------------------------------------- #
NTASKS="${NTASKS:-${SLURM_NTASKS_PER_NODE:-$(nproc)}}"
export OMP_NUM_THREADS=1
if (( NTASKS % NPOOL != 0 )); then
    log "npool ${NPOOL} does not divide ntasks ${NTASKS}; using npool=1"
    NPOOL=1
fi
log "layout: ${NTASKS} MPI ranks x 1 thread, npool=${NPOOL}, --cpu-bind=cores"

# --------------------------------------------------------------------------- #
# Stage the run: unique output dir on shared storage for logs/results, but
# QE scratch (outdir, wavefunctions) on NODE-LOCAL /tmp. Putting outdir on
# a network filesystem serialises the run on small-file I/O.
# --------------------------------------------------------------------------- #
# Instance type for the run-directory name (matches the other apps in this repo).
IMDS_TOKEN=$(curl -fsSL --max-time 3 -X PUT \
    -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' \
    http://169.254.169.254/latest/api/token 2>/dev/null || true)
INSTANCE_TYPE=$(curl -fsSL --max-time 3 \
    -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" \
    http://169.254.169.254/latest/meta-data/instance-type 2>/dev/null || echo unknown)

# Run-directory layout follows the other apps here:
#   <base>/Run/<jobname>/<cluster>/<jobid>-<nodes>x<instance>-<ntasks>-<date>
# The ${SLURM_RESTART_COUNT} suffix matters on Spot: a requeued job keeps its
# JobId, so a bare jobid-keyed collision guard would refuse to start the very
# retry the scheduler just granted.
RUN_TAG="${SLURM_JOB_ID:-manual-$$}"
[[ "${SLURM_RESTART_COUNT:-0}" == 0 ]] || RUN_TAG="${RUN_TAG}r${SLURM_RESTART_COUNT}"
RUN_DIR="${BASE_DIR}/Run/${SLURM_JOB_NAME:-${BENCH}}/${SLURM_CLUSTER_NAME:-cluster}/${RUN_TAG}-${SLURM_JOB_NUM_NODES:-1}x${INSTANCE_TYPE}-${NTASKS}-$(date '+%d-%m-%Y-%H-%M')"
[[ ! -e "${RUN_DIR}" ]] || die "run dir ${RUN_DIR} already exists; refusing to overwrite"
mkdir -p "${RUN_DIR}"
cd "${RUN_DIR}"
# Keep a copy of the launch script beside its results (repo convention).
cp "$0" . 2>/dev/null || true

# Node-local QE scratch, removed on ANY exit (including failure) rather than
# only on the success path.
SCRATCH=/tmp/qe-scratch-${SLURM_JOB_ID:-$$}.${SLURM_RESTART_COUNT:-0}
mkdir -p "${SCRATCH}"
trap 'rm -rf "${SCRATCH}"' EXIT

# Rewrite the deck's control paths: pseudo_dir -> the shared cache,
# outdir -> node-local scratch, disk_io -> 'none' (SCF benchmark; no
# restart files, no per-step wavefunction writes).
sed -e "s|pseudo_dir *=.*|pseudo_dir = '${BENCH_DIR}'|" \
    -e "s|outdir *=.*|outdir = '${SCRATCH}'|" \
    -e "s|disk_io *=.*|disk_io = 'none'|" \
    "${BENCH_DIR}/ausurf.in" > ausurf.in
grep -q "disk_io" ausurf.in || sed -i "/&CONTROL/a\\  disk_io = 'none'" ausurf.in

# --------------------------------------------------------------------------- #
# Node preparation: EFA provider, fork safety, THP, page cache.
# --------------------------------------------------------------------------- #
export FI_EFA_FORK_SAFE=1
# libfabric's shared-memory address-vector must be sized for the rank count
# when there are more than 128 ranks on a node -- which one-rank-per-core hits
# on any 192-core instance (hpc7a/hpc8a, c8g/m8g/r8g.48xlarge, c9g.48xlarge).
# Same guard the Fluent launchers in this repo use.
if (( ${NTASKS:-0} > 128 )); then
    export FI_EFA_SHM_AV_SIZE="${NTASKS}"
    log "FI_EFA_SHM_AV_SIZE=${FI_EFA_SHM_AV_SIZE} (>128 ranks/node)"
fi
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

# QE allocates very large arrays; THP 'always' reduces TLB misses.
echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled >/dev/null 2>&1 || true
# Cold page cache for a reproducible measurement.
sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true

# --------------------------------------------------------------------------- #
# Run.
# --------------------------------------------------------------------------- #
START=$(date +%s)
srun --mpi=pmix --ntasks="${NTASKS}" --cpus-per-task=1 --cpu-bind=cores \
    "${QE_PW_PATH}" -npool "${NPOOL}" -inp ausurf.in \
    > ausurf.out 2> ausurf.err
WALL=$(( $(date +%s) - START ))

# Other launchers in this repo tee the solver log to output.$SLURM_JOBID.out.
# Piping srun through tee here would put tee in the pipeline's exit path and
# merge the stderr stream that the JOB DONE / PWSCF-timer parsing below keeps
# separate, so the run redirects instead and the conventional name is provided
# as a link to the same bytes.
ln -sf ausurf.out "output.${SLURM_JOB_ID:-manual}.out" 2>/dev/null || true

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
echo " instance         : ${INSTANCE_TYPE}"   # resolved once, at run-dir staging
echo " ranks x threads  : ${NTASKS} x 1 (npool=${NPOOL})"
echo " job wall (s)     : ${WALL}"
echo " PWSCF wall       : ${PWSCF_WALL:-unavailable}"
echo " output           : ${RUN_DIR}/ausurf.out"
echo "=============================================================="

