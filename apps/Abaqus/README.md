# Abaqus

[Abaqus](https://www.3ds.com/products-services/simulia/products/abaqus/) is a software suite for finite element analysis and computer-aided engineering developed by [Dassault System](https://www.3ds.com/) (DS).

Abaqus is part of the [Simulia](https://www.3ds.com/products-services/simulia/) product suite. It consists of various core software products aimed at accelerating the process of evaluating the performance, reliability, and safety of materials and products before committing to physical prototypes.

This repository focuses on 2 specific software:

 * Abaqus/Standard (or Implicit), a general-purpose finite-element analyzer that employs an implicit integration scheme (traditional).
 * Abaqus/Explicit, a special-purpose finite-element analyzer that employs an explicit integration scheme to solve highly nonlinear systems with many complex contacts under transient loads.

# Versions

In this repository we will provide best practices for the following Abaqus versions:
 * [2019](https://)
 * [2021](https://)
 * [2022](https://)
 * [2023](https://) 

# Installation

The Abaqus installer only supports a few selected type of Linux operating systems. 

[Amazon Linux 2](https://aws.amazon.com/amazon-linux-2/) (AL2) is not one of those. So, if you are planning to install Abaqus on AL2 you need to work around the installer.

This is pretty straightforward as the installer checks the operating system being among the supported ones using `lsb_release`. 

All that's needed is to backup the actual `lsb_release` file `sudo mv /usr/bin/lsb_release /usr/bin/lsb_release_OLD`,
and then create a new `lsb_release`, like the following:

```bash
#!/bin/bash

echo "CentOS"
```

Once saved, give it execution permissions. After installation, you can return your backed-up file: `sudo mv /usr/bin/lsb_release_OLD /usr/bin/lsb_release`

The Abaqus installation process is interactive and can be done via terminal by running `./StartTUI.sh` or via graphical interface `./StartGUI.sh`

**_NOTE:_**  For the full Abaqus installation guide, please refer to the official documentation.

# Key settings

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

![Abaqus s4e](https://github.com/aws-samples/hpc-applications/blob/main/Doc/img/Abaqus/s4e.png?raw=true)
