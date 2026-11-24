"""How Utils/OSU-Benchmarks builds and runs OMB with the EFA installer's Open MPI 5 (OMPI_MODULE=openmpi5).

These tests pin, for build_osu_benchmarks_openmpi.sh and osu_benchmarks_openmpi.sbatch:
- OMPI_MODULE: openmpi (the default, Open MPI 4) or openmpi5 (Open MPI 5); any other value stops the script before
  any module loads, any download or any MPI starts;
- with openmpi5: module openmpi5 loads (then libfabric-aws, in the job script), the build installs to
  /fsx/OSU-Benchmark-OpenMPI5 by default and the job runs OMB from there, mpirun --version must name Open MPI 5 (else
  the script stops), and the job runs the same tests at the same layouts with the same options as with Open MPI 4,
  the pair tests under taskset with no --cpu-set, which Open MPI 5 refuses beside --map-by (as the stub mpirun
  does);
- the missing-binary message names the build command for OMPI_MODULE.

They run copies of the scripts with the stubs of tests/test_osu_build.py and tests/osu_harness.py. Every value is
synthetic.

Run with:
    python -m pip install -r tests/requirements.txt
    python -m pytest tests/test_osu_openmpi5.py -q
"""
from __future__ import annotations

import pytest

import osu_harness as h
import test_osu_build as b

pytestmark = pytest.mark.skipif(h.BASH is None, reason="needs bash")
OMPI5_DIR = "OSU-Benchmark-OpenMPI5/install/libexec/osu-micro-benchmarks/mpi"


@pytest.fixture(scope="session")
def build_tools(tmp_path_factory):
    return b.host_tools_dir(tmp_path_factory)


@pytest.fixture(scope="session")
def host_tools(tmp_path_factory):
    return h.host_tools_dir(tmp_path_factory)


# --- the build ---------------------------------------------------------------------------------------------------

def test_openmpi5_builds_with_open_mpi_5_into_its_own_install(tmp_path, build_tools):
    build = b.run_build(b.SCRIPTS["openmpi"], tmp_path, build_tools,
                        env={**b.sha_env(tmp_path), "OMPI_MODULE": "openmpi5"})
    assert build.proc.returncode == 0, build.proc.stdout + build.proc.stderr
    assert build.modules == [["load", "openmpi5", "unset"]]
    install = tmp_path / "fsx" / "OSU-Benchmark-OpenMPI5"
    assert build.configure == ["CC=mpicc", "CXX=mpicxx", f"--prefix={install}/install"]
    record = dict(line.split("=", 1) for line in (install / "install" / "osu-build.txt").read_text().splitlines())
    assert record["mpi"] == b.MPI_VERSIONS["openmpi5"][0]
    assert not (tmp_path / "fsx" / "OSU-Benchmark-OpenMPI").exists()
    assert "    with OMPI_MODULE=openmpi5 in the job's environment" in build.out


def test_the_default_build_does_not_mention_ompi_module(tmp_path, build_tools):
    build = b.run_build(b.SCRIPTS["openmpi"], tmp_path, build_tools, env=b.sha_env(tmp_path))
    assert build.proc.returncode == 0, build.proc.stderr
    assert not any("OMPI_MODULE" in line for line in build.out)


def test_openmpi5_with_a_module_that_gives_open_mpi_4_stops_the_build(tmp_path, build_tools):
    build = b.run_build(b.SCRIPTS["openmpi"], tmp_path, build_tools,
                        env={**b.sha_env(tmp_path), "OMPI_MODULE": "openmpi5", "STUB_WRONG_MPI": "1"})
    assert build.proc.returncode == 1, build.proc.stdout + build.proc.stderr
    assert any(line.startswith("ERROR: mpirun is not Open MPI 5 (mpirun --version: mpirun (Open MPI) 4.1.99): load "
                               "the openmpi5 module") for line in build.err), build.proc.stderr
    assert build.curl == []


@pytest.mark.parametrize("path_mpi, ok", [("openmpi5", True), ("openmpi4", False)])
def test_openmpi5_with_no_module_command_needs_open_mpi_5_on_the_path(path_mpi, ok, tmp_path, build_tools):
    build = b.run_build(b.SCRIPTS["openmpi"], tmp_path, build_tools, modules=False, path_mpi=path_mpi,
                        env={**b.sha_env(tmp_path), "OMPI_MODULE": "openmpi5"})
    assert (build.proc.returncode == 0) == ok, build.proc.stdout + build.proc.stderr
    assert (build.curl != []) == ok


@pytest.mark.parametrize("value", ["openmpi9", "intelmpi", "openmpi 5", "OPENMPI5"])
def test_another_ompi_module_stops_the_build_before_anything_runs(value, tmp_path, build_tools):
    build = b.run_build(b.SCRIPTS["openmpi"], tmp_path, build_tools, env={"OMPI_MODULE": value})
    assert build.proc.returncode == 1, build.proc.stdout + build.proc.stderr
    assert build.err == [f"ERROR: OMPI_MODULE={value}: use openmpi (Open MPI 4) or openmpi5 (Open MPI 5)"]
    assert build.modules == [] and build.curl == [] and build.left == []


# --- the job -----------------------------------------------------------------------------------------------------

def openmpi5_job(work, tools, **kwargs):
    env = {"OMPI_MODULE": "openmpi5", **kwargs.pop("env", {})}
    return h.run("openmpi", work, tools, install=work / "fsx" / OMPI5_DIR, env=env, **kwargs)


@pytest.mark.parametrize("nodes", [1, 2])
def test_openmpi5_runs_the_same_tests_at_the_same_layouts_with_the_same_options(nodes, tmp_path, host_tools):
    five = openmpi5_job(tmp_path / "five", host_tools, nodes=nodes)
    four = h.run("openmpi", tmp_path / "four", host_tools, nodes=nodes)
    assert five.proc.returncode == 0 and four.proc.returncode == 0, five.proc.stdout + five.proc.stderr
    assert five.modules == [["load", "openmpi5", "unset"], ["load", "libfabric-aws", "unset"]]
    assert {c.flavour for c in five.calls} == {"openmpi5"}
    assert [c.options for c in five.calls] == [c.options for c in four.calls]
    assert [c.binary for c in five.calls] == [
        str(tmp_path / "five" / "fsx" / OMPI5_DIR / ("pt2pt" if c.test != "osu_allreduce" else "collective") / c.test)
        for c in five.calls]
    mpi = h.MPI_NAMES["openmpi5"]
    assert five.out[0] == f"==> OSU Micro-Benchmarks | {mpi} | {nodes} x {h.INSTANCE_TYPE} | job {h.JOB_ID}"


def test_openmpi5_runs_the_pair_tests_under_taskset_with_no_cpu_set(tmp_path, host_tools):
    """Open MPI 5's PRRTE turns --cpu-set into a second --map-by directive and refuses the launch, as the stub
    mpirun does: each rank of a pair test is bound by taskset instead, and every test ends with 0."""
    job = openmpi5_job(tmp_path, host_tools, nodes=2)
    assert job.proc.returncode == 0, job.proc.stdout + job.proc.stderr
    pairs = [c for c in job.calls if c.test in {f"osu_{t}" for t in h.PAIR_TESTS}]
    assert [c.test for c in pairs] == ["osu_latency", "osu_bw", "osu_bibw"]
    for call in pairs:
        assert "--cpu-set" not in call.args, call.args
        assert call.value("--bind-to") == "none" and call.value("--map-by") == "ppr:1:node", call.args
        assert call.options[-3:] == ["taskset", "-c", "0"], call.args
    summary = job.out[job.out.index("==> Summary") + 1:]
    assert [line.split() for line in summary] == [[f"osu_{t}", "ok"] for t in h.DEFAULT_TESTS]


def test_openmpi5_with_a_module_that_gives_open_mpi_4_stops_the_job(tmp_path, host_tools):
    job = openmpi5_job(tmp_path, host_tools, env={"STUB_WRONG_MPI": "1"})
    assert job.proc.returncode == 1 and job.calls == [], job.proc.stdout + job.proc.stderr
    assert any(line.startswith("ERROR: mpirun is not Open MPI 5 (mpirun --version: mpirun (Open MPI) 4.1.99)")
               for line in job.err), job.proc.stderr


@pytest.mark.parametrize("value", ["openmpi9", "intelmpi", "openmpi 5"])
def test_another_ompi_module_stops_the_job_before_any_module_or_mpi(value, tmp_path, host_tools):
    job = h.run("openmpi", tmp_path, host_tools, env={"OMPI_MODULE": value})
    assert job.proc.returncode == 1, job.proc.stdout + job.proc.stderr
    assert f"ERROR: OMPI_MODULE={value}: use openmpi (Open MPI 4) or openmpi5 (Open MPI 5)" in job.err
    assert job.calls == [] and job.modules == [] and "mpirun --version" not in job.events


def test_a_missing_open_mpi_5_binary_names_the_build_command_for_it(tmp_path, host_tools):
    job = openmpi5_job(tmp_path, host_tools, missing=("allreduce",))
    path = tmp_path / "fsx" / OMPI5_DIR / "collective" / "osu_allreduce"
    assert job.proc.returncode == 1 and job.calls == [], job.proc.stdout + job.proc.stderr
    assert (f"ERROR: {path} is missing: build OMB with OMPI_MODULE=openmpi5 bash build_osu_benchmarks_openmpi.sh "
            "(README.md, \"Build\"), or set OSU_DIR to the libexec/osu-micro-benchmarks/mpi directory of an OMB "
            "install") in job.err, job.proc.stderr
