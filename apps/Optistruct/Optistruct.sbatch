#!/bin/bash
#SBATCH --exclusive
#SBATCH -t 12:00:00 # Run time (hh:mm:ss) 
#SBATCH --chdir=/fsx-shared/slurm-out
##SBATCH -L optistruct:1   #TODO: figure out how to limit by licence restraint
#SBATCH --constraint=hpc6id.32xlarge
#SBATCH --ntasks=64  # 1 node 

## Please note this script is a work in progress

export I_MPI_OFI_LIBRARY_INTERNAL=0
module load intelmpi
export I_MPI_FABRICS=shm:ofi
export I_MPI_OFI_PROVIDER=efa
export FI_EFA_FORK_SAFE=1
module load libfabric-aws
export I_MPI_DEBUG=5

export KMP_AFFINITY=verbose
export OMP_NUM_THREADS=${1:-32}  # 32 cores per socket in hpc6id
export I_MPI_PIN_DOMAIN=omp:compact

export INPUT_FILE=${2:-"/path/to/input.fem"}
export ALTAIR_HOME="/fsx-shared/altair/2022.1/altair"
export RADFLEX_PATH="${ALTAIR_HOME}/hwsolvers/common/bin/linux64"
export LD_LIBRARY_PATH=${LD_LIBRARY_PATH}:${RADFLEX_PATH}
export OPTISTRUCT_LIBS="${ALTAIR_HOME}/hwsolvers/optistruct/bin/linux64"
export LD_LIBRARY_PATH=${LD_LIBRARY_PATH}:${OPTISTRUCT_LIBS}
export ALTAIR_OPTISTRUCT_EXEC="${ALTAIR_HOME}/hwsolvers/optistruct/bin/linux64/optistruct_2022.1_linux64_impi"

export ALM_HHWU=T
export ALM_HHWU_TOKEN=$(aws secretsmanager get-secret-value --secret-id arn:xxx --query SecretString --output text --region xxx)
export ALM_HHWU_USE_WININET=1

export basedir="/fsx-shared"

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
    export SCRATCH_DIR="${basedir}/scratch/scratch-$SLURM_JOB_ID"
    mkdir -p "${SCRATCH_DIR}"
    export TMPDIR="${SCRATCH_DIR}"
fi

scontrol show nodes $SLURM_NODELIST | grep NodeHostName= | awk '{print $2}' | sed 's/NodeHostName=//' >hostfile

echo "Drop caches on all nodes"
mpirun -np $SLURM_JOB_NUM_NODES -ppn 1 /bin/bash -c "sync && echo 3 | sudo tee /proc/sys/vm/drop_caches"

#/fsx/Altair/2022.1/altair/scripts/optistruct -v 2022.1 $(basename "${INPUT_FILE}") -mpi i -mpipath $(dirname $(which mpirun)) -hostfile hostfile -core in -np $SLURM_NPROCS -nt "${1}" -ddm -checkel NO -tmpdir "${SCRATCH_DIR}" -out -outfile "${LOG_FILE}"

nprocs=$((SLURM_NTASKS / OMP_NUM_THREADS))
nprocspernode=$((nprocs / SLURM_JOB_NUM_NODES))
mpirun -np $nprocs -ppn $nprocspernode -genvall $ALTAIR_OPTISTRUCT_EXEC -core=in -nt=${OMP_NUM_THREADS} -ddmmode $(basename "${INPUT_FILE}") -tmpdir="${SCRATCH_DIR}" -checkel=NO -out -outfile="${LOG_FILE}"
# -genvall: export all environment variables to all procs
# -core=in: tell Optistruct to use as much memory as possible, then overflow to disk
# -ddmode: Domain Decomposition Method
# -checkel=NO: Element quality checks are not performed, but mathematical validity checks are performed.