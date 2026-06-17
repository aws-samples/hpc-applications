# NAMD

This directory contains scripts for building and benchmarking [NAMD](https://www.ks.uiuc.edu/Research/namd/) on AWS HPC instances. NAMD is a parallel molecular dynamics code from the University of Illinois, designed for high-performance simulation of large biomolecular systems. Unlike the MPI-based codes in this repository, NAMD is built on the [Charm++](https://charm.cs.illinois.edu/) parallel runtime; on AWS the high-performance multi-node path is the Charm++ **OFI (libfabric) backend over EFA**.

The scripts are organised by architecture / accelerator:

- [`x86/`](x86/) — builds and benchmarks for x86_64 (`hpc8a`, `hpc7a`)
- [`Arm/`](Arm/) — builds and benchmarks for aarch64 (`hpc7g` / Graviton3E, `m8g` / Graviton4)
- [`GPU/`](GPU/) — GPU benchmarks via the official NVIDIA NGC `namd:3.0.1` container (`g6e` / L40S, `g7e` / Blackwell RTX PRO 6000, `p5` / H100)

## Phasing

| Phase | Target | Approach | Status |
|-------|--------|----------|--------|
| **Phase 1** | x86 (hpc8a, hpc7a) | Build from source: Charm++ (OFI/EFA, SMP) + NAMD with AVX-512 tile lists | In Progress |
| **Phase 2** | Arm (hpc7g, m8g) | Build from source: Charm++ (OFI/EFA, SMP) + NAMD for aarch64 | Future-Scope |
| **Phase 3** | GPU (g6e, g7e, p5) | NAMD 3.0 GPU-resident mode via the NVIDIA NGC `namd:3.0.1` container | Future-Scope |

## Why Charm++ OFI over EFA

NAMD does not use MPI directly — it runs on the Charm++ parallel runtime, whose network backend determines how nodes communicate. On AWS the recommended multi-node backend is **OFI**, which targets libfabric directly and therefore uses the EFA provider for RDMA. The **SMP** variant (`ofi-linux-x86_64-smp`) runs one process per node with several worker threads (PEs) plus a communication thread, minimising the number of EFA endpoints per node — the best fit for NAMD's communication pattern. Single-node runs use the `multicore` backend (no network layer).

## Build (Phase 1 — x86)

> **NAMD source requires accepting a license.** The NAMD source tarball is distributed from the [NAMD download page](https://www.ks.uiuc.edu/Research/namd/) behind a license click-through, so it cannot be fetched non-interactively. Download `NAMD_<version>_Source.tar.gz` once (accepting the license) and place it at `${BASE_DIR}/src/` (default `/fsx/namd/src/`); the build script picks it up from there.

```bash
# After staging /fsx/namd/src/NAMD_3.0.1_Source.tar.gz
sbatch x86/build_namd_x86.sbatch
```

The build script builds Charm++ (`ofi-linux-x86_64-smp` for multi-node EFA, plus `multicore` for single-node), then configures and compiles NAMD with AVX-512 tile lists, installing `namd3` under `/fsx/namd/x86_64/<version>/` with a generated env script.

| Variable | Default | Description |
|----------|---------|-------------|
| `NAMD_VERSION` | `3.0.1` | NAMD release (and bundled Charm++) |
| `TARGET_CPU` | `hpc8a` | `hpc8a` / `hpc7a` |
| `BASE_DIR` | `/fsx/namd` | Install root |
| `COMPILE_CORES` | `48` | Parallel build threads |

## Run (Phase 1 — x86)

*(Benchmark launcher and performance data land with Phase 1 validation.)*

```bash
# ApoA1 (~92K atoms) on a single node
sbatch --nodes=1 x86/namd-benchmark.sbatch

# STMV (~1.06M atoms) multi-node scaling over EFA
sbatch --nodes=4 --export=ALL,MODEL=STMV x86/namd-benchmark.sbatch
```

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
| `build_namd_x86.sbatch` | Build Charm++ (OFI/EFA SMP + multicore) and NAMD with AVX-512 tile lists; installs `namd3` and an env script |
| `namd-benchmark.sbatch` | Run ApoA1 / STMV over EFA (Charm++ OFI/SMP via Slurm PMI); auto-fetches and caches the deck; parses `Benchmark time: days/ns` → ns/day. *(Performance data + charts land with Phase 1 cluster validation.)* |
