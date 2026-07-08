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
