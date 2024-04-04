#!/bin/bash
#SBATCH --nodes=2
#SBATCH --partition=hpc7a
#SBATCH --output=%x_%j.out
#SBATCH --exclusive


# This is a submit script pared right down to the bare minuimum of what is needed to run on AWS.
# Submit this on SLURM using sbatch thisScript.sbatch 18.06.007 sim_file.sim macro.java
# It assumes the software has been installed on the FSx for Lustre file store at the /fsx/Siemens
# location with the remainder of the path using the Siemens defaults.

# Note that this script is a bare minimum to get up and running; there are no optimisations for
# particular AWS instances or scripting for advanced license options


module load intelmpi
# Tell Intel MPI to use external libfabric version with:
export I_MPI_OFI_LIBRARY_INTERNAL=0
export I_MPI_FABRICS=shm:ofi
export I_MPI_OFI_PROVIDER=efa

# Some HPC instances have multiple NICs and so we enable this with Intel MPI with the following command:
export I_MPI_MULTIRAIL=1

export FI_EFA_FORK_SAFE=1


APP_VERSION=${1:-"18.06.007"}
starccm_sim=${2:-"/fsx/MY_STARCCM_EXAMPLE/myStarccmModel.sim"}
MACRO=${3:-""}
starccm_sim_file=$(basename ${starccm_sim})

# Example for Power On Demand license only, customize as needed
LICENSEOPTS="-power -podkey ${PODLIC} -licpath 1999@flex.cd-adapco.com"

# Check the path to STAR-CCM+ (with the app version variable) points to the install of STAR-CCM+
/fsx/Siemens/${APP_VERSION}/STAR-CCM+${APP_VERSION}/star/bin/starccm+ \
    -pio \
    -bs slurm \
    ${LICENSEOPTS} \
    -mpi intel \
    -xsystemlibfabric -ldlibpath /opt/amazon/efa/lib64 \
    -fabric OFI \
    -batch ${MACRO} \
    ${starccm_sim_file} > "${starccm_sim_file%.*}.log" 2>&1