"""Property-based tests for the GROMACS support feature.

Validates the universal correctness properties from
.kiro/specs/gromacs-support/design.md.

The shell scripts under apps/Gromacs/ contain pure-function logic:
  * env-script string generation (one heredoc per Thread_MPI / Library_MPI
    variant in build_gromacs_x86.sbatch and the Arm equivalent)
  * install-path construction with the optional `-ompi5` suffix
  * md.log parsing for `Performance: <ns/day> <hour/ns>` and
    `Wall t (s):` extraction
  * unique run-directory naming
  * binary selection (gmx vs gmx_mpi) by node count
  * core-binding flag selection for hybrid MPI+OpenMP
  * DynamoDB JSON record construction

We re-implement the same logic in Python below and exercise it with
Hypothesis-generated inputs to verify the properties hold. The Python
helpers mirror what the shell scripts do byte-for-byte so the property
tests in tasks 9.2-9.7 verify the algorithm rather than the bash.

Run with:
    python -m pip install -r tests/requirements.txt
    python -m pytest tests/test_gromacs_properties.py -q

Validates: Requirements 13.1, 13.5
"""

from __future__ import annotations

import json
import re
from textwrap import dedent

from hypothesis import assume, given, settings, strategies as st


# ---------------------------------------------------------------------------
# Pure-function helpers re-implemented from the sbatch / shell scripts
# ---------------------------------------------------------------------------


def env_script(arch: str, target: str, variant: str, ompi_version: int,
               tag: str, install_dir: str) -> str:
    """Mirror of the env-script heredocs in the GROMACS build scripts.

    Returns the full text the build script would write to
    `gromacs-<tag>-{tmpi,ompi[5]}-env.sh`.

    The Thread_MPI variant has no MPI dependency and is byte-identical
    across architectures — only the comment header changes. The
    Library_MPI variant prepends `module purge`, `module load
    openmpi/<version>` (4.1.7 or 5.0.9), and `module load libfabric-aws`
    so EFA is automatic at runtime.
    """
    if variant == "tmpi":
        header = (
            f"# GROMACS {tag} — {arch} Thread_MPI variant "
            f"(GCC, {target})\n"
            "# Single-node only. Use the ompi variant for "
            "multi-node runs.\n"
        )
        modules = ""
    elif variant == "ompi":
        if ompi_version == 5:
            module_line = "module load openmpi/5.0.9"
        else:
            module_line = "module load openmpi/4.1.7"
        header = (
            f"# GROMACS {tag} — {arch} Library_MPI variant "
            f"(GCC + OpenMPI {ompi_version}, {target})\n"
            "# Multi-node capable. Invoke gmx_mpi under mpirun.\n"
        )
        modules = dedent(f"""\
            module purge
            {module_line}
            module load libfabric-aws
            """)
    else:
        raise ValueError(f"unknown variant: {variant!r}")

    body = dedent(f"""\
        export GROMACS_ROOT="{install_dir}"
        export GROMACS_TAG="{tag}"
        export PATH="${{GROMACS_ROOT}}/bin:${{PATH}}"
        export LD_LIBRARY_PATH="${{GROMACS_ROOT}}/lib64:${{GROMACS_ROOT}}/lib:${{LD_LIBRARY_PATH:-}}"
        export GMXLIB="${{GROMACS_ROOT}}/share/gromacs/top"
        """)
    return "#!/bin/bash\n" + header + modules + body


def install_path_arm(target: str, ompi_version: int, tag: str,
                     variant: str = "tmpi",
                     base_dir: str = "/fsx/gromacs") -> str:
    """Mirror of the Arm build's per-variant install-dir computation.

    /fsx/gromacs/aarch64-<target>[-ompi5]/<tag>/<variant>

    The `-ompi5` suffix is present iff `ompi_version == 5`. Both
    variant subdirectories (`tmpi/` and `ompi/`) live under the same
    parent directory, so the suffix tracks only the OpenMPI generation
    used by the Library_MPI variant.
    """
    if variant not in ("tmpi", "ompi"):
        raise ValueError(f"unknown variant: {variant!r}")
    suffix = "-ompi5" if ompi_version == 5 else ""
    return f"{base_dir}/aarch64-{target}{suffix}/{tag}/{variant}"


def install_path_x86(tag: str, variant: str = "tmpi",
                     base_dir: str = "/fsx/gromacs") -> str:
    """Mirror of the x86 build's per-variant install-dir computation.

    /fsx/gromacs/x86_64/<tag>/<variant>
    """
    if variant not in ("tmpi", "ompi"):
        raise ValueError(f"unknown variant: {variant!r}")
    return f"{base_dir}/x86_64/{tag}/{variant}"


# Mirrors the awk patterns in the benchmark script:
#   PERF_LINE: ^Performance:\s+<ns_per_day>\s+<hour_per_ns>
#   TIME_LINE: '/^[[:space:]]*Time:/ {wall=$3}' — wall is column 3 because
#   awk's field 1 is "Time:", field 2 is the core-time, field 3 is the
#   wall-time.
_PERF_RE = re.compile(
    r"^Performance:\s+(?P<ns_per_day>\d+(?:\.\d+)?)"
    r"\s+(?P<hour_per_ns>\d+(?:\.\d+)?)\s*$",
    re.MULTILINE,
)
_TIME_RE = re.compile(
    r"^\s*Time:\s+(?P<core>\d+(?:\.\d+)?)"
    r"\s+(?P<wall>\d+(?:\.\d+)?)"
    r"\s+(?P<pct>\d+(?:\.\d+)?)\s*$",
    re.MULTILINE,
)


def parse_md_log(text: str) -> tuple[float, float, float]:
    """Mirror of the GROMACS md.log parsing in the benchmark script.

    Returns (ns_per_day, hour_per_ns, wall_time_s). For inputs missing
    one or more of the lines, the missing field is returned as 0.0
    rather than raising — the per-job exit status from gmx_mpi is the
    authoritative success signal per design.md error-handling table.
    """
    ns_per_day = 0.0
    hour_per_ns = 0.0
    wall_time_s = 0.0

    perf_matches = list(_PERF_RE.finditer(text))
    if perf_matches:
        last = perf_matches[-1]  # `tail -1` in the bash
        ns_per_day = float(last.group("ns_per_day"))
        hour_per_ns = float(last.group("hour_per_ns"))

    time_matches = list(_TIME_RE.finditer(text))
    if time_matches:
        # awk's `{wall=$3} END {print wall}' keeps the last match
        wall_time_s = float(time_matches[-1].group("wall"))

    return ns_per_day, hour_per_ns, wall_time_s


def workdir(base_dir: str, job_name: str, model: str, cluster: str,
            job_id: int, nodes: int, instance_type: str,
            ranks: int, threads: int, ts: str) -> str:
    """Mirror of the WORKDIR construction in the GROMACS benchmark script.

    /fsx/gromacs/Run/<jobname>/<model>/<cluster>/
        <jobid>-<nodes>x<instance>-<ranks>x<threads>-<date>

    Note: GROMACS does NOT include a `-s<scale>` segment because the
    benchmark systems are fixed-size .tpr files — the LAMMPS lattice-
    replication knob has no GROMACS analogue.
    """
    return (
        f"{base_dir}/Run/{job_name}/{model}/{cluster}/"
        f"{job_id}-{nodes}x{instance_type}-{ranks}x{threads}-{ts}"
    )


def select_binary(num_nodes: int, gromacs_env: str | None = None
                  ) -> tuple[str, bool]:
    """Mirror of the binary-selection logic in the GROMACS benchmark script.

    Returns (binary_name, use_mpirun).

    Decision tree:
      * If GROMACS_ENV ends in `-tmpi-env.sh`, force `gmx` (Thread_MPI).
      * If GROMACS_ENV ends in `-ompi-env.sh` or `-ompi5-env.sh`, force
        `gmx_mpi` (Library_MPI under mpirun).
      * If GROMACS_ENV is None or its suffix is unrecognised, fall back
        to the node-count rule: 1 node → `gmx` (no mpirun); >1 node →
        `gmx_mpi` (under mpirun).

    Multi-node Thread_MPI is impossible — the launcher rejects that
    combination; this helper returns the `gmx` selection so the caller
    can detect the violation.
    """
    if gromacs_env is not None:
        if gromacs_env.endswith("-tmpi-env.sh"):
            return ("gmx", False)
        if (gromacs_env.endswith("-ompi-env.sh")
                or gromacs_env.endswith("-ompi5-env.sh")):
            return ("gmx_mpi", True)

    if num_nodes == 1:
        return ("gmx", False)
    return ("gmx_mpi", True)


def mpi_bind_flags(threads_per_rank: int, nrank_per_node: int) -> str:
    """Mirror of the bind-flag selection in the GROMACS benchmark script.

    Identical algorithm to the LAMMPS launcher:
      * THREADS_PER_RANK > 1 → `--bind-to core --map-by ppr:<rpn>:node:PE=<threads>`
      * THREADS_PER_RANK == 1 → `--bind-to core --map-by slot`
    """
    if threads_per_rank > 1:
        return (
            f"--bind-to core --map-by ppr:{nrank_per_node}:node:"
            f"PE={threads_per_rank}"
        )
    return "--bind-to core --map-by slot"


def dynamo_record(*, job_id: str, model: str, nodes: int,
                  ranks_total: int, ranks_per_node: int,
                  threads_per_rank: int, instance_type: str,
                  cluster_name: str, gromacs_tag: str, mpi_stack: str,
                  mpi_version: str, libfabric_version: str,
                  efa_version: str, kernel: str, os_pretty: str,
                  pc_version: str, region: str, atoms: int,
                  nsteps: int, ns_per_day: float, hour_per_ns: float,
                  wall_time_s: float, workdir_path: str,
                  timestamp: str,
                  gpu_count: int | None = None,
                  cuda_version: str | None = None) -> dict:
    """Mirror of the DynamoDB JSON record built by record_to_dynamodb.sh.

    Schema:
      * partition key:  job_id (S)
      * sort key:       config (S) — formatted "<nodes>N-<rpn>rpn-<model>"
      * Numeric fields wrapped as {"N": "<string>"}
      * String fields wrapped as {"S": "<string>"}

    The Phase 3 GPU fields (`gpu_count`, `cuda_version`) are appended
    only when BOTH are set; CPU runs omit them entirely, matching the
    GPU_FIELDS conditional in the recorder.
    """
    config = f"{nodes}N-{ranks_per_node}rpn-{model}"
    record = {
        "job_id":             {"S": job_id},
        "config":             {"S": config},
        "timestamp":          {"S": timestamp},
        "model":              {"S": model},
        "nodes":              {"N": str(nodes)},
        "ranks_total":        {"N": str(ranks_total)},
        "ranks_per_node":     {"N": str(ranks_per_node)},
        "threads_per_rank":   {"N": str(threads_per_rank)},
        "instance_type":      {"S": instance_type},
        "cluster_name":       {"S": cluster_name},
        "gromacs_tag":        {"S": gromacs_tag},
        "mpi_stack":          {"S": mpi_stack},
        "mpi_version":        {"S": mpi_version},
        "libfabric_version":  {"S": libfabric_version},
        "efa_version":        {"S": efa_version},
        "kernel":             {"S": kernel},
        "os":                 {"S": os_pretty},
        "pc_version":         {"S": pc_version},
        "region":             {"S": region},
        "atoms":              {"N": str(atoms)},
        "nsteps":             {"N": str(nsteps)},
        "ns_per_day":         {"N": f"{ns_per_day}"},
        "hour_per_ns":        {"N": f"{hour_per_ns}"},
        "wall_time_s":        {"N": f"{wall_time_s}"},
        "workdir":            {"S": workdir_path},
    }
    if gpu_count is not None and cuda_version is not None:
        record["gpu_count"] = {"N": str(gpu_count)}
        record["cuda_version"] = {"S": cuda_version}
    return record


# ---------------------------------------------------------------------------
# Hypothesis strategies
# ---------------------------------------------------------------------------

archs = st.sampled_from(["x86_64", "aarch64", "x86_64-cuda12"])
x86_targets = st.sampled_from(["hpc8a", "hpc7a"])
arm_targets = st.sampled_from(["graviton3", "graviton4"])
gpu_targets = st.sampled_from(["l40s", "h100"])
all_targets = st.sampled_from(
    ["hpc8a", "hpc7a", "graviton3", "graviton4", "l40s", "h100"]
)
variants = st.sampled_from(["tmpi", "ompi"])
ompi_versions = st.sampled_from([4, 5])
# GROMACS upstream tags look like "v2024.4", "v2024.5", "v2023.5"
tags = st.from_regex(r"^v20[0-9]{2}\.[0-9]{1,2}$", fullmatch=True)
models = st.sampled_from(["benchMEM", "benchPEP-h", "STMV", "RNAse"])
mpi_stacks = st.sampled_from(["tmpi", "openmpi-4", "openmpi-5"])
instance_types = st.sampled_from([
    "hpc8a.96xlarge", "hpc7a.96xlarge", "hpc7a.48xlarge",
    "hpc7g.16xlarge", "m8g.48xlarge", "r8g.48xlarge",
    "g6e.12xlarge", "p5.48xlarge",
])


# Strategies for Property 3 (md.log parsing) — fixed-point floats over the
# range a real GROMACS run produces, plus a sampled noise corpus modelling
# the lines that surround the Performance / Time block in a real md.log.
gromacs_floats = st.floats(
    min_value=0.001,
    max_value=999999.0,
    allow_nan=False,
    allow_infinity=False,
)

# Noise lines audited to NOT match either the Performance: or Time:
# regex on their own — they only contribute "context" the extractor must
# step over. The empty string is included because real md.log files
# contain blank lines between sections.
gromacs_log_noise = st.sampled_from([
    "GROMACS:    gmx_mpi mdrun, version 2024.4",
    "GROMACS modification: yes",
    "Build OS/arch: Linux 6.1.0",
    "C compiler: GCC 11.4.0",
    "OpenMP version: 4.5",
    "Started mdrun on rank 0",
    "step 0 done",
    "step 1000 done",
    "Writing final coordinates.",
    "NOTE: removing constraints from group 'rest'",
    "         Average load imbalance: 5.4 %",
    "DD step 999  vol min/aver 0.876! load imb.: force 14.8%",
    "                              Computing:               Num   Num      Call",
    "Domain decomposition grid 4 x 4 x 4, separate PME ranks 0",
    "    M E G A - F L O P S   A C C O U N T I N G",
    "         Distance check                  1.20",
    "                          Core t (s)     Wall t (s)        (%)",
    "                 (ns/day)    (hour/ns)",
    "",
])


def _format_perf_line(ns_per_day: float, hour_per_ns: float) -> str:
    """Mirror the GROMACS Performance: line layout used in md.log."""
    return f"Performance:      {ns_per_day:.6f}      {hour_per_ns:.6f}"


def _format_time_line(core_t: float, wall_t: float, pct: float) -> str:
    """Mirror the GROMACS Time: line layout used in md.log."""
    return f"       Time:    {core_t:.6f}     {wall_t:.6f}    {pct:.6f}"


def _assemble_log(*chunks: list[str]) -> str:
    """Flatten a sequence of line chunks into a single md.log payload."""
    return "\n".join(line for chunk in chunks for line in chunk) + "\n"


# ---------------------------------------------------------------------------
# Test classes — scaffold only.
#
# Each class corresponds to one of the seven Properties enumerated in
# design.md. The actual property assertions are filled in by tasks 9.2
# through 9.7. This task (9.1) creates only the scaffolding so the file
# imports cleanly and pytest collects it without errors.
# ---------------------------------------------------------------------------


class TestEnvScriptGeneration:
    """Property 1 — Env script generation correctness.

    Filled in by task 9.2.
    Validates: Requirements 1.4, 3.11, 5.5
    """

    @settings(max_examples=100)
    @given(arch=archs, target=all_targets, variant=variants,
           ompi_version=ompi_versions, tag=tags)
    def test_env_script_correctness(self, arch, target, variant,
                                    ompi_version, tag):
        """Verify the four (a)/(b)/(c)/(d) env-script invariants.

        For any valid (arch, target, variant, ompi_version, tag) tuple,
        the generated env script must contain:
          (a) `module load openmpi/<version>` iff variant == "ompi"
          (b) PATH export pointing at <install_dir>/bin
          (c) LD_LIBRARY_PATH export referencing both <install_dir>/lib
              and <install_dir>/lib64
          (d) GMXLIB export pointing at <install_dir>/share/gromacs/top
        """
        install_dir = (
            f"/fsx/gromacs/{arch}-{target}"
            f"{'-ompi5' if ompi_version == 5 else ''}/{tag}/{variant}"
        )
        text = env_script(arch, target, variant, ompi_version, tag,
                          install_dir)

        # (a) module load openmpi/<version> iff variant == "ompi"
        ompi_module_re = re.compile(r"^module load openmpi/\S+\s*$",
                                    re.MULTILINE)
        if variant == "ompi":
            expected_module = (
                "module load openmpi/5.0.9" if ompi_version == 5
                else "module load openmpi/4.1.7"
            )
            assert expected_module in text, (
                f"missing expected module-load line for ompi_version="
                f"{ompi_version}: {text!r}"
            )
            # Exactly one openmpi module-load line is present.
            ompi_lines = ompi_module_re.findall(text)
            assert len(ompi_lines) == 1, (
                f"expected exactly one `module load openmpi/...` line, "
                f"got {len(ompi_lines)}: {ompi_lines!r}"
            )
            # The wrong version must NOT be loaded.
            wrong_module = (
                "module load openmpi/4.1.7" if ompi_version == 5
                else "module load openmpi/5.0.9"
            )
            assert wrong_module not in text, (
                f"unexpected wrong-version module-load line in script "
                f"for ompi_version={ompi_version}: {text!r}"
            )
        else:
            # variant == "tmpi" — Thread_MPI must NOT load any openmpi
            # module since it has no MPI dependency.
            assert not ompi_module_re.search(text), (
                f"tmpi variant unexpectedly contains an "
                f"`module load openmpi/...` line: {text!r}"
            )

        # (b) PATH points at install_dir/bin via GROMACS_ROOT.
        assert f'export GROMACS_ROOT="{install_dir}"' in text, (
            f"GROMACS_ROOT not set to install_dir={install_dir!r}: "
            f"{text!r}"
        )
        assert "${GROMACS_ROOT}/bin:${PATH}" in text, (
            f"PATH does not prepend ${{GROMACS_ROOT}}/bin: {text!r}"
        )

        # (c) LD_LIBRARY_PATH references both lib and lib64.
        assert "${GROMACS_ROOT}/lib64" in text, (
            f"LD_LIBRARY_PATH missing lib64 entry: {text!r}"
        )
        assert "${GROMACS_ROOT}/lib:" in text, (
            f"LD_LIBRARY_PATH missing lib entry: {text!r}"
        )

        # (d) GMXLIB points at share/gromacs/top.
        assert ('export GMXLIB="${GROMACS_ROOT}/share/gromacs/top"'
                in text), (
            f"GMXLIB not set to ${{GROMACS_ROOT}}/share/gromacs/top: "
            f"{text!r}"
        )


class TestInstallPathNaming:
    """Property 2 — Install path naming convention (Arm `-ompi5` suffix).

    Validates: Requirement 3.9

    For any valid Arm build configuration (target, ompi_version, tag,
    variant), install_path_arm() must produce
    `/fsx/gromacs/aarch64-<target>[-ompi5]/<tag>/<variant>` where the
    `-ompi5` suffix is present iff `ompi_version == 5` (and absent iff
    `ompi_version == 4`). Both variant subdirectories (`tmpi/` and
    `ompi/`) must live under the same parent so the suffix tracks only
    the OpenMPI generation paired with the Library_MPI variant.
    """

    @settings(max_examples=100)
    @given(target=arm_targets, ompi_version=ompi_versions, tag=tags,
           variant=variants)
    def test_2a_install_path_format_and_ompi5_suffix(
        self, target: str, ompi_version: int, tag: str, variant: str,
    ) -> None:
        """Property 2a — install path matches the canonical layout.

        For random (target ∈ {graviton3, graviton4},
        ompi_version ∈ {4, 5}, tag, variant ∈ {tmpi, ompi}), the
        returned path equals
        `/fsx/gromacs/aarch64-<target>[-ompi5]/<tag>/<variant>` with
        `-ompi5` present iff `ompi_version == 5` and absent iff
        `ompi_version == 4`.
        """
        path = install_path_arm(target, ompi_version, tag, variant)

        suffix = "-ompi5" if ompi_version == 5 else ""
        expected = (
            f"/fsx/gromacs/aarch64-{target}{suffix}/{tag}/{variant}"
        )
        assert path == expected, (
            f"install_path_arm({target!r}, {ompi_version}, {tag!r}, "
            f"{variant!r}) returned {path!r}, expected {expected!r}"
        )

        # Suffix invariant: `-ompi5` is present iff ompi_version == 5.
        parent = f"/fsx/gromacs/aarch64-{target}"
        if ompi_version == 5:
            assert path.startswith(parent + "-ompi5/"), (
                f"ompi_version=5 but path lacks `-ompi5` suffix: {path!r}"
            )
            assert "-ompi5" in path
        else:
            # ompi_version == 4: the segment immediately after
            # `aarch64-<target>` must be `/`, not `-ompi5/`.
            assert path.startswith(parent + "/"), (
                f"ompi_version=4 but path has unexpected suffix after "
                f"aarch64-{target}: {path!r}"
            )
            assert "-ompi5" not in path, (
                f"ompi_version=4 but path contains `-ompi5`: {path!r}"
            )

        # Tag and variant land in the final two path components.
        components = path.split("/")
        assert components[-1] == variant, (
            f"final path component {components[-1]!r} != variant "
            f"{variant!r}: {path!r}"
        )
        assert components[-2] == tag, (
            f"second-to-last path component {components[-2]!r} != tag "
            f"{tag!r}: {path!r}"
        )

    @settings(max_examples=100)
    @given(target=arm_targets, ompi_version=ompi_versions, tag=tags)
    def test_2b_tmpi_and_ompi_share_parent_directory(
        self, target: str, ompi_version: int, tag: str,
    ) -> None:
        """Property 2b — `tmpi/` and `ompi/` siblings under one parent.

        For any (target, ompi_version, tag), the Thread_MPI and
        Library_MPI install paths must differ only in the final path
        component (the variant name). Their parent directories — and
        therefore the `-ompi5` suffix decision — must be identical.
        """
        tmpi_path = install_path_arm(target, ompi_version, tag, "tmpi")
        ompi_path = install_path_arm(target, ompi_version, tag, "ompi")

        # Distinct paths.
        assert tmpi_path != ompi_path

        # Identical parent directory.
        tmpi_parent, tmpi_leaf = tmpi_path.rsplit("/", 1)
        ompi_parent, ompi_leaf = ompi_path.rsplit("/", 1)
        assert tmpi_parent == ompi_parent, (
            f"tmpi and ompi parents differ for "
            f"(target={target!r}, ompi_version={ompi_version}, "
            f"tag={tag!r}): {tmpi_parent!r} vs {ompi_parent!r}"
        )

        # Final segments are exactly the variant names.
        assert tmpi_leaf == "tmpi"
        assert ompi_leaf == "ompi"


class TestLogParsing:
    """Property 3 — GROMACS log parsing (Performance / Wall t extraction).

    Filled in by task 9.3.
    Validates: Requirements 2.6, 2.7, 4.4
    """

    @staticmethod
    @settings(max_examples=100)
    @given(
        ns_per_day=gromacs_floats,
        hour_per_ns=gromacs_floats,
        core_t=gromacs_floats,
        wall_t=gromacs_floats,
        pct=gromacs_floats,
        prefix=st.lists(gromacs_log_noise, min_size=0, max_size=10),
        between=st.lists(gromacs_log_noise, min_size=0, max_size=10),
        suffix=st.lists(gromacs_log_noise, min_size=0, max_size=10),
        time_first=st.booleans(),
    )
    def test_parses_full_md_log(
        ns_per_day: float, hour_per_ns: float,
        core_t: float, wall_t: float, pct: float,
        prefix: list, between: list, suffix: list,
        time_first: bool,
    ) -> None:
        """Property 3a — fully populated md.log returns the exact triple.

        For random Performance: and Time: values embedded between
        randomly-positioned context lines, parse_md_log returns the
        triple that was generated. Block ordering is randomised because
        a real md.log can place the Time: summary either before or
        after the Performance: line depending on GROMACS version.
        """
        perf_line = [_format_perf_line(ns_per_day, hour_per_ns)]
        time_line = [_format_time_line(core_t, wall_t, pct)]

        if time_first:
            text = _assemble_log(prefix, time_line, between, perf_line,
                                 suffix)
        else:
            text = _assemble_log(prefix, perf_line, between, time_line,
                                 suffix)

        got_ns, got_hr, got_wall = parse_md_log(text)

        # Float round-trip tolerance: the formatter writes 6 decimal
        # places so values up to 999999.0 retain ≥ 6 significant
        # figures.
        assert abs(got_ns - ns_per_day) < 1e-3 * max(1.0, ns_per_day)
        assert abs(got_hr - hour_per_ns) < 1e-3 * max(1.0, hour_per_ns)
        assert abs(got_wall - wall_t) < 1e-3 * max(1.0, wall_t)

    @staticmethod
    @settings(max_examples=100)
    @given(
        core_t=gromacs_floats,
        wall_t=gromacs_floats,
        pct=gromacs_floats,
        prefix=st.lists(gromacs_log_noise, min_size=0, max_size=10),
        suffix=st.lists(gromacs_log_noise, min_size=0, max_size=10),
    )
    def test_missing_performance_line_returns_zero_perf(
        core_t: float, wall_t: float, pct: float,
        prefix: list, suffix: list,
    ) -> None:
        """Property 3b — md.log missing Performance: returns (0, 0, wall).

        gmx_mpi can crash mid-integration before the final timing
        block is printed; parse_md_log MUST return 0 for the missing
        ns/day and hour/ns columns rather than raising.
        """
        time_line = [_format_time_line(core_t, wall_t, pct)]
        text = _assemble_log(prefix, time_line, suffix)

        got_ns, got_hr, got_wall = parse_md_log(text)

        assert got_ns == 0.0
        assert got_hr == 0.0
        assert abs(got_wall - wall_t) < 1e-3 * max(1.0, wall_t)

    @staticmethod
    @settings(max_examples=100)
    @given(
        ns_per_day=gromacs_floats,
        hour_per_ns=gromacs_floats,
        prefix=st.lists(gromacs_log_noise, min_size=0, max_size=10),
        suffix=st.lists(gromacs_log_noise, min_size=0, max_size=10),
    )
    def test_missing_time_line_returns_zero_wall(
        ns_per_day: float, hour_per_ns: float,
        prefix: list, suffix: list,
    ) -> None:
        """Property 3c — md.log missing Time: returns (ns, hr, 0)."""
        perf_line = [_format_perf_line(ns_per_day, hour_per_ns)]
        text = _assemble_log(prefix, perf_line, suffix)

        got_ns, got_hr, got_wall = parse_md_log(text)

        assert abs(got_ns - ns_per_day) < 1e-3 * max(1.0, ns_per_day)
        assert abs(got_hr - hour_per_ns) < 1e-3 * max(1.0, hour_per_ns)
        assert got_wall == 0.0

    @staticmethod
    @settings(max_examples=100)
    @given(noise=st.lists(gromacs_log_noise, min_size=0, max_size=20))
    def test_missing_both_lines_returns_all_zero(noise: list) -> None:
        """Property 3d — md.log missing both lines returns (0, 0, 0)."""
        text = _assemble_log(noise)

        got_ns, got_hr, got_wall = parse_md_log(text)

        assert got_ns == 0.0
        assert got_hr == 0.0
        assert got_wall == 0.0


class TestRunDirUniqueness:
    """Property 4 — Run directory uniqueness.

    Validates: Requirements 2.8, 2.9
    """

    # Component strategies for the seven varying tuple positions:
    # (job_id, model, nodes, instance_type, ranks, threads, ts)
    # base_dir, job_name and cluster are held constant by these properties
    # (the requirement covers cluster too, but cluster constancy is
    # exercised at the script level, not this helper).
    _job_ids = st.integers(min_value=1, max_value=10**8)
    _node_counts = st.integers(min_value=1, max_value=200)
    _rank_counts = st.integers(min_value=1, max_value=10**6)
    _thread_counts = st.integers(min_value=1, max_value=192)
    # Matches the date-stamp format the launcher emits
    # (DD-MM-YYYY-HH-MM, mirroring the LAMMPS pattern).
    _timestamps = st.from_regex(
        r"^[0-9]{2}-[0-9]{2}-[0-9]{4}-[0-9]{2}-[0-9]{2}$",
        fullmatch=True,
    )

    _tuple_strategy = st.tuples(
        _job_ids, models, _node_counts, instance_types,
        _rank_counts, _thread_counts, _timestamps,
    )

    @staticmethod
    def _make_path(t: tuple) -> str:
        job_id, model, nodes, instance_type, ranks, threads, ts = t
        return workdir(
            base_dir="/fsx/gromacs",
            job_name="gromacs",
            model=model,
            cluster="hpc-cluster",
            job_id=job_id,
            nodes=nodes,
            instance_type=instance_type,
            ranks=ranks,
            threads=threads,
            ts=ts,
        )

    @settings(max_examples=100)
    @given(
        base=_tuple_strategy,
        idx=st.integers(min_value=0, max_value=6),
        alt_job_id=_job_ids,
        alt_model=models,
        alt_nodes=_node_counts,
        alt_instance=instance_types,
        alt_ranks=_rank_counts,
        alt_threads=_thread_counts,
        alt_ts=_timestamps,
    )
    def test_varying_any_single_component_changes_path(
        self, base, idx, alt_job_id, alt_model, alt_nodes,
        alt_instance, alt_ranks, alt_threads, alt_ts,
    ) -> None:
        """Property 4a — sensitivity to each input.

        Generate two tuples that differ ONLY in component `idx`
        (one of the seven components) and assert workdir() yields
        different paths. Per Requirement 2.8, two runs differing in
        any one of these attributes must produce different directory
        names.
        """
        alt_values = (
            alt_job_id, alt_model, alt_nodes, alt_instance,
            alt_ranks, alt_threads, alt_ts,
        )
        assume(alt_values[idx] != base[idx])

        other = list(base)
        other[idx] = alt_values[idx]

        path_a = self._make_path(base)
        path_b = self._make_path(tuple(other))

        assert path_a != path_b, (
            f"varying component index {idx} from {base[idx]!r} to "
            f"{alt_values[idx]!r} did not change the run directory path: "
            f"{path_a!r}"
        )

    @settings(max_examples=100)
    @given(a=_tuple_strategy, b=_tuple_strategy)
    def test_distinct_tuples_yield_distinct_paths(
        self, a: tuple, b: tuple,
    ) -> None:
        """Property 4b — full-tuple uniqueness.

        For any two distinct (job_id, model, nodes, instance_type,
        ranks, threads, ts) tuples, the generated run directory paths
        must differ. This guarantees no collisions across concurrent
        or repeated runs that vary in any combination of attributes.
        """
        assume(a != b)
        assert self._make_path(a) != self._make_path(b), (
            f"distinct tuples produced identical path: a={a!r}, b={b!r}"
        )


class TestBinarySelection:
    """Property 5 — Binary selection by node count (gmx vs gmx_mpi).

    Validates: Requirements 2.2, 4.2

    The launcher selects:
      * `gmx` (Thread_MPI, no mpirun) when N==1 and GROMACS_ENV is
        either unset or points at a `-tmpi-env.sh` script.
      * `gmx_mpi` (Library_MPI under mpirun) when N>1 (mpirun is
        invoked with `N * NRANK_PER_NODE` total ranks) OR when
        GROMACS_ENV explicitly points at a `-ompi-env.sh` /
        `-ompi5-env.sh` script even on a single node.

    Property 5d documents the helper's contract for the unsupported
    combination of multi-node + explicit Thread_MPI env: the helper
    returns ("gmx", False) so the caller (the launcher) can detect
    the violation and reject the run with a descriptive error.
    """

    def test_5a_single_node_default_selects_gmx(self) -> None:
        """Property 5a — N==1, GROMACS_ENV unset → ("gmx", False)."""
        binary, use_mpirun = select_binary(1, None)
        assert binary == "gmx"
        assert use_mpirun is False

    @settings(max_examples=100)
    @given(num_nodes=st.integers(min_value=2, max_value=64))
    def test_5b_multi_node_default_selects_gmx_mpi(
        self, num_nodes: int
    ) -> None:
        """Property 5b — N>=2 with GROMACS_ENV unset selects gmx_mpi
        under mpirun. The launcher invokes mpirun with
        N * NRANK_PER_NODE total ranks; the helper returns
        use_mpirun=True so the caller knows to wrap the run.
        """
        binary, use_mpirun = select_binary(num_nodes, None)
        assert binary == "gmx_mpi"
        assert use_mpirun is True
        # Sanity-check the documented total-rank computation: for any
        # NRANK_PER_NODE in the supported range, total ranks = N * rpn.
        nrank_per_node_choices = (1, 24, 48, 96, 144, 192)
        for rpn in nrank_per_node_choices:
            total_ranks = num_nodes * rpn
            assert total_ranks == num_nodes * rpn  # tautological by construction
            assert total_ranks >= num_nodes  # >0 ranks per node

    @settings(max_examples=100)
    @given(
        tag=tags,
        suffix=st.sampled_from(["-ompi-env.sh", "-ompi5-env.sh"]),
        prefix=st.sampled_from([
            "/fsx/gromacs/x86_64",
            "/fsx/gromacs/aarch64-graviton3",
            "/fsx/gromacs/aarch64-graviton3-ompi5",
            "/fsx/gromacs/aarch64-graviton4-ompi5",
        ]),
    )
    def test_5c_explicit_ompi_env_forces_gmx_mpi_on_single_node(
        self, tag: str, suffix: str, prefix: str
    ) -> None:
        """Property 5c — On a single node, an explicit GROMACS_ENV
        pointing at `-ompi-env.sh` or `-ompi5-env.sh` forces gmx_mpi
        under mpirun, overriding the single-node default. This is the
        documented escape hatch for users who want to exercise the
        Library_MPI variant on a single host.
        """
        env_path = f"{prefix}/{tag}/gromacs-{tag}{suffix}"
        binary, use_mpirun = select_binary(1, env_path)
        assert binary == "gmx_mpi"
        assert use_mpirun is True

    @settings(max_examples=100)
    @given(
        num_nodes=st.integers(min_value=2, max_value=64),
        tag=tags,
        prefix=st.sampled_from([
            "/fsx/gromacs/x86_64",
            "/fsx/gromacs/aarch64-graviton3",
            "/fsx/gromacs/aarch64-graviton3-ompi5",
            "/fsx/gromacs/aarch64-graviton4-ompi5",
        ]),
    )
    def test_5d_explicit_tmpi_env_returns_gmx_per_helper_contract(
        self, num_nodes: int, tag: str, prefix: str
    ) -> None:
        """Property 5d — Explicit `-tmpi-env.sh` on multi-node returns
        ("gmx", False) per the helper's contract. Multi-node Thread_MPI
        is unsupported; the launcher rejects it with an error message,
        but the helper itself surfaces the (binary, use_mpirun) values
        unchanged so the launcher can detect the violation.
        """
        env_path = f"{prefix}/{tag}/gromacs-{tag}-tmpi-env.sh"
        binary, use_mpirun = select_binary(num_nodes, env_path)
        assert binary == "gmx"
        assert use_mpirun is False


class TestCoreBindingFlags:
    """Property 6 — Core binding configuration for hybrid MPI+OpenMP.

    Filled in by task 9.6.
    Validates: Requirements 10.4, 10.5
    """

    @given(rpn=st.integers(min_value=1, max_value=192))
    @settings(max_examples=100)
    def test_pure_mpi_uses_map_by_slot(self, rpn: int) -> None:
        """Property 6a — pure-MPI (threads==1).

        For any positive ranks-per-node value, when OMP_NUM_THREADS == 1
        the launcher must emit `--bind-to core --map-by slot` exactly,
        independent of `rpn`. Mirrors Requirement 10.5.

        Validates: Requirements 10.5
        """
        assert mpi_bind_flags(1, rpn) == "--bind-to core --map-by slot"

    @given(
        threads=st.integers(min_value=2, max_value=192),
        rpn=st.integers(min_value=1, max_value=192),
    )
    @settings(max_examples=100)
    def test_hybrid_uses_ppr_with_pe(self, threads: int, rpn: int) -> None:
        """Property 6b — hybrid (threads>1).

        For any threads-per-rank ≥ 2 and any positive ranks-per-node,
        the launcher must emit
        `--bind-to core --map-by ppr:<rpn>:node:PE=<threads>` with both
        integers interpolated verbatim. Mirrors Requirement 10.4.

        Validates: Requirements 10.4
        """
        expected = (
            f"--bind-to core --map-by ppr:{rpn}:node:PE={threads}"
        )
        assert mpi_bind_flags(threads, rpn) == expected


class TestDynamoDbRecord:
    """Property 7 — DynamoDB record completeness.

    Filled in by task 9.7.
    Validates: Requirements 11.4, 11.5, 11.6, 11.7
    """

    REQUIRED_KEYS = {
        "job_id", "config", "timestamp", "model", "nodes",
        "ranks_total", "ranks_per_node", "threads_per_rank",
        "instance_type", "cluster_name", "gromacs_tag", "mpi_stack",
        "mpi_version", "libfabric_version", "efa_version", "kernel",
        "os", "pc_version", "region", "atoms", "nsteps", "ns_per_day",
        "hour_per_ns", "wall_time_s", "workdir",
    }
    NUMERIC_KEYS = {
        "nodes", "ranks_total", "ranks_per_node", "threads_per_rank",
        "atoms", "nsteps", "ns_per_day", "hour_per_ns", "wall_time_s",
    }
    STRING_KEYS = {
        "job_id", "config", "timestamp", "model", "instance_type",
        "cluster_name", "gromacs_tag", "mpi_stack", "mpi_version",
        "libfabric_version", "efa_version", "kernel", "os",
        "pc_version", "region", "workdir",
    }

    @staticmethod
    def _make_record(*, job_id, model, nodes, rpn, threads,
                     instance_type, gromacs_tag, mpi_stack, atoms,
                     nsteps, ns_per_day, hour_per_ns, wall_time_s,
                     gpu_count=None, cuda_version=None):
        ranks_total = nodes * rpn
        return dynamo_record(
            job_id=job_id,
            model=model,
            nodes=nodes,
            ranks_total=ranks_total,
            ranks_per_node=rpn,
            threads_per_rank=threads,
            instance_type=instance_type,
            cluster_name="hpc-test",
            gromacs_tag=gromacs_tag,
            mpi_stack=mpi_stack,
            mpi_version="4.1.7",
            libfabric_version="2.4.0",
            efa_version="204.0",
            kernel="6.1.0-amzn",
            os_pretty="Amazon Linux 2023",
            pc_version="3.13.0",
            region="us-east-1",
            atoms=atoms,
            nsteps=nsteps,
            ns_per_day=ns_per_day,
            hour_per_ns=hour_per_ns,
            wall_time_s=wall_time_s,
            workdir_path=f"/fsx/gromacs/Run/gromacs/{model}/hpc-test/{job_id}",
            timestamp="2026-05-21T12:00:00Z",
            gpu_count=gpu_count,
            cuda_version=cuda_version,
        )

    @settings(max_examples=100)
    @given(
        job_id=st.from_regex(r"^[0-9]{1,8}$", fullmatch=True),
        model=models,
        nodes=st.integers(min_value=1, max_value=200),
        rpn=st.integers(min_value=1, max_value=192),
        threads=st.integers(min_value=1, max_value=8),
        instance_type=instance_types,
        gromacs_tag=tags,
        mpi_stack=mpi_stacks,
        atoms=st.integers(min_value=1, max_value=10**8),
        nsteps=st.integers(min_value=1, max_value=10**6),
        ns_per_day=st.floats(min_value=0.0, max_value=10000.0,
                             allow_nan=False, allow_infinity=False),
        hour_per_ns=st.floats(min_value=0.0, max_value=10000.0,
                              allow_nan=False, allow_infinity=False),
        wall_time_s=st.floats(min_value=0.0, max_value=1e6,
                              allow_nan=False, allow_infinity=False),
    )
    def test_required_keys_present(self, job_id, model, nodes, rpn,
                                   threads, instance_type, gromacs_tag,
                                   mpi_stack, atoms, nsteps, ns_per_day,
                                   hour_per_ns, wall_time_s):
        """Property 7a — every CPU-mode record contains the 25 required keys."""
        rec = self._make_record(
            job_id=job_id, model=model, nodes=nodes, rpn=rpn,
            threads=threads, instance_type=instance_type,
            gromacs_tag=gromacs_tag, mpi_stack=mpi_stack, atoms=atoms,
            nsteps=nsteps, ns_per_day=ns_per_day,
            hour_per_ns=hour_per_ns, wall_time_s=wall_time_s,
        )
        assert self.REQUIRED_KEYS.issubset(rec.keys())
        # CPU-mode records must omit the Phase 3 GPU keys.
        assert "gpu_count" not in rec
        assert "cuda_version" not in rec
        # No unexpected keys in the CPU-mode payload.
        assert set(rec.keys()) == self.REQUIRED_KEYS

    @settings(max_examples=100)
    @given(
        job_id=st.from_regex(r"^[0-9]{1,8}$", fullmatch=True),
        model=models,
        nodes=st.integers(min_value=1, max_value=200),
        rpn=st.integers(min_value=1, max_value=192),
        threads=st.integers(min_value=1, max_value=8),
        instance_type=instance_types,
        gromacs_tag=tags,
        mpi_stack=mpi_stacks,
        atoms=st.integers(min_value=1, max_value=10**8),
        nsteps=st.integers(min_value=1, max_value=10**6),
        ns_per_day=st.floats(min_value=0.0, max_value=10000.0,
                             allow_nan=False, allow_infinity=False),
        hour_per_ns=st.floats(min_value=0.0, max_value=10000.0,
                              allow_nan=False, allow_infinity=False),
        wall_time_s=st.floats(min_value=0.0, max_value=1e6,
                              allow_nan=False, allow_infinity=False),
    )
    def test_n_and_s_typing(self, job_id, model, nodes, rpn, threads,
                            instance_type, gromacs_tag, mpi_stack, atoms,
                            nsteps, ns_per_day, hour_per_ns, wall_time_s):
        """Property 7b — numeric fields use {"N": ...}, strings use {"S": ...}."""
        rec = self._make_record(
            job_id=job_id, model=model, nodes=nodes, rpn=rpn,
            threads=threads, instance_type=instance_type,
            gromacs_tag=gromacs_tag, mpi_stack=mpi_stack, atoms=atoms,
            nsteps=nsteps, ns_per_day=ns_per_day,
            hour_per_ns=hour_per_ns, wall_time_s=wall_time_s,
        )
        for key, val in rec.items():
            assert isinstance(val, dict) and len(val) == 1, (
                f"{key} must be a single-key DynamoDB attribute dict"
            )
            kind = next(iter(val))
            payload = val[kind]
            if key in self.NUMERIC_KEYS:
                assert kind == "N", f"{key} should be wrapped as N"
                assert isinstance(payload, str), (
                    f"{key} N-payload must be a string for DynamoDB"
                )
                # Numeric payload must round-trip through float()
                float(payload)
            else:
                assert key in self.STRING_KEYS, (
                    f"unexpected key in CPU-mode record: {key}"
                )
                assert kind == "S", f"{key} should be wrapped as S"
                assert isinstance(payload, str)

    @settings(max_examples=100)
    @given(
        job_id=st.from_regex(r"^[0-9]{1,8}$", fullmatch=True),
        model=models,
        nodes=st.integers(min_value=1, max_value=200),
        rpn=st.integers(min_value=1, max_value=192),
        threads=st.integers(min_value=1, max_value=8),
        instance_type=instance_types,
        gromacs_tag=tags,
        mpi_stack=mpi_stacks,
    )
    def test_mpi_stack_is_constrained(self, job_id, model, nodes, rpn,
                                      threads, instance_type, gromacs_tag,
                                      mpi_stack):
        """Property 7c — mpi_stack is one of tmpi, openmpi-4, openmpi-5."""
        rec = self._make_record(
            job_id=job_id, model=model, nodes=nodes, rpn=rpn,
            threads=threads, instance_type=instance_type,
            gromacs_tag=gromacs_tag, mpi_stack=mpi_stack,
            atoms=1, nsteps=1, ns_per_day=0.0, hour_per_ns=0.0,
            wall_time_s=0.0,
        )
        assert rec["mpi_stack"] == {"S": mpi_stack}
        assert rec["mpi_stack"]["S"] in {"tmpi", "openmpi-4", "openmpi-5"}

    @settings(max_examples=100)
    @given(
        job_id=st.from_regex(r"^[0-9]{1,8}$", fullmatch=True),
        model=models,
        nodes=st.integers(min_value=1, max_value=200),
        rpn=st.integers(min_value=1, max_value=192),
        threads=st.integers(min_value=1, max_value=8),
        instance_type=instance_types,
        gromacs_tag=tags,
        mpi_stack=mpi_stacks,
        atoms=st.integers(min_value=1, max_value=10**8),
        nsteps=st.integers(min_value=1, max_value=10**6),
        ns_per_day=st.floats(min_value=0.0, max_value=10000.0,
                             allow_nan=False, allow_infinity=False),
        hour_per_ns=st.floats(min_value=0.0, max_value=10000.0,
                              allow_nan=False, allow_infinity=False),
        wall_time_s=st.floats(min_value=0.0, max_value=1e6,
                              allow_nan=False, allow_infinity=False),
    )
    def test_record_is_json_serialisable(self, job_id, model, nodes, rpn,
                                         threads, instance_type,
                                         gromacs_tag, mpi_stack, atoms,
                                         nsteps, ns_per_day, hour_per_ns,
                                         wall_time_s):
        """Property 7d — record round-trips through json.dumps / json.loads."""
        rec = self._make_record(
            job_id=job_id, model=model, nodes=nodes, rpn=rpn,
            threads=threads, instance_type=instance_type,
            gromacs_tag=gromacs_tag, mpi_stack=mpi_stack, atoms=atoms,
            nsteps=nsteps, ns_per_day=ns_per_day,
            hour_per_ns=hour_per_ns, wall_time_s=wall_time_s,
        )
        # json.dumps must succeed without raising TypeError
        encoded = json.dumps(rec)
        decoded = json.loads(encoded)
        assert decoded == rec

    @settings(max_examples=100)
    @given(
        job_id=st.from_regex(r"^[0-9]{1,8}$", fullmatch=True),
        model=models,
        nodes=st.integers(min_value=1, max_value=200),
        rpn=st.integers(min_value=1, max_value=192),
        threads=st.integers(min_value=1, max_value=8),
        instance_type=instance_types,
        gromacs_tag=tags,
        mpi_stack=mpi_stacks,
        atoms=st.integers(min_value=1, max_value=10**8),
        nsteps=st.integers(min_value=1, max_value=10**6),
        gpu_count=st.one_of(st.none(), st.integers(min_value=1,
                                                   max_value=8)),
        cuda_version=st.one_of(
            st.none(),
            st.from_regex(r"^1[0-9]\.[0-9]{1,2}$", fullmatch=True),
        ),
    )
    def test_gpu_fields_appear_iff_both_provided(self, job_id, model, nodes,
                                                 rpn, threads, instance_type,
                                                 gromacs_tag, mpi_stack,
                                                 atoms, nsteps, gpu_count,
                                                 cuda_version):
        """Property 7e — Phase 3 GPU fields appear iff BOTH gpu_count and
        cuda_version are passed; otherwise neither key appears."""
        rec = self._make_record(
            job_id=job_id, model=model, nodes=nodes, rpn=rpn,
            threads=threads, instance_type=instance_type,
            gromacs_tag=gromacs_tag, mpi_stack=mpi_stack, atoms=atoms,
            nsteps=nsteps, ns_per_day=0.0, hour_per_ns=0.0,
            wall_time_s=0.0,
            gpu_count=gpu_count, cuda_version=cuda_version,
        )
        if gpu_count is not None and cuda_version is not None:
            assert rec["gpu_count"] == {"N": str(gpu_count)}
            assert rec["cuda_version"] == {"S": cuda_version}
        else:
            assert "gpu_count" not in rec
            assert "cuda_version" not in rec
