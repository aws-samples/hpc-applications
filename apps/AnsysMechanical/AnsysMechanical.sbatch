#!/bin/bash
#SBATCH --exclusive
#SBATCH --nodes=2
#SBATCH --ntasks=128
#SBATCH --constraint=hpc6id.32xlarge
#SBATCH --partition=hpc6id
#SBATCH --chdir=/fsx/slurm-out/mechanical


######################## EFA settings ######################## 
export I_MPI_OFI_LIBRARY_INTERNAL=0
module load intelmpi
export I_MPI_DEBUG=5
export I_MPI_FABRICS=shm:ofi
export I_MPI_OFI_PROVIDER=efa
export I_MPI_MULTIRAIL=1
#export FI_EFA_RECVWIN_SIZE=65536
export FI_EFA_FORK_SAFE=1
module load libfabric-aws
export INTELMPI_ROOT="$(dirname $(dirname $(which mpirun)))"
######################## EFA settings ######################## 

export ANSYSLMD_LICENSE_FILE=${ANSYSLMD_LICENSE_FILE:-"1055@172.31.89.151"}

mechanicalversion=${1:-"v251"}
input_file=${2:-"/fsx/.../your_file.dat"}
basedir=${BASE_DIR:-"/fsx"}

APP_BIN_PATH="${basedir}/ansys_inc/${mechanicalversion}/ansys/bin/mapdl"
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
workdir="$(readlink -m "${basedir}/${SLURM_JOB_NAME%.*}")/Run/${SLURM_JOB_ID}-${SLURM_JOB_NUM_NODES}x$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type)-${SLURM_NPROCS}-$(date "+%d-%m-%Y-%H-%M")"

mkdir -p "${workdir}" && cd "${workdir}"

export cores_x_node=$(((SLURM_NPROCS / SLURM_JOB_NUM_NODES ) + ( SLURM_NPROCS % SLURM_JOB_NUM_NODES > 0 )))

for i in $(scontrol show hostnames=$SLURM_JOB_NODELIST); do
  machines=$machines:$i:$cores_x_node
done
machines=${machines:1}

cp $0 .
ln -s "${input_file}" .

echo "Drop caches on all nodes"
mpirun -np $SLURM_JOB_NUM_NODES -ppn 1 /bin/bash -c "sync && echo 3 | sudo tee /proc/sys/vm/drop_caches"

echo "Enabling Transparent Huge Pages (THP)"
mpirun -np $SLURM_JOB_NUM_NODES -ppn 1 /bin/bash -c "echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled"

echo "Install missing lib"
mpirun -np $SLURM_JOB_NUM_NODES -ppn 1 /bin/bash -c "sudo yum -y install mesa-libGLU"

# Ansys Mechanical gets the total number of cores from hostlist not from -np
"${APP_BIN_PATH}" -b -dis -mpi intelmpi -ssh -machines $machines -i $(basename ${input_file}) -o output.log
