#!/bin/bash
# SIMULIA PowerFLOW on AWS (x86, Intel MPI + EFA).
# One Slurm job owns the nodes and runs exaqsub in the foreground on them,
# so exaqsub does not submit a second (nested) Slurm job.
#
# Submit from the case directory:
#   PF_VERSION=6-2026-R2 PF_CASE=my_case.cdi DSLS_POWERFLOW_LICENSE=<port>@<server> \
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
PF_VERSION="${PF_VERSION:?set PF_VERSION, e.g. 6-2026-R2}"
PF_CASE="${PF_CASE:?set PF_CASE to the .cdi file}"
MODE="${MODE:-simulate}"                   # simulate | discretize | all (discretize + simulate)
# SP ranks per node. On hpc8a.96xlarge and hpc7a.96xlarge (24 CCDs of 8 cores)
# use 120, 144, 168 or 192 so every CCD gets the same number of ranks
# (see Utils/flexible-cores); the script pins them with the matching list.
# With 192, the CP shares a core with an SP.
SP_PER_NODE="${SP_PER_NODE:-$(nproc)}"
DISC_NPROCS="${DISC_NPROCS:-8}"            # discretizer processes

: "${DSLS_POWERFLOW_LICENSE:?set DSLS_POWERFLOW_LICENSE to <port>@<server>[,...]}"
export DSLS_POWERFLOW_LICENSE

NNODES=${SLURM_JOB_NUM_NODES}
SIM_NPROCS=$(( NNODES * SP_PER_NODE ))

# ---------------------------------------------------------------------------
# PowerFLOW
# ---------------------------------------------------------------------------
export EXA_DIST="${PF_ROOT}/${PF_VERSION}"
export PATH="${EXA_DIST}/bin:${PATH}"
export LD_LIBRARY_PATH="${EXA_DIST}/dist/x86_linux/lib:${EXA_DIST}/dist/x86_linux/lib64:${LD_LIBRARY_PATH:-}"
EXAQSUB="${EXA_DIST}/bin/exaqsub"
[ -x "${EXAQSUB}" ] || { echo "ERROR: ${EXAQSUB} not found" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Intel MPI + EFA
# ---------------------------------------------------------------------------
source /etc/profile.d/modules.sh
module load libfabric-aws
module load intelmpi
# Run with the Intel MPI loaded above instead of the one bundled with PowerFLOW.
# It must be exported, or exaqsub never sees it. Set USE_BUNDLED_IMPI=1 to keep
# the bundled one.
if [ "${USE_BUNDLED_IMPI:-0}" != "1" ]; then
    export EXA_ALT_IMPI_ROOT="${I_MPI_ROOT}"
fi

export I_MPI_OFI_LIBRARY_INTERNAL=0        # use the EFA installer's libfabric
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
# NUMA domain.
export I_MPI_PIN=1
unset I_MPI_PIN_DOMAIN I_MPI_PIN_ORDER

# Explicit core list (Utils/flexible-cores): the same number of SPs on every CCD.
# Intel MPI's own placement can load the CCDs unevenly when fewer than 192 ranks
# run on a node. The list follows the flexible-cores rule: with k = SP_PER_NODE/24
# ranks per CCD, every (8/k)-th core when k divides 8, else each CCD's first k cores.
#
# The CP: the first list entry is a free core of the last CCD. On the first node the
# CP (listed first in the hostfile) takes it. On the other nodes there is no CP, so
# the first SP takes it and the list's last core, on the same CCD, stays free: every
# CCD still holds k SPs on every node. Check the "CPU pinning" table that
# I_MPI_DEBUG=5 prints at the start of simulator.log.
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
    # A core of the last CCD that no SP uses, for the CP.
    for (( free = nccd * g - 1; free >= (nccd - 1) * g; free-- )); do
        case ",${list}," in *",${free},"*) ;; *) break ;; esac
    done
    echo "${free},${list}"
}
if [ "${PIN_EXPLICIT:-1}" = "1" ]; then
    case "$(nproc):${SP_PER_NODE}" in
        192:24|192:48|192:72|192:96|192:120|192:144|192:168)
            I_MPI_PIN_PROCESSOR_LIST="$(pf_pin_list "${SP_PER_NODE}")"
            export I_MPI_PIN_PROCESSOR_LIST ;;
        192:192)
            echo "Note: 192 SPs per node leave no free core; the CP shares one with an SP." ;;
        *)
            echo "WARNING: no flexible-cores list for $(nproc) cores and ${SP_PER_NODE} SPs per node;" \
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
