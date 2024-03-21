#!/bin/bash
#SBATCH --exclusive
#SBATCH -t 99:00:00
#SBATCH --nodes=2
#SBATCH --ntasks=128
#SBATCH --constraint=hpc6id.32xlarge
#SBATCH --partition=hpc6id

input_file=${1:-"/fsx/abaqus/s4e/Model/s4e.inp"}
abaqus_version=${2:-"2022"}
basedir=${BASE_DIR:-"/fsx"}
abaqus_bin=${ABAQUS_BIN:-"${basedir}/SIMULIA/EstProducts/${abaqus_version}/linux_a64/code/bin/SMALauncher"}
mp_host_split=${MP_HOST_SPLIT:-""}
threads_mpi=${THREADS_MPI:-""}
verbose=${VERBOSE:-""}
dsls_license=${DSLS_LICENSE:-"/fsx/SIMULIA/EstProducts/2022/linux_a64/SMA/site/DSLicSrv.txt"}

module load intelmpi
export I_MPI_FABRICS=shm:ofi
export I_MPI_OFI_PROVIDER=efa
export I_MPI_MULTIRAIL=1
module load libfabric-aws

TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
workdir="$(readlink -m "${basedir}/${SLURM_JOB_NAME%.*}")/$(basename ${input_file%.*})/${SLURM_JOB_ID}-${SLURM_JOB_NUM_NODES}x$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type)-${SLURM_NPROCS}-$(date "+%d-%m-%Y-%H-%M")"

echo "Execution directory is: ${workdir}"
mkdir -p "${workdir}" && cd "${workdir}"

export cores_x_node=$(((SLURM_NPROCS / SLURM_JOB_NUM_NODES ) + ( SLURM_NPROCS % SLURM_JOB_NUM_NODES > 0 )))

SCRATCH_BASE=$(mount | grep ephemeral | awk '{print $3}')
if [[ $? != 0 ]]; then
    echo "Scratch failed."
    exit 1
elif [[ $SCRATCH_BASE ]]; then
    export SCRATCH_DIR="${SCRATCH_BASE}/scratch-$SLURM_JOB_ID"
    mkdir -p "${SCRATCH_DIR}"
    export TMPDIR="${SCRATCH_DIR}"
else
    export SCRATCH_DIR="${workdir}/scratch-$SLURM_JOB_ID"
    mkdir -p "${SCRATCH_DIR}"
    export TMPDIR="${SCRATCH_DIR}"
fi

cp $0 .
ln -s "${input_file}" .

echo "Drop caches on all nodes"
mpirun -np $SLURM_JOB_NUM_NODES -ppn 1 /bin/bash -c "sync && echo 3 | sudo tee /proc/sys/vm/drop_caches"

echo "Enabling Transparent Huge Pages (THP)"
mpirun -np $SLURM_JOB_NUM_NODES -ppn 1 /bin/bash -c "echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled"


    cat > abaqus_v6.env << EOF
# System-Wide ABAQUS Environment File
dsls_license_config="${dsls_license}"
mp_rsh_command='ssh -n -l %U %H %C'
mp_host_list=$(scontrol show nodes $SLURM_NODELIST | grep NodeHostName= | awk -v cores="$cores_x_node" -F" |=" 'BEGIN { printf "["; out="" } { out=out"[\x27"$7"\x27,"cores"]," } END { t=length(out); printf substr(out,0,t-1); print "]"; }')
EOF

[ -z "$mp_host_split" ] || echo "mp_host_split=$mp_host_split" >> abaqus_v6.env
[ -z "$threads_mpi" ] || echo "threads_per_mpi_process=$threads_mpi" >> abaqus_v6.env
[ -z "$verbose" ] || echo "verbose=$verbose" >> abaqus_v6.env
[ -z "$SCRATCH_DIR" ] || echo "scratch=\"${SCRATCH_DIR}\"" >> abaqus_v6.env

cat >> abaqus_v6.env << EOF
mp_mpi_implementation = IMPI
cpus=${SLURM_NPROCS}
mp_mpirun_path = {IMPI: "$(which mpirun)"}
mp_mpirun_options='-bootstrap ssh'
mp_mode = MPI
standard_parallel = ALL
EOF

"${abaqus_bin}" input=${benchmark_file} interactive -job ${benchmark_name} | tee ${benchmark_name}.log

rm -rf "${SCRATCH_DIR}"                                