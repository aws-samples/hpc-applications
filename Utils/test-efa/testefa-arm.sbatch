#!/bin/sh
#SBATCH --job-name=hello-world-job
#SBATCH --ntasks=4
#SBATCH --output=%x_%j.out

#######################
## EFA / MPI SETTINGS ##
########################

module load openmpi5
module load libfabric-aws
export FI_LOG_LEVEL=debug
export OMPI_MCA_mtl_ofi_verbose=100

########################
## EFA / MPI SETTINGS ##
########################

env > env.txt

echo "recv_bytes before the mpi job:"
cat /sys/class/infiniband/*/ports/1/hw_counters/recv_bytes

mpirun ./ring.exe

echo "recv_bytes after the mpi job:"
cat /sys/class/infiniband/*/ports/1/hw_counters/recv_bytes


