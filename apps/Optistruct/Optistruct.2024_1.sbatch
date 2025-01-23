#!/bin/bash
#SBATCH --exclusive
#SBATCH -t 99:00:00
#SBATCH --nodes=2
#SBATCH --ntasks=128
#SBATCH --constraint=hpc6id.32xlarge
#SBATCH --partition=hpc6id


export I_MPI_OFI_LIBRARY_INTERNAL=0
#module load intelmpi
export I_MPI_FABRICS=shm:ofi
export I_MPI_OFI_PROVIDER=efa
export FI_EFA_FORK_SAFE=1
#export I_MPI_MULTIRAIL=1
module load libfabric-aws
export I_MPI_DEBUG=5

OPTISTRUCT_VER="2024.1"
INPUT_FILE=${2:-"/path/to/Engine_Assy.fem"}
export ALTAIR_HOME="/fsx/Altair"
export RADFLEX_PATH="${ALTAIR_HOME}/${OPTISTRUCT_VER}/altair/hwsolvers/common/bin/linux64"
export LD_LIBRARY_PATH=${LD_LIBRARY_PATH}:${RADFLEX_PATH}

export TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
instanceType=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type)

export ALM_HHWU=T
export ALM_HHWU_TOKEN=$(aws secretsmanager get-secret-value --secret-id arn:xxx --query SecretString --output text --region xxx)
export ALM_HHWU_USE_WININET=1

basedir="/fsx/${SLURM_JOB_NAME%.*}"
INPUT_DIR="${basedir}/Model"
export workdir="${basedir}/Run/${INPUT_FILE%.*}/${SLURM_JOB_ID}-${SLURM_JOB_NUM_NODES}x${instanceType}-${SLURM_NPROCS}-$(date '+%d-%m-%Y-%H-%M')"

export NTHREADS=${1:-"8"}
export MPI_PROC=$((SLURM_NPROCS / NTHREADS))

mkdir -p "${workdir}" && cd "${workdir}"

cp $0 .
ln -s ${INPUT_DIR}/* .

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
    export SCRATCH_DIR="${workdir}/scratch/scratch-$SLURM_JOB_ID"
    mkdir -p "${SCRATCH_DIR}"
    export TMPDIR="${SCRATCH_DIR}"
fi

scontrol show nodes $SLURM_NODELIST | grep NodeHostName= | awk '{print $2}' | sed 's/NodeHostName=//' >hostfile

mpirun -n $SLURM_JOB_NUM_NODES --map-by ppr:1:node /bin/bash -c "sync && echo 3 | sudo tee /proc/sys/vm/drop_caches"
mpirun -n $SLURM_JOB_NUM_NODES --map-by ppr:1:node /bin/bash -c "echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled"

"${ALTAIR_HOME}/${OPTISTRUCT_VER}/altair/scripts/optistruct" ${INPUT_FILE} -mpipath /opt/intel/mpi/2021.13/bin -mpi i -ddm -np $MPI_PROC -nt ${NTHREADS} -hostfile hostfile -core in -tmpdir "${SCRATCH_DIR}" -out -outfile output.txt