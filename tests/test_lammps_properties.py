"""Property-based tests for the LAMMPS support feature.

Validates the universal correctness properties from
.kiro/specs/lammps-support/design.md.

The shell scripts under apps/LAMMPS/ contain pure-function logic
(env-script string generation, install-path construction, log-line
parsing, command-line generation, DynamoDB JSON construction). We
re-implement the same logic in Python below and exercise it with
Hypothesis-generated inputs to verify the properties hold.

Run with:
    python -m pip install -r tests/requirements.txt
    python -m pytest tests/test_lammps_properties.py -q
"""

from __future__ import annotations

import json
import re
from textwrap import dedent

from hypothesis import given, settings, strategies as st


# ---------------------------------------------------------------------------
# Pure-function helpers re-implemented from the sbatch scripts
# ---------------------------------------------------------------------------

def env_script(arch: str, target: str, ompi_version: int, tag: str,
               install_dir: str) -> str:
    """Mirror of the env-script heredoc in the build sbatch files.

    Returns the full text the build script would write to
    `lammps-<tag>[-ompi5]-env.sh`.
    """
    if ompi_version == 5:
        module = "openmpi5/5.0.9amzn1"
    else:
        module = "openmpi/4.1.7"
    return dedent(f"""\
        #!/bin/bash
        # LAMMPS {tag} — {arch}/{target} (GCC + OpenMPI {ompi_version})
        module purge
        module load {module}
        module load libfabric-aws
        export LAMMPS_ROOT="{install_dir}"
        export LAMMPS_TAG="{tag}"
        export PATH="${{LAMMPS_ROOT}}/bin:${{PATH}}"
        export LD_LIBRARY_PATH="${{LAMMPS_ROOT}}/lib64:${{LAMMPS_ROOT}}/lib:${{LD_LIBRARY_PATH:-}}"
        """)


def install_path_arm(target: str, ompi_version: int, tag: str,
                     base_dir: str = "/fsx/lammps") -> str:
    """Mirror of the Arm build's install-dir computation.

    /fsx/lammps/aarch64-<target>[-ompi5]/<tag>
    """
    suffix = "-ompi5" if ompi_version == 5 else ""
    return f"{base_dir}/aarch64-{target}{suffix}/{tag}"


_LOOP_RE = re.compile(
    r"^\s*Loop time of\s+(?P<time>\d+(?:\.\d+)?)\s+on\s+(?P<procs>\d+)\s+procs"
    r"\s+for\s+(?P<steps>\d+)\s+steps\s+with\s+(?P<atoms>\d+)\s+atoms\s*$"
)


def parse_loop_time(line: str) -> float | None:
    """Mirror of the awk parse for `Loop time of N on M procs ...`."""
    match = _LOOP_RE.match(line)
    if not match:
        return None
    return float(match.group("time"))


def workdir(base_dir: str, job_name: str, model: str, cluster: str,
            job_id: int, nodes: int, instance_type: str,
            ranks: int, threads: int, scale: int, ts: str) -> str:
    """Mirror of the WORKDIR construction in the benchmark sbatch files."""
    return (
        f"{base_dir}/Run/{job_name}/{model}/{cluster}/"
        f"{job_id}-{nodes}x{instance_type}-{ranks}x{threads}-s{scale}-{ts}"
    )


def mpi_bind_flags(threads_per_rank: int, nrank_per_node: int) -> str:
    """Mirror of the bind-flag selection in the benchmark scripts."""
    if threads_per_rank > 1:
        return (
            f"--bind-to core --map-by ppr:{nrank_per_node}:node:"
            f"PE={threads_per_rank}"
        )
    return "--bind-to core --map-by slot"


def lmp_var_args(scale: int, timesteps: int) -> list[str]:
    """Mirror of the LMP_ARGS construction (just the -var portion)."""
    return [
        "-var", "x", str(scale),
        "-var", "y", str(scale),
        "-var", "z", str(scale),
        "-var", "t", str(timesteps),
    ]


def dynamo_record(*, job_id: str, model: str, scale: int, nodes: int,
                  ranks_total: int, ranks_per_node: int,
                  threads_per_rank: int, instance_type: str,
                  cluster_name: str, lammps_tag: str, mpi_stack: str,
                  mpi_version: str, libfabric_version: str,
                  efa_version: str, kernel: str, os_pretty: str,
                  pc_version: str, region: str, atoms: int,
                  timesteps: int, loop_time_s: float,
                  timesteps_per_sec: float, atom_steps_per_sec: float,
                  wall_time_s: float, workdir_path: str,
                  timestamp: str) -> dict:
    """Mirror of the DynamoDB JSON record built in the benchmark scripts."""
    config = f"{nodes}N-{ranks_per_node}rpn-{model}-s{scale}"
    return {
        "job_id":             {"S": job_id},
        "config":             {"S": config},
        "timestamp":          {"S": timestamp},
        "model":              {"S": model},
        "scale":              {"N": str(scale)},
        "nodes":              {"N": str(nodes)},
        "ranks_total":        {"N": str(ranks_total)},
        "ranks_per_node":     {"N": str(ranks_per_node)},
        "threads_per_rank":   {"N": str(threads_per_rank)},
        "instance_type":      {"S": instance_type},
        "cluster_name":       {"S": cluster_name},
        "lammps_tag":         {"S": lammps_tag},
        "mpi_stack":          {"S": mpi_stack},
        "mpi_version":        {"S": mpi_version},
        "libfabric_version":  {"S": libfabric_version},
        "efa_version":        {"S": efa_version},
        "kernel":             {"S": kernel},
        "os":                 {"S": os_pretty},
        "pc_version":         {"S": pc_version},
        "region":             {"S": region},
        "atoms":              {"N": str(atoms)},
        "timesteps":          {"N": str(timesteps)},
        "loop_time_s":        {"N": f"{loop_time_s:.4f}"},
        "timesteps_per_sec":  {"N": f"{timesteps_per_sec:.4f}"},
        "atom_steps_per_sec": {"N": f"{atom_steps_per_sec:.0f}"},
        "wall_time_s":        {"N": f"{wall_time_s:.2f}"},
        "workdir":            {"S": workdir_path},
    }


# ---------------------------------------------------------------------------
# Hypothesis strategies
# ---------------------------------------------------------------------------

archs = st.sampled_from(["x86_64", "aarch64-graviton3", "aarch64-graviton4",
                         "aarch64-graviton3-ompi5", "aarch64-graviton4-ompi5"])
arm_targets = st.sampled_from(["graviton3", "graviton4"])
ompi_versions = st.sampled_from([4, 5])
tags = st.from_regex(r"^stable_[0-9A-Za-z_]{3,30}$", fullmatch=True)
models = st.sampled_from(["lj", "rhodo", "eam"])
instance_types = st.sampled_from([
    "hpc8a.96xlarge", "hpc7a.96xlarge", "hpc7a.48xlarge",
    "hpc7g.16xlarge", "m8g.48xlarge", "r8g.48xlarge",
])


# ---------------------------------------------------------------------------
# Property 1 — Env script generation correctness
# ---------------------------------------------------------------------------

@settings(max_examples=200)
@given(arch=archs, target=st.sampled_from(["hpc8a", "hpc7a", "graviton3",
                                           "graviton4"]),
       ompi_version=ompi_versions, tag=tags)
def test_env_script_contains_required_exports(arch, target, ompi_version, tag):
    install_dir = f"/fsx/lammps/{arch}/{tag}"
    text = env_script(arch, target, ompi_version, tag, install_dir)

    if ompi_version == 5:
        assert "module load openmpi5/5.0.9amzn1" in text
    else:
        assert "module load openmpi/4.1.7" in text
    assert f'export LAMMPS_ROOT="{install_dir}"' in text
    assert "${LAMMPS_ROOT}/bin:${PATH}" in text
    assert "${LAMMPS_ROOT}/lib64:${LAMMPS_ROOT}/lib" in text
    assert text.startswith("#!/bin/bash")


# ---------------------------------------------------------------------------
# Property 2 — Install path naming convention
# ---------------------------------------------------------------------------

@settings(max_examples=200)
@given(target=arm_targets, ompi_version=ompi_versions, tag=tags)
def test_arm_install_path_naming(target, ompi_version, tag):
    path = install_path_arm(target, ompi_version, tag)
    expected_suffix = "-ompi5" if ompi_version == 5 else ""
    assert path == f"/fsx/lammps/aarch64-{target}{expected_suffix}/{tag}"
    if ompi_version == 5:
        assert "-ompi5/" in path
    else:
        assert "-ompi5/" not in path


# ---------------------------------------------------------------------------
# Property 3 — LAMMPS log parsing (Loop time extraction)
# ---------------------------------------------------------------------------

@settings(max_examples=300)
@given(time=st.floats(min_value=0.001, max_value=1e6, allow_nan=False,
                      allow_infinity=False),
       procs=st.integers(min_value=1, max_value=10000),
       steps=st.integers(min_value=1, max_value=1000000),
       atoms=st.integers(min_value=1, max_value=10**9))
def test_loop_time_parser_round_trip(time, procs, steps, atoms):
    line = (
        f"Loop time of {time} on {procs} procs for {steps} steps "
        f"with {atoms} atoms"
    )
    result = parse_loop_time(line)
    assert result is not None
    assert abs(result - time) < 1e-6 * max(1.0, time)


@given(garbage=st.text(max_size=200).filter(lambda s: "Loop time of" not in s))
def test_loop_time_parser_rejects_non_matches(garbage):
    assert parse_loop_time(garbage) is None


# ---------------------------------------------------------------------------
# Property 4 — Run directory uniqueness
# ---------------------------------------------------------------------------

@settings(max_examples=200)
@given(
    a=st.tuples(
        st.integers(1, 10**8), st.integers(1, 200), instance_types,
        st.integers(1, 10**6), st.integers(1, 192), st.integers(1, 8),
        st.from_regex(r"^[0-9]{2}-[0-9]{2}-[0-9]{4}-[0-9]{2}-[0-9]{2}$",
                      fullmatch=True),
    ),
    b=st.tuples(
        st.integers(1, 10**8), st.integers(1, 200), instance_types,
        st.integers(1, 10**6), st.integers(1, 192), st.integers(1, 8),
        st.from_regex(r"^[0-9]{2}-[0-9]{2}-[0-9]{4}-[0-9]{2}-[0-9]{2}$",
                      fullmatch=True),
    ),
)
def test_workdir_uniqueness_for_distinct_inputs(a, b):
    if a == b:
        return  # equal inputs are allowed to yield equal paths
    pa = workdir("/fsx/lammps", "lammps", "lj", "hpc-4", *a)
    pb = workdir("/fsx/lammps", "lammps", "lj", "hpc-4", *b)
    assert pa != pb


# ---------------------------------------------------------------------------
# Property 5 — SCALE -> -var mapping
# ---------------------------------------------------------------------------

@settings(max_examples=200)
@given(scale=st.integers(min_value=1, max_value=64),
       timesteps=st.integers(min_value=1, max_value=10**6))
def test_scale_emits_xyz_vars(scale, timesteps):
    args = lmp_var_args(scale, timesteps)
    # -var x SCALE -var y SCALE -var z SCALE -var t TIMESTEPS
    assert args[:3] == ["-var", "x", str(scale)]
    assert args[3:6] == ["-var", "y", str(scale)]
    assert args[6:9] == ["-var", "z", str(scale)]
    assert args[9:] == ["-var", "t", str(timesteps)]


# ---------------------------------------------------------------------------
# Property 6 — Core binding configuration
# ---------------------------------------------------------------------------

@settings(max_examples=200)
@given(threads=st.integers(min_value=1, max_value=8),
       rpn=st.integers(min_value=1, max_value=192))
def test_core_binding_flags(threads, rpn):
    flags = mpi_bind_flags(threads, rpn)
    if threads > 1:
        assert flags == (
            f"--bind-to core --map-by ppr:{rpn}:node:PE={threads}"
        )
    else:
        assert flags == "--bind-to core --map-by slot"


# ---------------------------------------------------------------------------
# Property 7 — DynamoDB record completeness
# ---------------------------------------------------------------------------

REQUIRED_KEYS = {
    "job_id", "config", "timestamp", "model", "scale", "nodes",
    "ranks_total", "ranks_per_node", "threads_per_rank", "instance_type",
    "cluster_name", "lammps_tag", "mpi_stack", "mpi_version",
    "libfabric_version", "efa_version", "kernel", "os", "pc_version",
    "region", "atoms", "timesteps", "loop_time_s", "timesteps_per_sec",
    "atom_steps_per_sec", "wall_time_s", "workdir",
}
NUMERIC_KEYS = {
    "scale", "nodes", "ranks_total", "ranks_per_node", "threads_per_rank",
    "atoms", "timesteps", "loop_time_s", "timesteps_per_sec",
    "atom_steps_per_sec", "wall_time_s",
}


@settings(max_examples=200)
@given(
    job_id=st.from_regex(r"^[0-9]{1,8}$", fullmatch=True),
    model=models,
    scale=st.integers(min_value=1, max_value=64),
    nodes=st.integers(min_value=1, max_value=200),
    rpn=st.integers(min_value=1, max_value=192),
    threads=st.integers(min_value=1, max_value=8),
    instance_type=instance_types,
    lammps_tag=tags,
    mpi_stack=st.sampled_from(["openmpi-4", "openmpi-5"]),
    atoms=st.integers(min_value=1, max_value=10**8),
    timesteps=st.integers(min_value=1, max_value=10**6),
    loop_time=st.floats(min_value=0.001, max_value=1e5, allow_nan=False,
                        allow_infinity=False),
)
def test_dynamo_record_schema(job_id, model, scale, nodes, rpn, threads,
                              instance_type, lammps_tag, mpi_stack, atoms,
                              timesteps, loop_time):
    ranks_total = nodes * rpn
    rec = dynamo_record(
        job_id=job_id,
        model=model, scale=scale,
        nodes=nodes, ranks_total=ranks_total, ranks_per_node=rpn,
        threads_per_rank=threads, instance_type=instance_type,
        cluster_name="hpc-test", lammps_tag=lammps_tag,
        mpi_stack=mpi_stack, mpi_version="4.1.7",
        libfabric_version="2.4.0", efa_version="204.0",
        kernel="6.1.0-amzn", os_pretty="Amazon Linux 2023",
        pc_version="3.13.0", region="us-east-1",
        atoms=atoms, timesteps=timesteps, loop_time_s=loop_time,
        timesteps_per_sec=timesteps / loop_time,
        atom_steps_per_sec=atoms * timesteps / loop_time,
        wall_time_s=loop_time + 5.0,
        workdir_path=f"/fsx/lammps/Run/test/{job_id}",
        timestamp="2026-05-21T12:00:00Z",
    )

    # All required keys present
    assert REQUIRED_KEYS.issubset(rec.keys())

    # Each value is a one-key dict {"N":...} or {"S":...}
    for key, val in rec.items():
        assert isinstance(val, dict) and len(val) == 1
        kind = next(iter(val.keys()))
        if key in NUMERIC_KEYS:
            assert kind == "N"
            float(val["N"])  # must parse as a number
        else:
            assert kind == "S"
            assert isinstance(val["S"], str)

    # config sort key follows the documented format
    assert rec["config"]["S"] == f"{nodes}N-{rpn}rpn-{model}-s{scale}"

    # The whole record must be JSON-serialisable (DynamoDB ingests via JSON)
    json.dumps(rec)
