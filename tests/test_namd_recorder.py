"""How apps/NAMD/dynamodb/record-benchmark.sh records one NAMD run.

These tests pin:
- what it reads from namd.out in --run-dir (or else from another *.out or *.log file with a "Benchmark time:" line):
  the last Benchmark time line's days/ns, and ns/day = 1 / (days/ns) to six significant digits; NAMD's WallClock:
  time as time_to_solution_seconds; the "Info: <N> ATOMS" line as atoms_million, and not the lines that count the
  atoms of a patch or a group; NAMD's version and platform; the number of steps (the sum of the "TCL: Running for
  <N> steps" lines when the config runs NAMD through run or minimize commands, else "Info: NUMBER OF STEPS") and the
  time step;
- that a value given by flag or in the environment wins over namd.out's, and that --days-per-ns gives ns/day;
- the cores, nodes and cores per node, given or from Slurm, and the libraries list, with the MPI, libfabric and EFA
  versions from mpirun and fi_info;
- the table, External_<Source>_Namd, with the source's letters and digits only, and --table and --region;
- the --metric and --char values, added after the record's own attributes: one that names an attribute the record
  holds is left out with a WARN, so each attribute is written once and the record's own value wins; a metric that is
  not a number, and a pair with no "=", are left out with a WARN;
- the NOTEs for a missing case, time, rate or size, and the required fields;
- --help, which prints the whole header comment and then the options, and an unknown option.

The instance metadata, --put, --no-put and the NOTEs on how to share a run are pinned for every recorder, this one
included, in tests/test_recorders_imds.py and tests/test_recorders_share_line.py. These tests run the recorder in
--dry-run, which prints the record and touches no file and no AWS, from a temporary directory, with a PATH that holds
no curl, aws, mpirun, fi_info or Slurm command (a test that adds stubs of mpirun and fi_info says so). Every value is
synthetic.

Run with:
    python -m pip install -r tests/requirements.txt
    python -m pytest tests/test_namd_recorder.py -q
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
RECORDER = REPO / "apps" / "NAMD" / "dynamodb" / "record-benchmark.sh"
BASH = shutil.which("bash")
pytestmark = pytest.mark.skipif(BASH is None, reason="needs bash")

# Host commands the recorder must not find: it reads the instance metadata with curl when no instance type is given,
# and the MPI, libfabric and EFA versions from mpirun and fi_info when they are on the PATH.
HIDDEN = frozenset({"aws", "aws_completer", "curl", "mpirun", "mpiexec", "fi_info", "srun", "sbatch", "scontrol",
                    "squeue", "sinfo"})

# A run described in full but for its case and results, so that the recorder needs no Slurm, metadata or MPI.
RUN_ARGS = ("--instance-type", "hpc7a.96xlarge", "--os", "Synthetic OS 1", "--num-cores", "96", "--num-nodes", "1",
            "--mpi", "openmpi", "--source", "TestSuite")

# A namd.out with the lines the recorder reads, and lines that look like them: patch and group atom counts, an
# "Initial time:" line, and a first Benchmark time line before the last.
NAMD_OUT = [
    "Charm++> Running in SMP mode: 1 processes, 95 worker threads (PEs) + 1 comm threads per process",
    "Info: NAMD 9.8.7 for Linux-AVX512-MPI-smp",
    "Info: TIMESTEP               2",
    "Info: NUMBER OF STEPS        3000",
    "Info: EMPTY PATCH LOAD       11 ATOMS",
    "Info: 456789 ATOMS",
    "Info: 3 ATOMS IN LARGEST HYDROGEN GROUP",
    "Info: LARGEST PATCH (12) HAS 345 ATOMS",
    "Info: Initial time: 96 CPUs 0.2 s/step 2.3 days/ns 500 MB memory",
    "Info: Benchmark time: 96 CPUs 0.1 s/step 0.75 days/ns 500 MB memory",
    "Info: Benchmark time: 96 CPUs 0.1 s/step 0.625 days/ns 500 MB memory",
    "WallClock: 321.250000  CPUTime: 300.000000  Memory: 500.000000 MB",
]
# What the recorder reads from NAMD_OUT.
FROM_NAMD_OUT = {"days_per_ns": "0.625", "ns_per_day": "1.6", "time_to_solution_seconds": "321.250000",
                 "atoms_million": "0.456789", "namd_version": "9.8.7", "namd_platform": "Linux-AVX512-MPI-smp",
                 "nsteps": "3000", "timestep_fs": "2"}


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


def record(work: Path, tools: Path, *args: str, files: dict[str, list[str]] | None = None,
           env: dict[str, str] | None = None, run_args: tuple = RUN_ARGS, stubs: dict[str, str] | None = None,
           dry_run: bool = True) -> subprocess.CompletedProcess:
    """Run the recorder from `work`, with `run_args`, `args` and --run-dir `work`/run, which holds `files` ({name:
    lines}; by default namd.out with NAMD_OUT). `stubs` puts commands ({name: bash body}) first on the PATH."""
    run_dir, bin_dir = work / "run", work / "bin"
    run_dir.mkdir(parents=True)
    bin_dir.mkdir()
    for name, lines in ({"namd.out": NAMD_OUT} if files is None else files).items():
        (run_dir / name).write_text("\n".join(lines) + "\n")
    for name, body in (stubs or {}).items():
        (bin_dir / name).write_text("#!/bin/bash\n" + body)
        (bin_dir / name).chmod(0o755)
    job_env = {"PATH": f"{bin_dir}{os.pathsep}{tools}", "HOME": str(work), "LC_ALL": "C", **(env or {})}
    return subprocess.run([BASH, str(RECORDER), *run_args, *(["--dry-run"] if dry_run else []), "--run-dir",
                           str(run_dir), *args], cwd=work, env=job_env, capture_output=True, text=True,
                          errors="replace", timeout=120)


def unique_keys(pairs: list[tuple]) -> dict:
    keys = [k for k, _ in pairs]
    assert len(keys) == len(set(keys)), keys
    return dict(pairs)


def dry_run(proc: subprocess.CompletedProcess) -> tuple[str, dict]:
    """The dry run's first line and its record, each value as its string (a list of strings for libraries). An
    attribute written twice fails."""
    assert proc.returncode == 0, proc.stdout + proc.stderr
    lines = proc.stdout.splitlines()
    start = next(i for i, line in enumerate(lines) if line.startswith("# DRY RUN"))
    data = json.loads("\n".join(lines[start + 1:]), object_pairs_hook=unique_keys)
    return lines[start], {k: [x["S"] for x in v["L"]] if "L" in v else v.get("S", v.get("N")) for k, v in data.items()}


def item(proc: subprocess.CompletedProcess) -> dict:
    return dry_run(proc)[1]


def test_namd_out_gives_the_result_the_size_and_the_run_length(tmp_path, host_tools):
    proc = record(tmp_path, host_tools, "--case", "STMV")
    first, rec = dry_run(proc)
    assert first.endswith(" would write to table 'External_TestSuite_Namd' (region us-east-1); no file, no AWS.")
    assert {k: rec.get(k) for k in FROM_NAMD_OUT} == FROM_NAMD_OUT
    assert rec["libraries"] == ["mpi:openmpi", "namd:9.8.7"]
    assert {k: rec[k] for k in ("application", "benchmark_case", "instance_type", "operating_system", "num_cores",
                                "num_instances", "cores_per_node", "mpi_implementation", "discipline",
                                "provenance_origin", "provenance_source_id")} == {
        "application": "namd", "benchmark_case": "STMV", "instance_type": "hpc7a.96xlarge",
        "operating_system": "Synthetic OS 1", "num_cores": "96", "num_instances": "1", "cores_per_node": "96",
        "mpi_implementation": "openmpi", "discipline": "MD", "provenance_origin": "external",
        "provenance_source_id": "TestSuite"}
    assert re.fullmatch(r"namd-TestSuite-hpc7a\.96xlarge-96c-STMV-\d{8}T\d{6}Z-\d+", rec["record_id"])
    assert "NOTE:" not in proc.stderr and "WARN" not in proc.stderr, proc.stderr
    assert sorted(p.name for p in tmp_path.iterdir()) == ["bin", "run"]   # no file written
    assert sorted(p.name for p in (tmp_path / "run").iterdir()) == ["namd.out"]



# A config that runs NAMD through Tcl run commands (DHFR's GPU benchmark configs: "run $num_steps_run") runs only
# their steps. NAMD prints its numsteps parameter as NUMBER OF STEPS, 0 when the config sets none, and a line per
# command; a minimization's steps are not counted.
@pytest.mark.parametrize("number_of_steps, tcl, nsteps", [
    ("0", ["TCL: Running for 1000 steps"], "1000"),
    ("0", ["TCL: Running for 400 steps", "TCL: Running for 600 steps without repeating first step"], "1000"),
    ("0", ["TCL: Minimizing for 100 steps", "TCL: Running for 1000 steps"], "1000"),
    ("0", ["TCL: Minimizing for 100 steps"], "0"),
    ("3000", ["TCL: Original numsteps 3000 will be ignored.", "TCL: Running for 2000 steps"], "2000"),
])
def test_a_config_with_run_commands_records_the_steps_they_ran(number_of_steps, tcl, nsteps, tmp_path, host_tools):
    lines = [line.replace("NUMBER OF STEPS        3000", f"NUMBER OF STEPS        {number_of_steps}")
             for line in NAMD_OUT]
    at = lines.index("Info: LARGEST PATCH (12) HAS 345 ATOMS") + 1
    lines[at:at] = tcl
    rec = item(record(tmp_path, host_tools, files={"namd.out": lines}))
    assert rec["nsteps"] == nsteps
    assert {k: rec[k] for k in FROM_NAMD_OUT if k != "nsteps"} == {k: v for k, v in FROM_NAMD_OUT.items()
                                                                   if k != "nsteps"}

@pytest.mark.parametrize("days, rate", [("0.625", "1.6"), ("0.0312", "32.0513"), ("1.5e-05", "66666.7"),
                                        ("3", "0.333333"), ("2.5E-3", "400")])
def test_ns_per_day_is_one_over_days_per_ns_to_six_significant_digits(days, rate, tmp_path, host_tools):
    lines = [*NAMD_OUT[:-2], f"Info: Benchmark time: 96 CPUs 0.1 s/step {days} days/ns 500 MB memory", NAMD_OUT[-1]]
    rec = item(record(tmp_path / "out", host_tools, files={"namd.out": lines}))
    assert (rec["days_per_ns"], rec["ns_per_day"]) == (days, rate)
    rec = item(record(tmp_path / "flag", host_tools, "--days-per-ns", days, files={}))
    assert (rec["days_per_ns"], rec["ns_per_day"]) == (days, rate)


def test_a_given_value_wins_over_namd_out(tmp_path, host_tools):
    """Flags and the environment's values are recorded as given; namd.out gives the rest."""
    rec = item(record(tmp_path / "flags", host_tools, "--days-per-ns", "0.5", "--time-to-solution", "99",
                      "--atoms-million", "2", "--version", "1.2.3"))
    assert {k: rec[k] for k in ("days_per_ns", "ns_per_day", "time_to_solution_seconds", "atoms_million",
                                "namd_version", "nsteps", "timestep_fs", "namd_platform")} == {
        "days_per_ns": "0.5", "ns_per_day": "2", "time_to_solution_seconds": "99", "atoms_million": "2",
        "namd_version": "1.2.3", "nsteps": "3000", "timestep_fs": "2", "namd_platform": "Linux-AVX512-MPI-smp"}
    assert rec["libraries"] == ["mpi:openmpi", "namd:1.2.3"]
    env = {"DAYS_PER_NS": "0.4", "TIME_TO_SOLUTION": "88", "ATOMS_MILLION": "3", "NAMD_VERSION": "4.5.6",
           "BENCHMARK_CASE": "ApoA1"}
    rec = item(record(tmp_path / "env", host_tools, env=env))
    assert {k: rec[k] for k in ("days_per_ns", "ns_per_day", "time_to_solution_seconds", "atoms_million",
                                "namd_version", "benchmark_case")} == {
        "days_per_ns": "0.4", "ns_per_day": "2.5", "time_to_solution_seconds": "88", "atoms_million": "3",
        "namd_version": "4.5.6", "benchmark_case": "ApoA1"}
    rec = item(record(tmp_path / "rate", host_tools, "--ns-per-day", "7.25"))
    assert (rec["days_per_ns"], rec["ns_per_day"]) == ("0.625", "7.25")


def test_with_no_namd_out_the_results_are_left_out_with_notes(tmp_path, host_tools):
    proc = record(tmp_path, host_tools, files={})
    rec = item(proc)
    for name in ("days_per_ns", "ns_per_day", "time_to_solution_seconds", "atoms_million", "nsteps", "timestep_fs",
                 "namd_version", "namd_platform", "benchmark_case"):
        assert name not in rec, name
    for note in ("NOTE: no --case given; the case/dataset name strongly improves model accuracy.",
                 "NOTE: no --time-to-solution given; this is the model's primary target metric.",
                 "NOTE: no --ns-per-day or --days-per-ns given, and no namd.out gives a days/ns.",
                 "NOTE: no --atoms-million given; system size is a key driver of runtime."):
        assert note in proc.stderr.splitlines(), proc.stderr


def test_another_out_or_log_file_with_a_benchmark_line_is_read_and_namd_out_comes_first(tmp_path, host_tools):
    no_bench = [line for line in NAMD_OUT if "Benchmark time:" not in line]
    other = [line.replace("0.625 days/ns", "0.8 days/ns") for line in NAMD_OUT]
    rec = item(record(tmp_path / "log", host_tools, files={"slurm-1.out": no_bench, "run.log": NAMD_OUT}))
    assert rec["days_per_ns"] == "0.625"
    rec = item(record(tmp_path / "first", host_tools, files={"a.out": other, "namd.out": NAMD_OUT}))
    assert rec["days_per_ns"] == "0.625"
    rec = item(record(tmp_path / "skip", host_tools, files={"namd.out": no_bench, "b.out": other}))
    assert rec["days_per_ns"] == "0.8"


def test_metrics_and_chars_come_after_the_records_own_attributes(tmp_path, host_tools):
    """A new name is recorded; a name the record holds, or one already given, is left out with a WARN."""
    proc = record(tmp_path, host_tools, "--metric", "procs_per_node=4", "--metric", "pes_per_proc=47",
                  "--char", "avx512_tiles=on", "--metric", "nsteps=5", "--metric", "days_per_ns=9",
                  "--char", "namd_version=0", "--char", "provenance_origin=x", "--metric", "num_cores=1",
                  "--metric", "procs_per_node=8", "--char", "avx512_tiles=off", "--char", "analysis_type=NPT")
    rec = item(proc)
    assert {k: rec[k] for k in ("procs_per_node", "pes_per_proc", "avx512_tiles", "nsteps", "days_per_ns",
                                "namd_version", "provenance_origin", "num_cores", "analysis_type")} == {
        "procs_per_node": "4", "pes_per_proc": "47", "avx512_tiles": "on", "nsteps": "3000", "days_per_ns": "0.625",
        "namd_version": "9.8.7", "provenance_origin": "external", "num_cores": "96", "analysis_type": "NPT"}
    warns = sorted(line for line in proc.stderr.splitlines() if line.startswith("WARN"))
    assert warns == sorted(f"WARN: ignoring a second value for '{name}'" for name in (
        "nsteps", "days_per_ns", "namd_version", "provenance_origin", "num_cores", "procs_per_node", "avx512_tiles"))


def test_a_metric_that_is_not_a_number_and_a_pair_with_no_equals_sign_are_left_out(tmp_path, host_tools):
    proc = record(tmp_path, host_tools, "--metric", "speed=fast", "--char", "layout", "--metric", "steps=1e3")
    rec = item(proc)
    assert "speed" not in rec and "layout" not in rec and rec["steps"] == "1e3"
    assert "WARN: ignoring non-numeric value for 'speed': 'fast'" in proc.stderr.splitlines(), proc.stderr
    assert "WARN: ignoring malformed 'layout' (expected name=value)" in proc.stderr.splitlines(), proc.stderr


def test_the_cores_and_nodes_given_or_from_slurm(tmp_path, host_tools):
    rec = item(record(tmp_path / "given", host_tools, "--num-cores", "384", "--num-nodes", "2"))
    assert (rec["num_cores"], rec["num_instances"], rec["cores_per_node"]) == ("384", "2", "192")
    rec = item(record(tmp_path / "per-node", host_tools, "--cores-per-node", "48"))
    assert rec["cores_per_node"] == "48"
    slurm = ("--instance-type", "hpc7a.96xlarge", "--os", "Synthetic OS 1", "--mpi", "openmpi")
    rec = item(record(tmp_path / "slurm", host_tools, run_args=slurm,
                      env={"SLURM_NTASKS": "8", "SLURM_JOB_NUM_NODES": "2", "SLURM_JOB_ID": "777"}))
    assert (rec["num_cores"], rec["num_instances"], rec["cores_per_node"]) == ("8", "2", "4")
    assert rec["record_id"].endswith("-777"), rec["record_id"]


def test_the_libraries_name_the_mpi_libfabric_efa_and_namd_versions(tmp_path, host_tools):
    """With mpirun and fi_info on the PATH (stubs here), the MPI is detected and the versions read."""
    stubs = {"mpirun": 'echo "mpirun (Open MPI) 4.1.7"\n',
             "fi_info": 'case "$*" in\n  --version) printf "fi_info: 2.4.0\\nlibfabric: 2.4.0amzn5.0\\n" ;;\n'
                        '  "-p efa -t FI_EP_RDM") printf "provider: efa\\n    version: 122.0\\n" ;;\nesac\n'}
    run_args = tuple(a for a in RUN_ARGS if a not in ("--mpi", "openmpi"))
    rec = item(record(tmp_path, host_tools, run_args=run_args, stubs=stubs))
    assert rec["mpi_implementation"] == "openmpi"
    assert rec["libraries"] == ["mpi:openmpi", "mpi-version:4.1.7", "libfabric:2.4.0amzn5.0", "efa:122.0",
                                "namd:9.8.7"]
    stubs["mpirun"] = 'echo "Intel(R) MPI Library for Linux* OS, Version 2021.18 Build 20250101"\n'
    rec = item(record(tmp_path / "intel", host_tools, run_args=run_args, stubs=stubs))
    assert rec["mpi_implementation"] == "intelmpi"
    assert rec["libraries"][:2] == ["mpi:intelmpi", "mpi-version:2021.18"]


def test_the_table_takes_the_sources_letters_and_digits(tmp_path, host_tools):
    run_args = tuple(a for a in RUN_ARGS if a not in ("--source", "TestSuite"))
    first, rec = dry_run(record(tmp_path / "source", host_tools, "--source", "Acme Corp-1!", run_args=run_args))
    assert "'External_AcmeCorp1_Namd' (region us-east-1)" in first
    assert rec["provenance_source_id"] == "AcmeCorp1"
    first, _ = dry_run(record(tmp_path / "default", host_tools, run_args=run_args))
    assert "'External_Community_Namd'" in first
    first, _ = dry_run(record(tmp_path / "table", host_tools, "--table", "Custom_Table", "--region", "eu-north-1"))
    assert "'Custom_Table' (region eu-north-1)" in first
    first, _ = dry_run(record(tmp_path / "region", host_tools, env={"DYNAMODB_REGION": "us-west-2"}))
    assert "(region us-west-2)" in first


@pytest.mark.parametrize("dropped, missing", [(("--num-cores", "96"), "num_cores (--num-cores)"),
                                              (("--num-nodes", "1"), "num_instances (--num-nodes)")])
def test_a_missing_required_field_stops_the_recorder(dropped, missing, tmp_path, host_tools):
    run_args = tuple(a for a in RUN_ARGS if a not in dropped)
    proc = record(tmp_path, host_tools, run_args=run_args)
    assert proc.returncode == 1, proc.stdout + proc.stderr
    assert f"ERROR: missing required field: {missing}" in proc.stderr.splitlines(), proc.stderr
    assert "DRY RUN" not in proc.stdout


def test_the_libraries_need_an_mpi_or_a_version_and_namd_out_gives_the_version(tmp_path, host_tools):
    run_args = tuple(a for a in RUN_ARGS if a not in ("--mpi", "openmpi"))
    rec = item(record(tmp_path / "out", host_tools, run_args=run_args))
    assert rec["libraries"] == ["namd:9.8.7"] and "mpi_implementation" not in rec
    proc = record(tmp_path / "none", host_tools, run_args=run_args, files={})
    assert proc.returncode == 1, proc.stdout + proc.stderr
    assert "ERROR: cannot compose 'libraries' (provide at least --mpi or --version)" in proc.stderr.splitlines()


def test_without_dry_run_the_record_is_a_json_file_in_out(tmp_path, host_tools):
    proc = record(tmp_path, host_tools, "--case", "STMV", "--no-put", "--out", str(tmp_path / "saved"),
                  dry_run=False)
    assert proc.returncode == 0, proc.stderr
    (saved,) = (tmp_path / "saved").glob("*.json")
    rec = json.loads(saved.read_text(), object_pairs_hook=unique_keys)
    assert saved.name == rec["record_id"]["S"] + ".json"
    assert rec["days_per_ns"] == {"N": "0.625"} and rec["benchmark_case"] == {"S": "STMV"}
    assert f"Skipped DynamoDB write (--no-put). JSON saved at {saved}." in proc.stdout.splitlines()


def header_comment() -> list[str]:
    """The script's header comment, from its second line to the last comment line before the code, less "# "."""
    lines = RECORDER.read_text().splitlines()[1:]
    header = []
    for line in lines:
        if not line.startswith("#"):
            break
        header.append(re.sub(r"^# ?", "", line))
    return header


def test_help_prints_the_whole_header_comment_then_the_options(tmp_path, host_tools):
    proc = subprocess.run([BASH, str(RECORDER), "--help"], cwd=tmp_path, capture_output=True, text=True,
                          errors="replace", timeout=120, env={"PATH": str(host_tools), "HOME": str(tmp_path),
                                                              "LC_ALL": "C"})
    assert proc.returncode == 0, proc.stderr
    header = header_comment()
    lines = proc.stdout.splitlines()
    assert lines[:len(header)] == header
    assert lines[len(header):len(header) + 2] == ["", "OPTIONS"]
    text = " ".join(proc.stdout.split())
    for option in ("--days-per-ns X", "--ns-per-day X", "--atoms-million X", "--run-dir DIR", "--dry-run"):
        assert option in text, option


def test_an_unknown_option_stops_the_recorder_with_exit_2(tmp_path, host_tools):
    proc = record(tmp_path, host_tools, "--days", "1")
    assert proc.returncode == 2
    assert "ERROR: unknown option '--days' (try --help)" in proc.stderr
