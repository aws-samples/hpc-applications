# WRF (Weather Research and Forecasting)

This directory contains scripts for building and benchmarking [WRF 4.6.1](https://github.com/wrf-model/WRF) on AWS HPC instances.

The scripts are organised by CPU architecture:

- [`x86/`](x86/) — builds and benchmarks for x86_64 (`hpc8a`, `hpc7a`, `hpc6a`, `c8i`, `m8a`)
- [`Arm/`](Arm/) — builds and benchmarks for aarch64 (`hpc7g` / Graviton3E, `m8g` / `r8g` / Graviton4)

## Best practice in brief

For the CONUS 2.5km forecast, as measured under [Performance](#performance):

- **Build:** on x86, the GCC + Intel MPI build ([Option 2](#option-2--gcc--intel-mpi-from-source)); on Graviton4, the [Arm build](#arm-builds) with `OMPI_VERSION=5`.
- **Ranks and threads:** pure MPI, one rank per core (`OMP_NUM_THREADS=1`), every node fully populated: 192 ranks per node on `hpc8a.96xlarge`, `hpc7a.96xlarge`, `c8i.96xlarge`, `m8a.48xlarge` and `m8g.48xlarge`, 96 on `hpc6a.48xlarge`. `c8i.96xlarge` ran with SMT disabled (in ParallelCluster, `DisableSimultaneousMultithreading: true`), so each of its 192 ranks had a physical core to itself. The Intel MPI scripts pin one rank to each core in order (`I_MPI_PIN_DOMAIN=core`, `I_MPI_PIN_ORDER=compact`), and the x86 OpenMPI scripts bind with `--bind-to core --map-by slot`.
- **Fewer ranks per node:** every WRF result in this README was measured on full nodes, and the scripts' pinning is for full nodes. To run fewer ranks per node on `hpc8a.96xlarge` or `hpc7a.96xlarge`, submit with one of the core counts of [flexible cores](https://github.com/aws-samples/hpc-applications/tree/main/Utils/flexible-cores) as `--ntasks-per-node`, and replace the scripts' pinning with its list for that count: in the Intel MPI scripts, `I_MPI_PIN_PROCESSOR_LIST` instead of the `I_MPI_PIN_DOMAIN` and `I_MPI_PIN_ORDER` exports (Intel MPI ignores the list while `I_MPI_PIN_DOMAIN` is set); in the x86 OpenMPI scripts, `--bind-to cpu-list:ordered --cpu-list <list>` instead of `--bind-to core --map-by slot`.
- **Output:** the history and restart files through PnetCDF ([Output format](#output-format)), on a parallel file system such as FSx for Lustre (measured on `hpc8a`, `c8i`, `hpc7a` and `hpc6a`; `m8a` and `m8g` were run with serial output only). The x86 CONUS 2.5km scripts write their output through PnetCDF by default.
- **Instance type and node count:** from [Whole run with PnetCDF output](#conus-25km--whole-run-with-pnetcdf-output-6-hour-forecast). Of the AMD types measured, `hpc8a.96xlarge` is the fastest node (1.34–1.39× `hpc7a.96xlarge` from 1 to 8 nodes), and on 8 nodes of each the whole run keeps 88–97% parallel efficiency.
- **Timing:** run the full 6-hour forecast, not a shortened one. Compare configurations on the total wall time with the output settings you will use, and the scaling of the time steps on the median or the steady step ([Key Metrics](#key-metrics)).

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

- `OMPI_VERSION=4` (default) — builds against the system OpenMPI 4.1.7 at `/opt/amazon/openmpi`. Works on Graviton3E at full density (64 ranks/node). Graviton4 at 192 ranks per node needs OpenMPI 5.
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

# The same on hpc6a.48xlarge (96 cores per node)
for N in 1 2 4 8 16; do sbatch -p hpc6a --ntasks-per-node=96 --nodes=$N x86/wrf-benchmark-conus2.5km-intel.sbatch; done
```

The x86 scripts ask for the `hpc8a` partition and 192 tasks per node (`hpc8a.96xlarge`). On another instance type, pass its partition and its core count per node, as in the `hpc6a` line above. On `hpc8a.96xlarge` and `hpc7a.96xlarge` they run only 24, 48, 72, 96, 120, 144, 168 or 192 tasks per node, the counts that put the same number of ranks on each of their 24 CCDs ([flexible cores](https://github.com/aws-samples/hpc-applications/tree/main/Utils/flexible-cores)), and stop with any other count before the run directory and `mpirun`, with an ERROR that names these counts. Below 192, also replace the scripts' pinning with that count's list, as [Fewer ranks per node](#best-practice-in-brief) says: the scripts' own pinning is for full nodes.

When the instance metadata gives no instance type (no answer within 5 seconds, an HTTP error, or an answer that is not an instance type name), the x86 scripts check the count the same way on a node with 192 AMD cores (`lscpu`: vendor `AuthenticAMD`, and sockets × cores per socket is 192), which could be either type, and stop with an ERROR that names both types, says why, and names the same counts. `m8a.48xlarge` also has 192 AMD cores, so there too a count outside the list stops them when the instance type cannot be read. Any other node without an instance type runs such a count, with a one-line NOTE on stderr that the check was skipped; a supported count runs on every node, with no NOTE: no run stops only because the instance metadata did not answer.

> **Note:** The CONUS 12km grid (425×300) requires a minimum of 10 cells per MPI rank in each direction. With 192 cores/node, runs beyond 4 nodes (768 cores) will hit decomposition errors. Use the CONUS 2.5km case for larger scaling tests.

### CONUS 2.5km data download (one-time)

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

- Sets `OMP_NUM_THREADS=1` (pure MPI, one rank per core): the `dm+sm` WRF binary runs without OpenMP threads, as in the Graviton results below
- Starts the ranks over SSH (`--mca plm_rsh_agent ssh`, with a hostfile of the job's nodes) rather than through Slurm/prterun, as the Fluent Arm launcher does
- Uses `pml cm + mtl ofi` (zero-copy EFA fast path)
- Drops page caches and enables transparent huge pages before the run

> **Note:** For `hpc7g` (Graviton3E) the launcher leaves the binding of the ranks to OpenMPI's default policy (no `--bind-to core`), and it does the same on Graviton4.

All benchmark scripts (x86 and Arm):

- Use EFA for inter-node communication
- Create a unique run directory under `/fsx/wrf/Run/`
- Drop page caches and enable transparent huge pages
- Give the recorder what makes runs comparable, read from the run directory ([`lib/wrf-run-info.sh`](lib/wrf-run-info.sh)): the grid size (domain 1's `e_we × e_sn × e_vert`, in millions), the simulated minutes and the history output's `io_form` from `namelist.input`, and the number of time steps from `rsl.error.0000`; a value they do not give is left out
- Report the total WRF time (the wall time of `mpirun`) and the average, median and steady time per timestep (from `rsl.error.0000`; see [Key Metrics](#key-metrics))
- Record the run (see [Contribute your results](#contribute-your-results)) only when `rsl.error.0000` says `SUCCESS COMPLETE WRF` and every history and restart file WRF wrote is in the run directory and not empty ([`lib/wrf-run-check.sh`](lib/wrf-run-check.sh)); otherwise they print a NOTE that says why, and the job's exit status is unchanged

The run check assumes WRF's default output file names (`history_outname`, `rst_outname`), in the run directory, and every write in a single file (`io_form` 2 or 11), not in a file per rank (`io_form` 102); it reads domain 1 only. It looks for each history file under the name WRF writes for the run's `io_form_history`: the name `rsl.error.0000` gives it with serial netCDF (2, WRF's default), and that name with an `_` for each `:` with PnetCDF (11; see [Output format](#output-format)). It reads `frames_per_outfile` and `io_form_history` from the line that sets each, which must start with it (`frames_per_outfile = <n>, ...`), and refuses a run whose `namelist.input` sets either in any other form, or on more than one line, rather than assume WRF's default (10 frames per file, `io_form` 2). The scripts look for it as they look for `lib/wrf-step-timing.sh`, from the submit directory: for a job submitted from anywhere but the script's directory, `apps/WRF` or the repository root, for example with a copy of a script, set `WRF_RUN_CHECK_LIB` ([Overrides](#overrides)), or the run is not recorded.

### Overrides

| Variable | Default | Description |
|----------|---------|-------------|
| `WRF_VERSION` | `4.6.1` | WRF version to build |
| `OMPI_VERSION` | `4` (Arm build only) | `4` or `5` — which system OpenMPI to link against |
| `WRF_ENV` | see script | Path to environment setup script |
| `BENCHMARK` | `12km` (Arm launcher) | `12km` or `2.5km` — mesh resolution |
| `CONUS_DIR` | `/fsx/wrf/conus_12km` or `conus_2.5km` | Path to benchmark input data |
| `WRF_OUTPUT_FORMAT` | `pnetcdf` (CONUS 2.5km scripts) | `pnetcdf`: the history and restart files through PnetCDF (`io_form` 11 in the run directory's `namelist.input`); `namelist`: `namelist.input` as `CONUS_DIR` has it (see [Output format](#output-format)) |
| `BASE_DIR` | `/fsx/wrf` | Root for run output directories |
| `TARGET` | `auto` (Arm build only) | Force compile target: `graviton3` or `graviton4` |
| `PREFIX` | `/fsx/wrf/deps` | Dependency install prefix (x86 Intel build only) |
| `WRF_RUN_INFO_LIB` | found from the submit directory | Path to `lib/wrf-run-info.sh` (the grid size and run length the record carries), found as `WRF_STEP_TIMING_LIB` is |
| `WRF_STEP_TIMING_LIB` | found from the submit directory | Path to `lib/wrf-step-timing.sh` (median and steady step), for a job submitted from outside `x86/`, `Arm/`, `apps/WRF` and the repository root |
| `WRF_RUN_CHECK_LIB` | found from the submit directory | Path to `lib/wrf-run-check.sh` (the check before a run is recorded), found the same way |
| `DYNAMODB_RECORDER` | found from the submit directory | Path to `dynamodb/record-benchmark.sh`, found the same way (see [Contribute your results](#contribute-your-results)) |
| `SOURCE` | `Community` | Your organisation's tag on the runs you record |

### Output format

For the CONUS 2.5km forecast, write the history and restart files through [PnetCDF](https://parallel-netcdf.github.io/) (parallel netCDF): in `namelist.input`, `&time_control`, set `io_form_history = 11` and `io_form_restart = 11` (the case ships with 2, serial netCDF). Every build here links PnetCDF, so no rebuild is needed: Option 2 builds it with the other dependencies, and Spack's `wrf` package enables it by default (`+pnetcdf`). A build links it when its `configure.wrf` lists `-DPNETCDF`.

The CONUS 2.5km scripts (`x86/wrf-benchmark-conus2.5km.sbatch` and `x86/wrf-benchmark-conus2.5km-intel.sbatch`) make this change by default, in the copy of `namelist.input` they put in each run directory, and leave the one in `CONUS_DIR` as it is. They stop before `wrf.exe` unless the change sets exactly those two lines from 2 to 11, so `CONUS_DIR`'s `namelist.input` must set both to 2, each on a line of its own, as the case ships it. To run that namelist as it is, with the case's serial output for example, set `WRF_OUTPUT_FORMAT=namelist`. The CONUS 12km scripts and the Arm launcher always run the namelist as `CONUS_DIR` has it.

The scripts make the change with this `sed`, which you can run on a namelist of your own:

```bash
sed -i -E 's/^([[:space:]]*io_form_(history|restart)[[:space:]]*=[[:space:]]*)2([[:space:]]*,?[[:space:]]*)$/\111\3/' namelist.input
grep -E '^[[:space:]]*io_form_(history|restart)' namelist.input   # both now 11
```

- Parallel output is meant for a parallel file system, such as FSx for Lustre, where the measurements under [Performance](#performance) were made, with the file system's default striping layout.
- PnetCDF writes uncompressed CDF-2 (64-bit offset) files: on CONUS 2.5km, about 8.5 GB per history file and 33 GB for the restart. Check that your post-processing reads CDF-2; older versions of UPP did not.
- PnetCDF also writes each `:` of a file's name as `_`: `rsl.error.0000` names the first history file `wrfout_d01_2019-11-26_18:00:00`, and PnetCDF writes it as `wrfout_d01_2019-11-26_18_00_00`. Serial netCDF keeps the colons unless `nocolons = .true.`. Post-processing that opens the files by name needs the new names. WRF itself opens a restart file under its name with colons, so a run that restarts from a PnetCDF restart file needs `nocolons = .true.` in its `namelist.input` (its own files then have `_` too), or a link under the name with colons.
- With serial output, a build with netCDF-4 support writes compressed netCDF-4 (WRF's default; Spack's `netcdf_classic` variant, off by default, turns compression off at build time). On CONUS 2.5km the compression is most of the serial output's cost. If you keep serial output, `use_netcdf_classic = .true.` in `&time_control` writes uncompressed CDF-2 files instead, with the same post-processing caveat.
- ADIOS2 output and I/O quilting were not tested here. Post-processing tools such as UPP do not read ADIOS2 files, and quilting needs dedicated I/O ranks and more settings, where PnetCDF is a two-line change.

## Performance

The CONUS 2.5km results are three views of the same benchmark: WRF 4.6.1 on the CONUS 2.5km case (1501×1201 grid, 50 levels, 15s timestep), running the full 6-hour forecast it ships with (1,440 steps, a history write every hour and a restart write at 5 hours).

- [Whole run with PnetCDF output](#conus-25km--whole-run-with-pnetcdf-output-6-hour-forecast): the total wall time, with the output written as [Output format](#output-format) recommends, on `hpc8a`, `hpc7a` and `hpc6a` (AMD) and `c8i` (Intel). This is the time a run takes: use it to choose an instance type and a node count.
- [Compute scaling](#conus-25km--compute-scaling-6-hour-forecast): the steady step, which leaves the first step, the output and the input reads out, on `hpc8a`, `m8a`, `hpc7a` and `hpc6a` (AMD) and `c8i` (Intel), and on `m8g` (Graviton4) under [Arm](#arm--graviton3e-hpc7g-vs-graviton4-m8g). It shows how the time steps themselves scale.
- [Output format](#conus-25km--output-format-6-hour-forecast): what writing the output uncompressed, or in parallel through PnetCDF, changes.

The runs behind these views were made in October 2026: on `hpc8a`, `c8i`, `hpc7a` and `hpc6a` in eu-north-1 (ParallelCluster 3.16.0, EFA installer 1.49.0, Intel MPI 2021.18), and on `m8a` and `m8g` in us-east-2 (ParallelCluster 3.15.0, EFA installer 1.47.0; Intel MPI 2021.17 on `m8a`). `hpc7a` and `hpc6a` also ran the forecast with serial output in us-east-2; this README's tables and charts take their eu-north-1 runs only, so that each instance type is measured on one software stack. On the configurations run in both Regions, the two stacks' steady steps agree within 2%, but on 16 `hpc6a.48xlarge` nodes the two us-east-2 runs were both about 5% slower than the two eu-north-1 runs.

Each CPU vendor's results are given against a reference of the same vendor: one `hpc7a.96xlarge` node for the AMD types, and for `c8i.96xlarge` (Intel) and `m8g.48xlarge` (Graviton4), the only types of their vendors in these runs, one node of the same type.

### CONUS 2.5km — whole run with PnetCDF output (6-hour forecast)

This chart shows the scaling of the whole forecast with its history and restart files written through PnetCDF (`io_form_history = io_form_restart = 11`) to FSx for Lustre, on 1 to 16 nodes of the AMD-based AWS EC2 [hpc8a](https://aws.amazon.com/ec2/instance-types/hpc8a/), [hpc7a](https://aws.amazon.com/ec2/instance-types/hpc7a/) and [hpc6a](https://aws.amazon.com/ec2/instance-types/hpc6a/) instances. The Intel-based [c8i](https://aws.amazon.com/ec2/instance-types/c8i/) follows the table, against one node of its own type.

Every node is fully populated with one MPI rank per core (96 on `hpc6a.48xlarge`, 192 on the others), over EFA, with the GCC + Intel MPI build (Option 2) and the Intel MPI settings of `x86/wrf-benchmark-conus2.5km-intel.sbatch` (Intel MPI 2021.18, MULTIRAIL enabled). Performance is the whole run: the wall time of `wrf.exe` from the start of `mpirun` to its exit, output included (the scripts' `Total WRF time`), the median over each configuration's runs, normalized to a single `hpc7a.96xlarge` node — higher is better. The right panel shows each instance type's parallel efficiency against its own single node.

![WRF CONUS 2.5km 6-hour forecast with PnetCDF output: scaling of the whole run on AMD instance types](https://github.com/aws-samples/hpc-applications/blob/main/Doc/img/WRF/WRF-CONUS2.5km-6h-PnetCDF-Scaling.png?raw=true)

Relative performance with PnetCDF output (1 node `hpc7a.96xlarge` = 1.00×), and in brackets the parallel efficiency against one node of the same type:

| Nodes | hpc8a.96xlarge | hpc7a.96xlarge | hpc6a.48xlarge |
|------:|---------------:|---------------:|---------------:|
| 1 | 1.39× | 1.00× | 0.42× |
| 2 | 2.78× (100%) | 2.04× (102%) | 0.81× (96%) |
| 4 | 5.40× (97%) | 3.94× (98%) | 1.64× (98%) |
| 8 | 9.75× (88%) | 7.25× (91%) | 3.25× (97%) |
| 16 | — | — | 6.15× (92%) |

Every value is the median of 2 runs, and the two runs of each configuration agree within 1%. The runs were made in eu-north-1 in October 2026, with up to 3 other benchmark jobs sharing their FSx for Lustre file system.

`c8i.96xlarge` (Intel) ran the same forecast with PnetCDF output on 1 and 2 nodes, 2 runs each: against one `c8i.96xlarge` node = 1.00×, two nodes ran 1.90×, a parallel efficiency of 95%.

Key takeaways:

- The whole run keeps scaling to 1,536 cores: on 8 nodes, parallel efficiency is **88%** on `hpc8a.96xlarge`, **91%** on `hpc7a.96xlarge` and 97% on `hpc6a.48xlarge`, and 92% on 16 `hpc6a.48xlarge` nodes. With serial output instead (compressed netCDF-4, the default of a build with netCDF-4 support), the same forecast reached 42% on 8 `hpc8a.96xlarge` nodes (see [CONUS 2.5km — output format](#conus-25km--output-format-6-hour-forecast)).
- A single hpc8a node runs the whole forecast **1.39×** as fast as a single hpc7a node, and hpc8a stays at 1.34–1.39× hpc7a at every node count from 1 to 8.
- One `hpc6a.48xlarge` node (96 cores) delivers 0.42× of one `hpc7a.96xlarge` node (192 cores).
- The time outside the steady step (the output, the input reads and the first step) shrinks far less than the time steps as nodes are added, so its share of the run grows from 3–7% on one node to 21–28% on 1,536 cores. The steady step itself keeps 98–118% parallel efficiency in the same runs: that share is what brings the whole-run efficiency down.

### CONUS 2.5km — compute scaling (6-hour forecast)

This chart shows how the time steps of the same forecast scale, leaving the first step, the output and the input reads out, on 1 to 16 nodes of the AMD-based AWS EC2 [hpc8a](https://aws.amazon.com/ec2/instance-types/hpc8a/), [m8a](https://aws.amazon.com/ec2/instance-types/m8a/), [hpc7a](https://aws.amazon.com/ec2/instance-types/hpc7a/) and [hpc6a](https://aws.amazon.com/ec2/instance-types/hpc6a/) instances. The Intel-based [c8i](https://aws.amazon.com/ec2/instance-types/c8i/) follows the table, and the Graviton4-based [m8g](https://aws.amazon.com/ec2/instance-types/m8g/) is under [Arm](#arm--graviton3e-hpc7g-vs-graviton4-m8g), each against one node of its own type. These runs wrote the serial output the case ships with (`io_form_history = io_form_restart = 2`); m8a and m8g were run with that output only. On the 15 configurations also run with PnetCDF, the steady step of the PnetCDF runs is within 2.5% of that of the serial runs: the steady step does not depend on the output format.

Every node is fully populated with one MPI rank per core (96 on `hpc6a.48xlarge`, 192 on the others), over EFA. The x86 instances run the GCC + Intel MPI build (Option 2) with the Intel MPI settings of `x86/wrf-benchmark-conus2.5km-intel.sbatch` (Intel MPI 2021.17 or 2021.18, MULTIRAIL enabled). Performance is the steady step (see [Key Metrics](#key-metrics)), the median over each configuration's runs, normalized to a single `hpc7a.96xlarge` node — higher is better. The right panel shows each instance type's parallel efficiency against its own single node.

![WRF CONUS 2.5km 6-hour forecast: scaling of the steady step on four AMD instance types](https://github.com/aws-samples/hpc-applications/blob/main/Doc/img/WRF/WRF-CONUS2.5km-6h-Scaling.png?raw=true)

Relative performance (1 node `hpc7a.96xlarge` = 1.00×):

| Nodes | hpc8a.96xlarge | m8a.48xlarge | hpc7a.96xlarge | hpc6a.48xlarge |
|------:|---------------:|-------------:|---------------:|---------------:|
| 1 | 1.38× | 1.26× (1 run) | 1.00× (3 runs) | 0.41× |
| 2 | 2.85× | 2.58× (1 run) | 2.08× | 0.80× |
| 4 | 5.92× | — | 4.30× | 1.66× |
| 8 | 12.68× | — | 9.20× | 3.46× |
| 16 | — | — | — | 7.30× |

The other values are medians of 3 runs on `hpc8a.96xlarge`, and of 2 on `hpc7a.96xlarge` and `hpc6a.48xlarge`. The runs were made in October 2026, with 0 to 8 other benchmark jobs sharing their FSx for Lustre file system (the steady step leaves file I/O out), and the runs of each configuration agree within 3%.

`c8i.96xlarge` (Intel) ran the same forecast on 1 and 2 nodes, 3 runs each: against one `c8i.96xlarge` node = 1.00×, the steady step ran 2.00× as fast on two nodes, a parallel efficiency of 100%.

Key takeaways:

- The steady step keeps scaling to 1,536 cores: hpc7a and hpc8a both reach **115%** parallel efficiency on 8 nodes, and hpc6a **112%** on 16. Efficiency above 100% means the steady step shrank more than in proportion to the node count, which points to each rank's smaller part of the grid fitting better in cache.
- A single hpc8a node delivers **1.38×** the performance of a single hpc7a node, and hpc8a stays at 1.37–1.38× hpc7a at every node count from 1 to 8.
- m8a reaches 1.26× and 2.58× on 1 and 2 nodes (one run each).
- On the total wall time instead, the same runs reach only 3.52× (hpc7a) and 4.68× (hpc8a) on 8 nodes: the hourly history writes and the restart write do not get faster with more nodes, and as these x86 runs wrote them (serial, compressed netCDF-4) they take 15–16% of a one-node hpc7a or hpc8a run but 64–66% of an 8-node one. [Whole run with PnetCDF output](#conus-25km--whole-run-with-pnetcdf-output-6-hour-forecast) gives the whole run's scaling with the output written as [Output format](#output-format) recommends, and the next section what the output format changes.

### CONUS 2.5km — output format (6-hour forecast)

The same 6-hour forecast on 1 and 8 `hpc8a.96xlarge` nodes, with its output written three ways: serial compressed netCDF-4 (the default of a build with netCDF-4 support), serial uncompressed CDF-2 (`use_netcdf_classic = .true.`) and PnetCDF (`io_form_history = io_form_restart = 11`). Performance is the whole run's (total wall time, output included), relative to the compressed default on the same node count = 1.00× — higher is better:

| Output | 1 node | 8 nodes |
|--------|-------:|--------:|
| Serial, compressed netCDF-4 (default) | 1.00× | 1.00× |
| Serial, uncompressed CDF-2 (`use_netcdf_classic = .true.`) | 1.11× | 1.81× |
| PnetCDF (`io_form_history = io_form_restart = 11`) | 1.15× | 2.38× |

The runs used the GCC + Intel MPI build (Option 2, Intel MPI 2021.18) with 192 MPI ranks per node over EFA, on FSx for Lustre in eu-north-1, in October 2026. The values are medians of 2 runs (3 for the compressed default), and each point's runs agree within 3%. Up to 7 other benchmark jobs shared the file system; on 8 nodes the slowest compressed run had the fewest.

Key takeaways:

- Only the output changes: the steady step is the same with all three, within 1%.
- About three quarters of the time PnetCDF saves comes from not compressing (78% of it on 1 node, 77% on 8), and writing in parallel does the rest: PnetCDF is 1.03× the uncompressed serial run on 1 node and 1.31× on 8.
- The time outside the steady step (the output, the input reads and the first step) is 70% of the compressed run on 8 nodes, 45% of the uncompressed serial run and 27% of the PnetCDF run; on 1 node, 18%, 8.5% and 4.8%.
- Whole-run parallel efficiency on 8 nodes against 1 goes from 42% (compressed) to 69% (uncompressed serial) and 88% (PnetCDF).

Every configuration of [Whole run with PnetCDF output](#conus-25km--whole-run-with-pnetcdf-output-6-hour-forecast) also has serial, compressed runs, under [Compute scaling](#conus-25km--compute-scaling-6-hour-forecast). PnetCDF against serial, compressed output on the same configuration of the AMD types (whole run, the serial runs = 1.00×, higher is better):

| Nodes | hpc8a.96xlarge | hpc7a.96xlarge | hpc6a.48xlarge |
|------:|---------------:|---------------:|---------------:|
| 1 | 1.15× | 1.14× (3 serial runs) | 1.07× |
| 2 | 1.30× | 1.32× | 1.13× |
| 4 | 1.61× | 1.62× | 1.28× |
| 8 | 2.38× | 2.35× | 1.57× |
| 16 | — | — | 2.19× |

Each value compares the medians of the two sections' runs, all made in eu-north-1: 2 with PnetCDF, and with serial output 3 on `hpc8a.96xlarge` and 2 on `hpc7a.96xlarge` and `hpc6a.48xlarge`, or 3 where marked. The gain grows with the node count, because the time steps get faster with more nodes while the serial output does not, so the output takes a growing share of the serial run. It is smallest on `hpc6a.48xlarge`, whose time steps take longest, so that the output is a smaller share of its runs. How much of the gain comes from not compressing was measured on `hpc8a.96xlarge` only, in the first table of this section.

On `c8i.96xlarge` (Intel), against its own serial, compressed runs (3 on each node count, 2 with PnetCDF), PnetCDF ran 1.21× as fast on 1 node and 1.46× on 2.

### Arm — Graviton3E (hpc7g) vs Graviton4 (m8g)

This chart shows the scaling performance of WRF 4.6.1 running both CONUS benchmarks on [hpc7g](https://aws.amazon.com/ec2/instance-types/hpc7g/) (Graviton3E, Neoverse V1, 64 cores) vs [m8g](https://aws.amazon.com/ec2/instance-types/m8g/) (Graviton4, Neoverse V2, 192 cores) instances.

Each platform uses the CPU-tuned GCC build (`target=neoverse_v1` on Graviton3E, `target=neoverse_v2` on Graviton4), OpenMPI 5.0.9 over EFA, and pure MPI (one rank per core, `OMP_NUM_THREADS=1`). Performance is expressed as speedup on the total wall time (output included), normalized to a single `hpc7g.16xlarge` node — higher is better.

![WRF CONUS Graviton3E vs Graviton4](https://github.com/aws-samples/hpc-applications/blob/main/Doc/img/WRF/WRF-CONUS-Graviton3VsGraviton4.png?raw=true)

**CONUS 12km** — speedup vs 1 node hpc7g:

| Nodes | hpc7g (64 c/n) | m8g (192 c/n) |
|------:|---------------:|--------------:|
| 1 | 1.00× | **2.52×** |
| 2 | 1.75× | 3.41× |
| 4 | 2.55× | — (decomp limit) |

**CONUS 2.5km** — speedup vs 1 node hpc7g (estimated as 2 × 2N):

| Nodes | hpc7g (64 c/n) | m8g (192 c/n) |
|------:|---------------:|--------------:|
| 1 | *1.00× (est. 2 × 2N)* | **3.08×** |
| 2 | 2.00× | 5.04× |
| 4 | 3.30× | **7.49×** |

Key takeaways:

- A single m8g node delivers **2.52× (12km)** and an estimated **3.08× (2.5km)** the performance of a single hpc7g node — consistent with the 3× core-count ratio minus the usual communication/memory-bandwidth tax
- On CONUS 2.5km, m8g reaches **5.04× (2N)** and **7.49× (4N)** vs the hpc7g 1N baseline, while hpc7g scales from 1N → 4N at **3.30×** — both platforms scale sub-linearly (Amdahl) but G4 stays consistently ahead
- The **CONUS 12km grid (425×300) is too small for WRF's default split of 768 ranks (4N m8g)**: WRF requires each rank's patch to span at least 10 grid cells in each direction, and that split, 24 × 32 ranks in x and y, leaves 9 cells per rank in y, so WRF stops before the run starts. For that level of parallelism, use CONUS 2.5km (1501×1201), which supports 1500+ ranks cleanly.
- The 1N hpc7g 2.5km point is *estimated* at 2 × the 2N time; running it directly on a single 64-core node is expensive and a pessimistic baseline for a grid of 1501 × 1201 points
- A single m8g node is about as fast as **4 hpc7g nodes** for this workload: 99% of their speed on CONUS 12km (2.52× against 2.55×) and 93% on CONUS 2.5km (3.08× against 3.30×)

**CONUS 2.5km, October 2026 runs** — the steady step of the 6-hour forecast (serial output, as under [Compute scaling](#conus-25km--compute-scaling-6-hour-forecast)) on `m8g.48xlarge`, with the Graviton4 build and OpenMPI 5.0.9 launched as `Arm/wrf-benchmark.sbatch` does. Speedup against one `m8g.48xlarge` node, and in brackets the parallel efficiency:

| Nodes | m8g.48xlarge (192 c/n) |
|------:|-----------------------:|
| 1 | 1.00× |
| 2 | 1.93× (97%) |
| 4 | 3.81× (95%) |
| 8 | 7.67× (96%, 2 runs) |

The other values are medians of 3 runs. The steady step keeps 95–97% parallel efficiency from 2 to 8 nodes of `m8g.48xlarge`.

## Key Metrics

- **Average time per timestep** — extracted from `rsl.error.0000`; it includes the output writes, so to see how the time steps scale with the node count use the median or the steady step (below)
- **Median and steady time per timestep** — printed by every benchmark script next to the average (`Median timestep:`, `Steady timestep:`) and recorded with it; the steady step leaves out the first step and every step that follows an output write or a boundary read ([`lib/wrf-step-timing.sh`](lib/wrf-step-timing.sh))
- **Total wall time** — end-to-end execution time including MPI startup and I/O: the time a run takes

Run the full forecast the case ships with (6 hours, 1,440 steps of 15 s for CONUS 2.5km), not a shortened one. To see how the time steps scale with the node count, use the median time per step, or the steady step: the average without the first step and the steps that write output or read boundaries. The average per step and the total wall time both include output, which does not get faster in proportion to the node count: WRF counts each history or restart write in the `Timing for main` line of the step that makes it. To choose an instance type and a node count, compare the total wall time instead, with the output settings you will use ([Whole run with PnetCDF output](#conus-25km--whole-run-with-pnetcdf-output-6-hour-forecast)).

- **A shortened run mostly measures start-up.** A 5-minute window (20 steps) on 1, 2, 4 and 8 `hpc8a.96xlarge` nodes (Intel MPI, June 2026, medians of 3 to 7 runs) ran 1.22, 1.34 and 1.20 times as fast on 2, 4 and 8 nodes as on one, so 8 nodes looked slower than 4, while the median step ran 2.09, 4.31 and 9.47 times as fast. The first step took about the same time at every node count, most of it the history write at t=0, so it grew from 46-47% of the run on 1 node to 55-58% on 8, and it dominates the average over the 20 steps (only 1.47 times as fast on 8 nodes as on one).
- **The full forecast writes output every hour.** With the serial output the case ships with, on one `hpc7a.96xlarge`, `m8g.48xlarge` or `hpc6a.48xlarge` node (October 2026) its first step is under 2% of the run, but the 7 hourly history writes and the restart write took 7-17% of it, all but the last of them inside step timings, so the average step was 17-29% above the median step. On 8 nodes of `hpc7a.96xlarge` or `hpc8a.96xlarge` the same writes took about two thirds of the run, so the more nodes, the larger the share of the output in the average and in the wall time. With PnetCDF output the writes took 1-3% of a one-node run and 16% of an 8-node `hpc7a.96xlarge` or `hpc8a.96xlarge` run: much less, but they do not shrink as the time steps do: on 8 `hpc8a.96xlarge` nodes they took 5% longer than on one, and on 8 `hpc7a.96xlarge` nodes 30% less.

The 5-minute runs were launched a few at a time: 21 of the 22 overlapped 1 to 4 of the others on the cluster and its FSx for Lustre file system, and the one made alone (4 nodes) matched the other 4-node runs within 1%. The one-node 6-hour runs had up to 6 other benchmark jobs running on the same file system when they started or ended.

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

### Shared ([`lib/`](lib/), [`tests/`](tests/))

| File | Description |
|------|-------------|
| `lib/wrf-run-info.sh` | What every benchmark script records about the run besides its times: the grid size, the simulated minutes, the number of time steps and the history output's `io_form` |
| `lib/wrf-step-timing.sh` | Median and steady time per timestep from `rsl.error.0000`, used by every benchmark script |
| `lib/wrf-run-check.sh` | The check every benchmark script runs before it records a run: `SUCCESS COMPLETE WRF`, and the history and restart files in place |
| `tests/run-tests.sh` | The helpers' tests and the benchmark scripts' end-to-end tests (see [`tests/README.md`](tests/README.md)) |

## Contribute your results

The benchmark scripts in this folder call [`dynamodb/record-benchmark.sh`](dynamodb/record-benchmark.sh) after every run that completed and wrote its output (see [Benchmark](#benchmark)). The recorder saves the run as a small JSON record (`<record_id>.json`) and adds it to the shared AI-Powered HPC benchmark dataset when you have write access to it. That dataset trains a model that predicts HPC performance on AWS, so every result you share helps. Set `SOURCE=<YourOrg>` to tag your runs, and see [BENCHMARK-RECORDERS.md](../BENCHMARK-RECORDERS.md) for the options and how to send the record in.
