# Ansys Fluent benchmarking — the 2026 R1 method (MIUPS)

Starting with **Ansys 2026 R1 (v261)**, Ansys ships a single Python benchmark
harness that is the **go-forward way** to run Fluent benchmarks, for both GPU
and CPU solvers:

```
<fluent_root>/fluent/bench/bin/fluent_benchmark_gpu.py
```

Despite the `gpu` in the file name it is **not** GPU-only:

| Invocation | Solver benchmarked |
|------------|--------------------|
| harness **with** `-gpu`  | GPU solver (see [`gpu/Fluent-Benchmark-GPU.sbatch`](gpu/Fluent-Benchmark-GPU.sbatch)) |
| harness **without** `-gpu` | CPU solver (see [`x86/Fluent-Benchmark.2026R1.sbatch`](x86/Fluent-Benchmark.2026R1.sbatch)) |

The harness reads the case, runs a warm-up, then a fixed number of timed
iterations driven by its bundled journal (`fluent_benchmark_gpu.jou`), and
reports results per case.

## The headline metric: MIUPS

The new method standardises on **MIUPS — Million Cell Iterations per Wall
Second** (higher is faster). Each case writes a transcript
`<case>-<cores>.trn` under `working/<tag>/transcript/` containing:

```
Million Cell Iteration Per Wall Second =  <MIUPS>
Average wall-clock time per case input:   <sec>
Average wall-clock time per data input:   <sec>
```

and prints a scaling summary to stdout:

```
NumProc    MIUPS      Speedup     Efficiency
--------------------------------------------
192        <miups>    <speedup>   <eff>%
```

MIUPS relates to the classic per-iteration wall time by the mesh size:

```
time_per_iteration_seconds = num_cells_million / MIUPS
```

So a 140M-cell case at a MIUPS of `<miups>` takes 140 / `<miups>` seconds per iteration.

## Running the CPU benchmark

```bash
sbatch x86/Fluent-Benchmark.2026R1.sbatch [fluent_version] [benchmark_uri]
```

- `fluent_version` — Ansys version dir under `$ANSYS_ROOT/ansys_inc` (default `v261`).
- `benchmark_uri` — `s3://bucket/<case>.tar`, a local `<case>.tar`, or leave the
  default to use a case that already ships with the install (the harness finds
  it under `<fluent>/bench/fluent/v6/<BENCHMARK_NAME>/cas_dat`).

Useful environment knobs (all optional):

| Variable | Meaning |
|----------|---------|
| `BENCHMARK_NAME` | case id (default `f1_racecar_140m`) |
| `ITERATIONS` | timed iterations, time steps for a transient case (default 25; the harness's own default is 200) |
| `WARMUP_ITERATIONS` | warm-up iterations, time steps for a transient case, which the harness runs twice (default 10; the harness's own default is 50) |
| `SOLVER` | `segregated` \| `coupled` (blank → case default) |
| `EXTRA_FLUENT_ARGS` | extra raw Fluent flags, e.g. `3ddp` |
| `ANSYSLMD_LICENSE_FILE` | `port@host` of your Ansys license server |
| `SOURCE` | tag your DynamoDB benchmark contributions |

The CPU script's defaults are the protocol of its results under
[Performance](Readme.md#performance): 10 warm-up iterations, which the
harness runs twice, then 25 timed iterations (both counts are time steps for
a transient case), so a run at the defaults compares with those results as
it is. Set `ITERATIONS` and `WARMUP_ITERATIONS` to run another protocol, for
example the harness's own 200 and 50.

The CPU script records `ITERATIONS` (or 25) as `num_iterations`,
`WARMUP_ITERATIONS` (or 10), the setting the harness runs twice, as
`warmup_iterations`, and the iterations the harness timed, from the
`Number of Iterations` line of its transcript, as `timed_iterations`: for a
steady case the same as `num_iterations`, for a transient case every
iteration of its timed time steps.

Example — a CPU run of the shipped 140M case on one hpc8a node, at the
script's defaults:

```bash
BENCHMARK_NAME=f1_racecar_140m \
ANSYSLMD_LICENSE_FILE=1055@your.license.server \
sbatch -N1 --ntasks=192 --constraint=hpc8a.96xlarge \
    x86/Fluent-Benchmark.2026R1.sbatch v261 shipped
```

On `hpc8a.96xlarge` and `hpc7a.96xlarge` the script runs only at 24, 48, 72,
96, 120, 144, 168 or 192 ranks per node, and stops before Fluent starts at any
other count: see
[Cores per node (flexible cores)](Readme.md#cores-per-node-flexible-cores),
which also says what it does when the instance metadata gives no instance
type.

## Automatic benchmark recording

Both the CPU and GPU launch scripts call
[`dynamodb/record-benchmark.sh`](dynamodb/record-benchmark.sh) automatically
right after the solve (non-fatal, never changes the job's exit status). The
recorder parses the transcript, records **MIUPS**, the case/data read times and
the derived per-iteration time, and tags the row with `benchmark_method` and
`solver_mode` (`cpu`/`gpu`). Set `SOURCE=<YourOrg>` to attribute your rows. See
[../BENCHMARK-RECORDERS.md](../BENCHMARK-RECORDERS.md) for the full contribution
workflow.

The CPU script records a run only when the harness's transcript of the case
and core count, `working/<tag>/transcript/<case>-<cores>.trn`, gives the
case's rating: a positive number on its
`Million Cell Iteration Per Wall Second =` line, which the recorder then gets
as MIUPS. Otherwise the job output has a NOTE that names that transcript, and
nothing is recorded.

## Classic method (pre-2026 R1)

The classic `fluentbench.pl` harness (reported *Solver rating* / *Solver wall
time per iteration* / *Solver speed*) is still available via
[`x86/Fluent-Benchmark.OMPI.sbatch`](x86/Fluent-Benchmark.OMPI.sbatch). The
recorder understands both formats, so existing workflows keep working.

The classic scripts,
[`x86/Fluent-Benchmark.IMPI.sbatch`](x86/Fluent-Benchmark.IMPI.sbatch),
[`x86/Fluent-Benchmark.OMPI.sbatch`](x86/Fluent-Benchmark.OMPI.sbatch) and
[`Arm/Fluent-benchmark.sbatch`](Arm/Fluent-benchmark.sbatch), record a run
only when `fluentbench.pl`'s output of the case and core count,
`<case>-<cores>.out` in the run directory, gives the case's rating: a positive
number on its `Solver rating =` line. The recorder then gets that rating, and
that file's time per iteration and solver speed. Otherwise the job output has
a NOTE that names that file, and nothing is recorded.
