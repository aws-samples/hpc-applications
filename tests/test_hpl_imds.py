"""How the HPL launchers in Utils/HPL read the instance type from the instance metadata.

Utils/HPL/hpl.sbatch and Utils/HPL/hpl_bcast_sweep.sbatch name their run directory and their header line after the
instance type, read from the instance metadata (IMDSv2); Utils/HPL/hpl_gpu.sbatch also picks the GPU application
clocks from it (sudo nvidia-smi -ac). Each request gives up after 5 seconds (2 to connect) and fails on an HTTP error
(curl -f). No answer, an HTTP error, an answer cut off at the time limit, and an answer that is not an instance type
name (tested in the C locale), such as a proxy's page, a type name in capitals or a type name inside other text, count
as no answer: the job runs to its end, neither the run directory's name nor the header line has an instance type or
anything of the answer, and hpl_gpu.sbatch leaves the clocks as they are, with a one-line NOTE on stderr.

The launchers name their binaries, libraries and run directories under /fsx, so these tests run a copy of each that
names a temporary directory instead and differs from the launcher in those paths alone (checked here). They run it
with stubs of curl (the instance metadata), module, sudo, mpirun, srun, nproc and nvidia-smi, and a PATH that holds no
other curl, aws, MPI, Slurm or GPU command: mpirun and srun run nothing, and sudo runs none of the commands it is given
(the huge pages, THP and GPU clock settings), it only logs them. Every value is synthetic.

Run with:
    python -m pip install -r tests/requirements.txt
    python -m pytest tests/test_hpl_imds.py -q
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
HPL = REPO / "Utils" / "HPL"
LAUNCHERS = {"hpl": HPL / "hpl.sbatch", "bcast-sweep": HPL / "hpl_bcast_sweep.sbatch", "gpu": HPL / "hpl_gpu.sbatch"}
# How many times each launcher names /fsx/: its binaries, libraries and run directories, and in hpl_gpu.sbatch its
# job log and a usage example.
FSX_PATHS = {"hpl": 6, "bcast-sweep": 4, "gpu": 3}
BASH = shutil.which("bash")

pytestmark = pytest.mark.skipif(BASH is None, reason="needs bash")

# Host commands the launchers must not find: the stubs stand in for them.
HIDDEN = frozenset({"aws", "curl", "module", "mpirun", "mpiexec", "nproc", "nvidia-persistenced", "nvidia-smi",
                    "srun", "sbatch", "scontrol", "squeue", "sinfo", "sudo"})

# The stub curl. It logs each request's arguments to CURL_LOG and answers as STUB_IMDS says:
#   answer      the token request with a token, the instance type request with STUB_ANSWER (no newline added);
#   no-answer   nothing, and curl's exit at its --max-time (28), for every request;
#   http-error  an HTTP 401 for every request: with -f (--fail) nothing and exit 22, as curl does, else the page;
#   cut-off     for the instance type, STUB_ANSWER less its last five characters, then exit 28, as curl ends a
#               transfer at its --max-time.
CURL_STUB = r"""#!/bin/bash
printf '%s\n' "$*" >> "${CURL_LOG}"
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
        printf '%s\n' '<html><head><title>401 - Unauthorized</title></head>' '<body><h1>401 - Unauthorized</h1></body></html>'
        exit 0 ;;
esac
case "$*" in
    *latest/api/token*) printf '%s' stub-token; exit 0 ;;
    *meta-data/instance-type*)
        [ "${STUB_IMDS:-answer}" = cut-off ] && { printf '%s' "${STUB_ANSWER%?????}"; exit 28; }
        printf '%s' "${STUB_ANSWER}"; exit 0 ;;
esac
exit 22
"""

# nvidia-smi: eight GPUs of 143,771 MiB.
NVIDIA_SMI_STUB = r"""#!/bin/bash
case "$*" in
    -L) for g in 0 1 2 3 4 5 6 7; do echo "GPU ${g}: Stub GPU (UUID: GPU-stub-${g})"; done ;;
    *query-gpu=name*) for g in 0 1 2 3 4 5 6 7; do echo "Stub GPU"; done ;;
    *query-gpu=memory.total*) for g in 0 1 2 3 4 5 6 7; do echo 143771; done ;;
    *) echo "nvidia-smi stub: refusing $*" >&2; exit 1 ;;
esac
"""

STUBS = {
    "curl": CURL_STUB,
    "module": "#!/bin/bash\nexit 0\n",
    # sudo logs the command it is given, and runs none.
    "sudo": "#!/bin/bash\nprintf '%s\\n' \"$*\" >> \"${STATE}/sudo.log\"\ncat > /dev/null\nexit 0\n",
    "mpirun": "#!/bin/bash\npwd > \"${STATE}/run.cwd\"\nprintf '%s\\n' \"$*\" > \"${STATE}/run.args\"\n",
    "srun": "#!/bin/bash\npwd > \"${STATE}/run.cwd\"\nprintf '%s\\n' \"$*\" >> \"${STATE}/run.args\"\n",
    "nproc": "#!/bin/bash\necho 64\n",
    "nvidia-smi": NVIDIA_SMI_STUB,
}

TYPES = {"hpl": "hpc8a.96xlarge", "bcast-sweep": "hpc8a.96xlarge", "gpu": "p5en.48xlarge"}

# The run directory, under /fsx/HPL-Run/<job name>/: <job id>-<nodes>x<instance type>-<ranks>-<date> for the CPU
# launchers, and under /fsx/HPL-Run/gpu/: <job id>-<nodes>x<instance type>-<date> for the GPU launcher.
DATE = r"\d{2}-\d{2}-\d{4}-\d{2}-\d{2}"
RUN_DIRS = {"hpl": (("HPL-Run", "hpl"), re.compile(rf"4242-2x(?P<type>[^/]*)-384-{DATE}")),
            "bcast-sweep": (("HPL-Run", "hpl_bcast_sweep"), re.compile(rf"4242-2x(?P<type>[^/]*)-384-{DATE}")),
            "gpu": (("HPL-Run", "gpu"), re.compile(rf"4242-1x(?P<type>[^/]*)-{DATE}"))}
JOBS = {"hpl": {"SLURM_JOB_NAME": "hpl.sbatch", "SLURM_JOB_NUM_NODES": "2", "SLURM_NPROCS": "384"},
        "bcast-sweep": {"SLURM_JOB_NAME": "hpl_bcast_sweep.sbatch", "SLURM_JOB_NUM_NODES": "2",
                        "SLURM_NPROCS": "384"},
        "gpu": {"SLURM_JOB_NAME": "hpl-gpu", "SLURM_JOB_NUM_NODES": "1"}}

GPU_NOTE = "NOTE: the instance metadata gave no instance type, so the GPU application clocks are left as they are"

NOT_TYPE_NAMES = [
    pytest.param("<html><body>Request denied by proxy.example.com</body></html>", id="a proxy's page"),
    pytest.param("Request denied by proxy.example.com", id="other text, then a host name"),
    pytest.param("CAPITALS", id="capitals"),
    pytest.param("TYPE: not found", id="a type name, then other text"),
    pytest.param("TYPE\n<p>Request checked by proxy.example.com", id="a type name, then a second line"),
]


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


def runnable_copy(name: str, work: Path) -> Path:
    """The launcher, with /fsx/ moved under `work`: the copy differs from the launcher in those paths alone."""
    text = LAUNCHERS[name].read_text()
    assert text.count("/fsx/") == FSX_PATHS[name], "the launcher names /fsx/ in other places than these tests know"
    copy = work / LAUNCHERS[name].name
    copy.write_text(text.replace("/fsx/", f"{work}/fsx/"))
    assert copy.read_text().replace(f"{work}/fsx/", "/fsx/") == text
    return copy


def run(name: str, work: Path, tools: Path, imds: str = "answer", answer: str | None = None, locale: str = "C"):
    """Run a copy of one launcher, from `work`, with the stub curl answering as `imds` and `answer` (by default the
    launcher's own instance type) say. Returns the process, the run directory's name (None unless exactly one was
    made), and the requests the stub logged."""
    stubs, state, fsx = work / "stubs", work / "state", work / "fsx"
    binary = fsx / "HPL-OpenMPI" / "bin" / "Linux_AMD_OpenMPI" / "xhpl"
    for d in (stubs, state, binary.parent, fsx / "HPL-Run" / "gpu"):
        d.mkdir(parents=True)
    for stub, text in STUBS.items():
        (stubs / stub).write_text(text)
        (stubs / stub).chmod(0o755)
    binary.write_text("#!/bin/bash\nexit 0\n")
    binary.chmod(0o755)
    log = state / "curl-requests.txt"
    log.touch()
    env = {"PATH": f"{stubs}{os.pathsep}{tools}", "HOME": str(work), "LC_ALL": locale, "CURL_LOG": str(log),
           "STUB_IMDS": imds, "STUB_ANSWER": TYPES[name] if answer is None else answer, "STATE": str(state),
           "SLURM_JOB_ID": "4242", **JOBS[name]}
    proc = subprocess.run([BASH, str(runnable_copy(name, work))], cwd=work, env=env, stdin=subprocess.DEVNULL,
                          capture_output=True, text=True, errors="replace", timeout=120)
    runs = fsx.joinpath(*RUN_DIRS[name][0])
    made = sorted(p.name for p in runs.iterdir() if p.is_dir()) if runs.is_dir() else []
    return proc, (made[0] if len(made) == 1 else None), log.read_text().splitlines()


def assert_runs_in(name: str, proc, run_dir: str | None, work: Path, itype: str) -> None:
    """The job ran to its end, in one run directory named after `itype` ("" for none), and its header line names it.
    hpl_gpu.sbatch sets p5en.48xlarge's clocks, none for a type its table does not list, and none, with the NOTE,
    for no type."""
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert run_dir is not None, proc.stdout
    m = RUN_DIRS[name][1].fullmatch(run_dir)
    assert m and m.group("type") == itype, run_dir
    run_path = work.joinpath("fsx", *RUN_DIRS[name][0], run_dir)
    assert (work / "state" / "run.cwd").read_text().strip() == str(run_path)
    lines = proc.stdout.splitlines()
    if name == "hpl":
        assert f"==> HPL | MPI=openmpi | 2 x {itype}" in lines, proc.stdout
    elif name == "bcast-sweep":
        assert any(line.startswith(f"==> BCAST/DEPTH sweep | 2 x {itype} | N=") for line in lines), proc.stdout
    else:
        assert f"Instance: {itype} x 1" in lines, proc.stdout
        clocks = [c for c in (work / "state" / "sudo.log").read_text().splitlines() if c.startswith("nvidia-smi -ac")]
        assert clocks == (["nvidia-smi -ac 3201,1980"] if itype == "p5en.48xlarge" else []), clocks
        assert proc.stderr.splitlines().count(GPU_NOTE) == (1 if itype == "" else 0), proc.stderr


def answer_for(name: str, template: str) -> str:
    """A non-type answer built around the launcher's own type name, in capitals where the template says so."""
    return template.replace("CAPITALS", TYPES[name].upper()).replace("TYPE", TYPES[name])


@pytest.mark.parametrize("name", LAUNCHERS)
def test_the_instance_type_names_the_run_directory_and_the_header(name, tmp_path, host_tools):
    proc, run_dir, _ = run(name, tmp_path, host_tools)
    assert_runs_in(name, proc, run_dir, tmp_path, TYPES[name])


@pytest.mark.parametrize("name", LAUNCHERS)
def test_both_requests_give_up_within_5_seconds_and_fail_on_an_http_error(name, tmp_path, host_tools):
    _, _, requests = run(name, tmp_path, host_tools)
    assert len(requests) == 2, requests
    assert "latest/api/token" in requests[0] and "meta-data/instance-type" in requests[1], requests
    for request in requests:
        words = request.split()
        assert any(w == "--fail" or re.fullmatch(r"-[a-zA-Z]*f[a-zA-Z]*", w) for w in words), request
        assert re.search(r"(^| )--connect-timeout [1-5]( |$)", request), request
        assert re.search(r"(^| )--max-time [1-5]( |$)", request), request


@pytest.mark.parametrize("imds", ["no-answer", "http-error", "cut-off"])
@pytest.mark.parametrize("name", LAUNCHERS)
def test_no_answer_an_http_error_and_a_cut_off_answer_name_no_instance_type(name, imds, tmp_path, host_tools):
    """The job runs to its end; neither the run directory's name nor the header line has an instance type, anything
    of an error page, or the start of a type name cut off at the time limit, and hpl_gpu.sbatch sets no clocks."""
    proc, run_dir, _ = run(name, tmp_path, host_tools, imds)
    assert_runs_in(name, proc, run_dir, tmp_path, "")


@pytest.mark.parametrize("template", NOT_TYPE_NAMES)
@pytest.mark.parametrize("name", LAUNCHERS)
def test_an_answer_that_is_not_a_type_name_counts_as_none(name, template, tmp_path, host_tools):
    """A proxy's page, a host name after other text, a type name in capitals, a type name before other text, and a
    type name followed by a second line are not instance type names."""
    proc, run_dir, _ = run(name, tmp_path, host_tools, answer=answer_for(name, template))
    assert_runs_in(name, proc, run_dir, tmp_path, "")


@pytest.mark.parametrize("name", LAUNCHERS)
def test_a_type_name_with_an_i_reads_in_a_turkish_locale(name, tmp_path, host_tools):
    """In a Turkish locale [a-z] leaves out i, so the type name is tested in the C locale. No type in the GPU
    launcher's clock table has an i in its name, so it reads one the table does not list: it sets no clocks, and
    prints no NOTE."""
    if "tr_TR.utf8" not in subprocess.run(["locale", "-a"], capture_output=True, text=True).stdout.split():
        pytest.skip("the tr_TR.UTF-8 locale is not installed")
    proc, run_dir, _ = run(name, tmp_path, host_tools, answer="c8i.96xlarge", locale="tr_TR.UTF-8")
    assert_runs_in(name, proc, run_dir, tmp_path, "c8i.96xlarge")
