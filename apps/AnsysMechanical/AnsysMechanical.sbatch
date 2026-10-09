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
#                       NVMe (SCRATCH_ROOT, mounted by ParallelCluster) when
#                       ALL nodes pass the scratch check below - faster for
#                       out-of-core solves and keeps heavy scratch I/O off the
#                       shared filesystem. shared never checks.
#     SCRATCH_ROOT      instance-store mount point (default /scratch).
#     SCRATCH_MIN_FREE_GIB  free space SCRATCH_ROOT needs on every node for the
#                       solve to run there, in GiB (default 300; 1 to 9999999).
#     ANSYS_COMPAT_DIR  dir with the legacy libs AL2023 lacks (see Readme.md);
#                       default ${BASE_DIR}/ansys_compat, used when it exists.
#     ANSYSLMD_LICENSE_FILE, SOURCE, DYNAMODB_RECORDER    see recorder section.
#
# IMPORTANT: submit as a regular user, NEVER root. The -ssh start method
# authenticates with the submitting user's inter-node SSH identity, and on
# ParallelCluster only the default user (ec2-user) has one - root has no key to
# offer, so the remote ranks never start. Least privilege applies regardless: a
# solver has no need for root.
# ---------------------------------------------------------------------------
if [ "$(id -u)" -eq 0 ]; then
    echo "ERROR: run this job as a regular user, not root." >&2
    echo "       The -ssh start method authenticates with the submitting user's inter-node" >&2
    echo "       SSH identity, and on ParallelCluster only the default user (ec2-user)" >&2
    echo "       has one; root has no key to offer, so the remote ranks never start." >&2
    echo "       Running a solver as root also violates least privilege for no benefit." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Solve-verdict library. Sourced rather than inlined so the success/failure
# boundary is unit-tested: see tests/test-mapdl-verdict.sh (no Slurm or licensed
# solver needed). Located early so a missing library fails BEFORE burning
# solver time and licence tokens.
# ---------------------------------------------------------------------------
_verdict_lib="${MAPDL_VERDICT_LIB:-}"
_self_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" 2>/dev/null && pwd)"
for _c in "${_verdict_lib}" \
          "${_self_dir}/lib/mapdl-verdict.sh" \
          "${SLURM_SUBMIT_DIR:-.}/lib/mapdl-verdict.sh" \
          "${SLURM_SUBMIT_DIR:-.}/apps/AnsysMechanical/lib/mapdl-verdict.sh"; do
    if [ -n "${_c}" ] && [ -r "${_c}" ]; then _verdict_lib="${_c}"; break; fi
done
if [ -z "${_verdict_lib}" ] || [ ! -r "${_verdict_lib}" ]; then
    echo "ERROR: cannot find lib/mapdl-verdict.sh, which decides whether the solve" >&2
    echo "       succeeded. Keep it next to this script (apps/AnsysMechanical/lib/)" >&2
    echo "       or point MAPDL_VERDICT_LIB at it. Refusing to run: without it this" >&2
    echo "       job cannot tell a completed benchmark from a failed one." >&2
    exit 1
fi
# shellcheck source=lib/mapdl-verdict.sh
. "${_verdict_lib}"

######################## EFA settings ########################
# `module` is undefined in non-login shells (cron/SSM/automation) - source it.
command -v module >/dev/null 2>&1 || source /etc/profile.d/modules.sh
export I_MPI_OFI_LIBRARY_INTERNAL=0
module load intelmpi
export I_MPI_DEBUG=5
export I_MPI_FABRICS=shm:ofi
# Pinning the provider makes EFA selection FAIL-CLOSED: if EFA is unavailable the
# job errors out instead of quietly falling back to TCP and reporting a slower
# result as if it were an EFA number. Remove this line and the fallback becomes
# silent again - keep it for benchmarking.
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
# Where node-local instance-store NVMe is mounted. ParallelCluster uses /scratch;
# override for clusters that mount it elsewhere.
scratch_root=${SCRATCH_ROOT:-"/scratch"}
# Free space, in GiB, SCRATCH_ROOT must have on EVERY node for the solve to run
# there (see the scratch check below). The default holds the whole of an in-core
# V26 Cluster solve on one node (MAPDL reported at most 231 GiB of disk space used)
# with room to spare. Out-of-core solves write several times more (0.5-1.2 TB for
# those models), and a node that runs out of scratch mid-solve fails the run, so
# for an out-of-core model set it to what the model writes on a node.
scratch_min_free_gib=${SCRATCH_MIN_FREE_GIB:-"300"}
# A whole number from 1 to 9999999: at most 7 digits keeps the comparison far
# inside the shell's integers, and 0 would let any free space pass.
case "${scratch_min_free_gib}" in
    *[!0-9]*|0|00|000|0000|00000|000000|0000000|????????*)
        echo "ERROR: SCRATCH_MIN_FREE_GIB='${scratch_min_free_gib}' is not a whole number of GiB" >&2
        echo "       from 1 to 9999999. It is the free space SCRATCH_ROOT needs on every node" >&2
        echo "       for the solve to use node-local NVMe scratch. Refusing to run rather" >&2
        echo "       than guess at it." >&2
        exit 1 ;;
esac

APP_BIN_PATH="${basedir}/ansys_inc/${mechanicalversion}/ansys/bin/mapdl"

# ---------------------------------------------------------------------------
# MAPDL needs a writable HOME, and with -dis/-ssh it must be the REAL home: the
# remote launch reads the user's ~/.ssh identity from it. An empty scratch HOME
# would satisfy "writable" and then break multi-node startup with a confusing
# authentication error, so recover the account's actual home and only fall back
# to a temporary one for a genuinely single-node run.
# ---------------------------------------------------------------------------
if [ -z "${HOME:-}" ] || [ ! -w "${HOME}" ]; then
    _real_home="$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6)"
    if [ -n "${_real_home}" ] && [ -w "${_real_home}" ]; then
        export HOME="${_real_home}"
        echo "NOTE: HOME was unset/unwritable; recovered ${HOME} from the passwd database."
    elif [ "${SLURM_JOB_NUM_NODES:-1}" -gt 1 ]; then
        echo "ERROR: HOME is unset or not writable and the real home ('${_real_home:-unknown}')" >&2
        echo "       is unavailable. A multi-node -ssh launch needs the user's ~/.ssh identity" >&2
        echo "       from their real home, so a temporary HOME cannot work here." >&2
        echo "       Fix: submit as the cluster's default user with their home mounted, or" >&2
        echo "       export HOME=/path/to/that/home before sbatch." >&2
        exit 1
    else
        export HOME="$(mktemp -d)"
        echo "NOTE: HOME was unset/unwritable and the real home is unavailable; using the"
        echo "      temporary ${HOME}. This is only safe because this is a single-node run"
        echo "      (no ~/.ssh identity is needed)."
    fi
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
if ! mkdir -p "${shared_dir}"; then
    echo "ERROR: cannot create the shared run directory '${shared_dir}'." >&2
    echo "       Check that ${basedir} is mounted and writable. Refusing to run: the" >&2
    echo "       solver log would have nowhere durable to land." >&2
    exit 1
fi

# --- working directory: node-local NVMe when available ----------------------
# MAPDL writes its scratch to the working directory, and in DMP every rank
# resolves the same PATH locally on its own node. Running from /scratch
# (ParallelCluster mounts the instance-store there, e.g. 4x3.8TB on Hpc6id)
# keeps out-of-core I/O local: measurably faster and no shared-FS contention.
# Verified single-node and multi-node; each node needs the dir created, and
# each node's scratch must be reclaimed afterwards (warm nodes are reused).
#
# A writable SCRATCH_ROOT is not enough: on a type without instance store it can
# be a plain directory on the root volume, and the solve would then write its
# scratch to EBS. So every node runs nvme_scratch_probe (one srun task per node):
# SCRATCH_ROOT must be a mount point, every disk under it local NVMe instance
# storage (ParallelCluster stripes the drives into one LVM volume; lsblk reports
# each one's model as "Amazon EC2 NVMe Instance Storage"), writable by the job
# user, with at least SCRATCH_MIN_FREE_GIB free. NVMe is used only when the number
# of DISTINCT host names that passed equals the node count: a node that printed
# nothing, or a second answer from the same host, cannot stand in for a node.
# Anything else runs from the shared run directory, as SCRATCH_MODE=shared does.
# shellcheck disable=SC2317  # runs on each node through srun (declare -f), not here
nvme_scratch_probe() {   # <root> <min_free_gib> -> "<host> ok: ..." or "<host> no: <why>"
    local root="$1" need="$2" host src disks free_kib free_gib
    host="$(hostname)"
    if [ ! -d "${root}" ]; then echo "${host} no: ${root} does not exist"; return 0; fi
    # The last mount listed at that point is the one on top: the one a path there reaches.
    src="$(findmnt -n -o SOURCE --mountpoint "${root}" 2>/dev/null | tail -n 1)"
    if [ -z "${src}" ]; then
        echo "${host} no: ${root} is not a mount point (a directory on another filesystem)"; return 0
    fi
    disks="$(lsblk -n -s -P -o TYPE,MODEL "${src}" 2>/dev/null | grep 'TYPE="disk"')"
    if [ -z "${disks}" ]; then echo "${host} no: ${root} (${src}) is on no local disk"; return 0; fi
    if grep -qv 'MODEL="Amazon EC2 NVMe Instance Storage' <<< "${disks}"; then
        echo "${host} no: ${root} (${src}) has a disk that is not local NVMe instance storage"; return 0
    fi
    if [ ! -w "${root}" ]; then echo "${host} no: ${root} is not writable by $(id -un)"; return 0; fi
    free_kib="$(df -Pk "${root}" 2>/dev/null | awk 'NR == 2 { print $4 }')"
    # 18 digits at most, so the arithmetic below cannot overflow; 10# reads it as decimal
    case "${free_kib}" in
        ''|*[!0-9]*|???????????????????*) echo "${host} no: cannot read the free space of ${root}"; return 0 ;;
    esac
    free_gib=$(( 10#${free_kib} / 1048576 ))
    # "ok" only when the test holds: a comparison the shell cannot evaluate answers no.
    if [ "${free_gib}" -ge "${need}" ] 2>/dev/null; then
        echo "${host} ok: ${root} on local NVMe instance storage (${src}), ${free_gib} GiB free"
    elif [ "${free_gib}" -lt "${need}" ] 2>/dev/null; then
        echo "${host} no: ${root} has ${free_gib} GiB free, under ${need} GiB"
    else
        echo "${host} no: cannot compare the ${free_gib} GiB free on ${root} with ${need} GiB"
    fi
}
workdir="${shared_dir}"
if [ "${scratch_mode}" != "shared" ]; then
    echo "NVMe scratch check (SCRATCH_MODE=${scratch_mode}): ${scratch_root} on each of the" \
         "${SLURM_JOB_NUM_NODES} node(s) must be a mount point on local NVMe instance storage," \
         "writable, with at least ${scratch_min_free_gib} GiB free"
    _probe="$(srun --ntasks=${SLURM_JOB_NUM_NODES} --ntasks-per-node=1 /bin/bash -c \
                "$(declare -f nvme_scratch_probe); nvme_scratch_probe \"\$@\"" nvme-scratch-probe \
                "${scratch_root}" "${scratch_min_free_gib}" 2>&1)"
    [ -n "${_probe}" ] && printf '%s\n' "${_probe}" | sed 's/^/  /'
    _passed="$(printf '%s\n' "${_probe}" | awk '$2 == "ok:" && !seen[$1]++ { n++ } END { print n + 0 }')"
    if [ "${_passed}" = "${SLURM_JOB_NUM_NODES}" ]; then
        workdir="${scratch_root}/mapdl-${run_tag}"
        srun --ntasks=${SLURM_JOB_NUM_NODES} --ntasks-per-node=1 mkdir -p "${workdir}"
        scratch_mode="nvme"
        echo "Using node-local NVMe scratch on all ${SLURM_JOB_NUM_NODES} node(s): ${workdir}"
    else
        echo "${_passed} of ${SLURM_JOB_NUM_NODES} node(s) passed the NVMe scratch check; using the shared filesystem."
        if [ "${scratch_mode}" = "nvme" ]; then
            echo "WARNING: SCRATCH_MODE=nvme requested but '${scratch_root}' is unavailable on some node; using shared filesystem." >&2
        fi
        scratch_mode="shared"
    fi
fi
echo "Execution directory is: ${workdir} (scratch: ${scratch_mode}; logs: ${shared_dir})"
cd "${workdir}"

# ---------------------------------------------------------------------------
# -machines host:cores list.
#
# Take the per-host task counts from Slurm itself (SLURM_TASKS_PER_NODE, e.g.
# "64(x2)" or "43,42") instead of dividing --ntasks by --nodes. A plain division
# only agrees with the real placement when the allocation is homogeneous and
# divisible; ceiling division would hand MAPDL MORE cores than were allocated
# (oversubscribing the nodes and over-drawing HPC licence tokens), while floor
# division would silently drop ranks. The recommended layouts in Readme.md are
# all homogeneous and divisible, so this normally reproduces the simple result -
# it just stays correct when they are not.
# ---------------------------------------------------------------------------
expand_tasks_per_node() {   # "64(x2),32" -> "64 64 32"
    local spec="$1" part count reps r out=""
    [ -n "${spec}" ] || return 1
    local IFS=','
    for part in ${spec}; do
        if   [[ "${part}" =~ ^([0-9]+)\(x([0-9]+)\)$ ]]; then
            count="${BASH_REMATCH[1]}"; reps="${BASH_REMATCH[2]}"
        elif [[ "${part}" =~ ^([0-9]+)$ ]]; then
            count="${part}"; reps=1
        else
            return 1
        fi
        for (( r = 0; r < reps; r++ )); do out="${out} ${count}"; done
    done
    printf '%s\n' "${out# }"
}

mapfile -t _hosts < <(scontrol show hostnames="${SLURM_JOB_NODELIST}")
read -r -a _tpn <<< "$(expand_tasks_per_node "${SLURM_TASKS_PER_NODE:-}" || true)"

# FAIL CLOSED if Slurm's placement cannot be read. Redistributing the tasks
# ourselves would INVENT a placement rather than learn it, and guessing wrong means
# oversubscribed nodes and over-drawn licence tokens.
if [ "${#_tpn[@]}" -ne "${#_hosts[@]}" ]; then
    echo "ERROR: cannot determine the per-host task placement from Slurm." >&2
    echo "       SLURM_TASKS_PER_NODE='${SLURM_TASKS_PER_NODE:-unset}' expands to ${#_tpn[@]} entry/entries" >&2
    echo "       but SLURM_JOB_NODELIST='${SLURM_JOB_NODELIST:-unset}' has ${#_hosts[@]} host(s)." >&2
    echo "       Refusing to guess: an invented -machines list oversubscribes nodes and" >&2
    echo "       over-draws HPC licence tokens. Submit with an explicit homogeneous layout" >&2
    echo "       (--nodes=N --ntasks-per-node=C) so Slurm reports the placement, or query" >&2
    echo "       it authoritatively (e.g. scontrol show job \"\$SLURM_JOB_ID\")." >&2
    exit 1
fi

machines=""; _tpn_sum=0; _tpn_uniform=1
for _i in "${!_hosts[@]}"; do
    machines="${machines}:${_hosts[$_i]}:${_tpn[$_i]}"
    _tpn_sum=$(( _tpn_sum + _tpn[_i] ))
    [ "${_tpn[$_i]}" = "${_tpn[0]}" ] || _tpn_uniform=0
done
machines="${machines:1}"

if [ "${_tpn_sum}" -ne "${SLURM_NPROCS}" ]; then
    echo "ERROR: -machines totals ${_tpn_sum} cores but Slurm allocated ${SLURM_NPROCS}." >&2
    echo "       Refusing to run rather than over- or under-subscribing the allocation." >&2
    exit 1
fi
# Per-node count, meaningful ONLY when the allocation is homogeneous. Left empty
# for a heterogeneous layout so nothing downstream records one node's share as if
# it applied to all of them.
if [ "${_tpn_uniform}" -eq 1 ]; then
    export cores_x_node="${_tpn[0]}"
else
    export cores_x_node=""
    echo "NOTE: heterogeneous task placement (${machines}); cores_per_node is not a single value."
fi
echo "Task placement: ${machines} (total ${_tpn_sum} cores over ${#_hosts[@]} node(s); uniform=${_tpn_uniform})"

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
# Success detection — the OUTPUT decides, not the exit code. Several official
# benchmark decks stop at a fixed iteration count, making MAPDL print
# "*** ERROR *** The number of iterations exceeds N ... terminated at the
# user's request" and exit NON-ZERO after a perfectly good run; a killed or
# truncated run can conversely leave a zero status. Ansys's own runBench.py
# judges the output, and so do we. The rules and their edge cases live in
# lib/mapdl-verdict.sh and are covered by tests/test-mapdl-verdict.sh.
# ---------------------------------------------------------------------------
mapdl_solve_verdict "${output_file}" "${_rec_rc}"
mapdl_elapsed="${MAPDL_ELAPSED}"
memory_mode="$(mapdl_memory_mode "${output_file}")"
solve_ok="${MAPDL_SOLVE_OK}"
final_rc="${MAPDL_FINAL_RC}"
echo "rc=${_rec_rc} wall=${_rec_secs}s memory_mode=${memory_mode} $(mapdl_verdict_summary)"
if [ "${MAPDL_UNEXPECTED}" -gt 0 ]; then
    echo "Unexpected MAPDL error block(s) — first lines:" >&2
    mapdl_error_blocks "${output_file}" | grep -viE "${MAPDL_BENIGN_ERROR_RE}" | head -5 >&2
fi

# ---------------------------------------------------------------------------
# MAPDL's error logs on node-local scratch. Every MAPDL process writes its own
# file<N>.err in the working directory of the node it runs on, and the reclaim
# below deletes that directory. So, first, each node copies its own into
# <shared_dir>/<host>/ (the scratch check passed only distinct host names); then a
# name only one node holds moves up to <shared_dir>/, where a run on the shared
# filesystem has it, and a name more than one node holds stays under each <host>/,
# so no node's copy replaces another's. Best effort: a copy that fails prints a
# WARNING, and neither the reclaim nor the job's exit status changes.
# ---------------------------------------------------------------------------
keep_mapdl_error_logs() {   # <node-local workdir> <shared run dir>
    local src="$1" dest="$2" f same apart=0
    # shellcheck disable=SC2016  # the script is expanded by the bash on each node
    srun --ntasks="${SLURM_JOB_NUM_NODES}" --ntasks-per-node=1 /bin/bash -c '
        host="$(hostname)" copied=0 failed=0
        for f in "$1"/file*.err; do
            [ -f "${f}" ] || continue
            if mkdir -p "$2/${host}" && cp -p -- "${f}" "$2/${host}/"; then
                copied=$(( copied + 1 ))
            else
                failed=$(( failed + 1 ))
            fi
        done
        echo "${host}: ${copied} MAPDL error log(s) (file*.err) copied to $2"
        if [ "${failed}" -gt 0 ]; then
            echo "WARNING: ${host}: ${failed} MAPDL error log(s) (file*.err) not copied" >&2; exit 1
        fi' mapdl-error-logs "${src}" "${dest}" \
        || echo "WARNING: not every MAPDL error log (file*.err) was copied off the nodes' NVMe scratch; the reclaim deletes the rest." >&2
    for f in "${dest}"/*/file*.err; do
        [ -f "${f}" ] || continue
        same=( "${dest}"/*/"${f##*/}" )
        if [ "${#same[@]}" -eq 1 ] && [ ! -e "${dest}/${f##*/}" ]; then
            mv -- "${f}" "${dest}/"
        else
            apart=$(( apart + 1 ))
        fi
    done
    rmdir "${dest}"/*/ 2>/dev/null
    if [ "${apart}" -gt 0 ]; then
        echo "MAPDL error logs: ${apart} file(s) whose name another node also holds kept under ${dest}/<host>/"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Durable stage-out BEFORE reclaiming node-local scratch. When the solve ran on
# /scratch, the copy on the shared filesystem is the ONLY lasting record of it,
# so a failed copy must never be followed by `rm -rf`: keep the scratch, say
# exactly where it is, and fail the job.
# ---------------------------------------------------------------------------
if mapdl_stage_out "${output_file}" "${shared_dir}"; then
    if [ "${scratch_mode}" = "nvme" ]; then
        cd "${shared_dir}"
        keep_mapdl_error_logs "${workdir}" "${shared_dir}"
        srun --ntasks=${SLURM_JOB_NUM_NODES} --ntasks-per-node=1 \
          /bin/bash -c "rm -rf '${workdir}' && echo \"\$(hostname): local scratch reclaimed\""
    fi
else
    echo "ERROR: stage-out to '${shared_dir}' failed; NOT reclaiming node-local scratch." >&2
    echo "ERROR: the only copy of the solver output is on node $(hostname) at:" >&2
    echo "ERROR:   ${workdir}/${output_file}" >&2
    echo "ERROR: recover it before that node is reused or terminated, then replay the" >&2
    echo "ERROR: recorder with --run-dir <recovered dir>. Marking this job failed." >&2
    solve_ok=0
    [ "${final_rc}" -ne 0 ] || final_rc=4
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
# Recorder eligibility means the run was ACCEPTED OVERALL, not merely that the
# output looked complete: verified output AND a final status of zero AND a durable
# stage-out. A job the scheduler reports as failed must never contribute a
# benchmark row, otherwise a failure silently becomes training data.
if [ "${final_rc}" -eq 0 ] && [ "${solve_ok}" -eq 1 ] \
   && [ -n "${_recorder}" ] && [ -x "${_recorder}" ]; then
    _rec_args=( --char memory_mode="${memory_mode}" --char scratch_mode="${scratch_mode}" )
    # Only pass the MAPDL-reported solver time when it is actually valid; the
    # verdict above already guarantees it is positive when solve_ok=1.
    [ -n "${mapdl_elapsed}" ] && _rec_args+=( --metric mapdl_elapsed_seconds="${mapdl_elapsed}" )
    # cores_per_node is only meaningful when EVERY node got the same count.
    # Recording one node's share as if it were uniform would misdescribe a
    # heterogeneous allocation, so record the real layout instead.
    if [ "${_tpn_uniform}" -eq 1 ] && [ -n "${cores_x_node:-}" ]; then
        _rec_args+=( --cores-per-node "${cores_x_node}" )
    else
        _rec_args+=( --char task_placement="${machines}" )
        echo "NOTE: heterogeneous task placement; recording task_placement instead of cores_per_node." >&2
    fi
    MECHANICAL_VERSION="${mechanicalversion}" BENCHMARK_CASE="$(basename "${input_file%.*}")" \
    TIME_TO_SOLUTION="${_rec_secs}" RUN_DIR="${shared_dir}" "${_recorder}" "${_rec_args[@]}" \
        || echo "NOTE: benchmark recorder failed (non-fatal); the solve was unaffected." >&2
elif [ "${final_rc}" -ne 0 ]; then
    echo "NOTE: run not accepted (solver rc=${_rec_rc}, final rc=${final_rc}); skipping benchmark recording." >&2
elif [ "${solve_ok}" -ne 1 ]; then
    echo "NOTE: solve not verified (rc=${_rec_rc}); skipping benchmark recording." >&2
else
    echo "NOTE: benchmark recorder not found; set DYNAMODB_RECORDER=/path/to/record-benchmark.sh to record." >&2
fi

# Exit with the verdict's status: a verified-complete run is a success even when
# MAPDL's exit code is non-zero (fixed-iteration decks), an unverified run is a
# failure even when MAPDL returned 0, and an unrelated non-zero status is passed
# through untouched. See lib/mapdl-verdict.sh for the full table.
exit "${final_rc}"
