# NAMD

This directory holds scripts that build [NAMD](https://www.ks.uiuc.edu/Research/namd/) from source and run its
standard benchmarks on AWS HPC instances. NAMD is a parallel molecular dynamics code from the University of Illinois
Urbana-Champaign, designed for large biomolecular systems. It runs on the [Charm++](https://charm.cs.illinois.edu/)
parallel runtime rather than on MPI directly.

The scripts in [`x86/`](x86/) build and run NAMD 3.0 on x86_64 instances. The build has a target for each of these
instance families: hpc8a, hpc7a, m8a, c8i, r8i, hpc6id and hpc6a.

## How the scripts run NAMD

Charm++ has several network layers (`netlrts`, `mpi`, `ucx`, `ofi`, `verbs`, `multicore`). The build uses its `mpi`
layer on top of the system Open MPI, which carries the traffic between nodes over EFA through its libfabric provider.
It builds the SMP variant of that layer (`mpi-linux-x86_64-smp`): each NAMD process runs `PPN` worker threads (PEs)
and one communication thread. The launcher starts `PROCS_PER_NODE` processes per node, one by default, so each node
runs `PROCS_PER_NODE` × (`PPN` + 1) threads. A run on one node uses the same binary.

## Build

> **The NAMD source requires accepting a licence.** NAMD's source tarball is distributed from the
> [NAMD download page](https://www.ks.uiuc.edu/Research/namd/) behind a licence agreement, so the build script cannot
> fetch it. Download `NAMD_<version>_Source.tar.gz` once, accepting the licence, and place it at `${BASE_DIR}/src/`
> (default `/fsx/namd/src/`), or set `NAMD_SRC` to its path. This repository does not redistribute NAMD.

```bash
# After staging /fsx/namd/src/NAMD_3.0.2_Source.tar.gz: the hpc8a build, on an hpc8a node
sbatch x86/build_namd_x86.sbatch

# The c8i build, on a c8i node
sbatch -p c8i -C c8i.96xlarge --export=ALL,TARGET_CPU=c8i x86/build_namd_x86.sbatch
```

The build script:

1. installs the compilers, `make` and TCL's headers with `dnf` (through `sudo`);
2. builds FFTW as a static, single-precision library inside the install, so `namd3` needs no FFTW library on the
   compute nodes. Before it extracts the FFTW tarball, downloaded or staged, it checks the tarball's SHA-256 against
   `FFTW_SHA256` and stops on a mismatch;
3. builds the Charm++ that ships with the NAMD source (`mpi-linux-x86_64 smp --with-production`), with `-O3` and
   the target's `-march` and `-mtune`, against the Open MPI module;
4. configures NAMD for that Charm++, the system TCL and the static FFTW, and compiles it with the options of the
   target's NAMD arch file and the target's `-march` and `-mtune` (through `./config --cxx-opts` and `--cc-opts`);
5. installs `namd3` under `${BASE_DIR}/x86_64/<version>-<target>/`, with an env script, `namd-<version>-x86-env.sh`,
   that loads the Open MPI and `libfabric-aws` modules, puts `namd3` on the `PATH`, and names the target
   (`NAMD_TARGET_CPU`) and its instruction set (`NAMD_ISA`).

| `TARGET_CPU` | For | `-march` / `-mtune` | NAMD arch file | Instruction set |
|---|---|---|---|---|
| `hpc8a` (default), `hpc7a`, `m8a` | hpc8a, hpc7a and m8a instances | `x86-64-v4` / `znver4` | `Linux-AVX512-g++` | AVX-512 |
| `c8i`, `r8i` | c8i and r8i instances | `x86-64-v4` / `sapphirerapids` | `Linux-AVX512-g++` | AVX-512 |
| `hpc6id` | hpc6id instances | `x86-64-v4` / `icelake-server` | `Linux-AVX512-g++` | AVX-512 |
| `hpc6a` | hpc6a instances | `x86-64-v3` / `znver3` | `Linux-x86_64-g++` | AVX2 |

The `Linux-AVX512-g++` arch file compiles NAMD with `-O3 -fexpensive-optimizations -ffast-math -mavx512f -mavx512dq
-DNAMD_AVXTILES`: AVX-512, and NAMD's mixed-precision AVX-512 tile-list kernels. The `Linux-x86_64-g++` arch file has
the first three options only: hpc6a's CPU has no AVX-512. GCC 11, the default compiler of Amazon Linux 2023, has no
`znver5` or `graniterapids` tuning, so the hpc8a and m8a targets tune for `znver4`, and the c8i and r8i targets for
`sapphirerapids`. A build runs on every size of its instance family, and the script can build any target on any
x86_64 node. It never overwrites an install: remove `${BASE_DIR}/x86_64/<version>-<target>/` to build again. The job asks Slurm for
two hours (`#SBATCH --time=02:00:00`); pass `sbatch --time` to change it.

| Variable | Default | Description |
|---|---|---|
| `NAMD_VERSION` | `3.0.2` | NAMD release (with the Charm++ it bundles) |
| `TARGET_CPU` | `hpc8a` | The build target, from the table above |
| `BASE_DIR` | `/fsx/namd` | Install root |
| `COMPILE_CORES` | `48` | Parallel build jobs |
| `NAMD_SRC` | `${BASE_DIR}/src/NAMD_${NAMD_VERSION}_Source.tar.gz` | The staged source tarball |
| `NAMD_SRC_URL` | none | A private mirror to fetch the source from when it is not staged |
| `OPENMPI_MODULE` | `openmpi/4.1.7` | The Open MPI module Charm++ is built against and the env script loads |
| `FFTW_VERSION` | `3.3.10` | FFTW release, fetched from fftw.org unless `${BASE_DIR}/src/fftw-<version>.tar.gz` exists |
| `FFTW_SHA256` | FFTW's published SHA-256 for 3.3.10 | The FFTW tarball's expected SHA-256. For another version with none set, the build prints the tarball's SHA-256 and goes on |

## Run

```bash
# ApoA1 on one node
sbatch --nodes=1 x86/namd-benchmark.sbatch

# STMV on four nodes, over EFA
sbatch --nodes=4 --export=ALL,MODEL=STMV x86/namd-benchmark.sbatch

# ApoA1 on one hpc7a.96xlarge
sbatch -p hpc7a -C hpc7a.96xlarge x86/namd-benchmark.sbatch
```

The job asks Slurm for two hours (`#SBATCH --time=02:00:00`), so a run that stops progressing gives its nodes back;
pass `sbatch --time` for a longer run. The launcher:

1. picks the build of the node's instance family, `${BASE_DIR}/x86_64/<version>-<family>/` (the highest version),
   from the instance type in the instance metadata, and sources its env script. With no build for that family, it
   takes the only build under `${BASE_DIR}/x86_64/`, with a `NOTE:` on stderr that names it; with several, it stops and
   asks for `NAMD_ENV`. An AVX-512 build on a node whose CPU has no AVX-512 stops the job before anything runs;
2. on more than one node, checks EFA with `fi_info -p efa`;
3. fetches the deck into a cache on first use (its files, not the downloaded archive), and copies it into a run
   directory of its own, `${BASE_DIR}/Run/<job>-<MODEL>-<cluster>-<nodes>x<instance type>-<PPN>ppn-<UTC time>/` (with
   `<PROCS_PER_NODE>x<PPN>ppn` for more than one process per node). The run's config names its output files without
   the deck's `/usr/tmp/` directory, so NAMD writes them (`.coor`, `.vel`, `.xsc`) in the run directory;
4. drops the page cache and enables transparent huge pages on every node, where `sudo` allows it;
5. starts `namd3` with `mpirun`: `PROCS_PER_NODE` processes per node (`-np`, `--map-by ppr:<PROCS_PER_NODE>:node`),
   each with `+ppn PPN` worker threads, and `+setcpuaffinity` with the cores of each thread (see "Processes per node"
   and, below a full node of hpc8a.96xlarge or hpc7a.96xlarge, the flexible-cores list). It prints the whole command
   line first, on a line that starts with `==> mpirun`. On more than one node, Open MPI sends its traffic over EFA
   (`--mca pml cm --mca mtl ofi`, `FI_PROVIDER=efa`).

| Variable | Default | Description |
|---|---|---|
| `NAMD_ENV` | the build of the node's instance family | The build's env script |
| `MODEL` | `ApoA1` | `ApoA1`, `ATPase` (F1-ATPase) or `STMV` |
| `TIMESTEPS` | `1000` | The run's `numsteps` (and a `run` line's steps), 1 to 10,000,000 |
| `PPN` | the process's cores − 1 | Worker threads (PEs) per process, 1 to 192. With one process per node on hpc8a.96xlarge and hpc7a.96xlarge: 23, 47, 71, 95, 119, 143, 167, 191 or 192 (see below). With more than one, the process's cores − 1 |
| `PROCS_PER_NODE` | `1` | NAMD processes per node: a number that divides the node's cores and leaves each process at least two (see "Processes per node") |
| `NAMD_EXTRA_ARGS` | none | `namd3` options added before the config, each a `+` and a name, for example `+notiles`. The launcher sets `+ppn`, `+setcpuaffinity`, `+pemap` and `+commap` itself |
| `BASE_DIR` | `/fsx/namd` | Root of the deck cache and the run directories (an absolute path) |

## Processes per node

Each NAMD process in SMP mode has one communication thread, which handles all of its messages to other processes.
NAMD's user guide ("Improving Parallel Scaling" and "CPU Affinity") notes that this thread can limit an SMP build that
spans several nodes, and shows `+pemap` and `+commap` for several processes per node. `PROCS_PER_NODE` (P) sets their
number.

- P divides the node's cores, C, into groups of G = C / P consecutive cores, one group per process, with at least two
  cores each.
- On a full node, which more than one process per node always is, each process takes its group: its communication
  thread the group's first core, and its `PPN` = G − 1 worker threads the other cores. In NAMD's list syntax that is
  `+commap 0-<C-1>:<G> +pemap 1-<C-1>:<G>.<G-1>`; with P = 1 and `PPN` = C − 1, the communication thread takes core 0
  and the worker threads the others. Every node of the run uses the same cores.
- With more than one process per node, `PPN` is G − 1: leave it unset. With one process, a `PPN` equal to the node's
  cores leaves no core for the communication thread: Charm++ then places the threads, and a `NOTE:` says so.
- On hpc8a.96xlarge and hpc7a.96xlarge, each process's group must be whole CCDs of 8 cores: P = 1, 2, 3, 4, 6, 8, 12
  or 24. Any other P stops the job before anything runs.

| Instance | Cores | P that the launcher takes |
|---|--:|---|
| hpc8a.96xlarge, hpc7a.96xlarge | 192 | 1, 2, 3, 4, 6, 8, 12, 24 |
| m8a.48xlarge, c8i.96xlarge, r8i.96xlarge | 192 | any divisor of 192 up to 96 |
| hpc6a.48xlarge | 96 | any divisor of 96 up to 48 |
| hpc6id.32xlarge | 64 | any divisor of 64 up to 32 |

For example, STMV on two hpc8a.96xlarge nodes with four processes per node, each with 47 worker threads:

```bash
sbatch --nodes=2 --export=ALL,MODEL=STMV,PROCS_PER_NODE=4 x86/namd-benchmark.sbatch
```

## Cores per node on hpc8a.96xlarge and hpc7a.96xlarge

hpc8a.96xlarge and hpc7a.96xlarge have 192 cores in 24 CCDs of 8, each CCD with an L3 cache of its own. With one
NAMD process per node, it uses `PPN` + 1 cores, for its worker threads and its communication thread, and only 24, 48,
72, 96, 120, 144, 168 or 192 cores per node give every CCD the same number of threads
([Utils/flexible-cores](../../Utils/flexible-cores/)). So on these two types the launcher takes `PPN` = 23, 47, 71,
95, 119, 143, 167, 191 or 192, and stops at any other value before anything runs, with an `ERROR:` that names those
values.

- Below a full node (`PPN` 23 to 167), it pins the threads to the flexible-cores list of `PPN` + 1 cores: the
  communication thread to the list's first core (`+commap`), and the worker threads to the others (`+pemap`). The job
  log names the list on a line that starts with `Flexible cores:`, and every node of the run uses the same cores.
- At `PPN` 191 the process fills the node, as "Processes per node" describes; at 192 Charm++ places the threads.
- With no instance type from the instance metadata, a node that `lscpu` shows as AMD with 192 cores could be either
  type, so it gets the same check and lists, with a `NOTE:` on stderr. Any other node runs with no list, with a `NOTE:`
  that the check was skipped. The launcher reads `lscpu` only where the type changes what the job does: one process
  below a full node, or groups that are not whole CCDs.
- Other instance types and sizes get no list and no check.

## Benchmark models

| `MODEL` | System | Atoms | Steps in the deck | PME grid | Deck |
|---|---|--:|--:|---|---|
| `ApoA1` | Apolipoprotein A1 | 92,224 | 500 | 108 × 108 × 80 | [`apoa1.tar.gz`](https://www.ks.uiuc.edu/Research/namd/utilities/apoa1.tar.gz) |
| `ATPase` | F1-ATPase | 327,506 | 500 | 192 × 144 × 144 | [`f1atpase.tar.gz`](https://www.ks.uiuc.edu/Research/namd/utilities/f1atpase.tar.gz) |
| `STMV` | Satellite tobacco mosaic virus | 1,066,628 | 500 | 216 × 216 × 216 | [`stmv.tar.gz`](https://www.ks.uiuc.edu/Research/namd/utilities/stmv.tar.gz) |

The three decks come from the [NAMD utilities page](https://www.ks.uiuc.edu/Research/namd/utilities/), each with PME
and a time step of 1 fs. The launcher runs 1,000 steps of each by default (`TIMESTEPS`). It fetches each deck on first
use and keeps it at `${BASE_DIR}/benchmarks/<MODEL>/`; delete that directory to fetch it again.

## Metrics

NAMD prints its speed while it runs, on lines of this form:

```
Info: Benchmark time: <CPUs> CPUs <s> s/step <d> days/ns <MB> MB memory
```

NAMD prints a timing line every 5 × `stepspercycle` steps, 100 for the three decks: `Initial time:` for the first
three, then `Benchmark time:` up to step 900, each one the wall time per step over the 100 steps before it. A run of
1,000 steps, the launcher's default, prints six `Benchmark time:` lines, for steps 400 to 900; the decks' own 500 steps
print two. NAMD's user guide ("Improving Parallel Scaling") points to these lines to measure parallel performance.
The launcher takes the days/ns of the last one and reports ns/day = 1 / (days/ns), with NAMD's closing `WallClock:`
time.

When NAMD fails, the job ends with NAMD's exit status, after an `ERROR:` that names the run's `namd.out`. When NAMD
exits 0, the launcher reports a result only from a complete run: `namd.out` must have NAMD's closing `WallClock:` line,
and its last `Benchmark time:` line must give a positive days/ns. Otherwise it prints an `ERROR:` that says what is
missing, no results block and no `NAMDRESULT` line, and the job ends with status 1.

The results block ends with one line that scripts can parse:

```
NAMDRESULT model=<MODEL> nodes=<nodes> ppn=<PPN> instance=<instance type> days_per_ns=<d> ns_per_day=<r> wallclock=<s> procs_per_node=<P>
```

## Checking a run

In the run directory's `namd.out`:

- `Charm++> Running in SMP mode: <n> processes, <PPN> worker threads (PEs) + 1 comm threads per process`: nodes ×
  `PROCS_PER_NODE` processes, with the `PPN` asked for;
- `Charm++> cpu affinity enabled.`: Charm++ binds the threads to cores;
- `Charm++> cpuaffinity PE-core map (OS indices): <the +pemap value>`, and one line per process on the first node,
  `Charm++> set comm <k> on node <k> to PU P#<core>`: the cores the launcher passed (none when Charm++ places the
  threads);
- `Info: MIXED PRECISION AVX-512 TILES OPTIMIZATIONS: ENABLED`: the AVX-512 tile-list kernels are on. NAMD's `+notiles`
  option turns them off.

On more than one node, the job's log shows the `fi_info` listing of provider `efa`.

## Files

| File | Description |
|---|---|
| [`x86/build_namd_x86.sbatch`](x86/build_namd_x86.sbatch) | Builds static FFTW, Charm++ (`mpi-linux-x86_64-smp`, on the system Open MPI) and NAMD; installs `namd3` and its env script |
| [`x86/namd-benchmark.sbatch`](x86/namd-benchmark.sbatch) | Runs ApoA1, F1-ATPase or STMV with `mpirun`; fetches and caches the deck; reports days/ns and ns/day |
| [`tests/test_namd_launcher.py`](../../tests/test_namd_launcher.py), [`tests/test_namd_build.py`](../../tests/test_namd_build.py), [`tests/test_namd_properties.py`](../../tests/test_namd_properties.py) | Tests of the two scripts, with stubs only: no NAMD, MPI or Slurm needed |
