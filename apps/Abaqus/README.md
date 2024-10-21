# Abaqus

[Abaqus](https://www.3ds.com/products-services/simulia/products/abaqus/) is a software suite for finite element analysis and computer-aided engineering developed by [Dassault System](https://www.3ds.com/) (DS).

Abaqus is part of the [Simulia](https://www.3ds.com/products-services/simulia/) product suite. It consists of various core software products aimed at accelerating the process of evaluating the performance, reliability, and safety of materials and products before committing to physical prototypes.

This repository focuses on 2 specific software:

 * Abaqus/Standard (or Implicit), a general-purpose finite-element analyzer that employs an implicit integration scheme (traditional).
 * Abaqus/Explicit, a special-purpose finite-element analyzer that employs an explicit integration scheme to solve highly nonlinear systems with many complex contacts under transient loads.

# Versions

In this repository we will provide best practices for the following Abaqus versions 2021 (and newer)


# Installation

The Abaqus installer only supports a few selected types of Linux operating systems. [ `RHEL` `CentOS` and `SUSE`] <br>
Abaqus is typically distributed as `tar` files.<br>
For example Abaqus 2021 is comprised of 5 tar files named like `2021.AM_SIM_Abaqus_Extend.AllOS.1-5.tar ... 2021.AM_SIM_Abaqus_Extend.AllOS.5-5.tar` .<br>
Uncompress them with `tar xvf 2021.AM_SIM_Abaqus_Extend.AllOS.1-5.tar ... 2021.AM_SIM_Abaqus_Extend.AllOS.5-5.tar` .<br>
In order to install Abaqus go into `AM_SIM_Abaqus_Extend.AllOS/1`; The Abaqus installation process is interactive and can be done via terminal by running `./StartTUI.sh` or via graphical interface `./StartGUI.sh`
<br><br>
The Installer will ask you to choose the installation directory and will suggest `/usr/SIMULIA/EstProducts/<Abaqus_version>`, please change that to you shared Filesystem ([Amazon FSx for Lustre](https://aws.amazon.com/fsx/lustre/)), like `/fsx/SIMULIA/EstProducts/<Abaqus_version>`
<br>
Same for the `CAE commands directory path`, please change the suggested dir `/var/DassaultSystemes/SIMULIA/Commands` to `/fsx/DassaultSystemes/SIMULIA/Commands`
<br>
and for the `SIMULIA Established Products` please change `/var/DassaultSystemes/SIMULIA/CAE/plugins/<Abaqus_version>` to `/fsx/DassaultSystemes/SIMULIA/CAE/plugins/<Abaqus_version>`
<br><br>
Even if it works, at the moment [Amazon Linux 2](https://aws.amazon.com/amazon-linux-2/) (AL2) is not one of the supported Operating Systems. 
<br> If you are planning to install Abaqus on AL2 (or in general on an un-supported operating system) you need to work around the installer.

```bash
export DSY_Force_OS=linux_a64
export DSYAuthOS_`lsb_release --short --id | sed 's/ //g'`=1

..
...
#then

./StartTUI.sh 

```

**_NOTE:_**  For the full Abaqus installation guide, please refer to the official documentation.

#  Key settings & tips (performance related ones) :

  * Abaqus is a memory and (for Standard/Implicit simulations) IO bound code. So the best instance types are the ones with high memory per-core ratio (8:1 or 16:1). This would allow `in-core` simulations.
  * Abaqus Standard/Implicit can also benefit from fast IO, see below how to use the local NVMe disk (when available) of some AWS EC2 instances for the Abaqus scratch.
    * The best instance type for running Abaqus Standard/Implicit simulations is [Hpc6id](https://aws.amazon.com/ec2/instance-types/hpc6i) .
    * The best instance type for running Abaqus Explicit simulations is [Hpc7a](https://aws.amazon.com/ec2/instance-types/hpc7a) .
  

Abaqus key settings are stored and managed in the Abaqus configuration file **abaqus_v6.env** file. 

This file needs to be stored in the job execution directory. 
Below you can find an **abaqus_v6.env** file example:

```bash
license_server_type=DSLS
dsls_license_config="/fsx/DassaultSystemes/Licenses/DSLicSrv.txt"
mp_rsh_command='ssh -n -l %U %H %C'
mp_host_list=[['compute-od-1-dy-hpc6id-32xlarge-2',64],['compute-od-1-dy-hpc6id-32xlarge-3',64]]
mp_host_split=4
mp_mpi_implementation = IMPI
verbose=0
cpus=128
mp_mpirun_path = {IMPI: "/opt/intel/mpi/2021.6.0/bin/mpirun"}
mp_mpirun_options='-bootstrap ssh'
scratch="/scratch"
mp_mode = MPI
standard_parallel = ALL
```

The most important parameters are:
  * `mp_host_list` This variable defines the host (and the amount of available core per host) to be used for the simulation.
  * `cpus` This variable defines the total number of core being used. It might be different from the total amount of cores available from `mp_host_list`
  * `mp_mpi_implementation` This variable defines the MPI library being used
  * `mp_mpirun_path` while this one contains the path of a custom MPI library.
  * `mp_mpirun_options` This variable contains the MPI parameters to pass to the MPI executable.
  * `mp_host_split` Should be set to an integer equal to the desired number of MPI processes to run on each node.
  * `scratch` This variable defines the path of the scratch directory being used in the Implicit simulation only. This is typically set to the local NVME disk or on FSx for Lustre.


**_NOTE:_**  For the full Abaqus guide please refer to the official documentation.


# Performance

This section shows the benchmark results of Abaqus 2024 running common datasets for Standard/Implicit and Explicit simulations: `s4e` , `s9` , `e14_DropTest_v0` , and `e13` <br>
For more information about these benchmarks please refer to the Abaqus offical documentation.<br>

**_NOTE:_**  The benchmark results are based on wallclock time normalized.

## s4e

<br><br>
This chart shows the per-core performance of Abaqus 2024 running the s4e on all the different sizes of the AWS EC2 [Hpc7a](https://aws.amazon.com/ec2/instance-types/hpc7a/) Instances.
![Abaqus 2024 X core Performance on AMD-based instances](https://github.com/aws-samples/hpc-applications/blob/main/Doc/img/Abaqus/Abaqus-s4e-Hpc7a.png)
<br><br>
This chart shows the per-core performance of Abaqus 2024 running the s4e on older and newr generation of Intel-based AWS EC2 [Hpc6id](https://aws.amazon.com/ec2/instance-types/hpc6id/) Instances.
![Abaqus 2024 X core Performance on Intel-based instances](https://github.com/aws-samples/hpc-applications/blob/main/Doc/img/Abaqus/Abaqus-s4e-Hpc6id.png)
<br><br>
This chart shows the per-core performance of Abaqus 2024 running the s4e on older and newr generation of AMD-Based AWS EC2 [Hpc7a](https://aws.amazon.com/ec2/instance-types/hpc6a/) Instances.
![Abaqus 2024 X core Performance on AMD-based instances](https://github.com/aws-samples/hpc-applications/blob/main/Doc/img/Abaqus/Abaqus-s4e-Hpc7aVsHpc6a.png)

## s9

TBC

## e14_DropTest_v0

TBC

## e13

TBC