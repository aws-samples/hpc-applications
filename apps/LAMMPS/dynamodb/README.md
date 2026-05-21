# LAMMPS — DynamoDB result store (optional)

This directory contains the optional helper that records every LAMMPS benchmark run to a centralised DynamoDB table. It is **not** required to build or run LAMMPS — the benchmark scripts in [`x86/`](../x86/) and [`Arm/`](../Arm/) source [`record_to_dynamodb.sh`](record_to_dynamodb.sh) at the very end of the run, and skip it gracefully if the script (or the table, or the IAM permission) isn't available.

If you don't care about cross-run aggregation, you can simply delete this directory or skip it during deployment.

## Why a separate table

Tracking benchmark results in DynamoDB makes it easy to:

- Compare runs across instance types, node counts, models, and software versions over time
- Generate dashboards or charts without re-running jobs
- Detect performance regressions when MPI / libfabric / kernel versions change
- Share a single index of results across team members and clusters

## Table schema

- **Table:** `LAMMPS_Benchmarks` in `us-east-1`
- **Partition key:** `job_id` (S) — the Slurm job ID
- **Sort key:** `config` (S) — `<nodes>N-<rpn>rpn-<model>-s<scale>` (e.g. `4N-192rpn-rhodo-s1`)
- **Billing:** on-demand

### Item attributes

| Field | Type | Description |
|-------|------|-------------|
| `job_id` | S | Slurm job ID (partition key) |
| `config` | S | `<nodes>N-<rpn>rpn-<model>-s<scale>` (sort key) |
| `timestamp` | S | ISO 8601 UTC timestamp |
| `model` | S | `lj` / `rhodo` / `eam` |
| `scale` | N | Lattice replication factor |
| `nodes` | N | Node count |
| `ranks_total` | N | Total MPI ranks |
| `ranks_per_node` | N | MPI ranks per node |
| `threads_per_rank` | N | OpenMP threads per rank |
| `instance_type` | S | EC2 instance type from IMDSv2 |
| `cluster_name` | S | `SLURM_CLUSTER_NAME` |
| `lammps_tag` | S | LAMMPS git tag built from |
| `mpi_stack` | S | `openmpi-4` or `openmpi-5` |
| `mpi_version` | S | `mpirun --version` output |
| `libfabric_version` | S | `fi_info --version` output |
| `efa_version` | S | EFA libfabric provider version |
| `kernel` | S | `uname -r` |
| `os` | S | `/etc/os-release` PRETTY_NAME |
| `pc_version` | S | ParallelCluster cookbook version |
| `region` | S | AWS region from IMDSv2 |
| `atoms` | N | Atoms in the simulation |
| `timesteps` | N | Timesteps actually run (from LAMMPS log) |
| `loop_time_s` | N | LAMMPS Loop time in seconds |
| `timesteps_per_sec` | N | Derived: `timesteps / loop_time_s` |
| `atom_steps_per_sec` | N | Derived: `atoms * timesteps / loop_time_s` |
| `wall_time_s` | N | Total mpirun wall time |
| `workdir` | S | Run directory on FSx |

## Setup

### 1. Create the table

```bash
aws dynamodb create-table \
  --table-name LAMMPS_Benchmarks \
  --attribute-definitions \
      AttributeName=job_id,AttributeType=S \
      AttributeName=config,AttributeType=S \
  --key-schema \
      AttributeName=job_id,KeyType=HASH \
      AttributeName=config,KeyType=RANGE \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1
```

### 2. Grant `dynamodb:PutItem` to your compute node IAM role

Attach the following inline policy to the role used by your compute nodes (e.g. `AWSPCS-...` for AWS PCS, `<stack>-RoleHeadNode-...` and `<stack>-ComputeFleetQueuesNested-Role*-...` for ParallelCluster):

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": "dynamodb:PutItem",
            "Resource": "arn:aws:dynamodb:us-east-1:*:table/LAMMPS_Benchmarks"
        }
    ]
}
```

### 3. Place this script under `/fsx/lammps/scripts/dynamodb/` (or anywhere on shared storage)

The benchmark launchers source it from the same path layout used for the build / benchmark scripts, so a typical setup mirrors this repo's `apps/LAMMPS/` layout under `/fsx/lammps/scripts/`:

```
/fsx/lammps/scripts/
├── x86/lammps-benchmark.sbatch
├── Arm/lammps-benchmark.sbatch
└── dynamodb/record_to_dynamodb.sh    <-- this file
```

If [`record_to_dynamodb.sh`](record_to_dynamodb.sh) isn't present at the expected path the benchmark launcher prints a one-line note and continues — there is no failure path that depends on DynamoDB.

## Failure handling

A failed `aws dynamodb put-item` call is logged as a warning and **does not** fail the job. The local `log.lammps` file and the results block in the slurm output remain the authoritative record for any single run. The `dynamodb_record.json` file is preserved in the workdir so the put can be retried manually:

```bash
aws dynamodb put-item \
  --table-name LAMMPS_Benchmarks \
  --region us-east-1 \
  --item file:///path/to/Run/.../dynamodb_record.json
```

## Disabling DynamoDB recording

Three equivalent ways to skip the DynamoDB step entirely:

1. Don't deploy this directory — the benchmark scripts will fall back to a no-op when the script isn't found at the expected path.
2. Set `DYNAMODB_TABLE=` (empty) in the benchmark submit env.
3. Remove the `dynamodb:PutItem` permission from the compute role — the script will log a warning and exit successfully.
