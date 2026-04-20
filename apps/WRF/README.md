# WRF (Weather Research and Forecasting)

This directory contains scripts for building and benchmarking [WRF](https://github.com/wrf-model/WRF) on AWS HPC instances (targeting `hpc8a` / x86_64).

## Build Options

Two build approaches are provided. Both target WRF 4.6.1 by default.

> **Recommendation:** The Intel MPI build (Option 2) delivers better runtime performance than the Spack/OpenMPI build, particularly at multi-node scale where Intel MPI's EFA integration and MULTIRAIL support provide up to 10% faster time-to-results. Use Option 1 for quick setup and testing; use Option 2 for production benchmarks and performance-sensitive workloads.

### Option 1 — Spack (GCC + OpenMPI)

The simplest path. Spack handles all dependencies automatically:

```bash
sbatch build_wrf_spack.sbatch
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
bash build_wrf_dependencies_intel.sh /fsx/wrf/deps

# Step 2: Build WRF
sbatch build_wrf_intel.sbatch
```

- Compiler: GCC 11.5.0 (gfortran/gcc)
- MPI: Intel MPI 2021.17 (EFA-enabled via `mpigcc`/`mpifc` wrappers)
- Parallelism: `dmpar` (distributed memory, configure option 34)
- Install location: `/fsx/wrf/intel/4.6.1/WRF`
- Environment script: `/fsx/wrf/wrf-4.6.1-intel-env.sh`
- Build time: ~20 minutes (including dependencies on first run)

The configure step patches `configure.wrf` to use Intel MPI wrappers (`mpifc`/`mpigcc`) instead of generic `mpif90`/`mpicc`.

## Benchmark

Two benchmark cases are provided: CONUS 12km (small, quick) and CONUS 2.5km (large, proper scaling).

All benchmark scripts:
- Use 192 cores per node (full hpc8a.96xlarge)
- Create a unique run directory under `/fsx/wrf/Run/`
- Drop page caches and enable transparent huge pages before the run
- Use EFA for inter-node communication
- Report average time per timestep and total wall time

### CONUS 12km (425×300 grid)

Benchmark data (~534 MB) is automatically downloaded during the build step.

> **Note:** The CONUS 12km grid requires a minimum of 10 cells per MPI rank in each direction. With a 425×300 grid and 192 cores/node, runs beyond 4 nodes (768 cores) will hit decomposition errors. Use the CONUS 2.5km case for larger scaling tests.

```bash
# OpenMPI
sbatch --nodes=4 wrf-benchmark.sbatch

# Intel MPI
sbatch --nodes=4 wrf-benchmark-intel.sbatch
```

### CONUS 2.5km (1501×1201 grid)

The larger CONUS 2.5km case (~34 GB download from [NCAR](https://www2.mmm.ucar.edu/wrf/site/benchmark_cases.html)) provides a proper scaling workload. The 1501×1201 grid supports up to ~1500+ cores without decomposition issues, making it suitable for multi-node scaling studies.

```bash
# Download data first (one-time, ~7 min at 80 MB/s from NCAR)
mkdir -p /fsx/wrf/conus_2.5km && cd /fsx/wrf/conus_2.5km
curl -LO https://www2.mmm.ucar.edu/wrf/users/benchmark/v44/v4.4_bench_conus2.5km.tar.gz
tar xzf v4.4_bench_conus2.5km.tar.gz
mv v4.4_bench_conus2.5km/* . && rmdir v4.4_bench_conus2.5km
rm -f v4.4_bench_conus2.5km.tar.gz

# OpenMPI — scaling test
for N in 1 2 4 8; do sbatch --nodes=$N wrf-benchmark-conus2.5km.sbatch; done

# Intel MPI — scaling test
for N in 1 2 4 8; do sbatch --nodes=$N wrf-benchmark-conus2.5km-intel.sbatch; done
```

### Overrides

| Variable | Default | Description |
|----------|---------|-------------|
| `WRF_VERSION` | `4.6.1` | WRF version to build |
| `WRF_ENV` | see script | Path to environment setup script |
| `CONUS_DIR` | `/fsx/wrf/conus_12km` or `conus_2.5km` | Path to benchmark input data |
| `BASE_DIR` | `/fsx/wrf` | Root for run output directories |
| `PREFIX` | `/fsx/wrf/deps` | Dependency install prefix (Intel build only) |

## Performance

This chart shows the scaling performance of WRF running the CONUS 2.5km benchmark (1501×1201 grid, 15s timestep, 6-hour simulation) on AWS EC2 [hpc8a](https://aws.amazon.com/ec2/instance-types/hpc8a/) vs [hpc7a](https://aws.amazon.com/ec2/instance-types/hpc7a/) instances.

All runs use Intel MPI 2021.17 with EFA and MULTIRAIL enabled, 192 cores per node (full node utilization). Performance is expressed as speedup normalized to a single hpc7a.96xlarge node — higher is better.

![WRF CONUS 2.5km hpc8a vs hpc7a](https://github.com/aws-samples/hpc-applications/blob/main/Doc/img/WRF/WRF-CONUS2.5km-Hpc8aVsHpc7a.png?raw=true)

Key takeaways:
- A single hpc8a node delivers **1.38x** the performance of a single hpc7a node
- At 8 nodes, hpc8a reaches **4.59x** vs **3.51x** for hpc7a (relative to the 1N hpc7a baseline)
- hpc8a maintains a consistent ~30–38% advantage over hpc7a at every node count
- Both instance types show good scaling up to 4 nodes; efficiency tapers at 8 nodes as the CONUS 2.5km workload begins to saturate at 1536 cores

## Key Metrics

- **Average time per timestep** — extracted from `rsl.error.0000`
- **Total wall time** — end-to-end execution time including MPI startup and I/O

## Files

| File | Description |
|------|-------------|
| `build_wrf_spack.sbatch` | Build WRF using Spack (GCC + OpenMPI) |
| `build_wrf_intel.sbatch` | Build WRF from source (GCC + Intel MPI) |
| `build_wrf_dependencies_intel.sh` | Build all WRF dependencies for the Intel MPI toolchain |
| `wrf-benchmark.sbatch` | Run CONUS 12km benchmark with OpenMPI |
| `wrf-benchmark-intel.sbatch` | Run CONUS 12km benchmark with Intel MPI |
| `wrf-benchmark-conus2.5km.sbatch` | Run CONUS 2.5km benchmark with OpenMPI |
| `wrf-benchmark-conus2.5km-intel.sbatch` | Run CONUS 2.5km benchmark with Intel MPI |
