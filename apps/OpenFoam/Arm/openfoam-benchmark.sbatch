#!/bin/bash
# OCC DrivAer Static Mesh — OpenMPI on AWS Graviton (Arm)
# Works for hpc7g (Graviton3E, 64 cores/node) and m8g/r8g (Graviton4, 192 cores/node)
# Select the build via the OPENFOAM_ENV variable.
#
# Uses OpenMPI 5 (openmpi5/5.0.9amzn1) which correctly handles EFA with full-density
# rank placement on Graviton4 (OpenMPI 4.1.7 fails at 192 ranks/node).
#
# Mesh size is selectable via MESH_SIZE (65, 110, or 236 million cells).
# Default is 65M ("coarse") which fits within the 124 GB RAM of hpc7g.16xlarge
# during the serial decomposePar phase. Use 236M ("fine") on m8g (747 GB) for
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

# ---------------------------------------------------------------------------
# Working directory (follows Fluent convention; all output on FSx Lustre)
# ---------------------------------------------------------------------------
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
instanceType=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type)
workdir="${basedir}/Run/${SLURM_JOB_NAME%.*}/${SLURM_CLUSTER_NAME}/${SLURM_JOB_ID}-${SLURM_JOB_NUM_NODES}x${instanceType}-${TOTAL_CORES}-$(date "+%d-%m-%Y-%H-%M")"

echo "=== OCC DrivAer Static Mesh (${MESH_SIZE}M cells) — OpenMPI (Arm) ==="
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
# OpenMPI 4.1.7 (default) has EFA endpoint limits that fail at 192 ranks/node
# on Graviton4. OpenMPI 5.0.9 handles full-density EFA correctly on both
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
# To limit iterations for quick benchmarking, uncomment the next line:
# sed -i '/^[[:space:]]*endTime[[:space:]]/s/endTime.*/endTime         200;/' system/controlDict

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
OCC DrivAer Static Mesh (${MESH_SIZE}M) — OpenMPI (Arm) Results
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
Renumber:         ${RENUMBER_TIME}s
potentialFoam:    ${POTENTIAL_TIME}s
simpleFoam:       ${SOLVE_TIME}s
Total:            ${TOTAL_TIME}s
================================================================================
REPORT
