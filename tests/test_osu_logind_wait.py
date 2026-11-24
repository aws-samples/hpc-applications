"""How Utils/OSU-Benchmarks's two job scripts wait while systemd-logind closes the user's session.

A job submitted with an sbatch --export list starts with Slurm's `su - <user>` on its first node, after which
systemd-logind (RemoveIPC=yes, its default) removes the user's files in /dev/shm about 10 seconds later. These tests
pin, for osu_benchmarks_openmpi.sbatch and osu_benchmarks_intelmpi.sbatch:
- while `loginctl show-user <uid> -p State --value` answers closing, the job waits 0.5 s and asks again, at most 60
  times (30 s), then prints how long it waited, all before its first test's mpirun and after its settings;
- with any other answer (none, active), or with no loginctl on the PATH, it does not wait and prints nothing.

They run copies of the job scripts with the stubs of tests/osu_harness.py; the stub sleep returns at once. Every value
is synthetic.

Run with:
    python -m pip install -r tests/requirements.txt
    python -m pytest tests/test_osu_logind_wait.py -q
"""
from __future__ import annotations

import os

import pytest

import osu_harness as h

pytestmark = pytest.mark.skipif(h.BASH is None, reason="needs bash")
MPIS = tuple(h.LAUNCHERS)
QUERY = f"show-user {os.getuid()} -p State --value"


@pytest.fixture(scope="session")
def host_tools(tmp_path_factory):
    return h.host_tools_dir(tmp_path_factory)


def before_first_mpirun(job: h.Job) -> list[str]:
    """The loginctl and sleep calls before the first test's mpirun."""
    first = job.events.index("mpirun 1")
    return [e for e in job.events[:first] if e.startswith(("loginctl", "sleep"))]


def waited_lines(job: h.Job) -> list[str]:
    return [line for line in job.out if line.startswith("==> waited ")]


@pytest.mark.parametrize("name", MPIS)
def test_the_job_waits_while_logind_closes_the_session_before_the_first_test(name, tmp_path, host_tools):
    job = h.run(name, tmp_path, host_tools, env={"STUB_LOGIND": "closing:3"})
    assert job.proc.returncode == 0, job.proc.stdout + job.proc.stderr
    # Three answers "closing", each followed by 0.5 s, then the freed user's error: four calls, all before mpirun.
    assert job.loginctl == [QUERY] * 4
    assert before_first_mpirun(job) == ["loginctl", "sleep 0.5"] * 3 + ["loginctl"]
    assert [e for e in job.events if e.startswith(("loginctl", "sleep"))] == before_first_mpirun(job)
    assert waited_lines(job) == ["==> waited 1.5 s while systemd-logind closed this user's session, before starting "
                                 "MPI"]
    line = job.out.index(waited_lines(job)[0])
    assert line > job.out.index(next(x for x in job.out if x.startswith("MPI settings: ")))
    assert line < job.out.index(next(x for x in job.out if x.startswith("==> osu_latency")))
    assert len(job.calls) == len(h.DEFAULT_TESTS)


@pytest.mark.parametrize("name", MPIS)
def test_the_wait_stops_after_30_seconds(name, tmp_path, host_tools):
    job = h.run(name, tmp_path, host_tools, env={"STUB_LOGIND": "closing:1000"})
    assert job.proc.returncode == 0, job.proc.stdout + job.proc.stderr
    assert before_first_mpirun(job).count("sleep 0.5") == 60
    assert waited_lines(job) == ["==> waited 30.0 s while systemd-logind closed this user's session, before starting "
                                 "MPI"]
    assert len(job.calls) == len(h.DEFAULT_TESTS)


@pytest.mark.parametrize("closing, shown", [(1, "0.5"), (2, "1.0"), (7, "3.5")])
def test_the_wait_is_printed_in_seconds(closing, shown, tmp_path, host_tools):
    job = h.run("openmpi", tmp_path, host_tools, env={"STUB_LOGIND": f"closing:{closing}"})
    assert waited_lines(job) == [f"==> waited {shown} s while systemd-logind closed this user's session, before "
                                 "starting MPI"]


@pytest.mark.parametrize("logind", ["none", "active"])
@pytest.mark.parametrize("name", MPIS)
def test_no_wait_when_logind_is_not_closing_the_session(name, logind, tmp_path, host_tools):
    job = h.run(name, tmp_path, host_tools, env={"STUB_LOGIND": logind})
    assert job.proc.returncode == 0, job.proc.stdout + job.proc.stderr
    assert job.loginctl == [QUERY]
    assert before_first_mpirun(job) == ["loginctl"]
    assert waited_lines(job) == []


@pytest.mark.parametrize("name", MPIS)
def test_no_loginctl_on_the_path_means_no_wait(name, tmp_path, host_tools):
    job = h.run(name, tmp_path, host_tools, loginctl=False, env={"STUB_LOGIND": "closing:3"})
    assert job.proc.returncode == 0, job.proc.stdout + job.proc.stderr
    assert job.loginctl == [] and before_first_mpirun(job) == []
    assert waited_lines(job) == []
