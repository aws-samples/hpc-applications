#!/bin/bash
# SIMULIA PowerFLOW on AWS (x86, Intel MPI + EFA).
# One Slurm job owns the nodes and runs exaqsub in the foreground on them,
# so exaqsub does not submit a second (nested) Slurm job.
#
# Submit from the case directory:
#   PF_VERSION=<version> PF_CASE=my_case.cdi DSLS_POWERFLOW_LICENSE=<server>:<port> \
#       sbatch --nodes=2 /path/to/PowerFlow.sbatch
#   MODE=all SP_PER_NODE=144 ... sbatch --nodes=4 /path/to/PowerFlow.sbatch
#SBATCH --exclusive
#SBATCH --nodes=1
#SBATCH --partition=hpc8a
#SBATCH --constraint=hpc8a.96xlarge
#SBATCH --job-name=powerflow

set -u

# ---------------------------------------------------------------------------
# Case and sizing
# ---------------------------------------------------------------------------
PF_ROOT="${PF_ROOT:-/fsx/powerflow}"       # PowerFLOW installs: ${PF_ROOT}/<version>
PF_VERSION="${PF_VERSION:?set PF_VERSION to the directory of the install under PF_ROOT}"
PF_CASE="${PF_CASE:?set PF_CASE to the .cdi file}"
MODE="${MODE:-simulate}"                   # simulate | discretize | all (discretize + simulate)
# The node's physical cores, from lscpu: nproc follows OMP_NUM_THREADS and counts
# SMT threads.
CORES="$(LC_ALL=C lscpu -p=CORE,SOCKET 2>/dev/null | awk '!/^#/ && !seen[$0]++ { n++ } END { print n + 0 }')"
[ "${CORES}" -gt 0 ] || { echo "ERROR: lscpu shows no cores on this node" >&2; exit 1; }
# SP ranks per node. The default, one per physical core but one, leaves the CP a
# core of its own on the first node (191 SPs on hpc8a.96xlarge and hpc7a.96xlarge).
# Every node runs the same number of SPs, so one core stays idle on the others. The
# default is not yet benchmarked against the other counts. On hpc8a.96xlarge and
# hpc7a.96xlarge (24 CCDs of 8 cores), 24, 48, 72, 96, 120, 144 and 168 give every
# CCD the same number of SPs, and the script pins them with the matching list (see
# Utils/flexible-cores). With 192, the CP shares a core with an SP. Any other count
# runs on Intel MPI's own placement, with a WARNING.
SP_PER_NODE="${SP_PER_NODE:-$(( CORES - 1 ))}"
DISC_NPROCS="${DISC_NPROCS:-8}"            # discretizer processes

: "${DSLS_POWERFLOW_LICENSE:?set DSLS_POWERFLOW_LICENSE to <server>:<port>[,<server>:<port>...]}"
export DSLS_POWERFLOW_LICENSE

NNODES=${SLURM_JOB_NUM_NODES}
# Whole numbers only: no sign and no leading zero, which $(( )) would read as octal.
pf_count() { ( LC_ALL=C; [[ "$1" =~ ^[1-9][0-9]{0,5}$ ]] ) && [ "$1" -le "$2" ]; }
pf_count "${SP_PER_NODE}" "${CORES}" || {
    echo "ERROR: SP_PER_NODE=${SP_PER_NODE}: use a whole number from 1 to ${CORES}, this node's physical cores" >&2
    exit 1; }
pf_count "${DISC_NPROCS}" "$(( NNODES * CORES ))" || {
    echo "ERROR: DISC_NPROCS=${DISC_NPROCS}: use a whole number from 1 to $(( NNODES * CORES )), the job's cores" >&2
    exit 1; }
for v in PIN_EXPLICIT USE_BUNDLED_IMPI; do
    case "${!v-}" in ''|0|1) ;; *) echo "ERROR: ${v}=${!v}: use 0 or 1" >&2; exit 1 ;; esac
done
SIM_NPROCS=$(( NNODES * SP_PER_NODE ))

# ---------------------------------------------------------------------------
# PowerFLOW
# ---------------------------------------------------------------------------
export EXA_DIST="${PF_ROOT}/${PF_VERSION}"
export PATH="${EXA_DIST}/bin:${PATH}"
export LD_LIBRARY_PATH="${EXA_DIST}/dist/x86_linux/lib:${EXA_DIST}/dist/x86_linux/lib64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
EXAQSUB="${EXA_DIST}/bin/exaqsub"
[ -x "${EXAQSUB}" ] || { echo "ERROR: ${EXAQSUB} not found" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Intel MPI + EFA
# ---------------------------------------------------------------------------
source /etc/profile.d/modules.sh
# I_MPI_OFI_LIBRARY_INTERNAL=0 exported before intelmpi loads, and libfabric-aws
# loaded after it, ask Intel MPI for the EFA installer's libfabric instead of its own
# copy. Check which one PowerFLOW's ranks load: with I_MPI_DEBUG=5 the start of
# simulator.log names the libfabric version and provider.
export I_MPI_OFI_LIBRARY_INTERNAL=0
module load intelmpi
module load libfabric-aws
# Run with the Intel MPI loaded above instead of the one bundled with PowerFLOW.
# It must be exported, or exaqsub never sees it. Set USE_BUNDLED_IMPI=1 to keep
# the bundled one.
if [ "${USE_BUNDLED_IMPI:-0}" != "1" ]; then
    export EXA_ALT_IMPI_ROOT="${I_MPI_ROOT}"
fi

export I_MPI_FABRICS=shm:ofi
export I_MPI_OFI_PROVIDER=efa
export FI_EFA_FORK_SAFE=1
export FI_MR_CACHE_MONITOR=memhooks
export FI_EFA_SHM_AV_SIZE=256
if [ "$(lspci | grep -c -i efa)" -ge 2 ]; then
    export I_MPI_MULTIRAIL=1
fi
export I_MPI_DEBUG="${I_MPI_DEBUG:-5}"     # prints the provider and the pinning map

# One rank per core. I_MPI_PIN_DOMAIN=numa would let each rank float over a whole
# NUMA domain. A core list set in the submitting shell is dropped: the script sets
# its own, or none.
export I_MPI_PIN=1
unset I_MPI_PIN_DOMAIN I_MPI_PIN_ORDER I_MPI_PIN_PROCESSOR_LIST

# Explicit core list (Utils/flexible-cores) for 24 to 168 SPs per node on a 192-core
# node: the same number of SPs on every CCD. Intel MPI's own placement can load the
# CCDs unevenly when fewer than 192 ranks run on a node. The list follows the
# flexible-cores rule: with k = SP_PER_NODE/24 ranks per CCD, every (8/k)-th core
# when k divides 8, else each CCD's first k cores.
#
# The CP: the list adds core 191, which the flexible-cores list leaves free on the
# last CCD, because the first node also runs the CP. With one core more than
# SP_PER_NODE in the list, every process gets a core of its own on every node, and
# every CCD holds k SPs on every node when the CP is one of the last k ranks on its
# node. The "CPU pinning" table that I_MPI_DEBUG=5 prints at the start of
# simulator.log shows each rank's core but not which rank is the CP: during the run,
# `ps -eo pid,psr,args` on the first node shows each process's core and command line.
#
# Set PIN_EXPLICIT=0 to leave the placement to Intel MPI.
pf_pin_list() {
    local sp=$1 g=8 nccd=24 k list="" ccd i free
    k=$(( sp / nccd ))
    for (( ccd = 0; ccd < nccd; ccd++ )); do
        for (( i = 0; i < k; i++ )); do
            if (( g % k == 0 )); then
                list+="$(( ccd * g + i * (g / k) )),"
            else
                list+="$(( ccd * g + i )),"
            fi
        done
    done
    list=${list%,}
    # A core of the last CCD that the flexible-cores list leaves free.
    for (( free = nccd * g - 1; free >= (nccd - 1) * g; free-- )); do
        case ",${list}," in *",${free},"*) ;; *) break ;; esac
    done
    echo "${free},${list}"
}
if [ "${PIN_EXPLICIT:-1}" = "1" ]; then
    case "${CORES}:${SP_PER_NODE}" in
        192:24|192:48|192:72|192:96|192:120|192:144|192:168)
            I_MPI_PIN_PROCESSOR_LIST="$(pf_pin_list "${SP_PER_NODE}")"
            export I_MPI_PIN_PROCESSOR_LIST ;;
        "${CORES}:$(( CORES - 1 ))")
            echo "Note: ${SP_PER_NODE} SPs per node leave the CP a core of its own;" \
                 "Intel MPI places the ranks, one per core." ;;
        192:192)
            echo "Note: 192 SPs per node leave no free core; the CP shares one with an SP." ;;
        *)
            echo "WARNING: no flexible-cores list for ${CORES} cores and ${SP_PER_NODE} SPs per node;" \
                 "Intel MPI places the ranks. Use 24, 48, 72, 96, 120, 144 or 168 on a 192-core node." >&2 ;;
    esac
fi

# exaqsub starts the ranks over ssh (-mpirsh ssh): drop Hydra settings meant for
# the Slurm launcher, which conflict with it. Needs passwordless ssh between nodes.
unset HYDRA_BOOTSTRAP HYDRA_LAUNCHER_EXTRA_ARGS I_MPI_HYDRA_BOOTSTRAP_EXEC_EXTRA_ARGS
export I_MPI_HYDRA_BOOTSTRAP=ssh

# ---------------------------------------------------------------------------
# Run directory and scratch space
# ---------------------------------------------------------------------------
RUN_DIR="${SLURM_SUBMIT_DIR}"
cd "${RUN_DIR}" || exit 1
# PowerFLOW temporary files on the shared file system, not on the root EBS volume.
export EXA_TMPDIR="${RUN_DIR}/exa_tmp_${SLURM_JOB_ID}"
mkdir -p "${EXA_TMPDIR}"

# ---------------------------------------------------------------------------
# Hostfile for exaqsub: the CP on the first node, SP_PER_NODE SPs on every node.
# ---------------------------------------------------------------------------
HOSTFILE="hostfile.${SLURM_JOB_ID}"
mapfile -t HOSTS < <(scontrol show hostnames "${SLURM_JOB_NODELIST}")
{
    echo "cp ${HOSTS[0]}"
    for h in "${HOSTS[@]}"; do echo "${SP_PER_NODE} ${h}"; done
} > "${HOSTFILE}"

echo "PowerFLOW ${PF_VERSION}  case: ${PF_CASE}  mode: ${MODE}"
echo "Nodes: ${NNODES}  SP per node: ${SP_PER_NODE}  SP total: ${SIM_NPROCS}"
echo "Hostfile:"; cat "${HOSTFILE}"
echo "I_MPI_PIN_PROCESSOR_LIST=${I_MPI_PIN_PROCESSOR_LIST:-<Intel MPI default>}"

# ---------------------------------------------------------------------------
# Run in the foreground inside this allocation
# ---------------------------------------------------------------------------
COMMON_OPTS=(-nolock -foreground -impi -mpirsh ssh -mpifile "${HOSTFILE}")

case "${MODE}" in
    discretize)
        STEP_OPTS=(-discretize -disc_log discretizer.log -discnprocs "${DISC_NPROCS}") ;;
    simulate)
        STEP_OPTS=(-simulate -sim_log simulator.log --nprocs "${SIM_NPROCS}") ;;
    all)
        STEP_OPTS=(-discretize -disc_log discretizer.log -discnprocs "${DISC_NPROCS}"
                   -simulate -sim_log simulator.log --nprocs "${SIM_NPROCS}") ;;
    *)  echo "ERROR: unknown MODE=${MODE}" >&2; exit 1 ;;
esac

echo "Exec: ${EXAQSUB} ${COMMON_OPTS[*]} ${STEP_OPTS[*]} ${PF_CASE}"
start=$(date +%s)
"${EXAQSUB}" "${COMMON_OPTS[@]}" "${STEP_OPTS[@]}" "${PF_CASE}"
rc=$?
echo "exaqsub exit code ${rc}, elapsed $(( $(date +%s) - start )) s"

rm -rf "${EXA_TMPDIR}"
exit ${rc}
