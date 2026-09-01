# Ansys Mechanical (MAPDL)

Ansys [Mechanical](https://www.ansys.com/products/structures/ansys-mechanical) is a
finite element analysis (FEA) solver for structural, thermal and coupled-field
simulation. This page covers running the Mechanical APDL (MAPDL) solver on AWS
with the distributed-memory parallel (DMP) solver under a job scheduler.

# Versions

Best practices here are written against **2026 R1** (`v261`, `ansys261`) and apply
to 2023 and newer.

# Installation

MAPDL ships inside the Ansys `FLUIDSTRUCTURES` package, so the same unattended
installer used for Fluent installs it — see
[Fluent-Install.sh](https://github.com/aws-samples/hpc-applications/blob/main/apps/Fluent/Fluent-Install.sh):

```
./Fluent-Install.sh /fsx s3://your_bucket/FLUIDSTRUCTURES_2026R1_LINX64.tgz
```

The solver then lives at `/fsx/ansys_inc/v261/ansys/bin/` (`mapdl`, `ansys261`).
For multi-node runs it **must** be installed on a shared filesystem; we
recommend [Amazon FSx for Lustre](https://aws.amazon.com/fsx/lustre/).

## Required OS libraries on Amazon Linux 2023

`ansys.e` links a legacy X11/Motif stack that **Amazon Linux 2023 does not ship**
(most of it was dropped after RHEL 7). Nothing warns you up front — the job just
dies with `error while loading shared libraries`, and each missing library only
surfaces after you fix the previous one. Ansys bundles all of them except one:

| Library | In AL2023? | Where to get it |
|---|---|---|
| `libGLU.so.1` | no | `sudo dnf -y install mesa-libGLU` |
| `libXp.so.6` | no | bundled: `ansys/syslib/ubuntu/` |
| `libXm.so.4` (Motif) | no | bundled: `polyflow/polyflow26.1.0/lnamd64/libs/` |
| `libxcb-xlib.so.0` | no | bundled: `commonfiles/MainWin/linx64/mw/lib-amd64_linux/X11SLES/` |
| `libxcb-sync.so.0` | no | same `X11SLES` directory |
| `libxcb-xevie.so.0` | no | same `X11SLES` directory |
| `libxcb-xprint.so.0` | no | same `X11SLES` directory |
| `libjpeg.so.62` | **yes** | already provided by libjpeg-turbo |
| `libpng12.so.0` | no | **not bundled and not in any AL2023 repo — must be built** |

Link only the missing ones into a single directory and prepend it, so no system
library is shadowed:

```bash
COMPAT=/fsx/ansys_compat; mkdir -p $COMPAT; V=/fsx/ansys_inc/v261
ln -sf $V/ansys/syslib/ubuntu/libXp.so.6                    $COMPAT/
ln -sf $V/polyflow/polyflow26.1.0/lnamd64/libs/libXm.so.4   $COMPAT/
X11=$V/commonfiles/MainWin/linx64/mw/lib-amd64_linux/X11SLES
for l in libxcb-xlib.so.0 libxcb-sync.so.0 libxcb-xevie.so.0 libxcb-xprint.so.0; do
    ln -sf $X11/$l $COMPAT/
done
export LD_LIBRARY_PATH=$COMPAT:$LD_LIBRARY_PATH
```

`libpng12` is required by the bundled Motif and has to be built once (libpng 1.2
is end-of-life and absent from AL2023):

```bash
curl -fsSLO https://download.sourceforge.net/libpng/libpng-1.2.59.tar.gz
tar xzf libpng-1.2.59.tar.gz && cd libpng-1.2.59
./configure --prefix=/fsx/libpng12 --disable-static && make -j && make install
ln -sf /fsx/libpng12/lib/libpng12.so.0 $COMPAT/libpng12.so.0
```

**Why not just install these with dnf?** Only `mesa-libGLU` is packaged for
AL2023. The others are not available from the package manager: `libXp` and
Motif (`libXm`) are not in the AL2023 repositories (`dnf provides` returns no
match), `libpng12` is end-of-life and likewise absent, and the four `libxcb-*`
sonames were removed from libxcb upstream years ago, so no current distribution
packages them. AL2023 does not support EPEL, so there is no supported extra
repository to add. Using the libraries Ansys ships also has an operational
advantage on ParallelCluster: the compat directory lives on the shared
filesystem, so ephemeral compute nodes need no per-node package installation —
`mesa-libGLU` is the only per-node install required.

Three traps worth knowing:

  * **Do not** satisfy `libGLU.so.1` from the copy Ansys bundles under
    `CFD-Post/tools/Mesa-7.1/`. That is a Mesa 7.1-era library whose own
    dependencies pull in `libpng12`, turning one missing library into two.
    Install the distro `mesa-libGLU` package instead.
  * Prefer the `polyflow` `libXm.so.4` over the copy in
    `Electronics/Linux64/defer/` — it has the smaller dependency closure.
  * `libpng12` **cannot** be faked with a symlink to `libpng16`. That gets past
    the "not found" error and then fails with ``version `PNG12_0' not found``,
    because libpng uses versioned symbols specifically to prevent ABI mixing.

# Running under a job scheduler

See [AnsysMechanical.sbatch](https://github.com/aws-samples/hpc-applications/blob/main/apps/AnsysMechanical/AnsysMechanical.sbatch)
for a complete example. The essentials:

```bash
# MAPDL takes the total core count from the -machines list, NOT from -np
cores_x_node=$(( SLURM_NPROCS / SLURM_JOB_NUM_NODES ))
for i in $(scontrol show hostnames=$SLURM_JOB_NODELIST); do
    machines=$machines:$i:$cores_x_node
done
machines=${machines:1}

mapdl -b -dis -mpi intelmpi -ssh -machines $machines -i input.dat -o output.log
```

  * `-dis` selects the distributed-memory (DMP) solver, `-mpi intelmpi` the MPI
    implementation. **Intel MPI gives the best performance on AWS.**
  * **Do not run the job as root.** `-ssh` launches the remote ranks over SSH,
    and Intel MPI also refuses to start as root
    (*"mpirun has detected an attempt to run as root"*). On AWS ParallelCluster
    only the default user (`ec2-user`) holds the inter-node key pair — root has
    an `authorized_keys` file but no private key. If you drive submission from
    automation that runs as root (Systems Manager, cron), submit with
    `sudo -u ec2-user`.
  * **`HOME` must be set.** MAPDL writes preferences under `$HOME` and the SSH
    start method needs `~/.ssh`; in a bare batch environment the job aborts.
  * In a non-login shell, `module` is undefined, so `module load intelmpi` fails
    silently. Guard it with
    `command -v module >/dev/null || source /etc/profile.d/modules.sh`.
  * On Amazon Linux 2023 use `dnf` rather than `yum` for the `mesa-libGLU`
    prerequisite. ParallelCluster compute nodes are ephemeral, so install it per
    job (or bake it into a post-install script / custom AMI).

## EFA settings

```bash
export I_MPI_OFI_LIBRARY_INTERNAL=0
module load intelmpi
export I_MPI_FABRICS=shm:ofi
export I_MPI_OFI_PROVIDER=efa
export I_MPI_MULTIRAIL=1
export FI_EFA_FORK_SAFE=1
module load libfabric-aws
```

Confirm EFA is actually in use — set `I_MPI_DEBUG=5` and look for
`libfabric provider: efa` in the output. A silent fallback to TCP is easy to miss
and costs performance.

# Key settings & tips (performance related ones)

  * **MAPDL is memory bound, and for the sparse direct solver memory capacity
    decides everything.** Each benchmark/model has a documented memory
    requirement. If the *aggregate* RAM of the job is below it, MAPDL falls back
    to an **out-of-core** mode that does heavy I/O, and runtime can more than
    double. Size the job to fit in memory first; only then optimise for cores.
  * **Check which memory mode you got.** MAPDL reports `In-Core` or
    `Out-of-Core` in its output — it is the first thing to look at when a run is
    unexpectedly slow.
  * Because DMP aggregates memory across nodes, **adding a node can be far more
    effective than adding cores**: it raises the memory ceiling as well as the
    core count. Moving a model that is out-of-core on one node onto two nodes
    (so it fits in aggregate RAM) can improve runtime by far more than the added
    parallelism alone would explain — the speedup is the memory mode changing,
    not parallel efficiency.
  * **Once the model fits, extra memory buys nothing** — memory bandwidth and
    clock speed take over. Do not pay for high-memory instances beyond what the
    model needs.
  * **Instance selection:**
      * [Hpc6id](https://aws.amazon.com/ec2/instance-types/hpc6id/) — 16 GB/core,
        the cost-effective way to buy memory capacity, **plus 15.2 TB of local
        NVMe** for solver scratch (see below). Best choice for large
        sparse-direct models, and the reference configuration in the sbatch.
      * [Hpc8a](https://aws.amazon.com/ec2/instance-types/hpc8a/) /
        [Hpc7a](https://aws.amazon.com/ec2/instance-types/hpc7a/) — 4 GB/core but
        high memory bandwidth and core count; fastest once the model fits.
      * R-family ([r7i](https://aws.amazon.com/ec2/instance-types/r7i/) /
        [r8i](https://aws.amazon.com/ec2/instance-types/r8i/), or
        [r7id](https://aws.amazon.com/ec2/instance-types/r7i/) /
        [i-family](https://aws.amazon.com/ec2/instance-types/i7ie/) for local
        NVMe) only when a single node must hold a very large model; per-unit
        cost is high and they are not faster when the model already fits.
  * **Under-population raises memory per core.** Running fewer cores per node
    gives each rank more memory *and* more bandwidth, which is often a better
    trade than filling the node. See
    [Utils/flexible-cores](https://github.com/aws-samples/hpc-applications/tree/main/Utils/flexible-cores)
    for the pinning lists — and note that lowering `--ntasks-per-node` alone is
    not enough: without explicit pinning the ranks pack onto the first socket and
    you lose half the cache and memory controllers.

## Scratch space and concurrency

Out-of-core solves write a large amount of scratch to the working directory —
**on the order of 0.5-0.8 TB per job** for the bigger benchmark models (MAPDL
reports it as `Sum Scratch Used(All)` at the end of the run). On a shared
filesystem this is a hard planning constraint:

  * Size the filesystem for `concurrent_jobs x per_job_scratch`, not for the
    input data.
  * **Cap how many out-of-core jobs run at once.** Running many out-of-core
    solves concurrently can exhaust even a multi-terabyte shared filesystem in
    hours. When that happens the jobs typically do **not** fail cleanly — they
    hang on I/O and have to be cancelled, leaving their scratch behind to be
    reclaimed manually.
  * Heavy sharing distorts timings. Watch **`MetadataOperations`** and burst
    throughput in CloudWatch rather than average throughput: a filesystem can
    look nearly idle on average bandwidth while elevated metadata rates and
    throughput bursts are significantly inflating individual run times.
    Benchmark numbers collected under that load are not trustworthy — validate
    any surprising result with an isolated re-run before acting on it.
  * **Prefer local NVMe instance store for the solver scratch when the instance
    has it.** [Hpc6id](https://aws.amazon.com/ec2/instance-types/hpc6id/)
    (15.2 TB per node), r7id/r8id and the i-family carry instance-store NVMe
    that is both faster (local, no network round-trip) and effectively free
    compared to shared-filesystem capacity and throughput. AWS ParallelCluster
    formats and mounts the instance store at **`/scratch`** automatically. Run
    the solve with its working directory on `/scratch` — MAPDL writes its
    scratch files to the working directory, and this works **multi-node**
    (verified): in DMP every rank resolves the same path locally on its own
    node, so each node uses its own NVMe. Three mechanics to get right:
    **create** the working directory on every node before launching (e.g.
    `srun --ntasks-per-node=1 mkdir -p $workdir`), keep the input `.dat`/`.db`
    on the shared filesystem (only the master rank reads them — symlinks into
    the workdir suffice), and at the end copy the output file (written on the
    master node) back to the shared filesystem, then **reclaim** `/scratch` on
    every node (`srun --ntasks-per-node=1 rm -rf $workdir`) — warm nodes are
    reused between jobs and leftover scratch accumulates. This removes
    out-of-core I/O from the shared filesystem entirely — the concurrency cap
    and contention concerns above then apply only to input staging, and
    out-of-core solves stop competing with each other. Remember instance store
    is ephemeral: anything not copied back is lost when the node scales down.
    The [AnsysMechanical.sbatch](https://github.com/aws-samples/hpc-applications/blob/main/apps/AnsysMechanical/AnsysMechanical.sbatch)
    in this directory implements all of this (`SCRATCH_MODE=auto|nvme|shared`).

## Exit codes: do not use them to decide success

Several standard benchmark models are configured to stop after a fixed number of
iterations. MAPDL then prints

```
*** ERROR ***  The number of iterations exceeds 1.
               The run is terminated at the user's request.
```

and **exits non-zero even though the run completed normally** (the output still
contains `RUN COMPLETED` and the full statistics block). Ansys's own `runBench.py`
post-processes the output files rather than checking exit status, and automation
should do the same: treat the presence of `RUN COMPLETED` and a final
`Elapsed Time (sec)` as the success signal. Gating on the exit code silently
discards valid results.

That said, do still scan the log for **genuine** errors rather than ignoring
`*** ERROR ***` lines wholesale. The fixed-iteration termination above is
expected on those models, but other errors — license checkout failures, MPI
communication aborts, insufficient memory or disk — are real and must fail the
run. A robust success test is therefore: `RUN COMPLETED` present, a final
`Elapsed Time (sec)` present, **and** no `*** ERROR ***` entries other than the
expected iteration-limit termination.

When parsing that timing line, note the format —

```
|   Elapsed Time (sec) =    1327.590    Date  =  08/29/2026   |
```

take the number immediately after the `=`; a trailing regex match will pick the
year out of the `Date` field.

# Benchmarks

Ansys publishes standard benchmark sets for Mechanical. The **V26 Cluster** set
contains six models designed for multi-node runs — three sparse-direct and three
iterative (PCG/JCG) — and ships `JOBS.CONFIG` with each model's size in millions
of DOF and its memory requirement, which is what you need to size the job:

| Job | Model | Analysis | Solver | MDOF | Memory |
|---|---|---|---|--:|--:|
| V26direct-4 | Peltier Cooling Block | static, nonlinear, thermal-electric | sparse, non-symmetric | 5.7 | 510 GB |
| V26direct-5 | Turbine | static, nonlinear, structural | sparse, symmetric | 20.7 | 710 GB |
| V26direct-6 | Speaker | harmonic, linear, structural | sparse, complex | 15.8 | 1100 GB |
| V26iter-4 | Power Supply Module | static, linear, thermal | JCG | 45.0 | 165 GB |
| V26iter-5 | Tractor Rear Axle | static, linear, structural | PCG | 105.0 | 260 GB |
| V26iter-6 | Engine Block | static, linear, structural | PCG | 185.0 | 550 GB |

The package's default core increments are **16, 32, 64, 128** — Mechanical is a
comparatively low-core-count workload, so scaling studies should focus there
rather than on the thousands of cores typical of CFD.

Note that those default increments do **not** map well onto the CPU topology of
the AWS HPC instances: Hpc7a/Hpc8a.96xlarge have **24 CCDs of 8 cores each**
(192 physical cores, one L3 cache per CCD), and 16/32/64 spread unevenly across
24 CCDs while 128 does not divide 192 at all. For even CCD loading — every L3
cache carrying the same number of ranks — prefer increments of
**24, 48, 96, 192** (1, 2, 4, 8 cores per CCD), set via the `INCREMENT LIST`
line in `DMPJOBS.DAT`, combined with the explicit pinning from
[Utils/flexible-cores](https://github.com/aws-samples/hpc-applications/tree/main/Utils/flexible-cores).

Note that the bundled `runBench.py` is explicitly *not* intended for scheduler
environments. Run the models under your scheduler using the command line it
prints:

```
ansys261 -b nolist -perf on -dis -machines <host:cores:...> -nt 1 -mpi intelmpi \
         -i <job>.dat -o <job>_DMP__np<N>.out
```

Each `.dat` resumes a matching `<job>geom.db`, so both files (and `checkver.mac`)
must be present in the run directory.

# Recording results

[dynamodb/record-benchmark.sh](https://github.com/aws-samples/hpc-applications/blob/main/apps/AnsysMechanical/dynamodb/record-benchmark.sh)
records a run into the shared AI-Powered HPC dataset. Beyond the auto-detected
fields, `--mdofs` (model size) is the key size driver and worth always passing.
There is no dedicated flag for the solver family, so record it as a
characteristic — for example
`--char solver_type=sparse-direct-symmetric` or `--char solver_type=pcg-iterative`,
and `--char memory_mode=InCore|OutOfCore` — since those two attributes explain
most of the runtime variation between otherwise identical configurations.

# Performance

TBC — scaling and instance-comparison charts to follow.
