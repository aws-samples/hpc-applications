#!/bin/bash
set -e

#############################################################
# Run HPL-NVIDIA (GPU-accelerated) via NGC container
#
# Target: p5en.48xlarge (8x H200 141GB, 192 vCPUs, 2TB RAM)
#         Also works on p5.48xlarge (8x H100 80GB)
#
# NVIDIA distributes their GPU-optimized HPL as a pre-built
# binary inside the NGC hpc-benchmarks container. The upstream
# netlib HPL 2.3 has no GPU support — this is NVIDIA's
# closed-source fork that offloads DGEMM to GPUs via cuBLAS
# while using CPUs for panel factorization.
#
# The container includes hpl.sh, a wrapper that sets up
# affinity and launches xhpl with the correct libraries.
#
# Prerequisites (all present on DLAMI):
#   - Docker with NVIDIA runtime (nvidia-container-toolkit)
#   - CUDA drivers
#
# Usage:
#   bash run_hpl_gpu.sh                    # defaults
#   HPL_N=400000 bash run_hpl_gpu.sh       # custom N
#   HPL_NGC_TAG=24.09 bash run_hpl_gpu.sh  # different container version
#
# Tuning results on p5en.48xlarge (8x H200):
#
#   | NB   | P×Q | TFLOPS | TFLOPS/GPU | Notes                  |
#   |------|-----|--------|------------|------------------------|
#   |  256 | 2×4 |  304.6 |       38.1 | Conservative baseline  |
#   |  512 | 1×8 |  344.5 |       43.1 | Better grid            |
#   |  768 | 1×8 |  360.1 |       45.0 |                        |
#   | 1024 | 1×8 |  366.8 |       45.9 | CHUNK=32               |
#   | 1024 | 1×8 |  378.3 |       47.3 | CHUNK=64, CTA=32 (*)  |
#
#   (*) Best: 378.3 TFLOPS = 70.5% of H200 FP64 peak (67 TFLOPS)
#############################################################

############################################################
# Defaults — override via environment variables
############################################################
: "${HPL_NGC_TAG:=25.02}"
: "${HPL_NB:=1024}"
: "${HPL_MEM_FRACTION:=0.90}"
: "${HPL_WORK_DIR:=/tmp/hpl-gpu-run}"

NGC_IMAGE="nvcr.io/nvidia/hpc-benchmarks:${HPL_NGC_TAG}"

############################################################
# Detect hardware
############################################################
NUM_GPUS=$(nvidia-smi -L | wc -l)
GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1 | xargs)
GPU_MEM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1 | xargs)
TOTAL_CPU_CORES=$(nproc)

echo "==> Detected: ${NUM_GPUS}x ${GPU_NAME} (${GPU_MEM_MB} MiB each)"
echo "    CPU cores: ${TOTAL_CPU_CORES}"

############################################################
# Build CPU/memory affinity from GPU topology
# p5en: 2 sockets, 48 cores each (96 physical, 192 with HT)
#   GPU 0-3 → NUMA 0 (cores 0-47, HT 96-143)
#   GPU 4-7 → NUMA 1 (cores 48-95, HT 144-191)
############################################################
CORES_PER_SOCKET=48
CORES_PER_GPU=$((CORES_PER_SOCKET / (NUM_GPUS / 2)))

CPU_AFF=""
MEM_AFF=""
for gpu in $(seq 0 $((NUM_GPUS - 1))); do
    if [ "$gpu" -lt $((NUM_GPUS / 2)) ]; then
        numa=0
        start=$((gpu * CORES_PER_GPU))
    else
        numa=1
        local_gpu=$((gpu - NUM_GPUS / 2))
        start=$((CORES_PER_SOCKET + local_gpu * CORES_PER_GPU))
    fi
    end=$((start + CORES_PER_GPU - 1))
    CPU_AFF="${CPU_AFF:+${CPU_AFF}:}${start}-${end}"
    MEM_AFF="${MEM_AFF:+${MEM_AFF}:}${numa}"
done

echo "    CPU affinity: ${CPU_AFF}"
echo "    MEM affinity: ${MEM_AFF}"

############################################################
# Compute HPL parameters
############################################################
NB=${HPL_NB}

# Problem size based on total GPU memory
TOTAL_GPU_MEM_BYTES=$((NUM_GPUS * GPU_MEM_MB * 1024 * 1024))
if [ -n "${HPL_N}" ]; then
    N=${HPL_N}
else
    N=$(awk -v mem="${TOTAL_GPU_MEM_BYTES}" -v nb="${NB}" -v frac="${HPL_MEM_FRACTION}" \
        'BEGIN { n=int(sqrt(frac * mem / 8) / nb) * nb; print n }')
fi

# Process grid: 1 MPI rank per GPU, P=1 Q=NUM_GPUS
# P=1 Q=N outperforms P=2 Q=N/2 on single-node NVSwitch
# topologies because it minimizes row-swap communication
if [ -n "${HPL_P}" ] && [ -n "${HPL_Q}" ]; then
    P=${HPL_P}
    Q=${HPL_Q}
else
    P=1
    Q=${NUM_GPUS}
fi

echo "    N=${N} NB=${NB} P=${P} Q=${Q} ranks=${NUM_GPUS}"

############################################################
# Pull container
############################################################
echo "==> Pulling NGC container: ${NGC_IMAGE}"
sudo docker pull "${NGC_IMAGE}"

############################################################
# Prepare working directory and HPL.dat
############################################################
mkdir -p "${HPL_WORK_DIR}"

cat > "${HPL_WORK_DIR}/HPL.dat" <<EOF
HPLinpack benchmark input file
Innovative Computing Laboratory, University of Tennessee
HPL.out      output file name (if any)
6            device out (6=stdout,7=stderr,file)
1            # of problems sizes (N)
${N}         Ns
1            # of NBs
${NB}        NBs
0            PMAP process mapping (0=Row-,1=Column-major)
1            # of process grids (P x Q)
${P}         Ps
${Q}         Qs
16.0         threshold
1            # of panel fact
2            PFACTs (0=left, 1=Crout, 2=Right)
1            # of recursive stopping criteria
4            NBMINs (>= 1)
1            # of panels in recursion
2            NDIVs
1            # of recursive panel fact.
1            RFACTs (0=left, 1=Crout, 2=Right)
1            # of broadcast
1            BCASTs (0=1rg,1=1rM,2=2rg,3=2rM,4=Lng,5=LnM)
1            # of lookahead depth
1            DEPTHs (>=0)
2            SWAP (0=bin-exch,1=long,2=mix)
64           swapping threshold
0            L1 in (0=transposed,1=no-transposed) form
0            U  in (0=transposed,1=no-transposed) form
1            Equilibration (0=no,1=yes)
8            memory alignment in double (> 0)
EOF

echo "==> HPL.dat written to ${HPL_WORK_DIR}/HPL.dat"

############################################################
# System tuning
############################################################
echo madvise | sudo tee /sys/kernel/mm/transparent_hugepage/enabled > /dev/null 2>&1 || true
sudo sysctl -w vm.nr_hugepages=40000 > /dev/null 2>&1 || true

############################################################
# Run HPL-NVIDIA
#
# Key environment variables (tuned on p5en.48xlarge):
#   HPL_USE_NVSHMEM=1       GPU-initiated comms over NVSwitch
#   HPL_P2P_AS_BCAST=1      NCCL send/recv for broadcast
#   HPL_NVSHMEM_SWAP=1      Row swaps via NVSHMEM over NVSwitch
#   HPL_FCT_COMM_POLICY=0   Panel factorization comms via NVSHMEM
#   HPL_CHUNK_SIZE_NBS=64   Larger compute chunks for better GPU util
#   HPL_CTA_PER_FCT=32      More thread blocks for factorization
#   HPL_ALLOC_HUGEPAGES=1   2MB hugepages for host allocations
#   HPL_DIST_TRSM_FLAG=1    Distributed TRSM across all ranks
############################################################
echo "==> Running HPL-NVIDIA: ${NUM_GPUS} GPUs, N=${N}, NB=${NB}"

sudo docker run --rm \
    --gpus all \
    --privileged \
    --ipc=host \
    --ulimit memlock=-1:-1 \
    --ulimit stack=67108864:67108864 \
    --net=host \
    -v "${HPL_WORK_DIR}:/run-data" \
    -w /workspace \
    -e NVIDIA_VISIBLE_DEVICES=all \
    -e HPL_USE_NVSHMEM=1 \
    -e HPL_P2P_AS_BCAST=1 \
    -e HPL_NVSHMEM_SWAP=1 \
    -e HPL_FCT_COMM_POLICY=0 \
    -e HPL_ALLOC_HUGEPAGES=1 \
    -e HPL_CHUNK_SIZE_NBS=64 \
    -e HPL_CTA_PER_FCT=32 \
    -e HPL_DIST_TRSM_FLAG=1 \
    -e HPL_CUSOLVER_MP_TESTS=0 \
    -e WARMUP_END_PROG=5 \
    "${NGC_IMAGE}" \
    mpirun --allow-run-as-root \
        -np ${NUM_GPUS} \
        --bind-to none \
        -x NVIDIA_VISIBLE_DEVICES \
        -x HPL_USE_NVSHMEM \
        -x HPL_P2P_AS_BCAST \
        -x HPL_NVSHMEM_SWAP \
        -x HPL_FCT_COMM_POLICY \
        -x HPL_ALLOC_HUGEPAGES \
        -x HPL_CHUNK_SIZE_NBS \
        -x HPL_CTA_PER_FCT \
        -x HPL_DIST_TRSM_FLAG \
        -x HPL_CUSOLVER_MP_TESTS \
        -x WARMUP_END_PROG \
        /workspace/hpl.sh \
            --dat /run-data/HPL.dat \
            --cpu-affinity "${CPU_AFF}" \
            --mem-affinity "${MEM_AFF}" \
            --no-multinode

echo "==> HPL-NVIDIA complete. Results in ${HPL_WORK_DIR}/"
