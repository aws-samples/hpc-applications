# ANSYS Fluent

ANSYS [Fluent](https://www.ansys.com/products/fluids/ansys-fluent) (Fluent) is a general-purpose computational fluid dynamics (CFD) software used to model fluid flow, heat and mass transfer, chemical reactions, and more. 
Developed by [ANSYS](https://www.ansys.com/) it offers support for CPU (x86) and GPU solvers. An Arm-based version that will run on AWS Graviton is under development and available as a beta from Ansys.

# Versions

In this repository we will provide best practices for all the Fluent versions starting from 2020 and newer.
For Fluent version 2019 (v195) and older please refer to this [Blog Post](https://aws.amazon.com/it/blogs/compute/running-ansys-fluent-on-amazon-ec2-c5n-with-elastic-fabric-adapter-efa/) .

Fluent supports CPU and GPU solvers. Please refer to:
  * [This example script for CPU-based simulations](https://github.com/aws-samples/hpc-applications/blob/main/apps/Fluent/x86/Fluent.sbatch)
  * [This example script for GPU-based simulations](https://github.com/aws-samples/hpc-applications/blob/main/apps/Fluent/gpu/Fluent-GPU.sbatch)

**_NOTE:_**  We will provide best practices for AWS Graviton instances as soon as Fluent will officially support ARM-based cpus.


# Installation

Fluent is supported on both Windows and on Linux machines.<br>
In this repository we will share an example script to install Fluent on a Linux system.<br>
Fluent installation is relatively easy. You can have a look at [this example script](https://github.com/aws-samples/hpc-applications/blob/main/apps/Fluent/Fluent-Install.sh) to create your own installation procedure, or you can execute this script as follow:

```
./Fluent-Install.sh /fsx s3://your_bucket/FLUIDSTRUCTURES_2022R1_LINX64.tgz
```

  * This is working example installation script that run unattended.
  * The first parameter is the base directory where you want to install Fluent. If you pass `/fsx` the Fluent will be installed under `/fsx/ansys_inc` .
  * The second parameter is the [S3](https://aws.amazon.com/pm/serv-s3/) URI pointing to installation file (tar.gz).

<br>

For running Fluent on multiple nodes, it is required to install it in a shared directory, possibly a parallel file system.<br>
We would strongly recommend to use [Amazon FSx for Lustre](https://aws.amazon.com/fsx/lustre/), more info in the official [documentation](https://docs.aws.amazon.com/fsx/latest/LustreGuide/what-is.html) .

# Key settings & tips (performance related ones) :

  * Fluent is a compute and memory bandwidth bound code. 
    * the best instance types for running it are the ones with higher amount of cores, and higher memory bandwidth per core.
    * As of today, the instance that shows the **best price/performance** is the [Hpc7a](https://aws.amazon.com/ec2/instance-types/hpc7a/) .
  * Fluent is a software that scales nicely: the simulation time decreases proportionally to the numbrer of cores being used.
    * It is possible to achieve (almost) linear scaling by solving a mesh using max. between **30k-50k cells per core**.
    * This range is influenced by the complexity of your simulation and the phisics of your models. 
    * For example below (The f1_racecar_140m) has 140 Milions of cell. This model can be solved achieving a great scalability using up to ~4500cores (140 Milions of cell / 30k cells per core = ~4500cores)

  * `-platform=intel` This parameter tells Fluent to use an `AVX2` optimized binary. You can get up to **10-15% better performance** by using AVX2 instructions.
  * `-mpi=intel` This parameter specifies the MPI implementation. At the moment, `IntelMPI` is the MPI library that offer better performance on AWS.
  * `-t` This parameter specifies the number of cores used to run the simulation.

# Performance

This section shows the benchmark results of Fluent v241 running a public dataset called f1_racecar_140m.<br>
This case is an external flow over a Formula-1 Race car. The case has around 140 million Hex-core cells and uses the realizable k-e turbulence model and the Pressure based coupled solver, Least Squares cell based, pseudo transient solver.<br>
For more information about Fluent benchmarks please refer to the [official web page](https://www.ansys.com/it-solutions/benchmarks-overview).<br>

**_NOTE:_**  The "Rating" shown in the chatrs below is defined as the number of benchmarks that can be run on a given machine (in sequence) in a 24 hour period. <br>
It is computed by dividing the number of seconds in a day (86400 seconds) by the number of seconds required to run the benchmark. A higher rating means faster performance.
<br><br>
This chart shows the per-core performance of Fluent running the f1_racecar_140m on all the different sizes of the AWS EC2 [Hpc7a](https://aws.amazon.com/ec2/instance-types/hpc7a/) Instances.
![ANSYS Fluent f1_racecar_140m X core Performance on AMD-based instances](https://github.com/aws-samples/hpc-applications/blob/main/Doc/img/Fluent/f1_racecar_140mXcoreAMD.png?raw=true)
<br><br>
This chart shows the per-core performance at scale of Fluent running the f1_racecar_140m on AWS EC2 [Hpc7a](https://aws.amazon.com/ec2/instance-types/hpc7a/) Vs. [Hpc6a](https://aws.amazon.com/ec2/instance-types/hpc6a/) Instances
![ANSYS Fluent f1_racecar_140m X core Performance at scale](https://github.com/aws-samples/hpc-applications/blob/main/Doc/img/Fluent/f1_racecar_140mXcoreAtScaleAMD.png?raw=true)
<br><br>
This chart shows the per-instance performance of Fluent running the f1_racecar_140m on AWS EC2 [Hpc7a](https://aws.amazon.com/ec2/instance-types/hpc7a/) and [Hpc6a](https://aws.amazon.com/ec2/instance-types/hpc6a/) Instances
![ANSYS Fluent f1_racecar_140m X instance Performance](https://github.com/aws-samples/hpc-applications/blob/main/Doc/img/Fluent/f1_racecar_140mXinstanceAMD.png?raw=true)
<br><br>
This chart shows the per-instance performance of Fluent running the f1_racecar_140m on AWS EC2 [Hpc6id](https://aws.amazon.com/ec2/instance-types/hpc6i/) and [c5n](https://aws.amazon.com/it/ec2/instance-types/c5/) Instances
![ANSYS Fluent f1_racecar_140m X instance Performance](https://github.com/aws-samples/hpc-applications/blob/main/Doc/img/Fluent/f1_racecar_140mXinstanceINTEL.png?raw=true)

