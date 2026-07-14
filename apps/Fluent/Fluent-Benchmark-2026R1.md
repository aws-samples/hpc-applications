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

So a 140M-cell case at MIUPS = 12.3 corresponds to ~11.4 s per iteration.

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
| `ITERATIONS` | timed iterations (blank → harness default 200) |
| `WARMUP_ITERATIONS` | warm-up iterations (blank → harness default 50) |
| `SOLVER` | `segregated` \| `coupled` (blank → case default) |
| `EXTRA_FLUENT_ARGS` | extra raw Fluent flags, e.g. `3ddp` |
| `ANSYSLMD_LICENSE_FILE` | `port@host` of your Ansys license server |
| `SOURCE` | tag your DynamoDB benchmark contributions |

Example — a short CPU run of the shipped 140M case on one hpc8a node:

```bash
ITERATIONS=20 WARMUP_ITERATIONS=5 BENCHMARK_NAME=f1_racecar_140m \
ANSYSLMD_LICENSE_FILE=1055@your.license.server \
sbatch -N1 --ntasks=192 --constraint=hpc8a.96xlarge \
    x86/Fluent-Benchmark.2026R1.sbatch v261 shipped
```

## Automatic benchmark recording

Both the CPU and GPU launch scripts call
[`dynamodb/record-benchmark.sh`](dynamodb/record-benchmark.sh) automatically
right after the solve (non-fatal, never changes the job's exit status). The
recorder parses the transcript, records **MIUPS**, the case/data read times and
the derived per-iteration time, and tags the row with `benchmark_method` and
`solver_mode` (`cpu`/`gpu`). Set `SOURCE=<YourOrg>` to attribute your rows. See
[../BENCHMARK-RECORDERS.md](../BENCHMARK-RECORDERS.md) for the full contribution
workflow.

## Classic method (pre-2026 R1)

The classic `fluentbench.pl` harness (reported *Solver rating* / *Solver wall
time per iteration* / *Solver speed*) is still available via
[`x86/Fluent-Benchmark.OMPI.sbatch`](x86/Fluent-Benchmark.OMPI.sbatch). The
recorder understands both formats, so existing workflows keep working.
