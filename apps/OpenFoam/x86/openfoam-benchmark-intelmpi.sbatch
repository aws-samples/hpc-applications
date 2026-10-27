#!/bin/bash
# OCC DrivAer Fine Mesh (236M cells) — Intel MPI on hpc8a
#SBATCH --job-name=occ-drivaer-fine
#SBATCH -p hpc8a
#SBATCH --nodes=32
#SBATCH --ntasks-per-node=192
#SBATCH --time=50:00:00
#SBATCH --exclusive

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
OPENFOAM_ENV="${OPENFOAM_ENV:-/fsx/openfoam/x86_64-intelmpi/openfoam-v2512-env.sh}"
CASE_SRC="${CASE_SRC:-/fsx/openfoam/occ-drivaer/occDrivAerStaticMesh}"
basedir="${BASE_DIR:-/fsx/openfoam}"
TOTAL_CORES=$(( SLURM_JOB_NUM_NODES * SLURM_NTASKS_PER_NODE ))
# SIMPLE iterations (endTime): 200, as every result in ../README.md ran; the case ships with 4000
END_TIME="${END_TIME:-200}"
case "${END_TIME}" in
    ''|0*|*[!0-9]*) echo "ERROR: END_TIME must be a whole number of iterations, 1 or more (got: ${END_TIME})" >&2; exit 1 ;;
esac

# ---------------------------------------------------------------------------
# Working directory (follows Fluent convention)
# ---------------------------------------------------------------------------
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
instanceType=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type)
workdir="${basedir}/Run/${SLURM_JOB_NAME%.*}/${SLURM_CLUSTER_NAME}/${SLURM_JOB_ID}-${SLURM_JOB_NUM_NODES}x${instanceType}-${TOTAL_CORES}-$(date "+%d-%m-%Y-%H-%M")"

echo "=== OCC DrivAer Fine (236M) — Intel MPI ==="
echo "Nodes: ${SLURM_JOB_NUM_NODES}, Cores/node: ${SLURM_NTASKS_PER_NODE}, Total: ${TOTAL_CORES}"
echo "Execution directory: ${workdir}"
mkdir -p "${workdir}" && cd "${workdir}"

# Save launch script
cp "$0" .

# ---------------------------------------------------------------------------
# Environment — Intel MPI
# ---------------------------------------------------------------------------
export I_MPI_OFI_LIBRARY_INTERNAL=0
module load intelmpi 2>/dev/null || true
module load libfabric-aws 2>/dev/null || true
export I_MPI_DEBUG=5
export I_MPI_FABRICS=shm:ofi
export I_MPI_OFI_PROVIDER=efa
export FI_EFA_USE_DEVICE_RDMA=1
export I_MPI_HYDRA_BOOTSTRAP=slurm
export I_MPI_MULTIRAIL=1

set +euo pipefail
source "$OPENFOAM_ENV"
set -euo pipefail

# ---------------------------------------------------------------------------
# Build hostfile
# ---------------------------------------------------------------------------
echo "=== Building hostfile ==="
scontrol show nodes $SLURM_NODELIST | grep NodeHostName= | awk '{print $2}' | sed 's/NodeHostName=//' > hostfile

# ---------------------------------------------------------------------------
# Download case and mesh if not present
# ---------------------------------------------------------------------------
if [ ! -d "$CASE_SRC/system" ]; then
    echo "=== Downloading case files ==="
    mkdir -p "$CASE_SRC"
    curl -L -o /tmp/occ-case.tar.gz \
        "https://develop.openfoam.com/committees/hpc/-/archive/develop/hpc-develop.tar.gz?path=incompressible/simpleFoam/occDrivAerStaticMesh"
    tar xzf /tmp/occ-case.tar.gz -C "$CASE_SRC" --strip-components=4
    rm -f /tmp/occ-case.tar.gz
fi

if [ ! -d "$CASE_SRC/constant/polyMesh" ]; then
    echo "=== Downloading fine mesh (236M cells) from Zenodo ==="
    curl -L -o "$CASE_SRC/constant/polyMesh_236M.tar.gz" \
        "https://zenodo.org/records/15012221/files/polyMesh_236M.tar.gz?download=1"
    tar xzf "$CASE_SRC/constant/polyMesh_236M.tar.gz" -C "$CASE_SRC/constant/"
    rm -f "$CASE_SRC/constant/polyMesh_236M.tar.gz"
fi

# ---------------------------------------------------------------------------
# Prepare case
# ---------------------------------------------------------------------------
echo "=== Preparing case ==="
cp -r "${CASE_SRC}/0.orig" ./0.orig
cp -r "${CASE_SRC}/constant" ./constant
cp -r "${CASE_SRC}/system" ./system
cp -r ./0.orig ./0
sed -i '/#include.*FOwallClockTimeStatistics/d' system/controlDict 2>/dev/null || true
# Run END_TIME iterations (see Configuration)
sed -i "/^[[:space:]]*endTime[[:space:]]/s/endTime.*/endTime         ${END_TIME};/" system/controlDict
if [ "$(awk '/^[[:space:]]*endTime[[:space:]]/ {gsub(";", "", $2); print $2; exit}' system/controlDict)" != "${END_TIME}" ]; then
    echo "ERROR: could not set endTime ${END_TIME} in system/controlDict" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# System prep
# ---------------------------------------------------------------------------
echo "=== Drop caches and enable THP ==="
srun --ntasks-per-node=1 bash -c "sync && echo 3 | sudo tee /proc/sys/vm/drop_caches"
srun --ntasks-per-node=1 bash -c "echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled"

get_timestamp() { date +%s.%N; }
elapsed_seconds() { echo "$2 $1" | awk '{printf "%.2f", $1 - $2}'; }

# ---------------------------------------------------------------------------
# Decomposition
# decomposePar is serial and takes longer the more subdomains it writes, while
# the job holds all its nodes. With DECOMP_CACHE set to a directory on the
# shared file system, a run copies the decomposition that an earlier run of the
# same case and layout saved there instead of running decomposePar, and a run
# that finds none saves its own there, before renumberMesh changes it. A saved
# decomposition is used only if it was made from this decomposeParDict and from
# case files (0.orig, constant/polyMesh, and system/include if the case has
# one, whose values decomposePar writes into the decomposed fields) of the same
# names, sizes and modification times; any other is left as it is.
# ---------------------------------------------------------------------------
echo "=== Decomposition ==="
T_DECOMP_START=$(get_timestamp)

cat > system/decomposeParDict << EOF
FoamFile { version 2.0; format ascii; class dictionary; object decomposeParDict; }
numberOfSubdomains ${TOTAL_CORES};
method simple;
simpleCoeffs { n (${SLURM_JOB_NUM_NODES} 1 $(( SLURM_NTASKS_PER_NODE ))); }
EOF

copy_processor_dirs() {  # <from> <to>: the processor* directories, 16 copies at a time
    find "$1" -mindepth 1 -maxdepth 1 -type d -name 'processor*' -print0 | xargs -0 -r -n 16 -P 16 cp -a -t "$2"
}
count_processor_dirs() {
    find "$1" -mindepth 1 -maxdepth 1 -type d -name 'processor*' | wc -l
}
decomposition_inputs() {  # what a decomposition is made from (see above)
    local inputs=(0.orig constant/polyMesh)
    if [ -d "${CASE_SRC}/system/include" ]; then inputs+=(system/include); fi
    cat system/decomposeParDict
    (cd "${CASE_SRC}" && find -L "${inputs[@]}" -type f -printf '%p %s %T@\n' | LC_ALL=C sort)
}
DECOMP_CACHE="${DECOMP_CACHE:-}"
DECOMP_SAVED=""
DECOMPOSED="decomposePar in this job"
case "${DECOMP_CACHE}" in
    "") ;;
    /*) DECOMP_SAVED="${DECOMP_CACHE}/$(basename "${CASE_SRC}")/${SLURM_JOB_NUM_NODES}x${SLURM_NTASKS_PER_NODE}"
        if ! DECOMP_INPUTS="$(decomposition_inputs)"; then
            echo "NOTE: cannot read the case files the decomposition is made from; not using DECOMP_CACHE." >&2
            DECOMP_SAVED=""
        fi ;;
    *)  echo "NOTE: DECOMP_CACHE must be an absolute path (got '${DECOMP_CACHE}'); not using it." >&2 ;;
esac

if [ -n "${DECOMP_SAVED}" ] && [ -f "${DECOMP_SAVED}/.complete" ] \
        && [ "$(cat "${DECOMP_SAVED}/inputs.txt" 2>/dev/null)" = "${DECOMP_INPUTS}" ] \
        && [ "$(count_processor_dirs "${DECOMP_SAVED}")" -eq "${TOTAL_CORES}" ]; then
    echo "Reusing the decomposition saved in ${DECOMP_SAVED}"
    copy_processor_dirs "${DECOMP_SAVED}" .
    DECOMPOSED="reused from ${DECOMP_SAVED}"
    T_DECOMP_END=$(get_timestamp)
else
    if [ -n "${DECOMP_SAVED}" ] && [ -e "${DECOMP_SAVED}" ]; then
        echo "NOTE: ${DECOMP_SAVED} holds no decomposition of this case and layout; decomposing in this job and leaving it as it is." >&2
    fi
    decomposePar 2>&1 | tee log.decomposePar
    T_DECOMP_END=$(get_timestamp)
    if [ -n "${DECOMP_SAVED}" ] && [ ! -e "${DECOMP_SAVED}" ]; then
        # Saved into a directory this job creates (never one that exists), and
        # renamed into place once complete. A job ended with SIGTERM while it
        # saves (its time limit, for example) removes it first, as best it can.
        DECOMP_PARTIAL="${DECOMP_SAVED}.partial.${SLURM_CLUSTER_NAME:-cluster}.${SLURM_JOB_ID}.$$"
        DECOMP_MINE=""
        if mkdir -p "${DECOMP_SAVED%/*}" && mkdir "${DECOMP_PARTIAL}"; then
            DECOMP_MINE=1
            trap 'rm -rf "${DECOMP_PARTIAL}"; exit 143' TERM
        fi
        if [ -n "${DECOMP_MINE}" ] && copy_processor_dirs . "${DECOMP_PARTIAL}" \
                && printf '%s\n' "${DECOMP_INPUTS}" > "${DECOMP_PARTIAL}/inputs.txt" \
                && date -u +%FT%TZ > "${DECOMP_PARTIAL}/.complete" \
                && mv -T "${DECOMP_PARTIAL}" "${DECOMP_SAVED}" 2>/dev/null; then
            DECOMPOSED="decomposePar in this job, saved to ${DECOMP_SAVED}"
            echo "Decomposition saved to ${DECOMP_SAVED}"
        else
            if [ -n "${DECOMP_MINE}" ]; then rm -rf "${DECOMP_PARTIAL}"; fi
            echo "NOTE: the decomposition was not saved to ${DECOMP_SAVED}; the run goes on." >&2
        fi
        trap - TERM
    fi
fi
DECOMP_TIME=$(elapsed_seconds "$T_DECOMP_START" "$T_DECOMP_END")
echo "Decomposition time: ${DECOMP_TIME}s"

# ---------------------------------------------------------------------------
# Solver
# ---------------------------------------------------------------------------
echo "=== Solver phase ==="
T_RENUMBER_START=$(get_timestamp)
mpirun -np "$TOTAL_CORES" -ppn ${SLURM_NTASKS_PER_NODE} -f hostfile renumberMesh -parallel -overwrite 2>&1 | tee log.renumber
T_RENUMBER_END=$(get_timestamp)
RENUMBER_TIME=$(elapsed_seconds "$T_RENUMBER_START" "$T_RENUMBER_END")

T_POTENTIAL_START=$(get_timestamp)
mpirun -np "$TOTAL_CORES" -ppn ${SLURM_NTASKS_PER_NODE} -f hostfile potentialFoam -parallel 2>&1 | tee log.potential
T_POTENTIAL_END=$(get_timestamp)
POTENTIAL_TIME=$(elapsed_seconds "$T_POTENTIAL_START" "$T_POTENTIAL_END")

T_SOLVE_START=$(get_timestamp)
mpirun -np "$TOTAL_CORES" -ppn ${SLURM_NTASKS_PER_NODE} -f hostfile simpleFoam -parallel 2>&1 | tee log.solver
T_SOLVE_END=$(get_timestamp)
SOLVE_TIME=$(elapsed_seconds "$T_SOLVE_START" "$T_SOLVE_END")

TOTAL_TIME=$(elapsed_seconds "$T_DECOMP_START" "$T_SOLVE_END")

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
cat << REPORT

================================================================================
OCC DrivAer Fine (236M) — Intel MPI Results
================================================================================
Date:             $(date)
SLURM Job ID:     ${SLURM_JOB_ID}
Cluster:          ${SLURM_CLUSTER_NAME}
Nodes:            ${SLURM_JOB_NUM_NODES}
Cores per node:   ${SLURM_NTASKS_PER_NODE}
Total cores:      ${TOTAL_CORES}
Instance type:    ${instanceType}
MPI:              Intel MPI ${I_MPI_ROOT} (EFA)
Working dir:      ${workdir}

Decomposition:    ${DECOMP_TIME}s
Decomposed:       ${DECOMPOSED}
Renumber:         ${RENUMBER_TIME}s
potentialFoam:    ${POTENTIAL_TIME}s
simpleFoam:       ${SOLVE_TIME}s
Total:            ${TOTAL_TIME}s
================================================================================
REPORT

# ---------------------------------------------------------------------------
# Record this benchmark to the AI-Powered HPC dataset (best-effort, non-fatal).
# The recorder self-collects host details from the environment and can also
# parse the OpenFOAM solver log (log.solver) in this run dir, so no arguments
# are needed. A recorder problem NEVER fails a good solve (the `|| echo` keeps
# it non-fatal, even under `set -e`). Point DYNAMODB_RECORDER at the script if
# it isn't found automatically, and set SOURCE=<YourOrg> to tag contributions.
# See apps/OpenFoam/dynamodb/README.md and apps/BENCHMARK-RECORDERS.md.
# ---------------------------------------------------------------------------
_of_version="$(basename "${OPENFOAM_ENV}" 2>/dev/null | grep -oE 'v[0-9]+' | head -1 || true)"
_recorder="${DYNAMODB_RECORDER:-}"
for _c in "${_recorder}" \
          "${SLURM_SUBMIT_DIR:-.}/../dynamodb/record-benchmark.sh" \
          "${SLURM_SUBMIT_DIR:-.}/dynamodb/record-benchmark.sh" \
          "${SLURM_SUBMIT_DIR:-.}/apps/OpenFoam/dynamodb/record-benchmark.sh"; do
    if [ -n "${_c}" ] && [ -x "${_c}" ]; then _recorder="${_c}"; break; fi
done
if [ -n "${_recorder}" ] && [ -x "${_recorder}" ]; then
    OPENFOAM_VERSION="${_of_version}" BENCHMARK_CASE="occDrivAer-236M" \
    MESH_CELLS_MILLION="236" SOLVER="simpleFoam" \
    TIME_TO_SOLUTION="${SOLVE_TIME}" RUN_DIR="${workdir}" "${_recorder}" \
        || echo "NOTE: benchmark recorder failed (non-fatal); the solve was unaffected." >&2
else
    echo "NOTE: benchmark recorder not found; set DYNAMODB_RECORDER=/path/to/record-benchmark.sh to record." >&2
fi
