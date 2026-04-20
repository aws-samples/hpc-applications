# OpenFOAM

This directory contains scripts for building and benchmarking [OpenFOAM v2512](https://www.openfoam.com/) on AWS HPC instances (targeting `hpc8a` / `hpc7a` / x86_64).

## Build Options

Three build variants are provided. All target OpenFOAM v2512 (openfoam.com release) and use 48 cores for compilation.

> **Recommendation:** For single-instance-family deployments on `hpc8a`, use the AVX-512 OpenMPI build (Option 1) — it's the simplest path and delivers the best performance on Zen 5. For cross-instance comparisons (e.g. hpc8a vs hpc7a), use the AVX2 build (Option 3) to produce a portable binary that runs identically on both architectures.

### Option 1 — GCC 14 + OpenMPI (AVX-512, hpc8a-optimized)

Tuned for `hpc8a.96xlarge` (AMD EPYC 5th Gen / Zen 5 / Turin):

```bash
sbatch build_openfoam_com_v2512_hpc8a_openmpi.sbatch
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
sbatch build_openfoam_com_v2512_hpc8a_intelmpi.sbatch
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
sbatch build_openfoam_com_v2512_avx2.sbatch
```

- Compiler: system GCC
- Flags: `-O2 -march=x86-64-v3 -mtune=generic` (AVX2 + FMA + BMI, no AVX-512)
- MPI: OpenMPI 4.1.7
- Install location: `/fsx/openfoam/x86_64-avx2/v2512`
- Environment script: `/fsx/openfoam/x86_64-avx2/openfoam-v2512-env.sh`
- Build time: ~35 minutes

## Benchmark

The benchmark case is the [OCC DrivAer static-mesh](https://develop.openfoam.com/committees/hpc/-/tree/develop/incompressible/simpleFoam/occDrivAerStaticMesh) 236M-cell fine mesh — a steady-state external aerodynamics case using `simpleFoam`. The mesh is fetched from [Zenodo](https://zenodo.org/records/15012221) on first run.

Two benchmark scripts are provided:

```bash
# OpenMPI
sbatch --nodes=N openfoam-benchmark-openmpi.sbatch

# Intel MPI
sbatch --nodes=N openfoam-benchmark-intelmpi.sbatch
```

Both benchmark scripts:
- Use 192 cores per node (full `hpc8a.96xlarge` / `hpc7a.96xlarge`)
- Create a unique run directory under `/fsx/openfoam/Run/`
- Drop page caches and enable transparent huge pages before the run
- Use EFA for inter-node communication (plus MULTIRAIL for Intel MPI)
- Report timings for `decomposePar`, `renumberMesh`, `potentialFoam`, and `simpleFoam` separately

### Overrides

| Variable | Default | Description |
|----------|---------|-------------|
| `OPENFOAM_ENV` | see script | Path to OpenFOAM environment setup script |
| `CASE_SRC` | `/fsx/openfoam/occ-drivaer/occDrivAerStaticMesh` | Case and mesh source directory |
| `BASE_DIR` | `/fsx/openfoam` | Root for run output directories |

### Quick benchmarks

To shorten the `simpleFoam` phase for scaling studies, uncomment the `endTime` sed inside the benchmark script to cap iterations at 200 (from the case default). Leave it commented for production runs.

## Performance

This chart shows the scaling performance of OpenFOAM running the OCC DrivAer 236M-cell benchmark (200 iterations of `simpleFoam`) on AWS EC2 [hpc8a](https://aws.amazon.com/ec2/instance-types/hpc8a/) vs [hpc7a](https://aws.amazon.com/ec2/instance-types/hpc7a/) instances.

Both runs use the same AVX2 OpenFOAM build (Option 3) with OpenMPI and EFA, 192 cores per node (full node utilization). Using an identical binary isolates the hardware contribution from any compiler-driven differences. Performance is expressed as speedup normalized to a single `hpc7a.96xlarge` node — higher is better.

![OpenFOAM OCC DrivAer 236M hpc8a vs hpc7a](https://github.com/aws-samples/hpc-applications/blob/main/Doc/img/OpenFoam/OpenFOAM-OCCDrivAer-236M-Hpc8aVsHpc7a.png?raw=true)

Key takeaways:
- A single hpc8a node delivers **1.37x** the performance of a single hpc7a node
- At 16 nodes, hpc8a reaches **9.64x** vs **6.65x** for hpc7a (relative to the 1N hpc7a baseline)
- hpc8a maintains a consistent **37–45% advantage** over hpc7a at every node count
- Both instance types scale well through 8 nodes; hpc7a efficiency tapers more noticeably at 16 nodes as the 3072-core partition begins to saturate on the 236M-cell problem

## Key Metrics

- **`simpleFoam` time** — steady-state solver wall time for the configured number of iterations (the primary scaling metric)
- **`decomposePar` time** — domain decomposition cost (grows with node count; dominant at high scale)
- **`renumberMesh` / `potentialFoam` time** — setup phase cost

## Files

| File | Description |
|------|-------------|
| `build_openfoam_com_v2512_hpc8a_openmpi.sbatch` | Build OpenFOAM v2512 with GCC 14 + OpenMPI (AVX-512, hpc8a) |
| `build_openfoam_com_v2512_hpc8a_intelmpi.sbatch` | Build OpenFOAM v2512 with GCC 14 + Intel MPI (AVX-512, hpc8a) |
| `build_openfoam_com_v2512_avx2.sbatch` | Build OpenFOAM v2512 with GCC + OpenMPI (AVX2, portable) |
| `openfoam-benchmark-openmpi.sbatch` | OCC DrivAer 236M benchmark with OpenMPI |
| `openfoam-benchmark-intelmpi.sbatch` | OCC DrivAer 236M benchmark with Intel MPI |
