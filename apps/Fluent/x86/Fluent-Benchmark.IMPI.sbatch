#!/bin/bash
#SBATCH --exclusive
#SBATCH --nodes=2
#SBATCH --ntasks=384
#SBATCH --constraint=hpc8a.96xlarge
#SBATCH --partition=hpc8a
#SBATCH --time=12:00:00

# ---------------------------------------------------------------------------
# Ansys Fluent benchmark launcher (x86, IntelMPI + EFA)
#
# This script uses Fluent's built-in "-peth.efa" interconnect variant to
# enable EFA, which is available from Ansys Fluent v222 (2022 R2) onwards
# and is officially documented starting with v261 (2026 R1). Fluent's own
# mpirun wrapper (mpirun.fl) then injects the correct IntelMPI + libfabric
# tuning for AWS EFA:
#   I_MPI_OFI_PROVIDER=efa
#   I_MPI_FABRICS=shm:ofi
#   FI_EFA_RECVWIN_SIZE=65536
#   FI_MR_CACHE_MONITOR=memhooks
#
# Three settings are still needed from the submit script:
#   * I_MPI_OFI_LIBRARY_INTERNAL=0  (tell IntelMPI to use the system
#                                    libfabric-aws, not its bundled one.
#                                    Must be exported BEFORE module load
#                                    intelmpi so mpivars.sh picks it up.)
#   * I_MPI_MULTIRAIL=1             (multi-NIC EFA instances only, e.g.
#                                    hpc7a / hpc8a; omit on single-NIC
#                                    instances)
#   * FI_EFA_SHM_AV_SIZE=<ncores>   (required when using >128 ranks per node)
#
# Plus SCHEDULER_TIGHT_COUPLING=1, which tells Fluent v222 .. v242's mpirun
# wrapper to NOT force --rsh=ssh under Slurm. v251+ already does this by
# default, but setting it explicitly keeps one codepath across all versions.
# ---------------------------------------------------------------------------

# Tell IntelMPI to use the system libfabric (loaded via libfabric-aws
# below) instead of its own bundled one. This must be exported BEFORE
# `module load intelmpi` so that mpivars.sh / the shell wrappers see it.
export I_MPI_OFI_LIBRARY_INTERNAL=0

module load intelmpi
module load libfabric-aws

# Multi-NIC EFA instances (e.g. hpc7a / hpc8a) — omit on single-NIC instances.
export I_MPI_MULTIRAIL=1
# Required when ranks-per-node exceeds 128 (e.g. 192 on hpc7a / hpc8a).
export FI_EFA_SHM_AV_SIZE=${SLURM_NTASKS_PER_NODE:-192}
# Let IntelMPI's Slurm integration handle process launch natively on
# older Fluent versions (no-op on v251+).
export SCHEDULER_TIGHT_COUPLING=1

fluentversion=${1:-"v252"}
benchmark_uri=${2:-"s3://YOUR_BUCKET/f1_racecar_140m.tar"}
basedir=${BASE_DIR:-"/fsx"}
ansys_root=${ANSYS_ROOT:-"/fsx"}
export ANSYSLMD_LICENSE_FILE=${ANSYSLMD_LICENSE_FILE:-"1055@XXX.YYY.ZZZ.XYZ"}

benchmark_file=$(basename ${benchmark_uri})
APP_BIN_PATH="${ansys_root}/ansys_inc/${fluentversion}/fluent/bin/fluentbench.pl"
export FLUENT_ARCH=lnamd64

TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
workdir="$(readlink -m "${basedir}/${SLURM_JOB_NAME%.*}")/${benchmark_file%.*}/${SLURM_JOB_ID}-${SLURM_JOB_NUM_NODES}x$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type)-${SLURM_NPROCS}-$(date "+%d-%m-%Y-%H-%M")"

echo "Execution directory is: ${workdir}"
mkdir -p "${workdir}" && cd "${workdir}"

echo "Building the MPI hostfile"
scontrol show nodes $SLURM_NODELIST | grep NodeHostName= | awk '{print $2}' | sed 's/NodeHostName=//' >hostfile

cp $0 .
aws s3 cp --quiet "${benchmark_uri}" .
tar xf "${benchmark_file}"
ln -s bench/fluent/v6/${benchmark_file%.*}/cas_dat/* .

echo "Drop caches on all nodes"
mpirun -np $SLURM_JOB_NUM_NODES -ppn 1 /bin/bash -c "sync && echo 3 | sudo tee /proc/sys/vm/drop_caches"

echo "Enabling Transparent Huge Pages (THP)"
mpirun -np $SLURM_JOB_NUM_NODES -ppn 1 /bin/bash -c "echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled"

echo "Fluent version: ${fluentversion}"
echo "Run Fluent Benchmark: ${APP_BIN_PATH} ${benchmark_file%.*} -t${SLURM_NPROCS} -cnf=hostfile -part=4 -peth.efa -platform=intel -nosyslog -noloadchk -ssh -mpi=intel -norm"
"${APP_BIN_PATH}" ${benchmark_file%.*} -t${SLURM_NPROCS} -cnf=hostfile -part=4 -peth.efa -platform=intel -nosyslog -noloadchk -ssh -mpi=intel -norm | tee output.$SLURM_JOBID.out
