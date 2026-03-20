#!/bin/sh
#SBATCH --job-name=hello-world-job
#SBATCH --ntasks=4
#SBATCH --output=%x_%j.out

#######################
## EFA / MPI SETTINGS ##
########################

export I_MPI_OFI_LIBRARY_INTERNAL=0
export FI_EFA_SHM_AV_SIZE=256
export FI_MR_CACHE_MONITOR=memhooks
export I_MPI_FABRICS=shm:ofi
export I_MPI_OFI_PROVIDER=efa
numNICs=$(lspci | grep 'efa' | wc -l)
if [[ "$numNICs" -ge "2" ]]; then
  export I_MPI_MULTIRAIL=1
    export FI_EFA_FORK_SAFE=1
    fi
    module load intelmpi

    module load libfabric-aws
    export INTELMPI_ROOT="$(dirname $(dirname $(which mpirun)))"
    export I_MPI_DEBUG=5

########################
## EFA / MPI SETTINGS ##
########################

env > env.txt

echo "recv_bytes before the mpi job:"
cat /sys/class/infiniband/*/ports/1/hw_counters/recv_bytes

mpirun ./ring.exe

echo "recv_bytes after the mpi job:"
cat /sys/class/infiniband/*/ports/1/hw_counters/recv_bytes


