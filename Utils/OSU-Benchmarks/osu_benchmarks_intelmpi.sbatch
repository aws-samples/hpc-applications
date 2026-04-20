#!/bin/bash
#SBATCH --job-name=osu-benchmarks-intelmpi
#SBATCH --constraint=hpc8a.96xlarge
#SBATCH --partition=hpc8a
#SBATCH --nodes=2
#SBATCH --exclusive
#SBATCH --output=osu-benchmarks-intelmpi-%j.out

module load intelmpi
module load libfabric-aws

######################## EFA settings ######################## 
export I_MPI_OFI_LIBRARY_INTERNAL=0
module load intelmpi
export I_MPI_DEBUG=5
export I_MPI_FABRICS=shm:ofi
export I_MPI_OFI_PROVIDER=efa
export I_MPI_MULTIRAIL=1
module load libfabric-aws
######################## EFA settings ######################## 


OSU_DIR="/fsx/OSU-Benchmark-IntelMPI/install/libexec/osu-micro-benchmarks/mpi"

echo "==> Running OSU Latency Test (Intel MPI)"
mpirun -np 2 -ppn 1 "${OSU_DIR}/pt2pt/osu_latency"

echo "==> Running OSU Bandwidth Test (Intel MPI)"
mpirun -np 2 -ppn 1 "${OSU_DIR}/pt2pt/osu_bw"

echo "==> Running OSU Allreduce Test (Intel MPI)"
mpirun -np 2 -ppn 1 "${OSU_DIR}/collective/osu_allreduce"
