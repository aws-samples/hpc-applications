# HPC application best practices on AWS
This repository contains HPC application best practices, specifically designed for, and optimized to run, on AWS.<br>
In particular, these best practices take into account the peculiarity of AWS HPC-specific services and EC2 instances, in order to get the best out of them.<br>
This repo is maintained by AWS HPC Solution Architects, who will take care of updating and improving these best practices as AWS services evolve or new settings/tunings are discovered. This is **not intended** to be an AWS supported product or service, though.<br>

## HPC application Benchmarks
In addition to application best practices, this repo will include some HPC application benchmarks. For all the included applications, we've run some benchmarks using public datasets. We'll publish our data and some charts to show the performance and scalability you should be aiming to achieve.

## AWS HPC products and services being used
 * [AWS ParallelCluster](https://aws.amazon.com/hpc/parallelcluster/) and its [Documentation](https://docs.aws.amazon.com/parallelcluster/latest/ug/what-is-aws-parallelcluster.html)
 * [Elastic Fabric Adapter](https://aws.amazon.com/hpc/efa/) (EFA) and its [Documentation](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa.html)
 * [Amazon FSx for Lustre](https://aws.amazon.com/fsx/lustre/) and its [Documentation](https://docs.aws.amazon.com/fsx/latest/LustreGuide/what-is.html)
 * AWS EC2 [Hpc7a](https://aws.amazon.com/ec2/instance-types/hpc7a/) Instances
 * AWS EC2 [Hpc6a](https://aws.amazon.com/ec2/instance-types/hpc6a/) Instances
 * AWS EC2 [Hpc6id](https://aws.amazon.com/ec2/instance-types/hpc6i/) Instances
 * AWS EC2 [Hpc7g](https://aws.amazon.com/ec2/instance-types/hpc7g/) Instances

## HPC application best practices included:
1. [Fluent](https://github.com/aws-samples/hpc-applications/tree/main/apps/Fluent)
2. [Abaqus](https://github.com/aws-samples/hpc-applications/tree/main/apps/Abaqus)
3. [LS-Dyna](https://github.com/aws-samples/hpc-applications/tree/main/apps/LS-Dyna)
4. [Optistruct](https://github.com/aws-samples/hpc-applications/tree/main/apps/Optistruct)
5. [STAR-CCM+](https://github.com/aws-samples/hpc-applications/tree/main/apps/StarCCM)

## Request a HPC application best practice

We're starting with the most common HPC applications, specifically in the CAE market.  <br>
We're also updating the list of included HPC application best practice regularly, based on your feedback.<br>
So, feel free to request a new HPC application best practice from the [ISSUES](https://github.com/aws-samples/hpc-applications/issues) .<br>
We will do our best to satisfy your requests.<br>

## 1-Click deployment

If you already have a cluster up&running and you want to try these best practices, then you can just `git clone` this repository:
```
git clone https://github.com/aws-samples/hpc-applications.git
```
<br>
<br>

In case you don't have a cluster ready, you can use the CloudFormation template below to create a new one with just 1-Click.
Select your preferred AWS Region amond the supported ones. You will be asked a few questions about Networking and Storage; 
if you have no idea how to answer or what these services are, just leave the detault values: `AUTO`. 
The 1-Click deployment procedure will take care of creating everything needed for your HPC Cluster to run.

| Region       | Launch                                                                                                                                                                                                                                                                                                             | 
|--------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| US  | --- |
| Ohio (us-east-2)   | [![Launch](https://samdengler.github.io/cloudformation-launch-stack-button-svg/images/us-east-2.svg)](https://console.aws.amazon.com/cloudformation/home?region=us-east-2) |
| EU  |---|
| Stockholm (eu-north-1)   | [![Launch](https://samdengler.github.io/cloudformation-launch-stack-button-svg/images/eu-north-1.svg)](https://eu-north-1.console.aws.amazon.com/cloudformation/home?region=eu-north-1#/stacks/quickcreate?templateURL=https%3A%2F%2Fhpc-applications-best-practice.s3.eu-west-1.amazonaws.com%2Feu-north-1.yaml&stackName=test2&param_PublicSubnetAId=AUTO&param_FSx=AUTO&param_PrivateSubnetAId=AUTO) |
| APJ |---|


## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This library is licensed under the MIT-0 License. [See the LICENSE file](LICENSE).

