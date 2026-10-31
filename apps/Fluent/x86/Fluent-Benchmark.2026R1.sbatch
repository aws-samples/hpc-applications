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
#     ITERATIONS       timed iterations, time steps for a transient case
#                      (default 25, as this script's results in ../Readme.md
#                      ran; the harness's own default is 200)
#     WARMUP_ITERATIONS warm-up iterations, time steps for a transient case,
#                      which the harness runs twice (default 10, as those
#                      results ran; the harness's own default is 50)
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
iterations=${ITERATIONS:-"25"}
warmup_iterations=${WARMUP_ITERATIONS:-"10"}
solver=${SOLVER:-""}
extra_fluent_args=${EXTRA_FLUENT_ARGS:-""}
export ANSYSLMD_LICENSE_FILE=${ANSYSLMD_LICENSE_FILE:-"1055@XXX.YYY.ZZZ.XYZ"}

FLUENT_PYTHON_PATH="${ansys_root}/ansys_inc/${fluentversion}/commonfiles/CPython/3_10/linx64/Release/python/bin/python"
APP_BIN_PATH="${ansys_root}/ansys_inc/${fluentversion}/fluent/bench/bin/fluent_benchmark_gpu.py"
export FLUENT_ARCH=lnamd64

benchmark_file=$(basename ${benchmark_uri})

# The instance type, from the instance metadata (IMDSv2). Each request gives
# up after 5 seconds (2 to connect), and -f turns an HTTP error into no answer.
# An answer cut off at that limit, or one that is not an instance type name
# (tested in the C locale: in some locales [a-z] leaves out i), a proxy's page
# for example, counts as none, so it never names the run directory.
TOKEN=$(curl -fs --connect-timeout 2 --max-time 5 -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600") || TOKEN=""
instanceType=$(curl -fs --connect-timeout 2 --max-time 5 -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type) || instanceType=""
( LC_ALL=C; [[ "${instanceType}" =~ ^[a-z][a-z0-9-]*\.[a-z0-9-]+$ ]] ) || instanceType=""

# Ranks per node on hpc8a.96xlarge and hpc7a.96xlarge: only the counts that put
# the same number of ranks on each of their 24 CCDs (Utils/flexible-cores/).
# Fluent spreads its SLURM_NPROCS ranks evenly over the hostfile's nodes, so a
# node runs SLURM_NPROCS / SLURM_JOB_NUM_NODES of them. Any other count, or a
# total that does not divide evenly, stops the job here, before the run
# directory and Fluent. Other instance types and sizes are not checked. When
# the instance type cannot be read (no answer in time, an HTTP error, an
# answer cut off at the time limit, or an answer that is not an instance type
# name), a count outside the set is refused only on an AMD node with 192 cores
# (lscpu: sockets x cores per socket), which could be one of those two. Any
# other node runs, with a NOTE that the check was skipped: no run is refused
# only because the instance metadata did not answer.
ranks_per_node=""
if [[ "${SLURM_NPROCS:-}" =~ ^[1-9][0-9]{0,6}$ && "${SLURM_JOB_NUM_NODES:-}" =~ ^[1-9][0-9]{0,6}$ ]] \
        && (( SLURM_NPROCS % SLURM_JOB_NUM_NODES == 0 )); then
    ranks_per_node=$(( SLURM_NPROCS / SLURM_JOB_NUM_NODES ))
fi
case "${ranks_per_node}" in
    24|48|72|96|120|144|168|192) ;;
    *)
        layout="${SLURM_NPROCS:-?} ranks on ${SLURM_JOB_NUM_NODES:-?} node(s)${ranks_per_node:+ (${ranks_per_node} per node)}"
        supported="24, 48, 72, 96, 120, 144, 168 or 192 ranks per node"
        case "${instanceType}" in
            hpc8a.96xlarge|hpc7a.96xlarge)
                echo "ERROR: ${layout} load the 24 CCDs of ${instanceType} unevenly;" \
                     "run ${supported} (Utils/flexible-cores). Not starting Fluent." >&2
                exit 1 ;;
        esac
        if [ -z "${instanceType}" ]; then
            amd_192_cores="$(LC_ALL=C lscpu 2>/dev/null | awk -F: '
                { k = $1; sub(/^[[:space:]]+/, "", k); v = $2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", v) }
                k == "Vendor ID" { vendor = v }
                k == "Socket(s)" { sockets = v }
                k == "Core(s) per socket" { cores = v }
                END { if (vendor == "AuthenticAMD" && sockets ~ /^[0-9]+$/ && cores ~ /^[0-9]+$/ &&
                          sockets * cores == 192) print "yes" }')"
            if [ "${amd_192_cores}" = yes ]; then
                echo "ERROR: ${layout} load the 24 CCDs of hpc8a.96xlarge or hpc7a.96xlarge unevenly (the instance" \
                     "metadata did not name the instance type, and this node has 192 AMD cores, as those two do);" \
                     "run ${supported} (Utils/flexible-cores). Not starting Fluent." >&2
                exit 1
            fi
            echo "NOTE: the instance metadata did not name the instance type, and lscpu does not show the 192 AMD" \
                 "cores of hpc8a.96xlarge and hpc7a.96xlarge, so their ranks-per-node check (Utils/flexible-cores)" \
                 "is skipped for ${layout}." >&2
        fi ;;
esac

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
_rec_rc=${PIPESTATUS[0]}

# --- Record this benchmark to the AI-Powered HPC dataset (best-effort, non-fatal) ---
# The recorder self-collects host info from the environment, reads the case
# and data read times from the Fluent benchmark transcript in this run dir, and
# NEVER fails the job (the `|| echo` keeps it non-fatal). We only record a
# SUCCESSFUL benchmark: the harness's transcript of this case and core count,
# working/<tag>/transcript/<case>-<cores>.trn, must give the case's rating, a
# positive number on its "Million Cell Iteration Per Wall Second =" line, which
# the recorder gets as MIUPS. A transcript with only the journal's command for
# that line, or a rating in another case's or core count's transcript, in
# Fluent's own transcript or in a .trn shipped with the dataset, does not
# count, so failed solves don't pollute the data.
# Override the recorder path with DYNAMODB_RECORDER; set SOURCE=<YourOrg> to tag
# your contributions. See apps/Fluent/dynamodb/README.md and
# apps/BENCHMARK-RECORDERS.md.
_case_trn="working/*/transcript/${benchmark_name}-${SLURM_NPROCS}.trn"
_miups="$(cat "${workdir}"/working/*/transcript/"${benchmark_name}-${SLURM_NPROCS}.trn" 2>/dev/null \
    | awk '/^Million Cell Iteration Per Wall Second[[:space:]]*=/ {
               v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); split(v, f, /[[:space:]]+/); m = f[1] }
           END { print m }')"
[[ "${_miups}" =~ ^[0-9]+([.][0-9]+)?$ && "${_miups}" =~ [1-9] ]] || _miups=""
if [ -n "${_miups}" ]; then
    _recorder="${DYNAMODB_RECORDER:-}"
    for _c in "${_recorder}" \
              "${SLURM_SUBMIT_DIR:-.}/../dynamodb/record-benchmark.sh" \
              "${SLURM_SUBMIT_DIR:-.}/dynamodb/record-benchmark.sh" \
              "${SLURM_SUBMIT_DIR:-.}/apps/Fluent/dynamodb/record-benchmark.sh"; do
        if [ -n "${_c}" ] && [ -x "${_c}" ]; then _recorder="${_c}"; break; fi
    done
    # The run's length, so that runs compare. NUM_ITERATIONS below is the timed
    # count asked for; these add the warm-up count asked for (the harness runs
    # it twice) and the iterations the harness timed, from the "Number of
    # Iterations" line of its transcript.
    # For a transient case the harness runs both counts as time steps, so the
    # timed iterations are every iteration of those time steps.
    _record_args=(--char "warmup_iterations=${warmup_iterations}")
    _timed_iterations="$(cat "${workdir}"/working/*/transcript/"${benchmark_name}-${SLURM_NPROCS}.trn" 2>/dev/null \
        | awk '/^Number of Iterations[[:space:]]*=/ {
                   v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); split(v, f, /[[:space:]]+/); n = f[1] }
               END { print n }')"
    [[ "${_timed_iterations}" =~ ^[1-9][0-9]*$ ]] && _record_args+=(--char "timed_iterations=${_timed_iterations}")
    if [ -n "${_recorder}" ] && [ -x "${_recorder}" ]; then
        FLUENT_VERSION="${fluentversion}" RUN_DIR="${workdir}" MIUPS="${_miups}" \
        BENCHMARK_CASE="${benchmark_name}" BENCHMARK_METHOD="fluent_benchmark_harness" \
        SOLVER_MODE="cpu" NUM_ITERATIONS="${iterations}" "${_recorder}" "${_record_args[@]}" \
            || echo "NOTE: benchmark recorder failed (non-fatal); the solve was unaffected." >&2
    else
        echo "NOTE: benchmark recorder not found; set DYNAMODB_RECORDER=/path/to/record-benchmark.sh to record." >&2
    fi
else
    echo "NOTE: ${_case_trn}, the harness's transcript of this case and core count, gives no positive" \
         "MIUPS on a \"Million Cell Iteration Per Wall Second =\" line." >&2
    echo "NOTE: no MIUPS result found in transcripts; skipping benchmark recording." >&2
fi
# The job ends with the 2026 R1 harness's own exit status (not tee's), whatever
# the recording did, as the CFX and OptiStruct scripts and the STAR-CCM+ batch
# scripts end with their solver's.
exit "${_rec_rc}"
