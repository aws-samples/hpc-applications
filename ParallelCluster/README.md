## AWS ParallelCluster

Today we have implemented our HPC Application Best Practice using [AWS ParallelCluster](https://aws.amazon.com/hpc/parallelcluster/). <br>
AWS ParallelCluster is an open source cluster management tool that makes it easy for you to deploy and manage High Performance Computing (HPC) clusters on AWS. <br>
ParallelCluster offer a simple graphical user interface [GUI](https://docs.aws.amazon.com/parallelcluster/latest/ug/pcui-using-v3.html) or text file to model and provision the resources needed for your HPC applications in an automated and secure manner. <br>
It also supports multiple instance types and job submission queues, and job schedulers like AWS Batch and Slurm.<br>
<br>

### Build your cluster using the CLI
You can build your cluster using the AWS ParallelCluster [CLI](https://docs.aws.amazon.com/parallelcluster/latest/ug/pcluster-v3.html). <br> 
Find example ParallelCluster configuration files under the [config](config) directory. <br>
This configuration files are not working examples as they need you to replace a few tokens (like `subnet-1234567890` or `sg-1234567890`) with the resources you want to use on your AWS account.<br>

### Build your clsuster using CloudFormation (1-Click)
In addition, we have build a few working [CloudFormantion](https://aws.amazon.com/cloudformation/) templates that help you to create a new HPC cluster with just 1-Click.<br>
Select your preferred AWS Region among the supported ones. You will be asked a few questions about Networking and Storage; <br>
If you have no idea how to answer or what these services are, just leave the detault values: `AUTO`. <br>
The 1-Click deployment procedure will take care of creating everything needed for your HPC Cluster to run properly.<br>
<br>

| Region       | Type | Launch                                                                                                                                                                                                                                                                                                             | 
|--------------| --- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| US  | --- | --- |
| N. Virginia (us-east-1) | Arm | [![Launch](https://samdengler.github.io/cloudformation-launch-stack-button-svg/images/us-east-1.svg)](https://us-east-1.console.aws.amazon.com/cloudformation/home?region=us-east-1#/stacks/quickcreate?templateURL=https%3A%2F%2Fhpc-applications-best-practice.s3.eu-west-1.amazonaws.com%2Fus-east-1.Arm.yaml&stackName=hpc-best-practice&param_PrivateSubnet=AUTO&param_FSx=AUTO&param_ClusterSecurityGroup=AUTO) |
| Ohio (us-east-2) | x86 | [![Launch](https://samdengler.github.io/cloudformation-launch-stack-button-svg/images/us-east-2.svg)](https://us-east-2.console.aws.amazon.com/cloudformation/home?region=us-east-2#/stacks/quickcreate?templateURL=https%3A%2F%2Fhpc-applications-best-practice.s3.eu-west-1.amazonaws.com%2Fus-east-2.x86.yaml&stackName=hpc-best-practice&param_PrivateSubnet=AUTO&param_FSx=AUTO&param_ClusterSecurityGroup=AUTO) |
| EU  | --- | --- |
| Stockholm (eu-north-1)    | x86 | [![Launch](https://samdengler.github.io/cloudformation-launch-stack-button-svg/images/eu-north-1.svg)](https://eu-north-1.console.aws.amazon.com/cloudformation/home?region=eu-north-1#/stacks/quickcreate?templateURL=https%3A%2F%2Fhpc-applications-best-practice.s3.eu-west-1.amazonaws.com%2Feu-north-1.x86.yaml&stackName=hpc-best-practice&param_PrivateSubnet=AUTO&param_FSx=AUTO&param_ClusterSecurityGroup=AUTO) |
| Stockholm (eu-north-1)    | GPU | [![Launch](https://samdengler.github.io/cloudformation-launch-stack-button-svg/images/eu-north-1.svg)](https://eu-north-1.console.aws.amazon.com/cloudformation/home?region=eu-north-1#/stacks/quickcreate?templateURL=https%3A%2F%2Fhpc-applications-best-practice.s3.eu-west-1.amazonaws.com%2Feu-north-1.GPU.yaml&stackName=hpc-best-practice&param_PrivateSubnet=AUTO&param_FSx=AUTO&param_ClusterSecurityGroup=AUTO) |
| Ireland (eu-west-1)       | x86 | [![Launch](https://samdengler.github.io/cloudformation-launch-stack-button-svg/images/eu-west-1.svg)](https://console.aws.amazon.com/) |
| Ireland (eu-west-1)       | Arm | [![Launch](https://samdengler.github.io/cloudformation-launch-stack-button-svg/images/eu-west-1.svg)](https://console.aws.amazon.com/) |
| APJ | --- | --- |
| Tokyo (ap-northeast-1) | x86 | [![Launch](https://samdengler.github.io/cloudformation-launch-stack-button-svg/images/ap-northeast-1.svg)](https://console.aws.amazon.com/) |

<br>
<br>
After the CloudFormation stack is completed you can go to the `Output` tab and click on the `SystemManagerUrl` link. <br>
This link will let you access the HeadNode via SystemManager without using any password or certificate. <br>
(see the image below)

![CloudFormation Output Tab](https://github.com/aws-samples/hpc-applications/blob/main/Doc/img/CloudFormationOutput.png?raw=true)
