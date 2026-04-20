## AWS Parallel Computing Service (PCS)

[AWS Parallel Computing Service](https://aws.amazon.com/pcs/) (PCS) is a managed service that makes it easy to set up and manage high performance computing (HPC) clusters on AWS. <br>
PCS handles the provisioning and management of the Slurm scheduler, compute nodes, and networking, so you can focus on running your HPC workloads. <br>

### What's included

These CloudFormation templates create a PCS cluster with:
- Multiple HPC-optimized compute queues (hpc8a, hpc7a, hpc6id, hpc6a)
- A login node for interactive access via SSM Session Manager
- FSx for Lustre shared filesystem mounted at `/fsx`
- EFS-backed shared `/home` directory
- Passwordless SSH between login and compute nodes
- Support for custom AMIs with Intel MPI pre-installed

### Build your cluster using CloudFormation (1-Click)

Select your preferred AWS Region among the supported ones. You will be asked a few questions about Networking, Storage, and AMI; <br>
If you have no idea how to answer or what these services are, just leave the default values: `AUTO`. <br>
The 1-Click deployment procedure will take care of creating everything needed for your PCS Cluster to run properly. <br>
<br>

| Region       | Type | Launch                                                                                                                                                                                                                                                                                                             |
|--------------| --- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| US  | --- | --- |
| Ohio (us-east-2) | x86 | [![Launch](https://samdengler.github.io/cloudformation-launch-stack-button-svg/images/us-east-2.svg)](https://us-east-2.console.aws.amazon.com/cloudformation/home?region=us-east-2#/stacks/quickcreate?templateURL=https%3A%2F%2Fhpc-applications-best-practice.s3.eu-west-1.amazonaws.com%2Fus-east-2.x86.pcs.yaml&stackName=hpc-pcs&param_PrivateSubnet=AUTO&param_FSx=AUTO&param_ClusterSecurityGroup=AUTO&param_CustomAmi=AUTO) |
| EU  | --- | --- |
| Stockholm (eu-north-1) | x86 | [![Launch](https://samdengler.github.io/cloudformation-launch-stack-button-svg/images/eu-north-1.svg)](https://eu-north-1.console.aws.amazon.com/cloudformation/home?region=eu-north-1#/stacks/quickcreate?templateURL=https%3A%2F%2Fhpc-applications-best-practice.s3.eu-west-1.amazonaws.com%2Feu-north-1.x86.pcs.yaml&stackName=hpc-pcs&param_PrivateSubnet=AUTO&param_FSx=AUTO&param_ClusterSecurityGroup=AUTO&param_CustomAmi=AUTO) |

<br>

> **_NOTE:_** When `CustomAmi` is set to `AUTO`, the template will build a custom AMI using EC2 Image Builder with Intel MPI pre-installed. This adds approximately 30-45 minutes to the initial stack creation time. To skip the AMI build, provide an existing AMI ID.

> **_NOTE:_** The cluster size is set to `SMALL` (up to 24 managed instances). Each compute queue supports up to 3 instances. For larger deployments, modify the `Size` and `MaxInstanceCount` values in the template.

<br>

### Build a custom AMI separately

If you prefer to build the AMI independently (recommended for faster cluster deployments), use the Image Builder template:

```bash
aws cloudformation deploy \
  --stack-name pcs-ami-build \
  --template-file PCS/ami/create-pcs-image.yaml \
  --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
  --region us-east-2
```

Once the AMI is built, retrieve its ID and pass it as the `CustomAmi` parameter when deploying the cluster template.

See [PCS/ami/README.md](ami/README.md) for more details.

<br>

### Connecting to the cluster

After the CloudFormation stack is completed, go to the `Output` tab to find:
- `PcsConsoleUrl` — Link to the PCS console for your cluster
- `LoginNodeSsmCommand` — CLI command to connect to the login node via SSM Session Manager

You can also connect directly from your terminal:

```bash
aws ec2 describe-instances \
  --region <REGION> \
  --filters "Name=tag:Name,Values=pcs-login-<STACK_NAME>" "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].InstanceId" --output text \
  | xargs -I {} aws ssm start-session --region <REGION> --target {}
```

You will find the FSx for Lustre filesystem mounted at `/fsx` and a shared `/home` directory backed by EFS.
