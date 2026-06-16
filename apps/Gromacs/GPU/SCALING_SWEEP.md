# Phase 3 GROMACS GPU scaling sweep — runbook

This document is the operational checklist for the GPU scaling sweep:

> Run a Phase 3 chart sweep (1, 2, 4, 8 GPUs on g6e and p5; benchMEM and
> benchPEP-h); update `generate_charts.py` to render
> `Gromacs-<Workload>-P5VsG6e.png`.

The sweep is the data feed for the GPU chart in
[`Doc/img/Gromacs/generate_charts.py`](../../../Doc/img/Gromacs/) (the
`data_available_gpu` gate flips to `True` once the per-replicate lists are
populated) and the embedded PNGs in [`apps/Gromacs/README.md`](../README.md).

It is **not** runnable from a developer laptop — it must run on the head
node of a GPU cluster (g6e and p5 partitions, reached via the same
bastion topology as the CPU clusters). The artefacts in this directory
are intended to be `git pull`'d on the cluster head node and invoked
there.

## Status

**Documented, awaiting live execution.**

Phase 3 is intentionally future-scoped per the spec — the GPU scripts and
this runbook are committed so the layout and flow can be reviewed by
reading the source, but the live cluster validation (smoke build, smoke
benchmarks, this scaling sweep) requires SSH access to provisioned g6e
(L40S) and p5 (H100) clusters. Until that hardware is available, the
prerequisites below are not all met (see § Prerequisites). Once they
are, the operator runs `scaling_sweep_manifest.sh` on the head node,
waits for the 32 jobs to complete, runs `../dynamodb/scan_sweep.sh` to
confirm DynamoDB landed every record, then pastes the per-replicate
means into `Doc/img/Gromacs/generate_charts.py` and flips
`data_available_gpu = True`.

## Prerequisites

Tick each box **before** running the manifest. Submitting the full sweep
with any of these red burns g6e/p5 hours (p5 in particular is expensive)
and / or produces records the chart pipeline can't consume.

| # | Check | How to verify | Spec task |
|---|---|---|---|
| 1 | GPU build artefacts exist on FSx for both L40S and H100 | `ls /fsx/gromacs/x86_64-cuda12-l40s/v2024.4/{tmpi,ompi}/bin/gmx*` and `ls /fsx/gromacs/x86_64-cuda12-h100/v2024.4/{tmpi,ompi}/bin/gmx*` each return two binaries; `/fsx/gromacs/x86_64-cuda12-l40s/v2024.4/tmpi/bin/gmx --version \| grep -E 'GPU support: CUDA\|AVX_512'` matches both lines; same for the H100 prefix | 17.1, 19 |
| 2 | GPU benchmark smoke runs produced `Performance:` lines on **both** instance families AND `GPU_COUNT` validation rejects out-of-range values | A 1-GPU `MODEL=RNAse` submission of `gromacs-benchmark.sbatch` on g6e and a 1-GPU `MODEL=benchMEM` submission on p5 each leave a non-zero `ns/day:` in their slurm log within ~10 min; a multi-GPU run (4-GPU benchMEM on g6e and 8-GPU benchMEM on p5) confirms Thread_MPI multi-GPU works and the topology classification line (`GPU topology: NVLink/NVSwitch/PCIe`) is present; `GPU_COUNT=0`, `GPU_COUNT=9`, and `GPU_COUNT=` (greater than detected GPUs) submissions are rejected at submit time with a descriptive error | 18.1, 19 |
| 3 | `Gromacs_Benchmarks` table is `ACTIVE` in `us-east-1` (provisioned in Phase 1) | `aws dynamodb describe-table --table-name Gromacs_Benchmarks --region us-east-1 --query 'Table.TableStatus' --output text` returns `ACTIVE` | 3.1 |
| 4 | `dynamodb:PutItem` on `Gromacs_Benchmarks` is attached to the **GPU cluster** compute role | `salloc -p g6e -N1 --gres=gpu:1 -t 5:00 bash -lc 'aws dynamodb put-item --table-name Gromacs_Benchmarks --region us-east-1 --item ''{"job_id":{"S":"smoke-gpu"},"config":{"S":"0N-0rpn-test"}}'''` succeeds, then a follow-up `delete-item` cleans up. **The Phase 1 IAM policy attached the permission to the x86 cluster role and Phase 2 added the Arm cluster role — Phase 3 needs the same scoped policy on the GPU cluster role.** | 3.2 |
| 5 | Cluster copy of the launcher exists with the DynamoDB call site **uncommented** | `grep -c '^aws dynamodb put-item' /fsx/gromacs/scripts/GPU/gromacs-benchmark.sbatch` is at least 1 (the public-repo copy is `0`) — see [`apps/Gromacs/dynamodb/README.md`](../dynamodb/README.md) for the deploy-time uncomment recipe. Phase 3 records additionally carry `gpu_count` and `cuda_version` attributes the recorder appends only when both env vars are set | 18.1, 19 |

If you can tick (1) but not (2), do the smoke runs as specified in the prerequisites
before launching the sweep. If you can't tick (4), attach the inline
policy from [`apps/Gromacs/dynamodb/README.md`](../dynamodb/README.md) to
the GPU compute role and re-test. The 32-job sweep is meant to run with
steps 1-5 all green.

## Sweep contents (32 jobs)

| Partition | Nodes | GPUs/job | Model | Replicates | Sub-total |
|-----------|------:|---------:|-------|-----------:|----------:|
| g6e | 1 | 1 | benchMEM | 2 | 2 |
| g6e | 1 | 1 | benchPEP-h | 2 | 2 |
| g6e | 1 | 2 | benchMEM | 2 | 2 |
| g6e | 1 | 2 | benchPEP-h | 2 | 2 |
| g6e | 1 | 4 | benchMEM | 2 | 2 |
| g6e | 1 | 4 | benchPEP-h | 2 | 2 |
| g6e | 1 | 8 | benchMEM | 2 | 2 |
| g6e | 1 | 8 | benchPEP-h | 2 | 2 |
| p5 | 1 | 1 | benchMEM | 2 | 2 |
| p5 | 1 | 1 | benchPEP-h | 2 | 2 |
| p5 | 1 | 2 | benchMEM | 2 | 2 |
| p5 | 1 | 2 | benchPEP-h | 2 | 2 |
| p5 | 1 | 4 | benchMEM | 2 | 2 |
| p5 | 1 | 4 | benchPEP-h | 2 | 2 |
| p5 | 1 | 8 | benchMEM | 2 | 2 |
| p5 | 1 | 8 | benchPEP-h | 2 | 2 |
| **Total** | | | | | **32** |

All jobs are **single-node** — both g6e.48xlarge (8x L40S) and
p5.48xlarge (8x H100) ship up to 8 GPUs in one chassis, and the
launcher's `GPU_COUNT` validation tops out at `min(8, nvidia-smi -L
count)`. Multi-node GPU runs (Library_MPI under `mpirun`) are out of
Phase 3 scope and are not part of this manifest.
The launcher still supports them when `GPU_COUNT` exceeds GPUs/node —
see [`apps/Gromacs/GPU/gromacs-benchmark.sbatch`](gromacs-benchmark.sbatch)
for the path.

If you'd rather collect 48 jobs up front for tighter error bars, set
`REPLICATES=3` when invoking the manifest — the chart pipeline consumes
either shape.

## Run the sweep

On the GPU cluster head node:

```bash
# 1. Sanity-check the prerequisites table above.

# 2. Submit the sweep (interactive — prompts for confirmation).
cd /fsx/gromacs/scripts/GPU      # or wherever you've git-pull'd the repo
./scaling_sweep_manifest.sh

# 3. Wait for the queue to drain. Total wall time ~3-6 h depending on
#    queue contention; the 1-GPU benchPEP-h jobs are the longest single
#    runs at ~30-60 minutes per replicate (12M-atom system on a single
#    GPU). 8-GPU runs are short by comparison.
watch -n 30 'squeue -u $USER'
```

The manifest emits one `submitted <name> -> jobid <id>` line per job and
then exits. Slurm logs land under
`/fsx/gromacs/logs/gromacs_bench_gpu_<jobid>.{out,err}` per the
launcher's SBATCH headers.

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
# Expected: 32 (or 48 if REPLICATES=3)
```

For the structured per-cell view (one line per `(instance, gpus, model)`
cell with replicates and mean):

```bash
cd apps/Gromacs/dynamodb
./scan_sweep.sh                       # latest 24 hours
./scan_sweep.sh --since 2026-07-15    # explicit start date
./scan_sweep.sh --raw                 # full JSON of all matching items
```

`scan_sweep.sh` is architecture-agnostic — it groups rows by
`instance_type`, so the output for a Phase 3 sweep will include both
`g6e.48xlarge` and `p5.48xlarge` rows alongside any Phase 1 / Phase 2
rows still in the table. Filter on `--since` to scope to the window
the GPU sweep actually ran. Phase 3 records additionally carry
`gpu_count` and `cuda_version` attributes — the helper renders them
alongside `nodes` and `instance_type` when present.

Sample output shape (illustrative — not measured GROMACS performance on
g6e/p5):

```
instance             nodes  gpus    model       ns_per_day_replicates    mean_ns_per_day
g6e.48xlarge             1     1   benchMEM     [180.500, 181.220]                 180.860
g6e.48xlarge             1     1 benchPEP-h     [  4.520,   4.535]                   4.528
g6e.48xlarge             1     2   benchMEM     [340.700, 341.140]                 340.920
g6e.48xlarge             1     4   benchMEM     [620.500, 621.220]                 620.860
g6e.48xlarge             1     8   benchMEM     [1100.700, 1102.140]              1101.420
p5.48xlarge              1     1   benchMEM     [320.500, 321.220]                 320.860
p5.48xlarge              1     1 benchPEP-h     [  9.520,   9.535]                   9.528
p5.48xlarge              1     2   benchMEM     [620.700, 621.140]                 620.920
p5.48xlarge              1     4   benchMEM     [1180.500, 1181.220]              1180.860
p5.48xlarge              1     8   benchMEM     [2200.700, 2202.140]              2201.420
```

## Hand-off to the chart pipeline

Copy the per-replicate `ns_per_day_replicates` lists from `scan_sweep.sh`
output into [`Doc/img/Gromacs/generate_charts.py`](../../../Doc/img/Gromacs/generate_charts.py),
mirroring the placeholder pattern that's already in place for x86 and
Arm:

```python
# GPU — benchMEM ----------------------------------------------------------
# g6e (L40S, sm_89): per-GPU-count run on a single node
ns_g6e_1g_benchMEM = [180.500, 181.220]
ns_g6e_2g_benchMEM = [340.700, 341.140]
ns_g6e_4g_benchMEM = [620.500, 621.220]
ns_g6e_8g_benchMEM = [1100.700, 1102.140]
# p5 (H100, sm_90)
ns_p5_1g_benchMEM  = [320.500, 321.220]
ns_p5_2g_benchMEM  = [620.700, 621.140]
ns_p5_4g_benchMEM  = [1180.500, 1181.220]
ns_p5_8g_benchMEM  = [2200.700, 2202.140]

# GPU — benchPEP-h --------------------------------------------------------
ns_g6e_1g_benchPEPh = [4.520, 4.535]
# ... and so on for the other seven cells
```

The empty data lists in `generate_charts.py` show every
cell that needs filling. Then flip the gate near the top of the script:

```python
data_available_gpu = True
```

From the repo root, run `python3 Doc/img/Gromacs/generate_charts.py`. The
script writes `Gromacs-benchMEM-P5VsG6e.png` and
`Gromacs-benchPEP-h-P5VsG6e.png` next to itself. The GPU chart subsection
in [`apps/Gromacs/README.md`](../README.md) already embeds these PNGs by
raw-content URL — no edit to the README is required once the PNGs land
in `Doc/img/Gromacs/` on `main`. They'll start rendering automatically
the moment the commit reaches the default branch.

`git add Doc/img/Gromacs/Gromacs-*-P5VsG6e.png Doc/img/Gromacs/generate_charts.py`
and commit.

## Why this isn't auto-submitted

Same three reasons as the Phase 1 and Phase 2 sweeps, ported to the GPU
cluster:

1. **Cost** — 32 g6e/p5 jobs at 1-8 GPUs consume real cluster hours that
   bill against an internal AWS account. p5 (H100) hourly cost is
   meaningfully higher than the CPU partitions, so an operator
   confirmation step matters more here than on the CPU sweeps.
2. **Determinism** — running the sweep before tasks 17 and 18 are
   validated produces records the chart pipeline can't consume (e.g.
   GPU_COUNT validation broken, topology classification misreporting
   NVSwitch as PCIe, or the `-nb gpu -pme gpu -bonded gpu -update gpu`
   offload split silently falling back to CPU on smaller GPUs). The
   prerequisite checklist above exists to prevent that.
3. **DynamoDB blast radius** — the `Gromacs_Benchmarks` table is shared
   across teams and across phases (Phase 1 and Phase 2 records are still
   in the table); ad-hoc auto-runs would clutter it with mis-tagged
   records. The scan helper has a `--since` knob exactly so we can scope
   to a known sweep window without filtering on opaque job-id lists.

When the prerequisites are green and the operator wants to run the
sweep, there's nothing surprising — `scaling_sweep_manifest.sh` is a
one-line invocation that prompts before submitting and emits a job
table the operator can hand to `squeue` / `scan_sweep.sh` to follow up.
