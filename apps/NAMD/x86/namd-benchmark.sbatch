#!/bin/bash
#SBATCH --job-name=namd-x86
#SBATCH --constraint=hpc8a.96xlarge
#SBATCH --partition=hpc8a
#SBATCH --nodes=1
#SBATCH --exclusive
#SBATCH --output=namd-x86-%j.out
#
# Run a standard NAMD benchmark (ApoA1 / STMV) on x86 HPC instances over EFA.
#
# NAMD is built on Charm++ (MPI/SMP backend over the system OpenMPI). This
# launcher uses mpirun to start one process per node + worker threads, so
# inter-node traffic rides EFA through OpenMPI's libfabric provider. Single-node
# runs use the same binary with a single process.
#
# Performance metric: NAMD prints `Info: Benchmark time: ... <days/ns> days/ns`.
# The launcher extracts days/ns from the LAST such line and reports
# ns/day = 1 / days_per_ns, plus WallClock.
#
# Override via --export=ALL,...:
#   NAMD_ENV    env script from the build (auto-discovered under /fsx/namd if unset)
#   MODEL       ApoA1 | STMV                       (default ApoA1)
#   TIMESTEPS   numsteps override, 1..10000000     (default: model default)
#   PPN         worker threads (PEs) per node      (default: cores/node - 1)
#   BASE_DIR    run-output root (absolute path)    (default /fsx/namd)

set -uo pipefail

NAMD_ENV="${NAMD_ENV:-}"
MODEL="${MODEL:-ApoA1}"
TIMESTEPS="${TIMESTEPS:-}"
PPN="${PPN:-}"
BASE_DIR="${BASE_DIR:-/fsx/namd}"

fail() { echo "ERROR: $*" >&2; exit 1; }

# --- Validate MODEL ------------------------------------------------------
case "${MODEL}" in
  ApoA1|STMV) ;;
  *) fail "MODEL='${MODEL}' invalid (supported: ApoA1, STMV)" ;;
esac

# --- Validate overrides --------------------------------------------------
case "${BASE_DIR}" in /*) ;; *) fail "BASE_DIR must be an absolute path (got '${BASE_DIR}')" ;; esac
if [ -n "${TIMESTEPS}" ]; then
  [[ "${TIMESTEPS}" =~ ^[0-9]+$ ]] && [ "${TIMESTEPS}" -ge 1 ] && [ "${TIMESTEPS}" -le 10000000 ] \
    || fail "TIMESTEPS='${TIMESTEPS}' invalid (integer 1..10000000)"
fi
if [ -n "${PPN}" ]; then
  [[ "${PPN}" =~ ^[0-9]+$ ]] && [ "${PPN}" -ge 1 ] && [ "${PPN}" -le 192 ] \
    || fail "PPN='${PPN}' invalid (integer 1..192)"
fi

# --- Resolve the env script ----------------------------------------------
if [ -z "${NAMD_ENV}" ]; then
  for e in "${BASE_DIR}"/x86_64/*/namd-*-x86-env.sh; do [ -f "$e" ] && NAMD_ENV="$e"; done
  [ -n "${NAMD_ENV}" ] || fail "no NAMD env script found under ${BASE_DIR}/x86_64/*/ — build NAMD first or set NAMD_ENV"
fi
[ -f "${NAMD_ENV}" ] && [ -r "${NAMD_ENV}" ] || fail "NAMD_ENV not a readable file: ${NAMD_ENV}"
# shellcheck source=/dev/null
source "${NAMD_ENV}"
NAMD3="$(command -v namd3 || true)"
[ -x "${NAMD3}" ] || fail "namd3 not on PATH after sourcing ${NAMD_ENV}"
command -v mpirun >/dev/null 2>&1 || fail "mpirun not on PATH after sourcing ${NAMD_ENV} (env script should load the OpenMPI module)"

NODES="${SLURM_JOB_NUM_NODES:-1}"
CORES_PER_NODE="${SLURM_CPUS_ON_NODE:-$(nproc)}"
# SMP: one process per node, 1 comm thread + PPN worker threads. Reserve a core
# for the communication thread by default.
[ -n "${PPN}" ] || PPN=$(( CORES_PER_NODE > 1 ? CORES_PER_NODE - 1 : 1 ))
# Instance type via IMDSv2 (token-authenticated), falling back to "unknown".
IMDS_TOKEN="$(curl -s --max-time 2 -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || true)"
INSTANCE_TYPE="$(curl -s --max-time 2 ${IMDS_TOKEN:+-H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}"} \
  http://169.254.169.254/latest/meta-data/instance-type 2>/dev/null || echo unknown)"
[ -n "${INSTANCE_TYPE}" ] || INSTANCE_TYPE="unknown"

echo "================================================================================"
echo "NAMD benchmark — $(date)"
echo "  model=${MODEL}  nodes=${NODES} x ${INSTANCE_TYPE}  ppn=${PPN}  cores/node=${CORES_PER_NODE}"
echo "  namd3=${NAMD3}   CHARM_ARCH=${CHARM_ARCH:-unknown}"
echo "================================================================================"

# --- EFA verification (multi-node) ---------------------------------------
echo "=== EFA / Charm++ backend sanity ==="
if [ "${NODES}" -gt 1 ]; then
  fi_info -p efa -t FI_EP_RDM > /tmp/fi_efa.$$ 2>&1
  rc=$?
  grep -E "provider|fabric|domain|nic|version" /tmp/fi_efa.$$ | head -10 || true
  cat /tmp/fi_efa.$$; rm -f /tmp/fi_efa.$$
  [ "${rc}" -eq 0 ] || fail "fi_info -p efa failed (rc=${rc}); EFA unavailable for multi-node run"
  export FI_PROVIDER=efa FI_EFA_USE_DEVICE_RDMA=1 RDMAV_FORK_SAFE=1
else
  echo "single node — local SMP run, EFA not required"
fi

# --- Fetch + cache the benchmark deck ------------------------------------
declare -A DECK_URL=(
  [ApoA1]="https://www.ks.uiuc.edu/Research/namd/utilities/apoa1.tar.gz"
  [STMV]="https://www.ks.uiuc.edu/Research/namd/utilities/stmv.tar.gz"
)
declare -A DECK_CONF=( [ApoA1]="apoa1.namd" [STMV]="stmv.namd" )
CACHE_DIR="${BASE_DIR}/benchmarks/${MODEL}"
CONF="${DECK_CONF[${MODEL}]}"
if [ ! -s "${CACHE_DIR}/${CONF}" ]; then
  echo "==> fetching ${MODEL} deck from ${DECK_URL[${MODEL}]}"
  mkdir -p "${CACHE_DIR}"
  tmp="$(mktemp -d)"
  if curl -fsSL --max-time 600 --retry 3 -o "${tmp}/deck.tar.gz" "${DECK_URL[${MODEL}]}"; then
    tar xzf "${tmp}/deck.tar.gz" -C "${tmp}"
    # decks extract into a subdir (apoa1/ or stmv/); flatten into the cache
    find "${tmp}" -type f -exec cp -n {} "${CACHE_DIR}/" \;
    rm -rf "${tmp}"
  else
    rm -rf "${tmp}" "${CACHE_DIR}"
    fail "failed to download ${MODEL} deck from ${DECK_URL[${MODEL}]} after retries"
  fi
fi
[ -s "${CACHE_DIR}/${CONF}" ] || fail "benchmark config ${CONF} missing in ${CACHE_DIR} after fetch"
echo "deck: ${CACHE_DIR}/${CONF}"

# --- Unique run directory ------------------------------------------------
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
WORK="${BASE_DIR}/Run/${SLURM_JOB_ID:-local}-${MODEL}-${SLURM_CLUSTER_NAME:-cluster}-${NODES}x${INSTANCE_TYPE}-${PPN}ppn-${STAMP}"
[ -e "${WORK}" ] && fail "run directory already exists: ${WORK}"
mkdir -p "${WORK}"
cp "${CACHE_DIR}"/* "${WORK}/" 2>/dev/null || true
cd "${WORK}" || fail "cannot cd into ${WORK}"

# --- Build the per-run config (override numsteps, ensure timing output) ---
RUNCONF="run-${MODEL}.namd"
cp "${CONF}" "${RUNCONF}"
if [ -n "${TIMESTEPS}" ]; then
  # Override numsteps / final 'run N' so the benchmark length is deterministic.
  sed -i -E "s/^[[:space:]]*numsteps[[:space:]]+[0-9]+/numsteps ${TIMESTEPS}/I" "${RUNCONF}"
  sed -i -E "s/^[[:space:]]*run[[:space:]]+[0-9]+/run ${TIMESTEPS}/I" "${RUNCONF}"
fi
grep -qiE "^[[:space:]]*outputTiming" "${RUNCONF}" || echo "outputTiming 20" >> "${RUNCONF}"

# --- Drop page caches + enable THP on all nodes --------------------------
echo "==> dropping page caches + enabling THP on all nodes (best-effort)"
srun --ntasks="${NODES}" --ntasks-per-node=1 bash -c \
  'sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true; echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled >/dev/null 2>&1 || true'

# --- Launch NAMD ---------------------------------------------------------
# Charm++ MPI/SMP build: launch with mpirun, one process per node
# (--map-by ppr:1:node), each spawning PPN worker threads (+ppn) plus a comm
# thread. OpenMPI carries the traffic over EFA via its libfabric provider.
echo "==> launching NAMD: ${NODES} node(s) x 1 process x ${PPN} PEs"
MPI_ARGS=( -np "${NODES}" --map-by ppr:1:node --bind-to none )
if [ "${NODES}" -gt 1 ]; then
  MPI_ARGS+=( --mca pml cm --mca mtl ofi -x FI_PROVIDER -x FI_EFA_USE_DEVICE_RDMA -x RDMAV_FORK_SAFE )
fi
set -o pipefail
mpirun "${MPI_ARGS[@]}" \
     "${NAMD3}" +ppn "${PPN}" +setcpuaffinity "${RUNCONF}" 2>&1 | tee namd.out
rc=${PIPESTATUS[0]}
[ "${rc}" -eq 0 ] || fail "NAMD run exited non-zero (rc=${rc}); see ${WORK}/namd.out"

# --- Parse performance ---------------------------------------------------
# Take the days/ns value from the LAST 'Benchmark time:' line.
DAYS_PER_NS="$(awk '/Benchmark time:/ { for (i=1;i<=NF;i++) if ($i=="days/ns") print $(i-1) }' namd.out | tail -1)"
WALLCLOCK="$(awk '/^WallClock:/ {print $2}' namd.out | tail -1)"
[ -n "${DAYS_PER_NS}" ] || fail "could not parse 'days/ns' from NAMD output (${WORK}/namd.out)"
NS_PER_DAY="$(awk "BEGIN{ if (${DAYS_PER_NS}+0>0) printf \"%.4f\", 1.0/${DAYS_PER_NS}; else print \"0\" }")"

echo ""
echo "================================================================================"
echo "NAMD benchmark results"
echo "  Model:       ${MODEL}"
echo "  Nodes:       ${NODES} x ${INSTANCE_TYPE}   (${PPN} PEs/node)"
echo "  days/ns:     ${DAYS_PER_NS}"
echo "  ns/day:      ${NS_PER_DAY}"
echo "  WallClock:   ${WALLCLOCK:-n/a}s"
echo "  Workdir:     ${WORK}"
echo "================================================================================"
echo "NAMDRESULT model=${MODEL} nodes=${NODES} ppn=${PPN} instance=${INSTANCE_TYPE} days_per_ns=${DAYS_PER_NS} ns_per_day=${NS_PER_DAY} wallclock=${WALLCLOCK:-NA}"
