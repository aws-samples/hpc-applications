# WRF (Weather Research and Forecasting)

This directory contains scripts for building and benchmarking [WRF 4.6.1](https://github.com/wrf-model/WRF) on AWS HPC instances.

The scripts are organised by CPU architecture:

- [`x86/`](x86/) — builds and benchmarks for x86_64 (`hpc8a`, `hpc7a`)
- [`Arm/`](Arm/) — builds and benchmarks for aarch64 (`hpc7g` / Graviton3E, `m8g` / `r8g` / Graviton4)

## x86 builds

Two build approaches are provided. Both target WRF 4.6.1.

> **Recommendation:** The Intel MPI build (Option 2) delivers better runtime performance than the Spack/OpenMPI build, particularly at multi-node scale where Intel MPI's EFA integration and MULTIRAIL support provide up to 10% faster time-to-results. Use Option 1 for quick setup and testing; use Option 2 for production benchmarks and performance-sensitive workloads.

### Option 1 — Spack (GCC + OpenMPI)

The simplest path. Spack handles all dependencies automatically:

```bash
sbatch x86/build_wrf_spack.sbatch
```

- Compiler: GCC 12.4.0
- MPI: OpenMPI 4.1.7 (system-provided, EFA-enabled)
- Parallelism: `dm+sm` (distributed + shared memory)
- Install location: managed by Spack under `/fsx/spack`
- Environment script: `/fsx/wrf/wrf-4.6.1-env.sh`
- Build time: ~15 minutes (with dependencies pre-installed)

System krb5 and libtirpc are used as Spack externals to avoid OpenSSL build conflicts on Amazon Linux 2023.

### Option 2 — GCC + Intel MPI (from source)

Builds WRF and all dependencies from source using GCC with Intel MPI for the MPI layer:

```bash
# Step 1: Build dependencies (cmake, zlib-ng, libaec, HDF5, PnetCDF,
#         netCDF-C, netCDF-Fortran, PIO, METIS)
# This is called automatically by the build script if deps are missing,
# or you can run it standalone:
bash x86/build_wrf_dependencies_intel.sh /fsx/wrf/deps

# Step 2: Build WRF
sbatch x86/build_wrf_intel.sbatch
```

- Compiler: GCC 11.5.0 (gfortran/gcc)
- MPI: Intel MPI 2021.17 (EFA-enabled via `mpigcc`/`mpifc` wrappers)
- Parallelism: `dmpar` (distributed memory, configure option 34)
- Install location: `/fsx/wrf/intel/4.6.1/WRF`
- Environment script: `/fsx/wrf/wrf-4.6.1-intel-env.sh`
- Build time: ~20 minutes (including dependencies on first run)

The configure step patches `configure.wrf` to use Intel MPI wrappers (`mpifc`/`mpigcc`) instead of generic `mpif90`/`mpicc`.

## Arm builds

A single build script targets both AWS Graviton generations for HPC (`hpc7g` / Graviton3E and `m8g` / `r8g` / Graviton4). The Graviton generation is auto-detected at runtime from `/proc/cpuinfo` and the Spack install path is picked accordingly. Built with GCC + OpenMPI via Spack.

> **Note:** We evaluated Arm Compiler for Linux (ACfL / `armflang`) but found the classic `armflang` frontend has a >7-dimensional array limit that is incompatible with OpenMPI 5's `mpif-sizeof.h` header. Given that ACfL also showed no performance advantage for OpenFOAM on this hardware, only the GCC path is kept here.

### Which OpenMPI version?

Two `OMPI_VERSION` knobs are supported:

- `OMPI_VERSION=4` (default) — builds against the system OpenMPI 4.1.7 at `/opt/amazon/openmpi`. Works on Graviton3E at full density (64 ranks/node). On Graviton4 at 192 ranks/node it hits an EFA endpoint limit and fails with `PML cm cannot be selected`.
- `OMPI_VERSION=5` — builds against the system OpenMPI 5.0.9 at `/opt/amazon/openmpi5`. Handles full-density EFA correctly on both platforms. **Use this for Graviton4.** It also performs well on Graviton3E.

Both variants coexist in separate install paths so an OpenMPI 4 build is not disturbed when you add the OpenMPI 5 variant.

```bash
# Graviton3E (hpc7g.16xlarge, 64 cores) — OpenMPI 5 recommended
sbatch -p hpc7g --ntasks-per-node=64 \
  --export=ALL,OMPI_VERSION=5 Arm/build_wrf_arm.sbatch

# Graviton4 (m8g.48xlarge, 192 cores) — OpenMPI 5 required for 192 rpn
sbatch -p m8g --ntasks-per-node=192 \
  --export=ALL,OMPI_VERSION=5 Arm/build_wrf_arm.sbatch
```

Install locations (named after the detected target and OpenMPI generation):

| Target | OpenMPI | Install prefix | Env script |
|--------|---------|----------------|------------|
| Graviton3E | 4.1.7 | `/fsx/wrf/aarch64-graviton3` | `aarch64-graviton3/wrf-4.6.1-env.sh` |
| Graviton3E | 5.0.9 | `/fsx/wrf/aarch64-graviton3-ompi5` | `aarch64-graviton3-ompi5/wrf-4.6.1-ompi5-env.sh` |
| Graviton4 | 4.1.7 | `/fsx/wrf/aarch64-graviton4` | `aarch64-graviton4/wrf-4.6.1-env.sh` |
| Graviton4 | 5.0.9 | `/fsx/wrf/aarch64-graviton4-ompi5` | `aarch64-graviton4-ompi5/wrf-4.6.1-ompi5-env.sh` |

To override auto-detection (cross-build or an unknown CPU part), set `TARGET=graviton3` or `TARGET=graviton4`.

## Benchmark

Two benchmark cases are provided: **CONUS 12km** (small, quick) and **CONUS 2.5km** (large, proper scaling).

### x86

```bash
# CONUS 12km — OpenMPI
sbatch --nodes=4 x86/wrf-benchmark.sbatch

# CONUS 12km — Intel MPI
sbatch --nodes=4 x86/wrf-benchmark-intel.sbatch

# CONUS 2.5km — Intel MPI, scaling test
for N in 1 2 4 8; do sbatch --nodes=$N x86/wrf-benchmark-conus2.5km-intel.sbatch; done
```

> **Note:** The CONUS 12km grid (425×300) requires a minimum of 10 cells per MPI rank in each direction. With 192 cores/node, runs beyond 4 nodes (768 cores) will hit decomposition errors. Use the CONUS 2.5km case for larger scaling tests.

### CONUS 2.5km data download (one-time, x86)

```bash
mkdir -p /fsx/wrf/conus_2.5km && cd /fsx/wrf/conus_2.5km
curl -LO https://www2.mmm.ucar.edu/wrf/users/benchmark/v44/v4.4_bench_conus2.5km.tar.gz
tar xzf v4.4_bench_conus2.5km.tar.gz
mv v4.4_bench_conus2.5km/* . && rmdir v4.4_bench_conus2.5km
rm -f v4.4_bench_conus2.5km.tar.gz
```

### Arm

A single launcher works for both Graviton generations and both mesh resolutions. Pick the build via `WRF_ENV` and the mesh via `BENCHMARK` (`12km` or `2.5km`).

```bash
# Graviton3E — CONUS 12km (default)
sbatch -p hpc7g -N 4 --ntasks-per-node=64 \
  --export=ALL,WRF_ENV=/fsx/wrf/aarch64-graviton3-ompi5/wrf-4.6.1-ompi5-env.sh \
  Arm/wrf-benchmark.sbatch

# Graviton4 — CONUS 2.5km
sbatch -p m8g -N 4 --ntasks-per-node=192 \
  --export=ALL,WRF_ENV=/fsx/wrf/aarch64-graviton4-ompi5/wrf-4.6.1-ompi5-env.sh,BENCHMARK=2.5km \
  Arm/wrf-benchmark.sbatch
```

The launcher:

- Sets `OMP_NUM_THREADS=1` (pure MPI, one rank per core) — the `dm+sm` WRF binary is run without OpenMP threads to avoid a first-timestep deadlock seen on hpc7g with hybrid threads
- Uses SSH bootstrap (`--mca plm_rsh_agent ssh`) rather than Slurm/prterun — matches the pattern in the Fluent Arm launcher and avoids intermittent init deadlocks
- Uses `pml cm + mtl ofi` (zero-copy EFA fast path)
- Drops page caches and enables transparent huge pages before the run

> **Known issue:** On this cluster we observed that nodes that have **just finished** a WRF job sometimes hang on the first MPI collective when they are immediately reused for a new WRF job (processes spin at 100% CPU with no timestep progress). Fresh / power-cycled nodes work reliably. If a multi-node WRF run hangs at `SIMULATION START DATE` for more than a few minutes, cancel it and resubmit onto different (cold) nodes.

All benchmark scripts (x86 and Arm):

- Use EFA for inter-node communication
- Create a unique run directory under `/fsx/wrf/Run/`
- Drop page caches and enable transparent huge pages
- Report average time per timestep and total wall time (extracted from `rsl.error.0000`)

### Overrides

| Variable | Default | Description |
|----------|---------|-------------|
| `WRF_VERSION` | `4.6.1` | WRF version to build |
| `OMPI_VERSION` | `4` (Arm build only) | `4` or `5` — which system OpenMPI to link against |
| `WRF_ENV` | see script | Path to environment setup script |
| `BENCHMARK` | `12km` (Arm launcher) | `12km` or `2.5km` — mesh resolution |
| `CONUS_DIR` | `/fsx/wrf/conus_12km` or `conus_2.5km` | Path to benchmark input data |
| `BASE_DIR` | `/fsx/wrf` | Root for run output directories |
| `TARGET` | `auto` (Arm build only) | Force compile target: `graviton3` or `graviton4` |
| `PREFIX` | `/fsx/wrf/deps` | Dependency install prefix (x86 Intel build only) |

## Performance

### x86 — hpc8a vs hpc7a (CONUS 2.5km)

This chart shows the scaling performance of WRF running the CONUS 2.5km benchmark (1501×1201 grid, 15s timestep, 6-hour simulation) on AWS EC2 [hpc8a](https://aws.amazon.com/ec2/instance-types/hpc8a/) vs [hpc7a](https://aws.amazon.com/ec2/instance-types/hpc7a/) instances.

All runs use Intel MPI 2021.17 with EFA and MULTIRAIL enabled, 192 cores per node (full node utilization). Performance is expressed as speedup normalized to a single `hpc7a.96xlarge` node — higher is better.

![WRF CONUS 2.5km hpc8a vs hpc7a](https://github.com/aws-samples/hpc-applications/blob/main/Doc/img/WRF/WRF-CONUS2.5km-Hpc8aVsHpc7a.png?raw=true)

Key takeaways:

- A single hpc8a node delivers **1.38x** the performance of a single hpc7a node
- At 8 nodes, hpc8a reaches **4.59x** vs **3.51x** for hpc7a (relative to the 1N hpc7a baseline)
- hpc8a maintains a consistent ~30–38% advantage over hpc7a at every node count
- Both instance types show good scaling up to 4 nodes; efficiency tapers at 8 nodes as the CONUS 2.5km workload begins to saturate at 1536 cores

### Arm — Graviton3E (hpc7g) vs Graviton4 (m8g)

This chart shows the scaling performance of WRF 4.6.1 running both CONUS benchmarks on [hpc7g](https://aws.amazon.com/ec2/instance-types/hpc7g/) (Graviton3E, Neoverse V1, 64 cores) vs [m8g](https://aws.amazon.com/ec2/instance-types/m8g/) (Graviton4, Neoverse V2, 192 cores) instances.

Each platform uses the CPU-tuned GCC build (`target=neoverse_v1` on Graviton3E, `target=neoverse_v2` on Graviton4), OpenMPI 5.0.9 over EFA, and pure MPI (one rank per core, `OMP_NUM_THREADS=1`). Performance is expressed as speedup normalized to a single `hpc7g.16xlarge` node — higher is better.

![WRF CONUS Graviton3E vs Graviton4](https://github.com/aws-samples/hpc-applications/blob/main/Doc/img/WRF/WRF-CONUS-Graviton3VsGraviton4.png?raw=true)

**CONUS 12km** — total wall time (seconds):

| Nodes | hpc7g (64 c/n) | m8g (192 c/n) | m8g speedup |
|------:|---------------:|--------------:|------------:|
| 1 | 546.05 | 216.80 | **2.52×** |
| 2 | 311.83 | 160.33 | **1.94×** |
| 4 | 213.95 | — (decomp limit) | — |

**CONUS 2.5km** — total wall time (seconds):

| Nodes | hpc7g (64 c/n) | m8g (192 c/n) | m8g speedup |
|------:|---------------:|--------------:|------------:|
| 1 | *12304.80 (est. 2 × 2N)* | 4001.33 | — |
| 2 | 6152.40 | 2439.88 | **2.52×** |
| 4 | 3732.59 | 1642.47 | **2.27×** |

Key takeaways:

- A single m8g node delivers **2.52× (12km)** and an estimated **3.08× (2.5km)** the performance of a single hpc7g node — consistent with the 3× core-count ratio minus the usual communication/memory-bandwidth tax
- On CONUS 2.5km, m8g reaches **5.04× (2N)** and **7.49× (4N)** vs the hpc7g 1N baseline, while hpc7g scales from 1N → 4N at **3.30×** — both platforms scale sub-linearly (Amdahl) but G4 stays consistently ahead
- The **CONUS 12km grid (425×300) does not decompose past ~500 ranks** — 4N m8g at 768 ranks triggers a decomposition error. For that level of parallelism, use CONUS 2.5km (1501×1201), which supports 1500+ ranks cleanly.
- The 1N hpc7g 2.5km point is *estimated* at 2 × the 2N time; running it directly is expensive (~3.5 hours of wall time) and a single 64-core node is a pessimistic baseline for a 1.8M-cell grid
- A single m8g node (192 cores, ~4000s on 2.5km) is roughly equivalent to 3 hpc7g nodes — useful when capacity or interconnect cost is a concern

## Key Metrics

- **Average time per timestep** — extracted from `rsl.error.0000` (the primary scaling metric)
- **Total wall time** — end-to-end execution time including MPI startup and I/O

## Files

### x86 ([`x86/`](x86/))

| File | Description |
|------|-------------|
| `build_wrf_spack.sbatch` | Build WRF using Spack (GCC + OpenMPI) |
| `build_wrf_intel.sbatch` | Build WRF from source (GCC + Intel MPI) |
| `build_wrf_dependencies_intel.sh` | Build all WRF dependencies for the Intel MPI toolchain |
| `wrf-benchmark.sbatch` | Run CONUS 12km benchmark with OpenMPI |
| `wrf-benchmark-intel.sbatch` | Run CONUS 12km benchmark with Intel MPI |
| `wrf-benchmark-conus2.5km.sbatch` | Run CONUS 2.5km benchmark with OpenMPI |
| `wrf-benchmark-conus2.5km-intel.sbatch` | Run CONUS 2.5km benchmark with Intel MPI |

### Arm ([`Arm/`](Arm/))

| File | Description |
|------|-------------|
| `build_wrf_arm.sbatch` | Build WRF via Spack (GCC + OpenMPI 4 or 5, auto-detects Graviton3E or Graviton4) |
| `wrf-benchmark.sbatch` | CONUS 12km or 2.5km benchmark (selectable via `BENCHMARK`) with OpenMPI + EFA |
