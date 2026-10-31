#!/bin/bash
#SBATCH --exclusive
#SBATCH --nodes=2
#SBATCH --ntasks=384
#SBATCH --constraint=hpc8a.96xlarge
#SBATCH --partition=hpc8a
#SBATCH --time=12:00:00

# ---------------------------------------------------------------------------
# Ansys Fluent benchmark launcher (x86, IntelMPI + EFA)
#
# This script uses Fluent's built-in "-peth.efa" interconnect variant to
# enable EFA, which is available from Ansys Fluent v222 (2022 R2) onwards
# and is officially documented starting with v261 (2026 R1). Fluent's own
# mpirun wrapper (mpirun.fl) then injects the correct IntelMPI + libfabric
# tuning for AWS EFA:
#   I_MPI_OFI_PROVIDER=efa
#   I_MPI_FABRICS=shm:ofi
#   FI_EFA_RECVWIN_SIZE=65536
#   FI_MR_CACHE_MONITOR=memhooks
#
# Three settings are still needed from the submit script:
#   * I_MPI_OFI_LIBRARY_INTERNAL=0  (tell IntelMPI to use the system
#                                    libfabric-aws, not its bundled one.
#                                    Must be exported BEFORE module load
#                                    intelmpi so mpivars.sh picks it up.)
#   * I_MPI_MULTIRAIL=1             (multi-NIC EFA instances only, e.g.
#                                    hpc7a / hpc8a; omit on single-NIC
#                                    instances)
#   * FI_EFA_SHM_AV_SIZE=<ncores>   (required when using >128 ranks per node)
#
# Plus SCHEDULER_TIGHT_COUPLING=1, which tells Fluent v222 .. v242's mpirun
# wrapper to NOT force --rsh=ssh under Slurm. v251+ already does this by
# default, but setting it explicitly keeps one codepath across all versions.
# ---------------------------------------------------------------------------

# Tell IntelMPI to use the system libfabric (loaded via libfabric-aws
# below) instead of its own bundled one. This must be exported BEFORE
# `module load intelmpi` so that mpivars.sh / the shell wrappers see it.
export I_MPI_OFI_LIBRARY_INTERNAL=0

module load intelmpi
module load libfabric-aws

# Multi-NIC EFA instances (e.g. hpc7a / hpc8a) — omit on single-NIC instances.
export I_MPI_MULTIRAIL=1
# Required when ranks-per-node exceeds 128 (e.g. 192 on hpc7a / hpc8a).
export FI_EFA_SHM_AV_SIZE=${SLURM_NTASKS_PER_NODE:-192}
# Let IntelMPI's Slurm integration handle process launch natively on
# older Fluent versions (no-op on v251+).
export SCHEDULER_TIGHT_COUPLING=1

fluentversion=${1:-"v252"}
benchmark_uri=${2:-"s3://YOUR_BUCKET/f1_racecar_140m.tar"}
basedir=${BASE_DIR:-"/fsx"}
ansys_root=${ANSYS_ROOT:-"/fsx"}
export ANSYSLMD_LICENSE_FILE=${ANSYSLMD_LICENSE_FILE:-"1055@XXX.YYY.ZZZ.XYZ"}

benchmark_file=$(basename ${benchmark_uri})
APP_BIN_PATH="${ansys_root}/ansys_inc/${fluentversion}/fluent/bin/fluentbench.pl"
export FLUENT_ARCH=lnamd64

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

echo "Building the MPI hostfile"
scontrol show nodes $SLURM_NODELIST | grep NodeHostName= | awk '{print $2}' | sed 's/NodeHostName=//' >hostfile

cp $0 .
aws s3 cp --quiet "${benchmark_uri}" .
tar xf "${benchmark_file}"
ln -s bench/fluent/v6/${benchmark_file%.*}/cas_dat/* .

echo "Drop caches on all nodes"
mpirun -np $SLURM_JOB_NUM_NODES -ppn 1 /bin/bash -c "sync && echo 3 | sudo tee /proc/sys/vm/drop_caches"

echo "Enabling Transparent Huge Pages (THP)"
mpirun -np $SLURM_JOB_NUM_NODES -ppn 1 /bin/bash -c "echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled"

echo "Fluent version: ${fluentversion}"
echo "Run Fluent Benchmark: ${APP_BIN_PATH} ${benchmark_file%.*} -t${SLURM_NPROCS} -cnf=hostfile -part=4 -peth.efa -platform=intel -nosyslog -noloadchk -ssh -mpi=intel -norm"
"${APP_BIN_PATH}" ${benchmark_file%.*} -t${SLURM_NPROCS} -cnf=hostfile -part=4 -peth.efa -platform=intel -nosyslog -noloadchk -ssh -mpi=intel -norm | tee output.$SLURM_JOBID.out
_rec_rc=${PIPESTATUS[0]}

# --- Record this benchmark to the AI-Powered HPC dataset (best-effort, non-fatal) ---
# The recorder self-collects host info from the environment and parses the Fluent
# solver log in this run dir, and NEVER fails the job (the `|| echo` keeps it
# non-fatal, even under `set -e`). We only record a SUCCESSFUL benchmark:
# fluentbench.pl's output of this case and core count, <case>-<cores>.out in this
# run dir, must give the case's rating, a positive number on its "Solver rating ="
# line. A rating only in another case's or core count's output, in this job's
# output.<jobid>.out or in a link to a file shipped with the dataset does not
# count, so failed solves don't pollute the data. The recorder gets that file's
# rating and, where that file gives them, its time per iteration and solver
# speed, as SOLVER_RATING, TIME_PER_ITERATION and SOLVER_SPEED. Override the
# recorder's path with DYNAMODB_RECORDER; set SOURCE=<YourOrg> to tag your
# contributions. See apps/Fluent/dynamodb/README.md and
# apps/BENCHMARK-RECORDERS.md.
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
    # The case and the method too: without them, the recorder takes both from the
    # run dir's first .trn file, which can be Fluent's own session transcript
    # (fluent-<date>-<pid>.trn).
    FLUENT_VERSION="${fluentversion}" RUN_DIR="${workdir}" SOLVER_RATING="${_rating}" \
        TIME_PER_ITERATION="${_time_per_iteration}" SOLVER_SPEED="${_solver_speed}" \
        BENCHMARK_CASE="${benchmark_file%.*}" BENCHMARK_METHOD="fluentbench" "${_recorder}" \
        || echo "NOTE: benchmark recorder failed (non-fatal); the solve was unaffected." >&2
else
    echo "NOTE: benchmark recorder not found; set DYNAMODB_RECORDER=/path/to/record-benchmark.sh to record." >&2
fi
# The job ends with fluentbench.pl's own exit status (not tee's), whatever the
# recording did, as the CFX and OptiStruct scripts and the STAR-CCM+ batch
# scripts end with their solver's.
exit "${_rec_rc}"
