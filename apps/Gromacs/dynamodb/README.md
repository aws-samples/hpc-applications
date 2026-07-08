# GROMACS — DynamoDB result store (optional)

This directory contains the optional helper that records every GROMACS benchmark run to a centralised DynamoDB table. It is **not** required to build or run GROMACS — the recorder call site is **commented out by default** in the benchmark scripts under [`x86/`](../x86/) and [`Arm/`](../Arm/), so customers who only want to run GROMACS can ignore this directory entirely.

If you don't care about cross-run aggregation, simply leave the block commented (or delete this directory). The default benchmark scripts will not attempt any DynamoDB calls.

## Why a separate table

Tracking benchmark results in DynamoDB makes it easy to:

- Compare runs across instance types, node counts, models, and software versions over time
- Generate dashboards or charts without re-running jobs
- Detect performance regressions when MPI / libfabric / kernel versions change
- Share a single index of results across team members and clusters

## Table schema

- **Table:** `Gromacs_Benchmarks` in `us-east-1`
- **Partition key:** `job_id` (S) — the Slurm job ID
- **Sort key:** `config` (S) — `<nodes>N-<rpn>rpn-<model>` (e.g. `4N-192rpn-benchMEM`)
- **Billing:** on-demand

### Item attributes

| Field | Type | Description |
|-------|------|-------------|
| `job_id` | S | Slurm job ID (partition key) |
| `config` | S | `<nodes>N-<rpn>rpn-<model>` (sort key) |
| `timestamp` | S | ISO 8601 UTC timestamp |
| `model` | S | `benchMEM` / `benchPEP-h` / `STMV` / `RNAse` |
| `nodes` | N | Node count |
| `ranks_total` | N | Total MPI ranks |
| `ranks_per_node` | N | MPI ranks per node |
| `threads_per_rank` | N | OpenMP threads per rank |
| `instance_type` | S | EC2 instance type from IMDSv2 |
| `cluster_name` | S | `SLURM_CLUSTER_NAME` |
| `gromacs_tag` | S | GROMACS git tag built from |
| `mpi_stack` | S | `tmpi`, `openmpi-4`, or `openmpi-5` |
| `mpi_version` | S | `mpirun --version` output |
| `libfabric_version` | S | `fi_info --version` output |
| `efa_version` | S | EFA libfabric provider version |
| `kernel` | S | `uname -r` |
| `os` | S | `/etc/os-release` PRETTY_NAME |
| `pc_version` | S | ParallelCluster cookbook version |
| `region` | S | AWS region from IMDSv2 |
| `atoms` | N | Atoms in the simulation |
| `nsteps` | N | Timesteps actually run (from `md.log`) |
| `ns_per_day` | N | GROMACS `Performance:` ns/day value |
| `hour_per_ns` | N | GROMACS `Performance:` hour/ns value |
| `wall_time_s` | N | GROMACS `Wall t (s):` value |
| `workdir` | S | Run directory on FSx |
| `gpu_count` | N | Phase 3 only, present when GPU run |
| `cuda_version` | S | Phase 3 only, present when GPU run |

## Setup

### 1. Create the table

```bash
aws dynamodb create-table \
  --table-name Gromacs_Benchmarks \
  --attribute-definitions \
      AttributeName=job_id,AttributeType=S \
      AttributeName=config,AttributeType=S \
  --key-schema \
      AttributeName=job_id,KeyType=HASH \
      AttributeName=config,KeyType=RANGE \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1
```

Wait until the table reaches `ACTIVE` status before submitting any benchmark with the recorder enabled — `put-item` calls against a `CREATING` table fail. Either poll with `describe-table` or use the built-in waiter:

```bash
aws dynamodb wait table-exists \
  --table-name Gromacs_Benchmarks \
  --region us-east-1

aws dynamodb describe-table \
  --table-name Gromacs_Benchmarks \
  --region us-east-1 \
  --query 'Table.TableStatus' \
  --output text
# Expected: ACTIVE
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
            "Resource": "arn:aws:dynamodb:us-east-1:*:table/Gromacs_Benchmarks"
        }
    ]
}
```

This mirrors the `LAMMPS_Benchmarks` permission already attached to the same role set on both internal clusters — see [`apps/LAMMPS/dynamodb/README.md`](../../LAMMPS/dynamodb/README.md) for the reference pattern.

### 3. Place this script under `/fsx/gromacs/scripts/dynamodb/` (or anywhere on shared storage) and uncomment the call site

A typical setup mirrors this repo's `apps/Gromacs/` layout under `/fsx/gromacs/scripts/`:

```
/fsx/gromacs/scripts/
├── x86/gromacs-benchmark.sbatch
├── Arm/gromacs-benchmark.sbatch
├── GPU/gromacs-benchmark.sbatch
└── dynamodb/record_to_dynamodb.sh    <-- this file
```

Then edit the `x86/gromacs-benchmark.sbatch`, `Arm/gromacs-benchmark.sbatch`, and / or `GPU/gromacs-benchmark.sbatch` you intend to run and **uncomment** the block at the bottom marked `Optional: record the result to DynamoDB.` (each line in that block starts with `# ` after the comment header — strip the leading `# ` to enable the call).

Override the recorder location with `DYNAMODB_RECORDER=/path/to/record_to_dynamodb.sh` on the `sbatch` command line if you place it somewhere other than the default. If the recorder isn't found at the resolved path, the benchmark prints a one-line note and continues — there is no failure path that depends on DynamoDB.

## Failure handling

A failed `aws dynamodb put-item` call is logged as a warning and **does not** fail the job. The local `md.log` file and the results block in the slurm output remain the authoritative record for any single run. The `dynamodb_record.json` file is preserved in the workdir so the put can be retried manually:

```bash
aws dynamodb put-item \
  --table-name Gromacs_Benchmarks \
  --region us-east-1 \
  --item file:///path/to/Run/.../dynamodb_record.json
```

## Disabling DynamoDB recording

The default state in this repository is **disabled** — the call site is commented out in `x86/gromacs-benchmark.sbatch` and `Arm/gromacs-benchmark.sbatch`. To skip DynamoDB recording you don't need to do anything: just submit the benchmark scripts as shipped.

To disable recording **after** you've enabled it, you have three equivalent options:

1. Re-comment the `Optional: record the result to DynamoDB.` block at the bottom of the benchmark `.sbatch` file you submitted.
2. Set `DYNAMODB_RECORDER=/path/that/does/not/exist` on the `sbatch` command line — the benchmark will log a one-line skip note and continue.
3. Remove the `dynamodb:PutItem` permission from the compute role — the recorder will log a warning and exit successfully, the benchmark won't fail.

---

## Contributing your results to the shared dataset

The `record-benchmark.sh` script in this same folder is a **separate**, self-contained recorder for the shared **AI-Powered HPC** dataset. It captures a single run into `External_<Source>_Gromacs` and is intended for colleagues and customers to contribute their own GROMACS benchmark results — distinct from the internal `record_to_dynamodb.sh` documented above (which records the maintainers' own runs to the `Gromacs_Benchmarks` table).

See **[../../BENCHMARK-RECORDERS.md](../../BENCHMARK-RECORDERS.md)** for usage, parameters, the contribution workflow, and `.sbatch` integration.
