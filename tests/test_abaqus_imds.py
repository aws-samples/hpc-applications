"""How apps/Abaqus/Abaqus.sbatch reads the instance type from the instance metadata.

The script names its run directory after the instance type, read from the instance metadata (IMDSv2). Each request
gives up after 5 seconds (2 to connect) and fails on an HTTP error (curl -f). No answer, an HTTP error, an answer cut
off at the time limit, and an answer that is not an instance type name (tested in the C locale), such as a proxy's
page, a type name in capitals or a type name inside other text, count as no answer: the job goes on, in a run
directory whose name has no instance type and nothing of the answer.

These tests run the script itself with stubs of curl (the instance metadata), module, mpirun, scontrol, mount and
the Abaqus launcher, and a PATH that holds no other curl, aws, MPI or Slurm command, from a temporary directory. The
stubs run nothing on the host: mpirun runs none of the commands it is given (the cache drop, the THP setting), and
mount shows no node-local scratch. Every value is synthetic.

Run with:
    python -m pip install -r tests/requirements.txt
    python -m pytest tests/test_abaqus_imds.py -q
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "apps" / "Abaqus" / "Abaqus.sbatch"
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
# scontrol show nodes: one record per node, as Slurm prints them; mount shows no ephemeral (node-local) volume; the
# Abaqus launcher logs where and how it was started.
STUBS = {
    "curl": CURL_STUB,
    "module": "#!/bin/bash\nexit 0\n",
    "mpirun": "#!/bin/bash\nprintf '%s\\n' \"$*\" >> \"${STATE}/mpirun.log\"\nexit 0\n",
    "mount": "#!/bin/bash\necho 'fsx@tcp:/fsx on /fsx type lustre (rw)'\n",
    "scontrol": "#!/bin/bash\nfor n in node1 node2; do\n  echo \"NodeName=${n} Arch=x86_64 CoresPerSocket=32\"\n"
                "  echo \"   NodeAddr=${n} NodeHostName=${n} Version=25.05.0\"\ndone\n",
    "sudo": "#!/bin/bash\nexit 0\n",
    "smalauncher": "#!/bin/bash\npwd > \"${STATE}/solver.cwd\"\nprintf '%s\\n' \"$*\" > \"${STATE}/solver.args\"\n"
                   "echo '[stub Abaqus] done'\n",
}
TYPE = "hpc6id.32xlarge"
# The run directory: BASE_DIR/<job name>/<input's name>/<job id>-<nodes>x<instance type>-<ranks>-<date>.
RUN_DIR = re.compile(r"4242-2x(?P<type>[^/]*)-128-\d{2}-\d{2}-\d{4}-\d{2}-\d{2}")
NOT_TYPE_NAMES = [
    pytest.param("<html><body>Request denied by proxy.example.com</body></html>", id="a proxy's page"),
    pytest.param("HPC6ID.32XLARGE", id="capitals"),
    pytest.param("hpc6id.32xlarge: not found", id="a type name, then other text"),
    pytest.param("Not found: hpc6id.32xlarge", id="other text, then a type name"),
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


def run(work: Path, tools: Path, imds: str = "answer", answer: str = TYPE, locale: str = "C"):
    """Run the script as a 2-node job of 128 ranks, from `work`, with the stub curl answering as `imds` and `answer`
    say. Returns the process, the run directory's name (None unless exactly one was made), and the requests the stub
    logged."""
    stubs, state, base = work / "stubs", work / "state", work / "base"
    for d in (stubs, state, base, work / "model"):
        d.mkdir(parents=True)
    for name, text in STUBS.items():
        (stubs / name).write_text(text)
        (stubs / name).chmod(0o755)
    (work / "model" / "s4e.inp").write_text("*Heading\n synthetic\n")
    log = state / "curl-requests.txt"
    log.touch()
    env = {"PATH": f"{stubs}{os.pathsep}{tools}", "HOME": str(work), "LC_ALL": locale, "CURL_LOG": str(log),
           "STUB_IMDS": imds, "STUB_ANSWER": answer, "STATE": str(state), "BASE_DIR": str(base),
           "ABAQUS_BIN": str(stubs / "smalauncher"), "DSLS_LICENSE": str(work / "DSLicSrv.txt"),
           "SLURM_JOB_NAME": "Abaqus.sbatch", "SLURM_JOB_ID": "4242", "SLURM_JOB_NUM_NODES": "2",
           "SLURM_NPROCS": "128", "SLURM_NODELIST": "node[1-2]"}
    proc = subprocess.run([BASH, str(SCRIPT), str(work / "model" / "s4e.inp"), "2022"], cwd=work, env=env,
                          capture_output=True, text=True, errors="replace", timeout=120)
    made = sorted(p.name for p in (base / "Abaqus" / "s4e").iterdir()) if (base / "Abaqus" / "s4e").is_dir() else []
    return proc, (made[0] if len(made) == 1 else None), log.read_text().splitlines()


def assert_runs_in(proc, run_dir: str | None, work: Path, itype: str) -> None:
    """The job ran the solver to its end, in one run directory named after `itype` ("" for none)."""
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert run_dir is not None, proc.stdout
    m = RUN_DIR.fullmatch(run_dir)
    assert m and m.group("type") == itype, run_dir
    assert (work / "state" / "solver.cwd").read_text().strip() == str(work / "base" / "Abaqus" / "s4e" / run_dir)
    assert f"Execution directory is: {work / 'base' / 'Abaqus' / 's4e' / run_dir}" in proc.stdout.splitlines()


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
    """The job goes on; the run directory's name has no instance type, nothing of an error page, and not the start of
    a type name cut off at the time limit."""
    proc, run_dir, _ = run(tmp_path, host_tools, imds)
    assert_runs_in(proc, run_dir, tmp_path, "")


@pytest.mark.parametrize("answer", NOT_TYPE_NAMES)
def test_an_answer_that_is_not_a_type_name_counts_as_none(answer, tmp_path, host_tools):
    """A proxy's page, a type name in capitals, a type name before or after other text, and a type name followed by
    a second line are not instance type names."""
    proc, run_dir, _ = run(tmp_path, host_tools, answer=answer)
    assert_runs_in(proc, run_dir, tmp_path, "")


def test_a_type_name_with_an_i_reads_in_a_turkish_locale(tmp_path, host_tools):
    """In a Turkish locale [a-z] leaves out i, so the type name is tested in the C locale."""
    if "tr_TR.utf8" not in subprocess.run(["locale", "-a"], capture_output=True, text=True).stdout.split():
        pytest.skip("the tr_TR.UTF-8 locale is not installed")
    proc, run_dir, _ = run(tmp_path, host_tools, answer="c8i.96xlarge", locale="tr_TR.UTF-8")
    assert_runs_in(proc, run_dir, tmp_path, "c8i.96xlarge")
