# Contributing Benchmark Results — DynamoDB Recorders

Each application ships a small, self-contained recorder at:

```
apps/<App>/dynamodb/record-benchmark.sh
```

It captures **one** benchmark run and stores it, in a canonical schema, into the
shared **AI-Powered HPC** benchmark dataset (Amazon DynamoDB). That dataset is
used to train a model that predicts HPC application performance on AWS and
recommends optimal cluster configurations. Contributing your own results
enriches the dataset and improves those predictions.

Recorders are available for: **Fluent, OpenFOAM, ANSYS Mechanical, CFX, LS-DYNA,
OptiStruct, STAR-CCM+, WRF, GROMACS, OpenRadioss, LAMMPS**.

---

## Design principles

- **Self-contained.** One file, no dependencies on anything else in this repo.
  Copy (or `curl`) just the script for your application and run it.
- **Safe by default.**
  - It **always** writes the record as a local JSON file you can inspect/keep.
  - It only calls `aws dynamodb put-item` when AWS write access is available (or
    you pass `--put`). With no credentials it just saves the JSON and tells you
    where it is — nothing fails.
  - `--dry-run` prints the record to stdout and touches neither disk nor AWS.
- **Auto-detecting.** On a SLURM/EC2 node it fills in instance type, OS, core
  count, node count, MPI, libfabric and EFA versions for you, so you pass as
  little as possible.
- **Attributed.** Every row is tagged with your source as external provenance.

## Requirements

- `bash` and `curl` (`curl` is only used for EC2 metadata auto-detection).
- AWS CLI v2 — **only** if you intend to write straight to DynamoDB (`--put`).

---

## Quick start

On a SLURM compute node, right after your solve (instance/OS/cores/nodes/MPI are
auto-detected):

```bash
apps/Fluent/dynamodb/record-benchmark.sh \
    --case f1_racecar_140m --num-cells-million 140 \
    --time-per-iteration 0.42 --num-iterations 25 \
    --source AcmeCorp
```

Off-cluster, or replaying a saved result — pass everything explicitly and
preview it first with `--dry-run`:

```bash
apps/Gromacs/dynamodb/record-benchmark.sh \
    --case benchPEP-h --atoms-million 12 --ns-per-day 42.5 --time-to-solution 600 \
    --instance-type hpc7a.96xlarge --os "Amazon Linux 2" \
    --num-cores 192 --num-nodes 1 --mpi openmpi-4 --version 2024.1 \
    --source AcmeCorp --dry-run
```

Always check the authoritative option list for your app:

```bash
apps/<App>/dynamodb/record-benchmark.sh --help
```

---

## Parameters

### Common to every application

**Identity / destination**
| Flag | Meaning |
|------|---------|
| `--source LABEL` | Your org/handle (default `Community`). Becomes the table suffix `External_<LABEL>_<App>` and the row's provenance. Letters/digits only. |
| `--table NAME` | Override the destination table name entirely. |
| `--region REGION` | AWS region of the table (default `us-east-1`). |
| `--id ID` | Record id (the table key). Auto-generated if omitted. |

**Core run configuration** — auto-detected on SLURM/EC2 when omitted:
| Flag | Meaning |
|------|---------|
| `--instance-type TYPE` | EC2 instance type (e.g. `hpc7a.96xlarge`). |
| `--os NAME` | Operating system (e.g. `"Amazon Linux 2"`). |
| `--num-cores N` | Total cores / MPI ranks used. |
| `--num-nodes N` | Number of instances / nodes. |
| `--cores-per-node N` | Cores per node (derived from the two above if omitted). |
| `--mpi NAME` | MPI implementation (e.g. `openmpi-4`, `intelmpi`). |
| `--version VER` | Application version (e.g. `2024R2`, `v2512`, `2024.1`). |

**Result + dataset description** — recommended; this is what makes a row useful
for training:
| Flag | Meaning |
|------|---------|
| `--case NAME` | Benchmark case / dataset id (e.g. `f1_racecar_140m`, `CONUS-2.5km`). |
| `--time-to-solution SEC` | Total solver wall-clock seconds — the model's primary target. |
| *(app-specific size/rate metrics)* | See the per-app table below. |

**Extensible** — capture anything not covered by a dedicated flag:
| Flag | Meaning |
|------|---------|
| `--metric NAME=VALUE` | Any extra **numeric** performance metric (repeatable). |
| `--char NAME=VALUE` | Any extra **string** dataset characteristic (repeatable). |

**Behavior**
| Flag | Meaning |
|------|---------|
| `--put` | Force the DynamoDB write (error out if it fails). |
| `--no-put` | Never call AWS; only write the JSON file. |
| `--dry-run` | Print the record; touch no file and no AWS. |
| `--out DIR` | Directory for the saved JSON (default: current dir). |
| `-h`, `--help` | Full option list (authoritative for that app). |

### Required fields

The model rejects a row that is missing any of:
`instance_type`, `operating_system`, `num_cores`, `num_instances`, `libraries`.

On a cluster these are auto-detected. Off-cluster, pass `--instance-type`,
`--os`, `--num-cores`, `--num-nodes`, and at least one of `--mpi` / `--version`
(so the `libraries` list can be composed).

### App-specific result & size fields

| App | Discipline | Key result metric(s) | Size metric | Notable extra characteristics |
|-----|-----------|----------------------|-------------|-------------------------------|
| **Fluent** | CFD | `--time-to-solution` **or** `--time-per-iteration` + `--num-iterations`; `--solver-rating`, `--solver-speed` | `--num-cells-million` | `--turbulence-model`, `--solver-type`, `--analysis-type`, `--cell-type` |
| **OpenFOAM** | CFD | `--time-to-solution` | `--mesh-cells-million` | `--solver` (e.g. `simpleFoam`), `--turbulence-model`, `--solver-type`, `--analysis-type` |
| **GROMACS** | MD | `--time-to-solution`, `--ns-per-day` | `--atoms-million` | `--analysis-type` (NVE/NVT/NPT) |
| **WRF** | Weather | `--time-to-solution` | `--num-cells-million` (grid points) | `--analysis-type` (forecast/idealized) |
| **CFX / STAR-CCM+** | CFD | `--time-to-solution` | see `--help` | see `--help` |
| **LS-DYNA / OptiStruct / ANSYS Mechanical / OpenRadioss** | FEA / structural | `--time-to-solution` | see `--help` | see `--help` |
| **LAMMPS** | MD | `--time-to-solution` | see `--help` | see `--help` |

> For Fluent, if you omit `--time-to-solution` but pass `--time-per-iteration`
> and `--num-iterations`, total solve time is computed as their product.
> For anything without a dedicated flag, use `--metric name=value` (numbers) and
> `--char name=value` (strings).

---

## Where the data goes

- **Table:** `External_<Source>_<App>` in the dataset owner's account
  (region `us-east-1` by default). `<App>` is the capitalized engine name, e.g.
  `External_AcmeCorp_Fluent`, `External_AcmeCorp_Openfoam`,
  `External_AcmeCorp_Gromacs`, `External_AcmeCorp_Wrf`.
- The ingestion side reads **every** `External_*` table with an identity map, so
  the canonical attribute names the recorder writes are consumed as-is.
- Each row carries: the required fields, your result metrics, dataset
  characteristics, a generated `record_id`, a `recorded_at` UTC timestamp, and
  provenance (`provenance_origin=external`, `provenance_source_id=<Source>`).

## Contribution workflow

1. Run the recorder right after your benchmark.
2. It **always** saves a local JSON file named `<record_id>.json`.
3. Then one of:
   - **You have write access** (or pass `--put` with valid credentials): the row
     is written straight to DynamoDB.
   - **You don't** (the usual case for external contributors): the write is
     skipped gracefully — send the saved JSON to the dataset owner, or upload it
     to their contribution inbox, and they load it for you.

Either way nothing fails and you keep the JSON.

---

## Using it inside a SLURM `.sbatch`

Add a recording step at the **end** of your job script, after the solver
finishes and you've parsed the metric(s) you care about:

```bash
#!/bin/bash
#SBATCH --job-name=fluent-f1
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=96
#SBATCH --exclusive
#SBATCH --time=04:00:00

module load libfabric-aws openmpi

# Point at the recorder for your app (use an absolute path on shared storage,
# e.g. /fsx/hpc-applications/apps/Fluent/dynamodb/record-benchmark.sh)
RECORDER=/fsx/hpc-applications/apps/Fluent/dynamodb/record-benchmark.sh
CASE=f1_racecar_140m

# 1) Run the solver
fluentbench.pl "${CASE}" -t"${SLURM_NTASKS}" -cnf=hostfile -mpi=openmpi -norm \
    | tee "solve.${SLURM_JOB_ID}.out"

# 2) Parse the metric(s) from the solver output
per_iter=$(awk '/Solver wall time per iteration/{v=$(NF-1)} END{print v}' "${CASE}"-*.out)

# 3) Record only a SUCCESSFUL solve (guard against storing empty/garbage rows)
if [ -n "${per_iter}" ]; then
    # If your MPI stack exported LD_PRELOAD (some Fluent builds do), drop it —
    # a stray preload can crash the Python-based AWS CLI:
    unset LD_PRELOAD

    # Run once (not once per rank). instance_type/os/num_cores/num_nodes/MPI
    # are auto-detected from SLURM + EC2.
    srun --ntasks=1 --nodes=1 "${RECORDER}" \
        --case "${CASE}" --num-cells-million 140 \
        --time-per-iteration "${per_iter}" --num-iterations 25 \
        --source AcmeCorp
else
    echo "Solve produced no timing; not recording." >&2
fi
```

The same three-step pattern (run → parse → record) applies to every app; only
the parsing and the app-specific flags change. Practical tips:

- **Record once**, not once per MPI rank — invoke it as a single task
  (`srun -n1 -N1 ...`), or outside `mpirun`.
- **Guard it** so you only record runs that actually produced a result.
- **Preview with `--dry-run`** first; remove it once the output looks right, and
  add `--put` if you have write access to the dataset.

## Environment-variable equivalents

Every core field also reads from an environment variable, which is handy for
templating jobs: `SOURCE`, `DYNAMODB_REGION`, `INSTANCE_TYPE`,
`OPERATING_SYSTEM`, `NUM_CORES`, `NUM_INSTANCES`, `CORES_PER_NODE`,
`MPI_IMPLEMENTATION`, `BENCHMARK_CASE`, `TIME_TO_SOLUTION`, and
`<APP>_VERSION` (e.g. `FLUENT_VERSION`, `OPENFOAM_VERSION`, `GROMACS_VERSION`,
`WRF_VERSION`). Command-line flags take precedence over environment variables.

## Notes

- No `--source`? Rows default to `External_Community_<App>`.
- Each row gets a unique `record_id`, so re-running never destructively
  overwrites earlier contributions.
- A few apps (e.g. GROMACS) also carry a separate internal
  `record_to_dynamodb.sh` in the same folder — that is the dataset owner's own
  path into the app's primary table, **not** the contribution path. Use
  `record-benchmark.sh` to contribute.
