#!/bin/bash
# =============================================================================
# NVMe scratch in AnsysMechanical.sbatch: the check every node must pass before
# MAPDL's working directory goes on SCRATCH_ROOT, and the copy of MAPDL's error
# logs (file*.err) off every node's NVMe scratch before the reclaim.
# =============================================================================
# Runs the assembled launcher, as test-sbatch-e2e.sh does, on emulated nodes. The
# srun stub runs each per-node step once per node (STUB_NODE=node-1..N), and
# hostname, findmnt, lsblk and df answer from that node's fixture, in the formats
# util-linux 2.37 (findmnt, lsblk) and GNU coreutils 8.32 (df -P) print. The hpc6id
# fixtures (fixtures/scratch-hpc6id-*.txt) are what a real hpc6id.32xlarge answered
# for the /scratch ParallelCluster mounts there: an LVM volume over its four
# instance-store drives. The emulated nodes share one real directory as
# SCRATCH_ROOT; while a node's error-log copy runs, the working directory holds
# that node's file*.err and no other node's.
#
# No Slurm, no EC2, no MPI, no licensed solver, no AWS credentials, no network.
#
#   ./tests/test-nvme-scratch.sh
# =============================================================================

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIX="${HERE}/fixtures"
SBATCH="${HERE}/../AnsysMechanical.sbatch"

pass=0; fail=0; skip=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"; fail=$((fail+1)); }
skipt(){ printf '  \033[33mSKIP\033[0m %s (%s)\n' "$1" "$2"; skip=$((skip+1)); }

STUBS="$(mktemp -d)"
CASES=()
cleanup() {
    local c
    for c in "${CASES[@]}"; do chmod -R u+rwx "${c}" 2>/dev/null; rm -rf "${c}"; done
    rm -rf "${STUBS}"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Stubs
# ---------------------------------------------------------------------------
mkdir -p "${STUBS}/bin"

cat > "${STUBS}/bin/scontrol" <<'EOF'
#!/bin/bash
# scontrol show hostnames=node-1,node-2
for a in "$@"; do
  case "$a" in hostnames=*) echo "${a#hostnames=}" | tr ',' '\n';; esac
done
EOF

# srun records each call in ${STUB_CALLS} as "<step> <srun options>", then runs the
# step once per emulated node, whatever the options ask for (the options are checked
# separately, from that record).
cat > "${STUBS}/bin/srun" <<'EOF'
#!/bin/bash
opts=()
while [ $# -gt 0 ] && [ "${1#--}" != "$1" ]; do opts+=("$1"); shift; done
if   [ "$1" = mkdir ];                  then step=mkdir
elif [ "${4:-}" = nvme-scratch-probe ]; then step=probe
elif [ "${4:-}" = mapdl-error-logs ];   then step=errlogs
elif [ "${3:-}" != "${3#rm -rf }" ];    then step=reclaim
else                                         step=other
fi
echo "${step} ${opts[*]}" >> "${STUB_CALLS}"
rc=0
for (( i = 1; i <= SLURM_JOB_NUM_NODES; i++ )); do
    node="node-${i}"; d="${STUB_NODES}/${node}"
    # a node whose probe prints nothing: it never answered
    if [ "${step}" = probe ] && [ -e "${d}/silent" ]; then continue; fi
    # the nodes share one working directory ($5): while a node's copy runs, it holds
    # that node's error logs (its "errlogs" fixture) and no other node's
    if [ "${step}" = errlogs ]; then
        rm -f "$5"/file*.err
        if [ -d "${d}/errlogs" ]; then cp "${d}/errlogs/"* "$5"/; fi
    fi
    STUB_NODE="${node}" "$@" || rc=1
done
exit "${rc}"
EOF

# A node answers with its "hostname" fixture when it has one, else its own name.
cat > "${STUBS}/bin/hostname" <<'EOF'
#!/bin/bash
f="${STUB_NODES}/${STUB_NODE:-node-1}/hostname"
if [ -f "$f" ]; then cat "$f"; else echo "${STUB_NODE:-node-1}"; fi
EOF

# findmnt -n -o SOURCE --mountpoint <path>: the node's "findmnt" fixture; for a path
# that is no mount point, nothing and status 1, as util-linux answers.
cat > "${STUBS}/bin/findmnt" <<'EOF'
#!/bin/bash
if [ "$#" -ne 5 ] || [ "$1 $2 $3 $4" != "-n -o SOURCE --mountpoint" ]; then
    echo "findmnt stub: unexpected arguments: $*" >&2; exit 64
fi
f="${STUB_NODES}/${STUB_NODE:-node-1}/findmnt"
[ -f "$f" ] || exit 1
cat "$f"
EOF

# lsblk -n -s -P -o TYPE,MODEL <device>: the node's "lsblk" fixture when <device> is
# the block device it describes ("lsblk.device"); for any other source (tmpfs,
# NFS ...), util-linux's answer for what is no block device.
cat > "${STUBS}/bin/lsblk" <<'EOF'
#!/bin/bash
if [ "$#" -ne 6 ] || [ "$1 $2 $3 $4 $5" != "-n -s -P -o TYPE,MODEL" ]; then
    echo "lsblk stub: unexpected arguments: $*" >&2; exit 64
fi
d="${STUB_NODES}/${STUB_NODE:-node-1}"
if [ -f "$d/lsblk" ] && [ "$6" = "$(cat "$d/lsblk.device" 2>/dev/null)" ]; then
    cat "$d/lsblk"
else
    echo "lsblk: $6: not a block device" >&2; exit 32
fi
EOF

# df -Pk <path>: the node's "df" fixture (the header and one line).
cat > "${STUBS}/bin/df" <<'EOF'
#!/bin/bash
if [ "$#" -ne 2 ] || [ "$1" != "-Pk" ]; then
    echo "df stub: unexpected arguments: $*" >&2; exit 64
fi
f="${STUB_NODES}/${STUB_NODE:-node-1}/df"
[ -f "$f" ] || { echo "df: $2: Input/output error" >&2; exit 1; }
cat "$f"
EOF

for c in mpirun module sudo; do printf '#!/bin/bash\nexit 0\n' > "${STUBS}/bin/${c}"; done
printf '#!/bin/bash\ncat > /dev/null\n' > "${STUBS}/bin/tee"

cat > "${STUBS}/bin/curl" <<'EOF'
#!/bin/bash
# IMDS stub: token request or instance-type lookup.
case "$*" in
  *api/token*)     echo "stub-token";;
  *instance-type*) echo "hpc6id.32xlarge";;
  *)               echo "";;
esac
exit 0
EOF

cat > "${STUBS}/bin/recorder-stub.sh" <<'EOF'
#!/bin/bash
echo "ARGS: $*" >> "${RECORDER_LOG}"
exit 0
EOF
chmod +x "${STUBS}"/bin/*

# ---------------------------------------------------------------------------
# Cases and nodes. new_case starts a case (CASE, NODES, ROOT); node <n> <kind>
# [option ...] writes node-<n>'s answers under ${NODES}/node-<n>/ (findmnt, lsblk and
# the device it describes, lsblk.device, df, hostname, silent, errlogs/).
#   kinds:   hpc6id     the real hpc6id.32xlarge answers (13335 GiB free)
#            plain-dir  a type with no instance store: SCRATCH_ROOT only a directory
#                       on the root volume, which findmnt does not list
#            ebs        an EBS volume mounted there
#            nvme+ebs   an LVM volume over an instance-store drive and an EBS volume
#            tmpfs, nfs a mount that is on no local disk
#   options: free=<GiB> with that many GiB free (plus less than a GiB, which does
#                       not count); df-kib=<n> with exactly n KiB free; no-df (df fails)
#            host=<name> the host name the node answers with; silent (no answer)
#            errlogs=<a,b,...> the MAPDL error logs its working directory holds,
#                       each reading "<name> written on node-<n>"
# ---------------------------------------------------------------------------
GIB=1048576   # KiB

new_case() {
    CASE="$(mktemp -d)"; CASES+=("${CASE}")
    NODES="${CASE}/nodes"; ROOT="${CASE}/scratch"
    mkdir -p "${NODES}" "${ROOT}"
}

df_fixture() {   # <source> <available KiB> <mounted on>
    printf 'Filesystem                     1024-blocks  Used   Available Capacity Mounted on\n'
    printf '%-30s %11s %5s %11s %8s %s\n' "$1" "$(( $2 + 1000 ))" 1000 "$2" "1%" "$3"
}

node() {
    local n="$1" kind="$2" d="${NODES}/node-$1" opt log; shift 2
    mkdir -p "${d}"
    case "${kind}" in
        hpc6id)
            cp "${FIX}/scratch-hpc6id-findmnt.txt" "${d}/findmnt"
            cp "${FIX}/scratch-hpc6id-findmnt.txt" "${d}/lsblk.device"
            cp "${FIX}/scratch-hpc6id-lsblk.txt" "${d}/lsblk"
            cp "${FIX}/scratch-hpc6id-df.txt" "${d}/df" ;;
        plain-dir)
            df_fixture /dev/nvme0n1p1 $(( 30 * GIB )) / > "${d}/df" ;;
        ebs)
            echo /dev/nvme1n1 > "${d}/findmnt"
            echo /dev/nvme1n1 > "${d}/lsblk.device"
            echo 'TYPE="disk" MODEL="Amazon Elastic Block Store"' > "${d}/lsblk"
            df_fixture /dev/nvme1n1 $(( 4000 * GIB )) /scratch > "${d}/df" ;;
        nvme+ebs)
            cp "${FIX}/scratch-hpc6id-findmnt.txt" "${d}/findmnt"
            cp "${FIX}/scratch-hpc6id-findmnt.txt" "${d}/lsblk.device"
            printf '%s\n' 'TYPE="lvm" MODEL=""' \
                'TYPE="disk" MODEL="Amazon EC2 NVMe Instance Storage"' \
                'TYPE="disk" MODEL="Amazon Elastic Block Store"' > "${d}/lsblk"
            df_fixture /dev/mapper/vg.01-lv_ephemeral $(( 4000 * GIB )) /scratch > "${d}/df" ;;
        tmpfs)
            echo tmpfs > "${d}/findmnt"
            df_fixture tmpfs $(( 4000 * GIB )) /scratch > "${d}/df" ;;
        nfs)
            echo 192.0.2.10:/scratch > "${d}/findmnt"
            df_fixture 192.0.2.10:/scratch $(( 4000 * GIB )) /scratch > "${d}/df" ;;
        *)  echo "unknown node kind ${kind}" >&2; return 1 ;;
    esac
    for opt in "$@"; do
        case "${opt}" in
            free=*)   df_fixture /dev/mapper/vg.01-lv_ephemeral \
                          "$(( ${opt#free=} * GIB + GIB - 1 ))" /scratch > "${d}/df" ;;
            df-kib=*) df_fixture /dev/mapper/vg.01-lv_ephemeral "${opt#df-kib=}" /scratch > "${d}/df" ;;
            no-df)    rm -f "${d}/df" ;;
            host=*)   echo "${opt#host=}" > "${d}/hostname" ;;
            silent)   : > "${d}/silent" ;;
            errlogs=*)
                mkdir -p "${d}/errlogs"
                for log in $(tr ',' ' ' <<<"${opt#errlogs=}"); do
                    echo "${log} written on node-${n}" > "${d}/errlogs/${log}"
                done ;;
            *)        echo "unknown node option ${opt}" >&2; return 1 ;;
        esac
    done
}

# scratch_job <nodes> [VAR=value ...]: run the launcher on <nodes> emulated nodes,
# with the given job environment (SCRATCH_MODE=..., SCRATCH_MIN_FREE_GIB=...). The
# mapdl stub writes MAPDL_FIXTURE (default normal-success.log) and exits MAPDL_RC
# (default 0); BLOCK_HOST_DIR=<host> puts a file where that host's error-log
# directory would go, in the run directory. Sets RC, OUT (stdout), ERR (stderr),
# CALLS (srun's calls: step, then its options), REC (the recorder's arguments; empty
# when it was not called) and SHARED (the run directory on the shared filesystem).
scratch_job() {
    local nodes="$1"; shift
    local base="${CASE}/base" vdir="${CASE}/base/ansys_inc/v261/ansys/bin" i nodelist tpn
    mkdir -p "${vdir}" "${base}/inputs"
    cat > "${vdir}/mapdl" <<EOF
#!/bin/bash
outfile=""; prev=""
for a in "\$@"; do [ "\$prev" = "-o" ] && outfile="\$a"; prev="\$a"; done
: > "${CASE}/mapdl-ran"
[ -n "\${outfile}" ] && cp "\${MAPDL_FIXTURE:-${FIX}/normal-success.log}" "\${outfile}"
if [ -n "\${BLOCK_HOST_DIR:-}" ]; then
    for d in "${base}"/*/Run/*; do [ -d "\$d" ] && echo blocked > "\$d/\${BLOCK_HOST_DIR}"; done
fi
exit "\${MAPDL_RC:-0}"
EOF
    chmod +x "${vdir}/mapdl"
    : > "${base}/inputs/V26direct-5.dat"
    nodelist="node-1"; for (( i = 2; i <= nodes; i++ )); do nodelist="${nodelist},node-${i}"; done
    tpn="64"; [ "${nodes}" -gt 1 ] && tpn="64(x${nodes})"
    : > "${CASE}/srun.calls"; : > "${CASE}/recorder.log"
    # Started in the case directory: a launcher that loses its working directory then
    # writes into the case, never into the checkout the tests run from.
    ( cd "${CASE}" && exec env -u SCRATCH_MODE -u SCRATCH_ROOT -u SCRATCH_MIN_FREE_GIB \
        PATH="${STUBS}/bin:${PATH}" STUB_NODES="${NODES}" STUB_CALLS="${CASE}/srun.calls" \
        RECORDER_LOG="${CASE}/recorder.log" DYNAMODB_RECORDER="${STUBS}/bin/recorder-stub.sh" \
        MAPDL_VERDICT_LIB="${HERE}/../lib/mapdl-verdict.sh" \
        BASE_DIR="${base}" SCRATCH_ROOT="${ROOT}" \
        SLURM_JOB_ID=94000 SLURM_JOB_NAME="AnsysMechanical.sbatch" \
        SLURM_JOB_NUM_NODES="${nodes}" SLURM_NPROCS=$(( 64 * nodes )) SLURM_NTASKS=$(( 64 * nodes )) \
        SLURM_JOB_NODELIST="${nodelist}" SLURM_TASKS_PER_NODE="${tpn}" \
        SLURM_SUBMIT_DIR="${HERE}/.." \
        "$@" \
        bash "${SBATCH}" v261 "${base}/inputs/V26direct-5.dat" ) > "${CASE}/stdout" 2> "${CASE}/stderr"
    RC=$?
    OUT="$(cat "${CASE}/stdout")"
    ERR="$(cat "${CASE}/stderr")"
    CALLS="$(cat "${CASE}/srun.calls")"
    REC="$(cat "${CASE}/recorder.log")"
    # resolved as the launcher resolves it (readlink -m), so log lines compare equal
    SHARED="$(find "${base}/AnsysMechanical/Run" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n 1)"
    [ -z "${SHARED}" ] || SHARED="$(readlink -m "${SHARED}")"
}

# Every MAPDL error log in the run directory, sorted, as "<path under it>=<content>|".
kept_logs() {
    local f
    [ -n "${SHARED}" ] || return 0
    while IFS= read -r f; do
        printf '%s=%s|' "${f#"${SHARED}"/}" "$(cat "${f}")"
    done < <(find "${SHARED}" -name 'file*.err' -type f | sort)
}

has()   { grep -qF -- "$2" <<<"$1"; }
steps() { awk '{ printf "%s%s", sep, $1; sep = " " }' <<<"${CALLS}"; }
probe_lines() { grep -E '^  node-[0-9]+ (ok|no): ' <<<"${OUT}" | tr '\n' '|'; }

expect_out()   { if has "${OUT}" "$2"; then ok "$1"; else bad "$1" "stdout has: $2" "$(probe_lines)"; fi; }
expect_steps() { if [ "$(steps)" = "$2" ]; then ok "$1"; else bad "$1" "srun steps: $2" "srun steps: $(steps)"; fi; }
expect_no_warning() {
    if has "${ERR}" "WARNING"; then bad "$1" "no WARNING on stderr" "$(grep WARNING <<<"${ERR}")"; else ok "$1"; fi
}

# The job used node-local NVMe on all <nodes>, recorded it, and reclaimed it.
expect_nvme() {   # <what> <nodes>
    local what="$1" nodes="$2"
    if [ "${RC}" -eq 0 ] && has "${OUT}" "Using node-local NVMe scratch on all ${nodes} node(s): ${ROOT}/mapdl-" \
       && has "${OUT}" "(scratch: nvme; logs: " && has "${REC}" "scratch_mode=nvme" \
       && [ -z "$(ls -A "${ROOT}")" ]; then
        ok "${what}: NVMe on all ${nodes} node(s), recorded as scratch_mode=nvme, reclaimed"
    else
        bad "${what}: NVMe on all ${nodes} node(s)" "exit 0, NVMe workdir, scratch_mode=nvme, reclaimed" \
            "exit ${RC}; $(grep -m1 -E 'Using node-local|passed the NVMe' <<<"${OUT}"); $(probe_lines)"
    fi
}

# The job ran from the shared run directory after <passed> of <nodes> passed the check,
# and nothing but the check ran on the nodes' scratch.
expect_shared() {   # <what> <passed> <nodes>
    local what="$1" passed="$2" nodes="$3"
    if [ "${RC}" -eq 0 ] \
       && has "${OUT}" "${passed} of ${nodes} node(s) passed the NVMe scratch check; using the shared filesystem." \
       && has "${OUT}" "(scratch: shared; logs: " && has "${REC}" "scratch_mode=shared" \
       && ! has "${OUT}" "local scratch reclaimed" && [ "$(steps)" = probe ] \
       && [ -z "$(ls -A "${ROOT}" 2>/dev/null)" ]; then
        ok "${what}: shared filesystem (${passed} of ${nodes} passed), recorded as scratch_mode=shared"
    else
        bad "${what}: shared filesystem (${passed} of ${nodes} passed)" \
            "exit 0, shared workdir, scratch_mode=shared, only the check ran on the nodes" \
            "exit ${RC}; $(grep -m1 -E 'Using node-local|passed the NVMe' <<<"${OUT}"); steps: $(steps)"
    fi
}

echo "== auto: NVMe only where every node passes the check =="

new_case; node 1 hpc6id
scratch_job 1
expect_nvme "a real hpc6id.32xlarge /scratch" 1
expect_out "the check says what it requires, with the default minimum of 300 GiB" \
    "NVMe scratch check (SCRATCH_MODE=auto): ${ROOT} on each of the 1 node(s) must be a mount point on local NVMe instance storage, writable, with at least 300 GiB free"
expect_out "the node's verdict names the volume and its free space" \
    "  node-1 ok: ${ROOT} on local NVMe instance storage (/dev/mapper/vg.01-lv_ephemeral), 13335 GiB free"
expect_no_warning "a passing node raises no warning"

new_case; node 1 hpc6id; node 2 hpc6id; node 3 hpc6id; node 4 hpc6id
scratch_job 4
expect_nvme "four hpc6id nodes" 4
expect_out "every node answers" "  node-4 ok: ${ROOT} on local NVMe instance storage"
expect_steps "the check, the workdir, the error-log copy and the reclaim are one srun step each" \
    "probe mkdir errlogs reclaim"
if [ -n "${CALLS}" ] && ! grep -qv -- ' --ntasks=4 --ntasks-per-node=1$' <<<"${CALLS}"; then
    ok "every per-node step asks srun for one task on each of the 4 nodes"
else
    bad "srun options of the per-node steps" "--ntasks=4 --ntasks-per-node=1 on every step" "${CALLS//$'\n'/|}"
fi

# node-1 passes, node-2 is <kind> [options]; node-2's line must give <reason>, in which
# @ROOT@ stands for the case's SCRATCH_ROOT.
fallback_case() {   # <what> <reason> <kind> [option ...]
    local what="$1" reason="$2"; shift 2
    new_case; node 1 hpc6id; node 2 "$@"
    reason="${reason//@ROOT@/${ROOT}}"
    scratch_job 2
    expect_shared "${what}" 1 2
    if has "${OUT}" "  node-2 no: ${reason}"; then
        ok "${what}: the log gives node-2's reason"
    else
        bad "${what}: node-2's reason" "  node-2 no: ${reason}" "$(probe_lines)"
    fi
}

fallback_case "a plain directory on the root volume" \
    "@ROOT@ is not a mount point (a directory on another filesystem)" plain-dir
fallback_case "an EBS volume" \
    "@ROOT@ (/dev/nvme1n1) has a disk that is not local NVMe instance storage" ebs
fallback_case "a volume over an instance-store drive and an EBS volume" \
    "@ROOT@ (/dev/mapper/vg.01-lv_ephemeral) has a disk that is not local NVMe instance storage" nvme+ebs
fallback_case "tmpfs" "@ROOT@ (tmpfs) is on no local disk" tmpfs
fallback_case "an NFS mount" "@ROOT@ (192.0.2.10:/scratch) is on no local disk" nfs
fallback_case "too little space (299 GiB free, 300 needed)" \
    "@ROOT@ has 299 GiB free, under 300 GiB" hpc6id free=299
fallback_case "df fails" "cannot read the free space of @ROOT@" hpc6id no-df
fallback_case "df answers a number the shell cannot hold" \
    "cannot read the free space of @ROOT@" hpc6id df-kib=9223372036854775808

new_case; node 1 hpc6id; node 2 hpc6id free=300
scratch_job 2
expect_nvme "exactly the minimum free (300 GiB)" 2

new_case; node 1 hpc6id; node 2 hpc6id silent
scratch_job 2
expect_shared "a node that does not answer" 1 2

new_case; node 1 hpc6id; node 2 hpc6id host=node-1
scratch_job 2
expect_shared "a repeated host name (node-2 answers as node-1)" 1 2
if [ "$(grep -c '^  node-1 ok: ' <<<"${OUT}")" -eq 2 ]; then
    ok "two answers from one host count as one node"
else
    bad "two answers from one host" "2 node-1 ok lines" "$(probe_lines)"
fi

new_case; node 1 hpc6id; node 2 hpc6id
scratch_job 2 SCRATCH_ROOT="${CASE}/no-such-dir"
if [ "${RC}" -eq 0 ] && has "${OUT}" "0 of 2 node(s) passed the NVMe scratch check" \
   && has "${OUT}" "  node-2 no: ${CASE}/no-such-dir does not exist" && [ ! -e "${CASE}/no-such-dir" ]; then
    ok "a SCRATCH_ROOT that does not exist: shared filesystem, and nothing is created"
else
    bad "a SCRATCH_ROOT that does not exist" "0 of 2 passed, 'does not exist', not created" "exit ${RC}; $(probe_lines)"
fi

if [ "$(id -u)" -eq 0 ]; then
    skipt "a SCRATCH_ROOT the job user cannot write" "running as root; permissions do not apply"
else
    new_case; node 1 hpc6id; chmod 555 "${ROOT}"
    scratch_job 1
    chmod 755 "${ROOT}"
    if [ "${RC}" -eq 0 ] && has "${OUT}" "0 of 1 node(s) passed the NVMe scratch check" \
       && has "${OUT}" "  node-1 no: ${ROOT} is not writable by $(id -un)"; then
        ok "a SCRATCH_ROOT the job user cannot write: shared filesystem"
    else
        bad "a SCRATCH_ROOT the job user cannot write" "0 of 1 passed, 'is not writable'" "exit ${RC}; $(probe_lines)"
    fi
fi

# Two mounts at SCRATCH_ROOT: the one on top (listed last) is what a path there reaches.
new_case; node 1 hpc6id
printf 'tmpfs\n/dev/mapper/vg.01-lv_ephemeral\n' > "${NODES}/node-1/findmnt"
scratch_job 1
expect_nvme "two mounts, the instance-store volume on top" 1
new_case; node 1 hpc6id
printf '/dev/mapper/vg.01-lv_ephemeral\ntmpfs\n' > "${NODES}/node-1/findmnt"
scratch_job 1
if has "${OUT}" "  node-1 no: ${ROOT} (tmpfs) is on no local disk" && has "${REC}" "scratch_mode=shared"; then
    ok "two mounts, tmpfs on top: shared filesystem"
else
    bad "two mounts, tmpfs on top" "node-1 no: (tmpfs) is on no local disk" "$(probe_lines)"
fi

echo "== the free-space minimum, SCRATCH_MIN_FREE_GIB =="

new_case; node 1 hpc6id free=150
scratch_job 1 SCRATCH_MIN_FREE_GIB=100
expect_nvme "set per job: 150 GiB free, 100 needed" 1
expect_out "the check says the minimum in force" "writable, with at least 100 GiB free"

new_case; node 1 hpc6id free=1
scratch_job 1 SCRATCH_MIN_FREE_GIB=1
expect_nvme "the lowest minimum, 1 GiB" 1

new_case; node 1 hpc6id free=9999999
scratch_job 1 SCRATCH_MIN_FREE_GIB=9999999
expect_nvme "the highest minimum, 9999999 GiB, with that much free" 1
new_case; node 1 hpc6id free=9999998
scratch_job 1 SCRATCH_MIN_FREE_GIB=9999999
if has "${OUT}" "  node-1 no: ${ROOT} has 9999998 GiB free, under 9999999 GiB" && has "${REC}" "scratch_mode=shared"; then
    ok "the highest minimum, 9999999 GiB, a GiB short: shared filesystem"
else
    bad "9999999 GiB needed, 9999998 free" "node-1 no: ... under 9999999 GiB" "$(probe_lines)"
fi

new_case; node 1 hpc6id free=300
scratch_job 1 SCRATCH_MIN_FREE_GIB=
expect_nvme "an empty SCRATCH_MIN_FREE_GIB means the default" 1
expect_out "and the default is 300 GiB" "writable, with at least 300 GiB free"

# Anything but a whole number from 1 to 9999999 ends the job before any node work.
refused_minimum() {   # <value> [VAR=value ...]
    local value="$1"; shift
    new_case; node 1 hpc6id
    scratch_job 1 SCRATCH_MIN_FREE_GIB="${value}" "$@"
    if [ "${RC}" -eq 1 ] \
       && has "${ERR}" "ERROR: SCRATCH_MIN_FREE_GIB='${value}' is not a whole number of GiB" \
       && [ -z "${CALLS}" ] && [ ! -e "${CASE}/mapdl-ran" ] && [ -z "${REC}" ]; then
        ok "SCRATCH_MIN_FREE_GIB='${value}'${1:+ ($*)} ends the job before the solve (exit 1)"
    else
        bad "SCRATCH_MIN_FREE_GIB='${value}' refused" "exit 1, the ERROR, no srun step, no solve, no row" \
            "exit ${RC}; steps: $(steps); solve ran: $([ -e "${CASE}/mapdl-ran" ] && echo yes || echo no)"
    fi
}
for v in 0 00 0000000 10000000 9223372036854775808 99999999999999999999 2TB -1 1.5 ' 300' '3 00'; do
    refused_minimum "${v}"
done
refused_minimum abc SCRATCH_MODE=shared

# The probe itself never answers ok when the comparison cannot be evaluated, should it
# ever get a minimum the launcher did not check.
probe_fn="$(sed -n '/^nvme_scratch_probe() {/,/^}$/p' "${SBATCH}")"
for need in 9223372036854775808 2TB; do
    new_case; node 1 hpc6id
    out="$(env PATH="${STUBS}/bin:${PATH}" STUB_NODES="${NODES}" STUB_NODE=node-1 \
           bash -c "${probe_fn}"$'\n''nvme_scratch_probe "$@"' nvme-scratch-probe "${ROOT}" "${need}" 2>&1)"
    expected="node-1 no: cannot compare the 13335 GiB free on ${ROOT} with ${need} GiB"
    if [ "${out}" = "${expected}" ]; then
        ok "the probe answers no to a minimum it cannot compare (${need})"
    else
        bad "the probe fails closed on ${need}" "${expected}" "${out}"
    fi
done

echo "== nvme and shared =="

new_case; node 1 hpc6id; node 2 hpc6id
scratch_job 2 SCRATCH_MODE=nvme
expect_nvme "SCRATCH_MODE=nvme where every node passes" 2
expect_no_warning "SCRATCH_MODE=nvme where every node passes raises no warning"

new_case; node 1 hpc6id; node 2 plain-dir
scratch_job 2 SCRATCH_MODE=nvme
expect_shared "SCRATCH_MODE=nvme where a node fails" 1 2
if has "${ERR}" "WARNING: SCRATCH_MODE=nvme requested but '${ROOT}' is unavailable on some node; using shared filesystem."; then
    ok "SCRATCH_MODE=nvme falls back with the same WARNING as before"
else
    bad "SCRATCH_MODE=nvme fallback warning" "WARNING: SCRATCH_MODE=nvme requested but ..." "${ERR}"
fi

new_case; node 1 hpc6id; node 2 plain-dir
scratch_job 2
expect_no_warning "SCRATCH_MODE=auto falls back without a warning (normal on a type without instance store)"

new_case; node 1 hpc6id; node 2 hpc6id
scratch_job 2 SCRATCH_MODE=shared
if [ "${RC}" -eq 0 ] && [ -z "${CALLS}" ] && ! has "${OUT}" "NVMe scratch check" \
   && has "${OUT}" "(scratch: shared; logs: " && has "${REC}" "scratch_mode=shared"; then
    ok "SCRATCH_MODE=shared never checks, even where NVMe is available"
else
    bad "SCRATCH_MODE=shared" "no srun step, no check, shared workdir" "exit ${RC}; steps: $(steps)"
fi

echo "== MAPDL's error logs (file*.err) come off every node's NVMe scratch =="

expect_kept() {   # <what> <expected kept_logs>
    if [ "$(kept_logs)" = "$2" ]; then ok "$1"; else bad "$1" "$2" "$(kept_logs)"; fi
}

new_case; node 1 hpc6id errlogs=file0.err,file1.err
scratch_job 1
expect_nvme "one node with two error logs" 1
expect_kept "they land in the run directory, where a shared-filesystem run has them" \
    "file0.err=file0.err written on node-1|file1.err=file1.err written on node-1|"
expect_out "the node says how many it copied" \
    "node-1: 2 MAPDL error log(s) (file*.err) copied to ${SHARED}"
expect_steps "they are copied before the reclaim deletes the working directory" \
    "probe mkdir errlogs reclaim"
if [ -n "${SHARED}" ] && [ ! -e "${SHARED}/node-1" ]; then
    ok "no per-host directory is left when every name is unique"
else
    bad "no per-host directory left" "no ${SHARED}/node-1" "$(find "${SHARED}" -mindepth 1 -maxdepth 1 -printf '%f ')"
fi
expect_no_warning "a complete copy raises no warning"

new_case; node 1 hpc6id errlogs=file0.err,file1.err; node 2 hpc6id errlogs=file2.err,file3.err
scratch_job 2
expect_nvme "two nodes with their own error logs" 2
expect_kept "every node's error logs are kept" \
    "file0.err=file0.err written on node-1|file1.err=file1.err written on node-1|file2.err=file2.err written on node-2|file3.err=file3.err written on node-2|"

new_case; node 1 hpc6id errlogs=file0.err,file1.err; node 2 hpc6id errlogs=file1.err,file2.err
scratch_job 2
expect_nvme "two nodes that both hold a file1.err" 2
expect_kept "a name both nodes hold stays under each host: no node's copy replaces another's" \
    "file0.err=file0.err written on node-1|file2.err=file2.err written on node-2|node-1/file1.err=file1.err written on node-1|node-2/file1.err=file1.err written on node-2|"
expect_out "and the log says where they are" \
    "MAPDL error logs: 2 file(s) whose name another node also holds kept under ${SHARED}/<host>/"

new_case; node 1 hpc6id errlogs=file0.err; node 2 hpc6id errlogs=file1.err,file2.err
scratch_job 2 BLOCK_HOST_DIR=node-2
expect_nvme "a node whose copy fails: the run still succeeds, is recorded and reclaimed" 2
if has "${ERR}" "WARNING: node-2: 2 MAPDL error log(s) (file*.err) not copied" \
   && has "${ERR}" "WARNING: not every MAPDL error log (file*.err) was copied off the nodes' NVMe scratch; the reclaim deletes the rest."; then
    ok "a failed copy prints a WARNING naming the node"
else
    bad "failed copy warning" "WARNING: node-2: 2 ... not copied, and the summary WARNING" "${ERR//$'\n'/|}"
fi
expect_kept "the other node's error logs are still kept" "file0.err=file0.err written on node-1|"

new_case; node 1 hpc6id errlogs=file0.err,file1.err; node 2 hpc6id errlogs=file2.err
scratch_job 2 MAPDL_FIXTURE="${FIX}/genuine-error-column-zero.log" MAPDL_RC=2
if [ "${RC}" -eq 2 ] && [ -z "${REC}" ] && has "${OUT}" "local scratch reclaimed"; then
    ok "a failed solve on NVMe keeps its exit status (2), records no row, and is reclaimed"
else
    bad "failed solve on NVMe" "exit 2, no row, reclaimed" "exit ${RC}; recorder: ${REC:-not called}"
fi
expect_kept "a failed solve's error logs are kept from every node" \
    "file0.err=file0.err written on node-1|file1.err=file1.err written on node-1|file2.err=file2.err written on node-2|"

new_case; node 1 hpc6id; node 2 hpc6id
scratch_job 2
expect_nvme "two nodes without error logs" 2
if has "${OUT}" "node-2: 0 MAPDL error log(s) (file*.err) copied to ${SHARED}" && [ -z "$(kept_logs)" ] \
   && [ ! -e "${SHARED}/node-1" ] && [ ! -e "${SHARED}/node-2" ]; then
    ok "a node without error logs copies none, makes no directory and warns about nothing"
else
    bad "nodes without error logs" "0 copied, no file, no host directory" \
        "$(kept_logs); $(find "${SHARED}" -mindepth 1 -maxdepth 1 -printf '%f ')"
fi
expect_no_warning "and raises no warning"

new_case; node 1 hpc6id errlogs=file0.err; node 2 plain-dir
scratch_job 2
expect_shared "a run that falls back to the shared filesystem" 1 2
if ! has "${OUT}" "MAPDL error log"; then
    ok "a shared-filesystem run copies no error logs: they are already in its run directory"
else
    bad "a shared-filesystem run copies nothing" "no 'MAPDL error log' line" "$(grep 'MAPDL error log' <<<"${OUT}")"
fi

echo
printf 'nvme scratch tests: %d passed, %d failed, %d skipped\n' "${pass}" "${fail}" "${skip}"
[ "${fail}" -eq 0 ] || exit 1
