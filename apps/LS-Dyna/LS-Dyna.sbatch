#!/bin/bash
#SBATCH --exclusive
#SBATCH -t 24:00:00
#SBATCH --nodes=2
#SBATCH --ntasks=384
#SBATCH --constraint=hpc7a.96xlarge
#SBATCH --partition=hpc7a


######################## EFA settings ######################## 
export I_MPI_OFI_LIBRARY_INTERNAL=0
module load intelmpi
export I_MPI_DEBUG=5
export I_MPI_FABRICS=shm:ofi
export I_MPI_OFI_PROVIDER=efa
export I_MPI_MULTIRAIL=1
module load libfabric-aws
export INTELMPI_ROOT="$(dirname $(dirname $(which mpirun)))"
######################## EFA settings ######################## 

SOLVER_PATH=${1:-"/fsx/ls-dyna_mpp_s_R10_2_0_x64_centos65_ifort160_avx2_intelmpi-2018/ls-dyna_mpp_s_R10_2_0_x64_centos65_ifort160_avx2_intelmpi-2018"}
input_file=${2:-"/fsx/MY_LS-DYNA_EXAMPLE/MY_INPUT_FILE.k"}
basedir=${BASE_DIR:-"/fsx"}

export LSTC_LICENSE_SERVER=${LSTC_LICENSE_SERVER:-"xxx.yyy.zzz."} #31010
export LSTC_MEMORY=auto

TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
workdir="$(readlink -m "${basedir}/${SLURM_JOB_NAME%.*}")/$(basename "${journal_file%.*}")/Run/${SLURM_JOB_ID}-${SLURM_JOB_NUM_NODES}x$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type)-${SLURM_NPROCS}-$(date "+%d-%m-%Y-%H-%M")"

echo "Execution directory is: ${workdir}"
mkdir -p "${workdir}" && cd "${workdir}"

echo "building the MPI hostfile"
scontrol show nodes $SLURM_NODELIST | grep NodeHostName= | awk '{print $2}' | sed 's/NodeHostName=//' >hostfile


## USE INTERNAL NVME DISK ONLY IF IT EXISTS, OTHERWISE USE THE SHARED DIR (FSx)
SCRATCH_BASE=$(mount | grep ephemeral | awk '{print $3}')
if [[ $? != 0 ]]; then
    echo "Scratch failed."
    exit 1
elif [[ $SCRATCH_BASE ]]; then
    export SCRATCH_DIR="${SCRATCH_BASE}/scratch-$SLURM_JOB_ID"
    mkdir -p "${SCRATCH_DIR}"
    export TMPDIR="${SCRATCH_DIR}"
else
    export SCRATCH_DIR="${workdir}/scratch-$SLURM_JOB_ID"
    mkdir -p "${SCRATCH_DIR}"
    export TMPDIR="${SCRATCH_DIR}"
fi

cp $0 .
ln -s ${input_file} .

# Create the pfile
cat > pfile << EOF
ge
{
 nobeamout
 nodump
 nofull
 lstc_reduce
}
 dir
{
local $SCRATCH_DIR
}
EOF


echo "Drop caches on all nodes"
mpirun -np $SLURM_JOB_NUM_NODES -ppn 1 /bin/bash -c "sync && echo 3 | sudo tee /proc/sys/vm/drop_caches"

echo "Enabling Transparent Huge Pages (THP)"
mpirun -np $SLURM_JOB_NUM_NODES -ppn 1 /bin/bash -c "echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled"

mpirun -hostfile hostfile -np ${SLURM_NPROCS} -bootstrap ssh -genvall $SOLVER_PATH i=$FILE_NAME | tee output.$SLURM_JOBID.out
