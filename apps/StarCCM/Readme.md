# STAR-CCM+

[Siemens Simcenter STAR-CCM+](https://plm.sw.siemens.com/en-US/simcenter/fluids-thermal-simulation/star-ccm/) is a multiphysics computational fluid dynamics (CFD) simulation software that enables engineers to model the complexity and explore the possibilities of products operating under real-world conditions. Recent software versions have included the capability to carry out Finite Element Analysis studies, and other physics phenomena that can be modelled in the software include battery and combustion modelling.

## Versions

There are 3 releases of STAR-CCM+ per year. There are also now 3 different builds; x86, GPGPU and Arm. While submit scripts are mostly common across versions, there are nuances to each to consider.

## Installation

STAR-CCM+ works on many flavours of Linux, but by default is only supported on a small number of them. Even though it's not officially supported, it runs on Amazon Linux 2, *except* for the Arm builds where glibc libraries on AL2 are out of date and thus RHEL8 or Ubuntu 20 should be used. Note that as of STAR-CCM+ 2402 (19.02) and onwards, glibc versions above 2.26 are required.

To install on a non-GUI based cluster,  the following command can be used:
`./STAR-CCM+_installer_.sh -i console -DPRODUCTEXCELLENCEPROGRAM=0 -DINSTALLDIR=/fsx/Siemens -DINSTALLFLEX=false -DADDSYSTEMPATH=true -DNODOC=false`
This will provide a fast install to the specified location (/fsx/Siemens), without the license server or documentation being installed (the latter of which makes up a large chunk of the install size but may be useful).

## Key Settings

### License

There are multiple ways to license STAR-CCM+. The two most common methods are
- host a local license on a license server
- use Power on Demand which checks out a license from a Siemens hosted license server

Each method has its advantages and disadvantages, however it's worth noting that Power on Demand licenses are significantly easier to use with AWS; the license key can be placed as an argument when launching STAR-CCM+ and - as long as the instance can communicate with the internet - the license gets checked out.

If running a license server, there is a requirement to either have an EC2 instance hosting the license server (for which it is recommended to have a fixed Elastic Network Interface) or to create a VPN connection to the license server running elsewhere. Instructions for using this means of license hosting are to come.

### MPI

While it is possible to use other MPI builds, typical MPI implementations used with STAR-CCM+ are OpenMPI and IntelMPI. Both are bundled with STAR-CCM+, as well as specific versions of each being installed with ParallelCluster on AWS. Once again, there are nuances on which MPI implementation works 'best' for what simulation type or which hardware is in use. Minumum MPI implementation versions will be written for various instance types in future.