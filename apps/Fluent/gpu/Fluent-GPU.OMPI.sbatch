#!/bin/bash
#SBATCH --exclusive
#SBATCH --nodes=1
#SBATCH --gpus=8
#SBATCH --constraint=g5.48xlarge
#SBATCH --partition=g5

######################## EFA settings ######################## 
module load openmpi/4.1.6    
#export  FI_PROVIDER="efa"
#export OMPI_MCA_mtl_ofi_verbose=1
#export FI_EFA_RECVWIN_SIZE=65536
module load libfabric-aws
export OPENMPI_ROOT="$(dirname $(dirname $(which mpirun)))"
######################## EFA settings ######################## 

fluentversion=${1:-"v261"}
journal_file=${2:-"/fsx/MY_FLUENT_EXAMPLE/MY_JOURNAL_FILE.jou"}
dataset_cas=${3:-"/fsx/MY_FLUENT_EXAMPLE/MY_CAS_FILE.cas.gz"}
dataset_dat=${4:-"/fsx/MY_FLUENT_EXAMPLE/MY_DAT_FILE.dat.gz"}
basedir=${BASE_DIR:-"/fsx"}
fluent_mode=${FLUENT_MODE:-"3ddp"}
export ANSYSLMD_LICENSE_FILE=${ANSYSLMD_LICENSE_FILE:-"1055@XXX.YYY.ZZZ.XYZ"}

APP_BIN_PATH="${basedir}/ansys_inc/${fluentversion}/fluent/bin/fluent"
export FLUENT_ARCH=lnamd64 

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

#echo "Drop caches on all nodes"
#mpirun -np $SLURM_JOB_NUM_NODES -ppn 1 /bin/bash -c "sync && echo 3 | sudo tee /proc/sys/vm/drop_caches"

#echo "Enabling Transparent Huge Pages (THP)"
#mpirun -np $SLURM_JOB_NUM_NODES -ppn 1 /bin/bash -c "echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled"

echo "Run Fluent: ${APP_BIN_PATH} ${fluent_mode} -g -cnf=hostfile -ssh -mpi=openmpi -t${SLURM_NPROCS} -gpuapp -i $(basename ${journal_file})"
"${APP_BIN_PATH}" ${fluent_mode} -g -cnf=./hostfile -ssh -peth.efa  -mpi=openmpi -t${SLURM_NPROCS} -gpu -gpu_remap -i $(basename ${journal_file}) | tee output.$SLURM_JOBID.out

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
