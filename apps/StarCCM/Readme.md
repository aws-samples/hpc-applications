# STAR-CCM+

[Siemens Simcenter STAR-CCM+](https://plm.sw.siemens.com/en-US/simcenter/fluids-thermal-simulation/star-ccm/) is a multiphysics computational fluid dynamics (CFD) simulation software that enables engineers to model the complexity and explore the possibilities of products operating under real-world conditions. Recent software versions have included the capability to carry out Finite Element Analysis studies, and other physics phenomena that can be modelled in the software include battery and combustion modelling.

## Versions

There are 3 releases of STAR-CCM+ per year. There are two platform builds — x86 and Arm — each available for both Linux and Windows. There are also separate mixed precision and double (higher) precision builds available. Each of these have slightly different solve speeds and compute requirements with the double precision version (labelled -R8) having the higher requirements of the two. GPGPU compute capability is included within the x86 build (not a separate build). While submit scripts are mostly common across versions, there are nuances for x86, Arm and GPGPU usage to consider. The submit scripts in this repository are organised by version and architecture under `scripts/`.

## OS Compatibility

STAR-CCM+ works on many flavours of Linux, but by default is only supported on a small number of them. Recommended operating systems for running on AWS are Amazon Linux 2023, Ubuntu 20.04+, or RHEL8+. Note that as of STAR-CCM+ 2402 (19.02) and onwards, glibc >= 2.26 is required, and from 21.02 onwards glibc >= 2.28 is required. Amazon Linux 2 is end-of-life and should not be used.

| STAR-CCM+ Version | AL2023 | Ubuntu 20+ | RHEL8+ |
|-------------------|:-:|:-:|:-:|
| 18.06 (x86/GPU) | ✓ | ✓ | ✓ |
| 18.06 (Arm) | ✓ | ✓ | ✓ |
| 21.02+ (all) | ✓ | ✓ | ✓ |

## Installation

To install on a non-GUI based cluster, the following command can be used:

```
./STAR-CCM+_installer_.sh -i console -DPRODUCTEXCELLENCEPROGRAM=0 -DINSTALLDIR=/fsx/Siemens -DINSTALLFLEX=false -DADDSYSTEMPATH=true -DNODOC=false
```
This will provide a fast install to the specified location (`/fsx/Siemens`), without the license server or documentation being installed (the latter of which makes up a large chunk of the install size but may be useful). Please read the STAR-CCM+ installation guide for more information on parameters that can be set at install time.

## Key Settings

### License

There are multiple ways to license STAR-CCM+. The two most common methods are

- host a vendor supplied license on a license server
- use Power on Demand (PoD) which checks out a license from a Siemens hosted license server

Each method has its advantages and disadvantages, however it's worth noting that Power on Demand licenses are significantly easier to use with AWS; the license key can be placed as an argument when launching STAR-CCM+ and — as long as the instance can communicate with the internet — the license gets checked out.

The submit scripts in this repository use a `PODLIC` environment variable to pass the PoD key to STAR-CCM+. This is our suggested approach for keeping keys out of scripts. Set it in your user's environment variables (e.g. in `~/.bashrc`) or before submitting:

```bash
export PODLIC="your-pod-key-here"
sbatch submit_batch.sbatch -v 21.02.007 -s /fsx/simulations/model.sim
```

If running a license server on AWS, consider the following:

- Use a dedicated Elastic Network Interface (ENI) attached to the license server EC2 instance. This ensures the MAC address (which FlexLM ties the license to) persists even if the instance is terminated and replaced.
- For additional resilience, FlexLM supports a triad of license servers. This provides redundancy — if one server goes down, the remaining two can continue to serve licenses.
- Alternatively, a VPN connection can be used to reach a license server running outside of AWS.

### MPI

OpenMPI is the recommended MPI for Linux per the Siemens STAR-CCM+ user guide, and is required for AMD-based instances (e.g. hpc8a, hpc7a, hpc6a) where Intel MPI is unsupported and can crashes on STAR-CCM+ 21.02+ (e.g. during mesh repartitioning). All 21.02+ scripts in this repository use OpenMPI.

Intel MPI remains viable on Intel instances (hpc6id, c7i, c8i) and is retained in the 18.06 scripts where the version bundled with STAR-CCM+ works reliably across all tested platforms.

| Version | x86 | GPU | Arm |
|---------|-----|-----|-----|
| 18.06 | Intel MPI | Intel MPI | OpenMPI |
| 21.02+ | **OpenMPI** | **OpenMPI** | OpenMPI |

For OpenMPI, the key STAR-CCM+ flags are:

```
-mpi openmpi -xsystemlibfabric -ldlibpath /opt/amazon/efa/lib64 -fabric OFI
```

For Intel MPI (18.06 only), the environment variables required are:

```bash
export I_MPI_OFI_LIBRARY_INTERNAL=0
export I_MPI_FABRICS=shm:ofi
export I_MPI_OFI_PROVIDER=efa
export I_MPI_MULTIRAIL=1
```

### CPU Binding

No `-cpubind` flag is needed in the submit scripts. STAR-CCM+ defaults to `-cpubind bandwidth` which maximises memory bandwidth across NUMA nodes. Benchmarking confirmed this is 42–45% faster than `-cpubind off` on AMD multi-CCD architectures (hpc8a, hpc7a).

## Submit Scripts

Submit scripts are provided under `scripts/` organised by STAR-CCM+ version and architecture. Each directory contains a `submit_batch.sbatch` for headless batch runs and a `submit_server.sbatch` for interactive server mode (connect via the STAR-CCM+ GUI).

See [`scripts/README.md`](scripts/README.md) for full usage documentation, flag reference, and customisation options. Not setting `-m` options will cause the simulation to start running/solving.

```
scripts/
├── 18.06/                    # STAR-CCM+ 18.06 (works on AL2, AL2023, RHEL8, Ubuntu)
│   ├── x86/                  # Intel MPI
│   ├── gpu/                  # Intel MPI + GPU offload
│   └── arm/                  # OpenMPI (Intel MPI is x86-only)
└── 21.02/                    # STAR-CCM+ 21.02+ (requires glibc >= 2.28)
    ├── x86/                  # OpenMPI (recommended for all platforms)
    ├── gpu/                  # OpenMPI + GPU offload
    └── arm/                  # OpenMPI
```

Quick start:

```bash
# x86 batch run (default version is 21.02.007)
sbatch scripts/21.02/x86/submit_batch.sbatch -s /fsx/simulations/model.sim

# Specify a version explicitly
sbatch scripts/21.02/x86/submit_batch.sbatch -v 21.02.007 -s /fsx/simulations/model.sim

# Run with a Java macro
sbatch scripts/21.02/x86/submit_batch.sbatch -s /fsx/simulations/model.sim -m RunAndTimeSimulation.java

# Chain multiple batch commands (macro, then mesh, then solve)
sbatch scripts/21.02/x86/submit_batch.sbatch -s model.sim -m "macro.java,mesh,run"

# GPU batch run
sbatch scripts/21.02/gpu/submit_batch.sbatch -v 21.02.007 -s /fsx/simulations/model.sim

# Server mode (connect via STAR-CCM+ GUI)
sbatch scripts/21.02/x86/submit_server.sbatch -v 21.02.007 -s /fsx/simulations/model.sim
```

## Macros

### RunAndTimeSimulation.java

A benchmarking macro that runs configurable warmup + timed iterations, measures solve time and memory, exports all simulation reports, and writes results to CSV and JSON. See [`macros/RunAndTimeSimulation.java`](macros/RunAndTimeSimulation.java) for full documentation.

This macro has been used internally at AWS for STAR-CCM+ benchmarking in place of the default `starccm+ -benchmark` flag. It provides more control over the benchmarking process — configurable warmup iterations, per-step timing, memory measurement, and report export — and works with both steady and unsteady simulations.

**Use at your own risk.** This is not officially supported by Siemens. It is written in a readable form so is easy to audit.

Usage:

```bash
sbatch scripts/21.02/x86/submit_batch.sbatch -s /fsx/simulations/model.sim -m RunAndTimeSimulation.java
```


## Benchmarking Summary

AWS ran STAR-CCM+ 2606 (21.04.007, mixed precision) on six models of Siemens's benchmark suite in October 2026, on [hpc8a](https://aws.amazon.com/ec2/instance-types/hpc8a/), [hpc7a](https://aws.amazon.com/ec2/instance-types/hpc7a/) and [hpc6a](https://aws.amazon.com/ec2/instance-types/hpc6a/) instances. The runs used the 21.02 x86 scripts' MPI options (the bundled Open MPI 5.0.9 over EFA with `-xsystemlibfabric -ldlibpath /opt/amazon/efa/lib64 -fabric OFI`, and the default `-cpubind bandwidth`), with the page cache dropped and THP set to `always` before each run. Each model was timed with STAR-CCM+'s `-benchmark` mode and Siemens's protocol for it (5 or 40 pre-iterations, with `-preclear` where Siemens asks for it, then 20 timed iterations; civil with 120 pre-iterations instead of 40): performance is the `AverageElapsedTime` of the 20 timed iterations, and every value below is the median of 3 runs.

The results in brief:

- **hpc8a.96xlarge is 1.37–1.50× hpc7a.96xlarge** node for node on Siemens's models, and both keep 82–108% parallel efficiency to 8 nodes.
- **With a Power licence, populate every node** and add nodes for speed: at the same node count, full nodes ran fastest. **With a licence per core, spread the ranks** at 96 per node on hpc8a and hpc7a: the same ranks ran 1.7–1.9× as fast for 1.08–1.18× the EC2 cost per run.

### Scaling on hpc8a, hpc7a and hpc6a

Every node is fully populated: 192 ranks per node on `hpc8a.96xlarge` and `hpc7a.96xlarge`, 96 on `hpc6a.48xlarge`. Performance is relative to one `hpc7a.96xlarge` node running the same model = 1.00× (for AeroSUV 322M, which needs at least two nodes: two `hpc7a.96xlarge` nodes = 1.00×); higher is faster. No model was run below about 10,000 cells per core, so reactor stops at 768 cores. The chart labels each line's last point with its parallel efficiency against the same instance type's first point.

![STAR-CCM+ 2606 scaling of six Siemens benchmark models on hpc8a, hpc7a and hpc6a](https://github.com/aws-samples/hpc-applications/blob/main/Doc/img/StarCCM/STARCCM-2606-Scaling.png?raw=true)

| Model (cells) | Instance type | 1 node | 2 nodes | 4 nodes | 8 nodes | 16 nodes |
|---|---|--:|--:|--:|--:|--:|
| reactor (9M) | hpc8a.96xlarge | 1.43× | 2.92× | 5.71× | — | — |
| | hpc7a.96xlarge | 1.00× | 2.04× | 3.88× | — | — |
| | hpc6a.48xlarge | 0.37× | 0.80× | 1.66× | 3.13× | — |
| civil (20M) | hpc8a.96xlarge | 1.42× | 2.91× | 5.85× | 10.92× | — |
| | hpc7a.96xlarge | 1.00× | 2.07× | 4.03× | 7.78× | — |
| | hpc6a.48xlarge | 0.40× | 0.81× | 1.70× | 3.48× | 6.36× |
| LeMans 100M segregated (106M) | hpc8a.96xlarge | 1.39× | 2.86× | 5.73× | 11.95× | — |
| | hpc7a.96xlarge | 1.00× | 2.02× | 3.95× | 7.99× | — |
| | hpc6a.48xlarge | 0.37× | 0.77× | 1.56× | 3.12× | 6.41× |
| AeroSUV 106M coupled | hpc8a.96xlarge | 1.42× | 2.81× | 5.82× | 11.43× | — |
| | hpc7a.96xlarge | 1.00× | 1.97× | 4.02× | 7.72× | — |
| | hpc6a.48xlarge | 0.40× | 0.76× | 1.60× | 3.31× | 5.97× |
| vtmBenchmark (178M) | hpc8a.96xlarge | 1.37× | 2.75× | 5.35× | 9.70× | — |
| | hpc7a.96xlarge | 1.00× | 1.99× | 3.81× | 6.57× | — |
| | hpc6a.48xlarge | 0.39× | 0.70× | 1.55× | 3.03× | 5.50× |
| AeroSUV 322M coupled | hpc8a.96xlarge | — | 1.41× | 2.84× | 5.58× | — |
| | hpc7a.96xlarge | — | 1.00× | 2.01× | 3.87× | — |
| | hpc6a.48xlarge | — | — | 0.81× | 1.59× | 3.21× |

The runs of 63 of the 71 points agree within 5%, and the median spread of all 71 is 1.1%. At the other 8 the median sets the value: their runs spread 5.5–17%, on civil (4 `hpc7a.96xlarge` and 8 `hpc8a.96xlarge` nodes) and reactor (4 and 8 `hpc6a.48xlarge` nodes), the shortest timed windows, on LeMans 100M (8 `hpc7a.96xlarge` nodes), and on AeroSUV 106M (1 and 2 `hpc6a.48xlarge` nodes) and vtmBenchmark (2 `hpc6a.48xlarge` nodes).

- `hpc8a.96xlarge` runs these models 1.37–1.43× as fast as `hpc7a.96xlarge` on one node (two for AeroSUV 322M), and 1.40–1.50× as fast on 8 nodes.
- On 8 nodes (1,536 ranks), parallel efficiency against the first point is 88–108% on `hpc8a.96xlarge` and 82–100% on `hpc7a.96xlarge`; on 16 `hpc6a.48xlarge` nodes (also 1,536 ranks) it is 89–109%. vtmBenchmark scales least of the six.
- One `hpc6a.48xlarge` node (96 cores) delivers 0.37–0.40× of one `hpc7a.96xlarge` node (192 cores).

### Fewer ranks per node

Which layout costs least depends on how STAR-CCM+ is licensed. A Power licence (Power on Demand, or a Power Session licence) covers a run on any number of cores, so its cost follows the run's wall time; a licence per core costs in proportion to ranks × time.

**The same ranks on more nodes.** Spreading a fixed number of ranks over more nodes, at the flexible-cores counts per node (see [Utils/flexible-cores](https://github.com/aws-samples/hpc-applications/tree/main/Utils/flexible-cores)), ran much faster at a higher EC2 cost per run. Relative to the fully populated shape of the same total = 1.00× (2 × 192 for 384 ranks, 3 × 192 for 576):

| Model | Instance type | Ranks | Nodes × ranks per node | Speed | EC2 cost per run |
|---|---|--:|---|--:|--:|
| AeroSUV 106M coupled | hpc8a.96xlarge | 384 | 4 × 96 | 1.83× | 1.09× |
| | | | 8 × 48 | 2.42× | 1.65× |
| | hpc7a.96xlarge | 384 | 4 × 96 | 1.85× | 1.08× |
| | | | 8 × 48 | 2.39× | 1.67× |
| | hpc8a.96xlarge | 576 | 4 × 144 | 1.27× | 1.05× |
| | | | 6 × 96 | 1.72× | 1.16× |
| LeMans 100M segregated | hpc8a.96xlarge | 384 | 4 × 96 | 1.69× | 1.18× |
| | | | 8 × 48 | 2.19× | 1.83× |
| | hpc7a.96xlarge | 384 | 4 × 96 | 1.71× | 1.17× |
| | | | 8 × 48 | 2.15× | 1.86× |

Speed is the reference's time over the shape's time (higher is faster). With the same total ranks, both licence models cost in proportion to the run time, so a speed of 1.83× is 0.55× the licence cost per run. The EC2 cost per run is nodes × time on the same instance type. The runs of each shape agree within 1.5%.

![STAR-CCM+ 2606: the same ranks spread over more nodes](https://github.com/aws-samples/hpc-applications/blob/main/Doc/img/StarCCM/STARCCM-2606-FlexibleCores.png?raw=true)

**Fewer ranks on the same nodes.** At the same node count, fully populated nodes ran fastest: on 4 nodes, 192 ranks per node ran 1.10–1.18× as fast as 96 per node, and on 8 nodes 1.64–1.91× as fast as 48 per node (AeroSUV 106M and LeMans 100M, on `hpc8a.96xlarge` and `hpc7a.96xlarge`). On one node of AeroSUV 106M, relative to the fully populated node (192 ranks = 1.00×):

| Instance type | Ranks per node | Speed (a Power licence costs in proportion to 1 / speed) | Ranks × time (a licence per core costs in proportion to it) |
|---|--:|--:|--:|
| hpc8a.96xlarge | 144 | 0.98× | 0.76× |
| | 96 | 0.91× | 0.55× |
| hpc7a.96xlarge | 144 | 0.97× | 0.77× |
| | 96 | 0.98× | 0.51× |

The 144-rank points' runs spread 8–10%; the others' within 4%. Measured on AeroSUV 106M and LeMans 100M only.

**Binding at 96 ranks per node.** Pinning the 96 ranks to the cores of the flexible-cores list for 96 per node (`-cpubind off`, with a rankfile passed through `-mpiflags`) ran within 0.1% of STAR-CCM+'s default `-cpubind bandwidth` on AeroSUV 106M coupled (one `hpc8a.96xlarge`, 3 runs each), so at these counts the default binding is enough and no rankfile is needed (measured on that model only).


### Key Takeaways

- **OpenMPI is now the default.** Intel MPI is no longer recommended on non-Intel instances. It crashes on AMD Turin/Genoa during mesh repartitioning in STAR-CCM+ 21.02+.
- **CPU binding matters.** The default `-cpubind bandwidth` is optimal; explicitly setting `-cpubind off` costs 42–45% performance on AMD multi-CCD architectures.
- **Warmup iterations are important for benchmarking.** The first ~100 iterations involve memory allocation overhead and should be discarded for timing purposes.
- **AL2023 is the recommended OS** for x86 and GPU instances (glibc 2.34). Amazon Linux 2 is no longer compatible with STAR-CCM+ 21.02+.

## Contribute your results

The benchmark scripts in this folder call [`dynamodb/record-benchmark.sh`](dynamodb/record-benchmark.sh) after every successful run. The recorder saves the run as a small JSON record (`<record_id>.json`) and adds it to the shared AI-Powered HPC benchmark dataset when you have write access to it. That dataset trains a model that predicts HPC performance on AWS, so every result you share helps. Set `SOURCE=<YourOrg>` to tag your runs, and see [BENCHMARK-RECORDERS.md](../BENCHMARK-RECORDERS.md) for the options and how to send the record in.
