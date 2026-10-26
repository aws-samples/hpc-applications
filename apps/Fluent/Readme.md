# ANSYS Fluent

ANSYS [Fluent](https://www.ansys.com/products/fluids/ansys-fluent) is a general-purpose computational fluid dynamics (CFD) software used to model fluid flow, heat and mass transfer, chemical reactions, and more.
Developed by [ANSYS](https://www.ansys.com/), it ships with CPU (x86) and GPU solvers. An Arm-based build that runs on AWS Graviton is available as a beta from Ansys.

# Versions

This repository provides best practices for all Fluent versions starting from 2020 and newer.
For Fluent 2019 (v195) and older please refer to this [blog post](https://aws.amazon.com/blogs/compute/running-ansys-fluent-on-amazon-ec2-c5n-with-elastic-fabric-adapter-efa/).

# Launch scripts

Pick a script depending on whether you want to run a benchmark or a journal file, and whether you want to use IntelMPI or OpenMPI. The x86 scripts target hpc8a by default, the GPU and Arm scripts their own instance types; edit the `#SBATCH` header to run on other instances.

| Script | Purpose | MPI |
|---|---|---|
| [`x86/Fluent-Benchmark.IMPI.sbatch`](https://github.com/aws-samples/hpc-applications/blob/main/apps/Fluent/x86/Fluent-Benchmark.IMPI.sbatch) | Ansys benchmark suite runner (e.g. `f1_racecar_140m`) | IntelMPI |
| [`x86/Fluent-Benchmark.2026R1.sbatch`](https://github.com/aws-samples/hpc-applications/blob/main/apps/Fluent/x86/Fluent-Benchmark.2026R1.sbatch) | Ansys benchmark suite runner with the 2026 R1 harness (MIUPS), CPU solver; see [Fluent-Benchmark-2026R1.md](Fluent-Benchmark-2026R1.md) | IntelMPI |
| [`x86/Fluent.IMPI.sbatch`](https://github.com/aws-samples/hpc-applications/blob/main/apps/Fluent/x86/Fluent.IMPI.sbatch) | Run your own journal file | IntelMPI |
| [`x86/Fluent-Benchmark.OMPI.sbatch`](https://github.com/aws-samples/hpc-applications/blob/main/apps/Fluent/x86/Fluent-Benchmark.OMPI.sbatch) | Ansys benchmark suite runner | OpenMPI |
| [`x86/Fluent.OMPI.sbatch`](https://github.com/aws-samples/hpc-applications/blob/main/apps/Fluent/x86/Fluent.OMPI.sbatch) | Run your own journal file | OpenMPI |
| [`gpu/Fluent-GPU.sbatch`](https://github.com/aws-samples/hpc-applications/blob/main/apps/Fluent/gpu/Fluent-GPU.sbatch) | GPU-based simulation | IntelMPI |
| [`gpu/Fluent-GPU.OMPI.sbatch`](https://github.com/aws-samples/hpc-applications/blob/main/apps/Fluent/gpu/Fluent-GPU.OMPI.sbatch) | GPU-based simulation | OpenMPI |
| [`gpu/Fluent-Benchmark-GPU.sbatch`](https://github.com/aws-samples/hpc-applications/blob/main/apps/Fluent/gpu/Fluent-Benchmark-GPU.sbatch) | GPU solver benchmark with the 2026 R1 harness | IntelMPI |
| [`Arm/Fluent-benchmark.sbatch`](https://github.com/aws-samples/hpc-applications/blob/main/apps/Fluent/Arm/Fluent-benchmark.sbatch) | Ansys benchmark suite runner on Graviton | OpenMPI |
| [`Arm/Fluent.sbatch`](https://github.com/aws-samples/hpc-applications/blob/main/apps/Fluent/Arm/Fluent.sbatch) | Run your own journal file on Graviton | OpenMPI |

IntelMPI and OpenMPI deliver similar performance on AWS EFA for Fluent (within ~1% on the `f1_racecar_140m` benchmark on hpc8a at 2 and 10 nodes). IntelMPI is the most mature path and the default recommendation. OpenMPI is a solid alternative — useful when you prefer a non-proprietary stack or need a specific OpenMPI feature.

# Installation

Fluent runs on Linux and Windows. This repo ships a Linux install script:

```bash
./Fluent-Install.sh /fsx s3://your_bucket/FLUIDSTRUCTURES_2022R1_LINX64.tgz
```

- First argument: the base directory where Fluent gets installed (e.g. `/fsx` produces `/fsx/ansys_inc`).
- Second argument: an [S3](https://aws.amazon.com/pm/serv-s3/) URI pointing to the installation archive.

For multi-node runs Fluent must live on a shared filesystem. We recommend [Amazon FSx for Lustre](https://aws.amazon.com/fsx/lustre/) ([docs](https://docs.aws.amazon.com/fsx/latest/LustreGuide/what-is.html)).

# Key settings & tips (performance-related)

### Instance selection

- Fluent is compute and memory-bandwidth bound. The best instance types have a high core count and high memory bandwidth per core.
- As of today [hpc8a](https://aws.amazon.com/ec2/instance-types/hpc8a/) offers the best price/performance, followed by [hpc7a](https://aws.amazon.com/ec2/instance-types/hpc7a/).

### Scalability

- Fluent scales nearly linearly down to **30k-50k cells per core**. Below that, collective overhead dominates.
- Example: the `f1_racecar_140m` dataset (140M cells) scales cleanly up to roughly 4500 cores (140M / 30k ≈ 4500).

### Fluent command-line flags the scripts set

- **`-peth.efa`** — tells Fluent's MPI wrapper (`mpirun.fl`) to activate its built-in EFA profile. The wrapper then exports the right IntelMPI / libfabric tuning for AWS EFA without you having to set them manually. Supported from Fluent v222 (2022 R2) onwards; officially documented from v261 (2026 R1). On OpenMPI the same flag is honored from v242; v222 / v231 have a wrapper bug that forces TCP and is unusable at scale.
- **`-platform=intel`** — use the AVX2-optimized solver binary. On AMD EPYC (hpc7a / hpc8a) this still outperforms `-platform=amd` at small-to-medium scale (we measured +13% at 2 nodes, equal at 20 nodes on v252) and it works on every Fluent version v222..v261, so it is the safe default.
- **`-t<N>`** — number of MPI ranks (cores).
- **`-mpi=intel`** or **`-mpi=openmpi`** — MPI implementation.

### Env vars the scripts set

- **`I_MPI_OFI_LIBRARY_INTERNAL=0`** (IntelMPI only) — export *before* `module load intelmpi` so that `mpivars.sh` picks up the system `libfabric-aws` instead of the one bundled with IntelMPI.
- **`I_MPI_MULTIRAIL=1`** (IntelMPI only, multi-NIC EFA instances only) — turns on IntelMPI's multi-NIC support, which shares the two EFA NICs of hpc7a / hpc8a out among the ranks. Omit on single-NIC instances. IntelMPI 2021.18 shared them out without it too: in runs of the 2026 R1 benchmark script, which does not set it, half of each node's ranks used each NIC (see [Checking the MPI setup](#checking-the-mpi-setup)).
- **`FI_EFA_SHM_AV_SIZE=${SLURM_NTASKS_PER_NODE}`** — the maximum number of entries in the EFA provider's shared-memory address vector, set for more than 128 ranks per node (e.g. 192 ranks/node on hpc7a / hpc8a). The 2026 R1 benchmark script does not set it, and ran 192 ranks per node with IntelMPI 2021.18 and libfabric 2.4 without it.
- **`SCHEDULER_TIGHT_COUPLING=1`** — tells Fluent v222..v242 not to inject `--rsh=ssh` under Slurm; v251+ already behaves this way. Prevents a `hydra_bstrap_proxy` crash on AL2023 when Fluent's wrapper fights IntelMPI's Slurm integration.

The 2026 R1 benchmark script, `x86/Fluent-Benchmark.2026R1.sbatch`, sets `I_MPI_OFI_LIBRARY_INTERNAL=0`, `I_MPI_FABRICS=shm:ofi`, `I_MPI_OFI_PROVIDER=efa` and `I_MPI_DEBUG=5`, and none of the other three.

### Checking the MPI setup

Add `-mpiopt="-genv I_MPI_DEBUG 5"` to the Fluent command line, as `x86/Fluent-Benchmark.2026R1.sbatch` does. The run's Fluent transcript (the 2026 R1 harness writes it as `fluent-<date>-<time>-<pid>.trn` in the case's working directory) then shows:

- the `mpirun` line Fluent builds, with the settings `-peth.efa` adds (`I_MPI_OFI_PROVIDER efa`, `I_MPI_FABRICS shm:ofi`, `FI_EFA_RECVWIN_SIZE 65536`, `FI_MR_CACHE_MONITOR memhooks`) and the placement it leaves to IntelMPI (`FLUENT_AFFINITY 0`, `I_MPI_PIN enable`);
- `libfabric provider: efa`;
- a NIC pinning table: on `hpc8a.96xlarge` and `hpc7a.96xlarge`, half of each node's ranks on each of the two EFA NICs;
- a CPU pinning table with the cores of each rank: with IntelMPI's own placement, at 96 ranks per node on `hpc8a.96xlarge`, two consecutive cores per rank, so four ranks on each 8-core CCD.

### OpenMPI-specific notes

The OpenMPI scripts select the MPI implementation via the `OMPI_VARIANT` env var:

| `OMPI_VARIANT` | What it uses | Notes |
|---|---|---|
| `ompi4` (default) | `module load openmpi` (currently OpenMPI 4.1.7) | Best-tested; works for Fluent v242..v261. |
| `ompi5` | `module load openmpi5` (currently OpenMPI 5.0.9amzn1) | May hang at startup with Fluent on some setups; fall back to `ompi4` if so. |
| `bundled` | Fluent's own bundled OpenMPI (4.0.5) | Works at small scale but hits PMIX scalability limits at ≥10 nodes. |

Older Fluent releases have bugs that the scripts work around automatically:

- **v222 / v231**: the OpenMPI+EFA branch of `mpirun.fl` forces the TCP BTL. `-peth.efa` on these versions therefore falls back to TCP and is unusable at multi-node scale. Use IntelMPI for v222 / v231.
- **v242 / v251**: `mpirun.fl` injects `-x FLUTE_UUID=$FLUTE_UUID` even when the variable is unset, which breaks OpenMPI argument parsing. The scripts export a non-empty `FLUTE_UUID` to side-step the bug.
- **AL2023**: Fluent's `fluent_mpi` binary transitively needs `libnsl.so.2` which AL2023 does not ship. The scripts `LD_PRELOAD` the copy that ships inside Fluent's bundled OpenMPI directory and propagate it to worker ranks via `-x LD_PRELOAD`.

# Performance

This section shows benchmark results from a public dataset, `f1_racecar_140m`: an external flow over a Formula 1 race car, ~140 million hex-core cells, realizable k-ε turbulence model, pressure-based coupled solver, least-squares cell-based pseudo-transient solver. For more information see the [official benchmarks page](https://www.ansys.com/it-solutions/benchmarks-overview).

> The "Rating" in the charts below is the number of benchmark runs per 24 hours. It is computed as `86400 / benchmark_seconds`. Higher is better.

Per-core performance on AWS EC2 [hpc8a](https://aws.amazon.com/ec2/instance-types/hpc8a/), [hpc7a](https://aws.amazon.com/ec2/instance-types/hpc7a/) and [hpc6a](https://aws.amazon.com/ec2/instance-types/hpc6a/):
![ANSYS Fluent f1_racecar_140m X core Performance on AMD-based instances](https://github.com/aws-samples/hpc-applications/blob/main/Doc/img/Fluent/f1_racecar_140mXcoreAMD.png?raw=true)

Per-instance relative performance (192 cores/node) hpc8a vs hpc7a:
![ANSYS Fluent f1_racecar_140m X instance Performance Hpc8a Vs Hpc7a](https://github.com/aws-samples/hpc-applications/blob/main/Doc/img/Fluent/f1_racecar_140mXinstanceHpc8aVsHpc7a.png?raw=true)

Per-instance performance on AWS EC2 [hpc6id](https://aws.amazon.com/ec2/instance-types/hpc6i/) and [c5n](https://aws.amazon.com/ec2/instance-types/c5/):
![ANSYS Fluent f1_racecar_140m X instance Performance](https://github.com/aws-samples/hpc-applications/blob/main/Doc/img/Fluent/f1_racecar_140mXinstanceINTEL.png?raw=true)

# Contribute your results

The benchmark scripts in this folder call [`dynamodb/record-benchmark.sh`](dynamodb/record-benchmark.sh) after every successful run. The recorder saves the run as a small JSON record (`<record_id>.json`) and adds it to the shared AI-Powered HPC benchmark dataset when you have write access to it. That dataset trains a model that predicts HPC performance on AWS, so every result you share helps. Set `SOURCE=<YourOrg>` to tag your runs, and see [BENCHMARK-RECORDERS.md](../BENCHMARK-RECORDERS.md) for the options and how to send the record in.
