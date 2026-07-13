#!/bin/bash
#SBATCH --exclusive
#SBATCH --nodes=2
#SBATCH --ntasks=128
#SBATCH --constraint=hpc6id.32xlarge
#SBATCH --partition=hpc6id
#SBATCH --chdir=/fsx/slurm-out/mechanical


######################## EFA settings ######################## 
export I_MPI_OFI_LIBRARY_INTERNAL=0
module load intelmpi
export I_MPI_DEBUG=5
export I_MPI_FABRICS=shm:ofi
export I_MPI_OFI_PROVIDER=efa
export I_MPI_MULTIRAIL=1
#export FI_EFA_RECVWIN_SIZE=65536
export FI_EFA_FORK_SAFE=1
module load libfabric-aws
export INTELMPI_ROOT="$(dirname $(dirname $(which mpirun)))"
######################## EFA settings ######################## 

export ANSYSLMD_LICENSE_FILE=${ANSYSLMD_LICENSE_FILE:-"1055@172.31.89.151"}

mechanicalversion=${1:-"v251"}
input_file=${2:-"/fsx/.../your_file.dat"}
basedir=${BASE_DIR:-"/fsx"}

APP_BIN_PATH="${basedir}/ansys_inc/${mechanicalversion}/ansys/bin/mapdl"
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
workdir="$(readlink -m "${basedir}/${SLURM_JOB_NAME%.*}")/Run/${SLURM_JOB_ID}-${SLURM_JOB_NUM_NODES}x$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type)-${SLURM_NPROCS}-$(date "+%d-%m-%Y-%H-%M")"

mkdir -p "${workdir}" && cd "${workdir}"

export cores_x_node=$(((SLURM_NPROCS / SLURM_JOB_NUM_NODES ) + ( SLURM_NPROCS % SLURM_JOB_NUM_NODES > 0 )))

for i in $(scontrol show hostnames=$SLURM_JOB_NODELIST); do
  machines=$machines:$i:$cores_x_node
done
machines=${machines:1}

cp $0 .
ln -s "${input_file}" .

echo "Drop caches on all nodes"
mpirun -np $SLURM_JOB_NUM_NODES -ppn 1 /bin/bash -c "sync && echo 3 | sudo tee /proc/sys/vm/drop_caches"

echo "Enabling Transparent Huge Pages (THP)"
mpirun -np $SLURM_JOB_NUM_NODES -ppn 1 /bin/bash -c "echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled"

echo "Install missing lib"
mpirun -np $SLURM_JOB_NUM_NODES -ppn 1 /bin/bash -c "sudo yum -y install mesa-libGLU"

# Ansys Mechanical gets the total number of cores from hostlist not from -np
_rec_t0="$(date +%s)"
"${APP_BIN_PATH}" -b -dis -mpi intelmpi -ssh -machines $machines -i $(basename ${input_file}) -o output.log

# ---------------------------------------------------------------------------
# Record this benchmark to the AI-Powered HPC dataset (best-effort, non-fatal).
# The recorder self-collects host details from the environment; this launch
# script times the solve (wall clock) and passes it, so no arguments are
# needed. Only a SUCCESSFUL solve is recorded, and the job's exit status is
# preserved (a recorder problem never changes it). Point DYNAMODB_RECORDER at
# the script if it isn't found automatically; set SOURCE=<YourOrg> to tag your
# contributions. See apps/AnsysMechanical/dynamodb/README.md and apps/BENCHMARK-RECORDERS.md.
# ---------------------------------------------------------------------------
_rec_rc=$?
_rec_secs=$(( $(date +%s) - ${_rec_t0:-$(date +%s)} ))
[ "${_rec_secs}" -gt 0 ] 2>/dev/null || _rec_secs=""
_recorder="${DYNAMODB_RECORDER:-}"
for _c in "${_recorder}" \
          "${SLURM_SUBMIT_DIR:-.}/dynamodb/record-benchmark.sh" \
          "${SLURM_SUBMIT_DIR:-.}/../dynamodb/record-benchmark.sh" \
          "${SLURM_SUBMIT_DIR:-.}/apps/AnsysMechanical/dynamodb/record-benchmark.sh"; do
    if [ -n "${_c}" ] && [ -x "${_c}" ]; then _recorder="${_c}"; break; fi
done
if [ "${_rec_rc}" -eq 0 ] && [ -n "${_recorder}" ] && [ -x "${_recorder}" ]; then
    MECHANICAL_VERSION="${mechanicalversion}" BENCHMARK_CASE="$(basename "${input_file%.*}")" \
    TIME_TO_SOLUTION="${_rec_secs}" RUN_DIR="${workdir}" "${_recorder}" \
        || echo "NOTE: benchmark recorder failed (non-fatal); the solve was unaffected." >&2
elif [ "${_rec_rc}" -ne 0 ]; then
    echo "NOTE: solver exited ${_rec_rc}; skipping benchmark recording." >&2
else
    echo "NOTE: benchmark recorder not found; set DYNAMODB_RECORDER=/path/to/record-benchmark.sh to record." >&2
fi
exit ${_rec_rc}
