#!/bin/bash
# OCC DrivAer Static Mesh — OpenMPI on AWS Graviton (Arm)
# Works for hpc7g (Graviton3E, 64 cores/node) and m8g/r8g (Graviton4, 192 cores/node)
# Select the build via the OPENFOAM_ENV variable.
#
# Uses OpenMPI 5 (openmpi5/5.0.9amzn1) for EFA with full-density rank placement
# (Graviton4 at 192 ranks per node needs OpenMPI 5).
#
# Mesh size is selectable via MESH_SIZE (65, 110, or 236 million cells).
# Default is 65M ("coarse"), which fits the 128 GiB of one hpc7g.16xlarge
# during the serial decomposePar phase. Use 236M ("fine") on m8g (768 GiB) for
# a larger, more representative workload.
#
# Examples:
#   # Graviton3E (hpc7g.16xlarge, 64 cores/node, 65M coarse mesh)
#   sbatch -p hpc7g -N 4 --ntasks-per-node=64 \
#       --export=ALL,OPENFOAM_ENV=/fsx/openfoam/aarch64-graviton3/openfoam-v2512-env.sh \
#       openfoam-benchmark.sbatch
#
#   # Graviton4 (m8g.48xlarge, 192 cores/node, 236M fine mesh)
#   sbatch -p m8g -N 4 --ntasks-per-node=192 \
#       --export=ALL,OPENFOAM_ENV=/fsx/openfoam/aarch64-graviton4/openfoam-v2512-env.sh,MESH_SIZE=236 \
#       openfoam-benchmark.sbatch

#SBATCH --job-name=occ-drivaer-arm
#SBATCH -p hpc7g
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=64
#SBATCH --time=10:00:00
#SBATCH --exclusive

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
OPENFOAM_ENV="${OPENFOAM_ENV:-/fsx/openfoam/aarch64-graviton3/openfoam-v2512-env.sh}"
MESH_SIZE="${MESH_SIZE:-65}"   # 65 | 110 | 236 (million cells)
CASE_SRC="${CASE_SRC:-/fsx/openfoam/occ-drivaer/occDrivAerStaticMesh-${MESH_SIZE}M}"
basedir="${BASE_DIR:-/fsx/openfoam}"
TOTAL_CORES=$(( SLURM_JOB_NUM_NODES * SLURM_NTASKS_PER_NODE ))

case "$MESH_SIZE" in
    65|110|236) ;;
    *) echo "ERROR: MESH_SIZE must be 65, 110, or 236 (got: $MESH_SIZE)"; exit 1 ;;
esac
# SIMPLE iterations (endTime): 200, as every result in ../README.md ran; the case ships with 4000
END_TIME="${END_TIME:-200}"
case "${END_TIME}" in
    ''|0*|*[!0-9]*) echo "ERROR: END_TIME must be a whole number of iterations, 1 or more (got: ${END_TIME})" >&2; exit 1 ;;
esac

# ---------------------------------------------------------------------------
# Working directory (follows Fluent convention; all output on FSx Lustre)
# ---------------------------------------------------------------------------
# The instance type, from IMDS, for the run directory's name and the job log
# only. Each request gives up after 5 seconds (2 to connect), and -f turns an
# HTTP error into no answer. No answer, an answer cut off at that limit, or an
# answer that is not an instance type name (checked in the C locale) leaves
# it empty, and the job goes on: the run directory's name then has no
# instance type, as on the x86 scripts.
TOKEN=$(curl -fs --connect-timeout 2 --max-time 5 -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600") || TOKEN=""
instanceType=$(curl -fs --connect-timeout 2 --max-time 5 -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type) || instanceType=""
if ! ( LC_ALL=C; [[ "${instanceType}" =~ ^[a-z][a-z0-9-]*\.[a-z0-9-]+$ ]] ); then instanceType=""; fi
workdir="${basedir}/Run/${SLURM_JOB_NAME%.*}/${SLURM_CLUSTER_NAME}/${SLURM_JOB_ID}-${SLURM_JOB_NUM_NODES}x${instanceType}-${TOTAL_CORES}-$(date "+%d-%m-%Y-%H-%M")"

echo "=== OCC DrivAer, the case and mesh in ${CASE_SRC} — OpenMPI (Arm) ==="
echo "Nodes: ${SLURM_JOB_NUM_NODES}, Cores/node: ${SLURM_NTASKS_PER_NODE}, Total: ${TOTAL_CORES}"
echo "Instance type: ${instanceType}"
echo "OPENFOAM_ENV: ${OPENFOAM_ENV}"
echo "Execution directory: ${workdir}"
mkdir -p "${workdir}" && cd "${workdir}"

# Save launch script
cp "$0" .

# ---------------------------------------------------------------------------
# OpenFOAM environment (OpenFOAM's bashrc sets MPI_ROOT / paths)
# ---------------------------------------------------------------------------
set +euo pipefail
source "$OPENFOAM_ENV"
set -euo pipefail

# ---------------------------------------------------------------------------
# Load OpenMPI 5 AFTER sourcing OpenFOAM so it takes precedence in PATH
# Graviton4 at 192 ranks per node over EFA needs OpenMPI 5 rather than the
# default OpenMPI 4.1.7. OpenMPI 5.0.9 runs full-density EFA on both
# Graviton3E (64 cores) and Graviton4 (192 cores). OMPI 4 and 5 share the same
# libmpi.so.40 ABI, so OpenFOAM binaries built with OMPI 4 run under OMPI 5.
# ---------------------------------------------------------------------------
echo "=== Loading OpenMPI 5 (EFA-enabled) ==="
set +euo pipefail
source /etc/profile.d/modules.sh 2>/dev/null || . /usr/share/Modules/init/bash 2>/dev/null || true
module unload openmpi 2>/dev/null || true
module load libfabric-aws openmpi5
# Force PATH/LD_LIBRARY_PATH to put openmpi5 first, overriding any OMPI4
# paths added by the OpenFOAM env script.
OMPI5_ROOT="${MPI_ROOT:-/opt/amazon/openmpi5}"
if [ -d "$OMPI5_ROOT/bin" ]; then
    export PATH="$OMPI5_ROOT/bin:$PATH"
    export LD_LIBRARY_PATH="$OMPI5_ROOT/lib:$OMPI5_ROOT/lib64:${LD_LIBRARY_PATH:-}"
fi
set -euo pipefail

which mpirun
mpirun --version 2>&1 | head -1

# ---------------------------------------------------------------------------
# EFA / OFI tuning for best performance
# ---------------------------------------------------------------------------
export FI_PROVIDER=efa
export FI_EFA_USE_DEVICE_RDMA=1
export RDMAV_FORK_SAFE=1

# OpenMPI 5 uses PRRTE/prterun under the hood. Keep the MCA path that ships
# with the amzn EFA stack: CM PML + OFI MTL (zero-copy EFA fast path).
# NOTE: OMPI5 rejects duplicate --map-by flags — put --map-by only on solver
# mpirun calls, not on MPI_FLAGS (so ppr:1:node calls can still override).
MPI_FLAGS="--mca pml cm --mca mtl ofi --mca btl ^tcp,openib --bind-to core"
MPI_FLAGS="$MPI_FLAGS -x PATH -x LD_LIBRARY_PATH"
MPI_FLAGS="$MPI_FLAGS -x WM_PROJECT_DIR -x FOAM_LIBBIN -x FOAM_USER_LIBBIN -x FOAM_APPBIN"
MPI_FLAGS="$MPI_FLAGS -x FI_PROVIDER -x FI_EFA_USE_DEVICE_RDMA -x RDMAV_FORK_SAFE"

# ---------------------------------------------------------------------------
# Build hostfile
# ---------------------------------------------------------------------------
echo "=== Building hostfile ==="
scontrol show nodes $SLURM_NODELIST | grep NodeHostName= | awk '{print $2}' | sed 's/NodeHostName=//' > hostfile
cat hostfile

# ---------------------------------------------------------------------------
# Download case and mesh if not present (cached on /fsx, one-time)
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
    echo "=== Downloading ${MESH_SIZE}M mesh from Zenodo ==="
    curl -L -o "$CASE_SRC/constant/polyMesh_${MESH_SIZE}M.tar.gz" \
        "https://zenodo.org/records/15012221/files/polyMesh_${MESH_SIZE}M.tar.gz?download=1"
    tar xzf "$CASE_SRC/constant/polyMesh_${MESH_SIZE}M.tar.gz" -C "$CASE_SRC/constant/"
    rm -f "$CASE_SRC/constant/polyMesh_${MESH_SIZE}M.tar.gz"
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
# Solver phases
# ---------------------------------------------------------------------------
echo "=== Solver phase ==="
T_RENUMBER_START=$(get_timestamp)
mpirun -np "$TOTAL_CORES" --map-by slot $MPI_FLAGS renumberMesh -parallel -overwrite 2>&1 | tee log.renumber
T_RENUMBER_END=$(get_timestamp)
RENUMBER_TIME=$(elapsed_seconds "$T_RENUMBER_START" "$T_RENUMBER_END")

T_POTENTIAL_START=$(get_timestamp)
mpirun -np "$TOTAL_CORES" --map-by slot $MPI_FLAGS potentialFoam -parallel 2>&1 | tee log.potential
T_POTENTIAL_END=$(get_timestamp)
POTENTIAL_TIME=$(elapsed_seconds "$T_POTENTIAL_START" "$T_POTENTIAL_END")

T_SOLVE_START=$(get_timestamp)
mpirun -np "$TOTAL_CORES" --map-by slot $MPI_FLAGS simpleFoam -parallel 2>&1 | tee log.solver
T_SOLVE_END=$(get_timestamp)
SOLVE_TIME=$(elapsed_seconds "$T_SOLVE_START" "$T_SOLVE_END")

TOTAL_TIME=$(elapsed_seconds "$T_DECOMP_START" "$T_SOLVE_END")

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
cat << REPORT

================================================================================
OCC DrivAer, the case and mesh in ${CASE_SRC} — OpenMPI (Arm) Results
================================================================================
Date:             $(date)
SLURM Job ID:     ${SLURM_JOB_ID}
Cluster:          ${SLURM_CLUSTER_NAME}
Nodes:            ${SLURM_JOB_NUM_NODES}
Cores per node:   ${SLURM_NTASKS_PER_NODE}
Total cores:      ${TOTAL_CORES}
Instance type:    ${instanceType}
MPI:              OpenMPI 5 (EFA)
OPENFOAM_ENV:     ${OPENFOAM_ENV}
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
