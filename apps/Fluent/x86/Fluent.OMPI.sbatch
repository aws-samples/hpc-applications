#!/bin/bash
#SBATCH --exclusive
#SBATCH --nodes=2
#SBATCH --ntasks=384
#SBATCH --constraint=hpc8a.96xlarge
#SBATCH --partition=hpc8a

# ---------------------------------------------------------------------------
# Ansys Fluent journal runner (x86, OpenMPI + EFA)
#
# Uses Fluent's built-in "-peth.efa" interconnect variant. On the OpenMPI
# path, Fluent's mpirun.fl wrapper loads the libfabric-aws module and
# appends to mpirun:
#   --mca mtl ofi -x FI_MR_CACHE_MONITOR=memhooks -x FI_EFA_RECVWIN_SIZE=65536
# which is the right baseline for EFA.
#
# Which mpirun Fluent uses is controlled by OPENMPI_ROOT:
#   * OPENMPI_ROOT set    -> that system OpenMPI is used
#   * OPENMPI_ROOT unset  -> Fluent's own bundled OpenMPI is used
# Select via the OMPI_VARIANT env var:
#   * OMPI_VARIANT=ompi4     (default)  use module openmpi   (currently 4.1.7)
#   * OMPI_VARIANT=ompi5                use module openmpi5  (currently 5.0.9amzn1)
#                                       note: may hang at startup with Fluent
#                                             on some setups; use ompi4 if so
#   * OMPI_VARIANT=bundled              use the OpenMPI shipped inside Fluent
#                                       note: OpenMPI 4.0.5, fails at >=10 nodes
#                                             due to PMIX scalability limits
#
# Notes:
#   * Recommended for Fluent v242 and later. v222 / v231 have a bug in the
#     OpenMPI+EFA branch of their mpirun.fl that forces TCP BTL, so they
#     fall back to TCP (and crash at scale from port collisions).
#   * On AL2023 Fluent's fluent_mpi binary needs libnsl.so.2 which is not
#     shipped by the OS. For system OpenMPI variants we LD_PRELOAD
#     libnsl.so.2 from Fluent's own bundled OpenMPI directory so node
#     processes can resolve it without shadowing other system libs.
#   * On the OpenMPI path we load libfabric-aws ourselves so that the
#     system libfabric is used rather than anything bundled with Fluent.
#   * FI_EFA_SHM_AV_SIZE=<ncores-per-node> is required when ranks-per-node
#     exceeds 128 (so 192 ranks/node on hpc7a / hpc8a).
#
# Usage:
#   sbatch Fluent.OMPI.sbatch <version> <journal.jou> <case.cas.gz> <data.dat.gz>
# Example:
#   sbatch --export=ALL,OMPI_VARIANT=ompi4 Fluent.OMPI.sbatch v252 \
#       /fsx/my-case/run.jou /fsx/my-case/model.cas.gz /fsx/my-case/model.dat.gz
# ---------------------------------------------------------------------------

fluentversion=${1:-"v252"}
journal_file=${2:-"/fsx/MY_FLUENT_EXAMPLE/MY_JOURNAL_FILE.jou"}
dataset_cas=${3:-"/fsx/MY_FLUENT_EXAMPLE/MY_CAS_FILE.cas.gz"}
dataset_dat=${4:-"/fsx/MY_FLUENT_EXAMPLE/MY_DAT_FILE.dat.gz"}
ompi_variant=${OMPI_VARIANT:-"ompi4"}
basedir=${BASE_DIR:-"/fsx"}
ansys_root=${ANSYS_ROOT:-"/fsx"}
fluent_mode=${FLUENT_MODE:-"3ddp"}

export ANSYSLMD_LICENSE_FILE=${ANSYSLMD_LICENSE_FILE:-"1055@XXX.YYY.ZZZ.XYZ"}

# Load the system libfabric first so the module-loaded /opt/amazon/efa/lib64
# appears in LD_LIBRARY_PATH ahead of anything Fluent might inject later.
module load libfabric-aws

# Select the OpenMPI that Fluent will use.
case "${ompi_variant}" in
    ompi4)
        module load openmpi
        export OPENMPI_ROOT=/opt/amazon/openmpi
        ;;
    ompi5)
        module load openmpi5
        export OPENMPI_ROOT=/opt/amazon/openmpi5
        ;;
    bundled)
        unset OPENMPI_ROOT
        ;;
    *)
        echo "Unknown OMPI_VARIANT: ${ompi_variant} (expected: ompi4 | ompi5 | bundled)" >&2
        exit 1
        ;;
esac

# Fluent's node binary needs libnsl.so.2 which is not shipped on AL2023.
# Later Fluent versions (v251+) include a compatible copy under their bundled
# OpenMPI directory; use any such copy we can find. For the bundled variant
# Fluent's mpirun.fl already handles this via sys_prepend_ld_library_path
# so this is only needed when pointing at a system OpenMPI.
# IMPORTANT: we use LD_PRELOAD rather than prepending to LD_LIBRARY_PATH
# because the Fluent-bundled OpenMPI dir also contains libopen-pal.so.40 /
# libopen-rte.so.40 from OpenMPI 4.0.5 which would shadow the system
# OpenMPI's own libs and break mpirun argument parsing.
if [ "${ompi_variant}" != "bundled" ]; then
    fluent_libnsl=$(ls "${ansys_root}/ansys_inc/${fluentversion}/fluent/fluent"*/multiport/mpi/lnamd64/openmpi/lib/libnsl.so.2 2>/dev/null | head -1)
    if [ -z "${fluent_libnsl}" ]; then
        # Fall back to any other Fluent version's libnsl.so.2 (older Fluent
        # installs are not shipped with one on AL2023).
        fluent_libnsl=$(ls "${ansys_root}"/ansys_inc/v*/fluent/fluent*/multiport/mpi/lnamd64/openmpi/lib/libnsl.so.2 2>/dev/null | head -1)
    fi
    if [ -n "${fluent_libnsl}" ]; then
        export LD_PRELOAD="${fluent_libnsl}${LD_PRELOAD:+:}${LD_PRELOAD}"
    fi
fi

# Required when ranks-per-node exceeds 128 (e.g. 192 on hpc7a / hpc8a).
export FI_EFA_SHM_AV_SIZE=${SLURM_NTASKS_PER_NODE:-192}
# Kept for parity with the Intel MPI script (no effect on OpenMPI).
export SCHEDULER_TIGHT_COUPLING=1

# OpenMPI 5 (PRRTE) re-reads the mpirun --hostfile on every worker node;
# Fluent's mpirun.fl puts that file in $FL_TMPDIR/fluent-appfile.$USER.$$
# (default /tmp). Point it at FSx so all nodes can read the same file.
# Use a per-job subdirectory so concurrent jobs don't race on each other's
# stale appfiles. Harmless on OpenMPI 4 / bundled / Intel MPI.
export FL_TMPDIR="${basedir}/tmp/${SLURM_JOB_ID:-$$}"
mkdir -p "${FL_TMPDIR}"

# Work around a bug in Fluent v242 / v251 where mpirun.fl emits
# "-x FLUTE_UUID=$FLUTE_UUID" even when the variable is empty, which
# breaks OpenMPI's argument parsing (you see "unknown option --map-by"
# in the trace). Setting a non-empty value sidesteps the bug; v252+
# correctly gates this on FLUTE_UUID being non-empty.
export FLUTE_UUID=${FLUTE_UUID:-"${SLURM_JOB_ID:-$$}"}

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
srun --ntasks=$SLURM_JOB_NUM_NODES --ntasks-per-node=1 /bin/bash -c "sync && echo 3 | sudo tee /proc/sys/vm/drop_caches"

echo "Enabling Transparent Huge Pages (THP)"
srun --ntasks=$SLURM_JOB_NUM_NODES --ntasks-per-node=1 /bin/bash -c "echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled"

echo "Fluent version: ${fluentversion} | OMPI variant: ${ompi_variant} | OPENMPI_ROOT: ${OPENMPI_ROOT:-<Fluent-bundled>}"

# Build mpiopt value: DEBUG_MPIOPT (user-supplied) plus a forced
# " -x LD_PRELOAD " when we injected libnsl.so.2 via LD_PRELOAD for system
# OpenMPI so worker ranks inherit it.
mpiopt_value=""
if [ -n "${DEBUG_MPIOPT}" ]; then
    mpiopt_value="${DEBUG_MPIOPT}"
fi
if [ -n "${LD_PRELOAD}" ] && [ "${ompi_variant}" != "bundled" ]; then
    mpiopt_value="${mpiopt_value} -x LD_PRELOAD "
fi

# Assemble Fluent args as an array so -mpiopt="value" stays a single argv entry.
fluent_args=(${fluent_mode} -g -t${SLURM_NPROCS} -cnf=hostfile -peth.efa -platform=intel -ssh -mpi=openmpi -i "$(basename ${journal_file})")
if [ -n "${mpiopt_value}" ]; then
    fluent_args+=("-mpiopt=${mpiopt_value}")
fi

echo "Run Fluent: ${APP_BIN_PATH} ${fluent_args[*]}"
"${APP_BIN_PATH}" "${fluent_args[@]}" | tee output.$SLURM_JOBID.out
