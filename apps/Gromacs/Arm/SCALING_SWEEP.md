# Phase 2 GROMACS scaling sweep — runbook

This document is the operational checklist for the Arm (Graviton) scaling sweep:

> Submit (1N, 2N, 4N) × {benchMEM, benchPEP-h} × 3 replicates on hpc7g and
> m8g (24 jobs); pull means from DynamoDB; update
> `Doc/img/Gromacs/generate_charts.py` Arm section with real data; produce
> `Gromacs-<Workload>-Graviton3VsGraviton4.png`; embed in the Performance
> section of the README.

The sweep is the data feed for the Arm chart in
[`Doc/img/Gromacs/generate_charts.py`](../../../Doc/img/Gromacs/) (the
`data_available_arm` gate flips to `True` once the per-replicate lists are
populated) and the embedded PNGs in [`apps/Gromacs/README.md`](../README.md).

It is **not** runnable from a developer laptop — it must run on the head
node of the Arm cluster (`ec2-user@10.3.51.188`, reached via bastion
`ec2-user@3.128.184.207`). The artefacts in this directory are intended
to be `git pull`'d on the cluster head node and invoked there.

## Status

**Documented, awaiting live execution.**

As of the time this file was committed the prerequisites below are not all
met (see § Prerequisites). Once they are, the operator runs
`scaling_sweep_manifest.sh` on the head node, waits for the 24 jobs to
complete, runs `../dynamodb/scan_sweep.sh` to confirm DynamoDB landed
every record, then pastes the per-replicate means into
`Doc/img/Gromacs/generate_charts.py` and flips `data_available_arm = True`.

## Prerequisites

Tick each box **before** running the manifest. Submitting the full sweep
with any of these red burns hpc7g/m8g hours and / or produces records the
chart pipeline can't consume.

| # | Check | How to verify | Spec task |
|---|---|---|---|
| 1 | Arm build artefacts exist on FSx for both Graviton3E (OMPI 5) and Graviton4 (OMPI 5) | `ls /fsx/gromacs/aarch64-graviton3-ompi5/v2024.4/{tmpi,ompi}/bin/gmx*` and `ls /fsx/gromacs/aarch64-graviton4-ompi5/v2024.4/{tmpi,ompi}/bin/gmx*` each return two binaries; `/fsx/gromacs/aarch64-graviton3-ompi5/v2024.4/tmpi/bin/gmx --version \| grep ARM_SVE` matches; same for the Graviton4 prefix | 11.1, 13 |
| 2 | Arm benchmark smoke runs produced `Performance:` lines on **both** partitions | A 1-node `MODEL=RNAse` submission of `gromacs-benchmark.sbatch` on hpc7g and a 1-node `MODEL=benchMEM` submission on m8g (`--ntasks-per-node=192`) each leave a non-zero `ns/day:` in their slurm log within ~10 min; a 4N benchPEP-h submission on m8g at 192 ranks/node confirms OpenMPI 5 endpoint scaling | 12.1, 13 |
| 3 | `Gromacs_Benchmarks` table is `ACTIVE` in `us-east-1` (provisioned in Phase 1) | `aws dynamodb describe-table --table-name Gromacs_Benchmarks --region us-east-1 --query 'Table.TableStatus' --output text` returns `ACTIVE` | 3.1 |
| 4 | `dynamodb:PutItem` on `Gromacs_Benchmarks` is attached to the **Arm cluster** compute role | `salloc -p hpc7g -N1 -t 5:00 bash -lc 'aws dynamodb put-item --table-name Gromacs_Benchmarks --region us-east-1 --item ''{"job_id":{"S":"smoke-arm"},"config":{"S":"0N-0rpn-test"}}'''` succeeds, then a follow-up `delete-item` cleans up. **The Phase 1 IAM policy attached the permission to the x86 cluster role only — re-attach the same scoped policy to the Arm cluster role.** | 3.2 |
| 5 | Cluster copy of the launcher exists with the DynamoDB call site **uncommented** | `grep -c '^aws dynamodb put-item' /fsx/gromacs/scripts/Arm/gromacs-benchmark.sbatch` is at least 1 (the public-repo copy is `0`) — see [`apps/Gromacs/dynamodb/README.md`](../dynamodb/README.md) for the deploy-time uncomment recipe | 12.1, 13 |

If you can tick (1) but not (2), do the smoke runs as specified in the prerequisites
before launching the sweep. If you can't tick (4), attach the inline
policy from [`apps/Gromacs/dynamodb/README.md`](../dynamodb/README.md) to
the Arm compute role and re-test. The 24-job sweep is meant to run with
steps 1-5 all green.

## Sweep contents (24 jobs)

| Partition | Node count | Ranks/node | Model | Replicates | Sub-total |
|-----------|-----------:|-----------:|-------|-----------:|----------:|
| hpc7g | 1 | 64 | benchMEM | 2 | 2 |
| hpc7g | 1 | 64 | benchPEP-h | 2 | 2 |
| hpc7g | 2 | 64 | benchMEM | 2 | 2 |
| hpc7g | 2 | 64 | benchPEP-h | 2 | 2 |
| hpc7g | 4 | 64 | benchMEM | 2 | 2 |
| hpc7g | 4 | 64 | benchPEP-h | 2 | 2 |
| m8g | 1 | 192 | benchMEM | 2 | 2 |
| m8g | 1 | 192 | benchPEP-h | 2 | 2 |
| m8g | 2 | 192 | benchMEM | 2 | 2 |
| m8g | 2 | 192 | benchPEP-h | 2 | 2 |
| m8g | 4 | 192 | benchMEM | 2 | 2 |
| m8g | 4 | 192 | benchPEP-h | 2 | 2 |
| **Total** | | | | | **24** |

The spec text says "3 replicates" but tallies "24 jobs" — same wording
discrepancy noted for the x86 sweep. `3 × 2 × 3 × 2 = 36`, not 24, so we honour the
**24-job** tally: 2 replicates per cell × 6 cells × 2 partitions. If
during analysis any cell shows replica-to-replica spread greater than
~3 % we'll add a third replicate to that cell only. Set `REPLICATES=3`
when invoking the manifest if you'd rather collect 36 jobs up front for
tighter error bars; the chart pipeline consumes either shape.

Both partitions are single-socket: hpc7g has 64 vCPUs (Graviton3E,
Neoverse V1) and m8g has 192 vCPUs (Graviton4, Neoverse V2). The
manifest sets `--ntasks-per-node` per partition so the m8g jobs land at
192 ranks/node — the launcher's default of 64 is correct for hpc7g but
would massively under-utilise m8g.

## Run the sweep

On the Arm cluster head node:

```bash
# 1. Sanity-check the prerequisites table above.

# 2. Submit the sweep (interactive — prompts for confirmation).
cd /fsx/gromacs/scripts/Arm     # or wherever you've git-pull'd the repo
./scaling_sweep_manifest.sh

# 3. Wait for the queue to drain. Total wall time ~3-5 h depending on
#    queue contention; m8g 4N benchPEP-h is the longest single job at
#    ~30-45 minutes per replicate.
watch -n 30 'squeue -u $USER'
```

The manifest emits one `submitted <name> -> jobid <id>` line per job and
then exits. Slurm logs land under
`/fsx/gromacs/logs/gromacs_bench_arm_<jobid>.{out,err}` per the launcher's
SBATCH headers.

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
./scan_sweep.sh --since 2026-06-15    # explicit start date
./scan_sweep.sh --raw                 # full JSON of all matching items
```

`scan_sweep.sh` is architecture-agnostic — it groups rows by
`instance_type`, so the output for a Phase 2 sweep will include both
`hpc7g.16xlarge` and `m8g.48xlarge` rows alongside any Phase 1 hpc8a /
hpc7a rows still in the table. Filter on `--since` to scope to the
window the Arm sweep actually ran.

Sample output shape (illustrative — not measured GROMACS performance on
hpc7g/m8g):

```
instance             nodes         model        ns_per_day_replicates    mean_ns_per_day
hpc7g.16xlarge           1     benchMEM     [ 92.300,  92.612]                  92.456
hpc7g.16xlarge           1   benchPEP-h     [  1.420,   1.428]                   1.424
hpc7g.16xlarge           2     benchMEM     [175.700, 176.110]                 175.905
hpc7g.16xlarge           2   benchPEP-h     [  2.715,   2.718]                   2.717
hpc7g.16xlarge           4     benchMEM     [320.500, 321.220]                 320.860
hpc7g.16xlarge           4   benchPEP-h     [  4.910,   4.927]                   4.919
m8g.48xlarge             1     benchMEM     [240.500, 241.220]                 240.860
m8g.48xlarge             1   benchPEP-h     [  3.520,   3.535]                   3.528
m8g.48xlarge             2     benchMEM     [462.700, 463.140]                 462.920
m8g.48xlarge             2   benchPEP-h     [  6.810,   6.825]                   6.818
m8g.48xlarge             4     benchMEM     [855.700, 857.220]                 856.460
m8g.48xlarge             4   benchPEP-h     [ 12.510,  12.580]                  12.545
```

## Hand-off to the chart pipeline

Copy the per-replicate `ns_per_day_replicates` lists from `scan_sweep.sh`
output into [`Doc/img/Gromacs/generate_charts.py`](../../../Doc/img/Gromacs/generate_charts.py),
mirroring the placeholder pattern that's already in place for x86:

```python
# Arm — benchMEM ----------------------------------------------------------
# hpc7g (Graviton3E, OpenMPI 5)
ns_hpc7g_1n_benchMEM = [92.300, 92.612]
ns_hpc7g_2n_benchMEM = [175.700, 176.110]
ns_hpc7g_4n_benchMEM = [320.500, 321.220]
# m8g (Graviton4, OpenMPI 5)
ns_m8g_1n_benchMEM   = [240.500, 241.220]
ns_m8g_2n_benchMEM   = [462.700, 463.140]
ns_m8g_4n_benchMEM   = [855.700, 857.220]

# Arm — benchPEP-h --------------------------------------------------------
ns_hpc7g_1n_benchPEPh = [1.420, 1.428]
# ... and so on for the other five cells
```

The empty data lists in `generate_charts.py` show every
cell that needs filling. Then flip the gate near the top of the script:

```python
data_available_arm = True
```

From the repo root, run `python3 Doc/img/Gromacs/generate_charts.py`. The
script writes `Gromacs-benchMEM-Graviton3VsGraviton4.png` and
`Gromacs-benchPEP-h-Graviton3VsGraviton4.png` next to itself. The Arm
chart subsection in [`apps/Gromacs/README.md`](../README.md) already
embeds these PNGs by raw-content URL — no edit to the README is required
once the PNGs land in `Doc/img/Gromacs/` on `main`. They'll start
rendering automatically the moment the commit reaches the default branch.

`git add Doc/img/Gromacs/Gromacs-*-Graviton3VsGraviton4.png Doc/img/Gromacs/generate_charts.py`
and commit.

## Why this isn't auto-submitted

Same three reasons as the Phase 1 sweep, ported to the Arm cluster:

1. **Cost** — 24 hpc7g/m8g jobs at 1-4 nodes consume real cluster hours
   that bill against an internal AWS account. We require an operator
   confirmation step before incurring that.
2. **Determinism** — running the sweep before tasks 11 and 13 are
   validated produces records the chart pipeline can't consume (e.g.
   m8g jobs running at 64 ranks/node instead of 192). The prerequisite
   checklist above exists to prevent that.
3. **DynamoDB blast radius** — the `Gromacs_Benchmarks` table is shared
   across teams and across phases (Phase 1 records are still in the
   table); ad-hoc auto-runs would clutter it with mis-tagged records.
   The scan helper has a `--since` knob exactly so we can scope to a
   known sweep window without filtering on opaque job-id lists.

When the prerequisites are green and the operator wants to run the
sweep, there's nothing surprising — `scaling_sweep_manifest.sh` is a
one-line invocation that prompts before submitting and emits a job table
the operator can hand to `squeue` / `scan_sweep.sh` to follow up.
