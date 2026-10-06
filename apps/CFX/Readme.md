# ANSYS CFX

Ansys [CFX](https://www.ansys.com/products/fluids/ansys-cfx) is a CFD software for turbomachinery applications. It offers streamlined workflows, advanced physics modeling capabilities, and accurate results.

# Versions

In this repository we will provide best practices for all the CFX versions starting from 2023 and newer.

**_NOTE:_**  We will provide best practices for AWS Graviton instances as soon as CFX will officially support ARM-based cpus.


# Installation

CFX is supported on both Windows and on Linux machines.<br>
In this repository we will share an example script to install CFX on a Linux system.<br>
CFX installation is relatively easy as it is part of the ANSYS `FLUIDSTRUCTURES` package. You can have a look at [this example script](https://github.com/aws-samples/hpc-applications/blob/main/apps/Fluent/Fluent-Install.sh) to create your own installation procedure, or you can execute this script as follow:

```
./Fluent-Install.sh /fsx s3://your_bucket/FLUIDSTRUCTURES_2024R2_LINX64.tgz
```

  * This is working example installation script that run unattended.
  * The first parameter is the base directory where you want to install CFX. If you pass `/fsx` then CFX will be installed under `/fsx/ansys_inc` .
  * The second parameter is the [S3](https://aws.amazon.com/pm/serv-s3/) URI pointing to installation package (tar.gz).

<br>

For running CFX on multiple nodes, it is required to install it in a shared directory, possibly a parallel file system.<br>
We would strongly recommend to use [Amazon FSx for Lustre](https://aws.amazon.com/fsx/lustre/), more info in the official [documentation](https://docs.aws.amazon.com/fsx/latest/LustreGuide/what-is.html) .

# Key settings & tips (performance related ones) :

  * CFX is a compute and memory bandwidth bound code. 
    * the best instance types for running it are the ones with higher amount of cores, and higher memory bandwidth per core.
    * As of today, the instance that shows the **best price/performance** is the [Hpc8a](https://aws.amazon.com/ec2/instance-types/hpc8a/): on the 100M Airfoil it took 29% less time than [Hpc7a](https://aws.amazon.com/ec2/instance-types/hpc7a/) on the same nodes, and 22% less per run at On-Demand prices in eu-north-1 (September 2026). See [Performance](#performance).
  * CFX is a software that scales on multiple nodes: the simulation time decreases as the numbrer of cores being used increases (typically not proportionally).

  * `-parallel` This parameter tells CFX to use run in parallel on multiple nodes.
  * ` -start-method 'Intel MPI Distributed Parallel'` This parameter specifies the MPI implementation. At the moment, `IntelMPI` is the MPI library that offer better performance on AWS.
  * `-par-dist "$HOST_LIST"` This parameter specifies hosts where the simulation run.
  * ` -part $SLURM_NPROCS` This parameter specifies the number of cores used to run the simulation.
  * ` -part-large` This parameter is used for large models.

# Performance

Measured on AWS in eu-north-1 with CFX 2026 R1 (`v261`) on the official benchmark
definition files at their shipped iteration count (10 for every case below), Intel
MPI 2021.14 over EFA, launched with
`cfx5solve -batch -def <case>.def -parallel -start-method 'Intel MPI Scheduler' -part <cores>`
(plus `-part-large` for the 100M Airfoil). Each cell is the median of 3 runs.

> Every figure below is relative performance: the reference configuration's time
> divided by each configuration's time, so the reference is 1.00 and higher is
> faster. The reference is one fully populated hpc7a.96xlarge node (192 cores),
> except for the small cases, which ran at 24 and 48 cores only and use one
> hpc7a.96xlarge at 48 cores.

cfx5solve runs in two phases, a partitioning run and the solver run, and the solver
run reports the time of the iterations themselves as `CFD Solver wall clock seconds`
in the output file. "Whole run" below is cfx5solve from the start of partitioning
to the end of the solver run. The wall clock around `cfx5solve`, which the sbatch
example in this directory passes to the recorder as `TIME_TO_SOLUTION`, also covers
cfx5solve's own start-up and wrap-up: in these runs it was 2-6% longer than the
whole run for the 100M Airfoil, and a larger share of the short small-case runs
(12-17% for Pump on one Hpc8a node at 24 cores).

## 100M Airfoil, full nodes

`perf_Airfoil_100M_R16`, 2026-08-28. The runs shared the cluster and its FSx for
Lustre file system with other runs of the same campaign; the three repeats of each
cell agree within 3% on the whole run.

| Instance | Cores (nodes) | Whole run | Partitioning | Iterations |
|---|---|--:|--:|--:|
| hpc8a.96xlarge | 192 (1) | 1.41 | 1.27 | 1.40 |
| hpc8a.96xlarge | 384 (2) | 1.61 | 1.22 | 2.68 |
| hpc8a.96xlarge | 768 (4) | 1.79 | 1.15 | 5.18 |
| hpc8a.96xlarge | 1,920 (10) | 1.66 | 1.05 | 10.63 |
| hpc7a.96xlarge | 192 (1) | 1.00 | 1.00 | 1.00 |
| hpc7a.96xlarge | 768 (4) | 1.26 | 0.89 | 3.72 |
| hpc7a.96xlarge | 1,536 (8) | 1.17 | 0.81 | 6.50 |
| hpc6a.48xlarge | 192 (2) | 0.78 | 0.95 | 0.74 |
| hpc6a.48xlarge | 768 (8) | 1.17 | 0.84 | 2.79 |
| hpc6a.48xlarge | 1,536 (16) | 1.13 | 0.77 | 4.98 |

Relative performance of each phase, one hpc7a.96xlarge node (192 cores) = 1.00.

  * The iterations kept scaling: 7.6x faster from 192 to 1,920 cores on Hpc8a,
    6.5x from 192 to 1,536 on Hpc7a.
  * The whole 10-iteration run did not. It was fastest at 768 cores on all three
    instance types and slower beyond, because partitioning and the solver run's
    time outside the iterations both grew with the core count. When you study
    scaling, time the iterations apart from partitioning: past a few hundred cores
    a 10-iteration benchmark mostly measures its set-up.
  * Hpc8a was 1.41x as fast as Hpc7a on one node and 1.42x on four (29% less
    time on the same nodes).

## Under-populated nodes, 192 cores

The same case and day, 192 cores spread over more nodes. Intel MPI's default
pinning placed the ranks evenly: 4 per CCD at 96 cores per node and 2 per CCD at
48 (4 per L3 group on Hpc6a).

| Instance | Nodes x cores per node | Whole run | Iterations |
|---|---|--:|--:|
| hpc8a.96xlarge | 1 x 192 | 1.41 | 1.40 |
| hpc8a.96xlarge | 2 x 96 | 1.68 | 2.60 |
| hpc8a.96xlarge | 4 x 48 | 1.78 | 3.79 |
| hpc7a.96xlarge | 1 x 192 | 1.00 | 1.00 |
| hpc7a.96xlarge | 2 x 96 | 1.22 | 1.95 |
| hpc7a.96xlarge | 4 x 48 | 1.31 | 2.80 |
| hpc6a.48xlarge | 2 x 96 | 0.78 | 0.74 |
| hpc6a.48xlarge | 4 x 48 | 1.09 | 1.59 |

Relative performance, one hpc7a.96xlarge node (192 cores) = 1.00.

  * On the same 192 cores, 2 or 4 times the nodes made the iterations 1.9-2.8x
    faster on Hpc8a and Hpc7a and 2.2x faster on Hpc6a, and the whole run took
    16-28% less time.
  * On the same four Hpc8a nodes, full nodes were faster still: the iterations ran
    1.36x as fast at 4 x 192 as at 4 x 48. Under-population pays when the core
    count is the constraint, as with per-core licences, rather than the node count.

## Small cases at the flexible-cores counts

One node, 2026-10-04, with at most three jobs on the cluster. The ranks were pinned
with the explicit lists from
[Utils/flexible-cores](https://github.com/aws-samples/hpc-applications/tree/main/Utils/flexible-cores)
(`I_MPI_PIN_PROCESSOR_LIST`, checked in Intel MPI's pinning table with
`I_MPI_DEBUG=5`).

| Case | Instance | 24 cores | 48 cores |
|---|---|--:|--:|
| perf_Pump_R16 | hpc8a.96xlarge | 1.07 (0.83) | 1.18 (1.37) |
| perf_Pump_R16 | hpc7a.96xlarge | 0.87 (0.59) | 1.00 (1.00) |
| perf_LeMansCar_R16 | hpc8a.96xlarge | 1.02 (0.76) | 1.21 (1.40) |
| perf_LeMansCar_R16 | hpc7a.96xlarge | 0.81 (0.54) | 1.00 (1.00) |

Relative performance of the whole run, with the iterations in brackets, each case
against one hpc7a.96xlarge at 48 cores = 1.00. Partitioning took about the same
time in every one of these runs, so it is a large share of the whole run, and the
largest share of the fastest runs.

  * 48 cores was faster than 24 for both cases on both instance types.
  * Hpc8a took 27-30% less time than Hpc7a on the iterations, and 16-21% on the
    whole run, of which partitioning is a large share.
