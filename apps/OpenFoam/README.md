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

The results of these builds are under [Graviton: m8g.48xlarge and c7gn.16xlarge](#graviton-m8g48xlarge-and-c7gn16xlarge): `m8g.48xlarge` with the Graviton4 build, on both meshes, and `c7gn.16xlarge`, which has the processor, memory and network bandwidth of `hpc7g.16xlarge`, with the Graviton3E build, on the 65M mesh.

## Benchmark

The benchmark case is the [OCC DrivAer static-mesh](https://develop.openfoam.com/committees/hpc/-/tree/develop/incompressible/simpleFoam/occDrivAerStaticMesh) from the [1st OpenFOAM HPC Challenge](https://zenodo.org/records/15012221) — a steady-state external aerodynamics case using `simpleFoam`. Three mesh resolutions are available (65M / 110M / 236M cells); mesh tarballs are fetched from Zenodo on first run and cached under `/fsx/openfoam/occ-drivaer/`. The case runs 4,000 SIMPLE iterations as it ships; the benchmark scripts run 200, as every result on this page did (see [Iterations](#iterations)).

### x86

```bash
# OpenMPI
sbatch --nodes=N x86/openfoam-benchmark-openmpi.sbatch

# Intel MPI
sbatch --nodes=N x86/openfoam-benchmark-intelmpi.sbatch
```

Without `--nodes`, the two scripts run on 8 nodes of their default instance type, `hpc8a.96xlarge`: the largest node count at which it kept 60% efficiency or more on the 236M mesh (see [Where scaling stops paying](#where-scaling-stops-paying)). Their time limit fits 200 iterations there (the default `END_TIME`), with `decomposePar` in the job and the mesh already in `CASE_SRC`; give a longer `--time` for fewer nodes, another instance type, more iterations, or a first run, which downloads and extracts the mesh in the job. A job that ends while it extracts the mesh leaves a partial `constant/polyMesh` in `CASE_SRC`, which later runs take as the mesh: delete that directory before the next run.

Both scripts run one MPI rank per core, 192 per node, on the `hpc8a` partition by default: a full `hpc8a.96xlarge`. `hpc7a.96xlarge`, `m8a.48xlarge` and `c8i.96xlarge` also have 192 cores, and run with the same defaults on their own partition (`-p`). On `hpc6a.48xlarge` (96 cores), run the AVX2 build (Option 3) at 96 ranks per node, with a time limit for the node count (`--time`):

```bash
sbatch -p hpc6a --nodes=N --ntasks-per-node=96 --time=HH:MM:SS \
  --export=ALL,OPENFOAM_ENV=/fsx/openfoam/x86_64-avx2/openfoam-v2512-env.sh \
  x86/openfoam-benchmark-openmpi.sbatch
```

They run the case and mesh in `CASE_SRC`, the 236M mesh by default; the Arm launcher below selects the mesh with `MESH_SIZE`. Every benchmark script records the mesh it ran by the cell count OpenFOAM writes in the header of `constant/polyMesh/owner`, in millions (`occDrivAer-236M` for the 236M mesh), and the number of iterations (`endTime`); a mesh whose header gives no cell count, or fewer than half a million cells, is not recorded, and a NOTE says which.

### Arm

A single launcher works for both Graviton generations — pick the right build via `OPENFOAM_ENV` and set the partition and core count accordingly. The launcher loads OpenMPI 5 at run time: Graviton4 at 192 ranks per node over EFA needs it rather than the default OpenMPI 4.1.7.

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
- Run `decomposePar` in the job, or copy a decomposition an earlier run saved (`DECOMP_CACHE`, see [Reusing a decomposition](#reusing-a-decomposition))
- Report timings for `decomposePar`, `renumberMesh`, `potentialFoam`, and `simpleFoam` separately
- Record the run (see [Contribute your results](#contribute-your-results)) only when `simpleFoam` completed every iteration on every rank: `log.solver` ends with `End` after its last iteration, which is `endTime`, its `nProcs` is the number of ranks of the job, and no log reports a `FOAM FATAL` error or a rank that ended on a signal. Otherwise they print a NOTE that says why, and the job's exit status and report are unchanged

### Overrides

| Variable | Default | Description |
|----------|---------|-------------|
| `OPENFOAM_ENV` | see script | Path to OpenFOAM environment setup script |
| `MESH_SIZE` | `65` (Arm only) | Mesh resolution: `65`, `110`, or `236` million cells |
| `END_TIME` | `200` | SIMPLE iterations (`endTime`): see [Iterations](#iterations) |
| `CASE_SRC` | `/fsx/openfoam/occ-drivaer/occDrivAerStaticMesh[-${MESH_SIZE}M]` | Case and mesh source directory |
| `BASE_DIR` | `/fsx/openfoam` | Root for run output directories |
| `DECOMP_CACHE` | unset | Directory (absolute path) to save each case and layout's decomposition in and reuse it from: see [Reusing a decomposition](#reusing-a-decomposition) |
| `TARGET` | `auto` (Arm build only) | Force compile target: `graviton3` or `graviton4` |

### Reusing a decomposition

`decomposePar` is serial, takes longer the more subdomains it writes (see [Key Metrics](#key-metrics)), and runs while the job holds all its nodes. To run it once per layout, set `DECOMP_CACHE` to a directory on the shared file system:

```bash
sbatch --nodes=8 --export=ALL,DECOMP_CACHE=/fsx/openfoam/decomposed x86/openfoam-benchmark-openmpi.sbatch
```

- A run that finds no saved decomposition of its case and layout runs `decomposePar` as before, then saves its `processor*` directories to `$DECOMP_CACHE/<case directory name>/<nodes>x<ranks per node>/`, before `renumberMesh` changes them. The decomposition time that run reports is `decomposePar`'s alone; its `Total` also includes the copy into `DECOMP_CACHE`, which no phase reports.
- A later run of the same case and layout copies them into its run directory instead of running `decomposePar`, with any of the benchmark scripts: the decomposition does not depend on the MPI, and the October runs under [Performance](#performance) used the same decompositions on x86 and Graviton instances. The decomposition time it reports is then the copy's.
- A saved decomposition is used only if it was made from the same `decomposeParDict` and from case files of the same names, sizes and modification times: `0.orig`, `constant/polyMesh`, and `system/include` if the case has one (the OCC DrivAer fields include `system/include/caseDefinition`, and `decomposePar` writes its values into the decomposed fields). Any other, or an incomplete one, is left as it is and the run decomposes in the job; delete its directory to save a new one.
- The report says which: `Decomposed: decomposePar in this job` (with `, saved to <directory>` when the run saved its decomposition) or `Decomposed: reused from <directory>`.
- A saved decomposition takes as much space as the `processor*` directories of a run. The run copies them into a directory it creates, `<directory>.partial.<cluster>.<job id>.<process id>`, and renames it once the copy is complete. If the save cannot be completed, the run removes that directory and goes on. A job ended while it saves (at its time limit, for example) removes it when Slurm signals the end, as far as it gets before Slurm stops the job: delete any such directory that is left by hand.
- Keep `DECOMP_CACHE` in a directory that only the people who run these benchmarks can write: a later run copies a saved decomposition into its case as it is, and OpenFOAM reads it, and runs any code its dictionaries hold (`#codeStream`), as it does the case's own files.

### Iterations

The case's `controlDict` runs 4,000 SIMPLE iterations (`endTime 4000`). The benchmark scripts set `endTime` to `END_TIME`, 200 by default, which every result on this page ran, so a run compares with them as it is. To run the case as it ships, set `END_TIME=4000` (`--export=ALL,END_TIME=4000`) and give the job a time limit to match (`--time`). The scripts refuse an `END_TIME` that is not a whole number of iterations, 1 or more, before they create the run directory.

## Performance

AWS ran both meshes, 236M and 65M cells, on four AMD instance types (`hpc8a`, `m8a`, `hpc7a`, `hpc6a`), one Intel type (`c8i`) and one Graviton type (`m8g`) in October 2026, 200 iterations each, with every node fully populated: one MPI rank per core, 192 per node (96 on `hpc6a.48xlarge`). Each run took the steps of the benchmark scripts here: the page cache dropped and transparent huge pages set to `always`, the case decomposed with the scripts' `simple` method (`n (nodes 1 ranks-per-node)`), then `renumberMesh`, `potentialFoam` and `simpleFoam`. Each layout (mesh, nodes and ranks per node) was decomposed once and copied into each of its runs (see [Key Metrics](#key-metrics)). `hpc8a`, `hpc7a`, `m8a` and `c8i` ran the AVX-512 OpenMPI build (Option 1) and `hpc6a.48xlarge` the AVX2 build (Option 3), both with OpenMPI 4.1.7 and one rank bound to each core (`--bind-to core --map-by slot`); `m8g.48xlarge` ran the Graviton4 build with OpenMPI 5.0.9. On 236M, `hpc8a.96xlarge` comes from May 2026 runs of the same phases with the same build options and MPI, which decomposed in the job. Graviton3E was run on `c7gn.16xlarge` in April 2026 (see [Graviton](#graviton-m8g48xlarge-and-c7gn16xlarge)).

Performance is the `simpleFoam` time (see [Key Metrics](#key-metrics)), the median over each configuration's runs, relative to one node of the same CPU vendor on the same mesh = 1.00×: `hpc7a.96xlarge` for the AMD types, `c8i.96xlarge` for Intel and `m8g.48xlarge` for Graviton; higher is faster. In parentheses: the parallel efficiency, the speed-up over the same instance type's smallest node count divided by the node-count ratio. Values are medians of 2 to 5 runs, except where marked ¹ (a single run). The runs of each configuration spread by at most 4.0% from fastest to slowest (median 0.8%); the October runs had 0 to 8 other benchmark jobs sharing their FSx for Lustre file system.

### OCC DrivAer 236M

On the AMD instance types, against one `hpc7a.96xlarge` node:

![OpenFOAM OCC DrivAer 236M scaling on four AMD instance types](https://github.com/aws-samples/hpc-applications/blob/main/Doc/img/OpenFoam/OpenFOAM-OCCDrivAer-236M-Scaling.png?raw=true)

| Nodes | hpc8a.96xlarge | m8a.48xlarge | hpc7a.96xlarge | hpc6a.48xlarge |
|------:|---------------:|-------------:|---------------:|---------------:|
| 1 | 1.39× | 1.38×¹ | 1.00× | — |
| 2 | 2.78× (100%) | — | 1.93× (96%) | 0.84× |
| 4 | 5.01× (90%) | — | 3.59× (90%) | 1.58× (94%) |
| 8 | 8.08× (73%) | — | 5.61× (70%) | 2.57× (76%) |
| 16 | 9.85×¹ (44%) | — | 6.74× (42%) | 3.51× (52%) |

`hpc6a.48xlarge` was run on 2 to 16 nodes, so its efficiency is against 2 nodes.

- `hpc8a.96xlarge` is 1.39–1.46× `hpc7a.96xlarge` at every node count from 1 to 16 (1.46× on 16 nodes, from one run).
- On one node, `m8a.48xlarge` is 0.99× `hpc8a` (one run).
- 16 nodes still run faster than 8, but at 42–52% efficiency: 1.22× as fast on `hpc8a`, 1.20× on `hpc7a` and 1.37× on `hpc6a`, for twice the nodes (`hpc8a` from one run on 16 nodes).

### OCC DrivAer 65M

On the AMD instance types, against one `hpc7a.96xlarge` node:

![OpenFOAM OCC DrivAer 65M scaling on four AMD instance types](https://github.com/aws-samples/hpc-applications/blob/main/Doc/img/OpenFoam/OpenFOAM-OCCDrivAer-65M-Scaling.png?raw=true)

| Nodes | hpc8a.96xlarge | m8a.48xlarge | hpc7a.96xlarge | hpc6a.48xlarge |
|------:|---------------:|-------------:|---------------:|---------------:|
| 1 | 1.40× | 1.35×¹ | 1.00× | 0.41× |
| 2 | 2.85× (102%) | — | 1.99× (100%) | 0.84× (103%) |
| 4 | 4.77× (85%) | — | 3.77× (94%) | 1.65× (100%) |
| 8 | 6.29× (56%) | — | 5.32× (66%) | 2.60× (79%) |
| 16 | — | — | — | 3.45× (53%) |

- `hpc8a.96xlarge` is 1.40× and 1.43× `hpc7a.96xlarge` on 1 and 2 nodes, and 1.26× and 1.18× on 4 and 8: on the smaller mesh, `hpc8a` reaches the end of its scaling first (56% efficiency on 8 nodes, where `hpc7a` keeps 66%).
- On one node, `m8a.48xlarge` is 0.97× `hpc8a` (one run).
- One `hpc6a.48xlarge` node (96 cores) delivers 0.41× one `hpc7a.96xlarge` node (192 cores), and keeps 79% efficiency up to 8 nodes.

### Intel: c8i.96xlarge

`c8i.96xlarge` (Intel Xeon 6) ran both meshes on 1 and 2 nodes, 3 runs each. Relative to one `c8i.96xlarge` node on the same mesh:

| Nodes | c8i.96xlarge, 236M | c8i.96xlarge, 65M |
|------:|-------------------:|------------------:|
| 1 | 1.00× | 1.00× |
| 2 | 1.89× (94%) | 1.58× (79%) |

On the smaller mesh the second node adds less: 79% efficiency on 65M, against 94% on 236M.

### Graviton: m8g.48xlarge and c7gn.16xlarge

`m8g.48xlarge` (Graviton4, 192 cores) ran both meshes on 1 to 8 nodes, with the Graviton4 build and OpenMPI 5.0.9. Graviton3E was measured on `c7gn.16xlarge` (64 cores, 128 GiB and 200 Gbps EFA: the processor, memory and network bandwidth of `hpc7g.16xlarge`), with the Graviton3E build and OpenMPI 5.0.9, on the 65M mesh, one run per node count (April 2026); the 65M mesh needs 2 or more of these 128 GiB nodes (see the memory note under [Benchmark](#benchmark)). Both are given against one `m8g.48xlarge` node on the same mesh:

![OpenFOAM OCC DrivAer scaling on Graviton](https://github.com/aws-samples/hpc-applications/blob/main/Doc/img/OpenFoam/OpenFOAM-OCCDrivAer-Graviton-Scaling.png?raw=true)

| Nodes | m8g.48xlarge, 236M | m8g.48xlarge, 65M | c7gn.16xlarge, 65M |
|------:|-------------------:|------------------:|-------------------:|
| 1 | 1.00× | 1.00× | — |
| 2 | 1.84× (92%) | 1.86× (93%) | 0.74×¹ |
| 4 | 3.28× (82%) | 3.19× (80%) | 1.27×¹ (86%) |
| 8 | 4.74× (59%) | 3.77×¹ (47%) | 1.98×¹ (67%) |

`c7gn.16xlarge` was run on 2 to 8 nodes, so its efficiency is against 2 nodes.

- `m8g.48xlarge` keeps 92% (236M) and 93% (65M) efficiency on 2 nodes and 82% and 80% on 4; on 8 it is at 59% and 47% (one run on 65M).
- On 65M, `c7gn.16xlarge` (64 cores per node) ran 0.74× on 2 nodes, 1.27× on 4 and 1.98× on 8, a parallel efficiency against 2 nodes of 86% on 4 and 67% on 8. On the same node counts, `m8g.48xlarge` (192 cores per node) ran 1.86×, 3.19× and 3.77× (one run on 8 nodes).

### Where scaling stops paying

On one instance type, the node-hours of a run, and so its EC2 cost, grow as 1 / efficiency against the type's smallest node count: at 60% efficiency a run costs 1.67× as much as on the smallest node count. Taking the first node count under 60% as the point where scaling stops paying:

- **AMD:** on 236M, 16 nodes of `hpc8a`, `hpc7a` and `hpc6a` (44% from one run, 42% and 52%); on 65M, 8 nodes of `hpc8a` (56%) and 16 of `hpc6a` (53%), while `hpc7a` kept 66% on 8 nodes, the most it was run on.
- **Intel:** `c8i` kept 94% (236M) and 79% (65M) on 2 nodes, the most it was run on.
- **Graviton:** 8 nodes of `m8g` on both meshes (59% on 236M, and 47% on 65M from one run). `c7gn` kept 67% on 8 nodes of 65M against 2 nodes (one run each), the most it was run on.
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

So fill the nodes, except on a single node, where 48 to 96 ranks ran 1.10–1.16× as fast as 192. Every under-populated run here placed its ranks with the [flexible-cores](../../Utils/flexible-cores) list for its count, which puts the same number of ranks on each of the 24 CCDs of `hpc8a.96xlarge` and `hpc7a.96xlarge`. The x86 benchmark scripts do the same on those two types: with fewer than 192 ranks per node (`--ntasks-per-node`), the solver phases bind them to the list for the count, `--bind-to cpu-list:ordered --cpu-list <list>` in place of `--bind-to core --map-by slot` in the OpenMPI script, and `I_MPI_PIN_PROCESSOR_LIST=<list>` in the Intel MPI script. There they refuse any count but 24, 48, 72, 96, 120, 144, 168 and 192 before the run starts, since it would load the CCDs unevenly. On other instance types they use no list: the OpenMPI scripts bind rank *i* to core *i*, which is right for a full node but fills the first cores of a node with fewer ranks, and the Intel MPI script leaves the placement to Intel MPI. To run fewer ranks per node there, set `BIND_FLAGS` in the x86 OpenMPI script's rank placement block, or `I_MPI_PIN_PROCESSOR_LIST` in the environment you submit the Intel MPI script from, to a list for the type's L3 layout (see [Other AMD instance types](../../Utils/flexible-cores/Readme.md#other-amd-instance-types)).

When IMDS gives no instance type (no answer within a few seconds, an error, or an answer that is not an instance type name), `lscpu` decides. A node with 192 AMD cores (sockets × cores per socket) could be either type, so the x86 scripts treat it as one of them: a supported count is bound to its list and any other is refused, naming both types, after a NOTE that says why. Any other node runs with no list, and a one-line NOTE on stderr says that the check was skipped. A full node (192 ranks per node) runs with one rank per core and no list, and prints no NOTE, whatever IMDS answers. No run is refused only because IMDS did not answer.

### Choosing an instance type

- **Per node,** of the AMD types, `hpc8a.96xlarge` was the fastest: 1.39× (236M) and 1.40× (65M) one `hpc7a.96xlarge`. Then `m8a.48xlarge` (1.38× and 1.35×, one run each) and `hpc7a.96xlarge`. `hpc6a.48xlarge`, with half the cores, delivered 0.41× on 65M.
- **Per cluster,** from 2 nodes on, `hpc8a.96xlarge` was the fastest of the AMD types measured (`m8a` was run on 1 node). On 1,536 cores, 8 `hpc8a.96xlarge` nodes ran 236M 8.08× and 65M 6.29× as fast as one `hpc7a.96xlarge`, against 5.61× and 5.32× on 8 `hpc7a.96xlarge`, and 3.51× and 3.45× on 16 `hpc6a.48xlarge`.
- **On Graviton,** `m8g.48xlarge` was the faster type per node and per cluster: two `c7gn.16xlarge` nodes ran 65M 0.74× as fast as one `m8g.48xlarge`, and eight 1.98× (one run), against 3.77× (one run) on eight `m8g.48xlarge`.
- **For more than one node,** the network bandwidth per node matters as well: EC2 gives 300 Gbps of EFA bandwidth to `hpc8a.96xlarge` and `hpc7a.96xlarge`, 100 Gbps to `hpc6a.48xlarge` and 75 Gbps to `m8a.48xlarge`; 100 Gbps to `c8i.96xlarge`; and 200 Gbps to `c7gn.16xlarge` and 50 Gbps to `m8g.48xlarge`.

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

The October runs under [Performance](#performance) were made that way: each layout (mesh, nodes and ranks per node) was decomposed once in a single-node job, and every run copied the decomposed case into its run directory. The copy took 0.2–4.7% as long as `simpleFoam` (at most 3.2% on 236M; 4.7% on 65M on 8 `hpc8a.96xlarge` nodes), where in the May runs above `decomposePar` took 0.13 to 3.92 times as long as `simpleFoam`. With `DECOMP_CACHE`, the benchmark scripts do the same from the second run of each layout on (see [Reusing a decomposition](#reusing-a-decomposition)). The time to compare is the whole `simpleFoam` phase the scripts time, from the `mpirun` that starts it to its exit, so it includes reading the decomposed mesh: OpenFOAM's own final `ClockTime` in `log.solver` was 0.97–1.00 of it in the October runs.

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

### Tests (`tests/`)

| File | Description |
|------|-------------|
| `run-tests.sh` | Runs every `test-*.sh` file of this directory and a syntax check (`bash -n`) of every script; no Slurm, OpenFOAM, MPI or AWS access needed |
| `stubs.sh` | The stubbed Slurm, IMDS, MPI and OpenFOAM commands, and the tiny case laid out like OCC DrivAer's, that the tests run the benchmark scripts with |
| `test-*.sh` | One file per behaviour of the benchmark scripts, named after it (`test-benchmark-scripts.sh`: a run from start to end), each running every script the behaviour applies to |

## Contribute your results

The benchmark scripts in this folder call [`dynamodb/record-benchmark.sh`](dynamodb/record-benchmark.sh) only after a run in which `simpleFoam` completed every iteration on every rank (see [Benchmark](#benchmark)). The recorder saves the run as a small JSON record (`<record_id>.json`) and adds it to the shared AI-Powered HPC benchmark dataset when you have write access to it. That dataset trains a model that predicts HPC performance on AWS, so every result you share helps. Set `SOURCE=<YourOrg>` to tag your runs, and see [BENCHMARK-RECORDERS.md](../BENCHMARK-RECORDERS.md) for the options and how to send the record in.
