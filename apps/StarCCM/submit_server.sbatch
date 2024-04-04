#!/bin/bash
#SBATCH --job-name=star_job
####SBATCH --ntasks=192
#SBATCH --output=%x_%j.out
#SBATCH --partition=hpc7a-96
#SBATCH --exclusive
#SBATCH --dependency=singleton
## 64 cores per c6in, 96 per hpc6a, 36 per c5n, 24 per c5a, 48 per hpc5a

# hpc7a

# use libfabric patched version for hpc7a
#export PATH=/fsx/libfabric-1.19.0.rc1/bin:$PATH
#export LD_LIBRARY_PATH=/fsx/libfabric-1.19.0.rc1/lib:$LD_LIBRARY_PATH

# HPC7a has 2x EFA NICs so to use both you need to set the following with Intel MPI. This is supported only with Intel MPI 2021.6 and onwards. ParallelCluster 3.6.1 should have 2$
export I_MPI_MULTIRAIL=1
export FI_EFA_FORK_SAFE=1

# Libfabric has a hardcoded limit on SHM AV size which restricts to run >128 MPI ranks per instance and the workarounds is as below. This will be fixed in a future libfabric rele$
export FI_EFA_SHM_AV_SIZE=256

# Make sure to tell Intel MPI to use the external libfabric version with the flag:
export I_MPI_OFI_LIBRARY_INTERNAL=0


export I_MPI_FABRICS=shm:ofi
export I_MPI_OFI_PROVIDER=efa
export I_MPI_HYDRA_BRANCH_COUNT=0
#export I_MPI_DEBUG=5
# export I_MPI_PIN=1
ulimit -s unlimited


# load system intelmpi
module load intelmpi

echo "Drop caches on all nodes"
mpirun -np $SLURM_JOB_NUM_NODES -ppn 1 /bin/bash -c "sync && echo 3 | sudo tee /proc/sys/vm/drop_caches"

echo "Enabling Transparent Huge Pages (THP)"
mpirun -np $SLURM_JOB_NUM_NODES -ppn 1 /bin/bash -c "echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled"


NUM_CORES=$((${SLURM_CPUS_ON_NODE} * $SLURM_JOB_NUM_NODES))
echo ${SLURM_CPUS_ON_NODE}
echo $SLURM_JOB_NUM_NODES
echo "Number of cores: ${NUM_CORES}"

starvers=18.04.008
astarvers=17.04.007

# STAR-CCM+ Versions 
# 17.04.007 18.02.008

delete_resultant_directory=false

SIM_FILE=${1}
MACRO=/fsx/benchmarking/lemans_17m/timeSimulation.java
export INSTANCE=${SLURM_JOB_PARTITION}
CUSTOM_TAGS="IntelMPI_${INSTANCE}_${starvers}"


echo "Host list:"
echo ${SLURM_NODELIST}

scontrol show hostname > hostlist

# Create a working directory with a time-stamp
WORKDIR=${SLURM_JOB_ID}-${INSTANCE}-${SLURM_NTASKS}-WD_$(date +%Y%m%d_%H%M%S)-"${CUSTOM_TAGS}"
mkdir -p $WORKDIR
# soft link the model input files to the working directory
ln -s ../${SIM_FILE} $WORKDIR/.
cp  ${MACRO} $WORKDIR/.
cp submit.sh ${WORKDIR}/.
ORIGDIR=`pwd`
cd $WORKDIR

# Use intel or openmp4 for mpi

/fsx/Siemens/${starvers}/STAR-CCM+${starvers}/star/bin/starccm+ \
        -bs slurm \
        -power \
        -podkey "${PODLIC}" \
        -licpath 1999@flex.cd-adapco.com \
        -xsystemlibfabric -ldlibpath /opt/amazon/efa/lib64 \
        -fabric OFI \
        -mpi intel \
	-server \
	${SIM_FILE} > ${SLURM_JOB_ID}-${INSTANCE}-${SLURM_NTASKS}-$(date +%Y%m%d_%H%M%S).out

cd ${ORIGDIR}

if [ "$delete_resultant_directory" = true ] ; then
	echo "Deleting the working directory with saved sim file and simulation output file as requested."
	rm -rfv ${WORKDIR}
fi
