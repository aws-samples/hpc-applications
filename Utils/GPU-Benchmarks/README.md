# GPU Microbenchmarks

System readiness microbenchmarks for GPU clusters using the [NVIDIA HPC Benchmarks](https://catalog.ngc.nvidia.com/orgs/nvidia/containers/hpc-benchmarks) container (26.02+). These tests validate NCCL, NVSHMEM, and MPI performance over EFA before running large-scale GPU workloads like HPL.

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
| 1 | NCCL | All-Reduce | 16 | GPU collective performance over NVLink + EFA |
| 2 | NCCL | All-to-All | 16 | All-to-all bandwidth across nodes |
| 3 | NVSHMEM | Device Put BW | 2 | Point-to-point RDMA bandwidth via libfabric/EFA |
| 4 | NVSHMEM | Device All-to-All | 16 | NVSHMEM collective over EFA |
| 5 | OSU MPI | Latency | 2 | Inter-node MPI latency |
| 6 | OSU MPI | Bandwidth | 2 | Inter-node MPI bandwidth |
| 7 | OSU MPI | All-Reduce | 16 | MPI collective performance |

## Usage

```bash
sbatch microbench.sbatch
```

To change the number of nodes:
```bash
sbatch -N 4 microbench.sbatch
```

## Key environment variables

The script sets the following for EFA:

| Variable | Value | Purpose |
|----------|-------|---------|
| `FI_PROVIDER` | `efa` | Use EFA libfabric provider |
| `FI_EFA_USE_DEVICE_RDMA` | `1` | Enable GPUDirect RDMA |
| `NVSHMEM_REMOTE_TRANSPORT` | `libfabric` | NVSHMEM over libfabric (not ibrc) |
| `NVSHMEM_DISABLE_CUDA_VMM` | `1` | Required for NVSHMEM on EFA |
| `OMPI_MCA_coll_ucc_enable` | `0` | Disable UCC (known issue with HPC-X 2.25) |

## Expected results (p5.48xlarge, 2 nodes)

- **NCCL All-Reduce**: ~380-400 GB/s bus bandwidth
- **OSU MPI Latency**: ~20-25 μs inter-node
- **OSU MPI Bandwidth**: ~24 GB/s per rank

## Container

Uses `nvcr.io/nvidia/hpc-benchmarks:26.02` which includes:
- NCCL 2.29.2
- NVSHMEM 3.5.19 with libfabric transport
- libfabric 2.1.0 with EFA-direct support
- OSU MPI Benchmarks

See [NVIDIA HPC Benchmarks documentation](https://docs.nvidia.com/nvidia-hpc-benchmarks/Microbenchmarks.html) for full details.
