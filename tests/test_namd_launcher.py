"""How apps/NAMD/x86/namd-benchmark.sbatch checks its settings, fetches a deck and starts a NAMD benchmark run.

These tests pin:
- the settings it refuses before mpirun starts (MODEL, TIMESTEPS, PPN, BASE_DIR);
- the deck: fetched from the NAMD utilities page into BASE_DIR/benchmarks/<MODEL>/ when the cache lacks it, reused
  with no download when it holds it, and copied into a run directory of its own;
- the run's config: numsteps from TIMESTEPS, and an outputTiming line when the deck has none;
- mpirun's command line, on one node and on two (where the job first checks EFA with fi_info), and NAMD's PEs;
- the result: days/ns from the last "Benchmark time:" line, ns/day = 1 / days/ns, and the NAMDRESULT line;
- the instance type from the instance metadata (IMDSv2): each request fails on an HTTP error and gives up after a few
  seconds, and an answer cut off at that limit, or one that is not an instance type name (tested in the C locale),
  counts as none. The banner, the run directory and NAMDRESULT then say "unknown", and the run goes on;
- the build: with NAMD_ENV unset, the build of the node's instance family under BASE_DIR/x86_64/<version>-<family>/
  (the highest version), else the only build there, with a NOTE, else a stop that asks for NAMD_ENV; and an AVX-512
  build on a CPU without AVX-512, refused before anything runs;
- cores per node on hpc8a.96xlarge and hpc7a.96xlarge: PPN 23, 47, 71, 95, 119, 143 and 167 pin the communication
  thread to the first core of the flexible-cores list of PPN + 1 cores in
  Utils/flexible-cores/hello-cpu.openmpi.explicit.sbatch and the PEs to the rest, which puts (PPN + 1) / 24 threads on
  every CCD, on every node; PPN 191 and 192 fill the node with no list; any other PPN stops the job before anything
  runs. With no instance type, lscpu decides (in the C locale), and only below a full node: a 192-core AMD node gets
  the same check and lists, any other node none, each with a NOTE. Other types get no list and no check.

They run the script with stubs of curl (the instance metadata and the deck downloads), srun, fi_info, nproc, lscpu
and mpirun, from a temporary directory, with a clean environment and a PATH that holds no other MPI, Slurm, ssh, curl, aws
or sudo command: no NAMD, MPI, Slurm or network is needed. The stub mpirun notes its arguments and prints a synthetic
namd.out. The script reads /proc/cpuinfo, so these tests run a copy of it that reads a synthetic cpuinfo instead and
differs from the script in that path alone (checked here). Every value is synthetic.

Run with:
    python -m pip install -r tests/requirements.txt
    python -m pytest tests/test_namd_launcher.py -q
"""
from __future__ import annotations

import io
import os
import re
import shutil
import subprocess
import tarfile
from dataclasses import dataclass
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "apps" / "NAMD" / "x86" / "namd-benchmark.sbatch"
FLEXIBLE_CORES = REPO / "Utils" / "flexible-cores" / "hello-cpu.openmpi.explicit.sbatch"
BASH = shutil.which("bash")
pytestmark = pytest.mark.skipif(BASH is None, reason="needs bash")

JOB_ID = "4242"
UTILITIES = "https://www.ks.uiuc.edu/Research/namd/utilities/"
# Host commands the script must not find: the stubs stand in for some of them, and it runs none of the others.
HIDDEN = frozenset({"curl", "srun", "sbatch", "scontrol", "squeue", "sinfo", "mpirun", "mpiexec", "module", "lscpu",
                    "nproc", "fi_info", "namd3", "ssh", "aws", "sudo"})

# Each deck: its tarball's name, its top directory, its config, and the lines of its config (keywords as in the
# decks on the NAMD utilities page, values synthetic).
DECKS = {
    "ApoA1": ("apoa1.tar.gz", "apoa1", "apoa1.namd",
              ["structure            apoa1.psf", "coordinates          apoa1.pdb", "timestep             1.0",
               "stepspercycle        20", "numsteps             500", "outputtiming         20",
               "outputname           /usr/tmp/apoa1-out"]),
    "STMV": ("stmv.tar.gz", "stmv", "stmv.namd",
             ["structure           stmv.psf", "coordinates         stmv.pdb", "timestep            1.0",
              "stepspercycle       20", "outputName          /usr/tmp/stmv-output", "outputTiming        20",
              "numsteps 500"]),
}
DECK_DATA = ("psf", "pdb")   # the other files of a deck, named <top>.<ext>

# The stub curl. It logs each call's arguments to STATE/curl.log. The instance metadata answers as STUB_IMDS says:
# ok (a token, then STUB_INSTANCE_TYPE), none (no answer: exit 28, no output), error (an HTTP error: exit 22 and no
# output under -f, an HTML page and exit 0 without it), text (STUB_IMDS_TEXT for the type), cut-off (the type less
# its last five characters, then exit 28). A deck URL copies STUB_DECKS/<tarball> to the -o path. Anything else:
# exit 22.
CURL_STUB = r"""#!/bin/bash
printf '%s\n' "$*" >> "${STATE}/curl.log"
url="" out="" fail=0 prev=""
for a in "$@"; do
    case "${prev}" in -o|--output) out="${a}" ;; esac
    case "${a}" in
        http://*|https://*) url="${a}" ;;
        --fail) fail=1 ;;
        --*) ;;
        -*f*) fail=1 ;;
    esac
    prev="${a}"
done
page='<html><head><title>404 Not Found</title></head>
<body><h1>Not Found</h1><p>The requested URL /latest/meta-data/ was not found on this server.</p></body></html>'
case "${url}" in
    http://169.254.169.254/latest/api/token)
        case "${STUB_IMDS}" in
            none) exit 28 ;;
            error) [ "${fail}" = 1 ] && exit 22; printf '%s' "${page}"; exit 0 ;;
            *) printf 'stub-token'; exit 0 ;;
        esac ;;
    http://169.254.169.254/latest/meta-data/instance-type)
        case "${STUB_IMDS}" in
            ok) printf '%s' "${STUB_INSTANCE_TYPE}"; exit 0 ;;
            none) exit 28 ;;
            error) [ "${fail}" = 1 ] && exit 22; printf '%s' "${page}"; exit 0 ;;
            text) printf '%s' "${STUB_IMDS_TEXT}"; exit 0 ;;
            cut-off) printf '%s' "${STUB_INSTANCE_TYPE%?????}"; exit 28 ;;
        esac ;;
    https://www.ks.uiuc.edu/Research/namd/utilities/*.tar.gz)
        name="${url##*/}"
        [ -n "${out}" ] && [ -f "${STUB_DECKS}/${name}" ] || exit 22
        cp "${STUB_DECKS}/${name}" "${out}"
        exit 0 ;;
esac
exit 22
"""
# srun: logs its arguments and does nothing else.
SRUN_STUB = r"""#!/bin/bash
printf '%s\n' "$*" >> "${STATE}/srun.log"
"""
# fi_info: an EFA provider listing, then exit STUB_FI_RC.
FI_INFO_STUB = r"""#!/bin/bash
printf '%s\n' "$*" >> "${STATE}/fi_info.log"
echo "provider: efa"
echo "    fabric: efa"
echo "    domain: rdmap0s0-rdm"
echo "    version: 122.0"
exit "${STUB_FI_RC:-0}"
"""
NPROC_STUB = r"""#!/bin/bash
echo 192
"""
# lscpu, as LC_ALL=C lscpu prints its summary: STUB_LSCPU is amd-192 (AuthenticAMD, 2 sockets of 96 cores), intel-192
# (GenuineIntel, 2 x 96), amd-96 (AuthenticAMD, 2 x 48) or fail (exit 1). It logs the LC_ALL it was given ("unset"
# when none).
LSCPU_STUB = r"""#!/bin/bash
printf '%s\n' "${LC_ALL-unset}" >> "${STATE}/lscpu.log"
case "${STUB_LSCPU:-amd-192}" in
    amd-192) vendor=AuthenticAMD per=96 ;;
    intel-192) vendor=GenuineIntel per=96 ;;
    amd-96) vendor=AuthenticAMD per=48 ;;
    *) exit 1 ;;
esac
echo "Architecture:                    x86_64"
echo "CPU(s):                          $(( 2 * per ))"
echo "Vendor ID:                       ${vendor}"
echo "  Thread(s) per core:            1"
echo "  Core(s) per socket:            ${per}"
echo "  Socket(s):                     2"
"""
# mpirun: for each call it notes, in its own directory, its arguments (one per line), its working directory,
# FI_PROVIDER ("unset" when none) and a copy of the run config (its last argument); then it prints a synthetic
# namd.out (STUB_NAMD_OUT: complete, no-wallclock, zero-days, no-bench or sci-days) and ends with STUB_RC. Like NAMD,
# it prints three "Initial time:" lines and then one "Benchmark time:" line per 100 steps from step 400 to 900; the
# last one gives STUB_DAYS days/ns, the others 0.5.
MPIRUN_STUB = r"""#!/bin/bash
n=1
while [ -e "${STATE}/mpirun-call-${n}" ]; do n=$((n + 1)); done
d="${STATE}/mpirun-call-${n}"
mkdir "${d}"
printf '%s\n' "$@" > "${d}/args"
pwd > "${d}/cwd"
printf '%s' "${FI_PROVIDER-unset}" > "${d}/fi_provider"
conf="${!#}"
[ -f "${conf}" ] && cp "${conf}" "${d}/config"
steps="$(awk 'tolower($1) == "numsteps" { s = $2 } END { print s + 0 }' "${conf}" 2>/dev/null)"
phases=$(( steps / 100 )); [ "${phases}" -gt 9 ] && phases=9
bench=$(( phases > 3 ? phases - 3 : 0 ))
days="${STUB_DAYS:-0.25}"
case "${STUB_NAMD_OUT:-complete}" in
    zero-days) days=0 ;;
    sci-days) days=1.5e-05 ;;
    no-bench) bench=0 ;;
esac
echo "Charm++> cpu affinity enabled. "
echo "Info: NAMD 3.0.2 for Linux-x86_64-MPI-smp"
echo "Info: TIMESTEP               1"
echo "Info: NUMBER OF STEPS        ${steps}"
echo "Info: 123456 ATOMS"
for i in 1 2 3; do echo "Info: Initial time: 191 CPUs 0.05 s/step 0.6 days/ns 1000 MB memory"; done
for (( i = 1; i <= bench; i++ )); do
    if [ "${i}" -eq "${bench}" ]; then v="${days}"; else v=0.5; fi
    echo "Info: Benchmark time: 191 CPUs 0.04 s/step ${v} days/ns 1000 MB memory"
done
if [ "${STUB_NAMD_OUT:-complete}" != no-wallclock ]; then
    echo "WallClock: 12.500000  CPUTime: 12.000000  Memory: 1000.000000 MB"
    echo "[Partition 0][Node 0] End of program"
fi
exit "${STUB_RC:-0}"
"""
# namd3, from the synthetic build: the stub mpirun never runs it.
NAMD3_STUB = "#!/bin/bash\necho 'namd3 stub: not to be run' >&2\nexit 99\n"
# The flags line of /proc/cpuinfo on a CPU with AVX-512 and on one without.
CPUINFO_AVX512 = "processor\t: 0\nflags\t\t: fpu sse2 avx avx2 fma avx512f avx512dq avx512bw avx512vl\n"
CPUINFO_AVX2 = "processor\t: 0\nflags\t\t: fpu sse2 avx avx2 fma\n"
# The build the launcher picks on an hpc8a node.
HPC8A_BUILD = ("3.0.2-hpc8a", {"NAMD_TARGET_CPU": "hpc8a", "NAMD_ISA": "avx512"})


@dataclass
class Job:
    proc: subprocess.CompletedProcess
    calls: list[dict]     # mpirun's calls, as the stub noted them
    curl: list[str]       # each curl call's arguments
    srun: list[str]       # each srun call's arguments
    fi_info: list[str]    # each fi_info call's arguments
    lscpu: list[str]      # each lscpu call's LC_ALL
    base: Path            # BASE_DIR
    state: Path

    @property
    def out(self) -> list[str]:
        return self.proc.stdout.splitlines()

    @property
    def err(self) -> list[str]:
        return self.proc.stderr.splitlines()

    def run_dirs(self) -> list[Path]:
        run = self.base / "Run"
        return sorted(run.iterdir()) if run.is_dir() else []


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


def deck_tarball(model: str, lines: list[str] | None = None) -> bytes:
    """The deck's tarball: its top directory, its config and its data files."""
    name, top, conf, default = DECKS[model]
    files = {conf: "\n".join(default if lines is None else lines) + "\n"}
    files.update({f"{top}.{ext}": f"synthetic {ext}\n" for ext in DECK_DATA})
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        for fname, text in files.items():
            data = text.encode()
            info = tarfile.TarInfo(f"{top}/{fname}")
            info.size = len(data)
            info.mode = 0o644
            tar.addfile(info, io.BytesIO(data))
    return buf.getvalue()


def make_build(base: Path, dirname: str = "3.0.2", exports: dict[str, str] | None = None) -> Path:
    """A synthetic build under base/x86_64/<dirname> (<version>[-<target>]): a stub namd3 and the env script that puts
    it on PATH."""
    root = base / "x86_64" / dirname
    version = dirname.split("-")[0]
    (root / "bin").mkdir(parents=True)
    (root / "bin" / "namd3").write_text(NAMD3_STUB)
    (root / "bin" / "namd3").chmod(0o755)
    env = {"NAMD_ROOT": str(root), "NAMD_VERSION": version, "CHARM_ARCH": "mpi-linux-x86_64-smp", **(exports or {})}
    script = root / f"namd-{version}-x86-env.sh"
    script.write_text("#!/bin/bash\n" + "".join(f'export {k}="{v}"\n' for k, v in env.items())
                      + 'export PATH="${NAMD_ROOT}/bin:${PATH}"\n')
    return script


def runnable_copy(work: Path, cpuinfo: str) -> Path:
    """The script, reading `cpuinfo` (written in `work`) instead of /proc/cpuinfo: the copy differs from the script in
    that path alone."""
    text = SCRIPT.read_text()
    assert text.count("/proc/cpuinfo") == 1, "the script names /proc/cpuinfo in other places"
    stub = work / "cpuinfo"
    stub.write_text(cpuinfo)
    copy = work / SCRIPT.name
    copy.write_text(text.replace("/proc/cpuinfo", str(stub)))
    assert copy.read_text().replace(str(stub), "/proc/cpuinfo") == text
    return copy


def run(work: Path, tools: Path, nodes: int = 1, env: dict[str, str | None] | None = None, imds: str = "ok",
        itype: str = "hpc8a.96xlarge", namd_out: str = "complete", rc: int = 0, cached: dict | None = None,
        decks: dict | None = None, builds: tuple = (HPC8A_BUILD,), cpuinfo: str = CPUINFO_AVX512) -> Job:
    """Run the script as a job on `nodes` nodes, from `work`/submit, with BASE_DIR `work`/base.

    `imds` and `itype` set the stub instance metadata, `namd_out` and `rc` the stub mpirun's output and exit status.
    `cached` puts decks in the cache ({MODEL: config lines or None for the default}), `decks` changes the tarballs the
    stub curl serves ({MODEL: config lines}). `builds` are the synthetic builds ((dirname, exports), ...), `cpuinfo`
    the node's /proc/cpuinfo. `env` adds variables to the job's environment, or unsets them (None)."""
    stubs, state, submit, base, served, tmp = (work / d for d in ("stubs", "state", "submit", "base", "decks", "tmp"))
    for d in (stubs, state, submit, base, served, tmp):
        d.mkdir(parents=True, exist_ok=True)
    for name, text in {"curl": CURL_STUB, "srun": SRUN_STUB, "fi_info": FI_INFO_STUB, "nproc": NPROC_STUB,
                       "lscpu": LSCPU_STUB, "mpirun": MPIRUN_STUB}.items():
        (stubs / name).write_text(text)
        (stubs / name).chmod(0o755)
    for model in DECKS:
        lines = (decks or {}).get(model)
        (served / DECKS[model][0]).write_bytes(deck_tarball(model, lines))
    for model, lines in (cached or {}).items():
        _, top, conf, default = DECKS[model]
        cache = base / "benchmarks" / model
        cache.mkdir(parents=True)
        (cache / conf).write_text("\n".join(default if lines is None else lines) + "\n")
        for ext in DECK_DATA:
            (cache / f"{top}.{ext}").write_text(f"synthetic cached {ext}\n")
    for dirname, exports in builds:
        make_build(base, dirname, exports)
    job_env = {"PATH": f"{stubs}{os.pathsep}{tools}", "HOME": str(work), "LC_ALL": "POSIX", "TMPDIR": str(tmp),
               "STATE": str(state), "STUB_IMDS": imds, "STUB_INSTANCE_TYPE": itype, "STUB_NAMD_OUT": namd_out,
               "STUB_RC": str(rc), "STUB_DECKS": str(served), "SLURM_JOB_ID": JOB_ID,
               "SLURM_JOB_NUM_NODES": str(nodes), "SLURM_CPUS_ON_NODE": "192", "SLURM_CLUSTER_NAME": "test",
               "SLURM_SUBMIT_DIR": str(submit), "BASE_DIR": str(base)}
    for name, value in (env or {}).items():
        if value is None:
            job_env.pop(name, None)
        else:
            job_env[name] = value
    proc = subprocess.run([BASH, str(runnable_copy(work, cpuinfo))], cwd=submit, env=job_env, capture_output=True,
                          text=True, errors="replace", timeout=120)
    calls = []
    for d in sorted(state.glob("mpirun-call-*"), key=lambda p: int(p.name.rsplit("-", 1)[1])):
        calls.append({"args": (d / "args").read_text().splitlines(), "cwd": (d / "cwd").read_text().strip(),
                      "fi_provider": (d / "fi_provider").read_text(),
                      "config": (d / "config").read_text().splitlines() if (d / "config").exists() else None})

    def log(name: str) -> list[str]:
        return (state / name).read_text().splitlines() if (state / name).exists() else []

    return Job(proc, calls, log("curl.log"), log("srun.log"), log("fi_info.log"), log("lscpu.log"), base, state)


def started(job: Job) -> dict:
    """The job called mpirun once and ended with exit status 0: that call."""
    assert job.proc.returncode == 0, job.proc.stdout + job.proc.stderr
    assert len(job.calls) == 1, job.calls
    return job.calls[0]


def namd_words(call: dict) -> list[str]:
    """mpirun's arguments from namd3 on: the binary, its options and the config."""
    args = call["args"]
    i = next(i for i, a in enumerate(args) if a.endswith("/namd3"))
    return args[i:]


def mpi_words(call: dict) -> list[str]:
    """mpirun's own arguments, before namd3."""
    args = call["args"]
    return args[:next(i for i, a in enumerate(args) if a.endswith("/namd3"))]


def deck_downloads(job: Job) -> list[str]:
    return [line for line in job.curl if UTILITIES in line]


def assert_refused(job: Job, message: str) -> None:
    """The job stopped with exit status 1 and `message` on stderr, before mpirun and before it made a run directory."""
    assert job.proc.returncode == 1, job.proc.stdout + job.proc.stderr
    assert message in job.proc.stderr, job.proc.stderr
    assert job.calls == []
    assert job.run_dirs() == []


def test_one_node_runs_one_process_with_191_pes_and_reports_the_last_benchmark_line(tmp_path, host_tools):
    job = run(tmp_path, host_tools)
    call = started(job)
    namd3 = str(tmp_path / "base" / "x86_64" / "3.0.2-hpc8a" / "bin" / "namd3")
    assert mpi_words(call) == ["-np", "1", "--map-by", "ppr:1:node", "--bind-to", "none"]
    assert namd_words(call) == [namd3, "+ppn", "191", "+setcpuaffinity", "run-ApoA1.namd"]
    assert call["fi_provider"] == "unset"
    assert "NAMDRESULT model=ApoA1 nodes=1 ppn=191 instance=hpc8a.96xlarge days_per_ns=0.25 ns_per_day=4.0000 " \
           "wallclock=12.500000" in job.out
    assert any(re.fullmatch(r"\s*model=ApoA1\s+nodes=1 x hpc8a\.96xlarge\s+ppn=191\s+cores/node=192", line)
               for line in job.out), job.out


def test_two_nodes_check_efa_and_send_mpis_traffic_over_it(tmp_path, host_tools):
    job = run(tmp_path, host_tools, nodes=2, env={"MODEL": "STMV"})
    call = started(job)
    assert mpi_words(call) == ["-np", "2", "--map-by", "ppr:1:node", "--bind-to", "none", "--mca", "pml", "cm",
                               "--mca", "mtl", "ofi", "-x", "FI_PROVIDER", "-x", "FI_EFA_USE_DEVICE_RDMA", "-x",
                               "RDMAV_FORK_SAFE"]
    assert call["fi_provider"] == "efa"
    assert job.fi_info == ["-p efa -t FI_EP_RDM"]
    assert "NAMDRESULT model=STMV nodes=2 ppn=191 instance=hpc8a.96xlarge days_per_ns=0.25 ns_per_day=4.0000 " \
           "wallclock=12.500000" in job.out


def test_no_efa_on_two_nodes_stops_the_job_before_mpirun(tmp_path, host_tools):
    job = run(tmp_path, host_tools, nodes=2, env={"STUB_FI_RC": "1"})
    assert job.proc.returncode == 1, job.proc.stdout + job.proc.stderr
    assert "fi_info -p efa failed" in job.proc.stderr
    assert job.calls == []


REFUSED = [
    pytest.param({"MODEL": "apoa1"}, "MODEL='apoa1' invalid", id="MODEL=apoa1"),
    pytest.param({"MODEL": "DHFR"}, "MODEL='DHFR' invalid", id="MODEL=DHFR"),
    *(pytest.param({"TIMESTEPS": v}, f"TIMESTEPS='{v}' invalid", id=f"TIMESTEPS={v}")
      for v in ("0", "10000001", "1e3")),
    *(pytest.param({"PPN": v}, f"PPN='{v}' invalid", id=f"PPN={v}") for v in ("0", "193", "abc")),
    pytest.param({"BASE_DIR": "relative/dir"}, "BASE_DIR must be an absolute path", id="relative BASE_DIR"),
]


@pytest.mark.parametrize("env, message", REFUSED)
def test_a_setting_out_of_its_range_stops_the_job_before_mpirun(env, message, tmp_path, host_tools):
    assert_refused(run(tmp_path, host_tools, env=env), message)


def test_timesteps_rewrites_numsteps_in_the_run_config_only(tmp_path, host_tools):
    job = run(tmp_path, host_tools, env={"TIMESTEPS": "2000"})
    config = started(job)["config"]
    assert [line for line in config if line.lower().startswith("numsteps")] == ["numsteps 2000"]
    cached = (job.base / "benchmarks" / "ApoA1" / "apoa1.namd").read_text().splitlines()
    assert "numsteps             500" in cached


def test_an_outputtiming_line_is_added_when_the_deck_has_none(tmp_path, host_tools):
    lines = [line for line in DECKS["ApoA1"][3] if not line.lower().startswith("outputtiming")]
    job = run(tmp_path, host_tools, decks={"ApoA1": lines})
    config = started(job)["config"]
    assert config[-1] == "outputTiming 20"
    assert sum(line.lower().startswith("outputtiming") for line in config) == 1


def test_a_deck_with_an_outputtiming_line_keeps_it(tmp_path, host_tools):
    config = started(run(tmp_path, host_tools))["config"]
    assert [line for line in config if line.lower().startswith("outputtiming")] == ["outputtiming         20"]


@pytest.mark.parametrize("model", list(DECKS))
def test_a_deck_missing_from_the_cache_is_downloaded_and_copied_into_the_run_directory(model, tmp_path, host_tools):
    job = run(tmp_path, host_tools, env={"MODEL": model})
    call = started(job)
    name, top, conf, _ = DECKS[model]
    downloads = deck_downloads(job)
    assert len(downloads) == 1 and downloads[0].endswith(UTILITIES + name), downloads
    cache = job.base / "benchmarks" / model
    assert (cache / conf).read_text().splitlines() == DECKS[model][3]
    (run_dir,) = job.run_dirs()
    assert call["cwd"] == str(run_dir)
    for fname in (conf, *(f"{top}.{ext}" for ext in DECK_DATA)):
        assert (run_dir / fname).read_text() == (cache / fname).read_text(), fname
    assert namd_words(call)[-1] == f"run-{model}.namd"


def test_a_cached_deck_is_reused_with_no_download(tmp_path, host_tools):
    job = run(tmp_path, host_tools, cached={"ApoA1": None})
    started(job)
    assert deck_downloads(job) == []
    (run_dir,) = job.run_dirs()
    assert (run_dir / "apoa1.psf").read_text() == "synthetic cached psf\n"


def test_the_run_directory_names_the_job_model_cluster_nodes_type_and_pes(tmp_path, host_tools):
    job = run(tmp_path, host_tools, nodes=2, env={"MODEL": "STMV"})
    started(job)
    (run_dir,) = job.run_dirs()
    assert re.fullmatch(rf"{JOB_ID}-STMV-test-2xhpc8a\.96xlarge-191ppn-\d{{8}}T\d{{6}}Z", run_dir.name), run_dir.name
    assert (run_dir / "namd.out").read_text().splitlines()[-1] == "[Partition 0][Node 0] End of program"


def test_the_last_benchmark_time_line_gives_the_result(tmp_path, host_tools):
    """Six Benchmark time lines in a 1,000-step run: the last one's days/ns is the result."""
    job = run(tmp_path, host_tools, env={"TIMESTEPS": "1000", "STUB_DAYS": "0.125"})
    started(job)
    (run_dir,) = job.run_dirs()
    bench = [line for line in (run_dir / "namd.out").read_text().splitlines() if "Benchmark time:" in line]
    assert len(bench) == 6
    assert any(line.startswith("NAMDRESULT ") and " days_per_ns=0.125 ns_per_day=8.0000 " in line for line in job.out)


def test_the_cache_drop_runs_once_on_every_node(tmp_path, host_tools):
    job = run(tmp_path, host_tools, nodes=2)
    started(job)
    assert len(job.srun) == 1 and job.srun[0].startswith("--ntasks=2 --ntasks-per-node=1 bash -c "), job.srun


NOT_A_TYPE = {
    "a proxy's page": "<html><head><title>Proxy</title></head>\n<body>Request denied by proxy.example.com</body></html>",
    "a type-shaped word at the end": "Request denied by proxy.example.com",
    "capitals": "HPC8A.96XLARGE",
    "a type, then other text": "hpc8a.96xlarge: not found",
    "a type, then a second line": "hpc8a.96xlarge\n<p>Request checked by proxy.example.com",
}
NO_TYPE = [pytest.param("none", None, id="no answer"), pytest.param("error", None, id="an HTTP error"),
           pytest.param("cut-off", None, id="an answer cut off at the time limit"),
           *(pytest.param("text", text, id=name) for name, text in NOT_A_TYPE.items())]


@pytest.mark.parametrize("imds, text", NO_TYPE)
def test_no_instance_type_from_the_metadata_names_it_unknown_and_the_run_goes_on(imds, text, tmp_path, host_tools):
    env = {"STUB_IMDS_TEXT": text} if text is not None else {}
    job = run(tmp_path, host_tools, imds=imds, env=env)
    started(job)
    (run_dir,) = job.run_dirs()
    assert re.fullmatch(rf"{JOB_ID}-ApoA1-test-1xunknown-191ppn-\d{{8}}T\d{{6}}Z", run_dir.name), run_dir.name
    assert any(re.fullmatch(r"\s*model=ApoA1\s+nodes=1 x unknown\s+ppn=191\s+cores/node=192", line)
               for line in job.out), job.out
    (result,) = [line for line in job.out if line.startswith("NAMDRESULT ")]
    assert " instance=unknown " in result, result
    for word in ("proxy", "html", "HPC8A", "hpc8a.96x"):
        assert word not in job.proc.stdout, word


def test_every_metadata_request_fails_on_an_http_error_and_has_a_time_limit(tmp_path, host_tools):
    job = run(tmp_path, host_tools)
    started(job)
    requests = [line for line in job.curl if "169.254.169.254" in line]
    assert len(requests) == 2, requests
    assert "latest/api/token" in requests[0] and "meta-data/instance-type" in requests[1], requests
    for request in requests:
        words = request.split()
        assert any(w == "--fail" or re.fullmatch(r"-[a-zA-Z]*f[a-zA-Z]*", w) for w in words), request
        assert re.search(r"(^| )--connect-timeout 2( |$)", request), request
        assert re.search(r"(^| )--max-time 5( |$)", request), request


def test_a_type_name_with_an_i_reads_in_a_turkish_locale(tmp_path, host_tools):
    """In a Turkish locale [a-z] leaves out i, so the type name is tested in the C locale."""
    if "tr_TR.utf8" not in subprocess.run(["locale", "-a"], capture_output=True, text=True).stdout.split():
        pytest.skip("the tr_TR.UTF-8 locale is not installed")
    job = run(tmp_path, host_tools, itype="c8i.96xlarge", env={"LC_ALL": "tr_TR.UTF-8"})
    started(job)
    (result,) = [line for line in job.out if line.startswith("NAMDRESULT ")]
    assert " instance=c8i.96xlarge " in result, result


def build_bin(job: Job, dirname: str) -> str:
    return str(job.base / "x86_64" / dirname / "bin" / "namd3")


ALL_TARGETS = tuple((f"3.0.2-{target}", {"NAMD_TARGET_CPU": target, "NAMD_ISA": "avx2" if target == "hpc6a" else
                                          "avx512"}) for target in ("hpc8a", "hpc7a", "m8a", "c8i", "r8i", "hpc6id",
                                                                    "hpc6a"))


@pytest.mark.parametrize("itype, dirname", [("hpc8a.96xlarge", "3.0.2-hpc8a"), ("hpc7a.96xlarge", "3.0.2-hpc7a"),
                                            ("hpc7a.48xlarge", "3.0.2-hpc7a"), ("c8i.96xlarge", "3.0.2-c8i"),
                                            ("r8i.96xlarge", "3.0.2-r8i"), ("m8a.48xlarge", "3.0.2-m8a"),
                                            ("hpc6id.32xlarge", "3.0.2-hpc6id")])
def test_the_build_of_the_nodes_instance_family_is_picked(itype, dirname, tmp_path, host_tools):
    job = run(tmp_path, host_tools, itype=itype, builds=ALL_TARGETS)
    call = started(job)
    assert namd_words(call)[0] == build_bin(job, dirname)
    target = dirname.split("-")[1]
    assert any(line.endswith(f"target={target}   isa=avx512") for line in job.out), job.out
    assert "NOTE:" not in job.proc.stderr, job.proc.stderr


def test_hpc6a_gets_its_avx2_build(tmp_path, host_tools):
    job = run(tmp_path, host_tools, itype="hpc6a.48xlarge", builds=ALL_TARGETS, cpuinfo=CPUINFO_AVX2,
              env={"SLURM_CPUS_ON_NODE": "96"})
    call = started(job)
    assert namd_words(call)[0] == build_bin(job, "3.0.2-hpc6a")
    assert any(line.endswith("target=hpc6a   isa=avx2") for line in job.out), job.out


def test_the_highest_version_of_the_familys_builds_is_picked(tmp_path, host_tools):
    builds = (("3.0.2-hpc8a", None), ("3.0.10-hpc8a", None), ("3.0.9-hpc8a", None), ("3.0.11-hpc7a", None))
    job = run(tmp_path, host_tools, builds=builds)
    assert namd_words(started(job))[0] == build_bin(job, "3.0.10-hpc8a")


@pytest.mark.parametrize("builds, imds", [((("3.0.2", None),), "ok"), ((HPC8A_BUILD,), "none"),
                                          ((("3.0.2-c8i", None),), "ok")],
                         ids=["a build from before the targets", "no instance type", "another family's build"])
def test_with_no_build_for_the_family_the_only_build_is_used_with_a_note(builds, imds, tmp_path, host_tools):
    job = run(tmp_path, host_tools, builds=builds, imds=imds)
    dirname = builds[0][0]
    assert namd_words(started(job))[0] == build_bin(job, dirname)
    family = "hpc8a" if imds == "ok" else "an unknown instance type"
    assert f"NOTE: no build for {family} under {job.base / 'x86_64'}/; using the only build there, " \
           f"{job.base / 'x86_64' / dirname}" in job.err, job.err


@pytest.mark.parametrize("imds", ["ok", "none"])
def test_several_builds_and_none_for_the_family_stop_the_job_and_ask_for_namd_env(imds, tmp_path, host_tools):
    builds = (("3.0.2-c8i", None), ("3.0.2-hpc7a", None))
    job = run(tmp_path, host_tools, builds=builds, imds=imds)
    family = "hpc8a" if imds == "ok" else "an unknown instance type"
    root = job.base / "x86_64"
    assert_refused(job, f"ERROR: no build for {family} under {root}/, which holds 2 others ({root / '3.0.2-c8i'} "
                        f"{root / '3.0.2-hpc7a'}): set NAMD_ENV to the env script of one of them")


def test_no_build_at_all_stops_the_job(tmp_path, host_tools):
    assert_refused(run(tmp_path, host_tools, builds=()), "ERROR: no NAMD env script found under")


def test_namd_env_set_by_hand_is_used_as_given(tmp_path, host_tools):
    env_script = tmp_path / "base" / "x86_64" / "3.0.2-c8i" / "namd-3.0.2-x86-env.sh"
    job = run(tmp_path, host_tools, builds=ALL_TARGETS, env={"NAMD_ENV": str(env_script)})
    assert namd_words(started(job))[0] == build_bin(job, "3.0.2-c8i")


@pytest.mark.parametrize("imds", ["ok", "none"])
def test_an_avx512_build_on_a_cpu_without_avx512_stops_the_job_before_anything_runs(imds, tmp_path, host_tools):
    env_script = tmp_path / "base" / "x86_64" / "3.0.2-hpc8a" / "namd-3.0.2-x86-env.sh"
    job = run(tmp_path, host_tools, nodes=2, itype="hpc6a.48xlarge", imds=imds, cpuinfo=CPUINFO_AVX2,
              env={"NAMD_ENV": str(env_script), "SLURM_CPUS_ON_NODE": "96"})
    assert_refused(job, f"ERROR: {env_script} is an AVX-512 build (NAMD_ISA=avx512), and this node's CPU has no "
                        "AVX-512: build TARGET_CPU=hpc6a for it, or set NAMD_ENV to that build's env script")
    assert job.fi_info == [] and deck_downloads(job) == []


def test_an_avx2_build_runs_on_a_cpu_with_avx512_too(tmp_path, host_tools):
    job = run(tmp_path, host_tools, builds=(("3.0.2-hpc6a", {"NAMD_TARGET_CPU": "hpc6a", "NAMD_ISA": "avx2"}),),
              env={"NAMD_ENV": str(tmp_path / "base" / "x86_64" / "3.0.2-hpc6a" / "namd-3.0.2-x86-env.sh")})
    started(job)


# The PPN of each flexible-cores count below a full node, and the counts.
LISTED_PPN = (23, 47, 71, 95, 119, 143, 167)
FLEX_TYPES = ("hpc8a.96xlarge", "hpc7a.96xlarge")


def flexible_cores_lists() -> dict[int, list[int]]:
    """The OPEN_MPI_PROCESSOR_LIST of each cores-per-node count in hello-cpu.openmpi.explicit.sbatch's case."""
    lists: dict[int, list[int]] = {}
    count = None
    for line in FLEXIBLE_CORES.read_text().splitlines():
        if m := re.fullmatch(r"\s*(\d+)\)", line):
            count = int(m.group(1))
        elif (m := re.fullmatch(r'\s*OPEN_MPI_PROCESSOR_LIST="([0-9,]+)"', line)) and count is not None:
            lists[count] = [int(c) for c in m.group(1).split(",")]
            count = None
    assert sorted(lists) == [24, 48, 72, 96, 120, 144, 168, 192], sorted(lists)
    return lists


def maps(call: dict) -> tuple[str | None, str | None]:
    """namd3's +commap and +pemap values (None when absent)."""
    words = namd_words(call)
    value = lambda opt: words[words.index(opt) + 1] if opt in words else None  # noqa: E731
    return value("+commap"), value("+pemap")


def assert_no_maps(call: dict) -> None:
    assert maps(call) == (None, None), namd_words(call)
    assert "+setcpuaffinity" in namd_words(call)


@pytest.mark.parametrize("ppn", LISTED_PPN)
@pytest.mark.parametrize("itype", FLEX_TYPES)
def test_below_a_full_node_the_threads_are_pinned_to_the_flexible_cores_list(itype, ppn, tmp_path, host_tools):
    """The communication thread on the list's first core, the PEs on the rest: every core once, and (PPN + 1) / 24
    threads on every CCD."""
    builds = (("3.0.2-hpc8a", None), ("3.0.2-hpc7a", None))
    job = run(tmp_path, host_tools, itype=itype, builds=builds, env={"PPN": str(ppn)})
    call = started(job)
    commap, pemap = maps(call)
    listed = flexible_cores_lists()[ppn + 1]
    assert [int(commap)] + [int(c) for c in pemap.split(",")] == listed
    cores = [int(commap)] + [int(c) for c in pemap.split(",")]
    assert len(cores) == len(set(cores)) == ppn + 1
    assert {ccd: sum(c // 8 == ccd for c in cores) for ccd in range(24)} == dict.fromkeys(range(24), (ppn + 1) // 24)
    assert namd_words(call)[1:4] == ["+ppn", str(ppn), "+setcpuaffinity"]
    assert namd_words(call)[-1] == "run-ApoA1.namd"
    assert f"Flexible cores: the communication thread on core {commap} and the {ppn} PEs on the rest of the " \
           f"{ppn + 1}-core list (Utils/flexible-cores/)" in job.out
    assert job.lscpu == []


def test_two_nodes_use_the_same_node_local_list(tmp_path, host_tools):
    job = run(tmp_path, host_tools, nodes=2, env={"PPN": "95", "MODEL": "STMV"})
    commap, pemap = maps(started(job))
    listed = flexible_cores_lists()[96]
    assert commap == str(listed[0]) and pemap == ",".join(map(str, listed[1:]))


@pytest.mark.parametrize("ppn", [191, 192])
@pytest.mark.parametrize("itype", FLEX_TYPES)
def test_a_full_node_gets_no_list(itype, ppn, tmp_path, host_tools):
    builds = (("3.0.2-hpc8a", None), ("3.0.2-hpc7a", None))
    job = run(tmp_path, host_tools, itype=itype, builds=builds, env={"PPN": str(ppn)})
    assert_no_maps(started(job))


def flex_error(ppn: int, node: str, on: str) -> str:
    return (f"ERROR: PPN={ppn} worker threads and the communication thread use {ppn + 1} cores per node, which would "
            f"load the 24 CCDs of {node} unevenly; on {on} use PPN=23, 47, 71, 95, 119, 143, 167, 191 or 192 (see "
            "Utils/flexible-cores/)")


@pytest.mark.parametrize("ppn", [63, 100, 1])
@pytest.mark.parametrize("itype", FLEX_TYPES)
def test_another_ppn_on_hpc8a_and_hpc7a_stops_the_job_before_anything_runs(itype, ppn, tmp_path, host_tools):
    builds = (("3.0.2-hpc8a", None), ("3.0.2-hpc7a", None))
    job = run(tmp_path, host_tools, itype=itype, builds=builds, env={"PPN": str(ppn)})
    assert_refused(job, flex_error(ppn, itype, "this type"))
    assert deck_downloads(job) == [] and job.srun == []


@pytest.mark.parametrize("itype, cpus", [("hpc6a.48xlarge", 96), ("c8i.96xlarge", 192), ("hpc7a.48xlarge", 96)])
def test_other_types_and_sizes_get_no_list_and_no_check(itype, cpus, tmp_path, host_tools):
    cpuinfo = CPUINFO_AVX2 if itype.startswith("hpc6a") else CPUINFO_AVX512
    job = run(tmp_path, host_tools, itype=itype, builds=ALL_TARGETS, cpuinfo=cpuinfo,
              env={"PPN": "63", "SLURM_CPUS_ON_NODE": str(cpus)})
    assert_no_maps(started(job))
    assert job.lscpu == []
    assert "NOTE:" not in job.proc.stderr, job.proc.stderr


NOTE_APPLY = ("NOTE: no instance type from the instance metadata; lscpu shows a 192-core AMD node, which could be an "
              "hpc8a.96xlarge or hpc7a.96xlarge, so their cores-per-node check and flexible-cores lists apply")
NOTE_SKIP = ("NOTE: no instance type from the instance metadata, and lscpu does not show a 192-core AMD node, so the "
             "flexible-cores check and lists for hpc8a.96xlarge and hpc7a.96xlarge are skipped")


def test_with_no_type_a_192_core_amd_node_gets_the_check(tmp_path, host_tools):
    job = run(tmp_path / "63", host_tools, imds="none", env={"PPN": "63", "STUB_LSCPU": "amd-192"})
    assert_refused(job, flex_error(63, "this 192-core AMD node", "this node"))
    assert NOTE_APPLY in job.err


def test_with_no_type_a_192_core_amd_node_gets_the_lists(tmp_path, host_tools):
    job = run(tmp_path, host_tools, imds="none", env={"PPN": "95", "STUB_LSCPU": "amd-192"})
    commap, pemap = maps(started(job))
    listed = flexible_cores_lists()[96]
    assert commap == str(listed[0]) and pemap == ",".join(map(str, listed[1:]))
    assert NOTE_APPLY in job.err
    (run_dir,) = job.run_dirs()
    assert "-1xunknown-95ppn-" in run_dir.name


@pytest.mark.parametrize("ppn", [63, 95])
@pytest.mark.parametrize("node", ["intel-192", "amd-96", "fail"])
def test_with_no_type_any_other_node_runs_with_no_list_and_a_note(node, ppn, tmp_path, host_tools):
    job = run(tmp_path, host_tools, imds="none", env={"PPN": str(ppn), "STUB_LSCPU": node})
    assert_no_maps(started(job))
    assert NOTE_SKIP in job.err


@pytest.mark.parametrize("ppn", [191, 192])
def test_with_no_type_a_full_node_asks_lscpu_nothing(ppn, tmp_path, host_tools):
    job = run(tmp_path, host_tools, imds="none", env={"PPN": str(ppn)})
    assert_no_maps(started(job))
    assert job.lscpu == []
    assert "lscpu" not in job.proc.stderr


def test_lscpu_is_read_in_the_c_locale(tmp_path, host_tools):
    job = run(tmp_path, host_tools, imds="none", env={"PPN": "95", "LC_ALL": "de_DE.UTF-8"})
    started(job)
    assert job.lscpu == ["C"]
