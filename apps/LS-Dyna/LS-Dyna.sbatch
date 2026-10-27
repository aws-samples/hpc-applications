#!/bin/bash
#SBATCH --exclusive
#SBATCH -t 24:00:00
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=192
#SBATCH --constraint=hpc8a.96xlarge
#SBATCH --partition=hpc8a
# =============================================================================
# LS-DYNA MPP with Intel MPI 2021 over EFA, one rank per core
# =============================================================================
# Runs one LS-DYNA MPP solve with the cluster's Intel MPI 2021 (module intelmpi)
# over EFA. Checked with these MPP single-precision builds, all of them linked
# against Intel MPI's libmpi.so.12:
#   R13.1    LSTC   ls-dyna_mpp_s_R13_1_0_x64_centos78_ifort190_avx2_intelmpi-2018
#   R14.1.1  Ansys  2025 R2: ansys_inc/v252/ansys/bin/linx64/lsdyna_sp_mpp.e
#   R15.0.2  LSTC   ls-dyna_mpp_s_R15_0_2_x64_centos79_aocc400_avx2_intelmpi-2018
#   R16.1.1  Ansys  2026 R1: ansys_inc/v261/ansys/bin/linx64/lsdyna_sp_mpp.e
#   R16.2.1  LSTC   ls-dyna_mpp_s_R16_2_1_x64_centos79_aocc420_avx512_intelmpi-2018
#   R17.0.1  LSTC   ls-dyna_mpp_s_R17_0_1_x64_rhel810_aocc500_avx512_intelmpi-2021
#
# Usage:
#   sbatch [sbatch options] LS-Dyna.sbatch <solver executable> <input deck> [pfile]
# The shape is sbatch's own: --nodes, --ntasks-per-node, --constraint and
# --partition on the command line override the defaults above, for example
#   sbatch --nodes=2 --ntasks-per-node=144 LS-Dyna.sbatch \
#       /fsx/ls-dyna_mpp_s_R13_1_0_x64_centos78_ifort190_avx2_intelmpi-2018/ls-dyna_mpp_s_R13_1_0_x64_centos78_ifort190_avx2_intelmpi-2018 \
#       /fsx/models/car2car/Caravan-V03c-2400k-main-shell16-120ms.k /fsx/models/car2car/Caravan-V03c_2400k.pfile
#
# The run directory links every file of the deck's directory (so the deck finds
# its *INCLUDE files) and gets its own pfile: the given one without its directory
# section, plus "dir { global <run dir> local <run dir>/local }".
#
# Environment (sbatch passes the submitting shell's environment to the job):
#   ANSYSLMD_LICENSE_FILE  <port>@<server> of an Ansys licence server (LSTC_LICENSE=ansys),
#                          for Ansys's builds and LSTC's alike
#   LSTC_LICENSE_SERVER    an LSTC network licence server (LSTC_LICENSE=network)
#                          One of the two is required; LSTC_LICENSE overrides the choice.
#   MEMORY, MEMORY2        memory= and memory2= for the solver, in words (e.g. 900m, 90m)
#   PFILE_LSTC_REDUCE=1    add lstc_reduce to the pfile's general section (reproducible
#                          energies; the deck and pfile as shipped otherwise)
#   LSTC_RSH               the remote shell LS-DYNA's MPP ranks signal the root rank with
#                          (default "ssh -x -o BatchMode=yes -o ConnectTimeout=10"; ""
#                          keeps the build's own, rsh for R13.1)
#   ENDTIME                endtime=: end the run earlier than the deck's termination time
#                          (a check; such a run is not recorded)
#   BASE_DIR               where the run directory goes (default /fsx)
#   LOCAL_DIR              the pfile's local directory (default <run dir>/local; created on
#                          every node)
#   BENCHMARK_CASE         the case name a recorded run gets (default: the deck's file name
#                          without its extension; the CCSA models' main deck is combine.key)
#   DYNAMODB_RECORDER, SOURCE   the benchmark recorder (see "Contribute your results")
# =============================================================================
set -uo pipefail

USAGE="usage: sbatch [sbatch options] LS-Dyna.sbatch <solver executable> <input deck> [pfile]"
[ -n "${1:-}" ] && [ -n "${2:-}" ] || { echo "${USAGE}" >&2; exit 1; }
SOLVER="$(readlink -f "$1")"
SHIPPED_PFILE=""
[ -z "${3:-}" ] || SHIPPED_PFILE="$(readlink -f "$3")"
[ -x "${SOLVER}" ] || { echo "ERROR: no executable solver at $1" >&2; exit 1; }
[ -f "$2" ] || { echo "ERROR: no input deck at $2" >&2; exit 1; }
[ -z "${SHIPPED_PFILE}" ] || [ -f "${SHIPPED_PFILE}" ] || { echo "ERROR: no pfile at $3" >&2; exit 1; }
# The deck's directory as given, not where a link in it points: a copy of a model's
# directory holds links to the shipped files and its own edited copies, and its
# files are the ones the run must see.
INPUT_DIR="$(cd "$(dirname "$2")" && pwd)"
INPUT_FILE="${INPUT_DIR}/$(basename "$2")"

# The helpers sit next to this script (lib/). Slurm runs a copy of the script from
# its spool directory, so they are also looked for from the submit directory.
_self_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" 2>/dev/null && pwd)"
_lib=""
for _c in "${LSDYNA_LIB:-}" "${_self_dir}/lib/lsdyna-run.sh" \
          "${SLURM_SUBMIT_DIR:-.}/lib/lsdyna-run.sh" \
          "${SLURM_SUBMIT_DIR:-.}/apps/LS-Dyna/lib/lsdyna-run.sh"; do
    if [ -n "${_c}" ] && [ -f "${_c}" ]; then _lib="${_c}"; break; fi
done
if [ -z "${_lib}" ]; then
    echo "ERROR: cannot find lib/lsdyna-run.sh; submit from apps/LS-Dyna (or set LSDYNA_LIB)" >&2
    exit 1
fi
# shellcheck source=lib/lsdyna-run.sh
. "${_lib}"

# --- The shape: ranks per node, nodes, instance type ----------------------------------
NODES="${SLURM_JOB_NUM_NODES:?not inside a Slurm job}"
if ! RPN="$(lsdyna_ranks_per_node)"; then
    echo "ERROR: the nodes hold different rank counts (SLURM_TASKS_PER_NODE=${SLURM_TASKS_PER_NODE:-});" \
         "submit with --ntasks-per-node" >&2
    exit 1
fi
NP=$(( NODES * RPN ))
TOKEN="$(curl -fs --connect-timeout 2 --max-time 5 -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 300" 2>/dev/null)"
INSTANCE_TYPE="$(curl -fs --connect-timeout 2 --max-time 5 -H "X-aws-ec2-metadata-token: ${TOKEN}" \
    http://169.254.169.254/latest/meta-data/instance-type 2>/dev/null)"
CORES="$(lscpu -p=CORE,SOCKET 2>/dev/null | grep -v '^#' | sort -u | wc -l)"
[ "${CORES:-0}" -gt 0 ] || CORES="$(nproc)"

# --- Intel MPI 2021 over EFA ----------------------------------------------------------
command -v module >/dev/null 2>&1 || source /etc/profile.d/modules.sh
export I_MPI_OFI_LIBRARY_INTERNAL=0
module load intelmpi
export I_MPI_FABRICS=shm:ofi
export I_MPI_OFI_PROVIDER=efa
export I_MPI_MULTIRAIL=1
export FI_EFA_FORK_SAFE=1
module load libfabric-aws
export I_MPI_DEBUG=5   # prints each rank's core: check the placement in the job log
# One rank per core: the flexible-cores list on an under-populated hpc8a/hpc7a.96xlarge.
lsdyna_pinning "${INSTANCE_TYPE}" "${RPN}" "${CORES}" || exit 1

# --- Licence, memory, the MPP remote shell ----------------------------------------------
lsdyna_licence || exit 1
export LSTC_MEMORY=auto
# LS-DYNA's MPP ranks signal the root rank through a remote shell, for example to stop
# the run early (the bg_switch file: "<shell> <root host> kill -INT <pid>"). R13.1's
# default is rsh, which ParallelCluster nodes do not have; Intel MPI passes LSTC_RSH to
# every rank.
LSTC_RSH="${LSTC_RSH-ssh -x -o BatchMode=yes -o ConnectTimeout=10}"
if [ -n "${LSTC_RSH}" ]; then export LSTC_RSH; else unset LSTC_RSH; fi
# LSTC's builds load the licensing client (ansyscl) and their own libraries from
# their directory. Ansys's builds find theirs in their install tree.
case "$(basename "${SOLVER}")" in
    ls-dyna_*)
        _solver_dir="$(dirname "${SOLVER}")"
        export LD_LIBRARY_PATH="${_solver_dir}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" ;;
esac

# --- The run directory ------------------------------------------------------------------
lsdyna_inputs_clean "${INPUT_DIR}" || exit 1
basedir="${BASE_DIR:-/fsx}"
workdir="$(readlink -m "${basedir}/${SLURM_JOB_NAME%.*}")/$(basename "${INPUT_FILE%.*}")/Run/${SLURM_JOB_ID}-${NODES}x${INSTANCE_TYPE:-unknown}-${NP}-$(date "+%d-%m-%Y-%H-%M")"
echo "Execution directory is: ${workdir}"
mkdir -p "${workdir}" || exit 1
cd "${workdir}" || exit 1
cp "$0" . 2>/dev/null
# Every input file of the deck's directory, linked (the deck's *INCLUDE files among them)
for f in "${INPUT_DIR}"/*; do
    [ -f "${f}" ] && ln -sf "${f}" .
done
LOCAL_DIR="${LOCAL_DIR:-${workdir}/local}"
srun --ntasks="${NODES}" --ntasks-per-node=1 mkdir -p "${LOCAL_DIR}" || exit 1
rm -f run.pfile
lsdyna_write_pfile "${SHIPPED_PFILE}" run.pfile "${workdir}" "${LOCAL_DIR}" "${PFILE_LSTC_REDUCE:-0}" || exit 1

# --- Node preparation: page cache dropped and THP always, on every node -----------------
srun --ntasks="${NODES}" --ntasks-per-node=1 /bin/bash -c \
    "sync && echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null && echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled >/dev/null" \
    || echo "WARNING: could not drop the page cache or set THP on every node" >&2

CMD=(mpirun -np "${NP}" -ppn "${RPN}" "${SOLVER}" "i=$(basename "${INPUT_FILE}")" "p=run.pfile")
[ -z "${MEMORY:-}" ] || CMD+=("memory=${MEMORY}")
[ -z "${MEMORY2:-}" ] || CMD+=("memory2=${MEMORY2}")
[ -z "${ENDTIME:-}" ] || CMD+=("endtime=${ENDTIME}")
echo "Instance type: ${INSTANCE_TYPE:-unknown}; ${NODES} node(s) x ${RPN} ranks; pinning: ${LSDYNA_PINNING}"
echo "Licence: LSTC_LICENSE=${LSTC_LICENSE}; LSTC_RSH=${LSTC_RSH:-unset (the default of the build)}"
echo "pfile: $(tr '\n' ' ' < run.pfile)"
echo "Running: ${CMD[*]}"
"${CMD[@]}" 2>&1 | tee "output.${SLURM_JOB_ID}.out"
_mpi_rc="${PIPESTATUS[0]}"

# --- Did the solve complete? LS-DYNA's own termination line decides, not the exit code -----
TERMINATION="$(lsdyna_termination d3hsp "output.${SLURM_JOB_ID}.out")"
ELAPSED="$(lsdyna_elapsed d3hsp)"
REVISION="$(lsdyna_revision d3hsp)"
_rec_rc="${_mpi_rc}"
if [ "${TERMINATION}" != normal ] && [ "${_rec_rc}" -eq 0 ]; then _rec_rc=1; fi
echo "LS-DYNA ${REVISION:-(no revision in d3hsp)}: ${TERMINATION} termination, elapsed ${ELAPSED:-?} s on ${NP} ranks; mpirun exit ${_mpi_rc}"
if [ "${TERMINATION}" != normal ]; then
    echo "NOTE: no normal termination; each rank's own message file is in ${LOCAL_DIR} (mesNNNN)" >&2
fi

# ---------------------------------------------------------------------------
# Record this benchmark to the AI-Powered HPC dataset (best-effort, non-fatal).
# Only a solve that ended in LS-DYNA's normal termination, at the deck's own end
# time, is recorded, with LS-DYNA's own elapsed time and the banner's version; the
# job's exit status is preserved (a recorder problem never changes it). Point
# DYNAMODB_RECORDER at the script if it isn't found automatically; set
# SOURCE=<YourOrg> to tag your contributions.
# See apps/LS-Dyna/dynamodb/README.md and apps/BENCHMARK-RECORDERS.md.
# ---------------------------------------------------------------------------
_recorder="${DYNAMODB_RECORDER:-}"
for _c in "${_recorder}" \
          "${SLURM_SUBMIT_DIR:-.}/dynamodb/record-benchmark.sh" \
          "${SLURM_SUBMIT_DIR:-.}/../dynamodb/record-benchmark.sh" \
          "${SLURM_SUBMIT_DIR:-.}/apps/LS-Dyna/dynamodb/record-benchmark.sh"; do
    if [ -n "${_c}" ] && [ -x "${_c}" ]; then _recorder="${_c}"; break; fi
done
if [ "${TERMINATION}" != normal ]; then
    echo "NOTE: no normal termination; skipping benchmark recording." >&2
elif [ "${_rec_rc}" -ne 0 ]; then
    echo "NOTE: mpirun exited ${_mpi_rc}; skipping benchmark recording." >&2
elif [ -n "${ENDTIME:-}" ]; then
    echo "NOTE: ENDTIME=${ENDTIME} ends the run early; skipping benchmark recording." >&2
elif [ -n "${_recorder}" ] && [ -x "${_recorder}" ]; then
    LSDYNA_VERSION="${REVISION%%-*}" BENCHMARK_CASE="${BENCHMARK_CASE:-$(basename "${INPUT_FILE%.*}")}" \
    TIME_TO_SOLUTION="${ELAPSED}" NUM_CORES="${NP}" NUM_INSTANCES="${NODES}" CORES_PER_NODE="${RPN}" \
    RUN_DIR="${workdir}" "${_recorder}" \
        || echo "NOTE: benchmark recorder failed (non-fatal); the solve was unaffected." >&2
else
    echo "NOTE: benchmark recorder not found; set DYNAMODB_RECORDER=/path/to/record-benchmark.sh to record." >&2
fi
exit "${_rec_rc}"
