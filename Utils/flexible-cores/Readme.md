# Flexible Cores Configuration

This directory contains examples demonstrating how to use flexible core configurations on AWS HPC instances, specifically targeting the [Hpc8a.96xlarge](https://aws.amazon.com/ec2/instance-types/hpc8a/) and [Hpc7a.96xlarge](https://aws.amazon.com/ec2/instance-types/hpc7a/) instance types.

## Overview

Both Hpc8a.96xlarge and Hpc7a.96xlarge instances provide 192 physical cores across 2 sockets (96 cores per socket) with [SMT](https://www.amd.com/en/blogs/2025/simultaneous-multithreading-driving-performance-a.html) disabled. These examples show how to configure MPI applications using both [Intel MPI](https://www.intel.com/content/www/us/en/developer/tools/oneapi/mpi-library.html) and [OpenMPI](https://www.open-mpi.org/) to use different core counts, ensuring all available L3 cache is accessible and balanced among the cores, effectively emulating smaller instance sizes while maintaining the same hardware platform.

## Motivation

For applications that are memory bandwidth bound, running on fewer cores per instance can lead to better performance. The higher performance is achieved thanks to the increase of available memory bandwidth per core (critical for CFD applications like Fluent, StarCCM+, OpenFOAM). As a side effect, available memory per core (critical for FEA applications like Abaqus, Mechanical, Nastran) is also increased.

Although we are sharing these custom configurations and settings, we believe a scalable approach is to leverage the [Amazon EC2 Optimize CPU](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instance-optimize-cpu.html) options so that customers/partners can integrate this easily with their custom orchestration tools or software.

## Files

- `hello-cpu.c` - MPI application that reports which CPU core each rank is running on
- `hello-cpu.intelmpi.simple.sbatch` - Intel MPI with automatic pinning
- `hello-cpu.intelmpi.explicit.sbatch` - Intel MPI with explicit core pinning
- `hello-cpu.openmpi.simple.sbatch` - OpenMPI with automatic pinning
- `hello-cpu.openmpi.explicit.sbatch` - OpenMPI with explicit core pinning

## Use Cases

Flexible core configurations allow you to:

- Maximize memory bandwidth per core for memory-intensive applications
- Test application scaling behavior without changing instance types or rebooting the instance with a different Optimize CPU setting.
- Optimize cost/licenses by using only the cores needed for your workload
- Emulate different instance sizes (Hpc8a.12xlarge, Hpc8a.24xlarge, Hpc8a.48xlarge)
- Experiment with different NUMA and cache locality patterns
- Compare performance across different core counts on the same hardware

## Supported Core Configurations

| Cores | Emulated Instance | Core Distribution | Notes |
|-------|-------------------|-------------------|-------|
| 24    | Hpc8a.12xlarge   | 1 cores per CCD  | Maximum spread across CCDs, 1/8 capacity |
| 48    | Hpc8a.24xlarge   | 2 cores per CCD  | Balanced distribution, 1/4 capacity |
| 72    | Custom           | 3 consecutive cores per CCD | Good cache locality, 3/8 capacity |
| 96    | Hpc8a.48xlarge   | 4 cores per CCD    | 1/2 capacity |
| 120   | Custom           | 5 cores per CCD  | 5/8 capacity  |
| 144   | Custom           | 6 cores per CCD  | 3/4 capacity  |
| 168   | Custom           | 7 cores per CCD  | 7/8 capacity  |
| 192   | Hpc8a.96xlarge   | All physical cores (both sockets) | Full instance capacity  |

## Script Comparison

### Intel MPI Scripts

#### Simple (Automatic Pinning)
`hello-cpu.intelmpi.simple.sbatch` uses Intel MPI's automatic pinning:

```bash
export I_MPI_PIN=1                    # Enable pinning
export I_MPI_PIN_ORDER=spread         # Spread ranks across NUMA domains
# I_MPI_PIN_DOMAIN=cache3            # Optional: pin to L3 cache domains
```

**Best for:** Easy to use and portabl, letting Intel MPI handle core placement automatically.

#### Explicit (Manual Pinning)
`hello-cpu.intelmpi.explicit.sbatch` uses dynamic explicit pinning:

- Automatically calculates cores per node from SLURM variables
- Uses case statement to select appropriate core list
- Provides fine-grained control over core placement
- Displays selected configuration for verification

**Best for:** Performance tuning, specific core placement requirements, reproducible benchmarks.

### OpenMPI Scripts

#### Simple (L3 Cache Mapping)
`hello-cpu.openmpi.simple.sbatch` uses OpenMPI's cache-aware mapping:

```bash
mpirun --map-by L3cache:PE=1 --report-bindings
```

**Best for:** Automatic cache-aware placement, simple configuration.

#### Explicit (Manual Binding)
`hello-cpu.openmpi.explicit.sbatch` uses explicit CPU list binding:

```bash
mpirun --bind-to cpu-list:ordered --cpu-list "${OPEN_MPI_PROCESSOR_LIST}"
```

**Best for:** Precise control over core placement, matching Intel MPI configurations.

## Usage

### Basic Usage

1. Choose the appropriate script for your MPI implementation and pinning strategy
2. Update the `--ntasks` parameter to match your desired core count
3. Update the `--partition` parameter to match your cluster configuration
4. Submit the job:

```bash
# Intel MPI with automatic pinning
sbatch hello-cpu.intelmpi.simple.sbatch

# Intel MPI with explicit pinning
sbatch hello-cpu.intelmpi.explicit.sbatch

# OpenMPI with L3 cache mapping
sbatch hello-cpu.openmpi.simple.sbatch

# OpenMPI with explicit pinning
sbatch hello-cpu.openmpi.explicit.sbatch
```

### Changing Core Count

For explicit pinning scripts, simply update the `--ntasks` parameter. The script will automatically select the appropriate core list:

```bash
#SBATCH --ntasks=48   # Will use 48-core configuration
#SBATCH --ntasks=96   # Will use 96-core configuration
#SBATCH --ntasks=192  # Will use all vCPUs
```

## MPI Configuration Details

### Intel MPI with EFA

```bash
module load intelmpi
export I_MPI_FABRICS=shm:ofi          # Shared memory + OFI
export I_MPI_OFI_PROVIDER=efa         # Use EFA provider
export I_MPI_DEBUG=5                  # Debug output level
```

### OpenMPI with EFA

```bash
module load openmpi
module load libfabric-aws
# export FI_LOG_LEVEL=warn            # Optional: libfabric logging
# export OMPI_MCA_mtl_ofi_verbose=100 # Optional: verbose OFI output
```

## Example Output

The application displays which CPU core each MPI rank is running on, sorted by core number:

```
Rank 0 running on CPU core 0
Rank 1 running on CPU core 8
Rank 2 running on CPU core 16
Rank 3 running on CPU core 24
...
```

This output helps verify that your pinning configuration is working as expected and that ranks are distributed according to your chosen strategy.

## Performance Considerations

### Core Placement Strategies

1. **Maximum Spread (24 cores, stride 8)**: Best for memory/bandwidth-intensive applications, (expected higher cost per job)
2. **Balanced (96 cores)**: Good to increase memory/bandwidth maximize performance (maintaining an acceptable cost per job)
4. **Full Utilization (192 cores)**: Maximum throughput for highly parallel workloads (expected lower cost per job)

### NUMA Topology

Both Hpc8a.96xlarge and Hpc7a.96xlarge have:
- 2 sockets with 96 physical cores each (192 total)
- 12 CCDs (Core Complex Dies) per socket (24 CCDs total)
- 8 cores per CCD
- Each CCD has its own L3 cache
- SMT is disabled by default
- Cores 0-95 typically map to socket 0, cores 96-191 to socket 1

## Notes

- Proper core pinning can significantly impact application performance, particularly for memory bandwidth bound applications
- Test different configurations to find optimal performance for your workload

## Addendum: Tuning for CMRX8i instances (Intel Granite Rapids, SNC3)

### Why CMRX8i Require Explicit Tuning

These instances (`C8i, C8id, C8in, C8ine, C8ib, M8i, M8id, M8in, M8idn, M8ine, M8ib, M8idb, R8i, R8id, R8in, R8idn, R8ib, R8idb, X8i)` use Intel Xeon 6900P processors (Granite Rapids) with Sub-NUMA Clustering (SNC3) enabled by default. Each socket contains 3 compute dies, and each die is exposed as a separate NUMA domain. This results in (taking the R8i case as an example):

- **R8i.48xlarge**: 1 socket, 3 NUMA nodes, 32 physical cores per NUMA node (96 total), SMT enabled (192 vCPUs)
- **R8i.96xlarge**: 2 sockets, 6 NUMA nodes, 32 physical cores per NUMA node (192 total), SMT enabled (384 vCPUs)

Please note that `32xlarge` sizes have only two NUMA domains and `16xlarge` and smaller are uniform (one NUMA).

The topology can be inspected with `lscpu --extended` (shows CPU to NUMA node and cache mapping) and `numactl --hardware` (shows NUMA nodes, memory sizes, and distance matrix).

Unlike Hpc8a/Hpc7a (which have a nearly flat intra-socket topology with less than 3% bandwidth penalty) and R7i (which has 0% intra-socket penalty), the 48.xlarge and 96.xlarge sizes of these instances have significant bandwidth penalties for accessing memory on a different die within the same socket:

| Access pattern | NUMA distance | Measured bandwidth loss |
| --- | --- | --- |
| Local (same die) | 10 | baseline |
| Adjacent die, same socket | 15 | 11 to 19% |
| Far die, same socket | 17 | 22 to 24% |
| Cross-socket (R8i.96xl only) | 21 to 28 | 36 to 45% |

NUMA distances are relative, dimensionless values defined by the ACPI SLIT table. Local access is always 10 (baseline), and higher values represent proportionally higher memory access latency. They are not expressed in nanoseconds or any physical unit.

The bandwidth loss measurements were obtained with the STREAM benchmark:

```bash
wget https://www.cs.virginia.edu/stream/FTP/Code/stream.c
gcc -O3 -march=native -fopenmp -DSTREAM_ARRAY_SIZE=80000000 -DNTIMES=20 -o stream_c.exe stream.c
export OMP_NUM_THREADS=8
numactl --cpunodebind=0 --membind=<N> ./stream_c.exe | grep Triad

```

Replace `<N>` with each NUMA node index (0, 1, 2, ... up to the number of nodes minus 1) to measure bandwidth at each distance.

Applications that ran well on R7i or Hpc7a with loose pinning may underperform on CMRX8i because threads or memory allocations silently cross die boundaries. The SNC3 topology is documented in the [Intel Xeon 6 with P-Cores Configuration and Tuning Guide for HPC Applications](https://www.intel.com/content/www/us/en/content-details/858491/intel-xeon-6-with-p-cores-configuration-and-tuning-guide-for-hpc-applications.html) (Document 858491, Rev 1.1, December 2025, Section 2.2) and confirmed by independent benchmarks ([Phoronix, Oct 2024](https://www.phoronix.com/review/xeon-6980p-snc3-hex), [Phoronix, Oct 2025](https://www.phoronix.com/review/intel-xeon-snc3-hex-benchmarks)). SNC3 cannot be disabled on EC2 instances (neither virtualized nor bare-metal).

### NUMA Distance Matrix

Obtained with:

```bash
numactl --hardware

```

**R8i.48xlarge example (1 socket, 3 NUMA nodes):**

```
node   0   1   2 
  0:  10  15  17 
  1:  15  10  15 
  2:  17  15  10 

```

**R8i.96xlarge example (2 sockets, 6 NUMA nodes):**

```
node   0   1   2   3   4   5 
  0:  10  15  17  21  28  26 
  1:  15  10  15  23  26  23 
  2:  17  15  10  26  23  21 
  3:  21  28  26  10  15  17 
  4:  23  26  23  15  10  15 
  5:  26  23  21  17  15  10 

```

### General Tuning Principles

**1. One MPI rank per NUMA domain**

The fundamental rule is to keep each rank and its memory within a single NUMA domain. Each NUMA domain contains 32 physical cores (64 vCPUs with SMT). The recommended decomposition per instance:

| Instance | Total physical cores | NUMA domains | Ranks per instance | Physical cores per rank | vCPUs per rank (with SMT) |
| --- | --- | --- | --- | --- | --- |
| R8i.48xl | 96 | 3 | 3 | 32 | 64 |
| R8i.96xl | 192 | 6 | 6 | 32 | 64 |

If the application uses fewer threads per rank, leave the remaining cores idle within that NUMA domain rather than packing additional ranks that would share the same memory controller. Verify rank placement by checking the NUMA domain boundaries in the output of `lscpu --extended` (NODE column) or `numactl --hardware` (CPU list per domain).

**2. Always bind memory locally**

```bash
#SBATCH --mem-bind=local

```

Without this, the Linux kernel may allocate memory pages on a remote die during initialization, causing persistent bandwidth loss for the entire run.

**3. Use compact pinning, not scatter**

```bash
export OMP_PROC_BIND=close
export OMP_PLACES=cores
export I_MPI_PIN_DOMAIN=omp:compact
export I_MPI_PIN_ORDER=compact

```

`scatter` and `spread` strategies that worked on R7i's flat topology or Hpc8a's nearly-flat intra-socket will spread threads across multiple dies on CMRX8i, incurring 11 to 24% bandwidth loss per misplaced thread.

**4. Handle SMT appropriately**

For compute-bound workloads (recommended):

```bash
#SBATCH --threads-per-core=1
#SBATCH --hint=nomultithread

```

When using `--hint=nomultithread`, always ensure `OMP_NUM_THREADS` matches `--cpus-per-task`. Setting `OMP_NUM_THREADS` higher than the allocated CPUs causes oversubscription and performance degradation from context switching.

If the application benefits from SMT (I/O-heavy or latency-hiding workloads), omit these flags and use `OMP_PLACES=cores` with `OMP_PROC_BIND=close` to place threads on distinct physical cores while leaving SMT siblings available.

**5. Generic Slurm template**

```bash
#!/bin/bash
#SBATCH --nodes=<N>
#SBATCH --ntasks-per-node=<NUMA_NODES>    # 3 for r8i.48xl, 6 for r8i.96xl
#SBATCH --cpus-per-task=<THREADS>          # up to 32 (physical) or 64 (with SMT)
#SBATCH --threads-per-core=1              # omit if SMT is desired
#SBATCH --hint=nomultithread              # omit if SMT is desired
#SBATCH --mem-bind=local

export OMP_NUM_THREADS=<THREADS>           # must match cpus-per-task
export OMP_PROC_BIND=close
export OMP_PLACES=cores

export I_MPI_HYDRA_BOOTSTRAP=slurm
export I_MPI_PIN_DOMAIN=omp:compact
export I_MPI_PIN_ORDER=compact

srun ./application

```

Replace `<NUMA_NODES>` with 3 (for .48xlarge sizes) or 6 (for .96xlarge sizes) and `<THREADS>` with the desired thread count per rank (up to 32 without SMT, 64 with SMT).

**6. Validate pinning before production runs**

```bash
export I_MPI_DEBUG=5
srun ./application

```

Verify in the output that each rank's CPU set falls entirely within one NUMA node boundary:

- CMRX8i.48xl: 0-31, 32-63, 64-95 (physical cores); add 96-127, 128-159, 160-191 if SMT is active
- CMRX8i.96xl: 0-31, 32-63, 64-95, 96-127, 128-159, 160-191 (physical cores); add 192-383 if SMT is active

Any rank spanning two NUMA boundaries will incur 11 to 45% bandwidth loss depending on the distance between the dies involved.

### Comparison with R7i

Settings that work on R7i without tuning will typically fail on CMRX8i:

| Setting | R7i (flat intra-socket) | CMRX8i (SNC3, requires tuning) |
| --- | --- | --- |
| OMP_PROC_BIND | false (safe, no intra-socket penalty) | close (required to prevent tile migration) |
| OMP_PLACES | undefined (safe) | cores (required) |
| I_MPI_PIN_DOMAIN | numa (48 cores, all local) | omp:compact (limits to one 32-core tile) |
| I_MPI_PIN_ORDER | scatter (safe) | compact (required) |
| --mem-bind | not critical (flat NUMA) | local (critical) |
| --hint | not critical | nomultithread (recommended for HPC) |

### Reference

- [Intel Xeon 6 with P-Cores Configuration and Tuning Guide for HPC Applications, Document 858491, Rev 1.1, Dec 2025](https://www.intel.com/content/www/us/en/content-details/858491/intel-xeon-6-with-p-cores-configuration-and-tuning-guide-for-hpc-applications.html)
- [Intel Xeon 6980P SNC3 vs HEX Clustering Mode Performance Review, Phoronix, Oct 2024](https://www.phoronix.com/review/xeon-6980p-snc3-hex)
- [Revisiting SNC3 vs HEX Mode Performance, Phoronix, Oct 2025](https://www.phoronix.com/review/intel-xeon-snc3-hex-benchmarks)
- [Intel Xeon 6 Granite Rapids product page](https://www.intel.com/content/www/us/en/ark/products/codename/128428/products-formerly-granite-rapids.html)