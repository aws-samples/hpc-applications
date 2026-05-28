# Phase 2 GROMACS — task 13 checkpoint hand-off

This document is the status sheet for spec task **13** in
[`tasks.md`](../../../.kiro/specs/gromacs-support/tasks.md):

> Checkpoint — verify Arm scripts:
> - `shellcheck --shell=bash apps/Gromacs/Arm/{build_gromacs_arm,gromacs-benchmark}.sbatch` clean
> - Smoke build on hpc7g (OpenMPI 5 default) and m8g (OpenMPI 5); confirm both Thread_MPI and Library_MPI variants installed and `gmx --version` reports `Acceleration … ARM_SVE`
> - Smoke benchmark on hpc7g (1N, RNAse) and m8g (1N, benchMEM); confirm `Performance:` is parsed
> - 4N benchPEP-h on m8g at 192 rpn — confirms OpenMPI 5 endpoint scaling

The task mixes **static checks** (locally verifiable from the repo) with
**live cluster smoke runs** (require SSH access to the Arm cluster head
node `ec2-user@10.3.51.188`, reached via bastion `ec2-user@3.128.184.207`).
The live items are handed off to the cluster operator; nothing on a
developer laptop can submit them.

## Status

| Item | Type | Status |
|---|---|---|
| `shellcheck` on `build_gromacs_arm.sbatch` and `gromacs-benchmark.sbatch` | Static (local) | **Clean** (exit 0, no findings — shellcheck 0.11.0) |
| `shellcheck` on `scaling_sweep_manifest.sh` | Static (local) | **Clean** (exit 0, no findings) |
| `bash -n` syntax parse on all three Arm shell artifacts | Static (local) | **Clean** (exit 0) |
| Smoke build on hpc7g (Graviton3E, OpenMPI 5 default) | Live (cluster) | **Pending operator** |
| Smoke build on m8g (Graviton4, OpenMPI 5) | Live (cluster) | **Pending operator** |
| Smoke benchmark hpc7g 1N RNAse | Live (cluster) | **Pending operator** |
| Smoke benchmark m8g 1N benchMEM | Live (cluster) | **Pending operator** |
| Smoke benchmark m8g 4N benchPEP-h at 192 rpn | Live (cluster) | **Pending operator** |

The static checks have run on this branch. shellcheck 0.11.0 reports no
issues for any of the three Arm shell artifacts; `bash -n` also parses
all three cleanly.

> **Capacity note:** `hpc8a` is currently unavailable, but task 13 only
> exercises `hpc7g` (Graviton3E) and `m8g` (Graviton4) partitions, so
> the Arm checkpoint is not blocked by the x86 capacity gap.

## Operator acceptance criteria

The cluster operator runs the live smoke items. Each row below names
the submission and the exact line / file the operator must observe to
mark the row green.

### 1. Smoke build — hpc7g (Graviton3E, OpenMPI 5 default)

```bash
sbatch -p hpc7g apps/Gromacs/Arm/build_gromacs_arm.sbatch
```

Acceptance:

- Job exits `0` with no error in
  `/fsx/gromacs/logs/build_arm_<jobid>.{out,err}`.
- `ls /fsx/gromacs/aarch64-graviton3-ompi5/v2024.4/{tmpi,ompi}/bin/gmx*`
  returns two binaries:
  - `…/tmpi/bin/gmx` (Thread_MPI variant)
  - `…/ompi/bin/gmx_mpi` (Library_MPI variant)
- `/fsx/gromacs/aarch64-graviton3-ompi5/v2024.4/tmpi/bin/gmx --version | grep 'Acceleration'`
  prints a line containing `ARM_SVE`.
- The matching env scripts exist:
  - `/fsx/gromacs/aarch64-graviton3-ompi5/v2024.4/gromacs-v2024.4-tmpi-env.sh`
  - `/fsx/gromacs/aarch64-graviton3-ompi5/v2024.4/gromacs-v2024.4-ompi5-env.sh`

### 2. Smoke build — m8g (Graviton4, OpenMPI 5)

```bash
sbatch -p m8g --ntasks-per-node=192 apps/Gromacs/Arm/build_gromacs_arm.sbatch
```

(The `--ntasks-per-node=192` override matches m8g's vCPU count and is
defensive — the build itself only consumes `COMPILE_CORES` for the
compile step, but the SBATCH default of 64 in this script is shaped for
hpc7g; on m8g we let slurm see all 192 slots.)

Acceptance:

- Job exits `0`.
- `ls /fsx/gromacs/aarch64-graviton4-ompi5/v2024.4/{tmpi,ompi}/bin/gmx*`
  returns two binaries.
- `/fsx/gromacs/aarch64-graviton4-ompi5/v2024.4/tmpi/bin/gmx --version | grep 'Acceleration'`
  reports `ARM_SVE`.
- Build log shows `-mcpu=neoverse-v2` was passed to the C/C++ compiler
  flags (Graviton4 auto-detect from `/proc/cpuinfo` worked).
- `mpirun --version` printed by the OpenMPI 5 env script in the build
  log reports a 5.x version (confirms `OMPI_VERSION=5` was forced for
  Graviton4 per Requirement 3.7).

### 3. Smoke benchmark — hpc7g 1N RNAse

```bash
sbatch -p hpc7g --nodes=1 \
       --export=ALL,MODEL=RNAse \
       /fsx/gromacs/scripts/Arm/gromacs-benchmark.sbatch
```

Note: the live submissions point at the cluster-deployed copy under
`/fsx/gromacs/scripts/Arm/`, not the in-repo copy. The cluster copy is
deployed from `apps/Gromacs/Arm/gromacs-benchmark.sbatch` with the
DynamoDB recorder block at the bottom **uncommented** so the sweep
results land in the `Gromacs_Benchmarks` table; the repo copy that
shellcheck validates ships with that block commented out.

Acceptance:

- Job exits `0` within ~10 minutes.
- The slurm log contains a `Performance:` line of the form
  `Performance: <ns_per_day> <hour_per_ns>` with `<ns_per_day> > 0`.
- The launcher's results-summary block is printed and `ns/day:` and
  `Wall time (s):` are non-zero (proves the awk extraction in
  `gromacs-benchmark.sbatch` parses the `md.log` correctly).
- The EFA verification block (`fi_info -p efa`, `mpirun --version`,
  `ldd`) is printed before the `mpirun` call. (Single-node still
  prints the block — only the rank count differs.)

### 4. Smoke benchmark — m8g 1N benchMEM

```bash
sbatch -p m8g --nodes=1 \
       --ntasks-per-node=192 \
       --export=ALL,MODEL=benchMEM \
       /fsx/gromacs/scripts/Arm/gromacs-benchmark.sbatch
```

Acceptance:

- Job exits `0`.
- `Performance:` line present and parsed; `ns/day:` non-zero in the
  results-summary block.
- `--ntasks-per-node=192` is observed in the slurm log (m8g is the
  only Arm partition that requires the override; hpc7g's default of 64
  is correct).
- `Mapping ranks per node: 192` (or equivalent) appears in the
  launcher's MCA selection / mapping summary.

### 5. Multi-node — m8g 4N benchPEP-h at 192 rpn (OpenMPI 5 endpoint scaling)

```bash
sbatch -p m8g --nodes=4 \
       --ntasks-per-node=192 \
       --export=ALL,MODEL=benchPEP-h \
       /fsx/gromacs/scripts/Arm/gromacs-benchmark.sbatch
```

Acceptance:

- Job exits `0`.
- The EFA verification block reports `fi_info -p efa -t FI_EP_RDM`
  with at least one provider line present (verifies the multi-node
  EFA path).
- `mpirun --version` (printed by the EFA verification block) reports
  a 5.x version — proves the Library_MPI build that was selected is
  linked against OpenMPI 5, which is the prerequisite for 192 rpn ×
  4N endpoint scaling.
- The three-line MCA selection block prints with
  `pml=cm`, `mtl=ofi`, `provider=efa`.
- Total ranks = 4 × 192 = **768** (visible in the `mpirun` command-line
  echoed at job start).
- `Performance:` line present; `ns/day:` non-zero in the
  results-summary block.
- No `mca_mtl_ofi: ofi_progress` errors or `endpoint allocation failed`
  / `Insufficient resources` messages — that's the OpenMPI 5 endpoint
  scaling the task explicitly calls out. The hpc7g + m8g + 192 rpn
  combination is what stresses the OFI / libfabric endpoint table the
  most; an OpenMPI 4 build of the same workload would typically fail
  here, which is why Phase 2 mandates OpenMPI 5 for both partitions.

## Live items reference

The five live items above are the same prerequisites that gate the
Phase 2 scaling sweep — see prerequisites #1 and #2 in
[`SCALING_SWEEP.md`](SCALING_SWEEP.md). When the operator marks these
green, task 13 is complete and the scaling sweep (task 14.2) can run on
the same green checklist.

If any of the live items fails, the operator should:

1. Capture the slurm `.out` / `.err` files and `md.log` from the run
   directory under `/fsx/gromacs/Run/gromacs/<model>/<cluster>/<jobid>-…/`.
2. File a finding here (or in the spec task tracker) so it can be
   diagnosed before task 14.2 runs the 24-job sweep.

## Why the live items don't run from the dev workspace

Same three reasons that gate the sweep itself, scoped to a smoke
submission:

1. **No SSH path** — the dev workspace doesn't have credentials for
   the bastion / Arm head node and shouldn't (production-style
   credentials).
2. **Cluster cost** — even smoke jobs on hpc7g / m8g consume real
   capacity that bills against an internal account.
3. **Determinism** — running smoke jobs against a build that hasn't
   been re-deployed since a script edit produces logs that are stale
   relative to the change under review.

The static checks (shellcheck + `bash -n`) catch the class of failure
that *can* be diagnosed without a cluster — syntax, quoting, unused
variables, common shell foot-guns. Those are run here on every change.

