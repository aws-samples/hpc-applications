#!/bin/bash
#SBATCH --exclusive
#SBATCH --nodes=2
#SBATCH --ntasks=128
#SBATCH --constraint=hpc6id.32xlarge
#SBATCH --partition=hpc6id
#SBATCH --chdir=/fsx/slurm-out/mechanical

# ---------------------------------------------------------------------------
# Ansys Mechanical (MAPDL) launcher — distributed-memory parallel (DMP).
#
# Usage:
#   sbatch AnsysMechanical.sbatch [mechanical_version] [input_file]
#     mechanical_version  Ansys version dir under ${BASE_DIR}/ansys_inc (def v261)
#     input_file          MAPDL input deck (.dat). Any file it resumes (e.g. the
#                         matching <case>geom.db) must sit next to it.
#   Env knobs:
#     BASE_DIR          install/base root (default /fsx)
#     SCRATCH_MODE      auto | nvme | shared   (default auto)
#                       nvme/auto run the solve from node-local instance-store
#                       NVMe (/scratch, mounted by ParallelCluster) when present
#                       on ALL nodes - faster for out-of-core solves and keeps
#                       heavy scratch I/O off the shared filesystem.
#     ANSYS_COMPAT_DIR  dir with the legacy libs AL2023 lacks (see Readme.md);
#                       default ${BASE_DIR}/ansys_compat, used when it exists.
#     ANSYSLMD_LICENSE_FILE, SOURCE, DYNAMODB_RECORDER    see recorder section.
#
# IMPORTANT: submit as a regular user, NEVER root. The -ssh start method needs
# the user's inter-node SSH key (on ParallelCluster only the default user has
# one) and Intel MPI refuses to run as root outright.
# ---------------------------------------------------------------------------
if [ "$(id -u)" -eq 0 ]; then
    echo "ERROR: this job must not run as root (ssh remote launch + Intel MPI both fail)." >&2
    exit 1
fi

######################## EFA settings ########################
# `module` is undefined in non-login shells (cron/SSM/automation) - source it.
command -v module >/dev/null 2>&1 || source /etc/profile.d/modules.sh
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

mechanicalversion=${1:-"v261"}
input_file=${2:-"/fsx/.../your_file.dat"}
basedir=${BASE_DIR:-"/fsx"}
scratch_mode=${SCRATCH_MODE:-"auto"}

APP_BIN_PATH="${basedir}/ansys_inc/${mechanicalversion}/ansys/bin/mapdl"

# MAPDL needs a writable HOME (preferences + ~/.ssh for the remote launch).
if [ -z "${HOME:-}" ] || [ ! -w "${HOME}" ]; then
    export HOME="$(mktemp -d)"
    echo "NOTE: HOME was unset/unwritable; using ${HOME}"
fi

# Legacy X11/Motif libraries Amazon Linux 2023 does not ship (see Readme.md for
# the one-time setup). Only prepended when the directory exists.
ANSYS_COMPAT_DIR=${ANSYS_COMPAT_DIR:-"${basedir}/ansys_compat"}
if [ -d "${ANSYS_COMPAT_DIR}" ]; then
    export LD_LIBRARY_PATH="${ANSYS_COMPAT_DIR}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
instanceType=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type)
run_tag="${SLURM_JOB_ID}-${SLURM_JOB_NUM_NODES}x${instanceType}-${SLURM_NPROCS}-$(date "+%d-%m-%Y-%H-%M")"
shared_dir="$(readlink -m "${basedir}/${SLURM_JOB_NAME%.*}")/Run/${run_tag}"
mkdir -p "${shared_dir}"

# --- working directory: node-local NVMe when available ----------------------
# MAPDL writes its scratch to the working directory, and in DMP every rank
# resolves the same PATH locally on its own node. Running from /scratch
# (ParallelCluster mounts the instance-store there, e.g. 4x3.8TB on Hpc6id)
# keeps out-of-core I/O local: measurably faster and no shared-FS contention.
# Verified single-node and multi-node; each node needs the dir created, and
# each node's scratch must be reclaimed afterwards (warm nodes are reused).
workdir="${shared_dir}"
if [ "${scratch_mode}" != "shared" ]; then
    if srun --ntasks=${SLURM_JOB_NUM_NODES} --ntasks-per-node=1 \
         /bin/bash -c '[ -d /scratch ] && [ -w /scratch ]' 2>/dev/null; then
        workdir="/scratch/mapdl-${run_tag}"
        srun --ntasks=${SLURM_JOB_NUM_NODES} --ntasks-per-node=1 mkdir -p "${workdir}"
        scratch_mode="nvme"
        echo "Using node-local NVMe scratch on all ${SLURM_JOB_NUM_NODES} node(s): ${workdir}"
    elif [ "${scratch_mode}" = "nvme" ]; then
        echo "WARNING: SCRATCH_MODE=nvme requested but /scratch is unavailable on some node; using shared filesystem." >&2
        scratch_mode="shared"
    else
        scratch_mode="shared"
    fi
fi
echo "Execution directory is: ${workdir} (scratch: ${scratch_mode}; logs: ${shared_dir})"
cd "${workdir}"

export cores_x_node=$(((SLURM_NPROCS / SLURM_JOB_NUM_NODES ) + ( SLURM_NPROCS % SLURM_JOB_NUM_NODES > 0 )))

for i in $(scontrol show hostnames=$SLURM_JOB_NODELIST); do
  machines=$machines:$i:$cores_x_node
done
machines=${machines:1}

cp "$0" "${shared_dir}/" 2>/dev/null
# inputs are read only by the master rank; symlinks into the workdir suffice
ln -sf "${input_file}" .
for aux in "$(dirname "${input_file}")"/*.db "$(dirname "${input_file}")"/checkver.mac; do
    [ -e "${aux}" ] && ln -sf "${aux}" .
done

echo "Drop caches on all nodes"
mpirun -np $SLURM_JOB_NUM_NODES -ppn 1 /bin/bash -c "sync && echo 3 | sudo tee /proc/sys/vm/drop_caches"

echo "Enabling Transparent Huge Pages (THP)"
mpirun -np $SLURM_JOB_NUM_NODES -ppn 1 /bin/bash -c "echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled"

echo "Install missing lib (dnf on AL2023, yum on AL2)"
mpirun -np $SLURM_JOB_NUM_NODES -ppn 1 /bin/bash -c \
  "[ -e /usr/lib64/libGLU.so.1 ] || sudo dnf -y install mesa-libGLU 2>/dev/null || sudo yum -y install mesa-libGLU"

output_file="output-${SLURM_JOB_ID}.log"

# Ansys Mechanical gets the total number of cores from hostlist not from -np
_rec_t0="$(date +%s)"
"${APP_BIN_PATH}" -b -dis -mpi intelmpi -ssh -machines $machines -i $(basename ${input_file}) -o "${output_file}"
_rec_rc=$?
_rec_secs=$(( $(date +%s) - _rec_t0 ))

# ---------------------------------------------------------------------------
# Success detection — do NOT trust the exit code alone. Several official
# benchmark decks stop at a fixed iteration count, making MAPDL print
# "*** ERROR *** The number of iterations exceeds N ... terminated at the
# user's request" and exit NON-ZERO after a perfectly good run. Ansys's own
# runBench.py judges the OUTPUT, and so do we:
#   success = "RUN COMPLETED" present
#             AND a final "Elapsed Time (sec)" present
#             AND no *** ERROR *** other than the iteration-limit termination.
# NB: parse the number right after the '=': the summary line ends with a Date
# field, so taking the LAST number on the line yields the year, not seconds.
# ---------------------------------------------------------------------------
mapdl_elapsed="$(grep -hE 'Elapsed Time +\(sec\)' "${output_file}" 2>/dev/null | tail -1 \
                 | sed -E 's/.*Elapsed Time *\(sec\) *= *([0-9]+(\.[0-9]+)?).*/\1/')"
case "${mapdl_elapsed}" in ''|*[!0-9.]*) mapdl_elapsed="" ;; esac
unexpected_errs=$(grep -A2 '^ \*\*\* ERROR' "${output_file}" 2>/dev/null \
  | grep -v 'iterations exceeds' | grep -c '^ \*\*\* ERROR' || true)
memory_mode="unknown"
if   grep -qi 'Out-of-Core' "${output_file}" 2>/dev/null; then memory_mode="OutOfCore"
elif grep -qiE 'In-Core|InCore' "${output_file}" 2>/dev/null; then memory_mode="InCore"; fi

if grep -q "RUN COMPLETED" "${output_file}" 2>/dev/null && [ -n "${mapdl_elapsed}" ] \
   && [ "${unexpected_errs:-0}" -eq 0 ]; then
    solve_ok=1
else
    solve_ok=0
fi
echo "solve_ok=${solve_ok} rc=${_rec_rc} wall=${_rec_secs}s mapdl_elapsed=${mapdl_elapsed:-n/a} memory_mode=${memory_mode} unexpected_errors=${unexpected_errs:-0}"

# keep the log on the shared filesystem, then reclaim node-local scratch
cp -f "${output_file}" "${shared_dir}/" 2>/dev/null
if [ "${scratch_mode}" = "nvme" ]; then
    cd "${shared_dir}"
    srun --ntasks=${SLURM_JOB_NUM_NODES} --ntasks-per-node=1 \
      /bin/bash -c "rm -rf '${workdir}' && echo \"\$(hostname): local scratch reclaimed\""
fi

# ---------------------------------------------------------------------------
# Record this benchmark to the AI-Powered HPC dataset (best-effort, non-fatal).
# Recording is gated on the OUTPUT-based success test above, not the exit code
# (which discards valid fixed-iteration benchmark runs). See
# apps/AnsysMechanical/dynamodb/README.md and apps/BENCHMARK-RECORDERS.md.
# ---------------------------------------------------------------------------
_recorder="${DYNAMODB_RECORDER:-}"
for _c in "${_recorder}" \
          "${SLURM_SUBMIT_DIR:-.}/dynamodb/record-benchmark.sh" \
          "${SLURM_SUBMIT_DIR:-.}/../dynamodb/record-benchmark.sh" \
          "${SLURM_SUBMIT_DIR:-.}/apps/AnsysMechanical/dynamodb/record-benchmark.sh"; do
    if [ -n "${_c}" ] && [ -x "${_c}" ]; then _recorder="${_c}"; break; fi
done
if [ "${solve_ok}" -eq 1 ] && [ -n "${_recorder}" ] && [ -x "${_recorder}" ]; then
    MECHANICAL_VERSION="${mechanicalversion}" BENCHMARK_CASE="$(basename "${input_file%.*}")" \
    TIME_TO_SOLUTION="${_rec_secs}" RUN_DIR="${shared_dir}" "${_recorder}" \
        --metric mapdl_elapsed_seconds="${mapdl_elapsed:-0}" \
        --char memory_mode="${memory_mode}" \
        --char scratch_mode="${scratch_mode}" \
        || echo "NOTE: benchmark recorder failed (non-fatal); the solve was unaffected." >&2
elif [ "${solve_ok}" -ne 1 ]; then
    echo "NOTE: solve not verified (rc=${_rec_rc}); skipping benchmark recording." >&2
else
    echo "NOTE: benchmark recorder not found; set DYNAMODB_RECORDER=/path/to/record-benchmark.sh to record." >&2
fi

# A verified-complete run is a success even when MAPDL's exit code is non-zero
# (fixed-iteration decks); a failed run keeps the solver's exit code.
[ "${solve_ok}" -eq 1 ] && exit 0 || exit ${_rec_rc}
