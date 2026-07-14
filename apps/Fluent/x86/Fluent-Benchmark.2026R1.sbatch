#!/bin/bash
#SBATCH --exclusive
#SBATCH --nodes=2
#SBATCH --ntasks=384
#SBATCH --constraint=hpc8a.96xlarge
#SBATCH --partition=hpc8a
#SBATCH --time=12:00:00

# ---------------------------------------------------------------------------
# Ansys Fluent benchmark launcher (x86 CPU) using the NEW 2026 R1 benchmarking
# method: the Python harness  fluent/bench/bin/fluent_benchmark_gpu.py .
#
# Starting with 2026 R1, Ansys ships a single Python benchmark harness that is
# the go-forward way to run Fluent benchmarks. Despite the "gpu" in the file
# name it is NOT GPU-only:
#   * pass  -gpu           -> the GPU solver is benchmarked (see ../gpu/)
#   * OMIT  -gpu (as here)  -> the standard CPU solver is benchmarked through
#                             the very same harness.
# The harness reads the case, does a warm-up, runs a fixed iteration count via
# its bundled journal (fluent_benchmark_gpu.jou), and reports MIUPS
# (Million Cell Iterations per Wall Second) for each case in a transcript file
# <case>-<cores>.trn, together with a NumProc/MIUPS/Speedup/Efficiency table
# and the case/data read wall-clock times.
#
# MIUPS is the metric Ansys standardises on going forward (higher is faster);
# with the mesh size you can recover the per-iteration wall time as
# cells_million / MIUPS. The DynamoDB recorder does this automatically.
#
# For the classic fluentbench.pl harness (Solver rating / wall time per
# iteration) use Fluent-Benchmark.OMPI.sbatch in this same directory instead.
#
# Usage:
#   sbatch Fluent-Benchmark.2026R1.sbatch [fluent_version] [benchmark_uri]
#     fluent_version   Ansys version dir under $ANSYS_ROOT/ansys_inc (def v261)
#     benchmark_uri    s3://bucket/<case>.tar | /path/<case>.tar | /path/dir
#                      or leave the default and rely on a case that already
#                      ships with the install (harness finds it under
#                      <fluent>/bench/fluent/v6/<BENCHMARK_NAME>/cas_dat).
#   Env knobs:
#     BENCHMARK_NAME   case id (default f1_racecar_140m)
#     ITERATIONS       timed iterations (blank -> harness default 200)
#     WARMUP_ITERATIONS warm-up iterations (blank -> harness default 50)
#     SOLVER           ""|segregated|coupled (blank -> case default)
#     EXTRA_FLUENT_ARGS extra raw Fluent flags (e.g. "3ddp")
#     SOURCE           tag your DynamoDB contributions (see recorder)
# ---------------------------------------------------------------------------

######################## EFA settings ########################
export I_MPI_OFI_LIBRARY_INTERNAL=0
module load intelmpi
export I_MPI_DEBUG=5
export I_MPI_FABRICS=shm:ofi
export I_MPI_OFI_PROVIDER=efa
module load libfabric-aws
export INTELMPI_ROOT="$(dirname $(dirname $(which mpirun)))"
######################## EFA settings ########################

fluentversion=${1:-"v261"}
benchmark_uri=${2:-"s3://YOUR_BUCKET/f1_racecar_140m.tar"}
benchmark_name=${BENCHMARK_NAME:-"f1_racecar_140m"}
basedir=${BASE_DIR:-"/fsx"}
ansys_root=${ANSYS_ROOT:-"${basedir}"}
iterations=${ITERATIONS:-""}
warmup_iterations=${WARMUP_ITERATIONS:-""}
solver=${SOLVER:-""}
extra_fluent_args=${EXTRA_FLUENT_ARGS:-""}
export ANSYSLMD_LICENSE_FILE=${ANSYSLMD_LICENSE_FILE:-"1055@XXX.YYY.ZZZ.XYZ"}

FLUENT_PYTHON_PATH="${ansys_root}/ansys_inc/${fluentversion}/commonfiles/CPython/3_10/linx64/Release/python/bin/python"
APP_BIN_PATH="${ansys_root}/ansys_inc/${fluentversion}/fluent/bench/bin/fluent_benchmark_gpu.py"
export FLUENT_ARCH=lnamd64

benchmark_file=$(basename ${benchmark_uri})

TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
instanceType=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type)
workdir="$(readlink -m "${basedir}/${SLURM_JOB_NAME%.*}")/${benchmark_name}/${fluentversion}-2026R1-cpu/${SLURM_JOB_ID}-${SLURM_JOB_NUM_NODES}x${instanceType}-${SLURM_NPROCS}-$(date "+%d-%m-%Y-%H-%M")"

echo "Execution directory is: ${workdir}"
mkdir -p "${workdir}" && cd "${workdir}"

echo "building the MPI hostfile"
scontrol show nodes $SLURM_NODELIST | grep NodeHostName= | awk '{print $2}' | sed 's/NodeHostName=//' >hostfile

cp $0 .

# Stage the dataset. Supported forms for benchmark_uri:
#   * s3://bucket/path/to/bundle.tar  - downloaded and extracted in-place
#   * /local/path/to/bundle.tar       - extracted in-place
#   * anything else                   - assume the case already ships with the
#                                       install; the harness resolves it under
#                                       <fluent>/bench/fluent/v6/<name>/cas_dat
case "${benchmark_uri}" in
    s3://*)
        aws s3 cp --quiet "${benchmark_uri}" .
        tar xf "${benchmark_file}"
        ;;
    *.tar)
        tar xf "${benchmark_uri}"
        ;;
    *)
        echo "Using case shipped with the install (no staging): ${benchmark_name}"
        ;;
esac

echo "Drop caches on all nodes"
srun --ntasks=$SLURM_JOB_NUM_NODES --ntasks-per-node=1 /bin/bash -c "sync && echo 3 | sudo tee /proc/sys/vm/drop_caches"
echo "Enabling Transparent Huge Pages (THP)"
srun --ntasks=$SLURM_JOB_NUM_NODES --ntasks-per-node=1 /bin/bash -c "echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled"

# Assemble harness args. -cores / -cases / -iterations / -warmup_iterations /
# -solver are consumed by the harness; everything after is passed through to
# Fluent unchanged. NO -gpu here => the CPU solver is benchmarked.
harness_args=(-cores "${SLURM_NPROCS}" -cases "${benchmark_name}")
[ -n "${iterations}" ]        && harness_args+=(-iterations "${iterations}")
[ -n "${warmup_iterations}" ] && harness_args+=(-warmup_iterations "${warmup_iterations}")
[ -n "${solver}" ]            && harness_args+=(-solver "${solver}")
# Fluent pass-through flags (CPU + EFA + Intel MPI, multi-node via hostfile):
harness_args+=(-cflush "-mpiopt=-genv I_MPI_DEBUG 5" -peth.efa -cnf=./hostfile -platform=intel -nosyslog -noloadchk -ssh -mpi=intel -norm)
[ -n "${extra_fluent_args}" ] && harness_args+=(${extra_fluent_args})

echo "Fluent version: ${fluentversion} | CPU solver via 2026R1 harness | cores: ${SLURM_NPROCS}"
echo "Run: ${FLUENT_PYTHON_PATH} ${APP_BIN_PATH} ${harness_args[*]}"
"${FLUENT_PYTHON_PATH}" "${APP_BIN_PATH}" "${harness_args[@]}" | tee output.$SLURM_JOBID.out

# --- Record this benchmark to the AI-Powered HPC dataset (best-effort, non-fatal) ---
# The recorder self-collects host info from the environment and parses the
# Fluent benchmark transcript (<case>-<cores>.trn -> MIUPS) in this run dir, so
# it needs no arguments and NEVER fails the job (the `|| echo` keeps it
# non-fatal). We only record a SUCCESSFUL benchmark, detected by the presence
# of a MIUPS result in a transcript, so failed solves don't pollute the data.
# Override the recorder path with DYNAMODB_RECORDER; set SOURCE=<YourOrg> to tag
# your contributions. See apps/Fluent/dynamodb/README.md and
# apps/BENCHMARK-RECORDERS.md.
_miups_hit="$(find "${workdir}" -name '*.trn' -exec grep -l 'Million Cell Iteration Per Wall Second' {} + 2>/dev/null)"
if [ -n "${_miups_hit}" ]; then
    _recorder="${DYNAMODB_RECORDER:-}"
    for _c in "${_recorder}" \
              "${SLURM_SUBMIT_DIR:-.}/../dynamodb/record-benchmark.sh" \
              "${SLURM_SUBMIT_DIR:-.}/dynamodb/record-benchmark.sh" \
              "${SLURM_SUBMIT_DIR:-.}/apps/Fluent/dynamodb/record-benchmark.sh"; do
        if [ -n "${_c}" ] && [ -x "${_c}" ]; then _recorder="${_c}"; break; fi
    done
    if [ -n "${_recorder}" ] && [ -x "${_recorder}" ]; then
        FLUENT_VERSION="${fluentversion}" RUN_DIR="${workdir}" \
        BENCHMARK_CASE="${benchmark_name}" BENCHMARK_METHOD="fluent_benchmark_harness" \
        SOLVER_MODE="cpu" NUM_ITERATIONS="${iterations:-200}" "${_recorder}" \
            || echo "NOTE: benchmark recorder failed (non-fatal); the solve was unaffected." >&2
    else
        echo "NOTE: benchmark recorder not found; set DYNAMODB_RECORDER=/path/to/record-benchmark.sh to record." >&2
    fi
else
    echo "NOTE: no MIUPS result found in transcripts; skipping benchmark recording." >&2
fi
