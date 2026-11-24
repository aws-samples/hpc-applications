"""Stubs and a runner for the tests of Utils/OSU-Benchmarks/osu_benchmarks_openmpi.sbatch and
osu_benchmarks_intelmpi.sbatch (tests/test_osu_*.py).

A launcher names /fsx/ (OSU_DIR's default), sources /etc/profile.d/modules.sh, and reads /sys/class/infiniband (the
EFA devices) and /sys/devices/system/node (the NUMA nodes' CPUs), so the tests run a copy that names a temporary
directory, a stub modules.sh (its `module` function) and a synthetic sysfs instead, and differs from the launcher in
those paths alone (checked here). They run it as a Slurm job of synthetic nodes, from a temporary directory, with a
clean environment and stubs of the commands it calls: three stub MPIs (Open MPI 4, Open MPI 5 and Intel MPI, each
with its own mpirun), scontrol, lscpu, curl (the instance metadata), fi_info, srun, loginctl, sleep and hostname. The
PATH holds no other MPI, Slurm, curl, aws, sudo, ssh or systemd command, so no MPI, Slurm, network or EFA is needed.
Every value is synthetic.

The stub mpirun notes each launch in a directory of its own (its arguments, the FI_*, I_MPI_*, OMPI_MCA_* and
PRTE_MCA_* variables it got, its MPI) and the order of every stub's calls in one events log, prints the provider
lines its MPI prints when asked for them (Open MPI's with --mca mtl_ofi_verbose, Intel MPI's with I_MPI_DEBUG),
adds traffic to the synthetic EFA devices' counters, and ends with the status STUB_RC gives its test. Like Open MPI
4.1.7 and 5.0.9, an Open MPI stub refuses --cpu-set beside --map-by, before anything starts.
"""
from __future__ import annotations

import os
import shutil
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
OSU = REPO / "Utils" / "OSU-Benchmarks"
LAUNCHERS = {"openmpi": OSU / "osu_benchmarks_openmpi.sbatch", "intelmpi": OSU / "osu_benchmarks_intelmpi.sbatch"}
MODULES = "/etc/profile.d/modules.sh"
EFA_SYSFS = "/sys/class/infiniband"
NUMA_SYSFS = "/sys/devices/system/node"
BASH = shutil.which("bash")
JOB_ID = "4242"
INSTANCE_TYPE = "hpc9z.96xlarge"
# The OMB install each launcher uses by default, under /fsx/, and the build script it names.
DEFAULT_OSU_DIRS = {"openmpi": "OSU-Benchmark-OpenMPI/install/libexec/osu-micro-benchmarks/mpi",
                    "intelmpi": "OSU-Benchmark-IntelMPI/install/libexec/osu-micro-benchmarks/mpi"}
BUILD_SCRIPTS = {"openmpi": "build_osu_benchmarks_openmpi.sh", "intelmpi": "build_osu_benchmarks_intelmpi.sh"}
# The MPI each launcher loads by default (a stub MPI's name), and the name its first output line gives.
DEFAULT_MPI = {"openmpi": "openmpi4", "intelmpi": "intelmpi"}
MPI_NAMES = {"openmpi4": "Open MPI 4.1.99", "openmpi5": "Open MPI 5.0.99stub", "intelmpi": "Intel MPI 2021.99.0"}
PAIR_TESTS = ("latency", "bw", "bibw")
MULTI_TESTS = ("mbw_mr", "multi_lat")
COLLECTIVE_TESTS = ("allreduce", "allgather", "alltoall", "bcast", "barrier", "reduce", "reduce_scatter")
ALL_TESTS = PAIR_TESTS + MULTI_TESTS + COLLECTIVE_TESTS
DEFAULT_TESTS = ("latency", "bw", "bibw", "mbw_mr", "allreduce")
COUNTERS = ("tx_bytes", "rx_bytes", "rdma_read_bytes", "rdma_read_resp_bytes", "rdma_write_bytes",
            "rdma_write_recv_bytes", "retrans_pkts")

# Host commands a launcher must not find: the stubs stand in for some of them, and it runs none of the others.
HIDDEN = frozenset({"curl", "wget", "module", "mpirun", "mpiexec", "mpicc", "srun", "sbatch", "scontrol", "squeue",
                    "sinfo", "salloc", "lscpu", "nproc", "fi_info", "loginctl", "sleep", "hostname", "ssh", "aws",
                    "sudo"})

MPI_VERSIONS = {
    "openmpi4": ["mpirun (Open MPI) 4.1.99", "", "Report bugs to https://www.example.invalid/"],
    "openmpi5": ["mpirun (Open MPI) 5.0.99stub", "", "Report bugs to https://www.example.invalid/"],
    "intelmpi": ["Intel(R) MPI Library for Linux* OS, Version 2021.99.0 Build 20990101 (id: stub)",
                 "Copyright 2003-2099, Intel Corporation."],
}

# mpirun, for the MPI named @FLAVOUR@. --version prints that MPI's version lines. Any other call is a launch, noted
# in STATE/mpirun-<n>/ and as "mpirun <n>" in STATE/events.log. With --mca mtl_ofi_verbose among its arguments, an
# Open MPI prints its provider lines on stderr: as Open MPI 4.1.7 prints them (STUB_OFI_LINES=4, an Open MPI 4's
# default) or as 5.0.9 does (5, an Open MPI 5's default). With I_MPI_DEBUG of 1 or more, Intel MPI prints its
# libfabric version and provider lines. Each launch adds STUB_TRAFFIC (default 4096) to tx_bytes, rx_bytes and, where
# the device has it, rdma_read_bytes of every device under STUB_EFA_SYSFS. It ends with the status STUB_RC gives its
# test ("osu_bw=3 osu_allreduce=5"), else 0. An Open MPI refuses --cpu-set beside --map-by as Open MPI 4.1.7 and
# 5.0.9 do: the launch is noted, then 4.1 ends with exit status 1 (its --cpu-set makes its rank_file mapper take
# over) and 5.0 with 213 (PRRTE turns --cpu-set into a second --map-by directive), each with its message.
MPIRUN_STUB = r"""#!/bin/bash
flavour=@FLAVOUR@
if [ "$*" = --version ]; then
    echo "mpirun --version" >> "${STATE}/events.log"
    case "${flavour}" in
@VERSION_LINES@
    esac
    exit 0
fi
n=1
while [ -e "${STATE}/mpirun-${n}" ]; do n=$((n + 1)); done
d="${STATE}/mpirun-${n}"
mkdir "${d}"
printf '%s\n' "$@" > "${d}/args"
echo "${flavour}" > "${d}/flavour"
env | LC_ALL=C grep -E '^(FI|I_MPI|OMPI_MCA|PRTE_MCA)_' | LC_ALL=C sort > "${d}/env"
echo "mpirun ${n}" >> "${STATE}/events.log"
if [[ "${flavour}" == openmpi* && " $* " == *" --cpu-set "* && " $* " == *" --map-by "* ]]; then
    if [ "${flavour}" = openmpi5 ]; then
        printf '%s\n' "When resolving deprecated command line options, the result generated" \
            "too many directives for the target option:" "  Command line option: map-by" >&2
        exit 213
    fi
    printf '%s\n' "Conflicting directives for mapping policy are causing the policy" "to be redefined:" \
        "  New policy:   RANK_FILE" "Please check that only one policy is defined." >&2
    exit 1
fi
bin=""
for a in "$@"; do case "${a##*/}" in osu_*) bin=${a##*/}; break ;; esac; done
case "${flavour}" in
    openmpi*)
        if [[ " $* " == *" mtl_ofi_verbose "* ]]; then
            if [ "${STUB_OFI_LINES:-${flavour#openmpi}}" = 5 ]; then
                echo "common_ofi.c:1099: mtl:ofi:provider: ${STUB_PROVIDER:-efa}" >&2
                echo "common_ofi.c:1100: mtl:ofi:provider:domain: ${STUB_DOMAIN:-rdmap0s9-rdm}" >&2
            else
                echo "mtl_ofi_component.c:980: mtl:ofi:prov: ${STUB_PROVIDER:-efa}" >&2
                echo "mtl_ofi_component.c:983: mtl:ofi:provider: ${STUB_DOMAIN:-rdmap0s9-rdm}" >&2
            fi
        fi ;;
    intelmpi)
        case "${I_MPI_DEBUG:-0}" in
            ''|0|*[!0-9]*) ;;
            *) echo "[0] MPI startup(): libfabric version: 9.9.0stub"
               echo "[0] MPI startup(): libfabric provider: ${STUB_PROVIDER:-efa}" ;;
        esac ;;
esac
if [ -n "${STUB_EFA_SYSFS:-}" ]; then
    for c in "${STUB_EFA_SYSFS}"/*/ports/1/hw_counters; do
        [ -d "${c}" ] || continue
        for name in tx_bytes rx_bytes rdma_read_bytes; do
            if [ -f "${c}/${name}" ]; then
                v=$(cat "${c}/${name}")
                echo $(( v + ${STUB_TRAFFIC:-4096} )) > "${c}/${name}"
            fi
        done
    done
fi
echo "# OSU MPI stub: ${bin} (${flavour}), launch ${n}"
rc=0
for pair in ${STUB_RC:-}; do [ "${pair%%=*}" = "${bin}" ] && rc=${pair#*=}; done
exit "${rc}"
"""

# The stub of /etc/profile.d/modules.sh: a module function that logs each call with I_MPI_OFI_LIBRARY_INTERNAL at that
# moment ("unset" when none), and puts a stub MPI's bin directory first on the PATH for each MPI module, as module
# load does. STUB_WRONG_MPI=1 makes each MPI module put another MPI there.
MODULES_STUB = r"""module() {
    printf '%s %s %s\n' "$1" "$2" "${I_MPI_OFI_LIBRARY_INTERNAL-unset}" >> "${STATE}/module.log"
    echo "module $1 $2" >> "${STATE}/events.log"
    local mpi=""
    case "$1 $2" in
        "load openmpi") mpi=openmpi4; [ "${STUB_WRONG_MPI:-0}" = 1 ] && mpi=intelmpi ;;
        "load openmpi5") mpi=openmpi5; [ "${STUB_WRONG_MPI:-0}" = 1 ] && mpi=openmpi4 ;;
        "load intelmpi") mpi=intelmpi; [ "${STUB_WRONG_MPI:-0}" = 1 ] && mpi=openmpi4
                         export I_MPI_ROOT="${STUB_MPI_ROOT}/intelmpi" ;;
        "load libfabric-aws") export LD_LIBRARY_PATH="/stub/libfabric-aws/lib64:${LD_LIBRARY_PATH:-}" ;;
        *) echo "module stub: refusing $*" >&2; return 1 ;;
    esac
    [ -n "${mpi}" ] && export PATH="${STUB_MPI_ROOT}/${mpi}/bin:${PATH}"
    return 0
}
"""
# scontrol show hostnames <the job's node list>: STUB_HOSTS, one per line.
SCONTROL_STUB = r"""#!/bin/bash
[ "$#" = 3 ] && [ "$1" = show ] && [ "$2" = hostnames ] && [ "$3" = "${SLURM_JOB_NODELIST}" ] \
    || { echo "scontrol stub: refusing $*" >&2; exit 1; }
printf '%s\n' ${STUB_HOSTS}
"""
# lscpu: logs the LC_ALL it was given ("unset" when none) and its arguments; answers no argument with a node of
# STUB_SOCKETS sockets of STUB_CORES_PER_SOCKET cores, one thread per core, in lscpu's format.
LSCPU_STUB = r"""#!/bin/bash
printf '%s|%s\n' "${LC_ALL-unset}" "$*" >> "${STATE}/lscpu.log"
[ "$#" = 0 ] || { echo "lscpu stub: refusing $*" >&2; exit 1; }
echo "Architecture:                    x86_64"
echo "CPU(s):                          $(( STUB_SOCKETS * STUB_CORES_PER_SOCKET ))"
echo "Vendor ID:                       SyntheticVendor"
echo "Model name:                      Synthetic CPU"
echo "    Thread(s) per core:          1"
echo "    Core(s) per socket:          ${STUB_CORES_PER_SOCKET}"
echo "    Socket(s):                   ${STUB_SOCKETS}"
echo "NUMA node(s):                    2"
"""
# curl, as the instance metadata answers (IMDSv2). It logs each call's STUB_HOST (empty in the job's own shell) and
# arguments, and answers as STUB_IMDS says:
#   answer      the token request with a token; the instance type request with STUB_TYPE; the instance id request
#               with the file STATE/ids/<STUB_HOST> (nothing when there is none), none with a newline added;
#   no-answer   nothing, and curl's exit at its --max-time (28), for every request;
#   http-error  an HTTP 401 for every request: with -f (--fail) nothing and exit 22, as curl does, else the page;
#   cut-off     for the instance type and id, the answer less its last five characters, then exit 28.
CURL_STUB = r"""#!/bin/bash
printf '%s|%s\n' "${STUB_HOST:-}" "$*" >> "${STATE}/curl.log"
case "$*" in
    *169.254.169.254*) ;;
    *) echo "curl stub: refusing $*" >&2; exit 7 ;;
esac
fail=0
for a in "$@"; do case "${a}" in --fail) fail=1 ;; --*) ;; -*f*) fail=1 ;; esac; done
case "${STUB_IMDS:-answer}" in
    no-answer) exit 28 ;;
    http-error)
        [ "${fail}" = 1 ] && exit 22
        printf '%s\n' '<html><head><title>401 - Unauthorized</title></head>' \
            '<body><h1>401 - Unauthorized</h1></body></html>'
        exit 0 ;;
esac
case "$*" in
    *latest/api/token*) printf '%s' stub-token; exit 0 ;;
    *meta-data/instance-type*) answer=${STUB_TYPE} ;;
    *meta-data/instance-id*) answer=$(cat "${STATE}/ids/${STUB_HOST:-none}" 2>/dev/null) || answer="" ;;
    *) exit 22 ;;
esac
[ "${STUB_IMDS:-answer}" = cut-off ] && { printf '%s' "${answer%?????}"; exit 28; }
printf '%s' "${answer}"
"""
FI_INFO_STUB = r"""#!/bin/bash
printf '%s\n' "$*" >> "${STATE}/fi_info.log"
[ "$*" = --version ] || { echo "fi_info stub: refusing $*" >&2; exit 1; }
printf '%s\n' "fi_info: 9.9.0stub" "libfabric: 9.9.0stub" "libfabric api: 9.9"
"""
# srun: logs its arguments, and runs its command once for each of the first --nodes=<n> hosts of STUB_HOSTS (all of
# them without --nodes), with STUB_HOST naming that host; then ends with STUB_SRUN_RC (default 0).
SRUN_STUB = r"""#!/bin/bash
printf '%s\n' "$*" >> "${STATE}/srun.log"
echo "srun" >> "${STATE}/events.log"
nodes=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --nodes=*) nodes=${1#--nodes=} ;;
        --*) ;;
        *) break ;;
    esac
    shift
done
i=0
for h in ${STUB_HOSTS}; do
    i=$((i + 1))
    if [ -n "${nodes}" ] && [ "${i}" -gt "${nodes}" ]; then break; fi
    STUB_HOST=${h} "$@"
done
exit "${STUB_SRUN_RC:-0}"
"""
# loginctl: logs its arguments and answers `show-user <uid> -p State --value` as STUB_LOGIND says: none (the default:
# exit 1, as for a user systemd-logind does not know), active, or closing:<n> (closing for its first n calls, then
# exit 1, as once logind has freed the user).
LOGINCTL_STUB = r"""#!/bin/bash
printf '%s\n' "$*" >> "${STATE}/loginctl.log"
echo "loginctl" >> "${STATE}/events.log"
calls=$(wc -l < "${STATE}/loginctl.log")
case "${STUB_LOGIND:-none}" in
    active) echo active; exit 0 ;;
    closing:*) [ "${calls}" -le "${STUB_LOGIND#closing:}" ] && { echo closing; exit 0; }; exit 1 ;;
    *) exit 1 ;;
esac
"""
# sleep: logs its arguments and returns at once.
SLEEP_STUB = r"""#!/bin/bash
echo "sleep $*" >> "${STATE}/events.log"
"""
# hostname: STUB_HOST, else the first of STUB_HOSTS.
HOSTNAME_STUB = r"""#!/bin/bash
h=${STUB_HOST:-${STUB_HOSTS%% *}}
echo "${h}"
"""


@dataclass
class Device:
    """A synthetic EFA device under /sys/class/infiniband: each value None is a file that does not exist."""
    name: str
    vendor: str | None = "0x1d0f"
    device: str | None = "0xefa1"
    numa: str | None = "0"
    counters: tuple[str, ...] | None = COUNTERS


DEVICES = (Device("rdmap0s9", numa="0"), Device("rdmap1s9", numa="1"))
CPULISTS = {0: "0-7", 1: "8-15"}


@dataclass
class Call:
    """One mpirun launch, as the stub noted it."""
    index: int
    args: list[str]
    env: dict[str, str]
    flavour: str

    @property
    def binary_index(self) -> int:
        return next(i for i, a in enumerate(self.args) if Path(a).name.startswith("osu_"))

    @property
    def binary(self) -> str:
        return self.args[self.binary_index]

    @property
    def test(self) -> str:
        return Path(self.binary).name

    @property
    def options(self) -> list[str]:
        """The arguments before the binary."""
        return self.args[:self.binary_index]

    @property
    def tail(self) -> list[str]:
        """The arguments after the binary."""
        return self.args[self.binary_index + 1:]

    def mca(self) -> dict[str, str]:
        """Open MPI's --mca <name> <value> pairs."""
        o = self.options
        return {o[i + 1]: o[i + 2] for i in range(len(o) - 2) if o[i] == "--mca"}

    def without_mca(self) -> list[str]:
        """The options with every --mca <name> <value> left out."""
        o, out, i = self.options, [], 0
        while i < len(o):
            if o[i] == "--mca":
                i += 3
            else:
                out.append(o[i])
                i += 1
        return out

    def value(self, option: str) -> str | None:
        o = self.options
        return o[o.index(option) + 1] if option in o else None

    def exported(self) -> list[str]:
        """The names Open MPI's -x options pass."""
        o = self.options
        return [o[i + 1] for i in range(len(o) - 1) if o[i] == "-x"]


@dataclass
class Job:
    proc: subprocess.CompletedProcess
    work: Path
    calls: list[Call]
    events: list[str]
    modules: list[list[str]]       # each module call: its two arguments and I_MPI_OFI_LIBRARY_INTERNAL then
    curl: list[tuple[str, str]]    # each curl call: its STUB_HOST and arguments
    srun: list[str]
    lscpu: list[str]               # each lscpu call: its LC_ALL and arguments, "<LC_ALL>|<arguments>"
    loginctl: list[str]
    fi_info: list[str]
    extra: dict = field(default_factory=dict)

    @property
    def out(self) -> list[str]:
        return self.proc.stdout.splitlines()

    @property
    def err(self) -> list[str]:
        return self.proc.stderr.splitlines()

    @property
    def tests(self) -> list[str]:
        return [c.test for c in self.calls]


def host_tools_dir(tmp_path_factory, hidden=HIDDEN) -> Path:
    """A directory of links to the host's commands, without the hidden ones."""
    tools = tmp_path_factory.mktemp("host-tools")
    for directory in os.environ.get("PATH", "").split(os.pathsep):
        try:
            entries = list(os.scandir(directory or "."))
        except OSError:
            continue
        for entry in entries:
            link = tools / entry.name
            if entry.name in hidden or link.is_symlink():
                continue
            try:
                if entry.is_file() and os.access(entry.path, os.X_OK):
                    link.symlink_to(entry.path)
            except OSError:
                continue
    return tools


def moved(work: Path) -> dict[str, str]:
    """The paths a runnable copy moves, and where to."""
    return {"/fsx/": f"{work}/fsx/", MODULES: str(work / "modules.sh"), EFA_SYSFS: f"{work}/sys/class/infiniband",
            NUMA_SYSFS: f"{work}/sys/devices/system/node"}


def runnable_copy(name: str, work: Path) -> Path:
    """The launcher, with the paths of moved() replaced: the copy differs from the launcher in those paths alone."""
    text = LAUNCHERS[name].read_text()
    assert str(work) not in text
    assert text.count(EFA_SYSFS) <= 1 and text.count(NUMA_SYSFS) <= 1, "the launcher reads sysfs in other places"
    copy_text = text
    for old, new in moved(work).items():
        copy_text = copy_text.replace(old, new)
    back = copy_text
    for old, new in reversed(list(moved(work).items())):
        back = back.replace(new, old)
    assert back == text
    copy = work / LAUNCHERS[name].name
    copy.write_text(copy_text)
    return copy


def mpi_stub(flavour: str) -> str:
    lines = "\n".join(f"        {f}) printf '%s\\n' " + " ".join(repr(line) for line in MPI_VERSIONS[f]) + " ;;"
                      for f in MPI_VERSIONS)
    return MPIRUN_STUB.replace("@FLAVOUR@", flavour).replace("@VERSION_LINES@", lines)


def write_sysfs(work: Path, devices, cpulists) -> Path:
    efa = work / "sys" / "class" / "infiniband"
    efa.mkdir(parents=True, exist_ok=True)
    for dev in devices:
        d = efa / dev.name / "device"
        d.mkdir(parents=True)
        for fname, value in (("vendor", dev.vendor), ("device", dev.device), ("numa_node", dev.numa)):
            if value is not None:
                (d / fname).write_text(value + "\n")
        if dev.counters is not None:
            c = efa / dev.name / "ports" / "1" / "hw_counters"
            c.mkdir(parents=True)
            for i, cname in enumerate(dev.counters):
                (c / cname).write_text(f"{1000 * (i + 1)}\n")
    for node, cpus in cpulists.items():
        n = work / "sys" / "devices" / "system" / "node" / f"node{node}"
        n.mkdir(parents=True)
        if cpus is not None:
            (n / "cpulist").write_text(cpus + "\n")
    return efa


def osu_dir(name: str, work: Path) -> Path:
    """The launcher's default OSU_DIR, as its runnable copy names it."""
    return work / "fsx" / DEFAULT_OSU_DIRS[name]


def install_binaries(directory: Path, tests=ALL_TESTS, missing=()) -> None:
    for t in tests:
        if t in missing:
            continue
        sub = "pt2pt" if t in PAIR_TESTS + MULTI_TESTS else "collective"
        b = directory / sub / f"osu_{t}"
        b.parent.mkdir(parents=True, exist_ok=True)
        b.write_text("#!/bin/bash\nexit 0\n")
        b.chmod(0o755)


def run(name: str, work: Path, tools: Path, nodes: int = 2, sockets: int = 2, cores_per_socket: int = 8,
        lscpu: bool = True, devices=DEVICES, cpulists=CPULISTS, env: dict[str, str | None] | None = None,
        modules: bool = True, path_mpi: str | None = None, install: Path | None | bool = True, missing=(),
        record: str | None = None, ids: dict[str, str] | None = None, fi_info: bool = True,
        loginctl: bool = True) -> Job:
    """Run a copy of launcher `name` as a job of `nodes` nodes n1, n2, ..., each with `sockets` x `cores_per_socket`
    cores (as lscpu shows them; no lscpu when `lscpu` is False), `devices` and the NUMA nodes' `cpulists`.

    `env` adds variables to the job's environment, or unsets them (None). `modules`: whether the stub modules.sh
    exists; `path_mpi`: a stub MPI whose bin directory is on the PATH. `install`: True installs every OMB binary in the
    launcher's default OSU_DIR (but `missing`), a Path installs them there instead, False installs none. `record`: the
    text of osu-build.txt next to the default install. `ids`: the instance id each host's metadata gives. `fi_info`,
    `loginctl`: whether those stubs are on the PATH. The job's LC_ALL is POSIX: the C locale under another name, so
    that the C locale shows in lscpu's log only where the launcher sets it."""
    stubs, state, mpi_root, tmp = work / "stubs", work / "state", work / "mpi", work / "tmp"
    for d in (stubs, state / "ids", tmp, work / "fsx"):
        d.mkdir(parents=True, exist_ok=True)
    for flavour in MPI_VERSIONS:
        b = mpi_root / flavour / "bin" / "mpirun"
        b.parent.mkdir(parents=True)
        b.write_text(mpi_stub(flavour))
        b.chmod(0o755)
    scripts = {"scontrol": SCONTROL_STUB, "curl": CURL_STUB, "srun": SRUN_STUB, "sleep": SLEEP_STUB,
               "hostname": HOSTNAME_STUB}
    if lscpu:
        scripts["lscpu"] = LSCPU_STUB
    if fi_info:
        scripts["fi_info"] = FI_INFO_STUB
    if loginctl:
        scripts["loginctl"] = LOGINCTL_STUB
    for stub, text in scripts.items():
        (stubs / stub).write_text(text)
        (stubs / stub).chmod(0o755)
    if modules:
        (work / "modules.sh").write_text(MODULES_STUB)
    efa = write_sysfs(work, devices, cpulists)
    if install is True:
        install_binaries(osu_dir(name, work), missing=missing)
    elif isinstance(install, Path):
        install_binaries(install, missing=missing)
    if record is not None:
        (osu_dir(name, work).parents[2] / "osu-build.txt").parent.mkdir(parents=True, exist_ok=True)
        (osu_dir(name, work).parents[2] / "osu-build.txt").write_text(record)
    hosts = [f"n{i}" for i in range(1, nodes + 1)]
    for host, value in (ids or {}).items():
        (state / "ids" / host).write_text(value)
    path = [str(stubs), *([str(mpi_root / path_mpi / "bin")] if path_mpi else []), str(tools)]
    job_env = {"PATH": os.pathsep.join(path), "HOME": str(work), "LC_ALL": "POSIX", "TMPDIR": str(tmp),
               "STATE": str(state), "STUB_MPI_ROOT": str(mpi_root), "STUB_HOSTS": " ".join(hosts),
               "STUB_SOCKETS": str(sockets), "STUB_CORES_PER_SOCKET": str(cores_per_socket),
               "STUB_TYPE": INSTANCE_TYPE, "STUB_EFA_SYSFS": str(efa), "SLURM_JOB_ID": JOB_ID,
               "SLURM_JOB_NUM_NODES": str(nodes), "SLURM_JOB_NODELIST": "n1" if nodes == 1 else f"n[1-{nodes}]",
               "SLURM_CPUS_ON_NODE": str(sockets * cores_per_socket)}
    for var, value in (env or {}).items():
        if value is None:
            job_env.pop(var, None)
        else:
            job_env[var] = value
    proc = subprocess.run([BASH, str(runnable_copy(name, work))], cwd=work, env=job_env, stdin=subprocess.DEVNULL,
                          capture_output=True, text=True, errors="replace", timeout=120)
    calls = []
    for d in sorted(state.glob("mpirun-*"), key=lambda p: int(p.name.rsplit("-", 1)[1])):
        env_lines = (d / "env").read_text().splitlines()
        calls.append(Call(int(d.name.rsplit("-", 1)[1]), (d / "args").read_text().splitlines(),
                          dict(line.split("=", 1) for line in env_lines if "=" in line),
                          (d / "flavour").read_text().strip()))

    def lines(fname: str) -> list[str]:
        return (state / fname).read_text().splitlines() if (state / fname).exists() else []

    return Job(proc, work, calls, lines("events.log"), [line.split() for line in lines("module.log")],
               [tuple(line.split("|", 1)) for line in lines("curl.log")], lines("srun.log"), lines("lscpu.log"),
               lines("loginctl.log"), lines("fi_info.log"))


def shared_blocks(text: str) -> dict[str, list[str]]:
    """The lines between each "# >>> shared: <name>" and "# <<< shared: <name>" line, by name."""
    blocks: dict[str, list[str]] = {}
    current = None
    for line in text.splitlines():
        if line.startswith("# >>> shared: "):
            assert current is None, f"block {line!r} opens inside {current!r}"
            current = line[len("# >>> shared: "):].split(" (")[0]
            assert current not in blocks, f"two blocks named {current!r}"
            blocks[current] = []
        elif line.startswith("# <<< shared: "):
            assert current == line[len("# <<< shared: "):], f"block {current!r} closes as {line!r}"
            current = None
        elif current is not None:
            blocks[current].append(line)
    assert current is None, f"block {current!r} is not closed"
    return blocks
