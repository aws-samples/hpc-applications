#!/bin/bash
#SBATCH --exclusive
#SBATCH --nodes=4
#SBATCH --ntasks=192
#SBATCH --ntasks-per-node=48
#SBATCH --constraint=hpc7a.96xlarge
#SBATCH --partition=hpc7a
#SBATCH --chdir=/fsx/slurm-out/cfx

######################## EFA settings ######################## 
#export I_MPI_DEBUG=5
export I_MPI_FABRICS=shm:ofi
export I_MPI_OFI_PROVIDER=efa
export I_MPI_MULTIRAIL=1
export I_MPI_ADJUST_REDUCE=2 
export I_MPI_ADJUST_ALLREDUCE=2
export I_MPI_ADJUST_BCAST=1
######################## EFA settings ######################## 

export I_MPI_PIN_PROCESSOR_LIST="0,4,8,12,16,20,24,28,32,36,40,44,48,52,56,60,64,68,72,76,80,84,88,92,96,100,104,108,112,116,120,124,128,132,136,140,144,148,152,156,160,164,168,172,176,180,184,188"

cfxversion=${cfxversion:-"v242"}
def_file=${def_file:-"/fsx/CFX/Dataset/perf_Airfoil_100M_R16.def"}
basedir=${basedir:-"/fsx"}

CFX_DIR="/fsx/ansys_inc/${cfxversion}/CFX/bin"

export ANSYSLMD_LICENSE_FILE=${ANSYSLMD_LICENSE_FILE:-"1055@172.31.89.151"}

TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
workdir="$(readlink -m "${basedir}/${SLURM_JOB_NAME%.*}")/Run/${SLURM_JOB_ID}-${SLURM_JOB_NUM_NODES}x$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type)-${SLURM_NPROCS}-$(date "+%d-%m-%Y-%H-%M")"

echo "Execution directory is: ${workdir}"
mkdir -p "${workdir}" && cd "${workdir}"

echo "building the MPI hostfile"
HOST_LIST=$(scontrol show hostname $SLURM_NODELIST)

cp $0 .
ln -s "${def_file}" .

"${CFX_DIR}/cfx5solve" -batch -def $def_file -parallel -start-method 'Intel MPI Distributed Parallel' -par-dist "$HOST_LIST" -part $SLURM_NPROCS -part-large