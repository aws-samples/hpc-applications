# LAMMPS

This directory contains scripts for building and benchmarking [LAMMPS](https://www.lammps.org/) on AWS HPC instances. LAMMPS (Large-scale Atomic/Molecular Massively Parallel Simulator) is the de-facto standard open-source molecular dynamics code from Sandia National Laboratories, used in materials science, chemistry, and physics.

The scripts are organised by CPU architecture:

- [`x86/`](x86/) — builds and benchmarks for x86_64 (`hpc8a`, `hpc7a`)
- [`Arm/`](Arm/) — builds and benchmarks for aarch64 (`hpc7g` / Graviton3E, `m8g` / Graviton4)

LAMMPS is a single-binary code: one executable (`lmp`) covers serial, MPI, OpenMP, and hybrid MPI+OpenMP execution. The binary is selected at build time via CMake package flags, and the input deck drives all run-time behaviour: the benchmarks run LAMMPS's own `bench/` decks (see [Benchmark](#benchmark)).

## x86 build

A single build script targets hpc8a (Zen5) and hpc7a (Zen4) — both AMD EPYC with AVX-512 — using GCC + system OpenMPI 4.1.7:

```bash
sbatch x86/build_lammps_x86.sbatch
```

- Compiler: GCC 11.5 (system, AL2023)
- Flags: `-O3 -march=x86-64-v4 -mtune=znver4 -DNDEBUG` (AVX-512, Zen 4/5 tuning)
- MPI: system OpenMPI 4.1.7 at `/opt/amazon/openmpi` (EFA-enabled at runtime)
- Install location: `/fsx/lammps/x86_64/<tag>/`
- Environment script: `/fsx/lammps/x86_64/lammps-<tag>-env.sh`
- Build time: ~10 minutes

GCC 11.5 doesn't know `znver5`, so Zen 5 (hpc8a) is compiled with `-mtune=znver4` — AVX-512 is still emitted and the binary runs at full speed on Zen 5. We only miss a handful of Zen 5-only scheduling tweaks.

Override via `--export=ALL,...`:

| Variable | Default | Description |
|----------|---------|-------------|
| `LAMMPS_TAG` | `stable_2Aug2023_update3` | Release tag from the [LAMMPS GitHub releases](https://github.com/lammps/lammps/releases) |
| `TARGET_CPU` | `hpc8a` | `hpc8a` / `hpc7a` (AVX-512 Zen 4/5) or `generic-avx2` (portable Zen 3+) |
| `BASE_DIR` | `/fsx/lammps` | Install root |
| `COMPILE_CORES` | `48` | Parallel compile threads |

The x86 results under [Performance](#performance) were measured with a build made the same way: this script's default tag and `TARGET_CPU`, compiler, flags, packages and OpenMPI. One binary ran on both `hpc8a` and `hpc7a`.

## Arm build

A single build script targets both Graviton generations. The generation is auto-detected from `/proc/cpuinfo` (`CPU part` field: `0xd40` = Neoverse V1 / Graviton3E, `0xd4f` = Neoverse V2 / Graviton4) so the same script works on hpc7g (16xlarge) and m8g (48xlarge). Build time ~10 min.

### Which OpenMPI version?

Two `OMPI_VERSION` knobs are supported, mirroring the OpenRadioss and OpenFOAM conventions:

- `OMPI_VERSION=4` (default) — builds against system OpenMPI 4.1.7 at `/opt/amazon/openmpi`, for Graviton3E at full density (64 ranks/node). At Graviton4's 192 ranks/node it reaches an EFA endpoint limit, so use `OMPI_VERSION=5` there.
- `OMPI_VERSION=5` — builds against system OpenMPI 5.0.9 at `/opt/amazon/openmpi5`. Handles full-density EFA on both platforms. **Use this for Graviton4.**

```bash
# Graviton3E (hpc7g.16xlarge, 64 cores) — OpenMPI 4 default
sbatch -p hpc7g --ntasks-per-node=64 \
  Arm/build_lammps_arm.sbatch

# Graviton4 (m8g.48xlarge, 192 cores) — OpenMPI 5 required for 192 rpn
sbatch -p m8g --ntasks-per-node=192 \
  --export=ALL,OMPI_VERSION=5 Arm/build_lammps_arm.sbatch
```

Install locations (named after the detected target + OpenMPI generation):

| Target | OpenMPI | Install prefix | Env script |
|--------|---------|----------------|------------|
| Graviton3E | 4.1.7 | `/fsx/lammps/aarch64-graviton3` | `aarch64-graviton3/lammps-<tag>-env.sh` |
| Graviton3E | 5.0.9 | `/fsx/lammps/aarch64-graviton3-ompi5` | `aarch64-graviton3-ompi5/lammps-<tag>-ompi5-env.sh` |
| Graviton4 | 5.0.9 | `/fsx/lammps/aarch64-graviton4-ompi5` | `aarch64-graviton4-ompi5/lammps-<tag>-ompi5-env.sh` |

Override via `--export=ALL,...`:

| Variable | Default | Description |
|----------|---------|-------------|
| `LAMMPS_TAG` | `stable_2Aug2023_update3` | Release tag to build |
| `OMPI_VERSION` | `4` | `4` or `5` |
| `TARGET` | `auto` | `graviton3` or `graviton4` to override CPU auto-detection |
| `BASE_DIR` | `/fsx/lammps` | Install root |
| `COMPILE_CORES` | `48` | Parallel compile threads |

### Enabled CMake packages

Both build scripts enable the same package set, sufficient to run all the benchmarks below plus most common LAMMPS workloads:

| Package | Enables |
|---------|---------|
| `KSPACE` | Long-range electrostatics (PPPM) — required for Rhodopsin |
| `MANYBODY` | EAM, Tersoff, ADP potentials — required for EAM |
| `MOLECULE` | Bonds, angles, dihedrals — required for Rhodopsin |
| `RIGID` | Rigid bodies, SHAKE — required for Rhodopsin (water constraints) |
| `REPLICA` | Replica exchange MD |
| `MISC` | Assorted utilities |
| `EXTRA-DUMP`, `EXTRA-FIX` | Common output formats |

## Benchmark

Four models from the upstream LAMMPS [`bench/`](https://github.com/lammps/lammps/tree/stable/bench) directory are supported via the `MODEL` environment variable. Each has a default size and number of timesteps (see [Run length](#run-length)); `SCALE` and `TIMESTEPS` override them:

| `MODEL` | Deck | Workload | Force field | Default `SCALE` | Atoms at the default | Default `TIMESTEPS` |
|---------|------|----------|-------------|----------------:|---------------------:|--------------------:|
| `lj` (default) | `in.lj` | Lennard-Jones melt | Pair potential only | 8 | 16,384,000 | 15,000 |
| `rhodo_scaled` | `in.rhodo.scaled` | Rhodopsin protein in water | CHARMM + PPPM | 4 | 2,048,000 | 6,000 |
| `eam` | `in.eam` | Cu metal | EAM many-body | 4 | 2,048,000 | 30,000 |
| `rhodo` | `in.rhodo` | Rhodopsin protein in water | CHARMM + PPPM | — | 32,000 | 6,000 |

The atom count is 32,000 × `SCALE`³: `in.lj`, `in.eam` and `in.rhodo.scaled` replicate their box `SCALE` times along each axis, which makes `SCALE` the knob for weak-scaling studies. `in.rhodo` has no `replicate` command, so `MODEL=rhodo` runs its 32,000 atoms whatever `SCALE` is; to scale the rhodopsin model, use `MODEL=rhodo_scaled` (at `SCALE=1` it is the same 32,000 atoms). For `eam` at `SCALE=1` (32,000 atoms), the EAM neighbour-list build does not parallelise well past about 64 ranks: use `SCALE=2` or more at higher rank counts.

Input decks are tiny (~1 KB each) and are auto-fetched from the LAMMPS GitHub repo on first run, then cached on FSx at `/fsx/lammps/benchmarks/<model>/`.

### Run length

The `bench/` decks end with `run 100`. At the sizes most runs use, a 100-step loop is short and the wall time is mostly start-up: in 56 runs of `lj` (`SCALE=1` and `4`), `rhodo` and `eam` (`SCALE=1`) on 1 to 4 nodes of `hpc8a.96xlarge`, `hpc7a.96xlarge`, `c7gn.16xlarge`, `m8g.48xlarge`, `hpc6id.32xlarge`, `r8i.96xlarge` and `i7i.48xlarge` (May and June 2026), the loop was a median 4.3% of the launcher's wall time, and at most 45%. Most of these runs overlapped 1 to 6 others of the same study on a shared FSx for Lustre file system; the 13 that ran alone gave a median of 5.0%. With `MODEL=rhodo_scaled` at `SCALE=16` (2 runs) the 100-step loop was 95% of the launcher's wall time.

None of the decks reads a step-count variable, so a `-var` on the command line alone does not change their 100 steps. The benchmark scripts copy the deck into the run directory with its `run 100` line made `run ${nsteps}`, and pass `-var nsteps` with the run length: the model's default `TIMESTEPS` above, or yours. The cached deck is not edited, and a deck without exactly one plain `run <steps>` line stops the job before any rank starts.

At the defaults the loop dominates: for `lj`, `rhodo_scaled` and `eam` it was 97–100% of LAMMPS's `Total wall time` in every run under [Performance](#performance), on 1 to 8 nodes. A run's work grows with atoms × timesteps, so change `TIMESTEPS` when you change `SCALE`: a larger `SCALE` at the same `TIMESTEPS` runs longer (raise `sbatch --time`, or lower `TIMESTEPS`), and a smaller one may need more timesteps for the loop to dominate. `MODEL=rhodo` runs `rhodo_scaled`'s 6,000 timesteps on its 32,000 atoms. To check any run, compare `Loop time` with `Total wall time` in its `log.lammps`.

### x86

```bash
# LJ on hpc8a (default), 1 node: SCALE=8, 15,000 timesteps
sbatch --nodes=1 x86/lammps-benchmark.sbatch

# Replicated rhodopsin (SCALE=4) scaling sweep on hpc8a
for N in 1 2 4 8; do
  sbatch --nodes=$N --export=ALL,MODEL=rhodo_scaled \
    x86/lammps-benchmark.sbatch
done

# EAM on hpc7a, 4 nodes, with 8x the default atoms (SCALE=8) and an eighth of its timesteps
sbatch -p hpc7a --ntasks-per-node=192 --nodes=4 \
  --export=ALL,MODEL=eam,SCALE=8,TIMESTEPS=3750 \
  x86/lammps-benchmark.sbatch
```

### Arm

The Arm launcher has the same defaults, which were sized on the 192-core x86 nodes above and not measured on Graviton. A run's time grows with `TIMESTEPS`, so for a quick check, on the 64-core `hpc7g` for example, set a smaller one (`TIMESTEPS=1500` runs a tenth of `lj`'s default).

```bash
# Graviton3E (hpc7g) — LJ, 1 node
sbatch -p hpc7g --ntasks-per-node=64 --nodes=1 \
  --export=ALL,LAMMPS_ENV=/fsx/lammps/aarch64-graviton3/lammps-stable_2Aug2023_update3-env.sh \
  Arm/lammps-benchmark.sbatch

# Graviton4 (m8g) — Rhodopsin, 4 nodes
sbatch -p m8g --ntasks-per-node=192 --nodes=4 \
  --export=ALL,MODEL=rhodo_scaled,LAMMPS_ENV=/fsx/lammps/aarch64-graviton4-ompi5/lammps-stable_2Aug2023_update3-ompi5-env.sh \
  Arm/lammps-benchmark.sbatch
```

All benchmark launchers:

- Use EFA for inter-node MPI (verified at job start via `fi_info`, `mpirun --version`, and a `ldd | grep libmpi|libfabric` sanity block in the slurm log)
- Print the OpenMPI MCA component selection at job start (`pml=cm`, `mtl=ofi`, `provider=efa`) so the log has direct evidence of the EFA fast path
- Create a unique run directory under `/fsx/lammps/Run/`
- Copy the deck into it and set the deck's run length (see [Run length](#run-length))
- Drop page caches and enable transparent huge pages before the run
- Extract `Loop time of N on M procs for K steps with L atoms` from `log.lammps` and compute timesteps/sec and atom-steps/sec
- Record results to DynamoDB (see below)

On `hpc8a.96xlarge` and `hpc7a.96xlarge` the x86 launcher takes 24, 48, 72, 96, 120, 144, 168 or 192 cores per node (`--ntasks-per-node`), the [flexible-cores](../../Utils/flexible-cores/) counts that give each of the node's 24 CCDs the same number of cores; at any other count it stops before LAMMPS starts, with a message that names them. With fewer than 192 MPI ranks per node (pure MPI) it pins the ranks with the flexible-cores lists. The lists cover pure MPI only: on these two types, run hybrid layouts (`THREADS_PER_RANK` above 1) on full nodes. If the instance metadata does not answer with an instance type within a few seconds, and the type would change what the job does (a count other than those eight, or a pure-MPI count below 192, which the lists pin), the job log says so in a `NOTE:` line: a node whose CPU `lscpu` shows as AMD with 192 cores, as on these two types, then gets the same check and lists, and any other node runs without them. No run is refused only because the instance metadata did not answer. Other instance types get no list (ranks are mapped by slot), so run full nodes there. The results under [Performance](#performance) are for full nodes.

### Overrides

| Variable | Default | Description |
|----------|---------|-------------|
| `LAMMPS_ENV` | see script | Path to environment setup script (select the build you want) |
| `MODEL` | `lj` | `lj` / `rhodo_scaled` / `eam` / `rhodo` (see [Benchmark](#benchmark)) |
| `SCALE` | per model | Lattice replication factor — atom count scales as `SCALE^3` (`MODEL=rhodo` ignores it) |
| `TIMESTEPS` | per model | Number of timesteps to run, from 1 to 10,000,000 (see [Run length](#run-length)) |
| `THREADS_PER_RANK` | `1` | OpenMP threads per MPI rank. Pure MPI (default) is fastest for these models on this hardware |
| `BASE_DIR` | `/fsx/lammps` | Root for run output directories |
| `EFA_VERBOSE` | `0` | Set to `1` to add `--mca mtl_base_verbose 5 --mca pml_base_verbose 5` — useful once to confirm the EFA path, very noisy |

To record each successful run to a centralised DynamoDB table, see [`dynamodb/`](dynamodb/) — the launchers ship with the recorder block commented out so DynamoDB is opt-in.

## Performance

### x86 — hpc8a (Zen5) vs hpc7a (Zen4), 1 to 8 nodes

This chart shows the scaling of LAMMPS `stable_2Aug2023_update3` on three `bench/` decks at their default sizes and run lengths (see [Benchmark](#benchmark)), on 1 to 8 nodes of [hpc8a](https://aws.amazon.com/ec2/instance-types/hpc8a/) and [hpc7a](https://aws.amazon.com/ec2/instance-types/hpc7a/) instances: `lj` at `SCALE=8` (16,384,000 atoms, 15,000 timesteps), `rhodo_scaled` at `SCALE=4` (2,048,000 atoms, 6,000 timesteps) and `eam` at `SCALE=4` (2,048,000 atoms, 30,000 timesteps).

Every node is fully populated with 192 MPI ranks and one OpenMP thread per rank, bound with `--bind-to core --map-by slot`, over EFA with OpenMPI 4.1.7 (`pml cm`, `mtl ofi`); one binary of the [x86 build](#x86-build) ran on both instance types. Performance is LAMMPS's own `Total wall time` (see [Key metrics](#key-metrics)), the median over each configuration's runs, relative to one `hpc7a.96xlarge` node running the same deck = 1.00× — higher is better. The percentages are each instance type's parallel efficiency against its own single node.

![LAMMPS bench decks on hpc8a and hpc7a, 1 to 8 nodes](https://github.com/aws-samples/hpc-applications/blob/main/Doc/img/LAMMPS/LAMMPS-Hpc8aVsHpc7a-Scaling.png?raw=true)

Relative performance (1 node `hpc7a.96xlarge` running the same deck = 1.00×), with parallel efficiency:

| Deck | Instance type | 1 node | 2 nodes | 4 nodes | 8 nodes |
|------|---------------|-------:|--------:|--------:|--------:|
| `lj`, `SCALE=8` | hpc8a.96xlarge | 1.39× | 2.97× (107%) | 6.31× (113%) | 11.71× (105%) |
| | hpc7a.96xlarge | 1.00× | 2.16× (108%) | 4.41× (110%) | 7.96× (100%) |
| `rhodo_scaled`, `SCALE=4` | hpc8a.96xlarge | 1.46× | 2.65× (90%) | 4.21× (72%) | 4.68× (40%)¹ |
| | hpc7a.96xlarge | 1.00× | 1.80× (90%) | 2.76× (69%) | 2.92× (37%)¹ |
| `eam`, `SCALE=4` | hpc8a.96xlarge | 1.31× | 2.41× (92%) | 4.01× (76%) | 7.46× (71%) |
| | hpc7a.96xlarge | 1.00× | 1.82× (91%) | 2.95× (74%) | 4.94× (62%) |

¹ A single run, where `rhodo_scaled` runs at 40% parallel efficiency or less; every other value is the median of 3 runs.

`hpc8a.96xlarge` against `hpc7a.96xlarge` at the same node count (the `hpc7a` time over the `hpc8a` time):

| Deck | 1 node | 2 nodes | 4 nodes | 8 nodes |
|------|-------:|--------:|--------:|--------:|
| `lj`, `SCALE=8` | 1.39× | 1.38× | 1.43× | 1.47× |
| `rhodo_scaled`, `SCALE=4` | 1.46× | 1.47× | 1.53× | 1.60×¹ |
| `eam`, `SCALE=4` | 1.31× | 1.33× | 1.36× | 1.51× |

The runs were made in October 2026 on one AWS ParallelCluster 3.16 cluster in eu-north-1, each run its own Slurm job on exclusive nodes, after the page cache was dropped and THP set to `always`. The runs of each configuration agree within 5%. Up to 4 other benchmark jobs shared the cluster's FSx for Lustre file system at a run's start or end; these decks write no trajectory or restart files.

Key takeaways:

- **`lj` scales near-linearly to 8 nodes:** 100–113% parallel efficiency on 2 to 8 nodes of either type, above 100% on 2 and 4 nodes, where the run time fell more than in proportion to the node count. Its EC2 time per run (nodes × time) on 2 to 8 nodes is 0.88–1.00× that of one node.
- **`eam` and `rhodo_scaled`, with an eighth of `lj`'s atoms (2,048,000 each), scale less.** `eam` keeps 91–92% on 2 nodes, 74–76% on 4 and 62–71% on 8. `rhodo_scaled` keeps 90% on 2 nodes and 69–72% on 4, but 8 nodes (a single run on each type¹) run it only 1.06–1.11× as fast as 4: at 37–40% efficiency, a run takes 2.5–2.7× the EC2 time of a one-node run.
- **hpc8a against hpc7a:** one `hpc8a.96xlarge` node runs these decks 1.31–1.46× as fast as one `hpc7a.96xlarge` node, and 8 `hpc8a` nodes run them 1.47–1.60× as fast as 8 `hpc7a` nodes (the 1.60× is `rhodo_scaled`'s, from single runs¹).

### Arm — Graviton3E (c7gn) vs Graviton4 (m8g)

These runs measured the decks' own 100-step loop: the Lennard-Jones melt deck (`in.lj`) at `SCALE=4` (2,048,000 atoms) for 100 timesteps, pure MPI (1 OpenMP thread per rank), compared on the LAMMPS-reported `Loop time` (the mean of 3 runs per point), which leaves the start-up out. To run the same, add `SCALE=4,TIMESTEPS=100` to `--export`.

The Graviton3E runs used `c7gn.16xlarge`, which EC2 lists with the same 64 cores, clock, memory and EFA network bandwidth as `hpc7g.16xlarge`, and the OpenMPI 4.1.7 build (`-mcpu=neoverse-v1`); the Graviton4 runs used `m8g.48xlarge` and the OpenMPI 5.0.9 build (`-mcpu=neoverse-v2`), which Graviton4 needs at 192 rpn (see [Which OpenMPI version?](#which-openmpi-version)). c7gn runs 64 ranks/node; m8g runs 192 ranks/node. Performance is normalised to a single `c7gn.16xlarge` node — higher is better.

![LAMMPS LJ Graviton3E vs Graviton4](https://github.com/aws-samples/hpc-applications/blob/main/Doc/img/LAMMPS/LAMMPS-LJ-Graviton3VsGraviton4.png?raw=true)

| Nodes | c7gn (64 c/n) | m8g (192 c/n) |
|------:|--------------:|--------------:|
| 1 | 1.00× | **4.08×** |
| 2 | 1.88× | **5.48×** |
| 4 | 3.23× | — |

Key takeaways:

- A single m8g node delivers **4.08×** the performance of a single c7gn node — consistent with the 3× core-count ratio (192 vs 64) plus the larger L2/L3 caches and faster DDR5 on Neoverse V2
- **c7gn keeps 81% parallel efficiency on 4 nodes** (3.23×) — the smaller 64-core nodes never run out of parallel work for 2M atoms

## Key metrics

- **Loop time** — LAMMPS' internal wall-clock measurement inside the time-integration loop, excluding setup and final I/O. Reported as `Loop time of <X> on <Y> procs for <Z> steps with <W> atoms` near the end of the run.
- **Total wall time** — LAMMPS's own total, the last line of `log.lammps` (`Total wall time: H:MM:SS`): setup, the loop and the final output, without the MPI start-up. The x86 results under [Performance](#performance) compare it.
- **Timesteps/sec** — derived as `timesteps / loop_time` — useful for comparing across models with different timestep budgets.
- **Atom-steps/sec** — derived as `atoms * timesteps / loop_time` — the workload-normalised metric, useful when comparing different atom counts (e.g. `SCALE` sweeps).
- **Wall time** — total mpirun wall time including MPI startup and final output, measured by the launcher.

At a run length where the loop dominates (see [Run length](#run-length)), `Loop time` and `Total wall time` give the same comparison: on either one, the x86 results under Performance agree within 3%. The launcher's `Wall time` also holds the MPI start-up, so compare it only once the loop dominates it too.

## Files

### x86 ([`x86/`](x86/))

| File | Description |
|------|-------------|
| `build_lammps_x86.sbatch` | Build LAMMPS with GCC + OpenMPI 4 (AVX-512, Zen 4/5) |
| `lammps-benchmark.sbatch` | Run LJ / Rhodopsin / EAM with EFA |

### Arm ([`Arm/`](Arm/))

| File | Description |
|------|-------------|
| `build_lammps_arm.sbatch` | Build LAMMPS with GCC + OpenMPI 4 or 5 (auto-detects Graviton3E / Graviton4) |
| `lammps-benchmark.sbatch` | Run LJ / Rhodopsin / EAM — pick the build via `LAMMPS_ENV` |

### DynamoDB result store (optional, [`dynamodb/`](dynamodb/))

| File | Description |
|------|-------------|
| `record-benchmark.sh` | Contribution recorder the launchers call after every successful run (see [Contribute your results](#contribute-your-results)) |
| `record_to_dynamodb.sh` | Optional helper that records each benchmark run to a centralised DynamoDB table |
| `README.md` | Table schema, IAM permissions, and setup instructions |

### Tests ([`tests/`](tests/))

| File | Description |
|------|-------------|
| `run-tests.sh` | Runs every shell test, then `bash -n` over the LAMMPS scripts |
| `test-sbatch-e2e.sh` | Runs both benchmark scripts end to end, with stubbed Slurm, IMDS, MPI and `lmp`; [`tests/README.md`](tests/README.md) lists what it checks |

## Contribute your results

The benchmark scripts in this folder call [`dynamodb/record-benchmark.sh`](dynamodb/record-benchmark.sh) after every successful run: one whose `log.lammps` reports the requested `TIMESTEPS` on its `Loop time` line and ends with LAMMPS's `Total wall time`. For any other run the job log says `NOTE: not recorded: <why>` and the contribution recorder is not called; the job's exit status and results block are unchanged. The recorder saves the run as a small JSON record (`<record_id>.json`) and adds it to the shared AI-Powered HPC benchmark dataset when you have write access to it. That dataset trains a model that predicts HPC performance on AWS, so every result you share helps. Set `SOURCE=<YourOrg>` to tag your runs, and see [BENCHMARK-RECORDERS.md](../BENCHMARK-RECORDERS.md) for the options and how to send the record in. Each record carries the model, its `SCALE` and atom count, and the timesteps LAMMPS ran, so that runs of different sizes and lengths stay apart.

This is separate from the optional `record_to_dynamodb.sh` uploader described above, which stays off unless you enable it. Once enabled, it records only the runs the contribution recorder records, after the same check. To point the launchers at another copy of the contribution recorder, set `CONTRIB_RECORDER`.
