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

TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
workdir="$(readlink -m "${basedir}/${SLURM_JOB_NAME%.*}")/${benchmark_file%.*}/${SLURM_JOB_ID}-${SLURM_JOB_NUM_NODES}x$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type)-${SLURM_NPROCS}-$(date "+%d-%m-%Y-%H-%M")"

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

"${APP_BIN_PATH}" ${benchmark_file%.*} -t${SLURM_NPROCS}  -cnf=hostfile -part=4 -nosyslog -noloadchk -ssh -p=eth.efa -mpi=openmpi