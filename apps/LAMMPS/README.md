# LAMMPS

This directory contains scripts for building and benchmarking [LAMMPS](https://www.lammps.org/) on AWS HPC instances. LAMMPS (Large-scale Atomic/Molecular Massively Parallel Simulator) is the de-facto standard open-source molecular dynamics code from Sandia National Laboratories, used in materials science, chemistry, and physics.

The scripts are organised by CPU architecture:

- [`x86/`](x86/) — builds and benchmarks for x86_64 (`hpc8a`, `hpc7a`)
- [`Arm/`](Arm/) — builds and benchmarks for aarch64 (`hpc7g` / Graviton3E, `m8g` / Graviton4)

LAMMPS is a single-binary code: one executable (`lmp`) covers serial, MPI, OpenMP, and hybrid MPI+OpenMP execution. The binary is selected at build time via CMake package flags, and the input deck (the `.lj`, `.rhodo`, `.eam` scripts in this repo's benchmark cache) drives all run-time behaviour.

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

## Arm build

A single build script targets both Graviton generations. The generation is auto-detected from `/proc/cpuinfo` (`CPU part` field: `0xd40` = Neoverse V1 / Graviton3E, `0xd4f` = Neoverse V2 / Graviton4) so the same script works on hpc7g (16xlarge) and m8g (48xlarge). Build time ~10 min.

### Which OpenMPI version?

Two `OMPI_VERSION` knobs are supported, mirroring the OpenRadioss and OpenFOAM conventions:

- `OMPI_VERSION=4` (default) — builds against system OpenMPI 4.1.7 at `/opt/amazon/openmpi`. Works cleanly on Graviton3E at full density (64 ranks/node). On Graviton4 at 192 ranks/node it hits an EFA endpoint exhaustion limit and fails to start.
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

Both build scripts enable the same package set, sufficient to run all three benchmarks below plus most common LAMMPS workloads:

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

Three standard LAMMPS benchmarks from the upstream [`bench/`](https://github.com/lammps/lammps/tree/stable/bench) directory are supported via the `MODEL` environment variable:

| `MODEL` | Workload | Force field | Default atoms (s=1) | Notes |
|---------|----------|-------------|--------------------:|-------|
| `lj` | Lennard-Jones melt | Pair potential only | 32,000 | Pure compute + nearest-neighbour MPI |
| `rhodo` | Rhodopsin protein in water | CHARMM + PPPM | 32,000 | Exercises long-range electrostatics |
| `eam` | Cu metal | EAM many-body | 32,000 | Exercises many-body potentials. **Use `SCALE>=2` at high rank counts** — at 32k atoms the EAM neighbour-list build does not parallelise well past ~64 ranks and the run can hang on collective calls |

Atom count scales as `SCALE^3` via lattice replication — `SCALE=2` gives ~256k atoms, `SCALE=4` gives ~2M atoms. Useful for weak-scaling studies.

Input decks are tiny (~1 KB each) and are auto-fetched from the LAMMPS GitHub repo on first run, then cached on FSx at `/fsx/lammps/benchmarks/<model>/`.

### x86

```bash
# LJ on hpc8a (default), 1 node
sbatch --nodes=1 x86/lammps-benchmark.sbatch

# Rhodopsin scaling sweep on hpc8a
for N in 1 2 4 8; do
  sbatch --nodes=$N --export=ALL,MODEL=rhodo \
    x86/lammps-benchmark.sbatch
done

# EAM on hpc7a with 2x lattice replication (8x atoms)
sbatch -p hpc7a --ntasks-per-node=192 --nodes=4 \
  --export=ALL,MODEL=eam,SCALE=2 \
  x86/lammps-benchmark.sbatch
```

### Arm

```bash
# Graviton3E (hpc7g) — LJ, 1 node
sbatch -p hpc7g --ntasks-per-node=64 --nodes=1 \
  --export=ALL,LAMMPS_ENV=/fsx/lammps/aarch64-graviton3/lammps-stable_2Aug2023_update3-env.sh \
  Arm/lammps-benchmark.sbatch

# Graviton4 (m8g) — Rhodopsin, 4 nodes
sbatch -p m8g --ntasks-per-node=192 --nodes=4 \
  --export=ALL,MODEL=rhodo,LAMMPS_ENV=/fsx/lammps/aarch64-graviton4-ompi5/lammps-stable_2Aug2023_update3-ompi5-env.sh \
  Arm/lammps-benchmark.sbatch
```

All benchmark launchers:

- Use EFA for inter-node MPI (verified at job start via `fi_info`, `mpirun --version`, and a `ldd | grep libmpi|libfabric` sanity block in the slurm log)
- Print the OpenMPI MCA component selection at job start (`pml=cm`, `mtl=ofi`, `provider=efa`) so the log has direct evidence of the EFA fast path
- Create a unique run directory under `/fsx/lammps/Run/`
- Drop page caches and enable transparent huge pages before the run
- Extract `Loop time of N on M procs for K steps with L atoms` from `log.lammps` and compute timesteps/sec and atom-steps/sec
- Record results to DynamoDB (see below)

### Overrides

| Variable | Default | Description |
|----------|---------|-------------|
| `LAMMPS_ENV` | see script | Path to environment setup script (select the build you want) |
| `MODEL` | `lj` | `lj` / `rhodo` / `eam` |
| `SCALE` | `1` | Lattice replication factor — atom count scales as `SCALE^3` |
| `TIMESTEPS` | model default | Override the deck's `-var t` value (number of timesteps) |
| `THREADS_PER_RANK` | `1` | OpenMP threads per MPI rank. Pure MPI (default) is fastest for these models on this hardware |
| `BASE_DIR` | `/fsx/lammps` | Root for run output directories |
| `EFA_VERBOSE` | `0` | Set to `1` to add `--mca mtl_base_verbose 5 --mca pml_base_verbose 5` — useful once to confirm the EFA path, very noisy |
| `DYNAMODB_TABLE` | `LAMMPS_Benchmarks` | Override the DynamoDB table name |
| `DYNAMODB_REGION` | `us-east-1` | Override the DynamoDB region |

## DynamoDB result store

Every benchmark run records its outcome to a DynamoDB table so results across instance types, node counts, models, and software versions can be queried after the fact without re-running jobs.

- **Table:** `LAMMPS_Benchmarks` in `us-east-1`
- **Partition key:** `job_id` (S) — the Slurm job ID
- **Sort key:** `config` (S) — `<nodes>N-<rpn>rpn-<model>-s<scale>` (e.g. `4N-192rpn-rhodo-s1`)
- **Billing:** on-demand
- **Failure handling:** if `aws dynamodb put-item` fails (network, IAM, throttling) the script prints a warning and exits successfully — the local `log.lammps` and the results block in the slurm output remain the authoritative record. The `dynamodb_record.json` file is preserved in the workdir for manual replay.

### Item schema

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

### Recreating the table

If you need to recreate the table in a fresh account or region:

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

### Required IAM permission

The compute node IAM role needs the following inline policy (or an equivalent managed policy):

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

On AWS PCS clusters, this is the `AWSPCS-...` instance role. On ParallelCluster clusters, it's the `<stack>-RoleHeadNode-...` and `<stack>-ComputeFleetQueuesNested-Role*-...` roles.

## Performance

All performance charts use the same methodology: **Lennard-Jones melt** input deck (`in.lj` from the LAMMPS `bench/` directory) with `SCALE=4` (lattice replication) producing **2,048,000 atoms**, run for **100 timesteps**, pure MPI (1 OpenMP thread per rank). Performance is expressed as **speedup over a 1-node baseline** computed from the LAMMPS-reported `Loop time` (mean of replicates).

### x86 — hpc8a (Zen5) vs hpc7a (Zen4)

The same binary (built with `-march=x86-64-v4 -mtune=znver4`) runs on both instance families, so the comparison isolates the hardware contribution from any compiler-driven differences. Performance is normalised to a single `hpc7a.96xlarge` node — higher is better.

![LAMMPS LJ hpc8a vs hpc7a](https://github.com/aws-samples/hpc-applications/blob/main/Doc/img/LAMMPS/LAMMPS-LJ-Hpc8aVsHpc7a.png?raw=true)

| Nodes | Cores | hpc7a | hpc8a |
|------:|------:|------:|------:|
| 1 | 192 | 1.00× | **1.39×** |
| 2 | 384 | 1.49× | 1.76× |
| 4 | 768 | 1.21× | **1.88×** |

Key takeaways:

- A single hpc8a node delivers **1.39×** the performance of a single hpc7a node on the LJ benchmark
- hpc8a scales smoothly: **1.39× → 1.76× → 1.88×** from 1N → 2N → 4N
- LJ at 2M atoms saturates around 4N on both families — communication overhead grows quickly past 768 ranks for this workload. The Rhodopsin and EAM benchmarks (with PPPM and many-body potentials respectively) sustain scaling further

### Arm — Graviton3E (hpc7g) vs Graviton4 (m8g)

Both Arm builds use OpenMPI 5.0.9 (required for Graviton4 at 192 rpn) and CPU-tuned flags (`-mcpu=neoverse-v1` on hpc7g, `-mcpu=neoverse-v2` on m8g). hpc7g runs 64 ranks/node; m8g runs 192 ranks/node. Performance is normalised to a single `hpc7g.16xlarge` node — higher is better.

![LAMMPS LJ Graviton3E vs Graviton4](https://github.com/aws-samples/hpc-applications/blob/main/Doc/img/LAMMPS/LAMMPS-LJ-Graviton3VsGraviton4.png?raw=true)

| Nodes | hpc7g (64 c/n) | m8g (192 c/n) |
|------:|---------------:|--------------:|
| 1 | 1.00× | **4.08×** |
| 2 | 1.88× | **5.48×** |
| 4 | 3.23× | — *(see note below)* |

Key takeaways:

- A single m8g node delivers **4.08×** the performance of a single hpc7g node — consistent with the 3× core-count ratio (192 vs 64) plus the larger L2/L3 caches and faster DDR5 on Neoverse V2
- **hpc7g scales near-linearly** through 4 nodes (3.23×) — the smaller 64-core nodes never run out of parallel work for 2M atoms
- m8g at 4 nodes (768 ranks) hit a reproducible MPI startup hang on this cluster (see "Known issues" below) — the 4N data point is omitted

### Known issues

- **m8g.48xlarge × 4 nodes hangs at LAMMPS startup with OpenMPI 5 + EFA** in our test cluster. The mpirun job advances past `MPI_Init` and prints the LAMMPS version banner, then deadlocks on the first MPI collective inside `Universe::Universe()`. This appears intermittent and node-specific (1N and 2N runs on the same instance type complete reliably). Workarounds we tried that did *not* eliminate the hang:
  - `--mca plm_rsh_agent ssh` (matches the WRF Arm launcher pattern)
  - `RDMAV_FORK_SAFE=1` (matches the WRF Arm launcher)
  - `--mca pml cm --mca mtl ofi --mca btl ^tcp,openib` (the established repo default)
  
  If you reproduce the same hang, try resubmitting on freshly-provisioned nodes — newly-launched instances tend to clear the deadlock. The same workload at 1N and 2N is reliable on m8g, and 4N is reliable on the Zen architectures (hpc8a / hpc7a).

- **hpc7a.96xlarge multi-node MPI hangs intermittently** with the same symptom. Adding the `--mca plm_rsh_agent ssh` and `RDMAV_FORK_SAFE=1` flags reduces but doesn't eliminate this. Resubmit on different (cold) nodes if the hang persists.

## Key metrics

- **Loop time** — LAMMPS' internal wall-clock measurement inside the time-integration loop, excluding setup and final I/O. Reported as `Loop time of <X> on <Y> procs for <Z> steps with <W> atoms` near the end of the run. Primary scaling metric.
- **Timesteps/sec** — derived as `timesteps / loop_time` — useful for comparing across models with different timestep budgets.
- **Atom-steps/sec** — derived as `atoms * timesteps / loop_time` — the workload-normalised metric, useful when comparing different atom counts (e.g. `SCALE` sweeps).
- **Wall time** — total mpirun wall time including MPI startup and final output, measured by the launcher.

## Files

### x86 ([`x86/`](x86/))

| File | Description |
|------|-------------|
| `build_lammps_x86.sbatch` | Build LAMMPS with GCC + OpenMPI 4 (AVX-512, Zen 4/5) |
| `lammps-benchmark.sbatch` | Run LJ / Rhodopsin / EAM with EFA + DynamoDB result recording |

### Arm ([`Arm/`](Arm/))

| File | Description |
|------|-------------|
| `build_lammps_arm.sbatch` | Build LAMMPS with GCC + OpenMPI 4 or 5 (auto-detects Graviton3E / Graviton4) |
| `lammps-benchmark.sbatch` | Run LJ / Rhodopsin / EAM — pick the build via `LAMMPS_ENV` |
