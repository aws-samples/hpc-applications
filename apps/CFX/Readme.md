# ANSYS CFX

Ansys [CFX](https://www.ansys.com/products/fluids/ansys-cfx) is a CFD software for turbomachinery applications. It offers streamlined workflows, advanced physics modeling capabilities, and accurate results.

# Versions

In this repository we will provide best practices for all the Fluent versions starting from 2023 and newer.

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
    * As of today, the instance that shows the **best price/performance** is the [Hpc7a](https://aws.amazon.com/ec2/instance-types/hpc7a/) .
  * CFX is a software that scales on multiple nodes: the simulation time decreases as the numbrer of cores being used increases (typically not proportionally).

  * `-parallel` This parameter tells CFX to use run in parallel on multiple nodes.
  * ` -start-method 'Intel MPI Distributed Parallel'` This parameter specifies the MPI implementation. At the moment, `IntelMPI` is the MPI library that offer better performance on AWS.
  * `-par-dist "$HOST_LIST"` This parameter specifies hosts where the simulation run.
  * ` -part $SLURM_NPROCS` This parameter specifies the number of cores used to run the simulation.
  * ` -part-large` This parameter is used for large models.

# Performance

TBC