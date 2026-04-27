#!/bin/bash
# WRF CONUS benchmark launcher for AWS Graviton (Arm)
# Works for hpc7g (Graviton3E) and m8g / r8g (Graviton4). Select the build
# via WRF_ENV and the benchmark case via BENCHMARK (12km or 2.5km).
#
# The env script pointed to by WRF_ENV knows which OpenMPI to load — this
# script is MPI-version agnostic. For Graviton4 use the -ompi5 env script
# (OpenMPI 4.1.7 hits the EFA endpoint limit at 192 ranks/node).
#
# Examples:
#   # Graviton3E, CONUS 12km (default), OpenMPI 4
#   sbatch -p hpc7g -N 4 --ntasks-per-node=64 \
#       --export=ALL,WRF_ENV=/fsx/wrf/aarch64-graviton3/wrf-4.6.1-env.sh \
#       wrf-benchmark.sbatch
#
#   # Graviton4, CONUS 2.5km, OpenMPI 5
#   sbatch -p m8g -N 4 --ntasks-per-node=192 \
#       --export=ALL,WRF_ENV=/fsx/wrf/aarch64-graviton4-ompi5/wrf-4.6.1-ompi5-env.sh,BENCHMARK=2.5km \
#       wrf-benchmark.sbatch

#SBATCH --job-name=wrf-arm
#SBATCH -p hpc7g
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=64
#SBATCH --time=04:00:00
#SBATCH --exclusive

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
WRF_ENV="${WRF_ENV:-/fsx/wrf/aarch64-graviton3/wrf-4.6.1-env.sh}"
BENCHMARK="${BENCHMARK:-12km}"   # 12km | 2.5km
basedir="${BASE_DIR:-/fsx/wrf}"
TOTAL_CORES=$(( SLURM_JOB_NUM_NODES * SLURM_NTASKS_PER_NODE ))

case "$BENCHMARK" in
    12km)  CONUS_DIR="${CONUS_DIR:-/fsx/wrf/conus_12km}";  GRID="425x300";  DT="60s"  ;;
    2.5km) CONUS_DIR="${CONUS_DIR:-/fsx/wrf/conus_2.5km}"; GRID="1501x1201"; DT="15s" ;;
    *) echo "ERROR: BENCHMARK must be 12km or 2.5km (got: $BENCHMARK)"; exit 1 ;;
esac

# ---------------------------------------------------------------------------
# Working directory
# ---------------------------------------------------------------------------
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
instanceType=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type)
workdir="${basedir}/Run/${SLURM_JOB_NAME%.*}/${SLURM_CLUSTER_NAME}/${SLURM_JOB_ID}-${SLURM_JOB_NUM_NODES}x${instanceType}-${TOTAL_CORES}-$(date "+%d-%m-%Y-%H-%M")"

echo "=== WRF CONUS ${BENCHMARK} Benchmark (Arm, grid ${GRID}, dt ${DT}) ==="
echo "Nodes: ${SLURM_JOB_NUM_NODES}, Cores/node: ${SLURM_NTASKS_PER_NODE}, Total: ${TOTAL_CORES}"
echo "Instance: ${instanceType}"
echo "WRF_ENV:  ${WRF_ENV}"
echo "CONUS_DIR: ${CONUS_DIR}"
echo "Run dir:  ${workdir}"
mkdir -p "${workdir}" && cd "${workdir}"

cp "$0" .

# ---------------------------------------------------------------------------
# Environment — source WRF env script (it handles MPI selection + PATH),
# then load libfabric-aws for the EFA provider libraries.
# ---------------------------------------------------------------------------
set +euo pipefail
source /etc/profile.d/modules.sh 2>/dev/null || . /usr/share/Modules/init/bash 2>/dev/null || true
source "$WRF_ENV"
module load libfabric-aws 2>/dev/null || true
set -euo pipefail

which mpirun
mpirun --version 2>&1 | head -1

# ---------------------------------------------------------------------------
# EFA / OFI tuning
# ---------------------------------------------------------------------------
export FI_PROVIDER=efa
export FI_EFA_USE_DEVICE_RDMA=1
export RDMAV_FORK_SAFE=1

# WRF was built as dm+sm (hybrid MPI+OpenMP). We run it pure-MPI here — one
# MPI rank per core with OMP_NUM_THREADS=1 — which is the configuration that
# gets the best performance on Graviton and avoids an OpenMP/pinning
# interaction that causes the first timestep to hang on hpc7g (Graviton3E).
export OMP_NUM_THREADS=1

# Use SSH bootstrap for OpenMPI rather than Slurm/prterun. Slurm-integrated
# prterun has shown intermittent init deadlocks on Graviton at multi-node
# scale; plain ssh launching avoids that path and matches how the Fluent Arm
# launcher works on this cluster.
# NOTE: no `--bind-to core` — combined with pure-MPI OMP=1 on hpc7g it deadlocks
# on the first collective. Let OpenMPI pick a default binding policy.
#        OMPI5 also rejects duplicate --map-by flags — put --map-by only on
# solver mpirun calls, not on MPI_FLAGS (so ppr:1:node prep calls can override).
MPI_FLAGS="--mca plm_rsh_agent ssh --mca pml cm --mca mtl ofi --mca btl ^tcp,openib"
MPI_FLAGS="$MPI_FLAGS -x PATH -x LD_LIBRARY_PATH -x WRF_DIR -x OMP_NUM_THREADS"
MPI_FLAGS="$MPI_FLAGS -x FI_PROVIDER -x FI_EFA_USE_DEVICE_RDMA -x RDMAV_FORK_SAFE"

# ---------------------------------------------------------------------------
# Prepare case
# ---------------------------------------------------------------------------
echo "=== Preparing CONUS ${BENCHMARK} case ==="
if [ ! -f "$CONUS_DIR/wrfinput_d01" ]; then
    echo "ERROR: CONUS ${BENCHMARK} data not found at $CONUS_DIR"
    if [ "$BENCHMARK" = "2.5km" ]; then
        echo "Download manually from NCAR:"
        echo "  mkdir -p $CONUS_DIR && cd $CONUS_DIR"
        echo "  curl -LO https://www2.mmm.ucar.edu/wrf/users/benchmark/v44/v4.4_bench_conus2.5km.tar.gz"
        echo "  tar xzf v4.4_bench_conus2.5km.tar.gz && mv v4.4_bench_conus2.5km/* . && rmdir v4.4_bench_conus2.5km"
    else
        echo "Run the build script first (it downloads the 12km benchmark data)."
    fi
    exit 1
fi

ln -sf "$CONUS_DIR"/wrfinput_d01 .
ln -sf "$CONUS_DIR"/wrfbdy_d01 .
cp "$CONUS_DIR"/namelist.input .

# Link WRF run files
ln -sf "$WRF_DIR"/test/em_real/RRTMG_* . 2>/dev/null || true
ln -sf "$WRF_DIR"/test/em_real/*.TBL . 2>/dev/null || true
ln -sf "$WRF_DIR"/test/em_real/ozone* . 2>/dev/null || true
ln -sf "$WRF_DIR"/test/em_real/CAMtr_volume_mixing_ratio* . 2>/dev/null || true
# Thompson microphysics data files (only present in 2.5km benchmark tarball)
for f in "$CONUS_DIR"/*.dat; do
    [ -f "$f" ] && ln -sf "$f" .
done

wrf_exe="$WRF_DIR/test/em_real/wrf.exe"
[ -x "$wrf_exe" ] || wrf_exe="$WRF_DIR/run/wrf.exe"
echo "WRF executable: $wrf_exe"

# ---------------------------------------------------------------------------
# Build hostfile
# ---------------------------------------------------------------------------
# Build hostfile with slots per node (required for SSH bootstrap)
scontrol show nodes $SLURM_NODELIST | grep NodeHostName= | awk '{print $2}' | sed 's/NodeHostName=//' | \
    awk -v n="$SLURM_NTASKS_PER_NODE" '{print $0" slots="n}' > hostfile
echo "Hostfile:"
cat hostfile

# ---------------------------------------------------------------------------
# System prep
# ---------------------------------------------------------------------------
echo "=== Drop caches and enable THP ==="
mpirun -np $SLURM_JOB_NUM_NODES --map-by ppr:1:node --hostfile hostfile $MPI_FLAGS /bin/bash -c "sync && echo 3 | sudo tee /proc/sys/vm/drop_caches"
mpirun -np $SLURM_JOB_NUM_NODES --map-by ppr:1:node --hostfile hostfile $MPI_FLAGS /bin/bash -c "echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled"

ulimit -s unlimited

get_timestamp() { date +%s.%N; }
elapsed_seconds() { echo "$2 $1" | awk '{printf "%.2f", $1 - $2}'; }

# ---------------------------------------------------------------------------
# Run WRF
# ---------------------------------------------------------------------------
echo "=== Running WRF ==="
T_START=$(get_timestamp)

mpirun -np "$TOTAL_CORES" --map-by slot --hostfile hostfile $MPI_FLAGS "$wrf_exe" 2>&1 | tee log.wrf

T_END=$(get_timestamp)
WRF_TIME=$(elapsed_seconds "$T_START" "$T_END")

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
echo "=== Checking results ==="
AVG_STEP="N/A"
if [ -f rsl.error.0000 ]; then
    if grep -q "SUCCESS COMPLETE WRF" rsl.error.0000; then
        echo "SUCCESS: WRF completed"
    else
        echo "WARNING: WRF may not have completed successfully"
    fi
    grep "Timing for main" rsl.error.0000 | tail -5
    AVG_STEP=$(grep "Timing for main" rsl.error.0000 | awk '{sum+=$9; n++} END {if(n>0) printf "%.2f", sum/n; else print "N/A"}')
fi

cat << REPORT

================================================================================
WRF CONUS ${BENCHMARK} — Arm Benchmark Results
================================================================================
Date:             $(date)
SLURM Job ID:     ${SLURM_JOB_ID}
Cluster:          ${SLURM_CLUSTER_NAME}
Nodes:            ${SLURM_JOB_NUM_NODES}
Cores per node:   ${SLURM_NTASKS_PER_NODE}
Total cores:      ${TOTAL_CORES}
Instance type:    ${instanceType}
MPI:              OpenMPI (EFA)
WRF_ENV:          ${WRF_ENV}
Benchmark:        CONUS ${BENCHMARK} (grid ${GRID}, dt ${DT})
Working dir:      ${workdir}

Total WRF time:   ${WRF_TIME}s
Avg timestep:     ${AVG_STEP}s
================================================================================
REPORT
