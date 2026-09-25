# HPL (High Performance Linpack) on AWS

[HPL](https://www.netlib.org/benchmark/hpl/) is the benchmark used to rank supercomputers on the [TOP500](https://www.top500.org/). This directory contains build/run scripts for both CPU-only and GPU-accelerated HPL.

## Target Hardware

### CPU (hpc8a)

| Component | Detail |
|-----------|--------|
| Instance  | hpc8a.96xlarge |
| CPU       | AMD EPYC 9R14 (Turin, Zen 5) |
| Cores     | 192 physical cores per node (SMT off) |
| Memory    | 768 GB DDR5 per node |
| Network   | EFA v2, 2 NICs per node |

### GPU (P-family instances)

| Instance | GPU | VRAM |
|----------|-----|------|
| p5.48xlarge | 8x H100 80GB | 640 GB |
| p5en.48xlarge | 8x H200 141GB | 1128 GB |
| p6-b200.48xlarge | 8x B200 | TBD |

## Files

| File | Description |
|------|-------------|
| `hpl.sbatch` | Parametric Slurm launcher for CPU HPL — single script for all configurations |
| `build_hpl_openmpi.sh` | Build CPU HPL linked against OpenMPI 4 |
| `build_hpl_intelmpi.sh` | Build CPU HPL linked against Intel MPI |
| `run_hpl_gpu.sh` | Run GPU HPL-NVIDIA via NGC container (p5/p5en/p6) |
| `hpl_gpu.sbatch` | Slurm + Pyxis launcher for GPU HPL-NVIDIA and HPL-MxP, single or multi-node over EFA |
| `hpl_gpu_container.sbatch` | Single-node GPU HPL with the whole batch job inside the NGC container |
| `hpl_bcast_sweep.sbatch` | CPU HPL broadcast algorithm sweep |

## CPU HPL (hpc8a)

### Prerequisites

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

## GPU HPL (NVIDIA)

GPU-accelerated HPL uses NVIDIA's pre-built binary distributed via the [NGC hpc-benchmarks container](https://catalog.ngc.nvidia.com/orgs/nvidia/containers/hpc-benchmarks). The upstream netlib HPL 2.3 has no GPU support — NVIDIA's closed-source fork offloads DGEMM to GPUs via cuBLAS while using CPUs for panel factorisation.

There are two ways to run it: `run_hpl_gpu.sh` on a single node with Docker, or `hpl_gpu.sbatch` under Slurm with Pyxis/Enroot on one or more nodes.

### Single node with Docker (`run_hpl_gpu.sh`)

- Docker with `nvidia-container-toolkit`
- NVIDIA GPU drivers (pre-installed on the [Deep Learning AMI](https://aws.amazon.com/machine-learning/amis/))
- No compilation needed — the binary is inside the container

```bash
# Default: auto-detect GPUs, 90% VRAM, NB=1024
bash run_hpl_gpu.sh

# Override problem size
HPL_N=400000 bash run_hpl_gpu.sh

# Different container version
HPL_NGC_TAG=24.09 bash run_hpl_gpu.sh
```

### `run_hpl_gpu.sh` parameters

| Variable | Default | Description |
|----------|---------|-------------|
| `HPL_NGC_TAG` | `25.02` | NGC container version |
| `HPL_NB` | `1024` | Block size |
| `HPL_MEM_FRACTION` | `0.90` | Fraction of GPU VRAM for the matrix |
| `HPL_N` | (auto) | Problem size — auto-calculated from GPU memory if not set |
| `HPL_P` | `1` | Process grid rows |
| `HPL_Q` | (auto) | Process grid columns — defaults to number of GPUs |
| `HPL_WORK_DIR` | `/tmp/hpl-gpu-run` | Working directory for HPL.dat and logs |

### Slurm with Pyxis (`hpl_gpu.sbatch`)

`hpl_gpu.sbatch` runs HPL-NVIDIA, and optionally HPL-MxP, through Pyxis/Enroot on one or more nodes. It launches one MPI rank per GPU with `srun --mpi=pmix`, so it needs a Slurm cluster with Pyxis/Enroot (for example AWS ParallelCluster with the [Pyxis post-install scripts](../../ParallelCluster/post-install)) and, for multi-node runs, EFA enabled on the compute nodes. Slurm writes the job log to `/fsx/HPL-Run/gpu`, so create it first:

```bash
mkdir -p /fsx/HPL-Run/gpu
sbatch hpl_gpu.sbatch                      # 1 node
sbatch -N 2 hpl_gpu.sbatch                 # 2 nodes over EFA
HPL_RUN_MXP=1 sbatch -N 2 hpl_gpu.sbatch   # also run HPL-MxP
NGC_TAG=26.02 sbatch hpl_gpu.sbatch        # other container version
```

| Variable | Default | Description |
|----------|---------|-------------|
| `NGC_TAG` | `26.02.01` | NGC container version |
| `NGC_IMAGE` | `nvcr.io#nvidia/hpc-benchmarks:${NGC_TAG}` | Full image reference, or a local `.sqsh` file |
| `HPL_NB` | `1024` | Block size |
| `HPL_MEM_FRACTION` | `0.85` | Fraction of GPU memory for the matrix (0.78 for GPUs under 100 GB, 0.70 under 50 GB) |
| `HPL_RUN_MXP` | `0` | Set to `1` to run HPL-MxP after HPL |

On a single node the script uses `P=1`, `Q=GPUs` and NVSHMEM over NVSwitch, with the settings in [Key environment variables](#key-environment-variables-single-node). Across nodes it uses one process row per node (`P=nodes`, `Q=GPUs per node`) and switches NVSHMEM off:

| Variable | Multi-node value | Purpose |
|----------|------------------|---------|
| `HPL_USE_NVSHMEM` | `0` | NVSHMEM off (see the known issue below) |
| `HPL_P2P_AS_BCAST` | `1` | Broadcasts over NCCL send/recv, which uses EFA through the container's AWS OFI NCCL plugin |
| `HPL_FCT_COMM_POLICY` | `1` | Panel factorisation over host MPI (HPC-X UCX over EFA) |
| `OMPI_MCA_coll_ucc_enable` | `0` | Disable UCC (known issue with HPC-X 2.25) |
| `FI_PROVIDER` | `efa` | Use the EFA libfabric provider |
| `FI_EFA_USE_DEVICE_RDMA` | `1` | Enable GPUDirect RDMA |

Validated on 2026-09-24 with `hpc-benchmarks` 26.02.01 on p5en.48xlarge at default GPU clocks: HPL and HPL-MxP on one and two nodes with `hpl_gpu.sbatch`, and HPL on one node with `hpl_gpu_container.sbatch`, all passed the residual check.

`hpl_gpu_container.sbatch` is a single-node alternative that runs the whole batch job inside the container:

```bash
sbatch --container-image='nvcr.io#nvidia/hpc-benchmarks:26.02.01' hpl_gpu_container.sbatch
```

#### Known issue: NVSHMEM over EFA

`hpc-benchmarks` 26.02 and 26.02.01 bundle NVSHMEM 3.5.19. With `HPL_USE_NVSHMEM=1` across nodes, every rank segfaults inside libfabric (`fi_getinfo`) when NVSHMEM brings up its EFA transport. NVSHMEM 3.6.5 fixed libfabric compatibility issues between build and runtime versions ([release notes](https://docs.nvidia.com/nvshmem/release-notes-install-guide/prior-releases/release-3605.html)), but overlaying a newer NVSHMEM build on the bundled `xhpl` fails too. Keep NVSHMEM off for multi-node runs until an `hpc-benchmarks` image ships NVSHMEM 3.6.5 or later.

### Tuning notes

Performance depends heavily on NB, CHUNK_SIZE_NBS, and CTA_PER_FCT. Run parameter sweeps on your target instance type to find the optimal configuration. The defaults in the script were determined through empirical testing on p5 and p5en instances.

### Key environment variables (single node)

| Variable | Value | Purpose |
|----------|-------|---------|
| `HPL_USE_NVSHMEM` | `1` | GPU-initiated comms over NVSwitch |
| `HPL_P2P_AS_BCAST` | `1` | NCCL send/recv for broadcast |
| `HPL_NVSHMEM_SWAP` | `1` | Row swaps via NVSHMEM over NVSwitch |
| `HPL_FCT_COMM_POLICY` | `0` | Panel factorisation comms via NVSHMEM |
| `HPL_CHUNK_SIZE_NBS` | `64` | Larger compute chunks for better GPU utilisation |
| `HPL_CTA_PER_FCT` | `32` | Thread blocks for factorisation |
| `HPL_ALLOC_HUGEPAGES` | `1` | 2MB hugepages for host allocations |

### Why P=1 Q=N?

On single-node NVSwitch topologies, `P=1 Q=NUM_GPUS` outperforms `P=2 Q=NUM_GPUS/2` because it minimises row-swap communication. All GPUs are fully connected via NVSwitch (NV18), so the 1D decomposition avoids the extra communication overhead of a 2D grid.

### GPU clock optimisation

For best results, set GPU clocks to maximum before running (per [AWS docs](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/optimize_gpu.html)):

```bash
sudo nvidia-persistenced
# p5 (H100):
sudo nvidia-smi -ac 2619,1980
# p5en (H200):
sudo nvidia-smi -ac 3201,1980
# p6-b200 (B200):
sudo nvidia-smi -ac 3996,1965
```

### HPL-MxP (mixed-precision)

HPL-MxP uses the same NGC container (`hpl-mxp.sh`). It uses mixed-precision arithmetic (FP8/FP16 for LU factorisation, FP64 for iterative refinement). Use `--sloppy-type 1` (FP8) for best performance on H100/H200.

`hpl_gpu.sbatch` runs it after HPL when `HPL_RUN_MXP=1`, on one node or across nodes. The HPL-MxP binary does not use NVSHMEM, so the NVSHMEM-over-EFA issue above does not affect it.

## References

- [HPL Official Site](https://www.netlib.org/benchmark/hpl/)
- [HPL Tuning Guide](https://www.netlib.org/benchmark/hpl/tuning.html)
- [TOP500](https://www.top500.org/)
- [AMD AOCC](https://developer.amd.com/amd-aocc/)
- [AMD AOCL](https://developer.amd.com/amd-aocl/)
- [AWS EFA Documentation](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa.html)
- [hpc8a Instance Type](https://aws.amazon.com/ec2/instance-types/hpc8a/)
- [NVIDIA HPC Benchmarks (NGC)](https://catalog.ngc.nvidia.com/orgs/nvidia/containers/hpc-benchmarks)
- [NVIDIA HPL Benchmark Docs](https://docs.nvidia.com/nvidia-hpc-benchmarks/HPL_benchmark.html)
- [AWS GPU Optimisation](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/optimize_gpu.html)
