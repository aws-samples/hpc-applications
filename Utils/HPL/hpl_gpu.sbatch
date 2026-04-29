#!/bin/bash
#SBATCH --job-name=hpl-gpu
#SBATCH --partition=p5en
#SBATCH --nodes=1
#SBATCH --exclusive
#SBATCH --gpus-per-node=8
#SBATCH --ntasks-per-node=8
#SBATCH --output=/fsx/HPL-Run/gpu/hpl-gpu-%j.out

#############################################################
# GPU HPL via NVIDIA NGC container (Pyxis/Enroot)
#
# Runs HPL-NVIDIA and optionally HPL-MxP on GPU instances
# using Slurm's Pyxis plugin for container execution.
#
# Usage:
#   sbatch hpl_gpu.sbatch                          # p5en default
#   sbatch -p p5 hpl_gpu.sbatch                    # p5 (H100)
#   sbatch -p p4d --gpus-per-node=8 hpl_gpu.sbatch # p4d (A100)
#   sbatch -N 2 hpl_gpu.sbatch                     # multi-node
#   HPL_RUN_MXP=1 sbatch hpl_gpu.sbatch            # also run MxP
#   HPL_NB=768 sbatch hpl_gpu.sbatch               # custom NB
#############################################################

############################################################
# Defaults
############################################################
: "${HPL_NB:=1024}"
: "${HPL_MEM_FRACTION:=0.85}"
: "${HPL_RUN_MXP:=0}"
: "${HPL_MXP_NB:=2048}"
: "${HPL_MXP_SLOPPY:=1}"
: "${NGC_TAG:=25.02}"

NGC_IMAGE="nvcr.io#nvidia/hpc-benchmarks:${NGC_TAG}"

############################################################
# Detect hardware
############################################################
NUM_GPUS_PER_NODE=$(nvidia-smi -L | wc -l)
NUM_NODES=${SLURM_JOB_NUM_NODES}
TOTAL_GPUS=$((NUM_GPUS_PER_NODE * NUM_NODES))
GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1 | xargs)
GPU_MEM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1 | xargs)
NUM_CORES=$(nproc)
CORES_PER_GPU=$((NUM_CORES / NUM_GPUS_PER_NODE))

# Instance type via IMDSv2
INSTANCE_TYPE=$(TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600") && curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type)

echo "============================================"
echo "HPL GPU | Job ${SLURM_JOB_ID}"
echo "Instance: ${INSTANCE_TYPE} x ${NUM_NODES}"
echo "GPUs:     ${TOTAL_GPUS}x ${GPU_NAME} (${GPU_MEM_MB} MiB)"
echo "Cores:    ${NUM_CORES}/node (${CORES_PER_GPU}/GPU)"
echo "============================================"

############################################################
# GPU optimization
############################################################
case "$INSTANCE_TYPE" in
    p3*|p3dn*)    sudo nvidia-smi -ac 877,1530 ;;
    p4d*)         sudo nvidia-smi -ac 1215,1410 ;;
    p4de*)        sudo nvidia-smi -ac 1593,1410 ;;
    p5.*)         sudo nvidia-smi -ac 2619,1980 ;;
    p5e*|p5en*)   sudo nvidia-smi -ac 3201,1980 ;;
    p6-b200*)     sudo nvidia-smi -ac 3996,1965 ;;
    p6-b300*)     sudo nvidia-smi -ac 3996,2032 ;;
esac
sudo nvidia-persistenced 2>/dev/null || true

# Hugepages
sudo sysctl -w vm.nr_hugepages=40000 > /dev/null 2>&1 || true
echo madvise | sudo tee /sys/kernel/mm/transparent_hugepage/enabled > /dev/null 2>&1 || true

############################################################
# Build affinity strings
############################################################
CPU_AFF=""
MEM_AFF=""
GPU_AFF=""
for gpu in $(seq 0 $((NUM_GPUS_PER_NODE - 1))); do
    start=$((gpu * CORES_PER_GPU))
    end=$((start + CORES_PER_GPU - 1))
    if [ "$gpu" -lt $((NUM_GPUS_PER_NODE / 2)) ]; then numa=0; else numa=1; fi
    CPU_AFF="${CPU_AFF:+${CPU_AFF}:}${start}-${end}"
    MEM_AFF="${MEM_AFF:+${MEM_AFF}:}${numa}"
    GPU_AFF="${GPU_AFF:+${GPU_AFF}:}${gpu}"
done

############################################################
# Memory fraction — smaller GPUs need lower fraction
############################################################
if [ "$GPU_MEM_MB" -lt 50000 ]; then
    HPL_MEM_FRACTION=0.70
elif [ "$GPU_MEM_MB" -lt 100000 ]; then
    HPL_MEM_FRACTION=0.78
fi

############################################################
# Working directory
############################################################
WORK_DIR="/fsx/HPL-Run/gpu/${SLURM_JOB_ID}-${NUM_NODES}x${INSTANCE_TYPE}-$(date '+%d-%m-%Y-%H-%M')"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

############################################################
# HPL FP64
############################################################
NB=${HPL_NB}
N=$(python3 -c "import math; print(int(math.sqrt(${HPL_MEM_FRACTION} * ${TOTAL_GPUS} * ${GPU_MEM_MB} * 1024 * 1024 / 8) / ${NB}) * ${NB})")

# Process grid: P x Q = TOTAL_GPUS, P=1 for single-node, auto for multi-node
if [ "$NUM_NODES" -eq 1 ]; then
    P=1; Q=${TOTAL_GPUS}
else
    P=$(python3 -c "import math; sq=int(math.sqrt(${TOTAL_GPUS})); p=max(i for i in range(1,sq+1) if ${TOTAL_GPUS}%i==0); print(p)")
    Q=$((TOTAL_GPUS / P))
fi

echo ""
echo "=== HPL FP64: N=${N} NB=${NB} P=${P} Q=${Q} ==="

cat > HPL.dat <<EOF
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

srun -n 1 --ntasks-per-node=1 \
    --container-image="${NGC_IMAGE}" \
    --container-mounts="${WORK_DIR}:/run-data" \
    --container-workdir=/workspace \
    --container-env=HPL_USE_NVSHMEM=1,HPL_P2P_AS_BCAST=1,HPL_NVSHMEM_SWAP=1,HPL_FCT_COMM_POLICY=0,HPL_ALLOC_HUGEPAGES=1,HPL_CHUNK_SIZE_NBS=64,HPL_CTA_PER_FCT=32,HPL_DIST_TRSM_FLAG=1,HPL_CUSOLVER_MP_TESTS=0,WARMUP_END_PROG=5 \
    --gpus-per-node=${NUM_GPUS_PER_NODE} \
    bash -c "mpirun --allow-run-as-root -np ${TOTAL_GPUS} --bind-to none \
        -x HPL_USE_NVSHMEM -x HPL_P2P_AS_BCAST -x HPL_NVSHMEM_SWAP \
        -x HPL_FCT_COMM_POLICY -x HPL_ALLOC_HUGEPAGES -x HPL_CHUNK_SIZE_NBS \
        -x HPL_CTA_PER_FCT -x HPL_DIST_TRSM_FLAG -x HPL_CUSOLVER_MP_TESTS \
        -x WARMUP_END_PROG \
        /workspace/hpl.sh --dat /run-data/HPL.dat \
            --cpu-affinity '${CPU_AFF}' --mem-affinity '${MEM_AFF}' \
            $([ "$NUM_NODES" -eq 1 ] && echo '--no-multinode')" \
    2>&1 | tee hpl-fp64.log

############################################################
# HPL-MxP (optional)
############################################################
if [ "${HPL_RUN_MXP}" = "1" ]; then
    NB_MXP=${HPL_MXP_NB}
    N_MXP=$(python3 -c "import math; print(int(math.sqrt(${HPL_MEM_FRACTION} * ${TOTAL_GPUS} * ${GPU_MEM_MB} * 1024 * 1024 / 8) / ${NB_MXP}) * ${NB_MXP})")

    echo ""
    echo "=== HPL-MxP: N=${N_MXP} NB=${NB_MXP} P=${P} Q=${Q} sloppy=${HPL_MXP_SLOPPY} ==="

    srun -n 1 --ntasks-per-node=1 \
        --container-image="${NGC_IMAGE}" \
        --container-mounts="${WORK_DIR}:/run-data" \
        --container-workdir=/workspace \
        --gpus-per-node=${NUM_GPUS_PER_NODE} \
        bash -c "mpirun --allow-run-as-root -np ${TOTAL_GPUS} --bind-to none \
            /workspace/hpl-mxp.sh \
                --gpu-affinity '${GPU_AFF}' \
                --cpu-affinity '${CPU_AFF}' --mem-affinity '${MEM_AFF}' \
                --n ${N_MXP} --nb ${NB_MXP} \
                --nprow ${P} --npcol ${Q} --nporder row \
                --sloppy-type ${HPL_MXP_SLOPPY}" \
        2>&1 | tee hpl-mxp.log
fi

echo ""
echo "=== DONE | Results in ${WORK_DIR} ==="
