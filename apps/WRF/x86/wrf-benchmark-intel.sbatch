#!/bin/bash
# WRF CONUS 12km Benchmark on hpc8a — Intel MPI variant
# Based on: https://catalog.workshops.aws/nwp-on-aws/en-US/2-wrf
#SBATCH --job-name=wrf-conus12-intel
#SBATCH -p hpc8a
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=192
#SBATCH --time=02:00:00
#SBATCH --exclusive

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
WRF_ENV="${WRF_ENV:-/fsx/wrf/wrf-4.6.1-intel-env.sh}"
CONUS_DIR="${CONUS_DIR:-/fsx/wrf/conus_12km}"
basedir="${BASE_DIR:-/fsx/wrf}"
TOTAL_CORES=$(( SLURM_JOB_NUM_NODES * SLURM_NTASKS_PER_NODE ))

# ---------------------------------------------------------------------------
# Working directory
# ---------------------------------------------------------------------------
# The instance type, from the instance metadata (IMDSv2). Each request gives up
# after 5 seconds (2 to connect), and -f turns an HTTP error into no answer. An
# answer that is not an instance type name (tested in the C locale: in some
# locales [a-z] leaves out i) counts as none, so it never names the run directory.
TOKEN=$(curl -fs --connect-timeout 2 --max-time 5 -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600") || TOKEN=""
instanceType=$(curl -fs --connect-timeout 2 --max-time 5 -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type) || instanceType=""
( LC_ALL=C; [[ "${instanceType}" =~ ^[a-z][a-z0-9-]*\.[a-z0-9-]+$ ]] ) || instanceType=""
# Ranks per node on hpc8a.96xlarge and hpc7a.96xlarge: their 192 cores sit in
# 24 CCDs of 8, one L3 cache each, and only 24, 48, 72, 96, 120, 144, 168 or
# 192 ranks per node put the same number of ranks on every CCD
# (Utils/flexible-cores). On those two types any other count stops the job
# here, before the run directory and mpirun. Other instance types and sizes are
# not checked. When the instance metadata gives no instance type (no answer in
# time, an HTTP error, or an answer that is not an instance type name), such a
# count stops the job on a node with 192 AMD cores (lscpu, read in the C
# locale: sockets x cores per socket), which could be one of the two; any other
# node runs it, with a NOTE that the check was skipped, so no run stops only
# because the instance metadata did not answer. A supported count below 192
# keeps the pinning below, which the README's results used on full nodes; the
# README says how to pin it with that count's flexible-cores list instead.
case "${SLURM_NTASKS_PER_NODE}" in
    24|48|72|96|120|144|168|192) ;;
    *)  _counts="run 24, 48, 72, 96, 120, 144, 168 or 192 ranks per node there (Utils/flexible-cores), and below 192 also replace this script's pinning with that count's list (README, Fewer ranks per node). Not starting WRF."
        case "${instanceType}" in
            hpc8a.96xlarge|hpc7a.96xlarge)
                echo "ERROR: ${SLURM_NTASKS_PER_NODE} ranks per node load the 24 CCDs of ${instanceType} unevenly; ${_counts}" >&2
                exit 1 ;;
        esac
        if [ -z "${instanceType}" ]; then
            _amd_192="$(LC_ALL=C lscpu 2>/dev/null | LC_ALL=C awk -F: '
                { k = $1; sub(/^[[:space:]]+/, "", k); v = $2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", v) }
                k == "Vendor ID" { vendor = v }
                k == "Socket(s)" { sockets = v }
                k == "Core(s) per socket" { cores = v }
                END { if (vendor == "AuthenticAMD" && sockets ~ /^[0-9]+$/ && cores ~ /^[0-9]+$/ &&
                          sockets * cores == 192) print "yes" }')" || _amd_192=""
            if [ "${_amd_192}" = yes ]; then
                echo "ERROR: ${SLURM_NTASKS_PER_NODE} ranks per node load the 24 CCDs of hpc8a.96xlarge and hpc7a.96xlarge unevenly, and this node could be either (the instance metadata gave no instance type, and lscpu shows 192 AMD cores); ${_counts}" >&2
                exit 1
            fi
            echo "NOTE: the instance metadata gave no instance type, and lscpu does not show the 192 AMD cores of hpc8a.96xlarge and hpc7a.96xlarge, so the ranks-per-node check (Utils/flexible-cores) is skipped: running ${SLURM_NTASKS_PER_NODE} ranks per node." >&2
        fi ;;
esac
workdir="${basedir}/Run/${SLURM_JOB_NAME%.*}/${SLURM_CLUSTER_NAME}/${SLURM_JOB_ID}-${SLURM_JOB_NUM_NODES}x${instanceType}-${TOTAL_CORES}-$(date "+%d-%m-%Y-%H-%M")"

echo "=== WRF CONUS 12km Benchmark (Intel MPI) ==="
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

# ---------------------------------------------------------------------------
# Prepare case
# ---------------------------------------------------------------------------
echo "=== Preparing CONUS 12km case ==="
if [ ! -f "$CONUS_DIR/wrfinput_d01" ]; then
    echo "ERROR: CONUS 12km data not found at $CONUS_DIR"
    echo "Run the build script first: sbatch build_wrf_intel.sbatch"
    exit 1
fi

# Link input data
ln -sf "$CONUS_DIR"/wrfinput_d01 .
ln -sf "$CONUS_DIR"/wrfbdy_d01 .
cp "$CONUS_DIR"/namelist.input .

# Link WRF run files
ln -sf "$WRF_DIR"/test/em_real/RRTMG_* . 2>/dev/null || true
ln -sf "$WRF_DIR"/test/em_real/*.TBL . 2>/dev/null || true
ln -sf "$WRF_DIR"/test/em_real/ozone* . 2>/dev/null || true
ln -sf "$WRF_DIR"/test/em_real/CAMtr_volume_mixing_ratio* . 2>/dev/null || true

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
MEDIAN_STEP="N/A"
STEADY_STEP="N/A"
if [ -f rsl.error.0000 ]; then
    if grep -q "SUCCESS COMPLETE WRF" rsl.error.0000; then
        echo "SUCCESS: WRF completed successfully"
    else
        echo "WARNING: WRF may not have completed"
    fi
    echo "=== Timing from rsl.error.0000 ==="
    grep "Timing for main" rsl.error.0000 | tail -5
    # Each step's time is the number before "elapsed seconds", $(NF-2). It is $9
    # only with a fixed time step: an adaptive one labels the step "main (dt= ...)".
    AVG_STEP=$(grep "Timing for main" rsl.error.0000 | awk '{sum+=$(NF-2); n++} END {if(n>0) printf "%.2f", sum/n; else print "N/A"}')
    echo "Average time per timestep: ${AVG_STEP}s"
    # WRF counts each output write and boundary read in the step that makes it,
    # so the average includes I/O that does not get faster in proportion to the
    # node count. To see how the time steps scale with the node count, use the
    # median or the steady step instead, from lib/wrf-step-timing.sh (its header
    # gives the rule).
    _step_lib="${WRF_STEP_TIMING_LIB:-}"
    for _c in "${_step_lib}" \
              "${SLURM_SUBMIT_DIR:-.}/../lib/wrf-step-timing.sh" \
              "${SLURM_SUBMIT_DIR:-.}/lib/wrf-step-timing.sh" \
              "${SLURM_SUBMIT_DIR:-.}/apps/WRF/lib/wrf-step-timing.sh"; do
        if [ -n "${_c}" ] && [ -r "${_c}" ]; then _step_lib="${_c}"; break; fi
    done
    if [ -n "${_step_lib}" ] && [ -r "${_step_lib}" ] && . "${_step_lib}"; then
        MEDIAN_STEP=$(wrf_median_step rsl.error.0000) || MEDIAN_STEP="N/A"
        STEADY_STEP=$(wrf_steady_step rsl.error.0000) || STEADY_STEP="N/A"
    else
        echo "NOTE: lib/wrf-step-timing.sh not found, so no median or steady step; set WRF_STEP_TIMING_LIB=/path/to/apps/WRF/lib/wrf-step-timing.sh." >&2
    fi
    echo "Median time per timestep: ${MEDIAN_STEP}s"
    echo "Steady time per timestep: ${STEADY_STEP}s"
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
WRF CONUS 12km Benchmark Results (Intel MPI)
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
Median timestep:  ${MEDIAN_STEP}s
Steady timestep:  ${STEADY_STEP}s
================================================================================
REPORT

# ---------------------------------------------------------------------------
# Record this benchmark to the AI-Powered HPC dataset (best-effort, non-fatal).
# The recorder self-collects host details from the environment and can also
# parse WRF's rsl.error.0000 in this run dir, so no arguments are needed. A
# recorder problem NEVER fails a good solve (the `|| echo` keeps it non-fatal,
# even under `set -e`). Point DYNAMODB_RECORDER at the script if it isn't found
# automatically, and set SOURCE=<YourOrg> to tag your contributions.
# See apps/WRF/dynamodb/README.md and apps/BENCHMARK-RECORDERS.md.
# ---------------------------------------------------------------------------
# Record only a run that completed and wrote its output: lib/wrf-run-check.sh
# checks that rsl.error.0000 says SUCCESS COMPLETE WRF and that every history
# and restart file WRF wrote is in the run directory and not empty. Point
# WRF_RUN_CHECK_LIB at it if it isn't found automatically.
_check_lib="${WRF_RUN_CHECK_LIB:-}"
for _c in "${_check_lib}" \
          "${SLURM_SUBMIT_DIR:-.}/../lib/wrf-run-check.sh" \
          "${SLURM_SUBMIT_DIR:-.}/lib/wrf-run-check.sh" \
          "${SLURM_SUBMIT_DIR:-.}/apps/WRF/lib/wrf-run-check.sh"; do
    if [ -n "${_c}" ] && [ -r "${_c}" ]; then _check_lib="${_c}"; break; fi
done
_run_ok=0
_run_problems="lib/wrf-run-check.sh not found; set WRF_RUN_CHECK_LIB=/path/to/apps/WRF/lib/wrf-run-check.sh"
# shellcheck source=../lib/wrf-run-check.sh
if [ -n "${_check_lib}" ] && [ -r "${_check_lib}" ] && . "${_check_lib}" \
        && declare -F wrf_run_check > /dev/null; then
    if _run_problems="$(wrf_run_check "${workdir}")"; then _run_ok=1; fi
fi
_wrf_version="$(basename "${WRF_ENV}" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true)"
# What makes runs comparable goes into the record too: the grid size, the
# simulated minutes, the number of time steps and the history output's io_form,
# which lib/wrf-run-info.sh reads from this run's namelist.input and
# rsl.error.0000. Point WRF_RUN_INFO_LIB at it if it isn't found automatically.
_info_lib="${WRF_RUN_INFO_LIB:-}"
for _c in "${_info_lib}" \
          "${SLURM_SUBMIT_DIR:-.}/../lib/wrf-run-info.sh" \
          "${SLURM_SUBMIT_DIR:-.}/lib/wrf-run-info.sh" \
          "${SLURM_SUBMIT_DIR:-.}/apps/WRF/lib/wrf-run-info.sh"; do
    if [ -n "${_c}" ] && [ -r "${_c}" ]; then _info_lib="${_c}"; break; fi
done
_run_info=()
# shellcheck source=../lib/wrf-run-info.sh
if [ -n "${_info_lib}" ] && [ -r "${_info_lib}" ] && . "${_info_lib}" \
        && declare -F wrf_run_info > /dev/null; then
    while IFS='=' read -r _k _v; do
        case "${_k}" in
            num_cells_million) _run_info+=(--num-cells-million "${_v}") ;;
            simulated_minutes|num_timesteps|io_form) _run_info+=(--char "${_k}=${_v}") ;;
        esac
    done < <(wrf_run_info "${workdir}")
else
    echo "NOTE: lib/wrf-run-info.sh not found, so the record has no grid size, run length or io_form; set WRF_RUN_INFO_LIB=/path/to/apps/WRF/lib/wrf-run-info.sh." >&2
fi
_recorder="${DYNAMODB_RECORDER:-}"
for _c in "${_recorder}" \
          "${SLURM_SUBMIT_DIR:-.}/../dynamodb/record-benchmark.sh" \
          "${SLURM_SUBMIT_DIR:-.}/dynamodb/record-benchmark.sh" \
          "${SLURM_SUBMIT_DIR:-.}/apps/WRF/dynamodb/record-benchmark.sh"; do
    if [ -n "${_c}" ] && [ -x "${_c}" ]; then _recorder="${_c}"; break; fi
done
if [ "${_run_ok}" -ne 1 ]; then
    echo "NOTE: not recording this run: ${_run_problems//$'\n'/; }" >&2
elif [ -n "${_recorder}" ] && [ -x "${_recorder}" ]; then
    WRF_VERSION="${_wrf_version}" BENCHMARK_CASE="CONUS-12km" ANALYSIS_TYPE="forecast" \
    TIME_TO_SOLUTION="${WRF_TIME}" RUN_DIR="${workdir}" "${_recorder}" \
        --metric "avg_timestep_seconds=${AVG_STEP}" \
        --metric "median_timestep_seconds=${MEDIAN_STEP}" \
        --metric "steady_timestep_seconds=${STEADY_STEP}" \
        ${_run_info[@]+"${_run_info[@]}"} \
        || echo "NOTE: benchmark recorder failed (non-fatal); the solve was unaffected." >&2
else
    echo "NOTE: benchmark recorder not found; set DYNAMODB_RECORDER=/path/to/record-benchmark.sh to record." >&2
fi
