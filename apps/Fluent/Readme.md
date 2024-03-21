# ANSYS Fluent

ANSYS [Fluent](https://www.ansys.com/products/fluids/ansys-fluent) is general-purpose computational fluid dynamics (CFD) software used to model fluid flow, heat and mass transfer, chemical reactions, and more. 
Developed by [ANSYS](https://www.ansys.com/) it offers support for CPU (x86) and GPU solvers. An Arm-based version that will run on AWS Graviton is under development and available as a beta from Ansys.

# Versions

In this repository we will provide best practices for the following Fluent versions:
 * [2019](https://)
 * [2021](https://)
 * [2022](https://)
 * [2023](https://) 

# Installation

.....


# Key settings

.....


# Performance

This section shows the benchmark results of Running ANSYS Fluent v241 running a public dataset called f1_racecar_140m.<br>
This case is an external flow over a Formula-1 Race car. The case has around 140 million Hex-core cells and uses the realizable k-e turbulence model and the Pressure based coupled solver, Least Squares cell based, pseudo transient solver.<br>
For more information about ANSYS Fluent benchmarks please refer to the [official web page](https://www.ansys.com/it-solutions/benchmarks-overview).<br>

**_NOTE:_**  The "Rating" shown in the chatrs below is defined as the number of benchmarks that can be run on a given machine (in sequence) in a 24 hour period. <br>
It is computed by dividing the number of seconds in a day (86400 seconds) by the number of seconds required to run the benchmark. A higher rating means faster performance.<br><br>

This chart shows the per-core performance of ANSYS Fluent running the f1_racecar_140m on all the different sizes of the AWS EC2 [Hpc7a](https://aws.amazon.com/ec2/instance-types/hpc7a/) Instances.
![ANSYS Fluent f1_racecar_140m X core Performance on AMD-based instances](https://github.com/aws-samples/hpc-applications/blob/main/Doc/img/Fluent/f1_racecar_140mXcoreAMD.png?raw=true)

This chart shows the per-core performance at scale of ANSYS Fluent running the f1_racecar_140m on AWS EC2 [Hpc7a](https://aws.amazon.com/ec2/instance-types/hpc7a/) Instances Vs. [Hpc6a](https://aws.amazon.com/ec2/instance-types/hpc6a/) Instances
![ANSYS Fluent f1_racecar_140m X core Performance at scale](https://github.com/aws-samples/hpc-applications/blob/main/Doc/img/Fluent/f1_racecar_140mXcoreAtScaleAMD.png?raw=true)

This chart shows the per-instance performance of ANSYS Fluent running the f1_racecar_140m on AWS EC2 [Hpc7a](https://aws.amazon.com/ec2/instance-types/hpc7a/) Instances and [Hpc6a](https://aws.amazon.com/ec2/instance-types/hpc6a/) Instances
![ANSYS Fluent f1_racecar_140m X instance Performance](https://github.com/aws-samples/hpc-applications/blob/main/Doc/img/Fluent/f1_racecar_140mXinstanceAMD.png?raw=true)
