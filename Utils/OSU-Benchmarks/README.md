# OSU Micro-Benchmarks

The [OSU Micro-Benchmarks](https://mvapich.cse.ohio-state.edu/benchmarks/) (OMB) are a widely used suite for evaluating MPI performance. They measure point-to-point latency, bandwidth, and collective operation performance, making them ideal for validating EFA and MPI configurations on HPC clusters.

This directory holds, for each of two MPIs, the EFA installer's Open MPI and Intel MPI, a script that builds OMB and a Slurm job script that runs it over EFA. The two job scripts run the same tests at the same layouts, so that the same nodes can be measured with both MPIs.

## Build

Two build scripts are provided, one per MPI implementation. Run the appropriate script from the head node (or a login node with access to `/fsx`):

**Open MPI:**

```bash
bash build_osu_benchmarks_openmpi.sh
```

Installs to `/fsx/OSU-Benchmark-OpenMPI/install`, built with the EFA installer's Open MPI 4 (`module load openmpi`). With the EFA installer's Open MPI 5 instead (`module load openmpi5`), it installs to `/fsx/OSU-Benchmark-OpenMPI5/install`:

```bash
OMPI_MODULE=openmpi5 bash build_osu_benchmarks_openmpi.sh
```

**Intel MPI:**

```bash
bash build_osu_benchmarks_intelmpi.sh
```

Installs to `/fsx/OSU-Benchmark-IntelMPI/install`, built with Intel MPI over the EFA installer's libfabric: the script exports `I_MPI_OFI_LIBRARY_INTERNAL=0` before `module load intelmpi`, then loads `libfabric-aws`.

Both scripts download OSU Micro-Benchmarks 7.5.3 and check the download's SHA-256 against the one they know for it. They also know the SHA-256 of 8.0b2, the beta of OMB 8.0, which they built before: `OSU_VERSION=8.0b2 bash build_osu_benchmarks_openmpi.sh` builds it, checked.

Each script first checks that `mpirun --version` names its MPI. Then it builds in a directory of its own under `$TMPDIR` (or `/tmp`): it unpacks the source there and, in the unpacked source, configures it with the MPI's compiler wrappers (`CC=mpicc CXX=mpicxx`), compiles it with `make -j` and installs it with `make install`, each step with its own log. If a step ends with another exit status than 0, the script prints that status, the last 30 lines of the step's log and the build directory, which it keeps, and ends with that status. Once OMB is installed, its logs go to `<INSTALL_DIR>/logs/<version>-<UTC time>/`, and `<INSTALL_DIR>/install/osu-build.txt` records the OMB version, the tarball's SHA-256, the MPI (`mpirun --version`), the compiler (`mpicc --version`), the time and the host; the build directory is then removed. The other files in `INSTALL_DIR` stay as they are: the source and objects of a build made in `INSTALL_DIR` itself, as these scripts made before, and an earlier release's tests in `<INSTALL_DIR>/install` that this release does not install (`make install` replaces the tests of the same name).

Settings, in the environment (`MAKE_JOBS=8 bash build_osu_benchmarks_openmpi.sh`):

| Setting | Default | Meaning |
|---|---|---|
| `OSU_VERSION` | `7.5.3` | The OMB release to build |
| `OSU_SHA256` | the SHA-256 the script knows for `OSU_VERSION` | The tarball's SHA-256, 64 hexadecimal digits. For a release the script does not know, the download is not checked unless you set it, and a NOTE says so |
| `INSTALL_DIR` | `/fsx/OSU-Benchmark-OpenMPI` (`/fsx/OSU-Benchmark-OpenMPI5` with `OMPI_MODULE=openmpi5`), `/fsx/OSU-Benchmark-IntelMPI` | An absolute path: OMB is installed in `<INSTALL_DIR>/install`, its build logs are kept in `<INSTALL_DIR>/logs` |
| `MAKE_JOBS` | the node's CPUs (`nproc`) | Parallel `make` jobs |
| `OMPI_MODULE` | `openmpi` | The Open MPI script's MPI: `openmpi` (Open MPI 4) or `openmpi5` (Open MPI 5) |

A value out of its range stops the script before anything is downloaded. Without a `module` command (on an image without Environment Modules), the scripts use the MPI on the `PATH`, after the same check.

## Run

Submit the job script matching your MPI build:

**Open MPI:**

```bash
sbatch osu_benchmarks_openmpi.sbatch
```

**Open MPI 5**, built with `OMPI_MODULE=openmpi5`:

```bash
OMPI_MODULE=openmpi5 sbatch osu_benchmarks_openmpi.sbatch
```

**Intel MPI:**

```bash
sbatch osu_benchmarks_intelmpi.sbatch
```

Both job scripts ask for 2 nodes of the `hpc8a` partition with the feature `hpc8a.96xlarge`, the names of a queue and an instance type in an AWS ParallelCluster cluster. For other instance types, such as hpc7a.96xlarge or hpc6a.48xlarge, or on another cluster, an AWS Parallel Computing Service (AWS PCS) cluster included, give your own on the command line, which takes precedence over the script's directives:

```bash
sbatch -p <queue> --constraint=<feature> --nodes=2 osu_benchmarks_openmpi.sbatch
```

Each job has a time limit of 30 minutes (`sbatch --time` gives another), and writes its output to `osu-benchmarks-<job id>.out` (Open MPI) or `osu-benchmarks-intelmpi-<job id>.out` (Intel MPI) in the directory you submit from.

## What the jobs run

By default each job runs these OMB tests, in this order, each with OMB's own message sizes, iterations and warm-up:

| Test | Measures | Ranks |
|---|---|---|
| `osu_latency` | Point-to-point latency | 2, one on each of the first two nodes |
| `osu_bw` | Point-to-point bandwidth, one way | 2, one on each of the first two nodes |
| `osu_bibw` | Point-to-point bandwidth, both ways | 2, one on each of the first two nodes |
| `osu_mbw_mr` | Bandwidth and message rate of many pairs: the first half of the ranks send to the second half | `OSU_PPN` on every node |
| `osu_allreduce` | `MPI_Allreduce` latency | `OSU_PPN` on every node |

`OSU_PPN` is one rank per core by default (the node's sockets times its cores per socket, from `lscpu`), so that the multi-pair and collective tests use every socket of a node, and every EFA device of nodes with more than one. On a job of one node the pair tests run both ranks on that node.

On two or more nodes, both ranks of a pair test run on the same core of their node: the first CPU of the NUMA node of the node's first EFA device (core 0 when that is unknown), which puts each next to that device. The other tests, and the pair tests of a job of one node, bind each rank to a core of its own.

The jobs keep OMB's defaults. In OMB 7.5.3, the point-to-point tests send messages of up to 4 MiB (8.0b2's, up to 1 MiB); `osu_latency` runs 10,000 iterations after 100 of warm-up up to 8 KiB, then 1,000 after 10; the bandwidth tests run 100 iterations after 10, then 20 after 2, with a window of 64 messages; the collectives send messages of up to 1 MiB, 1,000 iterations after 100, then 100 after 10. `OSU_ARGS` gives every test other values (for example `-m 1:65536 -i 1000 -x 100`).

Every test runs, also after one that ends with another exit status than 0. The job then prints a summary, one line per test, and ends with 1 when any test ended with another exit status than 0, else with 0.

## Settings

Pass the settings in the job's environment, as in `OSU_TESTS="latency bw" sbatch osu_benchmarks_openmpi.sbatch`: sbatch passes its environment to the job.

| Setting | Default | Meaning |
|---|---|---|
| `OSU_DIR` | the build script's install: `/fsx/OSU-Benchmark-OpenMPI/install/libexec/osu-micro-benchmarks/mpi` (Open MPI 4), `/fsx/OSU-Benchmark-OpenMPI5/install/libexec/osu-micro-benchmarks/mpi` (Open MPI 5), `/fsx/OSU-Benchmark-IntelMPI/install/libexec/osu-micro-benchmarks/mpi` (Intel MPI) | The `libexec/osu-micro-benchmarks/mpi` directory of an OMB install. When the build record (`osu-build.txt`) is in the install directory, the job prints its OMB version and MPI |
| `OMPI_MODULE` | `openmpi` | Open MPI: `openmpi` (the EFA installer's Open MPI 4) or `openmpi5` (its Open MPI 5); any other value stops the job before anything runs |
| `OSU_TESTS` | `latency bw bibw mbw_mr allreduce` | The tests, in order, with or without the `osu_` prefix: `latency`, `bw`, `bibw` (2 ranks); `mbw_mr`, `multi_lat` (in pairs: an even number of ranks); `allreduce`, `allgather`, `alltoall`, `bcast`, `barrier`, `reduce`, `reduce_scatter` |
| `OSU_PPN` | every core of the node | Ranks per node of the multi-pair and collective tests, from 1 to the node's cores |
| `OSU_ARGS` | none | OMB options for every test, split at blanks, such as `-m 1:65536 -i 1000` |
| `FI_PROVIDER` | `efa` | Open MPI: libfabric's provider |
| `OMPI_MCA_pml`, `OMPI_MCA_mtl` | `cm`, `ofi` | Open MPI: its point-to-point layer and its libfabric transport. Unless you set them, the job passes `--mca pml cm --mca mtl ofi` |
| `FI_EFA_USE_DEVICE_RDMA` | `1` on a node with EFA devices only, none of them `0xefa0`; else unset | See "EFA and MPI settings" |
| `I_MPI_FABRICS` | `shm:ofi` | Intel MPI: shared memory between the ranks of a node, libfabric between nodes |
| `I_MPI_OFI_PROVIDER` | `efa` | Intel MPI: libfabric's provider |
| `I_MPI_MULTIRAIL` | `1` | Intel MPI: the ranks use every EFA device of their node |
| `I_MPI_DEBUG` | `5` | Intel MPI: its startup report, which names the libfabric version and provider |
| `I_MPI_PIN_DOMAIN`, `I_MPI_PIN_ORDER`, `I_MPI_PIN_PROCESSOR_LIST` | set per test by the job | Intel MPI's pinning. When you set any of them, the job sets none, and your pinning applies to every test |
| `I_MPI_OFI_LIBRARY_INTERNAL` | `0` | Intel MPI: `0` uses the EFA installer's libfabric (see "EFA and MPI settings") |

The Intel MPI job also sets `I_MPI_HYDRA_BOOTSTRAP=slurm`, whatever the job's environment gives (see "EFA and MPI settings"). An unknown test, an `OSU_PPN` out of its range, an odd number of ranks for `osu_mbw_mr` or `osu_multi_lat`, or a missing binary stops the job before any MPI starts, with a message that says why.

## Both MPIs on the same nodes

The two job scripts run the same tests at the same layouts, with the same defaults, so one allocation can run them one after the other on the same nodes:

```bash
sbatch -p <queue> --constraint=<feature> --nodes=2 --exclusive --time=01:00:00 \
    --wrap 'bash osu_benchmarks_openmpi.sbatch; OMPI_MODULE=openmpi5 bash osu_benchmarks_openmpi.sbatch;
            bash osu_benchmarks_intelmpi.sbatch'
```

Submit it from this directory: the job runs the two scripts from the directory you submit from, writes their output to `slurm-<job id>.out`, and passes the settings in its environment to both.

## EFA and MPI settings

What the job scripts set, and why:

- **Open MPI**: `--mca pml cm --mca mtl ofi` (Open MPI's cm point-to-point layer over libfabric) and `FI_PROVIDER=efa`, passed to every rank with `-x`, as this repository's other Open MPI job scripts set them.
- **Intel MPI**: `I_MPI_FABRICS=shm:ofi`, `I_MPI_OFI_PROVIDER=efa` and `I_MPI_MULTIRAIL=1`. Intel MPI's module puts its own libfabric first unless `I_MPI_OFI_LIBRARY_INTERNAL` is `0` as it loads, so the job script and its build script export `I_MPI_OFI_LIBRARY_INTERNAL=0` first, then load `intelmpi` and `libfabric-aws` once each.
- **Intel MPI's bootstrap**: `I_MPI_HYDRA_BOOTSTRAP=slurm`, so that Intel MPI starts its processes with `srun`, inside the job. Slurm 23.11 and later set `I_MPI_HYDRA_BOOTSTRAP=slurm` and `I_MPI_HYDRA_BOOTSTRAP_EXEC_EXTRA_ARGS=--external-launcher` for a job submitted with no `I_MPI_HYDRA_BOOTSTRAP` in its environment, but a login profile can export another value, such as `ssh`, which the job then carries. The job script sets `slurm` whatever the job carries, and `--external-launcher` too when the job gives no extra argument of its own and carries `OMPI_MCA_plm_slurm_args=--external-launcher`, which Slurm sets where `srun` has that option.
- **Device RDMA**: Open MPI 4.1 asks libfabric for API version 1.5 ([mtl_ofi_component.c](https://github.com/open-mpi/ompi/blob/v4.1.7/ompi/mca/mtl/ofi/mtl_ofi_component.c#L670)), and Open MPI 5.0 for 1.18 ([mtl_ofi_component.c](https://github.com/open-mpi/ompi/blob/v5.0.9/ompi/mca/mtl/ofi/mtl_ofi_component.c#L615)). With API 1.18 or later, libfabric's EFA provider uses device RDMA wherever the device supports RDMA read; with an older API, it leaves device RDMA off on EFA devices `0xefa0` and `0xefa1` (PCI device ids) unless `FI_EFA_USE_DEVICE_RDMA=1`, and uses it by default on later devices. With `FI_EFA_USE_DEVICE_RDMA=1` on a device with no RDMA read, it stops the program ([efa_rdm_util.c](https://github.com/ofiwg/libfabric/blob/v2.4.0/prov/efa/src/rdm/efa_rdm_util.c#L24-L69)). Every instance type with Nitro v4 or later supports RDMA read, and of the Nitro v3 (EFA v1, PCI device `0xefa0`) types AWS lists p4d.24xlarge and p4de.24xlarge with it ([Supported instance types](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa.html#efa-instance-types)). So both job scripts set `FI_EFA_USE_DEVICE_RDMA=1` when every device in `/sys/class/infiniband` is an EFA device (PCI vendor `0x1d0f`) whose PCI device is not `0xefa0`, and leave it unset otherwise. A value in the job's environment is kept: on an instance type whose `0xefa0` devices support RDMA read, set it there. The job prints which, and why.
- **Pinning**: one rank per core (Open MPI `--bind-to core`; Intel MPI `I_MPI_PIN_DOMAIN=core` with `I_MPI_PIN_ORDER=compact`), and, on two or more nodes, each rank of a pair test on the same core of its node. Open MPI runs a pair test under `taskset -c <core>`, with `--bind-to none`, since it refuses `--cpu-set` beside `--map-by`; Intel MPI takes `I_MPI_PIN_PROCESSOR_LIST`, with no domain or order, under which Intel MPI would not take the list.

The job reads the EFA devices on its first node only, and applies what it finds there, the device RDMA setting and the pair tests' core, to every node: run it on nodes of one instance type, for example with `--constraint`.

To check that EFA works on a node before you measure it, see [Utils/test-efa](../test-efa/).
