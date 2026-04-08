#!/bin/bash
#SBATCH --job-name=hpl-bcsweep
#SBATCH --constraint=hpc8a.96xlarge
#SBATCH --partition=hpc8a
#SBATCH --nodes=10
#SBATCH --ntasks=1920
#SBATCH --exclusive
#SBATCH --output=hpl-bcsweep-%j.out

# BCAST/DEPTH sweep at 10 nodes to find optimal comm params at scale
# Tests: BCAST={1ringM,2ring,2ringM,Long} x DEPTH={0,1,2} = 12 combos

module load openmpi
module load libfabric-aws

AOCC_DIR="/fsx/aocc/aocc-compiler-5.1.0"
AOCL_DIR="/fsx/aocl/5.1.0"
export LD_LIBRARY_PATH="${AOCC_DIR}/lib:${AOCL_DIR}/lib:${LD_LIBRARY_PATH}"

export BLIS_ARCH_TYPE=zen5
export BLIS_NUM_THREADS=1
export OMP_NUM_THREADS=1

sudo sysctl -w vm.nr_hugepages=40000 2>/dev/null || true
echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
echo always | sudo tee /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true

MEM_PER_NODE_GB=768
NB=384
TOTAL_RANKS=${SLURM_NPROCS}
CORES_PER_NODE=$(((SLURM_NPROCS / SLURM_JOB_NUM_NODES) + (SLURM_NPROCS % SLURM_JOB_NUM_NODES > 0)))

N=$(awk -v nodes="$SLURM_JOB_NUM_NODES" -v mem_gb="$MEM_PER_NODE_GB" -v nb="$NB" \
    'BEGIN { n=int(sqrt(0.78*nodes*mem_gb*1024*1024*1024/8)/nb)*nb; print n }')

P=$(awk -v ranks="$TOTAL_RANKS" 'BEGIN { sq=int(sqrt(ranks)); p=1; for(i=sq;i>=1;i--) if(ranks%i==0){p=i;break}; print p }')
Q=$((TOTAL_RANKS / P))

HPL_BIN="/fsx/HPL-OpenMPI/bin/Linux_AMD_OpenMPI/xhpl"
instanceType=$(TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600") && curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type)
WORK_DIR="/fsx/HPL-Run/${SLURM_JOB_NAME%.*}/${SLURM_JOB_ID}-${SLURM_JOB_NUM_NODES}x${instanceType}-${SLURM_NPROCS}-$(date '+%d-%m-%Y-%H-%M')"
mkdir -p "$WORK_DIR"
cp "$HPL_BIN" "$WORK_DIR/"
cd "$WORK_DIR"

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
4            # of broadcast
1 2 3 4      BCASTs (0=1rg,1=1rM,2=2rg,3=2rM,4=Lng,5=LnM)
3            # of lookahead depth
0 1 2        DEPTHs (>=0)
2            SWAP (0=bin-exch,1=long,2=mix)
64           swapping threshold
0            L1 in (0=transposed,1=no-transposed) form
0            U  in (0=transposed,1=no-transposed) form
1            Equilibration (0=no,1=yes)
8            memory alignment in double (> 0)
EOF

echo "==> BCAST/DEPTH sweep | ${SLURM_JOB_NUM_NODES} x ${instanceType} | N=${N} NB=${NB} P=${P} Q=${Q} | ranks=${TOTAL_RANKS}"

mpirun -np ${TOTAL_RANKS} \
    -npernode ${CORES_PER_NODE} \
    --map-by core \
    --bind-to core \
    -x LD_LIBRARY_PATH \
    -x BLIS_ARCH_TYPE \
    -x BLIS_NUM_THREADS \
    -x OMP_NUM_THREADS \
    ./xhpl
