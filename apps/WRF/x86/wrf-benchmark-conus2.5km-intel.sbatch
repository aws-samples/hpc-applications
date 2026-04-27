#!/bin/bash
# WRF CONUS 2.5km Benchmark on hpc8a — Intel MPI
# Grid: 1501x1201, timestep: 15s
#SBATCH --job-name=wrf-c25-impi
#SBATCH -p hpc8a
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=192
#SBATCH --time=04:00:00
#SBATCH --exclusive

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
WRF_ENV="${WRF_ENV:-/fsx/wrf/wrf-4.6.1-intel-env.sh}"
CONUS_DIR="${CONUS_DIR:-/fsx/wrf/conus_2.5km}"
basedir="${BASE_DIR:-/fsx/wrf}"
TOTAL_CORES=$(( SLURM_JOB_NUM_NODES * SLURM_NTASKS_PER_NODE ))

# ---------------------------------------------------------------------------
# Working directory
# ---------------------------------------------------------------------------
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
instanceType=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type)
workdir="${basedir}/Run/${SLURM_JOB_NAME%.*}/${SLURM_CLUSTER_NAME}/${SLURM_JOB_ID}-${SLURM_JOB_NUM_NODES}x${instanceType}-${TOTAL_CORES}-$(date "+%d-%m-%Y-%H-%M")"

echo "=== WRF CONUS 2.5km Benchmark (Intel MPI) ==="
echo "Nodes: ${SLURM_JOB_NUM_NODES}, Cores/node: ${SLURM_NTASKS_PER_NODE}, Total: ${TOTAL_CORES}"
echo "Execution directory: ${workdir}"
mkdir -p "${workdir}" && cd "${workdir}"

cp "$0" .

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------
set +euo pipefail
source "$WRF_ENV"
set -euo pipefail

# Intel MPI + EFA settings
export I_MPI_FABRICS=shm:ofi
export I_MPI_OFI_LIBRARY_INTERNAL=0
export I_MPI_OFI_PROVIDER=efa
export FI_PROVIDER=efa
export FI_EFA_USE_DEVICE_RDMA=1
export I_MPI_PIN_DOMAIN=core
export I_MPI_PIN_ORDER=compact
export I_MPI_MULTIRAIL=1

# ---------------------------------------------------------------------------
# Prepare case
# ---------------------------------------------------------------------------
echo "=== Preparing CONUS 2.5km case ==="
if [ ! -f "$CONUS_DIR/wrfinput_d01" ]; then
    echo "ERROR: CONUS 2.5km data not found at $CONUS_DIR"
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
# Thompson microphysics data files (included in 2.5km benchmark)
for f in "$CONUS_DIR"/*.dat; do
    [ -f "$f" ] && ln -sf "$f" .
done

wrf_exe="$WRF_DIR/main/wrf.exe"
if [ ! -x "$wrf_exe" ]; then
    wrf_exe="$WRF_DIR/test/em_real/wrf.exe"
fi
if [ ! -x "$wrf_exe" ]; then
    wrf_exe="$WRF_DIR/run/wrf.exe"
fi

echo "WRF executable: $wrf_exe"

# ---------------------------------------------------------------------------
# Build hostfile
# ---------------------------------------------------------------------------
scontrol show nodes $SLURM_NODELIST | grep NodeHostName= | awk '{print $2}' | sed 's/NodeHostName=//' > hostfile

# ---------------------------------------------------------------------------
# System prep
# ---------------------------------------------------------------------------
echo "=== Drop caches and enable THP ==="
srun --ntasks-per-node=1 /bin/bash -c "sync && echo 3 | sudo tee /proc/sys/vm/drop_caches"
srun --ntasks-per-node=1 /bin/bash -c "echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled"

ulimit -s unlimited

get_timestamp() { date +%s.%N; }
elapsed_seconds() { echo "$2 $1" | awk '{printf "%.2f", $1 - $2}'; }

# ---------------------------------------------------------------------------
# Run WRF
# ---------------------------------------------------------------------------
echo "=== Running WRF (Intel MPI) ==="
T_START=$(get_timestamp)

mpirun -np "$TOTAL_CORES" \
    -ppn "$SLURM_NTASKS_PER_NODE" \
    -hostfile hostfile \
    "$wrf_exe" 2>&1 | tee log.wrf

T_END=$(get_timestamp)
WRF_TIME=$(elapsed_seconds "$T_START" "$T_END")

# ---------------------------------------------------------------------------
# Check results and extract timing
# ---------------------------------------------------------------------------
echo "=== Checking results ==="
AVG_STEP="N/A"
if [ -f rsl.error.0000 ]; then
    if grep -q "SUCCESS COMPLETE WRF" rsl.error.0000; then
        echo "SUCCESS: WRF completed successfully"
    else
        echo "WARNING: WRF may not have completed"
    fi
    echo "=== Timing from rsl.error.0000 ==="
    grep "Timing for main" rsl.error.0000 | tail -5
    AVG_STEP=$(grep "Timing for main" rsl.error.0000 | awk '{sum+=$9; n++} END {if(n>0) printf "%.2f", sum/n; else print "N/A"}')
    echo "Average time per timestep: ${AVG_STEP}s"
fi

if ls wrfout_d01_* &>/dev/null; then
    echo "Output files:"
    ls -lh wrfout_d01_*
fi

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
cat << REPORT

================================================================================
WRF CONUS 2.5km Benchmark Results (Intel MPI)
================================================================================
Date:             $(date)
SLURM Job ID:     ${SLURM_JOB_ID}
Cluster:          ${SLURM_CLUSTER_NAME}
Nodes:            ${SLURM_JOB_NUM_NODES}
Cores per node:   ${SLURM_NTASKS_PER_NODE}
Total cores:      ${TOTAL_CORES}
Instance type:    ${instanceType}
MPI:              Intel MPI (EFA)
Working dir:      ${workdir}

Total WRF time:   ${WRF_TIME}s
Avg timestep:     ${AVG_STEP}s
================================================================================
REPORT
