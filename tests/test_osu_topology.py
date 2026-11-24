"""How Utils/OSU-Benchmarks's two job scripts name each node's instance, for EC2's instance topology.

These tests pin, for osu_benchmarks_openmpi.sbatch and osu_benchmarks_intelmpi.sbatch:
- one srun step, one task on each of the job's nodes, reads each node's instance id from its instance metadata
  (IMDSv2); each request fails on an HTTP error and gives up within 5 seconds;
- after the node list, one line per node, "<host> <instance id>", in the hosts' order; no answer, an HTTP error, an
  answer cut off at the time limit, or an answer that is not an instance id (tested in the C locale) gives
  "unknown", and the job runs on;
- a NOTE when srun gives no line.

They run copies of the job scripts with the stubs of tests/osu_harness.py, whose srun runs its command once per host
and whose curl answers each host's instance id. Every value is synthetic.

Run with:
    python -m pip install -r tests/requirements.txt
    python -m pytest tests/test_osu_topology.py -q
"""
from __future__ import annotations

import re

import pytest

import osu_harness as h

pytestmark = pytest.mark.skipif(h.BASH is None, reason="needs bash")
MPIS = tuple(h.LAUNCHERS)
IDS = {"n1": "i-0123456789abcdef0", "n2": "i-0fedcba98765432a1", "n3": "i-00000000aaaabbbb", "n4": "i-1a2b3c4d"}


@pytest.fixture(scope="session")
def host_tools(tmp_path_factory):
    return h.host_tools_dir(tmp_path_factory)


def ran(job: h.Job) -> h.Job:
    assert job.proc.returncode == 0, job.proc.stdout + job.proc.stderr
    assert len(job.calls) == len(h.DEFAULT_TESTS)
    return job


def id_lines(job: h.Job) -> list[str]:
    """The lines after "Instance ids:"."""
    i = job.out.index("Instance ids:")
    lines = []
    for line in job.out[i + 1:]:
        if not line.startswith("    "):
            break
        lines.append(line.strip())
    return lines


@pytest.mark.parametrize("nodes", [1, 2, 4])
@pytest.mark.parametrize("name", MPIS)
def test_one_srun_step_names_each_nodes_instance_after_the_node_list(name, nodes, tmp_path, host_tools):
    job = ran(h.run(name, tmp_path, host_tools, nodes=nodes, ids=IDS))
    assert job.events.count("srun") == 1
    assert job.srun[0].startswith(f"--nodes={nodes} --ntasks={nodes} --ntasks-per-node=1 bash -c "), job.srun
    assert id_lines(job) == [f"n{i} {IDS[f'n{i}']}" for i in range(1, nodes + 1)]
    assert job.out.index("Instance ids:") == job.out.index(next(x for x in job.out if x.startswith("Nodes: "))) + 1
    assert job.out.index("Instance ids:") < job.out.index(next(x for x in job.out if x.startswith("OSU settings")))
    # The step comes before any MPI.
    assert job.events.index("srun") < job.events.index("mpirun 1")


def test_the_lines_follow_the_hosts_order(tmp_path, host_tools):
    ids = {f"n{i}": f"i-{i:017x}" for i in range(1, 11)}
    job = ran(h.run("openmpi", tmp_path, host_tools, nodes=10, ids=ids))
    assert id_lines(job) == [f"n{i} {ids[f'n{i}']}" for i in range(1, 11)]


@pytest.mark.parametrize("name", MPIS)
def test_each_nodes_requests_fail_on_an_http_error_and_give_up_within_5_seconds(name, tmp_path, host_tools):
    job = ran(h.run(name, tmp_path, host_tools, ids=IDS))
    on_nodes = [(host, args) for host, args in job.curl if host]
    assert [host for host, _ in on_nodes] == ["n1", "n1", "n2", "n2"]
    for i in (0, 2):
        assert "latest/api/token" in on_nodes[i][1] and "meta-data/instance-id" in on_nodes[i + 1][1], on_nodes
    for _, request in on_nodes:
        words = request.split()
        assert any(w == "--fail" or re.fullmatch(r"-[a-zA-Z]*f[a-zA-Z]*", w) for w in words), request
        assert re.search(r"(^| )--connect-timeout [1-5]( |$)", request), request
        assert re.search(r"(^| )--max-time [1-5]( |$)", request), request


@pytest.mark.parametrize("imds", ["no-answer", "http-error", "cut-off"])
@pytest.mark.parametrize("name", MPIS)
def test_no_answer_an_http_error_or_a_cut_off_answer_gives_unknown(name, imds, tmp_path, host_tools):
    """A cut-off id still looks like an instance id: only curl's status tells it from a whole one."""
    job = ran(h.run(name, tmp_path, host_tools, ids=IDS, env={"STUB_IMDS": imds}))
    assert id_lines(job) == ["n1 unknown", "n2 unknown"]


NOT_IDS = [
    pytest.param("<html><body>Request denied by proxy.example.com</body></html>", id="a proxy's page"),
    pytest.param("I-0123456789ABCDEF0", id="capitals"),
    pytest.param("i-0123456", id="too short"),
    pytest.param("i-0123456789abcdef01", id="too long"),
    pytest.param("i-0123456789abcdef0 extra", id="an id, then other text"),
    pytest.param("i-0123456789abcdef0\n<p>second line</p>", id="an id, then a second line"),
    pytest.param("", id="empty"),
]


@pytest.mark.parametrize("answer", NOT_IDS)
@pytest.mark.parametrize("name", MPIS)
def test_an_answer_that_is_not_an_instance_id_gives_unknown(name, answer, tmp_path, host_tools):
    job = ran(h.run(name, tmp_path, host_tools, ids={"n1": IDS["n1"], "n2": answer}))
    assert id_lines(job) == [f"n1 {IDS['n1']}", "n2 unknown"]


@pytest.mark.parametrize("name", MPIS)
def test_no_line_from_srun_gives_a_note(name, tmp_path, host_tools):
    """With no host, the stub srun runs nothing and prints nothing."""
    job = ran(h.run(name, tmp_path, host_tools, ids=IDS, env={"STUB_HOSTS": ""}))
    assert "NOTE: srun gave no instance id of the nodes" in job.out
    assert "Instance ids:" not in job.out
