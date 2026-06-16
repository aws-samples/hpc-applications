# Phase 1 GROMACS scaling sweep — runbook

This document is the operational checklist for the x86 scaling sweep:

> Submit (1N, 2N, 4N) × {benchMEM, benchPEP-h} × 3 replicates on hpc8a and
> on hpc7a (24 jobs); confirm DynamoDB has every record for the sweep;
> pull the means via the same scan helper used for LAMMPS.

The sweep is the data feed for the x86 chart in
[`Doc/img/Gromacs/generate_charts.py`](../../../Doc/img/Gromacs/)
and the embedded PNG in [`apps/Gromacs/README.md`](../README.md).

It is **not** runnable from a developer laptop — it must run on the head
node of the x86 cluster (`ec2-user@10.3.39.86`, reached via bastion
`ec2-user@3.128.184.207`). The artefacts in this directory are intended
to be `git pull`'d on the cluster head node and invoked there.

## Status

**Documented, awaiting live execution.**

As of 2026-05-26 the prerequisites below are not all met (see § Prerequisites).
Once they are, the operator runs `scaling_sweep_manifest.sh` on the head node,
waits for the 24 jobs to complete, runs `../dynamodb/scan_sweep.sh` to confirm
DynamoDB landed every record, then pastes the per-replicate means into
`Doc/img/Gromacs/generate_charts.py`.

### Partition fallback — hpc7a if hpc8a is unavailable

The Phase 1 build is identical for hpc8a (Zen5) and hpc7a.96xlarge (Zen4):
both are AVX-512 x86_64 and consume the same
`/fsx/gromacs/x86_64/<tag>/{tmpi,ompi}` install tree. **If hpc8a is
unavailable in the cluster** (capacity, maintenance, etc.), the smoke runs
the smoke test and the full sweep can be executed on hpc7a alone
without any code changes:

- `scaling_sweep_manifest.sh` already iterates `PARTITIONS=(hpc8a hpc7a)`
  and constrains hpc7a to the `hpc7a-96xlarge` feature so the rank shape
  matches hpc8a's 192 logical CPUs. Override the partition list at the
  command line if you want to run hpc7a-only:

  ```bash
  PARTITIONS=(hpc7a) ./scaling_sweep_manifest.sh
  ```

  (Edit the `PARTITIONS` array near the top of the script, or pass it as
  an environment variable if you've patched the script to honour it.)

- The default partition baked into `gromacs-benchmark.sbatch` is `hpc8a`.
  When submitting a one-shot smoke job on hpc7a, override it on the
  `sbatch` command line:

  ```bash
  sbatch -p hpc7a --constraint=hpc7a-96xlarge --nodes=1 \
      --export=ALL,MODEL=RNAse \
      /fsx/gromacs/scripts/x86/gromacs-benchmark.sbatch
  ```

- The DynamoDB record's `instance_type` field is read from IMDSv2 at run
  time, so hpc7a runs land in `Gromacs_Benchmarks` with
  `instance_type=hpc7a.96xlarge` automatically; the chart pipeline
  keys on `instance_type` and renders hpc8a vs hpc7a, so
  partial-only-hpc7a data is consumed cleanly when hpc8a backfill arrives.

The `--constraint=hpc7a-96xlarge` clause is required only on clusters where
the hpc7a partition is heterogeneous (12/24/48/96xlarge sharing one slurm
partition). On homogeneous clusters it's a no-op and can be omitted.

## Prerequisites

Tick each box **before** running the manifest. Submitting the full sweep with
any of these red burns hpc8a/hpc7a hours and / or produces records the chart
pipeline can't consume.

| # | Check | How to verify | Spec task |
|---|---|---|---|
| 1 | x86 build artefacts exist on FSx | `ls /fsx/gromacs/x86_64/v2024.4/{tmpi,ompi}/bin/gmx*` returns two binaries; `/fsx/gromacs/x86_64/v2024.4/tmpi/bin/gmx --version \| grep AVX_512` matches | 1.1, 2 |
| 2 | x86 benchmark smoke run produced a `Performance:` line | A 1-node `MODEL=RNAse` submission of `gromacs-benchmark.sbatch` left a non-zero `ns/day:` in its slurm log within ~5 min. Run on `hpc8a` if available, **or fall back to `hpc7a` (`-p hpc7a`)** — the AVX-512 build path is identical, so a clean smoke on hpc7a satisfies this prerequisite when hpc8a is unavailable | 5.1, 6 |
| 3 | `Gromacs_Benchmarks` table is `ACTIVE` in `us-east-1` | `aws dynamodb describe-table --table-name Gromacs_Benchmarks --region us-east-1 --query 'Table.TableStatus' --output text` returns `ACTIVE` | 3.1 |
| 4 | `dynamodb:PutItem` on `Gromacs_Benchmarks` is attached to the compute role | `salloc -p hpc8a -N1 -t 5:00 bash -lc 'aws dynamodb put-item --table-name Gromacs_Benchmarks --region us-east-1 --item ''{"job_id":{"S":"smoke"},"config":{"S":"0N-0rpn-test"}}'''` succeeds, then a follow-up `delete-item` cleans up | 3.2 |
| 5 | Cluster copy of the launcher exists with the DynamoDB call site **uncommented** | `grep -cE '^[[:space:]]*if \[ -x "\$\{DYNAMODB_RECORDER\}"' /fsx/gromacs/scripts/x86/gromacs-benchmark.sbatch` is at least 1 (the public-repo copy is `0`). The launcher invokes the recorder helper at `${DYNAMODB_RECORDER}` rather than calling `aws dynamodb put-item` directly, so grep on the recorder-call line — not on `aws dynamodb put-item` — to verify deployment | 5.1, 6 |

If you can tick (1) but not (2), do the smoke run as specified in the prerequisites before
launching the sweep. If you can't tick (4), attach the inline policy from
`apps/Gromacs/dynamodb/README.md` to the compute role and re-test. The 24-job
sweep is meant to run with steps 1-5 all green.

## Sweep contents (24 jobs)

| Partition | Node count | Model | Replicates | Sub-total |
|-----------|-----------:|-------|-----------:|----------:|
| hpc8a | 1 | benchMEM | 2 | 2 |
| hpc8a | 1 | benchPEP-h | 2 | 2 |
| hpc8a | 2 | benchMEM | 2 | 2 |
| hpc8a | 2 | benchPEP-h | 2 | 2 |
| hpc8a | 4 | benchMEM | 2 | 2 |
| hpc8a | 4 | benchPEP-h | 2 | 2 |
| hpc7a | 1 | benchMEM | 2 | 2 |
| hpc7a | 1 | benchPEP-h | 2 | 2 |
| hpc7a | 2 | benchMEM | 2 | 2 |
| hpc7a | 2 | benchPEP-h | 2 | 2 |
| hpc7a | 4 | benchMEM | 2 | 2 |
| hpc7a | 4 | benchPEP-h | 2 | 2 |
| **Total** | | | | **24** |

The spec text says "3 replicates" but tallies "24 jobs". `3 × 2 × 3 × 2 = 36`,
not 24, so we honour the **24-job** tally — 2 replicates per cell × 6 cells ×
2 partitions. If during analysis any cell shows replica-to-replica spread
greater than ~3 % we'll add a third replicate to that cell only.

If you prefer 3 replicates per cell (36 jobs) for tighter error bars, set
`REPLICATES=3` when invoking the manifest — both numbers are documented so
the chart pipeline can consume either.

## Run the sweep

On the x86 cluster head node:

```bash
# 1. Sanity-check the prerequisites table above.

# 2. Submit the sweep (interactive — prompts for confirmation).
cd /fsx/gromacs/scripts/x86      # or wherever you've git-pull'd the repo
./scaling_sweep_manifest.sh

# 3. Wait for the queue to drain. With Phase 1 hpc8a/hpc7a queues each
#    job should run in under 30 minutes; total wall time ~2-4 h depending
#    on queue contention.
watch -n 30 'squeue -u $USER'
```

The manifest emits one `submitted <name> -> jobid <id>` line per job and
then exits. Slurm logs land under `/fsx/gromacs/logs/gromacs_bench_<jobid>.{out,err}`
per the launcher's SBATCH headers.

## Confirm DynamoDB has every record

After the queue drains:

```bash
# Total record count for today's sweep
aws dynamodb scan \
    --table-name Gromacs_Benchmarks \
    --region us-east-1 \
    --filter-expression '#ts >= :since' \
    --expression-attribute-names '{"#ts":"timestamp"}' \
    --expression-attribute-values "{\":since\":{\"S\":\"$(date -u +%Y-%m-%d)\"}}" \
    --select COUNT --output text --query 'Count'
# Expected: 24 (or 36 if REPLICATES=3)
```

For the structured per-cell view (one line per `(instance, nodes, model)`
cell with replicates and mean):

```bash
cd apps/Gromacs/dynamodb
./scan_sweep.sh                       # latest 24 hours
./scan_sweep.sh --since 2026-05-27    # explicit start date
./scan_sweep.sh --raw                 # full JSON of all matching items
```

Sample output:

```
instance             nodes         model        ns_per_day_replicates    mean_ns_per_day
hpc7a.96xlarge           1     benchMEM     [144.598, 144.812]                 144.705
hpc7a.96xlarge           1   benchPEP-h     [  2.118,   2.122]                   2.120
hpc7a.96xlarge           2     benchMEM     [273.000, 273.500]                 273.250
hpc7a.96xlarge           2   benchPEP-h     [  4.018,   4.025]                   4.022
hpc7a.96xlarge           4     benchMEM     [490.500, 491.700]                 491.100
hpc7a.96xlarge           4   benchPEP-h     [  7.310,   7.402]                   7.356
hpc8a.96xlarge           1     benchMEM     [200.250, 200.610]                 200.430
hpc8a.96xlarge           1   benchPEP-h     [  2.940,   2.952]                   2.946
hpc8a.96xlarge           2     benchMEM     [380.500, 381.220]                 380.860
hpc8a.96xlarge           2   benchPEP-h     [  5.610,   5.633]                   5.622
hpc8a.96xlarge           4     benchMEM     [690.700, 692.140]                 691.420
hpc8a.96xlarge           4   benchPEP-h     [ 10.250,  10.298]                  10.274
```

(Numbers above are illustrative — they are **not** measured GROMACS
performance on hpc8a/hpc7a, just placeholders showing the table shape.)

## Hand-off to the chart pipeline

Copy the per-replicate `ns_per_day_replicates` lists from `scan_sweep.sh`
output into `Doc/img/Gromacs/generate_charts.py` as numeric Python literals,
mirroring the existing pattern in `Doc/img/LAMMPS/generate_charts.py`:

```python
# benchMEM ----------------------------------------------------------------
nodes_x86 = np.array([1, 2, 4])

# hpc8a (Zen5, OpenMPI 4): 2 replicas at every node count
ns_hpc8a_1n_benchMEM = [200.250, 200.610]
ns_hpc8a_2n_benchMEM = [380.500, 381.220]
ns_hpc8a_4n_benchMEM = [690.700, 692.140]

# hpc7a (Zen4, OpenMPI 4): 2 replicas at every node count
ns_hpc7a_1n_benchMEM = [144.598, 144.812]
# ...
```

Then run `python3 Doc/img/Gromacs/generate_charts.py` to produce
`Gromacs-benchMEM-Hpc8aVsHpc7a.png` and the equivalent benchPEP-h chart, and
embed them in `apps/Gromacs/README.md` using the GitHub
`raw=true` URL pattern documented in
[`apps/LAMMPS/README.md`](../../LAMMPS/README.md).

## Why this isn't auto-submitted

The repository ships the manifest **as a script the operator runs**, not as
a CI job that fires automatically, for three reasons:

1. **Cost** — 24 hpc8a/hpc7a jobs at 1-4 nodes consume real cluster hours
   that bill against an internal AWS account. We require an operator
   confirmation step before incurring that.
2. **Determinism** — running the sweep before tasks 2 and 6 are validated
   produces records the chart pipeline can't consume; the prerequisite
   checklist above exists to prevent that.
3. **DynamoDB blast radius** — the `Gromacs_Benchmarks` table is shared
   across teams; ad-hoc auto-runs would clutter it with mis-tagged records.
   The scan helper has a `--since` knob exactly so we can scope to a known
   sweep window without filtering on opaque job-id lists.

When the prerequisites are green and the operator wants to run the sweep,
there's nothing surprising — `scaling_sweep_manifest.sh` is a one-line
invocation that prompts before submitting and emits a job table the operator
can hand to `squeue` / `scan_sweep.sh` to follow up.
