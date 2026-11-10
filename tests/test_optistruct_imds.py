"""How apps/Optistruct/Optistruct.2024_1.sbatch reads the instance type from the instance metadata.

The script names its run directory after the instance type, read from the instance metadata (IMDSv2). Each request
gives up after 5 seconds (2 to connect) and fails on an HTTP error (curl -f). No answer, an HTTP error, an answer cut
off at the time limit, and an answer that is not an instance type name (tested in the C locale), such as a proxy's
page, a type name in capitals or a type name inside other text, count as no answer: the job runs to its end, in a run
directory whose name has no instance type and nothing of the answer.

The script names its install and its model's directory under /fsx, so these tests run a copy of it that names a
temporary directory instead and differs from the script in those paths alone (checked here). They run it with stubs
of curl (the instance metadata), aws (which refuses every call), module, mount, mpirun, scontrol, the OptiStruct
launcher and the recorder, and a PATH that holds no other curl, aws, MPI or Slurm command: mpirun runs none of the
commands it is given (the cache drop, the THP setting), and mount shows no node-local scratch. Every value is
synthetic.

Run with:
    python -m pip install -r tests/requirements.txt
    python -m pytest tests/test_optistruct_imds.py -q
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "apps" / "Optistruct" / "Optistruct.2024_1.sbatch"
BASH = shutil.which("bash")
pytestmark = pytest.mark.skipif(BASH is None, reason="needs bash")
# Host commands the script must not find: the stubs stand in for them.
HIDDEN = frozenset({"aws", "curl", "mpirun", "mpiexec", "module", "mount", "srun", "sbatch", "scontrol", "squeue",
                    "sinfo", "sudo"})
# The stub curl. It logs each request's arguments to CURL_LOG and answers as STUB_IMDS says:
#   answer      the token request with a token, the instance type request with STUB_ANSWER (no newline added);
#   no-answer   nothing, and curl's exit at its --max-time (28), for every request;
#   http-error  an HTTP 401 for every request: with -f (--fail) nothing and exit 22, as curl does, else the page;
#   cut-off     for the instance type, STUB_ANSWER less its last five characters, then exit 28, as curl ends a
#               transfer at its --max-time.
CURL_STUB = r"""#!/bin/bash
printf '%s\n' "$*" >> "${CURL_LOG}"
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
echo "curl stub: refusing $*" >&2
exit 7
"""
STUBS = {
    "curl": CURL_STUB,
    "aws": "#!/bin/bash\necho 'aws stub: refused' >&2\nexit 1\n",
    "module": "#!/bin/bash\nexit 0\n",
    "mount": "#!/bin/bash\necho 'fsx@tcp:/fsx on /fsx type lustre (rw)'\n",
    "mpirun": "#!/bin/bash\nprintf '%s\\n' \"$*\" >> \"${STATE}/mpirun.log\"\nexit 0\n",
    "scontrol": "#!/bin/bash\nfor n in node1 node2; do\n  echo \"NodeName=${n} Arch=x86_64 CoresPerSocket=32\"\n"
                "  echo \"   NodeAddr=${n} NodeHostName=${n} Version=25.05.0\"\ndone\n",
    "sudo": "#!/bin/bash\nexit 0\n",
    "recorder": "#!/bin/bash\necho \"call ${RUN_DIR}\" >> \"${STATE}/recorder.log\"\n",
}
SOLVER = "#!/bin/bash\npwd > \"${STATE}/solver.cwd\"\necho '[stub OptiStruct] done'\n"
TYPE = "hpc6id.32xlarge"
# The run directory: /fsx/<job name>/Run/<input's name>/<job id>-<nodes>x<instance type>-<ranks>-<date>.
RUN_DIR = re.compile(r"4242-2x(?P<type>[^/]*)-128-\d{2}-\d{2}-\d{4}-\d{2}-\d{2}")
NOT_TYPE_NAMES = [
    pytest.param("<html><body>Request denied by proxy.example.com</body></html>", id="a proxy's page"),
    pytest.param("Request denied by proxy.example.com", id="other text, then a host name"),
    pytest.param("HPC6ID.32XLARGE", id="capitals"),
    pytest.param("hpc6id.32xlarge: not found", id="a type name, then other text"),
    pytest.param("hpc6id.32xlarge\n<p>Request checked by proxy.example.com", id="a type name, then a second line"),
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


def runnable_copy(work: Path) -> Path:
    """The script, with /fsx/ moved under `work`: the copy differs from the script in those paths alone."""
    text = SCRIPT.read_text()
    assert text.count("/fsx/") == 2, "the script names /fsx/ in other places than its install and model paths"
    copy = work / SCRIPT.name
    copy.write_text(text.replace("/fsx/", f"{work}/fsx/"))
    assert copy.read_text().replace(f"{work}/fsx/", "/fsx/") == text
    return copy


def run(work: Path, tools: Path, imds: str = "answer", answer: str = TYPE, locale: str = "C"):
    """Run the copy as a 2-node job of 128 ranks (16 MPI processes of 8 threads), from `work`, with the stub curl
    answering as `imds` and `answer` say. Returns the process, the run directory's name (None unless exactly one was
    made), and the requests the stub logged."""
    stubs, state = work / "stubs", work / "state"
    basedir = work / "fsx" / "Optistruct.2024_1"
    launcher = work / "fsx" / "Altair" / "2024.1" / "altair" / "scripts" / "optistruct"
    for d in (stubs, state, basedir / "Model", launcher.parent):
        d.mkdir(parents=True)
    for name, text in STUBS.items():
        (stubs / name).write_text(text)
        (stubs / name).chmod(0o755)
    launcher.write_text(SOLVER)
    launcher.chmod(0o755)
    (basedir / "Model" / "synthetic_model.fem").write_text("$ synthetic\n")
    log = state / "curl-requests.txt"
    log.touch()
    env = {"PATH": f"{stubs}{os.pathsep}{tools}", "HOME": str(work), "LC_ALL": locale, "CURL_LOG": str(log),
           "STUB_IMDS": imds, "STUB_ANSWER": answer, "STATE": str(state),
           "DYNAMODB_RECORDER": str(stubs / "recorder"), "SLURM_JOB_NAME": "Optistruct.2024_1.sbatch",
           "SLURM_JOB_ID": "4242", "SLURM_JOB_NUM_NODES": "2", "SLURM_NPROCS": "128",
           "SLURM_NODELIST": "node[1-2]", "SLURM_SUBMIT_DIR": str(work)}
    proc = subprocess.run([BASH, str(runnable_copy(work)), "8", "synthetic_model.fem"], cwd=work, env=env,
                          capture_output=True, text=True, errors="replace", timeout=120)
    runs = basedir / "Run" / "synthetic_model"
    made = sorted(p.name for p in runs.iterdir()) if runs.is_dir() else []
    return proc, (made[0] if len(made) == 1 else None), log.read_text().splitlines()


def assert_runs_in(proc, run_dir: str | None, work: Path, itype: str) -> None:
    """The solve and the recorder ran, in one run directory named after `itype` ("" for none)."""
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert run_dir is not None, proc.stdout + proc.stderr
    m = RUN_DIR.fullmatch(run_dir)
    assert m and m.group("type") == itype, run_dir
    where = work / "fsx" / "Optistruct.2024_1" / "Run" / "synthetic_model" / run_dir
    assert (work / "state" / "solver.cwd").read_text().strip() == str(where)
    assert (work / "state" / "recorder.log").read_text().splitlines() == [f"call {where}"]


def test_the_instance_type_names_the_run_directory(tmp_path, host_tools):
    proc, run_dir, _ = run(tmp_path, host_tools)
    assert_runs_in(proc, run_dir, tmp_path, TYPE)


def test_both_requests_give_up_within_5_seconds_and_fail_on_an_http_error(tmp_path, host_tools):
    _, _, requests = run(tmp_path, host_tools)
    assert len(requests) == 2, requests
    assert "latest/api/token" in requests[0] and "meta-data/instance-type" in requests[1], requests
    for request in requests:
        words = request.split()
        assert any(w == "--fail" or re.fullmatch(r"-[a-zA-Z]*f[a-zA-Z]*", w) for w in words), request
        assert re.search(r"(^| )--connect-timeout [1-5]( |$)", request), request
        assert re.search(r"(^| )--max-time [1-5]( |$)", request), request


@pytest.mark.parametrize("imds", ["no-answer", "http-error", "cut-off"])
def test_no_answer_an_http_error_and_a_cut_off_answer_name_no_instance_type(imds, tmp_path, host_tools):
    """The job runs to its end; the run directory's name has no instance type, nothing of an error page, and not the
    start of a type name cut off at the time limit."""
    proc, run_dir, _ = run(tmp_path, host_tools, imds)
    assert_runs_in(proc, run_dir, tmp_path, "")


@pytest.mark.parametrize("answer", NOT_TYPE_NAMES)
def test_an_answer_that_is_not_a_type_name_counts_as_none(answer, tmp_path, host_tools):
    """A proxy's page, a host name after other text, a type name in capitals, a type name before other text, and a
    type name followed by a second line are not instance type names."""
    proc, run_dir, _ = run(tmp_path, host_tools, answer=answer)
    assert_runs_in(proc, run_dir, tmp_path, "")


def test_a_type_name_with_an_i_reads_in_a_turkish_locale(tmp_path, host_tools):
    """In a Turkish locale [a-z] leaves out i, so the type name is tested in the C locale."""
    if "tr_TR.utf8" not in subprocess.run(["locale", "-a"], capture_output=True, text=True).stdout.split():
        pytest.skip("the tr_TR.UTF-8 locale is not installed")
    proc, run_dir, _ = run(tmp_path, host_tools, answer="c8i.96xlarge", locale="tr_TR.UTF-8")
    assert_runs_in(proc, run_dir, tmp_path, "c8i.96xlarge")
