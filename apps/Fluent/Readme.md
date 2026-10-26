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
- Of the AMD instance types, by EC2 cost per run, [hpc8a](https://aws.amazon.com/ec2/instance-types/hpc8a/) comes first, then [hpc6a](https://aws.amazon.com/ec2/instance-types/hpc6a/) and [hpc7a](https://aws.amazon.com/ec2/instance-types/hpc7a/). On 192 cores, `hpc8a.96xlarge` ran four cases of the benchmark suite at the lowest EC2 cost per run of the three, 0.66–0.74× that of `hpc7a.96xlarge`, and `hpc6a.48xlarge` at 0.79–0.95×. See [AMD instance types on the suite's smaller cases](#amd-instance-types-on-the-suites-smaller-cases).
- With licences counted per core, the licence core-hours per run (cores × time) count too. `hpc8a.96xlarge` runs Fluent 1.48–1.67× as fast as `hpc7a.96xlarge` node for node, so it needs the fewest of the three, 0.60–0.67× those of `hpc7a.96xlarge`. `hpc6a.48xlarge` runs 0.84–1.01× as fast as `hpc7a.96xlarge` on the same cores, so it needs 0.99–1.19× the licence core-hours per run, which can make `hpc7a.96xlarge` the cheaper run overall.
- Of the Intel instance types measured on 192 cores, `c8i.96xlarge` ran the same four cases fastest and at the lowest EC2 cost per run: `r8i.96xlarge` ran them 0.95–0.99× as fast, at 1.49–1.55× the EC2 cost per run of `c8i.96xlarge`, and two nodes of `c7i`, `m7i` or `r7i.48xlarge` 0.71–0.84× as fast, at 1.17–1.88×. With licences counted per core, `c8i.96xlarge` also needs the fewest licence core-hours per run of the five. See [Intel instance types on the suite's smaller cases](#intel-instance-types-on-the-suites-smaller-cases).

### Scalability

Fluent scales well while each core has enough cells. On `hpc8a.96xlarge`, `hpc7a.96xlarge` and `hpc6a.48xlarge`, every configuration we measured at 18,000 cells per core or more kept 80% parallel efficiency or better, and below about 10,000 cells per core efficiency falls quickly:

| Cells per core | Measured on | Configurations | Parallel efficiency |
|---|---|--:|--:|
| 46,000–365,000 | `f1_racecar_140m` on 2 to 16 nodes | 8 | 82–99% |
| 36,000–42,000 | the 14–16M-cell cases on 2 `hpc8a.96xlarge` nodes (384 cores) | 3 | 94–104% |
| 18,000–21,000 | the 14–16M-cell cases on 768 cores | 9 | 80–96% |
| 7,000–10,000 | the 4–16M-cell cases on 384 to 1,920 cores | 10 | 48–88% |
| 2,000–5,000 | `sedan_4m` on 768 to 1,920 cores | 6 | 30–64% |

Every node is fully populated, and parallel efficiency is the speed-up over the same instance type's 192-core point (one node, two for `hpc6a.48xlarge`) divided by the core ratio. The runs are those of [Performance](#performance), on `hpc8a.96xlarge`, `hpc7a.96xlarge` and `hpc6a.48xlarge`.

Four Intel instance types were measured on 8 nodes, with parallel efficiency against two nodes of the same type. On `c7i.48xlarge`, `m7i.48xlarge` and `r7i.48xlarge` (768 cores, 18,000–21,000 cells per core), the 14–16M-cell cases kept 67–86%. On `hpc6id.32xlarge` (512 cores, 27,000–31,000 cells per core), they kept 79–100%.

While each core has enough cells, more nodes cost little more per run: on one instance type, the EC2 cost per run (nodes × time) against the 192-core point is 1 / parallel efficiency. `f1_racecar_140m` ran 7.3× as fast on 8 `hpc8a.96xlarge` nodes as on one for 1.09× the EC2 cost per run, and 13.8× as fast on 16 nodes for 1.16× (on `hpc7a.96xlarge`: 7.2× for 1.11×, 13.1× for 1.22×). With licences counted per core, the licence core-hours per run (cores × time) move by the same ratio. Ranked by cost per run alone, one node comes first, by 9–22%, ahead of 8 or 16 nodes that finish 7.2–13.8× sooner: weigh the run time too. Where efficiency falls, the cost per run rises with it: `sedan_4m` on 768 to 1,920 cores, at 30–64% parallel efficiency, cost 1.56–3.36× as much per run as on 192 cores.

### Cores per node (flexible cores)

Fluent's parallel (HPC) licences are counted in cores, so with a fixed number of licensed cores a run goes faster when those cores are spread over more nodes, each running fewer ranks with more memory bandwidth and L3 cache per rank:

- On `f1_racecar_140m`, the same ranks on twice the nodes at 96 per node ran 1.49–1.55× as fast on `hpc8a.96xlarge` and 1.60–1.64× on `hpc7a.96xlarge`, for 1.22–1.34× the EC2 cost per run and 0.61–0.67× the licence core-hours per run. 48 or 24 ranks per node ran faster still, at a steeply rising EC2 cost per run ([The same cores on more nodes](#the-same-cores-on-more-nodes)).
- On `hpc8a.96xlarge` and `hpc7a.96xlarge`, run 24, 48, 72, 96, 120, 144, 168 or 192 ranks per node, the counts that put the same number of ranks on each of their 24 CCDs (8 cores and one L3 cache each); on `hpc6a.48xlarge`, a multiple of 12, the same number on each of its 12 L3 groups of 8 cores. Pin the ranks with the list for that count from [Utils/flexible-cores](https://github.com/aws-samples/hpc-applications/tree/main/Utils/flexible-cores), which has the lists for `hpc8a.96xlarge` and `hpc7a.96xlarge`; for `hpc6a.48xlarge`, take the same number of cores from each of its 12 L3 groups ([Other AMD instance types](https://github.com/aws-samples/hpc-applications/blob/main/Utils/flexible-cores/Readme.md#other-amd-instance-types)).
- Fluent builds the `mpirun` command line itself (in Fluent 2026 R1 with `-genv FLUENT_AFFINITY 0 -genv I_MPI_PIN enable`, which leave the placement of its ranks to IntelMPI), so pass the list on that line too, through Fluent's `-mpiopt`, for example `-mpiopt="-genv I_MPI_DEBUG 5 -genv I_MPI_PIN_PROCESSOR_LIST <list>"`, and check in the CPU pinning table that each rank got its core from the list (see [Checking the MPI setup](#checking-the-mpi-setup)). In `x86/Fluent-Benchmark.2026R1.sbatch`, add `-genv I_MPI_PIN_PROCESSOR_LIST <list>` to the `-mpiopt=` element of `harness_args`, which must stay one array element: `EXTRA_FLUENT_ARGS` is split into words and cannot carry it. In `x86/Fluent-Benchmark.IMPI.sbatch` and `x86/Fluent.IMPI.sbatch`, add the whole `-mpiopt` option to the Fluent command line.
- In the runs of the 2026 R1 benchmark script (Fluent 2026 R1, IntelMPI 2021.18), which pass no list, IntelMPI's own placement put 4 and 2 ranks on every CCD at 96 and 48 ranks per node (4 on every L3 group of `hpc6a.48xlarge` at 48), the same balance as the lists. At 72, 120, 144 or 168 ranks per node (36, 60, 72 or 84 on `hpc6a.48xlarge`) it cannot give every rank the same number of cores, since the cores do not split into equal blocks: in an LS-DYNA run with IntelMPI 2021.18 on `hpc8a.96xlarge`, 144 ranks per node gave 48 ranks two cores and 96 ranks one, which loaded the CCDs unevenly.
- Ask Slurm for the layout, for example `sbatch --nodes=4 --ntasks=384 --ntasks-per-node=96 x86/Fluent-Benchmark.IMPI.sbatch v261 s3://your_bucket/f1_racecar_140m.tar` for 384 ranks on 4 nodes.

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

AWS ran Fluent 2026 R1 (v261) on public cases of the [Ansys Fluent benchmark suite](https://www.ansys.com/it-solutions/benchmarks-overview) in 2026, with `-platform=intel`, IntelMPI over EFA with the system libfabric, and the page cache dropped and THP set to `always` before each run:

- **`f1_racecar_140m`**, an external flow over a Formula 1 race car (about 140 million hex-core cells, realizable k-ε turbulence model, pressure-based coupled solver, least-squares cell-based, pseudo-transient), with the classic `fluentbench.pl` harness and IntelMPI 2021.16, on `hpc8a.96xlarge` and `hpc7a.96xlarge`: 1 to 16 nodes at 192, 96, 48 and 24 ranks per node, 4 runs per point (5 for two), on a ParallelCluster 3.14 cluster in us-east-2 in March 2026. Performance is Fluent's solver wall time per iteration. The runs of 38 of the 40 points agree within 5% (median spread 0.8%); those of `hpc8a.96xlarge` on 8 and 16 full nodes spread 9–10%.
- **Four smaller cases**, `sedan_4m`, `aircraft_wing_14m`, `landing_gear_15m` and `lm6000_16m` (4 to 16 million cells), with the 2026 R1 harness of `x86/Fluent-Benchmark.2026R1.sbatch` (CPU solver, `WARMUP_ITERATIONS=10` and `ITERATIONS=25`: two warm-up blocks of 10 iterations and 25 timed iterations, or time steps for the transient `landing_gear_15m` and `lm6000_16m`) and IntelMPI 2021.18, on three AMD and six Intel instance types (SMT off on the Intel types), 3 runs per point (4 for two), on a ParallelCluster 3.16 cluster in eu-north-1 in August 2026. Performance is the harness's MIUPS (million cell iterations per wall second). The runs of 87 of the 108 points agree within 5% (median spread 2.1%). On the AMD types, the widest spread, 11%, is `hpc7a.96xlarge` on 8 nodes for `aircraft_wing_14m`. On the Intel types, the three widest, 10–22%, are `hpc6id.32xlarge` on 4 × 32 for `aircraft_wing_14m`, and `m7i` and `r7i.48xlarge` on 8 nodes for `sedan_4m`.

Every value below is a ratio of medians: relative performance is the reference's time over the configuration's time, so higher is faster. The EC2 cost per run is nodes × time (× the On-Demand price, where instance types differ), relative to the reference.

The results in brief:

- **`hpc8a.96xlarge` is 1.48–1.67× `hpc7a.96xlarge` node for node**, and on 192 cores it ran the four smaller cases at the lowest EC2 cost per run of the three AMD instance types measured (0.66–0.74× `hpc7a.96xlarge`'s).
- **Of the Intel instance types, `c8i.96xlarge` ran the four smaller cases fastest and at the lowest EC2 cost per run** on 192 cores: `r8i.96xlarge` ran them 0.95–0.99× as fast, at 1.49–1.55× its EC2 cost per run.
- **More nodes cost little more per run while efficiency stays high:** 16 `hpc8a.96xlarge` nodes ran `f1_racecar_140m` 13.8× as fast as one, at 86% parallel efficiency, for 1.16× the EC2 cost per run.
- **With licences counted per core, spread the ranks:** `f1_racecar_140m` with the same total ranks on twice the nodes, at 96 per node, ran 1.49–1.64× as fast, for 0.61–0.67× the licence core-hours and 1.22–1.34× the EC2 cost per run.

### f1_racecar_140m on hpc8a and hpc7a

Every node is fully populated (192 ranks per node). Performance is relative to one `hpc7a.96xlarge` node = 1.00×. Parallel efficiency is the speed-up over one node of the same type divided by the node count, and the EC2 cost per run is nodes × time against one node of the same type.

![ANSYS Fluent f1_racecar_140m scaling on hpc8a and hpc7a, and the EC2 cost per run](https://github.com/aws-samples/hpc-applications/blob/main/Doc/img/Fluent/Fluent-f1_racecar_140m-Scaling.png?raw=true)

| Instance type | | 1 node | 2 nodes | 4 nodes | 8 nodes | 16 nodes |
|---|---|--:|--:|--:|--:|--:|
| `hpc8a.96xlarge` | Relative performance | 1.48× | 2.95× | 5.76× | 10.87× | 20.54× |
| | Parallel efficiency | — | 99% | 97% | 92% | 86% |
| | EC2 cost per run | 1.00× | 1.01× | 1.03× | 1.09× | 1.16× |
| `hpc7a.96xlarge` | Relative performance | 1.00× | 1.97× | 3.83× | 7.21× | 13.08× |
| | Parallel efficiency | — | 99% | 96% | 90% | 82% |
| | EC2 cost per run | 1.00× | 1.02× | 1.05× | 1.11× | 1.22× |

- `hpc8a.96xlarge` runs `f1_racecar_140m` 1.48–1.57× as fast as `hpc7a.96xlarge`, node for node.
- On 16 nodes (3,072 cores, about 46,000 cells per core), parallel efficiency is 82–86%, and the EC2 cost per run 1.16–1.22× that of one node.

### The same cores on more nodes

These runs spread a fixed number of `f1_racecar_140m` ranks over more nodes, at the flexible-cores counts of [Cores per node](#cores-per-node-flexible-cores). Values are relative to the fully populated shape of the same total = 1.00× (1 × 192 for 192 ranks, 2 × 192 for 384, 4 × 192 for 768, 8 × 192 for 1,536), and each row gives the range over the totals measured:

| Instance type | Ranks per node | Nodes, against full nodes | Totals measured (ranks) | Speed | EC2 cost per run | Licence core-hours per run |
|---|--:|--:|---|--:|--:|--:|
| `hpc8a.96xlarge` | 96 | 2× | 192–1,536 | 1.49–1.55× | 1.29–1.34× | 0.65–0.67× |
| | 48 | 4× | 192–768 | 1.77–1.79× | 2.24–2.26× | 0.56× |
| | 24 | 8× | 192, 384 | 1.85–1.87× | 4.28–4.32× | 0.53–0.54× |
| `hpc7a.96xlarge` | 96 | 2× | 192–1,536 | 1.60–1.64× | 1.22–1.25× | 0.61–0.62× |
| | 48 | 4× | 192–768 | 1.82–1.87× | 2.13–2.19× | 0.53–0.55× |
| | 24 | 8× | 192, 384 | 1.92–1.95× | 4.11–4.17× | 0.51–0.52× |

Speed is the reference's time over the shape's time. With the same total cores, the licence core-hours per run are 1 / speed; the EC2 cost per run is nodes × time on the same instance type.

![ANSYS Fluent f1_racecar_140m: the same ranks spread over more nodes](https://github.com/aws-samples/hpc-applications/blob/main/Doc/img/Fluent/Fluent-f1_racecar_140m-FlexibleCores.png?raw=true)

- 96 ranks per node gives most of the speed-up for the least extra EC2 cost.
- **Fewer ranks on the same nodes:** at the same node count, full nodes ran fastest. 96 ranks per node ran at 0.76–0.82× (`hpc8a.96xlarge`) and 0.82–0.91× (`hpc7a.96xlarge`) the speed of 192, for 0.61–0.66× and 0.55–0.61× the licence core-hours per run (1 to 16 nodes).
- **The four smaller cases agree** (2026 R1 harness, 192 ranks): on 2 × 96, `hpc8a.96xlarge` ran 1.33–1.52× and `hpc7a.96xlarge` 1.43–1.61× as fast as on one full node, for 1.32–1.50× and 1.24–1.40× the EC2 cost per run, and `hpc6a.48xlarge` on 4 × 48 ran 1.41–1.67× as fast as on 2 × 96 for 1.20–1.42×.
- On the Intel `hpc6id.32xlarge` (2026 R1 harness, 128 ranks), 4 × 32 ran the four smaller cases 1.19–1.38× as fast as 2 × 64, for 1.45–1.67× the EC2 cost per run.

### AMD instance types on the suite's smaller cases

On 192 cores (one node of `hpc8a.96xlarge` or `hpc7a.96xlarge`, two of `hpc6a.48xlarge`, every node fully populated), relative to one `hpc7a.96xlarge` node = 1.00×. The EC2 cost per run is nodes × time × the instance type's On-Demand Linux price in eu-north-1 (October 2026), relative to one `hpc7a.96xlarge` node.

![ANSYS Fluent on four smaller cases of the benchmark suite: three AMD instance types on 192 cores](https://github.com/aws-samples/hpc-applications/blob/main/Doc/img/Fluent/Fluent-InstanceTypes-192cores-AMD.png?raw=true)

| Instance type | Nodes × cores | `sedan_4m` | `aircraft_wing_14m` | `landing_gear_15m` | `lm6000_16m` | EC2 cost per run |
|---|---|--:|--:|--:|--:|--:|
| `hpc8a.96xlarge` | 1 × 192 | 1.49× | 1.53× | 1.54× | 1.67× | 0.66–0.74× |
| `hpc7a.96xlarge` | 1 × 192 | 1.00× | 1.00× | 1.00× | 1.00× | 1.00× |
| `hpc6a.48xlarge` | 2 × 96 | 0.84× | 0.87× | 0.88× | 1.01× | 0.79–0.95× |

The EC2 cost per run gives the range over the four cases. The runs of 11 of these 12 points agree within 5%; the other, `hpc6a.48xlarge` on two nodes for `sedan_4m`, spread 5.6%.

- `hpc8a.96xlarge` ran these cases 1.49–1.67× as fast as `hpc7a.96xlarge`, at 0.66–0.74× its EC2 cost per run, the lowest of the three.
- On 768 cores (4 nodes of `hpc8a.96xlarge` against 4 of `hpc7a.96xlarge`, 8 of `hpc6a.48xlarge`), `hpc8a.96xlarge` ran 1.51–1.58× as fast at 0.70–0.73× the EC2 cost per run, and `hpc6a.48xlarge` 0.84–0.90× as fast at 0.89–0.95×.

### Intel instance types on the suite's smaller cases

On 192 cores (one node of `c8i.96xlarge` or `r8i.96xlarge`, two of `m7i`, `r7i` or `c7i.48xlarge`, every node fully populated, SMT off), relative to one `c8i.96xlarge` node = 1.00×. The EC2 cost per run is nodes × time × the instance type's On-Demand Linux price in eu-north-1 (October 2026), relative to one `c8i.96xlarge` node.

![ANSYS Fluent on four smaller cases of the benchmark suite: five Intel instance types on 192 cores](https://github.com/aws-samples/hpc-applications/blob/main/Doc/img/Fluent/Fluent-InstanceTypes-192cores-Intel.png?raw=true)

| Instance type | Nodes × cores | `sedan_4m` | `aircraft_wing_14m` | `landing_gear_15m` | `lm6000_16m` | EC2 cost per run |
|---|---|--:|--:|--:|--:|--:|
| `c8i.96xlarge` | 1 × 192 | 1.00× | 1.00× | 1.00× | 1.00× | 1.00× |
| `r8i.96xlarge` | 1 × 192 | 0.95× | 0.98× | 0.98× | 0.99× | 1.49–1.55× |
| `m7i.48xlarge` | 2 × 96 | 0.76× | 0.80× | 0.79× | 0.79× | 1.33–1.41× |
| `r7i.48xlarge` | 2 × 96 | 0.75× | 0.80× | 0.80× | 0.84× | 1.68–1.88× |
| `c7i.48xlarge` | 2 × 96 | 0.71× | 0.75× | 0.78× | 0.82× | 1.17–1.35× |

The EC2 cost per run gives the range over the four cases. The runs of 14 of these 20 points agree within 5%; the other 6, all on two nodes of the 96-core types, spread up to 9.5%.

- `c8i.96xlarge` ran these cases the fastest of the five, at the lowest EC2 cost per run. `r8i.96xlarge` ran them 0.95–0.99× as fast, at 1.49–1.55× its EC2 cost per run, and two nodes of `c7i`, `m7i` or `r7i.48xlarge` 0.71–0.84× as fast, at 1.17–1.88×.
- `c8i.96xlarge` and `r8i.96xlarge` were measured on one node only. The 768-core runs of `c7i`, `m7i` and `r7i.48xlarge` (8 nodes) are given as their parallel efficiency against two nodes of the same type, under [Scalability](#scalability).
- `hpc6id.32xlarge` (64 cores per node) was measured on 128 and 512 cores, so it is not in this table.

# Contribute your results

The benchmark scripts in this folder call [`dynamodb/record-benchmark.sh`](dynamodb/record-benchmark.sh) after every successful run. The recorder saves the run as a small JSON record (`<record_id>.json`) and adds it to the shared AI-Powered HPC benchmark dataset when you have write access to it. That dataset trains a model that predicts HPC performance on AWS, so every result you share helps. Set `SOURCE=<YourOrg>` to tag your runs, and see [BENCHMARK-RECORDERS.md](../BENCHMARK-RECORDERS.md) for the options and how to send the record in.
