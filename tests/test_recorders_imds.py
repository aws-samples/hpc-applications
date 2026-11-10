"""How the recorders read the instance type from the instance metadata.

When no --instance-type (or INSTANCE_TYPE) is given, each application's dynamodb/record-benchmark.sh reads the instance
type from the instance metadata (IMDSv2). Each request gives up after 2 seconds (1 to connect) and fails on an HTTP
error (curl -f). An answer cut off at that limit, and an answer that is not an instance type name (tested in the C
locale), such as a proxy's page or a type name in capitals or inside other text, count as no answer. The record then
has no instance type, which every row needs, so the recorder stops with the error that names the missing field, as
it does with no answer at all: it prints no record and writes no file. A type given with --instance-type is used as
given, and the instance metadata is not asked.

These tests run all eleven recorders in --dry-run, which prints the record and touches no file and no AWS, with a stub
curl that answers as each case asks and logs every request, and a PATH that holds no other curl, aws, mpirun, fi_info
or Slurm command. Every value passed is synthetic.

Run with:
    python -m pip install -r tests/requirements.txt
    python -m pytest tests/test_recorders_imds.py -q
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
APPS = ("AnsysMechanical", "CFX", "Fluent", "Gromacs", "LAMMPS", "LS-Dyna", "OpenFoam", "OpenRadioss",
        "Optistruct", "StarCCM", "WRF")
# A run described in full but for its instance type, so that no recorder needs Slurm or an MPI.
RUN_ARGS = ("--os", "Amazon Linux 2023", "--num-cores", "192", "--num-nodes", "1", "--mpi", "openmpi",
            "--version", "1.0", "--case", "synthetic-case", "--time-to-solution", "100", "--source", "TestSuite")
MISSING = "ERROR: missing required field: instance_type (--instance-type)"
# Host commands the recorders must not find: the stub stands in for curl, and the recorders read the MPI, libfabric
# and EFA versions from mpirun and fi_info when they are on the PATH.
HIDDEN = frozenset({"aws", "aws_completer", "curl", "mpirun", "mpiexec", "fi_info", "srun", "sbatch", "scontrol",
                    "squeue", "sinfo"})
# The stub curl. It logs each request's arguments to CURL_LOG, answers the token request with a token, and the
# instance type request with STUB_ANSWER (as given: no newline added), then exits with STUB_EXIT: 0, or curl's code
# for a refused connection (7), an HTTP error under -f (22, with no output) or the end of --max-time (28).
CURL_STUB = """#!/bin/sh
printf '%s\\n' "$*" >> "$CURL_LOG"
case "$*" in
    *api/token*) printf 'stub-token'; exit 0 ;;
esac
printf '%s' "$STUB_ANSWER"
exit "${STUB_EXIT:-0}"
"""
BASH = shutil.which("bash")
pytestmark = pytest.mark.skipif(BASH is None, reason="needs bash")


def recorder(app: str) -> Path:
    return REPO / "apps" / app / "dynamodb" / "record-benchmark.sh"


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


def run_recorder(app: str, work: Path, tools: Path, answer: str = "", status: int = 0, *extra: str,
                 locale: str = "C", env_extra: dict[str, str] | None = None):
    """Run one recorder in --dry-run in `work`, with the stub curl answering `answer` and exiting `status` for the
    instance type. Returns the process and the requests the stub logged."""
    stubs, log = work / "stubs", work / "curl-requests.txt"
    stubs.mkdir(parents=True)
    (stubs / "curl").write_text(CURL_STUB)
    (stubs / "curl").chmod(0o755)
    log.touch()
    env = {"PATH": f"{stubs}{os.pathsep}{tools}", "HOME": str(work), "LC_ALL": locale, "CURL_LOG": str(log),
           "STUB_ANSWER": answer, "STUB_EXIT": str(status), **(env_extra or {})}
    proc = subprocess.run([BASH, str(recorder(app)), *RUN_ARGS, "--dry-run", "--run-dir", str(work), *extra],
                          cwd=work, env=env, capture_output=True, text=True, errors="replace", timeout=120)
    return proc, log.read_text().splitlines()


def assert_recorded(proc, itype: str) -> None:
    assert proc.returncode == 0, proc.stderr
    assert f'"instance_type": {{"S": "{itype}"}}' in proc.stdout, proc.stdout
    assert re.search(rf'"record_id": {{"S": "[^"]*-{re.escape(itype)}-192c-', proc.stdout), proc.stdout
    assert MISSING not in proc.stderr, proc.stderr


def assert_no_instance_type(proc, answer: str) -> None:
    """The recorder stopped on the missing instance type: exit 1, the field named, no record, and nothing of the
    answer anywhere."""
    assert proc.returncode == 1, proc.stdout + proc.stderr
    assert MISSING in proc.stderr, proc.stderr
    assert '"instance_type"' not in proc.stdout and "DRY RUN" not in proc.stdout, proc.stdout
    for word in re.findall(r"[A-Za-z0-9.]{4,}", answer):
        assert word not in proc.stdout + proc.stderr, word


@pytest.mark.parametrize("app", APPS)
def test_the_instance_type_from_imds_is_recorded(app, tmp_path, host_tools):
    """An instance type name from the instance metadata becomes the record's instance_type and names its record_id."""
    proc, _ = run_recorder(app, tmp_path, host_tools, "hpc7a.96xlarge")
    assert_recorded(proc, "hpc7a.96xlarge")


@pytest.mark.parametrize("app", APPS)
def test_an_answer_that_is_not_a_type_name_counts_as_none(app, tmp_path, host_tools):
    """A proxy's page, a type name in capitals, and a type name inside other text (after it, or before a second line)
    are not instance type names: the record gets none, so the recorder stops on the missing field."""
    answers = ("<html><head><title>Proxy</title></head>\n<body>Request not allowed by proxy.example.com</body></html>",
               "HPC7A.96XLARGE", "hpc7a.96xlarge: not found", "hpc7a.96xlarge\n<p>Request checked by proxy.example.com")
    for i, answer in enumerate(answers):
        proc, _ = run_recorder(app, tmp_path / str(i), host_tools, answer)
        assert_no_instance_type(proc, answer)


@pytest.mark.parametrize("app", APPS)
def test_an_answer_cut_off_at_the_time_limit_counts_as_none(app, tmp_path, host_tools):
    """The start of a type name, then curl's exit at its --max-time (28): no instance type, not a shortened one."""
    proc, _ = run_recorder(app, tmp_path, host_tools, "hpc7a.96x", 28)
    assert_no_instance_type(proc, "hpc7a.96x")


@pytest.mark.parametrize("app", APPS)
def test_no_answer_and_an_http_error_count_as_none(app, tmp_path, host_tools):
    """A refused connection (7), an HTTP error under -f (22) and no answer within --max-time (28): no instance type."""
    for status in (7, 22, 28):
        proc, _ = run_recorder(app, tmp_path / str(status), host_tools, "", status)
        assert_no_instance_type(proc, "")


@pytest.mark.parametrize("app", APPS)
def test_every_request_has_a_time_limit_and_fails_on_an_http_error(app, tmp_path, host_tools):
    """Both requests, the token's and the instance type's, carry -f, --connect-timeout and a --max-time of at most
    5 seconds."""
    _, requests = run_recorder(app, tmp_path, host_tools, "hpc7a.96xlarge")
    assert len(requests) == 2, requests
    assert "latest/api/token" in requests[0] and "meta-data/instance-type" in requests[1], requests
    for request in requests:
        words = request.split()
        assert any(w == "--fail" or re.fullmatch(r"-[a-zA-Z]*f[a-zA-Z]*", w) for w in words), request
        assert re.search(r"(^| )--connect-timeout [1-5]( |$)", request), request
        assert re.search(r"(^| )--max-time [1-5]( |$)", request), request


@pytest.mark.parametrize("app", APPS)
def test_a_type_name_with_an_i_reads_in_a_turkish_locale(app, tmp_path, host_tools):
    """In a Turkish locale [a-z] leaves out i, so the type name is tested in the C locale."""
    if "tr_TR.utf8" not in subprocess.run(["locale", "-a"], capture_output=True, text=True).stdout.split():
        pytest.skip("the tr_TR.UTF-8 locale is not installed")
    proc, _ = run_recorder(app, tmp_path, host_tools, "c8i.96xlarge", locale="tr_TR.UTF-8")
    assert_recorded(proc, "c8i.96xlarge")


@pytest.mark.parametrize("app", APPS)
def test_a_given_instance_type_is_used_as_given(app, tmp_path, host_tools):
    """--instance-type, or INSTANCE_TYPE, is the record's instance type as given, and the instance metadata is not
    asked: the test of the metadata's answer is not applied to it."""
    proc, requests = run_recorder(app, tmp_path / "flag", host_tools, "hpc8a.96xlarge", 0,
                                  "--instance-type", "hpc7a.96xlarge")
    assert_recorded(proc, "hpc7a.96xlarge")
    assert requests == [], requests
    proc, requests = run_recorder(app, tmp_path / "variable", host_tools, "hpc8a.96xlarge",
                                  env_extra={"INSTANCE_TYPE": "hpc7a.96xlarge"})
    assert_recorded(proc, "hpc7a.96xlarge")
    assert requests == [], requests
    proc, requests = run_recorder(app, tmp_path / "custom", host_tools, "hpc8a.96xlarge", 0,
                                  "--instance-type", "Custom-Node")
    assert proc.returncode == 0, proc.stderr
    assert '"instance_type": {"S": "Custom-Node"}' in proc.stdout, proc.stdout
    assert requests == [], requests
