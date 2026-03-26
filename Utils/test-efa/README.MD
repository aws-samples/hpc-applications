# Test EFA

**Elastic Fabric Adapter [(EFA)](https://aws.amazon.com/hpc/efa/)** is a network interface for Amazon EC2 instances that enables customers to run applications requiring high levels of inter-node communications at scale on AWS.

This directory contains instructions and scripts to help you verify that EFA is functioning correctly.

Before you begin, ensure you have a working **Slurm** cluster in AWS.

## Check if your instance type is supported by EFA

Run this command to get a list of all EC2 instance types that support EFA in your target Region.
In this example, we target the Ireland Region (eu-west-1). Replace the `--region` flag with your preferred Region.

```bash
aws ec2 describe-instance-types \
  --filters "Name=network-info.efa-supported,Values=true" \
  --region eu-west-1 \
  --query "InstanceTypes[*].InstanceType" \
  --output table
```

## Check if EFA is correctly installed

Follow the [EFA installation instructions](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa-start.html#efa-start-test) to verify that EFA is correctly installed.

## Run a test job

1. Log in to your Slurm cluster, download this example MPI code, and compile it:

```bash
wget -c https://raw.githubusercontent.com/mpitutorial/mpitutorial/gh-pages/tutorials/mpi-send-and-receive/code/ring.c
module load intelmpi
mpicc ring.c -o ring.exe
```

If you are compiling on an ARM-based instance, use OpenMPI instead:

```bash
wget -c https://raw.githubusercontent.com/mpitutorial/mpitutorial/gh-pages/tutorials/mpi-send-and-receive/code/ring.c
module load openmpi5
mpicc ring.c -o ring.exe
```

2. Run the test MPI job

Copy the compiled `ring.exe` file to a location accessible from all compute nodes (for example, a shared file system). The sbatch scripts run `mpirun ./ring.exe` from the job's working directory, so place `ring.exe` there or edit the `mpirun` line in the script to point to the correct path.

Submit the test job:

```bash
sbatch -n 200 testefa.sbatch
```

If you are running on ARM-based instances, use the ARM-specific script instead:

```bash
sbatch -n 200 testefa-arm.sbatch
```

This example spans the job across 200 cores (`-n 200`). Feel free to adjust the core count, but use enough cores to span at least two compute nodes.

The job captures the number of bytes received through the EFA device before and after the MPI run. In the job output file, verify that `recv_bytes` is higher after the job completes than before it started.

For example:

```bash
Loading intelmpi version 2021.9.0
recv_bytes before the mpi job:
872
5552

// [SNIP]
// here you will find the MPI logs
// ...

recv_bytes after the mpi job:
49084
26612
```

In this example, `recv_bytes` increased from 872 to 49084, confirming that network traffic flowed through the EFA device. Notice that two values appear (872 and 5552 before, 49084 and 26612 after). This is because the example uses Hpc7a instances, which come with two EFA-powered network cards.
