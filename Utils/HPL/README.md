# HPL (High Performance Linpack) on AWS hpc8a

[HPL](https://www.netlib.org/benchmark/hpl/) is the benchmark used to rank supercomputers on the [TOP500](https://www.top500.org/). This directory contains build scripts and a parametric Slurm launcher optimised for [hpc8a.96xlarge](https://aws.amazon.com/ec2/instance-types/hpc8a/) instances.

## Target Hardware

| Component | Detail |
|-----------|--------|
| Instance  | hpc8a.96xlarge |
| CPU       | AMD EPYC 9R14 (Turin, Zen 5) |
| Cores     | 192 physical cores per node (SMT off) |
| Memory    | 768 GB DDR5 per node |
| Network   | EFA v2, 2 NICs per node |

## Files

| File | Description |
|------|-------------|
| `hpl.sbatch` | Parametric Slurm launcher — single script for all configurations |
| `build_hpl_openmpi.sh` | Build HPL linked against OpenMPI 4 |
| `build_hpl_intelmpi.sh` | Build HPL linked against Intel MPI |

## Prerequisites

1. **AOCC 5.1.0** — AMD's compiler with `-march=znver5` support. Expected at `/fsx/aocc/aocc-compiler-5.1.0/`.
2. **AOCL 5.1.0** — AMD's BLIS and libFLAME libraries. Install the RPM and copy shared libs to `/fsx`:
   ```bash
   sudo rpm -ivh /fsx/aocl-linux-gcc-5.1.0-1.x86_64.rpm
   cp -P /opt/AMD/aocl/aocl-linux-gcc-5.1.0/gcc/lib/*.so* /fsx/aocl/5.1.0/lib/
   ```
   Libraries must be on the shared filesystem (`/fsx`) so compute nodes can access them.

## Build

Both build scripts use AOCC as the underlying C compiler (via `OMPI_CC=clang` or `I_MPI_CC=clang`) while linking against the respective MPI library. This gives us `znver5` codegen with full Zen 5 ISA support (AVX-512 native 512-bit datapath) that the system GCC does not support.

```bash
bash build_hpl_openmpi.sh    # → /fsx/HPL-OpenMPI/bin/Linux_AMD_OpenMPI/xhpl
bash build_hpl_intelmpi.sh   # → /fsx/HPL-IntelMPI/bin/Linux_AMD_IntelMPI/xhpl
```

### Why AOCC instead of system GCC?

The system GCC on Amazon Linux 2023 only supports up to `-march=znver4`. AOCC 5.1.0 (clang-17) supports `-march=znver5`, which generates code using the full Zen 5 instruction set. This matters for HPL because the DGEMM inner loops benefit from the wider AVX-512 execution units.

### Why AOCL BLIS instead of OpenBLAS?

BLIS is AMD's own BLAS implementation with hand-tuned micro-kernels for each EPYC generation. The `zen5` micro-kernel in BLIS 5.1.0 is specifically optimised for the Zen 5 cache hierarchy and execution units, providing significantly better DGEMM throughput than generic OpenBLAS on this hardware.

We link against `libblis-mt` (multithreaded BLIS) but run with `BLIS_NUM_THREADS=1` in pure MPI mode — each MPI rank uses a single BLIS thread. The `-mt` variant is used because it includes the OpenMP runtime needed for BLIS's internal parallelism infrastructure even in single-threaded mode.

### Compiler flags

```
-O3 -march=znver5 -mtune=znver5 -funroll-loops -fomit-frame-pointer -ffp-contract=fast -ffast-math
```

- `-march=znver5 -mtune=znver5`: Generate code for Zen 5 (Turin) with full AVX-512 support
- `-ffp-contract=fast -ffast-math`: Allow aggressive floating-point optimisations (FMA contraction, reordering). Safe for HPL since the residual check validates numerical correctness
- `-Wl,-rpath,...`: Embed library paths in the binary so compute nodes find BLIS and AOCC libs without needing `LD_LIBRARY_PATH` at link time

## Run

The launcher is fully parametric — all HPL and MPI settings are controlled via environment variables with sensible defaults:

```bash
# Default: OpenMPI 4, 2 nodes, 384 cores, NB=384
sbatch hpl.sbatch

# Scale to 20 nodes
sbatch -N 20 -n 3840 hpl.sbatch

# Use Intel MPI
HPL_MPI=intelmpi sbatch -N 10 -n 1920 hpl.sbatch

# Override specific HPL parameters
HPL_NB=256 HPL_MEM_FRACTION=0.80 sbatch hpl.sbatch

# Custom process grid
HPL_P=12 HPL_Q=32 sbatch hpl.sbatch
```

### Parameters

| Variable | Default | Description |
|----------|---------|-------------|
| `HPL_MPI` | `openmpi` | MPI implementation: `openmpi`, `openmpi5`, or `intelmpi` |
| `HPL_NB` | `384` | Block size for matrix distribution |
| `HPL_MEM_FRACTION` | `0.78` | Fraction of total memory to use for the matrix |
| `HPL_N` | (auto) | Problem size — auto-calculated from memory if not set |
| `HPL_P` | (auto) | Process grid rows — auto-calculated as largest factor ≤ √ranks |
| `HPL_Q` | (auto) | Process grid columns — auto-calculated as ranks/P |
| `HPL_BCAST` | `1` | Broadcast algorithm (0=1rg, 1=1ringM, 2=2rg, 3=2ringM, 4=Long) |
| `HPL_DEPTH` | `0` | Lookahead depth |
| `HPL_PFACT` | `2` | Panel factorisation (0=Left, 1=Crout, 2=Right) |
| `HPL_RFACT` | `1` | Recursive factorisation (0=Left, 1=Crout, 2=Right) |
| `HPL_NBMIN` | `4` | Minimum block size for recursion stopping |
| `HPL_SWAP` | `2` | Swap algorithm (0=bin-exch, 1=long, 2=mix) |

### Why these defaults?

Each default was determined through empirical testing on hpc8a.96xlarge:

- **NB=384**: Tested 192, 256, and 384. NB=384 gives the best performance because the larger DGEMM calls let BLIS's Zen 5 micro-kernel sustain higher throughput. An NB=384 block is 1.15 MB (slightly exceeds the 1 MB L2 cache per core), but BLIS streams it efficiently.

- **BCAST=1 (1ringM)**: At 2 nodes, 1ringM and 2ringM perform similarly. At 10+ nodes, 1ringM is significantly better. The modified 1-ring broadcast has lower latency for the panel distribution step.

- **DEPTH=0**: Counter-intuitively, no lookahead (DEPTH=0) outperforms DEPTH=1 at scale. The overhead of managing the lookahead pipeline across many nodes outweighs the benefit of overlapping communication with computation. At 2 nodes, DEPTH=1 is slightly better, but DEPTH=0 is used as the default since the goal is to maximise performance at scale.

- **PFACT=2 (Right), RFACT=1 (Crout)**: A full 3×3 sweep of all PFACT/RFACT combinations showed only ~1% variation. Right/Crout is marginally the best but the difference is within noise.

- **MEM_FRACTION=0.78**: The matrix uses 78% of total node memory. Higher fractions (80-85%) cause OOM kills because MPI buffers, BLIS working memory, and OS overhead consume the remaining ~22%. At 78%, N is large enough for good HPL efficiency while leaving sufficient headroom.

### Working directory

Each run creates a unique directory under `/fsx/HPL-Run/`:

```
/fsx/HPL-Run/<job-name>/<jobid>-<nodes>x<instance-type>-<nprocs>-<dd-mm-yyyy-HH-MM>/
```

The `xhpl` binary and `HPL.dat` are copied here, so multiple concurrent runs don't interfere with each other. The instance type is detected via EC2 IMDSv2.

### MPI-specific settings

**OpenMPI**: Ranks are mapped and bound to individual cores (`--map-by core --bind-to core`). Environment variables for BLIS and AOCC are forwarded to compute nodes via `-x` flags.

**Intel MPI**: EFA is configured with:
- `I_MPI_OFI_LIBRARY_INTERNAL=0` — Use the AWS-provided libfabric instead of Intel's bundled version. This must be set **before** `module load intelmpi` and `module load libfabric-aws`.
- `I_MPI_FABRICS=shm:ofi` — Shared memory for intra-node, OFI/EFA for inter-node.
- `I_MPI_OFI_PROVIDER=efa` — Explicitly select the EFA provider.
- `I_MPI_MULTIRAIL=1` — Use both EFA NICs on hpc8a (not enabled by default in Intel MPI).
- `I_MPI_PIN_DOMAIN=core` — Pin one rank per physical core.

### System tuning

The script enables transparent hugepages and allocates explicit hugepages to reduce TLB misses on HPL's large contiguous memory allocations:

```bash
sudo sysctl -w vm.nr_hugepages=40000
echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled
echo always | sudo tee /sys/kernel/mm/transparent_hugepage/defrag
```

## References

- [HPL Official Site](https://www.netlib.org/benchmark/hpl/)
- [HPL Tuning Guide](https://www.netlib.org/benchmark/hpl/tuning.html)
- [TOP500](https://www.top500.org/)
- [AMD AOCC](https://developer.amd.com/amd-aocc/)
- [AMD AOCL](https://developer.amd.com/amd-aocl/)
- [AWS EFA Documentation](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa.html)
- [hpc8a Instance Type](https://aws.amazon.com/ec2/instance-types/hpc8a/)
