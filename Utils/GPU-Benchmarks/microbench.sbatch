#!/bin/bash
#SBATCH --job-name=micro-bench
#SBATCH --partition=p5
#SBATCH --nodes=2
#SBATCH --exclusive
#SBATCH --gpus-per-node=8
#SBATCH --ntasks-per-node=8
#SBATCH --output=/fsx/HPL-Run/gpu/microbench-%j.out

#############################################################
# GPU system-readiness microbenchmarks over EFA (NCCL, OSU MPI,
# optional NVSHMEM) with the NVIDIA HPC-Benchmarks NGC container
# via Pyxis/Enroot.
#
# Usage:
#   sbatch microbench.sbatch                   # 2 nodes, default image
#   sbatch -p p5en -N 4 microbench.sbatch      # other partition / node count
#   IMAGE=/fsx/containers/hpc-benchmarks-26.02.01.sqsh sbatch microbench.sbatch  # local image
#   RUN_NVSHMEM=1 sbatch microbench.sbatch     # also run the NVSHMEM tests
#
# The NVSHMEM tests are skipped by default: NVSHMEM over EFA fails
# with the NVSHMEM 3.5.19 bundled in hpc-benchmarks 26.02/26.02.01
# (see README.md, "Known issues").
#############################################################

: "${IMAGE:=nvcr.io#nvidia/hpc-benchmarks:26.02.01}"
: "${MOUNTS:=/fsx:/fsx}"
: "${RUN_NVSHMEM:=0}"

COMMON="--cpu-bind=none --mpi=pmix --container-image=${IMAGE} --container-mounts=${MOUNTS}"
EXPORT="--export=ALL,OMPI_MCA_coll_ucc_enable=0,FI_PROVIDER=efa,FI_EFA_USE_DEVICE_RDMA=1"
NVSHMEM_EXPORT="${EXPORT},NVSHMEM_REMOTE_TRANSPORT=libfabric,NVSHMEM_LIBFABRIC_PROVIDER=efa,NVSHMEM_DISABLE_CUDA_VMM=1,FI_EFA_ENABLE_SHM_TRANSFER=0"

echo "============================================"
echo "Microbenchmarks | Job ${SLURM_JOB_ID}"
echo "Nodes: ${SLURM_JOB_NUM_NODES} | GPUs/node: 8"
echo "Nodes: $(scontrol show hostnames "$SLURM_JOB_NODELIST" | tr '\n' ' ')"
echo "Image: ${IMAGE}"
echo "============================================"

############################################################
# 1. NCCL Tests
############################################################
echo ""
echo "########################################"
echo "# NCCL All-Reduce (8 B - 8 GB)"
echo "########################################"
srun ${COMMON} ${EXPORT} \
    ./microbenchmarks/nccl_tests.sh --op allreduce --test-params "-b 8 -e 8G -f 2 -g 1" 2>&1

echo ""
echo "########################################"
echo "# NCCL All-to-All"
echo "########################################"
srun ${COMMON} ${EXPORT} \
    ./microbenchmarks/nccl_tests.sh --op alltoall --test-params "-b 8 -e 128M -f 2 -g 1" 2>&1

############################################################
# 2. NVSHMEM Performance Tests (opt-in, RUN_NVSHMEM=1)
############################################################
if [ "${RUN_NVSHMEM}" = "1" ]; then
    echo ""
    echo "########################################"
    echo "# NVSHMEM Device Put Bandwidth (2 ranks)"
    echo "########################################"
    srun -N2 --ntasks-per-node=1 ${COMMON} ${NVSHMEM_EXPORT} \
        ./microbenchmarks/nvshmem_device_tests.sh --op put-bw --test-params "-b 8 -e 128M -f 2" 2>&1

    echo ""
    echo "########################################"
    echo "# NVSHMEM Device All-to-All (all GPUs)"
    echo "########################################"
    srun ${COMMON} ${NVSHMEM_EXPORT} \
        ./microbenchmarks/nvshmem_device_tests.sh --op alltoall --test-params "-b 16 -e 128M -f 2" 2>&1
else
    echo ""
    echo "# NVSHMEM tests skipped (known issue on EFA with NVSHMEM 3.5.19; set RUN_NVSHMEM=1 to run them)"
fi

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
