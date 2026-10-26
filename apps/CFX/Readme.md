# ANSYS CFX

Ansys [CFX](https://www.ansys.com/products/fluids/ansys-cfx) is a CFD software for turbomachinery applications. It offers streamlined workflows, advanced physics modeling capabilities, and accurate results.

# Versions

In this repository we will provide best practices for all the CFX versions starting from 2023 and newer.
The results on this page were measured with CFX 2026 R1 (`v261`).

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
    * Of the AMD instance types measured, the one that shows the **best price/performance** is the [Hpc8a](https://aws.amazon.com/ec2/instance-types/hpc8a/): on the 100M Airfoil it took 29% less time than [Hpc7a](https://aws.amazon.com/ec2/instance-types/hpc7a/) on the same nodes, and 22% less per run at On-Demand prices in eu-north-1 (October 2026). See [Performance](#performance).
    * Hpc6a cost about the same per run as Hpc7a, at 0.78-0.82x its speed. See [Instance types at 192 cores](#instance-types-at-192-cores).
    * Of the Intel instance types measured, c8i.96xlarge ran both Airfoils fastest; two hpc6id.32xlarge nodes (128 cores) cost 0.93 times as much per run for the 50M Airfoil and 1.02 times for the 100M, at 0.62-0.67x its speed. See [Instance types at 192 cores](#instance-types-at-192-cores).
  * CFX scales on multiple nodes, and its iterations scale best: on the 100M Airfoil they ran 7.6x as fast on ten Hpc8a nodes (1,920 cores) as on one, while partitioning, which cfx5solve runs once before the solver starts, took longer with more partitions. So the more iterations a run has, the more nodes pay off: the 100M Airfoil's 10-iteration benchmark was fastest on four Hpc8a nodes, on 768 cores of full nodes and faster still on 384 cores at 96 per node (see [Under-populated nodes](#under-populated-nodes)). To compare node counts, compare the time of the iterations (see [Performance](#performance)).
  * **Use Intel MPI over EFA.** CFX ships its own Intel MPI and Open MPI. With the EFA settings of the sbatch example in this directory (`I_MPI_FABRICS=shm:ofi`, `I_MPI_OFI_PROVIDER=efa`, `I_MPI_MULTIRAIL=1`), Intel MPI runs over EFA: with `I_MPI_DEBUG=5` the job output shows `libfabric provider: efa` and the EFA devices used. CFX's Open MPI printed no libfabric provider, and its whole run was 0.90x as fast on the 50M Airfoil on two Hpc8a nodes. See [MPI and libfabric](#mpi-and-libfabric).
  * **Intel MPI's own libfabric is enough.** Loading the EFA installer's instead (`I_MPI_OFI_LIBRARY_INTERNAL=0` and `module load libfabric-aws`, as the Fluent scripts here do) gave the same times.
  * **Fewer ranks per node, at the flexible-cores counts.** CFX is memory-bandwidth bound: the same 192 ranks on two or four Hpc8a or Hpc7a nodes ran the 100M Airfoil's iterations 1.9-2.8x as fast as on one full node, which pays when the core count is the constraint, as with per-core licences (see [Under-populated nodes](#under-populated-nodes)). On hpc8a.96xlarge and hpc7a.96xlarge, run 24, 48, 72, 96, 120, 144, 168 or 192 ranks per node, the counts that put the same number of ranks on each of the 24 CCDs. When Intel MPI's `mpirun` starts the ranks, as with the sbatch example's start method, pin them with the list for that count from [Utils/flexible-cores](https://github.com/aws-samples/hpc-applications/tree/main/Utils/flexible-cores): export `I_MPI_PIN_PROCESSOR_LIST` in the job script before `cfx5solve`, and check the placement in Intel MPI's pinning table (`I_MPI_DEBUG=5`). In the runs on this page, Intel MPI's own placement put 4 and 2 ranks on every CCD at 96 and 48 ranks per node, the same balance as the lists.
  * **Run as a regular user, with `HOME` set.** Without `HOME`, cfx5solve exits with status 2 before it starts ("Please ensure that the HOME environment variable is set before running CFX-5."). sbatch passes the submitting environment to the job, so set `HOME` in the job script if the tool that submits it has none. As root, the ssh-based start methods, such as the example's `'Intel MPI Distributed Parallel'`, cannot log in to the other nodes, and CFX's Open MPI refuses to run: submit as the cluster's default user (`ec2-user` on Amazon Linux), for whom ParallelCluster sets up SSH between the nodes.

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
(plus `-part-large` for the 50M and 100M Airfoils), with the EFA settings of the
sbatch example in this directory. Each cell is the median of 3 runs.

> Every figure below is relative performance: the reference configuration's time
> divided by each configuration's time, so the reference is 1.00 and higher is
> faster. The reference is one fully populated node of the same CPU vendor running
> the same case: one hpc7a.96xlarge (192 cores) for the AMD instance types, and one
> c8i.96xlarge (192 cores) for the Intel ones. The small cases, which ran at 24 and
> 48 cores only, use one hpc7a.96xlarge at 48 cores, and a section names any other
> reference.

cfx5solve runs in two phases, a partitioning run and the solver run, and the solver
run reports the time of the iterations themselves as `CFD Solver wall clock seconds`
in the output file. "Whole run" below is cfx5solve from the start of partitioning
to the end of the solver run. The wall clock around `cfx5solve`, which the sbatch
example in this directory passes to the recorder as `TIME_TO_SOLUTION`, also covers
cfx5solve's own start-up and wrap-up: in these runs it was 2-7% longer than the
whole run for the 50M and 100M Airfoils, and a larger share of the short small-case
runs (12-17% for Pump on one Hpc8a node at 24 cores).

## 100M Airfoil, full nodes

`perf_Airfoil_100M_R16` (104 million hexahedral elements), 2026-08-28. The runs
shared the cluster and its FSx for Lustre file system with other runs of the same
campaign; the three repeats of each cell agree within 3% on the whole run.

| Instance | Cores (nodes) | Whole run | Partitioning | Iterations |
|---|---|--:|--:|--:|
| hpc8a.96xlarge | 192 (1) | 1.41 | 1.27 | 1.40 |
| hpc8a.96xlarge | 384 (2) | 1.61 | 1.22 | 2.68 |
| hpc8a.96xlarge | 768 (4) | 1.79 | 1.15 | 5.17 |
| hpc8a.96xlarge | 1,920 (10) | 1.66 | 1.05 | 10.63 |
| hpc7a.96xlarge | 192 (1) | 1.00 | 1.00 | 1.00 |
| hpc7a.96xlarge | 768 (4) | 1.26 | 0.89 | 3.71 |
| hpc7a.96xlarge | 1,536 (8) | 1.17 | 0.81 | 6.51 |
| hpc6a.48xlarge | 192 (2) | 0.78 | 0.95 | 0.74 |
| hpc6a.48xlarge | 768 (8) | 1.17 | 0.84 | 2.79 |
| hpc6a.48xlarge | 1,536 (16) | 1.13 | 0.77 | 4.98 |

Relative performance of each phase, one hpc7a.96xlarge node (192 cores) = 1.00.

  * The iterations kept scaling: 7.6x faster from 192 to 1,920 cores on Hpc8a,
    6.5x from 192 to 1,536 on Hpc7a. Against one node of the same type (two for
    Hpc6a), their parallel efficiency was 93-96% up to 768 cores and 76-84% at
    1,536 and 1,920 cores: on ten Hpc8a nodes an iteration cost 1.31x the
    node-hours it took on one.
  * The whole 10-iteration run did not. It was fastest at 768 cores on all three
    instance types and slower beyond, because partitioning and the solver run's
    time outside the iterations both grew with the core count. When you study
    scaling, time the iterations apart from partitioning: past a few hundred cores
    a 10-iteration benchmark mostly measures its set-up.
  * Hpc8a was 1.41x as fast as Hpc7a on one node and 1.42x on four (29% less
    time on the same nodes).

## 50M Airfoil, full nodes

`perf_Airfoil_50M_R16` (47 million hexahedral elements), the same day, cluster and
settings as the 100M Airfoil; the three repeats of each cell agree within 5% on the
whole run.

| Instance | Cores (nodes) | Whole run | Partitioning | Iterations |
|---|---|--:|--:|--:|
| hpc8a.96xlarge | 192 (1) | 1.38 | 1.25 | 1.39 |
| hpc8a.96xlarge | 384 (2) | 1.63 | 1.19 | 2.70 |
| hpc8a.96xlarge | 768 (4) | 1.70 | 1.13 | 4.98 |
| hpc7a.96xlarge | 192 (1) | 1.00 | 1.00 | 1.00 |
| hpc7a.96xlarge | 768 (4) | 1.22 | 0.89 | 3.58 |
| hpc6a.48xlarge | 192 (2) | 0.82 | 0.96 | 0.74 |
| hpc6a.48xlarge | 768 (8) | 1.16 | 0.85 | 2.72 |

Relative performance of each phase, one hpc7a.96xlarge node (192 cores) running the
50M Airfoil = 1.00.

  * The same pattern as the 100M Airfoil: from 192 to 768 cores the iterations ran
    3.6x as fast on Hpc8a and Hpc7a and 3.7x on Hpc6a (90-91% parallel
    efficiency), while partitioning and the solver run's time outside the
    iterations grew, so the whole run ran only 1.2-1.4x as fast.

## Instance types at 192 cores

Both Airfoils on 192 cores of each instance type, full nodes, 2026-08-28: one node
of the 192-core types, two of the 96-core types, and 128 cores on two
hpc6id.32xlarge (64 cores each). Simultaneous multithreading was off on the Intel
instance types, so every rank had a core of its own. The EC2 cost per run is the
nodes' On-Demand price in eu-north-1 (October 2026) times the whole run. Each CPU
vendor's instance types are given against one node of the same vendor running the
same case, for the time and the cost per run alike. The three repeats of each cell
agree within 2% on the whole run, except on m7i.48xlarge (5%) and c7i.48xlarge
(4%).

**AMD instance types:**

| Instance | Nodes x cores | 100M whole run | 100M iterations | 100M cost per run | 50M whole run | 50M iterations | 50M cost per run |
|---|---|--:|--:|--:|--:|--:|--:|
| hpc8a.96xlarge | 1 x 192 | 1.41 | 1.40 | 0.78 | 1.38 | 1.39 | 0.80 |
| hpc7a.96xlarge | 1 x 192 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| hpc6a.48xlarge | 2 x 96 | 0.78 | 0.74 | 1.02 | 0.82 | 0.74 | 0.97 |

Relative performance and EC2 cost per run, one hpc7a.96xlarge node running the same
case = 1.00.

  * Of the three, Hpc8a ran both Airfoils fastest, over the whole run and on the
    iterations, at the lowest cost per run.
  * Hpc6a cost about the same per run as Hpc7a, at 0.78-0.82x its speed.

**Intel instance types:**

| Instance | Nodes x cores | 100M whole run | 100M iterations | 100M cost per run | 50M whole run | 50M iterations | 50M cost per run |
|---|---|--:|--:|--:|--:|--:|--:|
| c8i.96xlarge | 1 x 192 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| r8i.96xlarge | 1 x 192 | 0.96 | 0.95 | 1.54 | 0.97 | 0.95 | 1.52 |
| m7i.48xlarge | 2 x 96 | 0.73 | 0.72 | 1.45 | 0.78 | 0.72 | 1.37 |
| r7i.48xlarge | 2 x 96 | 0.72 | 0.72 | 1.94 | 0.77 | 0.72 | 1.82 |
| c7i.48xlarge | 2 x 96 | 0.67 | 0.66 | 1.41 | 0.72 | 0.66 | 1.33 |
| hpc6id.32xlarge | 2 x 64 | 0.62 | 0.47 | 1.02 | 0.67 | 0.48 | 0.93 |

Relative performance and EC2 cost per run, one c8i.96xlarge node running the same
case = 1.00.

  * Of the six, c8i.96xlarge ran both Airfoils fastest, over the whole run and on
    the iterations.
  * r8i.96xlarge ran at 0.95-0.97x c8i.96xlarge's speed, at about 1.5 times its
    cost per run.
  * On two nodes each, m7i.48xlarge, r7i.48xlarge and c7i.48xlarge ran at
    0.66-0.78x c8i.96xlarge's speed, at 1.3-1.9 times its cost per run.
  * Two hpc6id.32xlarge nodes, with 128 cores, ran the whole run at 0.62-0.67x
    c8i.96xlarge's speed and the iterations at 0.47-0.48x. A run cost 1.02 times as
    much as on c8i.96xlarge for the 100M Airfoil and 0.93 times for the 50M, the
    lowest cost per run of the six there.

## Under-populated nodes

The same 100M Airfoil and day. Intel MPI's default pinning placed the ranks evenly:
4 per CCD at 96 cores per node and 2 per CCD at 48 (4 per L3 group on Hpc6a).

**192 cores on more nodes:**

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
  * The 50M Airfoil showed the same: on two Hpc8a nodes at 96 cores per node its
    iterations ran 1.85x as fast as on one full node (1.87x for the 100M Airfoil).
  * On hpc6id.32xlarge, 128 cores on four nodes (32 of their 64 cores each) ran the
    100M Airfoil's iterations 1.53x as fast as on two full nodes.

**Fewer ranks on the same four hpc8a.96xlarge nodes:**

| Nodes x cores per node | Cores | Whole run | Iterations |
|---|--:|--:|--:|
| 4 x 48 | 192 | 1.78 | 3.79 |
| 4 x 96 | 384 | 1.90 | 4.94 |
| 4 x 192 | 768 | 1.79 | 5.17 |

Relative performance, one hpc7a.96xlarge node (192 cores) = 1.00.

  * Full nodes ran the iterations fastest, 1.36x as fast as at 48 cores per node
    but only 1.05x as fast as at 96: with half the ranks, 96 per node gave 95% of
    the full nodes' iteration speed, and the fastest whole run of the 100M Airfoil
    on the AMD types measured. Under-population pays when the core count is the
    constraint, as with per-core licences, rather than the node count.

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
| perf_LeMansCar_R16 | hpc7a.96xlarge | 0.81 (0.53) | 1.00 (1.00) |

Relative performance of the whole run, with the iterations in brackets, each case
against one hpc7a.96xlarge at 48 cores = 1.00. Partitioning took about the same
time in every one of these runs, so it is a large share of the whole run, and the
largest share of the fastest runs.

  * 48 cores was faster than 24 for both cases on both instance types.
  * Hpc8a took 27-30% less time than Hpc7a on the iterations, and 16-21% on the
    whole run, of which partitioning is a large share.

The 10M Airfoil (`perf_Airfoil_10M_R16`, 9.4 million hexahedral elements) ran on one
hpc8a.96xlarge on 2026-08-28, at 48 and 96 cores with Intel MPI's default pinning
(2 and 4 ranks per CCD): 96 cores ran the whole run 1.14x and the iterations 1.37x
as fast as 48.

## MPI and libfabric

`perf_Airfoil_50M_R16` on two hpc8a.96xlarge nodes (384 cores), 3 runs of each
set-up, on the morning of 2026-08-28; the three runs of each set-up agree within 6%
on the whole run. Open MPI ran with the `Open MPI Scheduler` start method.

| MPI | libfabric | Whole run | Partitioning | Iterations |
|---|---|--:|--:|--:|
| Intel MPI 2021.14, bundled with CFX | Intel MPI's own (1.21.0) | 1.00 | 1.00 | 1.00 |
| Intel MPI 2021.14, bundled with CFX | the EFA installer's (2.4.0): `I_MPI_OFI_LIBRARY_INTERNAL=0`, `module load libfabric-aws` | 1.00 | 1.00 | 1.00 |
| Open MPI 4.1.8, bundled with CFX | none reported | 0.90 | 1.00 | 0.98 |

Relative performance, Intel MPI with its own libfabric = 1.00.

  * Intel MPI ran over EFA: with `I_MPI_DEBUG=5` its output shows
    `libfabric provider: efa`, and both of the node's EFA devices in its NIC
    pinning table. CFX's Open MPI printed no libfabric provider (with
    `OMPI_MCA_opal_common_ofi_provider_include=efa` and
    `OMPI_MCA_mtl_ofi_verbose=1`). Its iterations ran at 0.98x Intel MPI's speed,
    but the rest of its solver run took 1.5x as long, so its whole run ran at 0.90x.
  * The EFA installer's libfabric gave the same times as Intel MPI's own.

## Contribute your results

The benchmark scripts in this folder call [`dynamodb/record-benchmark.sh`](dynamodb/record-benchmark.sh) after every successful run. The recorder saves the run as a small JSON record (`<record_id>.json`) and adds it to the shared AI-Powered HPC benchmark dataset when you have write access to it. That dataset trains a model that predicts HPC performance on AWS, so every result you share helps. Set `SOURCE=<YourOrg>` to tag your runs, and see [BENCHMARK-RECORDERS.md](../BENCHMARK-RECORDERS.md) for the options and how to send the record in.
