"""How the recorders tell a contributor to share a run.

Each application's dynamodb/record-benchmark.sh always saves the run as a JSON
file. When it writes no row to DynamoDB, because it found no AWS CLI on the
PATH, with --put or by default, or because the default write was refused, it
prints a NOTE that says how to share that file: attach it to a Benchmark
results issue, the form in .github/ISSUE_TEMPLATE/benchmark-results.yml, and
rename a confidential case first, since the issue, the JSON and its file's
name are public. Either way it exits 0. With --put, a refused write still
ends the run with exit 1; with --no-put, the run prints its own line instead.

These tests run all eleven recorders on those paths with stubs only: a curl
that answers nothing (no instance metadata), an aws whose put-item is refused,
and a PATH that holds no other aws, curl, mpirun, fi_info or Slurm command.
Nothing reaches AWS, and every value passed is synthetic. The last checks keep
the old wording out of every recorder's --help, where seven recorders name the
issue instead, the "zero-arg" shorthand out of it too, where --run-dir now
says what it allows (a launch script can call the recorder with no arguments),
and "their contribution inbox" out of every file.

Run with:
    python -m pip install -r tests/requirements.txt
    python -m pytest tests/test_recorders_share_line.py -q
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
APPS = ("AnsysMechanical", "CFX", "Fluent", "Gromacs", "LAMMPS", "LS-Dyna", "OpenFoam", "OpenRadioss",
        "Optistruct", "StarCCM", "WRF")
# The recorders whose header comment, which --help prints, says how to share a run.
HEADER_APPS = ("CFX", "Fluent", "LAMMPS", "LS-Dyna", "OpenFoam", "Optistruct", "StarCCM")
FORM_URL = "https://github.com/aws-samples/hpc-applications/issues/new?template=benchmark-results.yml"
OLD_WORDING = ("dataset owner", "contribution inbox")

# A run described in full, so that no recorder needs Slurm, instance metadata or an MPI.
RUN_ARGS = ("--instance-type", "hpc7a.96xlarge", "--os", "Amazon Linux 2023", "--num-cores", "192",
            "--num-nodes", "1", "--mpi", "openmpi", "--version", "1.0", "--case", "synthetic-case",
            "--time-to-solution", "100", "--source", "TestSuite")

# Host commands the recorders must not find: the stubs stand in for aws and curl, and the recorders read the MPI,
# libfabric and EFA versions from mpirun and fi_info when they are on the PATH.
HIDDEN = frozenset({"aws", "aws_completer", "curl", "mpirun", "mpiexec", "fi_info", "srun", "sbatch", "scontrol",
                    "squeue", "sinfo"})

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


def write_stub(path: Path, body: str) -> None:
    path.write_text("#!/bin/sh\n" + body)
    path.chmod(0o755)


def run_recorder(app: str, work: Path, tools: Path, *extra: str, aws: bool = False):
    """Run one recorder in `work`, saving its JSON under work/out. With aws=True, the PATH holds an aws whose
    put-item is refused (exit 1) and which logs its arguments to work/aws-calls.txt."""
    stubs, run_dir, out = work / "stubs", work / "run", work / "out"
    stubs.mkdir(parents=True)
    run_dir.mkdir()
    write_stub(stubs / "curl", "exit 7\n")
    calls = work / "aws-calls.txt"
    if aws:
        write_stub(stubs / "aws", f'printf "%s\\n" "$*" >> "{calls}"\necho "stub: put-item refused" >&2\nexit 1\n')
    env = {"PATH": f"{stubs}{os.pathsep}{tools}", "HOME": str(work), "LC_ALL": "C"}
    proc = subprocess.run([BASH, str(recorder(app)), *RUN_ARGS, "--run-dir", str(run_dir), "--out", str(out),
                           *extra], cwd=run_dir, env=env, capture_output=True, text=True, errors="replace",
                          timeout=120)
    return proc, out, calls


def saved_json(out: Path) -> Path:
    """The one JSON record the run saved, which must parse."""
    files = sorted(out.glob("*.json"))
    assert len(files) == 1, files
    json.loads(files[0].read_text())
    return files[0]


def assert_says_how_to_share(proc, json_file: Path) -> None:
    for text in (str(json_file), FORM_URL, "its file's name", "rename a confidential case in both first"):
        assert text in proc.stderr, proc.stderr
    for old in OLD_WORDING:
        assert old not in proc.stdout + proc.stderr, proc.stdout + proc.stderr


@pytest.mark.parametrize("app", APPS)
def test_put_without_aws_cli_names_the_form(app, tmp_path, host_tools):
    """--put with no AWS CLI on the PATH: the JSON is kept, the NOTE names the form, and the run exits 0."""
    proc, out, _ = run_recorder(app, tmp_path, host_tools, "--put")
    assert proc.returncode == 0, proc.stderr
    json_file = saved_json(out)
    assert "NOTE: AWS CLI not found; kept JSON only." in proc.stderr
    assert_says_how_to_share(proc, json_file)


@pytest.mark.parametrize("app", APPS)
def test_refused_write_names_the_form(app, tmp_path, host_tools):
    """The default write, refused: the JSON is kept, the NOTE names the form, and the run exits 0. With --put, the
    same refusal still ends the run with exit 1 and its ERROR line."""
    proc, out, calls = run_recorder(app, tmp_path / "default", host_tools, aws=True)
    assert proc.returncode == 0, proc.stderr
    assert "dynamodb put-item" in calls.read_text()
    json_file = saved_json(out)
    assert "NOTE: could not write to DynamoDB" in proc.stderr
    assert_says_how_to_share(proc, json_file)

    proc, out, _ = run_recorder(app, tmp_path / "put", host_tools, "--put", aws=True)
    assert proc.returncode == 1, proc.stderr
    assert "ERROR: put-item failed" in proc.stderr
    saved_json(out)


@pytest.mark.parametrize("app", APPS)
def test_default_without_aws_cli_names_the_form(app, tmp_path, host_tools):
    """Neither --put nor --no-put, and no AWS CLI on the PATH: the JSON is kept, the NOTE that --put prints there
    names the form, and the run exits 0. An explicit --no-put still prints its own line, and not the form's URL."""
    proc, out, _ = run_recorder(app, tmp_path / "default", host_tools)
    assert proc.returncode == 0, proc.stderr
    json_file = saved_json(out)
    assert "NOTE: AWS CLI not found; kept JSON only." in proc.stderr
    assert "Skipped DynamoDB write" not in proc.stdout, proc.stdout
    assert_says_how_to_share(proc, json_file)

    proc, out, _ = run_recorder(app, tmp_path / "no-put", host_tools, "--no-put")
    assert proc.returncode == 0, proc.stderr
    assert "Skipped DynamoDB write (--no-put)." in proc.stdout, proc.stdout
    assert FORM_URL not in proc.stdout + proc.stderr, proc.stdout + proc.stderr
    saved_json(out)


def test_help_names_the_issue_not_the_old_channel(tmp_path, host_tools):
    """No recorder's --help names the dataset owner or a contribution inbox. The seven whose header comment says how
    to share a run name the Benchmark results issue there."""
    env = {"PATH": str(host_tools), "HOME": str(tmp_path), "LC_ALL": "C"}
    problems = []
    for app in APPS:
        proc = subprocess.run([BASH, str(recorder(app)), "--help"], cwd=tmp_path, env=env, capture_output=True,
                              text=True, errors="replace", timeout=120)
        text = " ".join(proc.stdout.split())
        if proc.returncode != 0:
            problems.append(f"{app}: exit {proc.returncode}")
        problems += [f"{app}: says {old!r}" for old in OLD_WORDING if old in text.lower()]
        if app in HEADER_APPS and "Benchmark results issue" not in text:
            problems.append(f"{app}: names no Benchmark results issue")
    assert not problems, problems


@pytest.mark.parametrize("app", APPS)
def test_help_says_what_run_dir_allows(app, tmp_path, host_tools):
    """--help explains --run-dir in plain words, without the "zero-arg" shorthand."""
    env = {"PATH": str(host_tools), "HOME": str(tmp_path), "LC_ALL": "C"}
    proc = subprocess.run([BASH, str(recorder(app)), "--help"], cwd=tmp_path, env=env, capture_output=True,
                          text=True, errors="replace", timeout=120)
    assert proc.returncode == 0, proc.stderr
    assert "zero-arg" not in proc.stdout.lower(), proc.stdout
    assert "Lets a launch script call the recorder with no arguments." in " ".join(proc.stdout.split()), proc.stdout


def test_no_file_names_a_contribution_inbox():
    """No recorder, README, guide or form sends contributors to "their contribution inbox", a place no page named."""
    this_file = Path(__file__).resolve()
    hits = []
    for root, dirs, files in os.walk(REPO):
        dirs[:] = [d for d in dirs if d not in {"__pycache__", "node_modules"}
                   and (d == ".github" or not d.startswith("."))]
        for name in files:
            path = Path(root, name)
            if path == this_file:
                continue
            data = path.read_bytes()
            if b"\0" in data:
                continue
            for number, line in enumerate(data.decode("utf-8", "replace").splitlines(), 1):
                if "contribution inbox" in line.lower():
                    hits.append(f"{path.relative_to(REPO)}:{number}")
    assert not hits, hits
