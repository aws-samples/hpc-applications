# Quantum ESPRESSO

This directory contains best practices for building and benchmarking
[Quantum ESPRESSO](https://www.quantum-espresso.org/) (QE) on AWS HPC
instances, validated on
**[AWS Parallel Computing Service (PCS)](https://aws.amazon.com/pcs/)**. QE is the
widely used open-source suite for plane-wave density-functional-theory (DFT)
electronic-structure calculations; the benchmarked binary is `pw.x`, the
PWscf SCF solver.

The scripts are organised by CPU architecture:

- [`Arm/`](Arm/): builds and benchmarks for aarch64 (AWS Graviton 2/3/4/5)
- [`x86/`](x86/): builds and benchmarks for x86_64 (AMD Zen 4/5, Intel
  Sapphire Rapids / Granite Rapids)

Both job scripts are plain Slurm batch scripts, developed and validated on
**AWS PCS** (managed Slurm) clusters; they should require minimal or no
change on other Slurm clusters whose compute AMI carries the EFA software
stack (e.g. ParallelCluster).

---

## Build

### Quick start

```bash
# On a Graviton partition of your PCS cluster; auto-detects the generation:
sbatch -p <graviton-partition> Arm/build_qe_arm.sbatch

# On an AMD or Intel partition; auto-detects the CPU family:
sbatch -p <x86-partition> x86/build_qe_x86.sbatch

# Then run the AUSURF112 benchmark on a full node:
sbatch -p <graviton-partition> Arm/qe-benchmark.sbatch
sbatch -p <x86-partition>      x86/qe-benchmark.sbatch
```

The build installs one architecture-tuned `pw.x` per Graviton generation under
`${BASE_DIR}/<qe-version>/gcc-<generation>/bin/` (default `BASE_DIR=/fsx/qe`),
writes a `build-manifest.json` provenance record next to it (compiler, flags,
MPI, binary + source SHA-256), and is **idempotent**: resubmitting for an
already-built (version, generation) exits immediately.

### Per-generation optimization flags

The compiler is told exactly which core it is targeting. The build script
auto-detects the generation from the Arm `CPU part` field in `/proc/cpuinfo`:

| Generation | `CPU part` | Microarchitecture | Flags | Upstream gcc |
|------------|-----------|-------------------|-------|--------------|
| Graviton2 (`c6g`/`m6g`/`r6g`) | `0xd0c` | Neoverse N1 | `-O3 -mcpu=neoverse-n1` | ≥ 9 |
| Graviton3 (`c7g`/`m7g`/`r7g`, `hpc7g`) | `0xd40` | Neoverse V1 | `-O3 -mcpu=neoverse-v1` | ≥ 11 |
| Graviton4 (`c8g`/`m8g`/`r8g`/`x8g`) | `0xd4f` | Neoverse V2 | `-O3 -mcpu=neoverse-v2` | ≥ 13 * |
| Graviton5 (`c9g`/`m9g`) | `0xd84` | Neoverse V3 | `-O3 -mcpu=neoverse-v3` | ≥ 15 * |

Build one binary per generation you plan to run on: `-mcpu=neoverse-v2` code
does not run on Graviton2/3, and a generic build leaves SVE width and tuning
on the table. The benchmark launcher picks the matching binary at run time
from the same `CPU part` probe, so a mixed-generation fleet "just works".

\* **On Amazon Linux 2023 the system compiler is enough.** Both
`-mcpu=neoverse-v2` and `-mcpu=neoverse-v3` are back-ported into the gcc 11 that
AL2023 ships, so a stock AL2023 node builds every target above natively — no
newer gcc required, including for Graviton5. The upstream gcc versions are
listed because they apply on other distributions. Source: the
[AWS Graviton getting-started C/C++ guide](https://github.com/aws/aws-graviton-getting-started/blob/main/c-c%2B%2B.md).

**Every target is probed, and falls back along the Neoverse line.** The build
script asks the compiler whether it accepts each `-mcpu` value before using it,
walking `neoverse-v3 → v2 → v1 → n1` until one is accepted. The ISA is backward
compatible, so an older target produces correct code on newer silicon, just
without the newer tuning — the same reasoning behind the AWS guide's advice to
target the oldest generation you plan to deploy on. This matters on
distributions without the AL2023 back-ports, where a vanilla gcc 11 rejects
`neoverse-v2`: the probe turns what would otherwise be an obscure failure part
way through the build into an explicit warning up front.

Any fallback is recorded in `build-manifest.json` as `mcpu_fallback: true`, and
because the resolved flags are part of the idempotence key, resubmitting later
with a newer compiler rebuilds instead of silently reusing the fallback binary.
To use a staged compiler:

```bash
sudo dnf install -y gcc14 gcc14-c++ gcc14-gfortran
sbatch -p <c9g-partition> \
       --export=ALL,QE_CC=gcc-14,QE_CXX=g++-14,QE_FC=gfortran-14 \
       Arm/build_qe_arm.sbatch
```

Configure-time feature probes (ELPA, MPI test programs) execute the code they
compile, so **build on the generation you intend to run on**. Graviton5
availability is region-limited at the time of writing, so check your region.

**`-ffast-math` is deliberately omitted.** QE is a DFT code: floating-point
reassociation can break SCF convergence and perturb total energies. `-O3`
plus the correct `-mcpu` is the safe ceiling for production DFT; verify any
flag beyond that against reference energies before trusting it.

### Build practice with the largest impact: MPI wrapper compiler override

QE is built through the MPI compiler wrappers (`mpicc`/`mpif90`). The
wrappers default to whatever compilers MPI was built with, which means a
"vendor-compiler build" can silently compile QE's Fortran (the bulk of the
code) with gfortran unless you override the wrappers:

```bash
export OMPI_CC=gcc OMPI_CXX=g++ OMPI_FC=gfortran        # GCC build
# e.g. for Arm Compiler for Linux (ACfL):
# export OMPI_CC=armclang OMPI_CXX=armclang++ OMPI_FC=armflang
```

`OMPI_CC`/`OMPI_FC` are honoured by the Open MPI wrappers at compile time.
This is equivalent to rebuilding Open MPI once per compiler, without doing
four MPI builds. If you benchmark "compiler A vs compiler B" without this,
you are almost certainly benchmarking gfortran against itself.

### Use the EFA-bundled Open MPI, not the distro package

QE links against the AWS EFA-bundled Open MPI under `/opt/amazon/openmpi`
(libfabric-aware, PMIx-backed). The Amazon Linux 2023 distro `openmpi-devel`
package's external-PMIx plugin cannot initialise under Slurm on AL2023;
builds succeed and then fail at scale-out. The build script refuses to run
if `/opt/amazon/openmpi` is missing.

### Math libraries

The default build uses **system OpenBLAS + FFTW3** (`-DQE_FFTW_VENDOR=FFTW3`):
zero-setup, reproducible by anyone. For Graviton, **Arm Performance
Libraries (ArmPL)** is the vendor-optimised alternative: install ACfL/ArmPL
(EULA click-through, so it cannot be auto-fetched), then point QE at it via
`-DBLAS_LIBRARIES=/path/to/libarmpl_lp64.so -DLAPACK_LIBRARIES=<same>` and
build with the ACfL compilers via the wrapper overrides above. Match the
threading variant to the build: serial ArmPL (`libarmpl_lp64`) for pure-MPI,
threaded (`libarmpl_lp64_mp`) only for a hybrid MPI+OpenMP build; a
pure-MPI rank must never silently spawn math-library threads.

### Flags and math libraries for AMD and Intel (x86_64)

The same build recipe (EFA Open MPI + wrapper overrides + vendor math
library) applies on x86 instances.
[`x86/build_qe_x86.sbatch`](x86/build_qe_x86.sbatch) implements the GCC rows
of the matrix below (CPU-family autodetect, same idempotence/banner-check/
manifest machinery as the Arm build); the AOCC and oneAPI rows require the
EULA-gated vendor installers and are documented here for operators who stage
them. The validated flag/library matrix is below: compile guidance only;
no x86 benchmark results are published in this directory.

| CPU family | Instances | Toolchain | `OMPI_CC` / `OMPI_FC` | Flags | Math library |
|------------|-----------|-----------|----------------------|-------|--------------|
| AMD Zen 3 (Milan) | `c6a`/`m6a`/`r6a`, `hpc6a` | GCC | `gcc` / `gfortran` | `-O3 -march=znver3` | OpenBLAS + FFTW3 |
| AMD Zen 4 (Genoa) | `c7a`/`m7a`/`r7a`, `hpc7a` | GCC | `gcc` / `gfortran` | `-O3 -march=znver4` | OpenBLAS + FFTW3 |
| AMD Zen 4 (Genoa) | `c7a`/`m7a`/`r7a`, `hpc7a` | AOCC | `clang` / `flang` | `-O3 -march=znver4` | AOCL (BLIS + libFLAME) |
| AMD Zen 5 (Turin) | `c8a`, `hpc8a` | GCC ≥ 14.1 | `gcc` / `gfortran` | `-O3 -march=znver5` | OpenBLAS + FFTW3 |
| Intel Sapphire Rapids | `c7i`/`m7i`/`r7i` | GCC | `gcc` / `gfortran` | `-O3 -march=sapphirerapids` | OpenBLAS + FFTW3 |
| Intel Sapphire Rapids | `c7i`/`m7i`/`r7i` | oneAPI | `icx` / `ifx` | `-O3 -xSAPPHIRERAPIDS` | Intel MKL |
| Intel Granite Rapids | `c8i` | GCC ≥ 14 | `gcc` / `gfortran` | `-O3 -march=graniterapids` | OpenBLAS + FFTW3 |

Key configuration details for these builds:

- **AOCC (AMD):** CMake integration is
  `-DQE_FFTW_VENDOR=FFTW3 -DBLAS_LIBRARIES=<libblis> -DLAPACK_LIBRARIES=<libflame>`.
  Use the *multithreaded* BLIS (`libblis-mt`) only in a hybrid MPI+OpenMP
  build; serial BLIS for pure MPI.
- **oneAPI (Intel):** MKL supplies BLAS/LAPACK/FFT in one:
  `-DQE_FFTW_VENDOR=MKL -DBLA_VENDOR=Intel10_64lp_seq` for pure MPI;
  the `_seq` (sequential) MKL layer matters, otherwise every MPI rank
  silently spawns an MKL thread pool and oversubscribes the node. Use
  `Intel10_64lp` (threaded) only in a hybrid build.
- **LLVM-based compilers (AOCC, and ACfL on Graviton) need
  `--gcc-toolchain=<path>`** appended to both C and Fortran flags so they
  find libgcc/CRT objects on Amazon Linux 2023.
- **CPU family alone does not identify the microarchitecture on AMD.** Family 25
  (`0x19`) covers **both Zen 3 and Zen 4**, and family 26 (`0x1a`) covers Zen 5
  and Zen 6. Dispatching on family alone would hand Zen 3 silicon
  (`c6a`/`m6a`/`r6a`/`hpc6a`, EPYC 7003 "Milan", family 25 **model 1**) an
  AVX-512 `znver4` target: the build fails late with a misleading error, and a
  `znver4` binary already present on shared storage `SIGILL`s at run time. Both
  x86 scripts therefore dispatch on family **and** model, using the same ranges
  GCC itself uses in `gcc/common/config/i386/cpuinfo.h`:

  | Family | Model (decimal) | Target |
  |--------|-----------------|--------|
  | 25 | 0–15 | `znver3` |
  | 25 | 16–31, 96–175 | `znver4` |
  | 26 | 0–79, 96–119, 208–215 | `znver5` |

  Anything outside these ranges — including Zen 6 family-26 models and Intel
  models with no entry — exits with an explicit "unrecognised" error rather than
  guessing a target.
- **Minimum gcc per flag:** `znver3` 11, `znver4` 13, `znver5` 14.1,
  `sapphirerapids` 11, `graniterapids` 14. `znver4` is back-ported into the
  gcc 11 that Amazon Linux 2023 ships. As on Arm, each target is probed and
  falls back one step along its line (`znver5 → znver4`,
  `graniterapids → sapphirerapids`) with `march_fallback: true` recorded in the
  manifest. A `znver4` binary runs correctly on Zen 5 because AVX-512 is already
  emitted; `znver5` adds scheduling for Zen 5's native 512-bit datapath.
- **Build on the target silicon.** Same rule as Graviton5: QE's dependency
  stack runs configure-time test programs, which SIGILL if you build a
  newer-ISA binary on an older node.
- **SMT:** Intel instances expose 2 vCPUs per physical core; Graviton and AMD
  on EC2 report `ValidThreadsPerCore=[1]`, i.e. there is no SMT to disable.
  Run one MPI rank per *physical* core. The x86 launcher does this for you: it
  derives the rank count from `lscpu` topology and passes
  `--threads-per-core=1` so Slurm hands each rank a whole core instead of
  packing two ranks onto sibling threads. Note that the rank count alone is
  not enough — without `--threads-per-core=1` (or SMT disabled at the instance
  level via the launch template's `CpuOptions`), `--cpus-per-task=1` requests
  a single *thread* and half the physical cores can sit idle.
- Vendor toolchains (AOCC, oneAPI, ACfL) sit behind EULA click-throughs, so
  they cannot be auto-fetched by a build script; stage the installers on
  shared storage once and pin their SHA-256.

### Build options held constant

To keep every binary comparable, the CMake configuration pins
`QE_ENABLE_MPI=ON` and **HDF5, libxc, and ScaLAPACK OFF**. The SCF benchmark
does not exercise them (PBE is a QE-native functional; `disk_io='none'`
never touches HDF5), and pinning them off stops one build from silently
picking up a system library another lacks. Single-node runs use QE's
built-in distributed diagonalisation; revisit ScaLAPACK/ELPA only for large
multi-node problems.

### Pure MPI first, hybrid later

The default build is pure MPI (`QE_ENABLE_OPENMP=OFF`), which was the
fastest single-node layout in the measurements below (one rank per physical
core; Graviton exposes one vCPU per physical core, no SMT). If you build a
hybrid MPI+OpenMP variant, install it to a distinct prefix so both binaries
coexist, link the *threaded* math library in that variant only, and tune the
rank×thread split per system size at run time; the optimum shifts with the
problem, not the machine.

### Verify the binary before trusting it

The build ends with a **banner check**: `pw.x` is launched once under
`mpirun -np 1` and the job fails unless the `Program PWSCF v.<version>`
banner appears. (A bare `./pw.x` can abort inside singleton `MPI_Init`
before printing anything; one rank under `mpirun` is the reliable probe.)
Only after the check passes is `build-manifest.json` written, so a manifest
never sits next to a broken binary.

---

## Benchmark: AUSURF112

[AUSURF112](https://github.com/QEF/benchmarks) is the standard QE benchmark:
a 112-atom gold surface (Au(111) slab), ultrasoft pseudopotential, 800 bands,
`ecutwfc = 25` Ry / `ecutrho = 200` Ry, run with `pw.x`. It fits in the memory
of any instance listed below and completes in minutes, making it well suited to
right-sizing studies.

**On k-points.** The deck does not list k-points explicitly; it requests an
automatic grid:

```
K_POINTS (automatic)
2 2 1 1 1 0
```

That is a shifted 2×2×1 Monkhorst-Pack grid, which symmetry reduces to **2
irreducible k-points** for this slab. Two is therefore the number that matters
for `-npool`, and it is the number `pw.x` prints as `number of k points=` near
the top of its output. If you change the deck, read that line rather than
assuming: `-npool` above the irreducible k-point count wins nothing and still
pays the per-pool memory cost.

> **Memory sizing for real workloads.** AUSURF112 is deliberately small;
> production QE jobs can need **far more memory per node**: plane-wave
> memory grows steeply with atom count, cutoff, and band count, and
> `-npool` replicates the real-space arrays once **per pool**. Hundreds of
> GiB per node is common for large slabs or supercells. If a run dies with
> an OOM kill (or QE's own `Error in routine allocate...`), move from the
> compute-optimised `c` families used here (2 GiB/core) to `m` (4 GiB/core),
> `r` (8 GiB/core), or `x` (16 GiB/core) Graviton instances (on Graviton,
> one core = one vCPU, so these match the per-vCPU figures in the EC2
> documentation) — for example `m8g`/`r8g`/`x8g` on Graviton4, or `m9g` and the
> larger-memory Graviton5 families as they become available in your region. The
> build and launchers in this directory detect the CPU **generation**, not the
> family, so they require no change across them.
>
> Beyond a single node, `pw.x` also runs **across multiple nodes over EFA
> with MPI**: the builds here already link the EFA-enabled Open MPI, and
> multi-node scale-out aggregates both cores and memory (often the deciding
> factor for very large systems). All results in this directory are
> **single-node**; multi-node scaling was not evaluated here and warrants
> its own study (interconnect-sensitive FFT all-to-alls dominate,
> and EFA-capable instance sizes are required, e.g. `hpc7g` or the
> largest size of each family).
>
> **GPUs.** Quantum ESPRESSO also ships an official NVIDIA GPU port of
> `pw.x` (OpenACC/CUDA Fortran, built with the NVIDIA HPC SDK toolchain
> rather than the GCC recipe used here; typically one MPI rank per GPU).
> On GPU instances (e.g. `g6e`, `p5` families) it can accelerate
> large plane-wave workloads, and is worth evaluating when
> system sizes grow well beyond this benchmark; small systems like
> AUSURF112 tend to under-utilise a modern datacenter GPU. GPU builds and
> benchmarks were **not evaluated in this directory**; this guide covers
> the CPU (Graviton) path.

The launcher ([`Arm/qe-benchmark.sbatch`](Arm/qe-benchmark.sbatch)):

- auto-fetches the input deck + pseudopotential from the upstream QEF
  benchmark repository on first run and caches them on the shared filesystem
- puts the EFA Open MPI and libfabric directories on `PATH`/`LD_LIBRARY_PATH`,
  then checks `ldd pw.x` resolves cleanly before launching anything
- refuses to run a `pw.x` with no `build-manifest.json` beside it. The build
  writes that file only after the binary passes its startup-banner check, so
  requiring it here means a half-installed binary cannot be benchmarked by
  accident (override with `QE_SKIP_MANIFEST_CHECK=1`)
- rewrites `outdir` to **node-local scratch** and sets `disk_io='none'`
  (see Runtime best practices below)
- runs pure MPI, one rank per physical core, `srun --mpi=pmix
  --cpu-bind=cores`
- enables Transparent Huge Pages and drops page caches before measuring
- fails loudly unless the run reaches `JOB DONE`, then reports both the
  Slurm job wall time and QE's own `PWSCF : ... WALL` timer. (It does
  **not** require `convergence has been achieved`: the upstream deck caps
  SCF at `electron_maxstep = 2` (a fixed-work benchmark), so
  non-convergence is the expected, correct outcome.)

```bash
# Full node (default: one rank per physical core)
sbatch -p <graviton-partition> Arm/qe-benchmark.sbatch

# Fixed rank count (e.g. scaling study point)
sbatch -p <graviton-partition> --export=ALL,NTASKS=32 Arm/qe-benchmark.sbatch

# k-point pools: AUSURF112 reduces to 2 irreducible k-points, so -npool 2 is
# worth testing when memory allows (each pool replicates the real-space arrays)
sbatch -p <graviton-partition> --export=ALL,NPOOL=2 Arm/qe-benchmark.sbatch
```

---

## Performance on AWS Graviton

**What this compares: current-generation Graviton, at equal core counts.** Wall
times are measured AUSURF112 SCF runs — pure MPI, one rank per physical core,
layout as above, the same deck each time (`electron_maxstep = 2`, fixed work).
Each core count is paired with the **smallest compute-optimised instance that
provides that many physical cores** (right-sizing: never undersubscribe a
bigger instance).

Only the **64- and 96-core** points are published. Below 64 cores this deck is
small enough that per-rank effects rather than the CPU under test dominate the
result, which makes those points a poor basis for comparing generations.

| Cores | Graviton4 (Neoverse V2) | Graviton5 (Neoverse V3) | Graviton5 advantage |
|------:|------------------------:|------------------------:|--------------------:|
| 64 | **185 s** (`c8g.16xlarge`) | **142 s** (`c9g.16xlarge`) | 1.30× |
| 96 | **172 s** (`c8g.24xlarge`) | **128 s** (`c9g.24xlarge`) | 1.34× |

Reading the data:

- **Graviton5 is a substantial step.** It completes the same fixed work ~1.3×
  faster than Graviton4 at equal core counts, at both 64 and 96 cores.
- **Strong scaling has flattened by 64 cores** for this system size: the step
  from 64 to 96 cores buys 7% on c8g and 10% on c9g, for 50% more cores.
  AUSURF112 is a small system — 112 atoms, 800 bands — so there is only so much
  plane-wave FFT work to spread across ranks. Larger systems scale further.
- **Right-size instead of undersubscribing.** Running 64 ranks on a 96-core
  instance costs more per run than the same 64 ranks on a 64-core instance, for
  identical wall time. Pick the instance to fit the rank count.
- Every Graviton generation exposes one vCPU per physical core (no SMT), so
  `nproc` is the physical core count on both instances above.

Older Graviton generations are still fully supported by the build and launcher
scripts (see [Per-generation optimization
flags](#per-generation-optimization-flags)); they are simply not the
right-sizing target for new work, so no results are published for them here.

### How these were measured

- **Graviton4** (`c8g`): `eu-north-1`. Compiled `-mcpu=neoverse-v2`.
- **Graviton5** (`c9g`): 2026-07, `eu-central-1`, AWS PCS with Slurm 25.11, one
  MPI rank per physical core, `sbatch --exclusive`, 10 reps per point (median
  of QE's own `PWSCF ... WALL` timer; spread across reps ≤ 12 s at every
  point). Also compiled `-mcpu=neoverse-v2`, **not** `-mcpu=neoverse-v3` — see
  the provenance note below.

The two sets were measured in separate campaigns and regions, so treat the
Graviton5 advantage as the headline and small absolute differences as
measurement noise.

**Provenance of the Graviton5 binary: it was _not_ V3-tuned.** The c9g runs used
a binary compiled with `-mcpu=neoverse-v2`, not `-mcpu=neoverse-v3`. It came from
the upstream benchmarking project's Spack-based build rather than the sbatch
script in this directory, and the reason the target is V2 is a property of that
toolchain:

- Spack/archspec 0.23.1 knows no `neoverse_v3` microarch, so a Graviton5 spec
  resolves to `target=neoverse_v2`. A V2-tuned binary runs correctly on V3
  because the ISA is backward compatible, so this yields a **correct but not
  V3-tuned** build — which is what was benchmarked.
- That project does have an opt-in for real V3 codegen (propagating
  `-mcpu=neoverse-v3` through `cflags==`/`cxxflags==`/`fflags==` across the whole
  compiled DAG), but it is off by default and was not used for these runs: the
  runner resolves `pw.x` out of the `neoverse_v2` install tree, and no V3 variant
  was staged.

Two consequences worth being explicit about:

1. **The measured 1.30–1.34× Graviton5 advantage is a pure hardware-generation
   gain**, obtained while compiling for the previous microarchitecture. Whatever
   `-mcpu=neoverse-v3` is worth on this workload is *not* included in these
   numbers and remains unmeasured.
2. **[`Arm/build_qe_arm.sbatch`](Arm/build_qe_arm.sbatch) does not reproduce the
   measured binary — it produces a better-tuned one.** On a stock Amazon Linux
   2023 node its probe accepts `-mcpu=neoverse-v3` (that flag is back-ported into
   AL2023's gcc 11), so it emits V3 code where the benchmark used V2. Expect the
   script's c9g wall times to be equal or better than the table above, not
   identical to it. To reproduce the measured configuration exactly, pin the
   target:

   ```bash
   sbatch -p <c9g-partition> --export=ALL,TARGET=graviton4 Arm/build_qe_arm.sbatch
   ```

   (`TARGET=graviton4` selects `-mcpu=neoverse-v2`; the resulting binary installs
   under `gcc-graviton4/` and the launcher's candidate chain will pick it up on a
   Graviton5 node.)

---

## Runtime best practices

These are validated against the AUSURF112 example in this directory, which is
deliberately small and single-node. However large jobs (more memory and or
multi-node) may need slightly different best-practices: node-local scratch and
a single shared `outdir` pull in opposite directions once ranks span nodes,
`-npool` trades memory for communicator width and the memory side dominates at
scale, and the EFA/libfabric settings below stop being optional once the FFT
all-to-alls leave the node.

1. **Keep QE scratch off the network filesystem.** `outdir` (wavefunctions,
   mixing history) is small-file, high-frequency I/O. On node-local NVMe or
   `/tmp` it is free; on NFS it serialises the SCF loop. The launcher
   rewrites `outdir` to node-local scratch and sets `disk_io='none'` for
   benchmarking (an SCF run needs no restart files).
2. **Keep the *binaries* on a shared filesystem with fast native metadata**
   (FSx for Lustre or EFS). The dynamic linker resolves dozens of shared
   libraries at every `pw.x` launch; on storage with slow or fragile
   metadata (e.g. NFS-over-object-storage gateways), directory lookups can
   stall or hang entire nodes. Address binaries by **exact absolute path**
   (the launcher's `QE_PW_PATH` override exists for this) rather than
   through shell globs or `PATH` searches that enumerate directories.
3. **Pin ranks.** `srun --cpu-bind=cores` with `OMP_NUM_THREADS=1` on the
   pure-MPI build. Unpinned runs show run-to-run variance large enough to
   swamp a 10% optimization. On SMT-enabled hardware add
   `--threads-per-core=1` so a "core" really is a core (the x86 launcher does).
4. **Transparent Huge Pages help.** QE allocates very large arrays; THP
   `always` measurably reduces TLB pressure. The launcher enables it
   best-effort at job start. Note it is set to `always` node-wide and not
   restored afterwards, so it persists for later jobs on a long-lived node.
5. **EFA environment.** The launcher puts `/opt/amazon/openmpi/bin` and
   `/opt/amazon/efa/bin` on `PATH` (with the matching library directories on
   `LD_LIBRARY_PATH`), sets `FI_EFA_FORK_SAFE=1`, and probes `fi_info -p efa`.
   `FI_PROVIDER=efa` is exported **only** when that probe finds a provider: on
   a node without EFA, pinning the provider makes libfabric fail to find one
   rather than fall back, so it is deliberately left unset there. An explicit
   `FI_PROVIDER` from the caller is always honoured. Single-node runs are
   unaffected either way; multi-node runs fall back to TCP without EFA.
   Above 128 ranks per node -- which one rank per core reaches on any 192-core
   instance -- `FI_EFA_SHM_AV_SIZE` is set to the rank count, matching the
   other launchers in this repo.
6. **`-npool` is the first QE-level knob to try.** AUSURF112's automatic grid
   reduces to 2 irreducible k-points (see above),
   so `-npool 2` halves the FFT communicator at the price of duplicating
   real-space arrays per pool; worth it on memory-rich instances (`r8g`/`x8g`
   on Graviton4, or the equivalent Graviton5 sizes), not on the
   compute-optimised families used for the benchmark above.
7. **Validate the marker that matches your deck, not just exit codes.** The
   launcher requires `JOB DONE` in the output; a wall time from a run that
   never got there is noise. AUSURF112 caps SCF at `electron_maxstep = 2`
   (a fixed-work benchmark), so gating on `convergence has been achieved`
   would misclassify every valid run; that string cannot appear by design.
   Keep 10 repetitions per configuration and report the median if you are
   producing data for decisions.
8. **Spot works well for this workload.** Each run is a self-contained,
   idempotent unit that re-runs from its input deck, so Spot interruption
   costs a restart, not corrupted results. Diversify instance sizes/AZs and
   let the median-of-reps methodology absorb the occasional retry.

---

## Not yet here: the DynamoDB benchmark recorder

Every other benchmarked application in this repository ships a contribution
recorder at `apps/<App>/dynamodb/record-benchmark.sh`, and its launch scripts
call it automatically after a successful solve — see
[`apps/BENCHMARK-RECORDERS.md`](../BENCHMARK-RECORDERS.md). **Quantum ESPRESSO
does not have one yet**, so QE runs contribute nothing to the shared benchmark
dataset. This is a known gap, not an oversight in the launcher design.

Wiring it up later is deliberately cheap, because the launchers already produce
what the recorder contract needs:

- the solver's exit status is preserved (`set -e` with an explicit `JOB DONE`
  gate), so only successful solves would ever be recorded,
- `WALL` is already an integer number of seconds, ready to pass as
  `--time-to-solution`,
- the run directory, instance type, rank count and `-npool` are all resolved and
  logged in one place.

Until then, treat the `build-manifest.json` written next to each `pw.x` as the
provenance record for a build, and the printed result block as the record for a
run. Note that "record" elsewhere in this document refers to that build
manifest, not to the DynamoDB recorder.

## Files

### Arm ([`Arm/`](Arm/))

| File | Description |
|------|-------------|
| `build_qe_arm.sbatch` | Build QE (`pw.x`, pure MPI) with GCC + EFA Open MPI + OpenBLAS/FFTW3. Auto-detects Graviton 2/3/4/5 and probes the matching `-mcpu` flag, falling back along `v3 → v2 → v1 → n1` and recording `mcpu_fallback` in the manifest. Idempotent on (version, target, **flags**), so a fallback build is replaced once a capable compiler is staged; writes a provenance manifest; fails unless the binary prints its startup banner |
| `qe-benchmark.sbatch` | Run the AUSURF112 SCF benchmark. Auto-selects the generation-matched `pw.x`, caches the input deck, keeps scratch node-local, pins ranks, requires the `JOB DONE` marker (not SCF convergence — see best practice 7), and reports wall times |

### x86 ([`x86/`](x86/))

| File | Description |
|------|-------------|
| `build_qe_x86.sbatch` | Build QE (`pw.x`, pure MPI) with GCC + EFA Open MPI + OpenBLAS/FFTW3. Detects AMD Zen 3/4/5 and Intel SPR/GNR from CPU **family and model** (see above) and probes the matching `-march` flag, falling back one step (`znver5 → znver4`, `graniterapids → sapphirerapids`) and recording `march_fallback`. Unrecognised silicon exits with an error rather than guessing. Same flag-aware idempotence / banner-check / manifest machinery as the Arm build. **No x86 benchmark results are published in this directory** — this path provides the build recipe and launcher, not measured data |
| `qe-benchmark.sbatch` | Run the AUSURF112 SCF benchmark on AMD/Intel. Same methodology as the Arm launcher, plus SMT handling: one MPI rank per **physical** core derived from `lscpu` topology, pinned with `--threads-per-core=1 --cpu-bind=cores` so ranks are not packed onto sibling threads (Intel exposes 2 vCPUs/core; AMD and Graviton have no SMT, where the flag is a no-op) |

## Overrides

| Variable | Default | Script | Description |
|----------|---------|--------|-------------|
| `QE_VERSION` | `7.5` | all | QE release tag (build) / installed version to select (benchmark) |
| `BASE_DIR` | `/fsx/qe` | all | Shared-filesystem root for installs, benchmark cache, and run outputs |
| `TARGET` | `auto` | build | Arm: `graviton2`–`graviton5`; x86: `znver3` / `znver4` / `znver5` / `sapphirerapids` / `graniterapids`; `auto` detects from `/proc/cpuinfo` |
| `QE_CC` / `QE_CXX` / `QE_FC` | `gcc` / `g++` / `gfortran` | build | Compilers the MPI wrappers wrap. Point these at a staged newer gcc (e.g. `gcc-14`) to reach `-mcpu=neoverse-v3`, `-march=znver5`, or `-march=graniterapids` |
| `QE_PW_PATH` | auto-discovered | benchmark | Absolute path to `pw.x` (skips CPU-based discovery) |
| `NTASKS` | all physical cores | benchmark | MPI rank count (x86 launcher counts physical cores, not vCPUs) |
| `NPOOL` | `1` | benchmark | k-point pools (`pw.x -npool`); must divide `NTASKS` |
| `QE_SKIP_MANIFEST_CHECK` | `0` | benchmark | Set to `1` to run a `pw.x` that has no `build-manifest.json` beside it (i.e. one whose banner check never passed). Off by default so the build-time guarantee holds at run time |
