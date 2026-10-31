#!/bin/bash
# =============================================================================
# Shared by the tests of x86/Fluent-Benchmark.2026R1.sbatch: source it.
# =============================================================================
# It defines the PASS/FAIL counters, writes the stubs, and defines run_2026r1,
# which runs the script ASSEMBLED, in an empty environment (env -i) whose PATH
# starts with the stubs:
#   curl      IMDS: a token, then STUB_INSTANCE_TYPE as the instance type (and
#             STUB_INSTANCE_ID as the instance id); it logs the arguments of
#             each call, and STUB_IMDS=no-answer, http-error or cut-off stands
#             for metadata that gives no answer, an HTTP error, or an answer
#             cut off at the time limit
#   lscpu     the summary of a node with STUB_CPU="<vendor id> <sockets>
#             <cores per socket> [<threads per core>] [indented]" (default
#             "AuthenticAMD 2 96", one thread per core), or none, with German
#             keys in a German locale; it logs each call
#   scontrol  `scontrol show nodes`: one record per node of STUB_NODES
#   srun      records its arguments and runs nothing (the cache drop, THP)
#   module, sudo
#             do nothing
#   mpirun    answers `mpirun --version` as Intel MPI and runs nothing else
#   aws       refuses every call
# Fluent's bundled Python, which the script starts with the 2026 R1 harness,
# is a stub too: it records its arguments, writes STUB_TRANSCRIPT where the
# harness writes its transcript of the case and core count
# (working/<tag>/transcript/<case>-<cores>.trn, and a copy in
# working/<tag>/<case>/), and exits with STUB_HARNESS_RC.
#
# The recorder is recorder-stub, which logs its arguments and the variables
# the script passes, or real-recorder: this directory's recorder in --dry-run,
# which prints the item it would store and writes nothing.
#
# No Slurm, no EC2, no Fluent, no MPI, no AWS credentials, no network: the
# stubs run nothing on the host, and HOME is a temporary directory.
#
# FLUENT_2026R1_SBATCH=/path/to/a/copy runs the tests on another copy.
# =============================================================================
HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLUENT_APP="$(cd "${HELPERS_DIR}/.." && pwd)"
FIX="${HELPERS_DIR}/fixtures"
SBATCH="${FLUENT_2026R1_SBATCH:-${FLUENT_APP}/x86/Fluent-Benchmark.2026R1.sbatch}"

pass=0; fail=0; skip=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"; fail=$((fail+1)); }
skipt(){ printf '  \033[33mSKIP\033[0m %s (%s)\n' "$1" "$2"; skip=$((skip+1)); }
summary() {  # <suite name>: print the counts; the exit status is the suite's
    echo
    printf '%s: %d passed, %d failed, %d skipped\n' "$1" "${pass}" "${fail}" "${skip}"
    [ "${fail}" -eq 0 ]
}
# has_line <text> <line>: the text has exactly that line
has_line() { grep -qxF -- "$2" <<< "$1"; }

if [ ! -f "${SBATCH}" ]; then
    echo "ERROR: no script at ${SBATCH}" >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/bin"

# ---------------------------------------------------------------------------
# Stubs
# ---------------------------------------------------------------------------
cat > "${WORK}/bin/curl" <<'EOF'
#!/bin/bash
# IMDS: the token request, then the instance-type lookup (STUB_INSTANCE_TYPE)
# or the instance-id lookup (STUB_INSTANCE_ID, i-0123456789abcdef0 if unset).
# Nothing else answers. Logs the arguments of each call to curl.log.
#   STUB_IMDS=no-answer   no answer within curl's time limit: no output, exit 28
#   STUB_IMDS=http-error  an HTTP 401 for the instance type or id, which curl -f
#                         (alone or in a group, such as -fs) or --fail turns
#                         into no output and exit 22, and plain curl into the
#                         error page and exit 0
#   STUB_IMDS=cut-off     for the instance type or id, its first characters
#                         (the answer less its last five), then exit 28, as
#                         curl ends a transfer at its time limit
printf '%s\n' "$*" >> "${STUB_STATE}/curl.log"
[ "${STUB_IMDS:-}" = no-answer ] && exit 28
case "$*" in
    *api/token*)     echo "stub-token" ;;
    *instance-type*|*instance-id*)
        case "$*" in
            *instance-type*) answer="${STUB_INSTANCE_TYPE-}" ;;
            *)               answer="${STUB_INSTANCE_ID-i-0123456789abcdef0}" ;;
        esac
        if [ "${STUB_IMDS:-}" = http-error ]; then
            for a in "$@"; do case "${a}" in --fail) exit 22 ;; --*) ;; -*f*) exit 22 ;; esac; done
            printf '%s' "<html><title>401 - Unauthorized</title></html>"
        elif [ "${STUB_IMDS:-}" = cut-off ]; then
            printf '%s' "${answer%?????}"
            exit 28
        else
            printf '%s' "${answer}"
        fi ;;
esac
exit 0
EOF
cat > "${WORK}/bin/lscpu" <<'EOF'
#!/bin/bash
# lscpu's summary for a node with STUB_CPU="<vendor id> <sockets> <cores per
# socket> [<threads per core>] [indented]", one thread per core unless given:
# flat, as util-linux 2.37 prints it into a pipe, or indented, as it prints it
# on a terminal. A BIOS vendor line follows the vendor's, as when lscpu can
# read the DMI tables. In a German locale (LC_ALL, else LC_MESSAGES, else
# LANG) the keys are German, as util-linux 2.37 translates them.
# STUB_CPU=none: no output, exit 1. Logs each call to lscpu.log.
printf '%s\n' "lscpu $*" >> "${STUB_STATE}/lscpu.log"
read -r vendor sockets cores more <<< "${STUB_CPU:-AuthenticAMD 2 96}"
[ "${vendor}" = none ] && exit 1
threads=1; i=""
for w in ${more}; do case "${w}" in indented) i="  " ;; *) threads="${w}" ;; esac; done
cpus=$((sockets * cores * threads))
de=""; case "${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}" in de|de[_.@]*) de=1 ;; esac
line() {  # <indent> <English key> <German key> <value>: one line, in the locale's language
    if [ -n "${de}" ]; then printf '%s%-33s%s\n' "$1" "$3" "$4"; else printf '%s%-33s%s\n' "$1" "$2" "$4"; fi
}
line ""         "Architecture:"        "Architektur:"             x86_64
line "${i}"     "CPU op-mode(s):"      "CPU Operationsmodus:"     "32-bit, 64-bit"
line "${i}"     "Byte Order:"          "Byte-Reihenfolge:"        "Little Endian"
line ""         "CPU(s):"              "CPU(s):"                  "${cpus}"
line "${i}"     "On-line CPU(s) list:" "Liste der Online-CPU(s):" "0-$((cpus - 1))"
line ""         "Vendor ID:"           "Anbieterkennung:"         "${vendor}"
line "${i}"     "BIOS Vendor ID:"      "BIOS-Anbieterkennung:"    "Amazon EC2"
line "${i}"     "Model name:"          "Modellname:"              synthetic
line "${i}${i}" "Thread(s) per core:"  "Thread(s) pro Kern:"      "${threads}"
line "${i}${i}" "Core(s) per socket:"  "Kern(e) pro Sockel:"      "${cores}"
line "${i}${i}" "Socket(s):"           "Sockel:"                  "${sockets}"
EOF
cat > "${WORK}/bin/scontrol" <<'EOF'
#!/bin/bash
# `scontrol show nodes <list>`: one record per node of STUB_NODES, as Slurm prints them.
for n in ${STUB_NODES:-node1 node2}; do
    echo "NodeName=${n} Arch=x86_64 CoresPerSocket=96"
    echo "   NodeAddr=${n} NodeHostName=${n} Version=25.05.0"
done
EOF
cat > "${WORK}/bin/srun" <<'EOF'
#!/bin/bash
# Records its arguments and runs nothing: the script's cache drop and THP setting.
printf '%s\n' "$*" >> "${STUB_STATE}/srun.log"
exit 0
EOF
cat > "${WORK}/bin/mpirun" <<'EOF'
#!/bin/bash
# Answers `mpirun --version` as Intel MPI does, and runs nothing else.
if [ "${1:-}" = "--version" ]; then
    echo "Intel(R) MPI Library for Linux* OS, Version 2021.18 Build 20260101 (id: 0)"
    exit 0
fi
printf '%s\n' "$*" >> "${STUB_STATE}/mpirun.log"
exit 0
EOF
printf '#!/bin/bash\nexit 0\n' > "${WORK}/bin/module"
printf '#!/bin/bash\nexit 0\n' > "${WORK}/bin/sudo"
cat > "${WORK}/bin/aws" <<'EOF'
#!/bin/bash
# Refuses every call, so that no test can reach AWS.
printf '%s\n' "$*" >> "${STUB_STATE}/aws.log"
echo "aws stub: refused" >&2
exit 1
EOF
cat > "${WORK}/bin/harness-python" <<'EOF'
#!/bin/bash
# Fluent's bundled Python, started as `python fluent_benchmark_gpu.py <arguments>`:
# records its arguments and working directory, writes STUB_TRANSCRIPT where the
# 2026 R1 harness writes its transcript of the case and core count
# (STUB_TRANSCRIPT_NAME names it otherwise), STUB_FLUENT_TRANSCRIPT as Fluent's
# own transcript, and exits with STUB_HARNESS_RC.
printf '%s\n' "$@" > "${STUB_STATE}/harness.args"
pwd > "${STUB_STATE}/harness.cwd"
cores=""; cases=""; prev=""
for a in "$@"; do
    case "${prev}" in -cores) cores="${a}" ;; -cases) cases="${a}" ;; esac
    prev="${a}"
done
tag="10-26-2026=12-00-00"
mkdir -p "working/${tag}/transcript" "working/${tag}/${cases}"
if [ -n "${STUB_TRANSCRIPT:-}" ]; then
    name="${STUB_TRANSCRIPT_NAME:-${cases}-${cores}.trn}"
    cp "${STUB_TRANSCRIPT}" "working/${tag}/transcript/${name}"
    cp "${STUB_TRANSCRIPT}" "working/${tag}/${cases}/${name}"
fi
if [ -n "${STUB_FLUENT_TRANSCRIPT:-}" ]; then
    cp "${STUB_FLUENT_TRANSCRIPT}" "working/${tag}/${cases}/fluent-20261026-120000-1000.trn"
fi
echo "[stub harness] ${cases} on ${cores} cores"
exit "${STUB_HARNESS_RC:-0}"
EOF
cat > "${WORK}/bin/recorder-stub" <<'EOF'
#!/bin/bash
# Logs how the script called the recorder: each argument, then the variables it passes.
{
    echo "CALL"
    for a in "$@"; do echo "ARG ${a}"; done
    for v in FLUENT_VERSION RUN_DIR BENCHMARK_CASE BENCHMARK_METHOD SOLVER_MODE NUM_ITERATIONS MIUPS; do
        echo "${v}=${!v-}"
    done
} >> "${STUB_STATE}/recorder.log"
echo "[stub recorder] called"
exit 0
EOF
cat > "${WORK}/bin/real-recorder" <<EOF
#!/bin/bash
# This directory's recorder in --dry-run: prints the item it would store, writes nothing.
"${FLUENT_APP}/dynamodb/record-benchmark.sh" --dry-run --no-put --source E2ETest "\$@" \\
    > "\${STUB_STATE}/recorder.json" 2>> "\${STUB_STATE}/recorder.err"
EOF
chmod +x "${WORK}"/bin/*

# ---------------------------------------------------------------------------
# run_2026r1 <name> [VAR=value ...]
# Runs the script from a new directory as a 2-node job of 384 ranks on
# hpc8a.96xlarge, with BENCHMARK_NAME=sedan_4m, ITERATIONS=25 and
# WARMUP_ITERATIONS=10, the harness writing fixtures/steady-25-iterations.trn,
# and the recorder stub. Each VAR=value replaces one of these settings or adds
# a variable; VAR= sets it empty, which the script reads as not set. RUN_URI
# is the script's second argument (default: shipped, no staging).
# Sets OUT and ERR (the job's output and error streams), RC (its exit status),
# STATE (the case's directory, with the stubs' logs) and WORKDIR (the run
# directory the job printed).
# ---------------------------------------------------------------------------
# shellcheck disable=SC2034  # the test files read RC, ERR and WORKDIR
run_2026r1() {
    local name="$1"; shift
    STATE="${WORK}/${name}"
    local pydir="${STATE}/ansys/ansys_inc/v261/commonfiles/CPython/3_10/linx64/Release/python/bin"
    mkdir -p "${STATE}/home" "${STATE}/base" "${STATE}/submit" "${pydir}"
    cp "${WORK}/bin/harness-python" "${pydir}/python"
    OUT="$(cd "${STATE}" && env -i \
        PATH="${WORK}/bin:/usr/bin:/bin" HOME="${STATE}/home" LANG=C \
        STUB_STATE="${STATE}" STUB_INSTANCE_TYPE=hpc8a.96xlarge STUB_NODES="node1 node2" \
        STUB_TRANSCRIPT="${FIX}/steady-25-iterations.trn" \
        BASE_DIR="${STATE}/base" ANSYS_ROOT="${STATE}/ansys" \
        DYNAMODB_RECORDER="${WORK}/bin/recorder-stub" \
        BENCHMARK_NAME=sedan_4m ITERATIONS=25 WARMUP_ITERATIONS=10 \
        SLURM_JOB_NAME=fluent-e2e.sbatch SLURM_JOB_ID=4242 SLURM_JOBID=4242 \
        SLURM_JOB_NUM_NODES=2 SLURM_NPROCS=384 SLURM_NTASKS=384 \
        SLURM_NODELIST='node[1-2]' SLURM_SUBMIT_DIR="${STATE}/submit" \
        "$@" \
        bash "${SBATCH}" v261 "${RUN_URI:-shipped}" 2> "${STATE}/stderr")"
    RC=$?
    ERR="$(cat "${STATE}/stderr")"
    WORKDIR="$(printf '%s\n' "${OUT}" | sed -n 's/^Execution directory is: //p')"
}

# recorder_calls: how many times the recorder stub was called in the last run
recorder_calls() {
    if [ -f "${STATE}/recorder.log" ]; then grep -c '^CALL$' "${STATE}/recorder.log"; else echo 0; fi
}
# recorder_has <line>: the recorder stub logged that line in the last run
recorder_has() { grep -qxF -- "$1" "${STATE}/recorder.log" 2>/dev/null; }
