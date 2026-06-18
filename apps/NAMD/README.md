# NAMD

This directory contains scripts for building and benchmarking [NAMD](https://www.ks.uiuc.edu/Research/namd/) on AWS HPC instances. NAMD is a parallel molecular dynamics code from the University of Illinois, designed for high-performance simulation of large biomolecular systems. Unlike the MPI-based codes in this repository, NAMD is built on the [Charm++](https://charm.cs.illinois.edu/) parallel runtime; on AWS the high-performance multi-node path is the Charm++ **MPI backend layered on the system OpenMPI**, which rides EFA through its libfabric provider.

The scripts are organised by architecture / accelerator:

- [`x86/`](x86/) — builds and benchmarks for x86_64 (`hpc8a`, `hpc7a`)
- [`Arm/`](Arm/) — builds and benchmarks for aarch64 (`hpc7g` / Graviton3E, `m8g` / Graviton4)
- [`GPU/`](GPU/) — GPU benchmarks via the official NVIDIA NGC `namd:3.0.1` container (`g6e` / L40S, `g7e` / Blackwell RTX PRO 6000, `p5` / H100)

## Phasing

| Phase | Target | Approach | Status |
|-------|--------|----------|--------|
| **Phase 1** | x86 (hpc8a, hpc7a) | Build from source: Charm++ (MPI/SMP over OpenMPI/EFA) + NAMD | Validated (x86 build + single/multi-node run) |
| **Phase 2** | Arm (hpc7g, m8g) | Build from source: Charm++ (MPI/SMP over OpenMPI/EFA) + NAMD for aarch64 | Future-Scope |
| **Phase 3** | GPU (g6e, g7e, p5) | NAMD 3.0 GPU-resident mode via the NVIDIA NGC `namd:3.0.1` container | Future-Scope |

## Why the Charm++ MPI backend over EFA

NAMD does not use MPI directly — it runs on the Charm++ parallel runtime, whose network backend determines how nodes communicate. Charm++ ships several backends (`netlrts`, `mpi`, `ucx`, `ofi`, `verbs`, `multicore`). We build the **`mpi` backend on top of the system OpenMPI**: OpenMPI uses EFA underneath via its libfabric provider, so inter-node Charm++ traffic still rides EFA RDMA, while avoiding the native `ofi` backend (Charm++ 8.0.0's OFI machine layer does not compile against the recent libfabric shipped on current AWS HPC AMIs). The **SMP** variant (`mpi-linux-x86_64-smp`) runs one process per node with several worker threads (PEs) plus a communication thread, minimising per-node endpoints — the best fit for NAMD's communication pattern. Single-node runs use the same SMP binary with one process.

## Build (Phase 1 — x86)

> **NAMD source requires accepting a license.** The NAMD source tarball is distributed from the [NAMD download page](https://www.ks.uiuc.edu/Research/namd/) behind a license click-through, so it cannot be fetched non-interactively. Download `NAMD_<version>_Source.tar.gz` once (accepting the license) and place it at `${BASE_DIR}/src/` (default `/fsx/namd/src/`); the build script picks it up from there.

```bash
# After staging /fsx/namd/src/NAMD_3.0.2_Source.tar.gz
sbatch x86/build_namd_x86.sbatch
```

The build script builds a static single-precision FFTW into the install prefix, builds Charm++ (`mpi-linux-x86_64-smp` over the system OpenMPI/EFA), then configures and compiles NAMD, installing a self-contained `namd3` under `/fsx/namd/x86_64/<version>/` with a generated env script. AVX-512 vectorisation comes from the host architecture flags (`-march=x86-64-v4`); FFTW is linked statically so the binary carries no external FFTW `.so` on ephemeral compute nodes, and TCL is linked against the runtime that ships in the base AMI.

| Variable | Default | Description |
|----------|---------|-------------|
| `NAMD_VERSION` | `3.0.2` | NAMD release (and bundled Charm++) |
| `TARGET_CPU` | `hpc8a` | `hpc8a` / `hpc7a` |
| `BASE_DIR` | `/fsx/namd` | Install root |
| `COMPILE_CORES` | `48` | Parallel build threads |

## Run (Phase 1 — x86)

```bash
# ApoA1 (~92K atoms) on a single node
sbatch --nodes=1 x86/namd-benchmark.sbatch

# STMV (~1.06M atoms) multi-node scaling over EFA
sbatch --nodes=4 --export=ALL,MODEL=STMV x86/namd-benchmark.sbatch
```

The launcher sources the build's env script, verifies EFA on multi-node runs (`fi_info -p efa`), auto-fetches and caches the deck, then launches `namd3` with `mpirun` (one process per node + `PPN` worker threads). On multi-node runs OpenMPI carries the traffic over EFA (`--mca pml cm --mca mtl ofi`, `FI_PROVIDER=efa`).

| Variable | Default | Description |
|----------|---------|-------------|
| `NAMD_ENV` | auto | Path to the generated env script |
| `MODEL` | `ApoA1` | `ApoA1` / `STMV` |
| `TIMESTEPS` | model default | `numsteps` override |
| `PPN` | auto | Charm++ worker threads (PEs) per node |
| `BASE_DIR` | `/fsx/namd` | Run-output root |

## Benchmark Models

| `MODEL` | System | Atoms (approx) | Source |
|---------|--------|---------------:|--------|
| `ApoA1` | Apolipoprotein A1 | ~92,224 | [NAMD utilities](https://www.ks.uiuc.edu/Research/namd/utilities/) |
| `STMV` | Satellite Tobacco Mosaic Virus | ~1,066,628 | [NAMD utilities](https://www.ks.uiuc.edu/Research/namd/utilities/) |

Input decks are auto-fetched from the NAMD utilities pages on first run and cached on FSx at `/fsx/namd/benchmarks/<MODEL>/`.

## Metrics

NAMD prints its performance near the end of the run on a `Benchmark time:` line:

```
Info: Benchmark time: 96 CPUs 0.00521 s/step 0.0603 days/ns 512 MB memory
```

The launcher extracts the **`days/ns`** value and converts it to the canonical **`ns/day = 1 / days_per_ns`**, and also captures `WallClock`. Charts are speedup-only (no absolute `ns/day`), consistent with the GROMACS / LAMMPS / WRF convention.

## Files

### x86 ([`x86/`](x86/))

| File | Description |
|------|-------------|
| `build_namd_x86.sbatch` | Build static FFTW + Charm++ (`mpi-linux-x86_64-smp` over OpenMPI/EFA) and NAMD; installs a self-contained `namd3` and an env script |
| `namd-benchmark.sbatch` | Run ApoA1 / STMV over EFA (Charm++ MPI/SMP via `mpirun`); auto-fetches and caches the deck; parses `Benchmark time: days/ns` → ns/day |
