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
