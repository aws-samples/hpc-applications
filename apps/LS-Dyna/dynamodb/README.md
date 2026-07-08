# LS-DYNA — Benchmark Result Recorder

`record-benchmark.sh` in this folder records **one** LS-DYNA benchmark run
(explicit structural dynamics / crash) into the shared AI-Powered HPC dataset
(Amazon DynamoDB), used to train a model that predicts HPC performance on AWS.
It is self-contained and **safe by default**: it always writes a local JSON
record and only writes to DynamoDB when you have write access (or pass `--put`).

**Full guide** — parameters, contribution workflow, `.sbatch` integration:
[../../BENCHMARK-RECORDERS.md](../../BENCHMARK-RECORDERS.md)

## Quick start

On a SLURM/EC2 node, right after your solve (instance type, OS, cores, nodes and
MPI are auto-detected):

```bash
./record-benchmark.sh \
    --case <benchmark-case> --time-to-solution <seconds> \
    --source YourOrg
```

See the LS-DYNA-specific metrics (model size / element count, analysis type)
with `./record-benchmark.sh --help`. Anything without a dedicated flag can be
added via `--metric name=value` (numbers) or `--char name=value` (strings).
Preview with `--dry-run`.
