#!/bin/bash
# OCC DrivAer Fine Mesh (236M cells) — OpenMPI on hpc8a
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
OPENFOAM_ENV="${OPENFOAM_ENV:-/fsx/openfoam/x86_64/openfoam-v2512-env.sh}"
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
# The instance type, from IMDS. No answer within a few seconds, an HTTP error,
# or an answer that is not an instance type name (checked in the C locale)
# leaves it empty: see "Rank placement" for what is checked then.
TOKEN=$(curl -fs --connect-timeout 2 --max-time 5 -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" || true)
instanceType=$(curl -fs --connect-timeout 2 --max-time 5 -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type || true)
if ! ( LC_ALL=C; [[ "${instanceType}" =~ ^[a-z][a-z0-9-]*\.[a-z0-9-]+$ ]] ); then instanceType=""; fi

# ---------------------------------------------------------------------------
# Rank placement (Utils/flexible-cores). A full node runs rank i on core i. On
# hpc8a.96xlarge and hpc7a.96xlarge (192 cores in 24 CCDs of 8, one L3 each),
# a node with fewer ranks binds them to the flexible-cores list for its count,
# which puts the same number of ranks on every CCD; any other count would load
# the CCDs unevenly, so it is refused before anything runs. Other instance
# types get no list. When IMDS gives no instance type, lscpu decides: a node
# with 192 AMD cores (sockets x cores per socket) could be either of those two
# types, so it gets the same list or refusal; any other node runs with no list,
# and a NOTE on stderr says that the check was skipped. A full node runs rank i
# on core i with no NOTE, whatever IMDS answers, and no run is refused only
# because IMDS did not answer.
# ---------------------------------------------------------------------------
flexible_cores_list() {  # <ranks per node>: its list in Utils/flexible-cores/hello-cpu.*.explicit.sbatch
    case "$1" in
        24)  echo "0,8,16,24,32,40,48,56,64,72,80,88,96,104,112,120,128,136,144,152,160,168,176,184" ;;
        48)  echo "0,4,8,12,16,20,24,28,32,36,40,44,48,52,56,60,64,68,72,76,80,84,88,92,96,100,104,108,112,116,120,124,128,132,136,140,144,148,152,156,160,164,168,172,176,180,184,188" ;;
        72)  echo "0,1,2,8,9,10,16,17,18,24,25,26,32,33,34,40,41,42,48,49,50,56,57,58,64,65,66,72,73,74,80,81,82,88,89,90,96,97,98,104,105,106,112,113,114,120,121,122,128,129,130,136,137,138,144,145,146,152,153,154,160,161,162,168,169,170,176,177,178,184,185,186" ;;
        96)  echo "0,2,4,6,8,10,12,14,16,18,20,22,24,26,28,30,32,34,36,38,40,42,44,46,48,50,52,54,56,58,60,62,64,66,68,70,72,74,76,78,80,82,84,86,88,90,92,94,96,98,100,102,104,106,108,110,112,114,116,118,120,122,124,126,128,130,132,134,136,138,140,142,144,146,148,150,152,154,156,158,160,162,164,166,168,170,172,174,176,178,180,182,184,186,188,190" ;;
        120) echo "0,1,2,3,4,8,9,10,11,12,16,17,18,19,20,24,25,26,27,28,32,33,34,35,36,40,41,42,43,44,48,49,50,51,52,56,57,58,59,60,64,65,66,67,68,72,73,74,75,76,80,81,82,83,84,88,89,90,91,92,96,97,98,99,100,104,105,106,107,108,112,113,114,115,116,120,121,122,123,124,128,129,130,131,132,136,137,138,139,140,144,145,146,147,148,152,153,154,155,156,160,161,162,163,164,168,169,170,171,172,176,177,178,179,180,184,185,186,187,188" ;;
        144) echo "0,1,2,3,4,5,8,9,10,11,12,13,16,17,18,19,20,21,24,25,26,27,28,29,32,33,34,35,36,37,40,41,42,43,44,45,48,49,50,51,52,53,56,57,58,59,60,61,64,65,66,67,68,69,72,73,74,75,76,77,80,81,82,83,84,85,88,89,90,91,92,93,96,97,98,99,100,101,104,105,106,107,108,109,112,113,114,115,116,117,120,121,122,123,124,125,128,129,130,131,132,133,136,137,138,139,140,141,144,145,146,147,148,149,152,153,154,155,156,157,160,161,162,163,164,165,168,169,170,171,172,173,176,177,178,179,180,181,184,185,186,187,188,189" ;;
        168) echo "0,1,2,3,4,5,6,8,9,10,11,12,13,14,16,17,18,19,20,21,22,24,25,26,27,28,29,30,32,33,34,35,36,37,38,40,41,42,43,44,45,46,48,49,50,51,52,53,54,56,57,58,59,60,61,62,64,65,66,67,68,69,70,72,73,74,75,76,77,78,80,81,82,83,84,85,86,88,89,90,91,92,93,94,96,97,98,99,100,101,102,104,105,106,107,108,109,110,112,113,114,115,116,117,118,120,121,122,123,124,125,126,128,129,130,131,132,133,134,136,137,138,139,140,141,142,144,145,146,147,148,149,150,152,153,154,155,156,157,158,160,161,162,163,164,165,166,168,169,170,171,172,173,174,176,177,178,179,180,181,182,184,185,186,187,188,189,190" ;;
        *)   return 1 ;;
    esac
}
BIND_FLAGS="--bind-to core --map-by slot"
FC_NODE=""   # what the lists apply to, as the job log names it
case "${instanceType}" in
    hpc8a.96xlarge|hpc7a.96xlarge) FC_NODE="${instanceType}" ;;
esac
if [ -z "${instanceType}" ] && [ "${SLURM_NTASKS_PER_NODE}" != 192 ]; then
    _cpu="$(LC_ALL=C lscpu 2>/dev/null | awk -F: '
        /^[[:space:]]*Vendor ID:/            {v = $2}
        /^[[:space:]]*Socket\(s\):/          {s = $2}
        /^[[:space:]]*Core\(s\) per socket:/ {c = $2}
        END {gsub(/[[:space:]]/, "", v); gsub(/[[:space:]]/, "", s); gsub(/[[:space:]]/, "", c)
             if (s ~ /^[0-9]+$/ && c ~ /^[0-9]+$/) print v, s * c}' || true)"
    if [ "${_cpu}" = "AuthenticAMD 192" ]; then
        FC_NODE="hpc8a.96xlarge or hpc7a.96xlarge"
        echo "NOTE: IMDS gave no instance type, and lscpu shows 192 AMD cores, as on an hpc8a.96xlarge" \
             "or hpc7a.96xlarge, so the flexible-cores check applies." >&2
    else
        echo "NOTE: IMDS gave no instance type, and lscpu does not show the 192 AMD cores of an hpc8a.96xlarge" \
             "or hpc7a.96xlarge, so the flexible-cores check is skipped: ${SLURM_NTASKS_PER_NODE} ranks per node run with no list." >&2
    fi
fi
if [ -n "${FC_NODE}" ] && [ "${SLURM_NTASKS_PER_NODE}" != 192 ]; then
    if ! CPU_LIST="$(flexible_cores_list "${SLURM_NTASKS_PER_NODE}")"; then
        echo "ERROR: ${SLURM_NTASKS_PER_NODE} ranks per node would load the 24 CCDs of ${FC_NODE} unevenly;" \
             "the supported counts are 24, 48, 72, 96, 120, 144, 168 and 192 (see Utils/flexible-cores)" >&2
        exit 1
    fi
    BIND_FLAGS="--bind-to cpu-list:ordered --cpu-list ${CPU_LIST}"
    echo "Binding ${SLURM_NTASKS_PER_NODE} ranks per node to the flexible-cores list of ${FC_NODE}"
fi

workdir="${basedir}/Run/${SLURM_JOB_NAME%.*}/${SLURM_CLUSTER_NAME}/${SLURM_JOB_ID}-${SLURM_JOB_NUM_NODES}x${instanceType}-${TOTAL_CORES}-$(date "+%d-%m-%Y-%H-%M")"

echo "=== OCC DrivAer Fine (236M) — OpenMPI ==="
echo "Nodes: ${SLURM_JOB_NUM_NODES}, Cores/node: ${SLURM_NTASKS_PER_NODE}, Total: ${TOTAL_CORES}"
echo "Execution directory: ${workdir}"
mkdir -p "${workdir}" && cd "${workdir}"

# Save launch script
cp "$0" .

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------
set +euo pipefail
source "$OPENFOAM_ENV"
set -euo pipefail

export FI_PROVIDER=efa
export FI_EFA_USE_DEVICE_RDMA=1

MPI_FLAGS="--mca pml cm --mca mtl ofi --mca btl ^tcp,openib --bind-to core --map-by slot"
MPI_FLAGS="$MPI_FLAGS -x PATH -x LD_LIBRARY_PATH -x WM_PROJECT_DIR -x FOAM_LIBBIN -x FOAM_USER_LIBBIN -x FOAM_APPBIN"
MPI_FLAGS="$MPI_FLAGS -x FI_PROVIDER -x FI_EFA_USE_DEVICE_RDMA"
# The solver phases: BIND_FLAGS (see "Rank placement") in place of rank i on core i
SOLVER_MPI_FLAGS="${MPI_FLAGS/--bind-to core --map-by slot/${BIND_FLAGS}}"

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
mpirun -np $SLURM_JOB_NUM_NODES --map-by ppr:1:node $MPI_FLAGS /bin/bash -c "sync && echo 3 | sudo tee /proc/sys/vm/drop_caches"
mpirun -np $SLURM_JOB_NUM_NODES --map-by ppr:1:node $MPI_FLAGS /bin/bash -c "echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled"

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
mpirun -np "$TOTAL_CORES" $SOLVER_MPI_FLAGS renumberMesh -parallel -overwrite 2>&1 | tee log.renumber
T_RENUMBER_END=$(get_timestamp)
RENUMBER_TIME=$(elapsed_seconds "$T_RENUMBER_START" "$T_RENUMBER_END")

T_POTENTIAL_START=$(get_timestamp)
mpirun -np "$TOTAL_CORES" $SOLVER_MPI_FLAGS potentialFoam -parallel 2>&1 | tee log.potential
T_POTENTIAL_END=$(get_timestamp)
POTENTIAL_TIME=$(elapsed_seconds "$T_POTENTIAL_START" "$T_POTENTIAL_END")

T_SOLVE_START=$(get_timestamp)
mpirun -np "$TOTAL_CORES" $SOLVER_MPI_FLAGS simpleFoam -parallel 2>&1 | tee log.solver
T_SOLVE_END=$(get_timestamp)
SOLVE_TIME=$(elapsed_seconds "$T_SOLVE_START" "$T_SOLVE_END")

TOTAL_TIME=$(elapsed_seconds "$T_DECOMP_START" "$T_SOLVE_END")

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
cat << REPORT

================================================================================
OCC DrivAer Fine (236M) — OpenMPI Results
================================================================================
Date:             $(date)
SLURM Job ID:     ${SLURM_JOB_ID}
Cluster:          ${SLURM_CLUSTER_NAME}
Nodes:            ${SLURM_JOB_NUM_NODES}
Cores per node:   ${SLURM_NTASKS_PER_NODE}
Total cores:      ${TOTAL_CORES}
Instance type:    ${instanceType}
MPI:              OpenMPI (EFA)
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
# Check before recording: the run is recorded only if simpleFoam completed
# every iteration on every rank. log.solver must have an "End" line after its
# last "Time =" line, that last time must be endTime in system/controlDict,
# its nProcs must be the ranks of this job, and no log may report a FOAM FATAL
# error or a rank that ended on a signal. A run that does not pass is not
# recorded, and a NOTE says why; the job's exit status and the report above
# are unchanged.
# ---------------------------------------------------------------------------
NOT_RECORDED=""
_end_time="$(awk '/^[[:space:]]*endTime[[:space:]]/ {gsub(";", "", $2); print $2; exit}' system/controlDict 2>/dev/null || true)"
_last_time="$(awk '/^Time = / {t = $3} END {print t}' log.solver 2>/dev/null || true)"
_nprocs="$(awk '/^nProcs[[:space:]]*:/ {print $3; exit}' log.solver 2>/dev/null || true)"
_end_after="$(awk '/^Time = / {e = 0} /^End[[:space:]]*$/ {e = 1} END {print e + 0}' log.solver 2>/dev/null || true)"
if [ "${_end_after}" != 1 ]; then
    NOT_RECORDED="${NOT_RECORDED}; log.solver has no End after its last Time ="
fi
if [ -z "${_last_time}" ] || [ -z "${_end_time}" ] \
        || ! awk -v a="${_last_time}" -v b="${_end_time}" 'BEGIN {exit !(a + 0 == b + 0)}'; then
    NOT_RECORDED="${NOT_RECORDED}; its last Time = is ${_last_time:-missing}, not endTime ${_end_time:-(none)}"
fi
if [ "${_nprocs}" != "${TOTAL_CORES}" ]; then
    NOT_RECORDED="${NOT_RECORDED}; its nProcs is ${_nprocs:-missing}, not the ${TOTAL_CORES} ranks of this job"
fi
if grep -qs 'FOAM FATAL' log.*; then
    NOT_RECORDED="${NOT_RECORDED}; a log reports a FOAM FATAL error"
fi
if grep -qszE 'exited on[[:space:]]+signal|KILLED BY SIGNAL' log.*; then
    NOT_RECORDED="${NOT_RECORDED}; a log reports a rank that ended on a signal"
fi
if [ -n "${NOT_RECORDED}" ]; then
    echo "NOTE: the run is not recorded: ${NOT_RECORDED#; }." >&2
    exit 0
fi

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
# What makes the run comparable with others: its mesh, from the cell count OpenFOAM
# writes in the header of constant/polyMesh/owner ("nCells:"), in millions (a mesh
# under half a million cells, which would round to none, is not recorded), and its
# number of iterations, endTime in system/controlDict.
_cells="$({ head -c 4096 "${CASE_SRC}/constant/polyMesh/owner" 2>/dev/null \
              || gzip -dc "${CASE_SRC}/constant/polyMesh/owner.gz" 2>/dev/null | head -c 4096; } \
            | grep -a -o -m 1 'nCells:[0-9]*' | cut -d: -f2 || true)"
_mesh=""
_mesh_note="cannot tell its mesh size from the header of ${CASE_SRC}/constant/polyMesh/owner (nCells)"
case "${_cells}" in
    ''|*[!0-9]*) ;;
    *) if [ "${_cells}" -ge 500000 ]; then _mesh=$(( (_cells + 500000) / 1000000 ))
       else _mesh_note="its mesh has ${_cells} cells, under half a million (the record gives the mesh in millions)"; fi ;;
esac
_iterations="$(awk '/^[[:space:]]*endTime[[:space:]]/ {gsub(";", "", $2); print $2; exit}' system/controlDict 2>/dev/null || true)"
_recorder="${DYNAMODB_RECORDER:-}"
for _c in "${_recorder}" \
          "${SLURM_SUBMIT_DIR:-.}/../dynamodb/record-benchmark.sh" \
          "${SLURM_SUBMIT_DIR:-.}/dynamodb/record-benchmark.sh" \
          "${SLURM_SUBMIT_DIR:-.}/apps/OpenFoam/dynamodb/record-benchmark.sh"; do
    if [ -n "${_c}" ] && [ -x "${_c}" ]; then _recorder="${_c}"; break; fi
done
if [ -z "${_mesh}" ]; then
    echo "NOTE: the run is not recorded: ${_mesh_note}." >&2
elif [ -n "${_recorder}" ] && [ -x "${_recorder}" ]; then
    OPENFOAM_VERSION="${_of_version}" BENCHMARK_CASE="occDrivAer-${_mesh}M" \
    MESH_CELLS_MILLION="${_mesh}" SOLVER="simpleFoam" \
    TIME_TO_SOLUTION="${SOLVE_TIME}" RUN_DIR="${workdir}" "${_recorder}" --metric "num_iterations=${_iterations}" \
        || echo "NOTE: benchmark recorder failed (non-fatal); the solve was unaffected." >&2
else
    echo "NOTE: benchmark recorder not found; set DYNAMODB_RECORDER=/path/to/record-benchmark.sh to record." >&2
fi
