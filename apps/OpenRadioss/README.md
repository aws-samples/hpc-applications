# OpenRadioss

This directory contains scripts for building and benchmarking [OpenRadioss](https://openradioss.org/) on AWS HPC instances. OpenRadioss is the open-source version of Altair Radioss, an explicit finite-element solver for highly non-linear dynamic events (crash, impact, drop test, blast).

The scripts are organised by CPU architecture:

- [`x86/`](x86/) — builds and benchmarks for x86_64 (`hpc8a`, `hpc7a`)
- [`Arm/`](Arm/) — builds and benchmarks for aarch64 (`hpc7g` / Graviton3E, `m8g` / Graviton4)

OpenRadioss is a two-stage solver:

- **starter** — a single-node, OpenMP-only pre-processor that partitions the mesh into `NSPMD` subdomains and writes the partitioned restart files
- **engine** — the MPI + OpenMP parallel solver that advances the time integration

Both stages are built from source using [OpenRadioss' upstream `build_script.sh`](https://github.com/OpenRadioss/OpenRadioss). The engine is linked against the system OpenMPI on AL2023 so EFA is used automatically at runtime.

## x86 build

A single build script targets hpc8a (Zen5) and hpc7a (Zen4) — both AMD EPYC with AVX-512 — using GCC + OpenMPI:

```bash
sbatch x86/build_openradioss_x86.sbatch
```

- Compiler: GCC 11.5 (gfortran/gcc, system)
- Flags: `-O3 -march=x86-64-v4 -mtune=znver4` (AVX-512, Zen 4/5 tuning)
- MPI: system OpenMPI 4.1.7 at `/opt/amazon/openmpi` (EFA-enabled)
- Install location: `/fsx/openradioss/x86_64/latest-20260319`
- Environment script: `/fsx/openradioss/x86_64/openradioss-latest-20260319-env.sh`
- Build time: ~30 minutes

Override via `--export=ALL,...`:

| Variable | Default | Description |
|----------|---------|-------------|
| `OPENRADIOSS_TAG` | `latest-20260319` | Release tag from the [OpenRadioss GitHub releases](https://github.com/OpenRadioss/OpenRadioss/releases) |
| `TARGET_CPU` | `hpc8a` | `hpc8a` / `hpc7a` (AVX-512 Zen 4/5) or `generic-avx2` (portable Zen 3+) |
| `COMPILE_CORES` | `48` | Parallel compile threads |

GCC 11.5 (AL2023) does not know `znver5`, so Zen 5 is compiled with `-mtune=znver4` — AVX-512 is still emitted and runs at full speed on Zen 5. A few Zen 5-only scheduling tweaks are missed but they have no measurable effect on OpenRadioss performance.

## Arm build

A single build script targets both Graviton generations. The generation is auto-detected from `/proc/cpuinfo` (`CPU part` field: `0xd40` = Neoverse V1 / Graviton3E, `0xd4f` = Neoverse V2 / Graviton4) so the same script works on hpc7g (16xlarge) and m8g (48xlarge). Build times are ~30 min.

Upstream ships two Arm build targets: `linuxa64` (Arm Compiler for Linux / ArmFlang) and `linuxa64_gf` (GCC + gfortran). We use the GCC path because AL2023 does not ship ACfL by default, and OpenFOAM / WRF on this cluster already use the GCC path.

> **Note:** OpenRadioss' HOWTO documentation refers to the Arm GCC target as `linux64a_gf`, but the actual directory in the source tree is `linuxa64_gf`. Our script uses the correct name.

### Which OpenMPI version?

Two `OMPI_VERSION` knobs are supported:

- `OMPI_VERSION=4` (default) — builds against the system OpenMPI 4.1.7 at `/opt/amazon/openmpi`. Works cleanly on Graviton3E at full density (64 ranks/node). On Graviton4 at 192 ranks/node it hits an EFA endpoint exhaustion limit and fails to start.
- `OMPI_VERSION=5` — builds against the system OpenMPI 5.0.9 at `/opt/amazon/openmpi5`. Handles full-density EFA on both platforms. **Use this for Graviton4.** It also performs well on Graviton3E.

```bash
# Graviton3E (hpc7g.16xlarge, 64 cores) — OpenMPI 4 is fine, OMPI 5 recommended
sbatch -p hpc7g --ntasks-per-node=64 \
  --export=ALL,OMPI_VERSION=5 Arm/build_openradioss_arm.sbatch

# Graviton4 (m8g.48xlarge, 192 cores) — OpenMPI 5 required for 192 rpn
sbatch -p m8g --ntasks-per-node=192 \
  --export=ALL,OMPI_VERSION=5 Arm/build_openradioss_arm.sbatch
```

Install locations (named after the detected target + OpenMPI generation):

| Target | OpenMPI | Install prefix | Env script |
|--------|---------|----------------|------------|
| Graviton3E | 4.1.7 | `/fsx/openradioss/aarch64-graviton3` | `aarch64-graviton3/openradioss-latest-20260319-env.sh` |
| Graviton3E | 5.0.9 | `/fsx/openradioss/aarch64-graviton3-ompi5` | `aarch64-graviton3-ompi5/openradioss-latest-20260319-ompi5-env.sh` |
| Graviton4 | 5.0.9 | `/fsx/openradioss/aarch64-graviton4-ompi5` | `aarch64-graviton4-ompi5/openradioss-latest-20260319-ompi5-env.sh` |

Override via `--export=ALL,...`:

| Variable | Default | Description |
|----------|---------|-------------|
| `OPENRADIOSS_TAG` | `latest-20260319` | Release tag to build |
| `OMPI_VERSION` | `4` | `4` or `5` |
| `TARGET` | `auto` | `graviton3` or `graviton4` to override CPU auto-detection |
| `COMPILE_CORES` | `48` | Parallel compile threads |

### Upstream workarounds baked into the build

Both build scripts transparently patch or work around a handful of issues in the upstream OpenRadioss release so that the installed tree runs cleanly on AL2023. They are explained in comments in the scripts and called out here for visibility:

1. **Arm GCC release-build missing `${md5_inc}` in C/CXX flags** — `starter/CMake_Compilers/cmake_linuxa64_gf.txt` and the equivalent engine file use `${zlib_inc}` but not `${md5_inc}` in the release-build flag lines, so Starter fails with `fatal error: md5.h: No such file or directory`. The Arm build script patches both files in-place. The debug/asan branches of those files already have `${md5_inc}` — only the release path is broken upstream.
2. **CMake hardcodes `/lib` not `/lib64` for `-mpi-root`** — the `-mpi-root` CLI option expands to `-L${root}/lib`, but the Amazon-built OpenMPI on AL2023 places libraries under `lib64`. Both build scripts pass `-mpi-include` and `-mpi-libdir` explicitly instead.
3. **Bundled `libapr-1.so.0` is linked against `libcrypt.so.1`** — AL2023 ships only `libcrypt.so.2` via libxcrypt, so the bundled `extlib/hm_reader/linux*/libapr-1.so.0` fails to load once it's on `LD_LIBRARY_PATH`. Both build scripts rename the bundled file to `libapr-1.so.0.bundled` at install time so the system `/lib64/libapr-1.so.0` (which uses `libcrypt.so.2`) is picked up instead.

## Benchmark

Two benchmark models from the [OpenRadioss example library](https://openradioss.atlassian.net/wiki/spaces/OPENRADIOSS/pages/47546369/Example+Models) are supported via the `MODEL` environment variable:

- `neon1m` — **Chrysler Neon 1M cells** crash test. ~1M elements, finishes in a few minutes on a single node. Good for smoke tests and per-rank tuning but saturates at 2 nodes — use Taurus for scaling studies.
- `taurus10m` — **Ford Taurus 10M cells** front-impact crash test. ~10M elements, runs for hours. This is the model used in the scaling charts below.

Both models are fetched from the OpenRadioss Atlassian wiki on first run and cached under `/fsx/openradioss/models/`.

### x86

```bash
# Neon 1M on hpc8a (default)
sbatch --nodes=1 x86/openradioss-benchmark.sbatch

# Taurus 10M scaling sweep on hpc8a
for N in 1 2 4; do
  sbatch --nodes=$N --export=ALL,MODEL=taurus10m,SIM_TIME=0.01 \
    x86/openradioss-benchmark.sbatch
done

# Same on hpc7a (same binary, AVX-512 Zen4)
for N in 1 2 4; do
  sbatch -p hpc7a --ntasks-per-node=192 --nodes=$N \
    --export=ALL,MODEL=taurus10m,SIM_TIME=0.01 \
    x86/openradioss-benchmark.sbatch
done
```

### Arm

A single launcher works for both Graviton generations — pick the build via `OPENRADIOSS_ENV`, the partition via `-p`, and the rank count via `--ntasks-per-node`.

```bash
# Graviton3E (hpc7g, 64 cores/node)
sbatch -p hpc7g --ntasks-per-node=64 --nodes=4 \
  --export=ALL,MODEL=taurus10m,SIM_TIME=0.01,OPENRADIOSS_ENV=/fsx/openradioss/aarch64-graviton3/openradioss-latest-20260319-env.sh \
  Arm/openradioss-benchmark.sbatch

# Graviton4 (m8g, 192 cores/node, OpenMPI 5)
sbatch -p m8g --ntasks-per-node=192 --nodes=4 \
  --export=ALL,MODEL=taurus10m,SIM_TIME=0.01,OPENRADIOSS_ENV=/fsx/openradioss/aarch64-graviton4-ompi5/openradioss-latest-20260319-ompi5-env.sh \
  Arm/openradioss-benchmark.sbatch
```

All benchmark launchers:

- Use EFA for inter-node MPI (verified at job start via `fi_info`, `mpirun --version`, and a `ldd | grep libmpi|libfabric` sanity block in the slurm log)
- Print the OpenMPI MCA component selection at job start (`pml=cm`, `mtl=ofi`, `provider=efa`) so the log has direct evidence of the EFA fast path
- Create a unique run directory under `/fsx/openradioss/Run/`
- Drop page caches and enable transparent huge pages before the run
- Report Starter time, Engine time, total wall time, and the Radioss-reported `ELAPSED TIME` (from `engine.log`)

### Overrides

| Variable | Default | Description |
|----------|---------|-------------|
| `OPENRADIOSS_ENV` | see script | Path to environment setup script (select the build you want) |
| `MODEL` | `neon1m` | `neon1m` (Chrysler Neon 1M) or `taurus10m` (Ford Taurus 10M) |
| `SIM_TIME` | deck default | Override `/RUN` final simulation time in seconds — see below |
| `THREADS_PER_RANK` | `1` | OpenMP threads per MPI rank. Pure MPI (default) is fastest for both models on this hardware |
| `BASE_DIR` | `/fsx/openradioss` | Root for run output directories |
| `EFA_VERBOSE` | `0` | Set to `1` to add `--mca mtl_base_verbose 5 --mca pml_base_verbose 5` — useful once to confirm the EFA path, very noisy |

### Choosing `SIM_TIME` for Taurus

Taurus' recommended simulation times (from the OpenRadioss benchmark documentation) are:

| `SIM_TIME` | Cycles | Intended use |
|------------|--------|--------------|
| `0.00201` | ~10,000 | Cluster smoke test (~5 min at 2N) |
| `0.01001` | ~50,000 | **Performance / scaling studies** (~30 min at 4N hpc8a) |
| `0.12001` | ~600,000 | Full 120 ms simulation (many hours even on 8 nodes) |

The scaling numbers reported below use `SIM_TIME=0.01` (50,253 cycles). This is long enough that the engine dominates total wall time at all node counts and short enough to fit 3 replicas per node count in a reasonable queue-time budget.

## Performance

All performance charts use the same methodology: **Ford Taurus 10M**, `SIM_TIME=0.01` (50,253 cycles), pure MPI (1 OpenMP thread per rank), 3 replicas per data point. Performance is expressed as **speedup over a 1-node baseline** computed from the Radioss-reported engine `ELAPSED TIME`.

### x86 — hpc8a (Zen5) vs hpc7a (Zen4)

The same binary (built with `-march=x86-64-v4 -mtune=znver4`) runs on both instance families, so the comparison isolates the hardware contribution from any compiler-driven differences. Performance is normalised to a single `hpc7a.96xlarge` node — higher is better.

![OpenRadioss Taurus 10M hpc8a vs hpc7a](https://github.com/aws-samples/hpc-applications/blob/main/Doc/img/OpenRadioss/OpenRadioss-Taurus10M-Hpc8aVsHpc7a.png?raw=true)

| Nodes | Cores | hpc7a | hpc8a |
|------:|------:|------:|------:|
| 1 | 192 | 1.00× | **1.44×** |
| 2 | 384 | 1.75× | 2.44× |
| 4 | 768 | 3.00× | **4.14×** |

Key takeaways:

- A single hpc8a node delivers **1.44×** the performance of a single hpc7a node
- At 4 nodes — the scaling sweet spot on both families — hpc8a reaches **4.14×** vs **3.00×** for hpc7a (relative to 1N hpc7a)
- hpc8a maintains a consistent **38–44 %** advantage over hpc7a at every node count
- Scaling stops at 4 nodes on both families: the Taurus 10M deck hits a contact-sort scaling wall at 1536 ranks (8N × 192 rpn). Inspection of the Radioss CPU breakdown shows "Contact sorting" rising from 24 % of CPU time at 4N to 48 % at 8N, and 8N hpc8a measured 6 % slower than 4N hpc8a. This is an algorithmic property of the Taurus deck, not a hardware or MPI limitation — the crash model has a limited amount of parallelisable contact work and runs out of runway around 768 ranks.

### Arm — Graviton3E (hpc7g) vs Graviton4 (m8g)

Both Arm builds use OpenMPI 5.0.9 (required for Graviton4 at 192 rpn) and CPU-tuned flags (`-mcpu=neoverse-v1` on hpc7g, `-mcpu=neoverse-v2` on m8g). hpc7g runs 64 ranks/node; m8g runs 192 ranks/node. Performance is normalised to a single `hpc7g.16xlarge` node — higher is better.

![OpenRadioss Taurus 10M Graviton3E vs Graviton4](https://github.com/aws-samples/hpc-applications/blob/main/Doc/img/OpenRadioss/OpenRadioss-Taurus10M-Graviton3VsGraviton4.png?raw=true)

| Nodes | hpc7g (64 c/n) | m8g (192 c/n) |
|------:|---------------:|--------------:|
| 1 | *1.00× (est. 2 × 2N)* | **3.31×** |
| 2 | 2.00× | 6.00× |
| 4 | 3.83× | **10.41×** |
| 8 | 6.65× | 12.75× |

Key takeaways:

- The **1N hpc7g engine run does not fit in a 4 h SLURM wall-time limit**; the 1N baseline is estimated as 2 × the 2N time (same convention used by the OpenFOAM and WRF Arm charts in this repo)
- A single m8g node delivers **3.31×** the performance of a single (estimated) hpc7g node — consistent with the 3× core-count ratio (192 vs 64) and the larger L2/L3 caches on Neoverse V2
- At 4 nodes m8g reaches **10.41×** vs **3.83×** for hpc7g (both relative to the estimated 1N hpc7g baseline)
- **hpc7g scales near-linearly all the way to 8 nodes (6.65× at 8N)** — the same contact-sort wall that limits x86 is reached much later on the smaller 64-core Graviton3E nodes, because 512 ranks is still well below where the contact-sort work runs out
- **m8g 8N continues to improve over m8g 4N** (12.75× vs 10.41×), the opposite behaviour to hpc8a 8N vs 4N at the same 1536-rank total. The larger per-node core count with 6 CCDs and higher memory bandwidth on Graviton4 appears to digest the contact-sort work better than 4 × hpc8a does
- A single m8g node outperforms roughly **3.3 hpc7g nodes** for this workload — useful when capacity or interconnect cost is a concern

## Key metrics

- **Radioss ELAPSED TIME** (from `engine.log`) — the primary scaling metric; this is Radioss' internal wall-clock measurement inside the time-integration loop, excluding MPI startup and file I/O
- **Engine time** — the total wall time spent in `mpirun ... engine_*` as measured by the launcher, including MPI startup and final I/O
- **Starter time** — the single-node mesh-partitioning phase; grows super-linearly with `NSPMD` (the number of subdomains = MPI ranks the engine will use). For Taurus 10M the starter is negligible at 1–2 nodes but reaches ~74 minutes at 8 nodes × 192 rpn on m8g. If you plan many engine runs on the same decomposition, run starter once and re-use the `.rst` files.

## Files

### x86 ([`x86/`](x86/))

| File | Description |
|------|-------------|
| `build_openradioss_x86.sbatch` | Build OpenRadioss with GCC + OpenMPI 4 (AVX-512, Zen 4/5) |
| `openradioss-benchmark.sbatch` | Run Neon 1M (default) or Taurus 10M (`MODEL=taurus10m`) |

### Arm ([`Arm/`](Arm/))

| File | Description |
|------|-------------|
| `build_openradioss_arm.sbatch` | Build OpenRadioss with GCC + OpenMPI 4 or 5 (auto-detects Graviton3E / Graviton4) |
| `openradioss-benchmark.sbatch` | Run Neon 1M or Taurus 10M — pick the build via `OPENRADIOSS_ENV` |
