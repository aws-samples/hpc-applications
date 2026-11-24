#!/bin/bash
#SBATCH --job-name=osu-benchmarks-intelmpi
#SBATCH --constraint=hpc8a.96xlarge
#SBATCH --partition=hpc8a
#SBATCH --nodes=2
#SBATCH --exclusive
#SBATCH --output=osu-benchmarks-intelmpi-%j.out
#SBATCH --time=00:30:00
#
# The OSU Micro-Benchmarks (OMB) with Intel MPI, over the EFA installer's libfabric and EFA. By default the job runs
# osu_latency, osu_bw and osu_bibw with 2 ranks, one on each of the first two nodes, then osu_mbw_mr and osu_allreduce
# with one rank per core on every node, each at OMB's own message sizes, iterations and warm-up.
# osu_benchmarks_openmpi.sbatch runs the same tests at the same layouts with Open MPI.
#
# Settings, in the job's environment (`OSU_TESTS="latency bw" sbatch osu_benchmarks_intelmpi.sbatch`) rather than in
# an sbatch --export list (README.md, "Settings"):
#   OSU_DIR      the libexec/osu-micro-benchmarks/mpi directory of an OMB install (default: the one
#                build_osu_benchmarks_intelmpi.sh installs, under /fsx/OSU-Benchmark-IntelMPI/install)
#   OSU_TESTS    the tests, in order (default "latency bw bibw mbw_mr allreduce")
#   OSU_PPN      ranks per node of the multi-pair and collective tests, 1 to the node's cores (default: every core)
#   OSU_ARGS     options for every test, such as "-m 1:65536 -i 1000"
#   I_MPI_FABRICS (default shm:ofi), I_MPI_OFI_PROVIDER (default efa), I_MPI_MULTIRAIL (default 1),
#   I_MPI_DEBUG (default 5, on the first test only), I_MPI_PIN_DOMAIN, I_MPI_PIN_ORDER, I_MPI_PIN_PROCESSOR_LIST,
#   I_MPI_OFI_LIBRARY_INTERNAL
#   (default 0) and FI_EFA_USE_DEVICE_RDMA: README.md, "EFA and MPI settings". The launcher sets
#   I_MPI_HYDRA_BOOTSTRAP=slurm whatever the job gives.
# A value out of its range stops the job before any MPI starts. Every test runs; the job ends with 1 when any test
# ended with another exit status than 0, else with 0.

set -uo pipefail

# The blocks between a ">>> shared:" and a "<<< shared:" line are the same in osu_benchmarks_openmpi.sbatch and
# osu_benchmarks_intelmpi.sbatch (tests/test_osu_launchers.py checks).

# >>> shared: helpers
die() { echo "ERROR: $*" >&2; exit 1; }
# Environment Modules' `module` is a shell function, which a batch job's shell may lack: then its init script is
# sourced. With no module command at all, the MPI on the PATH is used, after mpi_check.
if ! declare -F module >/dev/null 2>&1 && [ -r /etc/profile.d/modules.sh ]; then
    set +u
    # shellcheck disable=SC1091
    . /etc/profile.d/modules.sh
    set -u
fi
MODULE_NOTED=0
module_load() {  # <module>
    if declare -F module >/dev/null 2>&1; then
        set +u
        module load "$1" || echo "NOTE: module load $1 did not succeed" >&2
        set -u
    elif [ "${MODULE_NOTED}" = 0 ]; then
        echo "NOTE: no module command: using the MPI on the PATH" >&2
        MODULE_NOTED=1
    fi
}
mpi_check() {  # <text> <name>: mpirun --version's first line must hold <text>, else the job stops
    local out
    out=$(mpirun --version 2>/dev/null) || true
    MPI_VERSION=${out%%$'\n'*}
    case "${MPI_VERSION}" in
        *"$1"*) ;;
        *) die "mpirun is not $2 (mpirun --version: ${MPI_VERSION:-no output}): load its module, or put its bin" \
               "directory first on the PATH" ;;
    esac
}
is_count() {  # <value> <max>: a whole number from 1 to <max>, with no sign or leading zero
    case "$1" in ''|0*|*[!0-9]*) return 1 ;; esac
    [ "${#1}" -le 7 ] && [ "$1" -le "$2" ]
}
# <<< shared: helpers

# >>> shared: job and settings
[ -n "${SLURM_JOB_ID:-}" ] || die "SLURM_JOB_ID is not set: submit this script with sbatch"
NODES=${SLURM_JOB_NUM_NODES:-}
is_count "${NODES}" 9999999 || die "SLURM_JOB_NUM_NODES=${NODES}: submit this script with sbatch"
PAIR_TESTS="latency bw bibw"         # 2 ranks: one on each of the first two nodes, both on a job's only node
MULTI_TESTS="mbw_mr multi_lat"       # OSU_PPN ranks per node, in pairs
COLLECTIVE_TESTS="allreduce allgather alltoall bcast barrier reduce reduce_scatter"   # OSU_PPN ranks per node
KNOWN_TESTS="${PAIR_TESTS} ${MULTI_TESTS} ${COLLECTIVE_TESTS}"
read -r -d '' -a TESTS < <(printf '%s' "${OSU_TESTS:-latency bw bibw mbw_mr allreduce}") || true
[ "${#TESTS[@]}" -gt 0 ] || die "OSU_TESTS names no test: use any of ${KNOWN_TESTS}"
for i in "${!TESTS[@]}"; do
    TESTS[i]=${TESTS[i]#osu_}
    case " ${KNOWN_TESTS} " in
        *" ${TESTS[i]} "*) ;;
        *) die "OSU_TESTS: no test ${TESTS[i]}: use any of ${KNOWN_TESTS}, with or without osu_" ;;
    esac
done
# The node's cores: sockets x cores per socket from lscpu, in the C locale, else SLURM_CPUS_ON_NODE.
CORES=$(LC_ALL=C lscpu 2>/dev/null | awk -F: '
    /^[[:space:]]*Socket\(s\):/          {s = $2}
    /^[[:space:]]*Core\(s\) per socket:/ {c = $2}
    END {gsub(/[[:space:]]/, "", s); gsub(/[[:space:]]/, "", c)
         if (s ~ /^[0-9]+$/ && c ~ /^[0-9]+$/ && s * c > 0) print s * c}') || CORES=""
if ! is_count "${CORES}" 9999999; then
    CORES=${SLURM_CPUS_ON_NODE:-}
    is_count "${CORES}" 9999999 \
        || die "this node's cores are unknown: lscpu shows none and SLURM_CPUS_ON_NODE is not set"
fi
PPN=${OSU_PPN:-${CORES}}
is_count "${PPN}" "${CORES}" || die "OSU_PPN=${PPN}: use a whole number from 1 to ${CORES}, this node's cores"
RANKS=$(( NODES * PPN ))
for t in "${TESTS[@]}"; do
    case " ${MULTI_TESTS} ${COLLECTIVE_TESTS} " in
        *" ${t} "*) [ "${RANKS}" -ge 2 ] || die "osu_${t} needs 2 ranks or more: ${NODES} x ${PPN} ranks is ${RANKS}" ;;
    esac
    case " ${MULTI_TESTS} " in
        *" ${t} "*) [ $(( RANKS % 2 )) = 0 ] \
            || die "osu_${t} pairs its ranks: ${NODES} x ${PPN} ranks is ${RANKS}, an odd number;" \
                   "set OSU_PPN to an even number" ;;
    esac
done
read -r -d '' -a OSU_ARGV < <(printf '%s' "${OSU_ARGS:-}") || true
# <<< shared: job and settings

# The OMB install: where build_osu_benchmarks_intelmpi.sh installs it.
OSU_DIR="${OSU_DIR:-/fsx/OSU-Benchmark-IntelMPI/install/libexec/osu-micro-benchmarks/mpi}"
BUILD_HINT="bash build_osu_benchmarks_intelmpi.sh"

# >>> shared: binaries
osu_binary() {  # <test>: its binary
    case " ${PAIR_TESTS} ${MULTI_TESTS} " in
        *" $1 "*) echo "${OSU_DIR}/pt2pt/osu_$1" ;;
        *) echo "${OSU_DIR}/collective/osu_$1" ;;
    esac
}
for t in "${TESTS[@]}"; do
    [ -x "$(osu_binary "${t}")" ] || die "$(osu_binary "${t}") is missing: build OMB with ${BUILD_HINT} (README.md," \
        "\"Build\"), or set OSU_DIR to the libexec/osu-micro-benchmarks/mpi directory of an OMB install"
done
# <<< shared: binaries

# The MPI: Intel MPI (module intelmpi) over the EFA installer's libfabric (module libfabric-aws). Intel MPI's module
# puts its own libfabric and providers first unless I_MPI_OFI_LIBRARY_INTERNAL is 0 as it loads, so the launcher
# exports 0 first (a value the job gives is kept), then loads each module once.
export I_MPI_OFI_LIBRARY_INTERNAL="${I_MPI_OFI_LIBRARY_INTERNAL:-0}"
module_load intelmpi
module_load libfabric-aws
mpi_check "Intel(R) MPI Library" "Intel MPI"
MPI_NAME=${MPI_VERSION#*Version }
MPI_NAME="Intel MPI ${MPI_NAME%% *}"

# >>> shared: instance type
# For the first output line only. No answer within a few seconds, an HTTP error, an answer cut off at that limit, or
# an answer that is not an instance type name (tested in the C locale) gives "unknown".
TOKEN=$(curl -fs --connect-timeout 2 --max-time 5 -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600") || TOKEN=""
instanceType=$(curl -fs --connect-timeout 2 --max-time 5 -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type) || instanceType=""
if ! ( LC_ALL=C; [[ "${instanceType}" =~ ^[a-z][a-z0-9-]*\.[a-z0-9-]+$ ]] ); then instanceType=""; fi
# <<< shared: instance type

# >>> shared: EFA devices
# The EFA devices: the entries of efa_sysfs, in name order (C locale), read on this node, the job's first.
efa_sysfs=/sys/class/infiniband
numa_sysfs=/sys/devices/system/node
mapfile -t EFA_DEVICES < <(LC_ALL=C; for d in "${efa_sysfs}"/*; do [ -e "${d}" ] && echo "${d##*/}"; done)
# FI_EFA_USE_DEVICE_RDMA. For an MPI that asks libfabric for an API older than 1.18 (Open MPI 4.1 asks for 1.5),
# libfabric's EFA provider leaves device RDMA off on EFA devices 0xefa0 and 0xefa1 (PCI device ids) unless
# FI_EFA_USE_DEVICE_RDMA=1, and uses it by default on later ones; with 1, it stops the program on a device with no
# RDMA read. EFA v1 (0xefa0) has none on most instance types, and every later EFA has it (README.md, "EFA and MPI
# settings"). So the launcher sets 1, unless the job's environment gives a value, when every device is Amazon's
# (PCI vendor 0x1d0f) and none is 0xefa0; otherwise it leaves it unset.
RDMA_WHY=""
[ "${#EFA_DEVICES[@]}" -gt 0 ] || RDMA_WHY="this node has no EFA device"
for d in "${EFA_DEVICES[@]}"; do
    vendor=$(cat "${efa_sysfs}/${d}/device/vendor" 2>/dev/null) || vendor=""
    pci_device=$(cat "${efa_sysfs}/${d}/device/device" 2>/dev/null) || pci_device=""
    if [ "${vendor}" != 0x1d0f ]; then
        RDMA_WHY="${d} is not an EFA device (PCI vendor ${vendor:-unreadable})"
        break
    elif [ -z "${pci_device}" ] || [ "${pci_device}" = 0xefa0 ]; then
        RDMA_WHY="${d} may have no RDMA read (PCI device ${pci_device:-unreadable})"
        break
    fi
done
if [ -n "${FI_EFA_USE_DEVICE_RDMA:-}" ]; then
    RDMA_LINE="FI_EFA_USE_DEVICE_RDMA=${FI_EFA_USE_DEVICE_RDMA}, from the job's environment"
elif [ -z "${RDMA_WHY}" ]; then
    export FI_EFA_USE_DEVICE_RDMA=1
    RDMA_LINE="FI_EFA_USE_DEVICE_RDMA=1: every EFA device of this node supports RDMA read"
else
    unset FI_EFA_USE_DEVICE_RDMA
    RDMA_LINE="FI_EFA_USE_DEVICE_RDMA not set: ${RDMA_WHY}"
fi
# The pair tests' core, the same on both nodes: the first CPU of the NUMA node of the first EFA device whose PCI
# vendor is 0x1d0f, else core 0.
PAIR_CORE=0
PAIR_CORE_WHY="no EFA device's NUMA node is known"
for d in "${EFA_DEVICES[@]}"; do
    [ "$(cat "${efa_sysfs}/${d}/device/vendor" 2>/dev/null)" = 0x1d0f ] || continue
    numa=$(cat "${efa_sysfs}/${d}/device/numa_node" 2>/dev/null) || numa=""
    cpus=""
    case "${numa}" in
        ''|*[!0-9]*) ;;
        *) cpus=$(cat "${numa_sysfs}/node${numa}/cpulist" 2>/dev/null) || cpus="" ;;
    esac
    first=${cpus%%[-,]*}
    case "${first}" in
        ''|*[!0-9]*) PAIR_CORE_WHY="the NUMA node of ${d}, the first EFA device, is unknown" ;;
        *) PAIR_CORE=${first}; PAIR_CORE_WHY="the first CPU of NUMA node ${numa}, that of ${d}, the first EFA device" ;;
    esac
    break
done
# <<< shared: EFA devices

# Intel MPI's settings, each kept when the job's environment gives it: shared memory on a node, libfabric's EFA
# provider between nodes, every EFA device of a node for its ranks (multi-rail), and the startup report (I_MPI_DEBUG).
export I_MPI_FABRICS="${I_MPI_FABRICS:-shm:ofi}"
export I_MPI_OFI_PROVIDER="${I_MPI_OFI_PROVIDER:-efa}"
export I_MPI_MULTIRAIL="${I_MPI_MULTIRAIL:-1}"
MPI_SETTINGS="I_MPI_OFI_LIBRARY_INTERNAL=${I_MPI_OFI_LIBRARY_INTERNAL} I_MPI_FABRICS=${I_MPI_FABRICS}"
MPI_SETTINGS+=" I_MPI_OFI_PROVIDER=${I_MPI_OFI_PROVIDER} I_MPI_MULTIRAIL=${I_MPI_MULTIRAIL}"

# I_MPI_DEBUG: 5 on the job's first test only (its provider check, see run_test), unless the job gives a value,
# which every test keeps.
DEBUG_GIVEN=0
if [ -n "${I_MPI_DEBUG:-}" ]; then DEBUG_GIVEN=1; else unset I_MPI_DEBUG; fi
MPI_SETTINGS+=" I_MPI_DEBUG=${I_MPI_DEBUG:-5 (first test only)}"

# The bootstrap: slurm, so that Intel MPI starts its processes with srun, inside the job. A login profile can export
# I_MPI_HYDRA_BOOTSTRAP=ssh, which a job submitted from it carries: Slurm 23.11 and later then set neither slurm nor
# its --external-launcher, as they do for a job submitted with no value. So the launcher sets slurm whatever the job
# gives, and --external-launcher too when the job gives no extra argument and carries Slurm's own
# OMPI_MCA_plm_slurm_args=--external-launcher, which a Slurm whose srun has that option sets.
export I_MPI_HYDRA_BOOTSTRAP=slurm
if [ -z "${I_MPI_HYDRA_BOOTSTRAP_EXEC_EXTRA_ARGS:-}" ] && [ "${OMPI_MCA_plm_slurm_args:-}" = --external-launcher ]; then
    export I_MPI_HYDRA_BOOTSTRAP_EXEC_EXTRA_ARGS=--external-launcher
fi
MPI_SETTINGS+=" I_MPI_HYDRA_BOOTSTRAP=slurm"
[ -z "${I_MPI_HYDRA_BOOTSTRAP_EXEC_EXTRA_ARGS:-}" ] \
    || MPI_SETTINGS+=" I_MPI_HYDRA_BOOTSTRAP_EXEC_EXTRA_ARGS=${I_MPI_HYDRA_BOOTSTRAP_EXEC_EXTRA_ARGS}"
[ -z "${FI_EFA_USE_DEVICE_RDMA:-}" ] || MPI_SETTINGS+=" FI_EFA_USE_DEVICE_RDMA=${FI_EFA_USE_DEVICE_RDMA}"

# The pinning: unless the job's environment sets I_MPI_PIN_DOMAIN, I_MPI_PIN_ORDER or I_MPI_PIN_PROCESSOR_LIST (then
# the launcher sets none of them), the pair tests' ranks are pinned to PAIR_CORE and every other test's ranks each
# to a core of its own (see run_test).
PIN_GIVEN=0
for v in I_MPI_PIN_DOMAIN I_MPI_PIN_ORDER I_MPI_PIN_PROCESSOR_LIST; do
    [ -z "${!v:-}" ] || PIN_GIVEN=1
done
if [ "${PIN_GIVEN}" = 1 ]; then
    MPI_SETTINGS+=" pinning=the job's I_MPI_PIN_* settings"
    PAIR_PINNED=0
else
    unset I_MPI_PIN_DOMAIN I_MPI_PIN_ORDER I_MPI_PIN_PROCESSOR_LIST
    MPI_SETTINGS+=" pinning=one core per rank"
    PAIR_PINNED=1
fi

# >>> shared: header
NODE_LIST=$(scontrol show hostnames "${SLURM_JOB_NODELIST:-}" 2>/dev/null | paste -sd ' ' -) || NODE_LIST=""
echo "==> OSU Micro-Benchmarks | ${MPI_NAME} | ${NODES} x ${instanceType:-unknown} | job ${SLURM_JOB_ID}"
echo "Nodes: ${NODE_LIST:-${SLURM_JOB_NODELIST:-unknown}}"
# <<< shared: header

# >>> shared: build record and settings
BUILD_RECORD="${OSU_DIR%/libexec/osu-micro-benchmarks/mpi}/osu-build.txt"
record_value() { sed -n "s/^$1=//p" "${BUILD_RECORD}" | head -n 1; }
if [ -r "${BUILD_RECORD}" ]; then
    echo "Build: OMB $(record_value omb_version), $(record_value mpi) (${BUILD_RECORD})"
fi
echo "OSU settings: OSU_DIR=${OSU_DIR} OSU_TESTS=\"${TESTS[*]}\" OSU_PPN=${PPN} OSU_ARGS=\"${OSU_ARGV[*]}\""
echo "MPI settings: ${MPI_SETTINGS}"
echo "${RDMA_LINE}"
if [ "${NODES}" -ge 2 ] && [ "${PAIR_PINNED}" = 1 ]; then
    echo "Pair tests' core: ${PAIR_CORE}, ${PAIR_CORE_WHY}"
fi
# <<< shared: build record and settings

# >>> shared: provider check
# What carried the tests. The job's first test runs with the MPI's report of what it chose (see run_test), whose
# provider lines are then summarized; after each test, one line per EFA device of this node, the job's first, gives
# how much each of its counters grew during the test (EFA's hw_counters: bytes sent and received, and the RDMA and
# retransmit counters the device has).
LIBFABRIC=$(fi_info --version 2>/dev/null | sed -n 's/^libfabric: *//p' | head -n 1) || LIBFABRIC=""
echo "libfabric: ${LIBFABRIC:-unknown (fi_info --version named none)}"
[ "${#EFA_DEVICES[@]}" -gt 0 ] || echo "EFA devices: none in ${efa_sysfs}"
for d in "${EFA_DEVICES[@]}"; do
    vendor=$(cat "${efa_sysfs}/${d}/device/vendor" 2>/dev/null) || vendor=""
    pci_device=$(cat "${efa_sysfs}/${d}/device/device" 2>/dev/null) || pci_device=""
    numa=$(cat "${efa_sysfs}/${d}/device/numa_node" 2>/dev/null) || numa=""
    echo "EFA device ${d}: PCI ${vendor:-unknown}:${pci_device:-unknown}, NUMA node ${numa:-unknown}"
done
EFA_COUNTERS=(tx_bytes rx_bytes rdma_read_bytes rdma_read_resp_bytes rdma_write_bytes rdma_write_recv_bytes
              retrans_pkts)
efa_counters() {  # "<device> <counter> <value>", for each counter of EFA_COUNTERS each device has
    local d c v
    for d in "${EFA_DEVICES[@]}"; do
        for c in "${EFA_COUNTERS[@]}"; do
            v=$(cat "${efa_sysfs}/${d}/ports/1/hw_counters/${c}" 2>/dev/null) || continue
            case "${v}" in ''|*[!0-9]*) continue ;; esac
            echo "${d} ${c} ${v}"
        done
    done
}
efa_traffic() {  # <test> <efa_counters before it>: one line per device, how much each counter grew during the test
    local after
    after=$(efa_counters)
    if [ -z "${after}" ]; then
        echo "NOTE: no EFA counter of this node is readable (${efa_sysfs}/<device>/ports/1/hw_counters)"
        return 0
    fi
    printf '%s\n' "${after}" | BEFORE="$2" awk -v test="$1" '
        BEGIN { n = split(ENVIRON["BEFORE"], lines, "\n")
                for (i = 1; i <= n; i++) { split(lines[i], f, " "); if (f[3] != "") b[f[1] " " f[2]] = f[3] } }
        { key = $1 " " $2
          if (!($1 in text)) order[++m] = $1
          text[$1] = text[$1] sprintf(" %s %+.0f", $2, (key in b) ? $3 - b[key] : 0) }
        END { for (i = 1; i <= m; i++) print "==> EFA " order[i] " during osu_" test ":" text[order[i]] }'
}
provider_summary() {  # <test>: each value of the provider lines in its output (FIRST_OUTPUT), once
    local found
    found=$(sed -n -e 's/.*\(mtl:ofi:prov[a-z:]*\): *\([^[:space:]]*\).*/\1: \2/p' \
                   -e 's/.*\(libfabric version\): *\([^[:space:]]*\).*/\1: \2/p' \
                   -e 's/.*\(libfabric provider\): *\([^[:space:]]*\).*/\1: \2/p' "${FIRST_OUTPUT}" 2>/dev/null \
            | awk '!seen[$0]++' | paste -sd ';' - | sed 's/;/; /g')
    if [ -n "${found}" ]; then
        echo "==> provider, from osu_$1: ${found}"
    else
        echo "NOTE: osu_$1 printed no provider line (Open MPI's mtl:ofi:prov lines, Intel MPI's libfabric version" \
             "and provider lines)"
    fi
}
FIRST_TEST=1
FIRST_OUTPUT=$(mktemp "${TMPDIR:-/tmp}/osu-first-test.XXXXXX") || FIRST_OUTPUT=/dev/null
# <<< shared: provider check

# run_test <binary> <ranks> <ranks per node> <core, or empty>: one test, its ranks spread over the nodes as given.
# Unless the job sets Intel MPI's pinning, a pair test's ranks get I_MPI_PIN_PROCESSOR_LIST=<core> with no domain or
# order (with which Intel MPI would not take the list), and every other test's ranks a core each, in order
# (I_MPI_PIN_DOMAIN=core, I_MPI_PIN_ORDER=compact). The job's first test also gets I_MPI_DEBUG=5, Intel MPI's startup
# report, which names the libfabric version and provider, unless the job gives I_MPI_DEBUG.
run_test() {
    local vars=()
    if [ "${PIN_GIVEN}" = 1 ]; then
        :
    elif [ -n "$4" ]; then
        vars+=("I_MPI_PIN_PROCESSOR_LIST=$4")
    else
        vars+=(I_MPI_PIN_DOMAIN=core I_MPI_PIN_ORDER=compact)
    fi
    [ "${FIRST_TEST}" = 0 ] || [ "${DEBUG_GIVEN}" = 1 ] || vars+=(I_MPI_DEBUG=5)
    env "${vars[@]}" mpirun -np "$2" -ppn "$3" "$1" "${OSU_ARGV[@]}"
}

# >>> shared: logind wait
# A job submitted with an sbatch --export list (any value but ALL or NIL, NONE included) starts with Slurm loading the
# user's login environment (su - <user>) on the job's first node. That opens and closes a systemd-logind session, and
# where logind removes a user's IPC objects once the user's last session has ended (RemoveIPC=yes, its default), it
# removes the user's files in /dev/shm about 10 seconds later (UserStopDelaySec), the shared memory MPI creates for
# the ranks on a node among them. So while logind is closing this user, the job waits, at most 30 s, before the first
# test: logind is done with the user right after that clean-up. With no such session (a job submitted without an
# --export list, a user with an open session or lingering), loginctl answers at once and nothing waits.
LOGIND_WAITED=0
if command -v loginctl >/dev/null 2>&1; then
    while [ "$(loginctl show-user "$(id -u)" -p State --value 2>/dev/null)" = closing ] && (( LOGIND_WAITED < 60 )); do
        sleep 0.5
        LOGIND_WAITED=$(( LOGIND_WAITED + 1 ))
    done
    if (( LOGIND_WAITED > 0 )); then
        echo "==> waited $(( LOGIND_WAITED / 2 )).$(( LOGIND_WAITED % 2 * 5 )) s while systemd-logind closed this" \
             "user's session, before starting MPI"
    fi
fi
# <<< shared: logind wait

# >>> shared: tests
STATUS=()
for t in "${TESTS[@]}"; do
    core=""
    case " ${PAIR_TESTS} " in
        *" ${t} "*)
            np=2
            if [ "${NODES}" -ge 2 ]; then
                ppn=1
                [ "${PAIR_PINNED}" = 0 ] || core=${PAIR_CORE}
                echo "==> osu_${t}: 2 ranks, 1 per node on the first 2 nodes${core:+, on core ${core}}"
            else
                ppn=2
                echo "==> osu_${t}: 2 ranks on 1 node"
            fi ;;
        *)
            np=${RANKS}
            ppn=${PPN}
            echo "==> osu_${t}: ${RANKS} ranks, ${PPN} per node on ${NODES} node(s)" ;;
    esac
    BEFORE=$(efa_counters)
    if [ "${FIRST_TEST}" = 1 ]; then
        run_test "$(osu_binary "${t}")" "${np}" "${ppn}" "${core}" 2>&1 | tee "${FIRST_OUTPUT}"
        rc=${PIPESTATUS[0]}
        FIRST_TEST=0
        provider_summary "${t}"
        [ "${FIRST_OUTPUT}" = /dev/null ] || rm -f "${FIRST_OUTPUT}"
    else
        run_test "$(osu_binary "${t}")" "${np}" "${ppn}" "${core}"
        rc=$?
    fi
    efa_traffic "${t}" "${BEFORE}"
    STATUS+=("${t}:${rc}")
done
echo "==> Summary"
JOB_RC=0
for s in "${STATUS[@]}"; do
    if [ "${s#*:}" = 0 ]; then
        printf '    %-22s ok\n' "osu_${s%%:*}"
    else
        printf '    %-22s exit status %s\n' "osu_${s%%:*}" "${s#*:}"
        JOB_RC=1
    fi
done
exit "${JOB_RC}"
# <<< shared: tests
