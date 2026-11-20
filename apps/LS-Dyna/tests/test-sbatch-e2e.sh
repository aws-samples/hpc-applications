#!/bin/bash
# =============================================================================
# End-to-end test of LS-Dyna.sbatch as written
# =============================================================================
# Runs the real script with stubbed scheduler, IMDS, MPI and solver, so the whole
# script executes: the shape and pinning checks, the licence, the run directory
# and its pfile, the node preparation, the solver call, the termination verdict,
# the recorder call and the exit status. Every case runs in a clean environment.
#
# No Slurm, no EC2, no MPI, no licensed solver, no AWS credentials, no network.
#
#   ./tests/test-sbatch-e2e.sh
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$(cd "${HERE}/.." && pwd)"
SBATCH="${APP}/LS-Dyna.sbatch"

pass=0; fail=0; skip=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"; fail=$((fail+1)); }
skipt() { printf '  \033[33mSKIP\033[0m %s (%s)\n' "$1" "$2"; skip=$((skip+1)); }
# A Turkish-locale case checks something only where tr_TR.UTF-8 is installed:
# elsewhere bash falls back to the C locale, where [a-z] holds i anyway. There
# run_case skips such a case, with a SKIP line, and is, has and hasnt skip its
# checks, up to the next run_case.
TR=""
if grep -qiE '^tr_TR\.utf-?8$' <<< "$(locale -a 2>/dev/null)"; then TR=1; fi
SKIPPED=""
is()  { [ -z "${SKIPPED}" ] || return 0; if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$3" "$2"; fi; }
has() { [ -z "${SKIPPED}" ] || return 0; if grep -qF -- "$3" "$2" 2>/dev/null; then ok "$1"; else bad "$1" "a line with: $3" "$(cat "$2" 2>/dev/null)"; fi; }
hasnt() { [ -z "${SKIPPED}" ] || return 0; if grep -qF -- "$3" "$2" 2>/dev/null; then bad "$1" "no line with: $3" "$(grep -F -- "$3" "$2")"; else ok "$1"; fi; }

# Resolved, as the script resolves its run directory (readlink).
T="$(readlink -f "$(mktemp -d)")"
trap 'rm -rf "${T}"' EXIT
mkdir -p "${T}/bin"

# --- Stubs ------------------------------------------------------------------------------
cat > "${T}/bin/module" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "${T}/bin/srun" <<'EOF'
#!/bin/bash
# Drop srun's own options and run the command once, here.
while [ $# -gt 0 ]; do
  case "$1" in --*=*|-n|-N) shift ;; *) break ;; esac
done
echo "srun: $*" >> "${STUB_LOG}"
exec "$@"
EOF
cat > "${T}/bin/sudo" <<'EOF'
#!/bin/bash
cat > /dev/null
EOF
cat > "${T}/bin/curl" <<'EOF'
#!/bin/bash
# IMDS: a token, then the instance type (STUB_ITYPE; empty means IMDS does not answer).
# STUB_ITYPE_EXIT is the instance-type request's exit status after its answer: 28,
# curl's at its --max-time, makes STUB_ITYPE an answer cut off at that limit.
[ -n "${STUB_ITYPE:-}" ] || exit 28
case "$*" in
  *api/token*)     echo stub-token ;;
  *instance-type*) echo "${STUB_ITYPE}"; exit "${STUB_ITYPE_EXIT:-0}" ;;
esac
EOF
cat > "${T}/bin/lscpu" <<'EOF'
#!/bin/bash
# lscpu -p=CORE,SOCKET: one line per core (STUB_CORES of them, SMT off). lscpu with no
# option: the summary's vendor, cores per socket and sockets, as util-linux 2.37 prints
# them, for the CPU STUB_CPU names ("<vendor> <sockets> <cores per socket>", by default
# "AuthenticAMD 2 96", as on hpc8a/hpc7a.96xlarge). In a German locale (LC_ALL, else
# LC_MESSAGES, else LANG: de_DE.UTF-8) the labels are German, as lscpu prints them there.
# Every call goes to the case's log with its arguments: "lscpu: -p=CORE,SOCKET", or
# "lscpu:" for the summary.
echo "lscpu:${*:+ $*}" >> "${STUB_LOG}"
if [ "$#" -gt 0 ]; then
  echo "# CORE,SOCKET"
  for ((i = 0; i < ${STUB_CORES:-192}; i++)); do echo "${i},$(( i * 2 / ${STUB_CORES:-192} ))"; done
  exit 0
fi
read -r vendor sockets per_socket <<< "${STUB_CPU:-AuthenticAMD 2 96}"
case "${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}" in
  de|de[_.@]*)
    printf '%-26s%s\n' "Architektur:" x86_64 "CPU(s):" "$(( sockets * per_socket ))" \
        "Anbieterkennung:" "${vendor}" "  BIOS-Anbieterkennung:" "Amazon EC2" "  Modellname:" "stub CPU" \
        "    Thread(s) pro Kern:" 1 "    Kern(e) pro Sockel:" "${per_socket}" "    Sockel:" "${sockets}"
    exit 0 ;;
esac
printf '%-26s%s\n' "Architecture:" x86_64 "CPU(s):" "$(( sockets * per_socket ))" \
    "Vendor ID:" "${vendor}" "  BIOS Vendor ID:" "Amazon EC2" "  Model name:" "stub CPU" \
    "    Thread(s) per core:" 1 "    Core(s) per socket:" "${per_socket}" "    Socket(s):" "${sockets}"
EOF
cat > "${T}/bin/mpirun" <<'EOF'
#!/bin/bash
# Logs its arguments and the settings the ranks get, then writes what LS-DYNA would
# (STUB_TERMINATION normal|error|none) and exits STUB_MPI_RC.
{
  echo "ARGS: $*"
  echo "LSTC_LICENSE=${LSTC_LICENSE:-}"
  echo "LSTC_RSH=${LSTC_RSH-<unset>}"
  echo "LSTC_MEMORY=${LSTC_MEMORY:-}"
  echo "I_MPI_PIN=${I_MPI_PIN:-}"
  echo "I_MPI_PIN_PROCESSOR_LIST=${I_MPI_PIN_PROCESSOR_LIST:-<unset>}"
  echo "I_MPI_PIN_ORDER=${I_MPI_PIN_ORDER:-<unset>}"
  echo "I_MPI_FABRICS=${I_MPI_FABRICS:-} I_MPI_OFI_PROVIDER=${I_MPI_OFI_PROVIDER:-}"
  echo "LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-}"
  echo "PWD=${PWD}"
} >> "${STUB_LOG}"
cat > d3hsp <<'D3'
     |  Version : mpp s R13                              |
     |  Revision: R13.1-138-g8429c8a10f                  |
D3
case "${STUB_TERMINATION:-normal}" in
  normal) printf ' N o r m a l    t e r m i n a t i o n   01/01/26 00:00:00\n Elapsed time    1234 seconds for    5678 cycles using   144 MPP procs\n' | tee -a d3hsp ;;
  error)  printf ' E r r o r   t e r m i n a t i o n   01/01/26 00:00:00\n' | tee -a d3hsp ;;
esac
exit "${STUB_MPI_RC:-0}"
EOF
cat > "${T}/bin/recorder" <<'EOF'
#!/bin/bash
{
  echo "RECORDED: $*"
  echo "LSDYNA_VERSION=${LSDYNA_VERSION:-} BENCHMARK_CASE=${BENCHMARK_CASE:-} TIME_TO_SOLUTION=${TIME_TO_SOLUTION:-}"
  echo "NUM_CORES=${NUM_CORES:-} NUM_INSTANCES=${NUM_INSTANCES:-} CORES_PER_NODE=${CORES_PER_NODE:-}"
} >> "${STUB_LOG}"
EOF
chmod +x "${T}/bin/"*

# --- Two solvers (LSTC's naming and Ansys's install tree) and a model -------------------
LSTC_DIR="${T}/sw/ls-dyna_mpp_s_R13_1_0_x64_centos78_ifort190_avx2_intelmpi-2018"
LSTC="${LSTC_DIR}/ls-dyna_mpp_s_R13_1_0_x64_centos78_ifort190_avx2_intelmpi-2018"
ANSYS="${T}/ansys_inc/v261/ansys/bin/linx64/lsdyna_sp_mpp.e"
mkdir -p "${LSTC_DIR}" "$(dirname "${ANSYS}")" "${T}/model"
printf '#!/bin/bash\n' > "${LSTC}"; printf '#!/bin/bash\n' > "${ANSYS}"; chmod +x "${LSTC}" "${ANSYS}"
printf '*KEYWORD\n*INCLUDE\ncar1.k\n*END\n' > "${T}/model/deck.k"
printf '*KEYWORD\n*END\n' > "${T}/model/car1.k"
cp "${HERE}/fixtures/pfile-3cars-32" "${T}/model/model.pfile"

# run_case <name> [VAR=value ...] -- <script arguments>: the script in a clean
# environment as one Slurm job; its output in ${T}/<name>.out, the stubs' log in
# ${T}/<name>.log, its exit status in RC.
run_case() {
    local name="$1"; shift
    local -a vars=()
    while [ "$1" != "--" ]; do vars+=("$1"); shift; done
    shift
    local v
    SKIPPED=""
    for v in "${vars[@]+"${vars[@]}"}"; do
        case "${v}" in
            *=tr_TR.UTF-8) [ -n "${TR}" ] || { SKIPPED=1; skipt "the case ${name}, in a Turkish locale" "the tr_TR.UTF-8 locale is not installed"; return 0; } ;;
        esac
    done
    rm -f "${T}/${name}.log"; : > "${T}/${name}.log"
    env -i HOME="${T}" PATH="${T}/bin:/usr/bin:/bin" STUB_LOG="${T}/${name}.log" \
        SLURM_JOB_ID=4242 SLURM_JOB_NAME=LS-Dyna.sbatch SLURM_JOB_NUM_NODES=1 \
        SLURM_NTASKS_PER_NODE=144 SLURM_TASKS_PER_NODE=144 SLURM_SUBMIT_DIR="${T}" \
        LSDYNA_LIB="${APP}/lib/lsdyna-run.sh" BASE_DIR="${T}/runs-${name}" \
        DYNAMODB_RECORDER="${T}/bin/recorder" STUB_ITYPE=hpc8a.96xlarge STUB_CORES=192 \
        ANSYSLMD_LICENSE_FILE=1055@licence-host \
        "${vars[@]+"${vars[@]}"}" bash "${SCRIPT:-${SBATCH}}" "$@" > "${T}/${name}.out" 2>&1
    RC=$?
}
workdir_of() { find "${T}/runs-$1" -mindepth 4 -maxdepth 4 -type d | head -1; }

echo "== 1 x hpc8a.96xlarge at 144 ranks per node, an LSTC build, an Ansys licence =="
run_case lstc144 -- "${LSTC}" "${T}/model/deck.k"
L="${T}/lstc144.log"; W="$(workdir_of lstc144)"
is "exit 0" "${RC}" "0"
has "mpirun: 144 ranks, 144 per node, the deck and the run's pfile" "${L}" "ARGS: -np 144 -ppn 144 ${LSTC} i=deck.k p=run.pfile"
has "the flexible-cores list for 144" "${L}" "I_MPI_PIN_PROCESSOR_LIST=0,1,2,3,4,5,8,9,10,11,12,13,16,"
has "no pin order beside the list" "${L}" "I_MPI_PIN_ORDER=<unset>"
has "Intel MPI over EFA" "${L}" "I_MPI_FABRICS=shm:ofi I_MPI_OFI_PROVIDER=efa"
has "LSTC_LICENSE=ansys" "${L}" "LSTC_LICENSE=ansys"
has "LSTC_RSH: ssh" "${L}" "LSTC_RSH=ssh -x -o BatchMode=yes -o ConnectTimeout=10"
has "LSTC_MEMORY=auto" "${L}" "LSTC_MEMORY=auto"
has "an LSTC build's directory first on LD_LIBRARY_PATH" "${L}" "LD_LIBRARY_PATH=${LSTC_DIR}"
has "page cache and THP set on every node" "${L}" "srun: /bin/bash -c sync && echo 3 | sudo tee /proc/sys/vm/drop_caches"
has "the local directory made on every node" "${L}" "srun: mkdir -p ${W}/local"
is "the deck's include linked into the run directory" "$(readlink "${W}/car1.k")" "${T}/model/car1.k"
has "recorded with LS-DYNA's own elapsed time and version" "${L}" "LSDYNA_VERSION=R13.1 BENCHMARK_CASE=deck TIME_TO_SOLUTION=1234"
has "recorded with the shape" "${L}" "NUM_CORES=144 NUM_INSTANCES=1 CORES_PER_NODE=144"
run_case named BENCHMARK_CASE=camry-v5a-meshfix -- "${LSTC}" "${T}/model/deck.k"
has "BENCHMARK_CASE set: recorded under that name, not the deck's" "${T}/named.log" "BENCHMARK_CASE=camry-v5a-meshfix TIME_TO_SOLUTION=1234"

echo "== a copy of a model's directory: links to the shipped files, an edited file of its own =="
mkdir -p "${T}/model-fixed"
ln -s "${T}/model/deck.k" "${T}/model-fixed/deck.k"
printf '*KEYWORD\n$ edited\n*END\n' > "${T}/model-fixed/car1.k"
run_case copydir -- "${LSTC}" "${T}/model-fixed/deck.k"
W="$(workdir_of copydir)"
is "exit 0" "${RC}" "0"
is "the edited include is the copy's, not the shipped one" "$(readlink "${W}/car1.k")" "${T}/model-fixed/car1.k"
is "the deck is the copy's link" "$(readlink "${W}/deck.k")" "${T}/model-fixed/deck.k"
is "no pfile given: the directories only" "$(cat "${W}/run.pfile")" "dir { global ${W} local ${W}/local }"
case "${W}" in */deck/Run/4242-1xhpc8a.96xlarge-144-*) ok "run directory named after the deck, job, shape and type" ;;
               *) bad "run directory" "*/deck/Run/4242-1xhpc8a.96xlarge-144-*" "${W}" ;; esac

echo "== 2 x hpc8a.96xlarge full, Ansys's build, its pfile, lstc_reduce, memory words =="
run_case ansys2 SLURM_JOB_NUM_NODES=2 SLURM_NTASKS_PER_NODE=192 SLURM_TASKS_PER_NODE='192(x2)' \
    PFILE_LSTC_REDUCE=1 MEMORY=900m MEMORY2=90m -- "${ANSYS}" "${T}/model/deck.k" "${T}/model/model.pfile"
L="${T}/ansys2.log"; W="$(workdir_of ansys2)"
is "exit 0" "${RC}" "0"
has "mpirun: 384 ranks, 192 per node, memory words" "${L}" "ARGS: -np 384 -ppn 192 ${ANSYS} i=deck.k p=run.pfile memory=900m memory2=90m"
has "a full node: compact" "${L}" "I_MPI_PIN_ORDER=compact"
has "a full node: no list" "${L}" "I_MPI_PIN_PROCESSOR_LIST=<unset>"
hasnt "Ansys's build: its directory not added to LD_LIBRARY_PATH" "${L}" "LD_LIBRARY_PATH=$(dirname "${ANSYS}")"
is "the shipped pfile, its dir section replaced, lstc_reduce added" "$(cat "${W}/run.pfile")" \
    "$(printf 'gen { lstc_reduce nodump nobeamout dboutonly }\ndecomp { silist 6 sy 48 }\ndir { global %s local %s/local }' "${W}" "${W}")"
is "the shipped pfile itself unchanged" "$(cat "${T}/model/model.pfile")" "$(cat "${HERE}/fixtures/pfile-3cars-32")"

echo "== refusals before the solver starts =="
run_case cores64 SLURM_NTASKS_PER_NODE=64 SLURM_TASKS_PER_NODE=64 -- "${LSTC}" "${T}/model/deck.k"
is "64 ranks per node on hpc8a: exit 1" "${RC}" "1"
hasnt "64 ranks per node: no mpirun" "${T}/cores64.log" "ARGS:"
has "64 ranks per node: the reason" "${T}/cores64.out" "unevenly"
run_case nolicence ANSYSLMD_LICENSE_FILE= -- "${LSTC}" "${T}/model/deck.k"
is "no licence server: exit 1" "${RC}" "1"
hasnt "no licence server: no mpirun" "${T}/nolicence.log" "ARGS:"
run_case uneven SLURM_NTASKS_PER_NODE= SLURM_TASKS_PER_NODE='96,95' SLURM_JOB_NUM_NODES=2 -- "${LSTC}" "${T}/model/deck.k"
is "different ranks per node: exit 1" "${RC}" "1"
mkdir -p "${T}/dirty"; cp "${T}/model/deck.k" "${T}/dirty/"; : > "${T}/dirty/d3hsp"
run_case dirty -- "${LSTC}" "${T}/dirty/deck.k"
is "an earlier run's output beside the deck: exit 1" "${RC}" "1"
hasnt "an earlier run's output: no mpirun" "${T}/dirty.log" "ARGS:"
run_case nodeck -- "${LSTC}" "${T}/model/missing.k"
is "no deck: exit 1" "${RC}" "1"

echo "== the instance type from the metadata, and lscpu when there is none =="
# With no instance type below a full node, a node that lscpu, read in the C locale, shows
# with 192 AMD cores (sockets x cores per socket) could be an hpc8a.96xlarge or
# hpc7a.96xlarge: it gets their list at a supported count, and their refusal at any
# other. Any other node runs with Intel MPI's own placement, and a one-line NOTE that
# the check is skipped.
LIST144="I_MPI_PIN_PROCESSOR_LIST=0,1,2,3,4,5,8,9,10,11,12,13,16,"
run_case noimds STUB_ITYPE= -- "${LSTC}" "${T}/model/deck.k"
is "no answer, a 192-core AMD node, 144 ranks per node: exit 0" "${RC}" "0"
has "no answer, a 192-core AMD node, 144: the list for 144" "${T}/noimds.log" "${LIST144}"
has "no answer, a 192-core AMD node, 144: the job log says why" "${T}/noimds.out" \
    "Instance type: unknown; 1 node(s) x 144 ranks; pinning: flexible-cores list for 144 of 192 cores (the same number of ranks on every CCD), as on hpc8a.96xlarge or hpc7a.96xlarge (the instance metadata did not name the instance type, and this node has 192 AMD cores, as those two do)"
hasnt "no answer, a 192-core AMD node, 144: no NOTE that the check is skipped" "${T}/noimds.out" "is skipped"
run_case noimds64 STUB_ITYPE= SLURM_NTASKS_PER_NODE=64 SLURM_TASKS_PER_NODE=64 -- "${LSTC}" "${T}/model/deck.k"
is "no answer, a 192-core AMD node, 64 ranks per node: exit 1" "${RC}" "1"
hasnt "no answer, a 192-core AMD node, 64: no mpirun" "${T}/noimds64.log" "ARGS:"
has "no answer, a 192-core AMD node, 64: the reason names both types, why, and the supported counts" "${T}/noimds64.out" \
    "ERROR: 64 ranks per node load the 24 CCDs of hpc8a.96xlarge or hpc7a.96xlarge unevenly (the instance metadata did not name the instance type, and this node has 192 AMD cores, as those two do); use 24, 48, 72, 96, 120, 144, 168 or 192 (Utils/flexible-cores)"
# In a German locale lscpu's labels are German: read in the C locale, the node is still seen.
run_case noimdsde STUB_ITYPE= LC_ALL=de_DE.UTF-8 SLURM_NTASKS_PER_NODE=64 SLURM_TASKS_PER_NODE=64 -- "${LSTC}" "${T}/model/deck.k"
is "no answer, a 192-core AMD node in a German locale (lscpu read in the C locale), 64 ranks per node: exit 1" "${RC}" "1"
hasnt "no answer, a German locale, 64: no mpirun" "${T}/noimdsde.log" "ARGS:"
has "no answer, a German locale, 64: the reason names both types" "${T}/noimdsde.out" \
    "load the 24 CCDs of hpc8a.96xlarge or hpc7a.96xlarge unevenly"
run_case noimdsamd96 STUB_ITYPE= STUB_CPU="AuthenticAMD 2 48" STUB_CORES=96 \
    SLURM_NTASKS_PER_NODE=48 SLURM_TASKS_PER_NODE=48 -- "${LSTC}" "${T}/model/deck.k"
is "no answer, a 96-core AMD node, 48 ranks per node: exit 0" "${RC}" "0"
has "no answer, a 96-core AMD node, 48: Intel MPI's own placement (no list)" "${T}/noimdsamd96.log" "I_MPI_PIN_PROCESSOR_LIST=<unset>"
has "no answer, a 96-core AMD node, 48: no pin order" "${T}/noimdsamd96.log" "I_MPI_PIN_ORDER=<unset>"
is "no answer, a 96-core AMD node, 48: one NOTE that the check is skipped" \
    "$(grep -c '^NOTE: the instance metadata did not name the instance type, .* is skipped for 48 ranks per node$' "${T}/noimdsamd96.out")" "1"
run_case noimdsintel STUB_ITYPE= STUB_CPU="GenuineIntel 2 96" SLURM_NTASKS_PER_NODE=64 SLURM_TASKS_PER_NODE=64 \
    -- "${LSTC}" "${T}/model/deck.k"
is "no answer, a 192-core Intel node, 64 ranks per node: exit 0" "${RC}" "0"
has "no answer, a 192-core Intel node, 64: Intel MPI's own placement (no list)" "${T}/noimdsintel.log" "I_MPI_PIN_PROCESSOR_LIST=<unset>"
has "no answer, a 192-core Intel node, 64: the job log says so" "${T}/noimdsintel.out" \
    "Instance type: unknown; 1 node(s) x 64 ranks; pinning: Intel MPI's own placement for 64 of 192 cores on a node whose instance type is unknown"
is "no answer, a 192-core Intel node, 64: one NOTE that the check is skipped" \
    "$(grep -c '^NOTE: the instance metadata did not name the instance type, .* is skipped for 64 ranks per node$' "${T}/noimdsintel.out")" "1"
run_case noimdsfull STUB_ITYPE= SLURM_NTASKS_PER_NODE=192 SLURM_TASKS_PER_NODE=192 -- "${LSTC}" "${T}/model/deck.k"
is "IMDS silent on a full node: runs (compact needs no type)" "${RC}" "0"
# An answer that is not an instance type name (a proxy's page, a type name in
# capitals or inside other text), and an answer cut off at the time limit, count
# as no answer: at 144 ranks per node on this 192-core AMD node the run gets the
# list for 144, as with no answer, and a full node runs; the run directory and the
# job log say "unknown". A proxy's line that ends in a host name ends in a
# type-shaped token, and only the type test's ^ refuses it.
for answer in '<html><body>Request not allowed by proxy.example.com</body></html>' HPC8A.96XLARGE \
              'hpc8a.96xlarge: not found' 'Request not allowed by proxy.example.com'; do
    run_case notatype STUB_ITYPE="${answer}" -- "${LSTC}" "${T}/model/deck.k"
    is "the answer '${answer}' at 144 ranks per node: exit 0" "${RC}" "0"
    has "the answer '${answer}' at 144: the job log says unknown" "${T}/notatype.out" "Instance type: unknown;"
    has "the answer '${answer}' at 144: the list for 144 (192 AMD cores)" "${T}/notatype.log" "${LIST144}"
done
run_case cutoff STUB_ITYPE=hpc8a.96x STUB_ITYPE_EXIT=28 -- "${LSTC}" "${T}/model/deck.k"
is "an answer cut off at the time limit, at 144 ranks per node: exit 0" "${RC}" "0"
has "a cut-off answer at 144: the job log says unknown" "${T}/cutoff.out" "Instance type: unknown;"
has "a cut-off answer at 144: the list for 144 (192 AMD cores)" "${T}/cutoff.log" "${LIST144}"
run_case pagefull STUB_ITYPE='<html><body>Request not allowed by proxy.example.com</body></html>' \
    SLURM_NTASKS_PER_NODE=192 SLURM_TASKS_PER_NODE=192 -- "${LSTC}" "${T}/model/deck.k"
is "a proxy's page on a full node: runs (compact needs no type)" "${RC}" "0"
W="$(workdir_of pagefull)"
case "${W}" in */deck/Run/4242-1xunknown-192-*) ok "a proxy's page on a full node: the run directory says unknown" ;;
               *) bad "a proxy's page: the run directory" "*/deck/Run/4242-1xunknown-192-*" "${W}" ;; esac
has "a proxy's page on a full node: the job log says unknown" "${T}/pagefull.out" "Instance type: unknown;"
# A type name with an i reads as one in a Turkish locale too, where [a-z] leaves out i.
run_case turkish STUB_ITYPE=c8i.96xlarge LANG=tr_TR.UTF-8 -- "${LSTC}" "${T}/model/deck.k"
is "c8i.96xlarge in a Turkish locale, at 144 ranks per node: runs, with Intel MPI's own placement" "${RC}" "0"
has "c8i.96xlarge in a Turkish locale: no list" "${T}/turkish.log" "I_MPI_PIN_PROCESSOR_LIST=<unset>"
has "c8i.96xlarge in a Turkish locale: the job log names the type" "${T}/turkish.out" "Instance type: c8i.96xlarge;"

echo "== lscpu's summary: read only for an unknown type below a full node =="
# Each case's log holds its lscpu calls: "lscpu: -p=CORE,SOCKET" is the script's core
# count, which every run reads; "lscpu:" is the summary (vendor, sockets, cores per
# socket), which only an unknown type below a full node needs. The NOTE that the check
# is skipped goes with that read, on a node without 192 AMD cores.
lscpu_log() {  # lscpu_log <case>: "<core count reads>/<summary reads>/<NOTE lines>"
    echo "$(grep -cx 'lscpu: -p=CORE,SOCKET' "${T}/$1.log")/$(grep -cx 'lscpu:' "${T}/$1.log")/$(grep -c '^NOTE: .* is skipped for ' "${T}/$1.out")"
}
run_case c8i STUB_ITYPE=c8i.96xlarge -- "${LSTC}" "${T}/model/deck.k"
is "c8i.96xlarge at 144: the core count read, no summary, no NOTE" "$(lscpu_log c8i)" "1/0/0"
is "hpc8a.96xlarge at 144: the core count read, no summary, no NOTE" "$(lscpu_log lstc144)" "1/0/0"
is "no answer, a full 192-core AMD node: no summary, no NOTE" "$(lscpu_log noimdsfull)" "1/0/0"
is "no answer, a 192-core AMD node, 144: one summary read, no NOTE" "$(lscpu_log noimds)" "1/1/0"
is "no answer, a 192-core Intel node, 64: one summary read, one NOTE" "$(lscpu_log noimdsintel)" "1/1/1"
run_case noimdsintelfull STUB_ITYPE= STUB_CPU="GenuineIntel 2 96" SLURM_NTASKS_PER_NODE=192 SLURM_TASKS_PER_NODE=192 \
    -- "${LSTC}" "${T}/model/deck.k"
is "no answer, a full 192-core Intel node: exit 0" "${RC}" "0"
has "no answer, a full 192-core Intel node: compact" "${T}/noimdsintelfull.log" "I_MPI_PIN_ORDER=compact"
is "no answer, a full 192-core Intel node: no summary, no NOTE" "$(lscpu_log noimdsintelfull)" "1/0/0"
run_case noimdsover STUB_ITYPE= STUB_CPU="GenuineIntel 2 96" SLURM_NTASKS_PER_NODE=200 SLURM_TASKS_PER_NODE=200 \
    -- "${LSTC}" "${T}/model/deck.k"
is "no answer, 200 ranks per node on 192 Intel cores: exit 1" "${RC}" "1"
hasnt "no answer, 200 ranks per node: no mpirun" "${T}/noimdsover.log" "ARGS:"
is "no answer, 200 ranks per node: no summary, no NOTE" "$(lscpu_log noimdsover)" "1/0/0"

echo "== the verdict: LS-DYNA's termination line, not the exit status =="
run_case errterm STUB_TERMINATION=error -- "${LSTC}" "${T}/model/deck.k"
is "error termination with mpirun exit 0: exit 1" "${RC}" "1"
hasnt "error termination: not recorded" "${T}/errterm.log" "RECORDED"
has "error termination: the ranks' message files named" "${T}/errterm.out" "mesNNNN"
run_case noterm STUB_TERMINATION=none -- "${LSTC}" "${T}/model/deck.k"
is "no termination line: exit 1" "${RC}" "1"
hasnt "no termination line: not recorded" "${T}/noterm.log" "RECORDED"
run_case mpifail STUB_MPI_RC=7 -- "${LSTC}" "${T}/model/deck.k"
is "mpirun's own failure: its exit status" "${RC}" "7"
hasnt "mpirun's own failure: not recorded" "${T}/mpifail.log" "RECORDED"
run_case endtime ENDTIME=0.002 -- "${LSTC}" "${T}/model/deck.k"
is "ENDTIME: exit 0" "${RC}" "0"
has "ENDTIME: endtime= on the command line" "${T}/endtime.log" "p=run.pfile endtime=0.002"
hasnt "ENDTIME: not recorded (shorter than the deck)" "${T}/endtime.log" "RECORDED"

echo "== other settings =="
run_case rshoff LSTC_RSH= -- "${LSTC}" "${T}/model/deck.k"
has "LSTC_RSH empty: the build's own default" "${T}/rshoff.log" "LSTC_RSH=<unset>"
run_case lstcserver ANSYSLMD_LICENSE_FILE= LSTC_LICENSE_SERVER=licence-host -- "${LSTC}" "${T}/model/deck.k"
has "an LSTC licence server: LSTC_LICENSE=network" "${T}/lstcserver.log" "LSTC_LICENSE=network"
# Slurm runs a copy of the script from its spool directory: the helpers are then
# found from the submit directory (here the repository root's apps/LS-Dyna/lib).
mkdir -p "${T}/spool" "${T}/apps/LS-Dyna/lib"
cp "${SBATCH}" "${T}/spool/slurm_script"; cp "${APP}/lib/lsdyna-run.sh" "${T}/apps/LS-Dyna/lib/"
SCRIPT="${T}/spool/slurm_script" run_case submitdir LSDYNA_LIB= -- "${LSTC}" "${T}/model/deck.k"
is "a spool copy finds the helpers from the submit directory" "${RC}" "0"
rm -rf "${T}/apps"
SCRIPT="${T}/spool/slurm_script" run_case nolib LSDYNA_LIB= -- "${LSTC}" "${T}/model/deck.k"
is "no helpers anywhere: exit 1" "${RC}" "1"
has "no helpers anywhere: the reason" "${T}/nolib.out" "cannot find lib/lsdyna-run.sh"

echo
echo "sbatch-e2e: ${pass} passed, ${fail} failed, ${skip} skipped"
[ "${fail}" -eq 0 ]
