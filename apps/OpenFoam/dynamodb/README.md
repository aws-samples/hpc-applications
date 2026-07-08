# OpenFOAM — Benchmark Result Recorder

`record-benchmark.sh` in this folder records **one** OpenFOAM benchmark run
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
    --case drivaer --mesh-cells-million 65 --time-to-solution 900 \
    --solver simpleFoam --source YourOrg
```

OpenFOAM-specific fields include `--mesh-cells-million`, `--solver` (e.g.
`simpleFoam`), `--turbulence-model`, `--solver-type`, `--analysis-type`. Preview
with `--dry-run`; see every option with `./record-benchmark.sh --help`.
