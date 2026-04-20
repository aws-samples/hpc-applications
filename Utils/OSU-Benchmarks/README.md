# OSU Micro-Benchmarks

The [OSU Micro-Benchmarks](https://mvapich.cse.ohio-state.edu/benchmarks/) (OMB) are a widely used suite for evaluating MPI performance. They measure point-to-point latency, bandwidth, and collective operation performance, making them ideal for validating EFA and MPI configurations on HPC clusters.

This directory contains build scripts and Slurm job scripts for running OSU Micro-Benchmarks with both OpenMPI and IntelMPI.

## Build

Two build scripts are provided, one per MPI implementation. Run the appropriate script from the head-node (or a login node with access to `/fsx`):

**OpenMPI:**

```bash
bash build_osu_benchmarks_openmpi.sh
```

Installs to `/fsx/OSU-Benchmark-OpenMPI/install`.

**Intel MPI:**

```bash
bash build_osu_benchmarks_intelmpi.sh
```

Installs to `/fsx/OSU-Benchmark-IntelMPI/install`.

Both scripts download OSU Micro-Benchmarks v8.0b2, compile, and install them to the shared filesystem.

## Run

Submit the benchmark job matching your MPI build:

**OpenMPI:**

```bash
sbatch osu_benchmarks_openmpi.sbatch
```

**Intel MPI:**

```bash
sbatch osu_benchmarks_intelmpi.sbatch
```

Both jobs are configured to run on 2 `hpc8a.96xlarge` nodes in the `hpc8a` partition. Edit the `#SBATCH` directives to target a different instance type or partition.

## What Gets Tested

Each job runs three benchmarks:

- **osu_latency** — Point-to-point latency between two processes on different nodes
- **osu_bw** / **osu_mbw_mr** — Bandwidth (single-pair or multi-pair)
- **osu_allreduce** — Collective allreduce performance

## Customization

- To change the target instance type, update the `--constraint` and `--partition` SBATCH directives
- To run additional benchmarks, add `mpirun` commands pointing to other binaries under `${OSU_DIR}/pt2pt/` or `${OSU_DIR}/collective/`
- To test with more processes, adjust `-np` and `-ppn` / `-npernode` flags
