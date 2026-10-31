#!/bin/bash
# =============================================================================
# The sbatch example's cores-per-node check (Utils/flexible-cores).
# =============================================================================
# On hpc8a.96xlarge and hpc7a.96xlarge the sbatch example runs only at the
# cores-per-node counts that put the same number of ranks on each of their 24
# CCDs: 24, 48, 72, 96, 120, 144, 168 and 192. Any other count there, and ranks
# that do not divide evenly over the nodes, end the job with exit 1 and a
# message that names those counts, before the run directory exists and before
# cfx5solve starts. Other instance types and sizes are not checked.
#
# When the instance metadata gives no instance type (no answer, an error, an
# answer cut off at the time limit, or an answer that is not an instance type
# name, capitals included), lscpu decides.
# A node with 192 AMD cores could be one of those two types: such a count is
# refused there the same way, with a message that names both types and why. Any
# other node runs, with a one-line NOTE on stderr that the check was skipped.
# An instance type name reads as one in any locale, a Turkish one included,
# where [a-z] leaves out i.
#
# The test runs a copy of the example with curl (the instance metadata), lscpu,
# scontrol, cfx5solve and the recorder replaced by stubs; the copy differs from
# the script in its CFX_DIR line only, as in test-sbatch-e2e.sh. No Slurm, no
# EC2, no MPI, no licensed solver, no AWS credentials, no network.
#
#   ./tests/test-flexible-cores.sh
#   CFX_SBATCH=/path/to/CFX.sbatch ./tests/test-flexible-cores.sh   # another copy
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The sbatch example: CFX.sbatch, or CFX-mpirun.sbatch where it has that name.
SBATCH="${CFX_SBATCH:-}"
if [ -z "${SBATCH}" ]; then
    for _s in "${HERE}/../CFX.sbatch" "${HERE}/../CFX-mpirun.sbatch"; do
        if [ -f "${_s}" ]; then SBATCH="${_s}"; break; fi
    done
fi

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"; fail=$((fail+1)); }

if [ -z "${SBATCH}" ] || [ ! -f "${SBATCH}" ]; then
    echo "ERROR: no CFX sbatch example found next to ${HERE}" >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
echo "flexible-cores tests (${SBATCH#"${HERE}/../"})"

# The copy that runs: the CFX install root moved under ${CFX_TEST_ROOT}.
RUNNABLE="${WORK}/cfx-fc.sbatch"
sed 's#^CFX_DIR="/fsx/ansys_inc/#CFX_DIR="${CFX_TEST_ROOT}/ansys_inc/#' "${SBATCH}" > "${RUNNABLE}"
if [ "$(diff "${SBATCH}" "${RUNNABLE}" | grep -c '^[<>]')" = "2" ]; then
    ok "the copy differs from the script in its CFX_DIR line only"
else
    bad "the copy differs from the script in its CFX_DIR line only" "2 diff lines" \
        "$(diff "${SBATCH}" "${RUNNABLE}" | grep -c '^[<>]') diff lines"
    exit 1
fi

# ---------------------------------------------------------------------------
# Stubs
# ---------------------------------------------------------------------------
mkdir -p "${WORK}/bin" "${WORK}/root/ansys_inc/v261/CFX/bin" "${WORK}/case"
: > "${WORK}/case/perf_Test_R16.def"
# The instance metadata: the type in STUB_INSTANCE_TYPE. Every call is logged.
# STUB_IMDS gives another answer, as curl reports it:
#   down        no answer: the connection is refused (exit 7);
#   timeout     no answer within the call's --max-time (exit 28);
#   cut-off     for the instance type, its first characters (the type less
#               its last five; hpc8a.96x when STUB_INSTANCE_TYPE is empty),
#               then exit 28, as curl ends a transfer at its --max-time;
#   http-error  an HTTP error: no output and exit 22 with -f (--fail), the
#               error page and exit 0 without it;
#   not-a-type  an answer that is not an instance type name, such as a web
#               proxy's own page, which names the proxy's host (exit 0);
#   two-lines   an instance type name, then a line that ends in a host name,
#               as a proxy might add (exit 0).
# Without its ^ or its $, the type-name check would take two-lines for an
# instance type; without both, not-a-type too.
cat > "${WORK}/bin/curl" <<'EOF'
#!/bin/bash
echo "curl $*" >> "${STUB_STATE}/curl.log"
case "${STUB_IMDS:-up}" in
    down)    exit 7 ;;
    timeout) exit 28 ;;
    cut-off)
        case "$*" in
            *instance-type*) t="${STUB_INSTANCE_TYPE:-hpc8a.96xlarge}"; printf '%s' "${t%?????}"; exit 28 ;;
        esac ;;
    http-error)
        for _a in "$@"; do
            case "${_a}" in --fail) exit 22;; --*) ;; -*f*) exit 22;; esac
        done
        echo "<html><body><h1>401 - Unauthorized</h1></body></html>"
        exit 0 ;;
    not-a-type)
        echo "<html><head><title>Proxy</title></head><body>Request not allowed by proxy.example.com</body></html>"
        exit 0 ;;
    two-lines)
        printf '%s\n' "hpc8a.96xlarge" "<p>Request checked by proxy.example.com"
        exit 0 ;;
esac
case "$*" in
  *api/token*)     echo "stub-token";;
  *instance-type*) echo "${STUB_INSTANCE_TYPE:-}";;
esac
exit 0
EOF
# lscpu: the CPUs in STUB_LSCPU, default an Intel node with 2 sockets x 48
# cores. Every call is logged. "missing" answers as a node without lscpu,
# "amd-2x96-tree" in the indented layout lscpu prints on a terminal. In a
# German locale (LC_ALL, else LC_MESSAGES, else LANG: de_DE.UTF-8) the labels
# are German, as lscpu prints them there.
cat > "${WORK}/bin/lscpu" <<'EOF'
#!/bin/bash
echo "lscpu $*" >> "${STUB_STATE}/lscpu.log"
_loc="${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}"
line() {  # <English label> <German label> <value>
    if [ "${_loc#de}" != "${_loc}" ]; then printf '%-24s %s\n' "$2" "$3"; else printf '%-24s %s\n' "$1" "$3"; fi
}
cpus() {  # <vendor> <sockets> <cores per socket> <threads per core>
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
    amd-1x192)    cpus AuthenticAMD 1 192 1 ;;
    amd-1x96)     cpus AuthenticAMD 1 96 1 ;;
    amd-2x128)    cpus AuthenticAMD 2 128 1 ;;
    amd-2x48)     cpus AuthenticAMD 2 48 1 ;;
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
echo node1
EOF
cat > "${WORK}/root/ansys_inc/v261/CFX/bin/cfx5solve" <<'EOF'
#!/bin/bash
echo "cfx5solve $*" >> "${STUB_STATE}/cfx5solve.log"
exit 0
EOF
cat > "${WORK}/bin/recorder-stub.sh" <<'EOF'
#!/bin/bash
echo "recorder $*" >> "${STUB_STATE}/recorder.log"
EOF
chmod +x "${WORK}/bin/curl" "${WORK}/bin/lscpu" "${WORK}/bin/scontrol" "${WORK}/bin/recorder-stub.sh" \
         "${WORK}/root/ansys_inc/v261/CFX/bin/cfx5solve"

# run <name> <instance type> <nodes> <ranks> [VAR=value...]
# Runs the copy at that shape; sets RC and STATE.
run() {
    local name="$1" itype="$2" nodes="$3" ranks="$4"
    STATE="${WORK}/${name}"
    mkdir -p "${STATE}/base"
    (cd "${STATE}" && env PATH="${WORK}/bin:${PATH}" STUB_STATE="${STATE}" STUB_INSTANCE_TYPE="${itype}" \
        CFX_TEST_ROOT="${WORK}/root" cfxversion=v261 basedir="${STATE}/base" \
        def_file="${WORK}/case/perf_Test_R16.def" DYNAMODB_RECORDER="${WORK}/bin/recorder-stub.sh" \
        SLURM_JOB_NAME=cfx-fc.sbatch SLURM_JOB_ID=4243 SLURM_JOB_NUM_NODES="${nodes}" \
        SLURM_NPROCS="${ranks}" SLURM_NTASKS="${ranks}" SLURM_NODELIST=node1 SLURM_SUBMIT_DIR="${STATE}" \
        "${@:5}" bash "${RUNNABLE}" > "${STATE}/stdout" 2> "${STATE}/stderr")
    RC=$?
}

refused() {  # <description> <the expected ERROR line>: and no NOTE that the check was skipped
    local got; got="$(cat "${STATE}/stderr")"
    if [ "${RC}" -eq 1 ] && grep -qxF -- "$2" <<< "${got}" \
            && [ ! -e "${STATE}/cfx5solve.log" ] && [ -z "$(ls -A "${STATE}/base")" ] \
            && [ ! -e "${STATE}/recorder.log" ] \
            && ! grep -q 'cores-per-node check' "${STATE}/stdout" "${STATE}/stderr"; then
        ok "$1"
    else
        bad "$1" "exit 1, no run directory, no cfx5solve, no NOTE that the check was skipped, and: $2" \
            "exit ${RC}; cfx5solve $([ -e "${STATE}/cfx5solve.log" ] && echo ran || echo 'did not run'); stderr: ${got//$'\n'/ | }"
    fi
}
accepted() {  # <description>
    if [ "${RC}" -eq 0 ] && [ -s "${STATE}/cfx5solve.log" ] && ! grep -q '^ERROR' "${STATE}/stderr"; then
        ok "$1"
    else
        bad "$1" "exit 0, and cfx5solve ran" "exit ${RC}; stderr: $(tr '\n' '|' < "${STATE}/stderr")"
    fi
}
uneven() {  # <cores per node> <instance type>: the refusal's message
    echo "ERROR: $1 cores per node load the 24 CCDs of $2 unevenly; use 24, 48, 72, 96, 120, 144, 168 or 192 (Utils/flexible-cores). Not starting cfx5solve."
}
amd_uneven() {  # <cores per node>: the same refusal on a 192-core AMD node whose type is unknown
    echo "ERROR: $1 cores per node load the 24 CCDs of hpc8a.96xlarge or hpc7a.96xlarge unevenly (the instance metadata did not name the instance type, and this node has 192 AMD cores, as those two do); use 24, 48, 72, 96, 120, 144, 168 or 192 (Utils/flexible-cores). Not starting cfx5solve."
}
skip_note() {  # <cores per node>: the NOTE when the check is skipped
    echo "NOTE: the instance metadata did not name the instance type, and lscpu does not show the 192 AMD cores of hpc8a.96xlarge and hpc7a.96xlarge, so their cores-per-node check (Utils/flexible-cores) is skipped for $1 cores per node."
}
noted() {  # <description> <cores per node>: runs, and the NOTE is on stderr once, on one line
    if [ "${RC}" -eq 0 ] && [ -s "${STATE}/cfx5solve.log" ] && ! grep -q '^ERROR' "${STATE}/stderr" \
            && [ "$(grep -cxF -- "$(skip_note "$2")" "${STATE}/stderr")" -eq 1 ] \
            && [ "$(grep -c 'cores-per-node check' "${STATE}/stderr")" -eq 1 ] \
            && ! grep -q 'cores-per-node check' "${STATE}/stdout"; then
        ok "$1"
    else
        bad "$1" "exit 0, cfx5solve ran, and on stderr, once: $(skip_note "$2")" \
            "exit ${RC}; stderr: $(tr '\n' '|' < "${STATE}/stderr")"
    fi
}
quiet() {  # <description>: no word about the check, and no lscpu call
    if ! grep -q 'cores-per-node check' "${STATE}/stdout" "${STATE}/stderr" && [ ! -e "${STATE}/lscpu.log" ]; then
        ok "$1"
    else
        bad "$1" "no NOTE about the check, and lscpu not run" \
            "lscpu $([ -e "${STATE}/lscpu.log" ] && echo ran || echo 'not run'); stderr: $(tr '\n' '|' < "${STATE}/stderr")"
    fi
}

# ---------------------------------------------------------------------------
# 1. hpc8a.96xlarge: the supported counts run, every other count is refused.
# ---------------------------------------------------------------------------
for c in 24 48 72 96 120 144 168 192; do
    run "hpc8a-2x${c}" hpc8a.96xlarge 2 $(( 2 * c ))
    accepted "hpc8a.96xlarge, 2 nodes x ${c} cores per node -> runs"
done
for c in 16 32 64 128; do
    run "hpc8a-2x${c}" hpc8a.96xlarge 2 $(( 2 * c ))
    refused "hpc8a.96xlarge, 2 nodes x ${c} cores per node -> refused, naming the counts" \
        "$(uneven "${c}" hpc8a.96xlarge)"
done
run hpc8a-1x384 hpc8a.96xlarge 1 384
refused "hpc8a.96xlarge, 384 ranks on one node -> refused" "$(uneven 384 hpc8a.96xlarge)"
run hpc8a-3n-100 hpc8a.96xlarge 3 100
refused "hpc8a.96xlarge, 100 ranks on 3 nodes (33 or 34 per node) -> refused" "$(uneven 33-34 hpc8a.96xlarge)"
run hpc8a-2n-287 hpc8a.96xlarge 2 287
refused "hpc8a.96xlarge, 287 ranks on 2 nodes (143 and 144: one count outside the set) -> refused" \
    "$(uneven 143-144 hpc8a.96xlarge)"
# The job above stopped before the script's own metadata calls, so the log holds
# the check's two: each with curl's --connect-timeout 2 and --max-time 5, so a
# node whose instance metadata never answers waits seconds, not minutes.
STATE="${WORK}/hpc8a-2x64"
if [ "$(wc -l < "${STATE}/curl.log")" -eq 2 ] && [ "$(grep -cF -- '--connect-timeout 2 ' "${STATE}/curl.log")" -eq 2 ] \
        && [ "$(grep -cF -- '--max-time 5 ' "${STATE}/curl.log")" -eq 2 ]; then
    ok "the check's two instance metadata calls carry --connect-timeout 2 and --max-time 5"
else
    bad "the check's two instance metadata calls carry --connect-timeout 2 and --max-time 5" \
        "2 calls, each with both" "$(tr '\n' '|' < "${STATE}/curl.log")"
fi

# ---------------------------------------------------------------------------
# 2. hpc7a.96xlarge: the same rule.
# ---------------------------------------------------------------------------
run hpc7a-1x64 hpc7a.96xlarge 1 64
refused "hpc7a.96xlarge, 1 node x 64 cores -> refused" "$(uneven 64 hpc7a.96xlarge)"
run hpc7a-4x48 hpc7a.96xlarge 4 192
accepted "hpc7a.96xlarge, 4 nodes x 48 cores per node -> runs"

# ---------------------------------------------------------------------------
# 3. Other instance types and sizes are not checked, and lscpu is not asked:
#    the instance metadata named the type.
# ---------------------------------------------------------------------------
run hpc6a-2x64 hpc6a.48xlarge 2 128
accepted "hpc6a.48xlarge, 2 nodes x 64 cores per node -> runs"
quiet "hpc6a.48xlarge -> no NOTE, and lscpu not run"
run hpc7a48-1x32 hpc7a.48xlarge 1 32
accepted "hpc7a.48xlarge, 1 node x 32 cores -> runs"
quiet "hpc7a.48xlarge -> no NOTE, and lscpu not run"
run c8i-1x64 c8i.96xlarge 1 64
accepted "c8i.96xlarge, 1 node x 64 cores -> runs"
quiet "c8i.96xlarge -> no NOTE, and lscpu not run"
run m7a-1x64 m7a.48xlarge 1 64 STUB_LSCPU=amd-2x96
accepted "m7a.48xlarge, named by the instance metadata, on 192 AMD cores, 1 node x 64 cores -> runs"
quiet "m7a.48xlarge -> no NOTE, and lscpu not run"
run tr-c8i-1x64 c8i.96xlarge 1 64 LC_ALL= LC_CTYPE= LC_COLLATE= LANG=tr_TR.UTF-8
accepted "c8i.96xlarge, a Turkish locale, 1 node x 64 cores -> runs"
quiet "c8i.96xlarge, a Turkish locale -> no NOTE, and lscpu not run"

# ---------------------------------------------------------------------------
# 4. No instance type from the instance metadata, on a node without 192 AMD
#    cores (lscpu: Intel, 2 sockets x 48 cores, unless set): runs, with a NOTE.
#    A supported count needs no instance type.
# ---------------------------------------------------------------------------
for imds in down timeout cut-off http-error not-a-type two-lines; do
    run "noread-${imds}-2x64" "" 2 128 STUB_IMDS="${imds}"
    noted "instance metadata ${imds}, an Intel node, 2 nodes x 64 cores per node -> runs, with the NOTE" 64
done
run noread-down-2x96 "" 2 192 STUB_IMDS=down
accepted "no instance metadata, 2 nodes x 96 cores per node (a supported count) -> runs"
quiet "no instance metadata, 2 nodes x 96 cores per node -> no NOTE, and lscpu not run"
for spec in "amd-2x48:AMD, 2 sockets x 48 cores" "amd-2x48-smt:AMD, 192 CPUs from 96 cores x 2 threads" \
            "amd-1x96:AMD, 1 socket x 96 cores" "amd-2x128:AMD, 2 sockets x 128 cores" \
            "intel-2x96:Intel, 2 sockets x 96 cores" "missing:no lscpu"; do
    run "noread-${spec%%:*}-2x64" "" 2 128 STUB_IMDS=down STUB_LSCPU="${spec%%:*}"
    noted "no instance metadata, ${spec#*:}, 2 nodes x 64 cores per node -> runs, with the NOTE" 64
done

# ---------------------------------------------------------------------------
# 5. No instance type from the instance metadata, on a node with 192 AMD cores,
#    which could be hpc8a.96xlarge or hpc7a.96xlarge: the same rule, and the
#    same refusal, naming both types and why.
# ---------------------------------------------------------------------------
for imds in down timeout cut-off http-error not-a-type two-lines; do
    run "amd-${imds}-2x64" "" 2 128 STUB_IMDS="${imds}" STUB_LSCPU=amd-2x96
    refused "instance metadata ${imds}, AMD 2 sockets x 96 cores, 2 nodes x 64 cores per node -> refused" \
        "$(amd_uneven 64)"
done
run amd-down-2x96 "" 2 192 STUB_IMDS=down STUB_LSCPU=amd-2x96
accepted "no instance metadata, AMD 2 sockets x 96 cores, 2 nodes x 96 cores per node -> runs"
quiet "no instance metadata, AMD 2 sockets x 96 cores, 2 nodes x 96 cores per node -> no NOTE, and lscpu not run"
run amd-down-287 "" 2 287 STUB_IMDS=down STUB_LSCPU=amd-2x96
refused "no instance metadata, AMD 2 sockets x 96 cores, 287 ranks on 2 nodes -> refused" "$(amd_uneven 143-144)"
run amd-tree-2x64 "" 2 128 STUB_IMDS=down STUB_LSCPU=amd-2x96-tree
refused "no instance metadata, AMD 2 sockets x 96 cores in lscpu's indented layout -> refused" "$(amd_uneven 64)"
run amd-1x192-2x64 "" 2 128 STUB_IMDS=down STUB_LSCPU=amd-1x192
refused "no instance metadata, AMD 1 socket x 192 cores -> refused" "$(amd_uneven 64)"
run amd-upper-2x64 HPC8A.96XLARGE 2 128 STUB_LSCPU=amd-2x96
refused "the answer HPC8A.96XLARGE (capitals: not an instance type name), AMD 2 sockets x 96 cores -> refused" \
    "$(amd_uneven 64)"
run amd-de-2x64 "" 2 128 STUB_IMDS=down STUB_LSCPU=amd-2x96 LC_ALL=de_DE.UTF-8
refused "no instance metadata, AMD 2 sockets x 96 cores, a German locale (lscpu is read in the C locale) -> refused" \
    "$(amd_uneven 64)"

echo
printf 'flexible-cores tests: %d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ]
