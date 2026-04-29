#!/bin/bash
#SBATCH --exclusive
#SBATCH --nodes=2
#SBATCH --ntasks=384
#SBATCH --constraint=hpc8a.96xlarge
#SBATCH --partition=hpc8a

# ---------------------------------------------------------------------------
# Ansys Fluent journal runner (x86, Intel MPI + EFA)
#
# Uses the built-in "-peth.efa" interconnect variant (available from
# v222 / 2022 R2 onwards; documented in v261 / 2026 R1). See the big
# comment block in Fluent-Benchmark.sbatch for what -peth.efa does and
# why we set SCHEDULER_TIGHT_COUPLING=1.
# ---------------------------------------------------------------------------

# Tell Intel MPI to use the system libfabric (loaded via libfabric-aws
# below) instead of its own bundled one. Must be exported BEFORE
# `module load intelmpi` so mpivars.sh sees it.
export I_MPI_OFI_LIBRARY_INTERNAL=0

module load intelmpi
module load libfabric-aws

# 300 Gbps EFA instances (hpc7a / hpc8a) — remove on 100 Gbps instances.
export I_MPI_MULTIRAIL=1
# Required when ranks-per-node exceeds 128 (e.g. 192 on hpc7a / hpc8a).
export FI_EFA_SHM_AV_SIZE=${SLURM_NTASKS_PER_NODE:-192}
# Let Intel MPI's Slurm integration handle process launch natively on
# Fluent v222 .. v242 (no-op on v251+).
export SCHEDULER_TIGHT_COUPLING=1

fluentversion=${1:-"v252"}
journal_file=${2:-"/fsx/MY_FLUENT_EXAMPLE/MY_JOURNAL_FILE.jou"}
dataset_cas=${3:-"/fsx/MY_FLUENT_EXAMPLE/MY_CAS_FILE.cas.gz"}
dataset_dat=${4:-"/fsx/MY_FLUENT_EXAMPLE/MY_DAT_FILE.dat.gz"}
basedir=${BASE_DIR:-"/fsx"}
ansys_root=${ANSYS_ROOT:-"/fsx"}
fluent_mode=${FLUENT_MODE:-"3ddp"}

export ANSYSLMD_LICENSE_FILE=${ANSYSLMD_LICENSE_FILE:-"1055@XXX.YYY.ZZZ.XYZ"}

APP_BIN_PATH="${ansys_root}/ansys_inc/${fluentversion}/fluent/bin/fluent"
export FLUENT_ARCH=lnamd64

TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
workdir="$(readlink -m "${basedir}/${SLURM_JOB_NAME%.*}")/$(basename "${journal_file%.*}")/Run/${SLURM_JOB_ID}-${SLURM_JOB_NUM_NODES}x$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type)-${SLURM_NPROCS}-$(date "+%d-%m-%Y-%H-%M")"

echo "Execution directory is: ${workdir}"
mkdir -p "${workdir}" && cd "${workdir}"

echo "Building the MPI hostfile"
scontrol show nodes $SLURM_NODELIST | grep NodeHostName= | awk '{print $2}' | sed 's/NodeHostName=//' >hostfile

cp $0 .
ln -s "${journal_file}" .
ln -s "${dataset_cas}" .
ln -s "${dataset_dat}" .

echo "Drop caches on all nodes"
mpirun -np $SLURM_JOB_NUM_NODES -ppn 1 /bin/bash -c "sync && echo 3 | sudo tee /proc/sys/vm/drop_caches"

echo "Enabling Transparent Huge Pages (THP)"
mpirun -np $SLURM_JOB_NUM_NODES -ppn 1 /bin/bash -c "echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled"

echo "Fluent version: ${fluentversion}"
echo "Run Fluent: ${APP_BIN_PATH} ${fluent_mode} -g -t${SLURM_NPROCS} -cnf=hostfile -peth.efa -platform=intel -ssh -mpi=intel -i $(basename ${journal_file})"
"${APP_BIN_PATH}" ${fluent_mode} -g -t${SLURM_NPROCS} -cnf=hostfile -peth.efa -platform=intel -ssh -mpi=intel -i $(basename ${journal_file}) | tee output.$SLURM_JOBID.out
