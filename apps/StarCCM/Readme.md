# STAR-CCM+

[Siemens Simcenter STAR-CCM+](https://plm.sw.siemens.com/en-US/simcenter/fluids-thermal-simulation/star-ccm/) is a multiphysics computational fluid dynamics (CFD) simulation software that enables engineers to model the complexity and explore the possibilities of products operating under real-world conditions. Recent software versions have included the capability to carry out Finite Element Analysis studies, and other physics phenomena that can be modelled in the software include battery and combustion modelling.

# Versions

There are 3 releases of STAR-CCM+ per year. There are also now 3 different builds; x86, GPGPU and Arm. While submit scripts are mostly common across versions, there are nuances to each to consider.

# Installation

STAR-CCM+ works on many flavours of Linux, but by default is only supported on a small number of them. Even though it's not officially supported, it runs on Amazon Linux 2, *except* for the Arm builds where glibc libraries on AL2 are out of date and thus RHEL8 or Ubuntu 20 should be used. Note that as of STAR-CCM+ 2402 (19.02) and onwards, glibc versions above 2.26 are required.

To install on a non-GUI based cluster,  the following command can be used:
`./STAR-CCM+_installer_.sh -i console -DPRODUCTEXCELLENCEPROGRAM=0 -DINSTALLDIR=/fsx/Siemens -DINSTALLFLEX=false -DADDSYSTEMPATH=true -DNODOC=false`
This will provide a fast install to the specified location (/fsx/Siemens), without the license server or documentation being installed (the latter of which makes up a large chunk of the install size but may be useful).

# License

AWS does not have STAR-CCM+ licenses hosted on a license server. A few people have their own individual keys, the use of which has to be accounted for. If you need one, reach out to an HPC SSA. Note that the license request must be supported by an end-customer request (for example due to a POC and/or a RFx).