# OpenFOAM

This directory contains scripts for building and benchmarking [OpenFOAM v2512](https://www.openfoam.com/) on AWS HPC instances.

The scripts are organised by CPU architecture:

- [`x86/`](x86/) — builds and benchmarks for x86_64 (`hpc8a`, `hpc7a`, `hpc6a`, `m8a`, `c8i`)
- [`Arm/`](Arm/) — builds and benchmarks for aarch64 (`hpc7g` / Graviton3E, `m8g` / `r8g` / Graviton4)

## x86 builds

Three build variants are provided. All target OpenFOAM v2512 (openfoam.com release) and use 48 cores for compilation.

> **Recommendation:** Use the AVX-512 OpenMPI build (Option 1) on `hpc8a`, `hpc7a`, `m8a` and `c8i`: one binary runs on all four, and it is the build behind their results under [Performance](#performance). Use the AVX2 build (Option 3) on `hpc6a`, whose AMD EPYC 3rd Gen (Zen 3) processors have no AVX-512, and on any other x86 instance without it. On `hpc8a.96xlarge`, the AVX2 build ran `simpleFoam` within 2% of Option 1, and the Intel MPI build (Option 2) took 1.1–4.5% longer than Option 1.

### Option 1 — GCC 14 + OpenMPI (AVX-512, hpc8a-optimized)

Tuned for `hpc8a.96xlarge` (AMD EPYC 5th Gen / Zen 5 / Turin). The same binary runs on the other x86 instances with AVX-512: `hpc7a.96xlarge` (Zen 4), `m8a.48xlarge` (Zen 5) and `c8i.96xlarge` (Intel Xeon 6).

```bash
sbatch x86/build_openfoam_com_v2512_hpc8a_openmpi.sbatch
```

- Compiler: GCC 14
- Flags: `-O2 -march=x86-64-v4 -mtune=znver5` (AVX-512, FMA, Zen 5 tuning)
- MPI: OpenMPI 4.1.7 (system-provided, EFA-enabled)
- Install location: `/fsx/openfoam/x86_64/v2512`
- Environment script: `/fsx/openfoam/x86_64/openfoam-v2512-env.sh`
- Build time: ~40 minutes

### Option 2 — GCC 14 + Intel MPI (AVX-512, hpc8a-optimized)

Same compiler toolchain and flags as Option 1, but with Intel MPI:

```bash
sbatch x86/build_openfoam_com_v2512_hpc8a_intelmpi.sbatch
```

- Compiler: GCC 14
- Flags: `-O2 -march=x86-64-v4 -mtune=znver5`
- MPI: Intel MPI 2021.17 (EFA + MULTIRAIL enabled)
- Install location: `/fsx/openfoam/x86_64-intelmpi/v2512`
- Environment script: `/fsx/openfoam/x86_64-intelmpi/openfoam-v2512-env.sh`
- Build time: ~40 minutes

The build patches `OpenFOAM-v2512/etc/bashrc` to set `WM_MPLIB=INTELMPI` (the upstream default is `SYSTEMOPENMPI`).

On `hpc8a.96xlarge` with 192 ranks per node (OCC DrivAer 236M, May 2026, 3 or 4 runs each), `simpleFoam` took 1.1% longer with this build than with Option 1 on one node, and 3.6–4.5% longer on 2, 4 and 8 nodes.

### Option 3 — GCC + OpenMPI (AVX2, portable)

Portable binary for any x86 processor with AVX2, including those without AVX-512 such as the AMD EPYC 3rd Gen (Zen 3) of `hpc6a.48xlarge`, whose results under [Performance](#performance) use this build:

```bash
sbatch x86/build_openfoam_com_v2512_avx2.sbatch
```

- Compiler: system GCC (GCC 11 on Amazon Linux 2023)
- Flags: `-O2 -march=x86-64-v3 -mtune=generic` (AVX2 + FMA + BMI, no AVX-512)
- MPI: OpenMPI 4.1.7
- Install location: `/fsx/openfoam/x86_64-avx2/v2512`
- Environment script: `/fsx/openfoam/x86_64-avx2/openfoam-v2512-env.sh`
- Build time: ~35 minutes

On `hpc8a.96xlarge` (OCC DrivAer 236M, one run of this build on each of 1, 2, 4, 8 and 16 nodes), `simpleFoam` ran within 2% of Option 1 at every node count.

## Arm builds

A single build script targets all AWS Graviton processors (`hpc7g`, `m8g`, `r8g`). The Graviton generation is auto-detected at runtime from `/proc/cpuinfo` and the correct `-mcpu` flag is applied. Built with GCC 14 + OpenMPI and 48 cores for compilation.

> **Note:** We evaluated both GCC 14 and Arm Compiler for Linux (ACfL / `armclang`) on Graviton4 and measured nearly identical `simpleFoam` runtime (within 0.6% of each other on 1, 2, 4 and 8 nodes, OCC DrivAer 236M, one run of each build per node count and two of GCC 14 on one node). Since ACfL provides no meaningful advantage for this workload, only the GCC path is kept here.

```bash
# Graviton3E (hpc7g.16xlarge, 64 cores, Neoverse V1 / SVE 256-bit)
sbatch -p hpc7g --ntasks-per-node=64 \
  Arm/build_openfoam_com_v2512_arm.sbatch

# Graviton4 (m8g.48xlarge / r8g.48xlarge, 192 cores, Neoverse V2 / SVE2 128-bit)
sbatch -p m8g --ntasks-per-node=192 \
  Arm/build_openfoam_com_v2512_arm.sbatch
```

Compile flags:
- Graviton3E: `-O2 -mcpu=neoverse-v1 -mtune=neoverse-v1`
- Graviton4: `-O2 -mcpu=neoverse-v2 -mtune=neoverse-v2`

Install locations (named after the detected target):
- `/fsx/openfoam/aarch64-graviton3/v2512` with env script `aarch64-graviton3/openfoam-v2512-env.sh`
- `/fsx/openfoam/aarch64-graviton4/v2512` with env script `aarch64-graviton4/openfoam-v2512-env.sh`

To override auto-detection (e.g. cross-build or run on an instance whose CPU part isn't recognised), set `TARGET=graviton3` or `TARGET=graviton4` via `--export=ALL,TARGET=...`.

### Graviton results

`m8g.48xlarge` (Graviton4, this GCC 14 build, OpenMPI 5.0.9) is one of the six instance types under [Performance](#performance). On one node it ran `simpleFoam` 1.35× (236M) and 1.29× (65M) as fast as one `hpc7a.96xlarge`, which is 0.97× and 0.92× one `hpc8a.96xlarge`. Its parallel efficiency against one node was 82% (236M) and 80% (65M) on 4 nodes, and 59% and 47% on 8 (one run on 65M). `m8g.48xlarge` has 50 Gbps of network bandwidth, against 300 Gbps on `hpc7a.96xlarge` and `hpc8a.96xlarge`.

Graviton3E was measured on `c7gn.16xlarge` (64 cores, 128 GiB and 200 Gbps EFA: the processor, memory and network bandwidth of `hpc7g.16xlarge`), with the Graviton3E build and OpenMPI 5.0.9, on the 65M mesh, one run per node count (April 2026). Against one `hpc7a.96xlarge` node on 65M = 1.00×, it ran 0.95× on 2 nodes, 1.63× on 4 and 2.54× on 8, a parallel efficiency against 2 nodes of 86% on 4 and 67% on 8. On the same node counts, `m8g.48xlarge` ran 2.39×, 4.10× and 4.84× (one run on 8 nodes). The 65M mesh needs 2 or more of these 128 GiB nodes (see the memory note under [Benchmark](#benchmark)).

## Benchmark

The benchmark case is the [OCC DrivAer static-mesh](https://develop.openfoam.com/committees/hpc/-/tree/develop/incompressible/simpleFoam/occDrivAerStaticMesh) from the [1st OpenFOAM HPC Challenge](https://zenodo.org/records/15012221) — a steady-state external aerodynamics case using `simpleFoam`. Three mesh resolutions are available (65M / 110M / 236M cells); mesh tarballs are fetched from Zenodo on first run and cached under `/fsx/openfoam/occ-drivaer/`. The case runs 4,000 SIMPLE iterations as it ships; every result on this page ran 200 (see [Iterations](#iterations)).

### x86

```bash
# OpenMPI
sbatch --nodes=N x86/openfoam-benchmark-openmpi.sbatch

# Intel MPI
sbatch --nodes=N x86/openfoam-benchmark-intelmpi.sbatch
```

Both scripts run one MPI rank per core, 192 per node, on the `hpc8a` partition by default: a full `hpc8a.96xlarge`. `hpc7a.96xlarge`, `m8a.48xlarge` and `c8i.96xlarge` also have 192 cores, and run with the same defaults on their own partition (`-p`). On `hpc6a.48xlarge` (96 cores), run the AVX2 build (Option 3) at 96 ranks per node:

```bash
sbatch -p hpc6a --nodes=N --ntasks-per-node=96 \
  --export=ALL,OPENFOAM_ENV=/fsx/openfoam/x86_64-avx2/openfoam-v2512-env.sh \
  x86/openfoam-benchmark-openmpi.sbatch
```

They run the 236M mesh, which they record as `occDrivAer-236M`. The Arm launcher below selects the mesh with `MESH_SIZE`.

### Arm

A single launcher works for both Graviton generations — pick the right build via `OPENFOAM_ENV` and set the partition and core count accordingly. OpenMPI 5 is loaded at runtime because the default OpenMPI 4.1.7 cannot scale EFA endpoints to 192 ranks per node on Graviton4.

The mesh size is selectable via `MESH_SIZE` (65, 110, or 236 — millions of cells). Default is **65M (coarse)**, the mesh that fits a 64-core Graviton3E node's memory during the serial `decomposePar` phase. Use `MESH_SIZE=236` on Graviton4 for the full workload.

```bash
# Graviton3E (hpc7g, 64 cores/node) — 65M coarse mesh
sbatch -p hpc7g -N 4 --ntasks-per-node=64 \
  --export=ALL,OPENFOAM_ENV=/fsx/openfoam/aarch64-graviton3/openfoam-v2512-env.sh \
  Arm/openfoam-benchmark.sbatch

# Graviton4 (m8g, 192 cores/node) — 236M fine mesh
sbatch -p m8g -N 4 --ntasks-per-node=192 \
  --export=ALL,OPENFOAM_ENV=/fsx/openfoam/aarch64-graviton4/openfoam-v2512-env.sh,MESH_SIZE=236 \
  Arm/openfoam-benchmark.sbatch
```

> **Memory note:** The serial `decomposePar` of the 236M mesh needs more than the 128 GiB of one `hpc7g.16xlarge` — use `MESH_SIZE=65` (or `110`) on Graviton3E. On the 65M mesh, `simpleFoam` with 64 ranks also needs more memory than one 128 GiB node has (64 ranks × ~1M cells plus the GAMG multigrid coefficients), so run Graviton3E on **2 or more nodes**. Graviton4 (`m8g.48xlarge`, 768 GiB; `r8g.48xlarge`, 1,536 GiB) handles all three mesh sizes at any node count.

All benchmark scripts:
- Create a unique run directory under `/fsx/openfoam/Run/`
- Drop page caches and enable transparent huge pages before the run
- Use EFA for inter-node communication (plus MULTIRAIL for Intel MPI)
- Report timings for `decomposePar`, `renumberMesh`, `potentialFoam`, and `simpleFoam` separately

### Overrides

| Variable | Default | Description |
|----------|---------|-------------|
| `OPENFOAM_ENV` | see script | Path to OpenFOAM environment setup script |
| `MESH_SIZE` | `65` (Arm only) | Mesh resolution: `65`, `110`, or `236` million cells |
| `CASE_SRC` | `/fsx/openfoam/occ-drivaer/occDrivAerStaticMesh[-${MESH_SIZE}M]` | Case and mesh source directory |
| `BASE_DIR` | `/fsx/openfoam` | Root for run output directories |
| `TARGET` | `auto` (Arm build only) | Force compile target: `graviton3` or `graviton4` |

### Iterations

The case's `controlDict` runs 4,000 SIMPLE iterations (`endTime 4000`). Every result on this page ran 200: to compare with them, uncomment the `endTime` line in the benchmark script, which sets `endTime 200`. Leave it commented to run the case as it ships.

## Performance

AWS ran both meshes, 236M and 65M cells, on six instance types in October 2026, 200 iterations each, with every node fully populated: one MPI rank per core, 192 per node (96 on `hpc6a.48xlarge`). Each run took the steps of the benchmark scripts here: the page cache dropped and transparent huge pages set to `always`, the case decomposed with the scripts' `simple` method (`n (nodes 1 ranks-per-node)`), then `renumberMesh`, `potentialFoam` and `simpleFoam`. Each layout (mesh, nodes and ranks per node) was decomposed once and copied into each of its runs (see [Key Metrics](#key-metrics)). `hpc8a`, `hpc7a`, `m8a` and `c8i` ran the AVX-512 OpenMPI build (Option 1) and `hpc6a.48xlarge` the AVX2 build (Option 3), both with OpenMPI 4.1.7 and one rank bound to each core (`--bind-to core --map-by slot`); `m8g.48xlarge` ran the Graviton4 build with OpenMPI 5.0.9. On 236M, `hpc8a.96xlarge` comes from May 2026 runs of the same phases with the same build options and MPI, which decomposed in the job.

Performance is the `simpleFoam` time (see [Key Metrics](#key-metrics)), the median over each configuration's runs, relative to one `hpc7a.96xlarge` node on the same mesh = 1.00×; higher is faster. In parentheses: the parallel efficiency, the speed-up over the same instance type's smallest node count divided by the node-count ratio. Values are medians of 2 to 4 runs, except where marked ¹ (a single run). The runs of each configuration spread by at most 4.0% from fastest to slowest (median 0.8%); the October runs had 0 to 8 other benchmark jobs sharing their FSx for Lustre file system.

### OCC DrivAer 236M

![OpenFOAM OCC DrivAer 236M scaling on six instance types](https://github.com/aws-samples/hpc-applications/blob/main/Doc/img/OpenFoam/OpenFOAM-OCCDrivAer-236M-Scaling.png?raw=true)

| Nodes | hpc8a.96xlarge | c8i.96xlarge | m8a.48xlarge | m8g.48xlarge | hpc7a.96xlarge | hpc6a.48xlarge |
|------:|---------------:|-------------:|-------------:|-------------:|---------------:|---------------:|
| 1 | 1.39× | 1.52× | 1.38×¹ | 1.35× | 1.00× | — |
| 2 | 2.78× (100%) | 2.88× (94%) | — | 2.49× (92%) | 1.93× (96%) | 0.84× |
| 4 | 5.01× (90%) | — | — | 4.44× (82%) | 3.59× (90%) | 1.58× (94%) |
| 8 | 8.08× (73%) | — | — | 6.42× (59%) | 5.61× (70%) | 2.57× (76%) |
| 16 | 9.85×¹ (44%) | — | — | — | 6.74× (42%) | 3.51× (52%) |

`hpc6a.48xlarge` was run on 2 to 16 nodes, so its efficiency is against 2 nodes.

- `hpc8a.96xlarge` is 1.39–1.46× `hpc7a.96xlarge` at every node count from 1 to 16 (1.46× on 16 nodes, from one run).
- On one node, `c8i.96xlarge` leads (1.52×, or 1.10× `hpc8a`), and on two it is 1.04× `hpc8a`. `m8a.48xlarge` is 0.99× `hpc8a` on one node (one run).
- `m8g.48xlarge` (Graviton4) is 1.35× on one node and keeps 82% efficiency on 4 nodes; on 8 it is at 59%.
- 16 nodes still run faster than 8, but at 42–52% efficiency: 1.22× as fast on `hpc8a`, 1.20× on `hpc7a` and 1.37× on `hpc6a`, for twice the nodes (`hpc8a` from one run on 16 nodes).

### OCC DrivAer 65M

![OpenFOAM OCC DrivAer 65M scaling on six instance types](https://github.com/aws-samples/hpc-applications/blob/main/Doc/img/OpenFoam/OpenFOAM-OCCDrivAer-65M-Scaling.png?raw=true)

| Nodes | hpc8a.96xlarge | c8i.96xlarge | m8a.48xlarge | m8g.48xlarge | hpc7a.96xlarge | hpc6a.48xlarge |
|------:|---------------:|-------------:|-------------:|-------------:|---------------:|---------------:|
| 1 | 1.40× | 1.70× | 1.35×¹ | 1.29× | 1.00× | 0.41× |
| 2 | 2.85× (102%) | 2.68× (79%) | — | 2.39× (93%) | 1.99× (100%) | 0.84× (103%) |
| 4 | 4.77× (85%) | — | — | 4.10× (80%) | 3.77× (94%) | 1.65× (100%) |
| 8 | 6.29× (56%) | — | — | 4.84×¹ (47%) | 5.32× (66%) | 2.60× (79%) |
| 16 | — | — | — | — | — | 3.45× (53%) |

- `hpc8a.96xlarge` is 1.40× and 1.43× `hpc7a.96xlarge` on 1 and 2 nodes, and 1.26× and 1.18× on 4 and 8: on the smaller mesh, `hpc8a` reaches the end of its scaling first (56% efficiency on 8 nodes, where `hpc7a` keeps 66%).
- On one node, `c8i.96xlarge` leads (1.70×, or 1.21× `hpc8a`), but on two it falls to 79% efficiency and 0.94× `hpc8a`. `m8a.48xlarge` is 0.97× `hpc8a` on one node (one run).
- One `hpc6a.48xlarge` node (96 cores) delivers 0.41× one `hpc7a.96xlarge` node (192 cores), and keeps 79% efficiency up to 8 nodes.

### Where scaling stops paying

On one instance type, the node-hours of a run, and so its EC2 cost, grow as 1 / efficiency against the type's smallest node count: at 60% efficiency a run costs 1.67× as much as on the smallest node count. Taking the first node count under 60% as the point where scaling stops paying:

- **236M:** 16 nodes of `hpc8a`, `hpc7a` and `hpc6a` (44% from one run, 42% and 52%), and 8 of `m8g` (59%). `c8i` kept 94% on 2 nodes, the most it was run on.
- **65M:** 8 nodes of `hpc8a` and `m8g` (56%, and 47% from one run), and 16 of `hpc6a` (53%). `hpc7a` kept 66% on 8 nodes and `c8i` 79% on 2, the most each was run on.
- On `hpc8a.96xlarge`, efficiency stayed at 60% or more down to about 85,000 cells per core (236M on 8 nodes is about 153,000 cells per core, 65M on 4 nodes about 85,000), and was under 60% at 77,000 or fewer (236M on 16 nodes, one run; 65M on 8 nodes, about 43,000).

### Fewer ranks per node

`simpleFoam` is memory-bandwidth bound, so fewer ranks per node give each rank more bandwidth. That paid only on a single node:

- On one `hpc7a.96xlarge` (236M, October 2026, 3 runs at 96 ranks per node, 2 at 192), 96 ranks ran 1.08× as fast as 192. On two nodes, 96 ranks per node ran 0.99× as fast as 192 per node.
- On `hpc8a.96xlarge` (236M, May 2026, the OpenMPI build, 3 runs per point, 4 on 2 nodes at 96 and 192 ranks per node), relative to 192 ranks per node on the same node count:

| Ranks per node | 1 node | 2 nodes | 4 nodes | 8 nodes |
|---------------:|-------:|--------:|--------:|--------:|
| 48 | 1.14× | 0.93× | 0.66× | 0.50× |
| 72 | 1.16× | 0.96× | 0.81× | 0.62× |
| 96 | 1.10× | 0.98× | 0.86× | 0.70× |
| 120 | 1.09× | 0.99× | 0.89× | 0.78× |
| 144 | 1.07× | 1.01× | 0.91× | 0.84× |
| 168 | 1.03× | 1.00× | 0.99× | 0.93× |
| 192 | 1.00× | 1.00× | 1.00× | 1.00× |

So fill the nodes, except on a single node, where 48 to 96 ranks ran 1.10–1.16× as fast as 192. Every under-populated run here placed its ranks with the [flexible-cores](../../Utils/flexible-cores) list for its count, which puts the same number of ranks on each of the 24 CCDs of `hpc8a.96xlarge` and `hpc7a.96xlarge`. The OpenMPI benchmark scripts bind rank *i* to core *i* (`--bind-to core --map-by slot`), which is right for a full node; with fewer ranks per node it fills the first cores and leaves the others idle, and the Intel MPI script leaves the placement to Intel MPI. To run fewer ranks per node, bind them to the list instead, as the explicit scripts in [Utils/flexible-cores](../../Utils/flexible-cores) do: in the x86 OpenMPI script, replace `--bind-to core --map-by slot` in `MPI_FLAGS` with `--bind-to cpu-list:ordered --cpu-list <list>`; for the Intel MPI script, set `I_MPI_PIN_PROCESSOR_LIST=<list>` in the environment you submit it from (`sbatch` passes it on).

### Choosing an instance type

- **Per node,** `c8i.96xlarge` was the fastest: 1.52× (236M) and 1.70× (65M) one `hpc7a.96xlarge`. Then `hpc8a.96xlarge` (1.39× and 1.40×), `m8a.48xlarge` (1.38× and 1.35×, one run each), `m8g.48xlarge` (1.35× and 1.29×) and `hpc7a.96xlarge`. `hpc6a.48xlarge`, with half the cores, delivered 0.41× on 65M.
- **Per cluster,** at 4 nodes and more `hpc8a.96xlarge` was the fastest type measured (`c8i` was run on 1 and 2 nodes, `m8a` on 1). On 1,536 cores, 8 `hpc8a.96xlarge` nodes ran 236M 8.08× and 65M 6.29× as fast as one `hpc7a.96xlarge`, against 6.42× and 4.84× (one run) on 8 `m8g.48xlarge`, 5.61× and 5.32× on 8 `hpc7a.96xlarge`, and 3.51× and 3.45× on 16 `hpc6a.48xlarge`.
- **For more than one node,** compare the network bandwidth per node as well: 300 Gbps of EFA on `hpc8a.96xlarge` and `hpc7a.96xlarge`, 100 Gbps on `c8i.96xlarge` and `hpc6a.48xlarge`, 75 Gbps on `m8a.48xlarge` and 50 Gbps on `m8g.48xlarge`.

## Key Metrics

- **`simpleFoam` time** — steady-state solver wall time for the configured number of iterations (the primary scaling metric)
- **`decomposePar` time** — domain decomposition cost (grows with the number of subdomains; dominant at high scale)
- **`renumberMesh` / `potentialFoam` time** — setup phase cost

Compare runs on the `simpleFoam` time, which the benchmark scripts pass to the recorder as the time to solution, not on the `Total` they also print: `decomposePar` is serial, and it takes longer the more subdomains it writes. OCC DrivAer 236M, 200 iterations, `hpc8a.96xlarge` at 192 cores per node, May 2026, medians of 6 or 7 runs across the OpenMPI and Intel MPI builds, as relative performance of each phase (the 1-node time divided by the time, so 1 node = 1.00 and higher is faster):

| Nodes | `decomposePar` | `simpleFoam` | `decomposePar` to the end of `simpleFoam` | `decomposePar` time over `simpleFoam` time |
|------:|------:|------:|------:|------:|
| 1 | 1.00 | 1.00 | 1.00 | 0.13 |
| 2 | 0.90 | 2.01 | 1.72 | 0.30 |
| 4 | 0.79 | 3.56 | 2.50 | 0.60 |
| 8 | 0.57 | 5.74 | 2.77 | 1.35 |
| 16 (1 run) | 0.24 | 7.13 | 1.65 | 3.92 |

From 8 nodes on, decomposing took longer than solving, and the total makes 16 nodes look slower than 4 while the solve is twice as fast. The runs shared the cluster's FSx for Lustre file system with other runs of the same study, launched in waves whose `decomposePar` phases overlapped: each 1-node run and six of the seven 2-node runs had 13 others alongside, each 4-node run 6, each 8-node run 2 or 3, and the 16-node run 1. Contention was heaviest at the low node counts, so it does not explain the growth; the seventh 2-node run, made alone, decomposed in 13% less time than the 2-node median. `decomposePar` also runs on a single core while the job holds all its nodes, so for a multi-node study it is cheaper to decompose each layout once, in a single-node job, and copy the decomposed case into each run.

The October runs under [Performance](#performance) were made that way: each layout (mesh, nodes and ranks per node) was decomposed once in a single-node job, and every run copied the decomposed case into its run directory. The copy took 0.2–4.7% as long as `simpleFoam` (at most 3.2% on 236M; 4.7% on 65M on 8 `hpc8a.96xlarge` nodes), where in the May runs above `decomposePar` took 0.13 to 3.92 times as long as `simpleFoam`. The time to compare is the whole `simpleFoam` phase the scripts time, from the `mpirun` that starts it to its exit, so it includes reading the decomposed mesh: OpenFOAM's own final `ClockTime` in `log.solver` was 0.97–1.00 of it in the October runs.

## Files

### x86 (`x86/`)

| File | Description |
|------|-------------|
| `build_openfoam_com_v2512_hpc8a_openmpi.sbatch` | Build OpenFOAM v2512 with GCC 14 + OpenMPI (AVX-512, hpc8a) |
| `build_openfoam_com_v2512_hpc8a_intelmpi.sbatch` | Build OpenFOAM v2512 with GCC 14 + Intel MPI (AVX-512, hpc8a) |
| `build_openfoam_com_v2512_avx2.sbatch` | Build OpenFOAM v2512 with GCC + OpenMPI (AVX2, portable) |
| `openfoam-benchmark-openmpi.sbatch` | OCC DrivAer 236M benchmark with OpenMPI |
| `openfoam-benchmark-intelmpi.sbatch` | OCC DrivAer 236M benchmark with Intel MPI |

### Arm (`Arm/`)

| File | Description |
|------|-------------|
| `build_openfoam_com_v2512_arm.sbatch` | Build OpenFOAM v2512 with GCC 14 + OpenMPI (auto-detects Graviton3E or Graviton4) |
| `openfoam-benchmark.sbatch` | OCC DrivAer benchmark with OpenMPI 5 + EFA (Graviton3E/4; mesh selectable via `MESH_SIZE`, default 65M) |

## Contribute your results

The benchmark scripts in this folder call [`dynamodb/record-benchmark.sh`](dynamodb/record-benchmark.sh) after every successful run. The recorder saves the run as a small JSON record (`<record_id>.json`) and adds it to the shared AI-Powered HPC benchmark dataset when you have write access to it. That dataset trains a model that predicts HPC performance on AWS, so every result you share helps. Set `SOURCE=<YourOrg>` to tag your runs, and see [BENCHMARK-RECORDERS.md](../BENCHMARK-RECORDERS.md) for the options and how to send the record in.
