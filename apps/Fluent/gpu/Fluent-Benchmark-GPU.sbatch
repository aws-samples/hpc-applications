#!/bin/bash
#SBATCH --exclusive
#SBATCH --nodes=2
#SBATCH --ntasks=16
#SBATCH --constraint=g7e.48xlarge
#SBATCH --partition=g7e
#SBATCH --time=12:00:00

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
basedir=${BASE_DIR:-"/fsx"}
export ANSYSLMD_LICENSE_FILE=${ANSYSLMD_LICENSE_FILE:-"1055@XXX.YYY.ZZZ.XYZ"}

benchmark_file=$(basename ${benchmark_uri})
FLUENT_PYTHON_PATH="${basedir}/ansys_inc/${fluentversion}/commonfiles/CPython/3_10/linx64/Release/python/bin/python"
APP_BIN_PATH="${basedir}/ansys_inc/${fluentversion}/fluent/bench/bin/fluent_benchmark_gpu.py"
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
export TOKEN instanceType
export workdir="${basedir}/${SLURM_JOB_NAME%.*}/Run/${SLURM_JOB_ID}-${SLURM_JOB_NUM_NODES}x${instanceType}-${SLURM_NPROCS}-$(date "+%d-%m-%Y-%H-%M")"

echo "Execution directory is: ${workdir}"
mkdir -p "${workdir}" && cd "${workdir}"

echo "building the MPI hostfile"
scontrol show nodes $SLURM_NODELIST | grep NodeHostName= | awk '{print $2}' | sed 's/NodeHostName=//' >hostfile

cp $0 .
aws s3 cp --quiet "${benchmark_uri}" .
tar xf  "${benchmark_file}" 
ln -s bench/fluent/v6/${benchmark_file%.*}/cas_dat/* .

#store instanceIDs
# Each node reads its own instance id from its instance metadata, with the same
# limits and -f: no answer, an HTTP error or an answer cut off at the time limit
# leaves the id out of that node's line.
echo "Store InstanceIDs"
mpirun -np $SLURM_JOB_NUM_NODES -ppn 1 /bin/bash -c "TOKEN=\$(curl -fs --connect-timeout 2 --max-time 5 -X PUT \"http://169.254.169.254/latest/api/token\" -H \"X-aws-ec2-metadata-token-ttl-seconds: 21600\") || TOKEN=\"\"; instanceid=\$(curl -fs --connect-timeout 2 --max-time 5 -H \"X-aws-ec2-metadata-token: \$TOKEN\" http://169.254.169.254/latest/meta-data/instance-id) || instanceid=\"\"; host_name=\$(hostname); echo \$instanceid\":\"\$host_name >> ${workdir}/instance-ids"
echo "Drop caches on all nodes"
mpirun -np $SLURM_JOB_NUM_NODES -ppn 1 /bin/bash -c "sync && echo 3 | sudo tee /proc/sys/vm/drop_caches"
echo "Enabling Transparent Huge Pages (THP)"
mpirun -np $SLURM_JOB_NUM_NODES -ppn 1 /bin/bash -c "echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled"


${FLUENT_PYTHON_PATH} ${APP_BIN_PATH} -gpu -cores ${SLURM_NPROCS} -cases ${benchmark_file%.*} -cflush -mpiopt="-genv I_MPI_DEBUG 5" -peth.efa -cnf=./hostfile -part=4 -platform=intel -nosyslog -noloadchk -ssh -mpi=intel -norm | tee output.$SLURM_JOBID.out
_rec_rc=${PIPESTATUS[0]}

# --- Record this benchmark to the AI-Powered HPC dataset (best-effort, non-fatal) ---
# The recorder self-collects host info from the environment and parses the
# harness's transcript that this check reads, and NEVER fails the job (the
# `|| echo` keeps it non-fatal, even under `set -e`). As in
# x86/Fluent-Benchmark.2026R1.sbatch, we only record a SUCCESSFUL benchmark: the
# harness's transcript of this case and core count,
# working/<tag>/transcript/<case>-<cores>.trn, must give the case's rating, a
# positive number on its "Million Cell Iteration Per Wall Second =" line, which
# the recorder gets as MIUPS, and the transcript itself as TRANSCRIPT, so that it
# reads no other transcript in this run dir. A transcript with only the
# journal's command for that line, or a rating in another case's or core count's
# transcript, in Fluent's own transcript or in a .trn shipped with the dataset,
# does not count, so failed solves don't pollute the data. Override the
# recorder's path with DYNAMODB_RECORDER; set SOURCE=<YourOrg> to tag your
# contributions. See apps/Fluent/dynamodb/README.md and
# apps/BENCHMARK-RECORDERS.md.
_case_trn="working/*/transcript/${benchmark_file%.*}-${SLURM_NPROCS}.trn"
# The harness writes that transcript in one working/<tag>/; should there be
# more, the last one that has the line is the one checked. awk reads it on its
# standard input, as the recorder does, so that no path is an awk assignment.
_transcript=""
for _t in "${workdir}"/working/*/transcript/"${benchmark_file%.*}-${SLURM_NPROCS}.trn"; do
    grep -q '^Million Cell Iteration Per Wall Second[[:space:]]*=' "${_t}" 2>/dev/null && _transcript="${_t}"
done
_miups="$(awk '/^Million Cell Iteration Per Wall Second[[:space:]]*=/ {
               v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); split(v, f, /[[:space:]]+/); m = f[1] }
           END { print m }' 2>/dev/null < "${_transcript:-/dev/null}")"
[[ "${_miups}" =~ ^[0-9]+([.][0-9]+)?$ && "${_miups}" =~ [1-9] ]] || _miups=""
_recorder="${DYNAMODB_RECORDER:-}"
for _c in "${_recorder}" \
          "${SLURM_SUBMIT_DIR:-.}/../dynamodb/record-benchmark.sh" \
          "${SLURM_SUBMIT_DIR:-.}/dynamodb/record-benchmark.sh" \
          "${SLURM_SUBMIT_DIR:-.}/apps/Fluent/dynamodb/record-benchmark.sh"; do
    if [ -n "${_c}" ] && [ -x "${_c}" ]; then _recorder="${_c}"; break; fi
done
if [ -z "${_miups}" ]; then
    echo "NOTE: ${_case_trn}, the harness's transcript of this case and core count, gives no positive" \
         "MIUPS on a \"Million Cell Iteration Per Wall Second =\" line." >&2
    echo "NOTE: no MIUPS result found in transcripts; skipping benchmark recording." >&2
elif [ -n "${_recorder}" ] && [ -x "${_recorder}" ]; then
    FLUENT_VERSION="${fluentversion}" RUN_DIR="${workdir}" MIUPS="${_miups}" TRANSCRIPT="${_transcript}" \
    BENCHMARK_CASE="${benchmark_file%.*}" BENCHMARK_METHOD="fluent_benchmark_harness" \
    SOLVER_MODE="gpu" "${_recorder}" \
        || echo "NOTE: benchmark recorder failed (non-fatal); the solve was unaffected." >&2
else
    echo "NOTE: benchmark recorder not found; set DYNAMODB_RECORDER=/path/to/record-benchmark.sh to record." >&2
fi
# The job ends with the 2026 R1 harness's own exit status (not tee's), whatever
# the recording did, as the CFX and OptiStruct scripts and the STAR-CCM+ batch
# scripts end with their solver's.
exit "${_rec_rc}"
