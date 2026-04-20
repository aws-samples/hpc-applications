#!/bin/bash
#SBATCH --exclusive
#SBATCH -t 24:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=192
#SBATCH --constraint=hpc8a.96xlarge
#SBATCH --partition=hpc8a
#SBATCH --chdir=/fsx/slurm-out/stream
#SBATCH --job-name=stream-aocc

# OS tuning
sync && echo 3 | sudo tee /proc/sys/vm/drop_caches
sync && echo 1 | sudo tee /proc/sys/vm/compact_memory
echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled
echo always | sudo tee /sys/kernel/mm/transparent_hugepage/defrag

# OpenMP settings
export OMP_SCHEDULE=static
export OMP_PROC_BIND=spread
export OMP_DYNAMIC=false
export OMP_THREAD_LIMIT=256
export OMP_STACKSIZE=256M

# Optimal for hpc8a.96xlarge: 24 threads = 1 per L3 cache
export OMP_PLACES=0:24:8
export OMP_NUM_THREADS=24

# AOCC runtime
export LD_LIBRARY_PATH=/fsx/aocc/aocc-compiler-5.1.0/lib:$LD_LIBRARY_PATH

echo "STREAM Benchmark - AOCC 5.1.0 (hpc8a.96xlarge)"
/fsx/hpc-applications/apps/Stream/stream
