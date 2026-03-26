#!/bin/bash
#SBATCH --exclusive
#SBATCH --nodes=1
#SBATCH --ntasks=24
#SBATCH --constraint=hpc8a.96xlarge
#SBATCH --partition=hpc8a
#SBATCH --chdir=/fsx/hello-world/

######################## IntelMPI/EFA settings ######################## 
module load openmpi
module load libfabric-aws
#export FI_LOG_LEVEL=warn 
#export OMPI_MCA_mtl_ofi_verbose=100



cd /fsx/hello-world

mpicc hello-cpu.c -o hello-cpu

mpirun -np ${SLURM_NPROCS} --map-by L3cache:PE=1 --report-bindings ./hello-cpu
