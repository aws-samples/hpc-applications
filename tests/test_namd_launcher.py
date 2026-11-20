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
  counts as none. The banner, the run directory and NAMDRESULT then say "unknown", and the run goes on.

They run the script with stubs of curl (the instance metadata and the deck downloads), srun, fi_info, nproc and
mpirun, from a temporary directory, with a clean environment and a PATH that holds no other MPI, Slurm, ssh, curl, aws
or sudo command: no NAMD, MPI, Slurm or network is needed. The stub mpirun notes its arguments and prints a synthetic
namd.out. Every value is synthetic.

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


@dataclass
class Job:
    proc: subprocess.CompletedProcess
    calls: list[dict]     # mpirun's calls, as the stub noted them
    curl: list[str]       # each curl call's arguments
    srun: list[str]       # each srun call's arguments
    fi_info: list[str]    # each fi_info call's arguments
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
    """A synthetic build under base/x86_64/<dirname>: a stub namd3 and the env script that puts it on PATH."""
    root = base / "x86_64" / dirname
    (root / "bin").mkdir(parents=True)
    (root / "bin" / "namd3").write_text(NAMD3_STUB)
    (root / "bin" / "namd3").chmod(0o755)
    env = {"NAMD_ROOT": str(root), "NAMD_VERSION": "3.0.2", "CHARM_ARCH": "mpi-linux-x86_64-smp", **(exports or {})}
    script = root / "namd-3.0.2-x86-env.sh"
    script.write_text("#!/bin/bash\n" + "".join(f'export {k}="{v}"\n' for k, v in env.items())
                      + 'export PATH="${NAMD_ROOT}/bin:${PATH}"\n')
    return script


def run(work: Path, tools: Path, nodes: int = 1, env: dict[str, str | None] | None = None, imds: str = "ok",
        itype: str = "hpc8a.96xlarge", namd_out: str = "complete", rc: int = 0, cached: dict | None = None,
        decks: dict | None = None, builds: tuple = (("3.0.2", None),)) -> Job:
    """Run the script as a job on `nodes` nodes, from `work`/submit, with BASE_DIR `work`/base.

    `imds` and `itype` set the stub instance metadata, `namd_out` and `rc` the stub mpirun's output and exit status.
    `cached` puts decks in the cache ({MODEL: config lines or None for the default}), `decks` changes the tarballs the
    stub curl serves ({MODEL: config lines}). `builds` are the synthetic builds ((dirname, exports), ...). `env` adds
    variables to the job's environment, or unsets them (None)."""
    stubs, state, submit, base, served, tmp = (work / d for d in ("stubs", "state", "submit", "base", "decks", "tmp"))
    for d in (stubs, state, submit, base, served, tmp):
        d.mkdir(parents=True, exist_ok=True)
    for name, text in {"curl": CURL_STUB, "srun": SRUN_STUB, "fi_info": FI_INFO_STUB, "nproc": NPROC_STUB,
                       "mpirun": MPIRUN_STUB}.items():
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
    proc = subprocess.run([BASH, str(SCRIPT)], cwd=submit, env=job_env, capture_output=True, text=True,
                          errors="replace", timeout=120)
    calls = []
    for d in sorted(state.glob("mpirun-call-*"), key=lambda p: int(p.name.rsplit("-", 1)[1])):
        calls.append({"args": (d / "args").read_text().splitlines(), "cwd": (d / "cwd").read_text().strip(),
                      "fi_provider": (d / "fi_provider").read_text(),
                      "config": (d / "config").read_text().splitlines() if (d / "config").exists() else None})

    def log(name: str) -> list[str]:
        return (state / name).read_text().splitlines() if (state / name).exists() else []

    return Job(proc, calls, log("curl.log"), log("srun.log"), log("fi_info.log"), base, state)


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
    namd3 = str(tmp_path / "base" / "x86_64" / "3.0.2" / "bin" / "namd3")
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
