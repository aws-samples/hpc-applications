#!/bin/bash
#SBATCH --job-name=hpl-gpu
#SBATCH --partition=p5en
#SBATCH --nodes=1
#SBATCH --exclusive
#SBATCH --gpus-per-node=8
#SBATCH --ntasks-per-node=8
#SBATCH --output=/fsx/HPL-Run/gpu/hpl-gpu-%j.out
#SBATCH --container-mounts=/fsx:/fsx

#############################################################
# GPU HPL — single node, runs entirely inside the NGC container
#
# Usage:
#   sbatch --container-image='nvcr.io#nvidia/hpc-benchmarks:26.02.01' hpl_gpu_container.sbatch
#   sbatch --container-image='nvcr.io#nvidia/hpc-benchmarks:26.02.01' -p p5 hpl_gpu_container.sbatch
#   HPL_RUN_MXP=1 sbatch --container-image='nvcr.io#nvidia/hpc-benchmarks:26.02.01' hpl_gpu_container.sbatch
#
# For multi-node runs over EFA use hpl_gpu.sbatch, which launches
# one containerised rank per GPU on every node with srun.
#############################################################

: "${HPL_NB:=1024}"
: "${HPL_MEM_FRACTION:=0.85}"
: "${HPL_RUN_MXP:=0}"
: "${HPL_MXP_NB:=2048}"
: "${HPL_MXP_SLOPPY:=1}"

NUM_GPUS=$(nvidia-smi -L | wc -l)
GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1 | xargs)
GPU_MEM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1 | xargs)
NUM_CORES=$(nproc)
CORES_PER_GPU=$((NUM_CORES / NUM_GPUS))
NUM_NODES=${SLURM_JOB_NUM_NODES:-1}
if [ "$NUM_NODES" -gt 1 ]; then
    echo "ERROR: hpl_gpu_container.sbatch runs on a single node; use hpl_gpu.sbatch for multi-node runs." >&2
    exit 1
fi
TOTAL_GPUS=${NUM_GPUS}

echo "============================================"
echo "HPL GPU | Job ${SLURM_JOB_ID}"
echo "Nodes:    ${NUM_NODES}"
echo "GPUs:     ${TOTAL_GPUS}x ${GPU_NAME} (${GPU_MEM_MB} MiB)"
echo "Cores:    ${NUM_CORES}/node (${CORES_PER_GPU}/GPU)"
echo "============================================"

# Build affinity
CPU_AFF=""
MEM_AFF=""
for gpu in $(seq 0 $((NUM_GPUS - 1))); do
    start=$((gpu * CORES_PER_GPU))
    end=$((start + CORES_PER_GPU - 1))
    if [ "$gpu" -lt $((NUM_GPUS / 2)) ]; then numa=0; else numa=1; fi
    CPU_AFF="${CPU_AFF:+${CPU_AFF}:}${start}-${end}"
    MEM_AFF="${MEM_AFF:+${MEM_AFF}:}${numa}"
done
GPU_AFF=$(seq -s: 0 $((NUM_GPUS - 1)))

# Memory fraction
if [ "$GPU_MEM_MB" -lt 50000 ]; then HPL_MEM_FRACTION=0.70
elif [ "$GPU_MEM_MB" -lt 100000 ]; then HPL_MEM_FRACTION=0.78; fi

# Working directory
WORK_DIR="/fsx/HPL-Run/gpu/${SLURM_JOB_ID}"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

############################################################
# HPL FP64
############################################################
NB=${HPL_NB}
N=$(awk "BEGIN{n=int(sqrt(${HPL_MEM_FRACTION} * ${TOTAL_GPUS} * ${GPU_MEM_MB} * 1024 * 1024 / 8) / ${NB}) * ${NB}; print n}")

# Process grid: P=1, Q=GPUs (1D over NVSwitch)
P=1; Q=${TOTAL_GPUS}

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

export HPL_ALLOC_HUGEPAGES=1
export HPL_CHUNK_SIZE_NBS=64 HPL_CTA_PER_FCT=32
export HPL_DIST_TRSM_FLAG=1 HPL_CUSOLVER_MP_TESTS=0 WARMUP_END_PROG=5
export HPL_USE_NVSHMEM=1 HPL_P2P_AS_BCAST=1 HPL_NVSHMEM_SWAP=1
export HPL_FCT_COMM_POLICY=0

# Single node: mpirun inside the container
mpirun --allow-run-as-root -np ${TOTAL_GPUS} --bind-to none --oversubscribe \
    -x HPL_USE_NVSHMEM -x HPL_P2P_AS_BCAST -x HPL_NVSHMEM_SWAP \
    -x HPL_FCT_COMM_POLICY -x HPL_ALLOC_HUGEPAGES -x HPL_CHUNK_SIZE_NBS \
    -x HPL_CTA_PER_FCT -x HPL_DIST_TRSM_FLAG -x HPL_CUSOLVER_MP_TESTS \
    -x WARMUP_END_PROG \
    /workspace/hpl.sh --dat ${WORK_DIR}/HPL.dat \
        --cpu-affinity "${CPU_AFF}" --mem-affinity "${MEM_AFF}" \
        --no-multinode \
    2>&1 | tee hpl-fp64.log

############################################################
# HPL-MxP (optional)
############################################################
if [ "${HPL_RUN_MXP}" = "1" ]; then
    NB_MXP=${HPL_MXP_NB}
    N_MXP=$(awk "BEGIN{n=int(sqrt(${HPL_MEM_FRACTION} * ${TOTAL_GPUS} * ${GPU_MEM_MB} * 1024 * 1024 / 8) / ${NB_MXP}) * ${NB_MXP}; print n}")

    echo ""
    echo "=== HPL-MxP: N=${N_MXP} NB=${NB_MXP} sloppy=${HPL_MXP_SLOPPY} ==="

    mpirun --allow-run-as-root -np ${TOTAL_GPUS} --bind-to none --oversubscribe \
        /workspace/hpl-mxp.sh \
            --gpu-affinity "${GPU_AFF}" \
            --cpu-affinity "${CPU_AFF}" --mem-affinity "${MEM_AFF}" \
            --n ${N_MXP} --nb ${NB_MXP} \
            --nprow ${P} --npcol ${Q} --nporder row \
            --sloppy-type ${HPL_MXP_SLOPPY} \
        2>&1 | tee hpl-mxp.log
fi

echo ""
echo "=== DONE | Results in ${WORK_DIR} ==="
