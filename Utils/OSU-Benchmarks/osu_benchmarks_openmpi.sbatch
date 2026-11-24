#!/bin/bash
#SBATCH --job-name=osu-benchmarks-openmpi
#SBATCH --constraint=hpc8a.96xlarge
#SBATCH --partition=hpc8a
#SBATCH --nodes=2
#SBATCH --exclusive
#SBATCH --output=osu-benchmarks-%j.out
#SBATCH --time=00:30:00
#
# The OSU Micro-Benchmarks (OMB) with the EFA installer's Open MPI, over EFA. By default the job runs osu_latency,
# osu_bw and osu_bibw with 2 ranks, one on each of the first two nodes, then osu_mbw_mr and osu_allreduce with one
# rank per core on every node, each at OMB's own message sizes, iterations and warm-up.
# osu_benchmarks_intelmpi.sbatch runs the same tests at the same layouts with Intel MPI.
#
# Settings, in the job's environment (`OSU_TESTS="latency bw" sbatch osu_benchmarks_openmpi.sbatch`) rather than in
# an sbatch --export list (README.md, "Settings"):
#   OSU_DIR      the libexec/osu-micro-benchmarks/mpi directory of an OMB install (default: the one
#                build_osu_benchmarks_openmpi.sh installs, under /fsx/OSU-Benchmark-OpenMPI/install)
#   OSU_TESTS    the tests, in order (default "latency bw bibw mbw_mr allreduce")
#   OSU_PPN      ranks per node of the multi-pair and collective tests, 1 to the node's cores (default: every core)
#   OSU_ARGS     options for every test, such as "-m 1:65536 -i 1000"
#   FI_PROVIDER (default efa), FI_EFA_USE_DEVICE_RDMA, OMPI_MCA_pml (default cm) and OMPI_MCA_mtl (default ofi):
#                README.md, "EFA and MPI settings"
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

# The OMB install: where build_osu_benchmarks_openmpi.sh installs it.
OSU_DIR="${OSU_DIR:-/fsx/OSU-Benchmark-OpenMPI/install/libexec/osu-micro-benchmarks/mpi}"
BUILD_HINT="bash build_osu_benchmarks_openmpi.sh"

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

# The MPI: the EFA installer's Open MPI 4 (module openmpi) and its libfabric (module libfabric-aws).
module_load openmpi
module_load libfabric-aws
mpi_check "(Open MPI) 4." "Open MPI 4"
MPI_NAME="Open MPI ${MPI_VERSION##*) }"

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

# Open MPI's settings, each kept when the job's environment gives it: the cm PML over the ofi MTL (libfabric) and
# libfabric's EFA provider. Every rank is bound to a core, the pair tests' ranks to PAIR_CORE.
export FI_PROVIDER="${FI_PROVIDER:-efa}"
MCA_ARGS=()
[ -n "${OMPI_MCA_pml:-}" ] || MCA_ARGS+=(--mca pml cm)
[ -n "${OMPI_MCA_mtl:-}" ] || MCA_ARGS+=(--mca mtl ofi)
MPI_SETTINGS="pml=${OMPI_MCA_pml:-cm} mtl=${OMPI_MCA_mtl:-ofi} FI_PROVIDER=${FI_PROVIDER}"
[ -z "${FI_EFA_USE_DEVICE_RDMA:-}" ] || MPI_SETTINGS+=" FI_EFA_USE_DEVICE_RDMA=${FI_EFA_USE_DEVICE_RDMA}"
MPI_SETTINGS+=" bind-to=core"
PAIR_PINNED=1

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

# run_test <binary> <ranks> <ranks per node> <core, or empty>: one test, its ranks spread over the nodes as given,
# each bound to a core by Open MPI, or, when <core> is given, all of them to that CPU of their node by taskset:
# Open MPI refuses --cpu-set beside --map-by, and Open MPI 4.1 reads its list as hwloc's logical CPU numbers,
# while <core> is the operating system's.
run_test() {
    local args=("${MCA_ARGS[@]}") program=("$1")
    if [ -n "$4" ]; then
        args+=(--bind-to none)
        program=(taskset -c "$4" "$1")
    else
        args+=(--bind-to core)
    fi
    args+=(-np "$2" --map-by "ppr:$3:node" -x FI_PROVIDER)
    [ -z "${FI_EFA_USE_DEVICE_RDMA:-}" ] || args+=(-x FI_EFA_USE_DEVICE_RDMA)
    mpirun "${args[@]}" "${program[@]}" "${OSU_ARGV[@]}"
}

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
    run_test "$(osu_binary "${t}")" "${np}" "${ppn}" "${core}"
    rc=$?
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
