# NAMD — Benchmark Result Recorder
`record-benchmark.sh` in this folder records **one** NAMD benchmark run (molecular
dynamics) into the shared AI-Powered HPC dataset (Amazon DynamoDB), used to train a
model that predicts HPC performance on AWS. It is self-contained and **safe by
default**: it always writes a local JSON record and only writes to DynamoDB when you
have write access (or pass `--put`).
**Full guide** — parameters, contribution workflow, `.sbatch` integration:
[../../BENCHMARK-RECORDERS.md](../../BENCHMARK-RECORDERS.md)
## Quick start
[`x86/namd-benchmark.sbatch`](../x86/namd-benchmark.sbatch) calls it after every
complete run. By hand, in a run directory, right after the run (instance type, OS,
cores, nodes and MPI are auto-detected, and the results come from `namd.out`):
```bash
./record-benchmark.sh --case STMV --source YourOrg
```
From `namd.out` it reads the last `Benchmark time:` line's days/ns (and ns/day =
1 / days/ns), NAMD's `WallClock:` time (`time_to_solution_seconds`), the atom count,
NAMD's version and platform, the number of steps and the time step. See every option
with `./record-benchmark.sh --help`. Anything without a dedicated flag can be added
via `--metric name=value` (numbers) or `--char name=value` (strings). Preview with
`--dry-run`.
