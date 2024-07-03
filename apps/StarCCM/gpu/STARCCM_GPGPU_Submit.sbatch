#!/bin/bash
#SBATCH --job-name=STAR_GPGPU_JOB
#SBATCH --tasks=16
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=8
#SBATCH --partition=p4d24
#SBATCH --output=%x_%j.out
#SBATCH --exclusive
#SBATCH --no-requeue


# This is a submit script pared right down to the bare minuimum of what is needed to run on AWS.
# Submit this on SLURM using sbatch thisScript.sbatch 18.06.007 sim_file.sim macro.java
# It assumes the software has been installed on the FSx for Lustre file store at the /fsx/Siemens
# location with the remainder of the path using the Siemens defaults.

# Note that this script is a bare minimum to get up and running; there are no optimisations for
# particular AWS instances or scripting for advanced license options

# Note also that this script uses Intel MPI built into STAR-CCM+, not OpenMPI.
# Lastly, the version of libfabric called assumes this script is being used on AWS ParallelCluster
# with libfabric in the install location that uses.


# Tell Intel MPI to use external libfabric version with:
export I_MPI_OFI_LIBRARY_INTERNAL=0
module load intelmpi
export I_MPI_FABRICS=shm:ofi
export I_MPI_OFI_PROVIDER=efa
# This is to ensure the correct EFA fabrics are used.

export I_MPI_HYDRA_BRANCH_COUNT=0
export I_MPI_PIN=1
export FI_EFA_SHM_AV_SIZE=256
export FI_EFA_FORK_SAFE=1
ulimit -s unlimited


# Some HPC instances have multiple NICs and so we enable this with Intel MPI with the following command:
export I_MPI_MULTIRAIL=1

export FI_EFA_FORK_SAFE=1

# Specify STAR-CCM+ version to use
APP_VERSION=${1:-"18.06.007"}
# Specify a default sim file you want to use.
starccm_sim=${2:-"/fsx/MY_STARCCM_EXAMPLE/myStarccmModel.sim"}
# Specify a macro file you want to use. Note that if this is left blank the simulation will just solve.
MACRO=${3:-""}
starccm_sim_file=$(basename ${starccm_sim})

# Example for Power On Demand license only, customize as needed. For example, if using a license server, then
# that should be referred to here.
LICENSEOPTS="-power -podkey ${PODLIC} -licpath 1999@flex.cd-adapco.com"

# Generate host and gpu files
rm -rf ${SLURM_JOB_ID}_hosts.txt
rm -rf ${SLURM_JOB_ID}_gpus.txt
for i in `scontrol show hostname $SLURM_NODELIST`
do
  echo $i:8 >> ${SLURM_JOB_ID}_hosts.txt
  echo $i auto:8 >> ${SLURM_JOB_ID}_gpus.txt
done
echo ${SLURM_JOB_ID}_hosts.txt
cat ${SLURM_JOB_ID}_hosts.txt
echo ========================
echo ${SLURM_JOB_ID}_gpus.txt
cat ${SLURM_JOB_ID}_gpus.txt
echo ========================

echo ========================
echo Start Time:    `date`

# Check the path to STAR-CCM+ (with the app version variable) points to the install of STAR-CCM+
/fsx/Siemens/${APP_VERSION}/STAR-CCM+${APP_VERSION}/star/bin/starccm+ \
    -gpgpu file:${SLURM_JOB_ID}_gpus.txt -np 16 \
	  -machinefile ${SLURM_JOB_ID}_hosts.txt \
    -pio \
    -bs slurm \
    ${LICENSEOPTS} \
    -mpi intel \
    -xsystemlibfabric -ldlibpath /opt/amazon/efa/lib64 \
    -fabric OFI \
    -batch ${MACRO} \
    ${starccm_sim_file} > "${starccm_sim_file%.*}.log" 2>&1


echo ========================
echo Finish Time:    `date`
