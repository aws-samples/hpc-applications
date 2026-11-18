"""How apps/PowerFlow/PowerFlow.sbatch sizes, pins and starts a SIMULIA PowerFLOW job.

The script runs exaqsub in the foreground inside one Slurm job, with a hostfile that puts the CP on the first node and
SP_PER_NODE SPs on every node. These tests pin:
- without SP_PER_NODE, one SP per physical core but one on every node (191 on a 192-core node), with a note and no core
  list, also with OMP_NUM_THREADS=1 and OMP_THREAD_LIMIT=1 exported and with SMT on: the script counts the node's
  physical cores with lscpu, in the C locale, and never calls nproc;
- at 24, 48, 72, 96, 120, 144 and 168 SPs per node on a 192-core node, I_MPI_PIN_PROCESSOR_LIST is core 191 followed
  by the list of the same count in Utils/flexible-cores/hello-cpu.intelmpi.explicit.sbatch. Under Intel MPI's
  explicit-list rule (on each node, the i-th rank takes the list's i-th entry), every process gets a core of its own
  and every CCD (8 cores) the same number of SPs, on the first node and on the others. With the CP at another index
  among the first node's ranks, every process still gets a core of its own, and the CCDs stay even exactly when the CP
  is the first rank or one of the last k (k = SP_PER_NODE / 24);
- 192 SPs per node get a note and no list, 191 set by hand the default's note, the other counts a WARNING and no list,
  and PIN_EXPLICIT=0 neither; a core list set in the submitting shell never reaches exaqsub on those paths, and the
  script's own list replaces it on the others;
- SP_PER_NODE, DISC_NPROCS, PIN_EXPLICIT, USE_BUNDLED_IMPI, lscpu's count, the required variables and exaqsub's
  install are checked before the modules load and before any file is written, and the ends of the ranges and the
  switches' values are accepted;
- I_MPI_OFI_LIBRARY_INTERNAL=0 is exported before intelmpi loads, and libfabric-aws loads after it; LD_LIBRARY_PATH
  holds PowerFLOW's two library directories and no empty entry;
- exaqsub's command line for each MODE (an unknown MODE stops the job before exaqsub), the environment it gets
  (EXA_ALT_IMPI_ROOT, I_MPI_MULTIRAIL, the Hydra variables), and its exit status, which ends the job once EXA_TMPDIR
  is removed.

The script sources /etc/profile.d/modules.sh, so these tests run a copy of it that sources a stub modules.sh (its
`module` function) instead and differs from the script in that path alone (checked here). They run it with stubs of
lscpu, nproc, lspci, scontrol and exaqsub, from a temporary directory, with a clean environment and a PATH that holds
no other MPI, Slurm, ssh, curl, aws or sudo command: no PowerFLOW, MPI or Slurm is needed. The stub nproc answers as
GNU nproc does, OMP_NUM_THREADS and OMP_THREAD_LIMIT included, and logs every call: the script must make none. Every
value is synthetic.

Run with:
    python -m pip install -r tests/requirements.txt
    python -m pytest tests/test_powerflow_launcher.py -q
"""
from __future__ import annotations

import functools
import os
import re
import shutil
import subprocess
from collections import Counter
from dataclasses import dataclass
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "apps" / "PowerFlow" / "PowerFlow.sbatch"
FLEXIBLE_CORES = REPO / "Utils" / "flexible-cores" / "hello-cpu.intelmpi.explicit.sbatch"
MODULES = "/etc/profile.d/modules.sh"
BASH = shutil.which("bash")
pytestmark = pytest.mark.skipif(BASH is None, reason="needs bash")

JOB_ID = "4242"
VERSION = "synthetic-release"
CASE = "synthetic.cdi"
# The counts with a flexible-cores list on a 192-core node.
LISTED = (24, 48, 72, 96, 120, 144, 168)
# Host commands the script must not find: the stubs stand in for some of them, and it runs none of the others.
HIDDEN = frozenset({"nproc", "lscpu", "lspci", "scontrol", "srun", "sbatch", "squeue", "sinfo", "mpirun", "mpiexec",
                    "module", "exaqsub", "ssh", "curl", "aws", "sudo"})
# The variables the stub exaqsub notes, when they are set.
NOTED = ("I_MPI_PIN_PROCESSOR_LIST", "I_MPI_PIN", "I_MPI_PIN_DOMAIN", "I_MPI_PIN_ORDER", "LD_LIBRARY_PATH",
         "EXA_ALT_IMPI_ROOT", "EXA_TMPDIR", "I_MPI_OFI_LIBRARY_INTERNAL", "I_MPI_MULTIRAIL", "I_MPI_HYDRA_BOOTSTRAP",
         "HYDRA_BOOTSTRAP", "HYDRA_LAUNCHER_EXTRA_ARGS", "I_MPI_HYDRA_BOOTSTRAP_EXEC_EXTRA_ARGS")

# lscpu -p=CORE,SOCKET in the parse format: its "#" header lines, then one line per CPU (STUB_CORES cores on two
# sockets, STUB_THREADS CPUs per core). It logs the LC_ALL it was given ("unset" when none) and its arguments, and
# answers no other arguments.
LSCPU_STUB = r"""#!/bin/bash
printf '%s %s\n' "${LC_ALL-unset}" "$*" >> "${STATE}/lscpu.log"
[ "$*" = "-p=CORE,SOCKET" ] || { echo "lscpu stub: refusing $*" >&2; exit 1; }
echo "# The following is the parsable format, which can be fed to other"
echo "# programs. Each different item in every column has an unique ID"
echo "# starting usually from zero."
echo "# Core,Socket"
for (( t = 0; t < STUB_THREADS; t++ )); do
    for (( c = 0; c < STUB_CORES; c++ )); do echo "${c},$(( c * 2 / STUB_CORES ))"; done
done
"""
# GNU nproc's answer: the node's CPUs, or OMP_NUM_THREADS's first value, at most OMP_THREAD_LIMIT. It logs each call.
NPROC_STUB = r"""#!/bin/bash
printf '%s\n' "$*" >> "${STATE}/nproc.log"
n=$(( STUB_CORES * STUB_THREADS ))
[ -n "${OMP_NUM_THREADS:-}" ] && n=${OMP_NUM_THREADS%%,*}
[ -n "${OMP_THREAD_LIMIT:-}" ] && [ "${OMP_THREAD_LIMIT}" -lt "${n}" ] && n=${OMP_THREAD_LIMIT}
echo "${n}"
"""
# One ENA device, then STUB_EFA EFA devices.
LSPCI_STUB = r"""#!/bin/bash
echo "00:03.0 Ethernet controller: Amazon.com, Inc. Elastic Network Adapter (ENA)"
for (( i = 0; i < STUB_EFA; i++ )); do
    echo "00:1${i}.0 Ethernet controller: Amazon.com, Inc. Elastic Fabric Adapter (EFA)"
done
"""
# scontrol show hostnames <the job's node list>: STUB_HOSTS, one per line.
SCONTROL_STUB = r"""#!/bin/bash
[ "$#" = 3 ] && [ "$1" = show ] && [ "$2" = hostnames ] && [ "$3" = "${SLURM_JOB_NODELIST}" ] \
    || { echo "scontrol stub: refusing $*" >&2; exit 1; }
printf '%s\n' ${STUB_HOSTS}
"""
# The stub of /etc/profile.d/modules.sh: a module function that logs each call with the value
# I_MPI_OFI_LIBRARY_INTERNAL has at that moment ("unset" when none), and prepends a library directory for each module,
# as module load does; intelmpi also sets I_MPI_ROOT.
MODULES_STUB = r"""module() {
    printf '%s %s %s\n' "$1" "$2" "${I_MPI_OFI_LIBRARY_INTERNAL-unset}" >> "${STATE}/module.log"
    case "$1 $2" in
        "load intelmpi")
            export I_MPI_ROOT=/stub/intel/mpi
            export LD_LIBRARY_PATH="/stub/intel/mpi/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" ;;
        "load libfabric-aws")
            export LD_LIBRARY_PATH="/stub/libfabric-aws/lib64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" ;;
        *) echo "module stub: refusing $*" >&2; return 1 ;;
    esac
}
"""
# The stub exaqsub, in PF_ROOT/PF_VERSION/bin. For each call it notes, in its own directory, its arguments (one per
# line), its working directory, a copy of the hostfile given with -mpifile, each NOTED variable that is set, and
# whether EXA_TMPDIR is a directory; then it ends with STUB_RC.
EXAQSUB_STUB = r"""#!/bin/bash
n=1
while [ -e "${STATE}/exaqsub-call-${n}" ]; do n=$((n + 1)); done
d="${STATE}/exaqsub-call-${n}"
mkdir "${d}"
printf '%s\n' "$@" > "${d}/args"
pwd > "${d}/cwd"
prev=""
for a in "$@"; do
    [ "${prev}" = -mpifile ] && cp "${a}" "${d}/hostfile"
    prev=${a}
done
for v in ${STUB_NOTED}; do
    [ "${!v+set}" = set ] && printf '%s' "${!v}" > "${d}/env.${v}"
done
[ -d "${EXA_TMPDIR:-/nonexistent}" ] && touch "${d}/exa-tmpdir-exists"
echo "[stub exaqsub] done"
exit "${STUB_RC}"
"""

COMMON = ["-nolock", "-foreground", "-impi", "-mpirsh", "ssh", "-mpifile", f"hostfile.{JOB_ID}"]


def discretize(procs: int) -> list[str]:
    return ["-discretize", "-disc_log", "discretizer.log", "-discnprocs", str(procs)]


def simulate(procs: int) -> list[str]:
    return ["-simulate", "-sim_log", "simulator.log", "--nprocs", str(procs)]


def default_note(sps: int) -> str:
    return f"Note: {sps} SPs per node leave the CP a core of its own; Intel MPI places the ranks, one per core."


@dataclass
class Job:
    proc: subprocess.CompletedProcess
    calls: list[dict]           # exaqsub's calls, as the stub noted them
    modules: list[list[str]]    # each module call: its two arguments and I_MPI_OFI_LIBRARY_INTERNAL at that moment
    lscpu: list[str]            # each lscpu call: its LC_ALL and its arguments
    nproc: list[str]            # each nproc call's arguments
    case_dir: Path


@pytest.fixture(scope="session")
def host_tools(tmp_path_factory) -> Path:
    """A directory of links to the host's commands, without the HIDDEN ones."""
    tools = tmp_path_factory.mktemp("host-tools")
    for directory in os.environ.get("PATH", "").split(os.pathsep):
        try:
            entries = list(os.scandir(directory or "."))
        except OSError:
            continue
        for entry in entries:
            link = tools / entry.name
            if entry.name in HIDDEN or link.is_symlink():
                continue
            try:
                if entry.is_file() and os.access(entry.path, os.X_OK):
                    link.symlink_to(entry.path)
            except OSError:
                continue
    return tools


@functools.cache
def flexible_cores_lists() -> dict[int, str]:
    """The I_MPI_PIN_PROCESSOR_LIST of each cores-per-node count in hello-cpu.intelmpi.explicit.sbatch's case."""
    lists: dict[int, str] = {}
    count = None
    for line in FLEXIBLE_CORES.read_text().splitlines():
        if m := re.fullmatch(r"\s*(\d+)\)", line):
            count = int(m.group(1))
        elif (m := re.fullmatch(r'\s*export I_MPI_PIN_PROCESSOR_LIST="([0-9,]+)"', line)) and count is not None:
            lists[count] = m.group(1)
            count = None
    assert sorted(lists) == [*LISTED, 192], sorted(lists)
    return lists


def runnable_copy(work: Path) -> Path:
    """The script, with /etc/profile.d/modules.sh replaced by the stub modules.sh in `work`: the copy differs from the
    script in that path alone."""
    text = SCRIPT.read_text()
    assert text.count(MODULES) == 1, "the script names /etc/profile.d/modules.sh in other places"
    stub = str(work / "modules.sh")
    copy = work / "PowerFlow.sbatch"
    copy.write_text(text.replace(MODULES, stub))
    assert copy.read_text().replace(stub, MODULES) == text
    return copy


def run(work: Path, tools: Path, nodes: int = 2, cores: int | None = 192, threads: int = 1, efa: int = 2,
        rc: int = 0, install: bool = True, env: dict[str, str | None] | None = None) -> Job:
    """Run the copy of the script as a job on `nodes` nodes n1, n2, ..., submitted from `work`/case, on nodes of
    `cores` physical cores (None: no lscpu at all) with `threads` CPUs per core and `efa` EFA devices, the stub
    exaqsub ending with `rc` (`install`: whether exaqsub is in PF_ROOT/PF_VERSION/bin). `env` adds variables to the
    job's environment, or unsets them (None). The job's LC_ALL is POSIX: the C locale under another name, so that the
    C locale shows in lscpu's log only if the script sets it."""
    stubs, state, case_dir = work / "stubs", work / "state", work / "case"
    pf_bin = work / "pf" / VERSION / "bin"
    for d in (stubs, state, case_dir, pf_bin):
        d.mkdir(parents=True)
    texts = {stubs / "nproc": NPROC_STUB, stubs / "lspci": LSPCI_STUB, stubs / "scontrol": SCONTROL_STUB}
    if cores is not None:
        texts[stubs / "lscpu"] = LSCPU_STUB
    if install:
        texts[pf_bin / "exaqsub"] = EXAQSUB_STUB
    for path, text in texts.items():
        path.write_text(text)
        path.chmod(0o755)
    (work / "modules.sh").write_text(MODULES_STUB)
    (case_dir / CASE).write_text("synthetic case\n")
    hosts = [f"n{i}" for i in range(1, nodes + 1)]
    job_env = {"PATH": f"{stubs}{os.pathsep}{tools}", "HOME": str(work), "LC_ALL": "POSIX", "STATE": str(state),
               "STUB_CORES": str(cores or 0), "STUB_THREADS": str(threads), "STUB_EFA": str(efa), "STUB_RC": str(rc),
               "STUB_HOSTS": " ".join(hosts), "STUB_NOTED": " ".join(NOTED), "SLURM_JOB_ID": JOB_ID,
               "SLURM_JOB_NUM_NODES": str(nodes), "SLURM_JOB_NODELIST": "n1" if nodes == 1 else f"n[1-{nodes}]",
               "SLURM_SUBMIT_DIR": str(case_dir), "PF_ROOT": str(work / "pf"), "PF_VERSION": VERSION,
               "PF_CASE": CASE, "DSLS_POWERFLOW_LICENSE": "<server>:<port>"}
    for name, value in (env or {}).items():
        if value is None:
            job_env.pop(name, None)
        else:
            job_env[name] = value
    proc = subprocess.run([BASH, str(runnable_copy(work))], cwd=case_dir, env=job_env, capture_output=True, text=True,
                          errors="replace", timeout=120)
    calls = []
    for d in sorted(state.glob("exaqsub-call-*"), key=lambda p: int(p.name.rsplit("-", 1)[1])):
        calls.append({"args": (d / "args").read_text().splitlines(), "cwd": (d / "cwd").read_text().strip(),
                      "hostfile": (d / "hostfile").read_text().splitlines() if (d / "hostfile").exists() else None,
                      "env": {v: (d / f"env.{v}").read_text() if (d / f"env.{v}").exists() else None for v in NOTED},
                      "tmpdir": (d / "exa-tmpdir-exists").exists()})

    def log(name: str) -> list[str]:
        return (state / name).read_text().splitlines() if (state / name).exists() else []

    return Job(proc, calls, [line.split() for line in log("module.log")], log("lscpu.log"), log("nproc.log"),
               case_dir)


def started(job: Job) -> dict:
    """The job called exaqsub once and ended with its exit status, 0: that call."""
    assert job.proc.returncode == 0, job.proc.stdout + job.proc.stderr
    assert len(job.calls) == 1, job.calls
    return job.calls[0]


def assert_refused(job: Job, message: str) -> None:
    """The job stopped with exit status 1 and `message` at the end of a line on stderr, before the modules loaded and
    before it wrote any file or called exaqsub."""
    assert job.proc.returncode == 1, job.proc.stdout + job.proc.stderr
    assert any(line.endswith(message) for line in job.proc.stderr.splitlines()), job.proc.stderr
    assert job.calls == []
    assert job.modules == []
    assert sorted(p.name for p in job.case_dir.iterdir()) == [CASE]


def placement(hostfile: list[str], pinned: str) -> dict[str, list[tuple[str, int]]]:
    """Each node's processes, in rank order, with their cores, under Intel MPI's explicit-list rule: the ranks follow
    the hostfile ("cp <host>", then "<SPs> <host>" lines), and on each node the i-th rank takes the list's i-th entry,
    from its start again past its end."""
    cores = [int(c) for c in pinned.split(",")]
    nodes: dict[str, list[tuple[str, int]]] = {}
    for line in hostfile:
        what, host = line.split()
        ranks = nodes.setdefault(host, [])
        for _ in range(1 if what == "cp" else int(what)):
            ranks.append(("cp" if what == "cp" else "sp", cores[len(ranks) % len(cores)]))
    return nodes


def even_ccds(cores, k: int) -> bool:
    """k of `cores` on every one of the 24 CCDs of 8 cores of a 192-core node."""
    return Counter(core // 8 for core in cores) == {ccd: k for ccd in range(24)}


DEFAULTS = {
    "a 192-core node": (192, 1, {}),
    "OMP_NUM_THREADS=1 and OMP_THREAD_LIMIT=1 exported": (192, 1, {"OMP_NUM_THREADS": "1", "OMP_THREAD_LIMIT": "1"}),
    "SMT on: 384 CPUs, 192 cores": (192, 2, {}),
    "a 96-core node": (96, 1, {}),
}


@pytest.mark.parametrize("cores, threads, env", list(DEFAULTS.values()), ids=list(DEFAULTS))
def test_the_default_is_one_sp_per_physical_core_but_one_with_no_list(cores, threads, env, tmp_path, host_tools):
    """The count comes from lscpu, in the C locale, never from nproc; the note is on stdout, nothing on stderr."""
    job = run(tmp_path, host_tools, cores=cores, threads=threads, env=env)
    call = started(job)
    sps = cores - 1
    assert call["hostfile"] == ["cp n1", f"{sps} n1", f"{sps} n2"]
    assert call["args"] == [*COMMON, *simulate(2 * sps), CASE]
    assert call["env"]["I_MPI_PIN_PROCESSOR_LIST"] is None
    assert default_note(sps) in job.proc.stdout.splitlines()
    assert job.proc.stderr == ""
    assert job.lscpu == ["C -p=CORE,SOCKET"]
    assert job.nproc == []


def test_191_set_by_hand_runs_as_the_default(tmp_path, host_tools):
    job = run(tmp_path, host_tools, env={"SP_PER_NODE": "191"})
    call = started(job)
    assert call["hostfile"] == ["cp n1", "191 n1", "191 n2"]
    assert call["env"]["I_MPI_PIN_PROCESSOR_LIST"] is None
    assert default_note(191) in job.proc.stdout.splitlines()
    assert job.proc.stderr == ""


@pytest.mark.parametrize("sps", LISTED)
def test_the_list_is_core_191_then_the_flexible_cores_list_of_the_same_count(sps, tmp_path, host_tools):
    job = run(tmp_path, host_tools, env={"SP_PER_NODE": str(sps)})
    call = started(job)
    pinned = call["env"]["I_MPI_PIN_PROCESSOR_LIST"]
    assert pinned == "191," + flexible_cores_lists()[sps]
    entries = pinned.split(",")
    assert len(entries) == len(set(entries)) == sps + 1
    assert call["hostfile"] == ["cp n1", f"{sps} n1", f"{sps} n2"]
    assert job.proc.stderr == ""


@pytest.mark.parametrize("nodes", [1, 2, 3])
@pytest.mark.parametrize("sps", LISTED)
def test_the_list_gives_every_process_a_core_and_k_sps_to_every_ccd_on_every_node(sps, nodes, tmp_path, host_tools):
    """The CP alone on core 191 on the first node; on the others, the first SP on 191 and the list's last core free."""
    call = started(run(tmp_path, host_tools, nodes=nodes, env={"SP_PER_NODE": str(sps)}))
    pinned = call["env"]["I_MPI_PIN_PROCESSOR_LIST"]
    last = int(pinned.split(",")[-1])
    on = placement(call["hostfile"], pinned)
    assert list(on) == [f"n{i}" for i in range(1, nodes + 1)]
    for i, (host, ranks) in enumerate(on.items()):
        used = [core for _, core in ranks]
        assert len(used) == len(set(used)), (host, ranks)
        assert even_ccds([core for what, core in ranks if what == "sp"], sps // 24), (host, ranks)
        if i == 0:
            assert ranks[0] == ("cp", 191) and [what for what, _ in ranks].count("cp") == 1, ranks
        else:
            assert ranks[0] == ("sp", 191) and last not in used, (host, ranks)


@pytest.mark.parametrize("sps", LISTED)
def test_with_the_cp_at_any_index_the_ccds_stay_even_only_at_the_first_or_one_of_the_last_k(sps, tmp_path, host_tools):
    """The first node runs SP_PER_NODE + 1 ranks on as many distinct list entries, so every process gets a core of its
    own wherever the CP is among them. The CP takes the list entry at its own index and the SPs every other one, which
    give every CCD k SPs exactly when the CP's index is 0 or one of the last k."""
    call = started(run(tmp_path, host_tools, env={"SP_PER_NODE": str(sps)}))
    pinned = [int(c) for c in call["env"]["I_MPI_PIN_PROCESSOR_LIST"].split(",")]
    k = sps // 24
    assert len(pinned) == len(set(pinned)) == sps + 1
    even = {cp for cp in range(sps + 1) if even_ccds(pinned[:cp] + pinned[cp + 1:], k)}
    assert even == {0, *range(sps + 1 - k, sps + 1)}


def test_192_sps_per_node_get_the_note_and_no_list(tmp_path, host_tools):
    job = run(tmp_path, host_tools, env={"SP_PER_NODE": "192"})
    call = started(job)
    assert call["env"]["I_MPI_PIN_PROCESSOR_LIST"] is None
    assert "Note: 192 SPs per node leave no free core; the CP shares one with an SP." in job.proc.stdout.splitlines()
    assert job.proc.stderr == ""


@pytest.mark.parametrize("sps", [100, 128])
def test_a_count_with_no_list_runs_on_intel_mpis_placement_with_a_warning(sps, tmp_path, host_tools):
    job = run(tmp_path, host_tools, env={"SP_PER_NODE": str(sps)})
    call = started(job)
    assert call["env"]["I_MPI_PIN_PROCESSOR_LIST"] is None
    assert job.proc.stderr.splitlines() == [
        f"WARNING: no flexible-cores list for 192 cores and {sps} SPs per node; Intel MPI places the ranks. Use 24, "
        "48, 72, 96, 120, 144 or 168 on a 192-core node."]
    assert not any(line.startswith("Note:") for line in job.proc.stdout.splitlines())


@pytest.mark.parametrize("env", [{"SP_PER_NODE": "120"}, {}], ids=["120", "the default"])
def test_pin_explicit_0_leaves_the_placement_to_intel_mpi(env, tmp_path, host_tools):
    job = run(tmp_path, host_tools, env={"PIN_EXPLICIT": "0", **env})
    call = started(job)
    assert call["env"]["I_MPI_PIN_PROCESSOR_LIST"] is None
    assert not any(line.startswith(("Note:", "WARNING:")) for line in job.proc.stdout.splitlines())
    assert job.proc.stderr == ""


# Pinning settings exported in the submitting shell, which sbatch passes to the job.
STRAY = {"I_MPI_PIN_PROCESSOR_LIST": "0-191", "I_MPI_PIN_DOMAIN": "numa", "I_MPI_PIN_ORDER": "scatter"}
NO_LIST = {"the default": {}, "192": {"SP_PER_NODE": "192"}, "100": {"SP_PER_NODE": "100"},
           "PIN_EXPLICIT=0": {"PIN_EXPLICIT": "0", "SP_PER_NODE": "120"}}


@pytest.mark.parametrize("env", list(NO_LIST.values()), ids=list(NO_LIST))
def test_a_core_list_from_the_submitting_shell_never_reaches_exaqsub_on_a_path_without_a_list(env, tmp_path,
                                                                                              host_tools):
    call = started(run(tmp_path, host_tools, env={**STRAY, **env}))
    assert {v: call["env"][v] for v in STRAY} == dict.fromkeys(STRAY)
    assert call["env"]["I_MPI_PIN"] == "1"


@pytest.mark.parametrize("sps", LISTED)
def test_on_a_path_with_a_list_the_scripts_list_replaces_the_submitting_shells(sps, tmp_path, host_tools):
    call = started(run(tmp_path, host_tools, env={**STRAY, "SP_PER_NODE": str(sps)}))
    assert call["env"]["I_MPI_PIN_PROCESSOR_LIST"] == "191," + flexible_cores_lists()[sps]
    assert call["env"]["I_MPI_PIN_DOMAIN"] is None and call["env"]["I_MPI_PIN_ORDER"] is None


SP_RANGE = "use a whole number from 1 to 192, this node's physical cores"
DISC_RANGE = "use a whole number from 1 to 384, the job's cores"
REFUSED = [
    *(pytest.param({"SP_PER_NODE": v}, f"ERROR: SP_PER_NODE={v}: {SP_RANGE}", id=f"SP_PER_NODE={v!r}")
      for v in ("0", "0120", "abc", "-5", "+5", " 120", "1e2", "193", "9999999")),
    *(pytest.param({"DISC_NPROCS": v}, f"ERROR: DISC_NPROCS={v}: {DISC_RANGE}", id=f"DISC_NPROCS={v!r}")
      for v in ("0", "08", "x", "385")),
    *(pytest.param({name: v}, f"ERROR: {name}={v}: use 0 or 1", id=f"{name}={v!r}")
      for name in ("PIN_EXPLICIT", "USE_BUNDLED_IMPI") for v in ("2", "true", "yes")),
]


@pytest.mark.parametrize("env, message", REFUSED)
def test_a_value_out_of_its_range_stops_the_job_before_anything_runs(env, message, tmp_path, host_tools):
    """On a 2-node job of 192-core nodes: SP_PER_NODE from 1 to 192 and DISC_NPROCS from 1 to 384, each a whole
    number with no sign and no leading zero, and the switches unset, empty, 0 or 1."""
    assert_refused(run(tmp_path, host_tools, env=env), message)


@pytest.mark.parametrize("cores", [None, 0], ids=["no lscpu", "lscpu shows no CPU"])
def test_no_core_count_from_lscpu_stops_the_job_before_anything_runs(cores, tmp_path, host_tools):
    assert_refused(run(tmp_path, host_tools, cores=cores), "ERROR: lscpu shows no cores on this node")


@pytest.mark.parametrize("sps", [1, 192])
def test_sp_per_node_from_1_to_the_nodes_physical_cores_is_accepted(sps, tmp_path, host_tools):
    call = started(run(tmp_path, host_tools, env={"SP_PER_NODE": str(sps)}))
    assert call["hostfile"] == ["cp n1", f"{sps} n1", f"{sps} n2"]
    assert call["args"] == [*COMMON, *simulate(2 * sps), CASE]


def test_disc_nprocs_up_to_the_jobs_cores_is_accepted(tmp_path, host_tools):
    call = started(run(tmp_path, host_tools, env={"DISC_NPROCS": "384", "MODE": "discretize"}))
    assert call["args"] == [*COMMON, *discretize(384), CASE]


@pytest.mark.parametrize("value", ["", "0", "1"], ids=["empty", "0", "1"])
@pytest.mark.parametrize("name", ["PIN_EXPLICIT", "USE_BUNDLED_IMPI"])
def test_the_switches_take_empty_0_and_1(name, value, tmp_path, host_tools):
    """Empty is the default: the core list on, the system Intel MPI."""
    call = started(run(tmp_path, host_tools, env={name: value, "SP_PER_NODE": "120"}))
    if name == "PIN_EXPLICIT":
        assert (call["env"]["I_MPI_PIN_PROCESSOR_LIST"] is None) == (value == "0")
    else:
        assert (call["env"]["EXA_ALT_IMPI_ROOT"] is None) == (value == "1")


def test_intelmpi_loads_with_the_internal_libfabric_off_then_libfabric_aws(tmp_path, host_tools):
    """I_MPI_OFI_LIBRARY_INTERNAL=0 is exported before `module load intelmpi`, and libfabric-aws loads after it."""
    job = run(tmp_path, host_tools)
    call = started(job)
    assert job.modules == [["load", "intelmpi", "0"], ["load", "libfabric-aws", "0"]]
    assert call["env"]["I_MPI_OFI_LIBRARY_INTERNAL"] == "0"


@pytest.mark.parametrize("before", [None, "", "/synthetic/lib"], ids=["unset", "empty", "set"])
def test_ld_library_path_holds_powerflows_libraries_and_no_empty_entry(before, tmp_path, host_tools):
    """PowerFLOW's two library directories, then the job's own value when it has one."""
    entries = started(run(tmp_path, host_tools, env={"LD_LIBRARY_PATH": before}))["env"]["LD_LIBRARY_PATH"].split(":")
    assert "" not in entries, entries
    dist = tmp_path / "pf" / VERSION / "dist" / "x86_linux"
    i = entries.index(str(dist / "lib"))
    assert entries[i:] == [str(dist / "lib"), str(dist / "lib64"), *([before] if before else [])], entries


MODES = {
    "the default": (None, simulate(382)),
    "simulate": ("simulate", simulate(382)),
    "discretize": ("discretize", discretize(8)),
    "all": ("all", [*discretize(8), *simulate(382)]),
}


@pytest.mark.parametrize("mode, steps", list(MODES.values()), ids=list(MODES))
def test_exaqsub_runs_in_the_foreground_in_the_submit_directory_with_the_steps_of_mode(mode, steps, tmp_path,
                                                                                       host_tools):
    job = run(tmp_path, host_tools, env={"MODE": mode})
    call = started(job)
    assert call["args"] == [*COMMON, *steps, CASE]
    assert "--impi" not in call["args"]
    assert call["cwd"] == str(job.case_dir)
    assert call["hostfile"] == ["cp n1", "191 n1", "191 n2"]


def test_an_unknown_mode_stops_the_job_before_exaqsub(tmp_path, host_tools):
    job = run(tmp_path, host_tools, env={"MODE": "simulation"})
    assert job.proc.returncode == 1, job.proc.stdout + job.proc.stderr
    assert "ERROR: unknown MODE=simulation" in job.proc.stderr.splitlines()
    assert job.calls == []


@pytest.mark.parametrize("rc", [0, 3])
def test_the_job_ends_with_exaqsubs_exit_status_once_exa_tmpdir_is_removed(rc, tmp_path, host_tools):
    job = run(tmp_path, host_tools, rc=rc)
    assert job.proc.returncode == rc, job.proc.stdout + job.proc.stderr
    assert len(job.calls) == 1, job.calls
    tmp = job.case_dir / f"exa_tmp_{JOB_ID}"
    assert job.calls[0]["env"]["EXA_TMPDIR"] == str(tmp) and job.calls[0]["tmpdir"]
    assert not tmp.exists()
    assert any(line.startswith(f"exaqsub exit code {rc}, elapsed ") for line in job.proc.stdout.splitlines())


def test_the_hydra_settings_for_the_slurm_launcher_are_dropped_and_the_bootstrap_is_ssh(tmp_path, host_tools):
    hydra = {"HYDRA_BOOTSTRAP": "slurm", "HYDRA_LAUNCHER_EXTRA_ARGS": "--external-launcher",
             "I_MPI_HYDRA_BOOTSTRAP": "slurm", "I_MPI_HYDRA_BOOTSTRAP_EXEC_EXTRA_ARGS": "--external-launcher"}
    call = started(run(tmp_path, host_tools, env=hydra))
    assert {v: call["env"][v] for v in hydra} == {
        "HYDRA_BOOTSTRAP": None, "HYDRA_LAUNCHER_EXTRA_ARGS": None, "I_MPI_HYDRA_BOOTSTRAP": "ssh",
        "I_MPI_HYDRA_BOOTSTRAP_EXEC_EXTRA_ARGS": None}


@pytest.mark.parametrize("bundled, root", [(None, "/stub/intel/mpi"), ("1", None)],
                         ids=["the system Intel MPI", "USE_BUNDLED_IMPI=1"])
def test_exa_alt_impi_root_is_the_loaded_intel_mpi_unless_the_bundled_one_is_kept(bundled, root, tmp_path,
                                                                                  host_tools):
    call = started(run(tmp_path, host_tools, env={"USE_BUNDLED_IMPI": bundled}))
    assert call["env"]["EXA_ALT_IMPI_ROOT"] == root


@pytest.mark.parametrize("efa, multirail", [(2, "1"), (1, None)], ids=["two EFA devices", "one EFA device"])
def test_multirail_with_two_efa_devices(efa, multirail, tmp_path, host_tools):
    call = started(run(tmp_path, host_tools, efa=efa))
    assert call["env"]["I_MPI_MULTIRAIL"] == multirail


REQUIRED = {
    "PF_VERSION": "PF_VERSION: set PF_VERSION to the directory of the install under PF_ROOT",
    "PF_CASE": "PF_CASE: set PF_CASE to the .cdi file",
    "DSLS_POWERFLOW_LICENSE": "DSLS_POWERFLOW_LICENSE: set DSLS_POWERFLOW_LICENSE to "
                              "<server>:<port>[,<server>:<port>...]",
}


@pytest.mark.parametrize("name", list(REQUIRED))
def test_a_required_variable_unset_stops_the_job_before_anything_runs(name, tmp_path, host_tools):
    assert_refused(run(tmp_path, host_tools, env={name: None}), REQUIRED[name])


def test_no_exaqsub_in_the_install_stops_the_job_before_anything_runs(tmp_path, host_tools):
    job = run(tmp_path, host_tools, install=False)
    assert_refused(job, f"ERROR: {tmp_path / 'pf' / VERSION / 'bin' / 'exaqsub'} not found")
