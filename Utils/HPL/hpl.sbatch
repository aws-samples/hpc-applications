#!/bin/bash
#SBATCH --job-name=hpl
#SBATCH --constraint=hpc8a.96xlarge
#SBATCH --partition=hpc8a
#SBATCH --nodes=2
#SBATCH --ntasks=384
#SBATCH --exclusive
#SBATCH --output=hpl-%j.out

#############################################################
# Parametric HPL launcher for hpc8a.96xlarge
#
# All parameters can be overridden via environment variables:
#
#   HPL_MPI=openmpi|openmpi5|intelmpi  (default: openmpi)
#   HPL_NB=384                         (default: 384)
#   HPL_MEM_FRACTION=0.78              (default: 0.78)
#   HPL_N=400000                       (override auto-calc)
#   HPL_P=12                           (override auto-calc)
#   HPL_Q=32                           (override auto-calc)
#   HPL_BCAST=1                        (default: 1 = 1ringM)
#   HPL_DEPTH=0                        (default: 0)
#   HPL_PFACT=2                        (default: 2 = Right)
#   HPL_RFACT=1                        (default: 1 = Crout)
#   HPL_NBMIN=4                        (default: 4)
#   HPL_SWAP=2                         (default: 2 = mix)
#
# Examples:
#   sbatch hpl.sbatch
#   HPL_MPI=intelmpi sbatch -N 4 -n 768 hpl.sbatch
#   HPL_NB=256 HPL_MEM_FRACTION=0.80 sbatch hpl.sbatch
#   HPL_P=12 HPL_Q=32 sbatch hpl.sbatch
#############################################################

############################################################
# Defaults
############################################################
: "${HPL_MPI:=openmpi}"
: "${HPL_NB:=384}"
: "${HPL_MEM_FRACTION:=0.78}"
: "${HPL_BCAST:=1}"
: "${HPL_DEPTH:=0}"
: "${HPL_PFACT:=2}"
: "${HPL_RFACT:=1}"
: "${HPL_NBMIN:=4}"
: "${HPL_SWAP:=2}"

############################################################
# MPI setup + EFA settings
# Intel MPI: exports must come before module loads so that
# libfabric-aws picks up I_MPI_OFI_LIBRARY_INTERNAL=0
############################################################
case "${HPL_MPI}" in
    openmpi)
        module load openmpi
        module load libfabric-aws
        HPL_BIN="/fsx/HPL-OpenMPI/bin/Linux_AMD_OpenMPI/xhpl"
        ;;
    openmpi5)
        module load openmpi5/5.0.8amzn1
        module load libfabric-aws
        HPL_BIN="/fsx/HPL-OpenMPI5/bin/Linux_AMD_OpenMPI5/xhpl"
        ;;
    intelmpi)
        export I_MPI_OFI_LIBRARY_INTERNAL=0
        module load intelmpi
        module load libfabric-aws
        export I_MPI_DEBUG=5
        export I_MPI_FABRICS=shm:ofi
        export I_MPI_OFI_PROVIDER=efa
        export I_MPI_MULTIRAIL=1
        export I_MPI_PIN=1
        export I_MPI_PIN_DOMAIN=core
        export I_MPI_PIN_ORDER=compact
        HPL_BIN="/fsx/HPL-IntelMPI/bin/Linux_AMD_IntelMPI/xhpl"
        ;;
    *)
        echo "ERROR: Unknown HPL_MPI=${HPL_MPI}. Use openmpi, openmpi5, or intelmpi."
        exit 1
        ;;
esac

############################################################
# Runtime libraries
############################################################
AOCC_DIR="/fsx/aocc/aocc-compiler-5.1.0"
AOCL_DIR="/fsx/aocl/5.1.0"
export LD_LIBRARY_PATH="${AOCC_DIR}/lib:${AOCL_DIR}/lib:${LD_LIBRARY_PATH}"

export BLIS_ARCH_TYPE=zen5
export BLIS_NUM_THREADS=1
export OMP_NUM_THREADS=1

############################################################
# System tuning
############################################################
sudo sysctl -w vm.nr_hugepages=40000 2>/dev/null || true
echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
echo always | sudo tee /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true

############################################################
# Compute parameters
############################################################
MEM_PER_NODE_GB=768
NB=${HPL_NB}
TOTAL_RANKS=${SLURM_NPROCS}
CORES_PER_NODE=$(((SLURM_NPROCS / SLURM_JOB_NUM_NODES) + (SLURM_NPROCS % SLURM_JOB_NUM_NODES > 0)))

# N
if [ -n "${HPL_N}" ]; then
    N=${HPL_N}
else
    N=$(awk -v nodes="$SLURM_JOB_NUM_NODES" -v mem_gb="$MEM_PER_NODE_GB" \
           -v nb="$NB" -v frac="$HPL_MEM_FRACTION" \
        'BEGIN { n=int(sqrt(frac*nodes*mem_gb*1024*1024*1024/8)/nb)*nb; print n }')
fi

# P x Q
if [ -n "${HPL_P}" ] && [ -n "${HPL_Q}" ]; then
    P=${HPL_P}
    Q=${HPL_Q}
else
    P=$(awk -v ranks="$TOTAL_RANKS" \
        'BEGIN { sq=int(sqrt(ranks)); p=1; for(i=sq;i>=1;i--) if(ranks%i==0){p=i;break}; print p }')
    Q=$((TOTAL_RANKS / P))
fi

############################################################
# Working directory on shared filesystem
############################################################
instanceType=$(TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600") && curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type)
WORK_DIR="/fsx/HPL-Run/${SLURM_JOB_NAME%.*}/${SLURM_JOB_ID}-${SLURM_JOB_NUM_NODES}x${instanceType}-${SLURM_NPROCS}-$(date '+%d-%m-%Y-%H-%M')"
mkdir -p "$WORK_DIR"
cp "$HPL_BIN" "$WORK_DIR/"
cd "$WORK_DIR"

############################################################
# Generate HPL.dat
############################################################
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
${HPL_PFACT}            PFACTs (0=left, 1=Crout, 2=Right)
1            # of recursive stopping criteria
${HPL_NBMIN}            NBMINs (>= 1)
1            # of panels in recursion
2            NDIVs
1            # of recursive panel fact.
${HPL_RFACT}            RFACTs (0=left, 1=Crout, 2=Right)
1            # of broadcast
${HPL_BCAST}            BCASTs (0=1rg,1=1rM,2=2rg,3=2rM,4=Lng,5=LnM)
1            # of lookahead depth
${HPL_DEPTH}            DEPTHs (>=0)
${HPL_SWAP}            SWAP (0=bin-exch,1=long,2=mix)
64           swapping threshold
0            L1 in (0=transposed,1=no-transposed) form
0            U  in (0=transposed,1=no-transposed) form
1            Equilibration (0=no,1=yes)
8            memory alignment in double (> 0)
EOF

############################################################
# Run
############################################################
echo "==> HPL | MPI=${HPL_MPI} | ${SLURM_JOB_NUM_NODES} x ${instanceType}"
echo "    N=${N} NB=${NB} P=${P} Q=${Q} ranks=${TOTAL_RANKS}"
echo "    BCAST=${HPL_BCAST} DEPTH=${HPL_DEPTH} PFACT=${HPL_PFACT} RFACT=${HPL_RFACT}"
echo "    WORK_DIR=${WORK_DIR}"

case "${HPL_MPI}" in
    openmpi|openmpi5)
        mpirun -np ${TOTAL_RANKS} \
            -npernode ${CORES_PER_NODE} \
            --map-by core \
            --bind-to core \
            -x LD_LIBRARY_PATH \
            -x BLIS_ARCH_TYPE \
            -x BLIS_NUM_THREADS \
            -x OMP_NUM_THREADS \
            ./xhpl
        ;;
    intelmpi)
        mpirun -np ${TOTAL_RANKS} -ppn ${CORES_PER_NODE} ./xhpl
        ;;
esac
