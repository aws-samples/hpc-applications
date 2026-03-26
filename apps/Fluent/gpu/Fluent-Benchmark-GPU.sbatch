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

export TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
export instanceType=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type)
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
echo "Store InstanceIDs"
mpirun -np $SLURM_JOB_NUM_NODES -ppn 1 /bin/bash -c "export TOKEN=\$(curl -s -X PUT \"http://169.254.169.254/latest/api/token\" -H \"X-aws-ec2-metadata-token-ttl-seconds: 21600\"); instanceid=\$(curl -s -H \"X-aws-ec2-metadata-token: \$TOKEN\" http://169.254.169.254/latest/meta-data/instance-id); host_name=\$(hostname); echo \$instanceid\":\"\$host_name >> ${workdir}/instance-ids"
echo "Drop caches on all nodes"
mpirun -np $SLURM_JOB_NUM_NODES -ppn 1 /bin/bash -c "sync && echo 3 | sudo tee /proc/sys/vm/drop_caches"
echo "Enabling Transparent Huge Pages (THP)"
mpirun -np $SLURM_JOB_NUM_NODES -ppn 1 /bin/bash -c "echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled"


${FLUENT_PYTHON_PATH} ${APP_BIN_PATH} -gpu -cores ${SLURM_NPROCS} -cases ${benchmark_file%.*} -cflush -mpiopt="-genv I_MPI_DEBUG 5" -peth.efa -cnf=./hostfile -part=4 -platform=intel -nosyslog -noloadchk -ssh -mpi=intel -norm | tee output.$SLURM_JOBID.out
