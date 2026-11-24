"""How Utils/OSU-Benchmarks's two job scripts say which provider and EFA devices carried each test.

These tests pin, for osu_benchmarks_openmpi.sbatch and osu_benchmarks_intelmpi.sbatch:
- the header: libfabric's version (fi_info --version, "unknown" without it) and each EFA device of the job's first
  node with its PCI vendor and device and its NUMA node;
- the job's first test, and only it, with the MPI's report of what it chose: Open MPI with --mca mtl_ofi_verbose 1
  --mca mtl_base_verbose 1, Intel MPI with I_MPI_DEBUG=5 unless the job gives I_MPI_DEBUG, which every test then
  keeps; its output shown, then one line with each value of its provider lines once (Open MPI 4.1's mtl:ofi:prov and
  mtl:ofi:provider lines, Open MPI 5.0's mtl:ofi:provider and mtl:ofi:provider:domain lines, Intel MPI's libfabric
  version and provider lines), or a NOTE when it printed none; its exit status kept, and its temporary file removed;
- after every test, one line per EFA device with how much each counter it has grew during the test (tx_bytes,
  rx_bytes, rdma_read_bytes, rdma_read_resp_bytes, rdma_write_bytes, rdma_write_recv_bytes, retrans_pkts), or a NOTE
  when no counter is readable.

They run copies of the job scripts with the stubs of tests/osu_harness.py, whose mpirun prints the provider lines its
MPI prints when asked for them and adds traffic to the synthetic devices' counters. Every value is synthetic.

Run with:
    python -m pip install -r tests/requirements.txt
    python -m pytest tests/test_osu_provider_check.py -q
"""
from __future__ import annotations

import pytest

import osu_harness as h

pytestmark = pytest.mark.skipif(h.BASH is None, reason="needs bash")
MPIS = tuple(h.LAUNCHERS)
VERBOSE = ["--mca", "mtl_ofi_verbose", "1", "--mca", "mtl_base_verbose", "1"]
NOTE_NONE = ("NOTE: osu_{} printed no provider line (Open MPI's mtl:ofi:prov lines, Intel MPI's libfabric version "
             "and provider lines)")


@pytest.fixture(scope="session")
def host_tools(tmp_path_factory):
    return h.host_tools_dir(tmp_path_factory)


def ran(job: h.Job) -> h.Job:
    assert job.proc.returncode == 0, job.proc.stdout + job.proc.stderr
    return job


def has_verbose(call: h.Call) -> bool:
    words = call.options
    return any(words[i:i + 6] == VERBOSE for i in range(len(words)))


def provider_lines(job: h.Job) -> list[str]:
    return [line for line in job.out if line.startswith("==> provider, from ")]


def traffic(job: h.Job) -> list[str]:
    return [line for line in job.out if line.startswith("==> EFA ")]


# --- the header ----------------------------------------------------------------------------------------------------

@pytest.mark.parametrize("name", MPIS)
def test_the_header_names_libfabric_and_each_efa_device(name, tmp_path, host_tools):
    devices = (h.Device("rdmap0s9", numa="0"), h.Device("rdmap1s9", device="0xefa3", numa="1"),
               h.Device("rdmap2s9", vendor=None, device=None, numa=None))
    job = ran(h.run(name, tmp_path, host_tools, devices=devices))
    assert "libfabric: 9.9.0stub" in job.out
    assert [line for line in job.out if line.startswith("EFA device")] == [
        "EFA device rdmap0s9: PCI 0x1d0f:0xefa1, NUMA node 0", "EFA device rdmap1s9: PCI 0x1d0f:0xefa3, NUMA node 1",
        "EFA device rdmap2s9: PCI unknown:unknown, NUMA node unknown"]
    assert job.fi_info == ["--version"]
    # After the settings, before the first test.
    settings = next(x for x in job.out if x.startswith("MPI settings"))
    assert job.out.index("libfabric: 9.9.0stub") > job.out.index(settings)
    assert job.out.index("libfabric: 9.9.0stub") < job.out.index(next(x for x in job.out if x.startswith("==> osu_")))


@pytest.mark.parametrize("name", MPIS)
def test_with_no_fi_info_libfabric_is_unknown_and_no_device_is_named(name, tmp_path, host_tools):
    job = ran(h.run(name, tmp_path, host_tools, fi_info=False, devices=()))
    assert "libfabric: unknown (fi_info --version named none)" in job.out
    assert "EFA devices: none in " + str(tmp_path / "sys" / "class" / "infiniband") in job.out


# --- the first test's provider report ------------------------------------------------------------------------------

@pytest.mark.parametrize("lines, summary", [
    ("4", "mtl:ofi:prov: efa; mtl:ofi:provider: rdmap0s9-rdm"),
    ("5", "mtl:ofi:provider: efa; mtl:ofi:provider:domain: rdmap0s9-rdm")], ids=["Open MPI 4.1", "Open MPI 5.0"])
def test_open_mpis_first_test_prints_its_provider_lines_and_their_summary(lines, summary, tmp_path, host_tools):
    job = ran(h.run("openmpi", tmp_path, host_tools, env={"STUB_OFI_LINES": lines}))
    assert [has_verbose(c) for c in job.calls] == [True] + [False] * (len(h.DEFAULT_TESTS) - 1)
    assert provider_lines(job) == [f"==> provider, from osu_latency: {summary}"]
    # The test's own provider lines are shown too, before the summary.
    first = next(line for line in job.out if "mtl:ofi:prov" in line and not line.startswith("==>"))
    assert job.out.index(first) < job.out.index(provider_lines(job)[0])


def test_open_mpis_report_goes_with_whichever_test_runs_first(tmp_path, host_tools):
    job = ran(h.run("openmpi", tmp_path, host_tools, env={"OSU_TESTS": "allreduce latency"}))
    assert [c.test for c in job.calls if has_verbose(c)] == ["osu_allreduce"]
    assert provider_lines(job) == ["==> provider, from osu_allreduce: mtl:ofi:prov: efa; mtl:ofi:provider: "
                                   "rdmap0s9-rdm"]


def test_intel_mpis_first_test_runs_with_i_mpi_debug_5_and_the_others_without(tmp_path, host_tools):
    job = ran(h.run("intelmpi", tmp_path, host_tools))
    assert [c.env.get("I_MPI_DEBUG") for c in job.calls] == ["5"] + [None] * (len(h.DEFAULT_TESTS) - 1)
    assert provider_lines(job) == ["==> provider, from osu_latency: libfabric version: 9.9.0stub; libfabric "
                                   "provider: efa"]
    words = next(line for line in job.out if line.startswith("MPI settings: ")).split()
    assert "I_MPI_DEBUG=5" in words and "only)" in words


@pytest.mark.parametrize("given", ["2", "6"])
def test_an_i_mpi_debug_the_job_gives_applies_to_every_test(given, tmp_path, host_tools):
    job = ran(h.run("intelmpi", tmp_path, host_tools, env={"I_MPI_DEBUG": given}))
    assert [c.env.get("I_MPI_DEBUG") for c in job.calls] == [given] * len(h.DEFAULT_TESTS)
    assert provider_lines(job) == ["==> provider, from osu_latency: libfabric version: 9.9.0stub; libfabric "
                                   "provider: efa"]
    assert f"I_MPI_DEBUG={given}" in next(line for line in job.out if line.startswith("MPI settings: ")).split()


def test_a_first_test_that_prints_no_provider_line_gets_a_note(tmp_path, host_tools):
    """I_MPI_DEBUG=0 given: Intel MPI prints no startup report."""
    job = ran(h.run("intelmpi", tmp_path, host_tools, env={"I_MPI_DEBUG": "0"}))
    assert provider_lines(job) == []
    assert NOTE_NONE.format("latency") in job.out


@pytest.mark.parametrize("name", MPIS)
def test_the_first_tests_exit_status_is_kept_and_its_temporary_file_removed(name, tmp_path, host_tools):
    job = h.run(name, tmp_path, host_tools, env={"STUB_RC": "osu_latency=3"})
    assert job.proc.returncode == 1, job.proc.stdout + job.proc.stderr
    summary = job.out[job.out.index("==> Summary") + 1:]
    assert summary[0].split(maxsplit=1) == ["osu_latency", "exit status 3"]
    assert [line.split()[1] for line in summary[1:]] == ["ok"] * (len(h.DEFAULT_TESTS) - 1)
    assert list((tmp_path / "tmp").iterdir()) == []


# --- each test's traffic -------------------------------------------------------------------------------------------

@pytest.mark.parametrize("name", MPIS)
def test_each_test_is_followed_by_each_devices_counters_growth(name, tmp_path, host_tools):
    job = ran(h.run(name, tmp_path, host_tools, env={"STUB_TRAFFIC": "8192"}))
    grown = "tx_bytes +8192 rx_bytes +8192 rdma_read_bytes +8192 rdma_read_resp_bytes +0 rdma_write_bytes +0 " \
            "rdma_write_recv_bytes +0 retrans_pkts +0"
    assert traffic(job) == [f"==> EFA {d} during osu_{t}: {grown}" for t in h.DEFAULT_TESTS
                            for d in ("rdmap0s9", "rdmap1s9")]
    # Each test's lines come after its output and before the next test's layout line.
    for t in h.DEFAULT_TESTS:
        i = job.out.index(f"==> EFA rdmap0s9 during osu_{t}: {grown}")
        assert job.out[i - 1].startswith("# OSU MPI stub: osu_") or job.out[i - 1].startswith("==> provider")


@pytest.mark.parametrize("name", MPIS)
def test_a_device_shows_only_the_counters_it_has(name, tmp_path, host_tools):
    devices = (h.Device("rdmap0s9", counters=("tx_bytes", "rx_bytes")), h.Device("rdmap1s9", counters=()))
    job = ran(h.run(name, tmp_path, host_tools, devices=devices, env={"OSU_TESTS": "bw"}))
    assert traffic(job) == ["==> EFA rdmap0s9 during osu_bw: tx_bytes +4096 rx_bytes +4096"]


@pytest.mark.parametrize("devices", [(), (h.Device("rdmap0s9", counters=None),)], ids=["no device", "no counters"])
@pytest.mark.parametrize("name", MPIS)
def test_no_readable_counter_gives_one_note_per_test(name, devices, tmp_path, host_tools):
    job = ran(h.run(name, tmp_path, host_tools, devices=devices))
    note = (f"NOTE: no EFA counter of this node is readable ({tmp_path}/sys/class/infiniband/<device>/ports/1/"
            "hw_counters)")
    assert job.out.count(note) == len(h.DEFAULT_TESTS)
    assert traffic(job) == []
