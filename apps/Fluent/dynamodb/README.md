# Ansys Fluent — Benchmark Result Recorder

`record-benchmark.sh` in this folder records **one** Ansys Fluent benchmark run
(CFD) into the shared AI-Powered HPC dataset (Amazon DynamoDB), used to train a
model that predicts HPC performance on AWS. It is self-contained and **safe by
default**: it always writes a local JSON record and only writes to DynamoDB when
you have write access (or pass `--put`).

**Full guide** — parameters, contribution workflow, `.sbatch` integration:
[../../BENCHMARK-RECORDERS.md](../../BENCHMARK-RECORDERS.md)

## Quick start

On a SLURM/EC2 node, right after your solve (instance type, OS, cores, nodes and
MPI are auto-detected):

```bash
./record-benchmark.sh \
    --case f1_racecar_140m --num-cells-million 140 \
    --time-per-iteration 0.42 --num-iterations 25 \
    --source YourOrg
```

Fluent-specific fields include `--num-cells-million`, `--time-per-iteration` +
`--num-iterations` (their product is used when `--time-to-solution` is omitted),
`--solver-rating`, `--solver-speed`, `--turbulence-model`, `--solver-type`,
`--analysis-type`, `--cell-type`. Preview with `--dry-run`; see every option
with `./record-benchmark.sh --help`.

### 2026 R1 method (MIUPS)

The recorder also understands the **2026 R1** benchmark harness
(`fluent_benchmark_gpu.py`, used for both CPU and GPU — see
[../Fluent-Benchmark-2026R1.md](../Fluent-Benchmark-2026R1.md)). Run zero-arg at
the end of a job (the launch scripts already do this) and it parses the
`<case>-<cores>.trn` transcript to record **`miups`** (Million Cell Iterations
per Wall Second), `case_read_seconds`, `data_read_seconds`, `benchmark_method`
and `solver_mode`. With the mesh size it also derives `time_per_iteration_seconds`
( = `num_cells_million` / `miups` ). New flags: `--miups`, `--case-read`,
`--data-read`, `--benchmark-method`, `--solver-mode`.
