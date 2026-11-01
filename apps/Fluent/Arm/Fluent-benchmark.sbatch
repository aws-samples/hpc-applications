#!/bin/bash
#SBATCH --exclusive
#SBATCH --nodes=4
#SBATCH --ntasks=256
#SBATCH --constraint=hpc7g.16xlarge
#SBATCH --partition=hpc7g
#SBATCH --time=12:00:00

######################## EFA settings ######################## 
module load openmpi
module load libfabric-aws
export FI_EFA_RECVWIN_SIZE=65536
#export FI_LOG_LEVEL=warn 
#export OMPI_MCA_mtl_ofi_verbose=100
export OPENMPI_ROOT="$(dirname $(dirname $(which mpirun)))"
######################## EFA settings ########################  

fluentversion=${1:-"v251"}
benchmark_uri=${2:-"s3://YOUR_BUCKET/f1_racecar_140m.tar"}
basedir=${BASE_DIR:-"/fsx"}
export ANSYSLMD_LICENSE_FILE=${ANSYSLMD_LICENSE_FILE:-"1055@XXX.YYY.ZZZ.XYZ"}

benchmark_file=$(basename ${benchmark_uri})
APP_BIN_PATH="/fsx/ansys_inc/v242/fluent/bin/fluentbench.pl"
export FLUENT_ARCH=lnarm64 

# The instance type, from the instance metadata (IMDSv2), for the run
# directory's name only. Each request gives up after 5 seconds (2 to connect),
# and -f turns an HTTP error into no answer. An answer cut off at that limit,
# or one that is not an instance type name (tested in the C locale: in some
# locales [a-z] leaves out i), a proxy's page for example, counts as none, so
# it never names the run directory; the name then has no instance type, and
# the job goes on.
TOKEN=$(curl -fs --connect-timeout 2 --max-time 5 -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600") || TOKEN=""
instanceType=$(curl -fs --connect-timeout 2 --max-time 5 -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type) || instanceType=""
( LC_ALL=C; [[ "${instanceType}" =~ ^[a-z][a-z0-9-]*\.[a-z0-9-]+$ ]] ) || instanceType=""
workdir="$(readlink -m "${basedir}/${SLURM_JOB_NAME%.*}")/${benchmark_file%.*}/${SLURM_JOB_ID}-${SLURM_JOB_NUM_NODES}x${instanceType}-${SLURM_NPROCS}-$(date "+%d-%m-%Y-%H-%M")"

echo "Execution directory is: ${workdir}"
mkdir -p "${workdir}" && cd "${workdir}"

echo "building the MPI hostfile"
scontrol show nodes $SLURM_NODELIST | grep NodeHostName= | awk '{print $2}' | sed 's/NodeHostName=//' >hostfile

cp $0 .
aws s3 cp --quiet "${benchmark_uri}" .
tar xf  "${benchmark_file}" 
ln -s bench/fluent/v6/${benchmark_file%.*}/cas_dat/* .


echo "Drop caches on all nodes"
mpirun -n $SLURM_JOB_NUM_NODES --map-by ppr:1:node /bin/bash -c "sync && echo 3 | sudo tee /proc/sys/vm/drop_caches"

echo "Enabling Transparent Huge Pages (THP)"
mpirun -n $SLURM_JOB_NUM_NODES --map-by ppr:1:node /bin/bash -c "echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled"

echo "Install missing libraries"
mpirun -n $SLURM_JOB_NUM_NODES --map-by ppr:1:node /bin/bash -c "sudo yum -y install libXtst libXtst-devel libvorbis libvorbis-devel"

"${APP_BIN_PATH}" ${benchmark_file%.*} -t${SLURM_NPROCS}  -cnf=hostfile -part=4 -nosyslog -noloadchk -ssh -peth.efa -mpi=openmpi
_rec_rc=$?

# --- Record this benchmark to the AI-Powered HPC dataset (best-effort, non-fatal) ---
# The recorder self-collects host info from the environment and parses the Fluent
# solver log in this run dir, and NEVER fails the job (the `|| echo` keeps it
# non-fatal, even under `set -e`). We only record a SUCCESSFUL benchmark:
# fluentbench.pl's output of this case and core count, <case>-<cores>.out in this
# run dir, must give the case's rating, a positive number on its "Solver rating ="
# line. A rating only in another case's or core count's output, in the job's own
# output or in a link to a file shipped with the dataset does not count, so
# failed solves don't pollute the data. The recorder gets that file's rating
# and, where that file gives them, its time per iteration and solver speed, as
# SOLVER_RATING, TIME_PER_ITERATION and SOLVER_SPEED. Override the recorder's
# path with DYNAMODB_RECORDER; set SOURCE=<YourOrg> to tag your contributions.
# See apps/Fluent/dynamodb/README.md and apps/BENCHMARK-RECORDERS.md.
_case_out="${benchmark_file%.*}-${SLURM_NPROCS}.out"
# _case_value <name>: the first word after "=" on that file's last "<name> =" line
_case_value() {
    awk -v name="$1" '$0 ~ "^[[:space:]]*" name "[[:space:]]*=" {
                          v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); split(v, f, /[[:space:]]+/); r = f[1] }
                      END { print r }' "${workdir}/${_case_out}" 2>/dev/null
}
_rating=""; _time_per_iteration=""; _solver_speed=""
if [ -f "${workdir}/${_case_out}" ] && [ ! -L "${workdir}/${_case_out}" ]; then
    _rating="$(_case_value "Solver rating")"
    _time_per_iteration="$(_case_value "Solver wall time per iteration")"
    _solver_speed="$(_case_value "Solver speed")"
fi
[[ "${_rating}" =~ ^[0-9]+([.][0-9]+)?$ && "${_rating}" =~ [1-9] ]] || _rating=""
_recorder="${DYNAMODB_RECORDER:-}"
for _c in "${_recorder}" \
          "${SLURM_SUBMIT_DIR:-.}/../dynamodb/record-benchmark.sh" \
          "${SLURM_SUBMIT_DIR:-.}/dynamodb/record-benchmark.sh" \
          "${SLURM_SUBMIT_DIR:-.}/apps/Fluent/dynamodb/record-benchmark.sh"; do
    if [ -n "${_c}" ] && [ -x "${_c}" ]; then _recorder="${_c}"; break; fi
done
if [ -z "${_rating}" ]; then
    echo "NOTE: ${_case_out}, fluentbench.pl's output of this case and core count, gives no positive" \
         "rating on a \"Solver rating =\" line." >&2
    echo "NOTE: no solver rating found in the benchmark output; skipping benchmark recording." >&2
elif [ -n "${_recorder}" ] && [ -x "${_recorder}" ]; then
    # The case and the method too, so that the record names them whichever
    # recorder runs: an older one takes both from the run dir's first .trn, which
    # can be Fluent's own session transcript (fluent-<date>-<time>-<pid>.trn).
    FLUENT_VERSION="${fluentversion}" RUN_DIR="${workdir}" SOLVER_RATING="${_rating}" \
        TIME_PER_ITERATION="${_time_per_iteration}" SOLVER_SPEED="${_solver_speed}" \
        BENCHMARK_CASE="${benchmark_file%.*}" BENCHMARK_METHOD="fluentbench" "${_recorder}" \
        || echo "NOTE: benchmark recorder failed (non-fatal); the solve was unaffected." >&2
else
    echo "NOTE: benchmark recorder not found; set DYNAMODB_RECORDER=/path/to/record-benchmark.sh to record." >&2
fi
# The job ends with fluentbench.pl's own exit status, whatever the recording
# did, as the CFX and OptiStruct scripts and the STAR-CCM+ batch scripts end
# with their solver's.
exit "${_rec_rc}"
