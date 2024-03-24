# ANSYS Fluent

ANSYS [Fluent](https://www.ansys.com/products/fluids/ansys-fluent) (Fluent) is general-purpose computational fluid dynamics (CFD) software used to model fluid flow, heat and mass transfer, chemical reactions, and more. 
Developed by [ANSYS](https://www.ansys.com/) it offers support for CPU (x86) and GPU solvers. An Arm-based version that will run on AWS Graviton is under development and available as a beta from Ansys.

# Versions

In this repository we will provide best practices for all the Fluent versions starting from 2020 and newer.
For Fluent version 2019 (v195) and older please refer to this [Blog Post](https://aws.amazon.com/it/blogs/compute/running-ansys-fluent-on-amazon-ec2-c5n-with-elastic-fabric-adapter-efa/)

Fluent supports CPU and GPU solvers. Please refer to:
  * [This example script for CPU-based simulations](https://github.com/aws-samples/hpc-applications/blob/main/apps/Fluent/x86/Fluent.sbatch)
  * [This example script for GPU-based simulations](https://github.com/aws-samples/hpc-applications/blob/main/apps/Fluent/gpu/Fluent-GPU.sbatch)

**_NOTE:_**  We will provide best practices for AWS Graviton instances as soon as Fluent will officially support ARM-based cpus.


# Installation

Fluent is a software suite available on Windows and on Linux. <br>
In this repository we will share an example script to install Fluent on a Linux system.<br>
Fluent installation is relatively easy. You can have a look at [this example script](https://github.com/aws-samples/hpc-applications/blob/main/apps/Fluent/Fluent-Install.sh) to create your own installation procedure, or you can execute this script as follow:

```
./Fluent-Install.sh /fsx s3://your_bucket/FLUIDSTRUCTURES_2022R1_LINX64.tgz
```

  * The first parameter is the root base directory where you want to install Fluent.
  * The second parameter is the s3 URI where you have stored your FLuent installation file.

<br>

For running Fluent as a multi-node job, it is required to install Fluent in a shared directory, possibly a parallel file system.<br>
We would strongly recommend to use [Amazon FSx for Lustre](https://aws.amazon.com/fsx/lustre/), more info in the official [documentation](https://docs.aws.amazon.com/fsx/latest/LustreGuide/what-is.html) .

# Key settings & tips (performance related ones) :

  * Fluent is a compute and memory bandwidth bound code. 
    * the best instance types for running it are the ones with higher amount of cores, and higher memory bandwidth per core.
    * As of today, the instance that shows the **best price/performance** is the [Hpc7a](https://aws.amazon.com/ec2/instance-types/hpc7a/) .
  * Fluent is a software that scales very well: the simulation time decreases proportionally to the numbrer of cores being used.
    * It is possible to achieve (almost) linear scaling by solving a mesh using max. between **30k-50k cells per core**.
    * This range is influenced by the complexity of your simulation and the phisics of your models. 

  * `-platform=intel` This parameter tells Fluent to use an `AVX2` optimized binary. You can get up to 10-15% better performance by using AVX2 instructions.
  * `-mpi=intel` This parameter specifies the MPI implementation. At the moment, `IntelMPI` offer better performance on AWS.
  * `-t` his parameter specifies number of processors used to run your simulation.

# Performance

This section shows the benchmark results of Running Fluent v241 running a public dataset called f1_racecar_140m.<br>
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

