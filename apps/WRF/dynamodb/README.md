# WRF — Benchmark Result Recorder

`record-benchmark.sh` in this folder records **one** WRF benchmark run
(numerical weather prediction) into the shared AI-Powered HPC dataset (Amazon
DynamoDB), used to train a model that predicts HPC performance on AWS. It is
self-contained and **safe by default**: it always writes a local JSON record and
only writes to DynamoDB when you have write access (or pass `--put`).

**Full guide** — parameters, contribution workflow, `.sbatch` integration:
[../../BENCHMARK-RECORDERS.md](../../BENCHMARK-RECORDERS.md)

## Quick start

On a SLURM/EC2 node, right after your run (instance type, OS, cores, nodes and
MPI are auto-detected):

```bash
./record-benchmark.sh \
    --case CONUS-2.5km --num-cells-million 1.8 --time-to-solution 1200 \
    --source YourOrg
```

For WRF, `--num-cells-million` captures the grid size (grid points, in
millions), and `--analysis-type` the run type (e.g. forecast/idealized).
Preview with `--dry-run`; see every option with `./record-benchmark.sh --help`.
