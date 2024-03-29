#!/bin/bash
#SBATCH --exclusive
#SBATCH -t 24:00:00
#SBATCH --nodes=2
#SBATCH --ntasks=384
#SBATCH --constraint=hpc7a.96xlarge
#SBATCH --partition=hpc7a


######################## EFA settings ######################## 
export I_MPI_OFI_LIBRARY_INTERNAL=0
module load intelmpi
export I_MPI_DEBUG=5
export I_MPI_FABRICS=shm:ofi
export I_MPI_OFI_PROVIDER=efa
export I_MPI_MULTIRAIL=1
module load libfabric-aws
export INTELMPI_ROOT="$(dirname $(dirname $(which mpirun)))"
######################## EFA settings ######################## 

SOLVER_PATH="${1:-"/fsx/ls-dyna_mpp_s_R10_2_0_x64_centos65_ifort160_avx2_intelmpi-2018/ls-dyna_mpp_s_R10_2_0_x64_centos65_ifort160_avx2_intelmpi-2018"}"
INPUT_FILE="${2:-"/fsx/MY_LS-DYNA_EXAMPLE/MY_INPUT_FILE.k"}"
# translate INPUT_FILE variable into an absolute path
INPUT_FILE="$(readlink -f ${INPUT_FILE})"
basedir="${BASE_DIR:-"/fsx"}"

export LSTC_LICENSE="${LSTC_LICENSE:-network}"
# you need to export LSTC_LICENSE_SERVER set to your license servers hostname, FQDN or IP address
# the default here will not work
export LSTC_LICENSE_SERVER="${LSTC_LICENSE_SERVER:-"www.xxx.yyy.zzz"}"
export LSTC_MEMORY=auto

TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
workdir="$(readlink -m "${basedir}/${SLURM_JOB_NAME%.*}")/$(basename "${input_file%.*}")/Run/${SLURM_JOB_ID}-${SLURM_JOB_NUM_NODES}x$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type)-${SLURM_NPROCS}-$(date "+%d-%m-%Y-%H-%M")"

echo "Execution directory is: ${workdir}"
mkdir -p "${workdir}"
# create a softlink in ${workdir} that points to the input file
ln -s ${INPUT_FILE} ${workdir}
cd "${workdir}"

# copy sbatch script to ${workdir}
cp ${0} .


HOSTFILE="${SLURM_JOBID}.hostfile"
echo "building the MPI hostfile: ${HOSTFILE}"
scontrol show nodes ${SLURM_NODELIST} | grep NodeHostName= | awk '{print $2}' | sed 's/NodeHostName=//' > ${HOSTFILE}


## USE INTERNAL NVME DISK ONLY IF IT EXISTS, OTHERWISE USE THE SHARED DIR (FSx)
SCRATCH_BASE=$(mount | grep ephemeral | awk '{print $3}')
if [[ $? != 0 ]]; then
    echo "Finding scratch failed."
    exit 1
elif [[ "${SCRATCH_BASE}" ]]; then
    export SCRATCH_DIR="${SCRATCH_BASE}/scratch-${SLURM_JOB_ID}"
    mkdir -p "${SCRATCH_DIR}"
    export TMPDIR="${SCRATCH_DIR}"
else
    export SCRATCH_DIR="${workdir}/scratch-${SLURM_JOB_ID}"
    mkdir -p "${SCRATCH_DIR}"
    export TMPDIR="${SCRATCH_DIR}"
fi

# Create the pfile
cat > pfile << EOF
ge
{
 nobeamout
 nodump
 nofull
 lstc_reduce
}
 dir
{
local ${SCRATCH_DIR}
}
EOF


echo "Drop caches on all nodes"
mpirun -np ${SLURM_JOB_NUM_NODES} -ppn 1 /bin/bash -c "sync && echo 3 | sudo tee /proc/sys/vm/drop_caches"

echo "Enabling Transparent Huge Pages (THP)"
mpirun -np ${SLURM_JOB_NUM_NODES} -ppn 1 /bin/bash -c "echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled"

echo "Running: mpirun -hostfile ${HOSTFILE} -np ${SLURM_NPROCS} -bootstrap ssh -genvall ${SOLVER_PATH} i=${INPUT_FILE}"
mpirun -hostfile ${HOSTFILE} -np ${SLURM_NPROCS} -bootstrap ssh -genvall ${SOLVER_PATH} i=${INPUT_FILE} | tee output.${SLURM_JOBID}.out
