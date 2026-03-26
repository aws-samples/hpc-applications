#!/bin/bash
#SBATCH --exclusive
#SBATCH --nodes=1
#SBATCH --ntasks=24
#SBATCH --constraint=hpc8a.96xlarge
#SBATCH --partition=hpc8a

######################## IntelMPI/EFA settings ######################## 
module load intelmpi
export I_MPI_DEBUG=5
export I_MPI_FABRICS=shm:ofi
export I_MPI_OFI_PROVIDER=efa

export I_MPI_PIN=1	#enable pinning
export I_MPI_PIN_ORDER=spread	#spread ranks over all the CCD/NUMA nodes available
#I_MPI_PIN_DOMAIN=cache3	#spread ranks equally on L3 cache / CCX / CCD


mpicc hello-cpu.c -o hello-cpu
mpirun -n ${SLURM_NPROCS} ./hello-cpu
