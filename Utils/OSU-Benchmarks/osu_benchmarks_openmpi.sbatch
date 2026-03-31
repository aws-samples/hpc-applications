#!/bin/bash
#SBATCH --job-name=osu-benchmarks-openmpi
#SBATCH --constraint=hpc8a.96xlarge
#SBATCH --partition=hpc8a
#SBATCH --nodes=2
#SBATCH --exclusive
#SBATCH --output=osu-benchmarks-%j.out

module load openmpi
module load libfabric-aws

OSU_DIR="/fsx/OSU-Benchmark-OpenMPI/install/libexec/osu-micro-benchmarks/mpi"

echo "==> Running OSU Latency Test"
mpirun -np 2 --map-by node "${OSU_DIR}/pt2pt/osu_latency"

echo "==> Running OSU Bandwidth Test"
mpirun -np 8 -npernode 4 "${OSU_DIR}/pt2pt/osu_mbw_mr"

echo "==> Running OSU Allreduce Test"
mpirun -np 8 -npernode 4 "${OSU_DIR}/collective/osu_allreduce"
