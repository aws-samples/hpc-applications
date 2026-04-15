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

# ---------------------------------------------------------------------------
# Working directory (follows Fluent convention)
# ---------------------------------------------------------------------------
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
instanceType=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type)
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
# Only replace the endTime value line (not stopAt which contains 'endTime')
sed -i '/^[[:space:]]*endTime[[:space:]]/s/endTime.*/endTime         200;/' system/controlDict

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
# ---------------------------------------------------------------------------
echo "=== Decomposition ==="
T_DECOMP_START=$(get_timestamp)

cat > system/decomposeParDict << EOF
FoamFile { version 2.0; format ascii; class dictionary; object decomposeParDict; }
numberOfSubdomains ${TOTAL_CORES};
method simple;
simpleCoeffs { n (${SLURM_JOB_NUM_NODES} 1 $(( SLURM_NTASKS_PER_NODE ))); }
EOF

decomposePar 2>&1 | tee log.decomposePar

T_DECOMP_END=$(get_timestamp)
DECOMP_TIME=$(elapsed_seconds "$T_DECOMP_START" "$T_DECOMP_END")
echo "Decomposition time: ${DECOMP_TIME}s"

# ---------------------------------------------------------------------------
# Solver
# ---------------------------------------------------------------------------
echo "=== Solver phase ==="
T_RENUMBER_START=$(get_timestamp)
mpirun -np "$TOTAL_CORES" $MPI_FLAGS renumberMesh -parallel -overwrite 2>&1 | tee log.renumber
T_RENUMBER_END=$(get_timestamp)
RENUMBER_TIME=$(elapsed_seconds "$T_RENUMBER_START" "$T_RENUMBER_END")

T_POTENTIAL_START=$(get_timestamp)
mpirun -np "$TOTAL_CORES" $MPI_FLAGS potentialFoam -parallel 2>&1 | tee log.potential
T_POTENTIAL_END=$(get_timestamp)
POTENTIAL_TIME=$(elapsed_seconds "$T_POTENTIAL_START" "$T_POTENTIAL_END")

T_SOLVE_START=$(get_timestamp)
mpirun -np "$TOTAL_CORES" $MPI_FLAGS simpleFoam -parallel 2>&1 | tee log.solver
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
Renumber:         ${RENUMBER_TIME}s
potentialFoam:    ${POTENTIAL_TIME}s
simpleFoam:       ${SOLVE_TIME}s
Total:            ${TOTAL_TIME}s
================================================================================
REPORT
