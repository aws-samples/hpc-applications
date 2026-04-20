# PCS HPC-Ready AMI with Intel MPI

This directory contains a CloudFormation template (`create-pcs-image.yaml`) that uses [EC2 Image Builder](https://aws.amazon.com/image-builder/) to build a custom AWS PCS AMI with Intel MPI, following the best practices from the [aws-hpc-recipes](https://github.com/aws-samples/aws-hpc-recipes/tree/main/recipes/pcs/hpc_ready_ami) project.

## What's Installed

All components from the [HPC-ready AMI recipe](https://github.com/aws-samples/aws-hpc-recipes/tree/main/recipes/pcs/hpc_ready_ami):
- OS updates and HPC performance optimizations
- CloudWatch and SSM agents
- EFA driver and libraries
- Lustre and EFS clients
- PCS agent and Slurm
- Spack package manager

Plus:
- Intel MPI (from Intel oneAPI repository) with environment module support (`module load intelmpi`)

## Supported Distributions

- Amazon Linux 2
- Amazon Linux 2023
- Ubuntu 22.04

## Build

```bash
aws cloudformation deploy \
  --stack-name pcs-ami-build \
  --template-file PCS/ami/create-pcs-image.yaml \
  --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
  --region us-east-2 \
  --parameter-overrides \
    Distro=amzn-2023 \
    Architecture=x86
```

The AMI build takes approximately 30-45 minutes. Once complete, retrieve the AMI ID from the stack outputs:

```bash
aws cloudformation describe-stacks \
  --stack-name pcs-ami-build \
  --region us-east-2 \
  --query 'Stacks[0].Outputs[?OutputKey==`AmiId`].OutputValue' \
  --output text
```

## Integration with PCS Cluster Template

The main PCS CloudFormation templates (`PCS/CloudFormation/*.yaml`) can build this AMI automatically. Set the `CustomAmi` parameter to `AUTO` (the default) and the AMI will be built as a nested stack. Pass an existing AMI ID to skip the build.
