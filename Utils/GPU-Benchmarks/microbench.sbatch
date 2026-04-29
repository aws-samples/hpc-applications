#!/bin/bash
#SBATCH --job-name=micro-bench
#SBATCH --partition=p5
#SBATCH --nodes=2
#SBATCH --exclusive
#SBATCH --gpus-per-node=8
#SBATCH --ntasks-per-node=8
#SBATCH --output=/fsx/HPL-Run/gpu/microbench-%j.out

IMAGE="nvcr.io#nvidia/hpc-benchmarks:26.02"
MOUNTS="/fsx:/fsx"
COMMON="--cpu-bind=none --mpi=pmix --container-image=${IMAGE} --container-mounts=${MOUNTS}"
EXPORT="--export=ALL,OMPI_MCA_coll_ucc_enable=0,FI_PROVIDER=efa,FI_EFA_USE_DEVICE_RDMA=1"

echo "============================================"
echo "Microbenchmarks | Job ${SLURM_JOB_ID}"
echo "Nodes: ${SLURM_JOB_NUM_NODES} | GPUs/node: 8"
echo "Nodes: $(scontrol show hostnames $SLURM_JOB_NODELIST | tr '\n' ' ')"
echo "============================================"

############################################################
# 1. NCCL Tests
############################################################
echo ""
echo "########################################"
echo "# NCCL All-Reduce"
echo "########################################"
srun ${COMMON} ${EXPORT} \
    ./microbenchmarks/nccl_tests.sh --op allreduce --test-params "-b 8 -e 128M -f 2 -g 1" 2>&1

echo ""
echo "########################################"
echo "# NCCL All-to-All"
echo "########################################"
srun ${COMMON} ${EXPORT} \
    ./microbenchmarks/nccl_tests.sh --op alltoall --test-params "-b 8 -e 128M -f 2 -g 1" 2>&1

############################################################
# 2. NVSHMEM Performance Tests
############################################################
echo ""
echo "########################################"
echo "# NVSHMEM Device Put Bandwidth (2 ranks)"
echo "########################################"
srun -N2 --ntasks-per-node=1 ${COMMON} ${EXPORT},NVSHMEM_REMOTE_TRANSPORT=libfabric,NVSHMEM_DISABLE_CUDA_VMM=1 \
    ./microbenchmarks/nvshmem_device_tests.sh --op put-bw --test-params "-b 8 -e 128M -f 2" 2>&1

echo ""
echo "########################################"
echo "# NVSHMEM Device All-to-All (all GPUs)"
echo "########################################"
srun ${COMMON} ${EXPORT},NVSHMEM_REMOTE_TRANSPORT=libfabric,NVSHMEM_DISABLE_CUDA_VMM=1 \
    ./microbenchmarks/nvshmem_device_tests.sh --op alltoall --test-params "-b 16 -e 128M -f 2" 2>&1

############################################################
# 3. OSU MPI Benchmarks
############################################################
echo ""
echo "########################################"
echo "# OSU MPI Latency (2 ranks)"
echo "########################################"
srun -N2 --ntasks-per-node=1 ${COMMON} ${EXPORT} \
    ./microbenchmarks/osu_mpi_tests.sh --op latency 2>&1

echo ""
echo "########################################"
echo "# OSU MPI Bandwidth (2 ranks)"
echo "########################################"
srun -N2 --ntasks-per-node=1 ${COMMON} ${EXPORT} \
    ./microbenchmarks/osu_mpi_tests.sh --op bw 2>&1

echo ""
echo "########################################"
echo "# OSU MPI All-Reduce (all ranks)"
echo "########################################"
srun ${COMMON} ${EXPORT} \
    ./microbenchmarks/osu_mpi_tests.sh --op allreduce --test-params "-m 1024:1048576" 2>&1

echo ""
echo "=== ALL MICROBENCHMARKS DONE ==="
