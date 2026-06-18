"""Property-based tests for the NAMD support feature.

Validates the universal correctness properties from
.kiro/specs/namd-support/design.md.

The shell scripts under apps/NAMD/ contain pure-function logic:
  * env-script string generation (the heredoc in build_namd_x86.sbatch)
  * NAMD stdout parsing for `Info: Benchmark time: ... <days/ns> days/ns`
    and `WallClock: <s>`, with days/ns -> ns/day = 1 / days_per_ns
  * MODEL validation (ApoA1 / STMV) and deck-cache reuse
  * GPU_COUNT validation (Phase 3)

We re-implement that logic in Python below and exercise it with
Hypothesis-generated inputs to verify the properties hold. The Python
helpers mirror what the shell scripts do so the property tests verify the
algorithm rather than the bash itself.

Run with:
    python -m pip install -r tests/requirements.txt
    python -m pytest tests/test_namd_properties.py -q

Validates: Requirements 2.6, 2.7, 1.4, 6.1, 6.2, 5.3
"""

from __future__ import annotations

import re
from textwrap import dedent

from hypothesis import assume, given, settings, strategies as st


# ---------------------------------------------------------------------------
# Pure-function helpers re-implemented from the sbatch / shell scripts
# ---------------------------------------------------------------------------


def env_script(version: str, install_dir: str, charm_arch: str,
               openmpi_module: str = "openmpi/4.1.7") -> str:
    """Mirror of the env-script heredoc in build_namd_x86.sbatch.

    Returns the full text the build script writes to
    `namd-<version>-x86-env.sh`. The script module-loads OpenMPI (so
    mpirun is on PATH) and libfabric-aws (EFA), exports NAMD_ROOT / PATH /
    LD_LIBRARY_PATH, and records NAMD_VERSION and the Charm++ arch.
    """
    return dedent(f"""\
        #!/bin/bash
        # NAMD {version} — x86_64 (Charm++ {charm_arch} over OpenMPI/EFA, AVX-512 via -march)
        module load {openmpi_module} libfabric-aws 2>/dev/null || true
        export NAMD_ROOT="{install_dir}"
        export PATH="${{NAMD_ROOT}}/bin:${{PATH}}"
        export LD_LIBRARY_PATH="${{NAMD_ROOT}}/lib:${{LD_LIBRARY_PATH:-}}"
        export NAMD_VERSION="{version}"
        export CHARM_ARCH="{charm_arch}"
        """)


# Mirrors the awk in namd-benchmark.sbatch:
#   DAYS_PER_NS = awk '/Benchmark time:/ { for (i..) if ($i=="days/ns")
#                       print $(i-1) }' | tail -1
#   WALLCLOCK   = awk '/^WallClock:/ {print $2}' | tail -1
_BENCH_RE = re.compile(r"Benchmark time:")
_WALL_RE = re.compile(r"^WallClock:\s+(?P<wall>\d+(?:\.\d+)?)", re.MULTILINE)


def parse_namd_output(text: str) -> tuple[float, float, float | None]:
    """Mirror of the NAMD performance parsing in namd-benchmark.sbatch.

    Returns (days_per_ns, ns_per_day, wallclock).

    days_per_ns is taken from the token immediately preceding the literal
    `days/ns` on the LAST `Benchmark time:` line. ns_per_day = 1 /
    days_per_ns (0 when days_per_ns <= 0). wallclock comes from the last
    `WallClock:` line ($2), or None if absent.

    Raises ValueError when no parseable `Benchmark time: ... days/ns` value
    exists — the script's `[ -n "${DAYS_PER_NS}" ] || fail` guard, i.e. it
    signals extraction failure rather than emitting a zero/sentinel.
    """
    days_per_ns: float | None = None
    for line in text.splitlines():
        if "Benchmark time:" not in line:
            continue
        toks = line.split()
        for i, tok in enumerate(toks):
            if tok == "days/ns" and i >= 1:
                try:
                    days_per_ns = float(toks[i - 1])  # keep LAST match
                except ValueError:
                    pass

    if days_per_ns is None:
        raise ValueError("no parseable 'Benchmark time: ... days/ns' value")

    ns_per_day = (1.0 / days_per_ns) if days_per_ns > 0 else 0.0

    wall: float | None = None
    wmatches = list(_WALL_RE.finditer(text))
    if wmatches:
        wall = float(wmatches[-1].group("wall"))

    return days_per_ns, ns_per_day, wall


SUPPORTED_MODELS = ("ApoA1", "STMV")


def model_is_valid(model: str) -> bool:
    """Mirror of the `case ${MODEL} in ApoA1|STMV)` guard."""
    return model in SUPPORTED_MODELS


def deck_needs_fetch(config_present_nonempty: bool) -> bool:
    """Mirror of `if [ ! -s "${CACHE_DIR}/${CONF}" ]` — fetch iff the cached
    config is absent or empty.
    """
    return not config_present_nonempty


def gpu_count_is_valid(gpu_count: int, detected_gpus: int) -> bool:
    """Mirror of the Phase 3 GPU_COUNT guard: integer in
    1..min(8, detected GPUs).
    """
    upper = min(8, detected_gpus)
    return 1 <= gpu_count <= upper


def workdir(base_dir: str, job_id: str, model: str, cluster: str,
            nodes: int, instance_type: str, ppn: int, stamp: str) -> str:
    """Mirror of the WORK construction in namd-benchmark.sbatch:

    ${BASE_DIR}/Run/<jobid>-<model>-<cluster>-<nodes>x<instance>-<ppn>ppn-<stamp>
    """
    return (
        f"{base_dir}/Run/{job_id}-{model}-{cluster}-"
        f"{nodes}x{instance_type}-{ppn}ppn-{stamp}"
    )


# ---------------------------------------------------------------------------
# Hypothesis strategies
# ---------------------------------------------------------------------------

namd_versions = st.from_regex(r"^3\.0\.[0-9]{1,2}$", fullmatch=True)
charm_archs = st.sampled_from([
    "mpi-linux-x86_64-smp",
    "mpi-linux-arm8-smp",
])
openmpi_modules = st.sampled_from(["openmpi/4.1.7", "openmpi5/5.0.9amzn1"])
models = st.sampled_from(["ApoA1", "STMV"])
bad_models = st.text(min_size=0, max_size=12).filter(
    lambda s: s not in SUPPORTED_MODELS
)
instance_types = st.sampled_from([
    "hpc8a.96xlarge", "hpc7a.96xlarge", "hpc7a.48xlarge",
    "hpc7g.16xlarge", "m8g.48xlarge",
])

# Fixed-point floats over the range a real NAMD run produces.
namd_floats = st.floats(
    min_value=0.0001, max_value=99999.0,
    allow_nan=False, allow_infinity=False,
)

# Context lines audited to NOT contain "Benchmark time:" or start with
# "WallClock:" so they only act as noise the parser must step over.
namd_log_noise = st.sampled_from([
    "Info: NAMD 3.0.2 for Linux-x86_64-MPI-smp",
    "Info: Built Tue Jun 17 14:25 2026",
    "Charm++> Running in SMP mode: 2 processes, 191 worker threads",
    "Info: Entering startup at 0.5 s, 800 MB of memory in use",
    "PERFORMANCE: 300 averaging 17.5 ns/day, 0.0049 sec/step",
    "Info: Initial time: 191 CPUs 0.0042 s/step 0.0495 days/ns 14962 MB",
    "ENERGY:     500    ... TEMP 298.0",
    "WRITING COORDINATES TO OUTPUT FILE AT STEP 500",
    "Info: useSync = 1 useProxySync = 0",
    "",
])


def _bench_line(days_per_ns: float, cpus: int = 191) -> str:
    """Mirror a real NAMD `Info: Benchmark time:` line layout."""
    return (
        f"Info: Benchmark time: {cpus} CPUs "
        f"{days_per_ns / 10:.6f} s/step {days_per_ns:.6f} days/ns "
        f"14962.3 MB memory"
    )


def _wall_line(wall: float) -> str:
    return f"WallClock: {wall:.6f}  CPUTime: {wall:.6f}  Memory: 14962.3 MB"


def _assemble(*chunks: list[str]) -> str:
    return "\n".join(line for chunk in chunks for line in chunk) + "\n"


# ---------------------------------------------------------------------------
# Property 1 — Benchmark-time parsing (days/ns -> ns/day)
# Validates: Requirements 2.6, 2.7, 4.3, 5.6
# ---------------------------------------------------------------------------


class TestBenchmarkTimeParsing:
    """Property 1 — days/ns extraction and ns/day conversion."""

    @settings(max_examples=200)
    @given(
        days_per_ns=namd_floats,
        wall=namd_floats,
        prefix=st.lists(namd_log_noise, min_size=0, max_size=10),
        between=st.lists(namd_log_noise, min_size=0, max_size=10),
        suffix=st.lists(namd_log_noise, min_size=0, max_size=10),
    )
    def test_parses_days_per_ns_and_converts(
        self, days_per_ns, wall, prefix, between, suffix,
    ) -> None:
        """For output with a Benchmark time line, the parser returns its
        days/ns value and ns_per_day = 1 / days_per_ns, plus WallClock.
        """
        text = _assemble(
            prefix, [_bench_line(days_per_ns)], between,
            [_wall_line(wall)], suffix,
        )
        got_days, got_ns, got_wall = parse_namd_output(text)

        assert abs(got_days - days_per_ns) < 1e-3 * max(1.0, days_per_ns)
        assert got_ns > 0
        assert abs(got_ns - 1.0 / days_per_ns) < 1e-3 * (1.0 / days_per_ns)
        assert got_wall is not None
        assert abs(got_wall - wall) < 1e-3 * max(1.0, wall)

    @settings(max_examples=100)
    @given(
        first=namd_floats, last=namd_floats,
        between=st.lists(namd_log_noise, min_size=0, max_size=8),
    )
    def test_uses_last_benchmark_line(self, first, last, between) -> None:
        """When several Benchmark time lines exist, the LAST one wins."""
        assume(abs(first - last) > 1e-3 * max(1.0, last))
        text = _assemble(
            [_bench_line(first)], between, [_bench_line(last)],
        )
        got_days, _got_ns, _ = parse_namd_output(text)
        assert abs(got_days - last) < 1e-3 * max(1.0, last)

    @settings(max_examples=100)
    @given(noise=st.lists(namd_log_noise, min_size=0, max_size=20))
    def test_missing_benchmark_line_raises(self, noise) -> None:
        """Output with no Benchmark time line signals extraction failure
        rather than returning a zero/sentinel value.
        """
        text = _assemble(noise)
        try:
            parse_namd_output(text)
        except ValueError:
            return
        raise AssertionError("expected ValueError for missing Benchmark line")

    @settings(max_examples=100)
    @given(
        days_per_ns=namd_floats,
        prefix=st.lists(namd_log_noise, min_size=0, max_size=8),
    )
    def test_missing_wallclock_returns_none(self, days_per_ns, prefix) -> None:
        """A Benchmark line with no WallClock line still parses days/ns,
        returning None for the missing wallclock.
        """
        text = _assemble(prefix, [_bench_line(days_per_ns)])
        got_days, got_ns, got_wall = parse_namd_output(text)
        assert abs(got_days - days_per_ns) < 1e-3 * max(1.0, days_per_ns)
        assert got_ns > 0
        assert got_wall is None


# ---------------------------------------------------------------------------
# Property 2 — Env script generation correctness
# Validates: Requirements 1.4, 3.5
# ---------------------------------------------------------------------------


class TestEnvScriptGeneration:
    """Property 2 — the generated env script carries the four invariants."""

    @settings(max_examples=100)
    @given(version=namd_versions, charm_arch=charm_archs,
           openmpi_module=openmpi_modules)
    def test_env_script_invariants(self, version, charm_arch,
                                   openmpi_module) -> None:
        install_dir = f"/fsx/namd/x86_64/{version}"
        text = env_script(version, install_dir, charm_arch, openmpi_module)

        # (a) libfabric-aws (EFA) module load present.
        assert re.search(r"^module load .*\blibfabric-aws\b", text,
                         re.MULTILINE), text
        # OpenMPI module also loaded so mpirun is on PATH.
        assert openmpi_module in text, text

        # (b) PATH prepends the install bin (where namd3 lives).
        assert f'export NAMD_ROOT="{install_dir}"' in text, text
        assert "${NAMD_ROOT}/bin:${PATH}" in text, text

        # (c) LD_LIBRARY_PATH references the install lib dir.
        assert "${NAMD_ROOT}/lib:" in text, text

        # (d) Charm++ arch recorded.
        assert f'export CHARM_ARCH="{charm_arch}"' in text, text
        assert f'export NAMD_VERSION="{version}"' in text, text


# ---------------------------------------------------------------------------
# Property 3 — Model validation and deck-cache reuse
# Validates: Requirements 2.14, 6.1, 6.2, 6.4
# ---------------------------------------------------------------------------


class TestModelAndDeckCache:
    """Property 3 — MODEL gating and deck-cache reuse."""

    @settings(max_examples=50)
    @given(model=models)
    def test_supported_models_accepted(self, model) -> None:
        assert model_is_valid(model) is True

    @settings(max_examples=200)
    @given(model=bad_models)
    def test_unsupported_models_rejected(self, model) -> None:
        assert model_is_valid(model) is False

    @settings(max_examples=50)
    @given(present=st.booleans())
    def test_cache_reuse_skips_fetch(self, present) -> None:
        """A present, non-empty cached config means no network fetch;
        a missing/empty one triggers a fetch.
        """
        assert deck_needs_fetch(present) is (not present)


# ---------------------------------------------------------------------------
# Property 4 — GPU_COUNT validation (Phase 3)
# Validates: Requirements 5.3
# ---------------------------------------------------------------------------


class TestGpuCountValidation:
    """Property 4 — GPU_COUNT must be an integer in 1..min(8, detected)."""

    @settings(max_examples=200)
    @given(
        gpu_count=st.integers(min_value=-4, max_value=20),
        detected=st.integers(min_value=1, max_value=16),
    )
    def test_gpu_count_range(self, gpu_count, detected) -> None:
        upper = min(8, detected)
        expected = 1 <= gpu_count <= upper
        assert gpu_count_is_valid(gpu_count, detected) is expected


# ---------------------------------------------------------------------------
# Run-directory uniqueness (supporting property for the launcher)
# ---------------------------------------------------------------------------


class TestRunDirUniqueness:
    """Two runs differing in any naming component get distinct workdirs."""

    _job_ids = st.from_regex(r"^[0-9]{1,8}$", fullmatch=True)
    _node_counts = st.integers(min_value=1, max_value=200)
    _ppn_counts = st.integers(min_value=1, max_value=192)
    _stamps = st.from_regex(
        r"^[0-9]{8}T[0-9]{6}Z$", fullmatch=True,
    )

    _tuple = st.tuples(
        _job_ids, models, _node_counts, instance_types, _ppn_counts, _stamps,
    )

    @staticmethod
    def _make(t: tuple) -> str:
        job_id, model, nodes, instance_type, ppn, stamp = t
        return workdir(
            base_dir="/fsx/namd", job_id=job_id, model=model,
            cluster="cluster", nodes=nodes, instance_type=instance_type,
            ppn=ppn, stamp=stamp,
        )

    @settings(max_examples=100)
    @given(
        base=_tuple,
        idx=st.integers(min_value=0, max_value=5),
        alt_job=_job_ids, alt_model=models, alt_nodes=_node_counts,
        alt_instance=instance_types, alt_ppn=_ppn_counts, alt_stamp=_stamps,
    )
    def test_varying_any_component_changes_path(
        self, base, idx, alt_job, alt_model, alt_nodes, alt_instance,
        alt_ppn, alt_stamp,
    ) -> None:
        alts = (alt_job, alt_model, alt_nodes, alt_instance, alt_ppn,
                alt_stamp)
        assume(alts[idx] != base[idx])
        other = list(base)
        other[idx] = alts[idx]
        assert self._make(base) != self._make(tuple(other))
