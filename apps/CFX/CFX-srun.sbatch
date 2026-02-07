#!/bin/bash
#SBATCH --partition=hpc7a
#SBATCH --constraint=hpc7a.96xlarge
#SBATCH --ntasks=4
#SBATCH --ntasks-per-socket=1
#SBATCH --cpus-per-task=1
#SBATCH --mem 28GB
#SBATCH --job-name=scfx-static-mixer
#SBATCH --output=%x-%j/main.out
#SBATCH --error=%x-%j/main.err

######################## MPI and EFA settings ######################## 
export I_MPI_OFI_LIBRARY_INTERNAL=0
module load intelmpi
export I_MPI_DEBUG=5
export I_MPI_FABRICS=shm:ofi
export I_MPI_OFI_PROVIDER=efa
export I_MPI_MULTIRAIL=1
export FI_EFA_FORK_SAFE=1
export I_MPI_PMI_LIBRARY=/opt/slurm/lib/libpmi2.so
module load libfabric-aws
######################## MPI and EFA settings ######################## 

cfxversion=${cfxversion:-"v252"}
def_file=${def_file:-"/fsx/CFX/Dataset/perf_Airfoil_100M_R16.def"}
basedir=${basedir:-"/fsx"}

CFX_DIR="/fsx/ansys_inc/${cfxversion}/CFX/bin"

export ANSYSLMD_LICENSE_FILE=${ANSYSLMD_LICENSE_FILE:-"1055@172.31.89.151"}

TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
workdir="$(readlink -m "${basedir}/${SLURM_JOB_NAME%.*}")/Run/${SLURM_JOB_ID}-${SLURM_JOB_NUM_NODES}x$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type)-${SLURM_NPROCS}-$(date "+%d-%m-%Y-%H-%M")"

echo "Execution directory is: ${workdir}"
mkdir -p "${workdir}" && cd "${workdir}"

cp $0 .
ln -s "${def_file}" .


"${CFX_DIR}/cfx5solve" -batch -def "${def_file}" -parallel -part $SLURM_NTASKS -start-method "Intel MPI SRUN from SBATCH"