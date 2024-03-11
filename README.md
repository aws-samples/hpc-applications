## HPC Application Best Practices on AWS

This repository contains HPC application best practices, specifically designed and optimized to run on AWS.<br>
In particular, these best practices take into account the peculiarity of AWS HPC specific services and EC2 instances, in order to get the best out of them.<br>
This Repository is mainteined by AWS HPC Solution Architects, which will take care of updating and improving these best practices as new AWS HPC services are released or new settings/tuning are discovered.<br>
This Repository is not intended to be an AWS supported product or service.<br>

# AWS HPC Services being used
 * [AWS ParallelCluster](https://aws.amazon.com/hpc/parallelcluster/) and its [Documentation](https://docs.aws.amazon.com/parallelcluster/latest/ug/what-is-aws-parallelcluster.html)
 * [Elastic Fabric Adapter](https://aws.amazon.com/hpc/efa/) (EFA) and its [Documentation](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa.html)
 * [Amazon FSx for Lustre](https://aws.amazon.com/fsx/lustre/) and its [Documentation](https://docs.aws.amazon.com/fsx/latest/LustreGuide/what-is.html)
 * AWS EC2 [Hpc7a](https://aws.amazon.com/ec2/instance-types/hpc7a/) Instances
 * AWS EC2 [Hpc6id](https://aws.amazon.com/ec2/instance-types/hpc6i/) Instances
 * AWS EC2 [Hpc7g](https://aws.amazon.com/ec2/instance-types/hpc7g/) Instances

# HPC Application best practices supported:

1. [Fluent](https://github.com/aws-samples/hpc-applications/tree/main/apps/Fluent)
2. [Abaqus](https://github.com/aws-samples/hpc-applications/tree/main/apps/Abaqus)
3. [LS-Dyna](https://github.com/aws-samples/hpc-applications/tree/main/apps/LS-Dyna)
4. [Optistruct](https://github.com/aws-samples/hpc-applications/tree/main/apps/Optistruct)
5. [Starccm+](https://github.com/aws-samples/hpc-applications/tree/main/apps/Starccm)

**_NOTE:_**  This list is being updated with additional application best practices on a constant basis.

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This library is licensed under the MIT-0 License. [See the LICENSE file](LICENSE).

