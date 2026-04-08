# HPL (High Performance Linpack)

[HPL](https://www.netlib.org/benchmark/hpl/) is the benchmark used to rank supercomputers on the [TOP500 list](https://www.top500.org/). It measures floating-point performance by solving a dense system of linear equations. This directory contains build scripts and Slurm job scripts optimised for AWS `hpc8a.96xlarge` instances.

## Target Hardware

| Component | Detail |
|-----------|--------|
| Instance  | hpc8a.96xlarge |
| CPU       | AMD EPYC 9R14 (Turin, Zen 5 / `znver5`) |
| Cores     | 192 physical cores per node (SMT off) |
| Memory    | 768 GB DDR5 per node |
| Network   | EFA v2 (Elastic Fabric Adapter), 2 NICs |

## Architecture-Specific Optimisations

### Compiler
Both build scripts use AMD AOCC 5.1.0 (`clang-17`) which supports `-march=znver5` for full Zen 5 ISA codegen (AVX-512 with native 512-bit datapath). AOCC is set as the underlying compiler for `mpicc` via `I_MPI_CC=clang` (Intel MPI) or `OMPI_CC=clang` (OpenMPI).

### BLAS
AMD AOCL 5.1.0 BLIS multithreaded (`libblis-mt`) + libFLAME. BLIS is AMD's own BLAS implementation with micro-kernels hand-tuned for each EPYC generation. The runtime variable `BLIS_ARCH_TYPE=zen5` selects the Zen 5 kernel.

### Compiler flags
`-O3 -march=znver5 -mtune=znver5 -funroll-loops -fomit-frame-pointer -ffp-contract=fast -ffast-math`

### Process binding
HPL is compute-bound — all 192 physical cores per node are used. Ranks are pinned 1:1 to cores (`I_MPI_PIN_DOMAIN=core` for Intel MPI, `--map-by core --bind-to core` for OpenMPI).

### Memory / hugepages
Transparent hugepages and explicit hugepages (`vm.nr_hugepages=40000`) are enabled to reduce TLB misses.

### HPL.dat tuning
The sbatch scripts use an expanded HPL.dat that sweeps multiple algorithmic variants (PFACT, RFACT, BCAST, DEPTH) in a single run to find the best combination for the hardware.

## Files

| File | Description |
|------|-------------|
| `build_hpl_openmpi.sh`  | Build HPL with OpenMPI + AOCC + AOCL BLIS |
| `build_hpl_intelmpi.sh` | Build HPL with Intel MPI + AOCC + AOCL BLIS |
| `hpl_openmpi.sbatch`    | Slurm job — OpenMPI, 2 × hpc8a (default) |
| `hpl_intelmpi.sbatch`   | Slurm job — Intel MPI, 2 × hpc8a (default) |

## Prerequisites

1. AOCC 5.1.0 installed at `/fsx/aocc/aocc-compiler-5.1.0/`
2. AOCL 5.1.0 installed: `sudo rpm -ivh /fsx/aocl-linux-gcc-5.1.0-1.x86_64.rpm`

## Build

```bash
# OpenMPI variant
bash build_hpl_openmpi.sh

# Intel MPI variant
bash build_hpl_intelmpi.sh
```

## Run

```bash
sbatch hpl_intelmpi.sbatch
# or
sbatch hpl_openmpi.sbatch
```

## Scaling

Override node count and tasks from the command line (the script computes N, P, Q automatically):

```bash
# 4 nodes, all cores
sbatch -N 4 -n 768 hpl_intelmpi.sbatch

# 8 nodes, all cores
sbatch -N 8 -n 1536 hpl_intelmpi.sbatch
```

### Example auto-calculated values

| Nodes | Total RAM | N (auto) | P  | Q  | Ranks |
|-------|-----------|----------|----|----|-------|
| 1     | 768 GB    | 288768   | 12 | 16 | 192   |
| 2     | 1536 GB   | 408576   | 16 | 24 | 384   |
| 4     | 3072 GB   | 577536   | 24 | 32 | 768   |
| 8     | 6144 GB   | 816768   | 32 | 48 | 1536  |

### Manual overrides

```bash
export HPL_N=500000 HPL_P=16 HPL_Q=24
sbatch hpl_intelmpi.sbatch
```

## References

- [HPL Official Site](https://www.netlib.org/benchmark/hpl/)
- [HPL Tuning Guide](https://www.netlib.org/benchmark/hpl/tuning.html)
- [AMD AOCC](https://developer.amd.com/amd-aocc/)
- [AMD AOCL](https://developer.amd.com/amd-aocl/)
- [EFA Documentation](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa.html)
