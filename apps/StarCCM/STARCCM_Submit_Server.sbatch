#!/bin/bash
#SBATCH -t 50:00:00
#SBATCH --ntasks=384
#SBATCH --nodes=2
#SBATCH --constraint=hpc7a.96xlarge
#SBATCH --partition=hpc7a
#SBATCH --exclusive

export I_MPI_OFI_LIBRARY_INTERNAL=0
module load intelmpi
export FI_MR_CACHE_MONITOR=memhooks
export I_MPI_FABRICS=shm:ofi
export I_MPI_OFI_PROVIDER=efa
export I_MPI_MULTIRAIL=1
module load libfabric-aws
export FI_EFA_FORK_SAFE=1
export I_MPI_DEBUG=5
export INTEL_MPI_PATH="${I_MPI_ROOT}"

. '/etc/parallelcluster/cfnconfig'

APP_VERSION=${1:-"18.06.007"}
starccm_sim=${2:-"/fsx/MY_STARCCM_EXAMPLE/myStarccmModel.sim"}
basedir=${BASE_DIR:-"/fsx"}
starccm_bin=${STARCCM_BIN:-"${basedir}/Siemens/${APP_VERSION}/STAR-CCM+${APP_VERSION}/star/bin/starccm+"}
starccm_sim_file=$(basename ${starccm_sim})

#example for POD license only, customize as needed
license_arn=${LICENSE_ARN:-"arn:aws:secretsmanager:XXXXXXXX"}
PODLIC="$(aws secretsmanager get-secret-value --secret-id ${license_arn} --query SecretString --output text --region ${cfn_region} )"
LICENSEOPTS="-power -podkey ${PODLIC} -licpath 1999@flex.cd-adapco.com"

TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
workdir="$(readlink -m "${basedir}/${SLURM_JOB_NAME%.*}")/${starccm_sim_file%.*}/${SLURM_JOB_ID}-${SLURM_JOB_NUM_NODES}x$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type)-${SLURM_NPROCS}-$(date "+%d-%m-%Y-%H-%M")"

echo "Execution directory is: ${workdir}"
mkdir -p "${workdir}" && cd "${workdir}"

cd "${workdir}"
cp $0 .
ln -s "${starccm_sim}" .

scontrol show nodes $SLURM_NODELIST | grep NodeHostName= | awk '{print $2}' | sed 's/NodeHostName=//' >hostfile

mpirun -np $SLURM_JOB_NUM_NODES -ppn 1 /bin/bash -c "sync && echo 3 | sudo tee /proc/sys/vm/drop_caches"
mpirun -np $SLURM_JOB_NUM_NODES -ppn 1 /bin/bash -c "echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled"

"${starccm_bin}" \
    -batch \
    -pio \
    -np ${SLURM_NTASKS} \
    -bs slurm \
    ${LICENSEOPTS} \
    -mpi intel \
    -xsystemlibfabric -ldlibpath ${LD_LIBRARY_PATH} \
    -fabric OFI \
    -batch-report \
    ${starccm_sim_file} > "${starccm_sim_file%.*}.log" 2>&1