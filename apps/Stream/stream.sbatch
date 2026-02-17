#!/bin/bash
#SBATCH --exclusive
#SBATCH -t 24:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=192
#SBATCH --constraint=hpc8a.96xlarge
#SBATCH --partition=hpc8a
#SBATCH --chdir=/fsx/slurm-out/stream

source setenv_AOCC.sh

# For optimal stream performance, it is recommended to set the following OS parameters (requires root/sudo access)
sync && echo 3 | sudo tee /proc/sys/vm/drop_caches # Clear caches to maximize available RAM
sync && echo 1 | sudo tee /proc/sys/vm/compact_memory  # Rearrange RAM usage to maximise the size of free blocks
echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled  # Enable hugepages
echo always | sudo tee /sys/kernel/mm/transparent_hugepage/defrag # Enable hugepages


# Optimize OpenMP performance behavious
export OMP_SCHEDULE=static  # Disable dynamic loop scheduling
export OMP_PROC_BIND=TRUE   # Bind threads to specific resources
export OMP_DYNAMIC=false    # Disable dynamic thread pool sizing
export OMP_THREAD_LIMIT=256
export OMP_STACKSIZE=256M
#export OMP_NESTED=FALSE


############# FOR AMD EPYC™ 9654 ##################
# For example, a dual socket AMD 4th Gen EPYC™ Processor with 192 (96x2) cores,
# with 4 threads per L3 cache: 96 total places, stride by 2 cores:
#export OMP_PLACES=0:96:2
#export OMP_NUM_THREADS=96

############# FOR Hpc6a ##################
# For example, a dual socket AMD 3rd Gen EPYC™ Processor with 96 (48x2) cores,
# with 1 thread per L3 cache: 12 total places, stride by 8 cores:
export OMP_PLACES=0:12:8
export OMP_NUM_THREADS=12


############# FOR Hpc[7-8]a ##################
# For example, a dual socket AMD 4th or 5th Gen EPYC™ Processor with 192 (96x2) cores,
# with 1 thread per L3 cache: 24 total places, stride by 8 cores:
export OMP_PLACES=0:24:8
export OMP_NUM_THREADS=24


./stream
