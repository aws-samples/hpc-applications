# STREAM Benchmark

This directory contains scripts for building and running the [STREAM benchmark](https://www.cs.virginia.edu/stream/) on AWS HPC instances. STREAM is a synthetic benchmark that measures sustainable memory bandwidth and the corresponding computation rate for simple vector kernels.

## Overview

STREAM is widely used to measure memory bandwidth performance on HPC systems. It performs four simple vector operations:

- **Copy**: `c[i] = a[i]`
- **Scale**: `b[i] = scalar * c[i]`
- **Add**: `c[i] = a[i] + b[i]`
- **Triad**: `a[i] = b[i] + scalar * c[i]`

The benchmark is particularly useful for:
- Measuring peak memory bandwidth
- Comparing memory performance across different instance types
- Validating system configuration and optimization
- Understanding memory bandwidth limitations for HPC applications

## Files

- `stream-build-aocc.sh` - Build script that downloads and compiles STREAM with AOCC 5.1.0 compiler
- `stream.sbatch` - SLURM batch script for running STREAM on HPC instances

## Build Process

The build script performs the following steps:

1. Downloads AMD Optimizing C/C++ Compiler (AOCC) 5.1.0
2. Installs AOCC compiler locally
3. Downloads the latest STREAM source code from GitHub
4. Compiles STREAM with aggressive optimization flags targeting AMD EPYC 5th Gen (znver5)

### Compilation Flags

The build uses the following optimization flags for maximum performance:

```bash
clang stream.c \
  -fopenmp \                          # Enable OpenMP parallelization
  -mcmodel=large \                    # Support large memory arrays
  -DSTREAM_TYPE=double \              # Use double precision
  -DSTREAM_ARRAY_SIZE=560000000 \     # ~4.2 GB per array (12.6 GB total)
  -DNTIMES=100 \                      # Run 100 iterations
  -ffp-contract=fast \                # Fast floating-point contractions
  -fnt-store \                        # Non-temporal stores
  -O3 -Ofast -ffast-math \           # Aggressive optimizations
  -ffinite-loops \                    # Assume finite loops
  -march=znver5 \                     # Target AMD EPYC 5th Gen (Turin)
  -zopt \                             # AMD-specific optimizations
  -fremap-arrays \                    # Array remapping optimization
  -mllvm -enable-strided-vectorization \  # Strided vectorization
  -fvector-transform \                # Vector transformations
  -o stream
```


## Usage

### Building STREAM

```bash
cd apps/Stream
bash stream-build-aocc.sh
```

This will:
- Download and install AOCC compiler
- Create `setenv_AOCC.sh` for environment setup
- Compile the STREAM binary

### Running STREAM

```bash
sbatch stream.sbatch
```

The script is pre-configured for different instance types. Edit the OpenMP settings in `stream.sbatch` to match your target instance.

## Configuration

### Instance-Specific Settings

The sbatch script includes configurations for different AWS HPC instances:

#### Hpc6a (AMD EPYC 3rd Gen, 96 cores)
```bash
export OMP_PLACES=0:12:8      # 12 places, stride by 8 cores
export OMP_NUM_THREADS=12     # 1 thread per L3 cache (12 CCDs)
```

#### Hpc7a/Hpc8a (AMD EPYC 4th/5th Gen, 192 cores)
```bash
export OMP_PLACES=0:24:8      # 24 places, stride by 8 cores
export OMP_NUM_THREADS=24     # 1 thread per L3 cache (24 CCDs)
```

#### AMD EPYC 9654 (Generic dual-socket, 192 cores)
```bash
export OMP_PLACES=0:96:2      # 96 places, stride by 2 cores
export OMP_NUM_THREADS=96     # 4 threads per L3 cache
```

### OpenMP Environment Variables

```bash
export OMP_SCHEDULE=static    # Static loop scheduling for consistency
export OMP_PROC_BIND=TRUE     # Bind threads to specific cores
export OMP_DYNAMIC=false      # Disable dynamic thread adjustment
export OMP_THREAD_LIMIT=256   # Maximum thread limit
export OMP_STACKSIZE=256M     # Stack size per thread
```

### System Optimization (Requires Root/Sudo)

The script includes optional system-level optimizations:

```bash
# Clear caches to maximize available RAM
sync && echo 3 | sudo tee /proc/sys/vm/drop_caches

# Rearrange RAM to maximize free block sizes
sync && echo 1 | sudo tee /proc/sys/vm/compact_memory

# Enable transparent hugepages
echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled
echo always | sudo tee /sys/kernel/mm/transparent_hugepage/defrag
```

**Note:** These commands require root/sudo access. Comment them out if you don't have the necessary permissions.

## Understanding Results

STREAM reports bandwidth in MB/s for each operation. Example output:

```
Function    Best Rate MB/s  Avg time     Min time     Max time
Copy:       450000.0        0.019200     0.019100     0.019300
Scale:      440000.0        0.019600     0.019500     0.019700
Add:        480000.0        0.026800     0.026700     0.026900
Triad:      475000.0        0.027100     0.027000     0.027200
```

### Key Metrics

- **Best Rate**: Maximum bandwidth achieved across all iterations
- **Triad**: Most important metric, represents typical HPC memory access patterns
- **Copy**: Simplest operation, often shows highest bandwidth

### Expected Performance

Typical STREAM Triad bandwidth for AWS HPC instances:

| Instance Type | Cores Used | Expected Triad BW | Notes |
|---------------|------------|-------------------|-------|
| Hpc6a.48xlarge | 12 (1/CCD) | ~400 GB/s | AMD EPYC 3rd Gen |
| Hpc7a.96xlarge | 24 (1/CCD) | ~700 GB/s | AMD EPYC 4th Gen |
| Hpc8a.96xlarge | 24 (1/CCD) | ~1000 GB/s | AMD EPYC 5th Gen |

## Performance Tuning Tips

### Thread Placement Strategy

For optimal STREAM performance on AMD EPYC processors:

1. **Use 1 thread per L3 cache (CCD)**: Minimizes cache contention
2. **Stride by 8 cores**: Ensures threads are spread across CCDs
3. **Avoid SMT**: Use physical cores only for memory bandwidth tests

### Why 1 Thread per CCD?

- Each CCD has its own L3 cache and memory controllers
- Multiple threads per CCD compete for the same memory bandwidth
- Spreading threads across CCDs maximizes aggregate bandwidth
- This is why we use 12 threads on Hpc6a (12 CCDs) and 24 threads on Hpc7a/8a (24 CCDs)

### Memory Considerations

- Ensure array size exceeds all cache levels
- Use at least 4× the total L3 cache size
- Enable transparent hugepages for better TLB performance
- Clear caches before running for consistent results

## References

- [STREAM Benchmark Official Site](https://www.cs.virginia.edu/stream/)
- [STREAM on GitHub](https://github.com/jeffhammond/STREAM)
- [AMD AOCC Compiler](https://developer.amd.com/amd-aocc/)
- [OpenMP Specification](https://www.openmp.org/specifications/)

## Notes

- STREAM measures sustainable memory bandwidth, not peak theoretical bandwidth
- Results are sensitive to system configuration and background processes
- Run multiple times and report the best result
- The Triad operation is most representative of real HPC application behavior
- For production benchmarking, ensure exclusive node access and minimal system activity
