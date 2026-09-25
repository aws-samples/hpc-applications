# GPU Microbenchmarks

System readiness microbenchmarks for GPU clusters using the [NVIDIA HPC Benchmarks](https://catalog.ngc.nvidia.com/orgs/nvidia/containers/hpc-benchmarks) container (26.02.01). These tests validate NCCL and MPI performance over EFA before running large-scale GPU workloads like HPL. The NVSHMEM tests are included but skipped by default because of a known issue on EFA (see [Known issues](#known-issues)).

## Prerequisites

- AWS ParallelCluster with Pyxis/Enroot configured
- p5.48xlarge (or p5en.48xlarge) instances with EFA enabled
- FSx for Lustre mounted at `/fsx`
- Local NVMe mounted at `/scratch`

## What's included

### `microbench.sbatch`

Runs the following benchmarks sequentially on 2 nodes (16 GPUs):

| # | Benchmark | Test | Ranks | What it measures |
|---|-----------|------|-------|------------------|
| 1 | NCCL | All-Reduce | 16 | GPU collective performance over NVLink + EFA, 8 B to 8 GB |
| 2 | NCCL | All-to-All | 16 | All-to-all bandwidth across nodes |
| 3 | NVSHMEM | Device Put BW | 2 | Point-to-point RDMA bandwidth via libfabric/EFA (opt-in) |
| 4 | NVSHMEM | Device All-to-All | 16 | NVSHMEM collective over EFA (opt-in) |
| 5 | OSU MPI | Latency | 2 | Inter-node MPI latency |
| 6 | OSU MPI | Bandwidth | 2 | Inter-node MPI bandwidth |
| 7 | OSU MPI | All-Reduce | 16 | MPI collective performance |

## Usage

Slurm writes the job log to `/fsx/HPL-Run/gpu`, so create it first:

```bash
mkdir -p /fsx/HPL-Run/gpu
sbatch microbench.sbatch
```

Common overrides:

```bash
# Partition and node count
sbatch -p p5en -N 4 microbench.sbatch

# Import the image once and reuse it, instead of pulling it from nvcr.io in every step
enroot import -o /fsx/containers/hpc-benchmarks-26.02.01.sqsh 'docker://nvcr.io#nvidia/hpc-benchmarks:26.02.01'
IMAGE=/fsx/containers/hpc-benchmarks-26.02.01.sqsh sbatch microbench.sbatch

# Also run the NVSHMEM tests
RUN_NVSHMEM=1 sbatch microbench.sbatch
```

## Key environment variables

The script sets the following for EFA:

| Variable | Value | Purpose |
|----------|-------|---------|
| `FI_PROVIDER` | `efa` | Use EFA libfabric provider |
| `FI_EFA_USE_DEVICE_RDMA` | `1` | Enable GPUDirect RDMA |
| `OMPI_MCA_coll_ucc_enable` | `0` | Disable UCC (known issue with HPC-X 2.25) |
| `NVSHMEM_REMOTE_TRANSPORT` | `libfabric` | NVSHMEM over libfabric, not ibrc (NVSHMEM tests only) |
| `NVSHMEM_LIBFABRIC_PROVIDER` | `efa` | Select the EFA libfabric provider (NVSHMEM tests only) |
| `NVSHMEM_DISABLE_CUDA_VMM` | `1` | Required by the NVSHMEM libfabric transport (NVSHMEM tests only) |
| `FI_EFA_ENABLE_SHM_TRANSFER` | `0` | Required by NVSHMEM with the EFA provider (NVSHMEM tests only) |

NCCL needs no extra settings: the container ships the AWS OFI NCCL plugin and NCCL loads it automatically. To confirm that NCCL uses EFA rather than TCP sockets, submit with `NCCL_DEBUG=INFO sbatch microbench.sbatch` and look for `NET/OFI Selected provider is efa` in the output.

## Expected results (p5en.48xlarge, 2 nodes)

Measured on 2026-09-24 with `hpc-benchmarks` 26.02.01, in two runs on different node pairs (host EFA installer 1.50.0, NVIDIA driver 595.71.05):

| Test | Message size | Result |
|------|--------------|--------|
| NCCL All-Reduce, bus bandwidth | 128 MB | 317-329 GB/s |
| NCCL All-Reduce, bus bandwidth | 1 GB | 434-442 GB/s |
| NCCL All-Reduce, bus bandwidth | 4 GB | 458-464 GB/s |
| NCCL All-to-All, bus bandwidth | 128 MB | 74 GB/s |
| OSU MPI Latency | 8 B | 12.9-13.3 μs |
| OSU MPI Bandwidth | 4 MB | 39.6-46.7 GB/s |
| OSU MPI All-Reduce, 16 ranks | 1 MB | 604-627 μs |

Compare the large-message rows. The `# Avg bus bandwidth` line that nccl-tests prints is the mean over all message sizes, so small messages dominate it (about 121 GB/s for this script's all-reduce sweep).

## Known issues

NVSHMEM over EFA does not work with `hpc-benchmarks` 26.02 or 26.02.01, which both bundle NVSHMEM 3.5.19. This is why the NVSHMEM tests are opt-in:

- As shipped, the NVSHMEM tests abort with `NVSHMEM device library version does not match with NVSHMEM host library version`. The container's `run_benchmark.sh` puts `/usr/local/cuda/lib64` first on `LD_LIBRARY_PATH`, which resolves to the image's system NVSHMEM 3.4.5 instead of the 3.5.19 in `/workspace/lib/nvshmem`.
- With the library path corrected, NVSHMEM segfaults inside libfabric (`fi_getinfo`) when it brings up its EFA transport. NVSHMEM 3.6.5 fixed libfabric compatibility issues between build and runtime versions ([release notes](https://docs.nvidia.com/nvshmem/release-notes-install-guide/prior-releases/release-3605.html)).

Re-run with `RUN_NVSHMEM=1` once an `hpc-benchmarks` image ships NVSHMEM 3.6.5 or later. The same limitation affects multi-node HPL; see [Utils/HPL](../HPL/README.md) for the multi-node configuration that works.

## Container

Uses `nvcr.io/nvidia/hpc-benchmarks:26.02.01`, which includes:

- NCCL 2.29.2 with the AWS OFI NCCL plugin 1.17.0
- libfabric 2.1.0 (EFA installer 1.43.1) with EFA-direct support
- HPC-X 2.25.1-RC2 (Open MPI with UCX 1.20, which uses the EFA SRD transport)
- NVSHMEM 3.5.19 with libfabric transport
- OSU MPI Benchmarks 7.5

26.02.01 differs from 26.02 only in the HPL binary (`xhpl`). The libraries above are identical, so the microbenchmarks behave the same with either tag.

See [NVIDIA HPC Benchmarks documentation](https://docs.nvidia.com/nvidia-hpc-benchmarks/Microbenchmarks.html) for full details.
