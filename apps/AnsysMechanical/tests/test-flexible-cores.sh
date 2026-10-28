#!/bin/bash
# =============================================================================
# The cores-per-node check of AnsysMechanical.sbatch (Utils/flexible-cores).
# =============================================================================
# On hpc8a.96xlarge and hpc7a.96xlarge the sbatch runs only at the cores-per-node
# counts at which the flexible-cores lists spread the ranks evenly over their 24
# CCDs: 24, 48, 72, 96, 120, 144, 168 and 192, on every node as Slurm placed the
# tasks (SLURM_TASKS_PER_NODE). Any other count there ends the job with exit 1 and
# an ERROR that names those counts and an example layout that sets --ntasks,
# before the run directory, the scratch check and the solve; above 192 the ERROR
# says the tasks exceed the node's 192 cores. A placement that is not a count is
# left to the sbatch's -machines check. Other instance types and sizes are not
# checked.
#
# The instance metadata is read with curl -fs and timeouts of 2 seconds to
# connect and 5 in all. When it gives no instance type (no answer, an HTTP error,
# or an answer that is not an instance type name, capitals included; a type name
# reads as one in any locale, a Turkish one too, where [a-z] leaves out i) and a
# node's count is outside the set, lscpu decides: a node with 192 AMD cores
# (sockets x cores per socket) could be one of those two types, so such a count is
# refused there too, by the same check with both types named and the reason; any
# other node (192 CPUs from 96 cores, 96 AMD cores on one socket, 256 on two, an
# Intel node, no lscpu) runs, with a one-line NOTE on stderr that the check was
# skipped. A supported count needs no instance type: no lscpu, no NOTE. Neither an
# HTTP error's page nor an answer that is not a type name (a proxy's page) names
# the run directory or, on local NVMe, the scratch directory.
#
# Runs the assembled launcher, as test-sbatch-e2e.sh does, with the instance
# metadata (curl), lscpu, scontrol, srun, mpirun, module, sudo, tee, hostname, the
# scratch check's findmnt, lsblk and df, mapdl and the recorder replaced by stubs.
# No Slurm, no EC2, no MPI, no licensed solver, no AWS credentials, no network.
#
#   ./tests/test-flexible-cores.sh
# =============================================================================

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIX="${HERE}/fixtures"
SBATCH="${HERE}/../AnsysMechanical.sbatch"

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"; fail=$((fail+1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# ---------------------------------------------------------------------------
# Stubs. curl, lscpu, srun, mapdl and the recorder write to the case's directory
# (STUB_STATE), so a case can tell what the job asked and whether the scratch
# check, the solve and the recording ran.
# ---------------------------------------------------------------------------
mkdir -p "${WORK}/bin"

# The instance metadata: the type in STUB_INSTANCE_TYPE (any answer, a type name
# or not). Every call is logged. STUB_IMDS gives another answer, as curl reports
# it:
#   down        no answer: the connection is refused (exit 7);
#   timeout     no answer within the call's --max-time (exit 28);
#   http-error  an HTTP error: no output and exit 22 with -f (--fail), the error
#               page and exit 0 without it.
cat > "${WORK}/bin/curl" <<'EOF'
#!/bin/bash
echo "curl $*" >> "${STUB_STATE}/curl.log"
case "${STUB_IMDS:-up}" in
  down)    exit 7 ;;
  timeout) exit 28 ;;
  http-error)
    for _a in "$@"; do
      case "${_a}" in --fail) exit 22 ;; --*) ;; -*f*) exit 22 ;; esac
    done
    echo "<html><body><h1>401 - Unauthorized</h1></body></html>"
    exit 0 ;;
esac
case "$*" in
  *api/token*)     echo "stub-token";;
  *instance-type*) printf '%s\n' "${STUB_INSTANCE_TYPE:-}";;
esac
exit 0
EOF

# lscpu: the CPUs in STUB_LSCPU, by default an Intel node with 2 sockets of 48
# cores. Every call is logged. "missing" answers as a node without lscpu;
# "amd-2x96-tree" prints the indented layout of newer util-linux releases, with
# their BIOS Vendor ID line. In a German locale (LC_ALL, else LC_MESSAGES, else
# LANG: de_DE.UTF-8) the labels are German, as lscpu prints them there.
cat > "${WORK}/bin/lscpu" <<'EOF'
#!/bin/bash
echo "lscpu $*" >> "${STUB_STATE}/lscpu.log"
_loc="${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}"
line() {   # <English label> <German label> <value>
  if [ "${_loc#de}" != "${_loc}" ]; then printf '%-24s %s\n' "$2" "$3"; else printf '%-24s %s\n' "$1" "$3"; fi
}
cpus() {   # <vendor> <sockets> <cores per socket> <threads per core>
  line "Architecture:" "Architektur:" x86_64
  line "CPU(s):" "CPU(s):" "$(( $2 * $3 * $4 ))"
  line "Vendor ID:" "Anbieterkennung:" "$1"
  line "Thread(s) per core:" "Thread(s) pro Kern:" "$4"
  line "Core(s) per socket:" "Kern(e) pro Sockel:" "$3"
  line "Socket(s):" "Sockel:" "$2"
}
case "${STUB_LSCPU:-intel-2x48}" in
  missing)      echo "lscpu: command not found" >&2; exit 127 ;;
  amd-2x96)     cpus AuthenticAMD 2 96 1 ;;
  amd-1x96)     cpus AuthenticAMD 1 96 1 ;;
  amd-2x128)    cpus AuthenticAMD 2 128 1 ;;
  amd-2x48-smt) cpus AuthenticAMD 2 48 2 ;;
  intel-2x96)   cpus GenuineIntel 2 96 1 ;;
  intel-2x48)   cpus GenuineIntel 2 48 1 ;;
  amd-2x96-tree)
    printf '%s\n' "Architecture:                x86_64" \
      "CPU(s):                      192" \
      "  On-line CPU(s) list:       0-191" \
      "Vendor ID:                   AuthenticAMD" \
      "  BIOS Vendor ID:            Advanced Micro Devices, Inc." \
      "  Model name:                AMD EPYC" \
      "    Thread(s) per core:      1" \
      "    Core(s) per socket:      96" \
      "    Socket(s):               2" ;;
esac
EOF

cat > "${WORK}/bin/scontrol" <<'EOF'
#!/bin/bash
# scontrol show hostnames=node1,node2
for a in "$@"; do
  case "$a" in hostnames=*) echo "${a#hostnames=}" | tr ',' '\n';; esac
done
EOF

# srun records its call, drops its own options and runs the step once, locally.
cat > "${WORK}/bin/srun" <<'EOF'
#!/bin/bash
echo "srun $*" >> "${STUB_STATE}/srun.log"
while [ $# -gt 0 ]; do
  case "$1" in --ntasks=*|--ntasks-per-node=*|-n|-N) shift;; *) break;; esac
done
exec "$@"
EOF

# No instance store: SCRATCH_ROOT is no mount point, so the scratch check sends the
# job to the shared filesystem. With STUB_SCRATCH=nvme, findmnt, lsblk and df answer
# for SCRATCH_ROOT what a real hpc6id.32xlarge answers for /scratch, so the job runs
# from local NVMe scratch.
cat > "${WORK}/bin/findmnt" <<EOF
#!/bin/bash
[ "\${STUB_SCRATCH:-}" = nvme ] || exit 1
cat "${FIX}/scratch-hpc6id-findmnt.txt"
EOF
cat > "${WORK}/bin/lsblk" <<EOF
#!/bin/bash
cat "${FIX}/scratch-hpc6id-lsblk.txt"
EOF
cat > "${WORK}/bin/df" <<EOF
#!/bin/bash
cat "${FIX}/scratch-hpc6id-df.txt"
EOF
printf '#!/bin/bash\necho node1\n' > "${WORK}/bin/hostname"
for c in mpirun module sudo; do printf '#!/bin/bash\nexit 0\n' > "${WORK}/bin/${c}"; done
printf '#!/bin/bash\ncat > /dev/null\n' > "${WORK}/bin/tee"

cat > "${WORK}/bin/recorder-stub.sh" <<'EOF'
#!/bin/bash
echo "ARGS: $*" >> "${STUB_STATE}/recorder.log"
exit 0
EOF
chmod +x "${WORK}"/bin/*

# fc_case <name> <instance type> <nodes> <SLURM_TASKS_PER_NODE> <tasks> [VAR=value ...]:
# run the sbatch on that layout; a clean solve when it gets that far. LC_ALL and
# LC_MESSAGES are unset unless given here, so a LANG given here is the locale.
# Sets RC, STATE (the case's directory) and BASE (its BASE_DIR).
fc_case() {
    local name="$1" itype="$2" nodes="$3" tpn="$4" ntasks="$5" i nodelist="node1"
    shift 5
    for (( i = 2; i <= nodes; i++ )); do nodelist="${nodelist},node${i}"; done
    STATE="${WORK}/${name}"; BASE="${STATE}/base"
    mkdir -p "${BASE}/ansys_inc/v261/ansys/bin" "${BASE}/inputs" "${STATE}/scratch"
    cat > "${BASE}/ansys_inc/v261/ansys/bin/mapdl" <<EOF
#!/bin/bash
echo "mapdl \$*" >> "${STATE}/mapdl.log"
outfile=""; prev=""
for a in "\$@"; do [ "\$prev" = "-o" ] && outfile="\$a"; prev="\$a"; done
[ -n "\${outfile}" ] && cp "${FIX}/normal-success.log" "\${outfile}"
exit 0
EOF
    chmod +x "${BASE}/ansys_inc/v261/ansys/bin/mapdl"
    : > "${BASE}/inputs/V26direct-5.dat"
    # Started in the case directory, so the job never writes into the checkout.
    ( cd "${STATE}" && exec env -u SCRATCH_MODE -u SCRATCH_MIN_FREE_GIB -u LC_ALL -u LC_MESSAGES \
        -u STUB_IMDS -u STUB_LSCPU -u STUB_SCRATCH \
        PATH="${WORK}/bin:${PATH}" STUB_STATE="${STATE}" STUB_INSTANCE_TYPE="${itype}" \
        DYNAMODB_RECORDER="${WORK}/bin/recorder-stub.sh" \
        MAPDL_VERDICT_LIB="${HERE}/../lib/mapdl-verdict.sh" \
        BASE_DIR="${BASE}" SCRATCH_ROOT="${STATE}/scratch" \
        SLURM_JOB_ID=96000 SLURM_JOB_NAME="AnsysMechanical.sbatch" \
        SLURM_JOB_NUM_NODES="${nodes}" SLURM_NPROCS="${ntasks}" SLURM_NTASKS="${ntasks}" \
        SLURM_JOB_NODELIST="${nodelist}" SLURM_TASKS_PER_NODE="${tpn}" \
        SLURM_SUBMIT_DIR="${HERE}/.." \
        "$@" \
        bash "${SBATCH}" v261 "${BASE}/inputs/V26direct-5.dat" ) > "${STATE}/stdout" 2> "${STATE}/stderr"
    RC=$?
}

ran() { if [ -s "$1" ]; then echo ran; else echo "did not run"; fi; }

# The ERROR when the instance type could not be read and lscpu showed 192 AMD cores:
# it names both types, and says why on the line after the first.
BOTH="hpc8a.96xlarge or hpc7a.96xlarge"
WHY="       (the instance metadata did not name the instance type, and this node has"

# refused <what> <count> <instance type, or ${BOTH}> <SLURM_TASKS_PER_NODE> [first line]:
# exit 1 with the ERROR whose first line names the count and the type (by default as an
# uneven load of the CCDs; a first line given here replaces that one, which must then be
# absent), then the placement, the supported counts and an example that sets --ntasks
# (the sbatch's header sets it, and Slurm gives it precedence over --ntasks-per-node),
# with the reason when the type is ${BOTH} and without it otherwise, and with no NOTE
# about a skipped check; all before the scratch check, the run directory, the solve and
# the recorder.
refused() {
    local what="$1" n="$2" itype="$3" tpn="$4" uneven place reason=ok
    uneven="ERROR: ${n} cores per node load the 24 CCDs of ${itype} unevenly"
    local want="${5:-${uneven}}"
    if [ "${itype}" = "${BOTH}" ]; then
        place="       192 AMD cores, as those two do; SLURM_TASKS_PER_NODE=${tpn}). On hpc8a.96xlarge and"
        grep -qxF "${WHY}" "${STATE}/stderr" || reason=missing
    else
        place="       (SLURM_TASKS_PER_NODE=${tpn}). On hpc8a.96xlarge and"
        ! grep -qF "did not name the instance type" "${STATE}/stderr" || reason=unexpected
    fi
    if [ "${RC}" -eq 1 ] && grep -qxF "${want}" "${STATE}/stderr" \
       && { [ "${want}" = "${uneven}" ] || ! grep -qF "${uneven}" "${STATE}/stderr"; } \
       && grep -qxF "${place}" "${STATE}/stderr" && [ "${reason}" = ok ] \
       && ! grep -qF "skipped" "${STATE}/stderr" \
       && grep -qF "run 24, 48, 72, 96, 120, 144, 168 or 192 cores per node," "${STATE}/stderr" \
       && grep -qF -- "e.g. --nodes=2 --ntasks=192 --ntasks-per-node=96:" "${STATE}/stderr" \
       && [ ! -s "${STATE}/srun.log" ] && ! grep -q 'NVMe scratch check' "${STATE}/stdout" \
       && [ ! -e "${BASE}/AnsysMechanical" ] && [ ! -s "${STATE}/mapdl.log" ] \
       && [ ! -s "${STATE}/recorder.log" ]; then
        ok "${what}"
    else
        bad "${what}" \
            "exit 1, '${want}', the placement line, the reason only for '${BOTH}', the supported counts and an example that sets --ntasks; no skip NOTE, scratch check, run directory, solve or row" \
            "exit ${RC}; reason ${reason}; scratch check $(ran "${STATE}/srun.log"); solve $(ran "${STATE}/mapdl.log"); stderr: $(tr '\n' '|' < "${STATE}/stderr")"
    fi
}

# skip_note <what> <yes|no>: whether the job printed the one-line NOTE that it could not
# read its instance type and skipped the check. "no" also means no other mention of a
# skipped check.
SKIP_NOTE="NOTE: the instance metadata did not name the instance type, and lscpu does not show the 192 AMD cores of hpc8a.96xlarge and hpc7a.96xlarge, so their cores-per-node check (Utils/flexible-cores) is skipped."
skip_note() {
    local got=no
    if grep -qxF "${SKIP_NOTE}" "${STATE}/stderr"; then
        got=yes
    elif grep -qF "skipped" "${STATE}/stderr"; then
        got="another form"
    fi
    if [ "${got}" = "$2" ]; then
        ok "$1"
    else
        bad "$1" "skip NOTE: $2" "skip NOTE: ${got}; stderr: $(tr '\n' '|' < "${STATE}/stderr")"
    fi
}

# lscpu_asked <what> <yes|no>: whether the job ran lscpu.
lscpu_asked() {
    local got=no
    [ -s "${STATE}/lscpu.log" ] && got=yes
    if [ "${got}" = "$2" ]; then ok "$1"; else bad "$1" "lscpu asked: $2" "lscpu asked: ${got}"; fi
}

# runs <what>: the scratch check, the solve and the recorder ran, with no refusal, and
# the job exited 0.
runs() {
    if [ "${RC}" -eq 0 ] && [ -s "${STATE}/srun.log" ] && [ -s "${STATE}/mapdl.log" ] \
       && [ -s "${STATE}/recorder.log" ] && ! grep -q 'CCDs' "${STATE}/stderr"; then
        ok "$1"
    else
        bad "$1" "exit 0; the scratch check, the solve and a row" \
            "exit ${RC}; solve $(ran "${STATE}/mapdl.log"); stderr: $(tr '\n' '|' < "${STATE}/stderr")"
    fi
}

echo "== hpc8a.96xlarge: the supported counts run, any other count is refused =="

for c in 24 48 72 96 120 144 168 192; do
    fc_case "hpc8a-1x${c}" hpc8a.96xlarge 1 "${c}" "${c}"
    runs "hpc8a.96xlarge, 1 node x ${c} cores -> runs"
done

fc_case hpc8a-2x96 hpc8a.96xlarge 2 "96(x2)" 192
runs "hpc8a.96xlarge, 2 nodes x 96 cores per node -> runs"
if grep -q -- '-machines node1:96:node2:96 ' "${STATE}/mapdl.log" \
   && grep -q -- '--cores-per-node 96' "${STATE}/recorder.log"; then
    ok "hpc8a.96xlarge, 2 x 96: -machines node1:96:node2:96, recorded at 96 cores per node"
else
    bad "hpc8a.96xlarge, 2 x 96 placement" "-machines node1:96:node2:96, --cores-per-node 96" \
        "$(cat "${STATE}/mapdl.log" 2>/dev/null) | $(cat "${STATE}/recorder.log" 2>/dev/null)"
fi
# Both requests to the instance metadata, the token and then the type, give up after 5
# seconds (2 to connect) and turn an HTTP error into no answer.
if [ "$(grep -c '^curl ' "${STATE}/curl.log")" -eq 2 ] \
   && [ "$(grep -c '^curl -fs --connect-timeout 2 --max-time 5 ' "${STATE}/curl.log")" -eq 2 ] \
   && grep -q '^curl -fs --connect-timeout 2 --max-time 5 -X PUT .*/latest/api/token' "${STATE}/curl.log" \
   && grep -q '^curl -fs --connect-timeout 2 --max-time 5 -H .*/latest/meta-data/instance-type$' "${STATE}/curl.log"; then
    ok "the instance metadata is read twice (token, type), each with curl -fs --connect-timeout 2 --max-time 5"
else
    bad "the instance metadata's two requests" "2 calls, each 'curl -fs --connect-timeout 2 --max-time 5 ...'" \
        "$(tr '\n' '|' < "${STATE}/curl.log")"
fi

for c in 16 32 64 128; do
    fc_case "hpc8a-1x${c}" hpc8a.96xlarge 1 "${c}" "${c}"
    refused "hpc8a.96xlarge, 1 node x ${c} cores -> refused before the solve, naming the supported counts" \
        "${c}" hpc8a.96xlarge "${c}"
done

fc_case hpc8a-2x64 hpc8a.96xlarge 2 "64(x2)" 128
refused "hpc8a.96xlarge, the sbatch's own 2 x 64 layout (64(x2)) -> refused" 64 hpc8a.96xlarge "64(x2)"

fc_case hpc8a-1x191 hpc8a.96xlarge 1 191 191
refused "hpc8a.96xlarge, 191 tasks on one node -> refused as an uneven load, not as more tasks than cores" \
    191 hpc8a.96xlarge 191
fc_case hpc8a-1x216 hpc8a.96xlarge 1 216 216
refused "hpc8a.96xlarge, 216 tasks on one node -> refused, as more tasks than the node's 192 cores" \
    216 hpc8a.96xlarge 216 "ERROR: 216 tasks per node exceed the 192 cores of hpc8a.96xlarge"
fc_case hpc8a-1x384 hpc8a.96xlarge 1 384 384
refused "hpc8a.96xlarge, 384 tasks on one node -> refused, as more tasks than the node's 192 cores" \
    384 hpc8a.96xlarge 384 "ERROR: 384 tasks per node exceed the 192 cores of hpc8a.96xlarge"

echo "== a heterogeneous placement: every node's count must be one of them =="

fc_case hpc8a-96-48 hpc8a.96xlarge 2 "96,48" 144
runs "hpc8a.96xlarge, 96 and 48 cores on two nodes -> runs"

fc_case hpc8a-96-64 hpc8a.96xlarge 2 "96,64" 160
refused "hpc8a.96xlarge, 96 and 64 cores on two nodes -> refused, naming 64" 64 hpc8a.96xlarge "96,64"

fc_case hpc8a-43-42 hpc8a.96xlarge 2 "43,42" 85
refused "hpc8a.96xlarge, 43 and 42 cores on two nodes -> refused, naming 43" 43 hpc8a.96xlarge "43,42"

echo "== a placement that is not a count: left to the -machines check =="

fc_case hpc8a-1xabc hpc8a.96xlarge 1 abc 96
if [ "${RC}" -eq 1 ] \
   && grep -qxF "ERROR: cannot determine the per-host task placement from Slurm." "${STATE}/stderr" \
   && ! grep -q 'CCDs' "${STATE}/stderr" && [ ! -s "${STATE}/mapdl.log" ] \
   && [ ! -s "${STATE}/recorder.log" ]; then
    ok "hpc8a.96xlarge, SLURM_TASKS_PER_NODE=abc -> refused by the -machines check, not as a core count"
else
    bad "hpc8a.96xlarge, SLURM_TASKS_PER_NODE=abc" \
        "exit 1 and the -machines ERROR (cannot determine the per-host task placement); no CCDs line, solve or row" \
        "exit ${RC}; solve $(ran "${STATE}/mapdl.log"); stderr: $(tr '\n' '|' < "${STATE}/stderr")"
fi

echo "== hpc7a.96xlarge: the same rule =="

fc_case hpc7a-1x64 hpc7a.96xlarge 1 64 64
refused "hpc7a.96xlarge, 1 node x 64 cores -> refused" 64 hpc7a.96xlarge 64

fc_case hpc7a-1x96 hpc7a.96xlarge 1 96 96
runs "hpc7a.96xlarge, 1 node x 96 cores -> runs"

fc_case hpc7a-4x48 hpc7a.96xlarge 4 "48(x4)" 192
runs "hpc7a.96xlarge, 4 nodes x 48 cores per node -> runs"

echo "== other instance types and sizes are not checked =="

fc_case hpc6id-2x64 hpc6id.32xlarge 2 "64(x2)" 128
runs "hpc6id.32xlarge, 2 nodes x 64 cores per node (the sbatch's own layout) -> runs"
skip_note "hpc6id.32xlarge: its type was read, so no NOTE about a skipped check" no
lscpu_asked "hpc6id.32xlarge: its type was read, so lscpu is not asked" no
fc_case tr-hpc6id hpc6id.32xlarge 2 "64(x2)" 128 LANG=tr_TR.UTF-8
runs "hpc6id.32xlarge in a Turkish locale, 2 nodes x 64 cores per node -> runs"
skip_note "hpc6id.32xlarge in a Turkish locale: its type reads ([a-z] tested in the C locale), so no NOTE" no
lscpu_asked "hpc6id.32xlarge in a Turkish locale: its type reads, so lscpu is not asked" no

fc_case hpc7a48-1x32 hpc7a.48xlarge 1 32 32
runs "hpc7a.48xlarge, 1 node x 32 cores -> runs"

fc_case c8i-1x64 c8i.96xlarge 1 64 64
runs "c8i.96xlarge, 1 node x 64 cores -> runs"

fc_case hpc6a-1x32 hpc6a.48xlarge 1 32 32
runs "hpc6a.48xlarge, 1 node x 32 cores -> runs"

# A type that was read is never checked by its CPUs: m7a.48xlarge has the 192 AMD cores
# of hpc8a/hpc7a.96xlarge too.
fc_case m7a-1x64 m7a.48xlarge 1 64 64 STUB_LSCPU=amd-2x96
runs "m7a.48xlarge on a 192-core AMD node, 1 node x 64 cores -> runs"
skip_note "m7a.48xlarge: its type was read, so no NOTE about a skipped check" no
lscpu_asked "m7a.48xlarge: its type was read, so lscpu is not asked" no

echo "== no instance type from the instance metadata: lscpu decides =="

fc_case imds-down-1x64 "" 1 64 64 STUB_IMDS=down
runs "no answer from the instance metadata, Intel node, 1 node x 64 cores -> runs (no list applies)"
skip_note "no answer from the instance metadata, Intel node -> the one-line NOTE says the check is skipped" yes
fc_case imds-down-1x96 "" 1 96 96 STUB_IMDS=down
runs "no answer from the instance metadata, Intel node, 1 node x 96 cores (a supported count) -> runs"
skip_note "no answer, a supported count -> nothing to check, so no NOTE" no
lscpu_asked "no answer, a supported count -> lscpu is not asked" no

fc_case imds-down-amd-1x64 "" 1 64 64 STUB_IMDS=down STUB_LSCPU=amd-2x96
refused "no answer, a 192-core AMD node, 1 node x 64 cores -> refused, naming both types and why" \
    64 "${BOTH}" 64

fc_case imds-down-amd-1x96 "" 1 96 96 STUB_IMDS=down STUB_LSCPU=amd-2x96
runs "no answer, a 192-core AMD node, 1 node x 96 cores -> runs"
skip_note "no answer, a 192-core AMD node at a supported count -> checked, so no NOTE" no

fc_case imds-down-amd-1x216 "" 1 216 216 STUB_IMDS=down STUB_LSCPU=amd-2x96
refused "no answer, a 192-core AMD node, 216 tasks on one node -> refused, as more tasks than its 192 cores" \
    216 "${BOTH}" 216 "ERROR: 216 tasks per node exceed the 192 cores of ${BOTH}"

fc_case imds-timeout-amd-1x64 "" 1 64 64 STUB_IMDS=timeout STUB_LSCPU=amd-2x96
refused "no answer within --max-time, a 192-core AMD node, 1 node x 64 cores -> refused" 64 "${BOTH}" 64

fc_case imds-http-amd-1x64 "" 1 64 64 STUB_IMDS=http-error STUB_LSCPU=amd-2x96
refused "an HTTP error from the instance metadata, a 192-core AMD node, 1 node x 64 cores -> refused" \
    64 "${BOTH}" 64

fc_case imds-http-1x64 "" 1 64 64 STUB_IMDS=http-error
runs "an HTTP error from the instance metadata, Intel node, 1 node x 64 cores -> runs"
skip_note "an HTTP error, Intel node -> the one-line NOTE says the check is skipped" yes
_run_dirs=( "${BASE}/AnsysMechanical/Run"/* )
if [ "${#_run_dirs[@]}" -eq 1 ] && [[ "${_run_dirs[0]##*/}" == 96000-1x-64-* ]]; then
    ok "an HTTP error: the run directory names no instance type (96000-1x-64-<date>), not the error page"
else
    bad "the run directory after an HTTP error" "one directory 96000-1x-64-<date>" "${_run_dirs[*]##*/Run/}"
fi

fc_case imds-other-1x64 "401 - Unauthorized" 1 64 64
runs "an instance metadata answer that is not a type name, Intel node, 1 node x 64 cores -> runs"
skip_note "an answer that is not a type name, Intel node -> the one-line NOTE says the check is skipped" yes

# A page that names a host with a dot, and a type name followed by more lines, are not a
# type name either.
PROXY_PAGE="<html><body>Request denied by proxy.example.com</body></html>"
fc_case imds-proxy-amd-1x64 "${PROXY_PAGE}" 1 64 64 STUB_LSCPU=amd-2x96
refused "a proxy page naming proxy.example.com, a 192-core AMD node, 1 node x 64 cores -> refused" \
    64 "${BOTH}" 64

fc_case imds-proxy-1x64 "${PROXY_PAGE}" 1 64 64
runs "a proxy page naming proxy.example.com, Intel node, 1 node x 64 cores -> runs"
skip_note "a proxy page naming proxy.example.com, Intel node -> the one-line NOTE says the check is skipped" yes
# An answer that is not a type name counts as none: the page does not name the run
# directory, nor, at a supported count on local NVMe, the scratch directory.
_run_dirs=( "${BASE}/AnsysMechanical/Run"/* )
if [ "${#_run_dirs[@]}" -eq 1 ] && [[ "${_run_dirs[0]##*/}" == 96000-1x-64-* ]]; then
    ok "a proxy page: the run directory names no instance type (96000-1x-64-<date>), and none of the page"
else
    bad "the run directory after a proxy page" "one directory 96000-1x-64-<date>" "${_run_dirs[*]##*/Run/}"
fi
fc_case imds-proxy-nvme-1x96 "${PROXY_PAGE}" 1 96 96 STUB_SCRATCH=nvme
runs "a proxy page, local NVMe scratch, 1 node x 96 cores (a supported count) -> runs"
skip_note "a proxy page at a supported count -> nothing to check, so no NOTE" no
lscpu_asked "a proxy page at a supported count -> lscpu is not asked" no
_want='^Execution directory is: .*/scratch/mapdl-96000-1x-96-[0-9-]+ \(scratch: nvme; logs: .*/AnsysMechanical/Run/96000-1x-96-[0-9-]+\)$'
if grep -qE -- "${_want}" "${STATE}/stdout"; then
    ok "a proxy page: the NVMe scratch and run directories name no instance type, and none of the page"
else
    bad "the NVMe scratch and run directories after a proxy page" \
        "Execution directory is: <scratch>/mapdl-96000-1x-96-<date> (scratch: nvme; logs: <base>/AnsysMechanical/Run/96000-1x-96-<date>)" \
        "$(grep '^Execution directory is:' "${STATE}/stdout")"
fi

fc_case imds-twolines-amd-1x64 $'hpc8a.96xlarge\n<html><body>proxy error</body></html>' 1 64 64 STUB_LSCPU=amd-2x96
refused "a type name followed by an HTML line, a 192-core AMD node, 1 node x 64 cores -> refused" \
    64 "${BOTH}" 64
fc_case imds-upper-amd-1x64 HPC8A.96XLARGE 1 64 64 STUB_LSCPU=amd-2x96
refused "the answer HPC8A.96XLARGE (capitals: not a type name), a 192-core AMD node, 1 node x 64 cores -> refused" \
    64 "${BOTH}" 64

echo "== no instance type: what lscpu counts =="

fc_case lscpu-smt-1x64 "" 1 64 64 STUB_IMDS=down STUB_LSCPU=amd-2x48-smt
runs "no answer, AMD with 2 x 48 cores and 2 threads per core (192 CPUs), 1 node x 64 cores -> runs"
skip_note "no answer, AMD with 96 cores and 192 CPUs -> the NOTE (cores are counted, not CPUs)" yes

fc_case lscpu-intel192-1x64 "" 1 64 64 STUB_IMDS=down STUB_LSCPU=intel-2x96
runs "no answer, an Intel node with 192 cores, 1 node x 64 cores -> runs"
skip_note "no answer, an Intel node with 192 cores -> the NOTE" yes
fc_case lscpu-amd1x96-1x64 "" 1 64 64 STUB_IMDS=down STUB_LSCPU=amd-1x96
runs "no answer, AMD with 1 socket x 96 cores, 1 node x 64 cores -> runs"
skip_note "no answer, AMD with 1 x 96 cores -> the NOTE (sockets x cores per socket must be 192)" yes
fc_case lscpu-amd2x128-1x64 "" 1 64 64 STUB_IMDS=down STUB_LSCPU=amd-2x128
runs "no answer, AMD with 2 sockets x 128 cores, 1 node x 64 cores -> runs"
skip_note "no answer, AMD with 256 cores -> the NOTE (exactly 192, not at least 192)" yes

fc_case lscpu-missing-1x64 "" 1 64 64 STUB_IMDS=down STUB_LSCPU=missing
runs "no answer and no lscpu, 1 node x 64 cores -> runs"
skip_note "no answer and no lscpu -> the NOTE" yes

fc_case lscpu-tree-amd-1x64 "" 1 64 64 STUB_IMDS=down STUB_LSCPU=amd-2x96-tree
refused "no answer, lscpu's indented layout with a BIOS Vendor ID line, 192 AMD cores, 1 node x 64 cores -> refused" \
    64 "${BOTH}" 64

fc_case lscpu-de-amd-1x64 "" 1 64 64 STUB_IMDS=down STUB_LSCPU=amd-2x96 LC_ALL=de_DE.UTF-8
refused "no answer, a 192-core AMD node in a German locale, 1 node x 64 cores -> refused (lscpu read in LC_ALL=C)" \
    64 "${BOTH}" 64

echo
printf 'flexible-cores tests: %d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ] || exit 1
