#!/bin/bash
#SBATCH --exclusive
#SBATCH -t 24:00:00
#SBATCH --nodes=4
#SBATCH --ntasks=256
#SBATCH --constraint=hpc7g.16xlarge
#SBATCH --partition=hpc7g

######################### EFA settings ######################## 
module load openmpi
module load libfabric-aws
#export FI_LOG_LEVEL=warn 
#export OMPI_MCA_mtl_ofi_verbose=100
export OPENMPI_ROOT="$(dirname $(dirname $(which mpirun)))"
######################## EFA settings ######################## 

fluentversion=${1:-"v251"}
journal_file=${2:-"/fsx/MY_FLUENT_EXAMPLE/MY_JOURNAL_FILE.jou"}
dataset_cas=${3:-"/fsx/MY_FLUENT_EXAMPLE/MY_CAS_FILE.cas.gz"}
dataset_dat=${4:-"/fsx/MY_FLUENT_EXAMPLE/MY_DAT_FILE.dat.gz"}
basedir=${BASE_DIR:-"/fsx"}
fluent_mode=${FLUENT_MODE:-"3d"}

export ANSYSLMD_LICENSE_FILE=${ANSYSLMD_LICENSE_FILE:-"1055@XXX.YYY.ZZZ.XYZ"}

APP_BIN_PATH="/fsx/ansys_inc/${fluentversion}/fluent/bin/fluent"
export FLUENT_ARCH=lnarm64 

TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
workdir="$(readlink -m "${basedir}/${SLURM_JOB_NAME%.*}")/$(basename "${journal_file%.*}")/Run/${SLURM_JOB_ID}-${SLURM_JOB_NUM_NODES}x$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type)-${SLURM_NPROCS}-$(date "+%d-%m-%Y-%H-%M")"

echo "Execution directory is: ${workdir}"
mkdir -p "${workdir}" && cd "${workdir}"

echo "building the MPI hostfile"
scontrol show nodes $SLURM_NODELIST | grep NodeHostName= | awk '{print $2}' | sed 's/NodeHostName=//' >hostfile

cp $0 .
ln -s "${journal_file}" .
ln -s "${dataset_cas}" .
ln -s "${dataset_dat}" .

echo "Drop caches on all nodes"
mpirun -n $SLURM_JOB_NUM_NODES --map-by ppr:1:node /bin/bash -c "sync && echo 3 | sudo tee /proc/sys/vm/drop_caches"

echo "Enabling Transparent Huge Pages (THP)"
mpirun -n $SLURM_JOB_NUM_NODES --map-by ppr:1:node /bin/bash -c "echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled"

"${APP_BIN_PATH}" ${fluent_mode} -g -t${SLURM_NPROCS} -cnf=hostfile -cflush -env -ssh -part=4 -p=eth.efa -mpi=openmpi -i ${journal_file} | tee output.$SLURM_JOBID.out

# --- Record this benchmark to the AI-Powered HPC dataset (best-effort, non-fatal) ---
# The recorder self-collects host info from the environment and parses the Fluent
# solver log in this run dir, so it needs no arguments and NEVER fails the job
# (the `|| echo` keeps it non-fatal, even under `set -e`). Override its path with
# DYNAMODB_RECORDER; set SOURCE=<YourOrg> to tag your contributions. See
# apps/Fluent/dynamodb/README.md and apps/BENCHMARK-RECORDERS.md.
_recorder="${DYNAMODB_RECORDER:-}"
for _c in "${_recorder}" \
          "${SLURM_SUBMIT_DIR:-.}/../dynamodb/record-benchmark.sh" \
          "${SLURM_SUBMIT_DIR:-.}/dynamodb/record-benchmark.sh" \
          "${SLURM_SUBMIT_DIR:-.}/apps/Fluent/dynamodb/record-benchmark.sh"; do
    if [ -n "${_c}" ] && [ -x "${_c}" ]; then _recorder="${_c}"; break; fi
done
if [ -n "${_recorder}" ] && [ -x "${_recorder}" ]; then
    FLUENT_VERSION="${fluentversion}" RUN_DIR="${workdir}" "${_recorder}" \
        || echo "NOTE: benchmark recorder failed (non-fatal); the solve was unaffected." >&2
else
    echo "NOTE: benchmark recorder not found; set DYNAMODB_RECORDER=/path/to/record-benchmark.sh to record." >&2
fi
