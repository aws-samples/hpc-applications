# Flexible Cores Configuration

This directory contains examples demonstrating how to use flexible core configurations on AWS HPC instances, specifically targeting the [Hpc8a.96xlarge](https://aws.amazon.com/ec2/instance-types/hpc8a/) and [Hpc7a.96xlarge](https://aws.amazon.com/ec2/instance-types/hpc7a/) instance types.

## Overview

Both Hpc8a.96xlarge and Hpc7a.96xlarge instances provide 192 physical cores across 2 sockets (96 cores per socket) with [SMT](https://www.amd.com/en/blogs/2025/simultaneous-multithreading-driving-performance-a.html) disabled. These examples show how to configure MPI applications using both [Intel MPI](https://www.intel.com/content/www/us/en/developer/tools/oneapi/mpi-library.html) and [OpenMPI](https://www.open-mpi.org/) to use different core counts, ensuring all available L3 cache is accessible and balanced among the cores, effectively emulating smaller instance sizes while maintaining the same hardware platform.

## Motivation

For applications that are memory bandwidth bound, running on fewer cores per instance can lead to better performance. The higher performance is achieved thanks to the increase of available memory bandwidth per core (critical for CFD applications like Fluent, StarCCM+, OpenFOAM). As a side effect, available memory per core (critical for FEA applications like Abaqus, Mechanical, Nastran) is also increased.

Although we are sharing these custom configurations and settings, we believe a scalable approach is to leverage the [Amazon EC2 Optimize CPU](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instance-optimize-cpu.html) options so that customers/partners can integrate this easily with their custom orchestration tools or software.

What fewer cores per instance gains depends on the application and on how it is licensed: [Core Placement Strategies](#core-placement-strategies) gives what STAR-CCM+ and LS-DYNA measured.

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
- Emulate smaller instance sizes (Hpc7a.12xlarge, Hpc7a.24xlarge, Hpc7a.48xlarge) and their core counts
- Experiment with different NUMA and cache locality patterns
- Compare performance across different core counts on the same hardware

## Supported Core Configurations

| Cores | Emulated Instance | Core Distribution | Notes |
|-------|-------------------|-------------------|-------|
| 24    | Hpc7a.12xlarge (on Hpc7a) | 1 core per CCD   | Maximum spread across CCDs, 1/8 capacity |
| 48    | Hpc7a.24xlarge (on Hpc7a) | 2 cores per CCD  | Balanced distribution, 1/4 capacity |
| 72    | Custom           | 3 consecutive cores per CCD | Good cache locality, 3/8 capacity |
| 96    | Hpc7a.48xlarge (on Hpc7a) | 4 cores per CCD    | 1/2 capacity |
| 120   | Custom           | 5 cores per CCD  | 5/8 capacity  |
| 144   | Custom           | 6 cores per CCD  | 3/4 capacity  |
| 168   | Custom           | 7 cores per CCD  | 7/8 capacity  |
| 192   | Hpc8a.96xlarge, Hpc7a.96xlarge | All physical cores (both sockets) | Full instance capacity  |

Hpc7a also comes in smaller sizes: Hpc7a.12xlarge, Hpc7a.24xlarge and Hpc7a.48xlarge have 24, 48 and 96 cores.
Hpc8a comes in one size, and EC2 lists exactly these eight counts as the core counts that the
[Optimize CPU](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instance-optimize-cpu.html) options accept for
Hpc8a.96xlarge (it lists none for Hpc7a.96xlarge). Query a Region that offers Hpc8a:

```bash
aws ec2 describe-instance-types --region eu-north-1 --instance-types hpc8a.96xlarge \
    --query 'InstanceTypes[0].VCpuInfo.ValidCores'
```

### Counts not in the table

Any other count per node loads the 24 CCDs unevenly, and spreading the ranks with
an even stride (`192 / count`) does not fix it:

| Cores per node | Stride | Ranks per CCD |
|---|--:|---|
| 16 | 12 | 1 on 16 CCDs, none on the other 8 |
| 32 | 6 | 2 on 8 CCDs, 1 on the other 16 |
| 64 | 3 | 3 on 16 CCDs, 2 on the other 8 |

Every list in the explicit scripts gives each CCD the same number of ranks, 1 to 8.
Counts like these come up when an application's own increments are powers of two:
the Ansys Mechanical benchmark package uses 16, 32, 64 and 128 (see
[AnsysMechanical](https://github.com/aws-samples/hpc-applications/tree/main/apps/AnsysMechanical)).

The explicit scripts print a warning for a count they have no list for, and carry
on. Where only balanced runs are acceptable, benchmarking for example, refuse the
count in the job itself, before the solver starts, so that a submission made by
hand is checked as well as one made by your tooling:

```bash
# Refuse a cores-per-node count the lists above do not cover, on Hpc8a.96xlarge
# and Hpc7a.96xlarge. cores_x_node is computed as in the explicit scripts.
case "${cores_x_node}" in
    24|48|72|96|120|144|168|192) ;;   # a count the lists cover: nothing to check
    *)
        TOKEN=$(curl -fs --connect-timeout 2 --max-time 5 -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60") || TOKEN=""
        instance_type=$(curl -fs --connect-timeout 2 --max-time 5 -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type) || instance_type=""
        check_node=""
        case "${instance_type}" in
            hpc8a.96xlarge|hpc7a.96xlarge) check_node="${instance_type}" ;;
        esac
        if ! ( LC_ALL=C; [[ "${instance_type}" =~ ^[a-z][a-z0-9-]*\.[a-z0-9-]+$ ]] ); then
            # No instance type from IMDS: no answer within a few seconds, an error, or
            # not a type name. A node with 192 AMD cores could be either type.
            amd_cores=$(LC_ALL=C lscpu 2>/dev/null | awk -F': *' '/^ *Vendor ID:/ {v = $2}
                /^ *Socket\(s\):/ {s = $2} /^ *Core\(s\) per socket:/ {c = $2}
                END {print (v == "AuthenticAMD" ? s * c : 0)}') || amd_cores=0
            if [ "${amd_cores}" = 192 ]; then
                check_node="this 192-core AMD node"
            else
                echo "NOTE: no instance type from IMDS, and not a 192-core AMD node; the cores-per-node check is skipped" >&2
            fi
        fi
        if [ -n "${check_node}" ]; then
            echo "ERROR: ${cores_x_node} cores per node loads the CCDs of ${check_node} unevenly; use 24, 48, 72, 96, 120, 144, 168 or 192" >&2
            exit 1
        fi ;;
esac
```

The snippet checks the count on Hpc8a.96xlarge and Hpc7a.96xlarge only, and its
message names the counts to use. A count the lists cover needs no check, so the
snippet asks IMDS for the instance type only for another count. When IMDS gives no
instance type (no answer within a few seconds, an error, or an answer that is not
an instance type name, tested in the C locale), a node with 192 AMD cores
(`lscpu`: vendor AuthenticAMD, and sockets × cores per socket is 192) could be
either of them, so the count is checked in the same way. Without an instance type,
any other node runs it, with a one-line NOTE on stderr that the check was skipped:
a run is never refused only because IMDS did not answer. The snippet is written for
bash, like the explicit scripts.

If your own tooling submits the jobs, refuse the count there as well, so that no
node starts for it.

### Other AMD instance types

The lists here are for the 192-core Hpc8a/Hpc7a.96xlarge, but the same principle
applies to other AMD instances, with their own L3 layout. On an hpc6a.48xlarge
(AMD EPYC 7R13, 2 sockets of 48 cores, SMT off), `lscpu` shows 4 NUMA nodes of 24
cores and 12 L3 groups of 8 consecutive cores (0-7, 8-15, ..., 88-95), 3 per NUMA
node and 6 per socket. Balanced counts per node there are multiples of 12 (12, 24,
..., 96). Check the layout of the instance you use before you choose counts:

```bash
lscpu -e=CPU,CORE,SOCKET,NODE,CACHE   # the last field of CACHE is the L3 id
```

Every list in the explicit scripts follows one rule, so you can build the list for
another layout. With g cores per L3 group (8 on these instances, one group per CCD)
and k ranks per group (here the count per node divided by 24), a list takes every
(g/k)-th core when k divides g (every 8th, 4th, 2nd or every core: the lists for 24,
48, 96 and 192), and each group's first k cores otherwise (72, 120, 144 and 168). On
an hpc6a.48xlarge the same rule over its 12 L3 groups gives, for example,
`0,8,16,...,88` for 12 cores per node. The explicit scripts hold the
Hpc8a/Hpc7a.96xlarge lists only: replace them before you run the scripts on another
instance type, and check the placement with `hello-cpu`.

## Script Comparison

### Intel MPI Scripts

#### Simple (Automatic Pinning)
`hello-cpu.intelmpi.simple.sbatch` uses Intel MPI's automatic pinning:

```bash
export I_MPI_PIN=1                    # Enable pinning
export I_MPI_PIN_ORDER=spread         # Spread ranks across NUMA domains
# I_MPI_PIN_DOMAIN=cache3            # Optional: pin to L3 cache domains
```

**Best for:** Easy to use and portable, letting Intel MPI handle core placement automatically. Check what it gives at your count (the script sets `I_MPI_DEBUG=5`): Intel MPI's own placement can leave the CCDs uneven (see [Pinning at the supported counts](#pinning-at-the-supported-counts)).

#### Explicit (Manual Pinning)
`hello-cpu.intelmpi.explicit.sbatch` uses dynamic explicit pinning:

- Automatically calculates cores per node from SLURM variables
- Uses case statement to select appropriate core list
- Provides fine-grained control over core placement
- Displays selected configuration for verification

**Best for:** Performance tuning, specific core placement requirements, reproducible benchmarks, and counts where Intel MPI's default placement is uneven, such as 144 per node.

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
#SBATCH --ntasks=192  # Will use all 192 physical cores
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

AWS measured three ways of using these counts in October 2026, on Hpc8a.96xlarge and
Hpc7a.96xlarge: with STAR-CCM+ 2606 (its bundled Open MPI 5.0.9 and its default
`-cpubind bandwidth`), and with LS-DYNA MPP (Intel MPI 2021.18, with the explicit scripts'
lists on under-populated nodes; car2car-ver10 on R13.1, the Camry v5a, the Yaris v2j and
3cars on R17.0.1). The
[STAR-CCM+](https://github.com/aws-samples/hpc-applications/blob/main/apps/StarCCM/Readme.md)
and [LS-DYNA](https://github.com/aws-samples/hpc-applications/blob/main/apps/LS-Dyna/Readme.md)
pages give the values for each model. Speed is a reference layout's time over the
layout's time (higher is faster), the EC2 cost per run is nodes × time on the same
instance type, and every value is a ratio of medians of 3 runs unless stated (of 4 for
the STAR-CCM+ points whose first 3 runs spread more than 5%).

**Full nodes (192 ranks per node).** On the same nodes, full nodes ran STAR-CCM+
fastest: 1.10–1.18× as fast as 96 ranks per node on 4 nodes, and 1.64–1.91× as fast as
48 on 8 nodes (AeroSUV 106M coupled and LeMans 100M segregated). They ran LS-DYNA
1.05–1.29× as fast as 96 ranks per node on 2 nodes (car2car-ver10, the Camry and the
Yaris). Two results go the other way, both car2car-ver10's: on one Hpc8a.96xlarge it
ran 1.02× as fast at 144 ranks as at 192 (below), and on four nodes, where it has
stopped scaling, 1.04–1.13× as fast at 96 or 48 ranks per node as at 192 (each
four-node full point is a single run). For a given number of ranks, full nodes cost the
least EC2 per run. So for these two applications, when the licence cost does not depend
on the core count (STAR-CCM+'s Power licences cover a run on any number of cores), fill
the nodes, and add nodes while the model scales.

**The same ranks on more nodes (144, 96 or 48 ranks per node).** Spreading a fixed
number of ranks over more nodes made most runs faster, and every layout cost more EC2
per run. Relative to the fully populated layout of the same total on the same instance
type = 1.00× (1 × 192 for 192 ranks, 2 × 192 for 384, 3 × 192 for 576):

| Application: models | Ranks | Nodes × ranks per node | Speed | EC2 cost per run |
|---|--:|---|--:|--:|
| STAR-CCM+: AeroSUV 106M coupled, LeMans 100M segregated | 384 | 4 × 96 | 1.69–1.85× | 1.08–1.18× |
| | | 8 × 48 | 2.15–2.42× | 1.65–1.86× |
| STAR-CCM+: AeroSUV 106M coupled (Hpc8a.96xlarge) | 576 | 4 × 144 | 1.27× | 1.05× |
| | | 6 × 96 | 1.72× | 1.16× |
| LS-DYNA: car2car-ver10, Camry v5a, Yaris v2j, 3cars | 192 | 2 × 96 | 1.09–1.49× | 1.35–1.83× |
| | | 4 × 48 | 0.88–1.54× | 2.60–4.56× |
| LS-DYNA: car2car-ver10, Camry v5a | 384 | 4 × 96 | 0.93–1.29× | 1.55–2.16× |
| | | 8 × 48 | 1.07–1.33× | 3.00–3.73× |

Each range spans the models and both instance types. With the same ranks, a licence
priced per core costs in proportion to the run time (LS-DYNA checks out its licence
features per rank), so a speed of 1.69× is 0.59× the licence cost per run. STAR-CCM+
gained more from the spread than LS-DYNA, whose gain depends on the model: on 4 × 48,
the Camry ran 1.45–1.54× as fast as on one full node, and 3cars 0.88–1.05×. The runs of
each layout agree within 5%, except car2car-ver10's on 4 × 96, which spread 7–12% (the
LS-DYNA page says why).

**Fewer ranks on the same nodes (144 or 96 per node).** With a licence per core, the
licence cost per run follows ranks × time, which falls with the rank count even where
the run slows down. On one node of AeroSUV 106M coupled (STAR-CCM+), relative to 192
ranks = 1.00×, 144 ranks ran at 0.97× and 96 ranks at 0.91–0.98×, for 0.78× and
0.51–0.55× the ranks × time (the 144-rank points' 4 runs spread 8–10%). LS-DYNA's
car2car-ver10 on one Hpc8a.96xlarge ran 1.02× as fast with 144 ranks as with 192, on
25% fewer ranks.

Measure your own model at two or three of these layouts before you choose one: the gain
varies with the application and the model.

### Pinning at the supported counts

In the runs measured below, the same number of ranks on every CCD mattered, and which
of a CCD's cores they used mattered little.

- **An MPI's own placement can leave the CCDs uneven.** With Intel MPI 2021.18's own
  placement (pinning on, no processor list, `I_MPI_PIN_DOMAIN` and `I_MPI_PIN_ORDER` at
  their defaults), 144 ranks per node got one or two cores each: 48 ranks two cores and
  96 ranks one, so the CCDs held 4, 6 and 8 ranks in turn. LS-DYNA (car2car-ver10, one
  Hpc8a.96xlarge, 3 runs each) took 4.3% longer that way than on the list for 144, which
  puts 6 ranks on every CCD. At 96 ranks per node the same settings gave every rank two
  neighbouring cores, 4 ranks on every CCD, and the two agreed within 0.2% (two nodes).
- **Which cores of a CCD the ranks use mattered little.** On one node, STAR-CCM+'s
  default binding, `-cpubind bandwidth`, put 6 ranks on every CCD at 144 ranks per node,
  on the cores of the list for 144, and 4 at 96, on each CCD's first four cores, where
  the list for 96 takes every other core. Pinned to the list for 96 instead
  (`-cpubind off`, with a rankfile passed through `-mpiflags`), AeroSUV 106M coupled ran
  as fast as the default within the runs' spread (one Hpc8a.96xlarge, 3 runs each:
  medians within 0.1%, runs spread up to 6%).
- **Check the placement** once for each count and MPI you use: with `hello-cpu`, Intel
  MPI's pinning table (`I_MPI_DEBUG=5`, which the Intel MPI scripts here set, prints each
  rank's cores under "CPU pinning"), Open MPI's `--report-bindings`, or STAR-CCM+'s
  `-cpubind bandwidth,v`. The `lscpu` command in
  [Other AMD instance types](#other-amd-instance-types) shows which L3, and so which
  CCD, each core belongs to.

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
