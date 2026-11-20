# NAMD

This directory holds scripts that build [NAMD](https://www.ks.uiuc.edu/Research/namd/) from source and run its
standard benchmarks on AWS HPC instances. NAMD is a parallel molecular dynamics code from the University of Illinois
Urbana-Champaign, designed for large biomolecular systems. It runs on the [Charm++](https://charm.cs.illinois.edu/)
parallel runtime rather than on MPI directly.

The scripts in [`x86/`](x86/) build and run NAMD 3.0 on x86_64 instances: hpc8a.96xlarge and hpc7a.96xlarge.

## How the scripts run NAMD

Charm++ has several network layers (`netlrts`, `mpi`, `ucx`, `ofi`, `verbs`, `multicore`). The build uses its `mpi`
layer on top of the system Open MPI, which carries the traffic between nodes over EFA through its libfabric provider.
It builds the SMP variant of that layer (`mpi-linux-x86_64-smp`): each NAMD process runs `PPN` worker threads (PEs)
and one communication thread. The launcher starts one process per node, so each node runs `PPN` + 1 threads. A run on
one node uses the same binary, as a single process.

## Build

> **The NAMD source requires accepting a licence.** NAMD's source tarball is distributed from the
> [NAMD download page](https://www.ks.uiuc.edu/Research/namd/) behind a licence agreement, so the build script cannot
> fetch it. Download `NAMD_<version>_Source.tar.gz` once, accepting the licence, and place it at `${BASE_DIR}/src/`
> (default `/fsx/namd/src/`), or set `NAMD_SRC` to its path. This repository does not redistribute NAMD.

```bash
# After staging /fsx/namd/src/NAMD_3.0.2_Source.tar.gz
sbatch x86/build_namd_x86.sbatch
```

The build script:

1. installs the compilers, `make` and TCL's headers with `dnf` (through `sudo`);
2. builds FFTW as a static, single-precision library inside the install, so `namd3` needs no FFTW library on the
   compute nodes;
3. builds the Charm++ that ships with the NAMD source (`mpi-linux-x86_64 smp --with-production`), with
   `-O3 -march=x86-64-v4 -mtune=znver4`, against the Open MPI module;
4. configures NAMD for that Charm++, the system TCL and the static FFTW, and compiles it with the options of NAMD's
   `Linux-x86_64-g++` arch file (`-O3 -fexpensive-optimizations -ffast-math`);
5. installs `namd3` under `${BASE_DIR}/x86_64/<version>/`, with an env script, `namd-<version>-x86-env.sh`, that loads
   the Open MPI and `libfabric-aws` modules and puts `namd3` on the `PATH`.

One build serves hpc8a.96xlarge and hpc7a.96xlarge. The script never overwrites an install: remove
`${BASE_DIR}/x86_64/<version>/` to build again.

| Variable | Default | Description |
|---|---|---|
| `NAMD_VERSION` | `3.0.2` | NAMD release (with the Charm++ it bundles) |
| `TARGET_CPU` | `hpc8a` | `hpc8a` or `hpc7a` |
| `BASE_DIR` | `/fsx/namd` | Install root |
| `COMPILE_CORES` | `48` | Parallel build jobs |
| `NAMD_SRC` | `${BASE_DIR}/src/NAMD_${NAMD_VERSION}_Source.tar.gz` | The staged source tarball |
| `NAMD_SRC_URL` | none | A private mirror to fetch the source from when it is not staged |
| `OPENMPI_MODULE` | `openmpi/4.1.7` | The Open MPI module Charm++ is built against and the env script loads |
| `FFTW_VERSION` | `3.3.10` | FFTW release, fetched from fftw.org unless `${BASE_DIR}/src/fftw-<version>.tar.gz` exists |

## Run

```bash
# ApoA1 on one node
sbatch --nodes=1 x86/namd-benchmark.sbatch

# STMV on four nodes, over EFA
sbatch --nodes=4 --export=ALL,MODEL=STMV x86/namd-benchmark.sbatch

# ApoA1 on one hpc7a.96xlarge
sbatch -p hpc7a -C hpc7a.96xlarge x86/namd-benchmark.sbatch
```

The launcher:

1. sources the build's env script;
2. on more than one node, checks EFA with `fi_info -p efa`;
3. fetches the deck into a cache on first use, and copies it into a run directory of its own,
   `${BASE_DIR}/Run/<job>-<MODEL>-<cluster>-<nodes>x<instance type>-<PPN>ppn-<UTC time>/`;
4. drops the page cache and enables transparent huge pages on every node, where `sudo` allows it;
5. starts `namd3` with `mpirun`: one process per node, with `+ppn PPN` worker threads and `+setcpuaffinity`. On more
   than one node, Open MPI sends its traffic over EFA (`--mca pml cm --mca mtl ofi`, `FI_PROVIDER=efa`).

| Variable | Default | Description |
|---|---|---|
| `NAMD_ENV` | the env script under `${BASE_DIR}/x86_64/*/` | The build's env script |
| `MODEL` | `ApoA1` | `ApoA1` or `STMV` |
| `TIMESTEPS` | the deck's | The run's `numsteps`, 1 to 10,000,000 |
| `PPN` | the node's CPUs − 1 | Worker threads (PEs) per node, 1 to 192 |
| `BASE_DIR` | `/fsx/namd` | Root of the deck cache and the run directories (an absolute path) |

## Benchmark models

| `MODEL` | System | Atoms | Steps in the deck |
|---|---|--:|--:|
| `ApoA1` | Apolipoprotein A1 | 92,224 | 500 |
| `STMV` | Satellite tobacco mosaic virus | 1,066,628 | 500 |

Both decks come from the [NAMD utilities page](https://www.ks.uiuc.edu/Research/namd/utilities/), with PME and a
time step of 1 fs. The launcher fetches each one on first use and keeps it at `${BASE_DIR}/benchmarks/<MODEL>/`; delete
that directory to fetch it again.

## Metrics

NAMD prints its speed while it runs, on lines of this form:

```
Info: Benchmark time: <CPUs> CPUs <s> s/step <d> days/ns <MB> MB memory
```

The launcher takes the days/ns of the last such line and reports ns/day = 1 / (days/ns), with NAMD's closing
`WallClock:` time. Its results block ends with one line that scripts can parse:

```
NAMDRESULT model=<MODEL> nodes=<nodes> ppn=<PPN> instance=<instance type> days_per_ns=<d> ns_per_day=<r> wallclock=<s>
```

## Checking a run

In the run directory's `namd.out`:

- `Charm++> Running in SMP mode: <n> processes, <PPN> worker threads (PEs) + 1 comm threads per process`: one process
  per node, with the `PPN` asked for;
- `Charm++> cpu affinity enabled.`: Charm++ binds the threads to cores.

On more than one node, the job's log shows the `fi_info` listing of provider `efa`.

## Files

| File | Description |
|---|---|
| [`x86/build_namd_x86.sbatch`](x86/build_namd_x86.sbatch) | Builds static FFTW, Charm++ (`mpi-linux-x86_64-smp`, on the system Open MPI) and NAMD; installs `namd3` and its env script |
| [`x86/namd-benchmark.sbatch`](x86/namd-benchmark.sbatch) | Runs ApoA1 or STMV with `mpirun`; fetches and caches the deck; reports days/ns and ns/day |
| [`tests/test_namd_launcher.py`](../../tests/test_namd_launcher.py), [`tests/test_namd_build.py`](../../tests/test_namd_build.py), [`tests/test_namd_properties.py`](../../tests/test_namd_properties.py) | Tests of the two scripts, with stubs only: no NAMD, MPI or Slurm needed |
