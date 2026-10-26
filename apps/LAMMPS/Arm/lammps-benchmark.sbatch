#!/bin/bash
# Run a LAMMPS standard benchmark (LJ melt, Rhodopsin, or EAM Cu) on
# aarch64 nodes (Graviton3E / Graviton4) using OpenMPI + EFA.
#
# Optional: a commented-out block at the end of this script can record
# each run to a DynamoDB table for cross-run aggregation. It is disabled
# by default so customers don't need to provision DynamoDB. To enable,
# follow the instructions in apps/LAMMPS/dynamodb/README.md and uncomment
# the marked block at the bottom of this file.
#
# A single launcher targets both Graviton3E (hpc7g.16xlarge, 64 cores) and
# Graviton4 (m8g.48xlarge / r8g.48xlarge, 192 cores). Select the right
# build by pointing LAMMPS_ENV at the appropriate env script.
#
# Every deck ends with "run 100". The run directory gets a copy of the deck
# with that line made "run ${nsteps}", and LAMMPS gets -var nsteps, so the
# run length is TIMESTEPS (the cached deck is never edited).
#
# Override via --export=ALL,...:
#   LAMMPS_ENV         path to env script (choose Graviton3 / 4 build)
#   MODEL              lj (default) | rhodo | rhodo_scaled | eam
#   SCALE              lattice replication factor (default per model:
#                      lj 8, rhodo_scaled 4, eam 4; rhodo ignores it)
#                      atom count scales as SCALE^3
#   TIMESTEPS          timesteps to run, 1 to 10000000 (default per model:
#                      lj 15000, rhodo and rhodo_scaled 6000, eam 30000)
#   THREADS_PER_RANK   OpenMP threads per MPI rank (default: 1 = pure MPI)
#   BASE_DIR           run output root (default: /fsx/lammps)
#
# The defaults were sized on 192-core x86 nodes (hpc8a.96xlarge and
# hpc7a.96xlarge) and not measured on Graviton. A run's time grows with
# TIMESTEPS: for a quick check, on the 64-core hpc7g for example, set a
# smaller one.
#
# Usage:
#   # Graviton3E (hpc7g)
#   sbatch -p hpc7g -N 1 --ntasks-per-node=64 \
#     --export=ALL,LAMMPS_ENV=/fsx/lammps/aarch64-graviton3/lammps-stable_2Aug2023_update3-env.sh \
#     lammps-benchmark.sbatch
#
#   # Graviton4 (m8g)
#   sbatch -p m8g -N 1 --ntasks-per-node=192 \
#     --export=ALL,LAMMPS_ENV=/fsx/lammps/aarch64-graviton4-ompi5/lammps-stable_2Aug2023_update3-ompi5-env.sh \
#     lammps-benchmark.sbatch

#SBATCH --job-name=lammps
#SBATCH -p hpc7g
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=64
#SBATCH --time=02:00:00
#SBATCH --exclusive
#SBATCH --output=/fsx/lammps/logs/slurm-%x-%j.out

set -euo pipefail

LAMMPS_ENV="${LAMMPS_ENV:-/fsx/lammps/aarch64-graviton3/lammps-stable_2Aug2023_update3-env.sh}"
MODEL="${MODEL:-lj}"
THREADS_PER_RANK="${THREADS_PER_RANK:-1}"
BASE_DIR="${BASE_DIR:-/fsx/lammps}"

# Per model: input file, default scale and run length, extra files. The
# defaults are the x86 launcher's (see x86/lammps-benchmark.sbatch and the
# note above).
case "${MODEL}" in
    lj)
        DECK_FILE="in.lj"
        DEFAULT_SCALE=8
        DEFAULT_TIMESTEPS=15000
        EXTRA_FILES=()
        ;;
    rhodo)
        # in.rhodo has no replicate command: 32,000 atoms whatever SCALE is.
        DECK_FILE="in.rhodo"
        DEFAULT_SCALE=1
        DEFAULT_TIMESTEPS=6000
        EXTRA_FILES=("data.rhodo")
        ;;
    rhodo_scaled)
        # in.rhodo.scaled is the same Rhodopsin protein in water as
        # in.rhodo, but the input deck replicates the box via -var x/y/z
        # so the atom count grows as 32000 * x*y*z instead of 32000 * x^3
        # (LJ-style). Used by Murata-Manufacturing's published
        # benchmark with -var x 16 -var y 16 -var z 16 -> ~131M atoms.
        DECK_FILE="in.rhodo.scaled"
        DEFAULT_SCALE=4
        DEFAULT_TIMESTEPS=6000
        EXTRA_FILES=("data.rhodo")
        ;;
    eam)
        DECK_FILE="in.eam"
        DEFAULT_SCALE=4
        DEFAULT_TIMESTEPS=30000
        EXTRA_FILES=("Cu_u3.eam")
        ;;
    *)
        echo "ERROR: Unknown MODEL: ${MODEL} (expected: lj | rhodo | rhodo_scaled | eam)" >&2
        exit 1
        ;;
esac

SCALE="${SCALE:-${DEFAULT_SCALE}}"
TIMESTEPS="${TIMESTEPS:-${DEFAULT_TIMESTEPS}}"
# At most 8 digits before the arithmetic test, so a long value cannot overflow it.
if ! [[ "${TIMESTEPS}" =~ ^[1-9][0-9]{0,7}$ ]] || (( TIMESTEPS > 10000000 )); then
    echo "ERROR: TIMESTEPS must be a whole number from 1 to 10000000, such as 15000 (got '${TIMESTEPS}')" >&2
    exit 1
fi

NPROC_TOTAL=$(( SLURM_JOB_NUM_NODES * SLURM_NTASKS_PER_NODE ))
if (( THREADS_PER_RANK > 1 )); then
    NRANK_TOTAL=$(( NPROC_TOTAL / THREADS_PER_RANK ))
else
    NRANK_TOTAL=${NPROC_TOTAL}
fi
NRANK_PER_NODE=$(( SLURM_NTASKS_PER_NODE / THREADS_PER_RANK ))

TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_TYPE=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type)
# REGION is referenced by the optional DynamoDB recorder block at the
# bottom of this file (commented out by default).
# shellcheck disable=SC2034
REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)
WORKDIR="${BASE_DIR}/Run/${SLURM_JOB_NAME}/${MODEL}/${SLURM_CLUSTER_NAME:-cluster}/${SLURM_JOB_ID}-${SLURM_JOB_NUM_NODES}x${INSTANCE_TYPE}-${NRANK_TOTAL}x${THREADS_PER_RANK}-s${SCALE}-$(date '+%d-%m-%Y-%H-%M')"

mkdir -p "${WORKDIR}"
cd "${WORKDIR}"
cp "$0" .

echo "=== LAMMPS benchmark (Arm) ==="
echo "Date:          $(date)"
echo "SLURM Job ID:  ${SLURM_JOB_ID}"
echo "Model:         ${MODEL} (${DECK_FILE})"
echo "Nodes:         ${SLURM_JOB_NUM_NODES} x ${INSTANCE_TYPE}"
echo "MPI ranks:     ${NRANK_TOTAL} total (${NRANK_PER_NODE}/node)"
echo "OMP threads:   ${THREADS_PER_RANK}/rank -> ${NPROC_TOTAL} cores total"
echo "Scale factor:  ${SCALE} (atom count scales as SCALE^3)"
echo "Timesteps:     ${TIMESTEPS}"
echo "Workdir:       ${WORKDIR}"

if [ ! -f "${LAMMPS_ENV}" ]; then
    echo "ERROR: LAMMPS env script not found: ${LAMMPS_ENV}" >&2
    exit 1
fi
set +u
# shellcheck source=/dev/null
source "${LAMMPS_ENV}"
set -u
LMP_BIN="$(command -v lmp || true)"
if [ -z "${LMP_BIN}" ]; then
    echo "ERROR: lmp binary not in PATH; check ${LAMMPS_ENV}" >&2
    exit 1
fi
echo "lmp binary:    ${LMP_BIN}"
echo "LAMMPS tag:    ${LAMMPS_TAG:-unknown}"

# ---------------------------------------------------------------------------
# MPI / EFA sanity
# ---------------------------------------------------------------------------
echo "=== MPI / EFA sanity ==="
echo "mpirun:          $(command -v mpirun)"
mpirun --version 2>&1 | head -2 | sed 's/^/  /'
echo "libfabric (fi_info -l):"
fi_info -l 2>&1 | sed 's/^/  /' | head -6
echo "libfabric EFA provider (fi_info -p efa -t FI_EP_RDM):"
fi_info -p efa -t FI_EP_RDM 2>&1 | grep -E "provider|fabric|domain|nic|version" | sed 's/^/  /' | head -10 || true
echo "lmp libfabric/openmpi linkage:"
ldd "${LMP_BIN}" 2>/dev/null | grep -E "libmpi|libfabric|libopen-" | sed 's/^/  /' || true
echo

# ---------------------------------------------------------------------------
# Stage benchmark input files
# ---------------------------------------------------------------------------
BENCH_CACHE="${BASE_DIR}/benchmarks/${MODEL}"
mkdir -p "${BENCH_CACHE}"
RAW_BASE="https://raw.githubusercontent.com/lammps/lammps/${LAMMPS_TAG:-stable_2Aug2023_update3}/bench"

fetch_if_missing() {
    local name="$1"
    local dest="${BENCH_CACHE}/${name}"
    if [ ! -s "${dest}" ]; then
        echo "Downloading ${name} from ${RAW_BASE}/${name}"
        if ! curl -fsSL "${RAW_BASE}/${name}" -o "${dest}"; then
            echo "ERROR: failed to download ${name} from ${RAW_BASE}/${name}" >&2
            rm -f "${dest}"
            return 1
        fi
    fi
    cp "${dest}" .
}

fetch_if_missing "${DECK_FILE}"
for extra in "${EXTRA_FILES[@]}"; do
    fetch_if_missing "${extra}"
done

# ---------------------------------------------------------------------------
# Run length. Each bench deck ends with one "run 100" line and reads no
# step-count variable, so a -var alone cannot change it. The run directory's
# copy of the deck gets that line as "run ${nsteps}", and LAMMPS gets
# -var nsteps TIMESTEPS (below). A deck without exactly one plain
# "run <steps>" line stops the job here, before any rank starts.
# ---------------------------------------------------------------------------
set_run_length() {
    local deck="$1" runs
    runs="$(grep -cE '^[[:space:]]*run[[:space:]]' "${deck}" || true)"
    if [ "${runs}" != 1 ]; then
        echo "ERROR: ${deck} has ${runs} run lines; exactly one plain 'run <steps>' line is needed to set the run length" >&2
        return 1
    fi
    if ! grep -qE '^[[:space:]]*run[[:space:]]+[0-9]+[[:space:]]*$' "${deck}"; then
        echo "ERROR: ${deck}: its run line is '$(grep -E '^[[:space:]]*run[[:space:]]' "${deck}")'; a plain 'run <steps>' line is needed to set the run length" >&2
        return 1
    fi
    # shellcheck disable=SC2016  # ${nsteps} is LAMMPS's variable, not the shell's
    sed -i -E 's/^([[:space:]]*run[[:space:]]+)[0-9]+([[:space:]]*)$/\1${nsteps}\2/' "${deck}"
}
set_run_length "${DECK_FILE}" || exit 1
echo "Run length:    ${TIMESTEPS} timesteps (${DECK_FILE} runs \${nsteps})"

# ---------------------------------------------------------------------------
# Hostfile + system tuning
# ---------------------------------------------------------------------------
echo "=== Building hostfile and tuning nodes ==="
scontrol show nodes "${SLURM_NODELIST}" \
    | grep NodeHostName= | awk '{print $2}' | sed 's/NodeHostName=//' > hostfile

srun --ntasks="${SLURM_JOB_NUM_NODES}" --ntasks-per-node=1 /bin/bash -c \
    "sync && echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null && \
     echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled >/dev/null" \
    || true

export OMP_NUM_THREADS="${THREADS_PER_RANK}"
export OMP_PLACES=cores
export OMP_PROC_BIND=close

export FI_PROVIDER=efa
export FI_EFA_USE_DEVICE_RDMA=1
export RDMAV_FORK_SAFE=1

MCA_FLAGS="--mca plm_rsh_agent ssh --mca pml cm --mca mtl ofi --mca btl ^tcp,openib"
if [ "${EFA_VERBOSE:-0}" = "1" ]; then
    MCA_FLAGS="${MCA_FLAGS} --mca mtl_base_verbose 5 --mca pml_base_verbose 5"
fi

# Graviton instances (hpc7g, m8g) are single-socket with a flat NUMA
# layout, so the dual-socket flex-cores cpu-list pattern used on x86
# isn't applicable. Plain map-by slot / map-by ppr:rpn:node:PE=t is the
# right choice here.
if (( THREADS_PER_RANK > 1 )); then
    BIND_FLAGS="--bind-to core --map-by ppr:${NRANK_PER_NODE}:node:PE=${THREADS_PER_RANK}"
else
    BIND_FLAGS="--bind-to core --map-by slot"
fi
X_ENV="-x OMP_NUM_THREADS -x OMP_PLACES -x OMP_PROC_BIND -x FI_PROVIDER -x FI_EFA_USE_DEVICE_RDMA -x RDMAV_FORK_SAFE -x PATH -x LD_LIBRARY_PATH"

# -var x/y/z: lattice replication (in.rhodo reads none of them); -var nsteps:
# the run length of the run directory's copy of the deck (set_run_length).
LMP_ARGS=(-in "${DECK_FILE}" -var x "${SCALE}" -var y "${SCALE}" -var z "${SCALE}" -var nsteps "${TIMESTEPS}")

echo ""
echo "=== Running LAMMPS (${NRANK_TOTAL} ranks x ${THREADS_PER_RANK} threads) ==="
T_START=$(date +%s.%N)
# We capture stdout to log.run because LAMMPS itself writes log.lammps in
# the cwd (the file used to extract Loop time / atoms etc.).
# shellcheck disable=SC2086
mpirun -np "${NRANK_TOTAL}" --hostfile hostfile \
    ${BIND_FLAGS} ${MCA_FLAGS} ${X_ENV} \
    "${LMP_BIN}" "${LMP_ARGS[@]}" \
    2>&1 | tee log.run
T_END=$(date +%s.%N)
WALL_TIME=$(awk "BEGIN{printf \"%.2f\", ${T_END} - ${T_START}}")

LOOP_LINE="$(grep -E '^Loop time of' log.lammps | tail -1 || true)"
if [ -n "${LOOP_LINE}" ]; then
    LOOP_TIME=$(echo "${LOOP_LINE}" | awk '{print $4}')
    LOOP_STEPS=$(echo "${LOOP_LINE}" | awk '{print $9}')
    ATOMS=$(echo "${LOOP_LINE}" | awk '{print $12}')
else
    echo "WARNING: 'Loop time of ...' line not found in log.lammps" >&2
    LOOP_TIME=0
    LOOP_STEPS=0
    ATOMS=0
fi

if awk "BEGIN { exit !(${LOOP_TIME} > 0) }"; then
    TIMESTEPS_PER_SEC=$(awk "BEGIN{printf \"%.4f\", ${LOOP_STEPS} / ${LOOP_TIME}}")
    ATOM_STEPS_PER_SEC=$(awk "BEGIN{printf \"%.0f\", ${ATOMS} * ${LOOP_STEPS} / ${LOOP_TIME}}")
else
    TIMESTEPS_PER_SEC=0
    ATOM_STEPS_PER_SEC=0
fi

cat <<REPORT

================================================================================
LAMMPS benchmark results
================================================================================
Date:             $(date)
SLURM Job ID:     ${SLURM_JOB_ID}
Model:            ${MODEL}
Nodes:            ${SLURM_JOB_NUM_NODES} x ${INSTANCE_TYPE}
MPI ranks:        ${NRANK_TOTAL} (${NRANK_PER_NODE}/node)
OMP threads:      ${THREADS_PER_RANK}/rank  (total cores: ${NPROC_TOTAL})
Scale factor:     ${SCALE}
Atoms:            ${ATOMS}
Timesteps run:    ${LOOP_STEPS}
Workdir:          ${WORKDIR}

Loop time:        ${LOOP_TIME}s
Timesteps/sec:    ${TIMESTEPS_PER_SEC}
Atom-steps/sec:   ${ATOM_STEPS_PER_SEC}
Wall time:        ${WALL_TIME}s
================================================================================
REPORT

# ---------------------------------------------------------------------------
# Optional: record the result to DynamoDB.
#
# Disabled by default so customers who only want to run LAMMPS aren't
# forced to provision a DynamoDB table or grant dynamodb:PutItem to their
# compute role. To enable cross-run aggregation, deploy
# apps/LAMMPS/dynamodb/record_to_dynamodb.sh on shared storage (default
# path /fsx/lammps/scripts/dynamodb/record_to_dynamodb.sh), grant the IAM
# permission described in apps/LAMMPS/dynamodb/README.md, and uncomment
# the block below by removing the leading '# ' from each line.
# ---------------------------------------------------------------------------
# if [[ "${LD_LIBRARY_PATH:-}" == *"openmpi5"* ]]; then
#     MPI_STACK="openmpi-5"
# else
#     MPI_STACK="openmpi-4"
# fi
# DYNAMODB_RECORDER="${DYNAMODB_RECORDER:-/fsx/lammps/scripts/dynamodb/record_to_dynamodb.sh}"
# if [ -x "${DYNAMODB_RECORDER}" ]; then
#     export SLURM_JOB_ID SLURM_JOB_NUM_NODES SLURM_CLUSTER_NAME
#     export MODEL SCALE
#     export NRANK_TOTAL NRANK_PER_NODE THREADS_PER_RANK
#     export INSTANCE_TYPE REGION LAMMPS_TAG MPI_STACK
#     export ATOMS LOOP_STEPS LOOP_TIME
#     export TIMESTEPS_PER_SEC ATOM_STEPS_PER_SEC WALL_TIME
#     export WORKDIR
#     "${DYNAMODB_RECORDER}" || true
# else
#     echo "DynamoDB recorder not found at ${DYNAMODB_RECORDER} — skipping result persistence"
# fi

# ---------------------------------------------------------------------------
# Contribute this benchmark to the shared AI-Powered HPC dataset (best-effort,
# non-fatal). This uses the *contribution* recorder
# (apps/LAMMPS/dynamodb/record-benchmark.sh), SEPARATE from the optional
# internal record_to_dynamodb.sh block above. It self-collects host details
# from the environment and parses log.lammps in this run dir, so it needs no
# arguments. A recorder problem NEVER fails a good solve (`|| echo` keeps it
# non-fatal, even under `set -e`). Override the recorder path with
# CONTRIB_RECORDER (NOT DYNAMODB_RECORDER, used by the internal block), and
# set SOURCE=<YourOrg> to tag your contributions.
# See apps/LAMMPS/dynamodb/README.md and apps/BENCHMARK-RECORDERS.md.
# ---------------------------------------------------------------------------
_lt="${LOOP_TIME:-}";           [ "${_lt}" != "0" ]  || _lt=""
_tps="${TIMESTEPS_PER_SEC:-}";  [ "${_tps}" != "0" ] || _tps=""
_asp="${ATOM_STEPS_PER_SEC:-}"; [ "${_asp}" != "0" ] || _asp=""
# The run length, so that records of runs of different lengths stay apart.
_steps="${LOOP_STEPS:-}";       [ "${_steps}" != "0" ] || _steps=""
_atoms_m=""
if [ -n "${ATOMS:-}" ] && [ "${ATOMS}" != "0" ]; then
    _atoms_m="$(awk -v x="${ATOMS}" 'BEGIN{if (x+0>0) printf "%.6g", x/1000000}' 2>/dev/null || true)"
fi
_contrib_recorder="${CONTRIB_RECORDER:-}"
for _c in "${_contrib_recorder}" \
          "${SLURM_SUBMIT_DIR:-.}/../dynamodb/record-benchmark.sh" \
          "${SLURM_SUBMIT_DIR:-.}/dynamodb/record-benchmark.sh" \
          "${SLURM_SUBMIT_DIR:-.}/apps/LAMMPS/dynamodb/record-benchmark.sh"; do
    if [ -n "${_c}" ] && [ -x "${_c}" ]; then _contrib_recorder="${_c}"; break; fi
done
if [ -n "${_contrib_recorder}" ] && [ -x "${_contrib_recorder}" ]; then
    LAMMPS_VERSION="${LAMMPS_TAG:-}" BENCHMARK_CASE="${MODEL}" \
    TIME_TO_SOLUTION="${_lt}" TIMESTEPS_PER_SEC="${_tps}" ATOMS_MILLION="${_atoms_m}" \
    ANALYSIS_TYPE="md" RUN_DIR="${WORKDIR}" "${_contrib_recorder}" \
        --char "scale=${SCALE}" --char "timesteps=${_steps}" --metric "atom_steps_per_sec=${_asp}" \
        || echo "NOTE: benchmark recorder failed (non-fatal); the solve was unaffected." >&2
else
    echo "NOTE: contribution recorder not found; set CONTRIB_RECORDER=/path/to/record-benchmark.sh to record." >&2
fi
