# OSU Micro-Benchmarks

The [OSU Micro-Benchmarks](https://mvapich.cse.ohio-state.edu/benchmarks/) (OMB) are a widely used suite for evaluating MPI performance. They measure point-to-point latency, bandwidth, and collective operation performance, making them ideal for validating EFA and MPI configurations on HPC clusters.

This directory contains build scripts and Slurm job scripts for running OSU Micro-Benchmarks with both OpenMPI and IntelMPI.

## Build

Two build scripts are provided, one per MPI implementation. Run the appropriate script from the head node (or a login node with access to `/fsx`):

**Open MPI:**

```bash
bash build_osu_benchmarks_openmpi.sh
```

Installs to `/fsx/OSU-Benchmark-OpenMPI/install`, built with the EFA installer's Open MPI 4 (`module load openmpi`).

**Intel MPI:**

```bash
bash build_osu_benchmarks_intelmpi.sh
```

Installs to `/fsx/OSU-Benchmark-IntelMPI/install`, built with Intel MPI over the EFA installer's libfabric: the script exports `I_MPI_OFI_LIBRARY_INTERNAL=0` before `module load intelmpi`, then loads `libfabric-aws`.

Both scripts download OSU Micro-Benchmarks 8.0b2 and check the download's SHA-256 against the one they know for that release.

Each script first checks that `mpirun --version` names its MPI. Then it builds in a directory of its own under `$TMPDIR` (or `/tmp`): it unpacks the source there and, in the unpacked source, configures it with the MPI's compiler wrappers (`CC=mpicc CXX=mpicxx`), compiles it with `make -j` and installs it with `make install`, each step with its own log. If a step ends with another exit status than 0, the script prints that status, the last 30 lines of the step's log and the build directory, which it keeps, and ends with that status. Once OMB is installed, its logs go to `<INSTALL_DIR>/logs/<version>-<UTC time>/`, and `<INSTALL_DIR>/install/osu-build.txt` records the OMB version, the tarball's SHA-256, the MPI (`mpirun --version`), the compiler (`mpicc --version`), the time and the host; the build directory is then removed. The other files in `INSTALL_DIR` stay as they are: the source and objects of a build made in `INSTALL_DIR` itself, as these scripts made before, and an earlier release's tests in `<INSTALL_DIR>/install` that this release does not install (`make install` replaces the tests of the same name).

Settings, in the environment (`MAKE_JOBS=8 bash build_osu_benchmarks_openmpi.sh`):

| Setting | Default | Meaning |
|---|---|---|
| `OSU_VERSION` | `8.0b2` | The OMB release to build |
| `OSU_SHA256` | the SHA-256 the script knows for `OSU_VERSION` | The tarball's SHA-256, 64 hexadecimal digits. For a release the script does not know, the download is not checked unless you set it, and a NOTE says so |
| `INSTALL_DIR` | `/fsx/OSU-Benchmark-OpenMPI`, `/fsx/OSU-Benchmark-IntelMPI` | An absolute path: OMB is installed in `<INSTALL_DIR>/install`, its build logs are kept in `<INSTALL_DIR>/logs` |
| `MAKE_JOBS` | the node's CPUs (`nproc`) | Parallel `make` jobs |

A value out of its range stops the script before anything is downloaded. Without a `module` command (on an image without Environment Modules), the scripts use the MPI on the `PATH`, after the same check.

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
