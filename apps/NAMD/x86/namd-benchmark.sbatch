#!/bin/bash
#SBATCH --job-name=namd-x86
#SBATCH --constraint=hpc8a.96xlarge
#SBATCH --partition=hpc8a
#SBATCH --nodes=1
#SBATCH --exclusive
#SBATCH --time=02:00:00
#SBATCH --output=namd-x86-%j.out
#
# Run a standard NAMD benchmark (ApoA1 / F1-ATPase / STMV) on x86 HPC instances
# over EFA.
#
# NAMD is built on Charm++ (MPI/SMP backend over the system OpenMPI). This
# launcher uses mpirun to start PROCS_PER_NODE processes per node (default 1),
# each with PPN worker threads and a communication thread, so inter-node traffic
# rides EFA through OpenMPI's libfabric provider. Single-node runs use the same
# binary.
#
# Performance metric: NAMD prints `Info: Benchmark time: ... <days/ns> days/ns`.
# The launcher extracts days/ns from the LAST such line and reports
# ns/day = 1 / days_per_ns, plus WallClock. The job ends with NAMD's exit
# status when NAMD fails; when NAMD exits 0, a result is reported only from a
# complete run (namd.out ends with NAMD's WallClock: line, and the last
# Benchmark time line gives a positive days/ns), and otherwise the job ends
# with status 1. A complete run is then recorded with the contribution
# recorder, apps/NAMD/dynamodb/record-benchmark.sh (see the end of this script).
#
# Override via --export=ALL,...:
#   NAMD_ENV    env script from the build (default: the build of this node's
#               instance family under ${BASE_DIR}/x86_64/, see below)
#   MODEL       ApoA1 | ATPase | STMV              (default ApoA1)
#   TIMESTEPS   the run's numsteps, 1..10000000    (default 1000: six
#               Benchmark time lines, see below)
#   PPN         worker threads (PEs) per process   (default: the process's
#               cores - 1; with one process per node on hpc8a.96xlarge and
#               hpc7a.96xlarge 23, 47, 71, 95, 119, 143, 167, 191 or 192, see
#               below)
#   PROCS_PER_NODE  NAMD processes per node, P     (default 1; see below)
#   NAMD_EXTRA_ARGS namd3 options added before the config, each a +word
#               (for example +notiles)
#   BASE_DIR    run-output root (absolute path)    (default /fsx/namd)
#   SOURCE, DYNAMODB_RECORDER   the contribution recorder's tag and path (see
#               the end of this script)

set -uo pipefail

NAMD_ENV="${NAMD_ENV:-}"
MODEL="${MODEL:-ApoA1}"
TIMESTEPS="${TIMESTEPS:-1000}"
PPN="${PPN:-}"
PROCS_PER_NODE="${PROCS_PER_NODE:-1}"
NAMD_EXTRA_ARGS="${NAMD_EXTRA_ARGS:-}"
BASE_DIR="${BASE_DIR:-/fsx/namd}"

fail() { echo "ERROR: $*" >&2; exit 1; }

# --- Validate MODEL ------------------------------------------------------
case "${MODEL}" in
  ApoA1|ATPase|STMV) ;;
  *) fail "MODEL='${MODEL}' invalid (supported: ApoA1, ATPase, STMV)" ;;
esac

# --- Validate overrides --------------------------------------------------
case "${BASE_DIR}" in /*) ;; *) fail "BASE_DIR must be an absolute path (got '${BASE_DIR}')" ;; esac
[[ "${TIMESTEPS}" =~ ^[0-9]+$ ]] && [ "${TIMESTEPS}" -ge 1 ] && [ "${TIMESTEPS}" -le 10000000 ] \
  || fail "TIMESTEPS='${TIMESTEPS}' invalid (integer 1..10000000)"
if [ -n "${PPN}" ]; then
  [[ "${PPN}" =~ ^[1-9][0-9]*$ ]] && [ "${PPN}" -le 192 ] \
    || fail "PPN='${PPN}' invalid (integer 1..192)"
fi
# NAMD_EXTRA_ARGS: namd3 options, each a + and a name (+notiles, for example);
# the launcher sets +ppn, +setcpuaffinity, +pemap and +commap itself.
read -r -a EXTRA_ARGS <<< "${NAMD_EXTRA_ARGS}"
for w in ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}; do
  [[ "${w}" =~ ^\+[A-Za-z][A-Za-z0-9_]*$ ]] \
    || fail "NAMD_EXTRA_ARGS: '${w}' is not a namd3 option word (a + and a name of letters, digits and _)"
  case "${w}" in
    +ppn|+setcpuaffinity|+pemap|+commap) fail "NAMD_EXTRA_ARGS: ${w} is set by the launcher" ;;
  esac
done

NODES="${SLURM_JOB_NUM_NODES:-1}"
CORES_PER_NODE="${SLURM_CPUS_ON_NODE:-$(nproc)}"
# SMP: PROCS_PER_NODE (P) processes per node, each with G = cores / P cores of
# its own: a communication thread and PPN = G - 1 worker threads by default.
# More than one process per node needs a full node: PPN is then G - 1.
P="${PROCS_PER_NODE}"
[[ "${P}" =~ ^[1-9][0-9]*$ ]] && (( P <= CORES_PER_NODE / 2 && CORES_PER_NODE % P == 0 )) \
  || fail "PROCS_PER_NODE='${P}' invalid (an integer that divides the node's ${CORES_PER_NODE} cores and leaves each process at least 2)"
G=$(( CORES_PER_NODE / P ))
[ -n "${PPN}" ] || PPN=$(( G > 1 ? G - 1 : 1 ))
if (( P > 1 && PPN != G - 1 )); then
  fail "PPN=${PPN} with PROCS_PER_NODE=${P}: each process has ${G} cores, so PPN is $(( G - 1 )) (a core for its communication thread); leave PPN unset"
fi
# Instance metadata (IMDSv2). Each read gives up after a few seconds and never
# ends the job: no answer, an HTTP error or an answer that is not an instance
# type name (an error page, for example; the name is tested in the C locale)
# leaves INSTANCE_TYPE empty, and the banner, the run directory and the results
# then name the type "unknown".
IMDS_CURL=(curl -fs --connect-timeout 2 --max-time 5)
TOKEN=$("${IMDS_CURL[@]}" -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600") || TOKEN=""
INSTANCE_TYPE=$("${IMDS_CURL[@]}" -H "X-aws-ec2-metadata-token: ${TOKEN}" \
  http://169.254.169.254/latest/meta-data/instance-type) || INSTANCE_TYPE=""
( LC_ALL=C; [[ "${INSTANCE_TYPE}" =~ ^[a-z][a-z0-9-]*\.[a-z0-9-]+$ ]] ) || INSTANCE_TYPE=""

# --- Resolve the build -----------------------------------------------------
# build_namd_x86.sbatch installs each TARGET_CPU under
# ${BASE_DIR}/x86_64/<version>-<target>/. With NAMD_ENV unset, the launcher takes
# the build of this node's instance family (the highest version), else the only
# build there is, with a NOTE; with several builds and none for this family, it
# stops: set NAMD_ENV.
FAMILY="${INSTANCE_TYPE%%.*}"
if [ -z "${NAMD_ENV}" ]; then
  if [ -n "${FAMILY}" ]; then
    NAMD_ENV="$(printf '%s\n' "${BASE_DIR}"/x86_64/*-"${FAMILY}"/namd-*-x86-env.sh | sort -V | tail -1)"
    [ -f "${NAMD_ENV}" ] || NAMD_ENV=""
  fi
  if [ -z "${NAMD_ENV}" ]; then
    BUILDS=()
    for e in "${BASE_DIR}"/x86_64/*/namd-*-x86-env.sh; do [ -f "$e" ] && BUILDS+=("$e"); done
    case "${#BUILDS[@]}" in
      0) fail "no NAMD env script found under ${BASE_DIR}/x86_64/*/ — build NAMD first or set NAMD_ENV" ;;
      1) NAMD_ENV="${BUILDS[0]}"
         echo "NOTE: no build for ${FAMILY:-an unknown instance type} under ${BASE_DIR}/x86_64/; using the only build there, ${NAMD_ENV%/*}" >&2 ;;
      *) fail "no build for ${FAMILY:-an unknown instance type} under ${BASE_DIR}/x86_64/, which holds ${#BUILDS[@]} others ($(printf '%s ' "${BUILDS[@]%/*}"| sed 's/ $//')): set NAMD_ENV to the env script of one of them" ;;
    esac
  fi
fi
[ -f "${NAMD_ENV}" ] && [ -r "${NAMD_ENV}" ] || fail "NAMD_ENV not a readable file: ${NAMD_ENV}"
# shellcheck source=/dev/null
source "${NAMD_ENV}"
NAMD3="$(command -v namd3 || true)"
[ -x "${NAMD3}" ] || fail "namd3 not on PATH after sourcing ${NAMD_ENV}"
command -v mpirun >/dev/null 2>&1 || fail "mpirun not on PATH after sourcing ${NAMD_ENV} (env script should load the OpenMPI module)"
# An AVX-512 build would stop with an illegal instruction on a CPU without
# AVX-512 (hpc6a), so it is refused there, before anything runs.
if [ "${NAMD_ISA:-}" = avx512 ] && ! grep -qw avx512f /proc/cpuinfo; then
  fail "${NAMD_ENV} is an AVX-512 build (NAMD_ISA=avx512), and this node's CPU has no AVX-512: build TARGET_CPU=hpc6a for it, or set NAMD_ENV to that build's env script"
fi

# --- Cores per node on hpc8a.96xlarge and hpc7a.96xlarge --------------------
# 192 cores in 24 CCDs of 8, one L3 cache per CCD. With one NAMD process per
# node, it uses PPN + 1 cores: its PPN worker threads and its communication
# thread. Only 24, 48, 72, 96, 120, 144, 168 or 192 cores per node give every
# CCD the same number of threads (Utils/flexible-cores/), so on these types PPN
# is 23, 47, 71, 95, 119, 143, 167, 191 or 192, and any other value stops the
# job here, before anything runs. Below a full node, the threads are pinned to
# the flexible-cores list of PPN + 1 cores: the communication thread to its
# first core (+commap), the worker threads to the others (+pemap). With more
# than one process per node, each process's G cores must be whole CCDs: P = 1,
# 2, 3, 4, 6, 8, 12 or 24.
# With no instance type from the instance metadata, a node that lscpu shows as
# AMD with 192 cores (sockets x cores per socket) could be either type and gets
# the same check and lists; any other node runs with no list, with a NOTE on
# stderr. lscpu is asked, and a NOTE printed, only where the type changes what
# the job does: one process below a full node, or processes of a size that is
# not a whole number of CCDs. Other instance types and sizes get no list and no
# check.
amd_192_cores() {
  local info vendor sockets per_socket
  info="$(LC_ALL=C lscpu 2>/dev/null)" || return 1
  vendor="$(awk -F: '/^[[:space:]]*Vendor ID:/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' <<< "${info}")"
  sockets="$(awk -F: '/^[[:space:]]*Socket\(s\):/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' <<< "${info}")"
  per_socket="$(awk -F: '/^[[:space:]]*Core\(s\) per socket:/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' <<< "${info}")"
  [ "${vendor}" = AuthenticAMD ] && [[ "${sockets}" =~ ^[1-9][0-9]{0,2}$ ]] \
    && [[ "${per_socket}" =~ ^[1-9][0-9]{0,3}$ ]] && (( sockets * per_socket == 192 ))
}
# flex_cores_list <cores>: the flexible-cores list for <cores> per node (24 to
# 168, a multiple of 24), by Utils/flexible-cores/'s rule: with k = cores / 24
# threads on each CCD of 8 cores, every (8 / k)-th core of each CCD when k
# divides 8, and each CCD's first k cores otherwise.
flex_cores_list() {
  local k=$(( $1 / 24 )) step ccd i list=()
  if (( 8 % k == 0 )); then step=$(( 8 / k )); else step=1; fi
  for (( ccd = 0; ccd < 24; ccd++ )); do
    for (( i = 0; i < k * step; i += step )); do list+=( $(( ccd * 8 + i )) ); done
  done
  local IFS=,
  echo "${list[*]}"
}
FLEX_NODE=""   # the node the check applies to, as the messages name it ("": no check)
FLEX_ON=""
case "${INSTANCE_TYPE}" in
  hpc8a.96xlarge|hpc7a.96xlarge)
    FLEX_NODE="${INSTANCE_TYPE}"; FLEX_ON="this type" ;;
  "")
    if { (( P == 1 && PPN + 1 < CORES_PER_NODE )) || (( P > 1 && G % 8 != 0 )); }; then
      if amd_192_cores; then
        FLEX_NODE="this 192-core AMD node"; FLEX_ON="this node"
        echo "NOTE: no instance type from the instance metadata; lscpu shows a 192-core AMD node, which could be an hpc8a.96xlarge or hpc7a.96xlarge, so their cores-per-node check and flexible-cores lists apply" >&2
      else
        echo "NOTE: no instance type from the instance metadata, and lscpu does not show a 192-core AMD node, so the flexible-cores check and lists for hpc8a.96xlarge and hpc7a.96xlarge are skipped" >&2
      fi
    fi ;;
esac
MAP_ARGS=()
if [ -n "${FLEX_NODE}" ] && (( P > 1 )); then
  (( G % 8 == 0 )) \
    || fail "PROCS_PER_NODE=${P} gives each process ${G} cores, which would load the 24 CCDs of ${FLEX_NODE} unevenly; on ${FLEX_ON} use PROCS_PER_NODE=1, 2, 3, 4, 6, 8, 12 or 24 (see Utils/flexible-cores/)"
elif [ -n "${FLEX_NODE}" ]; then
  case "${PPN}" in
    191|192) ;;   # the whole node
    23|47|71|95|119|143|167)
      FLEX_LIST="$(flex_cores_list $(( PPN + 1 )))"
      MAP_ARGS=( +commap "${FLEX_LIST%%,*}" +pemap "${FLEX_LIST#*,}" )
      echo "Flexible cores: the communication thread on core ${FLEX_LIST%%,*} and the ${PPN} PEs on the rest of the $(( PPN + 1 ))-core list (Utils/flexible-cores/)" ;;
    *)
      fail "PPN=${PPN} worker threads and the communication thread use $(( PPN + 1 )) cores per node, which would load the 24 CCDs of ${FLEX_NODE} unevenly; on ${FLEX_ON} use PPN=23, 47, 71, 95, 119, 143, 167, 191 or 192 (see Utils/flexible-cores/)" ;;
  esac
fi
# --- A full node: each process on G consecutive cores ------------------------
# P processes fill the node's C cores in groups of G: process k's
# communication thread on core k*G (+commap 0-<C-1>:G), its PPN = G - 1 worker
# threads on the other cores of its group (+pemap 1-<C-1>:G.<G-1>), in NAMD's
# list syntax. Charm++ hands each node's processes the entries in order, so
# every node uses the same cores. With one process and PPN equal to the node's
# cores, no core is left for the communication thread: Charm++ places the
# threads.
C_LAST=$(( CORES_PER_NODE - 1 ))
if (( P > 1 || PPN + 1 == CORES_PER_NODE )); then
  MAP_ARGS=( +commap "0-${C_LAST}:${G}" +pemap "1-${C_LAST}:${G}.$(( G - 1 ))" )
elif (( PPN >= CORES_PER_NODE )); then
  echo "NOTE: PPN=${PPN} on a node of ${CORES_PER_NODE} cores leaves no core for the communication thread; Charm++ places the threads" >&2
fi

echo "================================================================================"
echo "NAMD benchmark — $(date)"
echo "  model=${MODEL}  nodes=${NODES} x ${INSTANCE_TYPE:-unknown}  procs/node=${P}  ppn=${PPN}  cores/node=${CORES_PER_NODE}"
echo "  namd3=${NAMD3}   CHARM_ARCH=${CHARM_ARCH:-unknown}   target=${NAMD_TARGET_CPU:-unknown}   isa=${NAMD_ISA:-unknown}"
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
  [ATPase]="https://www.ks.uiuc.edu/Research/namd/utilities/f1atpase.tar.gz"
  [STMV]="https://www.ks.uiuc.edu/Research/namd/utilities/stmv.tar.gz"
)
declare -A DECK_CONF=( [ApoA1]="apoa1.namd" [ATPase]="f1atpase.namd" [STMV]="stmv.namd" )
CACHE_DIR="${BASE_DIR}/benchmarks/${MODEL}"
CONF="${DECK_CONF[${MODEL}]}"
if [ ! -s "${CACHE_DIR}/${CONF}" ]; then
  echo "==> fetching ${MODEL} deck from ${DECK_URL[${MODEL}]}"
  mkdir -p "${CACHE_DIR}"
  tmp="$(mktemp -d)"
  if curl -fsSL --max-time 600 --retry 3 -o "${tmp}/deck.tar.gz" "${DECK_URL[${MODEL}]}"; then
    mkdir "${tmp}/deck"
    tar xzf "${tmp}/deck.tar.gz" -C "${tmp}/deck"
    # decks extract into a subdir (apoa1/, f1atpase/ or stmv/); flatten its
    # files, not the downloaded archive, into the cache
    find "${tmp}/deck" -type f -exec cp -n {} "${CACHE_DIR}/" \;
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
LAYOUT="${PPN}ppn"; (( P == 1 )) || LAYOUT="${P}x${PPN}ppn"
WORK="${BASE_DIR}/Run/${SLURM_JOB_ID:-local}-${MODEL}-${SLURM_CLUSTER_NAME:-cluster}-${NODES}x${INSTANCE_TYPE:-unknown}-${LAYOUT}-${STAMP}"
[ -e "${WORK}" ] && fail "run directory already exists: ${WORK}"
mkdir -p "${WORK}"
cp "${CACHE_DIR}"/* "${WORK}/" 2>/dev/null || true
cd "${WORK}" || fail "cannot cd into ${WORK}"

# --- Build the per-run config (override numsteps, ensure timing output) ---
RUNCONF="run-${MODEL}.namd"
cp "${CONF}" "${RUNCONF}"
# The run's length: numsteps (and a final 'run N') become TIMESTEPS, by default
# 1000. NAMD prints a timing line every 5 x stepspercycle steps (100 for the
# three decks), "Initial time:" for the first three and "Benchmark time:" from
# step 400 to step 900: six Benchmark time lines in a 1,000-step run, two in the
# decks' own 500 steps.
sed -i -E "s/^[[:space:]]*numsteps[[:space:]]+[0-9]+/numsteps ${TIMESTEPS}/I" "${RUNCONF}"
sed -i -E "s/^[[:space:]]*run[[:space:]]+[0-9]+/run ${TIMESTEPS}/I" "${RUNCONF}"
grep -qiE "^[[:space:]]*outputTiming" "${RUNCONF}" || echo "outputTiming 20" >> "${RUNCONF}"
# The decks write their output files (.coor, .vel, .xsc) to /usr/tmp/<name>:
# the run config keeps the name and drops the directory, so NAMD writes them in
# the run directory.
sed -i -E 's|^([[:space:]]*outputname[[:space:]]+)[^[:space:]#;]*/([^/[:space:]#;]+)|\1\2|I' "${RUNCONF}"

# --- Drop page caches + enable THP on all nodes --------------------------
echo "==> dropping page caches + enabling THP on all nodes (best-effort)"
srun --ntasks="${NODES}" --ntasks-per-node=1 bash -c \
  'sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true; echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled >/dev/null 2>&1 || true'

# --- Launch NAMD ---------------------------------------------------------
# Charm++ MPI/SMP build: launch with mpirun, P processes per node
# (--map-by ppr:P:node), each spawning PPN worker threads (+ppn) plus a comm
# thread. OpenMPI carries the traffic over EFA via its libfabric provider.
echo "==> launching NAMD: ${NODES} node(s) x ${P} process(es) x ${PPN} PEs"
MPI_ARGS=( -np "$(( NODES * P ))" --map-by "ppr:${P}:node" --bind-to none )
if [ "${NODES}" -gt 1 ]; then
  MPI_ARGS+=( --mca pml cm --mca mtl ofi -x FI_PROVIDER -x FI_EFA_USE_DEVICE_RDMA -x RDMAV_FORK_SAFE )
fi
NAMD_ARGS=( +ppn "${PPN}" +setcpuaffinity ${MAP_ARGS[@]+"${MAP_ARGS[@]}"} ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} )
echo "==> mpirun ${MPI_ARGS[*]} ${NAMD3} ${NAMD_ARGS[*]} ${RUNCONF}"
set -o pipefail
mpirun "${MPI_ARGS[@]}" "${NAMD3}" "${NAMD_ARGS[@]}" "${RUNCONF}" 2>&1 | tee namd.out
rc=${PIPESTATUS[0]}
if [ "${rc}" -ne 0 ]; then
  echo "ERROR: NAMD exited with status ${rc}; see ${WORK}/namd.out" >&2
  exit "${rc}"
fi

# --- Parse performance, and the success gate --------------------------------
# Take the days/ns value from the LAST 'Benchmark time:' line. NAMD exited 0; a
# result is reported, and recorded, only from a complete run: namd.out has
# NAMD's closing WallClock: line, and the last Benchmark time line gives a
# positive days/ns (a decimal, in scientific notation or not). Otherwise a NOTE
# says the run is not recorded, an ERROR says what is missing, no result is
# printed, and the job ends with status 1.
DAYS_PER_NS="$(awk '/Benchmark time:/ { for (i=1;i<=NF;i++) if ($i=="days/ns") print $(i-1) }' namd.out | tail -1)"
WALLCLOCK="$(awk '/^WallClock:/ {print $2}' namd.out | tail -1)"
NOT_COMPLETE=""
if [ -z "${DAYS_PER_NS}" ]; then
  NOT_COMPLETE="could not parse 'days/ns' from NAMD output"
elif ! grep -qE '^WallClock:' namd.out; then
  NOT_COMPLETE="namd.out has no closing 'WallClock:' line, so NAMD did not end normally"
elif ! awk -v d="${DAYS_PER_NS}" 'BEGIN { exit !(d ~ /^([0-9]+[.]?[0-9]*|[.][0-9]+)([eE][-+]?[0-9]+)?$/ && d + 0 > 0) }'; then
  NOT_COMPLETE="the last 'Benchmark time:' line gives no positive days/ns ('${DAYS_PER_NS}')"
fi
if [ -n "${NOT_COMPLETE}" ]; then
  echo "NOTE: not recorded: ${NOT_COMPLETE}" >&2
  fail "${NOT_COMPLETE} (${WORK}/namd.out)"
fi
NS_PER_DAY="$(awk -v d="${DAYS_PER_NS}" 'BEGIN { printf "%.4f", 1.0 / d }')"

echo ""
echo "================================================================================"
echo "NAMD benchmark results"
echo "  Model:       ${MODEL}"
echo "  Nodes:       ${NODES} x ${INSTANCE_TYPE:-unknown}   (${P} process(es) x ${PPN} PEs per node)"
echo "  days/ns:     ${DAYS_PER_NS}"
echo "  ns/day:      ${NS_PER_DAY}"
echo "  WallClock:   ${WALLCLOCK:-n/a}s"
echo "  Workdir:     ${WORK}"
echo "================================================================================"
echo "NAMDRESULT model=${MODEL} nodes=${NODES} ppn=${PPN} instance=${INSTANCE_TYPE:-unknown} days_per_ns=${DAYS_PER_NS} ns_per_day=${NS_PER_DAY} wallclock=${WALLCLOCK:-NA} procs_per_node=${P}"

# --- Contribute the result (best-effort, non-fatal) ------------------------
# The complete run is recorded in the shared AI-Powered HPC benchmark dataset by
# the contribution recorder, apps/NAMD/dynamodb/record-benchmark.sh. It reads
# the host's details itself, and from namd.out in the run directory the atom
# count, NAMD's version and platform, the number of steps and the time step.
# The launcher hands it the case, the days/ns (from which the recorder computes
# ns/day), NAMD's WallClock time, the nodes and the cores the run used
# (PROCS_PER_NODE x (PPN + 1) per node, at most the node's cores), and what
# makes runs comparable, under the names the dataset gives them: the processes
# per node (procs_per_node), the worker threads per process (pes_per_proc), and
# whether NAMD's AVX-512 tile-list kernels ran (avx512_tiles: on when namd.out
# says they are ENABLED). A recorder problem never changes the job's exit
# status: a NOTE says so. Point DYNAMODB_RECORDER at the recorder if it is not
# found from the submit directory, and set SOURCE=<YourOrg> to tag your
# contributions. See apps/NAMD/dynamodb/README.md and apps/BENCHMARK-RECORDERS.md.
REC_CORES=$(( P * (PPN + 1) ))
if (( REC_CORES > CORES_PER_NODE )); then REC_CORES="${CORES_PER_NODE}"; fi
TILES=off
if grep -q 'AVX-512 TILES OPTIMIZATIONS: ENABLED' namd.out; then TILES=on; fi
RECORDER="${DYNAMODB_RECORDER:-}"
for cand in "${RECORDER}" \
            "${SLURM_SUBMIT_DIR:-.}/../dynamodb/record-benchmark.sh" \
            "${SLURM_SUBMIT_DIR:-.}/dynamodb/record-benchmark.sh" \
            "${SLURM_SUBMIT_DIR:-.}/apps/NAMD/dynamodb/record-benchmark.sh"; do
  if [ -n "${cand}" ] && [ -x "${cand}" ]; then RECORDER="${cand}"; break; fi
done
if [ -n "${RECORDER}" ] && [ -x "${RECORDER}" ]; then
  BENCHMARK_CASE="${MODEL}" DAYS_PER_NS="${DAYS_PER_NS}" TIME_TO_SOLUTION="${WALLCLOCK}" \
  NUM_INSTANCES="${NODES}" NUM_CORES="$(( NODES * REC_CORES ))" CORES_PER_NODE="${REC_CORES}" \
  INSTANCE_TYPE="${INSTANCE_TYPE}" RUN_DIR="${WORK}" "${RECORDER}" \
      --metric "procs_per_node=${P}" --metric "pes_per_proc=${PPN}" --char "avx512_tiles=${TILES}" \
    || echo "NOTE: benchmark recorder failed (non-fatal); the solve was unaffected." >&2
else
  echo "NOTE: benchmark recorder not found; set DYNAMODB_RECORDER=/path/to/record-benchmark.sh to record." >&2
fi
exit 0
