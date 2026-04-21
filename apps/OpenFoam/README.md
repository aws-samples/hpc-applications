# OpenFOAM

This directory contains scripts for building and benchmarking [OpenFOAM v2512](https://www.openfoam.com/) on AWS HPC instances.

The scripts are organised by CPU architecture:

- [`x86/`](x86/) — builds and benchmarks for x86_64 (`hpc8a`, `hpc7a`)
- [`Arm/`](Arm/) — builds and benchmarks for aarch64 (`hpc7g` / Graviton3E, `m8g` / `r8g` / Graviton4)

## x86 builds

Three build variants are provided. All target OpenFOAM v2512 (openfoam.com release) and use 48 cores for compilation.

> **Recommendation:** For single-instance-family deployments on `hpc8a`, use the AVX-512 OpenMPI build (Option 1) — it's the simplest path and delivers the best performance on Zen 5. For cross-instance comparisons (e.g. hpc8a vs hpc7a), use the AVX2 build (Option 3) to produce a portable binary that runs identically on both architectures.

### Option 1 — GCC 14 + OpenMPI (AVX-512, hpc8a-optimized)

Tuned for `hpc8a.96xlarge` (AMD EPYC 5th Gen / Zen 5 / Turin):

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

### Option 3 — GCC + OpenMPI (AVX2, portable)

Portable binary that runs identically on any Zen 3/4/5 CPU — used for hpc8a vs hpc7a comparisons:

```bash
sbatch x86/build_openfoam_com_v2512_avx2.sbatch
```

- Compiler: system GCC
- Flags: `-O2 -march=x86-64-v3 -mtune=generic` (AVX2 + FMA + BMI, no AVX-512)
- MPI: OpenMPI 4.1.7
- Install location: `/fsx/openfoam/x86_64-avx2/v2512`
- Environment script: `/fsx/openfoam/x86_64-avx2/openfoam-v2512-env.sh`
- Build time: ~35 minutes

## Arm builds

A single build script targets all AWS Graviton processors (`hpc7g`, `m8g`, `r8g`). The Graviton generation is auto-detected at runtime from `/proc/cpuinfo` and the correct `-mcpu` flag is applied. Built with GCC 14 + OpenMPI and 48 cores for compilation.

> **Note:** We evaluated both GCC 14 and Arm Compiler for Linux (ACfL / `armclang`) on Graviton4 and measured nearly identical `simpleFoam` runtime (within 0.1–0.6% across 1/2/4/8 nodes). Since ACfL provides no meaningful advantage for this workload, only the GCC path is kept here.

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

## Benchmark

The benchmark case is the [OCC DrivAer static-mesh](https://develop.openfoam.com/committees/hpc/-/tree/develop/incompressible/simpleFoam/occDrivAerStaticMesh) from the [1st OpenFOAM HPC Challenge](https://zenodo.org/records/15012221) — a steady-state external aerodynamics case using `simpleFoam`. Three mesh resolutions are available (65M / 110M / 236M cells); mesh tarballs are fetched from Zenodo on first run and cached under `/fsx/openfoam/occ-drivaer/`.

### x86

```bash
# OpenMPI
sbatch --nodes=N x86/openfoam-benchmark-openmpi.sbatch

# Intel MPI
sbatch --nodes=N x86/openfoam-benchmark-intelmpi.sbatch
```

Both scripts default to 192 cores per node (full `hpc8a.96xlarge` / `hpc7a.96xlarge`).

### Arm

A single launcher works for both Graviton generations — pick the right build via `OPENFOAM_ENV` and set the partition and core count accordingly. OpenMPI 5 is loaded at runtime because the default OpenMPI 4.1.7 cannot scale EFA endpoints to 192 ranks per node on Graviton4.

The mesh size is selectable via `MESH_SIZE` (65, 110, or 236 — millions of cells). Default is **65M (coarse)** so `hpc7g.16xlarge` (124 GB RAM) can run the benchmark without OOMing during the serial `decomposePar` phase. Use `MESH_SIZE=236` on Graviton4 (747 GB RAM) for the full workload.

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

> **Memory note:** At 236M cells the serial `decomposePar` phase exceeds the 124 GB RAM of `hpc7g.16xlarge` — use `MESH_SIZE=65` (or `110`) on Graviton3E to stay within budget. For the 65M mesh, the `simpleFoam` solver also OOMs on a **single** hpc7g node (64 ranks × ~1M cells + GAMG multigrid coefficients exceed 124 GB), so Graviton3E runs require **2 or more nodes**. Graviton4 (`m8g.48xlarge` / `r8g.48xlarge`, 747 GB RAM) handles all three mesh sizes at any node count.

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

### Quick benchmarks

To shorten the `simpleFoam` phase for scaling studies, uncomment the `endTime` sed inside the benchmark script to cap iterations at 200 (from the case default). Leave it commented for production runs.

## Performance

### x86 — hpc8a vs hpc7a (236M cells)

This chart shows the scaling performance of OpenFOAM running the OCC DrivAer 236M-cell benchmark (200 iterations of `simpleFoam`) on AWS EC2 [hpc8a](https://aws.amazon.com/ec2/instance-types/hpc8a/) vs [hpc7a](https://aws.amazon.com/ec2/instance-types/hpc7a/) instances.

Both runs use the same AVX2 OpenFOAM build (Option 3) with OpenMPI and EFA, 192 cores per node (full node utilization). Using an identical binary isolates the hardware contribution from any compiler-driven differences. Performance is expressed as speedup normalized to a single `hpc7a.96xlarge` node — higher is better.

![OpenFOAM OCC DrivAer 236M hpc8a vs hpc7a](https://github.com/aws-samples/hpc-applications/blob/main/Doc/img/OpenFoam/OpenFOAM-OCCDrivAer-236M-Hpc8aVsHpc7a.png?raw=true)

Key takeaways:
- A single hpc8a node delivers **1.37x** the performance of a single hpc7a node
- At 16 nodes, hpc8a reaches **9.64x** vs **6.65x** for hpc7a (relative to the 1N hpc7a baseline)
- hpc8a maintains a consistent **37–45% advantage** over hpc7a at every node count
- Both instance types scale well through 8 nodes; hpc7a efficiency tapers more noticeably at 16 nodes as the 3072-core partition begins to saturate on the 236M-cell problem

### Arm — Graviton3E (hpc7g) vs Graviton4 (m8g) (65M cells)

This chart shows the scaling performance of OpenFOAM running the OCC DrivAer 65M-cell coarse benchmark (200 iterations of `simpleFoam`) on [hpc7g](https://aws.amazon.com/ec2/instance-types/hpc7g/) (Graviton3E, Neoverse V1) vs [m8g](https://aws.amazon.com/ec2/instance-types/m8g/) (Graviton4, Neoverse V2) instances.

Each instance family uses the CPU-tuned GCC 14 build (`-mcpu=neoverse-v1` on Graviton3E, `-mcpu=neoverse-v2` on Graviton4), OpenMPI 5 over EFA, 64 cores/node on hpc7g and 192 cores/node on m8g. Performance is expressed as speedup normalized to a single `hpc7g.16xlarge` node — higher is better.

![OpenFOAM OCC DrivAer 65M Graviton3E vs Graviton4](https://github.com/aws-samples/hpc-applications/blob/main/Doc/img/OpenFoam/OpenFOAM-OCCDrivAer-65M-Graviton3VsGraviton4.png?raw=true)

Key takeaways:
- **1N hpc7g OOMs** on the 65M mesh (64 simpleFoam ranks + GAMG coefficients exceed 124 GB RAM); the 1N baseline is *estimated* as 2 × the 2N time
- A single m8g node delivers **2.81x** the performance of a single hpc7g node — 3× the cores plus microarchitectural gains
- At 8 nodes, m8g reaches **11.55x** vs **5.36x** for hpc7g
- m8g maintains a **2.15–2.81x** advantage at every node count
- Both instance types scale sub-linearly beyond 4 nodes as the 65M case becomes small relative to 1,536 cores on m8g 8N
- A single m8g node (192 cores, 2.81x) outperforms two hpc7g nodes (128 cores, 2.00x) — useful when capacity or interconnect scaling is a concern

## Key Metrics

- **`simpleFoam` time** — steady-state solver wall time for the configured number of iterations (the primary scaling metric)
- **`decomposePar` time** — domain decomposition cost (grows with node count; dominant at high scale)
- **`renumberMesh` / `potentialFoam` time** — setup phase cost

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
