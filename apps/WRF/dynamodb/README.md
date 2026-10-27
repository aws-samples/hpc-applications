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
    --case CONUS-2.5km --num-cells-million 90.135 --time-to-solution 1200 \
    --source YourOrg
```

For WRF, `--num-cells-million` captures the grid size: domain 1's
`e_we × e_sn × e_vert` from `namelist.input`, in millions (CONUS 2.5km:
1501 × 1201 × 50 = 90.135). `--analysis-type` gives the run type (e.g.
forecast/idealized). The benchmark scripts in this folder's parent pass the
grid size as `--num-cells-million`, and the simulated minutes, the number of
time steps and the history output's `io_form` as `--char` values, read from
the run directory ([`../lib/wrf-run-info.sh`](../lib/wrf-run-info.sh)).
Preview with `--dry-run`; see every option with `./record-benchmark.sh --help`.
