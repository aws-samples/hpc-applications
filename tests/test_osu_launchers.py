"""How Utils/OSU-Benchmarks/osu_benchmarks_openmpi.sbatch and osu_benchmarks_intelmpi.sbatch run the OSU tests.

These tests pin, for both launchers:
- the tests, in OSU_TESTS's order (by default osu_latency, osu_bw, osu_bibw, osu_mbw_mr, osu_allreduce; the osu_
  prefix is allowed), each with the options of OSU_ARGS, from OSU_DIR (by default the install of the matching build
  script), every test run even after one that ends with another status than 0, then a summary, and the job's exit
  status: 1 when any test ended with another status than 0, else 0;
- the layouts: the pair tests (osu_latency, osu_bw, osu_bibw) with 2 ranks, one on each of the first two nodes, both
  bound to the first CPU of the NUMA node of the first EFA device (core 0 when that is unknown), with Open MPI by
  taskset and --bind-to none (Open MPI refuses --cpu-set beside --map-by, as the stub mpirun does), or both on a
  job's only node; the multi-pair and collective tests with OSU_PPN ranks on every node, by default the node's
  cores from lscpu, in the C locale (SLURM_CPUS_ON_NODE when lscpu shows none), each rank bound to a core;
- what stops a job before any MPI or module starts: no Slurm job, an unknown test, an OSU_PPN out of range, an odd
  rank count for osu_mbw_mr or osu_multi_lat, one rank for a test that needs two, a missing binary; and, once the
  modules have loaded, an mpirun that is not the launcher's MPI;
- the MPI: Open MPI 4 from module openmpi, then libfabric-aws, with the cm PML over the ofi MTL and FI_PROVIDER=efa,
  each kept when the job's environment gives it; Intel MPI from module intelmpi, loaded once after
  I_MPI_OFI_LIBRARY_INTERNAL=0 (a value the job gives is kept), then libfabric-aws, with I_MPI_FABRICS=shm:ofi,
  I_MPI_OFI_PROVIDER=efa, I_MPI_MULTIRAIL=1 and I_MPI_DEBUG=5 (each kept when given), its pinning (none of it when the
  job sets any), and I_MPI_HYDRA_BOOTSTRAP=slurm with --external-launcher when Slurm's own
  OMPI_MCA_plm_slurm_args says srun has it; with no module command, the MPI on the PATH, with a NOTE;
- FI_EFA_USE_DEVICE_RDMA=1 when every EFA device is Amazon's and none is 0xefa0 (passed to Open MPI's ranks with -x),
  else unset, and a value the job gives kept;
- the output: the first line (MPI, nodes, instance type from the instance metadata or "unknown"), the nodes, the build
  record when there is one, the settings, a layout line per test;
- the instance metadata reads: each request fails on an HTTP error and gives up within 5 seconds, and no answer, an
  error page, an answer cut off at that limit, or one that is not an instance type name gives "unknown";
- the blocks the two launchers share are the same in both.

They run copies of the launchers with stubs (tests/osu_harness.py). Every value is synthetic.

Run with:
    python -m pip install -r tests/requirements.txt
    python -m pytest tests/test_osu_launchers.py -q
"""
from __future__ import annotations

import os
import re
import subprocess

import pytest

import osu_harness as h

pytestmark = pytest.mark.skipif(h.BASH is None, reason="needs bash")
MPIS = tuple(h.LAUNCHERS)
CORES = 16          # the harness's default node: 2 sockets x 8 cores


@pytest.fixture(scope="session")
def host_tools(tmp_path_factory):
    return h.host_tools_dir(tmp_path_factory)


def ran(job: h.Job) -> h.Job:
    """The job ended with 0."""
    assert job.proc.returncode == 0, job.proc.stdout + job.proc.stderr
    return job


def assert_refused(job: h.Job, message: str, modules_loaded: bool = False) -> None:
    """The job ended with 1 and `message` on stderr, before any MPI started (and, unless `modules_loaded`, before any
    module loaded)."""
    assert job.proc.returncode == 1, job.proc.stdout + job.proc.stderr
    assert any(message in line for line in job.err), job.proc.stderr
    assert job.calls == []
    if not modules_loaded:
        assert job.modules == [] and "mpirun --version" not in job.events


def binary(name: str, work, test: str) -> str:
    sub = "pt2pt" if test in h.PAIR_TESTS + h.MULTI_TESTS else "collective"
    return str(h.osu_dir(name, work) / sub / f"osu_{test}")


def layout(call: h.Call) -> dict:
    """Where the launch puts its ranks: their count, per node, and (Open MPI) its binding and the CPU that taskset,
    before the binary, binds them to, or (Intel MPI) its pinning variables."""
    if call.flavour.startswith("openmpi"):
        program = call.options[-3:]
        return {"np": call.value("-np"), "map-by": call.value("--map-by"), "cpu-set": call.value("--cpu-set"),
                "bind-to": call.value("--bind-to"),
                "taskset": program[2] if program[:2] == ["taskset", "-c"] else None}
    pins = {v: call.env.get(v) for v in ("I_MPI_PIN_PROCESSOR_LIST", "I_MPI_PIN_DOMAIN", "I_MPI_PIN_ORDER")}
    return {"np": call.value("-np"), "ppn": call.value("-ppn"), **pins}


def pair_layout(name: str, nodes: int, core: str | None = "0") -> dict:
    if name == "openmpi":
        if nodes > 1:
            return {"np": "2", "map-by": "ppr:1:node", "cpu-set": None, "bind-to": "none", "taskset": core}
        return {"np": "2", "map-by": "ppr:2:node", "cpu-set": None, "bind-to": "core", "taskset": None}
    if nodes > 1:
        return {"np": "2", "ppn": "1", "I_MPI_PIN_PROCESSOR_LIST": core, "I_MPI_PIN_DOMAIN": None,
                "I_MPI_PIN_ORDER": None}
    return {"np": "2", "ppn": "2", "I_MPI_PIN_PROCESSOR_LIST": None, "I_MPI_PIN_DOMAIN": "core",
            "I_MPI_PIN_ORDER": "compact"}


def spread_layout(name: str, nodes: int, ppn: int) -> dict:
    if name == "openmpi":
        return {"np": str(nodes * ppn), "map-by": f"ppr:{ppn}:node", "cpu-set": None, "bind-to": "core",
                "taskset": None}
    return {"np": str(nodes * ppn), "ppn": str(ppn), "I_MPI_PIN_PROCESSOR_LIST": None, "I_MPI_PIN_DOMAIN": "core",
            "I_MPI_PIN_ORDER": "compact"}


def first_line(job: h.Job) -> str:
    return job.out[0]


def settings(job: h.Job, prefix: str) -> list[str]:
    """The words of the job's "<prefix>:" output line."""
    lines = [line for line in job.out if line.startswith(f"{prefix}: ")]
    assert len(lines) == 1, job.proc.stdout
    return lines[0][len(prefix) + 2:].split(" ")


# --- the tests, their order, their layouts -------------------------------------------------------------------------

@pytest.mark.parametrize("nodes", [1, 2, 4])
@pytest.mark.parametrize("name", MPIS)
def test_the_default_tests_run_in_order_at_their_layouts(name, nodes, tmp_path, host_tools):
    job = ran(h.run(name, tmp_path, host_tools, nodes=nodes))
    assert job.tests == [f"osu_{t}" for t in h.DEFAULT_TESTS]
    for call, t in zip(job.calls, h.DEFAULT_TESTS):
        assert call.binary == binary(name, tmp_path, t)
        assert call.tail == []
        expected = pair_layout(name, nodes) if t in h.PAIR_TESTS else spread_layout(name, nodes, CORES)
        assert layout(call) == expected, (t, call.args, call.env)
        assert call.flavour == h.DEFAULT_MPI[name]
    summary = job.out[job.out.index("==> Summary") + 1:]
    assert [line.split() for line in summary] == [[f"osu_{t}", "ok"] for t in h.DEFAULT_TESTS]


@pytest.mark.parametrize("name", MPIS)
def test_each_test_gets_a_layout_line(name, tmp_path, host_tools):
    job = ran(h.run(name, tmp_path, host_tools, nodes=2))
    assert [line for line in job.out if line.startswith("==> osu_")] == [
        "==> osu_latency: 2 ranks, 1 per node on the first 2 nodes, on core 0",
        "==> osu_bw: 2 ranks, 1 per node on the first 2 nodes, on core 0",
        "==> osu_bibw: 2 ranks, 1 per node on the first 2 nodes, on core 0",
        "==> osu_mbw_mr: 32 ranks, 16 per node on 2 node(s)",
        "==> osu_allreduce: 32 ranks, 16 per node on 2 node(s)"]


@pytest.mark.parametrize("name", MPIS)
def test_a_job_on_one_node_runs_the_pair_tests_on_that_node(name, tmp_path, host_tools):
    job = ran(h.run(name, tmp_path, host_tools, nodes=1, env={"OSU_TESTS": "latency"}))
    assert "==> osu_latency: 2 ranks on 1 node" in job.out
    assert not any(line.startswith("Pair tests' core:") for line in job.out)


@pytest.mark.parametrize("name", MPIS)
def test_osu_tests_picks_the_tests_and_their_order_with_or_without_the_prefix(name, tmp_path, host_tools):
    job = ran(h.run(name, tmp_path, host_tools, env={"OSU_TESTS": "osu_alltoall bibw  osu_latency\tmulti_lat"}))
    assert job.tests == ["osu_alltoall", "osu_bibw", "osu_latency", "osu_multi_lat"]
    assert layout(job.calls[0]) == spread_layout(name, 2, CORES)
    assert layout(job.calls[3]) == spread_layout(name, 2, CORES)


@pytest.mark.parametrize("name", MPIS)
def test_every_known_test_runs_from_its_directory(name, tmp_path, host_tools):
    job = ran(h.run(name, tmp_path, host_tools, env={"OSU_TESTS": " ".join(h.ALL_TESTS)}))
    assert job.tests == [f"osu_{t}" for t in h.ALL_TESTS]
    assert [c.binary for c in job.calls] == [binary(name, tmp_path, t) for t in h.ALL_TESTS]


@pytest.mark.parametrize("name", MPIS)
def test_osu_args_go_to_every_test(name, tmp_path, host_tools):
    job = ran(h.run(name, tmp_path, host_tools, env={"OSU_ARGS": " -m 1:4096\t-i 10 -x 2 "}))
    assert len(job.calls) == len(h.DEFAULT_TESTS)
    for call in job.calls:
        assert call.tail == ["-m", "1:4096", "-i", "10", "-x", "2"], call.args


@pytest.mark.parametrize("name", MPIS)
def test_osu_dir_names_the_install(name, tmp_path, host_tools):
    other = tmp_path / "elsewhere" / "mpi"
    job = ran(h.run(name, tmp_path, host_tools, install=other, env={"OSU_DIR": str(other)}))
    assert [c.binary for c in job.calls] == [
        str(other / ("pt2pt" if t in h.PAIR_TESTS + h.MULTI_TESTS else "collective") / f"osu_{t}")
        for t in h.DEFAULT_TESTS]


@pytest.mark.parametrize("name", MPIS)
def test_osu_ppn_sets_the_ranks_per_node_of_the_multi_pair_and_collective_tests(name, tmp_path, host_tools):
    job = ran(h.run(name, tmp_path, host_tools, nodes=4, env={"OSU_PPN": "6"}))
    for call, t in zip(job.calls, h.DEFAULT_TESTS):
        assert layout(call) == (pair_layout(name, 4) if t in h.PAIR_TESTS else spread_layout(name, 4, 6))


@pytest.mark.parametrize("ppn", ["1", str(CORES)])
@pytest.mark.parametrize("name", MPIS)
def test_osu_ppn_from_1_to_the_nodes_cores_is_accepted(name, ppn, tmp_path, host_tools):
    job = ran(h.run(name, tmp_path, host_tools, env={"OSU_PPN": ppn, "OSU_TESTS": "allreduce"}))
    assert layout(job.calls[0]) == spread_layout(name, 2, int(ppn))


@pytest.mark.parametrize("name", MPIS)
def test_the_cores_come_from_lscpu_in_the_c_locale(name, tmp_path, host_tools):
    job = ran(h.run(name, tmp_path, host_tools, sockets=3, cores_per_socket=5, env={"OSU_TESTS": "mbw_mr"}))
    assert job.lscpu == ["C|"]
    assert layout(job.calls[0]) == spread_layout(name, 2, 15)


@pytest.mark.parametrize("name", MPIS)
def test_with_no_lscpu_the_cores_come_from_slurm_cpus_on_node(name, tmp_path, host_tools):
    job = ran(h.run(name, tmp_path, host_tools, lscpu=False, env={"SLURM_CPUS_ON_NODE": "12", "OSU_TESTS": "mbw_mr"}))
    assert layout(job.calls[0]) == spread_layout(name, 2, 12)


@pytest.mark.parametrize("rc", [{"osu_bw": "3"}, {"osu_latency": "1", "osu_allreduce": "139"}])
@pytest.mark.parametrize("name", MPIS)
def test_every_test_runs_after_one_that_ends_with_another_status_and_the_job_ends_with_1(name, rc, tmp_path,
                                                                                         host_tools):
    job = h.run(name, tmp_path, host_tools, env={"STUB_RC": " ".join(f"{t}={s}" for t, s in rc.items())})
    assert job.proc.returncode == 1, job.proc.stdout + job.proc.stderr
    assert job.tests == [f"osu_{t}" for t in h.DEFAULT_TESTS]
    summary = [line.split(maxsplit=1) for line in job.out[job.out.index("==> Summary") + 1:]]
    assert summary == [[f"osu_{t}", f"exit status {rc[f'osu_{t}']}" if f"osu_{t}" in rc else "ok"]
                       for t in h.DEFAULT_TESTS]


# --- what stops a job before any MPI starts ------------------------------------------------------------------------

KNOWN = " ".join(h.ALL_TESTS)
REFUSED = [
    pytest.param({"OSU_TESTS": "latency osu_put_latency"}, f"ERROR: OSU_TESTS: no test put_latency: use any of {KNOWN}",
                 id="an unknown test"),
    pytest.param({"OSU_TESTS": " \t "}, f"ERROR: OSU_TESTS names no test: use any of {KNOWN}", id="only blanks"),
    *(pytest.param({"OSU_PPN": v}, f"ERROR: OSU_PPN={v}: use a whole number from 1 to {CORES}, this node's cores",
                   id=f"OSU_PPN={v!r}") for v in ("0", "17", "08", "x", "-1", "+2", " 4", "99999999")),
    pytest.param({"OSU_TESTS": "latency mbw_mr", "OSU_PPN": "3", "SLURM_JOB_NUM_NODES": "1",
                  "SLURM_JOB_NODELIST": "n1"},
                 "ERROR: osu_mbw_mr pairs its ranks: 1 x 3 ranks is 3, an odd number; set OSU_PPN to an even number",
                 id="mbw_mr at an odd rank count"),
    pytest.param({"OSU_TESTS": "multi_lat", "OSU_PPN": "5", "SLURM_JOB_NUM_NODES": "3", "SLURM_JOB_NODELIST": "n[1-3]"},
                 "ERROR: osu_multi_lat pairs its ranks: 3 x 5 ranks is 15, an odd number; set OSU_PPN to an even "
                 "number",
                 id="multi_lat at an odd rank count"),
    pytest.param({"OSU_TESTS": "allreduce", "OSU_PPN": "1", "SLURM_JOB_NUM_NODES": "1", "SLURM_JOB_NODELIST": "n1"},
                 "ERROR: osu_allreduce needs 2 ranks or more: 1 x 1 ranks is 1", id="allreduce with 1 rank"),
    pytest.param({"SLURM_JOB_ID": None}, "ERROR: SLURM_JOB_ID is not set: submit this script with sbatch",
                 id="no Slurm job"),
    *(pytest.param({"SLURM_JOB_NUM_NODES": v}, f"ERROR: SLURM_JOB_NUM_NODES={v}: submit this script with sbatch",
                   id=f"SLURM_JOB_NUM_NODES={v!r}") for v in ("", "0", "two")),
]


@pytest.mark.parametrize("env, message", REFUSED)
@pytest.mark.parametrize("name", MPIS)
def test_a_value_out_of_its_range_stops_the_job_before_any_module_or_mpi(name, env, message, tmp_path, host_tools):
    assert_refused(h.run(name, tmp_path, host_tools, env=env), message)


@pytest.mark.parametrize("name", MPIS)
def test_no_core_count_stops_the_job(name, tmp_path, host_tools):
    job = h.run(name, tmp_path, host_tools, lscpu=False, env={"SLURM_CPUS_ON_NODE": None})
    assert_refused(job, "ERROR: this node's cores are unknown: lscpu shows none and SLURM_CPUS_ON_NODE is not set")


@pytest.mark.parametrize("name", MPIS)
def test_a_missing_binary_stops_the_job_and_names_the_build_script(name, tmp_path, host_tools):
    job = h.run(name, tmp_path, host_tools, missing=("bibw",))
    path = binary(name, tmp_path, "bibw")
    assert_refused(job, f"ERROR: {path} is missing: build OMB with bash {h.BUILD_SCRIPTS[name]} (README.md, \"Build\"),"
                        " or set OSU_DIR to the libexec/osu-micro-benchmarks/mpi directory of an OMB install")


@pytest.mark.parametrize("name", MPIS)
def test_a_test_not_selected_needs_no_binary(name, tmp_path, host_tools):
    ran(h.run(name, tmp_path, host_tools, missing=("bibw",), env={"OSU_TESTS": "latency bw"}))


# --- the MPI and its modules ---------------------------------------------------------------------------------------

def test_open_mpi_loads_openmpi_then_libfabric_aws_once_each(tmp_path, host_tools):
    job = ran(h.run("openmpi", tmp_path, host_tools))
    assert job.modules == [["load", "openmpi", "unset"], ["load", "libfabric-aws", "unset"]]


@pytest.mark.parametrize("given, seen", [(None, "0"), ("1", "1")], ids=["unset", "given 1"])
def test_intel_mpi_loads_once_with_the_internal_libfabric_off_then_libfabric_aws(given, seen, tmp_path, host_tools):
    job = ran(h.run("intelmpi", tmp_path, host_tools, env={"I_MPI_OFI_LIBRARY_INTERNAL": given}))
    assert job.modules == [["load", "intelmpi", seen], ["load", "libfabric-aws", seen]]
    assert {c.env["I_MPI_OFI_LIBRARY_INTERNAL"] for c in job.calls} == {seen}


@pytest.mark.parametrize("name", MPIS)
def test_a_module_that_gives_another_mpi_stops_the_job_before_any_test(name, tmp_path, host_tools):
    job = h.run(name, tmp_path, host_tools, env={"STUB_WRONG_MPI": "1"})
    named = "Open MPI 4" if name == "openmpi" else "Intel MPI"
    assert_refused(job, f"ERROR: mpirun is not {named} (mpirun --version: ", modules_loaded=True)


@pytest.mark.parametrize("name", MPIS)
def test_with_no_module_command_the_mpi_on_the_path_is_used_with_a_note(name, tmp_path, host_tools):
    job = ran(h.run(name, tmp_path, host_tools, modules=False, path_mpi=h.DEFAULT_MPI[name]))
    assert job.err == ["NOTE: no module command: using the MPI on the PATH"]
    assert {c.flavour for c in job.calls} == {h.DEFAULT_MPI[name]}


@pytest.mark.parametrize("path_mpi", [None, "other"])
@pytest.mark.parametrize("name", MPIS)
def test_with_no_module_command_another_mpi_or_none_stops_the_job(name, path_mpi, tmp_path, host_tools):
    other = "intelmpi" if name == "openmpi" else "openmpi4"
    job = h.run(name, tmp_path, host_tools, modules=False, path_mpi=other if path_mpi else None)
    named = "Open MPI 4" if name == "openmpi" else "Intel MPI"
    message = f"ERROR: mpirun is not {named} (mpirun --version: " + ("no output)" if path_mpi is None else "")
    assert job.proc.returncode == 1 and job.calls == [], job.proc.stdout + job.proc.stderr
    assert any(line.startswith(message) for line in job.err), job.proc.stderr


def test_open_mpi_runs_the_cm_pml_over_the_ofi_mtl_and_passes_the_fi_settings(tmp_path, host_tools):
    job = ran(h.run("openmpi", tmp_path, host_tools))
    for call in job.calls:
        assert {"pml": "cm", "mtl": "ofi"}.items() <= call.mca().items(), call.args
        assert call.exported() == ["FI_PROVIDER", "FI_EFA_USE_DEVICE_RDMA"]
        assert call.env["FI_PROVIDER"] == "efa" and call.env["FI_EFA_USE_DEVICE_RDMA"] == "1"
    assert settings(job, "MPI settings")[:4] == ["pml=cm", "mtl=ofi", "FI_PROVIDER=efa", "FI_EFA_USE_DEVICE_RDMA=1"]


def test_open_mpi_keeps_the_pml_the_mtl_and_the_provider_the_job_gives(tmp_path, host_tools):
    job = ran(h.run("openmpi", tmp_path, host_tools,
                    env={"OMPI_MCA_pml": "ob1", "OMPI_MCA_mtl": "psm2", "FI_PROVIDER": "tcp"}))
    for call in job.calls:
        assert "pml" not in call.mca() and "mtl" not in call.mca()
        assert call.env["OMPI_MCA_pml"] == "ob1" and call.env["FI_PROVIDER"] == "tcp"
    assert settings(job, "MPI settings")[:3] == ["pml=ob1", "mtl=psm2", "FI_PROVIDER=tcp"]


def test_open_mpi_options_are_only_these(tmp_path, host_tools):
    """--mca options aside, which the provider check may add. A pair test on two nodes runs under taskset, with
    --bind-to none and no --cpu-set, which Open MPI refuses beside --map-by."""
    job = ran(h.run("openmpi", tmp_path, host_tools, nodes=2))
    for call, t in zip(job.calls, h.DEFAULT_TESTS):
        if t in h.PAIR_TESTS:
            bind, np, per, program = "none", "2", "1", ["taskset", "-c", "0"]
        else:
            bind, np, per, program = "core", "32", "16", []
        assert call.without_mca() == ["--bind-to", bind, "-np", np, "--map-by", f"ppr:{per}:node", "-x",
                                      "FI_PROVIDER", "-x", "FI_EFA_USE_DEVICE_RDMA", *program], call.args


@pytest.mark.parametrize("flavour, status, message", [
    ("openmpi4", 1, "Conflicting directives for mapping policy are causing the policy"),
    ("openmpi5", 213, "When resolving deprecated command line options, the result generated")])
def test_the_stub_mpirun_refuses_cpu_set_beside_map_by_as_open_mpi_does(flavour, status, message, tmp_path):
    """Open MPI 4.1.7 and 5.0.9 refuse such a launch before they start anything, so a launcher that passes both
    measures nothing: the stub does the same, and a launch with --map-by alone runs."""
    stub, state = tmp_path / "mpirun", tmp_path / "state"
    stub.write_text(h.mpi_stub(flavour))
    stub.chmod(0o755)
    state.mkdir()
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "STATE": str(state), "LC_ALL": "POSIX"}
    pinned = ["--bind-to", "core", "-np", "2", "--map-by", "ppr:1:node", "--cpu-set", "0", "/x/osu_latency"]
    proc = subprocess.run([str(stub), *pinned], env=env, capture_output=True, text=True, timeout=60)
    assert proc.returncode == status and message in proc.stderr, proc.stdout + proc.stderr
    assert "# OSU MPI stub" not in proc.stdout
    plain = ["--bind-to", "none", "-np", "2", "--map-by", "ppr:1:node", "taskset", "-c", "0", "/x/osu_latency"]
    proc = subprocess.run([str(stub), *plain], env=env, capture_output=True, text=True, timeout=60)
    assert proc.returncode == 0 and "# OSU MPI stub: osu_latency" in proc.stdout, proc.stdout + proc.stderr


def test_intel_mpi_options_are_only_these(tmp_path, host_tools):
    job = ran(h.run("intelmpi", tmp_path, host_tools, nodes=2))
    for call, t in zip(job.calls, h.DEFAULT_TESTS):
        np, per = ("2", "1") if t in h.PAIR_TESTS else ("32", "16")
        assert call.options == ["-np", np, "-ppn", per], call.args


def test_intel_mpi_sets_its_fabric_provider_multi_rail_and_debug(tmp_path, host_tools):
    job = ran(h.run("intelmpi", tmp_path, host_tools))
    for call in job.calls:
        assert {k: call.env.get(k) for k in ("I_MPI_FABRICS", "I_MPI_OFI_PROVIDER", "I_MPI_MULTIRAIL")} == {
            "I_MPI_FABRICS": "shm:ofi", "I_MPI_OFI_PROVIDER": "efa", "I_MPI_MULTIRAIL": "1"}
        assert "FI_PROVIDER" not in call.env
    assert job.calls[0].env["I_MPI_DEBUG"] == "5"


def test_intel_mpi_keeps_the_values_the_job_gives(tmp_path, host_tools):
    given = {"I_MPI_FABRICS": "ofi", "I_MPI_OFI_PROVIDER": "tcp", "I_MPI_MULTIRAIL": "0", "I_MPI_DEBUG": "2"}
    job = ran(h.run("intelmpi", tmp_path, host_tools, env=given))
    for call in job.calls:
        assert {k: call.env.get(k) for k in given} == given
    words = settings(job, "MPI settings")
    for k, v in given.items():
        assert f"{k}={v}" in words


BOOTSTRAP = {
    "unset, no Slurm argument": ({}, "slurm", None),
    "unset, Slurm's argument": ({"OMPI_MCA_plm_slurm_args": "--external-launcher"}, "slurm", "--external-launcher"),
    "slurm, as Slurm sets it": ({"I_MPI_HYDRA_BOOTSTRAP": "slurm", "I_MPI_HYDRA_BOOTSTRAP_EXEC_EXTRA_ARGS":
                                 "--external-launcher", "OMPI_MCA_plm_slurm_args": "--external-launcher"},
                                "slurm", "--external-launcher"),
    "ssh, Slurm's argument": ({"I_MPI_HYDRA_BOOTSTRAP": "ssh", "OMPI_MCA_plm_slurm_args": "--external-launcher"},
                              "slurm", "--external-launcher"),
    "ssh, no Slurm argument": ({"I_MPI_HYDRA_BOOTSTRAP": "ssh"}, "slurm", None),
    "ssh, an extra argument given": ({"I_MPI_HYDRA_BOOTSTRAP": "ssh", "I_MPI_HYDRA_BOOTSTRAP_EXEC_EXTRA_ARGS":
                                      "--exact", "OMPI_MCA_plm_slurm_args": "--external-launcher"}, "slurm", "--exact"),
}


@pytest.mark.parametrize("env, bootstrap, extra", list(BOOTSTRAP.values()), ids=list(BOOTSTRAP))
def test_intel_mpi_starts_its_processes_with_slurm(env, bootstrap, extra, tmp_path, host_tools):
    job = ran(h.run("intelmpi", tmp_path, host_tools, env=env))
    for call in job.calls:
        assert call.env.get("I_MPI_HYDRA_BOOTSTRAP") == bootstrap
        assert call.env.get("I_MPI_HYDRA_BOOTSTRAP_EXEC_EXTRA_ARGS") == extra
    words = settings(job, "MPI settings")
    assert "I_MPI_HYDRA_BOOTSTRAP=slurm" in words
    assert (f"I_MPI_HYDRA_BOOTSTRAP_EXEC_EXTRA_ARGS={extra}" in words) == (extra is not None)


@pytest.mark.parametrize("given", [{"I_MPI_PIN_DOMAIN": "numa"}, {"I_MPI_PIN_ORDER": "scatter"},
                                   {"I_MPI_PIN_PROCESSOR_LIST": "0-3"}], ids=lambda g: next(iter(g)))
def test_intel_mpi_sets_no_pinning_when_the_job_sets_any(given, tmp_path, host_tools):
    job = ran(h.run("intelmpi", tmp_path, host_tools, env=given))
    for call in job.calls:
        assert {v: call.env.get(v) for v in ("I_MPI_PIN_PROCESSOR_LIST", "I_MPI_PIN_DOMAIN", "I_MPI_PIN_ORDER")} == {
            **dict.fromkeys(("I_MPI_PIN_PROCESSOR_LIST", "I_MPI_PIN_DOMAIN", "I_MPI_PIN_ORDER")), **given}
    assert "==> osu_latency: 2 ranks, 1 per node on the first 2 nodes" in job.out
    assert not any(line.startswith("Pair tests' core:") for line in job.out)


# --- EFA: device RDMA and the pair tests' core ---------------------------------------------------------------------

RDMA = {
    "two EFA devices 0xefa1": (h.DEVICES, "1", "FI_EFA_USE_DEVICE_RDMA=1: every EFA device of this node supports "
                                               "RDMA read"),
    "one 0xefa3": ((h.Device("rdmap0s9", device="0xefa3"),), "1", None),
    "one 0xefa0": ((h.Device("rdmap0s9", device="0xefa0"),), None,
                   "FI_EFA_USE_DEVICE_RDMA not set: rdmap0s9 may have no RDMA read (PCI device 0xefa0)"),
    "0xefa1 and 0xefa0": ((h.Device("rdmap0s9"), h.Device("rdmap1s9", device="0xefa0")), None, None),
    "no device": ((), None, "FI_EFA_USE_DEVICE_RDMA not set: this node has no EFA device"),
    "another vendor": ((h.Device("mlx5_0", vendor="0x15b3", device="0x101b"),), None,
                       "FI_EFA_USE_DEVICE_RDMA not set: mlx5_0 is not an EFA device (PCI vendor 0x15b3)"),
    "unreadable ids": ((h.Device("rdmap0s9", vendor=None, device=None),), None,
                       "FI_EFA_USE_DEVICE_RDMA not set: rdmap0s9 is not an EFA device (PCI vendor unreadable)"),
    "unreadable device id": ((h.Device("rdmap0s9", device=None),), None,
                             "FI_EFA_USE_DEVICE_RDMA not set: rdmap0s9 may have no RDMA read (PCI device unreadable)"),
}


@pytest.mark.parametrize("devices, value, line", list(RDMA.values()), ids=list(RDMA))
@pytest.mark.parametrize("name", MPIS)
def test_device_rdma_is_set_only_where_every_efa_device_supports_rdma_read(name, devices, value, line, tmp_path,
                                                                           host_tools):
    job = ran(h.run(name, tmp_path, host_tools, devices=devices))
    for call in job.calls:
        assert call.env.get("FI_EFA_USE_DEVICE_RDMA") == value
        if name == "openmpi":
            assert ("FI_EFA_USE_DEVICE_RDMA" in call.exported()) == (value is not None)
    if line is not None:
        assert line in job.out, job.proc.stdout


@pytest.mark.parametrize("given", ["0", "1"])
@pytest.mark.parametrize("devices", [h.DEVICES, (h.Device("rdmap0s9", device="0xefa0"),)], ids=["efa1", "efa0"])
@pytest.mark.parametrize("name", MPIS)
def test_device_rdma_keeps_the_value_the_job_gives(name, devices, given, tmp_path, host_tools):
    job = ran(h.run(name, tmp_path, host_tools, devices=devices, env={"FI_EFA_USE_DEVICE_RDMA": given}))
    assert {c.env.get("FI_EFA_USE_DEVICE_RDMA") for c in job.calls} == {given}
    assert f"FI_EFA_USE_DEVICE_RDMA={given}, from the job's environment" in job.out


CORE = {
    "the first device on NUMA node 1": ((h.Device("rdmap0s9", numa="1"), h.Device("rdmap1s9", numa="0")),
                                        {0: "0-7", 1: "8-15"}, "8",
                                        "the first CPU of NUMA node 1, that of rdmap0s9, the first EFA device"),
    "a cpulist of single CPUs": ((h.Device("rdmap0s9", numa="1"),), {0: "0-47", 1: "48,49,50"}, "48", None),
    "a cpulist of ranges": ((h.Device("rdmap0s9", numa="1"),), {0: "0-23,96-119", 1: "24-47,120-143"}, "24", None),
    "devices in name order": ((h.Device("rdmap9s1", numa="0"), h.Device("rdmap10s1", numa="1")),
                              {0: "0-7", 1: "8-15"}, "8", None),
    "another vendor's device first": ((h.Device("a_mlx5", vendor="0x15b3", numa="0"),
                                       h.Device("rdmap0s9", numa="1")), {0: "0-7", 1: "8-15"}, "8", None),
    "no NUMA node": ((h.Device("rdmap0s9", numa=None),), {0: "0-7"}, "0",
                     "the NUMA node of rdmap0s9, the first EFA device, is unknown"),
    "NUMA node -1": ((h.Device("rdmap0s9", numa="-1"),), {0: "0-7"}, "0", None),
    "no cpulist": ((h.Device("rdmap0s9", numa="1"),), {0: "0-7", 1: None}, "0", None),
    "an empty cpulist": ((h.Device("rdmap0s9", numa="1"),), {0: "0-7", 1: ""}, "0", None),
    "no device": ((), {0: "0-7"}, "0", "no EFA device's NUMA node is known"),
}


@pytest.mark.parametrize("devices, cpulists, core, why", list(CORE.values()), ids=list(CORE))
@pytest.mark.parametrize("name", MPIS)
def test_the_pair_tests_run_on_the_first_cpu_of_the_first_efa_devices_numa_node(name, devices, cpulists, core, why,
                                                                                tmp_path, host_tools):
    job = ran(h.run(name, tmp_path, host_tools, devices=devices, cpulists=cpulists))
    for call in job.calls:
        if call.test in {f"osu_{t}" for t in h.PAIR_TESTS}:
            assert layout(call) == pair_layout(name, 2, core)
        else:
            assert layout(call) == spread_layout(name, 2, CORES)
    if why is not None:
        assert f"Pair tests' core: {core}, {why}" in job.out, job.proc.stdout


# --- the output ----------------------------------------------------------------------------------------------------

@pytest.mark.parametrize("nodes", [1, 3])
@pytest.mark.parametrize("name", MPIS)
def test_the_first_line_names_the_mpi_the_nodes_and_their_type_then_the_node_list(name, nodes, tmp_path, host_tools):
    job = ran(h.run(name, tmp_path, host_tools, nodes=nodes))
    mpi = h.MPI_NAMES[h.DEFAULT_MPI[name]]
    assert first_line(job) == f"==> OSU Micro-Benchmarks | {mpi} | {nodes} x {h.INSTANCE_TYPE} | job {h.JOB_ID}"
    assert job.out[1] == "Nodes: " + " ".join(f"n{i}" for i in range(1, nodes + 1))


@pytest.mark.parametrize("name", MPIS)
def test_the_settings_line_names_each_osu_setting(name, tmp_path, host_tools):
    job = ran(h.run(name, tmp_path, host_tools, env={"OSU_TESTS": "osu_bw allreduce", "OSU_PPN": "4",
                                                     "OSU_ARGS": "-m 8:8"}))
    line = next(line for line in job.out if line.startswith("OSU settings: "))
    assert line == (f"OSU settings: OSU_DIR={h.osu_dir(name, tmp_path)} OSU_TESTS=\"bw allreduce\" OSU_PPN=4 "
                    "OSU_ARGS=\"-m 8:8\"")


@pytest.mark.parametrize("name", MPIS)
def test_the_build_record_is_named_when_there_is_one(name, tmp_path, host_tools):
    record = "omb_version=9.9synthetic\nomb_sha256=0123\nmpi=mpirun (Open MPI) 4.1.99\nhost=stub\n"
    job = ran(h.run(name, tmp_path, host_tools, record=record))
    path = h.osu_dir(name, tmp_path).parents[2] / "osu-build.txt"
    assert f"Build: OMB 9.9synthetic, mpirun (Open MPI) 4.1.99 ({path})" in job.out
    job2 = ran(h.run(name, tmp_path / "again", host_tools))
    assert not any(line.startswith("Build: ") for line in job2.out)


def test_the_directives_are_mains_with_a_time_limit():
    for name, launcher in h.LAUNCHERS.items():
        directives = [line for line in launcher.read_text().splitlines() if line.startswith("#SBATCH")]
        output = "osu-benchmarks-%j.out" if name == "openmpi" else "osu-benchmarks-intelmpi-%j.out"
        assert directives == [f"#SBATCH --job-name=osu-benchmarks-{name}", "#SBATCH --constraint=hpc8a.96xlarge",
                              "#SBATCH --partition=hpc8a", "#SBATCH --nodes=2", "#SBATCH --exclusive",
                              f"#SBATCH --output={output}", "#SBATCH --time=00:30:00"]


# --- the instance metadata -----------------------------------------------------------------------------------------

def type_requests(job: h.Job) -> list[str]:
    """The job's own curl calls (not those of a step on the nodes)."""
    return [args for host, args in job.curl if host == ""]


@pytest.mark.parametrize("name", MPIS)
def test_the_instance_type_requests_fail_on_an_http_error_and_give_up_within_5_seconds(name, tmp_path, host_tools):
    job = ran(h.run(name, tmp_path, host_tools))
    own = type_requests(job)
    assert len(own) == 2 and "latest/api/token" in own[0] and "meta-data/instance-type" in own[1], own
    for _, request in job.curl:
        words = request.split()
        assert any(w == "--fail" or re.fullmatch(r"-[a-zA-Z]*f[a-zA-Z]*", w) for w in words), request
        assert re.search(r"(^| )--connect-timeout [1-5]( |$)", request), request
        assert re.search(r"(^| )--max-time [1-5]( |$)", request), request


NOT_TYPE_NAMES = [
    pytest.param("<html><body>Request denied by proxy.example.com</body></html>", id="a proxy's page"),
    pytest.param("Request denied by proxy.example.com", id="other text, then a host name"),
    pytest.param("HPC9Z.96XLARGE", id="capitals"),
    pytest.param("hpc9z.96xlarge: not found", id="a type name, then other text"),
    pytest.param("hpc9z.96xlarge\n<p>Request checked by proxy.example.com", id="a type name, then a second line"),
    pytest.param("", id="empty"),
]


@pytest.mark.parametrize("imds", ["no-answer", "http-error", "cut-off"])
@pytest.mark.parametrize("name", MPIS)
def test_no_answer_an_http_error_or_a_cut_off_answer_gives_unknown(name, imds, tmp_path, host_tools):
    job = ran(h.run(name, tmp_path, host_tools, env={"STUB_IMDS": imds}))
    assert first_line(job).endswith(f" | 2 x unknown | job {h.JOB_ID}"), first_line(job)
    assert len(job.calls) == len(h.DEFAULT_TESTS)


@pytest.mark.parametrize("answer", NOT_TYPE_NAMES)
@pytest.mark.parametrize("name", MPIS)
def test_an_answer_that_is_not_an_instance_type_name_gives_unknown(name, answer, tmp_path, host_tools):
    job = ran(h.run(name, tmp_path, host_tools, env={"STUB_TYPE": answer}))
    assert first_line(job).endswith(f" | 2 x unknown | job {h.JOB_ID}"), first_line(job)


@pytest.mark.parametrize("name", MPIS)
def test_a_type_name_with_an_i_reads_in_a_turkish_locale(name, tmp_path, host_tools):
    """In a Turkish locale [a-z] leaves out i, so the type name is tested in the C locale."""
    if "tr_TR.utf8" not in subprocess.run(["locale", "-a"], capture_output=True, text=True).stdout.split():
        pytest.skip("the tr_TR.UTF-8 locale is not installed")
    job = ran(h.run(name, tmp_path, host_tools, env={"STUB_TYPE": "c9i.48xlarge", "LC_ALL": "tr_TR.UTF-8"}))
    assert " | 2 x c9i.48xlarge | " in first_line(job)


# --- the two launchers share their common blocks -------------------------------------------------------------------

def test_the_blocks_both_launchers_share_are_the_same():
    blocks = {name: h.shared_blocks(launcher.read_text()) for name, launcher in h.LAUNCHERS.items()}
    assert set(blocks["openmpi"]) == set(blocks["intelmpi"])
    assert {"helpers", "job and settings", "binaries", "instance type", "EFA devices", "header",
            "build record and settings", "tests"} <= set(blocks["openmpi"])
    for block in blocks["openmpi"]:
        assert blocks["openmpi"][block] == blocks["intelmpi"][block], block
